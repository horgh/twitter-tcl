# twitter-tcl

Twitter libraries and client scripts in Tcl.

 * oauth.tcl - A library to authenticate with Twitter OAuth.

 * twitter.tcl - An eggdrop IRC bot client/gateway script. Running this on
   a bot will output Twitter home timeline statuses to IRC channels, and
   allow various other Twitter requests, such as sending tweets, and
   following or unfollowing.

 * `twitter_poll.tcl` - A script that polls a home timeline for tweets and
   inserts them into a postgres database.

 * `test_oauth.tcl` - A script to test authentication with OAuth.
   This can also be used to build the tokens/keys needed for OAuth.


# Requirements

 * tcllib (unknown minimum version)

 * Tcl (unknown minimum version. Tested with 8.5 and 8.6.)

 * twitter.tcl depends on oauth.tcl and twitlib.tcl.


# twitter.tcl Usage information

## Usage notes

  - We store state in the value of the variable `$state_file` file in the
    eggdrop root directory
  - The default time between tweet fetches is 10 minutes.
    You can alter the "bind time" option below to change to a different setting.
    Note you may not be able to use the 1 minute option if you are polling both
    the home and the mentions timeline as this can exceed Twitter's API limits.
  - Requires +o on the bot to issue !commands. This is different from having
    operator status in the channel. It means you must be recognized as a user
    with +o permission by the bot in its user records. If the bot does not
    respond to any of the commands in a channel set +twitter, then the bot may
    not recognize you.
  - You can set multiple channels that the bot outputs and accepts
    commands on by setting each channel `.chanset #channel +twitter`


## Setup

  - Load oauth.tcl, twitlib.tcl, and twitter.tcl on to your bot. You should
    ensure they load in this order as the first two are libraries that the
    latter depends on. Like other eggdrop scripts, you can place them in a
    scripts subdirectory, and source them as usual in your eggdrop configuration
    file.
  - Register for a consumer key/secret at
   [http://twitter.com/oauth\_clients](http://twitter.com/oauth_clients) which
   will be needed to authenticate with oauth (and `!twit_request_token`)
  - `.chanset #channel +twitter` to provide access to !commands in #channel.
    These channels also receive status update output. You issue this command in
    the eggdrop's partyline which you can reach either through telnet or DCC
    chat. How you get on to this depends on your configuration.
  - Trying any command should prompt you to begin oauth authentication, or just
    try `!twit_request_token` if not. You will be given instructions on what to
    do after (calling `!twit_access_token`, etc). The bot should respond to you
    in the channel. If it does not, confirm the channel is +twitter and that it
    recognizes you as a +o user. See usage notes above.
  - `!twit_request_token` / `!twit_access_token` should only need to be done
    once (unless you wish to change the account that is used).
  - Alter the variables at the top of twitlib.tcl and twitter.tcl to change
    various options.


## FAQ

  * Error `Update retrieval (mentions) failed: OAuth not initialised.` in
    partyline.
    * This means you need to complete the OAuth authentication. To do this, see
      the setup points above. TL;DR: Issue `!twit_request_token` in a channel
      set +twitter. The bot should answer you.
  * No status updates show.
    * Ensure that `poll_home_timeline` at the top of twitter.tcl is set 1.

## Authentication notes

  - To begin authentication on an account use `!twit_request_token`.
  - To change which account the script follows use `!twit_request_token`. Make
    sure you are logged into Twitter on the account you want and visit the
    authentication URL (or login to the account you want at this URL)
    and do `!twit_access_token` as before.
  - Changing account / enabling OAuth resets tweet tracking state so you will
    likely be flooded by up to `max_updates` tweets.


## IRC Commands

This list may be non-exhaustive. Refer to the trigger section of the script for
the canonical list.

  - `!twit` / `!tweet` - Send a tweet
  - `!twit_msg` - Send a private message
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

  * `!twit_request_token <consumer_key> <consumer_secret>`
  * `!twit_access_token <oauth_token> <oauth_token_secret> <PIN from authentication url of !twit_request_token>`


## oauth.tcl Usage information

### Setup for users

  - Register for consumer key/secret at
   [http://twitter.com/oauth\_clients](http://twitter.com/oauth_clients).


### Library usage

  - You can store `oauth_token` / `oauth_token_secret` from
    `::oauth::get_access_token` and use them indefinitely.
    Thus the setup (below) need only be done once by storing and reusing
    these.
  - Start with `::oauth::get_request_token`.
   - Usage: `::oauth::get_request_token $consumer_key $consumer_secret`
   - Returns dict including `oauth_token` / `oauth_token_secret` for
     `https://api.twitter.com/oauth/authorize?oauth_token=OAUTH_TOKEN`
   - Going to this URL, logging in, and allowing will give a PIN e.g.
     1021393.
  - Then use the pin as the value for `oauth_verifier` in
    `::oauth::get_access_token`.
   - Usage: `oauth::get_access_token $consumer_key $consumer_token
     $oauth_token $oauth_token_secret $pin`
   - Also use `oauth_token` / `oauth_token_secret` from
     `get_request_token` here.
   - Returns dict including new `oauth_token` & `oauth_token_secret` (access
     token).
  - Afterwards use `oauth_token` / `oauth_token_secret` from
    `get_access_token` in `::oauth::query_api` to make API calls.
   - Usage: `oauth::query_api $url $consumer_key $consumer_secret $http_method
     $oauth_token $oauth_token_secret $key:value_http_query`
   - The `$key:value_http_query` is such that you would pass to
     `::http::formatQuery` e.g. `status {this is a tweet}`.
   - Example call: `puts [oauth::query_api
     http://api.twitter.com/1/statuses/update.json <key> <secret> POST
     $oauth_token_done $oauth_token_secret_done [list status "does it work?"]]`
