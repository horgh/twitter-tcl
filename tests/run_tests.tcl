#!/usr/bin/env tclsh
#
# Program to run some automated tests
#

# Dummy some Eggdrop commands. We just want them to not error.
proc bind {a b c d} {}
proc setudef {a b} {}
proc putlog {a} {
	puts "putlog said: $a"
}
proc putserv {a} {
	puts "putserv said: $a"
}
proc binds {a} {}

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
	source "$parent/twitter.tcl"
}

proc ::main {} {
	::include_libraries

	set json_file [::get_args]

	set success 1

	if {![::get_test_statuses $json_file]} {
		puts "get_test_statuses failed"
		set success 0
	}

	if {![::test_load_config]} {
		puts "test_load_config failed"
		set success 0
	}

	if {![::test_save_config]} {
		puts "test_save_config failed"
		set success 0
	}

	if {![::test_output_updates]} {
		puts "test_output_updates failed"
		set success 0
	}

	if {$success} {
		puts "All tests passed"
	} else {
		puts "Some tests failed"
	}

	return $success
}

proc ::test_load_config {} {
	set tmpfile /tmp/twitter-tests.bin
	if {[file exists $tmpfile]} {
		file delete $tmpfile
	}
	set ::twitter::config_file $tmpfile

	# Test file not existing.
	::twitter::load_config
	if {[dict size $::twitter::account_to_channels] != 0} {
		puts "load_config when the file does not exist unexpectedly had non-zero mapping"
		return 0
	}

	# Test cases where the file exists.
	set tests [list \
		[dict create \
			description "empty file" \
			input "" \
			expected [dict create] \
		] \
		[dict create \
			description "empty section" \
			input "\[account-to-channel-mapping\]\n" \
			expected [dict create] \
		] \
		[dict create \
			description "empty section but with comments" \
			input "\[account-to-channel-mapping\]\n; test comment\n; another\n" \
			expected [dict create] \
		] \
		[dict create \
			description "multiple accounts set up" \
			input "\[account-to-channel-mapping\]\n; test comment\n; another\naccount1 = #chan1\naccount2 = #chan1,#chan2, #chaN3\naccounT1=#chan4\n; another account\nAccount5=#chan5" \
			expected [dict create \
				account1 [list #chan4] \
				account2 [list #chan1 #chan2 #chan3] \
				account5 [list #chan5] \
			] \
		] \
		[dict create \
			description "multiple accounts set up, extra stuff in file outside of section" \
			input "junk=#hi\n\[account-to-channel-mapping\]\n; test comment\n; another\naccount1 = #chan1\naccount2 = #chan1,#chan2, #chaN3\naccounT1=#chan4\n; another account\nAccount5=#chan5" \
			expected [dict create \
				account1 [list #chan4] \
				account2 [list #chan1 #chan2 #chan3] \
				account5 [list #chan5] \
			] \
		] \
	]

	foreach test $tests {
		set fh [open $tmpfile w]
		if {[string length [dict get $test input]] > 0} {
			puts -nonewline $fh [dict get $test input]
		}
		close $fh

		::twitter::load_config

		set got $::twitter::account_to_channels
		set expected [dict get $test expected]

		if {[dict size $got] != [dict size $expected]} {
			puts "Test failed: [dict get $test description]: Different number of keys"
			return 0
		}

		foreach key [dict keys $expected] {
			if {![dict exists $got $key]} {
				puts "Test failed: [dict get $test description]: Key $key is missing"
				return 0
			}

			set got_chans [dict get $got $key]
			set expected_chans [dict get $expected $key]
			if {$got_chans != $expected_chans} {
				puts "Test failed: [dict get $test description]: Key $key is '$got_chans', wanted '$expected_chans'"
				return 0
			}
		}
	}

	return 1
}

proc ::test_save_config {} {
	set tests [list \
		[dict create \
			description "no accounts" \
			map [dict create] \
			content_before "" \
			content_after "" \
		] \
		[dict create \
			description "no accounts, wipe out old" \
			map [dict create] \
			content_before "; a comment\n\[account-to-channel-mapping\]\n; another comment\n" \
			content_after "; a comment\n\n\[account-to-channel-mapping\]\n" \
		] \
		[dict create \
			description "one account, no change" \
			map [dict create \
				account1 [list #chan1] \
			] \
			content_before "; a comment\n\[account-to-channel-mapping\]\n; another comment\naccount1 = #chan1\n" \
			content_after "; a comment\n\n\[account-to-channel-mapping\]\n; another comment\naccount1=#chan1\n" \
		] \
		[dict create \
			description "one account, removes old" \
			map [dict create \
				account1 [list #chan1] \
			] \
			content_before "; a comment\n\[account-to-channel-mapping\]\n; another comment\naccount2 = #chan2\naccount3=#chan3" \
			content_after "; a comment\n\n\[account-to-channel-mapping\]\naccount1=#chan1\n" \
		] \
		[dict create \
			description "multiple accounts" \
			map [dict create \
				account1 [list #chan1 #chan2] \
				account2 [list #chan3 #chan4] \
			] \
			content_before "; a comment\n\[account-to-channel-mapping\]\n; another comment\naccount2 = #chan2\naccount3=#chan3" \
			content_after "; a comment\n\n\[account-to-channel-mapping\]\naccount1=#chan1,#chan2\n; another comment\naccount2=#chan3,#chan4\n" \
		] \
	]

	set tmpfile /tmp/twitter-tests.bin
	if {[file exists $tmpfile]} {
		file delete $tmpfile
	}
	set ::twitter::config_file $tmpfile

	foreach test $tests {
		set ::twitter::account_to_channels [dict get $test map]

		set fh [open $tmpfile w]
		puts -nonewline $fh [dict get $test content_before]
		close $fh

		::twitter::save_config

		set fh [open $tmpfile r]
		set content [read -nonewline $fh]
		close $fh

		if {$content != [dict get $test content_after]} {
			puts "Test failed: [dict get $test description]: Content is $content, wanted [dict get $test content_after]"
			return 0
		}
	}

	return 1
}

proc ::test_output_updates {} {
	set tests [list \
		[dict create \
			description "no mappings, no channels +twitter" \
			channels [list #one #two] \
			channels_plustwitter [list] \
			mappings [dict create] \
			statuses [list \
				[dict create screen_name acct1 id 1 text hi] \
			] \
			expected [dict create] \
		] \
		[dict create \
			description "no mappings, all channels +twitter" \
			channels [list #one #two] \
			channels_plustwitter [list #one #two] \
			mappings [dict create] \
			statuses [list \
				[dict create screen_name acct1 id 1 text hi] \
			] \
			expected [dict create 1 [list #one #two]] \
		] \
		[dict create \
			description "mapping present but empty, all channels +twitter" \
			channels [list #one #two] \
			channels_plustwitter [list #one #two] \
			mappings [dict create acct1 [list]] \
			statuses [list \
				[dict create screen_name acct1 id 1 text hi] \
			] \
			expected [dict create 1 [list #one #two]] \
		] \
		[dict create \
			description "mapping present, one channel that is +twitter" \
			channels [list #one #two] \
			channels_plustwitter [list #one #two] \
			mappings [dict create acct1 [list #one]] \
			statuses [list \
				[dict create screen_name acct1 id 1 text hi] \
			] \
			expected [dict create 1 [list #one]] \
		] \
		[dict create \
			description "mapping present, two channels that are +twitter, one isn't" \
			channels [list #one #two #three] \
			channels_plustwitter [list #one #two] \
			mappings [dict create acct1 [list #one #two #three]] \
			statuses [list \
				[dict create screen_name acct1 id 1 text hi] \
			] \
			expected [dict create 1 [list #one #two]] \
		] \
	]

	foreach test $tests {
		global channels_result
		set channels_result [dict get $test channels]

		global channel_to_plustwitter
		set channel_to_plustwitter [dict create]
		foreach ch [dict get $test channels_plustwitter] {
			dict set channel_to_plustwitter $ch 1
		}

		set ::twitter::account_to_channels [dict get $test mappings]

		set got [::twitter::output_updates [dict get $test statuses]]

		foreach key [dict keys [dict get $test expected]] {
			if {![dict exists $got $key]} {
				puts "Test failed: [dict get $test description]: Key $key does not exist"
				return 0
			}

			set got_channels [dict get $got $key]
			set expected_channels [dict get $test expected $key]

			if {$got_channels != $expected_channels} {
				puts "Test failed: [dict get $test description]: Key $key is $got_channels, wanted $expected_channels"
				return 0
			}
		}
	}

	return 1
}

# Dummy the eggdrop function channels.
set channels_result [list]
proc channels {} {
	global channels_result
	return $channels_result
}

# Dummy the eggdrop function channel
set channel_to_plustwitter [dict create]
proc channel {command channel flag} {
	global channel_to_plustwitter
	if {[dict exists $channel_to_plustwitter $channel]} {
		return 1
	}
	return 0
}

if {![::main]} {
	exit 1
}
