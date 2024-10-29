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
CDF_HOME=${CDF_HOME:-"/opt/cdf"}
if [[ -f "${CDF_HOME}/bin/env.sh" ]]; then
    source ${CDF_HOME}/bin/env.sh
fi
currentDir=$(cd `dirname $0`;pwd)
BIN_DIR=$currentDir
LOG_FOLDER=${CDF_HOME}/log/deployment-status
mkdir -p ${LOG_FOLDER}
log_date=$(date "+%Y%m%d%H%M%S")
LOG_FILE=${LOG_FOLDER}/deployment-status_${log_date}.log
OUTPUT_LEN=75
ENABLE_ROLLING="true"
ROLLID=

if [[ -f "${CDF_HOME}/properties/images/images.properties" ]]; then
    source ${CDF_HOME}/properties/images/images.properties
fi
if [[ -f "${CDF_HOME}/properties/images/charts.properties" ]]; then
    source ${CDF_HOME}/properties/images/charts.properties
fi
SCRIPT_NAME="deployment-status.sh"
usage() {
    echo -e "Show the status of specified deployments or namespaces

    Usage: $SCRIPT_NAME [-n <namespaces> or -d <deployment names>]

    [Options]
      -n     Specify the comma delimited namespaces of deployment which you want to check.
      -d     Specify the comma delimited deployment names which you want to check.
      -h     Show help.

    [Examples]
      # Check the status of namespace: demo-xxx
        $SCRIPT_NAME -n demo-xxx
      # Check the status of namespaces: demo-xxx-1,demo-xxx-2
        $SCRIPT_NAME -n demo-xxx-1,demo-xxx-2
      # Check the status of deployment: foo and bar
        $SCRIPT_NAME -d foo-xxx,bar-xxx
"
}

while [ $# -gt 0 ];do
    case "$1" in
    -n)
        case "$2" in
          -*) err "-n option requires a value." ; exit 1 ;;
          *)  if [[ -z "$2" ]] ; then err "-n option needs to provide deployment namespace. " ; exit 1 ; fi ; DEPLOY_NAMESPACE=$2 ; shift 2 ;;
        esac ;;
    -d)
        case "$2" in
          -*) err "-d option requires a value." ; exit 1 ;;
          *)  if [[ -z "$2" ]] ; then err "-d option needs to provide deployment name. " ; exit 1 ; fi ; DEPLOY_NAME=$2 ; shift 2 ;;
        esac ;;
    ---disable-rolling) ENABLE_ROLLING="false";;
    -h) usage; exit 0;;
    *)
        err -e "The input parameter $1 is not a supported parameter or not used in a correct way. Please refer to the following usage.\n"
        usage; exit 1;;
    esac
done

taskClean(){
    kill -s SIGTERM "$pid" 2>/dev/null
}
#repeatly print $1 with $2 times
repl() { printf "$1"'%.s' $(eval "echo {1.."$(($2))"}"); }
MASK_REG_EXP="(?i)(sessionId|token|password)(\"?\s*[:=]\s*)[^',}\s]*"
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
    local consoleTimeFmt=$(date "+%Y-%m-%d %H:%M:%S")
    local logTimeFmt=$(getRfcTime)
    case $level in
        info)     echo -e "$consoleTimeFmt INFO $msg  " && echo "$logTimeFmt INFO $msg" >>$LOG_FILE ;;
        infolog)  echo "$logTimeFmt INFO $msg" >>$LOG_FILE ;;
        begin)    echo -e "$consoleTimeFmt INFO $msg\c" && uniformStepMsgLen "${#msg}" && echo -e "$logTimeFmt INFO $msg \c" >> $LOG_FILE ;;
        end)      echo "$msg" && echo "$msg" >> $LOG_FILE ;;
        warn)     echo -e "$consoleTimeFmt WARN $msg  " && echo "$logTimeFmt WARN $msg" >>$LOG_FILE ;;
        warnlog)  echo "$logTimeFmt WARN $msg" >>$LOG_FILE ;;
        errorlog) echo "$logTimeFmt ERROR $msg" >>$LOG_FILE ;;
        fatal)
            echo -e "$consoleTimeFmt FATAL $msg  " && echo "$logTimeFmt FATAL $msg" >>$LOG_FILE
            echo "Please refer $LOG_FILE for more details."
            exit 1;;
        *)
            echo -e "$consoleTimeFmt INFO $msg  " && echo "$logTimeFmt INFO $msg" >>$LOG_FILE ;;
    esac
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
    if [ "$ENABLE_ROLLING" == "true" ];then
        rolling &
        ROLLID=$!
    fi
}

stopRolling(){
    if [ "$ENABLE_ROLLING" == "true" ];then
        if [[ -n $ROLLID ]];then
            echo -ne '\b'
            kill -s SIGTERM $ROLLID
            wait $ROLLID >/dev/null 2>&1
        else
            ROLLID=
        fi
    fi
}

checkCertificate() {
    # for a valid deployment, it should contains a 'nginx-default-secret' secret.
    local ns=$1 deploy=$2 json nsMsg
    echo "[Nginx default secret]"
    json=$(kubectl get secret nginx-default-secret -n ${ns} -o json)  #should not use exec_cmd, we don't want secret be exposed
    if [ $? -ne 0 ];then
        echo -e "    nginx-default-secret: \033[1m\033[31mNot Found\033[?25h\033[0m";
        if [ -n "$deploy" ];then
            nsMsg="deployment:$deploy,namespace:$ns"
        else
            nsMsg="namespace:$ns"
        fi
        echo "Currently only OMT managed deployment is supported, checking for $nsMsg not supported!"
        return 1
    fi
    expire_date=$(echo $json | ${BIN_DIR}/jq -r '.data."tls.crt"' | base64 -d -w0 | openssl x509 -outform PEM 2>>$LOG_FILE | openssl x509 -noout -enddate 2>>$LOG_FILE | cut -d "=" -f 2)
    expire_date_stamp=`date -d "${expire_date}" +%s`
    today_stamp=`date +%s`
    days=$(( ($expire_date_stamp - $today_stamp)/86400 ))
    RELEASE_NAME=$(echo $json | ${BIN_DIR}/jq -r '.metadata.annotations."meta.helm.sh/release-name"?')
    echo -e "    Expiration date: \033[35m${expire_date}\033[0m"
    echo -e "    Days left:       \033[35m${days}\033[0m \n"
}
showStatus(){
    local type=$1
    local ns=$2
    local items=$3
    echo "    [$type]"
    for item in $items; do
        local name=$(echo $item | awk -F: '{print $1}')
        local available=$(echo $item | awk -F: '{print $2}')
        local desired=$(echo $item | awk -F: '{print $3}')
        local unavainable=$(echo $item | awk -F: '{print $4}') #for deploy only
        local msg="($ns) $name"
        local lotLen=$((OUTPUT_LEN-${#msg}-1))
        if [ "$available" == "<none>" ];then
            available=0
        fi
        if [ -n "$desired" ] && [[ $available -eq $desired ]];then
            echo -e "        $msg$(repl '.' "$lotLen") \033[1m\033[32m$available/$desired\033[?25h\033[0m"
            if [ -n "$unavainable" ] && [ "$unavainable" != "<none>" ];then
            echo -e "        Warning: $unavainable pod(s) for $name is(are) not in Running state"
            fi
        else
            if [ -z "$desired" ];then
                echo -e "        $msg$(repl '.' "$lotLen") \033[1m\033[31m$available\033[?25h\033[0m"
            else
                echo -e "        $msg$(repl '.' "$lotLen") \033[1m\033[31m$available/$desired\033[?25h\033[0m"
            fi
        fi
    done
}
filterOut(){
    local part=$1
    local all=$2

    local found result
    for name in $part; do
        found="false"
        for item in $all;do
            itemName=$(echo $item | awk -F: '{print $1}')
            if [ "$itemName" == "$name" ];then
                found="true"
                result="$result $item"
                break
            fi
        done
        if [ "$found" == "false" ];then
            result="$result $name:Missing"
        fi
    done
    echo $result
}
checkPrimarySuite(){
    local ns=$1 deploy=$2 deploys daemonsets statefulsets
    if [ -n "$deploy" ];then
        echo "[Namespace: ${ns}, Deployment: ${deploy}]"
    else
        echo "[Namespace: ${ns}]"
    fi


    deploys=$(exec_cmd "kubectl get deploy -n $ns --no-headers 2>>${LOG_FILE} | tr / ' ' | awk '{print \$1\":\"\$2\":\"\$3}' | xargs" -p=true)
    daemonsets=$(exec_cmd "kubectl get ds -n $ns  --no-headers 2>>${LOG_FILE} | awk '{print \$1\":\"\$6\":\"\$2}' | xargs" -p=true)
    statefulsets=$(exec_cmd "kubectl get sts -n $ns --no-headers 2>>${LOG_FILE} | tr / ' ' | awk '{print \$1\":\"\$2\":\"\$3}' | xargs" -p=true)
    showStatus "Deployment"   "$ns" "$deploys"
    showStatus "Daemonset"    "$ns" "$daemonsets"
    showStatus "StatefulSet"  "$ns" "$statefulsets"
}
checkHelmRelease(){
    local release=$1 ns=$2 deployName=$3
    local releases deploys daemonsets statefulsets extDeploy extDs extSts deploysIn daemonsetsIn statefulsetsIn deploySet dsSet stsSet msg
    releases=$(exec_cmd "${BIN_DIR}/helm list -n  $ns -o json 2>>${LOG_FILE}" -p=true)
    if [ $? -ne 0 ];then
        log "fatal" "Helm list failed!"
    fi
    if [ -z "$deployName" ];then
        msg="[Namespace: $ns, Helm Release: $release]"
    else
        msg="[Namespace: $ns, Deployment: $deployName, Helm Release: $release]"
    fi

    lotLen=$((OUTPUT_LEN-${#msg}-1))
    if [ $(echo $releases | jq -r '.[]|.name' | grep $release | wc -l) -eq 0 ];then
        echo -e "$msg$(repl '.' "$lotLen") \033[1m\033[31mNot Deployed\033[?25h\033[0m"
        return
    else
        echo -e "$msg$(repl '.' "$lotLen") \033[1m\033[32mDeployed\033[?25h\033[0m"
        deploys=$(exec_cmd "${BIN_DIR}/helm get manifest $release -n$ns 2>>${LOG_FILE} | yq e 'select(.kind==\"Deployment\").metadata.name' - | grep -v -e \"---\" | xargs" -p=true)
        daemonsets=$(exec_cmd "${BIN_DIR}/helm get manifest $release -n$ns 2>>${LOG_FILE} | yq e 'select(.kind==\"DaemonSet\").metadata.name' - | grep -v -e \"---\" | xargs" -p=true)
        statefulsets=$(exec_cmd "${BIN_DIR}/helm get manifest $release -n$ns 2>>${LOG_FILE} | yq e 'select(.kind==\"StatefulSet\").metadata.name' - | grep -v -e \"---\" | xargs" -p=true)
        extDeploy=$(exec_cmd "kubectl get deploy -n $ns -o json 2>>${LOG_FILE} | jq -r '.items[]|select(.metadata.annotations.\"meta.helm.sh/release-name\" == \"$release\").metadata.name' | xargs" -p=true)
        extDs=$(exec_cmd "kubectl get ds -n $ns -o json 2>>${LOG_FILE} | jq -r '.items[]|select(.metadata.annotations.\"meta.helm.sh/release-name\" == \"$release\").metadata.name' | xargs" -p=true)
        extSts=$(exec_cmd "kubectl get sts -n $ns -o json 2>>${LOG_FILE} | jq -r '.items[]|select(.metadata.annotations.\"meta.helm.sh/release-name\" == \"$release\").metadata.name' | xargs" -p=true)
        deploys="$deploys $extDeploy";         deploys=$(echo $deploys | tr ' ' '\n' | sort -u | tr '\n' ' ')
        daemonsets="$daemonsets $extDs";       daemonsets=$(echo $daemonsets | tr ' ' '\n' | sort -u | tr '\n' ' ')
        statefulsets="$statefulsets $extSts";  statefulsets=$(echo $statefulsets | tr ' ' '\n' | sort -u | tr '\n' ' ')

        #For deploy, as they adopt rolling update, if one pod is not updated successfuly, the original pod will not be terminated,
        #in this case, the ready replicas = desired replicas. However we should show warning for such case.
        deploysIn=$(exec_cmd "kubectl get deploy -n $ns --no-headers -o=custom-columns=Name:.metadata.name,Ready:.status.readyReplicas,DESIRE:.spec.replicas,Unavainable:.status.unavailableReplicas 2>>${LOG_FILE} | awk '{print \$1\":\"\$2\":\"\$3\":\"\$4}' | xargs" -p=true)
        daemonsetsIn=$(exec_cmd "kubectl get ds -n $ns  --no-headers 2>>${LOG_FILE} | awk '{print \$1\":\"\$6\":\"\$2}' | xargs" -p=true)
        statefulsetsIn=$(exec_cmd "kubectl get sts -n $ns --no-headers 2>>${LOG_FILE} | tr / ' ' | awk '{print \$1\":\"\$2\":\"\$3}' | xargs" -p=true)
        deploySet=$(filterOut "$deploys" "$deploysIn")
        dsSet=$(filterOut "$daemonsets" "$daemonsetsIn")
        stsSet=$(filterOut "$statefulsets" "$statefulsetsIn")
        showStatus "Deployment" "$ns" "$deploySet"
        showStatus "DaemonSet" "$ns" "$dsSet"
        showStatus "StatefulSet" "$ns" "$stsSet"
    fi
}
checkK8sObjests() {
    local ns=$1 deploy=$2
    #as long as nginx-default-secret exist, if RELEASE_NAME not found, we treat it as Primary deployment
    if [ -z "$RELEASE_NAME" ] || [ "$RELEASE_NAME" == "null" ];then
        checkPrimarySuite "$ns" "$deploy"
    else
        if [ -n "$RELEASE_NAME" ];then
            if [[ "$RELEASE_NAME" == "apphub" ]];then
                #in some case, there is no cdf configmap, and we can't get capability, thus, here we hardcode "kube-registry itom-velero itom-logrotate"
                local releases="apphub kube-registry itom-velero itom-logrotate"
                #local releases="itom-logrotate"
                for release in $releases; do
                    checkHelmRelease "$release" "$ns"
                done
            else
                checkHelmRelease "$RELEASE_NAME" "$ns"
            fi
        else
            log "fatal" "No valid release found!"
        fi
    fi
    echo ""
}


startPvcJobs(){
    local namespace="$1"
    local uid="" gid="" image="" suite_registry="" registry_orgname="" cluster_cm="" values=""
    if [ $(exec_cmd "kubectl auth can-i get pv -q 2>/dev/null" -p=false; echo $?) -ne 0 ];then
        log "warn" "Failed to check Persistent Volumes: no permission."
        return 1
    fi
    if [ -z "$RELEASE_NAME" ] || [ "$RELEASE_NAME" == "null" ];then
        podName=$(exec_cmd "kubectl get pod -n $ns --no-headers -o=custom-columns=Name:.metadata.name | head -n 1" -p true)
        if [ "$?" -ne 0 ];then
            log "warn" "No pod is found under namespace: $ns. Skip checking Persistent Volumes."
            return 1
        fi
        json=$(exec_cmd "kubectl get pod -n $ns $podName -o json" -p=true)
        uid=$(echo $json | jq -r '.spec.securityContext.runAsUser')
        gid=$(echo $json | jq -r '.spec.securityContext.runAsGroup')
        image=$(echo $json | jq -r '.spec.containers[0].image')
        suite_registry=${image%%/*}
        registry_orgname=${image#*/}
        registry_orgname=${registry_orgname%/*}
    else
        values=$(${BIN_DIR}/helm get values $RELEASE_NAME -n ${namespace}  -o json 2>>$LOG_FILE)
        uid=$(echo $values | jq -r '.global.securityContext.user')
        gid=$(echo $values | jq -r '.global.securityContext.fsGroup')
        suite_registry=$(echo $values | jq -r '.global.docker.registry')
        registry_orgname=$(echo $values | jq -r '.global.docker.orgName')
    fi

    local pvc_node_pairs all_pvcs
    local pod_names=$(kubectl get pods -n ${namespace} --no-headers 2>>${LOG_FILE} |grep -P '\bRunning\b'|awk '{print $1}')
    if [ -z "$pod_names" ]; then
        log "info" "(${namespace}) no pvs need to check"
        return
    fi

    for pod_name in $pod_names;do
        local pod_json=$(kubectl get pod $pod_name -n ${namespace} -o json 2>>${LOG_FILE})
        local claim_names=$(echo "$pod_json"|jq -r '.spec.volumes[].persistentVolumeClaim.claimName'|grep -v "null")
        local node_name=$(echo "$pod_json"|jq -r '.spec.nodeName')
        if [ -n "$claim_names" ]; then
            for pvc in $claim_names; do
                #                              pvc_name@node_name
                pvc_node_pairs="$pvc_node_pairs\n${pvc}@${node_name}"
                all_pvcs="$all_pvcs\n$pvc"
            done
        fi
    done

    uniq_pvcs=$(echo -e "$all_pvcs" | sort | uniq )

    local uniq_pvc_node_pairs
    for pvc in $uniq_pvcs; do
        local node_name=$(echo -e "$pvc_node_pairs" | grep -E "^${pvc}@" | head -1 | awk -F@ '{print $2}')
        # the pvcs need to be checked and the pod for checking should be run on @node
        uniq_pvc_node_pairs="$uniq_pvc_node_pairs ${pvc}@$node_name"
    done

    for pvc_node_pair in $uniq_pvc_node_pairs; do
        local node_name=$(echo "$pvc_node_pair" | awk -F@ '{print $2}')
        local pvc=$(echo "$pvc_node_pair" | awk -F@ '{print $1}')
        local volume_name=$(kubectl get pvc -n ${namespace} $pvc -o json|jq -r '.spec.volumeName')
        local job_name="cdf-volume-${pvc}-$(date '+%Y%m%d%H%M%S')"
        [ "${#volume_name}" -gt 63 ] && volume_name=${volume_name:0:62}
        [ "${#job_name}" -gt 63 ] && job_name=${job_name:0:62}
        kubectl delete jobs $job_name -n $namespace >/dev/null 2>&1
        echo "
apiVersion: batch/v1
kind: Job
metadata:
  labels:
    app: ${job_name}
    volume-name: ${volume_name}
  name: ${job_name}
  namespace: ${namespace}
spec:
  backoffLimit: 0
  completions: 1
  parallelism: 1
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        app: ${job_name}
        volume-name: ${volume_name}
    spec:
      imagePullSecrets:
        - name: registrypullsecret
      containers:
      - image: ${suite_registry}/${registry_orgname}/${IMAGE_ITOM_TOOLS_BASE}
        imagePullPolicy: IfNotPresent
        name: cdf-volume
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
        command: ['sh', '-c', 'if [ \$(echo -n 1>&2 2>/tmp/error > /test/rw;echo \$?) -eq 0 ];then if [ \$(stat -c %u /test/rw) == ${uid} -o \$(stat -c %g /test/rw) == ${gid} ];then /bin/rm -f /test/rw;echo OK; else echo \"Failed: folder owner or group is not equals to ${uid} and ${gid}\";/bin/rm -f /test/rw;exit 102; fi else more /tmp/error;exit 101; fi']
        volumeMounts:
        - mountPath: /test
          name: test-volume
      restartPolicy: Never
      dnsPolicy: ClusterFirst
      nodeName: ${node_name}
      securityContext:
        runAsUser: ${uid}
        runAsGroup: ${gid}
        fsGroup: ${gid}
        supplementalGroups: [${gid}]
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      volumes:
      - name: test-volume
        persistentVolumeClaim:
          claimName: ${pvc}
            "| kubectl create -f - 1>/dev/null 2>>${LOG_FILE}
            JOB_NS_PAIRS="$JOB_NS_PAIRS ${job_name}@${namespace}"
    done
}

checkPvcJobs(){
    local retry_count=60 name ns jobJson complete succeeded volume volJson msg lotLen
    while (( $retry_count > 0 )); do
        if [[ -z "$JOB_NS_PAIRS" ]];then
            break
        fi
        for pair in $JOB_NS_PAIRS;do
            name=$(echo "$pair"|awk -F@ '{print $1}')
            ns=$(echo "$pair"|awk -F@ '{print $2}')
            jobJson=$(exec_cmd "kubectl get jobs $name -n $ns -o json 2>>${LOG_FILE}" -p=true)
            complete=$(echo "$jobJson" | jq -r '.status.conditions[]|select(.type == "Complete").status?' 2>>${LOG_FILE})
            if [ "$complete" != "True" ];then
                continue
            fi
            succeeded=$(echo "$jobJson" | jq -r '.status.succeeded')
            volume=$(echo "$jobJson" | jq -r '.metadata.labels."volume-name"')
            msg="$volume"
            lotLen=$((OUTPUT_LEN-${#msg}-1))
            if [[ "$succeeded" -ge 1 ]];then
                echo -e "   $msg $(repl "." $lotLen) \033[1m\033[32mOK\033[?25h\033[0m"
            else
                echo -e "   $msg $(repl "." $lotLen) \033[1m\033[31mFailed\033[?25h\033[0m"
                log "info" "-------failed pod logs----------"
                kubectl logs $name -n $ns >>${LOG_FILE} 2>>${LOG_FILE}
            fi
            JOB_NS_PAIRS=$(echo "$JOB_NS_PAIRS"|xargs -n1|awk '$1 != "'"$pair"'"'|xargs)
            kubectl delete jobs $name -n $ns 1>/dev/null 2>>${LOG_FILE}
        done
        sleep 1
        retry_count=$(( $retry_count - 1 ))
    done

    if [[ "$retry_count" -le 0 ]];then
        for pair in $JOB_NS_PAIRS;do
            name=$(echo "$pair"|awk -F@ '{print $1}')
            ns=$(echo "$pair"|awk -F@ '{print $2}')
            jobJson=$(exec_cmd "kubectl get jobs $name -n $ns -o json 2>>${LOG_FILE}" -p=true)
            volume=$(echo "$jobJson" | jq -r '.metadata.labels."volume-name"')
            msg="$volume"
            lotLen=$((OUTPUT_LEN-${#msg}-1))
            echo -e "   $msg $(repl "." $lotLen) \033[1m\033[31mTimeout\033[?25h\033[0m"

            log "infolog" "-------timeout pod description----------"
            kubectl describe pods $name -n $ns >>${LOG_FILE} 2>>${LOG_FILE}
            log "infolog" "-------failed pod logs----------"
            kubectl logs $name -n $ns >>${LOG_FILE} 2>>${LOG_FILE}
            kubectl delete jobs $name -n $ns 1>/dev/null 2>>${LOG_FILE}
        done
    fi
}

checPV(){
    local ns=$1
    echo "[[Persistent Volume]]"
    JOB_NS_PAIRS=""
    startPvcJobs "${ns}"
    checkPvcJobs
    JOB_NS_PAIRS=""
}

init(){
    ##If we set a default value for DEPLOY_NAMESPACE, then, what should we do,if customer provide a deployment name and no namespace?
    ##So, no default value for DEPLOY_NAMESPACE
    if [ -z "$DEPLOY_NAME" ] && [ -z "$DEPLOY_NAMESPACE" ];then
        if [ -z "$CDF_NAMESPACE" ];then
            echo "Warning: we found \$CDF_NAMESPACE is empty. Please check the following:"
            echo "  1. Do you install OMT successfuly?"
            echo "  2. If yes, have your logout your session after installation(You need to log out your session and re-login to make the environment variables to take effect)?"
        else
            DEPLOY_NAMESPACE=$CDF_NAMESPACE
        fi
    elif [ -z "$DEPLOY_NAME" ] && [ -n "$DEPLOY_NAMESPACE" ];then
        DEPLOY_NAMESPACE=${DEPLOY_NAMESPACE//,/ }
    elif [ -n "$DEPLOY_NAME" ] && [ -z "$DEPLOY_NAMESPACE" ];then
        if [ $(exec_cmd "kubectl auth can-i get ns -q 2>/dev/null" -p=false; echo $?) -ne 0 ];then
            log "fatal" "Failed to convert deployment name to namespace: no permissions to get namespace details. The status of deployment: \"$DEPLOY_NAME\" will not be checked!"
        else
            DEPLOY_NAME=${DEPLOY_NAME//,/ }
            for deploy in $DEPLOY_NAME; do
                deploy_ns=$(${BIN_DIR}/cdfctl deployment get 2>>$LOG_FILE | grep "$deploy" | awk '{print $3}')
                if [ -z "$deploy_ns" ];then
                    log "warn" "Failed to convert deployment name \"$deploy\" to namespace: not found. The status of deployment: \"$deploy\" will not be checked!"
                else
                    DEPLOYMENT_NAME_NS_MAPPING="$DEPLOYMENT_NAME_NS_MAPPING $deploy:$deploy_ns"
                fi
            done
        fi
    else
        log "fatal" "You should either provide deployment name or deployment namespace, but not both at the same time."
    fi
}
check(){
    for ns in $DEPLOY_NAMESPACE;do
        checkCertificate "$ns"; if [ "$?" -ne 0 ];then continue; fi
        checkK8sObjests "$ns"
        checPV "$ns"
    done
    for item in $DEPLOYMENT_NAME_NS_MAPPING; do
        local deploy_name=${item%:*}
        local deploy_ns=${item#*:}
        checkCertificate "$deploy_ns" "$deploy_name"; if [ "$?" -ne 0 ];then continue; fi
        checkK8sObjests "$deploy_ns" "$deploy_name"
        checPV "$deploy_ns" "$deploy_name"
    done
}

########
# Main #
########

trap 'taskClean; exit' 1 2 3 8 9 14 15 EXIT
init
check