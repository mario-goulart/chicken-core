#!/bin/sh -e
#
# identify.sh - check for .git directory and obtain checked out revision and branch
#
# usage: identify.sh SOURCEDIR


# make sure file exists anyway, since branchname is a special case
if test \! -f "buildbranch"; then
    touch buildbranch
fi

rev0=`cat buildid || echo ""`
branchname0=`cat buildbranch || echo ""`
tag0=`cat buildtag.h || echo ""`
buildtime=`date +%Y-%m-%d`
host=`hostname`
usys=`uname`

if test -d "$1/.git"; then
    rev=`GIT_DIR="$1/.git" git rev-parse --short HEAD 2>/dev/null`
    branchname=`GIT_DIR="$1/.git" git branch --no-color 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/'`
    tag="#define C_BUILD_TAG \"compiled ${buildtime} on ${host} (${usys})\""
else
    branchname=${branchname:-"custom"}
    tag=${tag:-"#define C_BUILD_TAG \"compiled ${buildtime} on ${host} (${usys})\""}
fi

case "${branchname}" in
    "") branchname="";;
    "(no branch)") branchname="";;
    "master") branchname="";;
    "release") branchname="";;
esac
if test "x${rev0}" \!= "x${rev}"; then
    echo ${rev} >buildid
fi
if test "x${branchname0}" \!= "x${branchname}"; then
    echo ${branchname} >buildbranch
fi
if test "x${tag0}" \!= "x${tag}"; then
    echo ${tag} >buildtag.h
fi
