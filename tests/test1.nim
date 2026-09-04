import std/[unittest, os, osproc, strutils]
import mpx/[protocol, pty, session, log, config]
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

# Config tests
suite "config":
  setup:
    let realCfg = getEnv("XDG_CONFIG_HOME")
    let dir = getTempDir() / "mpx_test_config"
    removeDir(dir)
    createDir(dir / "mpx")
    putEnv("XDG_CONFIG_HOME", dir)

  teardown:
    putEnv("XDG_CONFIG_HOME", realCfg)
    removeDir(dir)

  test "absent config file means defaults":
    check loadConfig().listen == ""
    check not loadConfig().log

  test "parse listen and log":
    let cfg = parseConfig("""
# comment
listen = 10.0.0.4:4534
log = true
""")
    check cfg.listen == "10.0.0.4:4534"
    check cfg.log

  test "log off variants":
    check not parseConfig("log = false").log
    check not parseConfig("log = no").log
    check not parseConfig("log = 0").log

  test "unknown keys ignored":
    let cfg = parseConfig("frobnicate = yes\nlisten = localhost:9000\n")
    check cfg.listen == "localhost:9000"

  test "loaded from config file":
    writeFile(dir / "mpx" / "config", "listen = 127.0.0.1:4534\nlog = true\n")
    let cfg = loadConfig()
    check cfg.listen == "127.0.0.1:4534"
    check cfg.log

  test "parseListen splits host and port":
    let (ip, port) = parseListen("10.0.0.4:4534")
    check ip.address_v4 == [byte 10, 0, 0, 4]
    check port == 4534

  test "parseListen rejects junk":
    expect(ValueError): discard parseListen("no-port-here")
    expect(ValueError): discard parseListen("host:0")
    expect(ValueError): discard parseListen("host:99999")
    expect(ValueError): discard parseListen(":1234")
    expect(ValueError): discard parseListen("10.0.0.4:notanumber")

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
    let l = initLogger()
    l.info "hello log"
    l.close()
    check not dirExists(dir / "mpx")

  test "enabled via initLogger(true)":
    let dir = getTempDir() / "mpx_test_data"
    removeDir(dir)
    putEnv("XDG_DATA_HOME", dir)
    let l = initLogger(true)
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
