#
# Twitter API call library
#
# This is intended to abstract out Twitter API request logic
# from twitter.tcl so that it may be used in more than the eggdrop
# script.
#

package require json
package require oauth

package provide twitlib 0.1

namespace eval ::twitlib {
	# maximum number of timeline tweets to fetch at one time.
	variable max_updates 10

	# the last tweet id we have seen - home timeline.
	variable last_id 1
	# last tweet id we have seen - mentions timeline.
	variable last_mentions_id 1

	# oauth authentication information.
	variable oauth_consumer_key {}
	variable oauth_consumer_secret {}
	variable oauth_token {}
	variable oauth_token_secret {}

	# Twitter API URLs
	variable status_url       https://api.twitter.com/1.1/statuses/update.json
	variable home_url         https://api.twitter.com/1.1/statuses/home_timeline.json
	variable mentions_url     https://api.twitter.com/1.1/statuses/mentions_timeline.json
	variable msg_url          https://api.twitter.com/1.1/direct_messages/new.json
	variable msgs_url         https://api.twitter.com/1.1/direct_messages.json
	variable trends_place_url https://api.twitter.com/1.1/trends/place.json
	variable follow_url       https://api.twitter.com/1.1/friendships/create.json
	variable unfollow_url     https://api.twitter.com/1.1/friendships/destroy.json
	variable search_url       https://search.twitter.com/search.json
	variable followers_url    https://api.twitter.com/1.1/followers/list.json
	variable following_url    https://api.twitter.com/1.1/friends/list.json
	variable retweet_url      https://api.twitter.com/1.1/statuses/retweet/
	variable search_users_url https://api.twitter.com/1.1/users/search.json
}

# perform a Twitter API request.
#
# we require the URL to send the request to,
# the query parameters, and the HTTP method.
#
# we convert the json response to a dict and return it.
#
# it is an error to call this without having first set the oauth
# tokens/consumer key/secret.
proc ::twitlib::query {url {query_list {}} {http_method {}}} {
	# set http mode of query
	if {$http_method eq "" && $query_list ne ""} {
		set method POST
	} elseif {$http_method eq "" && $query_list eq ""} {
		set method GET
	} else {
		set method $http_method
	}

	if {$::twitlib::oauth_token == "" || $::twitlib::oauth_token_secret == "" \
		|| $::twitlib::oauth_consumer_key == {} \
		|| $::twitlib::oauth_consumer_secret == {}} {
		error "OAuth not initialised."
	}

	# append query string to URL for GET queries.
	if {$method eq "GET" && $query_list ne ""} {
		append url ?[::http::formatQuery {*}$query_list]
		# NOTE: we must leave $query_list as is - we need it separate later on
		#   for the purposes of oauth signing.
	}

	set data [::oauth::query_api $url $::twitlib::oauth_consumer_key \
		$::twitlib::oauth_consumer_secret $method $::twitlib::oauth_token \
		$::twitlib::oauth_token_secret $query_list]

	return [::json::json2dict $data]
}

# retrieve the latest unseen updates.
#
# we return a list of dicts. each dict represents a single
# unseen tweet, and has the keys:
#   screen_name
#   id
#   text
#
# the tweets are ordered from oldest to newest.
#
# NOTE: we may raise an error if the request fails.
proc ::twitlib::get_unseen_updates {} {
	set params [list count $::twitlib::max_updates \
		since_id $::twitlib::last_id]

	# NOTE: this may raise an error.
	set result [::twitlib::query $::twitlib::home_url $params GET]

	# re-order - oldest to newest.
	set result [lreverse $result]

	set updates [list]
	foreach status $result {
		set screen_name [dict get $status user screen_name]
		set id          [dict get $status id]
		set text        [dict get $status text]

		set d [dict create]
		dict set d screen_name $screen_name
		dict set d id $id
		dict set d text $text

		lappend updates $d

		if {$id > $::twitlib::last_id} {
			set ::twitlib::last_id $id
		}
	}
	return $updates
}

# retrieve unseen mention timeline statuses
#
# we return a list of dicts. each dict represents a single
# unseen tweet, and has the keys:
#   screen_name
#   id
#   text
#
# the tweets are ordered from oldest to newest.
#
# NOTE: we may raise an error if the request fails.
proc ::twitlib::get_unseen_mentions {} {
	set params [list count $::twitlib::max_updates \
		since_id $::twitlib::last_mentions_id]

	set result [::twitlib::query $::twitlib::mentions_url $params GET]

	# re-order - oldest to newest.
	set result [lreverse $result]

	set updates [list]
	foreach status $result {
		set screen_name [dict get $status user screen_name]
		set id          [dict get $status id]
		set text        [dict get $status text]

		set d [dict create]
		dict set d screen_name $screen_name
		dict set d id $id
		dict set d text $text

		lappend updates $d

		if {$id > $::twitlib::last_mentions_id} {
			set ::twitlib::last_mentions_id $id
		}
	}
	return $updates
}
