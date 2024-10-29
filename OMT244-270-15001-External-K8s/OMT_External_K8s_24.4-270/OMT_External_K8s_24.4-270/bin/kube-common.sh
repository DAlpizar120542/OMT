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

if [[ -f "/etc/profile.d/itom-cdf.sh" ]]; then
	source /etc/profile.d/itom-cdf.sh
fi

CURRENTDIR=$(cd "$(dirname "$0")";pwd)

if [ -f $CURRENTDIR/env.sh ]
then
	source $CURRENTDIR/env.sh
fi

LOCAL_IP=`ip route get 8.8.8.8|sed 's/^.*src \([^ ]*\).*$/\1/;q'`

OUTPUT_LEN=${OUTPUT_LEN:-75}
TIMEOUT=${TIMEOUT:-300}
K8S_HOME=${K8S_HOME:-"/opt/kubernetes"}
K8S_LOG_PATH=${K8S_LOG_PATH:-${K8S_HOME}/log}
INFO_LOG=${INFO_LOG:-${K8S_LOG_PATH}/info_$(date +%y%m%d%H%M%S).log}
ERR_LOG=${ERR_LOG:-${K8S_LOG_PATH}/err_$(date +%y%m%d%H%M%S).log}


trap 'echo -e "\033[?25h\033[0m";exit' HUP INT QUIT TSTP TERM

getTime(){
	date --rfc-3339=ns | sed 's/ /T/'
}

logger_info(){
	echo "$(getTime) INFO $*" >> ${INFO_LOG}
}

logger_warn(){
	echo "$(getTime) WARN $*" >> ${INFO_LOG}
}

logger_err(){
	echo "$(getTime) ERROR $*" >> ${INFO_LOG}
	echo "$(getTime) ERROR $*" >> ${ERR_LOG}
}

inf(){
	echo -e "$*"
	logger_info "$*"
}
warn(){
	echo -e WARN: "$*"
	logger_warn "$*"
}

err(){
	echo -e ERROR: "$*"
	logger_err "$*"
}
log_begin(){
	echo -e "$*\c"
	echo -e "$* \c" >> $INFO_LOG
}
log_end(){
	echo "$*"
	echo "$*" >> $INFO_LOG
}

showName() {
#
# print a string in length OUTPUT_LEN. padded with '.'
#
	s_name=$1
	len_of_name=${#s_name}
	len_of_dot=$((OUTPUT_LEN-len_of_name-1))

	echo -ne "$s_name "

	while(( $len_of_dot>0 ))
	do
		echo -ne "."
		len_of_dot=$((len_of_dot-1))
	done

	echo -ne " "
}

showStatus() {
	local msg=$*
	if [[ "$msg" =~ ^[0-9]*/[0-9]*$ ]]; then
		desired=`echo $msg | cut -d \/ -f 1`
		available=`echo $msg | cut -d \/ -f 2`
		if [ $desired -lt $available ]; then
			echo -e "\033[1m\033[31m$msg\033[?25h\033[0m"
		else
			echo -e "\033[1m\033[32m$msg\033[?25h\033[0m"
		fi
	else
		case "$(echo $msg|tr 'a-z' 'A-Z')" in
		PASSED|RUNNING|STOPPED|STARTED|DONE)
			echo -e "\033[1m\033[32m$msg\033[?25h\033[0m"
			;;
		IGNORED)
			echo -e "$msg\033[?25h\033[0m"
			;;
		*)
			echo -e "\033[1m\033[31m$msg\033[?25h\033[0m"
			;;
		esac
	fi


}

showSucc() {
	local msg=$*

	echo -e "\033[1m\033[32m$msg\033[?25h\033[0m"

}

showFail() {
	local msg=$*

	echo -e "\033[1m\033[31m$msg\033[?25h\033[0m"

}

rolling(){
    while true;do
        echo -ne '\b|'
        sleep 0.125
        echo -ne '\b/'
        sleep 0.125
        echo -ne '\b-'
        sleep 0.125
        echo -ne '\b\\'
        sleep 0.125
    done
}

startRolling(){
	rolling &
	ROLLID=$!
}

stopRolling(){
	if [[ -n $ROLLID ]];then
		echo -ne '\b'
		kill -s SIGTERM $ROLLID
		wait $ROLLID >/dev/null 2>&1
		ROLLID=""
	else
		ROLLID=
	fi
}

exec_cmd() {
    ${CURRENTDIR}/cmd_wrapper -c "$1" -f "$LOGFILE" $2 $3 $4 $5 $6
    return $?
}

execCmdWithRetry() {
    local cmd="$1"
    local retryTimes=1
    local maxTime=${2:-"60"}
    local waitTime=${3:-"1"}
    local cmdExtraOptions=${4:-""}
    while true; do
        exec_cmd "${cmd}" "$cmdExtraOptions"
        if [[ $? == 0 ]] ; then
            return 0
        elif (( $retryTimes >= ${maxTime} )); then
            return 1
        fi
        retryTimes=$(( $retryTimes + 1 ))
        sleep $waitTime
    done
}

CURRENT_PID=$$
spin(){
    local lost=
    local spinner="\\|/-"
    while :
    do
        if [[ -n "$lost" ]] ; then
            break
        fi
        for i in $(seq 0 3)
        do
            ps -p $CURRENT_PID > /dev/null 2>&1
            if [[ $? -ne 0 ]] ; then
                lost=true
                break
            fi
            echo -n "${spinner:$i:1}"
            echo -en "\010"
            ps -p $CURRENT_PID > /dev/null 2>&1
            if [[ $? -ne 0 ]] ; then
                lost=true
                break
            fi
            sleep 0.2
        done
    done
    CDF_LOADING_LAST_PID=
}

startLoading(){
    stopLoading
    spin &
    CDF_LOADING_LAST_PID=$!
}

stopLoading(){
    if [[ -n "$CDF_LOADING_LAST_PID" ]];then
        ps -p $CDF_LOADING_LAST_PID > /dev/null 2>&1
        if [[ $? == 0 ]] ; then
            kill -s SIGTERM $CDF_LOADING_LAST_PID >/dev/null 2>&1
            wait $CDF_LOADING_LAST_PID >/dev/null 2>&1
        fi
        CDF_LOADING_LAST_PID=
    fi
}
