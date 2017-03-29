#!/usr/bin/env tclsh8.6
#
# Twitter tweet poller.
#
# This script polls latest unseen home statuses from twitter and inserts them
# into a PostgreSQL database.
#

namespace eval ::twitter_poll {
	# Database connection variables.
	variable db_name {}
	variable db_host 0
	variable db_port 5432
	variable db_user {}
	variable db_pass {}

	# Verbosity. Boolean.
	variable verbose 0
}

# Setup our configuration variables.
#
# We expect a configuration file in this location:
#
# ~/.config/twitter_poll.conf
#
# The contents of the config are key and values in the format:
#
# key=value
#
# We require the keys:
#
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

	# TODO: Check that file exists first? So we can give a nicer error message.
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

		if {[string length $key] == 0 \
			|| [string length $val] == 0} {
			continue
		}
		dict set values $key $val
	}

	# TODO: The below will generate an error if a config key is missing. It would
	# be better to handle this more cleanly.

	# OAuth variables.
	set ::twitlib::oauth_consumer_key    [dict get $values oauth_consumer_key]
	set ::twitlib::oauth_consumer_secret [dict get $values oauth_consumer_secret]
	set ::twitlib::oauth_token           [dict get $values oauth_token]
	set ::twitlib::oauth_token_secret    [dict get $values oauth_token_secret]

	# Database variables.
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

# See here for working with timelines:
# https://dev.twitter.com/rest/public/timelines
proc ::twitter_poll::get_last_tweet_id {dbh} {
	# "This problem is avoided by setting the sinc_id parameter to the greatest ID
	# of all the Tweets your application has already processed."
	set sql "SELECT MAX(tweet_id) AS tweet_id FROM tweet"
	set tweet_id 1

	::pg::select $dbh $sql array {
		set tweet_id $array(tweet_id)
	}

	if {$::twitter_poll::verbose} {
		puts "Latest tweet ID seen: $tweet_id"
	}

	# NOTE: Apparently select proc cleans up for us.

	return $tweet_id
}

# Status is a dict with keys: id, screen_name, text.
#
# It represents a single tweet.
proc ::twitter_poll::store_update {dbh status} {
	set sql {\
		INSERT INTO tweet \
		(nick, text, tweet_id, time) \
		SELECT $1, $2, $3, $4 \
		WHERE NOT EXISTS \
			(SELECT NULL FROM tweet WHERE tweet_id = $5) \
		}

	set tweet [dict get $status text]

	# We get back a result handle that can be used to get at other data. It may
	# be used to clean up too.

	# NOTE: id is actually id_str. It's extracted inside twitlib.

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

	if {$::twitter_poll::verbose} {
		puts "Stored tweet: $tweet (ID: [dict get $status id])"
	}

	# Clean up.
	::pg::result $result -clear

	return 1
}

proc ::twitter_poll::poll {} {
	set dbh [::twitter_poll::get_db_handle]

	# Find the last tweet id we have recorded. We use this as the last seen tweet
	# id.

	if {$::twitter_poll::verbose} {
		puts "Determining latest tweet ID..."
	}

	set ::twitlib::last_id [::twitter_poll::get_last_tweet_id $dbh]

	if {$::twitter_poll::verbose} {
		puts "Latest tweet ID is $::twitlib::last_id."
	}

	# Retrieve unseen tweets.

	if {$::twitter_poll::verbose} {
		puts "Fetching updates..."
	}

	set updates [::twitlib::get_unseen_updates]

	if {$::twitter_poll::verbose} {
		puts "Updates received! Storing..."
	}

	foreach status $updates {
		if {![::twitter_poll::store_update $dbh $status]} {
			::pg::disconnect $dbh
			return 0
		}
	}

	set count [llength $updates]

	if {$::twitter_poll::verbose} {
		puts "Retrieved $count update(s)."
	}

	if {$count >= $::twitlib::max_updates} {
		puts "Warning: Retrieved maximum number of tweets: $count"
	}

	::pg::disconnect $dbh

	return 1
}

# include_libraries sets up the package include path (auto_path) and then loads
# required packages.
#
# I do this in a procedure rather than globally so I can dynamically adjust the
# auto_path.
proc ::twitter_poll::include_libraries {} {
	global auto_path

	# Find the directory the script is in.
	set script_path [info script]
	set script_dir [file dirname $script_path]

	# Libraries we want are in the parent directory.
	if {[file pathtype $script_dir] == "absolute"} {
		set parent [file dirname $script_dir]
		set auto_path [linsert $auto_path 0 $parent]
	} else {
		set parent [file join $script_dir ".."]
		set auto_path [linsert $auto_path 0 $parent]
	}

	package require Pgtcl
	package require twitlib
}

proc ::twitter_poll::main {} {
	::twitter_poll::include_libraries

	::twitter_poll::setup

	if {![::twitter_poll::poll]} {
		exit 1
	}
	exit 0
}

::twitter_poll::main
