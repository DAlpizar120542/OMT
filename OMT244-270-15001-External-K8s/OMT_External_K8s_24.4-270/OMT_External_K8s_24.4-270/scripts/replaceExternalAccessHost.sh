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


###################################################################
#This script is for replacing EXTERNAL ACCESS HOST of CDF part only.
###################################################################

#see feature: OCTFT19S1761772
if [[ "bash" != "$(readlink /proc/$$/exe|xargs basename)" ]];then
    echo "Error: only bash support, current shell: $(readlink /proc/$$/exe)"
    exit 1
fi
set +o posix

CURRENTDIR=$(cd "$(dirname "$0")";pwd)
KUBE_NAMESPACE=kube-system
MAX_RETRY=200

if [[ -f "/etc/profile.d/itom-cdf.sh" ]];then
    source "/etc/profile.d/itom-cdf.sh"
else
    source $HOME/itom-cdf.sh
fi
KUBE_SYSTEM_NAMESPACE=${CDF_NAMESPACE:-"core"}
COMPONENTNAME=$(basename $0|cut -d'.' -f1)

CONFIRM="false"
SKIP_WARNING="false"
DNS_HOSTS_CM="dns-hosts-configmap"
if [ -e ${CDF_HOME}/images/infra-common-images.tgz ];then
    IS_BYOK="false"
    BIN_DIR=${CDF_HOME}/bin
    LOGDIR=$CDF_HOME/log/$COMPONENTNAME
else
    IS_BYOK="true"
    if [ -n "${CDF_HOME}" ];then
        BIN_DIR=${CDF_HOME}/bin
        LOGDIR=$CDF_HOME/log/$COMPONENTNAME
    else
        BIN_DIR=${CURRENTDIR}/../bin
        LOGDIR=${CURRENTDIR}
    fi
fi
JQ=${BIN_DIR}/jq
/bin/mkdir -p $LOGDIR
logfile=$LOGDIR/$COMPONENTNAME.`date "+%Y%m%d%H%M%S"`.log
flagfile=$LOGDIR/flagfile
API_RESULT="Failed"

usage(){
    echo "Usage: $0 [-c|--cert <path>] [-k|--key <path>] [-t|--cacert <path>] [-n|--host <hostname>]"
                echo "       -y|--yes         Answer yes for any confirmations."
                echo "       --skip-warning   Skip all warnings."
                echo "       -c|--cert        new certificate file."
                echo "       -k|--key         new private key file."
                echo "       -P|--keypass     pass phrase for private key file."
                echo "       -t|--cacert      new rootCA file."
                echo "       -n|--host        new external access host."
                echo "       -u|--user        administrator username."
                echo "       -p|--password    administrator password."
                echo "       -h|--help        show help."
    exit 1
}

if [ $# -lt 1  ]; then
    usage
fi

while [[ ! -z $1 ]] ; do
    case "$1" in
        -y|--yes)
            CONFIRM=true;shift 1;;
        --skip-warning)
            SKIP_WARNING=true;shift 1;;
        -c|--cert)
        case "$2" in
            -*) echo "-c|--cert parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-c|--cert parameter requires a value. " ; exit 1 ; fi ; NEW_SERVER_CERT_FILE=$2 ; shift 2 ;;
        esac ;;
        -k|--key)
        case "$2" in
            -*) echo "-k|--key parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-k|--key parameter requires a value. " ; exit 1 ; fi ; NEW_SERVER_KEY_FILE_TMP=$2 ; shift 2 ;;
        esac ;;
        -P|--keypass)
        case "$2" in
            -*) echo "-P|--keypass parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-P|--keypass parameter requires a value. " ; exit 1 ; fi ; NEW_SERVER_KEY_PASS=$2 ; shift 2 ;;
        esac ;;
        -t|--cacert)
        case "$2" in
            -*) echo "-t|--cacert parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-t|--cacert parameter requires a value. " ; exit 1 ; fi ; NEW_SERVER_CACERT_FILE=$2 ; shift 2 ;;
        esac ;;
        -n|--host)
        case "$2" in
            -*) echo "-n|--host parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-n|--host parameter requires a value. " ; exit 1 ; fi ; NEW_EXTERNAL_ACCESS_HOST=$2 ; shift 2 ;;
        esac ;;
        -u|--user)
        case "$2" in
            -*) echo "-u|--user parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-u|--user parameter requires a value. " ; exit 1 ; fi ; CDF_USERNAME=$2 ; shift 2 ;;
        esac ;;
        -p|--password)
        case "$2" in
            -*) echo "-p|--password parameter requires a value. " ; exit 1 ;;
            *)  if [[ -z $2 ]] ; then echo "-p|--password parameter requires a value. " ; exit 1 ; fi ; CDF_PASSWORD=$2 ; shift 2 ;;
        esac ;;
        *|-*|-h|--help|/?|help) usage ;;
    esac
done

logAndWait(){
    local msg=$1;shift
    INTERVAL=0.5
    RCOUNT="0"
    log "infonobr" "$msg ......"
    while :
    do
        if [[ -e ${flagfile} ]];then
            log "end" "$(cat ${flagfile})"
            if [ "Failed" == "$(cat ${flagfile})" ];then
              API_RESULT="Failed"
            fi
            break
        fi
        ((RCOUNT = RCOUNT + 1))
        case $RCOUNT in
            1) echo -e '-\b\c'
                sleep $INTERVAL
                ;;
            2) echo -e '\\\b\c'
                sleep $INTERVAL
                ;;
            3) echo -e '|\b\c'
                sleep $INTERVAL
                ;;
            4) echo -e '/\b\c'
                sleep $INTERVAL
                ;;
            *) RCOUNT=0
                ;;
        esac
    done
}
getRfcTime(){
    date --rfc-3339=ns|sed 's/ /T/'
}

CURRENT_PID=$$
spin(){
    local lost=
    local spinner="\\|/-"
    trap 'lost=true' SIGTERM
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
    echo -n " "
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
    local logTimeFmt=$(getRfcTime)
    if [[ -n "$CDF_LOADING_LAST_PID" ]] && [[ "$level" =~ ^(debug|info|loading|infonobr|end|warn|error|fatal)$ ]];then
        stopLoading
        echo -e " "
    fi
    case $level in
        debug)
            echo -e "[DEBUG] $consoleTimeFmt : $msg  " && echo "$logTimeFmt DEBUG $msg" >>$logfile ;;
        info)
            echo -e "[INFO] $consoleTimeFmt : $msg  " && echo "$logTimeFmt INFO  $msg" >>$logfile ;;
        loading)
            echo -n "[INFO] $consoleTimeFmt : $msg " && echo "$logTimeFmt INFO  $msg" >>$logfile
            startLoading
            ;;
        infonobr)
            echo -n "[INFO] $consoleTimeFmt : $msg " && echo "$logTimeFmt INFO  $msg" >>$logfile ;;
        end)
            echo "$msg" && echo "$msg" >> $logfile ;;
        infolog)
            echo "$logTimeFmt INFO  $msg" >>$logfile ;;
        error)
            echo -e "[ERROR] $consoleTimeFmt : $msg  " && echo "$logTimeFmt ERROR $msg" >>$logfile ;;
        warn)
            echo -e "[WARN] $consoleTimeFmt : $msg  " && echo "$logTimeFmt WARN  $msg" >>$logfile ;;
        warnlog)
            echo "$logTimeFmt WARN  $msg" >>$logfile ;;
        fatal)
            echo -e "[FATAL] $consoleTimeFmt : $msg  " && echo "$logTimeFmt FATAL $msg" >>$logfile
            echo -e "Please refer to $logfile for more details."
            exit 1;;
        *)
            echo -e "[INFO] $consoleTimeFmt : $msg  " && echo "$logTimeFmt INFO  $msg" >>$logfile ;;
    esac
}

check_file(){
    if [ ! -f "$1" ]; then
        log "fatal" "The path \"$1\" does not exist"
    fi
}

exec_cmd(){
    $BIN_DIR/cmd_wrapper -c "$1" -f $logfile -x=DEBUG $2 $3 $4 $5
    return $?
}

is_new_pod_ready(){
    local new_pods=$1;shift
    local old_pods=$1;shift
    new_pods=(${new_pods[@]})
    old_pods=(${old_pods[@]})
    local result=0
    local ready="false"

    for new_pod in ${new_pods[@]};do
        local index=0
        for old_pod in ${old_pods[@]};do
            if [ "$new_pod" == "$old_pod" ];then
                break
            fi
            index=$((index+1))
        done
        if [ $index -eq ${#old_pods[@]} ];then
            result=$((result+1))
        fi
        if [ $result -ne 0 ];then
            ready="true"
            break
        fi
    done
    echo "$ready"
}

update_cdf_apiserver(){
    log "loading" "update external access host through cdf-apiserver ..."
    CDF_APISERVER_NAME=$(kubectl get pods -n $KUBE_SYSTEM_NAMESPACE --sort-by=.metadata.creationTimestamp -l 'deployments.microfocus.com/component=itom-cdf-apiserver' -o json | $JQ -r '.items | .[-1].metadata.name')
    if [[ -f $NEW_SERVER_CERT_FILE ]] && [[ -f $NEW_SERVER_CACERT_FILE ]] && [[ -f $NEW_SERVER_KEY_FILE ]];then
        local cert_pem=$(sed -e '$a\' ${NEW_SERVER_CERT_FILE} ${NEW_SERVER_CACERT_FILE} | base64 -w 0)
        local key_pem=$(sed -e '$a\' ${NEW_SERVER_KEY_FILE} | base64 -w 0)
        local ca_pem=$(sed -e '$a\' ${NEW_SERVER_CACERT_FILE} | base64 -w 0)
        exec_cmd "kubectl exec $CDF_APISERVER_NAME --container cdf-apiserver -n $KUBE_SYSTEM_NAMESPACE -- /base_apiserver/scripts/replaceExternalAccessHost.sh -n $NEW_EXTERNAL_ACCESS_HOST -u $CDF_USERNAME -p '$(echo "$CDF_PASSWORD"|sed -e "s/'/'\\\\''/g")' -c $cert_pem -k $key_pem -t $ca_pem >>$logfile 2>/dev/null" -m=false
    else
        exec_cmd "kubectl exec $CDF_APISERVER_NAME --container cdf-apiserver -n $KUBE_SYSTEM_NAMESPACE -- /base_apiserver/scripts/replaceExternalAccessHost.sh -n $NEW_EXTERNAL_ACCESS_HOST -u $CDF_USERNAME -p '$(echo "$CDF_PASSWORD"|sed -e "s/'/'\\\\''/g")' >>$logfile 2>/dev/null" -m=false
    fi

    local apiCallResult=$?
    if [ $apiCallResult -eq 0 ];then
        API_RESULT="OK"
        log "info" "end to update external access host through cdf-apiserver ..."
    else
        log "fatal" "error when update external access host through cdf-apiserver"
    fi
}

patch_public_ca_certificate() {
    local patchfile=${CURRENTDIR}/$COMPONENTNAME.`date "+%Y%m%d%H%M%S"`.patch.yaml
    cat <<\EOF > ${patchfile}
data:
  CUS_ca.crt: |-
EOF
    sed -e '$a\' ${NEW_SERVER_CACERT_FILE} | sed 's/^/    /' >> ${patchfile}
    kubectl patch cm public-ca-certificates -n $KUBE_SYSTEM_NAMESPACE --patch-file ${patchfile}
    rm -f ${patchfile}
}

update_cdf_chart(){
    log "loading" "update external access host through charts ..."
    n=0
    i=0
    CMD=$(helm list -n ${KUBE_SYSTEM_NAMESPACE} -o json)
    HELM_NUM=$(echo "$CMD" | $JQ -r '.|length')
    while [[ $n -lt $HELM_NUM ]];
    do
        CHART_NAME=$(echo "$CMD" | $JQ -r ".[$n].chart")
        RESULT=$(echo "$CHART_NAME" | grep "apphub-")
        if [ "$RESULT" != "" ]; then
            RELEASE_NAME=$(echo "$CMD" | $JQ -r ".[$n].name")
            i=$((i+1))
            break
        fi
        n=$((n+1))
    done
    if [ $i -gt 1 ];then
        log "error" "Apphub chart exists more then 1"
        exit 1
    fi
    if [ -z "$RELEASE_NAME" ];then
        log "error" "Apphub chart doesn't exist!"
        exit 1
    fi
    if [ -e old_values.yaml ];then
        rm -f old_values.yaml
    fi
    CHART_FILE="$CDF_HOME/charts/$CHART_NAME.tgz"
    exec_cmd "helm get values -n '${KUBE_SYSTEM_NAMESPACE}' '${RELEASE_NAME}' >> old_values.yaml" -p true -m false
    exec_cmd "helm upgrade '$RELEASE_NAME' '$CHART_FILE' --debug --namespace '${KUBE_SYSTEM_NAMESPACE}' --values=old_values.yaml --set-string global.externalAccessHost='$NEW_EXTERNAL_ACCESS_HOST' --set-file frontendIngress.nginx.tls.cert='$NEW_SERVER_CERT_FILE' --set-file frontendIngress.nginx.tls.key='$NEW_SERVER_KEY_FILE' --set-file portalIngress.nginx.tls.cert='$NEW_SERVER_CERT_FILE' --set-file portalIngress.nginx.tls.key='$NEW_SERVER_KEY_FILE'" -p true -m false
    if [ -e old_values.yaml ];then
        rm -f old_values.yaml
    fi
    log "info" "end to update external access host through charts ..."
}

check_cdf_chart(){
    log "loading" "check Apphub chart ..."
    n=0
    i=0
    CMD=$(helm list -n ${KUBE_SYSTEM_NAMESPACE} -o json)
    HELM_NUM=$(echo "$CMD" | $JQ -r '.|length')
    while [[ $n -lt $HELM_NUM ]];
    do
        CHART_NAME=$(echo "$CMD" | $JQ -r ".[$n].chart")
        RESULT=$(echo "$CHART_NAME" | grep "apphub-")
        if [ "$RESULT" != "" ]; then
            RELEASE_NAME=$(echo "$CMD" | $JQ -r ".[$n].name")
            i=$((i+1))
            break
        fi
        n=$((n+1))
    done
    if [ $i -gt 1 ];then
        log "error" "Apphub chart exists more then 1, so you can not change FQDN!"
        exit 0
    fi
    if [ -z "$RELEASE_NAME" ];then
        log "error" "Apphub chart doesn't exist, so you can not change FQDN!"
        exit 0
    fi

    clusterManagement=$(helm get values -n ${KUBE_SYSTEM_NAMESPACE} $RELEASE_NAME -o json | $JQ -r '.tags.clusterManagement')
    deploymentManagement=$(helm get values -n ${KUBE_SYSTEM_NAMESPACE} $RELEASE_NAME -o json | $JQ -r '.tags.deploymentManagement')
    monitoring=$(helm get values -n ${KUBE_SYSTEM_NAMESPACE} $RELEASE_NAME -o json | $JQ -r '.tags.monitoring')

    if [ "$clusterManagement" = "false" ] && [ "$deploymentManagement" = "false" ] && [ "$monitoring" = "false" ];then
        log "error" "The external access is not enabled, so it is not supported to change FQDN!"
        exit 0
    fi

    log "info" "end to check Apphub chart ..."
}

main(){
    if [ "$CONFIRM" = "false" ] && [ -z "$NEW_SERVER_CERT_FILE" -o -z "$NEW_SERVER_KEY_FILE_TMP" -o -z "$NEW_SERVER_CACERT_FILE" ];then
        answer=""
        read -p "Certificate and key file are not provided, will replace the external access host with auto-generated certificate and key. Are you sure to continue? (Y/N):" answer
        answer=$(echo "$answer" | tr '[A-Z]' '[a-z]')
        if [ "$answer" != "y" -a "$answer" != "yes" ];then log "fatal" "QUIT."; fi
    fi

    if [ -n "$NEW_EXTERNAL_ACCESS_HOST" ];then
        NEW_EXTERNAL_ACCESS_HOST=$(echo "$NEW_EXTERNAL_ACCESS_HOST" | tr '[:upper:]' '[:lower:]')
        echo "NEW_EXTERNAL_ACCESS_HOST=$NEW_EXTERNAL_ACCESS_HOST"
    else
        echo "NEW_EXTERNAL_ACCESS_HOST should not be empty"
        exit 1
    fi
    [ -n "$NEW_SERVER_CERT_FILE" ]       && echo "NEW_SERVER_CERT_FILE=$NEW_SERVER_CERT_FILE" && check_file $NEW_SERVER_CERT_FILE
    [ -n "$NEW_SERVER_KEY_FILE_TMP" ]    && echo "NEW_SERVER_KEY_FILE=$NEW_SERVER_KEY_FILE_TMP" && check_file $NEW_SERVER_KEY_FILE_TMP
    [ -n "$NEW_SERVER_CACERT_FILE" ]     && echo "NEW_SERVER_CACERT_FILE=$NEW_SERVER_CACERT_FILE" && check_file $NEW_SERVER_CACERT_FILE

    if [ -n "$NEW_SERVER_KEY_FILE_TMP" ];then
        local tmp_key_folder pem_head encrypted max_input_retry=3
        pem_head=$(cat $NEW_SERVER_KEY_FILE_TMP | grep "BEGIN")
        if [ -z "$pem_head" ];then
            echo "Error: unsupported certificate/key format! The only supported format are: PKCS#1/#8"
            exit 1
        fi
        encrypted=$(cat $NEW_SERVER_KEY_FILE_TMP | grep -i "ENCRYPTED")
        if [ -z "$encrypted" ];then
            NEW_SERVER_KEY_FILE=$NEW_SERVER_KEY_FILE_TMP
        else
            for((i=0;i<$max_input_retry;i++));do
                if [ -z "$NEW_SERVER_KEY_PASS" ];then
                    echo -e "\nThe private key: $NEW_SERVER_KEY_FILE_TMP is passphrase protected."
                    read -s -r -p "Please input the passphrase: " NEW_SERVER_KEY_PASS
                    echo ""
                else
                    break
                fi
            done
            if [ -z "$NEW_SERVER_KEY_PASS" ];then
                echo "Error: Failed to get the passphrase for key: $NEW_SERVER_KEY_FILE_TMP"
                exit 1
            fi
            tmp_key_folder=$(mktemp -d)
            exec_cmd "openssl rsa -in $NEW_SERVER_KEY_FILE_TMP -out $tmp_key_folder/pkcs8.pem -passin '$(echo "pass:$NEW_SERVER_KEY_PASS"|sed -e "s/'/'\\\\''/g")'" -m=false
            if [ "$?" -ne 0 ];then
                echo "Error: Decrypt key file failed!"
                exit 1
            fi
            NEW_SERVER_KEY_FILE="$tmp_key_folder/pkcs8.pem"
            chmod 400 $NEW_SERVER_KEY_FILE
        fi
    fi

    if [ -n "$NEW_SERVER_CERT_FILE" -a -n "$NEW_SERVER_KEY_FILE" -a -n "$NEW_SERVER_CACERT_FILE" ];then
        exec_cmd "$CURRENTDIR/certCheck -ca $NEW_SERVER_CACERT_FILE -cert $NEW_SERVER_CERT_FILE -key $NEW_SERVER_KEY_FILE -host $NEW_EXTERNAL_ACCESS_HOST" -p=true
        local certCheckResult=$?
        if [ $certCheckResult -ne 0 ]; then
            if [ $certCheckResult -ne 41 ]; then
                log "fatal" "Failed to check cert. Please make sure certificate file, private key file, rootCA file and external access host are correct."
                exit 1
            else
                if [ "$SKIP_WARNING" = "false" ];then
                    local newServerCertCN=$(openssl x509 -noout -subject -in ${NEW_SERVER_CERT_FILE} | cut -d'=' -f3 | sed 's/ //g')
                    local newServerCertSAN=$(openssl x509 -noout -text -in ${NEW_SERVER_CERT_FILE} | grep -A1 'Subject Alternative Name' | tail -n1 | xargs -d',' -n1 | cut -d':' -f2 | sed '/^$/d' | sort | uniq | tr '\n' ',' | sed 's/,$//')
                    echo "FQDN ${NEW_EXTERNAL_ACCESS_HOST} is not matched with Subject ${newServerCertCN} or SubjectAlternativeName ${newServerCertSAN} in ${NEW_SERVER_CERT_FILE}.
It will cause errors except an application loadbalancer is setup in front of nginx-ingress-controller and the FQDN is resolved to the loadbalancer.
If you are sure about what you are doing, use --skip-warning option to supress this message."
                    log "fatal" "QUIT."
                else
                    log "warn" "FQDN ${NEW_EXTERNAL_ACCESS_HOST} is not matched with Subject ${newServerCertCN} or SubjectAlternativeName ${newServerCertSAN} in ${NEW_SERVER_CERT_FILE}.
It will cause errors except an application loadbalancer is setup in front of nginx-ingress-controller and the FQDN is resolved to the loadbalancer."
                    exec_cmd "$CURRENTDIR/renewCert --host $NEW_EXTERNAL_ACCESS_HOST --renew -t ingress --cacert $NEW_SERVER_CACERT_FILE --cert $NEW_SERVER_CERT_FILE --key $NEW_SERVER_KEY_FILE --skip-warning -y" -p=true
                fi
            fi
        else
            exec_cmd "$CURRENTDIR/renewCert --host $NEW_EXTERNAL_ACCESS_HOST --renew -t ingress --cacert $NEW_SERVER_CACERT_FILE --cert $NEW_SERVER_CERT_FILE --key $NEW_SERVER_KEY_FILE -y" -p=true
        fi
    fi

    if [ -z "$NEW_SERVER_CERT_FILE" -o -z "$NEW_SERVER_KEY_FILE" -o -z "$NEW_SERVER_CACERT_FILE" ];then
        log "loading" "Certificate and key file are not provided, so call renewCert script to renew the existing certificate and key."
        exec_cmd "$CURRENTDIR/renewCert --host $NEW_EXTERNAL_ACCESS_HOST --renew -t ingress -y" -p=true
        if [ "$?" != "0" ]; then
            log "fatal" "Failed to renew cert."
            exit 1
        fi
        log "info" "Renew the existing certificate and key successfully."
    fi

    CDF_APISERVER_NAME=$(kubectl get pods -n $KUBE_SYSTEM_NAMESPACE | grep 'cdf-apiserver' | awk '{print $1}')
    if [ -n "$CDF_APISERVER_NAME" ];then
        while [ -z "$CDF_USERNAME" ]; do read -p "Please input the administrator username: " CDF_USERNAME ; done
        while [ -z "$CDF_PASSWORD" ]; do read -s -r -p "Please input the administrator password: " CDF_PASSWORD ; echo "" ; done
        CDF_PASSWORD=$(echo ${CDF_PASSWORD} | tr -d '[:cntrl:]')
    fi

    if [ -e $flagfile ];then
        rm -f $flagfile
    fi

    check_cdf_chart

    if [ -n "$CDF_APISERVER_NAME" ];then
        update_cdf_apiserver
        if [ $API_RESULT != "Failed" ]; then
            update_cdf_chart
        fi
    else
        if [ -n "${NEW_SERVER_CACERT_FILE}" ];then
            patch_public_ca_certificate
        fi
        update_cdf_chart
    fi

    if [ "$IS_BYOK" == "false" ];then
        echo -e "[Note] If the Domain Name Service (DNS) isn't configured in your environment, you need to update the external access host to new one in key dns-hosts-key in $DNS_HOSTS_CM configmap.\n       Run the following command to edit the configmap file: kubectl edit cm $DNS_HOSTS_CM -n $KUBE_NAMESPACE"
    fi
    if [ -n "$NEW_SERVER_KEY_PASS" ];then
        rm -rf $tmp_key_folder
    fi
}

#MAIN
main
