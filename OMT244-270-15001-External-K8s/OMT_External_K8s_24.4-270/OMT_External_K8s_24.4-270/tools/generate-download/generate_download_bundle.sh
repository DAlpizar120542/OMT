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


# Exit code definition for running in container
# 20  CA certificate verify failed
# 21  failed to contact registry
# 22  failed to get registry credential and url
# 23  malformed chart file
# 24  values file incorrect
# 25  file not exist
# 26  read file failed

#see feature: OCTFT19S1761772
if [[ "bash" != "$(readlink /proc/$$/exe|xargs basename)" ]];then
    echo "Error: only bash support, current shell: $(readlink /proc/$$/exe)"
    exit 1
fi
set +o posix

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

for command_var in CP RM MKDIR ; do
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

currentDir=$(cd `dirname $0`;pwd)
MAX_RETRY=3
CONCURRENCY=20
ROLLID=
SILENT_MODE="false"
ingressSslPort=5443
componemtName=$(basename $0|cut -d'.' -f1)
if [ -n "$CDF_HOME" ] && [ -d "$CDF_HOME" ];then #when uninstalled, CDF_HOME still hold value
    logDir=$CDF_HOME/log/$componemtName
    mkdir -p $logDir 2>/dev/null
    if [ $? -ne 0 ];then
        logDir=/tmp
        echo "Warning: No permission to write log to folder: $logDir. Switch the log folder to: /tmp"
    fi
else
    logDir=/tmp
fi
[ -f "$CDF_HOME/bin/env.sh" ] && source $CDF_HOME/bin/env.sh
LOG_FILE=$logDir/$componemtName.`date "+%Y%m%d%H%M%S"`.log
$MKDIR -p $logDir
CDFAPISERVER_CURL_OPT=""
if [ "$IN_APPHUB_POD" == "true" ];then
    export PATH=/bin:$PATH
    CDF_NAMESPACE=${CDF_NAMESPACE:-"core"}
    BIN_DIR=/bin
    SCRIPT_DIR=/bosun/scripts
    SILENT_MODE="true"
else
    if [[ -f "/etc/profile.d/itom-cdf.sh" ]];then
        source "/etc/profile.d/itom-cdf.sh"
    elif [ -f "$HOME/itom-cdf.sh" ]; then
        source $HOME/itom-cdf.sh
    fi
    export PATH=$currentDir/../../bin:$PATH
    CDF_NAMESPACE=${CDF_NAMESPACE:-"core"}
    BIN_DIR=${BIN_DIR:-"$currentDir/../../bin"} #IN skip-packing mode, BIN is exported from father shell
    SCRIPT_DIR=$currentDir/../../scripts
fi

usage(){
    echo -e "Usage: $0 [OPTIONS]

OPTIONS
  ##Global option
  -h, --help                  Displays this help message.
  -d, --dir                   Location where to place the offline-download.zip (default: user working dir.

  ## chart option
  -C, --chart                 Helm chart .tgz file or folder which contains chart.
  -H, --helm-values           Helm values yaml file.

  ## image-set.json option
  -f, --image-set             User specified image-set.json file.

  ## Registry option
  -S, --skip-image-check      Skip checking image delta from registry.
  -k, --insecure              Skip SSL certificate validation.
      --skip-verify           Skip SSL certificate validation(deprecated).
  -r, --registry              Registry url for caculating image delta.
  -a, --cacert                Registry CA for caculating image delta(for mutiple CA files, seperate them with comma).
      --registry-ca           Registry CA for caculating image delta(deprecated).
  -o, --orgname               Organization for caculating image delta (must be in lowercase, default 'hpeswitom').
  -U, --registry-username     User name for caculating image delta.
  -P, --registry-password     Password for caculating image delta.
  -A, --registry-auth         Use AUTH_STRING for accessing the registry. AUTH_STRING is a base64 encoded 'USERNAME[:PASSWORD].

  ## matadata and/or suite lifecycle management option
  -p, --password              Password of administrator(Only used in suite lifecycle manangement scenario).
  -u, --username              User name of administrator(Only used in suite lifecycle manangement scenario).
  -m, --metadata              Location and name of the suite metadata file (Mandatory for fresh installation).
  -F, --feature-set           Suite feature set(taken over the value defined in configuration file,comma seperated. If not specified,all feature sets are set.).
  -s, --suite-name            Suite name(taken over the value defined in configuration file).
  -v, --suite-version string  Suite version(taken over the value defined in configuration file).
  -c, --config                Location and name of the configuration file.

EXAMPLES
  Examples on generating offline-download.zip for installation or upgrade:
  1) generate with image-set.json:
    $0 -f <image-set.json> -d <output folder>
  2) generate with a chart file:
    $0 -C <chart file> -o <org name>
    $0 -C <chart file> -H <helm values yaml file> -o <org name>
  3) generate with a metadata file:
    explicitly specify suite name and version and feature set:
      $0 -m <suite metadata> -s <suite name> -v <suite version> -F <feature set>
    implicitly specify suite name and version by a configuration json file:
      $0 -m <suite metadata> -c <config file>

  Examples on generating offline-download.zip for suite lifecycle manangement:
  1) suite install:
    $0 -s <suite name> -v <suite version> -u <admin user name> -p <admin password>
  2) suite update:
    $0 -v <suite version> -u <admin user name> -p <admin password>
  3) suite reconfig:
    $0 -v <suite version> -F <feature set> -u <admin user name> -p <admin password>
  or if you provide a configuration file, the script can determine the lifecycle automatically:
    $0 -c <config json> -u <admin user name> -p <admin password>\n"
    exit $1
}

fatalOnInvalidParm(){
    echo "$1 parameter requires a value. "; usage "1";
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

while [ ! -z $1 ]; do
    step=2 ##shift step,default 2
    case "$1" in
        -c|--config )               setOptionVal "$1" "$2" "CONFIG_FILE";;
        -C|--chart )                setOptionVal "$1" "$2" "CHART_FILE";;
        -H|--helm-values )          setOptionVal "$1" "$2" "VALUES_FILE";;
        -f|--image-set )            setOptionVal "$1" "$2" "IMAGE_SET_FILE";;
        -m|--metadata )             setOptionVal "$1" "$2" "METADATA";;
        -d|--dir )                  setOptionVal "$1" "$2" "OUTPUT_DIR";;
        -u|--username )             setOptionVal "$1" "$2" "SUPER_USER";;
        -v|--suite-version )        setOptionVal "$1" "$2" "SUITE_VERSION";;
        -s|--suite-name )           setOptionVal "$1" "$2" "SUITE_NAME";;
        -F|--feature-set )          setOptionVal "$1" "$2" "FEATURE_SET";;
        -r|--registry)              setOptionVal "$1" "$2" "DELTA_REG";;
        -a|--cacert )               setOptionVal "$1" "$2" "DELTA_REG_CA";;
        --registry-ca )             setOptionVal "$1" "$2" "DELTA_REG_CA_DEPRECATED";;
        -o|--orgname)               setOptionVal "$1" "$2" "DELTA_REG_ORGNAME";;
        -U|--registry-username)     setOptionVal "$1" "$2" "DELTA_REG_USERNAME";;
        -A|--registry-auth)         setOptionVal "$1" "$2" "AUTH_STRING";;
        --concurrency)              setOptionVal "$1" "$2" "CONCURRENCY";;
        --image-validation-result)  setOptionVal "$1" "$2" "IMAGE_VALIDATE_JSON";;
        -p|--password) #not using setOptionVal to support password contains special chars
        case "$2" in
            -*) echo "-p|--password parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-p|--password parameter requires a value. " ; exit 1 ; fi ; SUPER_USERPWD=$2 ; ;;
        esac ;;
        -P|--registry-password) #not using setOptionVal to support password contains special chars
        case "$2" in
            -*) echo "-P|--registry-password parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-P|--registry-password parameter requires a value. " ; exit 1 ; fi ; DELTA_REG_PASSWORD=$2 ; ;;
        esac ;;

        -S|--skip-image-check )         SKIP_CHECK_IMAGE="true"; step=1;;
        --skip-duplicate)               SKIP_DUPLICATE="true"; step=1;;
        --skip-packing)                 SKIP_PACKING="true"; step=1;;
        -k|--insecure|--skip-verify)    SKIP_VERIFY="true"; step=1;;
        --debug)                        HELM_DEBUG="true";step=1;; #this option is used to indicate helm template use --debug option.
        -h|--help )                     usage "0";;
        *)  echo -e "\n>>> [Error] Invalid parameter: $1 "; usage "1" ;;
    esac
    shift $step
done


MASK_REG_EXP="(?i)(sessionId|token|password|Bearer)(\"?\s*[:=\s]\s*)[^',}\s]*"
exec_cmd(){
    ${BIN_DIR}/cmd_wrapper -c "$1" -f $LOG_FILE -x=DEBUG -ms -mre $MASK_REG_EXP $2 $3 $4 $5
    return $?
}

getRfcTime(){
    date --rfc-3339=ns|sed 's/ /T/'
}
uniformStepMsgLen(){
    local msgLen=$1
    local maxLen=70
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
    local exitCode=$3;
    local consoleTimeFmt=$(date "+%Y-%m-%d %H:%M:%S")
    local logTimeFmt=$(getRfcTime)
    case $level in
        info)
            echo -e "$consoleTimeFmt INFO $msg  " && echo "$logTimeFmt INFO $msg" >>$LOG_FILE ;;
        infolog)
            echo "$logTimeFmt INFO $msg" >>$LOG_FILE ;;
        begin)
            echo -e "$consoleTimeFmt INFO $msg\c" && uniformStepMsgLen "${#msg}" && echo -e "$logTimeFmt INFO $msg \c" >> $LOG_FILE ;;
        end)
            echo "$msg" && echo "$msg" >> $LOG_FILE ;;
        warn)
            echo -e "$consoleTimeFmt WARN $msg  " >&2 && echo "$logTimeFmt WARN $msg" >>$LOG_FILE ;;
        fatal)
            echo -e "$consoleTimeFmt FATAL $msg  " >&2 && echo "$logTimeFmt FATAL $msg" >>$LOG_FILE
            echo "Please refer $LOG_FILE for more details." >&2
            if [ -z "$exitCode" ]; then
                exitCode=1
            fi
            exit $exitCode;;
        *)
            echo -e "$consoleTimeFmt INFO $msg  " && echo "$logTimeFmt INFO $msg" >>$LOG_FILE ;;
    esac
}
taskClean(){
    if [ -n "$ROLLID" ];then
        kill -s SIGTERM ${ROLLID} 2>/dev/null
    fi
    if [ -n "$PID_ARRAY" ];then
        for pid in $PID_ARRAY;do
            kill -9 $pid 2>/dev/null
        done
    fi
    rm -f $CA_TMP $CHART_YAML $OUTPUT_DIR/missing_image.* $OUTPUT_DIR/lock_file.*
    rm -rf ${meta_tmp} $CHART_FOLDER
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
    if [ "$SILENT_MODE" == "false" ];then
        rolling &
        ROLLID=$!
    fi
}

stopRolling(){
    if [ "$SILENT_MODE" == "false" ];then
        if [[ -n $ROLLID ]];then
            echo -ne '\b'
            kill -s SIGTERM $ROLLID
            wait $ROLLID >/dev/null 2>&1
        else
            ROLLID=
        fi
    fi
}

getAuth(){
    while [ -z "$SUPER_USER" ]; do read -p "Please input the administrator username: " SUPER_USER ; done
    while [ -z "$SUPER_USERPWD" ]; do read -s -r -p "Please input the administrator password: " SUPER_USERPWD ; echo "" ; done
}


setApiBaseUrl(){
    local externalAccessHost=$(exec_cmd "kubectl get cm cdf -n $CDF_NAMESPACE  -o json 2>/dev/null | jq -r '.data.EXTERNAL_ACCESS_HOST'" -p=true)
    cdfApiBaseUrl="https://${externalAccessHost}:${ingressSslPort}/suiteInstaller"
}

calculateLifecycle(){
    log "infolog" "calculating the lifecycle..."
    if [ -z "$DEPLOYED_VERSION" ]; then # suite not installed
        LIFE_CYCLE="install"
        log "infolog" "Not found deployed suite, lifecycle=$LIFE_CYCLE"
    else # suite installed, reconfig or update
        local suiteVersionInJson
        if [ -n "$SUITE_VERSION" ];then
            suiteVersionInJson=$SUITE_VERSION
        else
            if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ];then
                suiteVersionInJson=$(exec_cmd "jq -r '.capabilities.version' $CONFIG_FILE" -p=true)
            fi
        fi
        log "infolog" "Deployed suite version: \"$DEPLOYED_VERSION\". Target suite version: \"$suiteVersionInJson\""
        log "infolog" "Deloyment UUID: \"$DEPLOYMENT_UUID\", Deloyment status: \"$DEPLOYED_STATUS\""
        if [ -z "$suiteVersionInJson" -o "$suiteVersionInJson" = "null" ]; then
            log "fatal" "Not find the suite version in $CONFIG_FILE; for detailed error information, check '$LOG_FILE'"
        elif [ "$suiteVersionInJson" = "$DEPLOYED_VERSION" ]; then
            if [ -n "$DEPLOYMENT_UUID" ] && ( [ "$DEPLOYED_STATUS" = "INSTALL_FINISHED" ] || [ "$DEPLOYED_STATUS" = "RECONFIGURE_FAILED" ] || [ "$DEPLOYED_STATUS" = "RECONFIGURING" ]);then
                LIFE_CYCLE="reconfigure"
            else
                LIFE_CYCLE="install"
            fi
        else
            LIFE_CYCLE="update"
        fi
        log "infolog" "lifecycle=$LIFE_CYCLE"
    fi
}

getXtoken(){
    log "infolog" "Getting X-AUTH-TOKEN"
    local x_auth_token=""
    local pwd=$(echo $SUPER_USERPWD | sed -e 's/"/\\"/g' -e 's/'\''/'\''\\'\'''\''/g')
    local api_url="/urest/v1.1/tokens"
    local apiResponse=$(exec_cmd "curl ${CDFAPISERVER_CURL_OPT} -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    -d '{\"passwordCredentials\":{\"password\":\"${pwd}\",\"username\":\"${SUPER_USER}\"},\"tenantName\":\"Provider\"}' \\
                    $noProxyOption \\
                    ${cdfApiBaseUrl}${api_url}" -p=true -m=false)
    if [[ $? -eq 60 ]];then
        log "fatal" "CA certificate verify failed!"
    fi
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "201" ]; then
        log "fatal" "Failed to get X-AUTH-TOKEN. API response: ${apiResponse:0:-3}"
    else
        x_auth_token=$(echo ${apiResponse:0:-3} | jq -r '.token')
        X_AUTH_TOKEN="X-AUTH-TOKEN: ${x_auth_token}"
    fi
}

getCsrfTokenSessionID(){
    log "infolog" "Getting X-CSRF-TOKEN"
    local x_csrf_token=""
    local session_id=""
    local session_name=""
    local api_url="/urest/v1.1/csrf-token"
    local apiResponse=$(exec_cmd "curl ${CDFAPISERVER_CURL_OPT} -s -X GET \\
                                 -w '%{http_code}' \\
                                 --header 'Accept: application/json' \\
                                 --header '${X_AUTH_TOKEN}' \\
                                 $noProxyOption \\
                                 ${cdfApiBaseUrl}${api_url}" -p=true)
    if [[ $? -eq 60 ]];then
        log "fatal" "CA certificate verify failed!"
    fi
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "201" ]; then
        log "fatal" "API response: ${apiResponse:0:-3}.\nFor detailed error information, check '$LOG_FILE'"
    else
        x_csrf_token=$(echo ${apiResponse:0:-3} |jq -r '.csrfToken')
        session_id=$(echo ${apiResponse:0:-3} |jq -r '.sessionId' )
        session_name=$(echo ${apiResponse:0:-3} |jq -r '.sessionName')
        if [ -z "${session_name}" -o "${session_name}" = "null" ]; then
            session_name="JSESSIONID"
        fi
        X_CSRF_TOKEN="X-CSRF-TOKEN: ${x_csrf_token}"
        JSESSION_ID="${session_name}=${session_id}"
    fi
}

lifecycleSupportValidate(){
    local lifecycle=$1
    log "infolog" "Checking if $1 action is supported via API ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/lifecycle"
    local apiResponse=$(exec_cmd "curl ${CDFAPISERVER_CURL_OPT} -s -X GET \\
                    -w '%{http_code}' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    $noProxyOption \\
                    '${cdfApiBaseUrl}${api_url}'" -p=true)
    if [[ $? -eq 60 ]];then
        log "fatal" "CA certificate verify failed!"
    fi
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "200" ]; then
        log "fatal" "API response: ${apiResponse:0:-3}.\nFor detailed error information, check '$LOG_FILE'"
    else
        local change_enabled=$(echo ${apiResponse:0:-3} | jq -r ".change.enabledAPI" )
        local reconfig_enabled=$(echo ${apiResponse:0:-3} | jq -r ".reconfig.enabledAPI" )
        local update_enabled=$(echo ${apiResponse:0:-3} | jq -r ".update.enabledAPI" )
        if [ "$lifecycle" = "reconfig" ]; then
            if [ "$change_enabled" != "true" -a "$reconfig_enabled" != "true" ]; then
                log "fatal" "suite $lifecycle is NOT supported via API.\nAPI response: ${apiResponse:0:-3}.\nFor detailed error information, check '$LOG_FILE'"
            else
                log "infolog" "suite $lifecycle is supported via API."
            fi
        elif [ "$lifecycle" = "update" ]; then
            if [ "$update_enabled" != "true" ]; then
                log "fatal" "suite $lifecycle is NOT supported via API.\nAPI response: ${apiResponse:0:-3}.\nFor detailed error information, check '$LOG_FILE'"
            else
                log "infolog" "suite $lifecycle is supported via API."
            fi
        fi
    fi
}

checkPrimaryDeployment(){
    log "infolog" "Get primary deployment ..."
    local activedStatus="NEW FEATURE_SETTED CONF_POD_STARTED SUITE_INSTALL INSTALL_FINISHED INSTALLING RECONFIGURING UPDATING INSTALL_FAILED RECONFIGURE_FAILED UPDATE_FAILED"
    local queryStatus=
    for i in $activedStatus
    do
        queryStatus="${queryStatus}&deploymentStatus=${i}"
    done
    local api_url="/urest/v1.1/deployment?deploymentType=PRIMARY${queryStatus}"
    local apiResponse=$(exec_cmd "curl ${CDFAPISERVER_CURL_OPT} -s -X GET \\
                    -w '%{http_code}' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    $noProxyOption \\
                    '${cdfApiBaseUrl}${api_url}'" -p=true)
    if [[ $? -eq 60 ]];then
        log "fatal" "CA certificate verify failed!"
    fi
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "200" ]; then
        log "fatal" "Failed to get the deployment.\nAPI response: ${apiResponse:0:-3}.\nFor detailed error information, check '$LOG_FILE'"
    else
        local result=${apiResponse:0:-3}
        if [ $(exec_cmd "echo '$result'|jq 'length'" -p=true) -ne 0 ]; then
            DEPLOYMENT_NAME=$(exec_cmd "echo '$result'|jq -r '.[].deploymentInfo.deploymentName'" -p=true);   if [ "$DEPLOYMENT_NAME" == "null" ];then DEPLOYMENT_NAME=""; fi
            DEPLOYMENT_UUID=$(exec_cmd "echo '$result'|jq -r '.[].deploymentInfo.deploymentUuid'" -p=true);   if [ "$DEPLOYMENT_UUID" == "null" ];then DEPLOYMENT_UUID=""; fi
            DEPLOYED_VERSION=$(exec_cmd "echo '$result'|jq -r '.[].deploymentInfo.version'" -p=true);         if [ "$DEPLOYED_VERSION" == "null" ];then DEPLOYED_VERSION=""; fi
            DEPLOYED_STATUS=$(exec_cmd "echo '$result'|jq -r '.[].deploymentInfo.deploymentStatus'" -p=true); if [ "$DEPLOYED_STATUS" == "null" ];then DEPLOYED_STATUS=""; fi
            log "info" "Find primary deployment: $DEPLOYMENT_NAME ; version: $DEPLOYED_VERSION; status:$DEPLOYED_STATUS; UUID: $DEPLOYMENT_UUID"
        else
            DEPLOYMENT_UUID=
            DEPLOYED_VERSION=
            log "info" "Not found the activated primary deployment."
        fi
    fi
}

post(){
    local api_url=$1
    local postBody="$(echo $2|awk '{printf("%s",$0)}')"
    local expectStatusCode=${3:-"200"}
    local retryCount=${4:-"0"}
    RESP_BODY=""
    getXtoken
    getCsrfTokenSessionID
    local retryTime=0
    while true; do
        local apiResult=$(exec_cmd "curl ${CDFAPISERVER_CURL_OPT} -s -X POST \\
                        -w '%{http_code}' \\
                        --header 'Content-Type: application/json' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --header '${X_CSRF_TOKEN}' \\
                        --cookie '${JSESSION_ID}' \\
                        $noProxyOption \\
                        -d '$postBody' \\
                        ${cdfApiBaseUrl}${api_url}" -p=true)
        if [[ $? -eq 60 ]];then
            log "fatal" "CA certificate verify failed!"
        fi
        local http_code=${apiResult:0-3}
        local is_expectStatusCode=
        for statusCode in "${expectStatusCode}";do
            if [ "$http_code" = "${statusCode}" ]; then
                is_expectStatusCode="true"
                break
            fi
        done
        if [ -z "${is_expectStatusCode}" ]; then
            if [ "$retryTime" -eq "${retryCount}" ]; then
                log "fatal" "${apiResult:0:-3}"
            else
                retryTime=$((retryTime+1))
            fi
        else
            break
        fi
    done
    RESP_BODY="${apiResult:0:-3}"
}

requestImageList(){
    IMAGE_LIST=
    local query_parametes=
    if [ -n "${DEPLOYMENT_UUID}" ];then
        query_parametes="?deploymentUuid=${DEPLOYMENT_UUID}"
    fi
    local api_url="$1${query_parametes}"
    local postBody=$2
    post "$api_url" "$postBody"
    IMAGE_LIST="$(echo ${RESP_BODY}|jq -r '.images[].image')"
}

getRegistryInfo(){
    if [ -n "$DELTA_REG" ];then
        REGISTRY_BASE="$DELTA_REG"
        REG_ORGNAME="$DELTA_REG_ORGNAME"
        REG_USERNAME="$DELTA_REG_USERNAME"
        REG_PASSWORD="$DELTA_REG_PASSWORD"
    else
        local res=$( which kubectl > /dev/null 2>& 1; echo $? )
        if [ $res -ne 0 ] ; then
            return 1
        else
            if [ -z "$CDF_NAMESPACE" ];then
                return 2
            fi
            local registryPullSecret data auth cdfCm
            cdfCm=$(exec_cmd "kubectl get cm cdf -n $CDF_NAMESPACE -o json" -p=true)
            if [ $? -ne 0 ]; then
                return 4
            fi
            REGISTRY_BASE=$(echo ${cdfCm} | jq -r '.data."SUITE_REGISTRY"')
            REG_ORGNAME=$(echo ${cdfCm} | jq -r '.data."REGISTRY_ORGNAME"')

            registryPullSecret=$(exec_cmd "kubectl get secret -n $CDF_NAMESPACE registrypullsecret -o json" -p=true)
            if [ $? -ne 0 ]; then
                return 4
            fi
            data=$(echo "$registryPullSecret" | jq -r '.data[".dockerconfigjson"]' | base64 -d)
            local hosts=$(echo $data|jq -r ".auths" | jq -r "keys[]" | xargs)
            for host in ${hosts};do
                if [[ "$host" =~ "$REGISTRY_BASE" ]];then
                    auth=$(echo $data | jq -r '.auths["'${host}'"].auth' | base64 -d 2>>$LOG_FILE)
                fi
            done

            if [ -z "$REGISTRY_BASE" ];then
                return 3
            else
                REG_USERNAME=${auth%%:*}
                REG_PASSWORD=${auth#*:}
                if [ "$REG_USERNAME" == "_json_key" ];then
                    echo $REG_PASSWORD >${currentDir}/key.json
                    KEY_FILE=${currentDir}/key.json
                fi
            fi
        fi
    fi

    SECURITY_OPT=""
    if [ "$SKIP_VERIFY" == "true" ] && [ -n "$DELTA_REG_CA" ];then
        log "fatal" "--insecure,--skip-verify can not use with -a,--cacert,--registry-ca"
    fi
    if [ "$SKIP_VERIFY" == "true" ];then
        SECURITY_OPT="-k "
    else
        #-a,--cacert take precedence over --registry-ca
        if [ -n "$DELTA_REG_CA_DEPRECATED" ] && [ -z "$DELTA_REG_CA" ];then
            DELTA_REG_CA=$DELTA_REG_CA_DEPRECATED
        fi

        #for local registry, we use <CDF_HOME>/ssl/ca.crt
        #for external registry, we assume the ca is updated into trust store
        if [ -n "$DELTA_REG_CA" ];then\
            local tmpCa=$(mktemp)
            local cas=${DELTA_REG_CA//,/ }
            for ca in $cas; do
                if [ ! -f "$ca" ];then
                    log "fatal" "File not exist: $ca" "21"
                fi
                cat $ca >>$tmpCa
                if [ $? -ne 0 ];then
                    log "fatal" "Can't read CA file: $ca" "26"
                fi
                echo "" >>$tmpCa
            done
            SECURITY_OPT="${SECURITY_OPT} --cacert ${tmpCa}"
        else
            if [[ "$REGISTRY_BASE" =~ "localhost:5000" ]];then
                local ca_file="${CDF_HOME}/ssl/ca.crt"
                if [ ! -f "$ca_file" ];then
                    log "fatal" "Can't find $ca_file" "21"
                fi
                SECURITY_OPT="${SECURITY_OPT} --cacert ${ca_file}"
            fi
        fi
    fi
    local version=$(curl --version | grep "curl" | cut -d ' ' -f 2)
    version=$(echo $version|tr -d ".")
    if [[ $version -ge 7470 ]];then #Since 7.47.0, the curl tool enables HTTP/2 by default for HTTPS connections
        SECURITY_OPT="${SECURITY_OPT} --http1.1 "
    fi
}
readLoginInfo() {
    local retry_time=$1;shift
    local user_tmp=""
    local need_input_password="false"

    if [ -n "$AUTH_STRING" ];then
        read -s -r -p "Please input the AUTH_STRING for accessing the registry: " AUTH_STRING
    else
        old=$(stty -g)
        if [ -z "$REG_USERNAME" ];then
            read -p "Username:" REG_USERNAME
            need_input_password="true"
        else
            if [[ $retry_time -gt 0 ]];then #user have provide username and password
                read -p "Username(${REG_USERNAME})" user_tmp
                if [ -n "$user_tmp" ];then  #use the name in ()
                    REG_USERNAME=$user_tmp
                fi
                need_input_password="true"
            fi
        fi

        if [ -z "$REG_PASSWORD" ] || [ "$need_input_password" == "true" ];then
            stty -echo
            read -p "Password:" REG_PASSWORD
            stty $old
            echo ""
        fi
    fi
}
contactRegistryByCurl(){
    local result=125
    local scheme token status_code curl_cmd http_resp auth_info

    #step 1. intentify the protocal scheme
    for scheme in "https://" "http://" ; do
        #can't add -I here, as we need to test if the returned http body contains "blocked"
        http_resp=$(exec_cmd "curl --connect-timeout 20 -s -w %{http_code} ${NOPROXY_OPT} ${SECURITY_OPT} ${scheme}${REGISTRY_BASE}/v2/" -p=true)
        if [[ $? -eq 60 ]];then
            if [ "$IN_APPHUB_POD" == "true" ];then
                log "fatal" "Peer certificate cannot be authenticated with known CA certificates when contacting registry: $REGISTRY_BASE"  "20"
            else
                log "warning" "Peer certificate cannot be authenticated with known CA certificates when contacting registry: $REGISTRY_BASE"
            fi
            return $result
        fi
        status_code=${http_resp:0-3}
        case "$status_code" in
            200)
                if [ $(echo -e "$http_resp" | grep "blocked" | wc -l) -ne 0 ];then #special handling for docker hub
                    continue
                else
                    AUTH_TYPE=""; AUTH_BASE=""; AUTH_SERVICE=""; result=0; break
                fi
                ;;
            401)
                http_resp=$(curl -s -I ${NOPROXY_OPT} ${SECURITY_OPT} ${scheme}${REGISTRY_BASE}/v2/)
                auth_info=$(echo "$http_resp" | grep "realm")
                AUTH_BASE=$(echo "$auth_info" | cut -d = -f2 | cut -d , -f1 | tr -d ["\" \r"])
                AUTH_TYPE=$(echo "$auth_info" | cut -d = -f1 | cut -d ' ' -f2)
                AUTH_SERVICE=$(echo "$auth_info" | cut -d , -f2 | cut -d = -f2 | tr -d ["\" \r"])
                AUTH_SERVICE=${AUTH_SERVICE// /%20} #escape space
                result=1
                break
                ;;
            *) ;;
        esac
    done
    REGISTRY_BASE=${scheme}${REGISTRY_BASE}

    #step 2. check if the credential is correct
    if [[ $result -eq 1 ]];then
        for((i=0;i<$MAX_RETRY;i++));do
            log "begin" "Contacting Registry: $REGISTRY_BASE"
            token=$(getAuthToken "")
            status_code=$(exec_cmd "curl -s -w %{http_code} ${NOPROXY_OPT} ${SECURITY_OPT} -H \"Authorization: $AUTH_TYPE $token\" $REGISTRY_BASE/v2/" -p=true)
            status_code=${status_code:0-3}
            if [ "$status_code" == "200" ];then
                log "end" "[OK]"
                result=0
                break
            else
                log "end" "[Failed]"
                sleep 2
                log "info" "Retry..."
                readLoginInfo $i
            fi
        done
    fi
    return $result
}
getImageTagsFromRegistry(){
    local image=$1;shift
    local org_name=$1;shift
    local repo resp http_code header_size body_size link_header body tags url_path url auth token
    if [ -z "$org_name" ];then
        repo=$image
    else
        repo=$org_name/$image
    fi
    token=$(getAuthToken "$repo" )

    url_path="/v2/${repo}/tags/list"
    while : ; do
      if [[ "$url_path" =~ "${REGISTRY_BASE}" ]];then  #some registry retrurn the <Link> with full url(e.g. aws), but some return only the path
        url=$url_path
      else
        url=${REGISTRY_BASE}${url_path}
      fi
      if [ -n "$token" ];then
        auth="-H \"Authorization: $AUTH_TYPE $token\""
      fi
      resp=$(exec_cmd "curl -w '\n%{size_header},%{size_download},%{http_code}' -s -i ${NOPROXY_OPT} ${SECURITY_OPT} $auth ${url}" -p=true)
      if [ $? -ne 0 ]; then
        continue
      fi
      header_size=$(echo -e "$resp" | awk -F, 'END{print $1}')
      body_size=$(echo -e "$resp" | awk -F, 'END{print $2}')
      http_code=$(echo -e "$resp" | awk -F, 'END{print $3}')
      if [ "$http_code" != "200" ];then
          tags=""
          break
      else
          body=${resp:$header_size:$body_size}
          tags="${tags} $(echo "$body" | jq -r '.tags|.[]' 2>>$LOG_FILE | xargs)"
          link_header=$(echo -e "$resp" | grep "Link:")   #handle pagination
          if [ -z "$link_header" ];then
            break
          else
            url_path=$(echo "$link_header" | awk '{print $2}' | tr -d "<>;")
          fi
      fi
    done
    echo "$tags"
}
checkImageTagInRegistry(){
    local image=$1
    local fd=$2
    local i=${image%:*}
    local t=${image##*:}
    local tags=$(getImageTagsFromRegistry "$i" "${REG_ORGNAME}")
    local found="false"
    for tag in ${tags[@]};do
        if [ "$tag" == "$t" ];then
            found="true"
            break
        fi
    done

    (
        #for concurrent mode, stdout output may mixed between different background process, so not output the details here.
        flock -e $fd
        if [ "$found" == "false" ]; then
            echo "$image" >>$OUTPUT_DIR/missing_image.$fd
        fi
    ){fd}>>$OUTPUT_DIR/lock_file.$fd  #The syntax is {descr}>/tmp/smth.lock (no dollar sign) to allocate the file descriptor and assign it to the variable descr

}


getAuthToken(){
    local repo=$1
    local token token_resp query_string
    if [ -z "$AUTH_TYPE" ];then
        token=""
    elif [ -n "$BEARER_TOKEN" ];then
        token=$BEARER_TOKEN
    else
        if [ -z "$AUTH_STRING" ];then
            if [ -z "$REG_USERNAME" ];then
                AUTH_STRING=""
            else
                if [ -n "$REG_PASSWORD" ];then
                    AUTH_STRING=$(echo -n "$REG_USERNAME:$REG_PASSWORD" | base64 -w0)
                elif [ -n "$PASSWORD_CMD" ];then
                    AUTH_STRING=$(echo -n "$REG_USERNAME:$(eval ${PASSWORD_CMD})" | base64 -w0)
                elif [ -n "$KEY_FILE" ];then
                    AUTH_STRING=$(echo -n "$REG_USERNAME:$(cat $KEY_FILE)" | base64 -w0)
                else
                    AUTH_STRING=""
                fi
            fi
        fi

        if [ "$AUTH_TYPE" == "Basic" ]; then
            token=$AUTH_STRING
        else
            if [ -z "$repo" ];then
                query_string="?service=${AUTH_SERVICE}"
            else
                query_string="?service=${AUTH_SERVICE}&scope=repository:${repo}:push,pull"
            fi
            log "infolog" "curl -s ${NOPROXY_OPT} ${SECURITY_OPT} ${AUTH_BASE}${query_string}"
            if [ -z "$AUTH_STRING" ];then
                token_resp=$(curl -s ${NOPROXY_OPT} ${SECURITY_OPT} ${AUTH_BASE}${query_string} 2>>$LOG_FILE)
            else
                token_resp=$(curl -s ${NOPROXY_OPT} ${SECURITY_OPT} -H "Authorization: Basic $AUTH_STRING" ${AUTH_BASE}${query_string} 2>>$LOG_FILE)
            fi
            token=$(echo "$token_resp" | jq -r '.token?')
            if [ "$token" == "null" ];then
                token=$(echo $token_resp | jq -r '.access_token?')
            fi
        fi
    fi
    echo  $token
}
getDeltaImagesetFromRegistry(){
    local suite_name=$1
    local suite_version=$2
    local org_name=$3
    local images=$4

    local tmp_images=($images) fd_base=500
    images=($(for tmp in ${tmp_images[@]}; do echo $tmp; done|sort -u|xargs))
    local allImages=
    allImages="${images[*]}"
    if [ "$SKIP_CHECK_IMAGE" == "false" ];then
        getRegistryInfo
        if [ $? -eq 0 ];then
            echo ""
            if [[ "$SKIP_PACKING" == "true" ]];then
                log "info" "Trying to calculate delta images base on registry, this will take some time."
            else
                log "info" "Trying to calculate delta images base on registry, this will take some time. Please note only the \"Missing\" images will be generated into offline-download.zip."
            fi
            contactRegistryByCurl
            if [ $? -eq 0 ];then
                log "begin" "Checking images"
                startRolling
                if [[ $CONCURRENCY -gt 50 ]]; then
                    CONCURRENCY=50
                fi

                local ptrHead=0 ptrTail loopLength restLength
                restLength=$(expr ${#images[@]} - $ptrHead)
                while : ; do
                    if [[ $restLength -ge $CONCURRENCY ]];then
                        loopLength=$CONCURRENCY
                    else
                        loopLength=$restLength
                    fi
                    if [[ $loopLength -le 0 ]];then
                        break
                    fi

                    ptrTail=$(expr $ptrHead + $loopLength)
                    for((i=$ptrHead;i<$ptrTail;i++));do
                        local image=${images[$i]}
                        local fd=$(($fd_base + ${i}%${CONCURRENCY}))
                        checkImageTagInRegistry "$image" "$fd" &
                        PID_ARRAY="$PID_ARRAY $!"
                    done
                    if [ -n "$PID_ARRAY" ];then
                        for pid in $PID_ARRAY; do
                            wait $pid >/dev/null 2>&1
                        done
                    fi
                    PID_ARRAY=""
                    ptrHead=$(expr $ptrHead + $loopLength)
                    restLength=$(expr $restLength - $loopLength)
                done
                stopRolling
                log "end" "[Done]"
                if [ "$(ls $OUTPUT_DIR | grep "missing_image" | wc -l)" -gt 0 ];then
                    images=($(cat $OUTPUT_DIR/missing_image.* | xargs))
                    log "info" "Missing images include:"
                    for im in ${images[@]}; do
                        echo "$im" && echo "$im" >> $LOG_FILE
                    done
                else
                    images=()
                    log "info" "No image missing"
                    if [[ "$SKIP_PACKING" == "true" ]];then
                        #genereate image validation result
                        generateImageValidationResult "$allImages" "${images[*]}"
                        exit 0
                    fi
                fi

                if [ -f $KEY_FILE ];then
                    $RM -f $KEY_FILE
                fi
            else
                if [ "$IN_APPHUB_POD" == "true" ];then
                    log "fatal" "Failed to contact registry" "22"
                else
                    log "warn" "Failed to contact registry, will generate the full image-set.json for the offline-download.zip."
                fi
            fi
        else
            if [ "$IN_APPHUB_POD" == "true" ];then
                log "fatal" "Failed to get registry credential and url" "23"
            else
                log "warn" "Failed to get registry credential and url, will generate the full image-set.json for the offline-download.zip."
            fi
        fi
    else
        REG_ORGNAME=$DELTA_REG_ORGNAME
    fi

    #genereate image validation result
    generateImageValidationResult "$allImages" "${images[*]}"

    #orgname priority: CLI > cluster env > image-set.json > default
    #if not skip image check, REG_ORGNAME is either from CLI or from Cluster env or empty
    #if skip image check, REG_ORGNAME is either from CLI or empty
    org_name=${DELTA_REG_ORGNAME:-${REG_ORGNAME:-"$org_name"}}
    if [ -z "$org_name" ];then
        org_name="hpeswitom"
    fi

    local imageSetFile
    if [ "$SKIP_PACKING" == "true" ]; then
        imageSetFile="image-set-`date "+%Y%m%d%H%M%S"`.json"
    else
        imageSetFile="image-set.json"
    fi
    mkdir -p ${OFFLINE_DOWNLOAD_DIR}

    echo '{}' | jq -r '. + {
        suite: "'"${suite_name}"'",
        display_name: "'"${display_name}"'",
        org_name: "'"${org_name}"'",
        version: "'"${suite_version}"'",
        images: '"$(echo '[]' | jq -r ".$(for im in "${images[@]}"; do echo " + [ {image: \"$im\"} ]";done)")"'
    }' > ${OFFLINE_DOWNLOAD_DIR}/$imageSetFile

    if [ "$SKIP_PACKING" == "true" ];then
        echo "$imageSetFile" > ${OFFLINE_DOWNLOAD_DIR}/image-set-file-name
        exit 1
    fi
}

generateImageValidationResult(){
    local allImages=$1
    local notFoundImages=$2
    if [ -n "$IMAGE_VALIDATE_JSON" ]; then
        # create directory if not exist and check r/w permission
        local resultDir=$(dirname $IMAGE_VALIDATE_JSON)
        if [ ! -d "$resultDir" ]; then
            mkdir -p $resultDir
            if [ $? -ne 0 ]; then
                log "fatal" "Can't create directory $resultDir; please specify the file $IMAGE_VALIDATE_JSON in a directory with read and write permissions."
            fi
        elif [ ! -w "$resultDir" ] || [ ! -r "$resultDir" ]; then
            log "fatal" "Can't read or write under $resultDir; please specify the file $IMAGE_VALIDATE_JSON in a directory with read and write permissions."
        fi
        # find out foundImage list
        local foundImages=
        for image in $allImages
        do
            local exist="false"
            for nfi in $notFoundImages
            do
                if [ "$nfi" = "$image" ]; then
                    exist="true"
                    break
                fi
            done
            if [ "$exist" = "false" ];then
                foundImages="$foundImages $image"
            fi
        done
        # generate result file
        local fims=
        local nfims=
        if [ -n "$foundImages" ]; then
            fims=$(for fim in $foundImages; do echo -n "{name:\"$fim\",found:true},";done)
            fims=${fims::-1} #remove the last character ','
        fi
        if [ -n "$notFoundImages" ]; then
            nfims=$(for nfim in $notFoundImages; do echo -n "{name:\"$nfim\",found:false},";done)
            nfims=${nfims::-1} #remove the last character ','
        fi
        echo '{"images":[]}' | jq -r ".images += [${fims}]" | jq -r ".images += [${nfims}]" > $IMAGE_VALIDATE_JSON
        if [ $? -ne 0 ]; then
            log "fatal" "Can't generate file $IMAGE_VALIDATE_JSON under $resultDir"
        fi
    fi
}

packBundle(){
    if [ "$SKIP_PACKING" == "false" ]; then
        $CP $BIN_DIR/jq $BIN_DIR/notary $SCRIPT_DIR/downloadimages.sh $SCRIPT_DIR/uploadimages.sh ${AWS_ECR_CREATE_REPOSITORY} ${OFFLINE_DOWNLOAD_DIR}
        cd $OUTPUT_DIR && zip -q -r offline-download.zip offline-download && rm -rf offline-download
        log "info" "offline-download.zip is generated under $OUTPUT_DIR"
        log "info" "For more details, please refer: $LOG_FILE"
    fi
}
generateFromChart(){
    log "info" "generate offline-download.zip from $CHART_FILE"

    local images file suite_name org_name suite_version
    if [ ! -r "$CHART_FILE" ];then
        log "fatal" "Can't find ${CHART_FILE}, please make sure file exists and gets right permission"
    fi
    CHART_FOLDER=$(mktemp -d -p $OUTPUT_DIR)
    if [ -z "$VALUES_FILE" ];then
        log "infolog" "no values yaml file provided"
        #strick the folder level to top folder or the second level folder
        file=$(tar -tf  ${CHART_FILE}  | awk -F/ '{if (NF<3) print }' | grep "image-set.json")
        if [ -z "$file" ];then
            log "fatal" "There is no image-set.json file in $CHART_FILE. Please provide values yaml file and try to generate again." "24"
        fi

        log "begin" "Decompressing chart file"
        tar -zxf ${CHART_FILE} -C $CHART_FOLDER ${file}
        if [ $? -ne 0 ];then
            log "end" "[Failed]"
            log "fatal" "extract ${file} from ${CHART_FILE} failed" "27"
        fi
        log "end" "[OK]"
        local image_set=$(cat $CHART_FOLDER/$file)
        suite_name=${SUITE_NAME:-"$(echo $image_set | jq -r ".suite")"}
        org_name=$(echo $image_set | jq -r ".org_name")
        suite_version=${SUITE_VERSION:-"$(echo $image_set | jq -r ".version")"}
        images=$(echo $image_set | jq -r ".images|.[].image" | xargs)
    else
        #use full path, as in packBundle we will change directory making relative path not work when deleting temp file
        log "infolog" "values yaml file provided"
        if [ ! -r "$VALUES_FILE" ];then
            log "fatal" "Can't find ${VALUES_FILE}, please make sure file exists and gets right permission"
        fi
        CHART_YAML=$(mktemp -p $CHART_FOLDER)
        local option tmp_images extra_images
        if [ -n "$VALUES_FILE" ];then
            option=" -f $VALUES_FILE"
        fi
        if [ "$HELM_DEBUG" = "true" ]; then
            option="$option --debug"
        fi

        log "begin" "Rendering chart"
        if [ $(exec_cmd "helm template test ${CHART_FILE} ${option} >${CHART_YAML} 2>&1" -p=false; echo $?) -ne 0 ];then
            log "end" "[Failed]"
            local additional_msg
            if [ -n "$VALUES_FILE" ];then
                additional_msg=", the provided values yaml file may not correct"
            fi
            local helm_debug_msg=
            if [ "$HELM_DEBUG" = "true" ]; then
                helm_debug_msg=$(cat $CHART_YAML)
            fi
            log "fatal" "Failed to run: helm template${additional_msg}!\n$helm_debug_msg" "25"
        fi
        log "end" "[OK]"
        tmp_images=$(cat ${CHART_YAML} | grep "image:" | sed -e 's/image://g; s@"@@g; s/\r//g' | xargs)
        log "infolog" "images from helm templat:  $tmp_images"
        extra_images=$(yq -N e '.metadata.annotations."deployments.microfocus.com/extra-images"' ${CHART_YAML} 2>/dev/null | grep -v "null" | sed -e 's@"@@g')
        extra_images=${extra_images//,/ }
        log "infolog" "additional images from annotaion:  $extra_images"
        for im in $tmp_images $extra_images; do
            if [ "$im" == "-" ];then
                continue
            fi
            image=${im##*/}
            images="$images $image"
        done
    fi

    getDeltaImagesetFromRegistry "$suite_name" "$suite_version" "$org_name" "$images"
    packBundle
}
getSuiteInfoFromConfig(){
    local config_file=$1

    if [ ! -f $config_file ];then
        log "fatal" "$config_file not found!"
    fi

    local has_cap cap
    has_cap=$(cat $config_file | jq -r 'has("capabilities")')
    if [ "$has_cap" == "false" ];then
        log "fatal" "Can't find capabilities section in $config_file."
    fi
    cap=$(jq -r '.capabilities' $config_file)
    CFG_SUITE_NAME=$(echo "$cap" | jq -r '.suite')
    CFG_SUITE_VERSION=$(echo "$cap" | jq -r '.version')
    local has_cap_selection
    has_cap_selection=$(echo "$cap" | jq -r 'has("capabilitySelection")')
    if [ "$has_cap_selection" == "true" ];then
        CFG_CAP_SEL=$(echo "$cap" | jq -r '.capabilitySelection[]|.name' | sort -u | xargs)
    fi
}
getCdfCommonImage(){
    local cdf_property_files k8s_property_files pkgs images="" image_pack_config=$currentDir/../../image_pack_config.json
    if [ ! -f "$image_pack_config" ];then
        log "fatal" "image_pack_config.json not found!"
    fi

    if [ -f "$currentDir/../../cdf/properties/images/images.properties" ];then
        cdf_property_files=$currentDir/../../cdf/properties/images/images.properties
    elif [ -f "$currentDir/../../properties/images/images.properties" ]; then
        cdf_property_files=$currentDir/../../properties/images/images.properties
    else
        log "fatal" "images.properties not found"
    fi
    source $cdf_property_files

    #include all images to support change registry url. feature-ID:1445009
    if [ "$SKIP_DUPLICATE" == "true" ];then  #it is an inner option, may removed future
        pkgs=""
    else
        pkgs=$(jq -r '.usage.byok_cdf|.[]' $image_pack_config | xargs)
    fi
    if [ -n "$pkgs" ];then
        for pkg in ${pkgs}; do
            local items=$(jq -r ".packages[]|select (.name==\"$pkg\").images[]" $image_pack_config | xargs)
            if [ -n "$items" ];then
                for item in ${items};do
                    local image=$(eval echo "\$$item")
                    images="$images $image"
                done
            fi
        done
    fi
    images=$(echo "$images" | tr " " "\n" | sort -u | xargs)
    echo "$images"
}
generateFromMeta(){
    local meta_tmp=${currentDir}/meta_tmp
    mkdir $meta_tmp
    tar -xzf ${METADATA} -C ${meta_tmp}
    local suite_name suite_version suite_fs

    if [ -n "$SUITE_NAME" ];then
        if [ -z "$SUITE_VERSION" ];then
            log "fatal" "suite version should be provided with suite name together."
        fi
        suite_name=$SUITE_NAME
        suite_version=$SUITE_VERSION
        suite_fs=$FEATURE_SET
    else
        if [ -z "$CONFIG_FILE" ];then
            log "fatal" "either configuration file or suite name/suite version must be provided."
        fi
        getSuiteInfoFromConfig "$CONFIG_FILE"
        suite_name=$CFG_SUITE_NAME
        suite_version=$CFG_SUITE_VERSION
        suite_fs=$CFG_CAP_SEL
    fi

    if [[ "$suite_fs" =~ "," ]];then
        suite_fs=${suite_fs//,/ }
    fi
    #can't determine suite_name or suite_version
    if [ -z "$suite_name" ] || [ -z "$suite_version" ];then
        log "fatal" "Can't determine suite name or suite version, we can't get images from metadata."
    fi
    log "info" "Aggregate valid image from metadata."
    json_file="${meta_tmp}/suite-metadata/suite_feature/${suite_name}/${suite_version}/${suite_name}_suitefeatures.${suite_version}.json"
    if [ ! -f $json_file ];then
        log "fatal" "${suite_name}_suitefeatures.${suite_version}.json is not found in ${METADATA}. The metadata may broken!"
    fi
    local suite_pub_image suite_cap_sel_image suite_images cdf_common_image all_image
    suite_pub_image=$(jq -r '.images[]|.image' $json_file 2>>$LOG_FILE)
    if [[ $? -ne 0 ]];then
        log "fatal" "Failed to parse file: $json_file"
    fi
    suite_pub_image=$(echo $suite_pub_image | xargs)
    if [ -n "$suite_fs" ]; then
        for sel in ${suite_fs}; do
            local sel_image
            sel_image=$(jq -r ".feature_sets[] | select (.id == \"$sel\") | .images[]|.image" $json_file )
            if [[ $? -ne 0 ]];then
                log "fatal" "Failed to parse file: $json_file"
            fi
            sel_image=$(echo $sel_image | xargs)
            suite_cap_sel_image="$suite_cap_sel_image $sel_image"
        done
    else
        suite_cap_sel_image=$(jq -r '.feature_sets[].images[].image' $json_file | xargs)
    fi
    if [ -d ${meta_tmp} ];then
        rm -rf ${meta_tmp}
    fi
    suite_images="$suite_pub_image $suite_cap_sel_image"
    cdf_common_image=$(getCdfCommonImage)
    all_image="${suite_images} ${cdf_common_image}"
    getDeltaImagesetFromRegistry "$suite_name" "$suite_version" "" "$all_image"
    packBundle
}
generate4SuiteLifecycle(){
    preSteps
    checkPrimaryDeployment
    calculateLifecycle

    log "info" "Generating the offline image download bundle for suite $LIFE_CYCLE ..."

    local has_cap cap suite_name suite_version suite_fs org_name
    if [ -n "$SUITE_VERSION" ];then
        if [ "$LIFE_CYCLE" == "install" ] && [ -z "$SUITE_VERSION" ];then
            log "fatal" "suite name must be provided for suite install."
        fi
        suite_name=$SUITE_NAME
        suite_version=$SUITE_VERSION
        suite_fs=$FEATURE_SET
    else
        if [ -z "$CONFIG_FILE" ];then
            log "fatal" "either configuration file or suite name/suite version must be provided for suite ${LIFE_CYCLE}!"
        fi
        getSuiteInfoFromConfig "$CONFIG_FILE"
        suite_name=$CFG_SUITE_NAME
        suite_version=$CFG_SUITE_VERSION
        suite_fs=$CFG_CAP_SEL
    fi

    if [[ ${suite_fs} =~ "," ]];then
        suite_fs=${suite_fs//,/ }
    fi
    if [ -n "$suite_fs" ];then
        local tmp_suite_fs=$suite_fs
        suite_fs="[]"
        for fs in $tmp_suite_fs;do
            suite_fs=$(echo "$suite_fs" | jq -r ".+[{\"name\":\"$fs\"}]")
        done
    fi

    local api_url="/urest/v1.1/lifecycle/${LIFE_CYCLE}/images:calculate"
    local postBody
    case $LIFE_CYCLE in
        update)
            if [ -z "$suite_version" ];then
                log "fatal" "Please specify the intended version for suite update!"
            fi
            postBody="{\"targetVersion\":\"$suite_version\"}"
            ;;
        reconfigure)
            if [ -z "$suite_fs" ];then
                log "fatal" "Please specify the intended feature set for suite reconfig!"
            fi
            postBody="{\"featureSets\":${suite_fs}}"
            ;;
        install)
            if [ -z "$suite_name" ] || [ -z "$suite_version" ];then
                log "fatal" "Please specify the suite name and version for suite install!"
            fi
            postBody="{\"suite\":\"$suite_name\",\"version\":\"$suite_version\"}"
            ;;
    esac
    requestImageList "${api_url}" "${postBody}"
    getDeltaImagesetFromRegistry "$suite_name" "$suite_version" "" "$IMAGE_LIST"
    packBundle
}

generateFromImageSet(){
    if [ "$SKIP_PACKING" == "false" ];then
        log "info" "generate offline-download.zip from $IMAGE_SET_FILE"
    fi

    local image_set=$(cat $IMAGE_SET_FILE)
    local suite_name=${SUITE_NAME:-"$(echo $image_set | jq -r ".suite")"}
    local org_name=$(echo $image_set | jq -r ".org_name")
    local suite_version=${SUITE_VERSION:-"$(echo $image_set | jq -r ".version")"}
    local images=$(echo $image_set | jq -r ".images|.[].image" | xargs)

    getDeltaImagesetFromRegistry "$suite_name" "$suite_version" "$org_name" "$images"
    packBundle
}

preSteps(){
    local cm=cdf
    local capabilities=$(exec_cmd "kubectl get cm $cm -n $CDF_NAMESPACE -o json | jq -r '.data.CAPABILITIES'" -p=true)
    if [[ ! "$capabilities" =~ "deploymentManagement=true" ]]; then
        log "warn" "The deploymentManagement capability is not enabled, cannot generate download bundle with cdf-apiserver.\nPlease provide the charts or suite metadata to generate the bundle.\n"
        usage "1"
    fi
    if [ "$SKIP_VERIFY" == "true" ];then
        CDFAPISERVER_CURL_OPT=" -k "
    else
        local public_ca cus_ca
        CA_TMP=$(mktemp)
        public_ca=$(exec_cmd "kubectl get cm public-ca-certificates -n ${CDF_NAMESPACE} -o json" -p=true)
        if [ $? -ne 0 ];then
            log "fatal" "Failed to get CA from public-ca-certificates configmap!"
        fi
        cus_ca=$(echo $public_ca | jq -r '.data["CUS_ca.crt"]?')
        if [ -n "$cus_ca" ] && [ "$cus_ca" != "null" ];then
            echo $public_ca | jq -r '.data["CUS_ca.crt"]?' > $CA_TMP
        else
            echo $public_ca | jq -r '.data["RE_ca.crt"]?' > $CA_TMP
        fi
        CDFAPISERVER_CURL_OPT=" --cacert $CA_TMP "
    fi
    getAuth
    setApiBaseUrl
    getXtoken
    getCsrfTokenSessionID
}

preCheck(){
    if [[ $DELTA_REG_ORGNAME =~ [A-Z] ]];then
        log "fatal" "error registry orgnization name: $DELTA_REG_ORGNAME, it must be in lowercase"
    fi
    if ([ -z "$IMAGE_SET_FILE" ] && [ -z "$CHART_FILE" ] && [ -z "$METADATA" ]) && ([ -n "$DELTA_REG" ] || [ -n "$DELTA_REG_ORGNAME" ] || [ -n "$DELTA_REG_USERNAME" ] || [ -n "$DELTA_REG_PASSWORD" ]);then
        log "fatal" "Please provide metadata or image-set or chart file."
    fi
    if [ -n "$IMAGE_SET_FILE" ] && ([ -n "$CONFIG_FILE" ] || [ -n "$CHART_FILE" ] || [ -n "$METADATA" ]); then
        log "warn" "when image-set file is provide, no other files are required, and they will be ignored."
    fi
    if [ -n "$CHART_FILE" ] && ([ -n "$CONFIG_FILE" ] || [ -n "$IMAGE_SET_FILE" ] || [ -n "$METADATA" ]); then
        log "warn" "when chart file is provide, no other files are required, and they will be ignored."
    fi
    if ([ -n "$METADATA" ] || [ -n "$CONFIG_FILE" ]) && ([ -n "$CHART_FILE" ] || [ -n "$IMAGE_SET_FILE" ]); then
        log "warn" "when metadata or configure file is provide, no chart or image-set are required, and they will be ignored."
    fi

    local json_files="$CONFIG_FILE $IMAGE_SET_FILE"
    for file in ${json_files}; do
        if [ ! -r $file ];then
            log "fatal" "can't find $file, please make sure the file exists and gets the right permission!"
        fi
        jq '.' $file 2>/dev/null 1>&2
        if [ $? -ne 0 ];then
            log "fatal" "$file not a valid json file!"
        fi
    done

    if [[ "$SKIP_PACKING" == "false" ]];then
        AWS_ECR_CREATE_REPOSITORY=""
        if [ -e "$BIN_DIR/aws-ecr-create-repository" ];then
            AWS_ECR_CREATE_REPOSITORY="${BIN_DIR}/aws-ecr-create-repository"
        else
            log "fatal" "aws-ecr-create-repository not found!"
        fi
        local other_file="$CHART_FILE $METADATA ${BIN_DIR}/jq ${BIN_DIR}/notary ${SCRIPT_DIR}/downloadimages.sh ${SCRIPT_DIR}/uploadimages.sh"
        for file in ${other_file};do
            if [ ! -r $file ];then
                log "fatal" "can't find $file, please make sure the file exists and gets the right permission!"
            fi
        done
        local res1 res2
        res1=$( which zip > /dev/null 2>&1; echo $? )
        res2=$( whereis zip 2>/dev/null | awk -F: '{print $2}' )
        if [ $res1 -ne 0 ] && [ -z "$res2" ]; then
            log "fatal" "Command: \"zip\" not found. Please install \"zip\" tool first!"
        fi
        if [ ! -d "$OFFLINE_DOWNLOAD_DIR" ];then
            mkdir -p $OFFLINE_DOWNLOAD_DIR
        fi
    else
        SILENT_MODE="true"
    fi
}


trap 'taskClean; exit' 1 2 3 8 9 14 15 EXIT
SKIP_CHECK_IMAGE=${SKIP_CHECK_IMAGE:-"false"}
SKIP_DUPLICATE=${SKIP_DUPLICATE:-"false"}
SKIP_PACKING=${SKIP_PACKING:-"false"}
SKIP_VERIFY=${SKIP_VERIFY:-"false"}
OUTPUT_DIR=${OUTPUT_DIR:-"$(pwd)"}
if [ "$SKIP_PACKING" == "false" ];then
    OFFLINE_DOWNLOAD_DIR=${OUTPUT_DIR}/offline-download
else
    OFFLINE_DOWNLOAD_DIR=${OUTPUT_DIR}
fi
NOPROXY_OPT=" --noproxy localhost,kube-registry.$MY_POD_NAMESPACE"


preCheck
if [ -n "$IMAGE_SET_FILE" ];then
    generateFromImageSet
elif [[ -n "$CHART_FILE" ]]; then
    generateFromChart
elif [ -n "$METADATA" ]; then
    generateFromMeta
else
    generate4SuiteLifecycle
fi