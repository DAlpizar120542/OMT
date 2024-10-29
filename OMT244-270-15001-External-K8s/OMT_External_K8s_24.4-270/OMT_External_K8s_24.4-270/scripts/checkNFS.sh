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



# This script is used for checking the nfs/efs server
# exported folder. Check if it's writable;
# if it's empty and if it's has enough free disk space.

#set -x

#see feature: OCTFT19S1761772
if [[ "bash" != "$(readlink /proc/$$/exe|xargs basename)" ]];then
    echo "Error: only bash support, current shell: $(readlink /proc/$$/exe)"
    exit 1
fi
set +o posix

usage(){
    echo "Usage: $0 -t <type> -s <server> -f <folder> [Options]"
    echo -e "\n [Mandatory Options]"
    echo "          -t|--type                Specify type. 'nfs' or 'efs'"
    echo "          -s|--server              Specify server. (IPv4 or hostname)"
    echo "          -f|--folder              Specify folder. (e.g: /var/vol/nfs)"
    echo -e "\n [Other Options]"
    echo "          -d|--disk-space          Specify the required free disk space on server (unit: GB)"
    echo "          -e|--is-empty            Specify whether need check the folder is empty or not"
    echo "          -g|--gid                 Specify the group id exposed on server"
    echo "          -u|--uid                 Specify the user id exposed on server"
    echo ""
    exit 1;
}

while [ $# -ne 0 ];
do
    case "$1" in
    -s|--server)
        case "$2" in
          -*) echo -e "-s|--server parameter requires a value."; exit 1 ;;
          * ) if [ -z $2 ]; then echo -e "-s|--server parameter requires a value."; exit 1; fi; SERVER=$2; shift 2;;
        esac ;;
    -f|--folder)
        case "$2" in
          -*) echo -e "-f|--folder parameter requires a value."; exit 1 ;;
          * ) if [ -z $2 ]; then echo -e "-f|--folder parameter requires a value."; exit 1; fi; FOLDER=$2; shift 2;;
        esac ;;
    -d|--disk-space)
        case "$2" in
          -*) echo -e "-d|--disk-space parameter requires a value."; exit 1 ;;
          * ) if [ -z $2 ]; then echo -e "-d|--disk-space parameter requires a value."; exit 1; fi; DISK_SPACE=$2; shift 2;;
        esac ;;
    -u|--uid)
        case "$2" in
          -*) echo -e "-u|--uid parameter requires a value."; exit 1 ;;
          * ) if [ -z $2 ]; then echo -e "-u|--uid parameter requires a value."; exit 1; fi; USER_ID=$2; shift 2;;
        esac ;;
    -g|--gid)
        case "$2" in
          -*) echo -e "-g|--gid parameter requires a value."; exit 1 ;;
          * ) if [ -z $2 ]; then echo -e "-g|--gid parameter requires a value."; exit 1; fi; GROUP_ID=$2; shift 2;;
        esac ;;
    -t|--type)
        case "$2" in
          -*) echo -e "-t|--type parameter requires a value."; exit 1 ;;
          * ) if [ -z $2 ]; then echo -e "-t|--type parameter requires a value."; exit 1; fi; TYPE=$2; shift 2;;
        esac ;;
    --persistence-threshold)
        case "$2" in
          -*) echo -e "--persistence-threshold parameter requires a value."; exit 1 ;;
          * ) if [ -z $2 ]; then echo -e "--persistence-threshold parameter requires a value."; exit 1; fi; PERSISTENCE_THREHOLD=$2; shift 2;;
        esac ;;
    -e|--is-empty) IS_EMPTY='true'; shift;;
    *) usage;;
    esac
done

check_showmount(){
if [ $(which showmount > /dev/null 2>&1; echo $?) != 0 ]; then
        echo -e "Failed: command showmount not found"
        exit 1
fi
}

mount_server(){
if [ "$UID" -eq 0 ];then
    if [ ! -d ${TMP_FOLDER} ]; then mkdir -p ${TMP_FOLDER}; fi
    if grep -qs "${TMP_FOLDER}" /proc/mounts; then umount -f -l ${TMP_FOLDER} >/dev/null 2>&1; fi
    if ! mount -o rw ${SERVER}:${FOLDER} ${TMP_FOLDER} >/dev/null 2>&1; then
        if ! mount -o rw ${SERVER}:${FOLDER} ${TMP_FOLDER} -o nolock >/dev/null 2>&1; then
            echo -e "Failed: cannot mount ${SERVER}:${FOLDER}"
            exit 1
        fi
    fi
fi
if [ "$UID" -ne 0 ];then
    if [ ! -d ${TMP_FOLDER} ]; then mkdir -p ${TMP_FOLDER}; fi
    if grep -qs "${TMP_FOLDER}" /proc/mounts; then expect expect_mount ${TMP_FOLDER} >/dev/null 2>&1; fi
    if ! expect expect_mount ${SERVER}:${FOLDER} ${TMP_FOLDER} >/dev/null 2>&1; then
        if ! expect expect_mount ${SERVER}:${FOLDER} ${TMP_FOLDER} -o nolock >/dev/null 2>&1; then
            echo -e "Failed: cannot mount ${SERVER}:${FOLDER}"
            exit 1
        fi
    fi
fi
}

check_rw(){
if ! touch ${TMP_FOLDER}/rwcheck.txt >/dev/null 2>&1; then
    umount_server
    echo -e "Failed: no write permission under ${FOLDER}"
    exit 1
fi
}

check_flock(){
    timeout 5 flock -x -w 5 ${TMP_FOLDER}/flockCheck.txt echo "flock check pass"
    if [ $? != 0 ]; then
        $RM -f ${TMP_FOLDER}/flockCheck.txt
        umount_server
        echo -e "Failed: cannot get exclusive lock on a file under nfs folder ${FOLDER}. The fsid setting on nfs exports may cause this issue; check file '/etc/exports' on nfs server and remove the fsid setting if exists and restart the nfs server."
        exit 1
    fi
    $RM -f ${TMP_FOLDER}/flockCheck.txt
}

check_performance(){
    local threhold="${PERSISTENCE_THREHOLD:-128}"
    local timeIn=$(date "+%s")
    timeout 60 dd if=/dev/zero of=${TMP_FOLDER}/zeroFile bs=${threhold}K count=1 &>/dev/null
    local timeOut=$(date "+%s")
    if [[ $(( ${timeOut} - ${timeIn} )) -gt 2 ]]; then
        echo "Warning: The I/O performance of ${SERVER}:${FOLDER} may be inadequate."
    fi
    $RM -f ${TMP_FOLDER}/zeroFile
}

check_uid(){
if [ -n "$USER_ID" -a "$TYPE" = "nfs" ]; then
    local user=($(ls -l ${TMP_FOLDER}/rwcheck.txt|cut -d' ' -f3))
    if [[ "${user}" =~ ^[0-9]+$ ]] && [ $(grep -E ^${user}: /etc/passwd | wc -l) -eq 0 ]; then #uid
        local uid=${user}
    else   #username
        local uid=$(grep -E ^${user}: /etc/passwd | cut -d":" -f3)
    fi
    [[ "$uid" -eq 0 ]] && return
    if [ "$USER_ID" != "$uid" ]; then
        umount_server
        echo -e "Failed: Server exposed uid:$uid is not consistent with the setting of SYSTEM_USER_ID:$USER_ID."
        exit 1
    fi
fi
}

check_gid(){
if [ -n "$GROUP_ID" -a "$TYPE" = "nfs" ]; then
    local group=($(ls -l ${TMP_FOLDER}/rwcheck.txt|cut -d' ' -f4))
    if [[ "${group}" =~ ^[0-9]+$ ]] && [ $(grep -E ^${group}: /etc/group | wc -l) -eq 0 ]; then #gid
        local gid=${group}
    else   #groupname
        local gid=$(grep -E ^${group}: /etc/group | cut -d":" -f3)
    fi
    [[ "$gid" -eq 0 ]] && return
    if [ "$GROUP_ID" != "$gid" ]; then
        umount_server
        echo -e "Failed: Server exposed gid:$gid is not consistent with the setting of SYSTEM_GROUP_ID:$GROUP_ID."
        exit 1
    fi
fi
}

check_empty(){
if [ "$IS_EMPTY" = 'true' ]; then
  if [ $(ls ${TMP_FOLDER}|wc -w) -ne 0 ]; then
      umount_server
      echo -e "Failed: ${SERVER}:${FOLDER} is not empty"
      exit 1
  fi
fi
}

check_disk(){
if [ ! -z "$DISK_SPACE" ]; then
  local disk=$(df "${TMP_FOLDER}"| sed '1d'| awk '{printf "%.0f", $4/1024/1024}')
  if [ $(echo $disk $DISK_SPACE | awk '{print $1<$2}') -eq 1 ]; then
      echo -e "Warning: ${SERVER}:${FOLDER} has $disk GB free disk space; less than required $DISK_SPACE GB"
  fi
fi
}

umount_server(){
if [ "$UID" -eq 0 ];then
    $RM -f ${TMP_FOLDER}/rwcheck.txt && umount -f -l ${TMP_FOLDER} && $RMDIR ${TMP_FOLDER} >/dev/null 2>&1
fi
if [ "$UID" -ne 0 ];then
    $RM -f ${TMP_FOLDER}/rwcheck.txt && expect expect_umount ${TMP_FOLDER} && $RMDIR ${TMP_FOLDER} >/dev/null 2>&1
fi
}

CheckServer(){
  mount_server
  check_disk
  check_empty
  check_rw
  check_flock
  check_uid
  check_gid
  check_performance
  umount_server
}

#MAIN#
NOTFOUND_COMMANDS=()
findCommand(){
    local command=$1
    if [[ -x "/usr/bin/$command" ]] ; then
        echo "/usr/bin/$command"
    elif [[ -x "/bin/$command" ]] ; then
        echo "/bin/$command"
    else
        local cmd=
        cmd=$(which $command 2>/dev/null | xargs -n1 | grep '^/')
        if [[ -n "$cmd" ]] && [[ -x "$cmd" ]] ; then
            echo $cmd
        else
            echo $command
            return 1
        fi
    fi
}

for command_var in RM RMDIR ; do
    command="$(echo $command_var|tr '[:upper:]' '[:lower:]')"
    command_val=$(findCommand "$command")
    if [[ $? != 0 ]] ; then
        NOTFOUND_COMMANDS+=($command)
    fi
    eval "${command_var}=\"${command_val}\""
    export $command_var
done

if [[ ${#NOTFOUND_COMMANDS[@]} != 0 ]] ; then
    log "warn" "! Warning: The '${NOTFOUND_COMMANDS[*]}' commands are not in the /bin or /usr/bin directory, the script will use variable in the current user's system environment."
    read -p "Are you sure to continue(Y/N)?" confirm
    if [ "$confirm" != 'y' -a "$confirm" != 'Y' ]; then
        exit 1
    fi
fi

TMP_FOLDER=/tmp/cdf_nfs_readwrite_check_`date +%s%N | md5sum | head -c 10`
if [ ! -z "$SERVER" -a ! -z "$FOLDER" ]; then
    CheckServer
    echo -e "Checking server and shared folder: passed"
else
    echo -e "\nError: Please provide TYPE, SERVER and FOLDER.\n"
    usage
fi
