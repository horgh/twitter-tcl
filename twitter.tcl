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
#  - add !update_interval to change delay between tweet/timeline fetches
#  - change specification of update interval in config slightly so that bind
#    times are not needed to be manually edited
#  - change flags for binds to requiring +o by default
#  - remove output_channel variable in favour of output status updates to
#    every channel that is set +twitter
#  - add config option to not show tweetid
#  - change output format
#  - change default state_file filename & variable
#  - require consumer key/secret specified in !twit_request_token rather than
#    hardcode into oauth.tcl
#  - fix failed tweet msg to make more sense (not assume http error)
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
#  - Stores states in variable $state_file file in eggdrop root directory
#  - Default time between tweet fetches is 10 minutes. Alter the "bind time"
#    option below to change to a different setting.
#  - Requires +o on the bot to issue !commands. You can set multiple channels
#    that the bot outputs and accepts commands on by setting each channel
#    .chanset #channel +twitter
#
# Setup:
#  - Register for consumer key/secret at http://twitter.com/oauth_clients which
#    will be needed to authenticate with oauth (and !twit_request_token)
#  - .chanset #channel +twitter to provide access to !commands in #channel.
#    These channels also receive status update output.
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
# Commands (probably not complete!):
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
#  - !update_interval
#
# oauth commands
#  - !twit_request_token <consumer_key> <consumer_secret>
#  - !twit_access_token <oauth_token> <oauth_token_secret> <PIN from authentication url of !twit_request_token>

package require http
# oauth.tcl library
package require oauth
# tcllib packages
package require json
package require htmlparse

namespace eval twitter {
	# Check for tweets every 1, 5, or 10 min
	# Must be 1, 5, or 10!
	set update_time 10

	# maximum number of tweets to fetch for display at one time
	variable max_updates 10

	# show tweet number (1 = on, 0 = off)
	# This is only really relevant if you are going to !retweet
	set show_tweetid 0

	# You don't really need to set anything below here

	# holds state (id of last seen tweet, oauth keys)
	variable state_file "scripts/twitter.state"

	variable output_cmd putserv

	# These may be set through running the script
	variable oauth_token
	variable oauth_token_secret
	variable oauth_consumer_key
	variable oauth_consumer_secret

	variable last_id
	variable last_update
	variable last_msg

	variable status_url "https://api.twitter.com/1/statuses/update.json"
	variable home_url "https://api.twitter.com/1/statuses/home_timeline.json"
	variable msg_url "http://api.twitter.com/1/direct_messages/new.json"
	variable msgs_url "http://api.twitter.com/1/direct_messages.json"
	variable trends_curr_url "http://search.twitter.com/trends/current.json"
	variable follow_url "http://api.twitter.com/1/friendships/create.json"
	variable unfollow_url "http://api.twitter.com/1/friendships/destroy.json"
	variable search_url "http://search.twitter.com/search.json"
	variable followers_url "http://api.twitter.com/1/statuses/followers.json"
	variable following_url "http://api.twitter.com/1/statuses/friends.json"
	variable retweet_url "https://api.twitter.com/1/statuses/retweet/"
	variable search_users_url "https://api.twitter.com/1/users/search.json"

	bind pub	o|o "!twit" twitter::tweet
	bind pub	o|o "!tweet" twitter::tweet
	bind pub	o|o "!twit_msg" twitter::msg
	bind pub	o|o "!twit_trends" twitter::trends
	bind pub	o|o "!follow" twitter::follow
	bind pub	o|o "!unfollow" twitter::unfollow
	bind pub	o|o "!twit_updates" twitter::updates
	bind pub	o|o "!twit_msgs" twitter::msgs
	bind pub	o|o "!twit_search" twitter::search
	bind pub	o|o "!twit_searchusers" twitter::search_users
	bind pub	o|o "!followers" twitter::followers
	bind pub	o|o "!following" twitter::following
	bind pub	o|o "!retweet" twitter::retweet
	bind pub	o|o "!update_interval" twitter::update_interval

	# oauth binds
	bind pub	o|o "!twit_request_token" twitter::oauth_request
	bind pub	o|o "!twit_access_token" twitter::oauth_access

	bind evnt	-|- "save" twitter::write_states

	setudef flag twitter
}

# handle retrieval of oauth request token
proc twitter::oauth_request {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }
	set argv [split $argv]
	if {[llength $argv] != 2} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !twit_request_token <consumer key> <consumer secret>"
		return
	}
	lassign $argv twitter::oauth_consumer_key twitter::oauth_consumer_secret

	if {[catch {oauth::get_request_token $twitter::oauth_consumer_key $twitter::oauth_consumer_secret} data]} {
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
	lassign $args oauth_token oauth_token_secret pin

	if {[catch {oauth::get_access_token $twitter::oauth_consumer_key $twitter::oauth_consumer_secret $oauth_token $oauth_token_secret $pin} data]} {
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

proc twitter::set_update_time {delay} {
	if {$delay != 1 && $delay != 10 && $delay != 5} {
		set delay 10
	}

	twitter::flush_update_binds

	if {$delay == 1} {
		bind time - "* * * * *" twitter::update
	} elseif {$delay == 5} {
		bind time - "?0 * * * *" twitter::update
		bind time - "?5 * * * *" twitter::update
	} else {
		bind time - "?0 * * * *" twitter::update
	}
}

proc twitter::flush_update_binds {} {
	foreach binding [binds time] {
		if {[lindex $binding 4] == "twitter::update"} {
			unbind [lindex $binding 0] [lindex $binding 1] [lindex $binding 2] [lindex $binding 4]
		}
	}
}

# change time between automatic update fetches
proc twitter::update_interval {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {$argv != 1 && $argv != 10 && $argv != 5} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !update_interval <1, 5, or 10>"
		return
	}

	twitter::set_update_time $argv

	$twitter::output_cmd "PRIVMSG $chan :Update interval set to $argv minute(s)."
}

# Output decoded/split string to given channel
proc twitter::output {chan str} {
	set str [htmlparse::mapEscapes $str]
	$twitter::output_cmd "PRIVMSG $chan :$str"
}

# Format status updates and output
proc twitter::output_update {chan name id str} {
	set out "\002$name\002: $str"
	if {$twitter::show_tweetid} {
		append out " ($id)"
	}
	twitter::output $chan $out
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
		$twitter::output_cmd "PRIVMSG $chan :Tweet failed! ($argv) Error: $result."
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
			foreach ch [channels] {
				if {[channel get $ch twitter]} {
					twitter::output_update $ch [dict get $user screen_name] $id $text
				}
			}
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

	set data [oauth::query_api $url $twitter::oauth_consumer_key $twitter::oauth_consumer_secret $method $twitter::oauth_token $twitter::oauth_token_secret $query_list]

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
	if {[catch {open $twitter::state_file r} fid]} {
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
	set twitter::oauth_consumer_key [lindex $states 5]
	set twitter::oauth_consumer_secret [lindex $states 6]
}

# Save states to file
proc twitter::write_states {args} {
	set fid [open $twitter::state_file w]
	puts $fid $twitter::last_id
	puts $fid $twitter::last_update
	puts $fid $twitter::last_msg
	puts $fid $twitter::oauth_token
	puts $fid $twitter::oauth_token_secret
	puts $fid $twitter::oauth_consumer_key
	puts $fid $twitter::oauth_consumer_secret
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

twitter::set_update_time $twitter::update_time

putlog "twitter.tcl (c) fedex and horgh"
