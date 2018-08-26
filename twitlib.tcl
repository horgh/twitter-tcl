#
# Twitter API call library
#
# This is intended to abstract out Twitter API request logic from twitter.tcl
# so that it may be used in more than the eggdrop script.
#

package require json
package require twitoauth

package provide twitlib 0.1

namespace eval ::twitlib {
	# Maximum number of timeline tweets to fetch at one time.
	# For home_url the current maximum is 200.
	variable max_updates 10

	# The last tweet id we have seen - home timeline.
	variable last_id 1

	# Last tweet id we have seen - mentions timeline.
	variable last_mentions_id 1

	# OAuth authentication information.
	variable oauth_consumer_key {}
	variable oauth_consumer_secret {}
	variable oauth_token {}
	variable oauth_token_secret {}

	# Twitter API URLs
	# GET account/settings to get info about your account.
	variable account_settings_url https://api.twitter.com/1.1/account/settings.json
	# POST status_url to create a tweet.
	variable status_url       https://api.twitter.com/1.1/statuses/update.json
	# GET home_url to retrieve tweets by users you follow/yourself.
	variable home_url         https://api.twitter.com/1.1/statuses/home_timeline.json
	variable mentions_url     https://api.twitter.com/1.1/statuses/mentions_timeline.json
	variable msg_url          https://api.twitter.com/1.1/direct_messages/new.json
	variable msgs_url         https://api.twitter.com/1.1/direct_messages.json
	variable trends_place_url https://api.twitter.com/1.1/trends/place.json
	variable follow_url       https://api.twitter.com/1.1/friendships/create.json
	variable unfollow_url     https://api.twitter.com/1.1/friendships/destroy.json
	variable search_url       https://api.twitter.com/1.1/search/tweets.json
	variable followers_url    https://api.twitter.com/1.1/followers/list.json
	variable following_url    https://api.twitter.com/1.1/friends/list.json
	variable retweet_url      https://api.twitter.com/1.1/statuses/retweet/
	variable search_users_url https://api.twitter.com/1.1/users/search.json
	variable statuses_show_url https://api.twitter.com/1.1/statuses/show.json
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

	set data [::twitoauth::query_api $url $::twitlib::oauth_consumer_key \
		$::twitlib::oauth_consumer_secret $method $::twitlib::oauth_token \
		$::twitlib::oauth_token_secret $query_list]

	# apparently we'll get back unicode
	return [::json::json2dict $data]
}

proc ::twitlib::get_account_settings {} {
	set result [::twitlib::query $::twitlib::account_settings_url {} GET]
	return $result
}

proc ::twitlib::get_my_screen_name {} {
	set settings [::twitlib::get_account_settings]
	if {![dict exists $settings screen_name]} {
		return ""
	}
	return [dict get $settings screen_name]
}

# take status dict from a timeline and reformats it if necessary.
#
# in particular we replace retweeted tweets with the original tweet
# but with 'RT @screenname:" prepended. this is to resolve issues
# where retweeted tweets get truncated.
#
# note this assumes that with retweeting the tweet itself has no
# new data (which seems to hold based on the API call to generate
# a retweet).
#
# as well we replace newlines with a single space.
#
# we also strip out non unicode characters as it seems we can
# get invalid ones.
proc ::twitlib::fix_status {status} {
	set changed 0
	set tweet [dict get $status full_text]

	# if it has a retweet then as they can be truncated and lose
	# data, especially urls, replace the tweet with the
	# original tweet but add 'RT @name' to it.
	if {[dict exists $status retweeted_status]} {
		set rt_user [dict get $status retweeted_status user screen_name]
		set rt_tweet [dict get $status retweeted_status full_text]
		set tweet "RT @$rt_user: $rt_tweet"
		set changed 1
	}

	# we can also apparently have newlines in tweets. replace them
	# with a space.
	# also drop zero width spaces that we would not want to display
	# anyway. (\u200b)
	# TODO: we could replace 2+ whitespace in a row with a single space.
	set tweet_no_newlines [string map {\n " " \r "" \u200b ""} $tweet]
	if {$tweet_no_newlines != $tweet} {
		set changed 1
		set tweet $tweet_no_newlines
	}

	# tweet json unicode characters come through as, for example, \u201c.
	# however we can still receive invalid unicode after converting from
	# json. for example:
	# ERROR:  invalid byte sequence for encoding "UTF8": 0xeda0bd
	# which in the tweet with this problem showed as a "clapping hands"
	# image. in the tweet: \ud83d\udc4f
	# which is "undefined u+eda0bd"?
	# on unicode.org looking up this hex code results in:
	# "Error: U+EDA0BD is outside the legal range of codepoints.
	# The legal range of codepoints is U+0000 through U+10FFFF."
	#                                                 U+EDA0BD
	# so to get around this I've tried stripping with regex and string maps:
	#set tweet [regsub -all -- {[\U00110000-\Uffffffff]} $tweet ""]
	# (this one because it seems tcl would replace invalid unicode with
	# \ufffd in some cases?)
	#set tweet [string map {\ufffd ""} $tweet]
	# neither worked. instead, checking with 'string is' seems to do
	# the tric.
	set tweet_filtered_chars ""
	for {set i 0} {$i < [string length $tweet]} {incr i} {
		set char [string index $tweet $i]
		# any unicode printing char including space.
		if {![string is print -strict $char]} {
			continue
		}
		append tweet_filtered_chars $char
	}
	if {$tweet_filtered_chars != $tweet} {
		set changed 1
		set tweet $tweet_filtered_chars
	}

	if {$changed} {
		dict set status full_text $tweet
	}
	return $status
}

# take a list of status dicts from a timeline and reformat them if necessary.
proc ::twitlib::fix_statuses {statuses} {
	set fixed_statuses [list]
	foreach status $statuses {
		set fixed_status [::twitlib::fix_status $status]
		lappend fixed_statuses $fixed_status
	}
	return $fixed_statuses
}

# retrieve the latest unseen updates.
#
# we return a list of dicts. each dict represents a single
# unseen tweet, and has the keys:
#   screen_name
#   id
#   full_text
#   created_at (time tweet created)
#
# the tweets are ordered from oldest to newest.
#
# NOTE: we may raise an error if the request fails.
#
# NOTE: it is still possible to miss old tweets using since_id.
#   this is for two reasons:
#   - twitter has a limit on the maximum age of a tweet it will
#     return. if you try to ask for since_id '1' then this will
#     be translated into the oldest tweet available. I'm not
#     sure how far back tweets are available
#   - since_id and count alone will return the most recent
#     count tweets tweets newer than since_id, so there can be
#     a gap between since_id and the tweets you get back.
#     to resolve this we must use the 'max_id' parameter to
#     page back. together with since_id and max_id we can
#     make another request using the oldest tweet_id in the
#     first request to get another 'page' of results.
#     note I do not implement this here.
proc ::twitlib::get_unseen_updates {} {
	set params [list \
		count $::twitlib::max_updates \
		since_id $::twitlib::last_id \
		tweet_mode extended \
	]

	# NOTE: this may raise an error.
	set result [::twitlib::query $::twitlib::home_url $params GET]

	# re-order - oldest to newest.
	set result [lreverse $result]

	# fix issues with truncation.
	set statuses [::twitlib::fix_statuses $result]

	set updates [list]
	foreach status $statuses {
		set user_id     [dict get $status user id_str]
		set screen_name [dict get $status user screen_name]
		set id          [dict get $status id_str]
		set created_at  [dict get $status created_at]
		set full_text   [dict get $status full_text]

		set d [dict create]
		dict set d user_id     $user_id
		dict set d screen_name $screen_name
		dict set d id $id
		dict set d full_text $full_text
		dict set d created_at $created_at

		lappend updates $d

		# Track the max id we've seen. We use this for since_id.
		#
		# You may wonder whether comparing the IDs like this is correct given they
		# are not sequential. However it looks in the past we switched to this for
		# some reason (from taking the last tweet ID as ordered by Twitter). Also,
		# the home_timeline docs say "return results with an ID greater than [..]",
		# so it sounds like it should be fine.
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
#   full_text
#
# the tweets are ordered from oldest to newest.
#
# NOTE: we may raise an error if the request fails.
proc ::twitlib::get_unseen_mentions {} {
	set params [list \
		count $::twitlib::max_updates \
		since_id $::twitlib::last_mentions_id \
		tweet_mode extended \
	]

	set result [::twitlib::query $::twitlib::mentions_url $params GET]

	# re-order - oldest to newest.
	set result [lreverse $result]

	# fix issues with truncation.
	set statuses [::twitlib::fix_statuses $result]

	set updates [list]
	foreach status $statuses {
		set user_id     [dict get $status user id_str]
		set screen_name [dict get $status user screen_name]
		set id          [dict get $status id_str]
		set full_text   [dict get $status full_text]

		set d [dict create]
		dict set d user_id     $user_id
		dict set d screen_name $screen_name
		dict set d id $id
		dict set d full_text $full_text

		lappend updates $d

		# See comment on similar logic in get_unseen_updates.
		if {$id > $::twitlib::last_mentions_id} {
			set ::twitlib::last_mentions_id $id
		}
	}
	return $updates
}

proc ::twitlib::get_status_by_id {id} {
	set params [list \
		id $id \
		tweet_mode extended \
	]

	set result [::twitlib::query $::twitlib::statuses_show_url $params GET]

	set fixed_status [::twitlib::fix_status $result]

	return $fixed_status
}
