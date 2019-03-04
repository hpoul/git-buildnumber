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

VERSION=1.0

GIT_REMOTE=${GIT_REMOTE:-origin}
GIT_PUSH_REMOTE=${GIT_PUSH_REMOTE:-${GIT_REMOTE}}
GIT_FETCH_REMOTE=${GIT_FETCH_REMOTE:-${GIT_REMOTE}}

REFS_BASE=refs/buildnumbers
REFS_LAST=${REFS_BASE}/last
REFS_COMMITS=${REFS_BASE}/commits
REFS_NOTES=refs/notes/buildnumbers
REFSPEC="+${REFS_BASE}/*:${REFS_BASE}/* +refs/notes/*:refs/notes/*"

CMD_NOTES="git notes --ref=${REFS_NOTES}"

######################


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

    blobhash=`git ls-tree $REFS_COMMITS "b${buildnumber}" | cut -f 1 | cut -d' ' -f3`
    commits=`git cat-file blob $blobhash`

    unique=`echo "$commits" | uniq`
    
    _logi "Found the following commits: \n$unique\n"

    git log $commits -1

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
    git log ${REFS_COMMITS}
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
    echo "  get                  -- show the build number for the current commit (if any)"
    echo "  sync                 -- fetch && push"
    echo "  fetch                -- fetch all refs from remote"
    echo "  push                 -- push all refs from remote"
}

__red="\e[1;91m"
__yellow="\e[33m"
__blue="\e[34m"
__dim="\e[2m"

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
    echo $arg -e "$color  $level $*\e[0m" >&2
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
    _logt "commitshash: $commitshash\n\n"
    if test -n "$commitshash" ; then
        parent="-p $commitshash"
        git ls-tree $commitshash | grep -v "\t${buildnumberfilename}$" > $treefile || :
        previous=`git ls-tree $commitshash ${buildnumberfilename} | cut -f1 | cut -d' ' -f3`
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
    newcommitshash=`git commit-tree $parent $treehash -m "${message}"`
    git update-ref -m "${message}" --create-reflog ${REFS_COMMITS} ${newcommitshash}

    rm $treefile $buildnumberfile

}

function _fetch {
    _logt -n "Fetching from ${GIT_FETCH_REMOTE} ...    "
    git fetch -q ${GIT_FETCH_REMOTE} ${REFSPEC}
    _logt -bare DONE
}

function _push {
    _logt -n "Pushing to ${GIT_PUSH_REMOTE} ...    "
    sleep 3
    git push -q ${GIT_PUSH_REMOTE} ${REFSPEC}
    _logt -bare DONE
}


case "${1:-generate}" in
    generate) # proceed with finding next build number
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
    log) log && exit 0 ;;
    help) usage && exit 0 ;;
    *)
        usage
        fail "Unknown argument ($*)"
    ;;
esac


######################

git diff-index --quiet HEAD || fail "Requires a clean repository state, without uncommited changes."

check_existing_buildnumber

_fetch

check_existing_buildnumber

lastbuildnumber=`git cat-file blob ${REFS_LAST} 2>&1` || {
    lastbuildnumber=0
    echo "No buildnumber yet, starting one now."
}

buildnumber=$(( $lastbuildnumber + 1 ))

_write_buildnumber $buildnumber "increment"

_push

echo ${buildnumber}
