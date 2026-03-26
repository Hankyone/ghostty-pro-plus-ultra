#!/bin/bash
# Wrapper around Apple's libtool that repacks all input .a archives to fix
# member alignment before combining.
#
# Zig 0.15+ produces .a archives with members that are not 8-byte aligned.
# Apple's libtool silently drops misaligned members when combining archives,
# causing missing symbols. This wrapper extracts all .o files from each input
# archive and passes them directly to libtool, bypassing the alignment issue.
#
# Usage: libtool_wrapper.sh -static -o <output> <input1.a> <input2.a> ...
set -euo pipefail

# Parse args: expect "libtool_wrapper.sh -static -o <output> <inputs...>"
shift  # skip -static
shift  # skip -o
OUTPUT="$1"
shift  # remaining args are input .a files

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Extract all .o files from all input archives into uniquely-named subdirs
# to avoid name collisions between archives.
IDX=0
ALL_OBJECTS=()
for archive in "$@"; do
    SUBDIR="$TMPDIR/$IDX"
    mkdir -p "$SUBDIR"
    ABS_ARCHIVE="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
    (cd "$SUBDIR" && ar x "$ABS_ARCHIVE" && chmod 644 *.o 2>/dev/null || true)
    for obj in "$SUBDIR"/*.o; do
        [ -f "$obj" ] && ALL_OBJECTS+=("$obj")
    done
    IDX=$((IDX + 1))
done

libtool -static -o "$OUTPUT" "${ALL_OBJECTS[@]}"
