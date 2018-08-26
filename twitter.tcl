#
# A Twitter client/gateway for IRC.
#
# By fedex and horgh.
#

package require htmlparse
package require http
package require inifile
package require twitoauth
package require twitlib

namespace eval ::twitter {
	# Check for tweets every update_time minutes.
	variable update_time 10

	# Show tweet number in tweets shown in channels (1 = on, 0 = off).
	# This is only really relevant if you are going to !retweet.
	variable show_tweetid 0

	# Path to the configuration file. The path is relative to the Eggdrop root
	# directory. You can specify an absolute path.
	#
	# The configuration file currently contains a small number of the available
	# options. Eventually we may move all options to it.
	variable config_file twitter.conf

	# Control what we poll. Each of these poll types is a separate API request
	# every 'update_time' interval, so if you don't need/want one, then it is
	# more efficient to disable it.
	#
	# By default we poll only the home timeline. This means you will see tweets
	# of users you follow.

	# Whether to poll home timeline.
	variable poll_home_timeline 1
	# Whether to poll mentions timeline.
	variable poll_mentions_timeline 0

	# Maximum characters per output line.
	variable line_length 400

	#
	# You shouldn't need to change anything below this point!
	#

	# Number of followers to output when listing followers. The API can return a
	# maximum of 200 at a time but you probably don't want to spam channels with
	# that many! If we wanted to see all of them then it is possible to make
	# multiple API calls using the cursor parameter to page through.
	variable followers_limit 50

	# This file holds state information (id of last seen tweet, oauth keys).
	variable state_file "scripts/twitter.state"

	variable output_cmd putserv

	variable last_update
	variable last_msg

	# Map of accounts you follow to the channels to show statuses in.
	#
	# If an account isn't in this map then its statuses go to all +twitter
	# channels.
	#
	# Define this mapping in the config file.
	variable account_to_channels [dict create]

	# Channel command binds.
	bind pub o|o "!twit"             ::twitter::tweet
	bind pub o|o "!tweet"            ::twitter::tweet
	bind pub o|o "!twit_msg"         ::twitter::msg
	bind pub -|- "!twit_trends"      ::twitter::trends_global
	bind pub o|o "!follow"           ::twitter::follow
	bind pub o|o "!unfollow"         ::twitter::unfollow
	bind pub -|- "!twit_updates"     ::twitter::updates
	bind pub -|- "!twit_msgs"        ::twitter::msgs
	bind pub -|- "!twit_search"      ::twitter::search
	bind pub -|- "!twit_searchusers" ::twitter::search_users
	bind pub -|- "!twit_get_tweet"   ::twitter::get_tweet

	variable followers_trigger !followers
	bind pub -|- $followers_trigger  ::twitter::followers

	variable following_trigger !following
	bind pub -|- $following_trigger  ::twitter::following

	bind pub o|o "!retweet"          ::twitter::retweet

	bind pub -|- !twitstatus         ::twitter::status

	# OAuth channel command binds.
	bind pub o|o "!twit_request_token" ::twitter::oauth_request
	bind pub o|o "!twit_access_token"  ::twitter::oauth_access

	# Save our state on save event.
	bind evnt -|- "save" ::twitter::write_states

	bind dcc -|- twitter-status ::twitter::dcc_status

	# Add channel flag +/-twitter.
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

# remove our time bind.
proc ::twitter::flush_update_binds {} {
	foreach binding [binds time] {
		if {[lindex $binding 4] == "::twitter::update"} {
			unbind [lindex $binding 0] [lindex $binding 1] [lindex $binding 2] \
				[lindex $binding 4]
		}
	}
}

proc ::twitter::status {nick uhost hand chan argv} {
	set screen_name [::twitlib::get_my_screen_name]
	$::twitter::output_cmd "PRIVMSG $chan :I'm @$screen_name."
}

# Output decoded/split string to given channel
proc ::twitter::output {chan str} {
	set str [::htmlparse::mapEscapes $str]
	set str [regsub -all -- {\n} $str " "]
	$::twitter::output_cmd "PRIVMSG $chan :$str"
}

# Format status update and output it to the channel.
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

	set argv [string trim $argv]
	set args [split $argv " "]
	if {[llength $args] == 0} {
		::twitter::follow_usage $chan
		return
	}
	set screen_name [string tolower [lindex $args 0]]

	set channels [list]
	if {[llength $args] > 1} {
		foreach channel [lrange $args 1 end] {
			set channel [string tolower $channel]

			if {[string index $channel 0] != "#"} {
				::twitter::follow_usage $chan
				return
			}

			if {[lsearch -exact $channels $channel] != -1} {
				continue
			}

			lappend channels $channel
		}
	}

	set query [list screen_name $screen_name]
	if {[catch {::twitlib::query $::twitlib::follow_url $query} result]} {
		$::twitter::output_cmd "PRIVMSG $chan :Unable to follow or already friends with $screen_name!"
		putlog "Unable to follow or already friends with $screen_name: $result"
		return
	}

	if {[dict exists $result error]} {
		::twitter::output $chan "Follow failed ($screen_name): [dict get $result error]"
		return
	}

	::twitter::output $chan "Now following [dict get $result screen_name]!"

	# Update mappings and save config no matter what (even if there is no
	# mapping). If they specified no channels then this lets us reset mapping to
	# all channels if the account was previously mapped.

	if {[llength $channels] == 0} {
		if {[dict exists $::twitter::account_to_channels $screen_name]} {
			dict unset ::twitter::account_to_channels $screen_name
		}
	} else {
		dict set ::twitter::account_to_channels $screen_name $channels
	}

	::twitter::save_config
}

proc ::twitter::follow_usage {chan} {
	$::twitter::output_cmd "PRIVMSG $chan :Usage: !follow <screen name> \[#channel1 #channel2 ...\]"
	$::twitter::output_cmd "PRIVMSG $chan :If you specify channel(s) then the screen name's statuses will only show in those channels. This updates the config. To show them in all channels, do not specify any here."
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

	set params [list \
		count $argv \
		tweet_mode extended \
	]

	if {[catch {::twitlib::query $::twitlib::home_url $params GET} result]} {
		$::twitter::output_cmd "PRIVMSG $chan :Retrieval error: $result."
		return
	}

	if {[llength $result] == 0} {
		$::twitter::output_cmd "PRIVMSG $chan :No updates."
		return
	}

	set result [::twitlib::fix_statuses $result]

	set result [lreverse $result]
	foreach status $result {
		dict with status {
			::twitter::output_update $chan [dict get $user screen_name] $id $full_text
		}
	}
}

# Return top 5 results for query $argv
proc ::twitter::search {nick uhost hand chan argv} {
	# Let this command work in any channel we're in.

	set argv [string trim $argv]
	if {[string length $argv] < 1 || [string length $argv] > 500} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_search <query, 500 chars max>"
		return
	}

	set params [list \
		q $argv \
		count 4 \
		tweet_mode extended \
	]

	if {[catch {::twitlib::query $::twitlib::search_url $params GET} data]} {
		$::twitter::output_cmd "PRIVMSG $chan :Search error ($data)"
		return
	}

	if {[dict exists $data error]} {
		::twitter::output $chan "Search failed ($argv): [dict get $result error]"
		return
	}

	set statuses [dict get $data statuses]
	set statuses [::twitlib::fix_statuses $statuses]
	set count 0
	foreach status $statuses {
		set user [dict get $status user]
		::twitter::output $chan "\002[dict get $user screen_name]\002: [dict get $status full_text]"
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

proc ::twitter::get_tweet {nick uhost hand chan argv} {
	set id [string trim $argv]
	if {$id == ""} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_get_tweet <ID>"
		return
	}

	if {[catch {::twitlib::get_status_by_id $id} status]} {
		$::twitter::output_cmd "PRIVMSG $chan :Error: $status"
		return
	}

	::twitter::output_update $chan [dict get $status user screen_name] $id \
		[dict get $status full_text]
}

# Look up and output the users following an account (the most recent).
#
# If no account is given, we output who is following us.
#
# We output at most $::twitter::followers_limit screen names.
proc ::twitter::followers {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	set argv [string trim $argv]
	set args [split $argv " "]
	if {[llength $args] > 1} {
		::twitter::output $chan "Usage: $::twitter::followers_trigger \[screen name\] (defaults to me)"
		return
	}
	set screen_name {}
	if {[llength $args] == 1} {
		set screen_name [lindex $args 0]
	}

	set query_list [list count $::twitter::followers_limit]
	if {$screen_name != ""} {
			lappend query_list screen_name $screen_name
	}
	if {[catch {::twitlib::query $::twitlib::followers_url $query_list GET} \
		result]} {
		::twitter::output $chan "Error fetching followers."
		putlog "Error fetching followers: $result"
		return
	}

	# Sort: First following -> last following.
	set users [lreverse [dict get $result users]]

	# Format.
	set followers []
	foreach user $users {
		append followers "[dict get $user screen_name] "
	}
	set followers [string trim $followers]

	foreach line [::twitter::split_line $::twitter::line_length $followers] {
		if {$screen_name == ""} {
			::twitter::output $chan "I have followers: $followers"
		} else {
			::twitter::output $chan "$screen_name has followers: $followers"
		}
	}

	if {[llength $users] == 0} {
		if {$screen_name == ""} {
			::twitter::output $chan "I have no followers."
		} else {
			::twitter::output $chan "$screen_name has no followers."
		}
	}
}

# Look up and output the users an account is following (the most recent).
#
# If no account is given, we output who we are following.
#
# We output at most $::twitter::followers_limit screen names.
proc ::twitter::following {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	set argv [string trim $argv]
	set args [split $argv " "]
	if {[llength $args] > 1} {
		::twitter::output $chan "Usage: $::twitter::following_trigger \[screen name\] (defaults to me)"
		return
	}
	set screen_name {}
	if {[llength $args] == 1} {
		set screen_name [lindex $args 0]
	}

	set query_list [list count $::twitter::followers_limit]
	if {$screen_name != ""} {
			lappend query_list screen_name $screen_name
	}
	if {[catch {::twitlib::query $::twitlib::following_url $query_list GET} \
		result]} {
		::twitter::output $chan "Error looking Twitter friends."
		putlog "Error looking up Twitter friends: $result"
		return
	}

	# Sort: First following -> last following.
	set users [lreverse [dict get $result users]]

	# Format output.
	set following ""
	foreach user $users {
		append following "[dict get $user screen_name] "
	}
	set following [string trim $following]

	foreach line [::twitter::split_line $::twitter::line_length $following] {
		if {$screen_name == ""} {
			::twitter::output $chan "I'm following: $line"
		} else {
			::twitter::output $chan "$screen_name is following: $line"
		}
	}

	if {[llength $users] == 0} {
		if {$screen_name == ""} {
			::twitter::output $chan "I'm not following anyone."
		} else {
			::twitter::output $chan "$screen_name is not following anyone."
		}
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
proc ::twitter::msg {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	set argv [split $argv]
	if {[llength $argv] < 2} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_msg <username> <text>"
		return
	}
	# I can't find a documented limit on the length of a message.
	# https://blog.twitter.com/official/en_us/a/2015/removing-the-140-character-limit-from-direct-messages.html
	set name [string trim [lindex $argv 0]]
	set msg [string trim [lrange $argv 1 end]]
	if {$name == "" || $msg == ""} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !twit_msg <username> <text>"
		return
	}

	set l [list \
		screen_name $name \
		text        $msg \
	]

	if {[catch {::twitlib::query $::twitlib::msg_url $l} data]} {
		$::twitter::output_cmd "PRIVMSG $chan :Message to \002$name\002 failed ($data)! Are they following you?"
		return
	}
	::twitter::output $chan "Message sent."
}

# Send status update (tweet)
proc ::twitter::tweet {nick uhost hand chan argv} {
	if {![channel get $chan twitter]} { return }

	set argv [string trim $argv]
	if {$argv == ""} {
		$::twitter::output_cmd "PRIVMSG $chan :Usage: !tweet <text>"
		return
	}
	if {[string length $argv] > 280} {
		set argv [string trim [string range $argv 0 279]]
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
	# Track what channels we output each status to. This is mainly useful for
	# testing so we can examine the return value for where an update was sent.
	set id_to_channels [dict create]

	set all_channels [channels]

	foreach status $updates {
		# Figure out what channels to output the status to.
		#
		# By default we output to all +twitter channels.
		#
		# However, if the account is mapped to particular channels, then output only
		# to those. Note they must be +twitter as well.

		set account [dict get $status screen_name]
		set account [string trim $account]
		set account [string tolower $account]
		if {$account == ""} {
			continue
		}

		set account_channels [list]
		if {[dict exists $::twitter::account_to_channels $account]} {
			set account_channels [dict get $::twitter::account_to_channels $account]
		}

		set output_channels $all_channels
		if {[llength $account_channels] > 0} {
			set output_channels $account_channels
		}

		foreach ch $output_channels {
			if {[lsearch -exact -nocase $all_channels $ch] == -1} {
				continue
			}
			if {![channel get $ch twitter]} {
				continue
			}

			set id [dict get $status id]
			# Don't use $account here. We've done things like lowercase it.
			::twitter::output_update $ch [dict get $status screen_name] $id \
				[dict get $status full_text]

			if {![dict exists $id_to_channels $id]} {
				dict set id_to_channels $id [list]
			}
			dict lappend id_to_channels $id $ch
		}
	}

	return $id_to_channels
}

proc ::twitter::loop {} {
	set update_time_seconds [expr $::twitter::update_time * 60]

	# Ratelimiting for the home timeline is 15 every 15 minutes. Since
	# ratelimiting works by starting a window when we make the first request, if
	# we make one request a minute, on the 16th request we can still be in the
	# original window. To avoid this, make requests every 61 seconds instead.
	#
	# Example of the problem: If we make our first request at 00:00:00 then we're
	# allowed 14 more requests up to and including 00:15:00. Request 0: 00:00:00,
	# request 1: 00:01:00, ..., request 15: 00:14:00, request 16: 00:15:00. That
	# last request is still within the original window.
	if {$update_time_seconds <= 60} {
		set update_time_seconds 61
	}

	set ::twitter::after_id [after [expr $update_time_seconds * 1000] ::twitter::loop]

	set now [clock seconds]

	# Don't retrieve update right when we load the script. It can contribute to
	# hitting ratelimit early as well as we may not be in any channels yet.
	if {![info exists ::twitter::last_update_time]} {
		set ::twitter::last_update_time $now
	}

	set earliest_update_time [expr $::twitter::last_update_time + $update_time_seconds]
	if {$now < $earliest_update_time} {
		return
	}

	set ::twitter::last_update_time $now

	if {$::twitter::poll_home_timeline} {
		if {[catch {::twitlib::get_unseen_updates} updates]} {
			putlog "Update retrieval (home) failed: $updates"
			return
		}
		if {[catch {::twitter::output_updates $updates} err]} {
			putlog "Outputting updates (home) failed: $err"
			return
		}
	}

	if {$::twitter::poll_mentions_timeline} {
		if {[catch {::twitlib::get_unseen_mentions} updates]} {
			putlog "Update retrieval (mentions) failed: $updates"
			return
		}
		if {[catch {::twitter::output_updates $updates} err]} {
			putlog "Outputting updates (mentions) failed: $err"
			return
		}
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

proc ::twitter::load_config {} {
	set ::twitter::account_to_channels [dict create]

	if {![file exists $::twitter::config_file]} {
		putlog "twitter.tcl: Config file $::twitter::config_file does not exist, skipping"
		return
	}

	if {[catch {::ini::open $::twitter::config_file r} ini]} {
		putlog "twitter.tcl: Error opening configuration file: $::twitter::config_file: $ini"
		return
	}

	set mapping_section account-to-channel-mapping
	if {![::ini::exists $ini $mapping_section]} {
		::ini::close $ini
		return
	}

	foreach key [::ini::keys $ini $mapping_section] {
		set account [string trim $key]
		if {[string length $account] == 0} {
			continue
		}
		set account [string tolower $account]

		# The ini is key/value. If you list the same key multiple times we get the
		# first definition's value multiple times, so it is not useful and is
		# probably not what you intended.
		if {![dict exists $::twitter::account_to_channels $account]} {
			dict set ::twitter::account_to_channels $account [list]
		} else {
			putlog "twitter.tcl: Error: $account is in $mapping_section twice"
			continue
		}

		set channels_string [::ini::value $ini $mapping_section $key]
		set channels [split $channels_string ,]
		foreach channel $channels {
			set channel [string trim $channel]
			if {[string length $channel] == 0} {
				continue
			}
			set channel [string tolower $channel]

			dict lappend ::twitter::account_to_channels $account $channel
		}
	}

	::ini::close $ini
}

proc ::twitter::save_config {} {
	# r+ is read/write
	if {[catch {::ini::open $::twitter::config_file r+} ini]} {
		putlog "twitter.tcl: Error opening configuration file: $::twitter::config_file: $ini"
		return
	}

	set mapping_section account-to-channel-mapping

	# Clear out the current mappings. Note that comments in the section do not
	# reliably stick around. They seem to stick around if the comment is above an
	# account that we have after rewriting the file. But if the comment is above a
	# key that we lose a mapping for all together then we lose the comment as
	# well.
	if {[::ini::exists $ini $mapping_section]} {
		foreach key [ini::keys $ini $mapping_section] {
			::ini::delete $ini $mapping_section $key
		}
	}

	set account_count 0
	foreach account [dict keys $::twitter::account_to_channels] {
		set channels [dict get $::twitter::account_to_channels $account]
		if {[llength $channels] == 0} {
			continue
		}
		set channels_csv [join $channels ,]
		::ini::set $ini $mapping_section $account $channels_csv
		incr account_count
	}

	::ini::commit $ini
	::ini::close $ini
	putlog "twitter.tcl: Wrote $::twitter::config_file ($account_count accounts)"
}

proc ::twitter::write_status_to_log {} {
	putlog "twitter.tcl: Config file is $::twitter::config_file"

	putlog "twitter.tcl: Mapped [dict size $::twitter::account_to_channels] accounts to specific channels"
	foreach account [dict keys $::twitter::account_to_channels] {
		set channels {}
		foreach c [dict get $::twitter::account_to_channels $account] {
			if {$channels == ""} {
				append channels $c
			} else {
				append channels ", $c"
			}
		}
		set channel_count [llength [dict get $::twitter::account_to_channels $account]]
		putlog "twitter.tcl: $account shows in $channel_count channels: $channels"
	}
}

# Split long line into list of strings for multi line output to irc.
#
# Split into strings of ~max.
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

proc ::twitter::dcc_status {handle idx text} {
	::twitter::write_status_to_log
	return 1
}

::twitter::get_states
::twitter::load_config
::twitter::write_status_to_log

if {[info exists ::twitter::after_id]} {
	after cancel $::twitter::after_id
}
::twitter::loop

# Stop the old update method that might still be running if we rehashed. In the
# future we can delete this.
::twitter::flush_update_binds

putlog "twitter.tcl (c) fedex and horgh"
