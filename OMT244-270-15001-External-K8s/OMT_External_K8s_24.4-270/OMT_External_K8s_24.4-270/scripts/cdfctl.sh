#!/bin/bash
# Copyright 2017 - 2024 Open Text.
#
# The only warranties for products and services of Open Text and its affiliates and licensors ("Open Text")
# are as may be set forth in the express warranty statements accompanying such products and services.
# Nothing herein should be construed as constituting an additional warranty. Open Text shall not be liable
# for technical or editorial errors or omissions contained herein. The information contained herein is subject
# to change without notice.
#
# Except as specifically indicated otherwise, this document contains confidential information and a valid
# license is required for possession, use or copying. If this work is provided to the U.S. Government,
# consistent with FAR 12.211 and 12.212, Commercial Computer Software, Computer Software
# Documentation, and Technical Data for Commercial Items are licensed to the U.S. Government under
# vendor's standard commercial license.


if [[ "bash" != "$(readlink /proc/$$/exe|xargs basename)" ]];then
    echo "Error: only bash support, current shell: $(readlink /proc/$$/exe)"
    exit 1
fi
set +o posix

CURRENTDIR=$(cd "$(dirname "$0")";pwd)

if [ -f $CURRENTDIR/../bin/cdfctl ]; then
    exec $CURRENTDIR/../bin/cdfctl $@
elif [ -f $CURRENTDIR/../../bin/cdfctl ]; then
    exec $CURRENTDIR/../../bin/cdfctl $@
else
    echo "FATAL: Can not found cdfctl executable file !"
    exit 1
fi
