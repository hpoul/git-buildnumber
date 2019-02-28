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

REMOTE=origin

#git diff-index --quiet HEAD || fail "Requires a clean repository state, without uncommited changes."
REFS_BASE=refs/buildnumbers
REFS_LAST=${REFS_BASE}/last
REFS_NOTES=refs/notes/buildnumbers
REFSPEC="+${REFS_BASE}/*:${REFS_BASE}/* +refs/notes/*:refs/notes/*"

CMD_NOTES="git notes --ref=${REFS_NOTES}"

######################

function find_commit_by_buildnumber {
    buildnumber=$1

    hash=`echo "$buildnumber" | git hash-object --stdin`
    notesfile=`git ls-tree $REFS_NOTES | grep "blob ${hash}" | cut -f 2`

    test -z "$notesfile" && fail "Unable to find commit for build number ${buildnumber}"

    git log "$notesfile" -1
}

case "${1:-}" in
    "") # empty, proceed with finding next build number
    ;;
    find-commit)
        test -z "$2" && fail "Usage: $0 find-commit <build number>"
        find_commit_by_buildnumber "$2"
        exit 0
    ;;
    *)
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

buildnumberhash=`echo "${buildnumber}" | git hash-object -w --stdin`
git update-ref -m 'buildnumber: ${buildnumber}' ${REFS_LAST} ${buildnumberhash}
${CMD_NOTES} add -m "${buildnumber}" HEAD

git push -q $REMOTE ${REFSPEC}

echo ${buildnumber}
