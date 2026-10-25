# clip - a command line parser for Tcl
# https://github.com/okhlybov/testme
#
# ::clip::parse argv defs
#
#   Parses argv against defs, returns the positional arguments and assigns
#   option values into the frame that called parse, see -apply below.
#
#   defs is a list of definitions, each of the form
#
#     { {opt(s)} -slot name -default value -info "text" -section {name} -apply {script} }
#
#   {opt(s)}  one or more spellings of the option, ex. {-v --verbose};
#             a trailing = marks an option taking a value, ex. -o=, --name=;
#             the spellings may also be given unbraced, a definition is
#             scanned up to the first attribute keyword
#   -slot     variable to assign, defaults to the bare name of the first
#             spelling, case exact
#   -default  the value a flag receives when given, default 1; options
#             taking a value always read it from argv, so their -default is
#             ignored; flags left off the command line leave the variable
#             untouched, preinitialize it in the caller as needed
#   -info     description shown by ::clip::usage
#   -section  usage section the option belongs to; options with a section
#             not requested by ::clip::usage are listed as generic
#   -apply    script run as the body of a {slot value} lambda one level
#             below parse; upvar 2 / uplevel 2 reach the frame that called
#             parse, which is what the built-in assignment does, so wrapping
#             parse in a helper proc redirects the assignments into that
#             helper instead
#
#   Syntax:
#   - -- terminates option parsing, everything after it is positional
#   - a lone - is positional, ex. the conventional stdin/stdout marker
#   - single letter flags may be coalesced, ex. -Sxy; the first option met
#     in the set consumes the rest of the token as its value, ex. -oFILE
#   - multi letter options must come on their own, ex. -foo, --foo; the
#     single and double dash spellings are interchangeable; they never
#     coalesce and never take a glued value (write -foo=v or -foo v)
#   - an option value is always the next token even if it reads as an option
#   - tokens reading as negative numbers, ex. -3, -3.5, -.5, are positional
#   - options are applied as encountered, the last occurrence wins; a parse
#     error leaves the options applied so far in place
#   - the attribute keywords are reserved and cannot be option spellings
#     outside the first position of a definition
#   - defining an option spelling more than once is an error


package require Tcl 8.6-


namespace eval ::clip {

  namespace export parse usage


  # errors carry a machine readable -errorCode, ex. {CLIP badopt}:
  #   badopt  unrecognized option or argument
  #   noval   value missing for an option expecting one
  #   badval  value supplied to a parameterless option
  #   baddef  malformed or conflicting option definition
  proc Fail {tag msg} {
    return -code error -errorCode [list CLIP $tag] $msg
  }


  # defs: { { opt(s) } -slot opt -default value -info "text" -section {common} -apply {script} }
  proc parse {argv defs} {
    lassign [NormalizeDefs $defs] short_flags short_opts long_flags long_opts
    set flagset [dict create]
    foreach f $short_flags {
      dict set flagset [dict get $f bare] $f
    }
    set optset [dict create]
    foreach o $short_opts {
      dict set optset [dict get $o bare] $o
    }
    set xargs {}
    set opts $argv
    while {[llength $opts]} {
      set x [lindex $opts 0]
      set opts [lrange $opts 1 end]
      # option terminator: everything that follows is positional,
      # recognized only here, never by the argv pre-scan
      if {$x eq "--"} {
        lappend xargs {*}$opts
        break
      }
      # a lone dash is positional, ex. the conventional stdin/stdout marker
      if {$x eq "-"} {
        lappend xargs $x
        continue
      }
      # option with inline value, ex. --abc=123, -n=5
      if {[regexp {^--?([[:alnum:]][[:alnum:]\-\_]*)=(.*)$} $x ~ tag value]} {
        if {[set d [FindDef [concat $long_opts $short_opts] $tag]] ne {}} {
          apply [dict get $d apply] [dict get $d slot] $value
          continue
        }
        if {[FindDef [concat $long_flags $short_flags] $tag] ne {}} {
          Fail badval "option [string range $x 0 [expr {[string first = $x]-1}]] takes no value"
        }
        Fail badopt "unrecognized option in $x"
      }
      # long/short option expecting separate value, ex. --abc 123
      if {[regexp {^--?([[:alnum:]][[:alnum:]\-\_]*)$} $x ~ tag]} {
        if {[set d [FindDef [concat $long_opts $short_opts] $tag]] ne {}} {
          if {![llength $opts]} { Fail noval "missing value for option $x" }
          apply [dict get $d apply] [dict get $d slot] [lindex $opts 0]
          set opts [lrange $opts 1 end]
          continue
        }
      }
      # long/short separate flag, ex. -C,  --create
      if {[regexp {^--?([[:alnum:]][[:alnum:]\-\_]*)$} $x ~ tag]} {
        if {[set d [FindDef [concat $long_flags $short_flags] $tag]] ne {}} {
          apply [dict get $d apply] [dict get $d slot] [dict get $d default]
          continue
        }
      }
      # short flags within the coalesced flag set, ex. -Sxy; the first
      # option met in the set consumes the rest of the token as its
      # value, ex. -oFILE
      if {[regexp {^-([[:alnum:]]+)$} $x ~ flags]} {
        # a leading digit reads as a negative number, ex. -3
        if {[string is digit [string index $flags 0]]} {
          lappend xargs $x
          continue
        }
        set pos 0
        foreach flag [split $flags {}] {
          incr pos
          if {[dict exists $flagset $flag]} {
            set d [dict get $flagset $flag]
            apply [dict get $d apply] [dict get $d slot] [dict get $d default]
            continue
          }
          if {[dict exists $optset $flag]} {
            set d [dict get $optset $flag]
            set rest [string range $flags $pos end]
            if {$rest eq {}} {
              if {![llength $opts]} { Fail noval "missing value for option -$flag" }
              set rest [lindex $opts 0]
              set opts [lrange $opts 1 end]
            }
            apply [dict get $d apply] [dict get $d slot] $rest
            break
          }
          if {$pos == 1} {
            # A multi letter token matching no whole option is reported whole
            # (ex. a stray -filter), only a genuine coalesced set reports
            # the offending single flag
            Fail badopt "unrecognized argument $x"
          }
          Fail badopt "unrecognized short flag -$flag"
        }
        continue
      }
      # a token reading as a negative number passes through, ex. -3.5, -.5
      if {[regexp {^-\.?\d} $x]} {
        lappend xargs $x
        continue
      }
      # stray -flag
      if {[string match -* $x]} {
        Fail badopt "unrecognized argument $x"
      }
      # the rest arguments are passed through
      lappend xargs $x
    }
    return $xargs
  }


  proc FindDef {defs tag} {
    foreach d $defs {
      if {$tag eq [dict get $d bare]} { return $d }
    }
    return {}
  }


  #
  proc usage {defs {sections {}} {chan stdout}} {
    set padding [ComputePadding $defs]
    dict for {section info} $sections {
      PrintSection [ExtractSectionDefs defs $section] $info $chan $padding
    }
    PrintSection $defs "Generic options" $chan $padding
  }


  proc ComputePadding {defs} {
    set pad 0
    foreach def $defs {
      set x [string length [FormatOpts [Opts $def]]]
      if {$x > $pad} { set pad $x }
    }
    return $pad
  }


  proc ExtractSectionDefs {defsVar section} {
    upvar $defsVar defs
    set rest [list]
    set filtered [list]
    foreach def $defs {
      if {[Section $def] eq $section} {
        lappend filtered $def
      } else {
        lappend rest $def
      }
    }
    set defs $rest
    return $filtered
  }


  proc FormatOpts {opts} {
    set arg 0
    set x [lmap opt $opts {
      if {[string match *= $opt]} { set arg 1 }
      string trimright $opt =
    }]
    set x [join $x {, }]
    if {$arg} { set x "$x <arg>" }
    return $x
  }


  proc PrintSection {defs info chan padding} {
    if {[llength $defs]} {
      incr padding 2
      if {$info ne {}} { puts $chan "\n* $info:\n" }
      foreach def $defs {
        set opts [format %-${padding}s [FormatOpts [Opts $def]]]
        puts $chan "$opts    [Info $def]"
      }
    }
  }


  proc SplitDef {def} {
    # Option spellings: the first element plus any further leading elements
    # that decode as option descriptors without being attribute keywords;
    # this heals unbraced spellings, ex. {-v --verbose -info "text"}.
    # Returns {spelling(s) attribute(s)}
    set opts [lindex $def 0]
    set n [llength $def]
    set i 1
    while {$i < $n} {
      set el [lindex $def $i]
      if {$el ni {-slot -default -info -section -apply} &&
          [regexp {^-+[[:alnum:]][[:alnum:]\-\_]*=?$} $el]} {
        lappend opts $el
        incr i
      } else {
        break
      }
    }
    return [list $opts [lrange $def $i end]]
  }


  proc Opts {def} { lindex [SplitDef $def] 0 }


  proc Dict {def} { lindex [SplitDef $def] 1 }


  # -default is the value a flag receives when given; options taking a
  # value always read it from argv, so their -default is ignored
  proc Default {def} {
    set d [Dict $def]
    if {[dict exists $d -default]} { return [dict get $d -default] }
    return 1
  }


  proc Section {def} {
    set d [Dict $def]
    if {[dict exists $d -section]} { return [dict get $d -section] }
    return {}
  }


  proc Info {def} {
    set d [Dict $def]
    if {[dict exists $d -info]} { return [dict get $d -info] }
    return {}
  }


  proc Slot {def} {
    set d [Dict $def]
    if {[dict exists $d -slot]} { return [dict get $d -slot] }
    return {}
  }


  # -apply scripts run as the body of a {slot value} lambda directly below
  # parse; upvar 2 / uplevel 2 reach the frame that called parse
  proc Apply {def} {
    set d [Dict $def]
    if {[dict exists $d -apply]} {
      return [list {slot value} [dict get $d -apply]]
    }
    # The default sets a variable in the frame that called ::clip::parse,
    # two levels up from this lambda; wrapping parse in a helper proc
    # redirects the assignment into that wrapper instead
    return {{slot value} { upvar 2 $slot x; set x $value }}
  }


  # Flags are the parameterless options which receive their -default value
  # when set, ex. -S
  # Single letter flags may be coalesced, ex. -Sxyz
  # Multi letter options must come on their own, ex. -foo, --foo;
  # the single dash multi letter form is a first-class short spelling:
  # the option namespace is thereby not capped at the alphabet,
  # at the price of never coalescing and never taking a glued value
  # (write -foo=v or -foo v)
  proc NormalizeDefs {defs} {
    set short_flags {}
    set short_opts {}
    set long_flags {}
    set long_opts {}
    set seen [dict create]
    foreach def $defs {
      set opts [Opts $def]
      set d [Dict $def]
      if {[llength $opts] == 0} {
        Fail baddef "missing option descriptors in [list $def]"
      }
      if {[llength $d] % 2} {
        Fail baddef "malformed option definition [list $def]: expected option spellings followed by -key value pairs"
      }
      # keep the keyword list in sync with Opts
      foreach {key value} $d {
        if {$key ni {-slot -default -info -section -apply}} {
          Fail baddef "unknown attribute $key in option definition [list $def]"
        }
      }
      set slot [Slot $def]
      foreach opt $opts {
        set bare [string trimright [string trimleft $opt -] =]
        if {[dict exists $seen $bare]} {
          Fail baddef "option $opt redefines [dict get $seen $bare]"
        }
        dict set seen $bare $opt
        if {$slot eq {}} { set slot $bare }
        switch -regexp $opt {
          {^-[[:alnum:]]$} { set kind short_flags }
          {^-[[:alnum:]]=$} { set kind short_opts }
          {^-[[:alnum:]][[:alnum:]\-\_]*$} { set kind short_flags }
          {^-[[:alnum:]][[:alnum:]\-\_]*=$} { set kind short_opts }
          {^-+[[:alnum:]][[:alnum:]\-\_]*$} { set kind long_flags }
          {^-+[[:alnum:]][[:alnum:]\-\_]*=$} { set kind long_opts }
          default { Fail baddef "failed to decode option descriptor $opt" }
        }
        lappend $kind [dict create bare $bare slot $slot default [Default $def] apply [Apply $def] info [Info $def] section [Section $def]]
      }
    }
    return [list $short_flags $short_opts $long_flags $long_opts]
  }


}
