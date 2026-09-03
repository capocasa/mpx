import std/[unittest, os, osproc, strutils]
import mpxlib/[protocol, pty, session]
import ttty/[terminal, grid]

# Protocol tests
test "socketPath":
  putEnv("XDG_RUNTIME_DIR", "/tmp")
  let path = socketPath("test")
  check "mpx" in path
  check "test.sock" in path

test "resolveSession named passes through":
  check resolveSession("work") == "work"

test "resolveSession auto number":
  let dir = getTempDir() / "mpx_test_sessions"
  removeDir(dir)
  createDir(dir / "mpx")
  putEnv("XDG_RUNTIME_DIR", dir)
  check resolveSession("") == "1"
  writeFile(dir / "mpx" / "1.sock", "")
  writeFile(dir / "mpx" / "foo.sock", "")
  check resolveSession("") == "2"
  writeFile(dir / "mpx" / "2.sock", "")
  check resolveSession("") == "3"
  removeDir(dir)

test "requireSession rejects empty":
  expect(ValueError):
    discard requireSession("")
  check requireSession("x") == "x"

test "isActive false for missing socket":
  putEnv("XDG_RUNTIME_DIR", getTempDir())
  check not isActive("definitely_not_a_session_xyz")

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
