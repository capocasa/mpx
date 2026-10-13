# Package

version       = "0.1.2"
author        = "Carlo Capocasa"
description   = "Transparent terminal multiplexer"
license       = "MIT"
srcDir        = "src"
bin           = @["mpx"]

# Dependencies

requires "nim >= 2.2.10"
requires "ttty >= 0.5.2"

task example, "Run example end-to-end":
  # nimble c, not raw nim: the committed nimble.lock disables nim's pkgs2
  # scan, so only nimble resolves the dependency paths.
  exec "nimble c --hints:off -o:build/example example/example.nim"
  exec "./build/example"

task test, "Run tests":
  when defined(windows):
    exec "nimble c -r --hints:off tests/test_windows.nim"
  else:
    exec "nimble c -r --hints:off tests/test1.nim"