import std/[unittest, os, osproc, strutils, times]
import std/posix except SocketHandle
import mpx/[protocol, pty, session, log, config, cli, runtime]
import ttty/[terminal, grid]

# Protocol tests
test "socketPath":
  let path = socketPath("test")
  check "mpx" in path
  check "test.sock" in path
  check path == mpxDir() / "test.sock"

test "socketPath folds long names under sun_path":
  # macOS sun_path is 92 bytes; a deep TMPDIR plus a long name overflows it
  var sa: Sockaddr_un
  let limit = sa.sun_path.len
  let long = repeat("x", 300)
  let p = socketPath(long)
  check p.len < limit
  check p == socketPath(long)          # deterministic across processes
  check socketPath(long) != socketPath(long & "y")
  check p.splitFile.ext == ".sock"
  check "xxxx" in p                    # readable prefix survives the fold

test "resolveSession named passes through":
  check resolveSession("work") == "work"

test "defaultName is cwd basename":
  let realCwd = getCurrentDir()
  putEnv("HOME", "/nonexistent_home")
  setCurrentDir(getTempDir())
  check defaultName() == lastPathPart(getTempDir())
  setCurrentDir(realCwd)

# CLI tests
suite "cli":
  test "no flags means plain defaults":
    let o = parseCliArgs(@["daemon", "work"])
    check o.listen == ""
    check o.port == 0
    check not o.log
    check o.sessions == @["daemon", "work"]

  test "short and long listen":
    check parseCliArgs(@["daemon", "work", "-l", "10.0.0.4:4534"]).listen == "10.0.0.4:4534"
    check parseCliArgs(@["daemon", "work", "--listen", "10.0.0.4:4534"]).listen == "10.0.0.4:4534"
    check parseCliArgs(@["daemon", "work", "--listen=10.0.0.4:4534"]).listen == "10.0.0.4:4534"
    check parseCliArgs(@["-l", "10.0.0.4:4534", "daemon", "work"]).listen == "10.0.0.4:4534"

  test "port flag":
    check parseCliArgs(@["-p", "4534", "daemon"]).port == 4534
    check parseCliArgs(@["--port=9999", "daemon"]).port == 9999
    expect(ValueError):
      discard parseCliArgs(@["-p", "0", "daemon"])
    expect(ValueError):
      discard parseCliArgs(@["-p", "notanumber", "daemon"])

  test "log flag variants":
    check parseCliArgs(@["daemon", "--log"]).log
    check parseCliArgs(@["daemon", "--log=true"]).log
    check parseCliArgs(@["daemon", "--log=false"]).log == false
    expect(ValueError):
      discard parseCliArgs(@["daemon", "--log=maybe"])

  test "unknown flag errors":
    expect(ValueError):
      discard parseCliArgs(@["daemon", "--frobnicate"])
    expect(ValueError):
      discard parseCliArgs(@["daemon", "-x"])

  test "bare command owns the rest of argv":
    check parseCliArgs(@["3code", "-r"]).sessions == @["3code", "-r"]
    check parseCliArgs(@["sh", "-c", "echo hi"]).sessions == @["sh", "-c", "echo hi"]
    let o = parseCliArgs(@["-l", "10.0.0.4:4534", "3code", "-r"])
    check o.listen == "10.0.0.4:4534"
    check o.sessions == @["3code", "-r"]
    # With a command word, the command's flags still need `--`
    expect(ValueError):
      discard parseCliArgs(@["daemon", "3code", "-r"])

  test "double dash stops option parsing":
    # The sentinel is kept: main splits the session name from the command
    # on it (an auto name can BE an existing command).
    let o = parseCliArgs(@["daemon", "work", "--", "sh", "-c", "echo hi"])
    check o.sessions == @["daemon", "work", "--", "sh", "-c", "echo hi"]
    check not o.log and o.listen == ""
    check parseCliArgs(@["--", "-l"]).sessions == @["--", "-l"]
    check parseCliArgs(@["daemon", "-"]).sessions == @["daemon", "-"]

  test "daemon re-exec shape keeps flags before the sentinel":
    # What `new` execs: flags are options until `--`, positionals after
    let o = parseCliArgs(@["daemon", "mpx", "-l", "10.0.0.4:4534", "--", "/bin/bash"])
    check o.sessions == @["daemon", "mpx", "--", "/bin/bash"]
    check o.listen == "10.0.0.4:4534"

  test "missing value errors":
    expect(ValueError):
      discard parseCliArgs(@["daemon", "-l"])
    expect(ValueError):
      discard parseCliArgs(@["daemon", "--listen"])

  test "listen validation errors":
    expect(ValueError):
      discard parseCliArgs(@["daemon", "-l", "no-port-here"])
    expect(ValueError):
      discard parseCliArgs(@["daemon", "-l", "host:0"])
    expect(ValueError):
      discard parseCliArgs(@["daemon", "-l", "10.0.0.4:notanumber"])

  test "version and help":
    check parseCliArgs(@["--version"]).version
    check parseCliArgs(@["-v"]).version
    check parseCliArgs(@["--help"]).help
    check parseCliArgs(@["-h"]).help
    expect(ValueError):
      discard parseCliArgs(@["--version=false"])

  test "toConfig merges listen and port":
    check toConfig(parseCliArgs(@["-l", "10.0.0.4:4534"])).listen == "10.0.0.4:4534"
    check toConfig(parseCliArgs(@["-p", "4534"])).listen == "0.0.0.0:4534"
    check toConfig(parseCliArgs(@["-l", "10.0.0.4:9000", "-p", "4534"])).listen == "10.0.0.4:4534"
    check toConfig(parseCliArgs(@["--log"])).log

suite "command resolution":
  test "unambiguous prefixes":
    check matchModes("d") == @["daemon"]
    check matchModes("da") == @["daemon"]
    check matchModes("a") == @["attach"]
    check matchModes("at") == @["attach"]
    check matchModes("n") == @["new"]
    check matchModes("ne") == @["new"]
    check matchModes("l") == @["ls"]
    check matchModes("k") == @["kill"]
    check matchModes("ki") == @["kill"]

  test "full names resolve to themselves":
    for m in ["daemon", "attach", "new", "ls", "kill"]:
      check matchModes(m) == @[m]

  test "no match means the word is a new-argument, not a command":
    check matchModes("htop").len == 0
    check matchModes("work").len == 0
    check matchModes("list").len == 0

  test "empty prefix is ambiguous":
    check matchModes("").len == 5

suite "config":
  test "parseListen splits host and port":
    let (ip, port) = parseListen("10.0.0.4:4534")
    check ip.address_v4 == [byte 10, 0, 0, 4]
    check port == 4534



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

test "suspend and resume frames round-trip":
  var buf: seq[byte]
  buf.add frameBytes(mkSuspend, [])
  buf.add frameBytes(mkResume, [])
  var kind: MsgKind
  var payload: seq[byte]
  check takeFrame(buf, kind, payload) and kind == mkSuspend and payload.len == 0
  check takeFrame(buf, kind, payload) and kind == mkResume and payload.len == 0
  check not takeFrame(buf, kind, payload)

# PTY tests
test "pty roundtrip":
  let p = openPty("/bin/cat", [], 80, 24)
  check p.progPid > 0  # known to the daemon, so suspend can signal the group
  let msg = "hello\n"
  discard p.write(msg.cstring, msg.len)
  sleep(50)
  var buf: array[256, char]
  let n = p.read(addr buf, buf.len)
  check n > 0
  let got = cast[string](buf[0..<n])
  check "hello" in got
  p.close()

when not defined(windows):
  test "pty suspend stops the program's group, resume thaws it":
    # Ctrl-Z in a command session is SIGTSTP to the program's group: the
    # whole job freezes (sh and its sleep child), output goes silent, and
    # SIGCONT starts it again.
    let script = "while true; do echo tick; sleep 0.1; done"
    let p = openPty("/bin/sh", ["-c", script], 80, 24)
    let fl = fcntl(p.masterFd, F_GETFL)
    discard fcntl(p.masterFd, F_SETFL, fl or O_NONBLOCK)

    proc drain(ms: int): string =
      let deadline = getTime() + initDuration(milliseconds = ms)
      var buf: array[4096, char]
      while getTime() < deadline:
        let n = posix.read(p.masterFd, addr buf[0], buf.len)
        if n > 0:
          result.add cast[string](buf[0..<n])
        else:
          sleep 20

    check "tick" in drain(700)
    p.suspend()
    discard drain(300)  # a tick already in flight may land; let it
    check "tick" notin drain(400)
    p.resume()
    check "tick" in drain(700)
    discard kill(-p.progPid, SIGKILL)
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
