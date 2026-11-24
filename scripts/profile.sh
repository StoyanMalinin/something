#!/usr/bin/env bash
# Profile the fuzzy search over /opt/homebrew with Instruments' Time Profiler
# (xctrace) and open the query-phase flame graph in speedscope, in Chrome.
#
#   scripts/profile.sh <query> [runs=5]
#
# Needs full Xcode (xcrun xctrace). With few runs the one-time index scan dominates the
# trace; the opened profile is filtered to stacks through queryLoop / FileIndex.search, so
# only the queries are shown. Use more runs (e.g. 200) for steadier numbers.
#
# Env:
#   ROOT=<dir>   folder to scan (default: /opt/homebrew, ~150k files, no macOS privacy prompts)
#   OUT=<dir>    where traces go (default: ./traces)
#   BROWSER_APP  app to open the profile with (default: "Google Chrome")
#   CODESIGN_IDENTITY  sign the binary with this identity so macOS privacy grants survive rebuilds
#   FOCUS=<re>   stacks to keep in the opened profile (default: queryLoop|FileIndex\.search)
set -euo pipefail

if [[ $# -lt 1 || -z "${1// }" ]]; then
  echo "usage: $0 <query> [runs=5]" >&2
  exit 2
fi
QUERY="$1"
RUNS="${2:-5}"
ROOT="${ROOT:-/opt/homebrew}"
BROWSER_APP="${BROWSER_APP:-Google Chrome}"
FOCUS="${FOCUS:-queryLoop|FileIndex\\.search}"
SPEEDSCOPE_VERSION="1.25.0"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
OUT="${OUT:-$repo/traces}"
# Dedicated install prefix: zig-out/bin is shared with plain `zig build` (Debug), editor
# build-on-save and `zig build run`, any of which can overwrite the binary. A Debug/ReleaseSafe
# binary uses SafeAllocator, which captures a stack trace per allocation and prints a trace per
# leaked allocation at exit, swamping the profile.
prefix="$repo/zig-out/profile"
bin="$prefix/bin/something"
stamp="$(date +%Y%m%d-%H%M%S)"
trace="$OUT/$stamp.trace"
queries="$OUT/$stamp.queries.txt"
xml="$OUT/$stamp.time-profile.xml"
log="$OUT/$stamp.run.log"

for tool in node npm zig python3; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done
xcrun xctrace version >/dev/null 2>&1 || {
  echo "xctrace not usable: install full Xcode, then run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license accept" >&2
  exit 1
}
mkdir -p "$OUT"

# Frame pointers keep stacks accurate; dsymutil makes the DWARF (left in .zig-cache
# object files on macOS) available for symbolication.
echo "==> building (ReleaseFast, frame pointers kept)"
(cd "$repo" && zig build -Doptimize=ReleaseFast -Dframe-pointers=true -p "$prefix")
dsymutil "$bin" 2>/dev/null || echo "warning: dsymutil failed, symbols may be missing" >&2

# macOS privacy grants (Desktop/Documents prompts, Full Disk Access) are keyed to the binary's
# code identity. An ad-hoc signature is a hash of the exact bytes, so every rebuild looks like a
# new app and the prompts return. Signing with a stable identity (e.g. a self-signed
# "Code Signing" certificate from Keychain Access) keeps the grant across rebuilds.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$bin"
fi

# The app reads queries from stdin: RUNS copies of the query, then quit.
# One process = one index build, so all runs hit the same warm index.
{
  for ((i = 0; i < RUNS; i++)); do printf '%s\n' "$QUERY"; done
  printf ':q\n'
} >"$queries"

# The parallel walker holds many directories open; the macOS default of 256 fds is too low.
hard="$(ulimit -Hn)"
want=65536
if [[ "$hard" != "unlimited" && "$hard" -lt "$want" ]]; then want="$hard"; fi
ulimit -n "$want" 2>/dev/null || echo "warning: could not raise fd limit (now $(ulimit -n))" >&2

echo "==> recording: scan '$ROOT', query '$QUERY' x$RUNS"
xcrun xctrace record --template 'Time Profiler' --output "$trace" \
  --target-stdin "$queries" --launch -- "$bin" "$ROOT" >"$log" 2>&1 \
  || { tail -30 "$log" >&2; exit 1; }
grep -E 'Indexing took|Total files|matches in' "$log" || true

echo "==> exporting samples"
xcrun xctrace export --input "$trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  --output "$xml" >/dev/null
python3 "$here/xctrace-to-folded.py" "$xml" "$OUT/$stamp" "$FOCUS"
folded="$OUT/$stamp.focus.folded"
[[ -s "$folded" ]] || { echo "no samples matched /$FOCUS/; try FOCUS=. to keep everything ($OUT/$stamp.all.folded)" >&2; exit 1; }

echo "==> opening in $BROWSER_APP"
echo "    Instruments trace:  $trace   (open it in Instruments for its own views)"
echo "    speedscope (focus): $folded"
echo "    all samples:        $OUT/$stamp.all.folded"

# Same approach as the speedscope CLI (profile -> temp .js, redirect page with a hash),
# but opened in the browser we choose instead of the system default.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/something-profile"
ss="$cache/node_modules/speedscope"
if [[ ! -f "$ss/dist/release/index.html" ]]; then
  echo "==> installing speedscope@$SPEEDSCOPE_VERSION into $cache"
  npm install --silent --no-audit --no-fund --prefix "$cache" "speedscope@$SPEEDSCOPE_VERSION"
fi
tmp="$(mktemp -d)"
node -e '
  const fs = require("fs"), path = require("path");
  const [profile, ss, tmp] = process.argv.slice(1);
  const b64 = fs.readFileSync(profile).toString("base64");
  const js = path.join(tmp, "profile.js");
  fs.writeFileSync(js, `speedscope.loadFileFromBase64(${JSON.stringify(path.basename(profile))}, ${JSON.stringify(b64)})`);
  const url = "file://" + path.join(ss, "dist/release/index.html") + "#localProfilePath=" + js + "&view=sandwich";
  fs.writeFileSync(path.join(tmp, "open.html"), `<script>window.location=${JSON.stringify(url)}</script>`);
' "$folded" "$ss" "$tmp"
open -a "$BROWSER_APP" "$tmp/open.html"
