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


#set -x
#default expose folder /nfsdir
#see feature: OCTFT19S1761772
if [[ "bash" != "$(readlink /proc/$$/exe|xargs basename)" ]];then
    echo "Error: only bash support, current shell: $(readlink /proc/$$/exe)"
    exit 1
fi
set +o posix

folder=${1:-"/var/vols/itom/core"}
isNFSServer=${2:-"true"}
userId=${3:-"1999"}
groupId=${4:-"1999"}
setupNFS(){
    echo "Setting up the NFS service ... "
    path=$(dirname $0)
    cd $path
    #check if NFS is installed
    isNFS=`rpm -qa|grep nfs-utils|wc -l`
    if [ $isNFS = 0 ]; then
        #install NFS with yum
        yum install -y nfs-utils 2>&1 1>/dev/null
        if [ $? != 0 ]; then
            echo "The NFS service installation failed."
            echo "If you have a CentOS repo or you can access the Internet from this host,"
            echo "you can install NFS with the command \"yum install -y nfs-utils\"."
            echo "If you don't have a CentOS repo and cannot access the Internet from this"
            echo "host, please download the nfs-utils and rpcbind packages and upload them"
            echo "to this host. Then run the command \"rpm -ivh <rpm-package-name>\" to install."
            exit 1
        fi
        isNFS=`rpm -qa|grep nfs-utils|wc -l`
        if [ $isNFS -gt 0 ]; then
            systemctl restart rpcbind
            systemctl enable rpcbind
            systemctl restart nfs-server
            systemctl enable nfs-server
            echo "The NFS service was installed successfully."
        fi
    else
        if ! systemctl status rpcbind >/dev/null 2>&1; then
            # need to start the service
            systemctl restart rpcbind
            systemctl enable rpcbind
        elif ! systemctl status nfs-server >/dev/null 2>&1; then
            # need to start the service
            systemctl restart nfs-server
            systemctl enable nfs-server
        fi
        echo "The NFS service was found to be already installed."
    fi
}

exposeFolder() {
    nfsdir=${1%*/}
    if [ "${nfsdir:0:1}" != "/" ] || [ ${#nfsdir} -eq 1 ]; then
      echo "error: folder should be absolute path and can not be '/'"
      exit 1
    fi
    echo "Exposing the folder ${nfsdir} ..."
    if [ -d $nfsdir ]; then
      if [ -n "$(ls -A $nfsdir)" ]; then
        echo "$nfsdir already exists and not empty, abort!"
        exit 1
      fi
      if [ "$(stat -c%u:%g $nfsdir)" != "${userId}:${groupId}" ]; then
        echo "$nfsdir already exists but the owner's <userId>:<groupId> should be ${userId}:${groupId}, abort!"
        exit 1
      fi
    else
        mkdir -p $nfsdir
        chown -R ${userId}:${groupId} $nfsdir
        chmod 755 $nfsdir
    fi
    isConfig=`grep -v '^$\|^\s*\#' /etc/exports|grep "$nfsdir "|wc -l `
    if [ $isConfig = 0 ]; then
      #if /etc/exports not end with newline, we need add a newline to prevent mixing 2 line into one
      if [[ $(tail -c1 /etc/exports | wc -l) -eq 0 ]];then
        echo "" >> /etc/exports
      fi
      echo "$nfsdir *(rw,sync,anonuid=${userId},anongid=${groupId},root_squash)">>/etc/exports
    fi

    exportfs -ra

}

configNfsFirewallSettings(){
    if [ $(systemctl status firewalld >/dev/null 2>&1; echo $?) -eq 0 ]; then
        local needReload
        local nfsPorts="111/tcp 111/udp 2049/tcp 2049/udp 20048/tcp 20048/udp 20049/tcp 20049/udp"
        local listPorts="$(firewall-cmd --list-ports 2>/dev/null)"
        echo -e "Note: The firewall service is running on this node. This script will open following necessary ports:
      ${nfsPorts// /, }"
        for port in $nfsPorts
        do
            if [[ ! "$listPorts" =~ "$port" ]]; then
                firewall-cmd --permanent --add-port=$port >/dev/null 2>&1
                needReload="true"
            fi
        done
        [ "$needReload" = "true" ] && firewall-cmd --reload >/dev/null 2>&1
    fi
}

#main

while [ "${1:0:1}" = "-" ]
do
    case $1 in
    -h|--help)
        echo -e "\n  This script is used to install NFS. You can configure NFS folder location, the userId and the groupId before the installtion of NFS. "
        echo -e "\n  If the firewall service is running on this node, this script will open the necessay ports automatically."
        echo -e "\n  1.To setup NFS by default, you don't need to enter any param. "
        echo -e "  Usage: $0 "
        echo -e "\n  P.S.  The default location of NFS folder will be at '/var/vols/itom/core'. "
        echo -e "        The default userId will be 1999 and the default groupId will be 1999. "
        echo -e "\n  2.To set NFS folder yourself, you should enter one param. "
        echo -e "  Usage: $0 [folder]"
        echo -e "\n  3.To set all the configurations yourself, you should enter 4 params. "
        echo -e "  Usage: $0 [folder] [true] [userId] [groupId]"
        echo -e "\n  Parameters: "
        echo -e "       [folder]           The NFS folder directory."
        echo -e "       [true]             Default value is true. If not true, it will not expose the NFS folder. "
        echo -e "       [userId]           To configure userId, please set it accorring to the parameter 'SYSTEM_USER_ID' in install.properties. "
        echo -e "       [groupId]          To configure groupId, please set it accorring to the parameter 'SYSTEM_GROUP_ID' in install.properties. "
        echo -e "\n  Options: "
        echo -e "       -h, --help         Print this help list."
        echo -e "\n  Examples: "
        echo -e "       $0                          Default setup. "
        echo -e "       $0 /xxx/xxx                 Set NFS folder. "
        echo -e "       $0 /xxx/xxx true 1999 1999  Set NFS folder, userId and groupId. "
        echo -e "       $0 -h                       Show help. "
        echo -e ""
        exit 0;;
    *)
        echo "$0: invalid option $1"
        echo "Try '$0 -h' for more information."
        exit 1;;
    esac
done

configNfsFirewallSettings
setupNFS
if [ "$isNFSServer" = true ]; then
    exposeFolder $folder
else
    echo "If you want to expose your nfs folder."
    echo "Usage: $0 [folder] [true] [userId] [groupId]"
fi
