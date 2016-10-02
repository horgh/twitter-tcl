#!/usr/bin/env tclsh
#
# This script provides a way to set up and test OAuth authentication.
#

# output usage information to stdout.
proc ::usage {} {
	global argv0

	puts "Usage: $argv0 <mode> \[arguments\]"
	puts ""
	puts "Mode is one of:"
	puts ""
	puts "  get_pin <consumer key> <consumer secret>"
	puts ""
	puts "    To perform authentication step 1 - get URL to retrieve PIN."
	puts "    You find the consumer key and secret on the Twitter OAuth"
	puts "    clients page."
	puts ""
	puts "  get_token <consumer key> <consumer secret> <token> <token secret> <pin>"
	puts ""
	puts "    to get an access token"
	puts ""
	puts "  get_updates <consumer key> <consumer secret> <token> <token secret>"
	puts ""
	puts "    to test usage of the tokens"
	puts ""
}

# perform authentication step 1 - request authorisation URL to get
# a PIN.
proc ::get_pin {consumer_key consumer_secret} {
	set d [::twitoauth::get_request_token $consumer_key $consumer_secret]
	foreach key [dict keys $d] {
		set val [dict get $d $key]
		puts "$key = $val"
	}
	puts "You should now authorise the access by going to the authentication"
	puts " URL, and then use it with this script in 'get_token' mode."
	return 1
}

# perform authentication step 2 - use the PIN from step 1 to authenticate.
proc ::get_token {consumer_key consumer_secret token token_secret pin} {
	set d [::twitoauth::get_access_token $consumer_key $consumer_secret \
		$token $token_secret $pin]
	foreach key [dict keys $d] {
		set val [dict get $d $key]
		puts "$key = $val"
	}
	puts "You should now have sufficient information to perform"
	puts "authenticated requests. Use the above data in the 'get_updates'"
	puts "mode of this script to test this."
	return 1
}

# use authentication information from step 2 to retrieve recent updates.
proc ::get_updates {consumer_key consumer_secret token token_secret} {
	set ::twitlib::oauth_consumer_key $consumer_key
	set ::twitlib::oauth_consumer_secret $consumer_secret
	set ::twitlib::oauth_token $token
	set ::twitlib::oauth_token_secret $token_secret
	# for testing it can be useful to set these
	#set ::twitlib::last_id 618247780138676226
	#set ::twitlib::max_updates 200

	set updates [::twitlib::get_unseen_updates]
	foreach status $updates {
		foreach key [dict keys $status] {
			set val [dict get $status $key]
			puts "$key = $val"
		}
	}

	set count [llength $updates]
	puts "Retrieved $count status update(s)."
	return 1
}

# include_libraries sets up the package include path (auto_path) and then
# loads required packages.
#
# I do this in a procedure rather than globally so I can dynamically adjust
# the auto_path.
proc ::include_libraries {} {
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

	package require twitoauth
	package require twitlib
}

# program entry.
# we will exit.
proc ::main {} {
	global argc
	global argv

	::include_libraries

	if {$argc == 0} {
		::usage
		exit 1
	}

	set mode [lindex $argv 0]

	if {$mode eq "get_pin"} {
		if {[llength $argv] != 3} {
			::usage
			exit 1
		}
		lassign $argv mode consumer_key consumer_secret
		if {![::get_pin $consumer_key $consumer_secret]} {
			exit 1
		}
		exit 0
	}

	if {$mode eq "get_token"} {
		if {[llength $argv] != 6} {
			::usage
			exit 1
		}
		lassign $argv mode consumer_key consumer_secret \
			token token_secret pin
		if {![::get_token $consumer_key $consumer_secret $token $token_secret \
			$pin]} {
			exit 1
		}
		exit 0
 	}

	if {$mode eq "get_updates"} {
		if {[llength $argv] != 5} {
			::usage
			exit 1
		}
		lassign $argv mode consumer_key consumer_secret \
			token token_secret
		if {![::get_updates $consumer_key $consumer_secret $token \
			$token_secret]} {
			exit 1
		}
		exit 0
	}

	::usage
	exit 1
}

::main
