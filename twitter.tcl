#
# A twitter client/gateway for IRC.
#
# By fedex and horgh.
#

package require http
package require htmlparse
package require oauth
package require twitlib

namespace eval twitter {
	# Check for tweets every 1, 5, or 10 min
	# Must be 1, 5, or 10!
	set update_time 10

	# maximum number of tweets to fetch for display at one time
	variable max_updates 10

	# show tweet number (1 = on, 0 = off)
	# This is only really relevant if you are going to !retweet
	set show_tweetid 0

	# you shouldn't need to change anything below this point.

	# holds state (id of last seen tweet, oauth keys)
	variable state_file "scripts/twitter.state"

	variable output_cmd putserv

	variable last_update
	variable last_msg

	# twitter binds.
	bind pub	o|o "!twit" twitter::tweet
	bind pub	o|o "!tweet" twitter::tweet
	bind pub	o|o "!twit_msg" twitter::msg
	bind pub	o|o "!twit_trends" twitter::trends_global
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

	# save our state on save event.
	bind evnt	-|- "save" twitter::write_states

	# add channel flag +/-twitter
	setudef flag twitter
}

# Handle retrieval of OAuth request token
proc twitter::oauth_request {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }
	set argv [split $argv]
	if {[llength $argv] != 2} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !twit_request_token <consumer key> <consumer secret>"
		return
	}
	lassign $argv ::twitlib::oauth_consumer_key ::twitlib::oauth_consumer_secret

	if {[catch {::oauth::get_request_token $::twitlib::oauth_consumer_key $::twitlib::oauth_consumer_secret} data]} {
		$twitter::output_cmd "PRIVMSG $chan :Error: $data"
		return
	}

	set url [dict get $data auth_url]
	$twitter::output_cmd "PRIVMSG $chan :To get your authentication verifier, visit ${url} and allow the application on your Twitter account."
	$twitter::output_cmd "PRIVMSG $chan :Then call !twit_access_token [dict get $data oauth_token] [dict get $data oauth_token_secret] <PIN from authorization URL of !twit_request_token>"
}

# Handle retrieval of OAuth access token
# if success, we store $::twitlib::oauth_token and $::twitlib::oauth_token_secret
proc twitter::oauth_access {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	set args [split $argv]
	if {[llength $args] != 3} {
		$twitter::output_cmd "PRIVMSG $chan :Usage: !twit_access_token <oauth_token> <oauth_token_secret> <PIN> (get these from !twit_request_token)"
		return
	}
	lassign $args oauth_token oauth_token_secret pin

	if {[catch {::oauth::get_access_token $::twitlib::oauth_consumer_key $::twitlib::oauth_consumer_secret $oauth_token $oauth_token_secret $pin} data]} {
		$twitter::output_cmd "PRIVMSG $chan :Error: $data"
		return
	}

	# reset stored state
	set ::twitlib::last_id 1
	set twitter::last_update 1
	set twitter::last_msg 1

	set ::twitlib::oauth_token [dict get $data oauth_token]
	set ::twitlib::oauth_token_secret [dict get $data oauth_token_secret]
	set screen_name [dict get $data screen_name]
	$twitter::output_cmd "PRIVMSG $chan :Successfully retrieved access token for \002${screen_name}\002."
}

# Set update time
proc twitter::set_update_time {delay} {
	if {$delay != 1 && $delay != 10 && $delay != 5} {
		set delay 10
	}

	twitter::flush_update_binds

	if {$delay == 1} {
		bind time - "* * * * *" twitter::update
	} else {
		bind time - "*/$delay * * * *" twitter::update
	}
}

# Flush update binds
proc twitter::flush_update_binds {} {
	foreach binding [binds time] {
		if {[lindex $binding 4] == "twitter::update"} {
			unbind [lindex $binding 0] [lindex $binding 1] [lindex $binding 2] [lindex $binding 4]
		}
	}
}

# Change time between automatic update fetches
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
	set str [regsub -all -- {\n} $str " "]
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
	set url "${::twitlib::retweet_url}${argv}.json"

	if {[catch {::twitlib::query $url {} POST} result]} {
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

	if {[catch {::twitlib::query $::twitlib::follow_url [list screen_name $argv]} result]} {
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

	if {[catch {::twitlib::query $::twitlib::unfollow_url [list screen_name $argv]} result]} {
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

	if {[catch {::twitlib::query $::twitlib::home_url [list count $argv] GET} result]} {
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

	if {[catch {::twitlib::query $::twitlib::search_url [list q $argv]} data]} {
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

	if {[catch {::twitlib::query $::twit::search_users_url [list q $argv per_page 5] GET} data]} {
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

	if {[catch {::twitlib::query $::twitlib::followers_url} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Error fetching followers."
	}

	# Make first followers -> last followers
	set result [lreverse $result]

	set followers []
	foreach user $result {
		append followers "[dict get $user screen_name] "
	}

	twitter::output $chan "Followers: $followers"
}

# Returns the latest users following acct is following (up to 100)
proc twitter::following {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[catch {::twitlib::query $::twitlib::following_url} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Error fetching friends."
		return
	}

	# Make first following -> last following
	set result [lreverse $result]

	set following []
	foreach user $result {
		append following "[dict get $user screen_name] "
	}

	twitter::output $chan "Following: $following"
}

# Get global trends
# GET /1.1/trends/place.json?id=1 provides us with the 'global'
# trends.
# we can provide different ids to see trends in other locations.
proc twitter::trends_global {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[catch {::twitlib::query $::twitlib::trends_place_url [list id 1] GET} result]} {
		$twitter::output_cmd "PRIVMSG $chan :Trend fetch failed!"
		return
	}

	# we receive a 'list' with one element - the object with our result.
	# the object has keys 'trends' (list of trends), 'as_of', 'created_at',
	# and 'locations'.
	set result [lindex $result 0]
	# pull out the trends object. this is a list of objects (dicts). the most
	# relevant piece of data we care about is the on the key 'name' - the
	# trend name.
	set trends [dict get $result trends]

	set output []
	set count 0
	foreach trend $trends {
		set output "$output\002#[incr count]\002 [dict get $trend name] "
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

	if {[catch {::twitlib::query $::twitlib::msgs_url $params GET} result]} {
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
# TODO: replace lrange by a substring starting at the first space to fix 'unmatched open brace in list'
#       issue if the tweet contains one { not balanced by a }.
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

	if {[catch {::twitlib::query $::twitlib::msg_url $l} data]} {
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

	if {[catch {::twitlib::query $::twitlib::status_url [list status $argv]} result]} {
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

# grab unseen status updates and output them to +twitter channels.
proc twitter::update {min hour day month year} {
	if {[catch {::twitlib::get_unseen_updates $::twitter::max_updates} result]} {
		putlog "Update retrieval failed: $result"
		return
	}

	foreach status $updates {
		foreach ch [channels] {
			if {[channel get $ch twitter]} {
				twitter::output_update $ch [dict get $status screen_name] \
					[dict get $status $id] [dict get $status $text]
			}
		}
	}
}

# Get saved ids/state
proc twitter::get_states {} {
	if {[catch {open $twitter::state_file r} fid]} {
		set ::twitlib::last_id 1
		set twitter::last_update 1
		set twitter::last_msg 1
		return
	}

	set data [read -nonewline $fid]
	set states [split $data \n]
	close $fid

	set ::twitlib::last_id [lindex $states 0]
	set twitter::last_update [lindex $states 1]
	set twitter::last_msg [lindex $states 2]
	set ::twitlib::oauth_token [lindex $states 3]
	set ::twitlib::oauth_token_secret [lindex $states 4]
	set ::twitlib::oauth_consumer_key [lindex $states 5]
	set ::twitlib::oauth_consumer_secret [lindex $states 6]
}

# Save states to file
proc twitter::write_states {args} {
	set fid [open $twitter::state_file w]
	puts $fid $::twitlib::last_id
	puts $fid $twitter::last_update
	puts $fid $twitter::last_msg
	puts $fid $::twitlib::oauth_token
	puts $fid $::twitlib::oauth_token_secret
	puts $fid $::twitlib::oauth_consumer_key
	puts $fid $::twitlib::oauth_consumer_secret
	close $fid
}

# Split long line into list of strings for multi line output to irc
# Split into strings of ~max
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
