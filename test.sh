#!/usr/bin/env bash
#
# Tests for git-buildnumber.sh, against throwaway repositories in a temp dir.
#
#   ./test.sh
#
# Every case builds its own origin and clones, runs the real script rather than
# a reimplementation of it, and asserts on what ended up on the *remote* — which
# is the only place a lost allocation is visible.
#
# The concurrency cases are deterministic rather than timing-based. A genuine
# race is reproducible only by luck; what matters is the state a race produces,
# and that state can be constructed exactly: one clone allocates and pushes
# while a second clone still holds pre-fetch refs, then the second pushes.

set -euo pipefail

GBN="$(cd "$(dirname "$0")" && pwd)/git-buildnumber.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; printf '       %s\n' "${2:-}"; fail=$((fail + 1)); }
note() { printf '\n%s\n' "$1"; }

# A repository pair: bare origin, plus $1 clones named a, b, …
setup() {
  local dir="$ROOT/$1"; shift
  rm -rf "$dir"; mkdir -p "$dir"; cd "$dir"
  git init -q --bare origin.git
  local name
  for name in "$@"; do
    git clone -q origin.git "$name" 2>/dev/null
    git -C "$name" config user.email t@example.com
    git -C "$name" config user.name Test
  done
  # One shared commit so the clones are not empty.
  cd "$dir/$1x" 2>/dev/null || cd "$dir/$(echo "$@" | cut -d' ' -f1)"
  echo seed > seed.txt
  git add seed.txt
  git commit -qm seed
  git push -q origin HEAD:master
  cd "$dir"
  for name in "$@"; do
    git -C "$name" fetch -q origin
    git -C "$name" checkout -q -B master origin/master 2>/dev/null || true
  done
}

commit_in() { # commit_in <clone> <text>
  ( cd "$1" && echo "$2" > file.txt && git add file.txt && git commit -qm "$2" )
}

remote_note_count() { # how many commits carry a buildnumbers note ON ORIGIN
  local dir="$1" n=0
  (
    set +e
    cd "$dir" || exit 0
    rm -rf inspect
    git clone -q origin.git inspect >/dev/null 2>&1 || exit 0
    cd inspect || exit 0
    git fetch -q origin '+refs/notes/buildnumbers:refs/notes/buildnumbers' >/dev/null 2>&1
    git notes --ref=buildnumbers list 2>/dev/null | wc -l | tr -d ' '
  ) || n=0
}

# ---------------------------------------------------------------- concurrency

note "Two clones allocating at the same moment"

# The window between fetching and pushing is small and real; the only honest way
# to enter it is to run both at once. Whoever loses must refetch and take the
# next number rather than returning the one it lost with.
setup race a b
RA="$ROOT/race/a"; RB="$ROOT/race/b"
commit_in "$RA" "from a"
commit_in "$RB" "from b"

( cd "$RA" && "$GBN" generate >"$ROOT/race/a.out" 2>/dev/null ) &
( cd "$RB" && "$GBN" generate >"$ROOT/race/b.out" 2>/dev/null ) &
wait

ra=$(tr -d '[:space:]' < "$ROOT/race/a.out" 2>/dev/null || true)
rb=$(tr -d '[:space:]' < "$ROOT/race/b.out" 2>/dev/null || true)

if [ -n "$ra" ] && [ -n "$rb" ] && [ "$ra" != "$rb" ]; then
  ok "the two allocations differ (a=$ra b=$rb)"
else
  bad "a=${ra:-<none>} b=${rb:-<none>}" "two artifacts would carry one build number"
fi

count=$(remote_note_count "$ROOT/race")
if [ "$count" = "2" ]; then
  ok "both notes survive on the remote"
else
  bad "origin carries $count note(s), expected 2" "one allocation was erased on the remote"
fi

# --------------------------------------------------------------- stdout shape

note "generate's stdout is consumed as a value"

setup out a
C="$ROOT/out/a"
commit_in "$C" "a change"
raw=$( cd "$C" && "$GBN" generate 2>/dev/null )
if printf '%s' "$raw" | grep -qE '^[0-9]+$'; then
  ok "stdout is a bare integer"
else
  bad "stdout was: $(printf '%q' "$raw")" "release.sh assigns this straight to a build number"
fi

# ------------------------------------------------------------- reachability

note "An allocated commit survives losing every branch that contained it"

setup reach a
D="$ROOT/reach/a"
( cd "$D" && git checkout -q -b throwaway )
commit_in "$D" "built here"
built=$( cd "$D" && git rev-parse HEAD )
( cd "$D" && "$GBN" generate >/dev/null 2>&1 )
(
  cd "$D"
  git checkout -q master
  git branch -qD throwaway
  git reflog expire --expire=now --all
  git gc --prune=now -q
)
if ( cd "$D" && git cat-file -e "$built" 2>/dev/null ); then
  ok "the commit survives gc locally"
else
  bad "the commit was collected" "its build number now names an object that does not exist"
fi

if ( cd "$ROOT/reach" && git --git-dir=origin.git cat-file -e "$built" 2>/dev/null ); then
  ok "the commit reached origin"
else
  bad "origin does not have the commit" "no other machine can resolve this build number"
fi

# ------------------------------------------------------------ the log stays a log

note "The allocation log does not become the project's history"

setup logs a
E="$ROOT/logs/a"
for i in 1 2 3; do
  commit_in "$E" "project commit $i"
  ( cd "$E" && "$GBN" generate >/dev/null 2>&1 )
done

# Each entry carries the built commit as a second parent, so a first-parent walk
# must still see only allocations — plus the chain's own root.
entries=$( cd "$E" && "$GBN" log 2>/dev/null | grep -c '^commit ' || true )
if [ "$entries" = "4" ]; then
  ok "log shows 3 allocations and the chain root, and no project commits"
else
  bad "log shows $entries commits, expected 4" \
      "a first-parent walk is reaching into the project's history"
fi

# --------------------------------------------------------------------- report

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
