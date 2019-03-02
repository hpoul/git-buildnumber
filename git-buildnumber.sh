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
set -eu

VERSION=1.0

REMOTE=origin

REFS_BASE=refs/buildnumbers
REFS_LAST=${REFS_BASE}/last
REFS_NOTES=refs/notes/buildnumbers
REFSPEC="+${REFS_BASE}/*:${REFS_BASE}/* +refs/notes/*:refs/notes/*"

CMD_NOTES="git notes --ref=${REFS_NOTES}"

######################


function fail () {
    echo "FAIL: "
    echo "$1" >&2
    exit 1
}

function check_existing_buildnumber () {
    currentbuildnumber=`${CMD_NOTES} show  2>&1` && {
        echo $currentbuildnumber
        exit 0
    } || :
}

function find_commit_by_buildnumber {
    buildnumber=$1

    hash=`echo "$buildnumber" | git hash-object --stdin`
    notesfile=`git ls-tree $REFS_NOTES | grep "blob ${hash}" | cut -f 2`

    test -z "$notesfile" && fail "Unable to find commit for build number ${buildnumber}"

    git log "$notesfile" -1
}

function force_buildnumber {
    buildnumber=$1
    _write_buildnumber $buildnumber "forced"
    echo "Written build number."
    _push
}

function log {
    tail `git rev-parse --git-dir`/logs/${REFS_LAST}
}

function usage {
    echo git-buildnumber, version $VERSION
    echo Usage: $0 [command]
    echo "         (without command, uses 'generate')"
    echo
    echo Commands:
    echo "  generate             -- The default, outputs build number for current commit"
    echo "                          or generates a new one."
    echo "  find-commit <number> -- Finds the commit (message) for a given build number."
    echo "  force <number>       -- Uses the given number as the current buildnumber of"
    echo "                          the current commit."
}

function _write_buildnumber {
    buildnumber=$1
    reason=${2}
    set -x
    buildnumberhash=`echo "${buildnumber}" | git hash-object -w --stdin`
    git update-ref -m "buildnumber: ${buildnumber} (${reason})" --create-reflog ${REFS_LAST} ${buildnumberhash} `git show-ref -s refs/buildnumbers/last`
    ${CMD_NOTES} add -m "${buildnumber}" -f HEAD
}

function _push {
    git push -q $REMOTE ${REFSPEC}
}

git diff-index --quiet HEAD || fail "Requires a clean repository state, without uncommited changes."

case "${1:-generate}" in
    generate) # proceed with finding next build number
    ;;
    find-commit)
        test -z "$2" && usage && fail
        find_commit_by_buildnumber "$2"
        exit 0
    ;;
    force)
        test -z "$2" && usage && fail
        force_buildnumber "$2"
        exit 0
    ;;
    log) log && exit 0 ;;
    *)
        usage
        fail "Unknown argument ($*)"
    ;;
esac


######################

check_existing_buildnumber

git fetch -q $REMOTE ${REFSPEC}

check_existing_buildnumber

lastbuildnumber=`git cat-file blob ${REFS_LAST} 2>&1` || {
    lastbuildnumber=0
    echo "No buildnumber yet, starting one now."
}

buildnumber=$(( $lastbuildnumber + 1 ))

_write_buildnumber $buildnumber "increment"

_push

echo ${buildnumber}
