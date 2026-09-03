# Package

version       = "0.1.0"
author        = "Carlo Capocasa"
description   = "Transparent terminal multiplexer"
license       = "MIT"
srcDir        = "src"
bin           = @["multiplexer"]

# Dependencies

requires "nim >= 2.2.10"
requires "ttty >= 0.5.1"