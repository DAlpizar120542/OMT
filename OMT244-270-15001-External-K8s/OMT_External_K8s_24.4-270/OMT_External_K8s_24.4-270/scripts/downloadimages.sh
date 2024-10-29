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

usage() {
    echo "Usage: ./downloadimages.sh [-y|--yes] [-u|--user <username>] [-p|--pass <password>] [-r|--registry <registry-url>] [-c|--content-trust <on/off>] [-t|--retry <retry times>] "
    echo "       -y|--yes            Answer yes for any confirmations."
    echo "       -d|--dir            Suite images tar directory path (The default value is /var/opt/cdf/offline)."
    echo "       -u|--user           Registry host account username."
    echo "       -p|--pass           Registry host account password. Wrap the 'password' in single quotes."
    echo "       -P|--pass-cmd       Command to get and refresh short term password.Wrap the password with single quotes"
    echo "       -f|--key-file       Key file registry host account."
    echo "       -r|--registry       The host name of the registry that you want to pull suite images from."
    echo "       -n|--notary-url     Notary url to check the image signature."
    echo "       -c|--content-trust  Use \"on/off\" to enable/disable content trust."
    echo "       -C|--config         Path of user specified \"image-set.json\", use it multiple times to specify multiple files."
    echo "       -t|--retry          The retry times when the image download fails."
    echo "       -o|--organization   Organization name of the registry the images will be download from."
    echo "       --auth              Use AUTH_STRING for accessing the registry. AUTH_STRING is a base64 encoded 'USERNAME[:PASSWORD]'. "
    echo "       --insecure          Skip SSL certificate validation. "
    echo "       --skip-verify       Skip SSL certificate validation(deprecated). "
    echo "       --cacert            Path to registry CA."
    echo "       -h|--help           Show help."
    exit 1
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
checkParm(){
    local key=$1
    local val=$2
    case "$key" in
        -c|--content-trust)
            local valInLower=$(echo "$val" | tr [:upper:] [:lower:])
            if [ "$valInLower" != "on" ] && [ "$valInLower" != "off" ];then
                echo "Invalid value for $key: $val, allowed value: \"on\",\"off\""; exit 1
            fi
            ;;
    esac
}

while [[ ! -z $1 ]] ; do
    step=2 ##shift step,default 2
    case "$1" in
        -y|--yes)               CONFIRM=true; step=1;;
        --insecure|--skip-verify) SKIP_VERIFY=true; step=1;;      #for debugging
        --debug-on)             DEBUG_ON="true";step=1;;
        -u|--user)              setOptionVal "$1" "$2" "USER_NAME";;
        -P|--pass-cmd)          setOptionVal "$1" "$2" "PASSWORD_CMD";;
        -r|--registry)          setOptionVal "$1" "$2" "REGISTRY_BASE";;
        -n|--notary-url)        setOptionVal "$1" "$2" "NOTARY_SERVER";;
        -t|--retry)             setOptionVal "$1" "$2" "MAX_RETRY";;
        -d|--dir)               setOptionVal "$1" "$2" "IMAGE_BASE_DIR";;
        -f|--key-file)          setOptionVal "$1" "$2" "KEY_FILE";;
        -o|--organization)      setOptionVal "$1" "$2" "USER_ORG_NAME";;
        -c|--content-trust)     setOptionVal "$1" "$2" "CONTENT_TRUST";;
        --auth)                 setOptionVal "$1" "$2" "AUTH_STRING";;
        --cacert)               setOptionVal "$1" "$2" "REGITRY_CA";;
        -C|--config)
        case "$2" in
            -*) echo "-C|--config parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-C|--config parameter requires a value. " ; exit 1 ; fi ; USER_IMAGE_SET_FILE="$USER_IMAGE_SET_FILE $2" ; ;;
        esac ;;
        -p|--pass) #not using setOptionVal to support password contains special chars
        case "$2" in
            -*) echo "-p|--pass parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-p|--pass parameter requires a value. " ; exit 1 ; fi ; PASSWORD=$2 ; ;;
        esac ;;
        *|-*|-h|--help|/?|help) usage ;;
    esac
    if [[ $step -eq 2 ]];then
        checkParm "$1" "$2"
    fi
    shift $step
done

readonly DEFAULT_IMAGE_BASE_DIR="/var/opt/cdf/offline"

AUTH_TYPE=""
AUTH_BASE=""
AUTH_SERVICE=""
NOTARY_AUTH=""
PID_ARRAY=""
SECURITY_OPT=""
NOPROXY_OPT=""
LAYER_FAIL_FILE=""
LOCK_FILE=""
LOG_FILE=""
LOG_FILE_NAME="downloadimages-`date "+%Y%m%d%H%M%S"`.log"

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export PATH=$PATH:$CURRENT_DIR:$CURRENT_DIR/../bin
if [ -n "$USER_IMAGE_SET_FILE" ];then
    IMAGE_SET_FILE=($USER_IMAGE_SET_FILE)
else
    IMAGE_SET_FILE=("${CURRENT_DIR}/image-set.json")
fi

MAX_RETRY=${MAX_RETRY:-"5"}
USER_NAME=${USER_NAME:-""}
PASSWORD=${PASSWORD:-""}
PASSWORD_CMD=${PASSWORD_CMD:-""}
CONFIRM=${CONFIRM:-"false"}
SKIP_VERIFY=${SKIP_VERIFY:-"false"}
CONTENT_TRUST=${CONTENT_TRUST:-"off"}
REGISTRY_BASE=${REGISTRY_BASE:-"https://registry-1.docker.io"}
IMAGE_BASE_DIR=${IMAGE_BASE_DIR:-"${DEFAULT_IMAGE_BASE_DIR}"}
NOTARY_SERVER=${NOTARY_SERVER:-"https://notary.docker.io"}
KEY_FILE=${KEY_FILE:-""}
DEBUG_ON=${DEBUG_ON:-"false"}
ROLLID=
DOWNLOAD_RESULT=0
USE_DEFAULT_IMAGE_FOLDER="false"

log() {
    if [ "$DEBUG_ON" == "false" ];then
        local level=$1
        local msg=$2
        local timestamp=$(date --rfc-3339='ns')
        timestamp=${timestamp:0:10}"T"${timestamp:11}
        case $level in
            debug) #debug level is dedicated for write to logfile,not to stdout
                echo -e "${timestamp} DEBUG $msg  " >> $LOG_FILE ;;
            debugln) #in case when log "begin" is used, the next line is often concated, use this "debugln" to avoid
                echo -e "\n${timestamp} DEBUG $msg  " >> $LOG_FILE ;;
            info|warn|error)
                echo -e "$msg" && echo -e "${timestamp} `echo $level|tr [:lower:] [:upper:]` $msg  " >> $LOG_FILE ;;
            begin)
                echo -e "$msg\c"
                echo -e "${timestamp} INFO $msg \c" >> $LOG_FILE ;;
            end)
                echo "$msg"
                echo "$msg" >> $LOG_FILE ;;
            fatal)
                echo -e "$timestamp FATAL $msg  " && echo "$timestamp FATAL $msg" >>$LOG_FILE
                echo "Please refer $LOG_FILE for more details."
                exit 1
                ;;
            *)
                echo -e "$msg"
                echo -e "${timestamp} INFO $msg  " >> $LOG_FILE ;;
        esac
    fi
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
    if [ "$DEBUG_ON" == "false" ];then
        rolling &
        ROLLID=$!
    fi
}

stopRolling(){
    if [ "$DEBUG_ON" == "false" ];then
        if [[ -n $ROLLID ]];then
            echo -ne '\b'
            kill -s SIGTERM $ROLLID
            wait $ROLLID >/dev/null 2>&1
        else
            ROLLID=
        fi
    fi
}
releaseLockFile(){
    LOCK_FILE="${IMAGE_BASE_DIR}/.download-lock"     #refresh file path as the base dir may renamed
    if [[ -f "$LOCK_FILE" ]] && [[ "$(cat $LOCK_FILE)" = "$$" ]] ; then
        rm -f $LOCK_FILE
    fi
}
makeSingleton(){
    if [[ -f "$LOCK_FILE" ]] ; then
        log "error" "Error: one instance is already running and only one instance is allowed at a time. "
        log "error" "Check to see if another instance is running."
        log "fatal" "If the instance stops running, delete $LOCK_FILE file."
    else
        echo "$$" > $LOCK_FILE
    fi
}
getConcurrencyFactor(){
    local cpuNum=$(cat /proc/cpuinfo 2>/dev/null |grep "processor"|sort -u|wc -l)
    if [[ -z "${cpuNum}" ]] || [[ ${cpuNum} -eq 0 ]] ; then
        cpuNum=4
    fi
    #echo $((cpuNum/2))
    echo $cpuNum
}
shellSemInit(){
    local value=$1
    mkfifo mulfifo
    exec 1000<>mulfifo
    rm -rf mulfifo
    for ((n=1;n<=${value};n++))
    do
            echo >&1000
    done
}
shellSemWait(){
    read -u1000
}
shellSemPost(){
    echo >&1000
}
shellSemDestroy(){
    exec 1000>&-
    exec 1000<&-
}
killTasks(){
    for pid in ${PID_ARRAY[*]} ${ROLLID} ; do
        kill -s SIGTERM "$pid" 2>/dev/null
    done
}

taskClean(){
    killTasks
    releaseLockFile
    shellSemDestroy
    LAYER_FAIL_FILE="${IMAGE_BASE_DIR}/layer_fail.log" #refresh
    rm -f ${IMAGE_BASE_DIR}/*.tmp
    rm -f ${LAYER_FAIL_FILE}
}

readLoginInfo() {
    local retry_time=$1;shift
    local user_tmp=""
    local need_input_password="false"
    if [ -n "$AUTH_STRING" ];then
        read -s -r -p "Please input the AUTH_STRING for accessing the registry: " AUTH_STRING
    else
        if [ -z "$USER_NAME" ];then
            read -p "Username:" USER_NAME
            need_input_password="true"
        else
            if [[ $retry_time -gt 0 ]];then #user have provide username and password
                read -p "Username(${USER_NAME})" user_tmp
                if [ -n "$user_tmp" ];then  #use the name in ()
                    USER_NAME=$user_tmp
                fi
                need_input_password="true"
            fi
        fi

        if [ -z "$PASSWORD" ] || [ "$need_input_password" == "true" ];then
            read -s -r -p "Password:" PASSWORD
            echo ""
        fi
    fi
}
getRegistryIp(){
    local host=$1
    local ip

    ip=$(ping "$host" -c 1 | awk 'NR==1 {print $3}' | tr -d '() ')
    if [[ $? -eq 0 ]];then
        echo "$ip"
    else
        echo "host can't resolved"
    fi
}
contactRegistry(){
    local result=125 scheme="" token="" status_code="" http_resp="" host port ip outputHost

    if [[ "$REGISTRY_BASE" =~ "://" ]];then  #if user provide registry with http/https scheme, remove it
        REGISTRY_BASE=${REGISTRY_BASE#*://}
    fi
    HOST_PORT="$REGISTRY_BASE"
    host=${HOST_PORT%:*}
    port=${HOST_PORT##*:}
    ip=$(getRegistryIp $host)
    if [ "$host" == "$ip" ];then
        outputHost=$HOST_PORT
    else
        if [ -n "$port" ] && [[ "$port" =~ ^[0-9]+$ ]];then
            outputHost="$host[$ip]:$port"
        else
            outputHost="$host[$ip]"
        fi
    fi

    #step 1. intentify the protocal scheme
    for scheme in "https://" "http://" ; do
        http_resp=$(curl --connect-timeout 20 -s -w %{http_code} ${NOPROXY_OPT} ${SECURITY_OPT} ${scheme}${HOST_PORT}/v2/ 2>>$LOG_FILE)
        if [[ $? -eq 60 ]];then
            if [ -n "$REGISTRY_CA" ] || [ "$CONFIRM" == "true" ];then #if ca provided, and not certified, quit
                log "fatal" "CA certificate verify failed on registry server: $HOST_PORT"
            else
                log "warn" "CA certificate verify failed on registry server: $HOST_PORT"
                read -p "Continue to download images without TLS verify?(Y/N)" answer
                answer=$(echo "$answer" | tr [:upper:] [:lower:])
                case "$answer" in
                    y|yes ) SECURITY_OPT="$SECURITY_OPT -k ";;
                    n|no )  log "fatal" "User select to quit." ;;
                    * )     log "fatal" "Unknown input, quit";;
                esac
            fi
            http_resp=$(curl --connect-timeout 20 -s -w %{http_code} ${NOPROXY_OPT} ${SECURITY_OPT} ${scheme}${HOST_PORT}/v2/ 2>>$LOG_FILE)
        fi
        status_code=${http_resp:0-3}
        case "$status_code" in
            200)
                if [ $(echo -e "$http_resp" | grep "blocked" | wc -l) -ne 0 ];then #special handling for docker hub
                    continue
                else
                    log "info" "Contacting Registry: $outputHost ... [OK]"
                    AUTH_TYPE=""; AUTH_BASE=""; AUTH_SERVICE=""; result=0; break
                fi
                ;;
            401)
                http_resp=$(curl -s -I ${SECURITY_OPT} ${scheme}${HOST_PORT}/v2/)
                auth_info=$(echo "$http_resp" | grep "realm")
                AUTH_BASE=$(echo "$auth_info" | cut -d = -f2 | cut -d , -f1 | tr -d ["\" \r"])
                AUTH_TYPE=$(echo "$auth_info" | cut -d = -f1 | cut -d ' ' -f2)
                AUTH_SERVICE=$(echo "$auth_info" | awk -F, '{print $2}' | awk -F= '{print $2}' | tr -d ["\" \r"])
                AUTH_SERVICE=${AUTH_SERVICE// /%20} #escape space
                result=1
                break
                ;;
            *) ;;
        esac
    done
    REGISTRY_BASE=${scheme}${HOST_PORT}

    #step 2. check if the credential is correct
    if [[ $result -eq 1 ]];then
        for((i=0;i<$MAX_RETRY;i++));do
            log "begin" "Contacting Registry: $outputHost ... "
            startRolling
            token=$(getAuthToken "")
            status_code=$(curl -s -w %{http_code} ${SECURITY_OPT} -H "Authorization: $AUTH_TYPE $token" "$REGISTRY_BASE/v2/")
            status_code=${status_code:0-3}
            stopRolling
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

    if [[ $result -ne 0 ]];then
        log "fatal" "Failed to login to $outputHost, please make sure your user name, password and network/proxy configuration are correct."
    fi
}
validateImageSet(){
    #check if image-set is valid
    local tmpImage badFiles
    for imageFile in ${IMAGE_SET_FILE[@]}; do
        tmpImage=$(cat ${imageFile[@]} 2>>$LOG_FILE | jq -r '.images|.[]|.image' 2>/dev/null)
        if [ $? -ne 0 ];then
            badFiles="$badFiles $imageFile"
        fi
    done
    if [ -n "$badFiles" ];then
        log "fatal" "File(s): $badFiles is/are not (a) valid image-set json file(s)"
    fi

    local organization=$(cat ${IMAGE_SET_FILE[0]} 2>>$LOG_FILE | jq -r '.org_name?')
    if ([ -z "$organization" ] || [ "$organization" == "null" ]) && [ -z "$USER_ORG_NAME" ];then
        log "fatal" "user does not provide organization name with -o|--organization, and organization name is not found in image-set.json either."
    fi
    local images_array=$(cat ${IMAGE_SET_FILE[0]} 2>>$LOG_FILE | jq -r '.images?')
    local image_array_len
    if [ "$images_array" != "null" ];then
        image_array_len=$(cat ${IMAGE_SET_FILE[0]} 2>>$LOG_FILE | jq -r '.images|length')
    fi
    if [ "$images_array" == "null" ] || [ $image_array_len -eq 0 ];then
        log "info" "No image is required to be downloaded."
        exit 0
    fi
}

init(){
    local image_set_hash=$(sha256sum ${IMAGE_SET_FILE[0]} | cut -d ' ' -f 1)
    if [[ "$IMAGE_BASE_DIR" =~ "$DEFAULT_IMAGE_BASE_DIR" ]];then
        USE_DEFAULT_IMAGE_FOLDER="true"
        IMAGE_BASE_DIR="${IMAGE_BASE_DIR}/images_${image_set_hash}" #set base dir as :/<Base_dir>/images_<hash>/ if use default base dir
    fi
    LAYER_FAIL_FILE="${IMAGE_BASE_DIR}/layer_fail.log"
    LOCK_FILE="${IMAGE_BASE_DIR}/.download-lock"
    LOG_FILE="${IMAGE_BASE_DIR}/${LOG_FILE_NAME}"

    mkdir -p ${IMAGE_BASE_DIR} 2>/dev/null
    if [ $? -ne 0 ];then
        echo "Fatal: No permission to create folder: ${IMAGE_BASE_DIR}. Please specify other folder with option \"-d\" for image downloading."
        exit 1
    fi
    #suppose we will not download from local registry, curl should alway get ca from trust store implictly or from a ca file explictly
    if [ "$SKIP_VERIFY" == "true" ] && [ -n "$REGITRY_CA" ];then
        log "fatal" "--insecure,--skip-verify can not use with --cacert"
    fi
    if [ "$SKIP_VERIFY" == "true" ];then
        SECURITY_OPT=" -k "
    fi
    if [ -n "$REGITRY_CA" ];then
        SECURITY_OPT=" --cacert $REGITRY_CA "
    fi

    #check files and tools
    for file in ${IMAGE_SET_FILE[@]} ; do
        if [ ! -f "$file" ];then
            log "fatal" "$file not found"
        fi
    done
    for tool in jq curl notary ; do
        local res1=$( which $tool > /dev/null 2>& 1; echo $? )
        local res2=$( whereis $tool > /dev/null 2>& 1; echo $? )
        if [ $res1 -ne 0 ] && [ $res2 -ne 0 ]; then
            log "fatal" "$tool not found in PATH($PATH)"
        fi
    done
    validateImageSet
    makeSingleton
}

logBegin(){
    local index=$1
    local total=$2
    local org=$3
    local image=$4;

    PID_ARRAY="" #clear PID_ARRAY
    rm -rf $LAYER_FAIL_FILE
    if [ -z "$org" ];then
        log "begin" "Downloading image [${index}/${total}] ${HOST_PORT}/${image} ... "
    else
        log "begin" "Downloading image [${index}/${total}] ${HOST_PORT}/${org}/${image} ... "
    fi
    startRolling
}
logEnd(){
    local result=$1
    stopRolling
    log "end" "[$result]"
}
getOneImageDigest(){
    local repo=$1
    local reference=$2
    local prefix=${HOST_PORT}

    local success="false" prefix opt
    if [ "$HOST_PORT" == "registry-1.docker.io" ];then
        prefix="docker.io"
    else
        prefix=$HOST_PORT
    fi
    if [[ ! "$NOTARY_SERVER" =~ "://" ]];then
        NOTARY_SERVER="https://$NOTARY_SERVER"
    fi
    if [ -n "$REGITRY_CA" ];then
        opt=" --tlscacert $REGITRY_CA"
    fi

    log "debug" "notary lookup $opt -s $NOTARY_SERVER ${prefix}/${repo} $reference"
    local resp=$(notary lookup $opt -s $NOTARY_SERVER ${prefix}/${repo} $reference 2>>$LOG_FILE)
    log "debug" "notary resp:$resp"
    if [[ "$resp" =~ "sha256" ]];then
        log "debug" "notary lookup success"
        local digest=$(echo $resp | cut -d ' ' -f2)
        echo $digest
    else
        log "debug" "notary lookup failed"
        echo "failed"
    fi
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
            if [ -z "$USER_NAME" ];then
                AUTH_STRING=""
            else
                if [ -n "$PASSWORD" ];then
                    AUTH_STRING=$(echo -n "$USER_NAME:$PASSWORD" | base64 -w0)
                elif [ -n "$PASSWORD_CMD" ];then
                    AUTH_STRING=$(echo -n "$USER_NAME:$(eval ${PASSWORD_CMD})" | base64 -w0)
                elif [ -n "$KEY_FILE" ];then
                    AUTH_STRING=$(echo -n "$USER_NAME:$(cat $KEY_FILE)" | base64 -w0)
                else
                    AUTH_STRING=""
                fi
            fi
        fi

        if [ "$AUTH_TYPE" == "Basic" ]; then
            token=$AUTH_STRING
        else
            if [ -z "$AUTH_SERVICE" ];then
                if [ -z "$repo" ];then
                    query_string=""
                else
                    query_string="?scope=repository:${repo}:push,pull"
                fi
            else
                if [ -z "$repo" ];then
                    query_string="?service=${AUTH_SERVICE}"
                else
                    query_string="?service=${AUTH_SERVICE}&scope=repository:${repo}:push,pull"
                fi
            fi
            log "debug" "curl -s ${NOPROXY_OPT} ${SECURITY_OPT} ${AUTH_BASE}${query_string}"
            if [ -z "$AUTH_STRING" ];then
                token_resp=$(curl -s ${NOPROXY_OPT} ${SECURITY_OPT} ${AUTH_BASE}${query_string} 2>>$LOG_FILE)
            else
                token_resp=$(curl -s ${NOPROXY_OPT} ${SECURITY_OPT} -H "Authorization: Basic $AUTH_STRING" ${AUTH_BASE}${query_string} 2>>$LOG_FILE)
            fi
            if [[ $? -eq 60 ]];then
                log "fatal" "CA certificate verify failed on authentication server: $AUTH_BASE"
            fi
            token=$(echo "$token_resp" | jq -r '.token?')
            if [ "$token" == "null" ];then
                token=$(echo $token_resp | jq -r '.access_token?')
            fi
        fi
    fi
    echo  $token
}

#https://github.com/moby/moby/issues/33700
fetchBlob() {
    local repo="$1"
    local digest="$2"
    local token="$3"
    local targetFile="$4"
    log "debug" "Begin to download layer[image=$repo,digest=$digest]"

    local result=1 url="$REGISTRY_BASE/v2/$repo/blobs/sha256:$digest" auth headers
    for((i=0;i<$MAX_RETRY;i++)); do
        log "debug" "Download layer with command:curl -S -s ${SECURITY_OPT} -H \"Authorization: $AUTH_TYPE ***\" $url -o $targetFile"
        if [ -z "token" ];then
            headers="$(curl -S -s ${SECURITY_OPT} "$url" -o "$targetFile" -D- 2>>$LOG_FILE)"
        else
            headers="$(curl -S -s ${SECURITY_OPT} -H "Authorization: $AUTH_TYPE $token" "$url" -o "$targetFile" -D- 2>>$LOG_FILE)"
        fi
        if [ $? -eq 23 ];then
            shellSemPost
            return 23
        fi
        headers="$(echo "$headers" | tr -d '\r')";
        if grep -qE "HTTP/[0-9].* 3" <<<"$headers"; then
            rm -f "$targetFile"
            local redirect="$(echo "$headers" | awk -F ': ' 'tolower($1) == "location" { print $2; exit }')"
            log "debug" "Download layer[image=$image,digest=$digest]:redirect to url:$redirect"
            if [ -n "$redirect" ]; then
                log "debug" "Download layer with command:curl -fSL -s ${SECURITY_OPT} $redirect -o $targetFile"
                curl -fSL -s ${SECURITY_OPT} "$redirect" -o "$targetFile" 2>>$LOG_FILE
                if [ $? -eq 23 ];then
                    shellSemPost
                    return 23
                fi
            fi
        fi

        if [[ -f "$targetFile" ]];then #make sure the downloaded layer digest is correct
            local checksum=$(sha256sum $targetFile | cut -d ' ' -f 1)
            if [[ "$digest" =~ "$checksum" ]];then
                result=0
                break
            else
                log "debug" "Layer digest check for [image=$image,digest=$digest]: failed"
                rm -f $targetFile
            fi
        fi

        log "debug" "Download layer[image=$image,digest=$digest]:failed, retry in 2 seconds"
        sleep 2
    done

    if [[ $result -ne 0 ]];then
        log "debug" "Download layer[image=$image,digest=$digest]:failed"
        echo "$digest" >> $LAYER_FAIL_FILE
    else
        log "debug" "Download layer[image=$image,digest=$digest] OK"
    fi

    shellSemPost
    return $result
}

fetchManifest(){
    local repo=$1
    local reference=$2
    local token=$3

    log "debugln" "Begin to download manifest[repo=$repo,reference=$reference]"

    local url="$REGISTRY_BASE/v2/$repo/manifests/$reference" auth manifestJson
    log "debug" "Download manifest with command: curl -fsSL ${SECURITY_OPT} -H \"Authorization: $AUTH_TYPE ***\" -H \"Accept: application/vnd.docker.distribution.manifest.v2+json\" -H \"Accept: application/vnd.docker.distribution.manifest.list.v2+json\" -H \"Accept: application/vnd.docker.distribution.manifest.v1+json\" $url"
    if [ -z "$token" ];then
        manifestJson="$(curl -fsSL ${SECURITY_OPT} -w %{http_code} -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' -H 'Accept: application/vnd.docker.distribution.manifest.v1+json' "$url"  2>>$LOG_FILE)"
    else
        manifestJson="$(curl -fsSL ${SECURITY_OPT} -w %{http_code} -H "Authorization: $AUTH_TYPE $token" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' -H 'Accept: application/vnd.docker.distribution.manifest.v1+json' "$url"  2>>$LOG_FILE)"
    fi
    echo $manifestJson
}
#handle 'application/vnd.docker.distribution.manifest.v2+json' manifest
handleSingleManifestV2() {
    local repo="$1"
    local manifest="$2"
    local token="$3"
    local rc=
    log "debug" "handleSingleManifestV2"

    local digest outFile digestSizeArray
    shellSemInit $(getConcurrencyFactor)
    shellSemWait
    digest="$(echo "$manifest" | jq -r '.config.digest')"
    digest="${digest#*:}" # strip off "sha256:"
    outFile="${IMAGE_BASE_DIR}/$digest.json";
    fetchBlob "$repo" "$digest" "$token" "${outFile}"
    rc=$?
    if [[ "$rc" -ne 0 ]];then
        return $rc
    fi

    digestSizeArray=$(echo "$manifest" | jq -r '.layers[]|.digest + ":" + (.size|tostring)')
    for item in ${digestSizeArray}; do
        digest=$(echo $item | awk -F: '{print $2}')
        size=$(echo $item | awk -F: '{print $3}')
        outFile="${IMAGE_BASE_DIR}/$digest.tar.gz"
        if [ -f "$outFile" ]; then
            local fileSize=$(stat -c "%s" $outFile)
            if [[ $size -eq $fileSize ]];then
                log "debug" "Skipping existing layer: $digest"
                continue
            else
                log "debug" "Found currupted layer:$outFile,remove it and re-download"
                rm -rf $outFile
            fi
        fi
        shellSemWait
        if [ "$DEBUG_ON" == "false" ];then
            fetchBlob "$repo" "$digest" "$token" "$outFile" &
        else
            fetchBlob "$repo" "$digest" "$token" "$outFile"
        fi
        PID_ARRAY="${PID_ARRAY} $!"
    done
    if [ "$DEBUG_ON" == "false" ];then
        if [[ -n "$PID_ARRAY" ]];then
            for pid in $PID_ARRAY;do
                wait "$pid" >/dev/null 2>&1
                exitCode="$?"
                if [[ $exitCode -ne 0 ]];then
                    return $exitCode
                fi
            done
        fi
    fi

    if [[ $(cat ${LAYER_FAIL_FILE}   2>/dev/null | wc -l) -ne 0 ]]; then
        log "error" "Handling manifest[image=$image]: failed to download some layers"
        return 1
    fi
    return 0
}
generateManifestEntry(){
    local repoTags=$1
    local manifest=$2

    local configFile=$(echo "$manifest" | jq -r '.config.digest' | awk -F: '{print $2".json"}')
    local layerFiles=($(echo "$manifest" | jq -r '.layers[].digest' | awk -F: '{print $2".tar.gz"}' | xargs))
    local json="$(
        echo '{}' | jq -r '. + {
            Config: "'"$configFile"'",
            RepoTags: ["'"${repoTags#library\/}"'"],
            Layers: '"$(echo '[]' | jq -r ".$(for layerFile in "${layerFiles[@]}"; do echo " + [ \"$layerFile\" ]"; done)")"'
        }'
    )"
    local outFile="${IMAGE_BASE_DIR}/${repoTags//\//_}.tmp"
    echo "$json" > $outFile
}
pullOneImage(){
    local organization=$1
    local image=$2
    local index=$3
    local total=$4

    local i repo manifest token schemaVersion mediaType repoTag name reference ctResult
    logBegin "$index" "${total}" "$organization" "$image"
    name=${image%%[:@]*}
    reference=${image#*[:@]}
    if [ -z "$organization" ];then
        repo="$name"; repoTag=$image
    else
        repo="$organization/$name"; repoTag=$organization/$image
    fi

    if [ "$CONTENT_TRUST" == "on" ] ; then
        for((i=0;i<$MAX_RETRY;i++)); do
            if [ -z "$USER_NAME" ] || [ -z "$PASSWORD" ];then
                logEnd "No Credential for Content Trust"
                readLoginInfo "$i"
                logBegin "$index" "${total}" "$organization" "$image"
            fi
            export NOTARY_AUTH=$(echo "${USER_NAME}:${PASSWORD}" | base64)
            ctResult=$(getOneImageDigest "$repo" "$reference")
            unset NOTARY_AUTH
            if [ "$ctResult" == "failed" ] ; then
                sleep 1
            else
                break
            fi
        done
        if [ $i -ge $MAX_RETRY ];then
            logEnd "CONTENT TRUST FAILED"
            return 1
        fi
    fi

    for((i=0;i<$MAX_RETRY;i++));do
        token=$(getAuthToken "$repo")
        manifest=$(fetchManifest "$repo" "$reference" "$token")
        http_code=${manifest:0-3}
        case "$http_code" in
            401)
                logEnd "Unauthorized";
                #OCTCR19S1781638: normally we got credential when contacting registry, but if registry run into error state and ask for credential again
                #we should not ask user to input user/password if previously download annoymously
                if [ -n "$USER_NAME" ];then
                    readLoginInfo "$i";
                fi
                logBegin "$index" "${total}" "$organization" "$image"
                ;;
            404) logEnd "NOT FOUND"; return 2;;
            200) manifest=${manifest:0:-3}; echo "$manifest" >>$LOG_FILE; break;;
            *)   log "debug" "http code: $http_code";
                 log "debug" "sleep and retry...";
                 sleep 5 ;;
        esac
    done
    if [ $i -ge $MAX_RETRY ];then
        logEnd "Failed"; return 3
    fi
    schemaVersion="$(echo "$manifest" | jq -r '.schemaVersion?')"
    mediaType="$(echo "$manifest" | jq -r '.mediaType?')"
    if [ "$schemaVersion" != "2" ] || [ "$mediaType" != "application/vnd.docker.distribution.manifest.v2+json" ];then
        logEnd "Unsupport"
        log "error" "Pull image[org_name=$organization,image=$image,$index/$total]:schemaVersion=$schemaVersion, mediaType=$mediaType"
        return 3
    else
        local ec
        handleSingleManifestV2 "$repo" "$manifest" "$token"
        ec="$?"

        if [ $ec -ne 0 ];then
            logEnd  "Failed"
            return $ec
        fi

        generateManifestEntry "$repoTag" "$manifest"
        logEnd  "OK"
    fi
}

gatherManifestInfo(){ #in case when there are too many images jq will complaint of too many argument list,so not use jq here
    local index=1
    local file_cnt=$(ls $IMAGE_BASE_DIR/ | grep ".tmp" | wc -l)

    rm -f "${IMAGE_BASE_DIR}/manifest.json"
    echo  "[" >> ${IMAGE_BASE_DIR}/manifest.json
    for manif in `ls $IMAGE_BASE_DIR/ | grep ".tmp"`; do
        cat ${IMAGE_BASE_DIR}/$manif 2>/dev/null >>${IMAGE_BASE_DIR}/manifest.json
        if [[ $index -lt $file_cnt ]];then
            echo "," >>${IMAGE_BASE_DIR}/manifest.json
        fi
        ((index+=1))
    done
    echo  "]" >> ${IMAGE_BASE_DIR}/manifest.json
    ##when disk out of space, write will fail, and the return code can be used as an indicator for such error
    if [ $? -ne 0 ];then
        DOWNLOAD_RESULT=$?
    fi
}
diskConfirmation() {
    if [ "$CONFIRM" == "false" ]; then
        local answer
        log "info" "! Warning: Please check suite sizing documentation and make sure you have enough disk space for downloading suite images."
        read -p "Continue?[Y/N]?" answer
        case $answer in
            Y | y) ;;
            *) log "fatal" "User cancel the download,answer=$answer" ;;
        esac
    fi
}

pullImages() {
    local suite_name=$(cat ${IMAGE_SET_FILE[0]} 2>>$LOG_FILE | jq -r '.suite')
    local suite_version=$(cat ${IMAGE_SET_FILE[0]} 2>>$LOG_FILE | jq -r '.version')
    local organization=${USER_ORG_NAME:-$(cat ${IMAGE_SET_FILE[0]} 2>>$LOG_FILE | jq -r '.org_name')}
    if [ "$HOST_PORT" == "docker.io" ] && [ -z "$organization" ];then
        organization="library"
    fi
    local msgHead msgBody msgTail
    msgHead="Start downloading the images"
    if [ -n "$suite_name" ] && [ "$suite_name" != "null" ];then
        if [ -z "$suite_version" ]||[ "$suite_version" == "null" ];then
            msgBody="for ${suite_name}"
        else
            msgBody="for ${suite_name}-${suite_version}"
        fi
    fi
    msgTail="..."
    log "info" "${msgHead} ${msgBody} ${msgTail}"

    diskConfirmation

    local images total=0
    images=$(cat ${IMAGE_SET_FILE[@]} 2>>$LOG_FILE | jq -r '.images|.[]|.image' | sort -u | xargs)
    total=$(cat ${IMAGE_SET_FILE[@]} 2>>$LOG_FILE | jq -r '.images|.[]|.image' | sort -u | wc -l)
    local begin_time=$(date +%s)
    local index=1 result=0
    for im in ${images}; do
        pullOneImage "${organization}" "$im" "$index" "$total"
        result=$?
        if [ $result -ne 0 ];then
            if [ $result -eq 23 ];then
                log "fatal" "Write data failed. Please check filesystem disk space and filesystem permission!"
            else
                DOWNLOAD_RESULT=$result
            fi

        fi
        index=$((index+1))
    done
    gatherManifestInfo
    local end_time=$(date +%s)
    local cost_time=$(( ${end_time} - ${begin_time} ))
    log "info" "Download completed in ${cost_time} seconds."

    if [ "$DOWNLOAD_RESULT" -eq 0 ]; then
        log "info" "Download-process successfully completed."
        if [[ "$USE_DEFAULT_IMAGE_FOLDER" == "true" ]];then #when successfully finished, change images_<hash> to images_<timestamp>
            targetFolder="${DEFAULT_IMAGE_BASE_DIR}/images_$(date "+%Y%m%d%H%M%S")"
            mv ${IMAGE_BASE_DIR} $targetFolder
            IMAGE_BASE_DIR=$targetFolder
        fi
        msgHead="Successfully downloaded the images"
        msgTail="to $IMAGE_BASE_DIR."
    else
        log "info" "Download-process completed with errors."
        msgHead="Downloaded the images"
        msgTail="with errors."
    fi
    echo "${msgHead} ${msgBody} ${msgTail}"
    exit $DOWNLOAD_RESULT
}

#########  MAIN  #########
trap 'taskClean; exit' 1 2 3 8 9 14 15 EXIT
init
contactRegistry
pullImages