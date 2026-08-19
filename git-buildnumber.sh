#!/usr/bin/env bash

# Create a continous, consistent buildnumber independent of branch.
#
# when run it will:
# 1. check if the current commit has already a build number (as a note in `refs/notes/buildnumbers`)
# 2. increment build number located in an object referenced in `refs/buildnumbers/last`
#    (starting at 1 if it does not exist)
# 3. store the new buildnumber for the commit (in a note in `refs/notes/buildnumbers`)
#
# Before and after the run it will fetch and push "refs/buildnumbers/*" and "refs/notes/*" to and from `origin`
#

#set -xeu
set -euE

if test "${VERBOSE:-}" == true ; then
  set -x
fi

VERSION=1.2

GIT_REMOTE=${GIT_REMOTE:-origin}
GIT_PUSH_REMOTE=${GIT_PUSH_REMOTE:-${GIT_REMOTE}}
GIT_FETCH_REMOTE=${GIT_FETCH_REMOTE:-${GIT_REMOTE}}

REFS_BASE=refs/buildnumbers
REFS_LAST=${REFS_BASE}/last
REFS_COMMITS=${REFS_BASE}/commits
REFS_NOTES=refs/notes/buildnumbers
# Scoped to our own notes ref on purpose. `+refs/notes/*:refs/notes/*` force-fetches
# and force-pushes *every* notes ref, so a stale clone silently rolls back notes it
# knows nothing about — refs/notes/commits used for review comments, for example.
#
# Kept as a glob rather than the exact ref because a plain refspec is fatal when
# the ref does not exist yet: "couldn't find remote ref" on fetch, "src refspec
# does not match any" on push. That is every first run.
#
# **Fetch and push need different refspecs, and sharing one is what made the
# retry below unreachable.** The leading `+` is per-ref `--force`. On the fetch
# that is wanted: the remote is the authority, and a local ref that has drifted
# should be overwritten. On the push it means a diverged remote is *overwritten
# rather than refused*, so `git push` cannot fail, so the `_push nofail ||`
# recovery paths could never run. Two clones allocating the same number would
# both "succeed", and the second would erase the first's note.
#
# Note `--force-with-lease` alone does not fix it: a `+` on the refspec
# overrides the lease. Measured — with `+`, a push carrying a stale lease value
# still reports "(forced update)".
FETCH_REFSPEC="+${REFS_BASE}/*:${REFS_BASE}/* +${REFS_NOTES}*:${REFS_NOTES}*"
PUSH_REFSPEC="${REFS_BASE}/*:${REFS_BASE}/* ${REFS_NOTES}*:${REFS_NOTES}*"

# What the last fetch saw, per ref, so the push can compare-and-swap against it.
# Fast-forward is not available here: ${REFS_LAST} points at a *blob*, which has
# no ancestry, so every update of it is a non-fast-forward and a plain push would
# refuse even a healthy single-machine run. A lease is the check that works.
OBSERVED_LAST=""
OBSERVED_COMMITS=""
OBSERVED_NOTES=""
# Whether _fetch has run in this process. Separate from the values above,
# because "no value observed" is the legitimate first-run state — the refs do
# not exist on the remote yet — and is indistinguishable from "never looked" if
# the values alone are consulted. Getting that wrong makes the push lease
# against what this process just wrote, which every remote then fails.
FETCHED=0

CMD_NOTES="git notes --ref=${REFS_NOTES}"

######################

IGNORE_REPOSITORY_STATE=${IGNORE_REPOSITORY_STATE:-0}
# By default ignore changes in newline characters.
DIFF_INDEX_ARGS=${DIFF_INDEX_ARGS:-"--ignore-space-at-eol"}


function _trap_exit {
    rc=$1
    lineno=$2
    command=$3
    if (( $rc )) ; then
        _logf "Exiting with error ($rc) at line $lineno: $command"
    fi
    exit $rc
}

trap '_trap_exit $? $LINENO "$BASH_COMMAND"' EXIT

function fail () {
    echo "${__red}FAIL: $1" $__reset >&2
    exit 1
}

function _get_existing_buildnumber () {
    # 2>/dev/null, not 2>&1: merging stderr put any git warning inside the value,
    # and callers feed this straight to --build-number and to app store metadata.
    currentbuildnumber=$(${CMD_NOTES} show 2>/dev/null) && {
        echo $currentbuildnumber
        return 0
    }
    return $?
}

function check_existing_buildnumber () {
    currentbuildnumber=$(_get_existing_buildnumber) && {
        echo $currentbuildnumber
        exit 0
    } || :
}

function find_commit_by_buildnumber {
    buildnumber=$1

    blobhash=`git ls-tree --full-tree $REFS_COMMITS "b${buildnumber}" | cut -f 1 | cut -d' ' -f3`

    if test -z "$blobhash" ; then
        echo "Unable to find buildnumber ${buildnumber} - make sure to run: $0 fetch"
        exit 1
    fi

    commits=`git cat-file blob $blobhash`

    unique=`echo "$commits" | uniq`
    
    _logi "Found the following commits: $unique"

    _git_log $commits -1

    # hash=`echo "$buildnumber" | git hash-object --stdin`
    # notesfile=`git ls-tree $REFS_NOTES | grep "blob ${hash}" | cut -f 2`

    # test -z "$notesfile" && fail "Unable to find commit for build number ${buildnumber}"

    # git log "$notesfile" -1
}

function force_buildnumber {    
    buildnumber=$1
    _fetch
    _write_buildnumber $buildnumber "forced"
    echo "Written build number."
    _push
}

function log {
    # tail `git rev-parse --git-dir`/logs/${REFS_LAST}
    #
    # --first-parent because each entry now carries the built commit as a second
    # parent (see _write_buildnumber). Without it this walks the project's whole
    # history instead of the allocation log.
    _git_log --first-parent ${REFS_COMMITS}
}

function _git_log {
    git_exit_code=0
    git log $* || git_exit_code=$?;
    if test $git_exit_code -ne 0 && test $git_exit_code -ne 141 ; then
        exit $git_exit_code
    else
        _logt "git log success with $git_exit_code"
    fi
}

function usage {
    echo git-buildnumber, version $VERSION
    echo "Usage: $0 <command>"
    echo
    echo Commands:
    echo "  generate             -- The default, outputs build number for current commit"
    echo "                          or generates a new one."
    echo "  find-commit <number> -- Finds the commit (message) for a given build number."
    echo "  force <number>       -- Uses the given number as the current buildnumber of"
    echo "                          the current commit."
    echo "  force-incr           -- Forces generation of a new build number for the "
    echo "                          current commit."
    echo "  get                  -- show the build number for the current commit (if any)"
    echo "  sync                 -- fetch && push"
    echo "  fetch                -- fetch all refs from remote"
    echo "  log                  -- shows the latest build numbers and corresponding "
    echo "                          commits"
    echo "  push                 -- push all refs from remote"
}

__red="[1;91m"
__yellow="[33m"
__blue="[34m"
__dim="[02m"
__reset="[0m"
# __red="\e[1;91m"
# __yellow="\e[33m"
# __blue="\e[34m"
# __dim="\e[2m"
# __reset="\e[0m"


function __log {
    arg=""
    color=$1
    level=$2
    shift ; shift
    while (( "$#" )) ; do
        case "$1" in
            -n) arg="-n" ; shift ;;
            -bare) level="" ; shift ;;
            *) break ;;
        esac
    done
    echo $arg "$color  $level $*$__reset" >&2
}

function _logt {
    __log $__dim TRACE "$@"
}

function _logd {
    __log $__blue DEBUG "$@"
}

function _logi {
    __log $__yellow INFO "$@"
}

function _logf {
    __log $__red FATAL "$@"
}

function _write_buildnumber {
    buildnumber=$1
    reason=${2}

    message="buildnumber: ${buildnumber} (${reason}) at commit `git rev-parse HEAD`"
    buildnumberhash=`echo "${buildnumber}" | git hash-object -w --stdin`
    git update-ref -m "${message}" --create-reflog ${REFS_LAST} ${buildnumberhash} `git show-ref -s refs/buildnumbers/last`
    ${CMD_NOTES} add -m "${buildnumber}" -f HEAD

    _logd "writing our own commits log"

    # For fun (and to have our own git log) create our own 
    # tree and commit in $REFS_COMMITS
    treefile=`mktemp`
    buildnumberfile=`mktemp`
    buildnumberfilename="b${buildnumber}"
    commitshash=`git show-ref -s $REFS_COMMITS || :`
    parent=""
    # **The chain needs a root of its own, so the built commit is always the
    # *second* parent.** Without one, the first allocation in a repository has no
    # previous entry, `-p HEAD` lands in first position, and `git log
    # --first-parent` then walks out of the allocation log and into the project's
    # history. An empty parentless commit costs nothing and keeps the invariant
    # true from the first entry onwards.
    if test -z "$commitshash" ; then
        commitshash=`git commit-tree $(git mktree </dev/null) -m "buildnumbers: start of the allocation log"`
    fi
    _logt "commitshash: $commitshash\n\n"
    if test -n "$commitshash" ; then
        parent="-p $commitshash"
        git ls-tree --full-tree $commitshash | grep -v "\t${buildnumberfilename}$" > $treefile || :
        _logt "treefile: $(cat $treefile)"
        previous=`git ls-tree --full-tree $commitshash ${buildnumberfilename} | cut -f1 | cut -d' ' -f3`
        _logt "previous hash for ${buildnumberfilename} is '${previous}'"
        if test -n "$previous" ; then
            # another commit already has this build number.. but anyway..
            _logd "Another commit ($previous) already uses this."
            git cat-file blob "$previous" > $buildnumberfile
        fi
    fi
    _logt "buildnumber file at $buildnumberfile"
    git rev-parse HEAD >> $buildnumberfile
    buildnumberfilehash=`git hash-object -w -- "$buildnumberfile"`
    
    _logt "Creating tree at $treefile"
    echo -e "100644 blob ${buildnumberfilehash}\t${buildnumberfilename}" >> $treefile
    treehash=`cat "$treefile" | git mktree`
    # **The built commit is a parent, not just a filename in the tree.** Without
    # this the SHA is recorded as blob *content*, which is a lookup and not a
    # reference: nothing in the object graph points at the commit, so `git gc`
    # collects it as soon as the last branch containing it goes away — and the
    # note still resolves afterwards, answering with a SHA that no longer exists.
    #
    # As a parent it survives gc, and pushing this ref carries its objects to the
    # remote, so another machine can still resolve the build number later.
    #
    # It is the *second* parent so `git log --first-parent` still walks only the
    # allocation history; see `log` below.
    newcommitshash=`git commit-tree $parent -p HEAD $treehash -m "${message}"`
    git update-ref -m "${message}" --create-reflog ${REFS_COMMITS} ${newcommitshash}

    rm $treefile $buildnumberfile

}

function _fetch {
    _logt -n "Fetching from ${GIT_FETCH_REMOTE} ...    "
    # **`--depth=1` only when the clone is already shallow.** Each chain entry
    # now has the built commit as a parent, so the ref's fetch closure is the
    # union of every built commit's ancestry — measured at 2364 KB against 20 KB
    # for a 30-commit repository, paid by every fresh CI runner on every
    # allocation. Depth-limiting the chain avoids that, and appending to a
    # shallow chain still works because the remote already has both parents.
    #
    # Never unconditionally: passing --depth to a full clone would introduce a
    # shallow boundary into a repository that did not have one.
    if git rev-parse --is-shallow-repository 2>/dev/null | grep -q true ; then
        git fetch -q --depth=1 ${GIT_FETCH_REMOTE} ${FETCH_REFSPEC}
    else
        git fetch -q ${GIT_FETCH_REMOTE} ${FETCH_REFSPEC}
    fi
    # Recorded immediately after the fetch, while the local refs still mirror the
    # remote — this is the value the push will lease against. Anything written
    # between here and the push is precisely what the lease must protect.
    # **A lease is a claim about the remote, so it is read from the remote.**
    # Reading the local refs after a fetch looks equivalent and is not: a fetch
    # only updates refs the remote actually has, so a ref that exists locally
    # and not remotely — a remote that moved, an earlier run against a different
    # GIT_REMOTE, residue from a failed run — leaves the local value in place
    # and the lease then claims something the remote never held. Every push then
    # dies "stale info", the retry re-fetches (a no-op, since the remote has
    # nothing to overwrite it with), finds the note it just wrote, and returns
    # it: exit 0, a number on stdout, and nothing published.
    OBSERVED_LAST=$(_remote_ref "${REFS_LAST}")
    OBSERVED_COMMITS=$(_remote_ref "${REFS_COMMITS}")
    OBSERVED_NOTES=$(_remote_ref "${REFS_NOTES}")
    FETCHED=1
    _logt -bare DONE
}

# The push remote's current value for a ref, or empty when it has none.
function _remote_ref {
    git ls-remote "${GIT_PUSH_REMOTE}" "$1" 2>/dev/null | cut -f1 || true
}

# `--force-with-lease=<ref>:<value>` for every ref we saw a value for. A ref that
# did not exist at fetch time gets no lease: there is nothing to compare against,
# and its creation is the first-run case rather than a conflict.
# Puts the local refs back to what the remote had, discarding a write that was
# never published.
function _restore_observed {
    _restore_one "${REFS_LAST}" "${OBSERVED_LAST}"
    _restore_one "${REFS_COMMITS}" "${OBSERVED_COMMITS}"
    _restore_one "${REFS_NOTES}" "${OBSERVED_NOTES}"
}

function _restore_one {
    if test -n "$2" ; then
        git update-ref "$1" "$2"
    else
        git update-ref -d "$1" 2>/dev/null || true
    fi
}

function _lease_args {
    if test -n "${OBSERVED_LAST}" ; then
        printf ' --force-with-lease=%s:%s' "${REFS_LAST}" "${OBSERVED_LAST}"
    fi
    if test -n "${OBSERVED_COMMITS}" ; then
        printf ' --force-with-lease=%s:%s' "${REFS_COMMITS}" "${OBSERVED_COMMITS}"
    fi
    if test -n "${OBSERVED_NOTES}" ; then
        printf ' --force-with-lease=%s:%s' "${REFS_NOTES}" "${OBSERVED_NOTES}"
    fi
}

function _push {
    _logt -n "Pushing to ${GIT_PUSH_REMOTE} ...    "
    #sleep 3
    # A push with no preceding fetch has nothing to lease against — but it must
    # not *fetch* to get one. `_fetch` force-updates the local refs from the
    # remote, so calling it here would discard exactly the local allocation the
    # user asked to publish: `push` destroyed local state, published nothing and
    # exited 0. Read the remote without touching anything local instead.
    if test "${FETCHED}" -ne 1 ; then
        OBSERVED_LAST=$(_remote_ref "${REFS_LAST}")
        OBSERVED_COMMITS=$(_remote_ref "${REFS_COMMITS}")
        OBSERVED_NOTES=$(_remote_ref "${REFS_NOTES}")
    fi
    # --atomic so a rejected lease on one ref cannot leave the others landed.
    # Without it a partial push publishes a counter without its note, or a note
    # without its chain entry, and the retry then has to reason about halves.
    git push -q --atomic ${GIT_PUSH_REMOTE} $(_lease_args) ${PUSH_REFSPEC} || {
        _logt -bare ERROR
        # ${1:-} because `set -u` is on and _push is called with no argument
        # from push, sync and force_buildnumber — where a failing push died with
        # "$1: unbound variable" instead of the message below.
        if test "${1:-}" != "nofail" ; then
            fail "Error while pushing to remote. Exiting"
        fi
        _logi "Error while pushing to remote"
        return 1
    }
    _logt -bare DONE
    return 0
}

function _force_incr {
    local attempt=${1:-1}
    _fetch
    _assert_clean_repository
    buildnumber=$( _generate_or_get )
    # **That ran in a subshell, and it fetched and pushed.** The observations
    # this process holds are from before it, so leasing against them refuses
    # every push here — burning a number per attempt and returning a higher one
    # than asked for. Re-observe before writing.
    _fetch
    # **The next number comes from the counter, never from HEAD's own note.**
    # Those differ whenever anything else has allocated since: with HEAD on 1
    # and the counter on 3, counting from the note yields 2 — a number another
    # commit already owns — and pushing it rolls the shared counter backwards,
    # so the following allocation hands out 3 a second time. The lease does not
    # catch it, because nothing else moved.
    lastbuildnumber=`git cat-file blob ${REFS_LAST} 2>/dev/null` || lastbuildnumber=${buildnumber}
    test "${lastbuildnumber}" -ge "${buildnumber}" || lastbuildnumber=${buildnumber}
    next_buildnumber=$(( $lastbuildnumber + 1 ))
    _write_buildnumber $next_buildnumber "force increment"
    _push nofail || {
        # Unbounded before: each pass incremented again, so a remote that kept
        # refusing burned a number per attempt and never stopped.
        test "${attempt}" -lt "${MAX_ATTEMPTS}" || \
            fail "Could not force-increment after ${MAX_ATTEMPTS} attempts."
        _logi "Another allocation won the race; refetching."
        _force_incr $(( attempt + 1 ))
        return 0
    }
    echo $next_buildnumber
}

function _assert_clean_repository {
    test $IGNORE_REPOSITORY_STATE = '1' || \
        git diff-index --quiet ${DIFF_INDEX_ARGS} HEAD || fail "Requires a clean repository state, without uncommitted changes."
}

MAX_ATTEMPTS=${MAX_ATTEMPTS:-10}

function _generate_or_get {
    local attempt=${1:-1}
    _assert_clean_repository

    # **Only the first attempt may trust a local note.** On a retry the local
    # note is the one we just wrote for the number that lost the race, and
    # returning it hands back a number another commit already owns — which was
    # the whole failure this retry exists to recover from. The fetch below
    # force-updates the notes ref from the remote, which discards that write.
    if test "${attempt}" -eq 1 ; then
        buildnumber=$(_get_existing_buildnumber) && echo $buildnumber && return 0
    fi

    _fetch

    buildnumber=$(_get_existing_buildnumber) && echo $buildnumber && return 0

    lastbuildnumber=`git cat-file blob ${REFS_LAST} 2>/dev/null` || {
        lastbuildnumber=0
        _logi "No buildnumber yet, starting one now."
    }

    buildnumber=$(( $lastbuildnumber + 1 ))

    _write_buildnumber $buildnumber "increment"

    _push nofail || {
        test "${attempt}" -lt "${MAX_ATTEMPTS}" || {
            # Leaving the unpublished write behind means the next run finds its
            # own note on attempt 1, returns it without fetching or pushing, and
            # reports a number nothing else in the world has.
            _restore_observed
            fail "Could not publish a build number after ${MAX_ATTEMPTS} attempts. Another job may be allocating continuously, or the remote is rejecting writes."
        }
        _logi "Another allocation won the race; refetching and taking the next number."
        _generate_or_get $(( attempt + 1 ))
        return 0
    }

    echo ${buildnumber}
}

case "${1:-generate}" in
    generate) # proceed with finding next build number
        _generate_or_get
    ;;
    fetch) _fetch && exit 0 ;;
    push) _push && exit 0 ;;
    sync) _fetch && _push && exit 0 ;;
    get) _fetch && check_existing_buildnumber && exit 0 ;;
    find | find-commit)
        test -z "$2" && usage && fail
        find_commit_by_buildnumber "$2"
        exit 0
    ;;
    force)
        test -z "$2" && usage && fail
        force_buildnumber "$2"
        exit 0
    ;;
    force-incr)
        _force_incr
        exit 0
    ;;
    log) log && exit 0 ;;
    help) usage && exit 0 ;;
    *)
        usage
        fail "Unknown argument ($*)"
    ;;
esac


######################
