# twitter-tcl

Twitter libraries and client scripts in Tcl.

 * oauth.tcl - A library to authenticate with Twitter OAuth

 * twitter.tcl - An eggdrop IRC bot client/gateway script. Running this on
   a bot will output Twitter home timeline statuses to IRC channels, and
   allow various other Twitter requests, such as sending tweets, and
   following or unfollowing.


# Requirements

 * tcllib (unknown minimum version)

 * Tcl (unknown minimum version. tested on 8.5)

 * twitter.tcl depends on oauth.tcl


# twitter.tcl Usage information

## Usage notes:

  - Stores states in variable `$state_file` file in eggdrop root directory
  - Default time between tweet fetches is 10 minutes.
    Alter the "bind time" option below to change to a different setting.
  - Requires +o on the bot to issue !commands.
    You can set multiple channels that the bot outputs and accepts
    commands on by setting each channel `.chanset #channel +twitter`


## Setup:

  - Register for consumer key/secret at http://twitter.com/oauth_clients which
    will be needed to authenticate with oauth (and `!twit_request_token`)
  - `.chanset #channel +twitter` to provide access to !commands in #channel.
    These channels also receive status update output.
  - Trying any command should prompt you to begin oauth authentication, or
    just try `!twit_request_token` if not. You will be given instructions on
    what to do after (calling `!twit_access_token`, etc).
  - `!twit_request_token` / `!twit_access_token` should only need to be done
    once (unless you wish to change the account that is used).


## Authentication notes:

  - To begin authentication on an account use `!twit_request_token`
  - To change which account the script follows use `!twit_request_token` make
    sure you are logged into Twitter on the account you want and visit the
    authentication URL (or login to the account you want at this URL)
    and do `!twit_access_token` as before
  - Changing account / enabling OAuth resets tweet tracking state so you will
    likely be flooded by up to 10 tweets


## IRC Commands:

Note this list may be non-exhaustive. Refer to the trigger section
of the script for the canonical list.

  - `!twit` / `!tweet` - send a tweet
  - `!twit_msg` - send a private message
  - `!twit_trends`
  - `!follow`
  - `!unfollow`
  - `!twit_updates`
  - `!twit_msgs`
  - `!twit_search`
  - `!followers`
  - `!following`
  - `!retweet`
  - `!twit_searchusers`
  - `!update_interval`

### IRC OAuth commands

    !twit_request_token <consumer_key> <consumer_secret>

    !twit_access_token <oauth_token> <oauth_token_secret>
      <PIN from authentication url of !twit_request_token>


## oauth.tcl Usage information

### Setup for users:

  - Register for consumer key/secret at http://twitter.com/oauth_clients

### Library usage:

  - You can store `oauth_token` / `oauth_token_secret` from
    `get_access_token[]` and use it indefinitely (unless twitter starts
    expiring the tokens).
    Thus the setup (below) need only be done once by storing and reusing
    these.

  - start with `oauth::get_request_token`
   - Usage: `oauth::get_request_token $consumer_key $consumer_secret`
   - Returns dict including `oauth_token` / `oauth_token_secret` for
     https://api.twitter.com/oauth/authorize?oauth_token=OAUTH_TOKEN
   - going to this URL, logging in, and allowing will give a PIN e.g.
     1021393

  - then use pin as value for `oauth_verifier` in `oauth::get_access_token`
   - Usage: `oauth::get_access_token $consumer_key $consumer_token
     $oauth_token $oauth_token_secret $pin`
   - also use `oauth_token` / `oauth_token_secret` from
     `get_request_token` here
   - returns dict including new `oauth_token` & `oauth_token_secret` (access
     token)

  - afterwards use `oauth_token` / `oauth_token_secret` from
    `get_access_token` in `oauth::query_api` to make API calls
   - Usage: `oauth::query_api $url $consumer_key $consumer_secret $http_method
     $oauth_token $oauth_token_secret $key:value_http_query`
   - the `$key:value_http_query` is such that you would pass to
     `http::formatQuery`
     e.g. `status {this is a tweet}`
   - Example call: `puts [oauth::query_api 
     http://api.twitter.com/1/statuses/update.json <key> <secret> POST
     $oauth_token_done $oauth_token_secret_done [list status "does it work"]]`
