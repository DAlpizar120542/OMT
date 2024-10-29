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

#see feature: OCTFT19S1761772
if [[ "bash" != "$(readlink /proc/$$/exe|xargs basename)" ]];then
    echo "Error: only bash support, current shell: $(readlink /proc/$$/exe)"
    exit 1
fi
set +o posix

usage(){
    echo -e "\nThis script is used to backup data of the control plane nodes.
The backed-up data can be used to recover the first control plane node when
all control plane nodes have crashed; restore the embedded PostgreSQL databases
, or restore Velero Helm release on embedded Kubernetes cluster.

Usage: $0 [Options]

[Options]
-m, --mode              backup, recover or restore. Allowable values: backup, recover, dbrestore, vlrestore
-b, --backup-path       fully qualified path to store the backup file
-t, --temp-path         temporary path to store data. If not specified, '/tmp' is used
-f, --file              the backup file to be used for recovery of the first control plane node or to restore embedded PostgreSQL databases
-h, --help              show this help message and exit
--no-encrypt            do not encrypt the backup package

Examples:
# Backup control plane node and output encrypted backup package
   $0 -m backup -b /opt/backup -t /opt/tmp
# Recover first control plane node
   $0 -m recover -f /opt/backup/cdf-br-master1.example.net-20211107081100.enc
# Restore embedded PostgreSQL databases
   $0 -m dbrestore -f /opt/backup/cdf-br-master1.example.net-20211107081100.enc
# Restore Velero helm release
   $0 -m vlrestore -f /opt/backup/cdf-br-master1.example.net-20211107081100.enc
"
exit 1
}

spin(){
    local lost=
    local spinner="\\|/-"
    trap "lost=true" SIGTERM
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
            printf "%c\010" "${spinner:$i:1}"
            ps -p $CURRENT_PID > /dev/null 2>&1
            if [[ $? -ne 0 ]] ; then
                lost=true
                break
            fi
            sleep 0.2
        done
    done
    echo " "
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

log() {
    local level=$1
    local msg=$2
    local consoleTimeFmt=$(date "+%Y-%m-%d %H:%M:%S")
    local logTimeFmt=$(date --rfc-3339=ns|sed 's/ /T/')
    [[ "$level" =~ ^(info|fatal|spin|warn|err)$ ]] && stopLoading
    case $level in
        info)       echo -e "[INFO] $consoleTimeFmt : $msg  " && echo "$logTimeFmt INFO  $msg" >>$LOG_FILE ;;
        warn)       echo -e "[WARN] $consoleTimeFmt : $msg  " && echo "$logTimeFmt WARN  $msg" >>$LOG_FILE ;;
        err)        echo -e "[ERR] $consoleTimeFmt : $msg  " && echo "$logTimeFmt ERR  $msg" >>$LOG_FILE ;;
        spin)       echo -en "[INFO] $consoleTimeFmt : $msg  " && echo "$logTimeFmt INFO  $msg" >>$LOG_FILE && startLoading ;;
        infolog)    echo "$logTimeFmt INFO  $msg" >>$LOG_FILE ;;
        fatal)      echo -e "[FATAL] $consoleTimeFmt : $msg  " && echo "$logTimeFmt FATAL $msg" >>$LOG_FILE; exit 1;;
        *)          echo -e "\n$msg  " && echo "$logTimeFmt INFO  $msg" >>$LOG_FILE ;;
    esac
}

exec_cmd(){
    cmd_wrapper -c "$1" -f $LOG_FILE -x=DEBUG $2 $3 $4 $5
    return $?
}

fatalOnInvalidParm(){
    echo -e "Error: $1 parameter requires a value.\n"
    usage
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

checkParam(){
    local key=$1;shift
    local val=$1;shift
    case "$key" in
        -m|--mode)
            if [ "$val" != "backup" -a "$val" != "recover" -a "$val" != "dbrestore" -a "$val" != "vlrestore" ];then
              echo -e "\nError: Invalid value for $key: $val, allowable values: backup, recover, dbrestore, vlrestore\n"
              exit 1
            fi
            ;;
        -b|--backup-path|-t|--temp-path)
            if ! echo "$val"|grep -Pq '^/';then
              echo -e "\nError: Invalid value for $key: '$val'; $key must be an absolute path.\n";
              exit 1
            fi
            ;;
        -f|--file)
            if [ ! -f "$val" ];then
              echo -e "\nError: File not found: $val.\n";
              exit 1
            fi
            ;;
        --no-encrypt)
            local msg="Warning: Unencrypted Backup Data - Security Risk Ahead!

Please be aware that choosing the option to perform an unencrypted backup carries inherent security risks.
Opting for an unencrypted backup may expose your sensitive information to potential vulnerabilities during both the transmission and storage processes.
"
            echo -e "$msg"
            read -p "Are you sure to continue(Y/N)?" confirm
            if [ "$confirm" != 'y' -a "$confirm" != 'Y' ]; then
                exit 1
            fi
            ;;
        *) echo -e "\nError: Invalid parameters: $key.\n"; usage;
            ;;
    esac
}

preCheck(){
    ##some pre-checks before executing this script
    # invalid usages
    if [ -z "$MODE" ] || [ -z "$BACKUP_PATH" -a "$MODE" = "backup" ] || [ "$MODE" = "recover" -a -z "$BACKUP_FILE" ] || [ "$MODE" = "dbrestore" -a -z "$BACKUP_FILE" ] || [ "$MODE" = "vlrestore" -a -z "$BACKUP_FILE" ]; then
        echo -e "\nError: Invalid usage.\n"
        usage
    fi
    # cannot backup on clean node
    if [ "$MODE" = "backup" ] && [ ! -f "/etc/profile.d/itom-cdf.sh" -a ! -f "$HOME/itom-cdf.sh" ];then
        echo -e "\nAbort: could not find a file itom-cdf.sh under /etc/profile.d or $HOME. Concluding kubernetes infrastructure has not been installed on this node. A backup cannot be created on this node.\n"
        exit 1
    fi
}

preBackup(){
    ## do NOT use exec_cmd in this func because logfile has not been defined.
    # source profiles
    if [[ -f "/etc/profile.d/itom-cdf.sh" ]];then
        source "/etc/profile.d/itom-cdf.sh"
    elif [ -f "$HOME/itom-cdf.sh" ]; then
        source $HOME/itom-cdf.sh
    fi
    [ -f "$CDF_HOME/bin/env.sh" ] && source $CDF_HOME/bin/env.sh
    #check env: classic or byok?
    #classic: exist images dir under CDF_HOME and have image files
    #otherwise: byok
    if [ $(ls $CDF_HOME/images/*.tgz 2>/dev/null | wc -l) -gt 0 ]; then
        CDF_MODE="classic"
    else
        CDF_MODE="byok"
    fi
    # set env
    CURRENT_DIR=$(cd "$(dirname "$0")";pwd)
    TEMP_PATH=${TEMP_PATH:-"/tmp"}
    LOG_DIR=$CDF_HOME/log/$(basename $0|cut -d'.' -f1)
    LOG_FILE=$LOG_DIR/$(basename $0|cut -d'.' -f1).$(date "+%Y%m%d%H%M%S").log
    LOG_MSG="For more details, refer to $LOG_FILE"
    mkdir -p $LOG_DIR
    export PATH=$PATH:$CDF_HOME/bin
    # print hint message
    if [ "$CDF_MODE" = "classic" ]; then
        BK_LIST=" - Node configuration
 - etcd
 - Vault
 - Kubernetes data
 - Velero release settings (if deployed)
 - Embedded PostgreSQL databases (if deployed)"
    else
        BK_LIST=" - Node configuration
 - etcd
 - Vault
 - Kubernetes data
 - Embedded PostgreSQL databases (if deployed)"
    fi
    echo -e "\nThis script will back up the following items. Please wait while Creating Backup...
${BK_LIST}\n"
}

backupNode(){
  if [ "$CDF_MODE" = "classic" ]; then
    log "info" "Back up node configuration"
    local backupDir=$TEMP_PATH/cdf_backup/node
    exec_cmd "/bin/mkdir -p $backupDir && /bin/rm -rf $backupDir/*"
    cd $backupDir
    exec_cmd "tar -zcpPf node_services.tar.gz /usr/lib/systemd/system/kubelet.service \\
                                              /usr/lib/systemd/system/containerd.service \\
                                              /usr/lib/systemd/system/containerd.service.d \\
              && tar -zcpPf cdf_home.tar.gz --exclude $CDF_HOME/log/audit/kube-apiserver/audit.log $CDF_HOME/{cfg,charts,log,manifests,objectdefs,properties,runconf,ssl} $CDF_HOME/*.{txt,json}"
    if [ $? -eq 1 ]; then
        log "fatal" "Some files were changed while being archived and so the resulting archive does not contain the exact copy of the file set..\nYou can try to rerun the script again."
    elif [ $? -eq 2 ]; then
        log "fatal" "Failed to back up CDF_HOME and node configuration files.\n$LOG_MSG"
    fi
    exec_cmd " /bin/cp -pf $CDF_HOME/bin/env.sh ./ \\
           && /bin/cp -rpf $CDF_HOME/cni/conf ./ \\
           && /bin/cp -pf $HOME/.kube/config ./kube-config \\
           && /bin/cp -pf /etc/profile.d/itom-cdf.sh ./ \\
           && /bin/cp -pf $CDF_HOME/version.txt ../"
    if [ $? != 0 ]; then
        log "fatal" "Failed to back up CDF_HOME and node configuration files.\n$LOG_MSG"
    fi
  elif [ "$CDF_MODE" = "byok" ]; then
    log "info" "No need to back up node configuration on managed Kubernetes cluster."
  fi
}

backupCm(){
  if [ "$CDF_MODE" = "classic" ]; then
    log "info" "Back up Kubernetes data"
    local backupDir=$TEMP_PATH/cdf_backup/cm
    local cm="cdf-cluster-host"
    local cmContent
    exec_cmd "/bin/mkdir -p $backupDir && /bin/rm -rf $backupDir/*"
    cd $backupDir
    #backup cluster-host cm
    cmContent=$(exec_cmd "kubectl get cm $cm -n $CDF_NAMESPACE -o json 2>/dev/null" -p=true)
    if [ $? = 0 ] ; then
        exec_cmd "echo '$cmContent' | jq -r .data | jq -r \"to_entries|map(\\\"\\(.key)=\\(.value|tostring)\\\")|.[]\" > basic_config.env"
        if [ $? != 0 ]; then
            log "fatal" "Failed to back up configmap $cm.\n$LOG_MSG"
        fi
    else
        log "fatal" "Failed to get configmap: $cm.\n$LOG_MSG"
    fi
    #backup pv info
    local pvc="itom-vol-claim"
    local pv=$(exec_cmd "kubectl get pvc $pvc -n $CDF_NAMESPACE -o json 2>/dev/null | jq -r '.spec.volumeName'" -p=true)
    if [ -n "$pv" ]; then
        local pvInfo=$(exec_cmd "kubectl get pv $pv -o json 2>/dev/null" -p=true)
        local nfsServer nfsPath
        if [ -n "$pvInfo" ]; then
            nfsServer=$(exec_cmd "echo '$pvInfo' | jq -r '.spec.nfs.server'" -p=true)
            nfsPath=$(exec_cmd "echo '$pvInfo' | jq -r '.spec.nfs.path'" -p=true)
            exec_cmd "echo 'itomvol_nfsserver=$nfsServer' >> basic_config.env \\
                   && echo 'itomvol_nfspath=$nfsPath' >> basic_config.env"
            if [ $? != 0 ]; then
              log "fatal" "Failed to backup the pv settings.\n$LOG_MSG"
            fi
        else
            log "fatal" "Failed to get pv details info: $pv.\n$LOG_MSG"
        fi
    else
        log "infolog" "Not found pv name base on pvc $pvc under $CDF_NAMESPACE namespace. Skip backup pv info. \n$LOG_MSG"
    fi
  elif [ "$CDF_MODE" = "byok" ]; then
    log "info" "No need to back up Kubernetes data on managed Kubernetes cluster."
  fi
}

backupEtcd(){
  if [ "$CDF_MODE" = "classic" ]; then
    log "info" "Back up etcd data"
    local backupDir=$TEMP_PATH/cdf_backup/etcd
    exec_cmd "/bin/mkdir -p $backupDir && /bin/rm -rf $backupDir/*"
    cd $backupDir
    exec_cmd "ETCDCTL_API=3 etcdctl --endpoints ${ETCD_ENDPOINT} \\
                                    --cacert ${CDF_HOME}/ssl/ca.crt \\
                                    --cert ${CDF_HOME}/ssl/etcd-server.crt \\
                                    --key ${CDF_HOME}/ssl/etcd-server.key \\
                                    snapshot save snapshot.db"
    if [ $? != 0 ]; then
        log "fatal" "Failed to back up the etcd data.\n$LOG_MSG"
    fi
  elif [ "$CDF_MODE" = "byok" ]; then
    log "info" "No need to back up etcd data on managed Kubernetes cluster."
  fi
}

waitForResourceReady(){
    local name=$1
    local type=${2:-"deploy"}
    local ns=${3:-"$CDF_NAMESPACE"}
    local maxRetry=${4:-"30"}
    local sec=${5:-"0"}
    local canSkipCheck=${6:-"false"}
    local sleepSec=30 retry=0
    #wait for $sec seconds before checking
    if [ "$sec" -gt 0 ];then
        log "infolog" "wait for $sec seconds before status checking"
        exec_cmd "sleep $sec"
    fi
    #check if the component exist
    if ! exec_cmd "kubectl get $type $name -n $ns"; then
        if [ "$canSkipCheck" = "true" ]; then
            log "infolog" "Could not find component $name under $ns namespace, skip checking"
            return 0
        else
            log "fatal" "Could not find component $name under $ns namespace"
        fi
    fi
    #start check
    while true
    do
        local status=$(exec_cmd "kubectl get $type $name -n $ns -o json 2>/dev/null | jq -r '.status'" -p=true)
        local readyReplicas replicas availableReplicas unavailableReplicas
        replicas=$(echo $status | jq -r '.replicas')
        readyReplicas=$(echo $status | jq -r '.readyReplicas')
        availableReplicas=$(echo $status | jq -r '.availableReplicas')
        unavailableReplicas=$(echo $status | jq -r '.unavailableReplicas?')
        if [ "$unavailableReplicas" = "null" -a "$replicas" = "$readyReplicas" -a "$readyReplicas" = "$availableReplicas" -a "$replicas" -gt 0 ]; then
            return 0
        else
            if [ "$retry" -gt "$maxRetry" ];then
                return 1
            else
                retry=$((retry+1))
                sleep $sleepSec
            fi
        fi
    done
}

backupVault(){
    #in thinhelm mode, itom-vault may not be deploy.
    if ! kubectl get deploy itom-vault -n $CDF_NAMESPACE >/dev/null 2>&1; then
        log "info" "Could not find itom-vault deployment, no need to back up vault data."
        return 0
    fi
    #
    log "info" "Back up Vault data"
    local backupDir=$TEMP_PATH/cdf_backup/vault
    exec_cmd "/bin/mkdir -p $backupDir && /bin/rm -rf $backupDir/*"
    cd $backupDir
    #backup vault credentials
    log "infolog" "* back up vault credentials"
    for secret in vault-credential vault-passphrase
    do
        local content
        content=$(exec_cmd "kubectl get secret $secret -n $CDF_NAMESPACE -o yaml 2>/dev/null" -p=true -o=false)
        if [ $? = 0 ]; then
            echo "$content" > ${secret}.yaml
        else
            log "fatal" "Failed to back up vault credentials (secret: $secret) under $CDF_NAMESPACE namespace.\n$LOG_MSG"
        fi
    done
    #backup vault-params-key vault keys
    if kubectl get svc cdf-svc -n $CDF_NAMESPACE >/dev/null 2>&1 && [ "$CDF_MODE" = "classic" ]; then
        log "infolog" "* back up vault-params-key vault keys"
        local tokenPass encToken vaultToken
        local name="itom-vault"
        tokenPass=$(cat ./vault-passphrase.yaml | grep 'passphrase:' | awk '{print $2}')
        encToken=$(cat ./vault-credential.yaml | grep 'root.token:' | awk '{print $2}')
        vaultToken=$(echo $encToken | openssl aes-256-cbc -md sha256 -a -d -pass pass:"${tokenPass}" 2>/dev/null)
        local svcIp roleId keys
        svcIp=$(kubectl get svc $name -n ${CDF_NAMESPACE} -o json 2>/dev/null | jq -r '.spec.clusterIP' )
        if [ -z "$svcIp" ]; then
            log "fatal" "Failed to get $name service ip.\n$LOG_MSG"
        fi
        roleId=$(curl -k --silent --header "X-Vault-Token: $vaultToken" --noproxy "$svcIp" https://${svcIp}:8200/v1/auth/approle/role/${CDF_NAMESPACE}-baseinfra/role-id 2>/dev/null | jq -r '.data.role_id')
        if [ -z "$roleId" ]; then
            log "fatal" "Failed to get vault role id for role:${CDF_NAMESPACE}-baseinfra.\n$LOG_MSG"
        fi
        keys=$(curl -k --silent -X LIST --header "X-Vault-Token: $vaultToken" --noproxy "$svcIp" https://${svcIp}:8200/v1/itom/suite/$roleId 2>/dev/null | jq -r '.data.keys[]')
        if [ -z "$keys" ]; then
            log "fatal" "Failed to list vault keys for role:${CDF_NAMESPACE}-baseinfra.\n$LOG_MSG"
        fi
        for key in $keys
        do
            #for thinhelm mode, does not exist this key, so will not be backup
            if [[ "$key" =~ "vault-params-key" ]]; then
                local val
                val=$(curl -k --silent --header "X-Vault-Token: $vaultToken" --noproxy "$svcIp" https://${svcIp}:8200/v1/itom/suite/$roleId/$key 2>/dev/null | jq -r '.data.value')
                if [ -z "$val" ]; then
                    log "fatal" "Failed to get the value of key: $key \n$LOG_MSG"
                fi
                echo "$val" > ${key}.json
            fi
        done
    fi
}

dbBRStatus(){
    local action=$1
    local location=$2
    local token=$3
    local statusInfo status
    local maxRetry=30
    local sleepSec=10
    local t=0

    while true
    do
        statusInfo=$(echo $token | $CDF_HOME/tools/postgres-backup/db_admin.sh status -t $action -l $location --no-header)
        if [ $? = 0 ]; then
            status=$(echo "$statusInfo" | jq -r '.status')
            if [ "$status" = "SUCCESS" ];then
              return 0
            elif [ "$status" = "FAILED" ]; then
              echo "$statusInfo"
              return 1
            else
              if [ "$t" -ge "$maxRetry" ]; then
                  echo "$statusInfo"
                  return 1
               else
                  t=$((t+1))
                  sleep $sleepSec
               fi
            fi
        else
            echo "$statusInfo"
            return 2
        fi
    done
}

backupDb(){
    local deploy="itom-pg-backup"
    if ! kubectl get deployment $deploy -n $CDF_NAMESPACE >/dev/null 2>&1; then
      log "info" "Not using the embedded PostgreSQL databases as there's no $deploy deployment in the $CDF_NAMESPACE namespace. If the cluster is deployed with external database, you're responsible to back up the database by yourselves."
      return 0
    fi
    log "spin" "Back up embedded PostgreSQL databases"
    #trigger backup progress
    local backupDir=$TEMP_PATH/cdf_backup/embedded_pg
    exec_cmd "/bin/mkdir -p $backupDir && /bin/rm -rf $backupDir/*"
    local tokenInfo token backupMsg bkLocation
    local scriptDir="$CDF_HOME/tools/postgres-backup"
    tokenInfo=$(exec_cmd "$scriptDir/getRestoreToken" -p=true)
    if [ $? = 0 ]; then
        token=$(echo $tokenInfo|awk -F 'Authorization token:' '{print $2}')
    else
        log "fatal" "Failed to get database backup token with tool 'getRestoreToken'; error message: $tokenInfo . \n$LOG_MSG"
    fi
    backupMsg=$(exec_cmd "echo $token | $scriptDir/db_admin.sh backup" -p=true)
    if [ $? = 0 ]; then
        bkLocation=$(echo $backupMsg | awk -F 'Backup location:' '{print $2}')
        exec_cmd "echo $bkLocation > $backupDir/backup-location.txt"
    else
        log "fatal" "Failed to back up embedded postgres database; error message: $backupMsg . \n$LOG_MSG"
    fi
    #fetch backup status
    log "infolog" "Check the backup progress"
    local msg
    msg=$(dbBRStatus "backup" "$bkLocation" "$token")
    if [ $? != 0 ]; then
        log "fatal" "Failed to back up embedded postgresql database; error message: $msg . \n$LOG_MSG"
    fi
    #
    stopLoading
}

getHelmReleases(){
    local result=
    local code=
    result=$(exec_cmd "helm list -n $CDF_NAMESPACE" -p=true)
    code=$?
    echo "$result"
    if [ $code != 0 ]; then
        return 1
    fi
}

releaseInstalled(){
    local releaseList=$1
    local releaseName=$2
    if $(echo "$releaseList" | grep -q "$releaseName"); then
        return 0
    fi
    return 1
}

backupVelero(){
    if [ "$CDF_MODE" = "classic" ]; then
        log "spin" "Back up Helm release settings of Velero"
        local releaseName="itom-velero"
        local releaseList=
        releaseList=$(getHelmReleases)
        if [ $? != 0 ]; then
            log "fatal" "Failed to get helm release list; error message: $releaseList . \n$LOG_MSG"
        fi
        if ! $(releaseInstalled "$releaseList" "$releaseName"); then
            log "warn" "Could not find release $releaseName; skip Velero release settings backup."
            return
        fi
        #backup release values
        local backupDir="$TEMP_PATH/cdf_backup/velero"
        local valuesFile="$backupDir/values.txt"
        exec_cmd "/bin/mkdir -p $backupDir && /bin/rm -rf $backupDir/*"
        local msg=
        msg=$(exec_cmd "helm get values $releaseName -n $CDF_NAMESPACE > $valuesFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to back up Helm release settings of Velero; error message: $msg . \n$LOG_MSG"
        fi
        #backup velero chart version
        local versionFile="$backupDir/chart-version.txt"
        msg=$(exec_cmd "echo \"$releaseList\" | grep \"^$releaseName\" | awk '{print \$NF}' > $versionFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to back up chart version; error message: $msg. \n$LOG_MSG"
        fi
        #backup pv, pvc of cloudserver
        local dn="itom-cloudserver"
        local pvFile="$backupDir/$dn-pv.json"
        local pvcFile="$backupDir/$dn-pvc.json"
        local pvcName=
        local pvName=
        pvcName=$(exec_cmd "kubectl get deploy $dn -n $CDF_NAMESPACE -ojson 2>/dev/null | jq -r '.spec.template.spec.volumes[] | select(.name == \"storage\") | .persistentVolumeClaim.claimName'" -p=true)
        if [ -n "$pvcName" ]; then
            pvName=$(exec_cmd "kubectl get pvc $pvcName -n $CDF_NAMESPACE -ojson 2>/dev/null | jq -r '.spec.volumeName'" -p=true)
            if [ -z "$pvName" ]; then
                log "fatal" "Failed to get volume name used by pvc $pvcName. \n$LOG_MSG"
            fi
        else
            log "fatal" "Failed to get pvc name used by $dn deployment. \n$LOG_MSG"
        fi
        msg=$(exec_cmd "kubectl get pv $pvName -ojson > $pvFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to back up pv $pvName information used by $dn deployment; error message: $msg . \n$LOG_MSG"
        fi
        msg=$(exec_cmd "kubectl get pvc $pvcName -n $CDF_NAMESPACE -ojson > $pvcFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to back up PVC information used by $dn deployment; error message: $msg . \n$LOG_MSG"
        fi
        #backup namespace defination
        local ns=$CDF_NAMESPACE
        local nsFile="$backupDir/ns-$ns.yaml"
        msg=$(exec_cmd "kubectl get ns $ns -ojson > $nsFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to back up $ns namespace defination; error message: $msg . \n$LOG_MSG"
        fi
    fi
}

unzipBackupData(){
    log "info" "Uncompressing backup data"
    local type=$(exec_cmd "file $BACKUP_FILE" -p=true)
    local gzipFile=
    local removeUnencFile=false
    if [[ "$type" =~ "gzip compressed data" ]]; then
        log "infolog" "package $BACKUP_FILE is gzip compressed data, donot need to decrpt."
        gzipFile=$BACKUP_FILE
    elif [[ "$type" =~ "enc'd data with salted password" ]]; then
        log "infolog" "package $BACKUP_FILE is openssl enc'd data, need to decrpt."
        removeUnencFile="true"
        local name=$(basename $BACKUP_FILE ".enc")
        gzipFile=$TEMP_PATH/${name}.tar.gz
        #read password
        log "infolog" "ask for inputing the passphrase to decrypt the pacakge"
        local pass=
        read -s -r -p "Please input passphrase to decrypt backup package: " pass
        while [ $(validatePwd "$pass"; echo $?) -ne 0 ]; do
            echo -e "\nPassphrase cannot be empty."
            read -s -r -p "Please input passphrase to decrypt backup package: " pass
        done
        echo ""
        local b64Pass=$(echo "$pass" | base64 -w0)
        #remove tar.gz file
        log "infolog" "remove existing decrypted package before decrypting"
        if [ -f "$gzipFile" ]; then
            exec_cmd "rm -f $gzipFile"
        fi
        #decrypt the package
        log "infolog" "decrypting package $BACKUP_FILE to $gzipFile"
        echo "$b64Pass" | base64 -d | openssl aes-256-cbc -md sha1 -d -pbkdf2 -in $BACKUP_FILE -out $gzipFile -pass stdin
        if [ $? != 0 ]; then
            log "fatal" "Failed to decrypt the backup package $BACKUP_FILE. Please ensure you input the correct passphrase."
        fi
    else
        log "fatal" "Incorrect file type: $type. The file should be gzip compressed data or enc'd data with salted password."
    fi
    # uncompress the pacakge
    log "infolog" "uncompressing the backup package"
    exec_cmd "rm -rf $ROOT_DIR \\
           && mkdir -p $ROOT_DIR \\
           && tar -zxPf $gzipFile -C $ROOT_DIR"
    [ $? != 0 ] && log "fatal" "Failed to uncompress the file $gzipFile. \n$LOG_MSG"
    [ "$removeUnencFile" = "true" ] && exec_cmd "rm -f $gzipFile"
}

validatePwd(){
    local pass="$1"
    if [ -z "$pass" ] || [[ "$pass" =~ [\'\"[:space:]] ]]; then
        return 1
    fi
}

getEncPassphrase(){
    local pass=
    local confirmPass=
    read -s -r -p "Please input passphrase to encrpty backup package: " pass
    echo ""
    while [ $(validatePwd "$pass"; echo $?) -ne 0 ]; do
        echo -e "Passphrase cannot be empty, cannot contain space or quotation mark."
        read -s -r -p "Please input passphrase to encrpty backup package: " pass
        echo ""
    done
    read -s -r -p "Confirm the encryption passphrase: " confirmPass
    echo ""
    while [ "$pass" != "$confirmPass" ];do
            echo -e "Passphrases does not match."
            read -s -r -p "Please input passphrase to encrpty backup package: " pass
            echo ""
            while [ $(validatePwd "$pass"; echo $?) -ne 0 ]; do
                echo -e "Passphrase cannot be empty, cannot contain space or quotation mark."
                read -s -r -p "Please input passphrase to encrpty backup package: " pass
                echo ""
            done
            read -s -r -p "Confirm the encryption passphrase: " confirmPass
            echo ""
    done
    PASSPHRASE=$(echo "$pass" | base64 -w0)
}

postBackup(){
    #create backup path
    exec_cmd "mkdir -p $BACKUP_PATH"
    #set backup file name
    if [ -n "$THIS_NODE" ]; then
        TGZ_BACKUP_FILE="cdf-br-${THIS_NODE}-$(date +%Y%m%d%H%M%S)".tar.gz
    else
        TGZ_BACKUP_FILE="cdf-br-$(date +%Y%m%d%H%M%S)".tar.gz
    fi
    local file=$TGZ_BACKUP_FILE
    #generate backup file and set corret permission
    cd $TEMP_PATH
    exec_cmd "tar -zcpPf $BACKUP_PATH/$TGZ_BACKUP_FILE cdf_backup \\
           && chmod 400 $BACKUP_PATH/$TGZ_BACKUP_FILE"
    if [ $? != 0 ]; then
        log "fatal" "Failed to compress the temporary backup directory $TEMP_PATH/cdf_backup.\n$LOG_MSG"
    fi
    if [ "$NO_ENCRYPT" != "true" ]; then
        # get passphrase from input
        getEncPassphrase
        # encrypt the tgz package
        ENC_BACKUP_FILE=$(basename $TGZ_BACKUP_FILE ".tar.gz").enc
        local result=
        result=$(exec_cmd "echo $PASSPHRASE | base64 -d | openssl aes-256-cbc -md sha1 -e -pbkdf2 -in $BACKUP_PATH/$TGZ_BACKUP_FILE -out $BACKUP_PATH/$ENC_BACKUP_FILE -pass stdin" -p=true -m=false)
        if [ $? != 0 ]; then
            log "fatal" "Failed to encrypt the package $BACKUP_PATH/$TGZ_BACKUP_FILE with passphrase. To encrypt the backup package, please ensure install the latest version openssl; or use '--no-encrypt' to skip data encryption. error: $result"
        fi
        file=$ENC_BACKUP_FILE
        exec_cmd "rm -f $BACKUP_PATH/$TGZ_BACKUP_FILE"
    fi
    #clean temp dir
    exec_cmd "/bin/rm -rf $TEMP_PATH/cdf_backup"
    #end msg
    if [ "$CDF_MODE" = "byok" ]; then
        echo -e "\nBackup complete.\n\nThe backup file $file is placed in $BACKUP_PATH.\nThis file can be used to restore the environment. Please store it securely.\n"
    else
        echo -e "\nBackup complete.\n\nThe backup file $file is placed in $BACKUP_PATH.\nThis file can be used to recover the environment in case of loss of control plane nodes. Please store it securely.\n"
    fi
}

setPars(){
    #set env
    CURRENT_DIR=$(cd "$(dirname "$0")";pwd)
    BUILD_DIR=$(cd $CURRENT_DIR/../../; pwd)
    TEMP_PATH=${TEMP_PATH:-"/tmp"}
    SCRIPT_NAME=$(basename $0|cut -d'.' -f1)
    LOG_FILE=$TEMP_PATH/$SCRIPT_NAME.$(date "+%Y%m%d%H%M%S").log
    LOG_MSG="For more details, refer to $LOG_FILE"
    export PATH=$PATH:$BUILD_DIR/bin
    #set target directory for uncompress backup data
    DIR_NAME=$(basename $BACKUP_FILE | awk -F. '{print $1}')
    ROOT_DIR=$TEMP_PATH/$DIR_NAME
    BACKUP_DATA_DIR=$ROOT_DIR/cdf_backup
}

preRecover(){
    #need recover on a clean node
    if [ -f "/etc/profile.d/itom-cdf.sh" ] ;then
        echo -e "\nAbort: Found a file /etc/profile.d/itom-cdf.sh; Concluding this node has installed kubernetes infrastructure. You can only run this script to recover on a clean node."
        exit 1
    fi
    #set parameters
    setPars
    #do not need recover on BYOK env
    #recover must run under build dir
    #try to judge it's byok or on-premise build from the directory structure
    #in byok build, no images directory and script is under <build>/scripts
    #in on-premise build, the script is under <build>/cdf/scripts
    if [ ! -d "$CURRENT_DIR/../../images" -a -f "$CURRENT_DIR/../version.txt" ]; then
       echo -e "\nThis script only works for OpenText Kubernetes control plane nodes.\n"
       exit 1
    fi
    #print hint message
    echo -e "\nThis script will recover this node as the first control plane node. Please wait while Restoring Backup...
\nBefore recovering, please remove the crashed control plane nodes by running the uninstall.sh script if the systems are still accessible. If not, you can create new systems.\n"
    read -p "Do you want to start recovery? (yY/nN):" confirm
    if [ "$confirm" != "y" -a "$confirm" != "Y" ]; then
        exit 2
    fi
    echo ""
}

recoverFirewalldSettings(){
    local status=
    local result=
    result=$(exec_cmd "systemctl is-active firewalld" -p=true)
    if [ "$result" = "active" ]; then
        log "spin" "Recovering firewalld settings"
        # open ports if need
        local failedPorts=
        local openedPorts=$(exec_cmd "firewall-cmd --list-ports" -p=true)
        local requiredPorts="2380/tcp
                           4001/tcp
                           5444/tcp
                           8472/udp
                           10248/tcp
                           10249/tcp
                           10250/tcp
                           10256/tcp
                           10257/tcp
                           10259/tcp
                           ${MASTER_API_SSL_PORT}/tcp"
        for port in $requiredPorts
        do
            if [[ "$openedPorts" =~ "$port" ]]; then
                log "infolog" "port $port has been already opened."
                continue
            fi
            log "infolog" "open $port"
            exec_cmd "firewall-cmd --permanent --add-port=$port" || failedPorts="$port $failedPorts"
        done
        if [ -n "$failedPorts" ]; then
            log "fatal" "Failed to open port(s): $failedPorts.\n$LOG_MSG"
        fi
        # check rules cmd: firewall-cmd --direct --get-rule ipv4 filter FORWARD
        # add firewall rules
        exec_cmd "firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 1 -o cni0 -j ACCEPT -m comment --comment 'flannel subnet'" || failedRules="flannel-subnet-1 $failedRules"
        exec_cmd "firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 1 -i cni0 -j ACCEPT -m comment --comment 'flannel subnet'" || failedRules="flannel-subnet-2 $failedRules"
        exec_cmd "firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 1 -s $POD_CIDR ! -d $POD_CIDR -j MASQUERADE" || failedRules="flannel-subnet-3 $failedRules"
        # check settings cmd: firewall-cmd --list-all
        if [ -n "$HA_VIRTUAL_IP" ]; then
            exec_cmd "firewall-cmd --permanent --add-protocol vrrp" || failedRules="keepalived-vrrp $failedRules"
        fi
        if [ -n "$failedRules" ]; then
            log "fatal" "Failed to set rule(s): $failedRules.\n$LOG_MSG"
        fi
        # enable forward and add cni0 into default zone
        local interface="cni0"
        local mainVersion=$(exec_cmd "firewall-cmd --version | awk -F. '{print \$1}'" -p=true)
        if [ "$mainVersion" -ge "1" ]; then
            exec_cmd "firewall-cmd --permanent --add-forward && firewall-cmd --permanent --add-interface=$interface"
            if [ $? != 0 ]; then
                log "fatal" "Failed to enable forward or add 'cni0' interface into default zone.\n$LOG_MSG"
            fi
        fi
        # reload firewall settings
        exec_cmd "firewall-cmd --reload"
        if [ $? != 0 ]; then
            log "fatal" "Failed to reload the firewall settings.\n$LOG_MSG"
        fi
    else
        log "infolog" "firewalld service is not active, status:$result; no need to restore the firewalld settings."
    fi
}

recoverNode(){
    #unzip backup data
    unzipBackupData
    ##checks
    #backup cdf version and current cdf version should be same
    log "infolog" "check backup data version with current build version"
    local bkVersion curVersion
    bkVersion=$(exec_cmd "cat $BACKUP_DATA_DIR/version.txt" -p=true)
    curVersion=$(exec_cmd "cat $BUILD_DIR/version.txt" -p=true)
    if [ "$bkVersion" != "$curVersion" ]; then
        exec_cmd "/bin/rm -rf $ROOT_DIR"
        log "fatal" "Cannot recover the cluster from release $bkVersion backup using $curVersion release build. You must provide a installation source that matches the version stored in the backup file.\n$LOG_MSG"
    fi
    #backup data should be used for recovering same node (hostname or ip)
    #get THIS_NODE
    log "infolog" "check backup data can be used for current node"
    source $BACKUP_DATA_DIR/node/env.sh 2>/dev/null
    if [[ "$THIS_NODE" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        #IPv4
        local ips=$(hostname -I)
        local sameIp="false"
        for ip in $ips
        do
            if [ "$ip" = "$THIS_NODE" ]; then
                sameIp="true"
                break
            fi
        done
        if [ "$sameIp" = "false" ]; then
            exec_cmd "/bin/rm -rf $ROOT_DIR"
            log "fatal" "The node IP address stored in the backup data file $BACKUP_FILE is $THIS_NODE. This node's IP is: $ips. You cannot recover to this node. The stored IP address and this node's IP address must be the same."
        fi
    else
        #FQDN
        local fqdn=$(hostname -f | tr [:upper:] [:lower:])
        if [ "$fqdn" != "$THIS_NODE" ]; then
            exec_cmd "/bin/rm -rf $ROOT_DIR"
            log "fatal" "The node FQDN stored in the backup data file $BACKUP_FILE is $THIS_NODE. This node's FQDN is: $fqdn. You cannot recover to this node. The stored FQDN and this node's FQDN must be the same."
        fi
    fi
    #recover profiles
    log "infolog" "restore and source profiles"
    exec_cmd "/bin/cp -pf $BACKUP_DATA_DIR/node/itom-cdf.sh /etc/profile.d/"
    source /etc/profile.d/itom-cdf.sh && source $BACKUP_DATA_DIR/node/env.sh && source $BACKUP_DATA_DIR/cm/basic_config.env
    [ $? != 0 ] && log "fatal" "Failed to recover or source profile files.\n$LOG_MSG"
    #recover cdf-home
    log "spin" "Recovering node configuration"
    exec_cmd "tar -zxPf $BACKUP_DATA_DIR/node/cdf_home.tar.gz -C /"
    [ $? != 0 ] && log "fatal" "Failed to recover CDF_HOME.\n$LOG_MSG"
    #recover bin/scripts/tools/cni
    log "infolog" "recover bin/scripts/tools"
    sBins="$BUILD_DIR/bin
           $BUILD_DIR/k8s/bin
           $BUILD_DIR/cri/bin
           $BUILD_DIR/cdf/bin"
    sScripts="$BUILD_DIR/scripts
              $BUILD_DIR/cdf/scripts"
    sTools="$BUILD_DIR/tools
            $BUILD_DIR/cdf/tools"
    sCni="$BUILD_DIR/k8s/cni"
    for dir in $sBins $sScripts $sTools $sCni
    do
        local target=$CDF_HOME/$(basename $dir)
        [ ! -d "$target" ] && exec_cmd "mkdir -p $target"
        exec_cmd "/bin/cp -rpf $dir/* $target"
        [ $? != 0 ] && log "fatal" "Failed to recover bin or scripts or tools.\n$LOG_MSG"
    done
    exec_cmd "/bin/cp -pf $BACKUP_DATA_DIR/node/env.sh $CDF_HOME/bin"
    [ $? != 0 ] && log "fatal" "Failed to recover env.sh script.\n$LOG_MSG"
    #recover images
    log "infolog" "recover image files"
    local iDirs="$BUILD_DIR/k8s/images
                 $BUILD_DIR/cdf/images"
    [ ! -d "$CDF_HOME/images" ] && exec_cmd "mkdir -p $CDF_HOME/images"
    for dir in $iDirs
    do
        exec_cmd "/bin/cp -rpf $dir/* $CDF_HOME/images"
        [ $? != 0 ] && log "fatal" "Failed to recover image files.\n$LOG_MSG"
    done
    #recover symbolic link
    log "info" "Recreating symbolic links"
    local sd=${CDF_HOME}/bin
    local td=/usr/bin
    local bin=(containerd  containerd-shim-runc-v2  crictl  ctr  etcdctl  helm  kubectl  kubelet  runc  vault)
    for file in ${bin[@]}
    do
        exec_cmd "ln -sf $sd/$file $td/$file"
        [ $? != 0 ] && log "fatal" "Failed to recover symbolic link for bin files.\n$LOG_MSG"
    done
    log "infolog" "recover symbolic link config for crictl"
    local f="crictl.yaml"
    exec_cmd "ln -sf $CDF_HOME/cfg/$f /etc/$f"
    #recover etcd
    log "info" "Recovering etcd data and static Pod YAML file"
    exec_cmd "ETCDCTL_API=3 $CDF_HOME/bin/etcdctl snapshot restore $BACKUP_DATA_DIR/etcd/snapshot.db --name $THIS_NODE --initial-cluster=${THIS_NODE}=https://${THIS_NODE}:2380 --initial-cluster-token etcd-cluster-1 --initial-advertise-peer-urls https://${THIS_NODE}:2380"
    [ $? != 0 ] && log "fatal" "Failed to uncompress etcd snapshot file.\n$LOG_MSG"
    exec_cmd "mkdir -p ${RUNTIME_CDFDATA_HOME}/etcd/data \\
           && /bin/rm -rf ${RUNTIME_CDFDATA_HOME}/etcd/data/member \\
           && /bin/cp -rpf ${THIS_NODE}.etcd/member ${RUNTIME_CDFDATA_HOME}/etcd/data/member \\
           && sed -i -e 's@--force-new-cluster=.*@--force-new-cluster=true@g' -e \"s@--initial-cluster=.*@--initial-cluster=${THIS_NODE}=https://${THIS_NODE}:2380@g\" $CDF_HOME/runconf/etcd.yaml"
    [ $? != 0 ] && log "fatal" "Failed to recover etcd data or yaml file.\n$LOG_MSG"
    exec_cmd "rm -rf ./${THIS_NODE}.etcd"
    #recover service file
    log "info" "Recovering host system services"
    exec_cmd "tar -zxPf $BACKUP_DATA_DIR/node/node_services.tar.gz -C /"
    [ $? != 0 ] && log "fatal" "Failed to recover native service configuration files.\n$LOG_MSG"
    #recover service workdir
    log "infolog" "recover native service workdir"
    exec_cmd "rm -rf /var/lib/kubelet \\
           && mkdir -p /var/lib/kubelet \\
           && mkdir -p ${RUNTIME_CDFDATA_HOME}/kubelet \\
           && mkdir -p ${RUNTIME_CDFDATA_HOME}/containerd"
    [ $? != 0 ] && log "fatal" "Failed to recover service workdir.\n$LOG_MSG"
    #recover other configs
    exec_cmd "mkdir -p ~/.kube $CDF_HOME/cni/conf \\
           && /bin/cp -pf $BACKUP_DATA_DIR/node/kube-config ~/.kube/config \\
           && rm -rf $CDF_HOME/cni/conf/* \\
           && /bin/cp -pf $BACKUP_DATA_DIR/node/conf/* $CDF_HOME/cni/conf/"
    [ $? != 0 ] && log "fatal" "Failed to recover kube config or cni config.\n$LOG_MSG"
    #recover ownership
    log "info" "Setting ownership and permissions"
    local ETCD_USER_ID ETCD_GROUP_ID
    ETCD_USER_ID=$(exec_cmd "$CDF_HOME/bin/yq '.spec.containers[0].securityContext.runAsUser' $CDF_HOME/runconf/etcd.yaml" -p)
    ETCD_GROUP_ID=$(exec_cmd "$CDF_HOME/bin/yq '.spec.containers[0].securityContext.runAsGroup' $CDF_HOME/runconf/etcd.yaml" -p)
    exec_cmd "chown -R ${SYSTEM_USER_ID} $CDF_HOME/cni $CDF_HOME/images $CDF_HOME/scripts \\
           && chown -R ${ETCD_USER_ID} ${RUNTIME_CDFDATA_HOME}/etcd \\
           && chown -R :${ETCD_GROUP_ID} ${RUNTIME_CDFDATA_HOME}/etcd/data \\
           && chmod -R 700 ${RUNTIME_CDFDATA_HOME}/etcd/data "
    [ $? != 0 ] && log "fatal" "Failed to recover ownership or permission.\n$LOG_MSG"
    if [ "$(getenforce)" = "Enforcing" ]; then
        exec_cmd "chcon -R -t usr_t ${CDF_HOME}"
        [ $? != 0 ] && log "fatal" "Failed to recover selinux type for CDF_HOME.\n$LOG_MSG"
    fi
    #restore firewalld settings
    recoverFirewalldSettings
    #start cdf
    log "spin" "Starting Kubernetes"
    exec_cmd "${CDF_HOME}/bin/kube-start.sh"
    [ $? != 0 ] && log "fatal" "Failed to start cdf.\n$LOG_MSG"
    #reset etcd setting and restart
    log "spin" "Reset etcd setting and restarting AppHub"
    exec_cmd "sed -i -e 's@--force-new-cluster=.*@--force-new-cluster=false@g' $CDF_HOME/runconf/etcd.yaml \\
           && ${CDF_HOME}/bin/kube-restart.sh -u -y"
    [ $? != 0 ] && log "fatal" "Failed to restart kubernetes infrastructure after reset etcd setting.\n$LOG_MSG"
    #enable service
    log "info" "Enabling host system services"
    exec_cmd "systemctl enable containerd.service && systemctl enable kubelet.service"
    [ $? != 0 ] && log "fatal" "Failed to enable services.\n$LOG_MSG"
}

postRecover(){
    #set msg
    local extendNodeMsg restartWorkerMsg restoreMsg needRestoreDb
    if [ -f "$BACKUP_DATA_DIR/embedded_pg/backup-location.txt" ]; then
        restoreMsg="Restore the embedded PostgreSQL databases by running the following command: '$0 -m dbrestore -f <backup file>'. For detailed script usage, run: '$0 -h'\n"
    fi
    local label="node-role.kubernetes.io/control-plane=" num=0
    num=$(exec_cmd "kubectl get nodes -l $label --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | wc -l" -p=true)
    if [ "$num" -gt 1 ]; then #multiple-master cluster env
        extendNodeMsg="Remove the other two crashed control plane nodes then add two new control plane nodes to the cluster.
   Refer to the documentation: 'Add or remove nodes from a cluster via CLI commands' under the Administer section for the detailed steps."
    fi
    restartWorkerMsg="Run the following command on worker nodes to restart Kubernetes.
   ${CDF_HOME}/bin/kube-restart.sh"
    #clean temp dir
    exec_cmd "/bin/rm -rf $ROOT_DIR"
    #move log file into log dir
    local logdir="$CDF_HOME/log/scripts/$SCRIPT_NAME"
    exec_cmd "mkdir -p $logdir \\
           && mv -f $LOG_FILE $logdir"
    #
    echo -e "\nRecovery complete.\n"
    #hint msg after recovery
    local msg step
    if [ -n "$extendNodeMsg" ]; then
        msg="1) $extendNodeMsg
2) $restartWorkerMsg"
        step=2
    else
        msg="1) $restartWorkerMsg"
        step=1
    fi
    if [ -n "$restoreMsg" ]; then
        msg="$msg
$((step+1))) $restoreMsg"
    fi
    echo -e "You must complete the following manual steps:\n$msg"
}

preRestore(){
    setPars
    # source profile
    if [[ -f "/etc/profile.d/itom-cdf.sh" ]];then
        source "/etc/profile.d/itom-cdf.sh"
    elif [ -f "$HOME/itom-cdf.sh" ]; then
        source $HOME/itom-cdf.sh
    fi
    [ -f "$CDF_HOME/bin/env.sh" ] && source $CDF_HOME/bin/env.sh
    #check env: classic or byok?
    #classic: exist images dir under CDF_HOME and have image files
    #otherwise: byok
    if [ $(ls $CDF_HOME/images/*.tgz 2>/dev/null | wc -l) -gt 0 ]; then
        CDF_MODE="classic"
    else
        CDF_MODE="byok"
    fi
}

printHintMsgFordbRestore(){
    #print hint message
    echo -e "\nThis script will restore the embedded PostgreSQL databases. Please wait while Restoring backup...
\nDuring restoring, this script will restart the components; this will cause the services to be unavailable during the restart.\n"
    read -p "Do you want to start restore? (yY/nN):" confirm
    if [ "$confirm" != "y" -a "$confirm" != "Y" ]; then
        exit 2
    fi
    echo ""
}

restoreDb(){
    #unzip backup data
    unzipBackupData
    #check whether need to restore
    local bf="$BACKUP_DATA_DIR/embedded_pg/backup-location.txt"
    if [ ! -f "$bf" ]; then
        log "info" "Could not find the database backup location file in $BACKUP_FILE. Concluding this environment does not use embedded PostgreSQL databases. Skip embedded databases restore."
        return 0
    fi
    log "info" "Restoring embedded databases"
    #wait for vault running
    local name="itom-vault"
    log "spin" " - Waiting for $name to be ready"
    waitForResourceReady "$name" "" "" "90" "180"
    [ $? != 0 ] && log "fatal" "$name deployment is not ready.\n$LOG_MSG"
    #wait for pg-backup running
    name="itom-pg-backup"
    log "spin" " - Waiting for $name to be ready"
    waitForResourceReady "$name" "" "" "90"
    [ $? != 0 ] && log "fatal" "$name deployment is not ready.\n$LOG_MSG"
    #wait for embedded postgres pods running
    local deploys="cdfapiserver-postgresql itom-postgresql"
    for d in $deploys
    do
        log "spin" " - Waiting for $d to be ready"
        waitForResourceReady "$d" "" "" "90" "" "true"
        [ $? != 0 ] && log "fatal" "$d deployment is not ready.\n$LOG_MSG"
    done
    if [ "$CDF_MODE" = "classic" ]; then
        #set runlevel to DB
        log "spin" " - Stopping components before restoring"
        exec_cmd "echo y | $CDF_HOME/bin/cdfctl runlevel set -l DB -n $CDF_NAMESPACE"
        [ $? != 0 ] && log "fatal" "Failed to set runlevel to DB.\n$LOG_MSG"
    fi
    #get restore token
    local tokenInfo token
    local scriptDir="$CDF_HOME/tools/postgres-backup"
    tokenInfo=$(exec_cmd "$scriptDir/getRestoreToken" -p=true)
    if [ $? = 0 ]; then
        token=$(echo $tokenInfo|awk -F 'Authorization token:' '{print $2}')
    else
        log "fatal" "Failed to get database restore token with tool 'getRestoreToken'; error message: $tokenInfo. \n$LOG_MSG"
    fi
    #trigger restore
    log "spin" " - Triggering database restore"
    local bkLocation rsMsg rsLocation
    bkLocation=$(cat $bf)
    rsMsg=$(echo "$token" | $scriptDir/db_admin.sh restore -l "$bkLocation")
    if [ $? = 0 ]; then
        rsLocation=$(exec_cmd "echo \"$rsMsg\" | awk -F'Restore location: ' '{print \$2}'" -p=true)
    else
        log "fatal" "Failed to trigger embedded database restore.\n$LOG_MSG"
    fi
    #check restore status
    log "spin" " - Waiting for restore to complete"
    local msg
    msg=$(dbBRStatus "restore" "$rsLocation" "$token")
    if [ $? != 0 ]; then
        log "fatal" "Failed to restore embedded postgres database; error message: $msg . \n$LOG_MSG"
    fi
    if [ "$CDF_MODE" = "classic" ]; then
        #set runlevel to UP
        log "spin" " - Starting components after restore"
        exec_cmd "echo y | $CDF_HOME/bin/cdfctl runlevel set -l UP -n $CDF_NAMESPACE"
        [ $? != 0 ] && log "fatal" "Failed to set runlevel to UP.\n$LOG_MSG"
    fi
    #
    stopLoading
}

restoreVelero(){
    if [ "$CDF_MODE" = "byok" ]; then
        log "info" "Cannot use this script to restore Velero Helm release on external Kubernetes cluster."
        exit 1
    fi
    #check whether need to restore
    local releaseName="itom-velero"
    local releaseList=
    releaseList=$(getHelmReleases)
    if [ $? != 0 ]; then
        log "fatal" "Failed to get helm release list; error message: $releaseList. \n$LOG_MSG"
    fi
    if $(releaseInstalled "$releaseList" "$releaseName"); then
        log "info" "Release $releaseName already installed; skip Velero release restore."
        echo "$releaseList"
        exit 0
    fi
    #unzip backup data
    unzipBackupData
    #check if have velero backup
    if [ ! -d "$BACKUP_DATA_DIR/velero" ]; then
        log "err" "Not found Velero backup data under $BACKUP_DATA_DIR. This means that the K8sBackup capability was not enabled when this backup was created. Cannot restore Velero Helm release with this backup package."
        exit 1
    fi
    #check namespace
    log "info" "Check $CDF_NAMESPACE namespace"
    local needRestoreNs=
    local result=
    result=$(exec_cmd "kubectl get ns $CDF_NAMESPACE >/dev/null" -p=true)
    if [ $? = 0 ]; then
        log "info" "$CDF_NAMESPACE namespace already exists"
    else
        if [[ ! "$result" =~ "not found" ]]; then
            log "fatal" "Failed to check if $CDF_NAMESPACE namespace exists, error: $result"
        fi
        log "info" "$CDF_NAMESPACE namespace does not exist"
        needRestoreNs="true"
    fi
    #restore namespace
    if [ "$needRestoreNs" = "true" ]; then
        log "info" "Restore namespace $CDF_NAMESPACE"
        local nsFile=$BACKUP_DATA_DIR/velero/ns-$CDF_NAMESPACE.yaml
        result=$(exec_cmd "kubectl apply -f $nsFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to restore $CDF_NAMESPACE namespace. error:$result"
        fi
    fi
    #check pv and pvc
    log "info" "Check pvc and pv"
    result=
    local pvFile=$BACKUP_DATA_DIR/velero/itom-cloudserver-pv.json
    local pvcFile=$BACKUP_DATA_DIR/velero/itom-cloudserver-pvc.json
    local pvName=$(cat $pvFile | jq -r '.metadata.name')
    local pvcName=$(cat $pvcFile | jq -r '.metadata.name')
    local scName=$(cat $pvcFile | jq -r '.spec.storageClassName')
    local needRestorePVC=
    local needRestorePV=
    local needCheckPV=
    # check pvc
    result=$(exec_cmd "kubectl get pvc $pvcName -n $CDF_NAMESPACE -o json" -p=true)
    if [ $? = 0 ]; then
        #pvc exists, check its status
        local status=$(echo $result | jq -r '.status.phase')
        if [ "$status" = "Bound" ] ;then
            log "info" "pvc $pvcName already exists under $CDF_NAMESPACE namespace and in $status status."
            log "warn" "Please ensure Velero backups are located on its bounded volume, otherwise, the backup will not be accessible."
        else
            log "info" "pvc $pvcName already exists under $CDF_NAMESPACE namespace but in $status status, delete this pvc"
            result=$(exec_cmd "kubectl delete pvc $pvcName -n $CDF_NAMESPACE --force --grace-period=0" -p=true)
            if [ $? != 0 ]; then
                log "fatal" "Failed to delete pvc $pvcName. error: $result"
            fi
            needRestorePVC="true"
            needCheckPV="true"
        fi
    elif [[ "$result" =~ "not found" ]]; then
        log "info" "pvc $pvcName does not exist"
        needRestorePVC="true"
        needCheckPV="true"
    else
        log "fatal" "Failed to check if pvc $pvcName exists. error: $result"
    fi
    # check pv
    result=
    if [ "$needCheckPV" = "true" ]; then
        result=$(exec_cmd "kubectl get pv $pvName -o json" -p=true)
        if [ $? = 0 ]; then
            #pv exists, check status
            status=$(echo $result | jq -r '.status.phase')
            if [ "$status" = "Bound" ] ;then
                #pv exits but pvc is 'not found' or not in 'Bound' status
                log "fatal" "pv $pvName already exists and in $status status, but required pvc $pvcName does not exist. Please ensure the required pvc $pvcName is bounded to correct volume."
            elif [ "$status" = "Available" ]; then
                log "info" "pv $pvName already exists and in $status status"
            else #in 'Released' or other unkonwn status
                log "infolog" "$CDF_NAMESPACE does not exist and pv $pvName exists with $status status"
                log "info" "pv $pvName already exists and in $status status, delete this pv"
                result=$(exec_cmd "kubectl delete pv $pvName --force --grace-period=0" -p=true)
                if [ $? != 0 ]; then
                    log "fatal" "Failed to delete pv $pvName. error: $result"
                fi
                needRestorePV="true"
            fi
        elif [[ "$result" =~ "not found" ]]; then
            log "info" "pv $pvName does not exist"
            needRestorePV="true"
        else
            log "fatal" "Failed to check if pv $pvName exists. error: $result"
        fi
    fi
    # restore pv
    result=
    if [ "$needRestorePV" = "true" ]; then
        log "info" "Restore pv $pvName"
        local newPvFile=$BACKUP_DATA_DIR/velero/itom-cloudserver-pv-new.json
        result=$(exec_cmd "cat $pvFile | jq 'del(.metadata.creationTimestamp, .metadata.finalizers, .metadata.resourceVersion, .metadata.uid, .spec.claimRef, .status)' > $newPvFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to generate pv json file. error: $result"
        fi
        result=$(exec_cmd "kubectl apply -f $newPvFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to restore pv from $newPvFile. error: $result"
        fi
    fi
    # restore pvc
    result=
    if [ "$needRestorePVC" = "true" ]; then
        log "info" "Restore pvc $pvcName"
        local newPvcFile=$BACKUP_DATA_DIR/velero/itom-cloudserver-pvc-new.json
        result=$(exec_cmd "cat $pvcFile | jq 'del(.metadata.creationTimestamp, .metadata.finalizers, .metadata.resourceVersion, .metadata.uid, .spec.volumeName, .status)' > $newPvcFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to generate pvc json file. error: $result"
        fi
        result=$(exec_cmd "kubectl apply -f $pvcFile" -p=true)
        if [ $? != 0 ]; then
            log "fatal" "Failed to restore pvc from $pvcFile. error: $result"
        fi
    fi
    #check pvc status
    if [ "$needRestorePV" = "true" -o "$needRestorePVC" = "true" ]; then
        log "spin" "Checking pvc $pvcName status"
        local maxRetry=6
        local waitSec=10
        local retryCount=0
        while true; do
            result=
            status=
            result=$(exec_cmd "kubectl get pvc $pvcName -n $CDF_NAMESPACE -o json" -p=true)
            if [ $? = 0 ]; then
                status=$(echo $result | jq -r '.status.phase')
                if [ "$status" = "Bound" ] ;then
                    log "infolog" "pvc is in Bound status. pvc restore ok."
                    break
                elif [ "$retryCount" -eq "$maxRetry" ]; then
                    log "fatal" "pvc $pvName not in Bound status. status: $status"
                fi
            elif [ "$retryCount" -eq "$maxRetry" ]; then
                log "fatal" "Failed to check pvc $pvcName status. error: $result"
            fi
            retryCount=$((retryCount + 1))
            sleep $waitSec
        done
    fi
    #restore velero
    log "spin" "Start to restore Velero Helm release, this may take several minutes"
    result=
    local relaseName="itom-velero"
    local chartVer=$(cat $BACKUP_DATA_DIR/velero/chart-version.txt)
    local chartFile="$CDF_HOME/charts/$relaseName-$chartVer.tgz"
    if [ ! -f "$chartFile" ]; then
        log "fatal" "File $chartFile not found. Please run the script under $CDF_HOME."
    fi
    result=$(exec_cmd "helm install $relaseName $chartFile -f $BACKUP_DATA_DIR/velero/values.txt -n $CDF_NAMESPACE --wait --timeout 30m" -p=true)
    if [ $? != 0 ]; then
        log "fatal" "Failed to restore velero release. error: $result"
    fi
    #enable schedule backup
    log "info" "Restore backup scheduler"
    result=
    local scheduleName="k8s-backup"
    local excludeNs="kube-system,default"
    result=$(exec_cmd "${CDF_HOME}/bin/velero schedule create $scheduleName --schedule=\"0 0 * * *\" --exclude-namespaces='$excludeNs'" -p=true)
    if [ $? != 0 ]; then
        log "fatal" "Failed to create schedule backup. error: $result"
    fi

    log "" "Velero Helm release restore completed. You can run command 'watch velero get backup' to check if velero backups are retrieved successfully."
    #
    stopLoading
}

postRestore(){
    #clean temp dir
    exec_cmd "/bin/rm -rf $ROOT_DIR"
    #move log file into log dir
    local logdir="$CDF_HOME/log/scripts/$SCRIPT_NAME"
    exec_cmd "mkdir -p $logdir \\
           && mv -f $LOG_FILE $logdir"
    #
    echo -e "\nRestore complete.\n"
}

backup(){
    preCheck
    preBackup
    backupNode
    backupEtcd
    backupVault
    backupCm
    backupVelero
    backupDb
    postBackup
}

recover(){
    preCheck
    preRecover
    recoverNode
    postRecover
}

dbRestore(){
    preCheck
    preRestore
    printHintMsgFordbRestore
    restoreDb
    postRestore
}

veleroRestore(){
    preCheck
    preRestore
    restoreVelero
    postRestore
}

## Main
CURRENT_PID=$$
while [ ! -z $1 ]; do
    step=2
    case "$1" in
      -m|--mode )           setOptionVal  "$1" "$2" "MODE" ;;
      -t|--temp-path )      setOptionVal  "$1" "$2" "TEMP_PATH" ;;
      -b|--backup-path )    setOptionVal  "$1" "$2" "BACKUP_PATH" ;;
      -f|--file )           setOptionVal  "$1" "$2" "BACKUP_FILE" ;;
      --no-encrypt)         setOptionVal  "$1" "true" "NO_ENCRYPT"; step=1;;
      -h|--help )           usage;;
    esac
    if [ "$step" = "2" ]; then
        checkParam "$1" "$2"
    else
        checkParam "$1"
    fi
    shift $step
done

if [ "$MODE" = "backup" ]; then
    backup
elif [ "$MODE" = "recover" ]; then
    recover
elif [ "$MODE" = "dbrestore" ]; then
    dbRestore
elif [ "$MODE" = "vlrestore" ]; then
    veleroRestore
else
    usage
fi