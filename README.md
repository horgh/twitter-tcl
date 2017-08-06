# twitter-tcl

This project provides an [Eggdrop](http://www.eggheads.org) bot script to
show tweets in IRC channels. You can also do things like tweet from IRC.

The repository contains libraries that are useful independently as well.

The scripts/libraries in this repository are:

  * `twitoauth.tcl` - A library to integrate with Twitter's OAuth.
  * `twitlib.tcl` - A Twitter API client library.
  * `twitter.tcl` - An Eggdrop IRC bot client/gateway script. You can use
    this to output Twitter home/mentions timeline statuses to IRC channels.
    You can also do things like tweet from IRC and follow/unfollow users.


# Requirements

  * Eggdrop
  * tcllib
  * Tcl (8.5+)


## Setup

  - Load `twitoauth.tcl`, `twitlib.tcl`, and `twitter.tcl` on to your bot.
    You should ensure they load in this order as the first two are
    libraries that the latter depends on. Like other Eggdrop scripts, you
    can place them in a scripts subdirectory, and source them as usual in
    your configuration file.
  - Review the variables at the top of `twitlib.tcl` and `twitter.tcl`. You
    can change the options there if you like. The defaults are probably
    okay.
  - Register for a consumer key/secret at
    [apps.twitter.com](https://apps.twitter.com) by creating an
    application. This is used for authentication with Twitter.
  - Make sure your Twitter application is set to have Read and Write
    permission. If it isn't then you will not be able to do things like
    follow people or tweet. There is a 3rd permission level where you can
    access direct messages, so if you want to be able to do that, you
    should enable that too. The permission settings are under the
    application's Permissions tab (at the time of writing).
  - Find your Twitter consumer key (API key) and consumer secret (API
    secret) for the application you registered. At the time of writing,
    this is under the Keys and Access Tokens tab for your application.
  - `.chanset #channel +twitter` to provide access to `!commands` in
    `#channel`. These channels also receive status update output. You issue
    this command in the Eggdrop's partyline which you can reach either
    through telnet or DCC chat. How you get on to the partyline depends on
    your configuration.
  - Say `!twit_request_token` in a channel you set `+twitter`. You will be
    given instructions on what to do after (calling `!twit_access_token`,
    etc). The bot should respond to you in the channel. If it does not,
    confirm the channel is `+twitter` and that it recognizes you as a +o
    user.


## Options

There are more options than these. Refer to the header section of the
scripts to see what else is available.

  - The script stores state (authentication keys, seen tweets, etc) in the
    file defined by the `$state_file` variable. This file is relative to
    the Eggdrop root directory. You can set it to any path.
  - The default time between tweet fetches is 10 minutes. You can alter the
    "bind time" option below to change to a different setting. Note you may
    not be able to use the 1 minute option if you are polling both the home
    and the mentions timeline as this can exceed Twitter's API limits.


## IRC channel commands

  - `!twit` / `!tweet` - Send a tweet
  - `!twit_msg` - Send a private message
  - `!twit_trends` - Look up trending hashtags
  - `!follow` - Follow an account
  - `!unfollow` - Unfollow an account
  - `!twit_updates` - Retrieve the most recent status updates
  - `!twit_msgs` - Retrieve direct messages
  - `!twit_search` - Search tweets
  - `!twit_searchusers` - Search users
  - `!followers` - Show followers of a specified account (limited by the
    option `followers_limit`)
  - `!following` - Show who the specified account is following (limited by
    the option `followers_limit`)
  - `!retweet` - Retweet
  - `!update_interval` - Change the time between status fetches
  - `!twitstatus` - Show bot's Twitter status. Currently this shows its
    screen name.
  - `!twit_request_token <consumer_key> <consumer_secret>`
    - Initiate authentication. This is step one of the authentication
      process.
  - `!twit_access_token <oauth_token> <oauth_token_secret> <PIN from authentication url of !twit_request_token>`
    - Complete authentication. This is step two of the authentication
      process.


## FAQ

  - How do I control what channels the bot shows tweets in?
    - You can set multiple channels that the bot outputs and accepts
      commands on by setting each channel `.chanset #channel +twitter`.
  - Why isn't the bot responding to the `!commands`?
    - First make sure the channel is set `+twitter`.
    - If it is, then you may not be recognized as +o by the bot. Many
      commands require that the bot recognizes you as +o. This is not the
      same as having operator status in the channel having operator status
      in the channel. It means you must be recognized as a user with +o
      permission by the bot in its user records.
  - Why do I see the error `Update retrieval (mentions) failed: OAuth not
    initialised.` in the bot's partyline?
    - This means you need to complete the OAuth authentication. To do this, see
      the setup points above. TL;DR: Issue `!twit_request_token` in a channel
      set `+twitter`. The bot should answer you.
  - Why do no status updates show?
    - Ensure that `poll_home_timeline` at the top of `twitter.tcl` is set 1.
  - How do I change the Twitter account used by the bot?
    - Call `!twit_request_token` again. This restarts the authentication
      process. Make sure you are logged into Twitter on the account you
      want and visit the authentication URL (or login to the account you
      want at this URL) and do `!twit_access_token` as when you initially
      set up the bot.
  - Why do I see errors like "Read-only application cannot POST" when
    trying to tweet or follow?
    - This means Twitter thinks your bot's credentials do not have write
      permission. Ensure that the application you set up for the bot is set
      to have read and write permissions. Also ensure that the key and
      secret you use in `!twit_request_token` match after checking/updating
      the write permission. You should start over from
      `!twit_request_token`.
