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
set oauth_token_done {}
set oauth_token_secret_done {}

# get request token
#puts [oauth::get_request_token]

# once have pin from request_token url
#puts [oauth::get_access_token $oauth_token $oauth_token_secret $oauth_verifier]

# tweet
#puts [oauth::query_api http://api.twitter.com/1/statuses/update.json POST $oauth_token_done $oauth_token_secret_done [list status "squirly is a traffic light #2"]]

# normal search
#puts [oauth::query_api http://search.twitter.com/search.json POST $oauth_token_done "ffffffffff" [list q "hi there"]]

# user search
#puts [oauth::query_api http://api.twitter.com/1/users/search.json?q=fuck GET $oauth_token_done $oauth_token_secret_done []]
#puts [oauth::query_api http://api.twitter.com/1/users/search.json?q=simon+fraser&per_page=5 GET $oauth_token_done $oauth_token_secret_done [list q {simon fraser} per_page 5]]
#puts [oauth::query_api http://api.twitter.com/1/users/search.json GET $oauth_token_done $oauth_token_secret_done [list q fuck]]
#puts [oauth::query_api http://api.twitter.com/1/users/search.json GET $oauth_token_done $oauth_token_secret_done []]
# works
puts [oauth::query_api http://api.twitter.com/1/users/search.json?q=[http::formatQuery "simon fraser"]&per_page=5 GET $oauth_token_done $oauth_token_secret_done [list q "simon fraser" per_page 5]]
