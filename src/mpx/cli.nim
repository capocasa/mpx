## Command line parsing for mpx.
##
## Flags may appear anywhere: before, between, or after the positional
## arguments (`mpx -l 10.0.0.4:4534 daemon work` and `mpx daemon work -l
## 10.0.0.4:4534` mean the same). Anything dash-prefixed must be a known
## flag: unknown flags are an error, never a guess. Values live in the next
## argument or after `=`, so a value that itself starts with '-' must use
## the `=` form.

import std/strutils
import mpx/config

const
  UsageHint* = "usage: mpx --help"

  ListenFlags* = ["l", "listen"]
  PortFlags* = ["p", "port"]
  LogFlags* = ["log"]
  VersionFlags* = ["v", "version"]
  HelpFlags* = ["h", "help"]

  FlagDocs* = [
    ("  -l, --listen <host:port>", "also listen on TCP; base port: each session takes the next free one"),
    ("  -p, --port <port>", "TCP base port, overrides the port in --listen"),
    ("      --log", "append to $XDG_DATA_HOME/mpx/mpx-YYYY.log"),
    ("  -v, --version", "show version"),
    ("  -h, --help", "show this help"),
  ]

type
  Opts* = object
    listen*: string        # "host:port", "" for unix socket only
    port*: int             # explicit TCP base port, 0 when not given
    log*: bool
    version*: bool
    help*: bool
    sessions*: seq[string] # positionals: mode, session name, command

proc fail(msg: string): ref ValueError =
  newException(ValueError, msg)

proc parseBool(flag, value: string): bool =
  case value.toLowerAscii
  of "1", "true", "yes", "on": result = true
  of "0", "false", "no", "off": result = false
  else: raise fail(flag & " expects true/false, got: " & value)

proc parsePort(flag, value: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise fail(flag & " expects a port number, got: " & value)
  if result < 1 or result > 65535:
    raise fail(flag & " out of range (1..65535): " & value)

proc parseCliArgs*(args: seq[string]): Opts =
  ## Parse argv (without argv[0]). Raises ValueError on anything wrong.
  var i = 0
  while i < args.len:
    let arg = args[i]
    var
      name = ""
      inlineValue = ""
      hasInline = false
    if arg.startsWith("--") and arg.len > 2:
      let body = arg[2 ..^ 1]
      let eq = body.find('=')
      if eq >= 0:
        name = body[0 ..< eq]
        inlineValue = body[eq + 1 ..^ 1]
        hasInline = true
      else:
        name = body
    elif arg.startsWith('-') and arg.len > 1:
      let body = arg[1 ..^ 1]
      let eq = body.find('=')
      if eq >= 0:
        name = body[0 ..< eq]
        inlineValue = body[eq + 1 ..^ 1]
        hasInline = true
      else:
        name = body
    else:
      result.sessions.add arg
      inc i
      continue

    if name.len == 0:
      raise fail("invalid option: " & arg)
    let dashed = if arg.startsWith("--"): "--" & name else: "-" & name

    if name in ListenFlags:
      var v = ""
      if hasInline:
        v = inlineValue
      elif i + 1 < args.len and not args[i + 1].startsWith('-'):
        inc i
        v = args[i]
      else:
        raise fail(dashed & " expects a value (use " & dashed & "=<value> if the value starts with '-')")
      try:
        discard parseListen(v)
      except ValueError:
        raise fail("invalid " & dashed & " value: " & getCurrentExceptionMsg())
      result.listen = v
    elif name in PortFlags:
      var v = ""
      if hasInline:
        v = inlineValue
      elif i + 1 < args.len and not args[i + 1].startsWith('-'):
        inc i
        v = args[i]
      else:
        raise fail(dashed & " expects a value (use " & dashed & "=<value> if the value starts with '-')")
      result.port = parsePort(dashed, v)
    elif name in LogFlags:
      if hasInline:
        result.log = parseBool(dashed, inlineValue)
      else:
        result.log = true
    elif name in VersionFlags:
      if hasInline:
        raise fail(dashed & " does not take a value")
      result.version = true
    elif name in HelpFlags:
      if hasInline:
        raise fail(dashed & " does not take a value")
      result.help = true
    else:
      raise fail("unknown option: " & arg & ". " & UsageHint)
    inc i

proc toConfig*(o: Opts): Config =
  ## Merge --listen and --port into what daemon and client consume.
  result.log = o.log
  if o.listen.len == 0 and o.port != 0:
    result.listen = "0.0.0.0:" & $o.port
  elif o.listen.len > 0 and o.port != 0:
    result.listen = o.listen.rsplit(':', 1)[0] & ":" & $o.port
  else:
    result.listen = o.listen
