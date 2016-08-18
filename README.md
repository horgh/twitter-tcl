# twitter-tcl

Twitter libraries and client scripts in Tcl.

The original purpose of these scripts was to provide an
[Eggdrop](http://www.eggheads.org) script to show tweets on IRC channels. The
repository includes libraries to assist with this and other related tools.

The libraries/tools in this repository are:

   * oauth.tcl - A library to integrate with Twitter's OAuth.
   * twitlib.tcl - Twitter API client library.
   * twitter.tcl - An Eggdrop IRC bot client/gateway script. Running this on a
     bot will output Twitter home timeline statuses to IRC channels. You can
     also do things like tweet from IRC and follow/unfollow users.
   * `twitter_poll` - A script that polls a Twitter home timeline for tweets
     and inserts them into a [PostgreSQL](https://www.postgresql.org) database.
   * `test_oauth.tcl` - A script to test authentication with OAuth. This can
     also be used to build the tokens/keys needed for OAuth.


# Requirements

 * tcllib
 * Tcl (8.5+)
 * `twitter_poll` depends on Pgtcl


# twitter.tcl Usage information

## Usage notes

  - Depends on oauth.tcl and twitlib.tcl.
  - We store state in the value of the variable `$state_file` file in the
    eggdrop root directory
  - The default time between tweet fetches is 10 minutes. You can alter the
    "bind time" option below to change to a different setting. Note you may not
    be able to use the 1 minute option if you are polling both the home and the
    mentions timeline as this can exceed Twitter's API limits.
  - Requires +o on the bot to issue !commands. This is different from having
    operator status in the channel. It means you must be recognized as a user
    with +o permission by the bot in its user records. If the bot does not
    respond to any of the commands in a channel set +twitter, then the bot may
    not recognize you.
  - You can set multiple channels that the bot outputs and accepts commands on
    by setting each channel `.chanset #channel +twitter`


## Setup

  - Load oauth.tcl, twitlib.tcl, and twitter.tcl on to your bot. You should
    ensure they load in this order as the first two are libraries that the
    latter depends on. Like other eggdrop scripts, you can place them in a
    scripts subdirectory, and source them as usual in your eggdrop configuration
    file.
  - Register for a consumer key/secret at [https://apps.twitter.com](https://apps.twitter.com)
    by creating an application. This is used for authentication.
  - Make sure your application is set to have Read and Write permission. If you
    don't, then you will not be able to do things like follow people or tweet.
    There is a 3rd permission level where you can access direct messages, so if
    you want to be able to do that, you should enable that too. The permission
    settings are under the application's Permissions tab (at the time of
    writing).
  - Find your consumer key (API key) and consumer secret (API secret) for the
    application you registered. At the time of writing, this is under the Keys
    and Access Tokens tab for your application.
  - `.chanset #channel +twitter` to provide access to !commands in #channel.
    These channels also receive status update output. You issue this command in
    the eggdrop's partyline which you can reach either through telnet or DCC
    chat. How you get on to this depends on your configuration.
  - Say `!twit_request_token` in a channel you set +twitter. You will be given
    instructions on what to do after (calling `!twit_access_token`, etc). The
    bot should respond to you in the channel. If it does not, confirm the
    channel is +twitter and that it recognizes you as a +o user. See usage
    notes above.
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
  * How do I change the Twitter account used by the bot?
    * Use the `!twit_request_token` command.


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


## IRC OAuth commands

  * `!twit_request_token <consumer_key> <consumer_secret>`
  * `!twit_access_token <oauth_token> <oauth_token_secret> <PIN from authentication url of !twit_request_token>`


# oauth.tcl Usage information

## Setup for users

  - Register for consumer key/secret at
   [http://twitter.com/oauth\_clients](http://twitter.com/oauth_clients).


## Library usage

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
