#!/usr/bin/env tclsh
# Tests for clip-0.tm, run with:  tclsh clip-0.test.tcl

package require tcltest 2
namespace import ::tcltest::*

tcl::tm::path add [file normalize [file dirname [info script]]]
package require clip

proc usageText {defs {sections {}}} {
  set chan [file tempfile path]
  ::clip::usage $defs $sections $chan
  close $chan
  set chan [open $path r]
  set text [read $chan]
  close $chan
  file delete $path
  return $text
}

# --- parsing ----------------------------------------------------------------

test clip-1.1 {flag: short and long spellings} -body {
  set v 0
  set pos [::clip::parse {-v --verbose foo} {{{-v --verbose} -info verbosity}}]
  list $v $pos
} -result {1 foo}

test clip-1.2 {option: separate value} -body {
  set n {}
  set pos [::clip::parse {-n 5 rest} {{{-n= --number=}}}]
  list $n $pos
} -result {5 rest}

test clip-1.3 {option: inline value} -body {
  set n {}
  ::clip::parse {-n=5 --number=6} {{{-n= --number=}}}
  set n
} -result 6

test clip-1.4 {coalesced flags, glued value, option mid-set} -body {
  set a 0; set b 0; set o {}; set S 0
  ::clip::parse {-ab} {{{-a}} {{-b}}}
  ::clip::parse {-oFILE} {{{-o= --output}}}
  set r1 "a=$a b=$b o=$o"
  set o {}
  ::clip::parse {-SoX} {{{-S}} {{-o=}}}
  list $r1 "S=$S o=$o"
} -result {{a=1 b=1 o=FILE} {S=1 o=X}}

test clip-1.5 {terminator, lone dash, negative numbers} -body {
  set v 0
  set pos [::clip::parse {-v -- -3 -3.5 -.5 - foo} {{{-v}}}]
  list $v $pos
} -result {1 {-3 -3.5 -.5 - foo}}

test clip-1.6 {last occurrence wins} -body {
  set n {}
  ::clip::parse {-n 1 -n 2} {{{-n=}}}
  set n
} -result 2

test clip-1.7 {flag receives -default when present} -body {
  set s off
  ::clip::parse {-S} {{{-S --strict} -slot s -default on}}
  set s
} -result on

test clip-1.8 {flag absent leaves variable untouched} -body {
  set s 0
  ::clip::parse {} {{{-S --strict} -slot s}}
  set s
} -result 0

test clip-1.9 {custom -apply reaches the caller via upvar 2} -body {
  set x 0
  ::clip::parse {-n 5} {{{-n=} -slot x -apply {upvar 2 $slot y; set y [expr {$value + 1}]}}}
  set x
} -result 6

test clip-1.10 {auto slot is the bare name, case exact} -body {
  unset -nocomplain S
  ::clip::parse {-SoX} {{{-S}} {{-o=}}}
  set S
} -result 1

test clip-1.11 {option value consumes the next token even if option-like} -body {
  set o {}
  ::clip::parse {-o -v} {{{-o=}} {{-v}}}
  set o
} -result {-v}

test clip-1.12 {a defined numeric option wins over the numeric passthrough} -body {
  unset -nocomplain one
  set pos [::clip::parse {-1 rest} {{{-1 --one} -slot one}}]
  list $one $pos
} -result {1 rest}

test clip-1.13 {single and double dash spellings are interchangeable} -body {
  set filter 0; set long 0
  ::clip::parse {--filter -long} {{{-filter}} {{--long}}}
  list $filter $long
} -result {1 1}

test clip-1.14 {empty glued value yields empty string} -body {
  set o KEEP
  ::clip::parse {-o=} {{{-o=}}}
  set o
} -result {}

# --- parse errors -----------------------------------------------------------

test clip-2.1 {missing value} -body {
  set rc [catch {::clip::parse {-o} {{{-o=}}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {missing value for option -o} {CLIP noval}}

test clip-2.2 {unrecognized option with inline value} -body {
  set rc [catch {::clip::parse {--xyz=1} {{{-v}}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {unrecognized option in --xyz=1} {CLIP badopt}}

test clip-2.3 {unrecognized option} -body {
  set rc [catch {::clip::parse {--xyz} {{{-v}}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {unrecognized argument --xyz} {CLIP badopt}}

test clip-2.4 {unrecognized coalesced flag} -body {
  set rc [catch {::clip::parse {-Sax} {{{-S}}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {unrecognized short flag -a} {CLIP badopt}}

test clip-2.5 {value supplied to a flag} -body {
  set rc [catch {::clip::parse {-S=1} {{{-S --strict}}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {option -S takes no value} {CLIP badval}}

test clip-2.6 {options applied before an error stay applied} -body {
  unset -nocomplain v
  set rc [catch {::clip::parse {-v -o} {{{-v}} {{-o=}}}} msg]
  list $rc $msg [info exists v]
} -result {1 {missing value for option -o} 1}

# --- definition errors ------------------------------------------------------

test clip-3.1 {duplicate option spelling is an error} -body {
  set rc [catch {::clip::parse {} {{{-n= --number}} {{-n}}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {option -n redefines -n=} {CLIP baddef}}

test clip-3.2 {odd attribute tail is an error} -body {
  set rc [catch {::clip::parse {} {{{-v} -slot}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {malformed option definition {{-v} -slot}: expected option spellings followed by -key value pairs} {CLIP baddef}}

test clip-3.3 {typoed attribute derails into malformed definition} -body {
  set rc [catch {::clip::parse {} {{{-v} -Default 1}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {malformed option definition {{-v} -Default 1}: expected option spellings followed by -key value pairs} {CLIP baddef}}

test clip-3.4 {unknown attribute is an error} -body {
  set rc [catch {::clip::parse {} {{{-v} -info x garbage y}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {unknown attribute garbage in option definition {{-v} -info x garbage y}} {CLIP baddef}}

test clip-3.5 {descriptor without a leading dash is an error} -body {
  set rc [catch {::clip::parse {} {{{a-b}}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {failed to decode option descriptor a-b} {CLIP baddef}}

test clip-3.6 {definition without option descriptors is an error} -body {
  set rc [catch {::clip::parse {} {{{} -info nothing}}} msg opt]
  list $rc $msg [dict get $opt -errorCode]
} -result {1 {missing option descriptors in {{} -info nothing}} {CLIP baddef}}

test clip-3.7 {unbraced spellings and attributes are healed} -body {
  unset -nocomplain num
  ::clip::parse {-n 42 --number=43} {{-n= --number= -slot num -info number}}
  set num
} -result 43

test clip-3.8 {multi spelling definition without attributes} -body {
  set v 0
  ::clip::parse {--verbose} {{{-v --verbose}}}
  set v
} -result 1

# --- usage ------------------------------------------------------------------

test clip-4.1 {usage: sections extracted, rest under generic} -body {
  set text [usageText {
    {{-v --verbose} -info {enable chatter}}
    {{--output= -o} -slot out -info {output file}}
    {{-h --help} -section Help -info {show this text}}
  } [dict create Help {Further help}]]
  list [string match {*\* Further help:*-h, --help*show this text*} $text] \
       [string match {*\* Generic options:*--verbose*enable chatter*--output*<arg>*} $text]
} -result {1 1}

test clip-4.2 {usage: option column is left aligned} -body {
  set text [usageText {{{-v --verbose} -info chatter} {{--output= -o} -info file}}]
  set lines [split $text \n]
  set indented [lsearch -regexp $lines {^[ \t]+-}]
  set flush [lsearch -regexp $lines {^-}]
  expr {$indented == -1 && $flush > -1}
} -result 1

test clip-4.3 {section matching is string exact} -body {
  set defs {{{-x} -section 007 -info xopt}}
  set a [usageText $defs [dict create 007 Sec]]
  set b [usageText $defs [dict create 7 Sec]]
  list [string match {*\* Sec:*} $a] [string match {*\* Generic options:*} $b]
} -result {1 1}

# --- misc -------------------------------------------------------------------

test clip-5.1 {parse and usage are exported} -body {
  lsort [namespace eval ::clip {namespace export}]
} -result {parse usage}

cleanupTests
