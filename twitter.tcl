#
# A Twitter client/gateway for IRC.
#
# By fedex and horgh.
#

package require http
package require htmlparse
package require twitoauth
package require twitlib

namespace eval ::twitter {
	# Check for tweets every 1, 5, or 10 min
	# Must be 1, 5, or 10!
	# Using 1 minute may put you up against Twitter's API limits if you have both
	# home and mentions polling enabled.
	variable update_time 10

	# Show tweet number (1 = on, 0 = off)
	# This is only really relevant if you are going to !retweet
	variable show_tweetid 0

	# Control what we poll. Each of these poll types is a separate API request
	# every 'update_time' interval, so if you don't need/want one, then it is
	# more efficient to disable.
	# By default we poll only the home timeline. This means you will see tweets of
	# users you follow.

	# Whether to poll home timeline.
	variable poll_home_timeline 1
	# Whether to poll mentions timeline.
	variable poll_mentions_timeline 0

	# Maximum characters per output line.
	variable line_length 400

	#
	# You shouldn't need to change anything below this point!
	#

	# Number of followers to output when listing followers.
	# This request can return a maximum of 5000 at a time.
	variable followers_limit 50

	# This file holds state information (id of last seen tweet, oauth keys).
	variable state_file "scripts/twitter.state"

	variable output_cmd putserv

	variable last_update
	variable last_msg

	# Twitter binds.
	bind pub	o|o "!twit"             ::twitter::tweet
	bind pub	o|o "!tweet"            ::twitter::tweet
	bind pub	o|o "!twit_msg"         ::twitter::msg
	bind pub	-|- "!twit_trends"      ::twitter::trends_global
	bind pub	o|o "!follow"           ::twitter::follow
	bind pub	o|o "!unfollow"         ::twitter::unfollow
	bind pub	-|- "!twit_updates"     ::twitter::updates
	bind pub	-|- "!twit_msgs"        ::twitter::msgs
	bind pub	-|- "!twit_search"      ::twitter::search
	bind pub	-|- "!twit_searchusers" ::twitter::search_users

	variable followers_trigger !followers
	bind pub	-|- $followers_trigger  ::twitter::followers

	variable following_trigger !following
	bind pub	-|- $following_trigger  ::twitter::following

	bind pub	o|o "!retweet"          ::twitter::retweet
	bind pub	o|o "!update_interval"  ::twitter::update_interval

	# OAuth binds
	bind pub	o|o "!twit_request_token" ::twitter::oauth_request
	bind pub	o|o "!twit_access_token"  ::twitter::oauth_access

	# Save our state on save event.
	bind evnt	-|- "save" ::twitter::write_states

	# Add channel flag +/-twitter
	setudef flag twitter
}

# Handle retrieval of OAuth request token
proc ::twitter::oauth_request {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }
	set argv [split $argv]
	if {[llength $argv] != 2} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_request_token <consumer key> <consumer secret>"
		return
	}
	lassign $argv ::twitlib::oauth_consumer_key ::twitlib::oauth_consumer_secret

	if {[catch {::twitoauth::get_request_token $::twitlib::oauth_consumer_key $::twitlib::oauth_consumer_secret} data]} {
		$::twitter::output_cmd "PRIVMSG $chan :Error: $data"
		return
	}

	set url [dict get $data auth_url]
	$::twitter::output_cmd "PRIVMSG $chan :To get your authentication verifier, visit ${url} and allow the application on your Twitter account."
	$::twitter::output_cmd "PRIVMSG $chan :Then call !twit_access_token [dict get $data oauth_token] [dict get $data oauth_token_secret] <PIN from authorization URL of !twit_request_token>"
}

# Handle retrieval of OAuth access token
# if success, we store $::twitlib::oauth_token and $::twitlib::oauth_token_secret
proc ::twitter::oauth_access {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	set args [split $argv]
	if {[llength $args] != 3} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_access_token <oauth_token> <oauth_token_secret> <PIN> (get these from !twit_request_token)"
		return
	}
	lassign $args oauth_token oauth_token_secret pin

	if {[catch {::twitoauth::get_access_token $::twitlib::oauth_consumer_key $::twitlib::oauth_consumer_secret $oauth_token $oauth_token_secret $pin} data]} {
		$::twitter::output_cmd "PRIVMSG $chan :Error: $data"
		return
	}

	# reset stored state
	set ::twitlib::last_id 1
	set ::twitlib::last_mentions_id 1
	set ::twitter::last_update 1
	set ::twitter::last_msg 1

	set ::twitlib::oauth_token [dict get $data oauth_token]
	set ::twitlib::oauth_token_secret [dict get $data oauth_token_secret]
	set screen_name [dict get $data screen_name]
	$::twitter::output_cmd "PRIVMSG $chan :Successfully retrieved access token for \002${screen_name}\002."
}

# set the update time by recreating the time bind.
proc ::twitter::set_update_time {delay} {
	if {$delay != 1 && $delay != 10 && $delay != 5} {
		set delay 10
	}
	::twitter::flush_update_binds
	if {$delay == 1} {
		bind time - "* * * * *" ::twitter::update
		return
	}
	# NOTE: */x cron syntax is not supported by eggdrop.
	if {$delay == 5} {
		bind time - "?0 * * * *" ::twitter::update
		bind time - "?5 * * * *" ::twitter::update
		return
	}
	# 10
	bind time - "?0 * * * *" ::twitter::update
}

# remove our time bind.
proc ::twitter::flush_update_binds {} {
	foreach binding [binds time] {
		if {[lindex $binding 4] == "::twitter::update"} {
			unbind [lindex $binding 0] [lindex $binding 1] [lindex $binding 2] \
				[lindex $binding 4]
		}
	}
}

# Change time between automatic update fetches
proc ::twitter::update_interval {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {$argv != 1 && $argv != 10 && $argv != 5} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !update_interval <1, 5, or 10>"
		return
	}

	::twitter::set_update_time $argv

	$::twitter::output_cmd "PRIVMSG $chan :Update interval set to $argv minute(s)."
}

# Output decoded/split string to given channel
proc ::twitter::output {chan str} {
	set str [::htmlparse::mapEscapes $str]
	set str [regsub -all -- {\n} $str " "]
	$::twitter::output_cmd "PRIVMSG $chan :$str"
}

# Format status updates and output
proc ::twitter::output_update {chan name id str} {
	set out "\002$name\002: $str"
	if {$::twitter::show_tweetid} {
		append out " ($id)"
	}
	::twitter::output $chan $out
}

# Retweet given id
proc ::twitter::retweet {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1 || ![regexp {^\d+$} $argv]} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !retweet <id>"
		return
	}

	# Setup url since id is not given as params for some reason...
	set url "${::twitlib::retweet_url}${argv}.json"

	if {[catch {::twitlib::query $url {} POST} result]} {
		$::twitter::output_cmd "PRIVMSG $chan :Retweet failure. ($argv) (You can't retweet your own updates!)"
		return
	}

	$::twitter::output_cmd "PRIVMSG $chan :Retweet sent."
}

# Follow a user (by screen name)
proc ::twitter::follow {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !follow <screen name>"
		return
	}

	if {[catch {::twitlib::query $::twitlib::follow_url [list screen_name $argv]} result]} {
		$::twitter::output_cmd "PRIVMSG $chan :Twitter failed or already friends with $argv!"
		return
	}

	if {[dict exists $result error]} {
		::twitter::output $chan "Follow failed ($argv): [dict get $result error]"
		return
	}

	::twitter::output $chan "Now following [dict get $result screen_name]!"
}

# Unfollow a user (by screen name)
proc ::twitter::unfollow {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !unfollow <screen name>"
		return
	}

	if {[catch {::twitlib::query $::twitlib::unfollow_url [list screen_name $argv]} result]} {
		$::twitter::output_cmd "PRIVMSG $chan :Unfollow failed. ($argv)"
		return
	}

	if {[dict exists $result error]} {
		::twitter::output $chan "Unfollow failed ($argv): [dict get $result error]"
		return
	}

	::twitter::output $chan "Unfollowed [dict get $result screen_name]."
}

# Get last n, n [1, 20] updates
proc ::twitter::updates {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] < 1 || ![string is integer $argv] || $argv > 20 || $argv < 1} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_updates <#1 to 20>"
		return
	}

	if {[catch {::twitlib::query $::twitlib::home_url [list count $argv] GET} result]} {
		$::twitter::output_cmd "PRIVMSG $chan :Retrieval error: $result."
		return
	}

	if {[llength $result] == 0} {
		$::twitter::output_cmd "PRIVMSG $chan :No updates."
		return
	}

	set result [lreverse $result]
	foreach status $result {
		dict with status {
			::twitter::output_update $chan [dict get $user screen_name] $id $text
		}
	}
}

# Return top 5 results for query $argv
proc ::twitter::search {nick uhost hand chan argv} {
	# Let this command work in any channel we're in.

	if {[string length $argv] < 1 || [string length $argv] > 140} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_search <string 140 chars or less>"
		return
	}

	if {[catch {::twitlib::query $::twitlib::search_url [list q $argv count 4] GET} data]} {
		$::twitter::output_cmd "PRIVMSG $chan :Search error ($data)"
		return
	}

	if {[dict exists $data error]} {
		::twitter::output $chan "Search failed ($argv): [dict get $result error]"
		return
	}

	set statuses [dict get $data statuses]
	set count 0
	foreach status $statuses {
		set user [dict get $status user]
		::twitter::output $chan "\002[dict get $user screen_name]\002: [dict get $status text]"
	}
}

# Get first 5 results from users search
proc ::twitter::search_users {nick uhost hand chan argv} {
	# Let this command work in any channel we're in.

	if {[string length $argv] < 1} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_searchusers <string>"
		return
	}

	if {[catch {::twitlib::query $::twitlib::search_users_url [list q $argv per_page 5] GET} data]} {
		$::twitter::output_cmd "PRIVMSG $chan :Search error ($data)."
		return
	}

	foreach result $data {
		::twitter::output $chan "#[incr count] \002[dict get $result screen_name]\002 Name: [dict get $result name] Location: [dict get $result location] Description: [dict get $result description]"
	}
}

# Return latest followers (up to 100)
proc ::twitter::followers {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }
	set args [split $argv " "]
	if {[llength $args] != 1} {
		::twitter::output $chan "Usage: $::twitter::followers_trigger <screen name>"
		return
	}
	set screen_name [lindex $args 0]

	set query_list [list screen_name $screen_name follows_count \
		$::twitter::followers_limit]
	if {[catch {::twitlib::query $::twitlib::followers_url $query_list GET} \
		result]} {
		::twitter::output $chan "Error fetching followers."
		putlog "Error fetching followers: $result"
		return
	}

	# order to: first following -> last following
	set users [lreverse [dict get $result users]]

	set followers []
	foreach user $users {
		set screen_name [dict get $user screen_name]
		append followers "$screen_name "
	}
	set followers [string trim $followers]

	foreach line [::twitter::split_line $::twitter::line_length $followers] {
		::twitter::output $chan "Followers: $followers"
	}

	if {[llength $users] == 0} {
		::twitter::output $chan "$screen_name has no followers."
	}
}

# Returns the latest users following acct is following (up to 100)
proc ::twitter::following {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }
	set args [split $argv " "]
	if {[llength $args] != 1} {
		::twitter::output $chan "Usage: $::twitter::following_trigger <screen name>"
		return
	}
	set screen_name [lindex $args 0]

	set query_list [list screen_name $screen_name follows_count \
		$::twitter::followers_limit]
	if {[catch {::twitlib::query $::twitlib::following_url $query_list GET} \
		result]} {
		::twitter::output $chan "Error fetching friends."
		putlog "Error fetching friends: $result"
		return
	}

	# order to: first following -> last following
	set users [lreverse [dict get $result users]]

	set following ""
	foreach user $users {
		set screen_name [dict get $user screen_name]
		append following "$screen_name "
	}
	set following [string trim $following]

	foreach line [::twitter::split_line $::twitter::line_length $following] {
		::twitter::output $chan "Following: $line"
	}

	if {[llength $users] == 0} {
		::twitter::output $chan "$screen_name is not following anyone."
	}
}

# Retrieve and output global trends.
proc ::twitter::trends_global {nick uhost hand chan argv} {
	# Let this command work in any channel we're in.

	# id is a WOED (where on earth id). 1 means global.
	if {[catch {::twitlib::query $::twitlib::trends_place_url [list id 1] GET} result]} {
		$::twitter::output_cmd "PRIVMSG $chan :Trends request failed: $result."
		return
	}

	# We receive an array with one element - the object with our result.
	#
	# The object has keys trends (list of trends), as_of, created_at, and
	# locations.
	set result [lindex $result 0]

	# Pull out the trends object. This is an array of JSON objects (as dicts).
	# What I care about in these objects is the name. This is the trend name.
	set trends [dict get $result trends]

	set output ""
	set count 0
	foreach trend $trends {
		if {$output != ""} {
			append output " "
		}

		append output "\002#[incr count]\002 [dict get $trend name]"

		if {$count >= 20} {
			break
		}
	}

	foreach line [::twitter::split_line $::twitter::line_length $output] {
		::twitter::output $chan $line
	}
}

# Direct messages
# Get last n, n [1, 20] messages or new if no argument
proc ::twitter::msgs {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] == 1 && [string is integer $argv] && $argv < 20} {
		set params [list count $argv]
	} else {
		set params [list since_id $::twitter::last_msg]
	}

	if {[catch {::twitlib::query $::twitlib::msgs_url $params GET} result]} {
		$::twitter::output_cmd "PRIVMSG $chan :Messages retrieval failed."
		return
	}

	if {[llength $result] == 0} {
		$::twitter::output_cmd "PRIVMSG $chan :No new messages."
		return
	}

	foreach msg $result {
		dict with msg {
			if {$id > $::twitter::last_msg} {
				set ::twitter::last_msg $id
			}
			::twitter::output $chan "\002From\002 $sender_screen_name: $text ($created_at)"
		}
	}
}

# Send direct message to a user
# TODO: replace lrange by a substring starting at the first space to fix
# 'unmatched open brace in list' issue if the tweet contains one { not balanced
# by a }.
proc ::twitter::msg {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }
	set argv [split $argv]

	if {[llength $argv] < 2 || [string length [join [lrange $argv 1 end]]] > 140} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_msg <username> <msg 140 chars or less>"
		return
	}

	set name [lindex $argv 0]
	set msg [lrange $argv 1 end]
	set l [list screen_name $name text $msg]

	if {[catch {::twitlib::query $::twitlib::msg_url $l} data]} {
		$::twitter::output_cmd "PRIVMSG $chan :Message to \002$name\002 failed ($data)! (Are they following you?)"
	} else {
		::twitter::output $chan "Message sent."
	}
}

# Send status update (tweet)
proc ::twitter::tweet {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	if {[string length $argv] > 140 || $argv == ""} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !tweet <up to 140 characters>"
		return
	}

	if {[catch {::twitlib::query $::twitlib::status_url [list status $argv]} result]} {
		$::twitter::output_cmd "PRIVMSG $chan :Tweet failed! ($argv) Error: $result."
		return
	}

	set update_id [dict get $result id]
	if {$update_id == $::twitter::last_update} {
		$::twitter::output_cmd "PRIVMSG $chan :Tweet failed: Duplicate of tweet #$update_id. ($argv)"
		return
	}
	set ::twitter::last_update $update_id

	::twitter::output $chan "Tweet sent."
}

# send timeline updates to all +twitter channels.
proc ::twitter::output_updates {updates} {
	foreach status $updates {
		foreach ch [channels] {
			if {![channel get $ch twitter]} {
				continue
			}
			::twitter::output_update $ch [dict get $status screen_name] \
				[dict get $status id] [dict get $status text]
		}
	}
}

# grab unseen status updates and output them to +twitter channels.
proc ::twitter::update {min hour day month year} {
	# home timeline updates.
	if {$::twitter::poll_home_timeline} {
		if {[catch {::twitlib::get_unseen_updates} updates]} {
			putlog "Update retrieval (home) failed: $updates"
			return
		}
		::twitter::output_updates $updates
	}

	# mentions timeline updates.
	if {$::twitter::poll_mentions_timeline} {
		if {[catch {::twitlib::get_unseen_mentions} updates]} {
			putlog "Update retrieval (mentions) failed: $updates"
			return
		}
		::twitter::output_updates $updates
	}
}

# Get saved ids/state
proc ::twitter::get_states {} {
	if {[catch {open $::twitter::state_file r} fid]} {
		set ::twitlib::last_id 1
		set ::twitter::last_update 1
		set ::twitter::last_msg 1
		set ::twitlib::last_mentions_id 1
		return
	}

	set data [read -nonewline $fid]
	set states [split $data \n]
	close $fid

	set ::twitlib::last_id [lindex $states 0]
	set ::twitter::last_update [lindex $states 1]
	set ::twitter::last_msg [lindex $states 2]
	set ::twitlib::oauth_token [lindex $states 3]
	set ::twitlib::oauth_token_secret [lindex $states 4]
	set ::twitlib::oauth_consumer_key [lindex $states 5]
	set ::twitlib::oauth_consumer_secret [lindex $states 6]

	set ::twitlib::last_mentions_id 1
	if {[llength $states] >= 8} {
		set ::twitlib::last_mentions_id [lindex $states 7]
	}
}

# Save states to file
proc ::twitter::write_states {args} {
	set fid [open $::twitter::state_file w]
	puts $fid $::twitlib::last_id
	puts $fid $::twitter::last_update
	puts $fid $::twitter::last_msg
	puts $fid $::twitlib::oauth_token
	puts $fid $::twitlib::oauth_token_secret
	puts $fid $::twitlib::oauth_consumer_key
	puts $fid $::twitlib::oauth_consumer_secret
	puts $fid $::twitlib::last_mentions_id
	close $fid
}

# Split long line into list of strings for multi line output to irc
# Split into strings of ~max
# by fedex
proc ::twitter::split_line {max str} {
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

::twitter::get_states
::twitter::set_update_time $::twitter::update_time

putlog "twitter.tcl (c) fedex and horgh"
