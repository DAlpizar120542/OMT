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


export LC_ALL=C

if [[ "bash" != "$(readlink /proc/$$/exe|xargs basename)" ]];then
    echo "Error: only bash support, current shell: $(readlink /proc/$$/exe)"
    exit 1
fi
set +o posix

trap "echo -e '\nAbort silent installation.\n'; exit 1" 1 2 3 6 8 9 14 15
unset CDF_LOADING_LAST_PID

CDF_DEV_INSECURITY_DEBUG_LOG=false

CURRENTDIR=$(cd `dirname $0`; pwd)
SYSTEM_NAMESPACE=${CDF_NAMESPACE:-core}
CDF_APISERVER_HOST="suite-installer-svc"
CDF_APISERVER_PORT=8443
BASE_URL="https://${CDF_APISERVER_HOST}:${CDF_APISERVER_PORT}"
SUITE_FRONTEND_HOST="itom-frontend-ui"
SUITE_FRONTEND_PORT=8443
SUITE_FRONTEND_URL="https://${SUITE_FRONTEND_HOST}:${SUITE_FRONTEND_PORT}"
FAILED_WORKER=0
FAILED_MASTER=0
SKIP_FAILED_WORKER_NODES_FILE="$CDF_INSTALL_RUNTIME_HOME/cdf_skip_failed_worker_nodes.tmp"



# legal notice
show_legal_notice(){
    if [[ ! -f "$CONFIG_FILE" ]];then
        return
    fi
    local hasAdminPwd=$($JQ 'has("adminPassword")' $CONFIG_FILE)
    local hasNodePwd="false"
    if [[ -n "$(cat $CONFIG_FILE|$JQ -r '.masterNodes[].password' 2>/dev/null)" ]] && [[ "$(cat $CONFIG_FILE|$JQ -r '[.masterNodes[].password]|map(type)[]' 2>/dev/null|xargs -n1|sort|uniq)" != "null" ]];then
        hasNodePwd="true"
    fi
    if [[ -n "$(cat $CONFIG_FILE|$JQ -r '.workerNodes[].password' 2>/dev/null)" ]] && [[ "$(cat $CONFIG_FILE|$JQ -r '[.workerNodes[].password]|map(type)[]' 2>/dev/null|xargs -n1|sort|uniq)" != "null" ]];then
        hasNodePwd="true"
    fi
    if [[ "$hasAdminPwd" == "true" ]] || [[ "$hasNodePwd" == "true" ]]; then
        write_log "warn" "The Administrator password is stored in plaintext in $CONFIG_FILE. OpenText recommends storing this file in a secure location or deleting it after the installation completes. By not implementing relevant protection measures you may be exposing the system to increased security risks. You understand and agree to assume all associated risks and hold OpenText harmless for the same. It remains at all times the Customer's sole responsibility to assess its own regulatory and business requirements. OpenText does not represent or warrant that its products comply with any specific legal or regulatory standards applicable to Customer in conducting Customer's business."
    fi
}

# comm
readonly MSG_UPDATE_START="Starting deployment <lifecycle> ..."
readonly MSG_UPDATE_UUID_GET="Getting deployment UUID ..."
readonly MSG_UPDATE_UUID_STATUS="Deployment name/UUID: <name>/<uuid>"
readonly MSG_COMM_IMAGES_CLAC="Collecting required container images ..."
readonly MSG_COMM_IMAGES_CHECK="Verifying if all images are available in the image registry ..."
readonly MSG_COMM_IMAGES_STATUS="Images required/available: <required>/<available>"
readonly MSG_UPDATE_CHECK_TYPE="Determining update type ..."
# simple update
readonly MSG_SIMPLE_UPDATE_START="Starting simple suite update ..."
readonly MSG_SIMPLE_UPDATE_PROGRESS="Checking update progress. Please wait ..."
readonly MSG_SIMPLE_UPDATE_FINISHED="Update finished."
readonly MSG_SIMPLE_UPDATE_SHOW_VERSION="Suite version was updated to <version>"
# complex update
readonly MSG_COMPLEX_DEPLOYER_START="Starting upgrade deployer pod ..."
readonly MSG_COMPLEX_DEPLOYER_SHOW="Upgrade deployer pod (<namespace>/<pod>) started."
readonly MSG_COMPLEX_UPGRADE_POD_START="Starting suite upgrade pod ..."
readonly MSG_COMPLEX_UPGRADE_POD_SHOW="Suite upgrade pod (<namespace>/<pod>) started."
readonly MSG_COMPLEX_UPGRADE_POD_WAIT="Waiting until the upgrade pod is running ..."
readonly MSG_COMPLEX_UPGRADE_POD_STATUS="The upgrade pod is running."
readonly MSG_COMPLEX_UPGRADE_POD_URL="The suite upgrade pod URL is <url>"
readonly MSG_COMPLEX_SUITE_POD_START="Starting actual suite upgrade ..."
readonly MSG_COMPLEX_SUITE_POD_PROGRESS="Checking update progress. Please wait ..."
readonly MSG_COMPLEX_SHOW_VERSION="Update finished. Suite version was updated to <version>"

readonly MSG_VOLUME_VALIDATE="{
    \"select-volume-validate-msg1\":\"Successfully created PV and PVC.\",
    \"select-volume-validate-msg2\":\"Cannot connect to server.\",
    \"select-volume-validate-msg3\":\"The NFS directory doesn't exist.\",
    \"select-volume-validate-msg4\":\"You can not set two same paths under one IP address.\",
    \"select-volume-validate-msg5\":\"The NFS host does not have PVC/PV.\",
    \"select-volume-validate-msg6\":\"Invalid deployment ID or namespace\",
    \"select-volume-validate-msg7\":\"You do not have write permission for this directory or you have specified either a non-empty directory or non-existent directory.\",
    \"select-volume-validate-msg8\":\"Exported Path should be absolute path.\",
    \"select-volume-validate-msg9\":\"The Exported Path is occupied.\",
    \"select-volume-validate-msg10\":\"You must enter a value for all fields.\",
    \"select-volume-validate-msg11\":\"Failed to connect this volume to external storage.\",
    \"select-volume-validate-msg12\":\"Failed to delete a PV or PVC.\",
    \"select-volume-validate-other-msg\":\"Failed to create a volume.\"
}"

# If adding node fails, you need to send the API for adding nodes (master2,master3 and all workers).
readonly FLAG_EXIST_RETRY_ADDNODE="@exist_retry_addnode"

########## Function START ##########
usage(){
    echo -e "Usage: $0 [Options]"
    echo -e "\n[Mandatory options]"
    echo -e "  -c|--config                 Specifies the absolute path of the config file for silent installation, reconfig or update"
    echo -e "  -L|--lifecycle              Specifies the lifecycle of silent action. Allowable value: install, delete, reconfig, update"
    echo -e "  -m|--metadata               Specifies the absolute path of the tar.gz suite metadata packages."
    echo -e "  -p|--password               Specifies the password for administrator"
    echo -e "  -u|--username               Specifies the username of administrator"
    echo -e "\n[Other options]"
    echo -e "  -e|--end-state              Specifies end state of silent installation: full-cdf, suite (Mandatory for install)"
    echo -e "  -E|--external-rep           Flag for indicate whether using external repository for deploy CDF and suite"
    echo -e "  -U|--registry-username      Specifies the username for registry"
    echo -e "  -P|--registry-password      Specifies the password for registry"
    echo -e "  -h|--help                   Lists a help message explaining proper usages"
    echo -e "  -i|--image-folder           Specifies the absolute path of image tar folder.Multiple paths can be specified, with comma(',') delimited and single quotes quoted."
    echo -e "  -t|--timeout                Specifies the suite installation timeout minutes. Default is 60 minutes."
    echo -e "  -d|--deployment             Specifies the suite installation deployment name."
    echo ""
    exit 1
}

CURRENT_PID=$$
spin(){
    sleep 1
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
            echo -n "${spinner:$i:1}" 2>/dev/null
            echo -en "\010" 2>/dev/null
            ps -p $CURRENT_PID > /dev/null 2>&1
            if [[ $? -ne 0 ]] ; then
                lost=true
                break
            fi
            sleep 0.125
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
        if [[ $? == 0 ]]; then
            kill -s SIGTERM $CDF_LOADING_LAST_PID >/dev/null 2>&1
            wait $CDF_LOADING_LAST_PID >/dev/null 2>&1
        fi
        CDF_LOADING_LAST_PID=
    fi
}

loadingFunc(){
    local fn=$1
    startLoading
    "$fn"
    stopLoading
}

tipsForFixConfig(){
    if is_step_not_done "@updateFullJsonParams";then
        echo "You can try to modify the configuration file ($CONFIG_FILE) to fix this error, then rerun install."
    fi
}

getRfcTime(){
    local fmt=$1
    date --rfc-3339=${fmt}|sed 's/ /T/'
}

toUpper(){
    echo "$1"|tr '[:lower:]' '[:upper:]'
}

toLower(){
    echo "$1"|tr '[:upper:]' '[:lower:]'
}

write_log() {
    local level=$1
    local msg=$2
    local status=$3
    local consoleTimeFmt=$(getRfcTime 'seconds')
    local logTimeFmt=$(getRfcTime 'ns')
    [ -n "$status" ] && showStatus "$status"
    if [[ -n "$CDF_LOADING_LAST_PID" ]] && [[ "$level" =~ ^(cata|step|info|warn|error|loading|fatal)$ ]];then
        stopLoading
        echo -e " "
    fi
    case $level in
        cata)
            echo -e "$consoleTimeFmt INFO : [NODE:${THIS_NODE}] $msg";;
        debug)
            echo -e "$logTimeFmt DEBUG $msg" >>$LOGFILE
            ;;
        warnlog)
            echo -e "$logTimeFmt WARN $msg" >>$LOGFILE
            ;;
        infolog)
            echo -e "$logTimeFmt INFO $msg" >>$LOGFILE
            ;;
        step)
            echo -n "$consoleTimeFmt INFO : $msg" && uniformStepMsgLen "${#msg}"
            echo -e "$logTimeFmt INFO  $msg" >>$LOGFILE
            startLoading
            ;;
        info|warn|error)
            echo -e "$consoleTimeFmt `echo $level|tr [:lower:] [:upper:]` : $msg" && echo -e "$logTimeFmt `echo $level|tr [:lower:] [:upper:]`  $msg" >>$LOGFILE
            ;;
        loading)
            echo -n "$consoleTimeFmt INFO : $msg " && echo -e "$logTimeFmt `echo $level|tr [:lower:] [:upper:]`  $msg" >>$LOGFILE
            startLoading
            ;;
        fatal)
            echo -e "$consoleTimeFmt FATAL : $msg" && echo -e "$logTimeFmt FATAL $msg" >>$LOGFILE
            exit 1 ;;
        *)
            echo -e "$consoleTimeFmt INFO : $msg" && echo -e "$logTimeFmt INFO  $msg" >>$LOGFILE
            ;;
    esac
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

showStatus(){
    stopLoading
    local status=$(echo $1|tr [:lower:] [:upper:])
    echo -e "[ $status ]"
}

MASK_REG_EXP="(?i)(sessionId|token|password|passPhrase|key|crt|cert)(\"?\s*[:=]\s*)[^',}\s]*"

exec_cmd(){
    local msOption="-ms"
    if [[ "$CDF_DEV_INSECURITY_DEBUG_LOG" == "true" ]];then
        msOption=""
    fi
    if [ "$INSTALLED_TYPE" = "CLASSIC" ];then
        ${CDF_HOME}/bin/cmd_wrapper -c "$1" -f "$LOGFILE" -x "DEBUG" $msOption -mre $MASK_REG_EXP $2 $3 $4 $5
    else
        $CURRENTDIR/../../bin/cmd_wrapper -c "$1" -f "$LOGFILE" -x "DEBUG" $msOption -mre $MASK_REG_EXP $2 $3 $4 $5
    fi
    return $?
}

wrap_curl(){
    # if [ "$INSTALLED_TYPE" = "CLASSIC" ];then
    #     ${CDF_HOME}/bin/cmd_wrapper -c "$1" -f "$LOGFILE" -x "DEBUG" -ms -mre $MASK_REG_EXP $2 $3 $4 $5
    #     return $?
    # fi
    # for BYOK and On-Premise
    local curl_cmd=$1
    local val=
    local ret_code=
    local container_name="cdf-apiserver"
    local pod_name=

    for (( n=0; n<RETRY_TIMES; n++ ));do
        # check k8s apiserver running
        for (( i=0; i<$RETRY_TIMES; i++));do
            if exec_cmd "$kubectl get pods -n ${SYSTEM_NAMESPACE}";then
                break
            fi
            write_log "warnlog" "Current k8s apiserver unstable and may be a problem with the network or etcd."
            sleep $SLEEP_TIME
        done

        # get pod_name
        local retry=0
        while true; do
            pod_name=$(exec_cmd "$kubectl get pods -n ${SYSTEM_NAMESPACE} 2>>'$LOGFILE'|grep '$container_name'|grep 'Running'|awk '{len=split(\$2,arr,\"/\");if(len==2&&arr[1]>0&&arr[1]==arr[2])print \$1}'" -p true)
            if [ -z "$pod_name" ];then
                if [ "$retry" -gt "$RETRY_TIMES" ]; then
                    write_log "fatal" "Failed to get $container_name pod name. Current k8s apiserver or pod unstable and may be a problem with the network or etcd."
                else
                    retry=$((retry+1))
                    sleep $SLEEP_TIME
                fi
            else
                break
            fi
        done

        # request API
        # val=$(eval "$kubectl exec $pod_name -n ${SYSTEM_NAMESPACE} -c $container_name 2>>'$LOGFILE' -- $curl_cmd" 2>>"$LOGFILE")
        val=$(exec_cmd "$kubectl exec $pod_name -n ${SYSTEM_NAMESPACE} -c $container_name 2>>'$LOGFILE' -- $curl_cmd" -p=true -m=${CDF_DEV_INSECURITY_DEBUG_LOG} -o=${CDF_DEV_INSECURITY_DEBUG_LOG})
        ret_code=$?
        if [[ "$ret_code" -eq 0 ]];then
            if [[ "$curl_cmd" =~ %\{http_code\} ]];then
                if [[ -n "$val" ]];then
                    write_log "warnlog" "http_code: ${val:0-3}"
                    break
                else
                    write_log "warnlog" "kubectl exec exit code is 0, but 'val' is not get any output from stdout, retry ..."
                fi
            else
                break
            fi
        fi
        write_log "warnlog" "Current k8s or pod unstable and retry run kubectl exec ..."
        sleep $SLEEP_TIME
    done

    if ! echo "$2 $3 $4 $5"|grep '\-[mo]=false' 1>/dev/null 2>&1;then
        record "$kubectl exec $pod_name -n ${SYSTEM_NAMESPACE} -c $container_name -- $curl_cmd"
        record "$val"
    fi
    if [[ -z "$val" ]] && [[ "$curl_cmd" =~ %\{http_code\} ]];then
        val="000"
        write_log "warnlog" "There may be an error in the response of the current API, and the content is empty, cmd exitCode: $ret_code."
    fi
    echo "$val"
    return $ret_code
}

record(){
    echo "`getRfcTime 'ns'` DEBUG # $1"|sed -r "s/((sessionId|token|password|privateKey|pass)(\": *\"| *: *|=| *'))[^\"']+/\\1***/gi" >>$LOGFILE 2>/dev/null
}

isFirstInstall(){
    if [ -f "$STEPS_FILE" ];then
        return 0
    else
        return 1
    fi
}

set_step_done(){
    exec_cmd "echo $1 >>$STEPS_FILE"
}

is_step_not_done(){
    [ "$(grep $1 $STEPS_FILE 2>/dev/null|wc -l)" -eq 0 ] && return 0 || return 1
}

is_exist_flag(){
    [ "$(grep $1 $STEPS_FILE 2>/dev/null|wc -l)" -eq 0 ] && return 1 || return 0
}

record_step(){
    local show_message=$1
    local func_name=$2

    local old_LC_ALL=$LC_ALL
    LC_ALL=C
    if [[ "$(type -t "$func_name")" != "function" ]];then
        write_log "fatal" "Function parameter call error: $FUNCNAME($1,$2)"
    fi
    LC_ALL=$old_LC_ALL

    if [[ "$LIFE_CYCLE" == "install" ]] || [[ "$LIFE_CYCLE" == "update" ]];then
        if is_step_not_done "@$func_name";then
            set_step_done "$func_name..."
            eval "$func_name"
            set_step_done "@$func_name"
        else
            if [[ "${show_message:0:1}" == "#" ]];then
                write_log "infolog" "$show_message (DONE)"
            else
                write_log "info" "$show_message (DONE)"
            fi
        fi
    else
        eval "$func_name"
    fi
}

showCdfEnvTips(){
    if [[ -n "$CDF_ENV_VARS_TIPS" ]];then
        write_log "info" "$CDF_ENV_VARS_TIPS."
    fi
}

showCdfHelmNotes(){
    exec_cmd "${CDF_HOME}/bin/helm get notes $CDF_HELM_RELEASE_NAME -n $CDF_NAMESPACE"
    if [ $? -eq 0 ];then
        write_log "info" "\n$(${CDF_HOME}/bin/helm get notes $CDF_HELM_RELEASE_NAME -n $CDF_NAMESPACE)"
    fi
}

showResolveFailedWorkers(){
    if [[ "$SKIP_FAILED_WORKER_NODE" == "true" ]];then
        local failedWorkers="$(exec_cmd "cat $SKIP_FAILED_WORKER_NODES_FILE|sort|uniq|xargs" -p=true)"
        if [[ -n "$failedWorkers" ]];then
            write_log "warn" "The following worker nodes failed to install: ${failedWorkers// /, }
                             How to resolve:
                             STEP 1: Review the node installation logs and fix any pre-check or configuration errors.
                             SETP 2: Run the following command to check whether the error of node's pre-check is fixed:
                                    (Note: a. cdfctl does not read install.properties, so do not attempt to fix these errors by modifying install.properties;
                                           b. If there is a configuration conflict between the current cluster and the node, and you must add this node, please uninstall $PRODUCT_SHORT_NAME, then update the installation parameters, and then reinstall it.)
cdfctl node precheck --node-type worker --node <node name> --node-user <username> --node-pass <node password> ;
or
cdfctl node precheck --node-type worker --node <node name> --node-user <username> --key <privateKey file> [ --key-pass <passphrase for the privateKey file> ] ;
                             STEP 3: Run 'cdfctl node add' to add the remaining nodes. You can copy/paste the following commands:"
            for node in $failedWorkers;do
                generateAddNodeCli "$node"
            done
        fi
        exec_cmd "$RM -f $SKIP_FAILED_WORKER_NODES_FILE"
    fi
}

finalize(){
    if [ -f "$PREVIOUS_INSTALL_CONFIG" ]; then exec_cmd "$RM -f $PREVIOUS_INSTALL_CONFIG"; fi
    if [ -f "$STEPS_FILE" ]; then
        exec_cmd "$CP -f $STEPS_FILE $LOGDIR/"
        exec_cmd "$RM -f $STEPS_FILE"
    fi
    exec_cmd "$RM -f $CDF_INSTALL_RUNTIME_HOME/user_confirm_skip_precheck_warning_*"
    if [[ -n "$CDF_ALIAS_WARNING" ]];then
        write_log "warn" "$CDF_ALIAS_WARNING."
    fi
    showCdfEnvTips
    showResolveFailedWorkers
    show_legal_notice
    showCdfHelmNotes
}

waitCdfApiServerReady(){
    write_log "loading" "Wait for the cdf-apiserver ready ..."
    local waitSeconds=0
    local timeoutSeconds=600
    local container_name="cdf-apiserver"
    while true;do
        local pod_name;pod_name=$(exec_cmd "$kubectl get pods -n ${SYSTEM_NAMESPACE} 2>/dev/null|grep '$container_name'|grep 'Running'|awk '{len=split(\$2,arr,\"/\");if(len==2&&arr[1]>0&&arr[1]==arr[2])print \$1}'" -p true)
        if [ -n "$pod_name" ];then
            break
        fi
        if [ $waitSeconds -lt $timeoutSeconds ]; then
            waitSeconds=$(( waitSeconds + 60 ))
            sleep 60
        else
            write_log "fatal" "Failed to get ${SYSTEM_NAMESPACE}/$container_name. For detail logs, please refer to $LOGFILE"
        fi
    done

    waitSeconds=0
    while true; do
        local api_url="/urest/v1.1/healthz"
        local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                        -w '%{http_code}' \\
                        --header 'Content-Type: application/json' \\
                        --header 'Accept: application/json' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        '${BASE_URL}${api_url}'" -p=true)
        local http_code=${apiResponse:0-3}
        if [ "$http_code" == "200" ]; then
            break
        fi
        if [ $waitSeconds -lt $timeoutSeconds ]; then
            waitSeconds=$(( waitSeconds + 60 ))
            sleep 60
        else
            write_log "fatal" "Waiting for cdf-apiserver timeout.\nAPI response: ${apiResponse:0:-3}"
        fi
    done
}

getXtoken(){
    write_log "infolog" "Getting X-AUTH-TOKEN"
    local waitForSeconds=0
    local x_auth_token=""
    local api_url="/urest/v1.1/tokens"
    local body="{\"passwordCredentials\":{\"password\":\"$(echo "${SUPER_USERPWD}"|sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\",\"username\":\"${SUPER_USER}\"},\"tenantName\":\"Provider\"}"
    while [ -z "${x_auth_token}" -o "${x_auth_token}" = "null" ]; do
        local apiResponse=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    -d '$(echo "$body"|sed -e "s/'/'\\\\''/g")' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    '${BASE_URL}${api_url}'" -p=true -m=false)
        local http_code=${apiResponse:0-3}
        if [ "$http_code" = "201" ]; then
            x_auth_token=$(echo "${apiResponse:0:-3}" | $JQ -r '.token')
            X_AUTH_TOKEN="X-AUTH-TOKEN: ${x_auth_token}"
            break
        fi
        if [ "$LIFE_CYCLE" = "install" -a "$waitForSeconds" -lt "$TIMEOUT_SECONDS" ]; then
            write_log "warnlog" "Failed to get X-AUTH-TOKEN. API response: ${apiResponse}; will retry in 30 seconds."
            waitForSeconds=$(( waitForSeconds + 30 ))
            sleep 30
        else
            write_log "fatal" "Authentication failed. Failed to get X-AUTH-TOKEN. API response: ${apiResponse}"
            exec_cmd "exit 1"
        fi
    done
}

getCsrfTokenSessionID(){
    write_log "infolog" "Getting X-CSRF-TOKEN"
    local x_csrf_token=""
    local session_id=""
    local session_name=""
    local api_url="/urest/v1.1/csrf-token"
    local waitForSeconds=0
    local totalSeconds=600
    while true; do
        local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                                    -w '%{http_code}' \\
                                    --header 'Accept: application/json' \\
                                    --header '${X_AUTH_TOKEN}' \\
                                    --noproxy '${CDF_APISERVER_HOST}' \\
                                    '${BASE_URL}${api_url}'" -p=true -m=false)
        local http_code=${apiResponse:0-3}
        if [ "$http_code" != "201" ]; then
            if [ "$waitForSeconds" -lt "$totalSeconds" ]; then
                write_log "warnlog" "Failed to get X-CSRF-TOKEN. API response: ${apiResponse}; will retry in 10 seconds."
                waitForSeconds=$(( waitForSeconds + 10 ))
                sleep 10
            else
                write_log "fatal" "Failed to get X-CSRF-TOKEN. API response: ${apiResponse}"
            fi
        else
            x_csrf_token=$(echo "${apiResponse:0:-3}" |$JQ -r '.csrfToken')
            session_id=$(echo "${apiResponse:0:-3}" |$JQ -r '.sessionId' )
            session_name=$(echo "${apiResponse:0:-3}" |$JQ -r '.sessionName')
            if [ -z "${session_name}" -o "${session_name}" = "null" ]; then
                session_name="JSESSIONID"
            fi
            X_CSRF_TOKEN="X-CSRF-TOKEN: ${x_csrf_token}"
            JSESSION_ID="${session_name}=${session_id}"
            break
        fi
    done
}

preSteps(){
    write_log "infolog" "Pre-steps"
    if [[ -n "$CONFIG_FILE" ]] && [[ -f "$CONFIG_FILE" ]];then
        exec_cmd "md5sum $CONFIG_FILE"
    fi
    if [ -z "$CONFIG_FILE" ]; then write_log "fatal" "Need provide json file for silent install/reconfig/update. Type $0 -h for help."; fi
    if [ "$LIFE_CYCLE" != "install" ]; then # silent reconfig or update
        write_log "info" "$(echo "$MSG_UPDATE_START"|sed -e "s#<lifecycle>#${LIFE_CYCLE}#")"
        while [ -z "$SUPER_USER" ]; do read -p "Please input the administrator username: " SUPER_USER ; done
        while [ -z "$SUPER_USERPWD" ]; do read -s -r -p "Please input the administrator password: " SUPER_USERPWD ; echo "" ; done
    else  # silent fresh install
        if [ -z "$END_STATE" ]; then write_log "fatal" "Need provide end state of silent install. Type $0 -h for help."; fi
        if [ -z "$EXTERNAL_REPOSITORY" ]; then
            local try_deploy_suite=$($JQ -r 'has("capabilities")' $CONFIG_FILE)
            if [ "$CAPS_DEPLOYMENT_MANAGEMENT" == "true" ] && [ "$try_deploy_suite" == "true" ] && [ -z "$IMAGE_FOLDER" ]; then
                write_log "fatal" "Missing the absolute path of image tar folder for uploading the images. Type $0 -h for help."
            fi
        fi
        write_log "info" "** Start full $PRODUCT_INFRA_NAME installation ..."
        while [ -z "$SUPER_USER" ]; do read -p "Please input the administrator username: " SUPER_USER ; done
        while [ -z "$SUPER_USERPWD" ]; do read -s -r -p "Please input the administrator password: " SUPER_USERPWD ; echo "" ; done
        STEPS_FILE=${STEPS_FILE:-"$CDF_INSTALL_RUNTIME_HOME/.cdfInstallCompletedSteps.tmp"}
    fi
    if [[ "$CAPS_DEPLOYMENT_MANAGEMENT" == "true" ]];then
        local is_pv_admin=$(cat ${CDF_HOME}/objectdefs/cdf-chart.values.yaml 2>/dev/null|grep -Po '^\s*persistentVolumes:\s*\w+'|awk '{print $2}')
        if [[ -z "$is_pv_admin" ]];then
            write_log "fatal" "Failed to get .global.cluster.managedResources.persistentVolumes."
        fi
        if [[ "$is_pv_admin" == 'true' ]]; then
            STORAGE_MODE="PV_CDF"
        else
            STORAGE_MODE="PV_ADMIN"
        fi
    fi

    # suite mode or suite update
    if [[ "$CAPS_SUITE_DEPLOYMENT_MANAGEMENT" == "true" ]] || [[ "$LIFE_CYCLE" != "install" ]];then
        local cdfApiServerIP=$(exec_cmd "$kubectl get svc suite-installer-svc -n ${SYSTEM_NAMESPACE} -o custom-columns=clusterIP:.spec.clusterIP --no-headers 2>/dev/null" -p=true)
        if [ -z "${cdfApiServerIP}" ];then
            write_log "fatal" "Failed to get IP address of cdf-apiserver pod"
        fi
    fi

    TIMEOUT_MINUTES=${CLI_TIMEOUT_MINUTES:-"60"}
    TIMEOUT_SECONDS=$(expr 60 \* $TIMEOUT_MINUTES)
}

startPrivateReg(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Checking registry ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/kubeRegistry"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                      -w \"%{http_code}\" \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      \"${BASE_URL}${api_url}\"" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        if [ "$(echo "${apiResult:0:-3}" | $JQ -r '.status')" = "true" ]; then
            write_log "info" "Deploy done"
        else
            write_log "fatal" "${apiResult:0:-3}"
        fi
    fi
}

getFullJson(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Generating full configuration file ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/file/cleanToDirty"
    local clean_json=""
    if [[ "$INSTALLED_TYPE" == "CLASSIC" ]];then
        local update_config="$(cat $CONFIG_FILE)"
        local global_skip_warning="$(exec_cmd "cat $CONFIG_FILE|jq -r '.nodeSkipWarning // empty'" -p=true)"
        local is_skip_warning=
        local nodename=
        local num="$(cat $CONFIG_FILE|jq -r '.masterNodes|length')"
        for (( i=0; i<num; i++ )) ;do
            is_skip_warning="$(exec_cmd "cat $CONFIG_FILE|jq -r '.masterNodes[$i].skipWarning // empty'" -p=true)"
            nodename="$(exec_cmd "cat $CONFIG_FILE|jq -r '.masterNodes[$i].hostname // empty'" -p=true)"
            if [[ -z "$is_skip_warning" ]];then
                is_skip_warning="$global_skip_warning"
            fi
            if [[ -z "$is_skip_warning" ]];then
                is_skip_warning="$CLI_SKIP_PRECHECK_WARNING"
            fi
            if [ -f "$CDF_INSTALL_RUNTIME_HOME/user_confirm_skip_precheck_warning_$nodename" ];then
                write_log "debug" "node: $nodename, user confirm skip precheck warnings"
                is_skip_warning=true
            fi
            if [[ -z "$is_skip_warning" ]];then
                is_skip_warning=false
            fi
            update_config=$(echo "$update_config"|$JQ -r ".masterNodes[$i].skipWarning=$is_skip_warning")
        done

        num="$(cat $CONFIG_FILE|jq -r '.workerNodes|length')"
        for (( i=0; i<num; i++ )) ;do
            is_skip_warning="$(exec_cmd "cat $CONFIG_FILE|jq -r '.workerNodes[$i].skipWarning // empty'" -p=true)"
            nodename="$(exec_cmd "cat $CONFIG_FILE|jq -r '.workerNodes[$i].hostname // empty'" -p=true)"
            if [[ -z "$is_skip_warning" ]];then
                is_skip_warning="$global_skip_warning"
            fi
            if [[ -z "$is_skip_warning" ]];then
                is_skip_warning="$CLI_SKIP_PRECHECK_WARNING"
            fi
            if [ -f "$CDF_INSTALL_RUNTIME_HOME/user_confirm_skip_precheck_warning_$nodename" ];then
                write_log "debug" "node: $nodename, user confirm skip precheck warnings"
                is_skip_warning=true
            fi
            if [[ -z "$is_skip_warning" ]];then
                is_skip_warning=false
            fi
            update_config=$(echo "$update_config"|$JQ -r ".workerNodes[$i].skipWarning=$is_skip_warning")
        done

        clean_json="$(echo "$update_config"|sed -e 's/'\''/'\''\\'\'''\''/g')"
    else
        clean_json="$(cat $CONFIG_FILE|sed -e 's/'\''/'\''\\'\'''\''/g')"
    fi
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '${clean_json}' \\
                    '${BASE_URL}${api_url}'" -p=true -o=false -m=false)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "201" ]; then
        write_log "fatal" "API response: ${apiResult:0:-3}"
    else
        FULL_JSON="${apiResult:0:-3}"
        write_log "info" "Generation done"
    fi
}

uploadJsonFile(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Uploading full configuration file into vault ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/params"
    local transparams_json="$FULL_JSON"
    record "curl -k -s -X POST --header *** -d *** ${BASE_URL}${api_url}"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '$(echo "$transparams_json"|sed -e "s/'/'\\\\''/g")' \\
                    '${BASE_URL}${api_url}'" -p=true -o=false -m=false)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        if [ "$(echo "${apiResult:0:-3}" | $JQ -r '.status')" = "true" ]; then
            write_log "info" "Upload done"
        else
            write_log "fatal" "${apiResult:0:-3}"
        fi
    fi
}

getFullJsonParams(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Requesting full configuration file ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/params"
    local apiResult=$(wrap_curl "curl -k -s -X GET \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    '${BASE_URL}${api_url}'" -p=true -o=false)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        FULL_JSON="${apiResult:0:-3}"
        write_log "info" "Request done"
    fi
}

storeSuiteFeature(){
    write_log "loading" "Store suite feature ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/feature"
    local body;body="$(echo "$FULL_JSON"|$JQ -r '.capability')"
    post "$api_url" "$body" "201" "10"
    write_log "info" "Store suite feature done"
}

nodePrecheck(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Pre-checking all nodes >>>> "
    local PRECHECK_RESULT=0
    local api_url="/urest/v1.1/deployment/allnodestatus"
    local response=$(wrap_curl "curl -k -s -X GET \\
                      -w \"%{http_code}\" \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      \"${BASE_URL}${api_url}\"" -p=true)
    local http_code=${response:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${response:0:-3}"
    else
        local node_num=$(echo "${response:0:-3}" | $JQ '. | length')
        local n=0
        while [ $n -lt $node_num ]
        do
            local first_node=$(exec_cmd "$kubectl get cm cdf-cluster-host -n $SYSTEM_NAMESPACE -o json 2>/dev/null | $JQ -r '.data.FIRST_MASTER_NODE'" -p=true)
            if [ -z "${first_node}" ];then
                write_log "fatal" "Failed to get name of first control plane node"
            fi
            local result=($(echo "${response:0:-3}" | $JQ -r ".[$n].hostname, .[$n].checkNodeResult.checkType, .[$n].checkNodeResult.checkResult"))
            if [ "${result[0]}" != "$first_node" ]; then
                if [ ${result[2]} = "true" ]; then
                    write_log "info" ">> Host : ${result[0]} (${result[1]})"
                    write_log "info" "PreCheck: Passed"
                else
                    PRECHECK_RESULT=$(( $PRECHECK_RESULT + 1 ))
                    write_log "info" ">> Host : ${result[0]} (${result[1]})"
                    write_log "error" "Precheck: Failed"
                    local info=$(echo "${response:0:-3}" | $JQ -r ".[$n].checkNodeResult.info")
                    local failed_items="$(echo -e "$info" | grep "Failed")"
                    if [ -z "${failed_items}" ]; then
                        write_log "info" "$info"
                    else
                        write_log "error" "$failed_items"
                    fi
                fi
            fi
            n=$((n+1))
        done

        if [ ${PRECHECK_RESULT} -gt 0 ]; then
            exit 1
        else
            sleep 10
        fi
    fi
}

launchExtend(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Start adding nodes ..."
    local api_url="/urest/v1.1/nodes"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                      -w \"%{http_code}\" \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      \"${BASE_URL}${api_url}\"" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        if [ "$(echo "${apiResult:0:-3}" | $JQ -r '.status')" != "true" ]; then
            write_log "fatal" "${apiResult:0:-3}"
        fi
    fi
}

getNodeTypeInfo(){
    local type=$1
    getXtoken
    getCsrfTokenSessionID
    write_log "infolog" "Get node type info ..."
    local api_url="/urest/v1.1/deployment/nodeTypeInfor"
	local apiResult=$(wrap_curl "curl -k -s -X GET \\
                      -w \"%{http_code}\" \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      \"${BASE_URL}${api_url}\"" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "infolog" "Get node type info error: ${apiResult}"
    else
        NODE_TYPE_INFO=$(echo "${apiResult:0:-3}" | $JQ -r ".[]|select(.label==\"$type\")")
        write_log "infolog" "Get node type info ok"
    fi
    if [[ -z "$NODE_TYPE_INFO" ]];then
        NODE_TYPE_INFO='{}'
    fi
}

copyFileToPod(){
    local uploadFile="$1"
    local target="$2"
    local container_name="cdf-apiserver"
    local pod_name;pod_name=$(exec_cmd "$kubectl get pods -n ${SYSTEM_NAMESPACE} 2>/dev/null|grep '$container_name'|grep 'Running'|awk '{len=split(\$2,arr,\"/\");if(len==2&&arr[1]>0&&arr[1]==arr[2])print \$1}'" -p true)
    if [ -z "$pod_name" ];then
        write_log "fatal" "Failed to get ${SYSTEM_NAMESPACE}/$container_name. For detail logs, please refer to $LOGFILE"
    fi
    local waitSeconds=0
    local timeoutSeconds=10
    while true;do
        if exec_cmd "$kubectl cp --no-preserve=true $uploadFile ${SYSTEM_NAMESPACE}/$pod_name:$target -c cdf-apiserver";then
            break
        fi
        if [ $waitSeconds -lt $timeoutSeconds ]; then
            waitSeconds=$(( waitSeconds + 1 ))
            sleep 2
        else
            write_log "fatal" "Failed to copy $uploadFile to ${SYSTEM_NAMESPACE}/$container_name. For detail logs, please refer to $LOGFILE"
        fi
    done
}

uploadPrivatekKey(){
    local key=$1
    local username=$2
    local hostname=$3
    local passphrase="$4"
    local keyInPod="/tmp/$(basename $key)_$(date "+%Y%m%d%H%M%S")"
    getXtoken
    getCsrfTokenSessionID
    copyFileToPod "$key" "$keyInPod"
    write_log "infolog" "Uploading private key for  ${username}@${hostname} ..."
    local api_url="/urest/v1.1/deployment/uploadPrivatekKey"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                      -w \"%{http_code}\" \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      -F 'hostName=$hostname' \\
                      -F 'userName=$username' \\
                      -F '$(echo "passPhrase=\"$(echo "$passphrase"|sed -e 's/"/\\"/g')\""|sed -e "s/'/'\\\\''/g")' \\
                      -F 'file=@$keyInPod' \\
                      \"${BASE_URL}${api_url}\"" -p=true -o=false)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "201" ]; then
        write_log "fatal" "${apiResult}"
    else
        if [ "$(echo "${apiResult:0:-3}" | $JQ -r '.status')" != "true" ]; then
           write_log "fatal" "Uploading private key error: ${apiResult:0:-3}"
        fi
        PRIVATE_KEY_CONTENT=$(echo "${apiResult:0:-3}" | $JQ -r '.message')
        write_log "infolog" "Upload private key ok"
    fi
}

precheckNodeByApi(){
    local node_name=$1
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Pre-checking node: ${node_name} ..."
    local api_url="/urest/v1.1/deployment/nodestatus"
    local dto_key=
    local null_key=
    local node_key=
    local masterNodeHa=
    local nodeType=
    if [[ "$(cat $CONFIG_FILE|$JQ -r '.workerNodes[]|select(.hostname=="'$node_name'").hostname')" == "$node_name" ]];then
        nodeType="worker"
        masterNodeHa=false
        null_key="masterNodeDTO"
        dto_key="workNodeDTO"
        node_key="host"
        node_obj=$(cat $CONFIG_FILE|$JQ -r '.workerNodes[]|select(.hostname=="'$node_name'")')
    else
        nodeType="master"
        masterNodeHa=true
        null_key="workNodeDTO"
        dto_key="masterNodeDTO"
        node_key="hostname"
        node_obj=$(cat $CONFIG_FILE|$JQ -r '.masterNodes[]|select(.hostname=="'$node_name'")')
    fi
    local password=
    if [[ "$(echo "$node_obj"|$JQ -r '[.password]|map(type)|.[0]')" != "null" ]];then
        password=$(echo "$node_obj"|$JQ -r '.password // empty')
    fi
    if [[ -z "$password" ]];then
        password=$(cat $CONFIG_FILE|$JQ -r '.nodePassword // empty')
    fi
    local user=
    if [[ "$(echo "$node_obj"|$JQ -r '[.user]|map(type)|.[0]')" != "null" ]];then
        user=$(echo "$node_obj"|$JQ -r '.user // empty')
    fi
    if [[ -z "$user" ]];then
        user=$(cat $CONFIG_FILE|$JQ -r '.nodeUser // empty')
    fi
    local type=
    if [[ "$(echo "$node_obj"|$JQ -r '[.type]|map(type)|.[0]')" != "null" ]];then
        type=$(echo "$node_obj"|$JQ -r '.type')
    fi
    type="${type:-"standard"}"
    local privateKey=
    if [[ "$(echo "$node_obj"|$JQ -r '[.privateKey]|map(type)|.[0]')" != "null" ]];then
        privateKey=$(echo "$node_obj"|$JQ -r '.privateKey // empty')
    fi
    if [[ -z "$privateKey" ]];then
        privateKey=$(cat $CONFIG_FILE|$JQ -r '.nodePrivateKey // empty')
    fi
    local privateKeyPassword=
    if [[ "$(echo "$node_obj"|$JQ -r '[.privateKeyPassword]|map(type)|.[0]')" != "null" ]];then
        privateKeyPassword=$(echo "$node_obj"|$JQ -r '.privateKeyPassword // empty')
    fi
    if [[ -z "$privateKeyPassword" ]];then
        privateKeyPassword=$(cat $CONFIG_FILE|$JQ -r '.nodePrivateKeyPassword // empty')
    fi
    local deviceType=
    if [[ "$(echo "$node_obj"|$JQ -r '[.deviceType]|map(type)|.[0]')" != "null" ]];then
        deviceType=$(echo "$node_obj"|$JQ -r '.deviceType')
    fi
    deviceType="${deviceType:-"overlay2"}"
    local flannelIface=
    if [[ "$(echo "$node_obj"|$JQ -r '[.flannelIface]|map(type)|.[0]')" != "null" ]];then
        flannelIface=$(echo "$node_obj"|$JQ -r '.flannelIface')
    fi
    local skipWarning=
    if [[ "$(echo "$node_obj"|$JQ -r '[.skipWarning]|map(type)|.[0]')" != "null" ]];then
        skipWarning=$(echo "$node_obj"|$JQ -r '.skipWarning // empty')
    fi
    if [[ -z "$skipWarning" ]];then
        skipWarning=$(cat $CONFIG_FILE|$JQ -r '.nodeSkipWarning // empty')
    fi
    if [[ -z "$skipWarning" ]];then
        skipWarning=$CLI_SKIP_PRECHECK_WARNING
    fi
    if [ -f "$CDF_INSTALL_RUNTIME_HOME/user_confirm_skip_precheck_warning_$node_name" ];then
        write_log "debug" "node: $node_name, user confirm skip precheck warnings"
        skipWarning=true
    fi
    skipWarning="${skipWarning:-"false"}"
    local skipResourceCheck=true
    if [[ "$(echo "$node_obj"|$JQ -r '[.skipResourceCheck]|map(type)|.[0]')" != "null" ]];then
        skipResourceCheck=$(echo "$node_obj"|$JQ -r '.skipResourceCheck // empty')
    fi
    if [[ -z "$skipResourceCheck" ]];then
        skipResourceCheck=$(cat $CONFIG_FILE|$JQ -r '.nodeSkipResourceCheck // empty')
    fi
    skipResourceCheck="${skipResourceCheck:-"true"}"

    PRIVATE_KEY_CONTENT=
    NODE_TYPE_INFO=
    getNodeTypeInfo "$type"
    local verifyWay="pwd"
    if [[ -n "$privateKey" ]];then
        verifyWay="cer"
        uploadPrivatekKey "$privateKey" "$user" "$node_name" "$privateKeyPassword"
    fi
    local body="{
            \"masterNodeHa\":${masterNodeHa},
            \"${null_key}\": null,
            \"${dto_key}\":{
                \"skipResourceCheck\":${skipResourceCheck},
                \"skipWarning\":${skipWarning},
                \"validate\":true,
                \"type\": ${NODE_TYPE_INFO},
                \"nodeType\": \"${nodeType}\",
                \"${node_key}\":\"${node_name}\",
                \"verifyWay\":\"${verifyWay}\",
                \"privateKey\":\"${PRIVATE_KEY_CONTENT}\",
                \"nodeHostUser\":\"${user}\",
                \"password\":\"$(echo "${password}"|sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\",
                \"deviceType\":\"${deviceType}\",
                \"flannelIface\": \"${flannelIface}\",
                \"runtimeData\":\"${CDF_HOME}/data\"
            }
    }"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                      -w \"%{http_code}\" \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      -d  '$(echo "$body"|sed -e "s/'/'\\\\''/g")' \\
                      \"${BASE_URL}${api_url}\"" -p=true -o=false)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "201" ]; then
        write_log "fatal" "Pre-check node ${node_name} failed: ${apiResult} \n$(tipsForFixConfig)"
    else
        if [ "$(echo "${apiResult:0:-3}" | $JQ -r '.checkNodeResult.checkResult')" != "true" ]; then
            write_log "fatal" "Pre-check node ${node_name} failed: ${apiResult} \n$(tipsForFixConfig)"
        fi
    fi
}

retryNode(){
    local node_name=$1
    local retry_count=$2
    if [[ $retry_count -le 0 ]];then
        write_log "fatal" "Timeout occurs when retry add node (${node_name})"
    fi
    precheckNode "$node_name"
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Retry adding node: ${node_name}..."
    write_log "infolog" "Retry adding node (${node_name}) $retry_count ..."
    local api_url="/urest/v1.1/nodes/retry?kubeNodeName=${node_name}"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                      -w \"%{http_code}\" \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      \"${BASE_URL}${api_url}\"" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        if [ "$(echo "${apiResult:0:-3}" | $JQ -r '.status')" != "true" ]; then
            sleep 5
            retry_count=$((retry_count-1))
            retryNode "${node_name}" "${retry_count}"
        fi
    fi

    set_step_done "$FLAG_EXIST_RETRY_ADDNODE"
}

callNodeStatusApi(){
    getXtoken
    getCsrfTokenSessionID
    local api_url="/urest/v1.1/deployment/node/status"
    local apiResponseBody=$(wrap_curl "curl -k -s -X GET \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      \"${BASE_URL}${api_url}\"" -p=true)
    echo "$apiResponseBody"
}

getNodeHost(){
    local n=$1
    local type=$2
    local response=$(callNodeStatusApi)
    local host=$(echo "$response" | $JQ -r ".${type}NodeStatus[$n].hostname")
    echo "$host"
}

getNodeNum(){
    local type=$1
    local response=$(callNodeStatusApi)
    local num=$(echo "$response" | $JQ ".${type}NodeStatus | length")
    echo "$num"
}

getNodeStatus(){
    local n=$1
    local type=$2
    local response=$(callNodeStatusApi)
    local status=$(echo "$response" | $JQ -r ".${type}NodeStatus[$n].status")
    echo "$status"
}

getMasterNodeHost(){
    local n=$1
    local response=$(callNodeStatusApi)
    local host=$(echo "$response" | $JQ -r ".masterNodeStatus[]|select(.order==\"$n\").hostname")
    echo "$host"
}

getMasterNodeStatus(){
    local n=$1
    local response=$(callNodeStatusApi)
    local status=$(echo "$response" | $JQ -r ".masterNodeStatus[]|select(.order==\"$n\").status")
    echo "$status"
}

requestExtendNode(){
    local host=$1
    if [[ -n "$host" ]];then
        local flag="@requestAddnode:$host"
        if is_step_not_done "$flag";then
            set_step_done "requestAddnode:$host ..."
            write_log "loading" "Start adding node: $host "
            retryNode "${host}" 5
            set_step_done "$flag"
        else
            write_log "info" "Request adding node: $host (DONE)"
        fi
    fi
}

checkMasterStatus(){
    write_log "loading" "Control plane nodes >>>>"
    for n in secondary tertiary
    do
        local host=$(getMasterNodeHost $n)
        if is_exist_flag "$FLAG_EXIST_RETRY_ADDNODE";then
            [[ "$n" == "tertiary" ]] && requestExtendNode "$host"
        fi
        write_log "loading" ">> Host : $host "
        local retry_count=0
        local status="wait"
        while [ "$status" = "wait" ]
        do
            status=$(getMasterNodeStatus $n)
            if [ "$status" = "wait" ]; then
                sleep 60
            elif [ "$status" = "error" ]; then
                if [[ "${retry_count}" -lt 5 ]];then
                    retry_count=$((retry_count+1))
                    write_log "loading" "Retry: ${retry_count} ..."
                    status="wait"
                    retryNode "${host}" 5
                    sleep 60
                else
                    FAILED_MASTER=$((FAILED_MASTER+1))
                    write_log "error" " Status : Error "
                    break
                fi
            elif [ "$status" = "finished" ]; then
                write_log "info" " Status : Finished "
                break
            fi
        done
    done
}

checkWorkerStatus(){
    local worker_num=$1
    local n=0
    write_log "loading" "Worker nodes >>>>"
    while [ "$n" -lt "$worker_num" ]
    do
       local host=$(getNodeHost "$n" "work")
       write_log "loading" ">> Host : $host "
       local retry_count=0
       local status="wait"
       while [ "$status" = "wait" ]
       do
           status=$(getNodeStatus "$n" "work")
           if [ "$status" = "wait" ]; then
               sleep 60
           elif [ "$status" = "error" ]; then
                if [[ "${retry_count}" -lt 5 ]];then
                        retry_count=$((retry_count+1))
                        write_log "loading" "Retry: ${retry_count} ..."
                        status="wait"
                        retryNode "${host}" 5
                        sleep 60
                else
                    FAILED_WORKER=$((FAILED_WORKER+1))
                    write_log "error" " Status : Error "
                    break
                fi
           elif [ "$status" = "finished" ]; then
               write_log "info" " Status : Finished "
               break
           fi
       done
       n=$((n+1))
    done
}

requestExtendWorkers(){
    local worker_num=$1
    local n=0
    write_log "loading" "Request adding worker nodes >>>>"
    while [ "$n" -lt "$worker_num" ]
    do
        local host=$(getNodeHost "$n" "work")
        requestExtendNode "$host"
        n=$((n+1))
    done
}

nodeExtendStatus(){
    local num_master=$(getNodeNum master)
    local num_worker=$(getNodeNum work)
    if [ "$num_master" -eq 1 ]; then
        checkWorkerStatus "$num_worker"
    else
        checkMasterStatus
        if [ "$FAILED_MASTER" -gt 0 ]; then
            exit 1
        else
            if is_exist_flag "$FLAG_EXIST_RETRY_ADDNODE";then
                requestExtendWorkers "$num_worker"
            fi
            checkWorkerStatus "$num_worker"
        fi
    fi
    if [ "$FAILED_MASTER" -gt 0 -o "$FAILED_WORKER" -gt 0 ]; then
        exit 1
    fi
}

geneDownloadZip(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Generating offline-download.zip ..."
    local api_url="/urest/v1.1/deployment/installbundle"
    local body="{\"deployment\":\"$DEPLOYMENT_UUID\"}"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                      -w \"%{http_code}\" \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      -d '$body' \\
                      \"${BASE_URL}${api_url}\"" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "201" -a "$http_code" != "202" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        local bundleTimeout=600
        local waitSeconds=0
        if [ "$(echo "${apiResult:0:-3}" | $JQ -r '.status')" = "true" ]; then
            while true; do
                if [ ! -f "${CDF_HOME}/tools/install_download_zip/offline-download.zip" ]; then
                    if [ "$waitSeconds" -ge $bundleTimeout ]; then
                        write_log "fatal" "Timeout occurs when generate offline-download.zip"
                    else
                        waitSeconds=$((waitSeconds + 5))
                        sleep 5
                    fi
                else
                    break
                fi
            done
            write_log "info" "Generate done"
        else
            write_log "fatal" "${apiResult:0:-3}"
        fi
    fi
}

createAllVolumes(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Creating all required volumes ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/volumes/createAll?storageMode=$STORAGE_MODE"
    local reqVolumes="$(echo "$FULL_JSON"|$JQ -r '.reqVolumes'|$JQ -r '.[].validateResult.status="WARN"')"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '${reqVolumes}' \\
                    '${BASE_URL}${api_url}'" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "Response code:$http_code, body:${apiResult:0:-3}"
    else
        local size="$(echo "${apiResult:0:-3}"|$JQ -r '.|length')"
        if [[ "$size" -eq 0 ]];then
            write_log "info" "Creation done"
            return
        fi
        local result
        if [[ "$STORAGE_MODE" == "PV_CDF" ]];then
            result="$(echo "${apiResult:0:-3}"|$JQ -r '.[].validateResult.status'|sort|uniq)"
        else
            # PV_ADMIN
            result="$(echo "${apiResult:0:-3}"|$JQ -r '.[]|select(.createPVC==true).validateResult.status'|sort|uniq)"
        fi
        if [ "$result" = "RIGHT" ]; then
            write_log "info" "Creation done"
        else
            # show error message
            local msg_key
            local msg_val
            local print_obj;print_obj=$(echo "${apiResult:0:-3}"|$JQ -r '[.[]|select(.validateResult.status=="ERROR")]')
            local count;count=$(echo "$print_obj"|$JQ -r '.|length')
            for (( i=0; i<$count; i++ ));do
                msg_key=$(echo "$print_obj"|$JQ -r ".[$i].validateResult.errors.message"|tr '[:upper:]' '[:lower:]')
                if [[ -n "$msg_key" ]] && [[ "$msg_key" != "null" ]];then
                    msg_val=$(echo "$MSG_VOLUME_VALIDATE"|$JQ -r ".\"$msg_key\"")
                    print_obj=$(echo "$print_obj"|$JQ -r ".[$i].validateResult.errors.message=\"$msg_val\"")
                fi
            done
            write_log "fatal" "Creation error: $print_obj"
        fi
    fi
}

addWorkerLabel(){
  local allowWorkerOnMaster=$($JQ -r ".allowWorkerOnMaster" $CONFIG_FILE)
  if [ "$allowWorkerOnMaster" = "true" ]; then
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Adding worker label on control plane nodes ..."
    local api_url="/urest/v1.1/nodes/label"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                      -w \"%{http_code}\" \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      \"${BASE_URL}${api_url}\"" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        if [ "$(echo "${apiResult:0:-3}" | $JQ -r '.status')" = "true" ]; then
            write_log "info" "Add done"
        else
            write_log "fatal" "${apiResult:0:-3}"
        fi
    fi
  fi
}

copyCertsForExternalhost(){
    write_log "loading" "Copying certificate(s) for external host ..."
    local certDir="/apiserver/nfsCore/offline_sync_tools"
    #copy external host certs
    local connectionObject=$(exec_cmd "$JQ -r '.connection' $CONFIG_FILE" -p=true)
    local hasServerCrtType=$(echo "$connectionObject" | $JQ 'has("serverCrtType")')
    if [ "$hasServerCrtType" = "true" ]; then
        local serverCrtType=$(echo "$connectionObject" | $JQ -r '.serverCrtType')
        if [ "$serverCrtType" = "PKCS#1_PKCS#8" ]; then
            copyPEMCerts "$connectionObject" "$certDir"
        elif [ "$serverCrtType" = "PKCS#12" ]; then
            local rootCrt=$(echo "$connectionObject" | $JQ -r '.rootCrt')
            local rootCrtFile=$(basename $rootCrt)
            if [ -f "$CDF_INSTALL_RUNTIME_HOME/pfx_server.key" -a -f "$CDF_INSTALL_RUNTIME_HOME/pfx_server.crt" ]; then
                exec_cmd "$kubectl cp --no-preserve=true $CDF_INSTALL_RUNTIME_HOME/pfx_server.key $cdfApiServerPodName:$certDir -n ${SYSTEM_NAMESPACE}; $kubectl cp --no-preserve=true $CDF_INSTALL_RUNTIME_HOME/pfx_server.crt $cdfApiServerPodName:$certDir -n ${SYSTEM_NAMESPACE}; $kubectl cp --no-preserve=true $rootCrt $cdfApiServerPodName:$certDir -n ${SYSTEM_NAMESPACE}"
                if ! exec_cmd "$kubectl exec $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- ls $certDir/pfx_server.crt" || ! exec_cmd "$kubectl exec $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- ls $certDir/pfx_server.key" || ! exec_cmd "$kubectl exec $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- ls $certDir/$rootCrtFile"; then
                    write_log "fatal" "[.connection] Failed to copy certificates to $cdfApiServerPodName:$certDir"
                fi
                exec_cmd " rm -f  $CDF_INSTALL_RUNTIME_HOME/pfx_server.key $CDF_INSTALL_RUNTIME_HOME/pfx_server.crt"
            else
                write_log "fatal" "Not found the server certificates 'pfx_server.crt' and 'pfx_server.key' which exported from PKCS#12 certificate under $TMP_FOLDER"
            fi
        fi
    else
        local hasServerKey=$(echo "$connectionObject" | $JQ 'has("serverKey")')
        local hasServerCrt=$(echo "$connectionObject" | $JQ 'has("serverCrt")')
        local hasRootCrt=$(echo "$connectionObject" | $JQ 'has("rootCrt")')
        if [ "$hasServerKey" = "true" -a "$hasServerCrt" = "true" -a "$hasRootCrt" = "true" ]; then
            copyPEMCerts "$connectionObject" "$certDir"
        fi
    fi
}

copyCerts(){
    write_log "loading" "Copying certificate(s) ..."
    local certDir="/apiserver/nfsCore/offline_sync_tools"
    local cdfApiServerPodName=$(exec_cmd "$kubectl get pods -n ${SYSTEM_NAMESPACE} 2>/dev/null| grep 'cdf-apiserver'|awk '{print \$1}' " -p=true)
    #copy external host certs
    local connectionObject=$(exec_cmd "$JQ -r '.connection' $CONFIG_FILE" -p=true)
    local hasServerCrtType=$(echo "$connectionObject" | $JQ 'has("serverCrtType")')
    if [ "$hasServerCrtType" = "true" ]; then
        local serverCrtType=$(echo "$connectionObject" | $JQ -r '.serverCrtType')
        if [ "$serverCrtType" = "PKCS#1_PKCS#8" ]; then
            copyPEMCerts "$connectionObject" "$certDir"
        elif [ "$serverCrtType" = "PKCS#12" ]; then
            local rootCrt=$(echo "$connectionObject" | $JQ -r '.rootCrt')
            local rootCrtFile=$(basename $rootCrt)
            if [ -f "$CDF_INSTALL_RUNTIME_HOME/pfx_server.key" -a -f "$CDF_INSTALL_RUNTIME_HOME/pfx_server.crt" ]; then
                exec_cmd "$kubectl cp --no-preserve=true $CDF_INSTALL_RUNTIME_HOME/pfx_server.key $cdfApiServerPodName:$certDir -n ${SYSTEM_NAMESPACE}; $kubectl cp --no-preserve=true $CDF_INSTALL_RUNTIME_HOME/pfx_server.crt $cdfApiServerPodName:$certDir -n ${SYSTEM_NAMESPACE}; $kubectl cp --no-preserve=true $rootCrt $cdfApiServerPodName:$certDir -n ${SYSTEM_NAMESPACE}"
                if ! exec_cmd "$kubectl exec $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- ls $certDir/pfx_server.crt" || ! exec_cmd "$kubectl exec $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- ls $certDir/pfx_server.key" || ! exec_cmd "$kubectl exec $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- ls $certDir/$rootCrtFile"; then
                    write_log "fatal" "[.connection] Failed to copy certificates to $cdfApiServerPodName:$certDir"
                fi
                exec_cmd " rm -f  $CDF_INSTALL_RUNTIME_HOME/pfx_server.key $CDF_INSTALL_RUNTIME_HOME/pfx_server.crt"
            else
                write_log "fatal" "Not found the server certificates 'pfx_server.crt' and 'pfx_server.key' which exported from PKCS#12 certificate under $CDF_INSTALL_RUNTIME_HOME"
            fi
        fi
    else
        local hasServerKey=$(echo "$connectionObject" | $JQ 'has("serverKey")')
        local hasServerCrt=$(echo "$connectionObject" | $JQ 'has("serverCrt")')
        local hasRootCrt=$(echo "$connectionObject" | $JQ 'has("rootCrt")')
        if [ "$hasServerKey" = "true" -a "$hasServerCrt" = "true" -a "$hasRootCrt" = "true" ]; then
            copyPEMCerts "$connectionObject" "$certDir"
        fi
    fi
    #copy db certs
    local dbType=$(exec_cmd "$JQ -r .database.type $CONFIG_FILE" -p=true)
    if [ "$dbType" = "extoracle" -o "$dbType" = "extpostgres" ]; then
        local dbCertDir="/apiserver/nfsCore/suite-install/deployments/$DEPLOYMENT_UUID/database/ssl/certificates"
        local dbCert=$(exec_cmd "$JQ -r .database.param.dbCert $CONFIG_FILE" -p=true)
        if [ -n "$dbCert" -a "$dbCert" != "null" ]; then
            for cert in ${dbCert//,/ }
            do
                if [ -f "$cert" ]; then
                    local certName=$(basename $cert)
                    write_log "info" "#copy db certs certName is $certName"
                    if [ $(exec_cmd "$kubectl exec -it $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- sh -c 'mkdir -p $dbCertDir/;/bin/chown -R $SYSTEM_USER_ID:$SYSTEM_GROUP_ID $dbCertDir/';$kubectl cp --no-preserve=true $cert $cdfApiServerPodName:$dbCertDir/${dbType}-$certName -n ${SYSTEM_NAMESPACE};$kubectl exec $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- ls $dbCertDir/${dbType}-${certName}"; echo $? ) -ne 0 ]; then
                        write_log "fatal" "[.database] Failed to copy file $cert to $cdfApiServerPodName:$dbCertDir/"
                    fi
                    if [ $(exec_cmd "$kubectl exec -it $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- chmod 755 $dbCertDir/${dbType}-${certName}"; echo $? ) -ne 0 ]; then
                        write_log "fatal" "[.database] Failed to chmod 755 $dbCertDir/${dbType}-${certName}"
                    fi
                else
                    write_log "warn" "[.database] File not found: '$cert', skip copy"
                fi
            done
        fi
    fi
    exec_cmd "/bin/chown -R $SYSTEM_USER_ID:$SYSTEM_GROUP_ID $certDir/*"
    write_log "info" "Copy done"
}

copyPEMCerts(){
    local cdfApiServerPodName=$(exec_cmd "$kubectl get pods -n ${SYSTEM_NAMESPACE} 2>/dev/null | grep 'cdf-apiserver'|awk '{print \$1}' " -p=true)
    local connectionObject=$1
    local certDir=$2
    local serverKey=$(echo "$connectionObject" | $JQ -r '.serverKey')
    local serverCrt=$(echo "$connectionObject" | $JQ -r '.serverCrt')
    local rootCrt=$(echo "$connectionObject" | $JQ -r '.rootCrt')
    for cert in $serverKey $serverCrt $rootCrt
    do
        local fileName=$(basename $cert)
        write_log "info" "copyPEMCerts crt: $cert"
        if ! exec_cmd "$kubectl cp --no-preserve=true $cert $cdfApiServerPodName:$certDir -n ${SYSTEM_NAMESPACE};$kubectl exec $cdfApiServerPodName -n ${SYSTEM_NAMESPACE} -- ls $certDir/${fileName}"; then
            write_log "fatal" "[.connection] Failed to copy file $cert to $cdfApiServerPodName:$certDir"
        fi
    done
}

uploadImages(){
    if [ -z "$REGISTRY_PASSWORD" ];then
        REGISTRY_PASSWORD=$SUPER_USERPWD
    fi
    write_log "loading" "Uploading images under $IMAGE_FOLDER to local registry... "
        local suite_name=$(cat $CONFIG_FILE | $JQ -r ".capabilities.suite")
        if [ -n "$suite_name" ]; then
            local image_folder_array=${IMAGE_FOLDER//,/ }
            image_folder_array=($image_folder_array)
            for folder in ${image_folder_array[@]};do
                #as testing of folder existence is done by uploadimages.sh, we not do it again here
                ${CDF_HOME}/scripts/uploadimages.sh -y -d $folder --auth "$(echo -n "$REGISTRY_USERNAME:$REGISTRY_PASSWORD"|base64 -w0)"
                if [ $? -ne 0 ]; then
                    write_log "fatal" "Upload images failed!"
                else
                    write_log "info" "Upload done"
                fi
            done
        else
            write_log "fatal" "Failed to get suite name from $CONFIG_FILE"
        fi
}

validateImages(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Validating result of container images ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/phaseimage"
    local apiResult=$(wrap_curl "curl -k -s -X GET \\
                    -w \"%{http_code}\" \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header \"${X_AUTH_TOKEN}\" \\
                    --noproxy \"${CDF_APISERVER_HOST}\" \\
                    \"${BASE_URL}${api_url}\"" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        local missImages=""
        local existNum=$(echo "${apiResult:0:-3}" | $JQ -r '.existNum')
        local allNum=$(echo "${apiResult:0:-3}" | $JQ -r '.allNum')
        if [ $existNum -eq $allNum ]; then
            write_log "info" "Number of images: $existNum/$allNum"
        else
            local missNum=$(($allNum - $existNum))
            local n=0
            while [ $n -lt $missNum ]; do
                local name=$(echo "${apiResult:0:-3}" | $JQ -r ".missImages[$n].image")
                missImages="${missImages}\n  ${name}"
                n=$((n+1))
            done
            write_log "fatal" "Number of images: $existNum/$allNum. Missing $missNum images. $missImages"
        fi
    fi
}

checkCdfPhase2Status(){
    if [ "$CAPS_DEPLOYMENT_MANAGEMENT" == "true" ];then
        write_log "loading" "Checking status of $PRODUCT_INFRA_NAME phase 2 components ..."
    else
        write_log "infolog" "Checking status of $PRODUCT_INFRA_NAME phase 2 components ..."
    fi
    local waitSeconds=0
    # echo -n 'Processing... this may take a while.'
    while true; do
        getSuiteFrontendUrl
        getXtoken
        getCsrfTokenSessionID
        local api_url="/urest/v1.2/deployment/${DEPLOYMENT_UUID}/components"
        local apiResult=$(wrap_curl "curl -s -X GET \\
                        -w \"%{http_code}\" \\
                        --header 'Content-Type: application/json' \\
                        --header 'Accept: application/json' \\
                        --header \"${X_AUTH_TOKEN}\" \\
                        --header \"${X_CSRF_TOKEN}\" \\
                        --cookie \"${JSESSION_ID}\" \\
                        --noproxy \"${SUITE_FRONTEND_HOST}\" \\
                        \"${SUITE_FRONTEND_URL}${api_url}\" -k" -p=true)
        local http_code=${apiResult:0-3}
        if [ "$http_code" != "200" ]; then
            write_log "fatal" "${apiResult:0:-3}"
        else
            local all_success="false"
            local code=$(echo "${apiResult:0:-3}"|$JQ -r '.code')
            if [[ "$code" == 0 ]];then
                local status=$(echo "${apiResult:0:-3}"|$JQ -r '.data'|$JQ -r 'to_entries'|$JQ -r '.[].value'|sort|uniq|xargs)
                if [[ "$status" == "SUCCESS" ]];then
                    all_success="true"
                fi
            fi
            if [[ "$all_success" == "true" ]]; then
                # echo -e
                if [ "$CAPS_DEPLOYMENT_MANAGEMENT" == "true" ];then
                    write_log "info" "All $PRODUCT_INFRA_NAME phase 2 components are running"
                else
                    write_log "infolog" "All $PRODUCT_INFRA_NAME phase 2 components are running"
                fi
                break
            elif [ "$waitSeconds" -lt "$TIMEOUT_SECONDS" ]; then
                waitSeconds=$((waitSeconds + 60 ))
                sleep 60
                # echo -n '.'
            else
                write_log "fatal" "Failed to start pod(s): ${apiResult:0:-3}"
            fi
        fi
    done
}

installSuite(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Launching suite deployment ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/deploy"
    local clean_json="$(cat $CONFIG_FILE | sed -e 's/'\''/'\''\\'\'''\''/g')"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '${clean_json}' \\
                    '${BASE_URL}${api_url}'" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "201" -a "$http_code" != "202" ]; then
         write_log "fatal" "${apiResult:0:-3}"
    else
         sleep 15
         write_log "info" "Deployment Launched"
    fi
}

setDeploymentStatus(){
    local retryCount=0
    local setToStatus=${1:-"CONF_POD_STARTED"}
    while true; do
        getXtoken
        getCsrfTokenSessionID
        write_log "infolog" "Set deployment status to $setToStatus ..."
        local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/status"
        local json="{\"status\":\"$setToStatus\"}"
        local apiResult=$(wrap_curl "curl -k -s -X PUT \\
                        -w '%{http_code}' \\
                        --header 'Content-Type: application/json' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --header '${X_CSRF_TOKEN}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        --cookie '${JSESSION_ID}' \\
                        -d '${json}' \\
                        '${BASE_URL}${api_url}'" -p=true)
        local http_code=${apiResult:0-3}
        if [ "$http_code" != "200" ]; then
            if [ "$retryCount" -lt 3 ];then
                sleep 1
                retryCount=$(( retryCount + 1 ))
                continue
            fi
            write_log "fatal" "Failed to set deployment status: ${apiResult:0:-3}"
        else
            write_log "infolog" "Sucessfully set deployment status"
            break
        fi
    done
}

retryDeploymentSuite(){
    local retryCount=$1
    setDeploymentStatus
    installSuite
    checkSuiteDeployStatus "$retryCount"
}

checkSuiteDeployStatus(){
    write_log "loading" "Checking status of suite deployment ..."
    local retryCount=${1:-"0"}
    local needRetry="false"
    local waitSeconds=0
    while true; do
        getXtoken
        getCsrfTokenSessionID
        local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}"
        local apiResult=$(wrap_curl "curl -k -s -X GET \\
                -w \"%{http_code}\" \\
                --header 'Content-Type: application/json' \\
                --header 'Accept: application/json' \\
                --header \"${X_AUTH_TOKEN}\" \\
                --noproxy \"${CDF_APISERVER_HOST}\" \\
                \"${BASE_URL}${api_url}\"" -p=true)
        local http_code=${apiResult:0-3}
        local deploy_status="unknown"
        if [ "$http_code" = "200" ]; then
            deploy_status=$(echo "${apiResult:0:-3}"|$JQ -r ".deploymentStatus")
        fi
        if [ "$deploy_status" = "INSTALL_FINISHED" ]; then
            write_log "info" "Suite deployment done"
            break
        elif [ "$deploy_status" = "INSTALL_FAILED" ]; then
            if [ "$retryCount" -gt 0 ];then
                needRetry="true"
                break
            else
                write_log "fatal" "Suite deployment failed. ${apiResult:0:-3}"
            fi
        elif [ "$waitSeconds" -lt "$TIMEOUT_SECONDS" ]; then
            waitSeconds=$(( waitSeconds + 60 ))
            sleep 60
        else
            write_log "fatal" "Suite deployment timeout. deployment status: $deploy_status [Expected status: INSTALL_FINISHED] ${apiResult:0:-3}"
        fi
    done

    if [ "$needRetry" == "true" ];then
        retryCount=$(( retryCount - 1 ))
        retryDeploymentSuite "$retryCount"
    fi
}

getDeploymentUuid(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "$MSG_UPDATE_UUID_GET"
    local deploymentType=
    local deployment_num=
    local deploymentStatus="INSTALL_FINISHED RECONFIGURE_FAILED UPDATE_FAILED INSTALL_FAILED"
    if [[ "$LIFE_CYCLE" = "update" ]];then
        deploymentStatus="INSTALL_FINISHED RECONFIGURE_FAILED UPDATE_FAILED INSTALL_FAILED UPDATING"
    fi
    for status in $deploymentStatus
    do
        local api_url="/urest/v1.1/deployment?deploymentStatus=${status}"
        local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                        -w '%{http_code}' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        '${BASE_URL}${api_url}'" -p=true)
        local http_code=${apiResponse:0-3}
        if [ "$http_code" != "200" ]; then
            write_log "fatal" "Failed to get deployment UUID.\nAPI response: ${apiResponse:0:-3}"
        else
            local n=0
            deployment_num=$(echo "${apiResponse:0:-3}" | $JQ '. | length')
            while [[ $n -lt $deployment_num ]];
            do
                deploymentType=$(echo "${apiResponse:0:-3}" | $JQ -r ".[$n].deploymentInfo.deploymentType")
                if [[ "$deploymentType" == "PRIMARY" ]];then
                    DEPLOYMENT_UUID=$(echo "${apiResponse:0:-3}" | $JQ -r ".[$n].deploymentInfo.deploymentUuid")
                    DEPLOYMENT_NAME=$(echo "${apiResponse:0:-3}" | $JQ -r ".[$n].deploymentInfo.deploymentName")
                    DEPLOYMENT_NAMESPACE=$(echo "${apiResponse:0:-3}" | $JQ -r ".[$n].deploymentInfo.namespace")
                    LAST_UPDATETIME=$(echo "${apiResponse:0:-3}" | $JQ -r ".[$n].deploymentInfo.updateTime")
                    if [ -n "$DEPLOYMENT_UUID" -a "$DEPLOYMENT_UUID" != "null" ]; then
                        write_log "info" "$(echo "$MSG_UPDATE_UUID_STATUS"|sed -e "s#<name>#$DEPLOYMENT_NAME#" -e "s#<uuid>#$DEPLOYMENT_UUID#")"
                        return
                    fi
                fi
                n=$((n+1))
            done
        fi
    done
    if [ -z "$DEPLOYMENT_UUID" -o "$DEPLOYMENT_UUID" = "null" ]; then
        write_log "fatal" "Currently only supports the PRIMARY suite update and reconfig, does not support additional suite update and reconfig.\n Failed to get PRIMARY suite deployment UUID.\nAPI response: ${apiResponse:0:-3}"
    fi
}

validateLifecycleSupport(){
    local lifecycle=$1
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Checking if $lifecycle action is supported via API ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/lifecycle"
    local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                    -w '%{http_code}' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    '${BASE_URL}${api_url}'" -p=true)
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "API response: ${apiResponse:0:-3}"
    else
        local change_enabled=$(echo "${apiResponse:0:-3}" | $JQ -r ".change.enabledAPI" )
        local reconfig_enabled=$(echo "${apiResponse:0:-3}" | $JQ -r ".reconfig.enabledAPI" )
        local update_enabled=$(echo "${apiResponse:0:-3}" | $JQ -r ".update.enabledAPI" )
        if [ "$lifecycle" = "reconfig" ]; then
            if [ "$change_enabled" != "true" -a "$reconfig_enabled" != "true" ]; then
                write_log "fatal" "suite $lifecycle is NOT supported via API.\nAPI response: ${apiResponse:0:-3}"
            else
                write_log "info" "suite $lifecycle is supported via API."
            fi
        elif [ "$lifecycle" = "update" ]; then
            if [ "$update_enabled" != "true" ]; then
                write_log "fatal" "suite $lifecycle is NOT supported via API.\nAPI response: ${apiResponse:0:-3}"
            else
                write_log "info" "suite $lifecycle is supported via API."
            fi
        fi
    fi
}

suiteReconfig(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Launching suite reconfiguration ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/reconfigure"
    local config_json="$(cat $CONFIG_FILE | sed -e 's/'\''/'\''\\'\'''\''/g')"
    local apiResponse=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '${config_json}' \\
                    '${BASE_URL}${api_url}'" -p=true -o=false)
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "202" ]; then
        write_log "fatal" "Failed to launch suite reconfiguration.\nAPI response: ${apiResponse:0:-3}"
    else
        local status=$(echo "${apiResponse:0:-3}" | $JQ -r ".status?")
        if [ "$status" != "true" ]; then
            write_log "fatal" "Failed to launch suite reconfiguration.\nAPI response: ${apiResponse:0:-3}"
        else
            write_log "info" "Reconfiguration launched"
        fi
    fi
}

checkSuiteReconfig(){
    write_log "loading" "Checking status of suite reconfig ..."
    local waitSeconds=0
    while true; do
        getXtoken
        getCsrfTokenSessionID
        local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}"
        local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                        -w '%{http_code}' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        '${BASE_URL}${api_url}'" -p=true)
        local http_code=${apiResponse:0-3}
        if [ "$http_code" != "200" ]; then
            write_log "fatal" "Failed to check suite reconfig status.\nAPI response: ${apiResponse:0:-3}"
        else
            local updateTime=$(echo "${apiResponse:0:-3}" | $JQ -r '.updateTime')
            local deploymentStatus=$(echo "${apiResponse:0:-3}" | $JQ -r '.deploymentStatus')
            if [ "$deploymentStatus" = "INSTALL_FINISHED" ] || [ "$deploymentStatus" = "RECONFIGURE_FAILED" ]; then
                if [ "$updateTime" -gt "$LAST_UPDATETIME" ]; then
                    if [ "$deploymentStatus" = "INSTALL_FINISHED" ]; then
                        write_log "info" "Reconfig done"
                        break
                    elif [ "$deploymentStatus" = "RECONFIGURE_FAILED" ]; then
                        write_log "fatal" "Suite reconfig failed.\nAPI response: ${apiResponse:0:-3}"
                    fi
                elif [ $waitSeconds -lt $TIMEOUT_SECONDS ]; then
                    write_log "infolog" "last updateTime: $LAST_UPDATETIME. current updateTime: $updateTime. Reconfig status is not updated; wait for 5 seconds to check the status again."
                    waitSeconds=$(( waitSeconds + 5 ))
                    sleep 5
                else
                    write_log "fatal" "Suite reconfig timeout. Please check the reconfig status manually."
                fi
            elif [ "$deploymentStatus" = "RECONFIGURING" ]; then
                if [ $waitSeconds -lt $TIMEOUT_SECONDS ]; then
                    write_log "infolog" "Suite is still under RECONFIGURING status; wait for 5 seconds to check the status again."
                    waitSeconds=$(( waitSeconds + 5 ))
                    sleep 5
                else
                    write_log "fatal" "Suite reconfig timeout. Please check the reconfig status manually."
                fi
            fi
        fi
    done
}

createDeploymentJson(){
    getXtoken
    getCsrfTokenSessionID
    write_log "infolog" "Creating deployment json ..."
    local api_url="/urest/v1.1/utils/upgrade-service/${DEPLOYMENT_UUID}/deploymentJson"
    local config_json="$(cat $CONFIG_FILE | sed -e 's/'\''/'\''\\'\'''\''/g')"
    local apiResponse=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '${config_json}' \\
                    '${BASE_URL}${api_url}'" -p=true -o=false)
    local http_code=${apiResponse:0-3}
    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
        write_log "infolog" "Creation done."
    else
        write_log "fatal" "Failed to create deployment json.\nAPI response: ${apiResponse}"
    fi
}

getSuiteUpdateType(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "$MSG_UPDATE_CHECK_TYPE"
    local config_json="$(cat $CONFIG_FILE | sed -e 's/'\''/'\''\\'\'''\''/g')"
    local api_url="/urest/v1.1/utils/upgrade-service/${DEPLOYMENT_UUID}/suiteupgradetype"
    local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '${config_json}' \\
                    '${BASE_URL}${api_url}'" -p=true -o=false)
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "Validation failed.\nAPI response: ${apiResponse:0:-3}"
    else
        UPDATE_TYPE=$(echo "${apiResponse:0:-3}" | $JQ -r ".upgradeType")
        if [[ "$UPDATE_TYPE" != "simple" ]] && [[ "$UPDATE_TYPE" != "complex" ]];then
            write_log "fatal" "Failed to get update type.\nAPI response: ${apiResponse}"
        fi
        # save UPDATE_TYPE for re-run
        exec_cmd "echo \"UPDATE_TYPE=$UPDATE_TYPE\" >> $PREVIOUS_INSTALL_CONFIG"
    fi
}

trySimpleUpdateImages(){
    local currentNumber=${1:-"1"}
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "$MSG_SIMPLE_UPDATE_START"
    local config_json="$(cat $CONFIG_FILE | sed -e 's/'\''/'\''\\'\'''\''/g')"
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/images:upgrade"
    local apiResponse=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \
                    --header 'Accept: application/json' \
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '${config_json}' \\
                    '${BASE_URL}${api_url}'" -p=true -o=false)
    local http_code=${apiResponse:0-3}
    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
        DEPLOYED_CONTROLLERS=${apiResponse:0:-3}
        write_log "infolog" "Simple update launched"
    elif [[ "$http_code" == "202" ]];then
        # try 15 minutes
        if [[ "$currentNumber" -ge 180 ]];then
            write_log "fatal" "Launch simple update timeout.\nAPI response: ${apiResponse}"
        fi
        write_log "warnlog" "Simple update launching ... (try $currentNumber)"
        if [[ "$currentNumber" -eq 1 ]];then
            echo -n 'Processing... this may take a while.'
        else
            echo -n "."
        fi
        sleep 5
        trySimpleUpdateImages "$((currentNumber+1))"
    else
        write_log "fatal" "Failed to launch simple update.\nAPI response: ${apiResponse}"
    fi
}

simpleUpdateStatus(){
    write_log "loading" "$MSG_SIMPLE_UPDATE_PROGRESS"
    local waitSeconds=0
    while true; do
        getXtoken
        getCsrfTokenSessionID
        local api_url="/urest/v1.1/utils/upgrade-service/${DEPLOYMENT_UUID}/check"
        local apiResponse=$(wrap_curl "curl -k -s -X POST \\
                        -w '%{http_code}' \\
                        --header 'Content-Type: application/json' \
                        --header 'Accept: application/json' \
                        --header '${X_AUTH_TOKEN}' \\
                        --header '${X_CSRF_TOKEN}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        --cookie '${JSESSION_ID}' \\
                        -d '${DEPLOYED_CONTROLLERS}' \\
                        '${BASE_URL}${api_url}'" -p=true)
        local http_code=${apiResponse:0-3}
        if [ "$http_code" != "201" -a "$http_code" != "423" ]; then
            write_log "fatal" "Failed to check deployed controllers.\nAPI response: ${apiResponse:0:-3}"
        elif [ "$http_code" = "201" ]; then
            local controller_num=$(echo "${apiResponse:0:-3}" | $JQ -r ".controllers | length")
            local ok_num=$(echo "${apiResponse:0:-3}" | $JQ -r ".controllers[].status" | grep 'OK' | wc -l)
            if [ $controller_num -eq $ok_num ]; then
                write_log "info" "$MSG_SIMPLE_UPDATE_FINISHED"
                break
            elif [ $waitSeconds -lt $TIMEOUT_SECONDS ]; then
                waitSeconds=$(( waitSeconds + 60 ))
                sleep 60
            else
                write_log "fatal" "Simple update timeout.\nAPI response: ${apiResponse:0:-3}"
            fi
        elif [ "$http_code" != "423" ]; then
            if [ $waitSeconds -lt $TIMEOUT_SECONDS ]; then
                waitSeconds=$(( waitSeconds + 60 ))
                sleep 60
            else
                write_log "fatal" "Simple update timeout.\nAPI response: ${apiResponse:0:-3}"
            fi
        fi
    done
}

simpleUpdateImages(){
    trySimpleUpdateImages
    simpleUpdateStatus
}

updateSuiteVersion(){
    getXtoken
    getCsrfTokenSessionID
    write_log "infolog" "Updating suite version ..."
    local config_version="$(cat "$CONFIG_FILE"|$JQ -r '.capabilities.version')"
    local api_url="/urest/v1.1/utils/upgrade-service/${DEPLOYMENT_UUID}/versionfeature?toversion=${config_version}&type=${UPDATE_TYPE}"
    local apiResponse=$(wrap_curl "curl -k -s -X PUT \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \
                    --header 'Accept: application/json' \
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    '${BASE_URL}${api_url}'" -p=true)
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "Failed to update suite version.\nAPI response: ${apiResponse:0:-3}"
    else
        write_log "info" "$(echo "$MSG_SIMPLE_UPDATE_SHOW_VERSION"|sed -e "s#<version>#${config_version}#")"
    fi
}

startUpgradePod(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "$MSG_COMPLEX_UPGRADE_POD_START"
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/startUpgradeImages"
    local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                    -w '%{http_code}' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    '${BASE_URL}${api_url}'" -p=true)
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "Create suite upgrade pod failed.\ncdf-apiserver API response: ${apiResponse:0:-3}"
    else
        write_log "infolog" "Create suiteUpgrade pod. cdf-apiserver API response: ${apiResponse}"
    fi
}

getUpgradePodStatus(){
    write_log "loading" "$MSG_COMPLEX_UPGRADE_POD_WAIT"
    local waitSeconds=0
    while true; do
        getXtoken
        getCsrfTokenSessionID
        local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/updatePod/status"
        local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                        -w '%{http_code}' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        '${BASE_URL}${api_url}'" -p=true)
        local http_code=${apiResponse:0-3}
        if [ "$http_code" != "200" ]; then
            write_log "fatal" "Failed to get upgrade pod status.\ncdf-apiserver API response: ${apiResponse:0:-3}"
        else
            local status=$(echo "${apiResponse:0:-3}" | $JQ -r '.threadInfo.threadStatus')
            if [ "$status" = "COMPLETED" ]; then
                write_log "log" "$MSG_COMPLEX_UPGRADE_POD_STATUS"
                break
            elif [ "$status" = "EXCEPTION" ];then
                write_log "fatal" "Get suite upgrade pod status failed.\ncdf-apiserver API response: ${apiResponse:0:-3}"
            elif [ $waitSeconds -lt 300 ]; then
                waitSeconds=$(( waitSeconds + 60 ))
                sleep 60
            else
                write_log "fatal" "Check upgrade pod status timeout.\nAPI response: ${apiResponse:0:-3}"
            fi
        fi
    done
}

getSuiteUpdateURL(){
    write_log "infolog" "Get suite upgrade pod url ..."
    SUITE_UPDATE_URL=""
    local waitSeconds=0
    while true; do
        getXtoken
        getCsrfTokenSessionID
        local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/lifecycle"
        local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                        -w '%{http_code}' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        '${BASE_URL}${api_url}'" -p=true)
        local http_code=${apiResponse:0-3}
        if [ "$http_code" != "200" ]; then
            if [ $waitSeconds -lt 300 ]; then
                waitSeconds=$(( waitSeconds + 60 ))
                sleep 60
            else
                write_log "fatal" "Get suite upgrade pod url timeout.\nAPI response: ${apiResponse:0:-3}"
            fi
        else
            SUITE_UPDATE_URL=$(echo "${apiResponse:0:-3}" | $JQ -r '.update.url')
            if [ -n "$SUITE_UPDATE_URL" ]; then
                write_log "log" "$(echo "$MSG_COMPLEX_UPGRADE_POD_URL"|sed -e "s#<url>#$SUITE_UPDATE_URL#")"
                break
            else
                write_log "fatal" "Failed to get suite upgrade pod url.\nAPI response: ${apiResponse:0:-3}"
            fi
        fi
    done
}

checkSuiteUpdateURL(){
    write_log "infolog" "Checking suite upgrade pod status ..."
    local waitSeconds=0
    while true; do
        getXtoken
        getCsrfTokenSessionID
        # proxy
        local apiResponse=$(wrap_curl "curl -s -X GET \\
                        -w '%{http_code}' \\
                        --header '${X_AUTH_TOKEN}' \\
                        '${SUITE_UPDATE_URL}' -k" -p=true)
        local http_code=${apiResponse:0-3}
        if [[ "$http_code" -ge "200" ]] && [[ "$http_code" -lt "400" ]];then
            break
        fi
        # no proxy
        local noproxyHost=$(echo "${SUITE_UPDATE_URL}"|grep -Po '(?<=//)[^/:#?]+')
        local apiResponse2=$(wrap_curl "curl -s -X GET \\
                        -w '%{http_code}' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --noproxy '${noproxyHost}' \\
                        '${SUITE_UPDATE_URL}' -k" -p=true)
        local http_code2=${apiResponse2:0-3}
        if [[ "$http_code2" -ge "200" ]] && [[ "$http_code2" -lt "400" ]];then
            break
        fi
        if [ $waitSeconds -lt 300 ]; then
            waitSeconds=$(( waitSeconds + 60 ))
            sleep 60
        else
            write_log "fatal" "Check suite upgrade pod status timeout.\nProxy API response: ${apiResponse:0:-3} \nNo Proxy API response: ${apiResponse2:0:-3}"
        fi
    done
}

checkSuiteUpdatePodStatus(){
    getSuiteUpdateURL
    checkSuiteUpdateURL
}

startComplexUpdate(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "$MSG_COMPLEX_SUITE_POD_START"
    local config_json="$(cat $CONFIG_FILE | sed -e 's/'\''/'\''\\'\'''\''/g')"
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/update"
    local apiResponse=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \
                    --header 'Accept: application/json' \
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '${config_json}' \\
                    '${BASE_URL}${api_url}'" -p=true -o=false)
    local http_code=${apiResponse:0-3}
    if [ "$http_code" != "202" ]; then
        write_log "fatal" "Failed to complex update.\nAPI response: ${apiResponse:0:-3}"
    else
        write_log "infolog" "Complex update launched"
    fi
}

complexUpdateStatus(){
    write_log "loading" "$MSG_COMPLEX_SUITE_POD_PROGRESS"
    local waitSeconds=0
    while true; do
        getXtoken
        getCsrfTokenSessionID
        local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}"
        local apiResponse=$(wrap_curl "curl -k -s -X GET \\
                -w \"%{http_code}\" \\
                --header 'Content-Type: application/json' \\
                --header 'Accept: application/json' \\
                --header \"${X_AUTH_TOKEN}\" \\
                --noproxy \"${CDF_APISERVER_HOST}\" \\
                \"${BASE_URL}${api_url}\"" -p=true)
        local http_code=${apiResponse:0-3}
        if [ "$http_code" != "200" ]; then
            write_log "fatal" "Failed to get suite version.\nAPI response: ${apiResponse:0:-3}"
        else
            local version=$(echo "${apiResponse:0:-3}" | $JQ -r '.version')
            local deploymentStatus=$(echo "${apiResponse:0:-3}" | $JQ -r '.deploymentStatus')
            local updateTime=$(echo "${apiResponse:0:-3}" | $JQ -r '.updateTime')
            local config_version="$(cat "$CONFIG_FILE"|$JQ -r '.capabilities.version')"
            if [ "$deploymentStatus" = "INSTALL_FINISHED" ] && [ "$version" = "$config_version" ]; then
                write_log "log" "$(echo "$MSG_COMPLEX_SHOW_VERSION"|sed -e "s#<version>#$version#")"
                break
            elif [ "$deploymentStatus" = "UPDATE_FAILED" ] && [ "$updateTime" -gt "$LAST_UPDATETIME" ]; then
                write_log "fatal" "Suite update failed.\nAPI response: ${apiResponse:0:-3}"
                break
            elif [ $waitSeconds -lt $TIMEOUT_SECONDS ]; then
                waitSeconds=$(( waitSeconds + 60 ))
                sleep 60
            else
                write_log "fatal" "Complex update timeout.\nAPI response: ${apiResponse:0:-3}"
            fi
        fi
    done
}

launchComplexUpdate(){
    startComplexUpdate
    complexUpdateStatus
}

stepStorage(){
    local step=$1
    getXtoken
    getCsrfTokenSessionID
    write_log "infolog" "Store front end step: $step ..."
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/configuration"
    local platformSelectionModel="$FULL_JSON"
    local body="{\"configuration\":[{\"key\":\"install\",\"value\":{\"step\":\"${step}\",\"platformSelectionModel\":${platformSelectionModel}}}]}"
    record "curl -s -k -X POST --header *** -d *** ${BASE_URL}${api_url}"
    local apiResult=$(wrap_curl "curl -k -s -X POST \\
                    -w '%{http_code}' \\
                    --header 'Content-Type: application/json' \\
                    --header 'Accept: application/json' \\
                    --header '${X_AUTH_TOKEN}' \\
                    --header '${X_CSRF_TOKEN}' \\
                    --noproxy '${CDF_APISERVER_HOST}' \\
                    --cookie '${JSESSION_ID}' \\
                    -d '$(echo "$body"|sed -e "s/'/'\\\\''/g")' \\
                    '${BASE_URL}${api_url}'" -p=true -o=false -m=false)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "201" ]; then
        write_log "fatal" "Failed to store front end step.\nAPI response: ${apiResult:0:-3}\nFor detail error information, refer to $LOGFILE"
    else
        write_log "infolog" "Store done"
    fi
}

getDeployment(){
    getXtoken
    getCsrfTokenSessionID
    write_log "loading" "Getting deploymentuuid for deployment ..."
    local api_url="/urest/v1.1/deployment?deploymentStatus=NEW&deploymentStatus=FEATURE_SETTED&deploymentStatus=CONF_POD_STARTED&deploymentStatus=SUITE_INSTALL&deploymentStatus=INSTALL_FINISHED&deploymentStatus=INSTALLING&deploymentStatus=RECONFIGURING&deploymentStatus=UPDATING&deploymentStatus=INSTALL_FAILED&deploymentStatus=RECONFIGURE_FAILED&deploymentStatus=UPDATE_FAILED&deploymentStatus=PHASE2_INSTALLING&deploymentStatus=PHASE2_FINISHED&deploymentStatus=PHASE2_FAILED&deploymentMode=suite"
    local apiResult=$(wrap_curl "curl -k -s -X GET \\
                      -w \"%{http_code}\" \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${CDF_APISERVER_HOST}\" \\
                      \"${BASE_URL}${api_url}\"" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        DEPLOYMENT_TYPE="PRIMARY"
        local deployment_num=$(echo "${apiResult:0:-3}" | $JQ -r '.|length')
        local n=0

        # get DEPLOYMENT_UUID and DEPLOYMENT_NAME
        while [[ $n -lt $deployment_num ]];
        do
            DEPLOYMENT_UUID=$(echo "${apiResult:0:-3}" | $JQ -r ".[$n].deploymentInfo.deploymentUuid")
            DEPLOYMENT_NAME=$(echo "${apiResult:0:-3}" | $JQ -r ".[$n].deploymentInfo.deploymentName")
            write_log "info" "Primary deployment: ($DEPLOYMENT_NAME: $DEPLOYMENT_UUID)"
            break
            n=$((n+1))
        done
    fi
}

getImageList(){
    write_log "loading" "$MSG_COMM_IMAGES_CLAC"
    if [ "$LIFE_CYCLE" = "install" ];then
        local config_json="$(cat $CONFIG_FILE|$JQ -r .)"
        local suite_name="$(cat $CONFIG_FILE|$JQ -r ".capabilities.suite")"
        local suite_version="$(cat $CONFIG_FILE|$JQ -r '.capabilities.version')"
        getImageList_install "$config_json" "$suite_name" "$suite_version"
    elif [ "$LIFE_CYCLE" = "update" ];then
        local targetVersion="$(cat $CONFIG_FILE|$JQ -r '.capabilities.version')"
        getImageList_update "$targetVersion"
    elif [ "$LIFE_CYCLE" = "reconfig" ];then
        local featureSets="$(cat $CONFIG_FILE|$JQ -r '.capabilities.capabilitySelection')"
        getImageList_reconfigure "$featureSets"
    fi
}

getImageList_install(){
    write_log "infolog" "Calculating image list for install ..."
    local config_json=$1
    local suite_name=$2
    local suite_version=$3
    local api_url="/urest/v1.1/lifecycle/install/images:calculate"
    if [ -n "$config_json" ]; then
        local postBody="{\"configjson\":$config_json}"
    elif [ -n "$suite_name" -a -z "$suite_version" ]; then
        local postBody="{\"suite\":\"$suite_name\"}"
        record "postBody=${postBody}"
    elif [ -n "$suite_name" -a -n "$suite_version" ]; then
        local postBody="{\"suite\":\"$suite_name\",\"version\":\"$suite_version\"}"
        record "postBody=${postBody}"
    fi
    # local postBody="{\"configjson\":$config_json,\"suite\":\"$suite_name\",\"version\":\"$suite_version\"}"
    requestImageList "${api_url}" "${postBody}"
}
getImageList_update(){
    write_log "infolog" "Calculating image list for update ..."
    local targetVersion=$1
    local api_url="/urest/v1.1/lifecycle/update/images:calculate"
    local postBody="{\"targetVersion\":\"$targetVersion\"}"
    record "postBody=${postBody}"
    requestImageList "${api_url}" "${postBody}"
}
getImageList_reconfigure(){
    write_log "infolog" "Calculating image list for reconfigure ..."
    local featureSets=$1
    local api_url="/urest/v1.1/lifecycle/reconfigure/images:calculate"
    local postBody="{\"featureSets\":${featureSets}}"
    record "postBody=${postBody}"
    requestImageList "${api_url}" "${postBody}"
}
requestImageList(){
    IMAGE_LIST=
    local query_parametes=
    if [ -n "${DEPLOYMENT_UUID}" ];then
        query_parametes="?deploymentUuid=${DEPLOYMENT_UUID}"
    fi
    local api_url="$1${query_parametes}"
    local postBody=$2
    post "$api_url" "$postBody" "200" "10"
    IMAGE_LIST="$(echo "${RESP_BODY}"|$JQ -c -r '{images:.images|map({image:.image})}')"
}

post(){
    local api_url=$1
    # local postBody=$2
    local postBody="$(echo "$2"|awk '{printf("%s",$0)}')"
    local expectStatusCode=${3:-"200"}
    local retryCount=${4:-"0"}

    # copy file to pod from local
    if [ "${postBody:0:1}" == "@" ];then
        local uploadFile="${postBody:1}"
        local container_name="cdf-apiserver"
        local pod_name;pod_name=$(exec_cmd "$kubectl get pods -n ${SYSTEM_NAMESPACE} 2>/dev/null|grep '$container_name'|grep 'Running'|awk '{len=split(\$2,arr,\"/\");if(len==2&&arr[1]>0&&arr[1]==arr[2])print \$1}'" -p true)
        if [ -z "$pod_name" ];then
            write_log "fatal" "Failed to get ${SYSTEM_NAMESPACE}/$container_name. For detail logs, please refer to $LOGFILE"
        fi
        local waitSeconds=0
        local timeoutSeconds=10
        while true;do
            if exec_cmd "$kubectl cp --no-preserve=true $uploadFile ${SYSTEM_NAMESPACE}/$pod_name:$uploadFile -c cdf-apiserver";then
                break
            fi
            if [ $waitSeconds -lt $timeoutSeconds ]; then
                waitSeconds=$(( waitSeconds + 1 ))
                sleep 2
            else
                write_log "fatal" "Failed to copy $uploadFile to ${SYSTEM_NAMESPACE}/$container_name. For detail logs, please refer to $LOGFILE"
            fi
        done
    fi

    RESP_BODY=""
    getXtoken
    getCsrfTokenSessionID
    record "POST ${BASE_URL}${api_url}"
    local retryTime=0
    while true; do
        local apiResult=$(wrap_curl "curl -k -s -X POST \\
                        -w '%{http_code}' \\
                        --header 'Content-Type: application/json' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --header '${X_CSRF_TOKEN}' \\
                        --cookie '${JSESSION_ID}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        -d '$(echo "$postBody"|sed -e "s/'/'\\\\''/g")' \\
                        '${BASE_URL}${api_url}'" -p=true -o=false)
        local http_code=${apiResult:0-3}
        local is_expectStatusCode=
        for statusCode in ${expectStatusCode};do
            if [ "$http_code" = "${statusCode}" ]; then
                is_expectStatusCode="true"
                break
            fi
        done
        if [ -z "${is_expectStatusCode}" ]; then
            if [ "$retryTime" -eq "${retryCount}" ]; then
                if [[ "${http_code}" == "000" ]];then
                    write_log "fatal" "An exception may have occurred on the server backend, and the content of the current API response is empty."
                else
                    write_log "fatal" "${apiResult}"
                fi
            else
                retryTime=$((retryTime+1))
            fi
        else
            break
        fi
        sleep 2
    done
    RESP_BODY="${apiResult:0:-3}"
}

start_query_images(){
    getXtoken
    getCsrfTokenSessionID
    local retryTime=0
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/images:validate?async=true"
    START_QUERY_IMAGES_RESP=
    while true; do
        local apiResult=$(wrap_curl "curl -k -s -X POST \\
                        -w '%{http_code}' \\
                        --header 'Content-Type: application/json' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --header '${X_CSRF_TOKEN}' \\
                        --cookie '${JSESSION_ID}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        -d '$IMAGE_LIST' \\
                        ${BASE_URL}${api_url}" -p=true)
        local http_code=${apiResult:0-3}
        if [ "$http_code" == "200" ] || [ "$http_code" == "201" ] || [ "$http_code" == "202" ]; then
            START_QUERY_IMAGES_RESP=$(echo "${apiResult:0:-3}"|$JQ -r '{threadInfo:.threadInfo}')
            break
        fi
        if [ "$retryTime" -eq 3 ]; then
            write_log "fatal" "${apiResult:0:-3}"
        else
            retryTime=$((retryTime+1))
        fi
    done
}

query_images_status(){
    getXtoken
    getCsrfTokenSessionID
    local retryTime=0
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/images/validate:result"
    QUERY_IMAGES_STATUS_RESP=
    while true; do
        local apiResult=$(wrap_curl "curl -k -s -X POST \\
                        -w '%{http_code}' \\
                        --header 'Content-Type: application/json' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --header '${X_CSRF_TOKEN}' \\
                        --cookie '${JSESSION_ID}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        -d '$START_QUERY_IMAGES_RESP' \\
                        ${BASE_URL}${api_url}" -p=true)
        local http_code=${apiResult:0-3}
        if [ "$http_code" != "200" ]; then
            if [ "$retryTime" -eq 3 ]; then
                write_log "fatal" "${apiResult:0:-3}"
            else
                retryTime=$((retryTime+1))
            fi
        else
            QUERY_IMAGES_STATUS_RESP=${apiResult:0:-3}
            break
        fi
    done
}

check_query_images(){
    start_query_images
    local retryTime=0
    while true; do
        query_images_status
        local threadStatus=$(echo "$QUERY_IMAGES_STATUS_RESP"|$JQ -r '.threadInfo.threadStatus')
        if [[ "$threadStatus" == "COMPLETED" ]];then
            break
        fi
        if [ "$retryTime" -eq 600 ]; then
            write_log "fatal" "${apiResult:0:-3}"
        else
            retryTime=$((retryTime+1))
            sleep 1
        fi
    done

    local allNum=$(echo "$QUERY_IMAGES_STATUS_RESP"|$JQ -r '.allNum')
    local existNum=$(echo "$QUERY_IMAGES_STATUS_RESP"|$JQ -r '.existNum')
    local missImages=
    if [ "$allNum" -ne "$existNum" ];then
        missImages=$(echo "$QUERY_IMAGES_STATUS_RESP"|$JQ -r '.missImages[].image')
    fi

    if [ -z "$missImages" ]; then
        write_log "info" "$(echo "$MSG_COMM_IMAGES_STATUS"|sed -e "s#<required>#$existNum#" -e "s#<available>#$allNum#")"
    else
        write_log "fatal" "Number of images: $existNum/$allNum . Missing images:\n $missImages"
    fi
}

checkImages(){
    if [[ -n "$IMAGE_LIST" ]] && [[ "$(echo "$IMAGE_LIST"|$JQ -r '.|length' 2>/dev/null)" -gt 0 ]]; then
        check_query_images
    else
        write_log "info" "$(echo "$MSG_COMM_IMAGES_STATUS"|sed -e "s#<required>#0#" -e "s#<available>#0#")"
    fi
}

changeComponentsStatus(){
    local retryCount=0
    while true; do
        getXtoken
        getCsrfTokenSessionID
        write_log "infolog" "Change components status ..."
        local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/components/status"
        local json='[{"name":"itom-suite-upgrade","status":"NEW"}]'
        local apiResult=$(wrap_curl "curl -k -s -X PUT \\
                        -w '%{http_code}' \\
                        --header 'Content-Type: application/json' \\
                        --header 'Accept: application/json' \\
                        --header '${X_AUTH_TOKEN}' \\
                        --header '${X_CSRF_TOKEN}' \\
                        --noproxy '${CDF_APISERVER_HOST}' \\
                        --cookie '${JSESSION_ID}' \\
                        -d '${json}' \\
                        '${BASE_URL}${api_url}'" -p=true)
        local http_code=${apiResult:0-3}
        if [ "$http_code" != "200" ]; then
            if [ "$retryCount" -lt 3 ];then
                sleep 1
                retryCount=$(( retryCount + 1 ))
                continue
            fi
            write_log "fatal" "Failed to reset suite status: ${apiResult:0:-3}"
        else
            write_log "infolog" "Sucessfully change status."
            break
        fi
    done
}

launchDeployerForUpgrade(){
    write_log "loading" "$MSG_COMPLEX_DEPLOYER_START"
    local api_url="/urest/v1.1/deployment/${DEPLOYMENT_UUID}/upgrade/cdfdeployer?upgradeSuiteToVersion=''"
    post "$api_url" "" "201" "10"
    local status;status="$(echo "${RESP_BODY}"|$JQ -r '.status')"
    if [[ "$status" != "true" ]];then
        write_log "fatal" "launch deployer for upgrade error: $RESP_BODY"
    fi
    local pod_name;pod_name=$($kubectl get pods -n $SYSTEM_NAMESPACE|grep -P 'itom-cdf-deployer-\d{4}\.\d{2}-3\.2'|awk '{print $1}'|head -1)
    local n=0
    while [[ -z "$pod_name" ]];do
        pod_name=$($kubectl get pods -n $SYSTEM_NAMESPACE|grep -P 'itom-cdf-deployer-\d{4}\.\d{2}-3\.2'|awk '{print $1}'|head -1)
        if [[ -n "$pod_name" ]];then
            break
        fi
        if [[ "$n" -gt 10 ]];then
            local cdf_version;cdf_version=$(cat ${CDF_HOME}/version.txt 2>/dev/null)
            pod_name="itom-cdf-deployer-${cdf_version%.*}-3.2"
            write_log "infolog" "Not found pod: $SYSTEM_NAMESPACE/itom-cdf-deployer-${cdf_version%.*}-3.2-*"
            break
        fi
        sleep 5
        n=$((n+1))
    done
    write_log "info" "$(echo "$MSG_COMPLEX_DEPLOYER_SHOW"|sed -e "s#<namespace>#$SYSTEM_NAMESPACE#" -e "s#<pod>#$pod_name#")"
}

getSuiteFrontendUrl(){
    local svc_ip;svc_ip=$(exec_cmd "$kubectl get svc itom-frontend-ui -n ${SYSTEM_NAMESPACE} -o custom-columns=clusterIP:.spec.clusterIP --no-headers 2>/dev/null" -p=true)
    if [ -z "${svc_ip}" ];then
        write_log "fatal" "Failed to get svc IP address of itom-frontend-ui"
    fi
}

startDeployerJob(){
    write_log "loading" "start deployer job ..."
    getSuiteFrontendUrl
    getXtoken
    getCsrfTokenSessionID
    local api_url="/urest/v1.2/deployment/${DEPLOYMENT_UUID}/deployer"
    local apiResult=$(wrap_curl "curl -s -X POST \\
                      -w \"%{http_code}\" \\
                      --header 'Content-Type: application/json' \\
                      --header 'Accept: application/json' \\
                      --header \"${X_AUTH_TOKEN}\" \\
                      --header \"${X_CSRF_TOKEN}\" \\
                      --cookie \"${JSESSION_ID}\" \\
                      --noproxy \"${SUITE_FRONTEND_HOST}\" \\
                      \"${SUITE_FRONTEND_URL}${api_url}\" -k" -p=true)
    local http_code=${apiResult:0-3}
    if [ "$http_code" != "200" ]; then
        write_log "fatal" "${apiResult:0:-3}"
    else
        local status;status="$(echo "${apiResult:0:-3}"|$JQ -r '.code')"
        if [[ "$status" != "0" ]];then
        local error_msg;error_msg="$(echo "${apiResult:0:-3}"|$JQ -r '.message')"
            write_log "fatal" "start deployer job error: $error_msg"
        fi
        write_log "info" "start deployer job done"
    fi
}

checkConfigNodesChanged(){
    # CLASSIC
    local master_sha=$(cat $CONFIG_FILE|$JQ  -r '.masterNodes[]|with_entries(.key=.key|.value=.value)'|sha256sum |awk '{print $1}')
    local worker_sha=$(cat $CONFIG_FILE|$JQ  -r '.workerNodes[]|with_entries(.key=.key|.value=.value)'|sha256sum |awk '{print $1}')
    source $PREVIOUS_INSTALL_CONFIG
    if [[ "$master_sha" != "$_masterNodes_sha" ]] || [[ "$worker_sha" != "$_workerNodes_sha" ]];then
        return 0
    fi
    return 1
}

updateConfigNodesSha(){
    # CLASSIC
    local master_sha=$(cat $CONFIG_FILE|$JQ  -r '.masterNodes[]|with_entries(.key=.key|.value=.value)'|sha256sum |awk '{print $1}')
    local worker_sha=$(cat $CONFIG_FILE|$JQ  -r '.workerNodes[]|with_entries(.key=.key|.value=.value)'|sha256sum |awk '{print $1}')
    exec_cmd "sed -i -r -e '/^_workerNodes_sha=\w+$/ d' $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "sed -i -r -e '/^_masterNodes_sha=\w+$/ d' $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo '_masterNodes_sha=$master_sha' >> $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo '_workerNodes_sha=$worker_sha' >> $PREVIOUS_INSTALL_CONFIG"
}

# Warning: Do not modify the function name!
precheckAllNodes(){
    if [ "$INSTALLED_TYPE" = "CLASSIC" ];then
        exec_cmd "echo '' > $SKIP_FAILED_WORKER_NODES_FILE"
        local master_nodes="$(cat $CONFIG_FILE|$JQ -r '.masterNodes[].hostname'|xargs)"
        local worker_nodes="$(cat $CONFIG_FILE|$JQ -r '.workerNodes[].hostname'|xargs)"
        local nodes="${master_nodes} ${worker_nodes}"
        for node_name in ${nodes};do
            precheckNode "$node_name"
        done
    fi
}

updateConfigFieldsSha(){
    local allowWorkerOnMaster_sha=$(cat $CONFIG_FILE|$JQ -r '.allowWorkerOnMaster'                                    2>/dev/null|sha256sum|awk '{print $1}')
    local masterNodes_sha=$(        cat $CONFIG_FILE|$JQ -r '.masterNodes[]   |with_entries(.key=.key|.value=.value)' 2>/dev/null|sha256sum|awk '{print $1}')
    local workerNodes_sha=$(        cat $CONFIG_FILE|$JQ -r '.workerNodes[]   |with_entries(.key=.key|.value=.value)' 2>/dev/null|sha256sum|awk '{print $1}')
    local volumes_sha=$(            cat $CONFIG_FILE|$JQ -r '.volumes[]       |with_entries(.key=.key|.value=.value)' 2>/dev/null|sha256sum|awk '{print $1}')
    local licenseAgreement_sha=$(   cat $CONFIG_FILE|$JQ -r '.licenseAgreement|with_entries(.key=.key|.value=.value)' 2>/dev/null|sha256sum|awk '{print $1}')
    local connection_sha=$(         cat $CONFIG_FILE|$JQ -r '.connection      |with_entries(.key=.key|.value=.value)' 2>/dev/null|sha256sum|awk '{print $1}')
    local database_sha=$(           cat $CONFIG_FILE|$JQ -r '.database        |with_entries(.key=.key|.value=.value)' 2>/dev/null|sha256sum|awk '{print $1}')
    local capabilities_sha=$(       cat $CONFIG_FILE|$JQ -r '.capabilities    |with_entries(.key=.key|.value=.value)' 2>/dev/null|sha256sum|awk '{print $1}')
    exec_cmd "sed -i -r -e '/^_allowWorkerOnMaster_sha=\w+$/ d' $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "sed -i -r -e '/^_masterNodes_sha=\w+$/ d'         $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "sed -i -r -e '/^_workerNodes_sha=\w+$/ d'         $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "sed -i -r -e '/^_volumes_sha=\w+$/ d'             $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "sed -i -r -e '/^_licenseAgreement_sha=\w+$/ d'    $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "sed -i -r -e '/^_connection_sha=\w+$/ d'          $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "sed -i -r -e '/^_database_sha=\w+$/ d'            $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "sed -i -r -e '/^_capabilities_sha=\w+$/ d'        $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo \"_allowWorkerOnMaster_sha=$allowWorkerOnMaster_sha\" >> $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo \"_masterNodes_sha=$masterNodes_sha\"                 >> $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo \"_workerNodes_sha=$workerNodes_sha\"                 >> $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo \"_volumes_sha=$volumes_sha\"                         >> $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo \"_licenseAgreement_sha=$licenseAgreement_sha\"       >> $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo \"_connection_sha=$connection_sha\"                   >> $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo \"_database_sha=$database_sha\"                       >> $PREVIOUS_INSTALL_CONFIG"
    exec_cmd "echo \"_capabilities_sha=$capabilities_sha\"               >> $PREVIOUS_INSTALL_CONFIG"
}

# Warning: Do not modify the function name! This is a critical step!
updateFullJsonParams(){
    getFullJson
    updateConfigFieldsSha
    uploadJsonFile
}

preCheckSilentConfig(){
    if [ "$INSTALLED_TYPE" = "CLASSIC" ];then
        if is_step_not_done "@updateFullJsonParams";then
            checkConfigNodesChanged
            if [[ $? -eq 0 ]];then
                exec_cmd "sed -i -r -e '/^@precheckAllNodes$/ d' $STEPS_FILE"
            fi

            record_step "Pre-checking all nodes ..." \
            precheckAllNodes

            # Update available values
            updateConfigNodesSha
        fi
    fi
}

collectInfo(){
    if [ "$LIFE_CYCLE" = "install" ];then
        copyCerts
    fi

    record_step "Generating and uploading full configuration file into vault ..." \
    updateFullJsonParams

    write_log "info" "** The configuration file has been uploaded to cdf-apiserver, please do not change this file."

    getFullJsonParams

    if [ "$CAPS_DEPLOYMENT_MANAGEMENT" == "true" ] && [ -n "$METADATA" ];then
        storeSuiteFeature
    fi
}

preUploadImages(){
    if [ "$CAPS_DEPLOYMENT_MANAGEMENT" == "true" ] && [ -n "$METADATA" ];then
        record_step "Creating all required volumes ..." \
        createAllVolumes
    fi

    if [ "$LIFE_CYCLE" = "install" ];then
        startPrivateReg
    fi

    stepStorage "download-start"
    # geneDownloadZip
}

checkImagesInExtRep(){
    getImageList
    checkImages
}

skipImagesCheck(){
    local isSkipImageCheck=$(cat $CONFIG_FILE | $JQ -r ".skipImageCheck")
    if [[ "$isSkipImageCheck" == "true" ]];then
        write_log "infolog" "The configuration file has skipped checking the image list."
    else
        record_step "$MSG_COMM_IMAGES_CHECK" \
        checkImagesInExtRep
    fi
}

deployFullCdf(){
    stepStorage "prepare-prepare"
    checkCdfPhase2Status
}

extendNodesByApi(){
    # record_step "Pre-checking all nodes ..." \
    # nodePrecheck

    record_step "Prepare node configuration information ..." \
    launchExtend

    nodeExtendStatus

    record_step "Adding worker label on control plane nodes ..." \
    addWorkerLabel

    stepStorage "prepare-start"
}

cmdPrecheckNode(){
    local node_type=$1
    local node_obj=$2
    local options=""
    for pk in $(echo "
                --flannel-iface:flannelIface
                --key:privateKey
                --key-pass:privateKeyPassword
                --node:hostname
                --node-pass:password
                --node-user:user
                --skip-warning:skipWarning
                "|xargs)
    do
        local option="${pk%:*}"
        local key="${pk#*:}"
        local has_key=$(echo "$node_obj"|$JQ "has(\"$key\")")
        local val=""
        if [[ "$has_key" == "true" ]];then
            val="$(echo "$node_obj"|$JQ -r ".${key} // empty")"
            if [[ -n "$val" ]];then
                if [[ "$key" == "password" ]] || [[ "$key" == "privateKeyPassword" ]];then
                    val="$(echo -n "$val"|base64 -w0)"
                fi
            fi
        fi
        if [[ "$has_key" != "true" ]] || [[ -z "$val" ]];then
            local gobal_key=""
            gobal_key="node$(echo "${key:0:1}"|tr '[:lower:]' '[:upper:]')${key:1}"
            val="$(cat $CONFIG_FILE|$JQ -r ".${gobal_key} // empty")"
            if [[ -n "$val" ]];then
                if [[ "$key" == "password" ]] || [[ "$key" == "privateKeyPassword" ]];then
                    val="$(echo -n "$val"|base64 -w0)"
                fi
            fi
        fi
        if [[ "$option" == "--skip-warning" ]];then
            if [[ -z "$val" ]];then
                val=$CLI_SKIP_PRECHECK_WARNING
            fi
            if [ -f "$CDF_INSTALL_RUNTIME_HOME/user_confirm_skip_precheck_warning_$hostname" ];then
                write_log "debug" "node: $hostname, user confirm skip precheck warnings"
                val=true
            fi
            if [[ -z "$val" ]];then
                val=false
            fi
        fi
        if [[ -n "$val" ]];then
            options="$options $option '$val'"
        fi
        if [[ "$key" == "hostname" ]];then
            local hostname="$val"
        fi
    done
    record "$CDF_HOME/bin/cdfctl node precheck --node-type='$node_type' $options --base64-pw 1>$TMP_FOLDER/cdf-precheck-node-$hostname.log 2>&1"
    exec_cmd "$CDF_HOME/bin/cdfctl node precheck --node-type='$node_type' $options --base64-pw 1>$TMP_FOLDER/cdf-precheck-node-$hostname.log 2>&1" -m=false
    if [[ $? -ne 0 ]];then
        local logLevel="fatal"
        if [[ "$SKIP_FAILED_WORKER_NODE" == "true" ]] && [[ "${node_type}" == "worker" ]];then
           logLevel="infolog"
           exec_cmd "echo '$hostname' >> $SKIP_FAILED_WORKER_NODES_FILE"
           write_log "info" "Pre-checking node: $hostname check failed and skipped"
        fi
        write_log "$logLevel" "Pre-check ${node_type} node $node_name failed: \n$(cat $TMP_FOLDER/cdf-precheck-node-$hostname.log)"
    fi
}

cmdRemoveNode(){
    local node_obj=$1
    local options=""
    for pk in $(echo "
                --key:privateKey
                --key-pass:privateKeyPassword
                --node:hostname
                --node-pass:password
                --node-user:user
                "|xargs)
    do
        local option="${pk%:*}"
        local key="${pk#*:}"
        local has_key=$(echo "$node_obj"|$JQ "has(\"$key\")")
        local val=""
        if [[ "$has_key" == "true" ]];then
            val="$(echo "$node_obj"|$JQ -r ".${key} // empty")"
            if [[ -n "$val" ]];then
                if [[ "$key" == "password" ]] || [[ "$key" == "privateKeyPassword" ]];then
                    val="$(echo -n "$val"|base64 -w0)"
                fi
            fi
        fi
        if [[ "$has_key" != "true" ]] || [[ -z "$val" ]];then
            local gobal_key=""
            gobal_key="node$(echo "${key:0:1}"|tr '[:lower:]' '[:upper:]')${key:1}"
            val="$(cat $CONFIG_FILE|$JQ -r ".${gobal_key} // empty")"
            if [[ "$key" == "password" ]] || [[ "$key" == "privateKeyPassword" ]];then
                val="$(echo -n "$val"|base64 -w0)"
            fi
        fi
        if [[ -n "$val" ]];then
            options="$options $option '$val'"
        fi
        if [[ "$key" == "hostname" ]];then
            local hostname="$val"
        fi
    done
    record "$CDF_HOME/bin/cdfctl node remove $options --skip-warning=false --force=true --follow=true 1>$TMP_FOLDER/cdf-remove-node-$hostname.log 2>&1"
    exec_cmd "$CDF_HOME/bin/cdfctl node remove $options --skip-warning=false --force=true --follow=true 1>$TMP_FOLDER/cdf-remove-node-$hostname.log 2>&1" -m=false
    if [[ $? -ne 0 ]];then
        write_log "fatal" "Remove node $node_name failed: \n$(cat $TMP_FOLDER/cdf-remove-node-$hostname.log)"
    fi
}

cmdAddNode(){
    local node_type=$1
    local node_obj=$2
    local options=""
    for pk in $(echo "
                --flannel-iface:flannelIface
                --key:privateKey
                --key-pass:privateKeyPassword
                --node:hostname
                --node-pass:password
                --node-user:user
                --skip-res-check:skipResourceCheck
                --skip-warning:skipWarning
                "|xargs)
    do
        local option="${pk%:*}"
        local key="${pk#*:}"
        local has_key=$(echo "$node_obj"|$JQ "has(\"$key\")")
        local val=""
        if [[ "$has_key" == "true" ]];then
            val="$(echo "$node_obj"|$JQ -r ".${key} // empty")"
            if [[ -n "$val" ]];then
                if [[ "$key" == "password" ]] || [[ "$key" == "privateKeyPassword" ]];then
                    val="$(echo -n "$val"|base64 -w0)"
                fi
            fi
        fi
        if [[ "$has_key" != "true" ]] || [[ -z "$val" ]];then
            local gobal_key=""
            gobal_key="node$(echo "${key:0:1}"|tr '[:lower:]' '[:upper:]')${key:1}"
            val="$(cat $CONFIG_FILE|$JQ -r ".${gobal_key} // empty")"
            if [[ -n "$val" ]];then
                if [[ "$key" == "password" ]] || [[ "$key" == "privateKeyPassword" ]];then
                    val="$(echo -n "$val"|base64 -w0)"
                fi
            fi
        fi
        if [[ "$option" == "--skip-warning" ]];then
            if [[ -z "$val" ]];then
                val=$CLI_SKIP_PRECHECK_WARNING
            fi
            if [ -f "$CDF_INSTALL_RUNTIME_HOME/user_confirm_skip_precheck_warning_$hostname" ];then
                write_log "debug" "node: $hostname, user confirm skip precheck warnings"
                val=true
            fi
            if [[ -z "$val" ]];then
                val=false
            fi
        fi
        if [[ -n "$val" ]];then
            options="$options $option '$val'"
        fi
        if [[ "$key" == "hostname" ]];then
            local hostname="$val"
        fi
    done
    record "$CDF_HOME/bin/cdfctl node add --node-type=${node_type} $options --follow=false --base64-pw 1>$TMP_FOLDER/cdf-add-node-$hostname.log 2>&1"
    exec_cmd "$CDF_HOME/bin/cdfctl node add --node-type=${node_type} $options --follow=false --base64-pw 1>$TMP_FOLDER/cdf-add-node-$hostname.log 2>&1" -m=false
    if [[ $? -ne 0 ]];then
        local logLevel="fatal"
        if [[ "$SKIP_FAILED_WORKER_NODE" == "true" ]] && [[ "${node_type}" == "worker" ]];then
            logLevel="infolog"
            exec_cmd "echo '$hostname' >> $SKIP_FAILED_WORKER_NODES_FILE"
            write_log "info" "Request add node: $hostname add failed and skipped"
        fi
        write_log "$logLevel" "Add ${node_type} node $node_name failed: \n$(cat $TMP_FOLDER/cdf-add-node-$hostname.log)"
    fi
}

generateAddNodeCli(){
    local name=$1
    local node_obj="$(cat $CONFIG_FILE|$JQ -r ".workerNodes[]|select(.hostname==\"$name\")")"
    local options=""
    for pk in $(echo "
                --flannel-iface:flannelIface
                --key:privateKey
                --key-pass:privateKeyPassword
                --node:hostname
                --node-pass:password
                --node-user:user
                --skip-res-check:skipResourceCheck
                --skip-warning:skipWarning
                "|xargs)
    do
        local option="${pk%:*}"
        local key="${pk#*:}"
        local has_key=$(echo "$node_obj"|$JQ "has(\"$key\")")
        local val=""
        if [[ "$has_key" == "true" ]];then
            val="$(echo "$node_obj"|$JQ -r ".${key} // empty")"
            if [[ -n "$val" ]];then
                if [[ "$key" == "password" ]] || [[ "$key" == "privateKeyPassword" ]];then
                    val="******"
                fi
            fi
        fi
        if [[ "$has_key" != "true" ]] || [[ -z "$val" ]];then
            local gobal_key=""
            gobal_key="node$(echo "${key:0:1}"|tr '[:lower:]' '[:upper:]')${key:1}"
            val="$(cat $CONFIG_FILE|$JQ -r ".${gobal_key} // empty")"
            if [[ -n "$val" ]];then
                if [[ "$key" == "password" ]] || [[ "$key" == "privateKeyPassword" ]];then
                    val="******"
                fi
            fi
        fi
        if [[ "$option" == "--skip-warning" ]];then
            if [[ -z "$val" ]];then
                val=$CLI_SKIP_PRECHECK_WARNING
            fi
            if [ -f "$CDF_INSTALL_RUNTIME_HOME/user_confirm_skip_precheck_warning_$name" ];then
                write_log "debug" "node: $name, user confirm skip precheck warnings"
                val=true
            fi
            if [[ -z "$val" ]];then
                val=false
            fi
        fi
        if [[ -n "$val" ]];then
            options="$options $option '$val'"
        fi
    done
    exec_cmd "echo \"cdfctl node add --node-type worker $options --follow ;\"" -p=true
}

checkGetNodesStatus(){
    local status_json="$1"
    local error_log="$TMP_FOLDER/cdf-node-status-error.log"
    local waitSeconds=0
    exec_cmd "$RM -f $status_json"
    while true;do
        exec_cmd "$CDF_HOME/bin/cdfctl node status 1>$status_json 2>$error_log"
        if [ $? -eq 0 ];then
            exec_cmd "cat $status_json"
            break
        fi
        if [ "$waitSeconds" -lt 120 ]; then
            waitSeconds=$(( waitSeconds + 10 ))
            sleep 10
        else
            write_log "fatal" "Check nodes: $(cat $error_log)."
        fi
    done
}

launchExtendByCmd(){
    write_log "loading" "Request adding nodes >>>>"
    local status_json="$TMP_FOLDER/cdf_status.json"
    checkGetNodesStatus "$status_json"

    for node_type in master worker;do
        local num="$(cat $CONFIG_FILE|$JQ -r ".${node_type}Nodes|length")"
        local n=0
        for (( n=0; n<num; n++));do
            local name="$(cat $CONFIG_FILE|$JQ -r ".${node_type}Nodes[$n].hostname"|tr '[:upper:]' '[:lower:]')"
            if [[ "$SKIP_FAILED_WORKER_NODE" == "true" ]] && [[ "${node_type}" == "worker" ]];then
                # skip precheck failed worker nodes
                if exec_cmd "grep -iq "^$name\$" $SKIP_FAILED_WORKER_NODES_FILE";then
                    continue
                fi
            fi
            local status="$(cat $status_json|$JQ -r ".[]|select(.name==\"$name\").status")"
            if [[ -z "$status" ]] || [[ "$status" == "null" ]];then
                write_log "info" " $(echo "$node_type"|sed 's/master/control plane/'): $name"
                cmdAddNode "$node_type" "$(cat $CONFIG_FILE|$JQ -r ".${node_type}Nodes[$n]")"
            fi
        done
    done
}

precheckNodeByCmd(){
    local node_name=$1
    local node_type=worker
    local obj=
    write_log "loading" "Pre-checking node: ${node_name} ..."
    obj=$(cat $CONFIG_FILE|$JQ -r ".workerNodes[]|select(.hostname==\"$node_name\")")
    if [[ -z "$obj" ]];then
        node_type=master
        obj=$(cat $CONFIG_FILE|$JQ -r ".masterNodes[]|select(.hostname==\"$node_name\")")
    fi
    if [[ -z "$obj" ]];then
        write_log "fatal" "No such node ($node_name) in $CONFIG_FILE."
    fi

    cmdPrecheckNode "$node_type" "$obj"
}

nodeExtendStatusByCmd(){
    local retry_count="${1:-5}"
    write_log "loading" "Check nodes >>>>"
    local master_nodes="$(cat $CONFIG_FILE|$JQ -r '.masterNodes[].hostname'|xargs|tr '[:upper:]' '[:lower:]')"

    local worker_nodes=""
    local config_worker_nodes="$(cat $CONFIG_FILE|$JQ -r '.workerNodes[].hostname'|xargs|tr '[:upper:]' '[:lower:]')"
    if [[ "$SKIP_FAILED_WORKER_NODE" == "true" ]];then
        # remove failed worker nodes in check_nodes
        for name in $config_worker_nodes;do
            if ! exec_cmd "grep -iq "^$name\$" $SKIP_FAILED_WORKER_NODES_FILE";then
                worker_nodes="$worker_nodes $name"
            fi
        done
    else
        worker_nodes="$config_worker_nodes"
    fi

    local check_nodes="$(echo "$master_nodes $worker_nodes"|xargs)"
    local error_nodes=""
    local status_json="$TMP_FOLDER/cdf_status.json"
    while true;do
        checkGetNodesStatus "$status_json"

        for name in $check_nodes;do
            local status="$(cat $status_json|$JQ -r ".[]|select(.name==\"$name\").status")"
            if [[ "$status" == "finished" ]];then
                # remove node from check_nodes
                check_nodes="$(echo "$check_nodes"|xargs -n1|awk -v n="$name" '$0 != n'|xargs)"
                write_log "info" ">> Host : $name "
                write_log "info" " Status : Finished "
            elif [[ "$status" == "error" ]];then
                # remove node from check_nodes
                check_nodes="$(echo "$check_nodes"|xargs -n1|awk -v n="$name" '$0 != n'|xargs)"
                # add node to error_nodes
                error_nodes="$(echo "$error_nodes $name"|xargs)"
                write_log "info" ">> Host : $name "
                write_log "info" " Status : Error "
            else #[[ "$status" == "wait" ]]
                write_log "infolog" "Wait $name ..."
                sleep 60
                continue
            fi
        done
        if [[ -z "$check_nodes" ]];then
            break
        fi
    done

    if [[ -n "$error_nodes" ]];then
        if [[ "${retry_count}" -gt 0 ]];then
            retry_count=$((retry_count-1))
            for name in $error_nodes;do
                write_log "loading" "Retry: $name ..."
                local type="$(cat $status_json|$JQ -r ".[]|select(.name==\"$name\").type")"
                local obj="$(cat $CONFIG_FILE|$JQ -r ".${type}Nodes[]|select(.hostname==\"$name\")")"
                cmdAddNode "$type" "$obj"
            done
            nodeExtendStatusByCmd "${retry_count}"
        else
            local logLevel="fatal"
            if [[ "$SKIP_FAILED_WORKER_NODE" == "true" ]];then
                # if just exist failed worker nodes, skip it
                local existFailedMaster=false
                for name in $error_nodes;do
                    local type="$(cat $status_json|$JQ -r ".[]|select(.name==\"$name\").type")"
                    if [[ "$type" == "master" ]];then
                        existFailedMaster=true
                        break
                    fi
                done
                if [[ "$existFailedMaster" == "false" ]];then
                    # skip failed worker nodes
                    logLevel="infolog"
                fi
            fi
            write_log "$logLevel" "Add nodes failed: $error_nodes."
        fi
    fi
}

addWorkerLabelByCmd(){
    local nodes="$(exec_cmd "kubectl get nodes --no-headers 2>/dev/null|awk '\$3 ~ \"(^|,)control-plane(,|\$)\"{print \$1}'|xargs" -p=true)"
    for node_name in $nodes;do
        exec_cmd "kubectl patch node $node_name -p '{\"metadata\":{\"labels\":{\"Worker\":\"label\",\"node-role.kubernetes.io/worker\":\"true\"}}}'"
        if [[ $? -ne 0 ]];then
            write_log "fatal" "Patch node $node_name labels error."
        fi
    done
}

updateKeepalived(){
    write_log "loading" "Scale KeepAlived ..."
    local yaml=$CDF_HOME/objectdefs/keepalived.yaml
    local yaml_update=$CDF_HOME/objectdefs/keepalived-update.yaml
    exec_cmd "sed -r -e 's#kubernetes.io/hostname:.*#$MASTER_NODELABEL_KEY: \"$MASTER_NODELABEL_VAL\"#' $yaml > $yaml_update"
    if [ $? -ne 0 ];then
        write_log "fatal" "Replace keepalived nodeSelector error."
    fi
    local reTryTimes=0
    while [ $(exec_cmd "${CDF_HOME}/bin/kubectl replace -f ${yaml_update}" -p=false; echo $? ) -ne 0 ]; do
        reTryTimes=$(( $reTryTimes + 1 ))
        if [ ${reTryTimes} -eq ${RETRY_TIMES} ]; then
            write_log "fatal" "Failed to update keepalived nodeSelector."
        fi
        sleep 5
    done
    write_log "infolog" "Successfully updated keepalived nodeSelector"
}

waitKeepalived(){
    local componentName="itom-cdf-keepalived"
    local reTryTimes=0
    while true;
    do
        local status=$(exec_cmd "${CDF_HOME}/bin/kubectl get ds $componentName -n kube-system -o jsonpath={.status} 2>/dev/null" -p=true)
        local desiredNumberScheduled=$(echo "$status"|$JQ -r '.desiredNumberScheduled')
        local currentNumberScheduled=$(echo "$status"|$JQ -r '.currentNumberScheduled')
        local numberReady=$(echo "$status"|$JQ -r '.numberReady')
        local updatedNumberScheduled=$(echo "$status"|$JQ -r '.updatedNumberScheduled + 0')
        local numberAvailable=$(echo "$status"|$JQ -r '.numberAvailable')
        local numberUnavailable=$(echo "$status"|$JQ -r '.numberUnavailable + 0')
        if [ "$desiredNumberScheduled" = "$currentNumberScheduled" -a "$desiredNumberScheduled" = "$numberReady" -a "$desiredNumberScheduled" = "$updatedNumberScheduled" -a "$desiredNumberScheduled" = "$numberAvailable" -a "$numberUnavailable" -eq 0 ]; then
            write_log "infolog" "$componentName is ready."
            break
        else
            reTryTimes=$(( $reTryTimes + 1 ))
            if [ $reTryTimes -ge 60 ]; then
                write_log "fatal" "Failed to start up $componentName."
            else
                write_log "infolog" "Failed to start up $componentName. Wait for 5 seconds and retry: $reTryTimes"
            fi
        fi
        sleep 5
    done
}

checkKeepalived(){
    if [ "$INSTALLED_TYPE" = "CLASSIC" ] && [ -n "${HA_VIRTUAL_IP}" ] &&  [ -f "$CDF_HOME/objectdefs/keepalived.yaml" ];then
        local master_num
        master_num="$(exec_cmd "kubectl get nodes --no-headers -l $MASTER_NODELABEL_KEY|wc -l" -p=true)"
        if [[ $? -eq 0 ]] && [[ "$master_num" == 3 ]];then
            record_step "Scale KeepAlived ..." \
            updateKeepalived

            waitKeepalived
        fi
    fi
}

addMasterTaint(){
    if [[ "$ALLOW_WORKLOAD_ON_MASTER" == "true" ]];then
        return
    fi
    exec_cmd "${CDF_HOME}/bin/kubectl taint node -l $MASTER_NODELABEL_KEY $TAINT_MASTER_KEY:NoSchedule --overwrite"
    if [ $? -ne 0 ]; then
        write_log "fatal" "Failed to taint control plane nodes. $LOG_SUPPORT_MSG" "failed"
    fi
}

extendNodesByCmd(){
    launchExtendByCmd

    nodeExtendStatusByCmd

    if [ "$ALLOW_WORKLOAD_ON_MASTER" = "true" ]; then
        record_step "Adding worker label on control plane nodes ..." \
        addWorkerLabelByCmd
    fi
}

extendNodes(){
    if [ "$CAPS_DEPLOYMENT_MANAGEMENT" == "true" ] && [ -n "$METADATA" ];then
        extendNodesByApi
    else
        extendNodesByCmd
    fi

    record_step "Update the taints on control plane nodes ..." \
    addMasterTaint
}

precheckNode(){
    local node_name=$1
    if [ "$CAPS_DEPLOYMENT_MANAGEMENT" == "true" ] && [ -n "$METADATA" ];then
        precheckNodeByApi "$node_name"
    else
        precheckNodeByCmd "$node_name"
    fi
}

firstTimeInstallSuite(){
    installSuite
}

deploySuite(){
    firstTimeInstallSuite

    checkSuiteDeployStatus 3
}

########## Function END ##########

while [ ! -z $1 ]; do
    case "$1" in
      -c|--config )
        case "$2" in
          -*) echo -e "\n>>> [Error] -c|--config parameter requires a value. \n"; usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -c|--config parameter requires a value.\n"; usage; elif [ ! -f "$2" ];then echo -e "\n>>> [Error] The file $2 you specified does not exist\n"; usage; fi;CONFIG_FILE="$2";shift 2;;
        esac ;;
      -e|--end-state )
        case "$2" in
          -*) echo -e "[Error] -e|--end-state parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -e|--end-state parameter requires a value.\n"; usage; fi;END_STATE="$2";shift 2;;
        esac ;;
      -E|--external-rep ) EXTERNAL_REPOSITORY="true"; shift;;
      -h|--help ) usage;;
      -p|--password )
        case "$2" in
          -*) echo -e "\n>>> [Error] -P|--password parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -P|--password parameter requires a value.\n";usage; fi;SUPER_USERPWD="$2";shift 2;;
        esac ;;
      --uid )
        case "$2" in
          -*) echo -e "\n>>> [Error] --uid parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] --uid parameter requires a value.\n";usage; fi;SYSTEM_USER_ID="$2";shift 2;;
        esac ;;
      --gid )
        case "$2" in
          -*) echo -e "\n>>> [Error] --gid parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] --gid parameter requires a value.\n";usage; fi;SYSTEM_GROUP_ID="$2";shift 2;;
        esac ;;
      -t|--timeout )
        case "$2" in
          -*) echo -e "\n>>> [Error] -o|--timeout parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -o|--timeout parameter requires a value.\n";usage; fi;CLI_TIMEOUT_MINUTES="$2";shift 2;;
        esac ;;
      -m|--metadata )
        case "$2" in
          -*) echo -e "\n>>> [Error] -m|--metadata parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -m|--metadata parameter requires a value.\n";usage; fi;METADATA="$2";shift 2;;
        esac ;;
      -d|--deployment )
        case "$2" in
          -*) echo -e "\n>>> [Error] -d|--deployment parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -d|--deployment parameter requires a value.\n";usage; fi;DEPLOYMENT_NAME="$2";shift 2;;
        esac ;;
      -i|--image-folder )
        case "$2" in
          -*) echo -e "\n>>> [Error] -i|--image-folder parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -i|--image-folder parameter requires a value.\n"; usage; fi;IMAGE_FOLDER="$2";shift 2;;
        esac ;;
      -L|--lifecycle )
        case "$2" in
          -*) echo -e "\n>>> [Error] -L|--lifecycle parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -L|--lifecycle parameter requires a value.\n"; usage; fi;LIFE_CYCLE="$2";shift 2;;
        esac ;;
      -T|--installed-type )
        case "$2" in
          -*) echo -e "\n>>> [Error] -T|--installed-type parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -T|--installed-type parameter requires a value.\n"; usage; fi;INSTALLED_TYPE="$2";shift 2;;
        esac ;;
      -U|--registry-username )
        case "$2" in
          -*) echo -e "\n>>> [Error] -U|--registry-username parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -U|--registry-username parameter requires a value.\n"; usage; fi;REGISTRY_USERNAME="$2";shift 2;;
        esac ;;
      -P|--registry-password )
        case "$2" in
          -*) echo -e "\n>>> [Error] -P|--registry-password parameter requires a value. \n";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -P|--registry-password parameter requires a value.\n"; usage; fi;REGISTRY_PASSWORD="$2";shift 2;;
        esac ;;
      -u|--username )
        case "$2" in
          -*) echo -e "\n>>> [Error] -u|--username parameter requires a value";usage;;
          * ) if [ -z "$2" ];then echo -e "\n>>> [Error] -u|--username parameter requires a value";usage; fi; SUPER_USER="$2";shift 2;;
        esac ;;
      *)  echo -e "\n>>> [Error] Invalid parameter: $1 \n"; usage ;;
    esac
done

if [ "$INSTALLED_TYPE" != "CLASSIC" -a "$INSTALLED_TYPE" != "BYOK" ];then
    echo -e "\n>>> [Error] -T|--installed-type parameter requires a value, allowable value: CLASSIC/BYOK."
    usage
fi

#MAIN#
LIFE_CYCLE=${LIFE_CYCLE:-"install"}

if [ "$INSTALLED_TYPE" = "CLASSIC" ];then
    if [[ -f /etc/profile.d/itom-cdf.sh ]];then
        source /etc/profile.d/itom-cdf.sh 2>/dev/null
    fi
    source ${CDF_HOME}/bin/env.sh
    kubectl=${CDF_HOME}/bin/kubectl
else
    if [[ -f $HOME/itom-cdf.sh ]];then
        source $HOME/itom-cdf.sh 2>/dev/null
    fi
    kubectl=kubectl
fi
JQ=$CDF_HOME/bin/jq
LOGDIR=$CDF_HOME/log/silent-${LIFE_CYCLE}
LOG_FILE_TIMESTAMP="${LOG_FILE_TIMESTAMP:-"$(date "+%Y%m%d%H%M%S")"}"
LOGFILE="$LOGDIR/silent-${LIFE_CYCLE}.${LOG_FILE_TIMESTAMP}.log"
/bin/mkdir -p $LOGDIR

if [ "$LIFE_CYCLE" = "install" ]; then
    preSteps
    if [ "$CAPS_SUITE_DEPLOYMENT_MANAGEMENT" == "true" ];then
        waitCdfApiServerReady
        preCheckSilentConfig
        getDeployment
        collectInfo
        preUploadImages
        # helm: Don't need to call uploadImages, checkImagesInExtRep, deployFullCdf
        if [ "$INSTALLED_TYPE" = "CLASSIC" -a -z "$EXTERNAL_REPOSITORY" ];then
            record_step "Uploading images under $IMAGE_FOLDER to local registry..." \
            uploadImages
        fi
        skipImagesCheck
        setDeploymentStatus
    else
        record_step "Pre-checking all nodes ..." \
        precheckAllNodes
    fi

    if [ "$INSTALLED_TYPE" = "CLASSIC" ];then
        extendNodes
    fi
    if [ "$CAPS_SUITE_DEPLOYMENT_MANAGEMENT" == "true" ];then
        startDeployerJob
        deployFullCdf
    fi

    if [ "$END_STATE" = "suite" ]; then
        deploySuite
    else
        checkKeepalived
    fi
    finalize
elif [ "$LIFE_CYCLE" = "reconfig" -o "$LIFE_CYCLE" = "update" ]; then
    preSteps
    getDeploymentUuid
    skipImagesCheck
    if [ "$LIFE_CYCLE" = "reconfig" ]; then
        suiteReconfig
        checkSuiteReconfig
    elif [ "$LIFE_CYCLE" = "update" ]; then
        record_step "# Creating deployment json ..." \
        createDeploymentJson

        record_step "$MSG_UPDATE_CHECK_TYPE"  \
        getSuiteUpdateType

        source "$PREVIOUS_INSTALL_CONFIG"
        if [[ -z "$UPDATE_TYPE" ]];then
            write_log "fatal" "Failed to get update type."
        fi
        if [ "$UPDATE_TYPE" = "simple" ]; then
            record_step "$MSG_SIMPLE_UPDATE_START" \
            simpleUpdateImages

            record_step "# Updating suite version ..." \
            updateSuiteVersion
        elif [ "$UPDATE_TYPE" = "complex" ]; then
            record_step "# Change components status ..." \
            changeComponentsStatus

            record_step "$MSG_COMPLEX_DEPLOYER_START" \
            launchDeployerForUpgrade

            record_step "$MSG_COMPLEX_UPGRADE_POD_START" \
            startUpgradePod

            record_step "# Checking upgrade pod status ..." \
            getUpgradePodStatus

            record_step "# Get and checking suite upgrade pod status ..." \
            checkSuiteUpdatePodStatus

            record_step "# Launching suite complex update ..." \
            launchComplexUpdate
        fi
        finalize
    fi
fi
