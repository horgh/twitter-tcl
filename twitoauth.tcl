#
# OAuth (1.0/1.0a) library for Twitter
#
# By horgh.
#

package require base64
package require http
package require sha1
package require tls

package provide twitoauth 0.1

# Only enable TLSv1
::http::register https 443 [list ::tls::socket -ssl2 0 -ssl3 0 -tls1 1]

namespace eval ::twitoauth {
	variable request_token_url https://api.twitter.com/oauth/request_token
	variable authorize_url     https://api.twitter.com/oauth/authorize
	variable access_token_url  https://api.twitter.com/oauth/access_token

	# Timeout for http requests (ms)
	variable timeout 60000
}

# first step.
#
# the consumer key and consumer secret are those set for a specific oauth client
# and may be found from the list of clients on twitter's developer's website.
#
# we return a dict with the data to request a pin.
# relevant keys:
#   auth_url
#   oauth_token
#   oauth_token_secret
proc ::twitoauth::get_request_token {consumer_key consumer_secret} {
	set params [list [list oauth_callback oob]]
	set data [::twitoauth::query_call $::twitoauth::request_token_url $consumer_key $consumer_secret GET $params]

	# dict has oauth_token, oauth_token_secret, ...
	set result [::twitoauth::params_to_dict $data]
	dict append result auth_url ${::twitoauth::authorize_url}?[http::formatQuery oauth_token [dict get $result oauth_token]]

	return $result
}

# second step
# for twitter, oauth_verifier is the pin.
# oauth_token & oauth_token_secret are found from get_request_token
#
# we return a dict with the data used in making authenticated requests.
# relevant keys:
#   oauth_token
#   oauth_secret
# note these tokens are different than those sent in the original
# get_request_token response.
proc ::twitoauth::get_access_token {consumer_key consumer_secret oauth_token oauth_token_secret oauth_verifier} {
	set params [list [list oauth_token $oauth_token] [list oauth_verifier $oauth_verifier]]
	set result [::twitoauth::query_call $::twitoauth::access_token_url $consumer_key $consumer_secret POST $params]

	# dict has oauth_token, oauth_token_secret (different than before), ...
	return [::twitoauth::params_to_dict $result]
}

# after the first two steps succeed, we now can make API requests to twitter.
# query_dict is POST request to twitter as before, key:value pairing (dict)
# oauth_token, oauth_token_secret are from get_access_token
proc ::twitoauth::query_api {url consumer_key consumer_secret method oauth_token oauth_token_secret query_dict} {
	set params [list [list oauth_token $oauth_token]]
	set result [::twitoauth::query_call $url $consumer_key $consumer_secret $method $params $query_dict $oauth_token_secret]
	return $result
}

# build header & query, call http request and return result
# params stay in oauth header
# sign_params are only used in base string for signing (optional) - dict
proc ::twitoauth::query_call {url consumer_key consumer_secret method params {sign_params {}} {token_secret {}}} {
	set oauth_raw [dict create oauth_nonce [::twitoauth::nonce]]
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

	set signature [::twitoauth::signature $url $consumer_secret $method $oauth_raw_sign $token_secret]
	dict append oauth_raw oauth_signature $signature

	set oauth_header [::twitoauth::oauth_header $oauth_raw]
	set oauth_query [::twitoauth::uri_escape $sign_params]

	return [::twitoauth::query $url $method $oauth_header $oauth_query]
}

# do http request with oauth header
proc ::twitoauth::query {url method oauth_header {query {}}} {
	set header [list Authorization [concat "OAuth" $oauth_header]]

	if {$method != "GET"} {
		set token [http::geturl $url -headers $header -query $query -method $method -timeout $::twitoauth::timeout]
	} else {
		set token [http::geturl $url -headers $header -method $method -timeout $::twitoauth::timeout]
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
proc ::twitoauth::oauth_header {params} {
	set header []
	foreach key [dict keys $params] {
		set header "${header}[::twitoauth::uri_escape $key]=\"[::twitoauth::uri_escape [dict get $params $key]]\","
	}
	return [string trimright $header ","]
}

# take dict of params and create as follows
# sort params by key
# create string as key=value&key2=value2...
# TODO: if key matches, sort by value
proc ::twitoauth::params_signature {params} {
	set str []
	foreach key [lsort [dict keys $params]] {
		set str ${str}[::twitoauth::uri_escape [list $key [dict get $params $key]]]&
	}
	return [string trimright $str &]
}

# build signature as in section 9 of oauth spec
# token_secret may be empty
proc ::twitoauth::signature {url consumer_secret method params {token_secret {}}} {
	# We want base URL for signing (remove ?params=...)
	set url [lindex [split $url "?"] 0]
	set base_string [::twitoauth::uri_escape ${method}]&[::twitoauth::uri_escape ${url}]&[::twitoauth::uri_escape [::twitoauth::params_signature $params]]
	set key [::twitoauth::uri_escape $consumer_secret]&[::twitoauth::uri_escape $token_secret]
	set signature [sha1::hmac -bin -key $key $base_string]
	return [base64::encode $signature]
}

proc ::twitoauth::nonce {} {
	set nonce [clock milliseconds][expr [tcl::mathfunc::rand] * 10000]
	return [sha1::sha1 $nonce]
}

# URI escape the parameter. The parameter may be a list or a string. If
# it's a list, we'll construct a string similar to ::http::formatQuery.
#
# A difference from ::http::formatQuery is that we uppercase percent
# encoded octets. This is required in some parts of the OAuth
# specification when signing.
proc ::twitoauth::uri_escape {str} {
	# Tcl 8.6.9 changed ::http::formatQuery to require an even number of
	# parameters. Account for that.
	if {[llength $str] % 2 != 0} {
		# For simplicity we only handle the single parameter case.
		if {[llength $str] != 1} {
			error "invalid number of parameters to uri_escape"
		}

		# Tcl 8.6.9 introduced ::http::quoteString as a replacement.
		#
		# Annoyingly we can't check for it with 'info procs'. I think it's
		# because of how it's declared (with 'interp alias').
		if {[catch {set str [::http::formatQuery $str]}]} {
			set str [::http::quoteString $str]
		}
	} else {
		set str [::http::formatQuery {*}$str]
	}

	# uppercase all %hex where hex=2 octets
	set str [regsub -all -- {%(\w{2})} $str {%[string toupper \1]}]
	return [subst $str]
}

# convert replies from http query into dict
# params of form key=value&key2=value2
proc ::twitoauth::params_to_dict {params} {
	set answer []
	foreach pair [split $params &] {
		dict set answer {*}[split $pair =]
	}
	return $answer
}
