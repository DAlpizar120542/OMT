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

if [ -f "/etc/profile.d/itom-cdf.sh" ]; then
    source /etc/profile.d/itom-cdf.sh 2>/dev/null
fi
if [ -f "$HOME_FOLDER/itom-cdf.sh" ]; then
    source $HOME_FOLDER/itom-cdf.sh 2>/dev/null
fi
CURRENTDIR=$(cd `dirname $0`; pwd)
CDF_NAMESPACE=${CDF_NAMESPACE:-"core"}
pgBackupServicePort=8443
componentName=$(basename $0|cut -d'.' -f1)

usage(){
    echo -e "Usage: $0 [Command][Options]"
    echo -e "\n[Command]"
    echo -e "  backup                start database backup"
    echo -e "  status                obtain database backup status"
    echo -e "  restore               start database restore"
    echo -e "\n[Options]"
    echo -e "  -t|--type             Perform backup/restore operation"
    echo -e "  -l|--location         Identify specific backup/restore operation"
    echo -e "  -a|--app              Specifies the appName that want to restore"
    echo -e "  -n|--namespace        Specifies the namespace the command will apply to(default is \$CDF_NAMESPACE)"
    echo -e "\nExamples:"
    echo -e "  $0 backup           # start database backup"
    echo -e "  $0 backup -n my_ns  # start database backup in namespace: my_ns"
    echo -e "  $0 status -l <location>  -t <operation>  \n                        # obtain backup/restore status with provided location"
    echo -e "  $0 restore -l <location>  -a <Application Name>  \n                # start database restore"
    exit 1
}

exec_cmd(){
  ${CDF_HOME}/bin/cmd_wrapper -c "$1" -f "$logFile" -x "DEBUG" $2 $3 $4 $5
  return $?
}

wrap_curl(){
    if [ "$INSTALLED_TYPE" = "CLASSIC" ];then
        "${CDF_HOME}"/bin/cmd_wrapper -c "$1" -f "$logFile" -x "DEBUG" $2 $3 $4 $5
    else
        local curl_cmd=$1 pod_name
        pod_name=$(exec_cmd "$kubectl get pods -n ${NAMESPACE}|grep 'itom-idm'|grep 'Running'|awk '{len=split(\$2,arr,\"/\");if(len==2&&arr[1]>0&&arr[1]==arr[2])print \$1}'" -p true)
        if [ -z "$pod_name" ];then
            log "fatal" "Failed to get ${NAMESPACE}/itom-idm. For detail logs, please refer to $logFile"
        fi
        echo "$kubectl exec $pod_name -n ${NAMESPACE} -c idm -- $curl_cmd" >> "$logFile"
        eval "$kubectl exec $pod_name -n ${NAMESPACE} -c idm -- $curl_cmd"
    fi
    return $?
}

getRfcTime(){
    date --rfc-3339=ns|sed 's/ /T/'
}

log() {
    local level=$1
    local msg=$2
    local consoleTimeFmt=$(date "+%Y-%m-%d %H:%M:%S")
    local logTimeFmt=$(getRfcTime)
    case $level in
        info)
            echo -e "[INFO] $consoleTimeFmt : $msg  " && echo "$logTimeFmt INFO  $msg" >>$logFile ;;
        fatal)
            echo -e "[FATAL] $consoleTimeFmt : $msg  " && echo "$logTimeFmt FATAL $msg" >>$logFile
            exit 1;;
        *)
            echo -e "[INFO] $consoleTimeFmt : $msg  " && echo "$logTimeFmt INFO  $msg" >>$logFile ;;
    esac
}

#check if either cdf-apiserver-db or idm-db are embeded
checkValid(){
  if [ "$NAMESPACE" == "$CDF_NAMESPACE" ];then
    local releaseName="apphub"
    if [ "$(helm list -q -n "$CDF_NAMESPACE" | grep -c "$releaseName")" -eq 0 ];then
        echo "Error: apphub is not deployed!"; exit 1
    fi

    #if .Values.global.database.internal=true:  both idm and cdf-apiserver using embeded db
    #if .Values.global.database.internal=false: idm using external db
    #if .Values.global.database.internal=false && .Values.cdfapiserver.deployment.database.internal=true: cdf-apiserver using embeded db
    #if .Values.global.database.internal=false && .Values.cdfapiserver.deployment.database.internal=false: cdf-apiserver using external db
    local cdfapiserverInternal globalInternal deploymentManagement
    deploymentManagement=$(helm get values "$releaseName" -n "$CDF_NAMESPACE" 2>/dev/null | yq e '.global.services.deploymentManagement' -)
    if [ "$deploymentManagement" == "false" ];then
        echo "Error: not support when deployment management capability is false!"
        exit 1
    fi
    cdfapiserverInternal=$(helm get values "$releaseName" -n "$CDF_NAMESPACE" 2>/dev/null | yq e '.cdfapiserver.deployment.database.internal' -)
    globalInternal=$(helm get values "$releaseName" -n "$CDF_NAMESPACE" 2>/dev/null | yq e '.global.database.internal' -)
    if [ "$globalInternal" == "false" ] && [ "$cdfapiserverInternal" == "false" ];then
        echo "Error: both idm db and cdf-apiserver db are external!" exit 1
    fi
  else
    #if have ns list privillage, we should check if user provided ns is correct or not
    if [ $(exec_cmd "kubectl auth can-i get ns -q 2>/dev/null" -p=false; echo $?) -eq 0 ];then
      local nss found="false"
      nss=$(exec_cmd "kubectl get ns --no-headers | awk '{print $1}' | xargs" -p=true)
      if [ $? -eq 0 ];then
        for ns in $nss; do
          if [ "$ns" == "$NAMESPACE" ];then
            found="true"
            break
          fi
        done
        if [ "$found" == "false" ];then
          echo "Error: incorrect namespace: $NAMESPACE!"; exit 1
        fi
      fi
    fi

    #check if pg-backup svc is exist or not
    if [ $(exec_cmd "kubectl get deploy -n $NAMESPACE --no-headers | grep \"pg-backup\" | wc -l 2>/dev/null" -p=true) -eq 0 ];then
      echo "Error: no pg-backup service exists!"; exit 1
    fi
  fi
}

getToken(){
    preSteps
    local backupdApiToken
    if [ -z "$backupdApiToken" ]; then  read -p "Please input the authorization: " backupdApiToken ; fi
    TOKEN="Authorization: Bearer $backupdApiToken"
}
preSteps(){
   pgBackupPodIP=$(exec_cmd "kubectl get pods -n $NAMESPACE -o json | jq -r '.items[] | select (.metadata.name | test(\"itom-pg-backup.\")) |.status.podIP'" -p=true)
    if [ -z "$pgBackupPodIP" ] || [[ ! "$pgBackupPodIP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log "fatal" "Failed to get IP address of itom-pg-backup pod"
    else
        pgBackupBaseUrl="https://${pgBackupPodIP}:${pgBackupServicePort}"
    fi
}
startBackup(){
    log "info" "Start postgres database backup ..."
    getToken
    local api_url="/backupd/api/v1/backups"
    local apiResult=$(wrap_curl "curl -k -s -I -X POST \\
                      -w \"%{http_code}\" \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${TOKEN}\" \\
                      --noproxy \"${pgBackupPodIP}\" \\
                      \"${pgBackupBaseUrl}${api_url}\"" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "201" ]; then
        local body=${apiResult:0:-3}
        body=${body#*<body>}
        body=${body%%</body>*}
        log "fatal" "httpCode: $http_code $body"
    else
        local currentLocation="$(exec_cmd "echo \"$apiResult\" | awk -F/ '/Location:/ {print \$NF}' | sed 's/\\r//g'" -p=true)"
        log "info" "Backup location: $currentLocation"
    fi
}

fetchStatus(){
    #add no-header for skipping the header printing when backup_recover.sh call this script.
    [ "${NO_HEADER}" != "true" ] && log "info" "Fetching database backup/restore status ..."
    local type=$1
    if [ -z "$type" ]; then
       log "fatal" "Need to specify the operation,backup or restore, Type $0 -h for detail usage"
    fi
    getToken
    local location=$2
    if [ -n "$location" ]; then
        if [ "$type" == "backup" ]; then
            local api_url="/backupd/api/v1/backups/$location"
            local apiResult=$(wrap_curl "curl -s -k -X GET \\
                          -w \"%{http_code}\"  \\
                          --header 'Accept: application/json' \\
                          --header \"${TOKEN}\" \\
                          --noproxy \"${pgBackupPodIP}\" \\
                          \"${pgBackupBaseUrl}${api_url}\"" -p=true)
            local http_code=${apiResult:0-3}
            if [ "$http_code" != "200" ]; then
              local body=${apiResult:0:-3}
              body=${body#*<body>}
              body=${body%%</body>*}
              log "fatal" "httpCode: $http_code $body"
            else
                [ "${NO_HEADER}" != "true" ] && log "info"
                echo "${apiResult:0:-3}" | $jq .
            fi
         elif [ $type == "restore" ]; then
           local api_url="/backupd/api/v1/restores/$location"
           local apiResult=$(wrap_curl "curl -s -k -X GET \\
                          -w \"%{http_code}\" \\
                          --header 'Accept: application/json' \\
                          --header \"${TOKEN}\" \\
                          --noproxy \"${pgBackupPodIP}\" \\
                          \"${pgBackupBaseUrl}${api_url}\"" -p=true)
            local http_code=${apiResult:0-3}
            if [[ "$http_code" != 2* ]]; then
                log "fatal" "${apiResult:0:-3}"
             else
                [ "${NO_HEADER}" != "true" ] && log "info"
                echo "${apiResult:0:-3}" | $jq .
             fi
         else
             echo -e "\n>>> [Error]  Requires specific operation type -t <operation type> , backup/restore"
             usage
         fi
     else
         if [ "$type" == "backup" ]; then
            local api_url="/backupd/api/v1/backups"
            local apiResult=$(wrap_curl "curl -s -k -X GET \\
                          -w \"%{http_code}\" \\
                          --header 'Accept: application/json' \\
                          --header \"${TOKEN}\" \\
                          --noproxy \"${pgBackupPodIP}\" \\
                          \"${pgBackupBaseUrl}${api_url}\"" -p=true)
             local httpCode=${apiResult:0-3}
             if [[ "$httpCode" != 2* ]]; then
                local body=${apiResult:0:-3}
                body=${body#*<body>}
                body=${body%%</body>*}
                log "fatal" "httpCode: $http_code $body"
             else
                [ "${NO_HEADER}" != "true" ] && log  "info"
                echo "${apiResult:0:-3}" | $jq .
             fi
         elif [ "$type" == "restore" ]; then
              local restoreStatusUrl="/backupd/api/v1/restore"
              local restoreStatueResponse=$(wrap_curl "curl -s -k -X GET \\
                                            -w \"%{http_code}\" \\
                                            --header 'Accept: application/json' \\
                                            --header \"${TOKEN}\" \\
                                            --noproxy \"${pgBackupPodIP}\" \\
                                            \"${pgBackupBaseUrl}${restoreStatusUrl}\"" -p=true)
              local httpCode=${restoreStatueResponse:0-3}
              if [[ "$httpCode" != 2* ]]; then
                 log "fatal" "${restoreStatueResponse:0:-3}"
              else
                 [ "${NO_HEADER}" != "true" ] && log "info"
                 echo "${restoreStatueResponse:0:-3}" | $jq .
              fi
         fi
    fi
}

restore(){
    log "info" "Start postgres database restore ..."
    local location=$1
    local app=$2
    local services=$3
    if [ -z "$location" ]; then
       log "fatal" "Need location when fetch the restore status. Type $0 -h for detail usage."
    fi
    if [[ -n "$app" ]]; then
       if [[ -n "$services" ]]; then
       getToken
       services=$(echo $services | sed -e 's/\(\w*\)/,"\1"/g' | cut -d , -f 2-)
       services="[$services]"
       local api_url="/backupd/api/v1/backups/$location/restore"
       local apiResult=$(wrap_curl "curl -s -k -X POST \\
                          -w \"%{http_code}\" \\
                          --header 'Accept: application/json' \\
                          --header \"${TOKEN}\" \\
                          -d '{\"appName\":\"$app\",\"services\":$services}' \\
                          --noproxy \"${pgBackupPodIP}\" \\
                          \"${pgBackupBaseUrl}${api_url}\"" -p=true)
       local httpCode=${apiResult:0-3}
          if [[ "$httpCode" != 2* ]]; then
              log "fatal" "${apiResult:0:-3}"
          else
              log "info" "${apiResult:0:-3}"
          fi
       else
          getToken
          local api_url="/backupd/api/v1/backups/$location/restore"
          local apiResult=$(wrap_curl "curl -sSL -D - -k  -X POST \\
                          -w \"%{http_code}\" \\
                          --header 'Accept: application/json' \\
                          --header \"${TOKEN}\" \\
                          -d '{\"application\":\"$app\"}' \\
                          --noproxy \"${pgBackupPodIP}\" \\
                          \"${pgBackupBaseUrl}${api_url}\"" -p=true)

          local httpCode=${apiResult:0-3}
          if [[ "$httpCode" != 2* ]]; then
           log "fatal" "${apiResult:0:-3}"
          else
            local currentLocation="$(exec_cmd "echo \"$apiResult\" | awk -F/ '/Location:/ {print \$NF}' | sed 's/\\r//g'" -p=true)"
            log "info" "Restore location: $currentLocation"
          fi
       fi
    else
       getToken
       local api_url="/backupd/api/v1/backups/$location/restore"
       local apiResult=$(wrap_curl "curl -k -s -I -X POST \\
                          -w \"%{http_code}\" \\
                          --header 'Accept: application/json' \\
                          --header \"${TOKEN}\" \\
                          --noproxy \"${pgBackupPodIP}\" \\
                          \"${pgBackupBaseUrl}${api_url}\"" -p=true)

       local httpCode=${apiResult:0-3}
       if [[ "$httpCode" != 2* ]]; then
           log "fatal" "${apiResult:0:-3}"
       else
           local currentLocation="$(exec_cmd "echo \"$apiResult\" | awk -F/ '/Location:/ {print \$NF}' | sed 's/\\r//g'" -p=true)"
           log "info" "Restore location: $currentLocation"
       fi
    fi

}

while [ ! -z $1 ]; do
    case "$1" in
      -l|--location )
        case "$2" in
          -*) echo -e "\n>>> [Error] -l|--location parameter requires a value";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -l|--location parameter requires a value";usage; fi; LOCATION="$2";shift 2;;
        esac ;;
      -a|--app )
        case "$2" in
           -*) echo -e "\n>>> [Error] -a|--app parameter requires a value";usage;;
           * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -l|--location parameter requires a value";usage; fi; APP="$2";shift 2;;
        esac ;;
      --services )
        case "$2" in
            -*) echo -e "\n>>> [Error] --services parameter requires a value";usage;;
            * ) if [ -z "$2" ];then echo -e "\n>>> [Error] --services parameter requires a value";usage; fi; SERVICES="$2";shift 2;;
         esac ;;
      -t|--type )
         case "$2" in
             -*) echo -e "\n>>> [Error] -t|--type parameter requires a value";usage;;
             * ) if [ -z "$2" ]; then echo -e "\n>>> [Error] -t|--type parameter requires a value";usage; fi; TYPE="$2";shift 2;;
         esac ;;
      -n|--namespace )
         case "$2" in
             -*) echo -e "\n>>> [Error] -n|--namespace parameter requires a value";usage;;
             * ) if [ -z "$2" ]; then echo -e "\n>>> [Error] -n|--namespace parameter requires a value";usage; fi; NAMESPACE="$2";shift 2;;
         esac ;;
      -h|--help ) usage;;
      backup ) BACKUP="true";shift;;
      status ) STATUS="true";shift;;
      restore ) RESTORE="true";shift;;
      #internal option --no-header
      --no-header) NO_HEADER="true"; shift;;
      *)  echo -e "\n>>> [Error] Invalid parameter: $1 "; usage ;;
    esac
done

#MAIN
INSTALLED_TYPE="CLASSIC"
if [ ! -f "$CURRENTDIR/../../images/infra-common-images.tgz" ];then
    INSTALLED_TYPE="BYOK"
fi

if [ "$INSTALLED_TYPE" = "CLASSIC" ];then
    logDir=$CDF_HOME/log/$componentName
    jq="${CDF_HOME}/bin/jq"
    kubectl="${CDF_HOME}/bin/kubectl"
else
    logDir=/tmp/log/$componentName
    jq="$CURRENTDIR/../../bin/jq"
    kubectl="kubectl"
fi

NAMESPACE=${NAMESPACE:-"$CDF_NAMESPACE"}
logFile=$logDir/$componentName.`date "+%Y%m%d%H%M%S"`.log
/bin/mkdir -p $logDir

checkValid

if [ "$BACKUP" = "true" ]; then
    startBackup
elif [ "$STATUS" = "true" ]; then
    fetchStatus  "$TYPE" "$LOCATION"
elif [ "$RESTORE" = "true" ]; then
    restore "$LOCATION" "$APP" "$SERVICES"
else
    usage
fi
