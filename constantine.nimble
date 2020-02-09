packageName   = "constantine"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "This library provides constant time big int primitives."
license       = "MIT or Apache License 2.0"
srcDir        = "src"

### Dependencies
requires "nim >= 1.0.6"

### Helper functions
proc test(fakeCurves: string, path: string, lang = "c") =
  if not dirExists "build":
    mkDir "build"
  exec "nim " & lang & fakeCurves & " --outdir:build -r --hints:off --warnings:off " & path

### tasks
task test, "Run all tests":
  test "",                  "tests/test_word_types.nim"
  test "",                  "tests/test_io.nim"
  test "",                  "tests/test_bigints.nim"
  test " -d:testingCurves", "tests/test_field_fp.nim"