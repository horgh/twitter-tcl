#!/usr/bin/env tclsh8.5
#
# Twitter tweet poller.
#
# This script polls latest unseen home statuses from twitter and inserts
# them into a postgres database.
#

# TODO: script directory instead of pwd?
set auto_path [linsert $auto_path 0 [pwd]]

package require Pgtcl
package require twitlib

namespace eval ::twitter_poll {
	# database connection variables.
	variable db_name {}
	variable db_host 0
	variable db_port 5432
	variable db_user {}
	variable db_pass {}

	# verbosity. boolean.
	variable verbose 0
}

# setup our configuration variables.
#
# we expect a configuration file in this location:
# ~/.config/twitter_poll.conf
#
# the contents of the config are key and values in the format:
# key=value
#
# we require the keys:
# oauth_consumer_key
# oauth_consumer_secret
# oauth_token
# oauth_token_secret
# db_name
# db_host
# db_port
# db_user
# db_pass
# verbose
proc ::twitter_poll::setup {} {
	# ~/.config/twitter_poll.conf
	set config_file [file join $::env(HOME) .config twitter_poll.conf]

	# TODO: check that file exists first?
	set f [open $config_file]
	set contents [read -nonewline $f]
	close $f

	set values [dict create]
	foreach line [split $contents \n] {
		set parts [split $line =]
		if {[llength $parts] != 2} {
			continue
		}
		lassign $parts key val
		set key [string trim $key]
		set val [string trim $val]

		if {[expr [string length $key] == 0] \
			|| [expr [string length $val] == 0]} {
			continue
		}
		dict set values $key $val
	}

	# TODO: the below will generate an error if a config key is missing.
	#   it would be better to handle this more cleanly.

	# oauth variables.
	set ::twitlib::oauth_consumer_key    [dict get $values oauth_consumer_key]
	set ::twitlib::oauth_consumer_secret [dict get $values oauth_consumer_secret]
	set ::twitlib::oauth_token           [dict get $values oauth_token]
	set ::twitlib::oauth_token_secret    [dict get $values oauth_token_secret]

	# database variables.
	set ::twitter_poll::db_name [dict get $values db_name]
	set ::twitter_poll::db_host [dict get $values db_host]
	set ::twitter_poll::db_port [dict get $values db_port]
	set ::twitter_poll::db_user [dict get $values db_user]
	set ::twitter_poll::db_pass [dict get $values db_pass]

	set ::twitlib::max_updates [dict get $values max_tweets_at_once]
	set ::twitter_poll::verbose [dict get $values verbose]
}

proc ::twitter_poll::get_db_handle {} {
	set conn_list [list \
		host $::twitter_poll::db_host \
		port $::twitter_poll::db_port \
		dbname $::twitter_poll::db_name \
		user $::twitter_poll::db_user \
		password $::twitter_poll::db_pass \
	]
	set dbh [::pg::connect -connlist $conn_list]
	return $dbh
}

proc ::twitter_poll::get_last_tweet_id {dbh} {
	# TODO: hmm, I think tweets are not guaranteed to always
	#   be increasing.
	#   but then why does the since_id parameter in the API exist?
	#   presumably it must be correct then.

	# take my internal id column so we can be sure it's the last
	# tweet received. I'm not sure max tweet id is valid due to
	# how the numbering works
	set sql "SELECT tweet_id FROM tweet ORDER BY id DESC LIMIT 1"
	set tweet_id 1
	::pg::select $dbh $sql array {
		set tweet_id $array(tweet_id)
	}
	if {$::twitter_poll::verbose} {
		puts "Latest tweet ID seen: $tweet_id"
	}
	# NOTE: apparently select proc cleans up for us.
	return $tweet_id
}

# status is a dict with keys: id, screen_name, text.
# it represents a single tweet.
proc ::twitter_poll::store_update {dbh status} {
	set sql {\
		INSERT INTO tweet \
		(nick, text, tweet_id, time) \
		SELECT $1, $2, $3, $4 \
		WHERE NOT EXISTS \
			(SELECT NULL FROM tweet WHERE tweet_id = $5) \
		}

	# we get back a result handle that can be used to get
	# at other data.
	# it may be used to clean up too.
	set tweet [dict get $status text]
	set result [::pg::sqlexec $dbh $sql \
		[dict get $status screen_name] \
		$tweet \
		[dict get $status id] \
		[dict get $status created_at] \
		[dict get $status id]]
	set result_status [::pg::result $result -status]
	if {$::twitter_poll::verbose} {
		puts "Result status: $result_status"
	}
	if {$result_status != "PGRES_COMMAND_OK"} {
		set err [::pg::result $result -error]
		puts "Failed to insert tweet: $tweet"
		puts "Error executing INSERT: $err"
		::pg::result $result -clear
		return 0
	}
	# clean up.
	::pg::result $result -clear
	if {$::twitter_poll::verbose} {
		puts "Stored tweet: $tweet"
	}
	return 1
}

proc ::twitter_poll::poll {} {
	# connect to the database.
	set dbh [::twitter_poll::get_db_handle]

	# find the last tweet id we have recorded. we use this as the
	# last seen tweet id.
	if {$::twitter_poll::verbose} {
		puts "Determining latest tweet ID..."
	}
	set ::twitlib::last_id [::twitter_poll::get_last_tweet_id $dbh]

	# retrieve unseen tweets.
	if {$::twitter_poll::verbose} {
		puts "Fetching updates..."
	}
	set updates [::twitlib::get_unseen_updates]
	if {$::twitter_poll::verbose} {
		puts "Updated received! Storing..."
	}

	# add each unseen tweet into the database.
	foreach status $updates {
		if {![::twitter_poll::store_update $dbh $status]} {
			::pg::disconnect $dbh
			return 0
		}
	}
	if {$::twitter_poll::verbose} {
		set count [llength $updates]
		puts "Retrieved $count update(s)."
	}
	::pg::disconnect $dbh
	return 1
}

# program entry.
proc ::twitter_poll::main {} {
	::twitter_poll::setup
	if {![::twitter_poll::poll]} {
		exit 1
	}
	exit 0
}

::twitter_poll::main
