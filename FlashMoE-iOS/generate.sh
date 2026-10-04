#!/bin/bash
# Regenerate FlashMoE.xcodeproj from project.yml.
#
# Use this instead of bare `xcodegen generate`. XcodeGen types
# ../metal_infer/nax_gemm.metal as `sourcecode.metal`, which makes Xcode
# compile it even though it sits in the Resources phase — producing a second
# default.metallib and failing the build with "Unexpected duplicate tasks".
# nax_gemm.metal is compiled at runtime via newLibraryWithSource and loaded
# with pathForResource:@"nax_gemm" ofType:@"metal", so it must ship as plain
# text under that exact name.
set -euo pipefail

cd "$(dirname "$0")"

xcodegen generate

/usr/bin/sed -i '' \
  's|\(/\* nax_gemm.metal \*/ = {isa = PBXFileReference; lastKnownFileType = \)sourcecode.metal\(;.*\)|\1text\2|' \
  FlashMoE.xcodeproj/project.pbxproj

if grep -q 'nax_gemm.metal \*/ = {isa = PBXFileReference; lastKnownFileType = sourcecode.metal' \
     FlashMoE.xcodeproj/project.pbxproj; then
  echo "error: could not retype nax_gemm.metal to text" >&2
  exit 1
fi

echo "Generated FlashMoE.xcodeproj (nax_gemm.metal kept as a plain resource)."
