# Package

version       = "0.1.0"
author        = "Carlo Capocasa"
description   = "Transparent terminal multiplexer"
license       = "MIT"
srcDir        = "src"
bin           = @["mpx"]

# Dependencies

requires "nim >= 2.2.10"
requires "ttty >= 0.5.1"

task example, "Run example end-to-end":
  exec "nim c --hints:off --path:src -o:build/example example/example.nim"
  exec "./build/example"

task test, "Run tests":
  exec "nim c -r --hints:off --path:src tests/test1.nim"