#!/usr/bin/env tclsh8.5
#
# program to run some automated tests
#

# TODO: script directory instead of pwd?
set auto_path [linsert $auto_path 0 [pwd]]

package require json
package require twitlib

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

proc ::main {} {
	set json_file [::get_args]
	if {![::get_test_statuses $json_file]} {
		return 0
	}
	return 1
}
if {![::main]} {
	exit 1
}
