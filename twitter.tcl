#
# Created by fedex and horgh. (www.summercat.com)
#
# 0.3 - ???
#  - fix direct msg
#  - replace decode_html with htmlparse::mapEscapes (though this isn't even
#    really needed i think!)
#  - add search users (!twit_searchusers)
#  - fix home timeline to use GET rather than POST. thanks to demonicpagan!
#  - change GETs that have http query to process params better
#
# 0.2 - May 18 2010
#  - add timeout to query to avoid hangs
#  - update decode_html for more accurate utf translation
#  - replace basic auth with oauth
#  - misc cleanup/small bugfixes
#  - add max_updates variable to control the number of status to display from
#    one query
#
# 0.1 - Feb 6 2010
#  - initial release
#
# Requirements: Tcl 8.5+, "recent" tcllib, oauth.tcl library
#
# Essentially a twitter client for IRC. Follow updates from tweets of all
# those you follow on the given account.
#
# Usage notes:
#  - Stores states in variable $idfile file in eggdrop root directory
#  - Default time between tweet fetches is 10 minutes. Alter the "bind time"
#    option below to change to a different setting. Right now there is only
#    options for 1 minute or 10 minutes.
#  - Accepts commands issued by anyone right now! Perhaps if you wish to use
#    in a channel with untrusted people, have one channel for output (set this
#    as variable below and one to control the script (chanset this channel
#    +twitter)
#
# Setup:
#  - You MUST set consumer key/secret in oauth.tcl. Header describes how to get
#    these values
#  - Set the channel variable as the channel where tweets will be output
#  - .chanset #channel +twitter to provide access to !commands in #channel
#  - Trying any command should prompt you to begin oauth authentication, or
#    just try !twit_request_token if not. You will be given instructions on
#    what to do after (calling !twit_access_token, etc).
#  - !twit_request_token/!twit_access_token should only need to be done once
#    unless you wish to change the account that is used
#
# Authentication notes:
#  - To begin authentication on an account use !twit_request_token
#  - To change which account the script follows use !twit_request_token make
#    sure you are logged into Twitter on the account you want and visit the
#    authentication URL (or login to the account you want at this URL)
#    and do !twit_access_token as before
#  - Changing account / enabling oauth resets tweet tracking state so you will
#    probably be flooded by up to 10 tweets
#
# Commands:
#  - !twit/!tweet - send a tweet
#  - !twit_msg - private msg
#  - !twit_trends
#  - !follow
#  - !unfollow
#  - !twit_updates
#  - !twit_msgs
#  - !twit_search
#  - !followers
#  - !following
#  - !retweet
#  - !twit_searchusers
# oauth commands
#  - !twit_request_token
#  - !twit_access_token <oauth_token> <oauth_token_secret> <PIN from authentication url of !twit_request_token>
#
# TODO:
#

package require http
# oauth.tcl library
package require oauth
# tcllib packages
package require json
package require htmlparse

namespace eval twitter {
	variable channel "#OUTPUT_CHANNEL"

	# Only have one of these uncommented
	# Check for tweets every 1 min
	#bind time - "* * * * *" twitter::update
	# Check for tweets every 10 min
	bind time - "?0 * * * *" twitter::update

	# maximum number of tweets to fetch for display at one time
	variable max_updates 10

	# You don't really need to set anything below here

	# holds states and ids of seen tweets
	variable idfile "twitter.last_id"

	# These may be set through running script
	variable oauth_token
	variable oauth_token_secret

	variable output_cmd "putserv"
	#variable output_cmd "cd::putnow"

	variable last_id
	variable last_update
	variable last_msg

	variable status_url "http://twitter.com/statuses/update.json"
	variable home_url "http://api.twitter.com/1/statuses/home_timeline.json"
	variable msg_url "http://twitter.com/direct_messages/new.json"
	variable msgs_url "http://twitter.com/direct_messages.json"
	variable trends_curr_url "http://search.twitter.com/trends/current.json"
	variable follow_url "http://twitter.com/friendships/create.json"
	variable unfollow_url "http://twitter.com/friendships/destroy.json"
	variable search_url "http://search.twitter.com/search.json"
	variable followers_url "http://twitter.com/statuses/followers.json"
	variable following_url "http://twitter.com/statuses/friends.json"
	variable retweet_url "http://api.twitter.com/1/statuses/retweet/"
	variable search_users_url http://api.twitter.com/1/users/search.json

	bind pub	-|- "!twit" twitter::tweet
	bind pub	-|- "!tweet" twitter::tweet
	bind pub	-|- "!twit_msg" twitter::msg
	bind pub	-|- "!twit_trends" twitter::trends
	bind pub	-|- "!follow" twitter::follow
	bind pub	-|- "!unfollow" twitter::unfollow
	bind pub	-|- "!twit_updates" twitter::updates
	bind pub	-|- "!twit_msgs" twitter::msgs
	bind pub	-|- "!twit_search" twitter::search
	bind pub	-|- "!twit_searchusers" twitter::search_users
	bind pub	-|- "!followers" twitter::followers
	bind pub	-|- "!following" twitter::following
	bind pub	-|- "!retweet" twitter::retweet

	# oauth binds
	bind pub	-|- "!twit_request_token" twitter::oauth_request
	bind pub	-|- "!twit_access_token" twitter::oauth_access

	bind evnt	-|- "save" twitter::write_states

	setudef flag twitter
}

# handle retrieval of oauth request token
proc twitter::oauth_request {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[catch {oauth::get_request_token} data]} {
		$twitter::output_cmd "PRIVMSG $chan :Error: $data"
		return
	}

	set url [dict get $data auth_url]
	$twitter::output_cmd "PRIVMSG $chan :To get your authentication verifier, visit ${url} and allow the application on your Twitter account."
	$twitter::output_cmd "PRIVMSG $chan :Then call !twit_access_token [dict get $data oauth_token] [dict get $data oauth_token_secret] <PIN from authorization URL of !twit_request_token>"
}

# handle retrieval of oauth access token
# if success, $twitter::oauth_token and $twitter::oauth_token_secret stored
proc twitter::oauth_access {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	set args [split $argv]
	if {[llength $args] != 3} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !twit_access_token <oauth_token> <oauth_token_secret> <PIN> (get these from !twit_request_token)"
		return
	}

	set oauth_token [lindex $args 0]
	set oauth_token_secret [lindex $args 1]
	set pin [lindex $args 2]

	if {[catch {oauth::get_access_token $oauth_token $oauth_token_secret $pin} data]} {
		$twitter::output_cmd "PRIVMSG $chan :Error: $data"
		return
	}

	# reset stored state
	set twitter::last_id 1
	set twitter::last_update 1
	set twitter::last_msg 1

	set twitter::oauth_token [dict get $data oauth_token]
	set twitter::oauth_token_secret [dict get $data oauth_token_secret]
	set screen_name [dict get $data screen_name]
	$twitter::output_cmd "PRIVMSG $chan :Successfully retrieved access token for \002${screen_name}\002."
}

# Output decoded/split string to given channel
proc twitter::output {chan str} {
	set str [htmlparse::mapEscapes $str]
#	foreach line [twitter::split_line 400 $str] {
#		$twitter::output_cmd "PRIVMSG $chan :$line"
#	}
	$twitter::output_cmd "PRIVMSG $chan :$str"
}

# Format status updates and output
proc twitter::output_update {chan name id str} {
	twitter::output $chan "\[\002$name\002\] $str ($id)"
}

# Retweet given id
proc twitter::retweet {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1 || ![regexp {^\d+$} $argv]} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !retweet <id>"
		return
	}

	# Setup url since id is not given as params for some reason...
	set url "${twitter::retweet_url}${argv}.json"

	if {[catch {twitter::query $url {} POST} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Retweet failure. ($argv) (You can't retweet your own updates!)"
		return
	}

	$twitter::output_cmd "PRIVMSG $chan :Retweet sent."
}

# Follow a user (by screen name)
proc twitter::follow {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !follow <screen name>"
		return
	}

	if {[catch {twitter::query $twitter::follow_url [list screen_name $argv]} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Twitter failed or already friends with $argv!"
		return
	}

	if {[dict exists $result error]} {
		twitter::output $chan "Follow failed ($argv): [dict get $result error]"
		return
	}

	twitter::output $chan "Now following [dict get $result screen_name]!"
}

# Unfollow a user (by screen name)
proc twitter::unfollow {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !unfollow <screen name>"
		return
	}

	if {[catch {twitter::query $twitter::unfollow_url [list screen_name $argv]} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Unfollow failed. ($argv)"
		return
	}

	if {[dict exists $result error]} {
		twitter::output $chan "Unfollow failed ($argv): [dict get $result error]"
		return
	}

	twitter::output $chan "Unfollowed [dict get $result screen_name]."
}

# Get last n, n [1, 20] updates
proc twitter::updates {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1 || ![string is integer $argv] || $argv > 20 || $argv < 1} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !twit_updates <#1 to 20>"
		return
	}

	if {[catch {twitter::query $twitter::home_url [list count $argv] GET} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Retrieval error: $result."
		return
	}

	if {[llength $result] == 0} {
		$twitter::output_cmd "PRIVMSG $chan :No updates."
		return
	}

	set result [lreverse $result]
	foreach status $result {
		dict with status {
			twitter::output_update $chan [dict get $user screen_name] $id $text
		}
	}
}

# Return top 5 results for query $argv
proc twitter::search {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1 || [string length $argv] > 140} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !twit_search <string 140 chars or less>"
		return
	}

	if {[catch {twitter::query $twitter::search_url [list q $argv]} data]} {
		$twitter::output_cmd "PRIVMSG $chan :Search error ($data)"
		return
	}

	if {[dict exists $data error]} {
		twitter::output $chan "Search failed ($argv): [dict get $result error]"
		return
	}

	set results [dict get $data results]
	set count 0
	foreach result $results {
		twitter::output $chan "#[incr count] \002[dict get $result from_user]\002 [dict get $result text]"
		if {$count > 4} {
			break
		}
	}
}

# Get first 5 results from users search
proc twitter::search_users {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !twit_searchusers <string>"
		return
	}

	if {[catch {twitter::query $twitter::search_users_url [list q $argv per_page 5] GET} data]} {
		$twitter::output_cmd "PRIVMSG $chan :Search error ($data)."
		return
	}

	foreach result $data {
		twitter::output $chan "#[incr count] \002[dict get $result screen_name]\002 Name: [dict get $result name] Location: [dict get $result location] Description: [dict get $result description]"
	}
}

# Return latest followers (up to 100)
proc twitter::followers {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[catch {twitter::query $twitter::followers_url} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Error fetching followers."
	}

	# Make first followers -> last followers
	set result [lreverse $result]

	set followers []
	foreach user $result {
		set followers "$followers[dict get $user screen_name] "
	}

	twitter::output $chan "Followers: $followers"
}

# Returns the latest users following acct is following (up to 100)
proc twitter::following {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[catch {twitter::query $twitter::following_url} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Error fetching friends."
		return
	}

	# Make first following -> last following
	set result [lreverse $result]

	set following []
	foreach user $result {
		set following "$following[dict get $user screen_name] "
	}

	twitter::output $chan "Following: $following"
}

# Get trends
proc twitter::trends {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[catch {twitter::query $twitter::trends_curr_url} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Trend fetch failed!"
		return
	}

	set trends [dict get $result trends]
	set output []
	set count 0
	foreach day [dict keys $trends] {
		foreach trend [dict get $trends $day] {
			set output "$output\002#[incr count]\002 [dict get $trend name] "
		}
	}

	twitter::output $chan $output
}

# Direct messages
# Get last n, n [1, 20] messages or new if no argument
proc twitter::msgs {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] == 1 && [string is integer $argv] && $argv < 20} {
		set params [list count $argv]
	} else {
		set params [list since_id $twitter::last_msg]
	}

	if {[catch {twitter::query $twitter::msgs_url $params GET} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Messages retrieval failed."
		return
	}

	if {[llength $result] == 0} {
		$twitter::output_cmd "PRIVMSG $chan :No new messages."
		return
	}

	foreach msg $result {
		dict with msg {
			if {$id > $twitter::last_msg} {
				set twitter::last_msg $id
			}
			twitter::output $chan "\002From\002 $sender_screen_name: $text ($created_at)"
		}
	}
}

# Send direct message to a user
proc twitter::msg {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }
	set argv [split $argv]

	if {[llength $argv] < 2 || [string length [join [lrange $argv 1 end]]] > 140} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !twit_msg <username> <msg 140 chars or less>"
		return
	}

	set name [lindex $argv 0]
	set msg [lrange $argv 1 end]
	set l [list screen_name $name text $msg]

	if {[catch {twitter::query $twitter::msg_url $l} data]} {
		$twitter::output_cmd "PRIVMSG $chan :Message to \002$name\002 failed ($data)! (Are they following you?)"
	} else {
		twitter::output $chan "Message sent."
	}
}

# Send status update (tweet)
proc twitter::tweet {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] > 140 || $argv == ""} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !tweet <up to 140 characters>"
		return
	}

	if {[catch {twitter::query $twitter::status_url [list status $argv]} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Tweet failed! ($argv) HTTP error: $result."
		return
	}

	set update_id [dict get $result id]
	if {$update_id == $twitter::last_update} {
		$twitter::output_cmd "PRIVMSG $chan :Tweet failed: Duplicate of tweet #$update_id. ($argv)"
		return
	}
	set twitter::last_update $update_id

	twitter::output $chan "Tweet sent."
}

# Grab unseen status updates
proc twitter::update {min hour day month year} {
	if {[catch {twitter::query $twitter::home_url [list since_id $twitter::last_id count $twitter::max_updates] GET} result]} {
		putlog "Twitter is busy. (error: $result)"
		return
	}

	set result [lreverse $result]

	foreach status $result {
		dict with status {
			twitter::output_update $twitter::channel [dict get $user screen_name] $id $text
			if {$id > $twitter::last_id} {
				set twitter::last_id $id
			}
		}
	}
}

# Twitter http query
proc twitter::query {url {query_list {}} {http_method {}}} {
	# Set http mode of query
	if {$http_method eq "" && $query_list ne ""} {
		set method POST
	} elseif {$http_method eq "" && $query_list eq ""} {
		set method GET
	} else {
		set method $http_method
	}

	if {$twitter::oauth_token == "" || $twitter::oauth_token_secret == ""} {
		error "OAuth not initialised. Try !twit_request_token"
	}

	# workaround as twitter expects ?param=value as part of URL for GET queries
	# that have params!
	if {$method eq "GET" && $query_list ne ""} {
		set url ${url}[twitter::url_params $query_list]
	}

	set data [oauth::query_api $url $method $twitter::oauth_token $twitter::oauth_token_secret $query_list]

	return [json::json2dict $data]
}

# return ?param1=value1&param2=value2... from key = param name dict
proc twitter::url_params {params_dict} {
	set str "?"
	foreach key [dict keys $params_dict] {
		set str ${str}${key}=[http::formatQuery [dict get $params_dict $key]]&
	}
	return [string trimright $str &]
}

# Get saved ids/state
proc twitter::get_states {} {
	if {[catch {open $twitter::idfile r} fid]} {
		set twitter::last_id 1
		set twitter::last_update 1
		set twitter::last_msg 1
		return
	}

	set data [read -nonewline $fid]
	set states [split $data \n]

	close $fid

	set twitter::last_id [lindex $states 0]
	set twitter::last_update [lindex $states 1]
	set twitter::last_msg [lindex $states 2]
	set twitter::oauth_token [lindex $states 3]
	set twitter::oauth_token_secret [lindex $states 4]
}

# Save states to file
proc twitter::write_states {args} {
	set fid [open $twitter::idfile w]
	puts $fid $twitter::last_id
	puts $fid $twitter::last_update
	puts $fid $twitter::last_msg
	puts $fid $twitter::oauth_token
	puts $fid $twitter::oauth_token_secret
	close $fid
}

# Split long line into list of strings for multi line output to irc
# Splits into strings of ~max
# by fedex
proc twitter::split_line {max str} {
	set last [expr {[string length $str] -1}]
	set start 0
	set end [expr {$max -1}]

	set lines []

	while {$start <= $last} {
		if {$last >= $end} {
			set end [string last { } $str $end]
		}

		lappend lines [string trim [string range $str $start $end]]
		set start $end
		set end [expr {$start + $max}]
	}

	return $lines
}

# Read states on load
twitter::get_states

putlog "twitter.tcl (c) fedex and horgh"
