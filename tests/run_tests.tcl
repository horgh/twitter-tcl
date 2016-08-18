#!/usr/bin/env tclsh
#
# Program to run some automated tests
#

# parameter: json_file: file with json payload of statuses.
#   home statuses timeline for example.
proc ::get_test_statuses {json_file} {
	# read in and decode the statuses
	set f [open $json_file]
	set data [read -nonewline $f]
	close $f
	set statuses [::json::json2dict $data]

	set fixed_statuses [::twitlib::fix_statuses $statuses]
	foreach status $fixed_statuses {
		set tweet [dict get $status text]
		puts "Tweet: $tweet"
	}
	return 1
}

proc ::print_usage {} {
	global argv0
	puts "Usage: $argv0 <file with JSON containing sample statuses>"
}

proc ::get_args {} {
	global argv
	if {[llength $argv] != 1} {
		::print_usage
		exit 1
	}
	return [lindex $argv 0]
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

	package require json
	package require twitlib
}

proc ::main {} {
	::include_libraries

	set json_file [::get_args]

	if {![::get_test_statuses $json_file]} {
		return 0
	}

	return 1
}

if {![::main]} {
	exit 1
}
