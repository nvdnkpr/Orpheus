# Orpheus - a small DSL for redis
#-------------------------------------#

_ = require 'underscore'           # flatten, extend, isString
async = require 'async'            # until
os = require 'os'                  # id generation
inflector = require './inflector'  # pluralize
commands = require './commands'    # redis commands
command_map = commands.command_map

log = console.log

# Orpheus
#-------------------------------------#
class Orpheus
	
	# Configuration
	@config:
		prefix: 'orpheus' # redis prefix, orpheus:obj:id:prop
		# client -       the redis client we should use
	
	@configure: (o) ->
		@config = _.extend @config, o
	
	# easy reference to all models
	@schema = {}
	
	# UniqueID counters
	@id_counter: 0
	@unique_id: -> @id_counter++
	
	# Mini pub/sub for errors
	@topics = {}
	
	@trigger = (topic, o) ->
		subs = @topics[topic]
		return unless subs
		(sub o for sub in subs)
	
	@on = (topic, f) ->
		@topics[topic] ||= []
		@topics[topic].push f
	
	# Orpheus model extends the model
	# - we can automagically detect
	#   the model name and qualifier.
	# - you don't need to call super()
	@create: ->
		
		class OrpheusModel extends @
			
			constructor: (@name, @q) ->
				@redis = Orpheus.config.client
				@prefix = Orpheus.config.prefix
				@pname = inflector.pluralize @name
				@model = {}
				@rels = []
				@rels_qualifiers = []
				@validations = []
				
				@fields = [
					'str'  # @str 'name'
					'num'  # @num 'points'
					'list' # @list 'activities'
					'set'  # @set  'uniques'
					'zset' # @zset 'ranking'
					'hash' # @hash 'progress'
				]
				
				# Create a simple schema for all fields
				for f in @fields
					do (f) =>
						@[f] = (field, options = {}) ->
							throw new Error("Field name already taken") if @model[field]
							
							@model[field] =
								type: f
								options: options
							
							return field
				
				# Create the model
				super()
			
			# Add mapping
			map: (field) ->
				throw new Error("Map only works on strings") if @model[field].type isnt 'str'
				@model[field].options.map = true
			
			# Add relations
			has: (rel) ->
				@rels.push rel
				qualifier = rel.substr(0,2)
				@rels_qualifiers.push qualifier
				
				# create a relation function,
				# e.g. user(12).book(15)
				@[rel] = (id) ->
					@["#{qualifier}_id"] = id
					return @
			
			# Add a validation function to a field
			# e.g. @validate 'name', (name) ->
			#  if name is 'jay' then true else message: 'beep!'
			validate: (key, func) ->
				@validations[key] ||= []
				@validations[key].push func
			
			# Mark field as private
			private: (field) ->
				@model[field].options.private = true
			
			# return OrpheusAPI if we have the id, or it's
			# a new id. otherwise, hget the id and then call
			# orpheus api.
			id: (id, fn) =>
				if not id or _.isString(id) or _.isNumber(id)
					if fn
						new_model = new OrpheusAPI(id, this)
						fn null, new_model, new_model.id, false
					else
						new OrpheusAPI(id, this)
				else
					for k,v of id
						pk = inflector.pluralize k
						@redis.hget "#{@prefix}:#{@pname}:map:#{pk}", v, (err, model_id) =>
							return fn err, false if err
							if model_id
								# existing
								new_model = new OrpheusAPI(model_id, this)
								fn null, new_model, model_id, false
							else
								# new
								model = new OrpheusAPI(null, this)
								model.add_map pk, v
								fn null, model, model.id, true
					
		
		# Converts class Player to 'player'
		name = @toString().match(/function (.*)\(/)[1].toLowerCase()
		
		# Qualifier
		q = name.substr(0,2)
		
		# Add to Schema
		Orpheus.schema[name] = @
		
		model = new OrpheusModel(name, q)
		return model.id


# Orpheus API
#-------------------------------------#
class OrpheusAPI
	constructor: (id, @model) ->
		
		_.extend @, @model
		
		# Redis multi commands
		@_commands = []
		
		@validation_errors = []
		
		# new or existing id
		@id = id or @generate_id()
		
		# Create functions for working with the relation set
		# e.g. user(15).books.sadd('dune') will map to sadd
		# orpheus:us:15:books dune.
		for rel in @rels
			prel = inflector.pluralize rel
			@[prel] = {}
			for f in commands.set
				do (prel, f) =>
					@[prel][f] = (args..., fn) =>
						@redis[f](["#{@prefix}:#{@q}:#{@id}:#{prel}"].concat(args), fn)
					
					# shorthand, use add instead of sadd
					@[prel][f[1..]] = @[prel][f]
			
			# Extract related models information,
			# one by one, based on an array of ids
			# e.g. user(10).books.get ['dune', 'valis']
			do (rel, prel) =>
				@[prel].get = (arr = [], fn) =>
					return fn null, [] unless arr.length
					results = []
					
					async.until ->
							results.length is arr.length
							
						, (c) ->
							# create the relation model
							model = Orpheus.schema[rel].create()
							
							# and get its information based on the arr id
							model(arr[results.length]).get (err, res) ->
								unless err
									results.push res
								c err
						, (err) ->
							fn err, results 
		
		# for every field, add all the redis commands
		# for its corresponding type.
		for key, value of @model
			@[key] = {}
			
			for f in commands[value.type]
				do (key, f) =>
					@[key][f] = (args...) =>
						# add multi command
						@_commands.push _.flatten [f, @get_key(key), args]
						
						# Extra commands: mapping
						@extra_commands(key, f, args) if @model[key].options.map
						
						return @
					
					# Shorthand form, incrby instead of zincrby and hincrby is also acceptable
					# str: h, num: h, list: l, set: s, zset: z
					@[key][f[1..]] = @[key][f] if f[0] is commands.shorthands[value.type]
		
		# create the add, set and del commands
		# based on the commands map they call
		# the respective command for the key,
		# value they recieve.
		@operations = ['add', 'set', 'del']
		for f in @operations
			do (f) =>
				@[f] = (o) ->
					for k, v of o
						
						# Run Validations
						if @validations[k]
							for valid in @validations[k]
								msg = valid(v)
								unless msg is true
									msg = new Error(msg.message)
									msg.type = 'validation'
									@validation_errors.push msg 
						
						# Add the Command. Note we won't actually
						# execute any of this commands if the
						# validation has failed.
						type = @model[k].type
						command = command_map[f][type]
						@[k][command](v) # e.g. @name.hset 'abe'
					
					return this
	
	
	# Generate a unique ID for model, similiar to MongoDB
	# http://www.mongodb.org/display/DOCS/Object+IDs
	generate_id: ->
		time = "#{new Date().getTime()}" # we convert to a str to
		                                 # avoid 4.3e+79 as id
		pid = process.pid
		host = 0; (host += s.charCodeAt(0) for s in os.hostname())
		counter = Orpheus.unique_id()
		
		"#{host}#{pid}#{time}#{counter}"
	
	
	get_key: (key) ->
		# Default: orpheus:pl:15
		k = "#{@prefix}:#{@q}:#{@id}"
		
		# Add qualifiers, if the relation was set.
		# e.g. orpheus:us:30:book:dune:page:13
		for rel in @rels_qualifiers when @[rel+"_id"]
			k += ":#{rel}:"+@[rel+"_id"]
		
		# delete and get just need the key for
		# del, hmget and hgetall
		return k unless key
		
		type = @model[key].type
		
		# generate a new key name, if it has a
		# dynamic key function.
		if key and @model[key].options.key
			key = @model[key].options.key()
		
		if type is 'str' or type is 'num'
			# orpheus:us:15:name somename
			return [k, key]
		else
			# orpheus:us:15:somelist
			return "#{k}:#{key}"
	
	add_map: (field, key) ->
		@_commands.push ['hset', "#{@prefix}:#{@pname}:map:#{field}", key, @id]
	
	extra_commands: (key, command, args) ->
		# Map stuff, e.g.
		# orpheus:users:map:fb_ids
		if @model[key].options.map and command is 'hset'
			pkey = inflector.pluralize key
			@add_map pkey, args[0]
	
	# deletes the model.
	delete: (fn) ->
		# flush commands and validations
		@_commands = [] 
		@validation_errors = []
		
		hdel_flag = false # no need to delete a hash twice
		for key, value of @model
			type = value.type
			if type is 'str' or type is 'num'
				unless hdel_flag
					hdel_flag = true
					@_commands.push ['del', @get_key()]
			else
				@_commands.push ['del', @get_key(key)]
		
		@exec fn
	
	# get public information only
	get: (fn) ->
		@getall fn, true
	
	# get ALL the model information.
	getall: (fn, get_private = false) ->
		# Helper for determining if a value is private or not
		not_private = -> not get_private or get_private and value.options.private isnt true
		
		schema = [] # we use the schema to convert the response
		            # to the appropriate value
		
		# It's ugly and nasty, but sometimes we want hmget
		# and sometimes we want hgetall
		hgetall_flag = false
		hash_parts_are_private = false
		hmget = []
		
		for key, value of @model
			type = value.type
			switch type
				when 'str', 'num'
					hgetall_flag = true
					if not_private()
						hmget.push key
					else
						hash_parts_are_private = true
						
				when 'list'
					if not_private()
						@_commands.push ['lrange', @get_key(key), 0, -1]
						
				when 'set'
					if not_private()
						@_commands.push ['smembers', @get_key(key)]
						
				when 'zset'
					if not_private()
						@_commands.push ['zrange', @get_key(key), 0, -1, 'withscores']
						
				when 'hash'
					if not_private()
						@_commands.push ['hgetall', @get_key(key)]
			
			schema.push key unless type is 'str' or type is 'num'
		
		if hash_parts_are_private
			if hmget.length
				@_commands.push ['hmget', @get_key()].concat(hmget)
				schema.push hmget
		else if hgetall_flag
			@_commands.push ['hgetall', @get_key()]
			schema.push 'hash'
		
		@exec (err, res, id) =>
			result = false
			unless err
				# convert the response type, based on the schmea
				result = {}
				for o,i in schema
					if o is 'hash'
						_.extend result, res[i]
					else if Array.isArray o
						for prop, j in o
							result[prop] = res[i][j]
					else
						result[o] = res[i]
				
				result.id = @id
			
			fn err, result, @id
	
	# execute the multi commands
	exec: (fn) ->
		if @validation_errors.length
			return fn @validation_errors, false, @id
		
		@redis
			.multi(@_commands)
			.exec (err, res) =>
				if err
					err.time = new Date()
					err.level = 'ERROR'
					err.type = 'Redis'
					err.msg = 'Failed Multi Execution'
					@_errors.push err
					Orpheus.trigger 'error', err
				fn err, res, @id

module.exports = Orpheus