import std/[unittest, os, osproc, strutils]
import multiplexer/[protocol, pty]
import ttty/[terminal, grid]

# Protocol tests
test "socketPath":
  putEnv("XDG_RUNTIME_DIR", "/tmp")
  let path = socketPath("test")
  check "mpx" in path
  check "test.sock" in path

# PTY tests
test "pty roundtrip":
  let p = openPty("/bin/cat", [], 80, 24)
  let msg = "hello\n"
  discard p.write(msg.cstring, msg.len)
  sleep(50)
  var buf: array[256, char]
  let n = p.read(addr buf, buf.len)
  check n > 0
  let got = cast[string](buf[0..<n])
  check "hello" in got
  p.close()

# Snapshot tests (now in ttty)
test "renderAnsi empty":
  let term = newTerminal(80, 24, 0)
  let snap = term.grid.renderAnsi(80, 24)
  check snap.startsWith("\x1b[2J\x1b[H")
  check snap.endsWith("\x1b[0m")

test "renderAnsi with content":
  let term = newTerminal(80, 24, 0)
  term.write("hello")
  let snap = term.grid.renderAnsi(80, 24)
  check "hello" in snap

test "grid resize":
  let term = newTerminal(80, 24, 0)
  term.write("hello")
  term.grid.resize(40, 10)
  check term.grid.width == 40
  check term.grid.height == 10
  let snap = term.grid.renderAnsi(40, 10)
  check "hello" in snap
