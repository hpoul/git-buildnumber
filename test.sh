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
# The concurrency case is timing-based, and honestly so: the window it needs is
# between fetching and pushing, and `generate` fetches immediately before
# allocating — so a sequenced version does NOT reproduce the race, it just
# watches the second run read the first's push and take the next number. An
# earlier draft of this file did exactly that and passed against the unfixed
# script.
#
# The consequence is that this case fails *open*: if the two runs serialize on a
# loaded machine it passes without having raced. It is run repeatedly to narrow
# that, and the lease itself is covered deterministically by the split-remote and
# force-incr cases, which do not depend on timing.

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
  cd "$dir/$1"
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

# How many commits carry a buildnumbers note ON ORIGIN. Always prints a number:
# an empty string here would read as "0 notes" in a diagnostic while actually
# meaning "the check itself broke".
remote_note_count() {
  local dir="$1" out
  out=$(
    set +e
    cd "$dir" || exit 0
    rm -rf inspect
    git clone -q origin.git inspect >/dev/null 2>&1 || exit 0
    cd inspect || exit 0
    git fetch -q origin '+refs/notes/buildnumbers:refs/notes/buildnumbers' >/dev/null 2>&1
    git notes --ref=buildnumbers list 2>/dev/null | wc -l | tr -d ' '
  ) || out=""
  printf '%s' "${out:-0}"
}

# Run something that is allowed to fail, capturing stdout. Without this, a
# non-zero exit inside a command substitution aborts the whole suite under
# `set -e` — so a regression would look like a crashed harness rather than a
# failed assertion.
try() { ( set +e; "$@" ) || true; }

# ---------------------------------------------------------------- concurrency

note "Two clones allocating at the same moment"

# The window between fetching and pushing is small and real; the only honest way
# to enter it is to run both at once. Whoever loses must refetch and take the
# next number rather than returning the one it lost with.
race_round=0
race_bad=""
while [ "$race_round" -lt 3 ]; do
  race_round=$((race_round + 1))
  setup "race$race_round" a b
  RA="$ROOT/race$race_round/a"; RB="$ROOT/race$race_round/b"
  commit_in "$RA" "from a"
  commit_in "$RB" "from b"

  # `wait` reports a background job's non-zero exit, which would abort the suite
  # under `set -e` before anything could be reported. The failure must land in an
  # assertion, not in the harness.
  ( cd "$RA" && "$GBN" generate >"$ROOT/race$race_round/a.out" 2>/dev/null ) &
  ( cd "$RB" && "$GBN" generate >"$ROOT/race$race_round/b.out" 2>/dev/null ) &
  wait || true

  ra=$(tr -d '[:space:]' < "$ROOT/race$race_round/a.out" 2>/dev/null || true)
  rb=$(tr -d '[:space:]' < "$ROOT/race$race_round/b.out" 2>/dev/null || true)
  count=$(remote_note_count "$ROOT/race$race_round")

  if [ -z "$ra" ] || [ -z "$rb" ] || [ "$ra" = "$rb" ]; then
    race_bad="round $race_round: a=${ra:-<none>} b=${rb:-<none>}"
    break
  fi
  if [ "$count" != "2" ]; then
    race_bad="round $race_round: origin carries $count note(s), expected 2"
    break
  fi
done

if [ -z "$race_bad" ]; then
  ok "3 rounds: allocations differ and both notes survive each time"
else
  bad "$race_bad" "two artifacts would carry one build number, or one was erased"
fi

# --------------------------------------------------------------- stdout shape

note "generate's stdout is consumed as a value"

setup out a
C="$ROOT/out/a"
commit_in "$C" "a change"
raw=$( try sh -c "cd '$C' && '$GBN' generate 2>/dev/null" )
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

# ------------------------------------------------------ separate fetch/push remotes

note "GIT_FETCH_REMOTE and GIT_PUSH_REMOTE may differ"

# A lease is a claim about the remote being pushed to. Observing the fetch remote
# and asserting it against the push remote refuses every push to a mirror that is
# perfectly in sync — deterministic, and it does not depend on any race.
setup split a
F="$ROOT/split/a"
git init -q --bare "$ROOT/split/mirror.git"
( cd "$F" && git remote add mirror "$ROOT/split/mirror.git" )

# The two remotes have to hold *different* state, or the observation taken from
# the wrong one happens to match and nothing is proven. So: allocate once and
# copy that to the mirror, then let origin move on alone.
commit_in "$F" "first change"
try sh -c "cd '$F' && '$GBN' generate 2>/dev/null" >/dev/null
( cd "$F" && git push -q mirror '+refs/buildnumbers/*:refs/buildnumbers/*' \
    '+refs/notes/buildnumbers:refs/notes/buildnumbers' )
commit_in "$F" "second change"
try sh -c "cd '$F' && '$GBN' generate 2>/dev/null" >/dev/null   # origin only

# origin is now two allocations ahead of the mirror. Pushing to the mirror must
# lease against the mirror's values, not origin's.
commit_in "$F" "third change"
n=$( try sh -c "cd '$F' && GIT_PUSH_REMOTE=mirror '$GBN' generate 2>/dev/null" )

if [ "$n" = "3" ]; then
  ok "an allocation against a diverged push remote succeeds (n=$n)"
else
  bad "generate produced: $(printf '%q' "$n"), expected 3" \
      "the lease was observed on the fetch remote and asserted against the push remote"
fi

# ------------------------------------------------------------------ force-incr

note "force-incr takes the next number, not the one after it"

# On a commit that ALREADY has a number, force-incr's inner lookup returns
# without pushing, so stale observations never show. The failing case is a commit
# with no number yet: the inner call allocates *and publishes*, which invalidates
# what this process observed before it.
setup incr a
G="$ROOT/incr/a"
commit_in "$G" "a change"
bumped=$( try sh -c "cd '$G' && '$GBN' force-incr 2>/dev/null" | tail -1 )
if [ "$bumped" = "2" ]; then
  ok "force-incr on an unnumbered commit returned 2"
else
  bad "force-incr returned $(printf '%q' "$bumped"), expected 2" \
      "its inner allocation published, so its own push leased against stale values"
fi

# --------------------------------------------------- chains from older versions

note "A chain created before this change is still usable"

setup old a
H="$ROOT/old/a"
commit_in "$H" "first"
(
  # Exactly what the previous version wrote: one entry, no root, no second
  # parent, the built SHA only as blob content in a b<n> tree entry.
  cd "$H"
  blob=$(git rev-parse HEAD | git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tb1\n' "$blob" | git mktree)
  entry=$(git commit-tree "$tree" -m "buildnumber: 1 (increment)")
  git update-ref refs/buildnumbers/commits "$entry"
  printf '1\n' | git hash-object -w --stdin | xargs git update-ref refs/buildnumbers/last
  git notes --ref=buildnumbers add -m 1 -f HEAD >/dev/null 2>&1
  git push -q origin '+refs/buildnumbers/*:refs/buildnumbers/*' '+refs/notes/buildnumbers:refs/notes/buildnumbers'
)
commit_in "$H" "second"
nextn=$( try sh -c "cd '$H' && '$GBN' generate 2>/dev/null" )
logok=$( try sh -c "cd '$H' && '$GBN' log 2>/dev/null" | grep -c '^commit ' || true )
if [ "$nextn" = "2" ]; then
  ok "generate continues an old chain (n=$nextn)"
else
  bad "generate returned $(printf '%q' "$nextn"), expected 2" "an existing chain was not continued"
fi
if [ "$logok" -ge 2 ]; then
  ok "log walks an old chain without error ($logok entries)"
else
  bad "log produced $logok entries" "the first-parent walk broke on a pre-existing chain"
fi

# --------------------------------------------------------- push publishes work

note "push publishes local work rather than discarding it"

# `_push` needs something to lease against, and must not use `_fetch` to get it:
# that force-updates the local refs from the remote, which discards the very
# allocation being published. The symptom was silent — local state gone, nothing
# pushed, exit 0.
setup pub a
P="$ROOT/pub/a"
git init -q --bare "$ROOT/pub/elsewhere.git"
( cd "$P" && git remote add elsewhere "$ROOT/pub/elsewhere.git" )
commit_in "$P" "a change"
# Allocate without origin seeing it, leaving local-only state to publish.
try sh -c "cd '$P' && GIT_FETCH_REMOTE=elsewhere GIT_PUSH_REMOTE=elsewhere '$GBN' generate 2>/dev/null" >/dev/null
before=$( cd "$P" && git cat-file blob refs/buildnumbers/last 2>/dev/null || echo "" )
try sh -c "cd '$P' && '$GBN' push 2>/dev/null" >/dev/null
after=$( cd "$P" && git cat-file blob refs/buildnumbers/last 2>/dev/null || echo "" )

if [ -n "$before" ] && [ "$after" = "$before" ]; then
  ok "local allocation survives a push (n=$after)"
else
  bad "local went from ${before:-<none>} to ${after:-<none>}" \
      "push discarded the state it was asked to publish"
fi

published=$( cd "$ROOT/pub" && git --git-dir=origin.git cat-file blob refs/buildnumbers/last 2>/dev/null || echo "" )
if [ "$published" = "$before" ]; then
  ok "and reaches the remote (n=$published)"
else
  bad "origin has ${published:-<nothing>}, local had ${before:-<none>}" "push reported success without publishing"
fi

# ------------------------------------------------- force-incr and the counter

note "force-incr counts from the shared counter, not from HEAD's own note"

# With HEAD on 1 and the counter on 3, counting from the note yields 2 — a
# number another commit already owns — and publishing it rolls the counter
# backwards so the next allocation hands out 3 twice. The lease cannot catch it,
# because nothing else moved.
setup fi a
I="$ROOT/fi/a"
commit_in "$I" "one";   c1=$( cd "$I" && git rev-parse HEAD )
try sh -c "cd '$I' && '$GBN' generate 2>/dev/null" >/dev/null
commit_in "$I" "two";   try sh -c "cd '$I' && '$GBN' generate 2>/dev/null" >/dev/null
commit_in "$I" "three"; try sh -c "cd '$I' && '$GBN' generate 2>/dev/null" >/dev/null

( cd "$I" && git checkout -q "$c1" )
bumped=$( try sh -c "cd '$I' && '$GBN' force-incr 2>/dev/null" | tail -1 )
counter=$( cd "$I" && git cat-file blob refs/buildnumbers/last 2>/dev/null || echo "" )

if [ "$bumped" = "4" ]; then
  ok "force-incr on an older commit took 4, past the counter"
else
  bad "force-incr returned $(printf '%q' "$bumped"), expected 4" \
      "it counted from HEAD's note and reused a number another commit owns"
fi
if [ "$counter" = "4" ]; then
  ok "the shared counter moved forward (now $counter)"
else
  bad "counter is $(printf '%q' "$counter"), expected 4" "the counter was rolled backwards"
fi

# ------------------------------------- a local ref the remote does not have

note "A ref present locally but absent on the remote still publishes"

# The lease is a claim about the remote. Taking it from the local refs after a
# fetch looks equivalent, but a fetch only updates refs the remote actually has
# — so a local-only ref makes the lease claim a value the remote never held, the
# push dies "stale info", and the retry then returns the note it just wrote.
# Exit 0, a number on stdout, nothing published.
setup orphanref a
J="$ROOT/orphanref/a"
commit_in "$J" "first"
try sh -c "cd '$J' && '$GBN' generate 2>/dev/null" >/dev/null
# The remote loses the allocation refs; the clone keeps them.
( cd "$ROOT/orphanref" && git --git-dir=origin.git update-ref -d refs/buildnumbers/last 2>/dev/null || true
  git --git-dir=origin.git update-ref -d refs/buildnumbers/commits 2>/dev/null || true
  git --git-dir=origin.git update-ref -d refs/notes/buildnumbers 2>/dev/null || true )
commit_in "$J" "second"
n2=$( try sh -c "cd '$J' && '$GBN' generate 2>/dev/null" )
onremote=$( cd "$ROOT/orphanref" && git --git-dir=origin.git cat-file blob refs/buildnumbers/last 2>/dev/null || echo "" )

if [ -n "$n2" ] && [ "$onremote" = "$n2" ]; then
  ok "the allocation reached the remote (n=$n2)"
else
  bad "reported ${n2:-<none>}, remote has ${onremote:-<nothing>}" \
      "a number was reported that nothing else in the world has"
fi

# ------------------------------------------- a run that gives up cleans up

note "A run that cannot publish leaves nothing behind for the next one to trust"

# The failure path used to leave the unpublished note and counter in the local
# refs, where the next run finds its own note on attempt 1 and returns it
# without fetching or pushing — a number nothing else in the world has.
setup giveup a
K="$ROOT/giveup/a"
commit_in "$K" "a change"
# A push remote that cannot work, so every attempt fails.
( cd "$K" && git remote add broken "$ROOT/giveup/nowhere.git" )
try sh -c "cd '$K' && MAX_ATTEMPTS=2 GIT_PUSH_REMOTE=broken '$GBN' generate 2>/dev/null" >/dev/null
leftover=$( cd "$K" && git notes --ref=buildnumbers show HEAD 2>/dev/null || echo "" )

if [ -z "$leftover" ]; then
  ok "no unpublished note survives the failure"
else
  bad "a note saying $leftover was left behind" \
      "the next run would return it without publishing anything"
fi

# tree validity after a number is rewritten — the tab-in-grep filter
note "Rewriting a number leaves a valid tree"

setup rewrite a
L="$ROOT/rewrite/a"
commit_in "$L" "a change"
try sh -c "cd '$L' && '$GBN' generate 2>/dev/null" >/dev/null
try sh -c "cd '$L' && '$GBN' force 1 2>/dev/null" >/dev/null
dupes=$( cd "$L" && git ls-tree --full-tree refs/buildnumbers/commits 2>/dev/null | awk '{print $4}' | sort | uniq -d | wc -l | tr -d ' ' )
if [ "$dupes" = "0" ]; then
  ok "the allocation tree has no duplicate entries"
else
  bad "$dupes duplicated name(s) in the tree" \
      "the old entry was not filtered out, so mktree wrote an fsck-invalid tree"
fi

# --------------------------------------------------------------------- report

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
