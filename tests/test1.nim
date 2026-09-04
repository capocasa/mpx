import std/[unittest, os, osproc, strutils]
import mpx/[protocol, pty, session, log]
import ttty/[terminal, grid]

# Protocol tests
test "socketPath":
  putEnv("XDG_RUNTIME_DIR", "/tmp")
  let path = socketPath("test")
  check "mpx" in path
  check "test.sock" in path

test "resolveSession named passes through":
  check resolveSession("work") == "work"

test "defaultName is cwd basename":
  let realCwd = getCurrentDir()
  putEnv("HOME", "/nonexistent_home")
  setCurrentDir(getTempDir())
  check defaultName() == lastPathPart(getTempDir())
  setCurrentDir(realCwd)

suite "resolveSession":
  setup:
    let dir = getTempDir() / "mpx_test_sessions"
    removeDir(dir)
    createDir(dir / "mpx")
    putEnv("XDG_RUNTIME_DIR", dir)
    let realCwd = getCurrentDir()
    let realHome = getEnv("HOME")
    putEnv("HOME", "/nonexistent_home")
    setCurrentDir(getTempDir() / "mpx_test_sessions")

  teardown:
    setCurrentDir(realCwd)
    putEnv("HOME", realHome)
    let dir = getTempDir() / "mpx_test_sessions"
    removeDir(dir)

  test "empty name defaults to cwd basename":
    check resolveSession("") == "mpx_test_sessions"

  test "counter deconflicts":
    check resolveSession("") == "mpx_test_sessions"
    writeFile(dir / "mpx" / "mpx_test_sessions.sock", "")
    check resolveSession("") == "mpx_test_sessions0"
    writeFile(dir / "mpx" / "mpx_test_sessions0.sock", "")
    check resolveSession("") == "mpx_test_sessions1"

  test "unrelated session does not affect numbering":
    writeFile(dir / "mpx" / "foo.sock", "")
    check resolveSession("") == "mpx_test_sessions"

  test "homedir defaults to ~":
    let fakeHome = getTempDir() / "mpx_test_home"
    createDir(fakeHome)
    setCurrentDir(fakeHome)
    putEnv("HOME", fakeHome)
    check defaultName() == "~"
    setCurrentDir(getTempDir())
    removeDir(fakeHome)

suite "logging":
  test "disabled by default":
    let dir = getTempDir() / "mpx_test_data"
    removeDir(dir)
    putEnv("XDG_DATA_HOME", dir)
    putEnv("MPX_LOG", "")
    let l = initLogger()
    l.info "should not land anywhere"
    l.close()
    check not dirExists(dir / "mpx")

  test "enabled with MPX_LOG=1":
    let dir = getTempDir() / "mpx_test_data"
    removeDir(dir)
    putEnv("XDG_DATA_HOME", dir)
    putEnv("MPX_LOG", "1")
    let l = initLogger()
    l.info "hello log"
    l.close()
    check fileExists(l.path)
    check "hello log" in readFile(l.path)
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
