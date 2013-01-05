#
# 0.2 - ???
#  - create base_url correctly for signing (remove ?params=...)
#  - improve error msg if http timeout occurs
#  - remove need to hardcode consumer key/secret by providing them as arguments
#    to the various functions
#
# 0.1 - May 18 2010
#  - Initial release
# 
# by horgh (www.summercat.com)
#
# OAuth (1.0/1.0a) library for Twitter
#
# Requirements:
#  - Tcl 8.5+ and "recent" tcllib (developed with tcllib 1.12)
#
# Setup for users:
#  - Register for consumer key/secret at http://twitter.com/oauth_clients
#
# Library usage:
#  - You can store oauth_token/oauth_token_secret from get_access_token[] and
#    use it indefinitely (unless twitter starts expiring the tokens). Thus the
#    setup (below) need only be done once by storing and reusing these.
#
#  - start with oauth::get_request_token
#   - usage: oauth::get_request_token $consumer_key $consumer_secret
#   - returns dict including oauth_token/oauth_token_secret for https://api.twitter.com/oauth/authorize?oauth_token=OAUTH_TOKEN
#   - going to this url, logging in, and allowing will give a PIN e.g. 1021393
#
#  - then use pin as value for oauth_verifier in oauth::get_access_token
#   - Usage: oauth::get_access_token $consumer_key $consumer_token $oauth_token $oauth_token_secret $pin
#   - also use oauth_token/oauth_token_secret from get_request_token here
#   - returns dict including new oauth_token & oauth_token_secret (access token)
#
#  - afterwards use oauth_token/oauth_token_secret from get_access_token in
#    oauth::query_api to make api calls
#   - usage: oauth::query_api $url $consumer_key $consumer_secret $http_method $oauth_token $oauth_token_secret $key:value_http_query
#   - the $key:value_http_query is such that you would pass to http::formatQuery
#     e.g. status {this is a tweet}
#   - example call: puts [oauth::query_api http://api.twitter.com/1/statuses/update.json <key> <secret> POST $oauth_token_done $oauth_token_secret_done [list status "does it work"]]
#

package require http
# tcllib packages
package require base64
package require sha1
package require tls

package provide oauth 0.1

http::register https 443 ::tls::socket

namespace eval oauth {
	variable request_token_url https://api.twitter.com/oauth/request_token
	variable authorize_url https://api.twitter.com/oauth/authorize
	variable access_token_url https://api.twitter.com/oauth/access_token

	# timeout for http requests (ms)
	variable timeout 60000
}

# first step
proc oauth::get_request_token {consumer_key consumer_secret} {
	set params [list [list oauth_callback oob]]
	set data [oauth::query_call $oauth::request_token_url $consumer_key $consumer_secret GET $params]

	# dict has oauth_token, oauth_token_secret, ...
	set result [oauth::params_to_dict $data]
	dict append result auth_url ${oauth::authorize_url}?[http::formatQuery oauth_token [dict get $result oauth_token]]

	return $result
}

# second step
# for twitter, oauth_verifier is pin
# oauth_token & oauth_token_secret from get_request_token
proc oauth::get_access_token {consumer_key consumer_secret oauth_token oauth_token_secret oauth_verifier} {
	set params [list [list oauth_token $oauth_token] [list oauth_verifier $oauth_verifier]]
	set result [oauth::query_call $oauth::access_token_url $consumer_key $consumer_secret POST $params]

	# dict has oauth_token, oauth_token_secret (different than before), ...
	return [oauth::params_to_dict $result]
}

# after first two steps succeed, we now can make api requests to twitter
# query_dict is POST request to twitter as before, key:value pairing (dict)
# oauth_token, oauth_token_secret from get_access_token
proc oauth::query_api {url consumer_key consumer_secret method oauth_token oauth_token_secret query_dict} {
	set params [list [list oauth_token $oauth_token]]
	set result [oauth::query_call $url $consumer_key $consumer_secret $method $params $query_dict $oauth_token_secret]
	return $result
}

# build header & query, call http request and return result
# params stay in oauth header
# sign_params are only used in base string for signing (optional) - dict
proc oauth::query_call {url consumer_key consumer_secret method params {sign_params {}} {token_secret {}}} {
	set oauth_raw [dict create oauth_nonce [oauth::nonce]]
	dict append oauth_raw oauth_signature_method HMAC-SHA1
	dict append oauth_raw oauth_timestamp [clock seconds]
	dict append oauth_raw oauth_consumer_key $consumer_key
	dict append oauth_raw oauth_version 1.0

	# variable number of params
	foreach param $params {
		dict append oauth_raw {*}$param
	}

	# second oauth_raw holds data to be signed but not placed in header
	set oauth_raw_sign $oauth_raw
	foreach key [dict keys $sign_params] {
		dict append oauth_raw_sign $key [dict get $sign_params $key]
	}

	set signature [oauth::signature $url $consumer_secret $method $oauth_raw_sign $token_secret]
	dict append oauth_raw oauth_signature $signature

	set oauth_header [oauth::oauth_header $oauth_raw]
	set oauth_query [oauth::uri_escape $sign_params]

	return [oauth::query $url $method $oauth_header $oauth_query]
}

# do http request with oauth header
proc oauth::query {url method oauth_header {query {}}} {
	set header [list Authorization [concat "OAuth" $oauth_header]]
	if {$method != "GET"} {
		set token [http::geturl $url -headers $header -query $query -method $method -timeout $oauth::timeout]
	} else {
		set token [http::geturl $url -headers $header -method $method -timeout $oauth::timeout]
	}
	set data [http::data $token]
	set ncode [http::ncode $token]
	set status [http::status $token]
	http::cleanup $token
	if {$status == "reset"} {
		error "OAuth failure: HTTP timeout"
	}
	if {$ncode != 200} {
		error "OAuth failure: (code: $ncode) $data"
	}
	return $data
}

# take a dict of params and create as follows:
# create string as: key="value",...,key2="value2"
proc oauth::oauth_header {params} {
	set header []
	foreach key [dict keys $params] {
		set header "${header}[oauth::uri_escape $key]=\"[oauth::uri_escape [dict get $params $key]]\","
	}
	return [string trimright $header ","]
}

# take dict of params and create as follows
# sort params by key
# create string as key=value&key2=value2...
# TODO: if key matches, sort by value
proc oauth::params_signature {params} {
	set str []
	foreach key [lsort [dict keys $params]] {
		set str ${str}[oauth::uri_escape [list $key [dict get $params $key]]]&
	}
	return [string trimright $str &]
}

# build signature as in section 9 of oauth spec
# token_secret may be empty
proc oauth::signature {url consumer_secret method params {token_secret {}}} {
	# We want base URL for signing (remove ?params=...)
	set url [lindex [split $url "?"] 0]
	set base_string [oauth::uri_escape ${method}]&[oauth::uri_escape ${url}]&[oauth::uri_escape [oauth::params_signature $params]]
	set key [oauth::uri_escape $consumer_secret]&[oauth::uri_escape $token_secret]
	set signature [sha1::hmac -bin -key $key $base_string]
	return [base64::encode $signature]
}

proc oauth::nonce {} {
	set nonce [clock milliseconds][expr [tcl::mathfunc::rand] * 10000]
	return [sha1::sha1 $nonce]
}

# wrapper around http::formatQuery which uppercases octet characters
proc oauth::uri_escape {str} {
	set str [http::formatQuery {*}$str]
	# uppercase all %hex where hex=2 octets
	set str [regsub -all -- {%(\w{2})} $str {%[string toupper \1]}]
	return [subst $str]
}

# convert replies from http query into dict
# params of form key=value&key2=value2
proc oauth::params_to_dict {params} {
	set answer []
	foreach pair [split $params &] {
		dict set answer {*}[split $pair =]
	}
	return $answer
}
