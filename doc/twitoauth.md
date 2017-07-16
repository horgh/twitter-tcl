# twitoauth.tcl

This is a library for interacting with Twitter's OAuth. It is useful for
developers interested in creating their own Twitter clients.


## Setup for users

  - Register for consumer key/secret at
   [twitter.com/oauth\_clients](https://twitter.com/oauth_clients).


## Library usage

  - You can store `oauth_token` / `oauth_token_secret` from
    `::twitoauth::get_access_token` and use them indefinitely. Thus the
    setup (below) need only be done once by storing and reusing these.
  - Start with `::twitoauth::get_request_token`.
   - Usage: `::twitoauth::get_request_token $consumer_key $consumer_secret`
   - Returns a dict including `oauth_token` / `oauth_token_secret` for
     `https://api.twitter.com/oauth/authorize?oauth_token=OAUTH_TOKEN`
   - Going to this URL, logging in, and allowing will give a PIN e.g.
     1021393.
  - Then use the pin as the value for `oauth_verifier` in
    `::twitoauth::get_access_token`.
   - Usage: `::twitoauth::get_access_token $consumer_key $consumer_token
     $oauth_token $oauth_token_secret $pin`
   - Also use `oauth_token` / `oauth_token_secret` from
     `get_request_token` here.
   - Returns a dict including new `oauth_token` & `oauth_token_secret`
     (access token).
  - Afterwards use `oauth_token` / `oauth_token_secret` from
    `get_access_token` in `::twitoauth::query_api` to make API calls.
   - Usage: `::twitoauth::query_api $url $consumer_key $consumer_secret $http_method
     $oauth_token $oauth_token_secret $key:value_http_query`
   - The `$key:value_http_query` is such that you would pass to
     `::http::formatQuery` e.g. `status {this is a tweet}`.
   - Example call: `puts [::twitoauth::query_api
     https://api.twitter.com/1/statuses/update.json <key> <secret> POST
     $oauth_token_done $oauth_token_secret_done [list status "does it work?"]]`
