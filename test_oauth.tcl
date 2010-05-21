#!/usr/bin/env tclsh
set auto_path [linsert $auto_path 0 [pwd]]
package require oauth

# for get_access_token
# from request response
set oauth_token []
set oauth_token_secret []
# from website after allowing (pin)
set oauth_verifier []

# for regular queries
set oauth_token_done []
set oauth_token_secret_done []

# get request token
puts [oauth::get_request_token]

# once have pin from request_token url
#puts [oauth::get_access_token $oauth_token $oauth_token_secret $oauth_verifier]

#puts [oauth::query_api http://api.twitter.com/1/statuses/update.json POST $oauth_token_done $oauth_token_secret_done [list status "does it work"]]
