#!/usr/bin/env bash
# Compare query speed between builds on a fixed, varied query set.
#
#   scripts/bench.sh [target...]      (default: HEAD .)
#
# A target is a built binary, "." for the working tree, or a git revision (built in a
# temporary worktree). Every target indexes ROOT once per round and then answers the whole
# query set REPS times; rounds alternate between targets so drift in disk cache or clock
# speed hits them all alike. Reports the median over rounds and repetitions.
#
# Env:
#   ROOT=<dir>      folder to index (default: /opt/homebrew, no macOS privacy prompts)
#   QUERIES=<file>  one query per line (default: scripts/queries.txt)
#   ROUNDS=<n>      processes per target (default: 1; raise it when a gap is near noise)
#   REPS=<n>        passes over the query set per process (default: 2)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
ROOT="${ROOT:-/opt/homebrew}"
QUERIES="${QUERIES:-$here/queries.txt}"
ROUNDS="${ROUNDS:-1}"
REPS="${REPS:-2}"
[[ $# -gt 0 ]] || set -- HEAD .

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Resolve every target to a ReleaseFast binary
bins=()
names=()
for t in "$@"; do
  if [[ -f "$t" && -x "$t" ]]; then
    bins+=("$t")
    # A short label: the install prefix of .../<prefix>/bin/something
    names+=("$(basename "$(dirname "$(dirname "$t")")")")
    continue
  elif [[ "$t" == "." ]]; then
    echo "==> building the working tree" >&2
    (cd "$repo" && zig build -Doptimize=ReleaseFast -p "$work/out-work")
    bins+=("$work/out-work/bin/something")
  else
    rev="$(git -C "$repo" rev-parse --short "$t")"
    echo "==> building $t ($rev)" >&2
    git -C "$repo" worktree add --quiet --detach "$work/wt-$rev" "$rev"
    (cd "$work/wt-$rev" && zig build -Doptimize=ReleaseFast -p "$work/out-$rev")
    git -C "$repo" worktree remove --force "$work/wt-$rev"
    bins+=("$work/out-$rev/bin/something")
  fi
  names+=("$t")
done

# REPS copies of the query set, then quit
input="$work/input.txt"
{
  for ((i = 0; i < REPS; i++)); do grep -v '^[[:space:]]*$' "$QUERIES"; done
  printf ':q\n'
} >"$input"

# The parallel walker holds many directories open; the macOS default of 256 fds is too low
hard="$(ulimit -Hn)"
want=65536
if [[ "$hard" != "unlimited" && "$hard" -lt "$want" ]]; then want="$hard"; fi
ulimit -n "$want" 2>/dev/null || true

nq="$(grep -vc '^[[:space:]]*$' "$QUERIES")"
echo "==> $ROUNDS rounds x $REPS passes x $nq queries over $ROOT" >&2
for ((r = 0; r < ROUNDS; r++)); do
  for i in "${!bins[@]}"; do
    "${bins[$i]}" "$ROOT" <"$input" >/dev/null 2>"$work/log-$i-$r.txt"
    printf '.' >&2
  done
done
echo >&2

python3 - "$work" "$QUERIES" "$ROUNDS" "${names[@]}" <<'PY'
import re, statistics, sys

work, qfile, rounds, *names = sys.argv[1:]
rounds = int(rounds)
queries = [l.strip() for l in open(qfile) if l.strip()]
nq = len(queries)

per_query = []   # [target][query] -> list of ms
pass_total = []  # [target] -> list of ms per pass over the set
index_ms = []    # [target] -> list of ms
for i, _ in enumerate(names):
    pq = [[] for _ in queries]
    totals, idx = [], []
    for r in range(rounds):
        text = open(f"{work}/log-{i}-{r}.txt").read()
        if m := re.search(r"Indexing took (\d+)ms", text):
            idx.append(int(m.group(1)))
        times = [float(t) for t in re.findall(r"matches in ([\d.]+)ms", text)]
        if len(times) % nq:
            sys.exit(f"{names[i]}: {len(times)} timings is not a whole number of passes")
        for k, t in enumerate(times):
            pq[k % nq].append(t)
        totals += [sum(times[p:p + nq]) for p in range(0, len(times), nq)]
    per_query.append(pq)
    pass_total.append(totals)
    index_ms.append(idx)

med = statistics.median
w = max(len(n) for n in names)
print(f"\n{'target':<{w}}  {'index ms':>9}  {'set ms':>8}  {'vs first':>8}")
base = med(pass_total[0])
for i, n in enumerate(names):
    s = med(pass_total[i])
    print(f"{n:<{w}}  {med(index_ms[i]) if index_ms[i] else float('nan'):>9.0f}  {s:>8.1f}  {s / base:>7.2f}x")

qw = max(len(q) for q in queries)
cw = max(9, w)
print(f"\n{'query':<{qw}}  " + "  ".join(f"{n:>{cw}}" for n in names))
order = sorted(range(nq), key=lambda k: -med(per_query[0][k]))
for k in order:
    print(f"{queries[k]:<{qw}}  " + "  ".join(f"{med(per_query[i][k]):>{cw}.2f}" for i in range(len(names))))
PY
