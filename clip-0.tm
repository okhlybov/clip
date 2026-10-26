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
#     { {opt(s)} -slot name -default value -global 1 -info "text" -section {name} -apply {script} -defs {...} }
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
#   -global   a true value marks an option to be passed through into every
#             nested subcommand
#   -info     description shown by ::clip::usage
#   -section  usage section the option belongs to; options with a section
#             not requested by ::clip::usage are listed as generic
#   -apply    script run as the body of a {slot value} lambda one level
#             below parse; upvar 2 / uplevel 2 reach the frame that called
#             parse, which is what the built-in assignment does, so wrapping
#             parse in a helper proc redirects the assignments into that
#             helper instead
#   -defs     option definitions of a subcommand, see below
#
#   Subcommands: a definition whose spellings do not start with - declares
#   subcommand names, ex.
#
#     {remote -slot cmd1 -info {manage remotes} -defs {...}}
#
#   its -defs hold the options and the further nested subcommands of that
#   command. When the first positional argument matches a subcommand, the
#   def-set switches over to it, the slot receives the chosen name and
#   parsing continues, so
#
#     mytool -C /x remote add -f foo
#
#   with -C global parses as dir=/x, cmd1=remote, cmd2=add, force=1 and
#   positionals {foo}. Rules:
#   - only the first positional argument of each level selects a command;
#     an unmatched one is an error when commands are defined at that level
#   - a lone dash and negative numbers are ordinary positionals and
#     consume the first-positional slot; -- ends command matching along
#     with option parsing
#   - global options of all levels stay recognized below; a name collision
#     with the subcommand's own options is an error
#   - command names and option names share one namespace
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
#
# ::clip::usage defs ?sections? ?chan? ?path?
#
#   Renders the usage text; path, ex. {remote add}, drills down into a
#   subcommand carrying the global options along, for implementing
#   "mytool help remote add".


package require Tcl 8.6-


namespace eval ::clip {

  namespace export parse usage


  # errors carry a machine readable -errorCode, ex. {CLIP badopt}:
  #   badopt  unrecognized option, argument or command
  #   noval   value missing for an option expecting one
  #   badval  value supplied to a parameterless option
  #   baddef  malformed or conflicting option definition
  proc Fail {tag msg} {
    return -code error -errorCode [list CLIP $tag] $msg
  }


  # defs: { { opt(s) } -slot opt -default value -global 1 -info "text" -section {common} -apply {script} -defs {...} }
  proc parse {argv defs} {
    lassign [NormalizeDefs $defs] short_flags short_opts long_flags long_opts commands
    set globals {}
    MergeGlobals globals short_flags short_opts long_flags long_opts
    lassign [OptionSets $short_flags $short_opts] flagset optset
    set xargs {}
    set first 1
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
        set first 0
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
          set first 0
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
        set first 0
        continue
      }
      # stray -flag
      if {[string match -* $x]} {
        Fail badopt "unrecognized argument $x"
      }
      # the first positional argument selects a subcommand when one matches
      if {$first && [llength $commands]} {
        set d [FindDef $commands $x]
        if {$d ne {}} {
          apply [dict get $d apply] [dict get $d slot] [dict get $d bare]
          # switch the def-set over to the subcommand; the options keep
          # applying from this same frame, so the assignment mechanism
          # is unaffected by the nesting depth
          lassign [NormalizeDefs [dict get $d defs]] short_flags short_opts long_flags long_opts commands
          MergeGlobals globals short_flags short_opts long_flags long_opts
          lassign [OptionSets $short_flags $short_opts] flagset optset
          set first 1
          continue
        }
        Fail badopt "unknown command $x"
      }
      # the rest arguments are passed through
      lappend xargs $x
      set first 0
    }
    return $xargs
  }


  proc FindDef {defs tag} {
    foreach d $defs {
      if {$tag eq [dict get $d bare]} { return $d }
    }
    return {}
  }


  # build the coalesced-set lookup tables of a def-set
  proc OptionSets {short_flags short_opts} {
    set flagset [dict create]
    foreach f $short_flags {
      dict set flagset [dict get $f bare] $f
    }
    set optset [dict create]
    foreach o $short_opts {
      dict set optset [dict get $o bare] $o
    }
    return [list $flagset $optset]
  }


  # fold the global options of a def-set into the pass-through set and, in
  # turn, the pass-through set into the def-set; any name collision is an
  # error. Runs on entry and on every subcommand switch
  proc MergeGlobals {globalsVar sf so lf lo} {
    upvar $globalsVar globals
    upvar $sf short_flags
    upvar $so short_opts
    upvar $lf long_flags
    upvar $lo long_opts
    set own {}
    foreach e [concat $short_flags $short_opts $long_flags $long_opts] {
      if {![dict get $e global]} { continue }
      set bare [dict get $e bare]
      foreach g [concat $globals $own] {
        if {[dict get $g bare] eq $bare} {
          Fail baddef "global option -$bare is defined more than once"
        }
      }
      lappend own $e
    }
    foreach g $globals {
      set bare [dict get $g bare]
      if {[FindDef [concat $short_flags $short_opts $long_flags $long_opts] $bare] ne {}} {
        Fail baddef "global option -$bare conflicts with the subcommand's own option of the same name"
      }
      lappend [dict get $g kind] $g
    }
    set globals [concat $globals $own]
  }


  # render the usage text; path optionally drills down into a subcommand,
  # ex. remote add, carrying the global options along
  proc usage {defs {sections {}} {chan stdout} {path {}}} {
    set globals {}
    foreach name $path {
      lassign [NormalizeDefs [concat $globals $defs]] sf so lf lo cmds
      foreach def $defs {
        if {[Global $def]} { lappend globals $def }
      }
      set d [FindDef $cmds $name]
      if {$d eq {}} { Fail badopt "unknown command $name" }
      set defs [dict get $d defs]
    }
    set defs [concat $globals $defs]
    NormalizeDefs $defs
    set padding [ComputePadding $defs]
    dict for {section info} $sections {
      PrintSection [ExtractSectionDefs defs $section] $info $chan $padding
    }
    PrintSection [ExtractCommandDefs defs] "Commands" $chan $padding
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


  proc ExtractCommandDefs {defsVar} {
    upvar $defsVar defs
    set rest [list]
    set cmds [list]
    foreach def $defs {
      if {[string match -* [lindex [Opts $def] 0]]} {
        lappend rest $def
      } else {
        lappend cmds $def
      }
    }
    set defs $rest
    return $cmds
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
      if {$el ni {-slot -default -global -info -section -apply -defs} &&
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


  # -global marks an option to be passed through into nested subcommands
  proc Global {def} {
    set d [Dict $def]
    if {[dict exists $d -global]} { return [dict get $d -global] }
    return 0
  }


  # -defs holds the option definitions of a subcommand
  proc Defs {def} {
    set d [Dict $def]
    if {[dict exists $d -defs]} { return [dict get $d -defs] }
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
  # Definitions whose spellings do not start with - declare subcommands
  proc NormalizeDefs {defs} {
    set short_flags {}
    set short_opts {}
    set long_flags {}
    set long_opts {}
    set commands {}
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
      # keep the keyword list in sync with SplitDef
      foreach {key value} $d {
        if {$key ni {-slot -default -global -info -section -apply -defs}} {
          Fail baddef "unknown attribute $key in option definition [list $def]"
        }
      }
      set slot [Slot $def]
      set sawopt 0
      set sawcmd 0
      foreach opt $opts {
        set bare [string trimright [string trimleft $opt -] =]
        if {[dict exists $seen $bare]} {
          Fail baddef "option $opt redefines [dict get $seen $bare]"
        }
        dict set seen $bare $opt
        if {$slot eq {}} { set slot $bare }
        if {[string match -* $opt]} {
          if {$sawcmd} {
            Fail baddef "cannot mix command names and option descriptors in one definition [list $def]"
          }
          set sawopt 1
          switch -regexp $opt {
            {^-[[:alnum:]]$} { set kind short_flags }
            {^-[[:alnum:]]=$} { set kind short_opts }
            {^-[[:alnum:]][[:alnum:]\-\_]*$} { set kind short_flags }
            {^-[[:alnum:]][[:alnum:]\-\_]*=$} { set kind short_opts }
            {^-+[[:alnum:]][[:alnum:]\-\_]*$} { set kind long_flags }
            {^-+[[:alnum:]][[:alnum:]\-\_]*=$} { set kind long_opts }
            default { Fail baddef "failed to decode option descriptor $opt" }
          }
          lappend $kind [dict create bare $bare slot $slot default [Default $def] apply [Apply $def] info [Info $def] section [Section $def] global [Global $def] kind $kind]
        } else {
          if {$sawopt} {
            Fail baddef "cannot mix command names and option descriptors in one definition [list $def]"
          }
          set sawcmd 1
          if {![regexp {^[[:alnum:]][[:alnum:]\-\_]*$} $opt]} {
            Fail baddef "failed to decode option descriptor $opt"
          }
          lappend commands [dict create bare $bare slot $slot apply [Apply $def] info [Info $def] section [Section $def] defs [Defs $def]]
        }
      }
    }
    return [list $short_flags $short_opts $long_flags $long_opts $commands]
  }


}
