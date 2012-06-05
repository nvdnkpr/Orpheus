# Orpheus - Redis Little Helper
Orpheus is a Redis Object Model for CoffeeScript.

`npm install orpheus`

- Rails like models
- Validations
- Private properties
- simple relations
- transactional spirit, with multi
- Dynamic keys
- Maps between strings and ids

A stable release will be out soon

# In Action
```coffee
  # Let's create a couple of models
  class User extends Orpheus
    constructor: ->
      @has 'book'
      
      @zset 'alltime_ranking'
      @str 'about_me'
      
      # one to one map between the id and the fb_id
      @map @str 'fb_id'
      
      # Private Keys
      @private @str 'fb_secret'
      
      # Dynamic Keys
      @zset 'monthly_ranking'
        key: ->
          d = new Date()
          "ranking:#{d.getFullYear()}:#{d.getMonth()+1}"
  
  class Book extends Orpheus
    constructor: ->
      @has 'user'
      @str 'name'
      @num 'votes'
      @list 'reviews'
      @set 'authors'
      
      # Validations
      @validate 'votes', (vote) ->
        if 0 <= vote <= 10
          true
        else
          message: "Vote isn't between 0 and 10"
  
  # Instantiate them
  user = Player.create()
  book = Book.create()
  
  # Add information in a boring way
  book('dune')
    .votes.incrby(6)
    .reviews.push('it sucked', 'it was awesome')
    .authors.smembers()
    .exec (err, res, id) ->
      # ...
  
  # Or in a fun way
  book('dune').add
    votes:  6
    reviews: ['it sucked', 'it was awesome']
  .authors.smembers()
  .exec (err, res, id) ->
    # ...
  
  # Get information, without private properties
  user('olga').get (err, res, id) -> #...
  
  # Get all the information
  user('xss-exhibitionist').getall (err, res, id) -> # ...

  # Fun with relations
  # add to the total votes for the book
  # hincrby prefix:bo:catch22 votes 1
  # and to olga's votes for the book
  # hincrby prefix:bo:catch22:us:olga votes 1
  book('catch22').add
    votes: 1
  .user('olga').add
    votes: 1
  .exec -> # ...
  
  # for every relation you get a free set
  book('SICP').users.smembers (err, users) ->
    return next err, false if err
    
    # and a helping hand for getting details
    book('SICP').users.get users, (err, users) ->
      next err, users
  
  # Sweet user authentication with maps
  # (this example uses passportjs)
  fb_connect = (req, res, next) ->
    fb = req.account
    fb_details =
      fb_id:    fb.id
      fb_name:  fb.displayName
      fb_token: fb.token
      fb_gener: fb.gender
      fb_url:   fb.profileUrl
    
    id = if req.user then req.user.id else fb_id: fb.id
    player id, (err, player, is_new) ->
      next err if err
      # That's it, we just handled autorization,
      # new users and authentication in one go
      player
        .set(fb_details)
        .exec (err, res, user_id) ->
          req.session.passport.user = user_id if user_id
          next err
  
  # We all hate configurations
  Orpheus.configure
    client: redis.createClient()
    prefix: 'bookapp'
```
## Validations ##

```coffee
class User extends Orpheus
  constructor: ->
    @str 'name'
    @validate 'name', (s) -> if s is 'something' then true else 'name should be "something".'

player = Player.create()
player('james').set
  name: 'james!!!'
.err (err) ->
  if err.type is 'validation'
    log err # <OrpheusValidationErrors>
  else
    # something is wrong with redis
.exec (res) ->
  # Never ever land
```

**OrpheusValidationErrors** has a few convenience functions:

- **add**: adds an error
- **toResponse**: returns a JSON:
```coffee
{
  status: 400, # Bad Request
  errors:
    name: ['name should be "something".']
}
```

`errors` contains the actual error objects:

```coffee
{
  name: [
    msg: 'name should be "something".',
    command: 'hset',
    args: ['james!!!'],
    value: 'james!!!'
  ],
  # ...
}


### Custom Validations ###

```coffee
class Player extends Orpheus
	constructor: ->
		@str 'name'
		@validate 'name', (s) -> if s is 'babomb' then true else 'String should be babomb.'
```

### Number Validations ###

```coffee
class Player extends Orpheus
	constructor: ->
		@num 'points'
		
		@validate 'points',
			numericality:
				only_integer: true
				greater_than: 3
				greater_than_or_equal_to: 3
				equal_to: 3
				less_than_or_equal_to: 3
				odd: true
```

Options:

- **only_integer**: `"#{n} must be an integer."`
- **greater_than**: `"#{a} must be greater than #{b}."`
- **greater_than_or_equal_to**: `"#{a} must be greater than or equal to #{b}."`
- **equal_to**: `"#{a} must be equal to #{b}."`
- **less_than**: `"#{a} must be less than #{b}."`
- **less_than_or_equal_to**: `"#{a} must be less than or equal to #{b}."`
- **odd**: `"#{a} must be odd."`
- **even**: `"#{a} must be even."`

### Exclusion and Inclusion Validations ###

```coffee
class Site extends Orpheus
	constructor: ->
		@str 'subdomain'
		@str 'size'
		@validate 'subdomain',
			exclusion: ['www', 'us', 'ca', 'jp']
		@validate 'size',
			inclusion: ['small', 'medium', 'large']
```

## Development ##
### Test ###
`cake test`

### Contribute ###

- `cake dev`
- Add your tests.
- Do your thing.
- `cake dev`

## Roadmap ##

- Validations
- Promises 