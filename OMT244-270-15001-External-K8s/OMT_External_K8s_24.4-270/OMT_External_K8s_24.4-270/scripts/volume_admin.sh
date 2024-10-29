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


# This script is used for update the nfs/efs server pv

#see feature: OCTFT19S1761772
if [[ "bash" != "$(readlink /proc/$$/exe|xargs basename)" ]];then
    echo "Error: only bash support, current shell: $(readlink /proc/$$/exe)"
    exit 1
fi
set +o posix

#set -x
SCRIPT_NAME="volume_admin.sh"
usage(){
echo -e "Reconfigure Kubernetes Persistent Volumes

Usage: $SCRIPT_NAME  [command]

[Commands]
  reconfigure      Reconfigure persistent volumes
  down             Stop application services by volume or namespace
  up               Start application services by volume or namespace
  search           (deprecated) Search application services by volume or namespace
  generate         Generate volume usage configuration file

[Options]
  -h,--help       Show help
"
}
usage_reconfigure(){
echo -e "Reconfigure persistent volumes

Usage: $SCRIPT_NAME reconfigure <volume name> or -f <configuration file>
[Global options]
  -y,--yes                   Skip any confirmations

[Options for reconfigure by file]
  -f                         Configuration file

[Options for reconfigure specific volume]
  -t,--type                  Persistent volume type. Allowed values: nfs, azurefile, cephfs

[Options for -t nfs]
  -s,--server,--nfs-server   NFS server for persistent volume. Allowed value format: hostname, IP
  -p,--path,--nfs-path       NFS exported path for persistent volume. Example: /var/vols/itom/vol1

[Options for -t azurefile]
  --azurefile-secret-name    Secret containing Azure Storage Account Name and Key
  --azurefile-secret-ns      Namespace for the AzureFile secret (contains Azure Storage Account Name and Key)
  --azurefile-share-name     Share name
  --azurefile-read-only      (false) Set to true if filesystem is read-only

[Options for -t cephfs]
  --cephfs-monitors          Comma-delimited list of Ceph monitors
  --cephfs-path              Base mountpoint path. Default: /
  --cephfs-user              The RADOS user name. Default: admin
  --cephfs-secret-name       Secret containing user authentication
  --cephfs-secret-ns         Namespace for authentication secret
  --cephfs-read-only         (false) Set to true if filesystem is read-only

[Examples]
  # Reconfigure volumes using a configuration file
    $SCRIPT_NAME reconfigure -f vol_conf.yaml
  # Reconfigure a single NFS volume
    $SCRIPT_NAME reconfigure vol-test -t nfs -s test.server.com -p /var/vols/test
  # Reconfigure a single Azurefile volume
    $SCRIPT_NAME reconfigure vol-test -t azureFile --azurefile-secret-name test-secret --azurefile-secret-ns test-ns --azurefile-share-name test/path
  # Reconfigure a single CEPHFS volume
    $SCRIPT_NAME reconfigure vol-test -t cephfs --cephfs-monitors test.monitor1.com:6789,test.monitor2.com:6789,test.monitor3.com:6789 --cephfs-path test/path --cephfs-user test-user --cephfs-secret-name test-secret --cephfs-secret-ns test-ns
"
}

usage_misc(){
local command=$1 action deprecatedFlag
case $command in
    up)   action="Start";;
    down) action="Stop";;
    search) action="Search"; deprecatedFlag="(deprecated) ";;
esac
echo -e "$action application services by volume or namespace

Usage: $SCRIPT_NAME $command <volume> or -n <namespace>

[Options]
  -n,--namespace   ${deprecatedFlag}$action application services by namespace
  -h,--help        Show help

[Example]
  # $action all application services that use the specified persistent volume
    $SCRIPT_NAME $command test-vol
  # $action application services by namespace
    $SCRIPT_NAME $command -n test-ns
"
}
usage_generate(){
echo -e "Generate volume usage configuration file

Usage: $SCRIPT_NAME generate [command] [option]

[Commands]
  config           Generate volume usage configuration file
[Options]
  -h,--help        Show help
"
}
usage_generate_config(){
echo -e "Generate volume usage configuration file

Usage: $SCRIPT_NAME generate config [option]

[Options]
  -n,--namespace   (Mandatory) Generate volume usage configuration file by namespace
  -d,--dir         Output directory for configuration file
  -h,--help        Show help

[Example]
  # Generate a configuration file for the \"demo\" namespace
    $SCRIPT_NAME generate config -n demo
"
}

CURRENTDIR=$(cd `dirname $0`; pwd)
COMPONENTNAME=$(basename $0|cut -d'.' -f1)
MAX_RETRY=5

if [ -f /etc/profile.d/itom-cdf.sh ]; then
    source /etc/profile.d/itom-cdf.sh
else
    #volume_admin.sh requires root privilige. But CDF may not installed by root.
    #We need to correctly determine where itom-cdf.sh locates.
    USER_ID=$(stat -c "%u" $0 2>/dev/null)
    USER_NAME=$(id -nu $USER_ID 2>/dev/null)
    if [ $? -eq 0 ];then
        HOME_FOLDER=$(awk -v user=$USER_NAME 'BEGIN{FS=":"}{if(user==$1) {printf("%s\n",$6)}}' /etc/passwd 2>/dev/null)
        if [ -z "$HOME_FOLDER" ];then
            echo "HOME folder not found!"; exit 1
        fi
        source $HOME_FOLDER/itom-cdf.sh
    fi
fi

CDF_HOME=${CDF_HOME:-".."}
JQ=${CDF_HOME}/bin/jq
DATE=$(date "+%Y%m%d%H%M%S")
LOGDIR=$CDF_HOME/log/$COMPONENTNAME
LOGFILE=$LOGDIR/${COMPONENTNAME}-${DATE}.log
TMP_FOLDER=${TMP_FOLDER:-/tmp}
BACKUP_DIR=$TMP_FOLDER/$COMPONENTNAME
/bin/mkdir -p $LOGDIR $BACKUP_DIR
TYPE=nfs
TYPE_CHANGE="false"
SETTING_CHANGE="true"

exec_cmd(){
    ${CDF_HOME}/bin/cmd_wrapper -c "$1" -f "$LOGFILE" -x "DEBUG" $2 $3 $4 $5
    return $?
}
getRfcTime(){
    local fmt=$1
    date --rfc-3339=${fmt}|sed 's/ /T/'
}
uniformStepMsgLen(){
    local msgLen=$1
    local maxLen=80
    local dots=""
    [ "$msgLen" -gt "$maxLen" ] && local dotLen=3 ||  local dotLen=$(($maxLen-$msgLen))
    while [ $dotLen -gt 0 ]
    do
        dots="${dots}."
        dotLen=$((dotLen-1))
    done
    echo -n "$dots "
}
log() {
    local level=$1
    local msg=$2
    local consoleTimeFmt=$(date "+%Y-%m-%d %H:%M:%S")
    local logTimeFmt=$(getRfcTime 'ns')
    case $level in
        begin)
            echo -n "$consoleTimeFmt [INFO]: $msg" && uniformStepMsgLen "${#msg}" && echo -e "$logTimeFmt [INFO]: $msg" >>$LOGFILE
            ;;
        end)
            echo -e "$msg" && echo -e "[$msg]" >>$LOGFILE
            ;;
        debug)
            echo "$logTimeFmt [DEBUG]: $msg" >>$LOGFILE
            ;;
        info|warn|error)
            echo -e "$consoleTimeFmt [$(echo $level | tr [:lower:] [:upper:])]: $msg  " && echo "$logTimeFmt [$(echo $level | tr [:lower:] [:upper:])]: $msg" >>$LOGFILE
            ;;
        fatal)
            echo -e "$consoleTimeFmt [FATAL]: $msg  " && echo "$logTimeFmt [FATAL]: $msg" >>$LOGFILE
            echo -e "Please refer to $LOGFILE for more details."
            exit 1
            ;;
        *)
            echo -e "$consoleTimeFmt [INFO]: $msg  " && echo "$logTimeFmt [INFO]: $msg" >>$LOGFILE
            ;;
    esac
}
fatalOnInvalidParm(){
    echo "$1 parameter requires a value. "; exit 1;
}

setOptionVal(){
    local cli=$1
    local val=$2
    local var=$3
    local str=""

    case "$val" in
        -*) fatalOnInvalidParm "$cli" ;;
        * ) if [ -z "$val" ];then fatalOnInvalidParm "$cli" ; fi; str="${var}=\"${val}\"";  eval $str; export $var; ;;
    esac
}

printServices(){
    local allItems=$1
    local name kind maxNameLen=0 maxKindLen=0 nsLen=0 kindLen=0 nameLen=0
    for item in $allItems; do
        name=$(echo $item | awk -F: '{print $2}')
        kind=$(echo $item | awk -F: '{print $3}')
        if [ ${#name} -gt $maxNameLen ];then
            maxNameLen=${#name}
        fi
        if [ ${#kind} -gt $maxKindLen ];then
            maxKindLen=${#kind}
        fi
    done
    if [ ${#NAMESPACE} -gt 9 ]; then #"Namespace" contains 9 chars
        nsLen=$((${#NAMESPACE}+3))
    else
        nsLen=12
    fi
    kindLen=$((${maxKindLen}+3))
    nameLen=$((${maxNameLen}+3))

    printf "%-${nsLen}s %-${kindLen}s %-${nameLen}s\n" "Namespace" "Kind" "Name"
    for item in $allItems; do
        ns=$(echo $item | awk -F: '{print $1}')
        name=$(echo $item | awk -F: '{print $2}')
        kind=$(echo $item | awk -F: '{print $3}')
        printf "%-${nsLen}s %-${kindLen}s %-${nameLen}s\n" "$ns" "$kind" "$name"
    done
}
getNsServices(){
    local ns=$1  #either pvc namespace or namespace from option -n
    local volume nsName ns name allItems basicColOpt colOpt
    basicColOpt='--no-headers=true -o=custom-columns=Namespace:.metadata.namespace,Name:.metadata.name,Kind:.kind,Pvc:.spec.template.spec.volumes[*].persistentVolumeClaim.claimName'


    for kind in deploy ds sts; do
        case "$kind" in
        deploy) colOpt="${basicColOpt},Number:spec.replicas" ;;
        ds)     colOpt="${basicColOpt},Number:status.numberAvailable" ;;
        sts)    colOpt="${basicColOpt},Number:status.availableReplicas" ;;
        esac
        items=$(exec_cmd "kubectl get $kind -n $ns --no-headers=true $colOpt | awk '{ret=index(\$5,\"none\");if((\$5>0)&&(ret==0)) print \$1\":\"\$2\":\"\$3\":\"\$5}' | xargs" -p true)
        allItems="$allItems $items"
    done

    #running jobs
    colOpt="${basicColOpt},Status:.status.active"
    items=$(exec_cmd "kubectl get job -n $ns $colOpt | grep -v "none" | awk '{print \$1\":\"\$2\":\"\$3\":\"\$5}' | xargs" -p true)
    allItems="$allItems $items"

    echo "$allItems"
}
getVolServices(){
    local ns=$1
    local targetPvc=$2
	local allItems=

    for line in $(exec_cmd "kubectl get pods -n $ns --no-headers=true | awk '{print \$1\":\"\$3}'" -p=true); do
        podName=${line%%:*}
        status=${line#*:}
        if [ "$status" == "Completed" ];then  #not display the completed jobs
          continue
        fi

        podInfo=$(exec_cmd "kubectl get pods $podName  -n $ns  -o=custom-columns=NAME:.spec.volumes[*].persistentVolumeClaim.claimName,CONTROLLER:.metadata.ownerReferences[0].name,KIND:.metadata.ownerReferences[0].kind --no-headers=true" -p=true)
        while read pvcs controller kind; do  #pvcs is delimited by ','
           if [[ "$pvcs" == "<none>" ]]; then
               continue
           fi
           found=false
           pvcArray="${pvcs//,/ }"
           for pvc in ${pvcArray} ; do
               if [[ "$pvc" == "$targetPvc" ]]; then
                   found=true
                   break
                fi
           done

           if [ "$found" == "false" ]; then
               continue
           fi

           if [[ "$kind" == "ReplicaSet" ]]; then
             local pcPt=$(exec_cmd "kubectl get rs -n $ns $controller -o=custom-columns=CONTROLLER:.metadata.ownerReferences[0].name,KIND:.metadata.ownerReferences[0].kind --no-headers=true" -p=true)
             local parentController=$(echo "$pcPt" | awk '{print $1}')
             local parentType=$(echo "$pcPt" | awk '{print $2}')
             if [[ "$parentController" != "<none>" ]]; then
                  controller=$parentController
             fi
             if [[ "$parentType" != "<none>" ]]; then
                 kind=$parentType
             fi
           fi
           if [[ "$kind" == "<none>" ]]; then
				allItems="$allItems ${ns}:${podName}:Pod:<none>"
           else
               local replicas=$(kubectl get ${kind} -n ${ns} ${controller} -o=custom-columns=REPLICAS:.spec.replicas --no-headers=true)
			   allItems="$allItems ${ns}:${controller}:${kind}:${replicas}"
           fi
        done <<< "$podInfo"
    done
	echo "$allItems"
}
cmd_search() {
    local volumeName=$1
    local allItems nsName ns name
    if [ -n "$NAMESPACE" ];then
        allItems=$(getNsServices "$NAMESPACE")
    else
        [ -z "$volumeName" ] && volumeName=$VOLUME
        nsName=$(exec_cmd "kubectl get pv $volumeName -o=custom-columns=Ns:.spec.claimRef.namespace,Name:.spec.claimRef.name --no-headers=true" -p=true)
        if [ $? -ne 0 ];then
            log "fatal" "Failed to get pv: $volumeName"
        fi
        ns=$(echo $nsName | awk '{print $1}')
        name=$(echo $nsName | awk '{print $2}')
        if [[ -z "$name" ]] || [[ "$name" == "<none>" ]]; then
            log "warn" "PV: $volumeName is not bound to any PVC!"
            exit 0
        fi
        allItems=$(getVolServices "$ns" "$name")
    fi
    printServices "$allItems"
}

cmd_down() {
    if [ -n "$NAMESPACE" ];then
        local runningJobs=$(kubectl get job -n $NAMESPACE -o json | $JQ -r ".items[] | select(.status.active == 1).metadata.name?" | xargs)
        if [ -n "$runningJobs" ];then
            runningJobs=${runningJobs// /,}
            log "fatal" "There are still some running Jobs: $runningJobs in namespace: $NAMESPACE.Please run this command after all Jobs under namespace: $NAMESPACE are completed!"
        else
            cdfctl runlevel set -l DOWN -n $NAMESPACE
        fi
    else
        local volume nsName pvcConsumer consumerNs consumerKind consumerName consumerReplicas otherConsumerInfo otherConsumerName otherConsumerKind otherConsumerNs otherConsumerReplicas allItems
        volume=$VOLUME
        nsName=$(exec_cmd "kubectl get pv ${volume} -o=custom-columns=Ns:.spec.claimRef.namespace,Name:.spec.claimRef.name --no-headers=true" -p=true)
        if [ $? -ne 0 ];then
            log "fatal" "Failed to get PV: ${volume}"
        fi
        local pvcNs=$(echo $nsName | awk '{print $1}')
        local pvcName=$(echo $nsName | awk '{print $2}')
        if [[ -z "$pvcName" ]] || [[ "$pvcName" == "<none>" ]]; then
            log "warn" "PV: $volume is not bound to any PVC!"
            exit 0
        fi
        log "begin" "Checking if any running Jobs reference volume: $volume"
        local runningJobs=$(kubectl get job -n $pvcNs --no-headers=true -o=custom-columns=Name:.metadata.name,Pvc:.spec.template.spec.volumes[*].persistentVolumeClaim.claimName,Status:.status.active | grep "itom-vol-claim" | grep -v "none" | awk '{print $1}' | xargs)
        if [ -n "$runningJobs" ];then
            log "end" "[Failed]"
            runningJobs=${runningJobs// /,}
            log "fatal" "Volume: $volume is still referenced by some running Jobs:$runningJobs. Please run this command after all jobs are completed!"
        fi
        log "end" "[OK]"
        log "begin" "Backup information for application services referencing volume: $volume"
        if [[ ! -f "${BACKUP_DIR}/pvcConsumeList-${volume}" ]] || [[ $(cat ${BACKUP_DIR}/pvcConsumeList-${volume} 2>/dev/null | wc -w ) -eq 0 ]]; then
            allItems=$(getVolServices "$pvcNs" "$pvcName")
            echo "$allItems" > ${BACKUP_DIR}/pvcConsumeList-${volume}
        fi
        log "end" "[Done]"
        log "info" "Stopping application services:"
        for pvcConsumer in $(cat ${BACKUP_DIR}/pvcConsumeList-${volume}); do
            cache=$pvcConsumer
            pvcConsumer=(${pvcConsumer//:/ })
            consumerNs=${pvcConsumer[0]}
            consumerKind=${pvcConsumer[2]}
            consumerName=${pvcConsumer[1]}
    #Deployment: kubectl scale --replicas=0 deployment/<CONSUME> -n <NAMESPACE>, for example kubectl scale --replicas=0 deployment/idm-n core
            if [[ "${consumerKind}" == "Deployment" ]]; then
                exec_cmd "kubectl scale --replicas=0 deployment/${consumerName} -n ${consumerNs}" -p=true
            fi
    #StatefulSet:  kubectl scale --replicas=0 sts/<CONSUME> -n <NAMESPACE> , for example kubectl scale --replicas=0 sts/demo1-app-api -n demo1
            if [[ "${consumerKind}" == "StatefulSet" ]]; then
                if [[ "${consumerName}" =~ "prometheus" ]]; then
                    otherConsumerInfo=($(kubectl get deploy -n ${consumerNs} | grep "prometheus-operator"))
                    otherConsumerName=${otherConsumerInfo[0]}
                    otherConsumerKind="Deployment"
                    otherConsumerNs=${consumerNs}
                    otherConsumerReplicas=${otherConsumerInfo[1]##*/}
                    exec_cmd "kubectl scale --replicas=0 deploy/${otherConsumerName} -n ${otherConsumerNs}" -p=true
                    times=0
                    while [[ "$(kubectl get pod -n ${otherConsumerNs} 2>/dev/null|grep ${otherConsumerName} |wc -l)" > "0" ]]; do
                        if [[ ${times} -gt 30 ]]; then
                            log "fatal" "Failed to stop ${otherConsumerKind}: ${otherConsumerName}.${otherConsumerNs}"
                        fi
                        sleep 1
                        times=$(($times + 1))
                    done
                    sed -i "s/$cache//g" ${BACKUP_DIR}/pvcConsumeList-${volume}
                    pvcConsumeContent=$(cat ${BACKUP_DIR}/pvcConsumeList-${volume})
                    echo "$pvcConsumeContent ${otherConsumerNs}:${otherConsumerName}:${otherConsumerKind}:${otherConsumerReplicas}" > ${BACKUP_DIR}/pvcConsumeList-${volume}
                    # echo "${otherConsumerNs}                 ${otherConsumerKind}           ${otherConsumerName}                            ${otherConsumerReplicas}" >> ${BACKUP_DIR}/pvcConsumeList-${volume}
                    # sed -i '/'${consumerName}'/d' ${BACKUP_DIR}/pvcConsumeList-${volume}

                fi
                exec_cmd "kubectl scale --replicas=0 sts/${consumerName} -n ${consumerNs}" -p=true
            fi
    #ReplicaSet:   kubectl scale --replicas=0 replicaset/<CONSUME> -n <NAMESPACE>, for example kubectl scale --replicas=0 replicaset/mng-portal -n core
            if [[ "${consumerKind}" == "ReplicaSet" ]]; then
                exec_cmd "kubectl scale --replicas=0 replicaset/${consumerName} -n ${consumerNs}" -p=true
            fi
    #ReplicationController:  kubectl scale --replicas=0 rc/<CONSUME> -n <NAMESPACE>, for example kubectl scale --replicas=0 rc/test-n core
            if [[ "${consumerKind}" == "ReplicationController" ]]; then
                exec_cmd "kubectl scale --replicas=0 rc/${consumerName} -n ${consumerNs}" -p=true
            fi
    #one-time pod or job: kubectl delete pod <pod name> n <NAMESPACE>, for example kubectl delete pod test job -n core
            if [[ "${consumerKind}" == "Pod" ]]; then
                exec_cmd "kubectl delete ${consumerKind} ${consumerName} -n ${consumerNs}" -p=true
            fi
            if [[ "${consumerKind}" == "Job" ]]; then
                exec_cmd "kubectl delete ${consumerKind} ${consumerName} -n ${consumerNs}" -p=true
            fi
    #Daemonset: kubectl patch ds <daemonset name> -n <NAMESPACE> -p <patch content>, for example kubectl patch ds itom-fluentd -n core -p '{"spec": {"template": {"spec": {"nodeSelector": {"myKey": "myValue"}}}}}'
            if [[ "${consumerKind}" == "DaemonSet" ]]; then
                exec_cmd "kubectl patch ds ${consumerName} -n ${consumerNs} -p '{\"spec\": {\"template\": {\"spec\": {\"nodeSelector\": {\"pvcUpdate\": \"stop\"}}}}}'" -p=true
            fi
        done
    fi
    echo ""

    log "info" "All application services stopped"
    log "info" "Next steps:\n  1. Copy the application data from the old storage location to the new location.\n  2. After the copy, run \"volume_admin.sh reconfigure\" to reconfigure the volume."
}

cmd_up() {
    log "Info" "Starting application services ..."
    if [ -n "$NAMESPACE" ];then
        if [[ -f "${BACKUP_DIR}/pvcConsumeList-${volume}" ]]; then
            log "warn" "Find pvcConsumeList-* file under ${BACKUP_DIR}."
            log "fatal" "That may caused by:\n  1. You run 'volume_admin.sh down <volume>' previously, if so, run 'volume_admin.sh up <volume>' instead.\n  2. script run into exceptions, if so, remove pvcConsumeList-* file, and run volume_admin.sh up -n <namespace>."
        fi
        cdfctl runlevel set -l UP -n $NAMESPACE
    else
        local volume pvcConsumer consumerNs consumerKind consumerName consumerReplicas execStatus pv_json
        volume=$VOLUME
        nsName=$(exec_cmd "kubectl get pv ${volume} -o=custom-columns=Ns:.spec.claimRef.namespace,Name:.spec.claimRef.name --no-headers=true" -p=true)
        if [ $? -ne 0 ];then
            log "fatal" "Failed to get PV: ${volume}"
        fi
        local pvcNs=$(echo $nsName | awk '{print $1}')
        local pvcName=$(echo $nsName | awk '{print $2}')
        if [[ -z "$pvcName" || "$pvcName" == "<none>" ]]; then
        log "fatal" "PV: $1 is not bound to any PVC!"
        fi
        if [[ ! -f "${BACKUP_DIR}/pvcConsumeList-${volume}" ]]; then
            log "warn" "Can not find ${BACKUP_DIR}/pvcConsumeList-${volume}."
            log "fatal" "That may caused by:\n  1. Not run 'volume_admin.sh down <volume>' previously, if so, run 'volume_admin.sh down <volume>' first.\n  2.  Already run 'volume_admin.sh up <volume>', if so, no need to run 'volume_admin.sh up <volume>' again.\n  3. Stop the application services by 'volume_admin.sh down -n <namespace>' previously, if so,run 'volume_admin.sh up -n <namespace>'"
        fi
        for pvcConsumer in $(cat ${BACKUP_DIR}/pvcConsumeList-${volume}); do
            pvcConsumer=(${pvcConsumer//:/ })
            consumerNs=${pvcConsumer[0]}
            consumerKind=${pvcConsumer[2]}
            consumerName=${pvcConsumer[1]}
            consumerReplicas=${pvcConsumer[3]}
    #Deployment: kubectl scale --replicas=0 deployment/<CONSUME> -n <NAMESPACE>, for example kubectl scale --replicas=0 deployment/idm-n core
            if [[ "${consumerKind}" == "Deployment" ]]; then
                exec_cmd "kubectl scale --replicas=${consumerReplicas} deployment/${consumerName} -n ${consumerNs}" -p=true
                execStatus=$?
            fi
    #StatefulSet:  kubectl scale --replicas=0 sts/<CONSUME> -n <NAMESPACE> , for example kubectl scale --replicas=0 sts/demo1-app-api -n demo1
            if [[ "${consumerKind}" == "StatefulSet" ]]; then
                exec_cmd "kubectl scale --replicas=${consumerReplicas} sts/${consumerName} -n ${consumerNs}" -p=true
                execStatus=$?
            fi
    #ReplicaSet:   kubectl scale --replicas=0 replicaset/<CONSUME> -n <NAMESPACE>, for example kubectl scale --replicas=0 replicaset/mng-portal -n core
            if [[ "${consumerKind}" == "ReplicaSet" ]]; then
                exec_cmd "kubectl scale --replicas=${consumerReplicas} replicaset/${consumerName} -n ${consumerNs}" -p=true
                execStatus=$?
            fi
    #ReplicationController:  kubectl scale --replicas=0 rc/<CONSUME> -n <NAMESPACE>, for example kubectl scale --replicas=0 rc/test-n core
            if [[ "${consumerKind}" == "ReplicationController" ]]; then
                exec_cmd "kubectl scale --replicas=${consumerReplicas} rc/${consumerName} -n ${consumerNs}" -p=true
                execStatus=$?
            fi
            if [[ "${consumerKind}" == "Pod" ]]; then
                continue
            fi
            if [[ "${consumerKind}" == "Job" ]]; then
                continue
            fi
    #Daemonset: kubectl patch ds <daemonset name> -n <NAMESPACE> -p <patch content>, for example kubectl patch ds itom-fluentd -n core -p '{"spec": {"template": {"spec": {"nodeSelector": {"myKey": "myValue"}}}}}'
            if [[ "${consumerKind}" == "DaemonSet" ]]; then
                exec_cmd "kubectl patch ds ${consumerName} -n ${consumerNs} -p '{\"spec\": {\"template\": {\"spec\": {\"nodeSelector\": {\"pvcUpdate\": null}}}}}'" -p=true
                execStatus=$?
            fi
            if [[ "${execStatus}" != "0" ]]; then
                log "fatal" "Can not scale up ${consumerKind}: ${consumerName}.${consumerNs} ."
            fi
        done
        rm -f ${BACKUP_DIR}/pvcConsumeList-${volume}
    fi
    echo ""
    log "info" "All application services started."
}

getFileName(){
    local fname="$DIR/$1" number=0
    while [ -e "$fname" ]; do
        printf -v fname '%s/%s.%02d' "$DIR" "$1" "$(( ++number ))"
    done
    echo "$fname"
}
cmd_generate_config(){
    local pvNames fname
    pvNames=$(exec_cmd "kubectl get pv --no-headers=true -o=custom-columns=Namespace:.spec.claimRef.namespace,Name:.metadata.name 2>/dev/null | grep -w $NAMESPACE | awk '{print \$2}' | xargs" -p true)
    if [ $? -ne 0 ];then
        log "fatal" "Get PV info in namespace: $NAMESPACE failed!"
    fi
    if [ -z "$pvNames" ];then
        log "warn" "No PV is referenced in namespace: $NAMESPACE"; exit 0
    fi
    log "begin" "Starting configuration file generation"
    fname=$(getFileName "vol_${NAMESPACE}.yaml")
    echo -e "
#Seperate each volume definition with 3 hyphens,like below:
#---
###Example for NFS type:
#  name: itom-vol
#  type: nfs
#  server: nfs.server.com
#  path: /var/vols/itom-vol
###Example for AzureFile type:
#  name: itom-vol
#  type: azurefile
#  secretName: azurefile-secret
#  shareName: azurefile-share
#  secretNamespace: azurefile-secret-namespace
###Example for CephFs type:
#  name: itom-vol
#  type: cephfs
#  path: /cephfs/path
#  user: cephfs-user
#  secretName: cephfs-secret
#  secretNamespace: cephfs-secret-namespace
#  monitors: test.monitor1.com:6789,test.monitor2.com:6789,test.monitor3.com:6789

## Volumes referenced by PVCs in namespace \"$NAMESPACE\"" >>$fname
    local pvJson
    for name in $pvNames; do
        pvJson=$(exec_cmd "kubectl get pv $name -o json" -p true)
        if [ $? -ne 0 ];then
            log "fatal" "Failed to get PV: $name yaml definition"
        fi
        if [[ $(echo "$pvJson" | $JQ -r '.spec.nfs?') != "null" ]];then
            local server=$(echo "$pvJson" | $JQ -r '.spec.nfs.server')
            local path=$(echo "$pvJson" | $JQ -r '.spec.nfs.path')
            echo -e "
name: ${name}
type: nfs
server: ${server}
path: ${path}
---" >>$fname
        fi

        if [[ $(echo "$pvJson" | $JQ -r '.spec.azureFile?') != "null" ]];then
            local shareName=$(echo "$pvJson" | $JQ -r '.spec.azureFile.shareName')
            local secretName=$(echo "$pvJson" | $JQ -r '.spec.azureFile.secretName')
            local secretNamespace=$(echo "$pvJson" | $JQ -r '.spec.azureFile.secretNamespace')
            echo -e "
name: ${name}
type: azurefile
shareName: ${shareName}
secretName: ${secretName}
secretNamespace: ${secretNamespace}
---" >>$fname
        fi

        if [[ $(echo "$pvJson" | $JQ -r '.spec.cephfs?') != "null" ]];then
            local path=$(echo "$pvJson" | $JQ -r '.spec.cephfs.path')
            local user=$(echo "$pvJson" | $JQ -r '.spec.cephfs.user')
            local secretName=$(echo "$pvJson" | $JQ -r '.spec.cephfs.secretRef.name')
            local secretNamespace=$(echo "$pvJson" | $JQ -r '.spec.cephfs.secretRef.namespace')
            local monitors=$(echo "$pvJson" | $JQ -r '.spec.cephfs.monitors[]?' | xargs)
            monitors=${monitors// /,}
            echo -e "
name: ${name}
type: cephfs
path: ${path}
user: ${user}
secretName: ${secretName}
secretNamespace: ${secretNamespace}
monitors: ${monitors}
---" >>$fname
        fi
    done
    sed -i -e '$d' $fname  #remove the last ---
    log "end" "[OK]"

    echo "Configuration file saved to: $fname"
}


tmpMountDir=$TMP_FOLDER/cdf_nfs_readwrite_check
mount_server(){
    if [ ! -d ${tmpMountDir} ]; then mkdir -p ${tmpMountDir}; fi
    if grep -qs "${tmpMountDir}" /proc/mounts; then sudo umount -f -l ${tmpMountDir} >/dev/null 2>&1; fi
    if ! sudo mount -o rw ${NEW_NFS_SERVER}:${NEW_NFS_PATH} ${tmpMountDir} >/dev/null 2>&1; then
        if ! sudo mount -o rw ${NEW_NFS_SERVER}:${NEW_NFS_PATH} ${tmpMountDir} -o nolock >/dev/null 2>&1; then
            if [ ! "$confirm" = "true" ];then
                echo -e "Warning: unable to mount ${NEW_NFS_SERVER}:${NEW_NFS_PATH}."
                for((i=0;i<$MAX_RETRY;i++)); do
                    read -p "Are you sure the NFS server and path are correct? (Y/N): " answer
                    answer=$(echo "$answer" | tr '[A-Z]' '[a-z]')
                    case "$answer" in
                        y|yes ) break;;
                        n|no )  echo -e "quit."; exit 1 ;;
                        * )     write_log "warn" "Unknown input, Please input Y or N";;
                    esac
                    if [[ $i -eq $MAX_RETRY ]];then
                        echo -e "error input for $MAX_RETRY times, quit."
                    fi
                done
            fi
        fi
    fi
}

umount_server(){
    rm -f ${tmpMountDir}/rwcheck.txt && sudo umount -f -l ${tmpMountDir} 2>/dev/null && rmdir ${tmpMountDir} >/dev/null 2>&1
}

getPvPvcCommon(){
    local name=$1
    local type=$2

    local pvJson=$(exec_cmd "kubectl get pv $name -o json" -p=true)
    if [ $? -ne 0 ];then
        log "fatal" "Failed to get PV yaml definition!"
    fi

    #at this point, we can confirm the volume name, and set the backups prefix with volume name
    PVC_JSON=$BACKUP_DIR/pvc-${name}-${DATE}.json
    PV_JSON=$BACKUP_DIR/pv-${name}-${DATE}.json

    local typeSepc=$(echo "$pvJson" | $JQ -r ".spec[\"$type\"]")
    if [ -z "$typeSepc" ] || [ "$typeSepc" == "null" ];then
        TYPE_CHANGE="true"
    fi

    pvName=$(echo "$pvJson" | $JQ -r ".metadata.name")
    pvPvcLabel=$(echo "$pvJson" | $JQ -r ".metadata.labels.pv_pvc_label")
    pvCapStorage=$(echo "$pvJson" | $JQ -r ".spec.capacity.storage")
    pvAccessMode=$(echo "$pvJson" | $JQ -r -c ".spec.accessModes" | cut -d '[' -f2|cut -d ']' -f1)
    pvcPolicy=$(echo "$pvJson" | $JQ -r ".spec.persistentVolumeReclaimPolicy"); [ "$pvcPolicy" == "null" ] && pvcPolicy="Retain"
    storageClass=$(echo "$pvJson" | $JQ -r ".spec.storageClassName?"); [ "$storageClass" == "null" ] && storageClass=""
    nfsServer=$(echo "$pvJson" | $JQ -r ".spec.nfs.server?")
    nfsPath=$(echo "$pvJson" | $JQ -r ".spec.nfs.path?")
    azureFileSecretName=$(echo "$pvJson" | $JQ -r ".spec.azureFile.secretName?")
    azureFileSecretNs=$(echo "$pvJson" | $JQ -r ".spec.azureFile.secretNamespace?")
    azureFileShareName=$(echo "$pvJson" | $JQ -r ".spec.azureFile.shareName?")
    azureFileReadOnly=$(echo "$pvJson" | $JQ -r ".spec.azureFile.readOnly?")
    cephMonitors=$(echo "$pvJson" | $JQ -r '.spec.cephfs.monitors[]?' | xargs)
    cephPath=$(echo "$pvJson" | $JQ -r '.spec.cephfs.path?')
    cephUser=$(echo "$pvJson" | $JQ -r '.spec.cephfs.user?')
    cephSecretName=$(echo "$pvJson" | $JQ -r '.spec.cephfs.secretRef.name?')
    cephSecretNamespace=$(echo "$pvJson" | $JQ -r '.spec.cephfs.secretRef.namespace?')
    cephReadonly=$(echo "$pvJson" | $JQ -r '.spec.cephfs.readOnly?')
    provisionBy=$(echo "$pvJson" | $JQ -r '.metadata.annotations."pv.kubernetes.io/provisioned-by"?')
    if [ "$provisionBy" == "nfs-provisioner" ];then
        if [ -z "$CDF_NAMESPACE" ];then
            log "fatal" "OMT namespace not found!"
        fi
        nfsProvisoner=$(exec_cmd "helm list -n $CDF_NAMESPACE -o json 2>/dev/null | $JQ -r '.[]|select(.name == \"nfs-provisioner\").name'" -p true)
        if [ "$nfsProvisoner" == "$provisionBy" ];then
            provisionedByCDF="true"
            nfsProvisionerJson=$(exec_cmd "helm get values nfs-provisioner -n $CDF_NAMESPACE -o json 2>/dev/null" -p true)
            nfsProvisionerServer=$(echo $nfsProvisionerJson | $JQ -r ".nfs.server?"); [ "$nfsProvisionerServer" == "null" ] && nfsProvisionerServer=""
            nfsProvisionerPath=$(echo $nfsProvisionerJson | $JQ -r ".nfs.path?"); [ "$nfsProvisionerPath" == "null" ] && nfsProvisionerPath=""
        fi
    fi

    claimRefName=$(echo "$pvJson" | $JQ -r ".spec.claimRef.name?")
    claimRefNs=$(echo "$pvJson" | $JQ -r ".spec.claimRef.namespace?")
    #remove claimRef, so that user can restore directly by kubectl create -f
    echo "$pvJson" | $JQ -r 'del(.spec.claimRef,.metadata.finalizers)' > $PV_JSON

    #if volume is referenced by PVC, save the pvc definetion
    if [ -n "$claimRefName" ] && [ "$claimRefName" != "null" ] && [ -n "$claimRefNs" ] && [ "$claimRefNs" != "null" ];then
        if [ $(exec_cmd "kubectl get pvc $claimRefName -n $claimRefNs -o json | $JQ 'del(.metadata.creationTimestamp,.metadata.finalizers,.metadata.resourceVersion,.metadata.selfLink,.metadata.uid,.status)' > $PVC_JSON "; echo $?) -ne 0 ];then
            log "fatal" "Backup PVC: $claimRefNs/$claimRefName failed!"
        fi
    fi
}

stopReferencePvc(){
    local name="$1"
    #if the pv is referenced by pvc, we should delete the pvc before recreate pv and recreate the pvc after new pv is ready
    if [ -n "$claimRefName" ] && [ "$claimRefName" != "null" ];then
        log "begin" "Removing bound PVC: $claimRefName, namespace: $claimRefNs"
        if [ $(exec_cmd "kubectl delete pvc $claimRefName -n $claimRefNs --grace-period=0 --force=true  --wait=0" -p=false; echo $?) -eq 0 ];then
            #don't test the exit code here, because if the pvc is not using by any k8s resource, the patch may failed, but that fail is expected
            exec_cmd "kubectl patch pvc $claimRefName -n $claimRefNs -p '{\"metadata\":{\"finalizers\":null}}'" -p=false
            log "end" "[OK]"
        else
            if exec_cmd "kubectl get pvc $claimRefName -n $claimRefNs 2>&1|grep 'NotFound'";then
                log "end" ""
                while true; do
                    read -p "Warning: The current pvc $claimRefName no longer exists. Are you sure you want to delete its bound persistent volume: $name ? (yY/nN): " yn
                    case $yn in
                        YES|Yes|yes|Y|y )
                            return 5;;
                        NO|No|N|n )
                            echo -e "Keep the persistent volume: $name"
                            return 6
                            ;;
                        *)
                            echo -e "Please input y|Y|n|N"
                            ;;
                    esac
                done
            else
                log "end" "[Failed]"; exit 1
            fi
        fi
    fi
}
startReferencePvc(){
    if [ -n "$claimRefName" ] && [ "$claimRefName" != "null" ];then
        log "begin" "Recreating PVC: $claimRefName, namespace: $claimRefNs"
        if [ $(exec_cmd "kubectl create -f $PVC_JSON"; echo $?) -ne 0 ];then
            log "end" "[Failed]"; exit 1
        fi
        log "end" "[OK]"
    fi
}
deletePv(){
    log "begin" "Delete PV"
    #delete pv
    if [ $(exec_cmd "kubectl delete -f $PV_JSON"; echo $?) -ne 0 ];then
        exec_cmd "kubectl create -f $PVC_JSON"
        log "end" "[Failed]"; exit 1
    fi
    log "end" "[OK]"
}
recreatNfsVol(){
    local name=$1
    local targetServer=$2
    local targetPath=$3
    log "begin" "Recreating NFS volume: $name"
    if [ "$TYPE_CHANGE" == "true" ];then #from other volume type to NFS
        echo "
kind: PersistentVolume
apiVersion: v1
metadata:
  name: ${name}
spec:
  capacity:
    storage: ${pvCapStorage}
  accessModes:
    - ${pvAccessMode}
  persistentVolumeReclaimPolicy: ${pvcPolicy}
  storageClassName: ${storageClass}
  nfs:
    path: ${targetPath}
    server: ${targetServer}
" | kubectl create -f -  >>$LOGFILE 2>&1
        if [ $? -eq 0 ]; then
            log "end" "[OK]"; return 0
        else
            log "end" "[Failed]"; return 1
        fi
    else  #NFS to NFS
        if [ -n "$claimRefName" ];then
            $JQ "del(.spec.claimRef)|.spec.nfs.server=\"${targetServer}\"|.spec.nfs.path=\"${targetPath}\"" $PV_JSON | kubectl create -f - >>$LOGFILE 2>&1
        else
            $JQ ".spec.nfs.server=\"${targetServer}\"|.spec.nfs.path=\"${targetPath}\"" $PV_JSON | kubectl create -f - >>$LOGFILE 2>&1
        fi
        log "end" "[OK]"; return 0
    fi
}
recreate2AzureFileVol(){
    local name=$1
    local targetShareName=$2
    local targetSecretName=$3
    local targetSecretNamespace=$4
    log "begin" "Recreating AzureFile volume: $name ... "


    if [ "$TYPE_CHANGE" == "true" ];then #from other volume type to azureFile
        echo "
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${name}
spec:
  capacity:
    storage: ${pvCapStorage}
  accessModes:
    - ${pvAccessMode}
  persistentVolumeReclaimPolicy: ${pvcPolicy}
  azureFile:
    storageClassName: ${storageClass}
    secretName: ${targetSecretName}
    shareName: ${targetShareName}
    secretNamespace: ${targetSecretNamespace}
    readOnly: ${azureFileReadOnly}
" | kubectl create -f -  >>$LOGFILE 2>&1
        if [ $? -eq 0 ]; then
            log "end" "[OK]"; return 0
        else
            log "end" "[Failed]"; return 1
        fi
    else
        if [ -n "$claimRefName" ];then
            $JQ "del(.spec.claimRef)|.spec.azureFile.secretName=\"${targetSecretName}\"|.spec.azureFile.shareName=\"${targetShareName}\"|.spec.azureFile.secretNamespace=\"${targetSecretNamespace}\"|.spec.azureFile.readOnly=${azureFileReadOnly}" $PV_JSON | kubectl create -f - >>$LOGFILE 2>&1
        else
            $JQ ".spec.azureFile.secretName=\"${targetSecretName}\"|.spec.azureFile.shareName=\"${targetShareName}\"|.spec.azureFile.secretNamespace=\"${targetSecretNamespace}\"|.spec.azureFile.readOnly=${azureFileReadOnly}" $PV_JSON | kubectl create -f - >>$LOGFILE 2>&1
        fi
        log "end" "[OK]"; return 0
    fi
}
recreateCephfsVol(){
    local name=$1
    local targetPath=$2
    local targetUser=$3
    local monitors=$4
    local targetSecretName=$5
    local targetSecretNamespace=$6
    #as monitors is delimitered by , we can replace all comma to \",\", and pad the head and tail with double quote also,
    # then all items in the array are double quoted and seperated with each other by comma
    local monitors="\"${monitors//,/\",\"}\""

    log "begin" "Recreating CephFS persist volume: $name"

    if [ "$TYPE_CHANGE" == "true" ];then #from other volume type to cephfs
        echo "
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${name}
spec:
  capacity:
    storage: ${pvCapStorage}
  accessModes:
    - ${pvAccessMode}
  persistentVolumeReclaimPolicy: ${pvcPolicy}
  storageClassName: ${storageClass}
  cephfs:
    monitors:
    path: ${targetPath}
    user: ${targetUser}
    secretRef:
      name: ${targetSecretName}
      namespace: ${targetSecretNamespace}
    readOnly: ${cephReadonly}
" | yq e ".spec.cephfs.monitors += [$monitors]" - | kubectl create -f -  >>$LOGFILE 2>&1
        if [ $? -eq 0 ]; then
            log "end" "[OK]"; return 0
        else
            log "end" "[Failed]"; return 1
        fi
    else
        if [ -n "$claimRefName" ];then
            $JQ "del(.spec.claimRef,.spec.cephfs.monitors[]) | .spec.cephfs.monitors += [$monitors] | .spec.cephfs.path=\"${targetPath}\" | .spec.cephfs.user=\"${targetUser}\" | .spec.cephfs.secretRef.name=\"${targetSecretName}\" | .spec.cephfs.secretRef.namespace=\"${targetSecretNamespace}\" | .spec.cephfs.readOnly=${cephReadonly}" $PV_JSON | kubectl create -f - >>$LOGFILE 2>&1
        else
            $JQ "del(.spec.cephfs.monitors[]) | .spec.cephfs.monitors += [$monitors] | .spec.cephfs.path=\"${targetPath}\" | .spec.cephfs.user=\"${targetUser}\" | .spec.cephfs.secretRef.name=\"${targetSecretName}\" | .spec.cephfs.secretRef.namespace=\"${targetSecretNamespace}\" | .spec.cephfs.readOnly=${cephReadonly}" $PV_JSON | kubectl create -f - >>$LOGFILE 2>&1
        fi
        log "end" "[OK]"; return 0
    fi
}


configSingleVol(){
    TYPE=$(echo "$TYPE" | tr [:upper:] [:lower:])
    if [ "$TYPE" != "nfs" ] && [ "$TYPE" != "azurefile" ] && [ "$TYPE" != "cephfs" ];then
        log "fatal" "Error: Only support \"nfs/azurefile/cephfs\" type for volume reconfigure!"
    fi
    #the type is case sensitive in yaml definition
    if [ "$TYPE" == "azurefile" ];then
        TYPE="azureFile"
    fi

    local nsName ns name referenceSvc
    nsName=$(exec_cmd "kubectl get pv $VOLUME -o=custom-columns=Ns:.spec.claimRef.namespace,Name:.spec.claimRef.name --no-headers=true" -p=true)
    if [ $? -ne 0 ];then
        log "fatal" "Failed to get pv: $VOLUME"
    fi
    ns=$(echo $nsName | awk '{print $1}')
    name=$(echo $nsName | awk '{print $2}')
    if [[ -z "$name" ]] || [[ "$name" == "<none>" ]]; then
        log "warn" "PV: $VOLUME is not bound to any PVC!"
        exit 0
    fi

    log "begin" "Checking if volume: $VOLUME is referenced by any application service"
    referenceSvc=$(echo $(getVolServices "$ns" "$name"))
    if [[ -n $referenceSvc ]]; then
        log "end" "[Failed]"
        log "warn" "Volume: $VOLUME is still referenced by the following services:"
        printServices "$referenceSvc"
        log "fatal" "Please make sure all the consuming services have been stopped!"
    fi
    log "end" "[OK]"

    Confirm
    #parameter check
    case "$TYPE" in
        nfs)
            if [ -z "$NEW_NFS_PATH" ] || [ -z "$NEW_NFS_SERVER" ];then
                log "fatal" "NFS server/NFS path must not be empty!"
            fi
            # mount_server
            # umount_server
            reconfig2NfsType "$VOLUME" "$NEW_NFS_SERVER" "$NEW_NFS_PATH"
        ;;
        azureFile)
            if [ -z "${NEW_AZUREFILE_SCECRET_NAME}" ] || [ -z "${NEW_AZUREFILE_SHARE_NAME}" ] || [ -z "${NEW_AZUREFILE_SCECRET_NS}" ];then
                log "fatal" "AzureFile secret name/secret namespace/share name/readonly must not be empty!"
            fi
            reconfig2AzureFile "$VOLUME" "$NEW_AZUREFILE_SHARE_NAME" "$NEW_AZUREFILE_SCECRET_NAME" "$NEW_AZUREFILE_SCECRET_NS" "$NEW_AZUREFILE_READ_ONLY"
        ;;
        cephfs)
            NEW_CEPHFS_PATH=${NEW_CEPHFS_PATH:-"/"}
            NEW_CEPHFS_USER=${NEW_CEPHFS_USER:-"admin"}
            NEW_CEPHFS_READ_ONLY=${NEW_CEPHFS_READ_ONLY:-"false"}
            if [ -z "$NEW_CEPHFS_MONITORS" ] || [ -z "$NEW_CEPHFS_PATH" ] || [ -z "$NEW_CEPHFS_SECRET_NAME" ] || [ -z "$NEW_CEPHFS_SECRET_NS" ];then
              log "fatal" "cephfs monitors/path/secret name/secret namespace must not be emtpy!"
            fi
            reconfig2Cephfs "$VOLUME" "$NEW_CEPHFS_PATH" "$NEW_CEPHFS_USER" "$NEW_CEPHFS_MONITORS" "$NEW_CEPHFS_SECRET_NAME" "$NEW_CEPHFS_SECRET_NS" "$NEW_CEPHFS_READ_ONLY"
        ;;
    esac
}

Confirm(){
    if [ ! "$confirm" = "true" ];then
        while true; do
            echo "Warning:"
            if [ -n "$CONFIG_FILE" ];then
                echo "  You are about to reconfigure the persistent volume using configuration file: $CONFIG_FILE."
            else
                echo "  You are about to reconfigure the storage for persistent volume ${VOLUME}."
            fi
            echo -e "
   Please make sure you have completed the following prerequisite tasks:
     1) All the consuming application services have been stopped.
     2) All the data has been copied to the new storage location.
     3) In case of any exceptions, please resort to the backup folders:$BACKUP_DIR for restoring."
            if [ -n "$CONFIG_FILE" ];then
                read -p "Are you sure you want to reconfigure the persistent volume base on configuration file: $CONFIG_FILE? (yY/nN): " yn
            else
                read -p "Are you sure you want to reconfigure the persistent volume: ${VOLUME}? (yY/nN): " yn
            fi

            case $yn in
                YES|Yes|yes|Y|y )
                    break;;
                NO|No|N|n )
                    echo -e "change pv process QUIT."
                    exit 0
                    ;;
                *)
                    echo -e "Please input y|Y|n|N"
                    ;;
            esac
        done
    fi
}

reconfig2NfsType(){
    local name=$1
    local targetServer=$2
    local targetPath=$3
    local targetPathPrefix=${targetPath%/*}

    getPvPvcCommon "$name" "nfs"

    #if pv is not NFS type, nfsServer=null, nfsPath=null
    if [ "$(echo $targetServer | tr [:upper:] [:lower:])" == "$(echo $nfsServer | tr [:upper:] [:lower:])" ] && [ "$targetPath" == "$nfsPath" ];then
        log "warn" "The provided NFS configurations are same with the ones in PV:$name, no change is applied!"
        SETTING_CHANGE="false"
        return
    fi

    #if nfs is provisioned by our nfs-provisioner, and the target server/path not match, we should block the reconfiguration
    if [ "$provisionedByCDF" == "true" ];then
        if [[ "$(echo $targetServer | tr [:upper:] [:lower:])" != "$(echo $nfsProvisionerServer | tr [:upper:] [:lower:])" ]];then
            log "fatal" "The target NFS server doesn't match the one defined in NFS provisoner chart!"
        fi
        if [[ "$targetPathPrefix" != "$nfsProvisionerPath" ]]; then
            log "fatal" "The path prefix of the target NFS path doesn't match the one defined in NFS provisoner chart!"
        fi
    fi
    stopReferencePvc "$name"
    local rc="$?"
    if [ "$rc" -eq 0 ];then
        deletePv
        recreatNfsVol "$name" "$targetServer" "$targetPath"
        if [ $? -eq 0 ];then
            startReferencePvc
        fi
    elif [ "$rc" -eq 5 ];then
        deletePv
    fi
}
reconfig2AzureFile(){
    local name=$1
    local targetShareName=$2
    local targetSecretName=$3
    local targetSecretNamespace=$4
    local targeReadOnly=$5
    local newPath oldPath

    getPvPvcCommon "$name" "azureFile"
    [ "${targetShareName:0:1}" != "/" ] && newPath="/${targetShareName}" || newPath=${targetShareName}
    [ "${azureFileShareName:0:1}" != "/" ] && oldPath="/${azureFileShareName}" || oldPath=${azureFileShareName}
    if [ "$azureFileSecretName" == "$targetSecretName" ] && [ "$newPath" == "$oldPath" ];then
        if ([ "$azureFileSecretNs" == "null" ] && [ "$targetSecretNamespace" == "default" ]) || ([ "$azureFileSecretNs" != "null" ] && [ "$targetSecretNamespace" == "$azureFileSecretNs" ]);then
            log "warn" "The provided AzureFile configurations are same with the ones in PV: $name, no change is applied!"
            return
        fi
    fi
    #priority of 'readOnly': user-privided value > old-template-value > default value
    if [ -n "$targeReadOnly" ];then
        azureFileReadOnly=$targeReadOnly
    else
        if [ -z "$azureFileReadOnly" ] || [ "$azureFileReadOnly" == "null" ];then
            azureFileReadOnly="false"
        fi
    fi
    stopReferencePvc "$name"
    local rc="$?"
    if [ "$rc" -eq 0 ];then
        deletePv
        recreatNfsVol "$name" "$targetServer" "$targetPath"
        if [ $? -eq 0 ];then
            startReferencePvc
        fi
    elif [ "$rc" -eq 5 ];then
        deletePv
    fi
}
reconfig2Cephfs(){
    local name=$1
    local targetPath=$2
    local targetUser=$3
    local monitors=$4
    local targetSecretName=$5
    local targetSecretNamespace=$6
    local targeReadOnly=$7

    getPvPvcCommon "$name" "cephfs"
    if [ "$targetSecretName" == "$cephSecretName" ] && [ "$targetSecretNamespace" == "$cephSecretNamespace" ] && [ "$targetUser" == "$cephUser" ];then
        local newPath oldPath newMonitors oldMonitors
        #path may start with "/", may not, there are same for ceph
        [ "${targetPath:0:1}" != "/" ] && newPath="/${targetPath}" || newPath=${targetPath}
        [ "${cephPath:0:1}" != "/" ] && oldPath="/${cephPath}" || oldPath=${cephPath}
        if [ "$newPath" == "$oldPath" ];then
            #check if monitors are same
            newMonitors=(${monitors//,/ })
            oldMonitors=($cephMonitors)
            if [ ${#newMonitors[@]} -eq ${#oldMonitors[@]} ];then
                allMatch="true"
                for newMonitor in ${newMonitors[@]};do
                    monitorFound="false"
                    for oldMonitor in ${oldMonitors[@]};do
                        if [ "$(echo $newMonitor | tr [:upper:] [:lower:])" == "$(echo $oldMonitor | tr [:upper:] [:lower:])" ];then
                            monitorFound="true"
                            break
                        fi
                    done
                    if [ "$monitorFound" == "false" ];then
                        allMatch="false"
                        break
                    fi
                done
                if [ "$allMatch" == "true" ];then
                    log "warn" "The provided cephfs configurations are same with the ones in PV: $name, no change is applied!"
                    return
                fi
            fi
        fi
    fi
    #if not all configure setting are same, we need handle readOnly field, priority is same as azureFile
    if [ -n "$targeReadOnly" ];then
        cephReadonly=$targeReadOnly
    else
        if [ -z "$cephReadonly" ] || [ "$cephReadonly" == "null" ];then
            cephReadonly="false"
        fi
    fi
    stopReferencePvc "$name"
    local rc="$?"
    if [ "$rc" -eq 0 ];then
        deletePv
        recreatNfsVol "$name" "$targetServer" "$targetPath"
        if [ $? -eq 0 ];then
            startReferencePvc
        fi
    elif [ "$rc" -eq 5 ];then
        deletePv
    fi
}

cmd_reconfigure_with_file(){
    local configFile=$1
    local length name type nfsServer nfsPath shareName secretName secretNamespace path user monitors nsName pvcNs pvcName referenceSvc exitCode=0

    Confirm
    length=$(yq ea '[.] | length' $configFile)
    for((i=0;i<$length;i++));do
        name=$(yq ea "select(di == $i) | .name" $configFile); if [ "$name" == "null" ];then log "error" "Failed to get the name of No.$i volume from $configFile!"; continue; fi
        type=$(yq ea "select(di == $i) | .type" $configFile); if [ "$type" == "null" ];then log "error" "Failed to get the type of No.$i volume from $configFile!"; continue; fi
        type=$(echo "$type" | tr [:upper:] [:lower:])

        echo ""
        log "info" "Starting to reconfigure volume: $name ..."
        nsName=$(exec_cmd "kubectl get pv $name -o=custom-columns=Ns:.spec.claimRef.namespace,Name:.spec.claimRef.name --no-headers=true" -p=true)
        if [ $? -ne 0 ];then
            log "error" "Failed to get PV: $name, stop reconfiguring this volume.";
            exitCode=1
            continue
        fi
        pvcNs=$(echo $nsName | awk '{print $1}')
        pvcName=$(echo $nsName | awk '{print $2}')
        if [[ -z "$pvcName" ]] || [[ "$pvcName" == "<none>" ]]; then
            log "warn" "PV: $name is not bound to any PVC!"
        else
            log "begin" "Checking if volume: $name is referenced by any application service"
            referenceSvc=$(echo $(getVolServices "$pvcNs" "$pvcName"))
            if [[ -n $referenceSvc ]]; then
                log "end" "[Failed]"
                log "warn" "Volume: $name is still referenced by the following application services:"
                printServices "$referenceSvc"
                log "error" "Unable to reconfigureing volume: $name"
                exitCode=1
                continue
            fi
            log "end" "[OK]"
        fi

        case "$type" in
        nfs)
            nfsServer=$(yq ea "select(di == $i) | .server" $configFile); if [ "$nfsServer" == "null" ];then log "error" "Failed to get the server of No.$i volume from $configFile!"; exitCode=1; continue; fi
            nfsPath=$(yq ea "select(di == $i) | .path" $configFile); if [ "$path" == "null" ];then log "error" "Failed to get the path of No.$i volume from $configFile!"; exitCode=1; continue; fi
            reconfig2NfsType "$name" "$nfsServer" "$nfsPath"
            ;;
        azurefile)
            shareName=$(yq ea "select(di == $i) | .shareName" $configFile); if [ "$shareName" == "null" ];then log "error" "Failed to get the shareName of No.$i volume from $configFile!"; exitCode=1; continue; fi
            secretName=$(yq ea "select(di == $i) | .secretName" $configFile); if [ "$secretName" == "null" ];then log "error" "Failed to get the secretName of No.$i volume from $configFile!"; exitCode=1; continue; fi
            secretNamespace=$(yq ea "select(di == $i) | .secretNamespace" $configFile); if [ "$secretNamespace" == "null" ];then log "error" "Failed to get the secretNamespace of $i volume from $configFile!"; exitCode=1; continue; fi
            reconfig2AzureFile "$name" "$shareName" "$secretName" "$secretNamespace"
            ;;
        cephfs)
            path=$(yq ea "select(di == $i) | .path" $configFile); if [ "$path" == "null" ];then log "error" "Failed to get the path of No.$i volume from $configFile!"; exitCode=1; continue; fi
            user=$(yq ea "select(di == $i) | .user" $configFile); if [ "$user" == "null" ];then log "error" "Failed to get the user of No.$i volume from $configFile!"; exitCode=1; continue; fi
            monitors=$(yq ea "select(di == $i) | .monitors" $configFile); if [ "$monitors" == "null" ];then log "error" "Failed to get the monitors of No.$i volume from $configFile!"; exitCode=1; continue; fi
            secretName=$(yq ea "select(di == $i) | .secretName" $configFile); if [ "$secretName" == "null" ];then log "error" "Failed to get the secretName of No.$i volume from $configFile!"; exitCode=1; continue; fi
            secretNamespace=$(yq ea "select(di == $i) | .secretNamespace" $configFile); if [ "$secretNamespace" == "null" ];then log "error" "Failed to get the secretNamespace of No.$i volume from $configFile!"; exitCode=1; continue; fi
            reconfig2Cephfs "$name" "$path" "$user" "$monitors" "$secretName" "$secretNamespace"
            ;;
        *)  log "error" "Unrecognized volume type for No.$i volume in $configFile";exitCode=1;  ;;
        esac
    done
    exit $exitCode
}

parseOpt(){
    local cmd=$1; shift 1
    if [ -z "$1" ];then
        echo "Error: either provide a single volume or provide namespace with \"-n\"!"
        usage_misc "$cmd"; exit 1
    fi
    if [ "$1" == "-h" ] || [ "$1" == "--help" ];then
        usage_misc "$cmd"; exit 0
    fi
    if [ "$1" == "-n" ];then
        if [ -z "$2" ];then
            usage_misc "$cmd"; exit 2
        else
            NAMESPACE="$2"; step=2
        fi
    else
        VOLUME=$1; step=1
    fi
    shift $step
    if [ "$#" -gt 0 ];then
        echo "Error: Too many arguments!"
        usage_misc "$cmd"; exit 3
    fi
}

command=$1; shift 1
case "$command" in
search|down|up)
    parseOpt $command $@
    cmd_$command
    ;;
generate)
    target=$1; shift 1;
    if [ -z "$target" ]; then
        echo "Error: Please provide subcommand for: generate";  usage_generate; exit 1;
    fi
    if [ "$target" == "-h" ] || [ "$target" == "--help" ];then
        usage_generate; exit 0;
    fi
    if [ "$target" != "config" ];then
        echo "Error: Unrecognized subcommand: $target";  usage_generate; exit 1;
    fi
    if [ "$target" == "config" ]; then
        while [[ ! -z $1 ]] ; do
            step=2 ##shift step,default 2
            case "$1" in
            -n|--namespace)    setOptionVal "$1" "$2" "NAMESPACE";;
            -d|--dir)          setOptionVal "$1" "$2" "DIR";;
            -h|--help)         usage_generate_config; exit 0 ;;
            *) usage_generate_config; exit 1 ;;
            esac
            shift $step
        done
    fi
    if [ -z "$DIR" ];then
        DIR=$CURRENTDIR
    fi
    if [ -z "$NAMESPACE" ];then
        echo "Error: Please specify the namespace with \"-n\" option!"; usage_generate; exit 1
    fi
    if [ ! -d $DIR ]; then
        mkdir -p $DIR
    fi
    cmd_${command}_${target}
    ;;
reconfigure)
    if [ -z "$1" ]; then
        echo "Error: Please provide volume to be reconfigured or the configuration file with \"-f\""; usage_reconfigure; exit 1
    fi
    if [ "$1" == "-h" ];then
        usage_reconfigure; exit 0
    fi
    if [ "$1" == "-y" ];then
        confirm=true; shift 1
    fi
    if [ "$1" == "-f" ];then
        if [ -z "$2" ];then
            echo "Error: \"-f\" parameter requires a value."; usage_reconfigure; exit 1
        else
            CONFIG_FILE=$2; shift 2;
            if [ "$1" == "-y" ];then
                confirm=true; shift 1
            fi
            if [ $# -gt 0 ];then
                echo "Error: Too many arguments!"; exit 1
            fi
        fi
        cmd_reconfigure_with_file $CONFIG_FILE
    else
        VOLUME=$1; shift 1
        while [[ ! -z $1 ]] ; do
            step=2 ##shift step,default 2
            case "$1" in
            -t|--type)                             setOptionVal "$1" "$2" "TYPE";;
            -s|--server|--nfs-server)              setOptionVal "$1" "$2" "NEW_NFS_SERVER";;
            -p|--path|--nfs-path)                  setOptionVal "$1" "$2" "NEW_NFS_PATH";;
            --azurefile-secret-name)               setOptionVal "$1" "$2" "NEW_AZUREFILE_SCECRET_NAME";;
            --azurefile-secret-ns)                 setOptionVal "$1" "$2" "NEW_AZUREFILE_SCECRET_NS";;
            --azurefile-share-name)                setOptionVal "$1" "$2" "NEW_AZUREFILE_SHARE_NAME";;
            --azurefile-read-only)                 setOptionVal "$1" "$2" "NEW_AZUREFILE_READ_ONLY";;

            --cephfs-monitors)                     setOptionVal "$1" "$2" "NEW_CEPHFS_MONITORS";;
            --cephfs-path)                         setOptionVal "$1" "$2" "NEW_CEPHFS_PATH";;
            --cephfs-secret-name)                  setOptionVal "$1" "$2" "NEW_CEPHFS_SECRET_NAME";;
            --cephfs-secret-ns)                    setOptionVal "$1" "$2" "NEW_CEPHFS_SECRET_NS";;
            --cephfs-user)                         setOptionVal "$1" "$2" "NEW_CEPHFS_USER";;
            --cephfs-read-only)                    setOptionVal "$1" "$2" "NEW_CEPHFS_READ_ONLY";;
            -y|--yes)
            confirm=true;step=1;;
            *) usage; exit 1;;
            esac
            shift $step
        done
        configSingleVol

        if [ "$SETTING_CHANGE" == "true" ] && [ $? -eq 0 ];then
            echo -e "The persistent volume was reconfigured successfully."
            echo -e "Warning: You will need to start the consuming application services with: $SCRIPT_NAME up $VOLUME"
        fi
    fi
    ;;
-h|--help)
    usage; exit 0 ;;
*)
    echo "Unrecognized command: $command"; usage; exit 1 ;;
esac