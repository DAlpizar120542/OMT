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

export LC_ALL=C
trap recordCtrlC SIGINT

trap exitHandler EXIT

function exitHandler(){
    stopRolling
    cleanup
    exit
}

function cleanup(){
    if [[ -f "$HOME/.upgrade-lock" ]] && [[ "$(cat $HOME/.upgrade-lock)" = "$$" ]] ; then 
        ${RM} -f $HOME/.upgrade-lock; 
    fi
}

function recordCtrlC(){
    if [[ ! -z $LOGFILE ]] ; then
        write_log "warn" "Cancelled by user!"
    else
        echo "Cancelled by user!"
    fi
    exitHandler
}

ROLLID=
CURRENT_DIR=$(cd `dirname $0`;pwd)
#The images list needs loading
K8S_IMAGE_PROPERTIES="${CURRENT_DIR}/k8s/properties/images/k8s_images.properties"
K8S_CHART_PROPERTIES="${CURRENT_DIR}/k8s/properties/images/k8s_charts.properties"
IMAGE_PROPERTIES="${CURRENT_DIR}/cdf/properties/images/images.properties"
CHART_PROPERTIES="${CURRENT_DIR}/cdf/properties/images/charts.properties"
BASEINFRA_VAULT_APPROLE=baseinfra
KUBE_SYSTEM_NAMESPACE=kube-system
DNS_DOMAIN="cluster.local"
CLUSTER_NODESELECT='node-role.kubernetes.io/control-plane: ""'
TAINT_MASTER_KEY="node-role.kubernetes.io/control-plane"
MULTI_SUITE=0
RETRY_TIMES=10
SLEEP_TIME=1
TIMEOUT_FOR_SERVICES=300
JQ=${CURRENT_DIR}/bin/jq
YQ=${CURRENT_DIR}/bin/yq
HELM=${CURRENT_DIR}/bin/helm

#raw version from current cluster
#format: 23.4-100
FROM_VERSION=
#format: 2023.11-100
FROM_INTERNAL_VERSION=
#format: 202311
FROM_INTERNAL_RELEASE=
#format: 100
FROM_BUILD_NUM=

#raw version from current build package, it is only for disply
#format: 23.4-100
TARGET_VERSION=$(cat ${CURRENT_DIR}/version.txt)
#internal version from current build package, it is involved in upgrade logic, NOT for disply, same for its child variables
#format: 2023.11-100
TARGET_INTERNAL_VERSION=$(cat ${CURRENT_DIR}/version_internal.txt)
#format: 202311
TARGET_INTERNAL_RELEASE=$(echo ${TARGET_INTERNAL_VERSION} | awk -F- '{print $1}' | awk -F. '{print $1$2}')
#format: 100
TARGET_BUILD_NUM=$(echo ${TARGET_INTERNAL_VERSION} | awk -F- '{print $2}')

#default value for tools-only env
TOOLS_ONLY=false

RESTART_POLICY=${RESTART_POLICY:-"unless-stopped"}
API_RESP=""
LOCAL_IP=""
LOAD_BALANCER_HOST=""
CERTCN=

CURRENT_STEP=0
STEP_CONT=""
GOLANG_TLS_CIPHERS=

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

for command_var in CP LS TAR RM RMDIR MV ; do
    command="$(echo $command_var|tr '[:upper:]' '[:lower:]')"
    command_val=$(findCommand "$command")
    if [[ $? != 0 ]] ; then
        NOTFOUND_COMMANDS+=($command)
    fi
    eval "${command_var}=\"${command_val}\""
    export $command_var
done

WARNING_MSG_AFTER_UPGRADE=

readonly ALL_MASTER_STEPS=11
readonly ALL_WORKER_STEPS=11
readonly CDF_UPGRADE_STEPS=5
readonly LOAD_IMAGE_STEPS=5

readonly MASTER_PACKAGES_INFRA=$($JQ -r '.usage.k8s_master_main|.[]' ${CURRENT_DIR}/image_pack_config.json 2>/dev/null | xargs)
readonly MASTER_PACKAGES_CDF=$($JQ -r '.usage.first_master_main|.[]' ${CURRENT_DIR}/image_pack_config.json 2>/dev/null | xargs)

#LAST_NODE_YAML_LIST contains the components upgrade on the last nodes
readonly LAST_NODE_YAML_LIST=("flannel.yaml" "kube-proxy.yaml")

#LAST_MASTER_YAML_LIST contains the components upgrade on the last nodes
readonly LAST_MASTER_YAML_LIST=("keepalived.yaml" "coredns.yaml")

#NOT_APPLY_YAML_LIST contains the componets need to delete and apply 
readonly NOT_APPLY_YAML_LIST=("")

#NEW_YAML_LIST contians the components that will delete and create with their new yaml, not using the yamls in backup folder
#array format NEW_YAML_LIST=("coredns.yaml")
readonly NEW_YAML_LIST=("flannel.yaml" "keepalived.yaml")

#LOCAL_APISERVER_YAML_LIST contains the components that use local apiserver to update
readonly LOCAL_APISERVER_YAML_LIST=("keepalived.yaml")
#json format  YAML_NAME_MAP='{"coredns.yaml": "kube-dns.yaml"}'
readonly YAML_NAME_MAP='{}'
#json format YAML_PATH_MAP='{"kube-dns.yaml": "origin_path"}'
readonly YAML_PATH_MAP='{}'

readonly NOT_CLEAN_IMAGES=("itom-busybox" "kubernetes-vault-init" "kubernetes-vault-renew")

# AZURE config file path
readonly AZURE_CONFIG_FILE="/etc/cdf/keepalived/keepalived-azure.conf"

# bash completion configuration file path
readonly CDF_KUBECTL_COMPLETION="/etc/bash_completion.d/itom-cdf-kubectl"

# k8s components certificates
readonly TLS_CERTS="etcd-server kube-api-server kubelet-server

                    kube-serviceaccount

                    kube-api-etcd-client kubelet-kube-api-client kube-api-kubelet-client 
                    kube-controller-kube-api-client kube-scheduler-kube-api-client 
                    kubectl-kube-api-client kube-api-proxy-client 

                    common-etcd-client"

readonly DEFAULT_TLS_MIN_VERSION="TLSv1.2"
readonly DEFAULT_TLS_CIPHERS="TLS_AES_128_GCM_SHA256,\
TLS_AES_256_GCM_SHA384,\
TLS_CHACHA20_POLY1305_SHA256,\
TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,\
TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,\
TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,\
TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,\
TLS_AES_128_CCM_8_SHA256,\
TLS_AES_128_CCM_SHA256"

readonly TAINT_MASTER_KEY="node-role.kubernetes.io/control-plane"
readonly MASTER_NODELABEL_KEY="node-role.kubernetes.io/control-plane"
readonly MASTER_NODELABEL_VAL=""

##map
declare -A K8sTLSVerMap=(["TLSv1.2"]="VersionTLS12" ["TLSv1.3"]="VersionTLS13")
declare -A EtcdTLSVerMap=(["TLSv1.2"]="TLS1.2" ["TLSv1.3"]="TLS1.3")
#version map, it's mainly for intermediate version
declare -A ReleaseVersionMap
ReleaseVersionMap["202205"]="2022.05"
ReleaseVersionMap["202211"]="2022.11"
ReleaseVersionMap["202305"]="2023.05"
ReleaseVersionMap["202311"]="23.4"
ReleaseVersionMap["202402"]="24.1"
ReleaseVersionMap["202405"]="24.2"
ReleaseVersionMap["202408"]="24.3"
ReleaseVersionMap["202411"]="24.4"

function rolling(){
    local lost=
    local spinner="|/-\\"
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
            sleep 0.125
        done
    done
}

function startRolling(){
    stopRolling
    rolling &
    ROLLID=$!
}

function stopRolling(){
    if [[ -n "$ROLLID" ]];then
        ps -p $ROLLID > /dev/null 2>&1
        if [[ $? == 0 ]] ; then
            kill -s SIGTERM $ROLLID >/dev/null 2>&1
            wait $ROLLID >/dev/null 2>&1
        fi
        ROLLID=
    fi
}

#append mode
function rollingStyleB() {
    local interval=0.125
    while true;do
        echo -ne " - "
        sleep $interval
        echo -ne "\b\b\b \\ "
        sleep $interval
        echo -ne "\b\b\b | "
        sleep $interval
        echo -ne "\b\b\b / "
        sleep $interval
        echo -ne "\b\b\b"
    done
}

write_log() {
    local level=$1
    local msg=$2
    #format 2018-09-17 16:30:01.772388983+08:00
    local timestamp=$(date --rfc-3339='ns')
    #format 2018-09-17T16:30:01.772388983+08:00
    timestamp=${timestamp:0:10}"T"${timestamp:11}
    case $level in
        debug)
            echo "${timestamp} DEBUG $msg  " >> $LOGFILE ;;
        info)
            echo -e "$msg"
            echo "${timestamp} INFO $msg  " >> $LOGFILE ;;
        error)
            echo -e "$msg"
            echo "${timestamp} ERROR $msg  " >> $LOGFILE ;;
        warn)
            echo -e "$msg"
            echo "${timestamp} WARN $msg  " >> $LOGFILE ;;
        fatal)
            echo -e "$msg"
            echo -e "The upgrade log file is ${LOGFILE}.\n"
            echo -e "${timestamp} FATAL $msg  \n" >> $LOGFILE
            echo "${timestamp} INFO Please refer to the Troubleshooting Guide for help on how to resolve this error.  " >> $LOGFILE
            echo "                                         The upgrade log file is ${LOGFILE}" >> $LOGFILE
            exit 1
            ;;
        *)
            echo "${timestamp} INFO $msg  " >> $LOGFILE ;;
    esac
}

usage(){
    echo "Usage: $0  [-i|--infra ] | [-u|--upgrade]  [Options]"
    echo "    -i, --infra              Upgrade Infrastructure components."
    echo "    -u, --upgrade            Upgrade AppHub components."
    echo "Options:"
    echo "    --drain                  Drain node before upgrade (Optional)."
    echo "                             It only takes effect during excuting upgrade.sh -i on worker nodes."
    echo "    --drain-timeout          The length of time to wait before giving up to drain the node. Default is 3600 seconds."
    echo "                             It only takes effect when you use option -e or --evict."
    echo "    -t, --temp               Specify an absolute path for storing cluster configurations. (Optional)."
    echo "                             If not specified, the configuration files will by default be saved in path '\$CDF_HOME/backup'."
    echo "    -y, --yes                Answer yes for any confirmations. (Optional)."
    echo "    -h, --help               Help message."
    echo "Advanced settings:"
    echo "    --apphub-helm-values     Specify YAML file containing custom AppHub Helm configuration. These settings will override auto-detected settings. Use with extreme caution and only if instructed through documentation and/or Customer Support.(Optional)"
    echo "                             It only takes effect during excuting upgrade.sh -u on one of the control plane node."
    exit 1;
}

exec_cmd(){
    local cmdSubPath="/bin"
    $CURRENT_DIR${cmdSubPath}/cmd_wrapper -c "$1" -f $LOGFILE -x=DEBUG $2 $3 $4 $5
    return $?
}

countRemainingSteps() {
    ((CURRENT_STEP++))
    #local step=`printf "%2d" "${CURRENT_STEP}"`
    if [[ "${IS_MASTER}" == "true" ]] && [[ "${UPGRADE_INFRA}" == "true" ]] ; then
        STEP_CONT="(Step ${CURRENT_STEP}/${ALL_MASTER_STEPS})"
    elif [[ "${IS_MASTER}" == "false" ]] && [[ "${UPGRADE_INFRA}" == "true" ]] ; then
        STEP_CONT="(Step ${CURRENT_STEP}/${ALL_WORKER_STEPS})"
    elif [[ "${IS_MASTER}" == "true" ]] && [[ "${UPGRADE_CDF}" == "true" ]] || [[ "${BYOK}" == "true" ]]; then
        STEP_CONT="(Step ${CURRENT_STEP}/${CDF_UPGRADE_STEPS})"
    else
        STEP_CONT="(Step ${CURRENT_STEP}/${LOAD_IMAGE_STEPS})"
    fi
}


isMasterNode(){
    local isMaster=
    if [[ -d ${RUNTIME_CDFDATA_HOME}/etcd ]] && [[ $(exec_cmd "${LS} ${RUNTIME_CDFDATA_HOME}/etcd|wc -l" -p=true) -gt 0 ]] ; then
        isMaster=true
    else
        isMaster=false
    fi
    echo $isMaster
}

getThisNode(){
    local thisNode=
    local all_nodes=$1
    local local_ips=
    local local_hostname=
    local local_shortname=
    local_ips=$(exec_cmd "ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'" -p=true)
    local_hostname=$(hostname -f | tr '[:upper:]' '[:lower:]')
    local_shortname=$(hostname -s | tr '[:upper:]' '[:lower:]')
    for node in ${all_nodes}
    do
        lower_node=$(echo $node | tr '[:upper:]' '[:lower:]')
        if [[ "$local_hostname" == "$lower_node" ]]; then
            thisNode="$local_hostname"
            break
        else 
            for ip in $local_ips
            do
              if [ "$node" == "$ip" ]; then
                thisNode="$ip"
                break
              fi
            done
        fi
        # shortname
        if [[ "$local_shortname" == "$lower_node" ]]; then
            thisNode="$local_shortname"
            break
        fi
    done
    echo "$thisNode"
}

getUpgradedMasterNodes(){
    local master_nodes=$1
    local upgradedMasterNodes=
    if [[ "${isFirstMaster}" == "true" ]] ; then
        upgradedMasterNodes=""
    else
        upgradedMasterNodes=$(exec_cmd "kubectl get configmap upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE} -o json | ${JQ} --raw-output '.data.UPGRADED_MASTER_NODES?'" -p=true)
    fi
    echo $upgradedMasterNodes
}

backupUpgrade() {
    countRemainingSteps
    write_log "info" "\n** Backup ${CDF_HOME} directory ... ${STEP_CONT}"
    
    BACKUP_DIR=CDF_${FROM_INTERNAL_RELEASE}_BACKUP

    if [[ ! -f ${UPGRADE_TEMP}/backup-complete-bin ]] ; then
        write_log "info" "     Copy filtered binaries to ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}"
        mkdir -p ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/bin
        local filterdBins=
        filterdBins=$(exec_cmd "${LS} ${CDF_HOME}/bin | grep -E '*.sh$|cdfctl|updateExternalDbInfo' | xargs" -p =true)
        for bin in $filterdBins ; do
            execCmdWithRetry "${CP} -rpf ${CDF_HOME}/bin/${bin} ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/bin/." "3"
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to copy filtered binaries."
            fi
        done
        exec_cmd "touch ${UPGRADE_TEMP}/backup-complete-bin"
        write_log "info" "     Backup filtered binaries successfully."
    else
        write_log "info" "     filtered binaries backup has already been done. Proceeding to the next step."
    fi

    if [[ ! -f ${UPGRADE_TEMP}/backup-complete-cri ]] ; then
        write_log "info" "     Copy CRI files to ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/CRI"
        mkdir -p ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/CRI
        execCmdWithRetry "${CP} -rpf ${CDF_HOME}/cfg ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/CRI/." "3"
        if [[ $? == 0 ]]; then
            exec_cmd "${CP} -rpf /usr/lib/systemd/system/containerd.service ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/CRI/."
            exec_cmd "touch ${UPGRADE_TEMP}/backup-complete-cri"
            write_log "info" "     Backup CRI folders successfully."
        else
            write_log "fatal" "Failed to backup CRI folders."
        fi
    else
        write_log "info" "     CRI backup has already been done. Proceeding to the next step."
    fi

    if [[ ! -f ${UPGRADE_TEMP}/backup-complete-k8s ]] ; then
        write_log "info" "     Copy k8s files to ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S"
        mkdir -p ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S
        execCmdWithRetry "${CP} -rpf ${CDF_HOME}/cni ${CDF_HOME}/cfg ${CDF_HOME}/ssl ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S/." "3"
        if [[ $? == 0 ]]; then
            exec_cmd "${CP} -rpf /usr/lib/systemd/system/kubelet.service ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S/."
            [[ -f /usr/lib/systemd/system/kube-proxy.service ]] && exec_cmd "${CP} -rpf /usr/lib/systemd/system/kube-proxy.service ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S/."
            exec_cmd "${CP} -rpf ${CDF_HOME}/objectdefs ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S/."
            exec_cmd "${CP} -rpf ${CDF_HOME}/runconf ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S/."
            exec_cmd "${CP} -rpf ${CDF_HOME}/cfg/apiserver-encryption.yaml ${UPGRADE_TEMP}/apiserver-encryption-orignal.yaml" || write_log "fatal" "Failed to backup ${CDF_HOME}/cfg/apiserver-encryption.yaml"
            if [[ $IS_MASTER == "true" ]] ; then
                exec_cmd "${CP} -rpf ${CDF_HOME}/runconf/kube-apiserver.yaml ${UPGRADE_TEMP}/kube-apiserver-orignal.yaml" || write_log "fatal" "Failed to backup ${CDF_HOME}/runconf/kube-apiserver.yaml"
            fi
            exec_cmd "touch ${UPGRADE_TEMP}/backup-complete-k8s"
            write_log "info" "     Backup k8s folders successfully."
        else
            write_log "fatal" "Failed to backup k8s folders."
        fi
    else
        write_log "info" "     K8S backup has already been done. Proceeding to the next step."
    fi

    if [[ ! -f ${UPGRADE_TEMP}/backup-complete-cdf ]] ; then
        write_log "info" "     Copy infrastructure files to ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/CDF"
        mkdir -p ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/CDF
        execCmdWithRetry "${CP} -rpf ${CDF_HOME}/scripts ${CDF_HOME}/ssl ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/CDF/." "3"
        if [[ $? == 0 ]]; then
            exec_cmd "${CP} -rpf ${CDF_HOME}/objectdefs ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/CDF/."
            exec_cmd "${CP} -rpf ${CDF_HOME}/tools ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/CDF/."
            exec_cmd "touch ${UPGRADE_TEMP}/backup-complete-cdf"
            write_log "info" "     Backup infrastructure folders successfully."
        else
            write_log "fatal" "Failed to backup infrastructure folders."
        fi
    else
        write_log "info" "     Infrastructure backup has already been done. Proceeding to the next step."
    fi
}

setenv(){
    #set env variables 
    if [[ ! -f ${UPGRADE_TEMP}/env_complete ]] ; then
        #generate env.sh
        echo "#!/bin/bash" > ${UPGRADE_TEMP}/env.sh
        echo "source /etc/profile.d/itom-cdf.sh" >> ${UPGRADE_TEMP}/env.sh
        echo "export THIS_NODE=${THIS_NODE}" >> ${UPGRADE_TEMP}/env.sh
        echo "export ETCD_ENDPOINT=${ETCD_ENDPOINT}" >> ${UPGRADE_TEMP}/env.sh
        echo "export K8S_MASTER_IP=${K8S_MASTER_IP}" >> ${UPGRADE_TEMP}/env.sh
        echo "export no_proxy=\${K8S_MASTER_IP},\${THIS_NODE},127.0.0.1,\$no_proxy" >> ${UPGRADE_TEMP}/env.sh
        echo "export SUITE_REGISTRY=${SUITE_REGISTRY}" >> ${UPGRADE_TEMP}/env.sh
        echo "export REGISTRY_ORGNAME=${REGISTRY_ORGNAME}" >> ${UPGRADE_TEMP}/env.sh
        echo "export RUNTIME_CDFDATA_HOME=${RUNTIME_CDFDATA_HOME}" >> ${UPGRADE_TEMP}/env.sh
        echo "export KUBELET_HOME=${KUBELET_HOME}" >> ${UPGRADE_TEMP}/env.sh
        echo "export K8S_MASTER_ENDPOINT=https://\${K8S_MASTER_IP}:${MASTER_API_SSL_PORT}" >> ${UPGRADE_TEMP}/env.sh
        exec_cmd "chmod 700 ${UPGRADE_TEMP}/env.sh"
        
        #generate itom-cdf.sh
        echo "# itom cdf env" > ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export K8S_HOME=${K8S_HOME}" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export CDF_HOME=${CDF_HOME}" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export CDF_NAMESPACE=${CDF_NAMESPACE}" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export VELERO_NAMESPACE=${CDF_NAMESPACE}" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export PATH=\$PATH:\${K8S_HOME}/bin" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export ETCDCTL_API=3" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export CONTAINERD_NAMESPACE=k8s.io" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export TMP_FOLDER=${TMP_FOLDER}" >> ${UPGRADE_TEMP}/itom-cdf.sh
        exec_cmd "chmod 644 ${UPGRADE_TEMP}/itom-cdf.sh"

        #copy env.sh to k8s home
        write_log "info" "     Copying env.sh to $CDF_HOME/bin ..."
        exec_cmd "${CP} -rpf ${CDF_HOME}/bin/env.sh ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/."
        exec_cmd "${CP} -rf ${UPGRADE_TEMP}/env.sh ${CDF_HOME}/bin/."

        #copy itom-cdf.sh to /etc/profile.d/.
        write_log "info" "     Copying itom-cdf.sh to /etc/profile.d/ ..."
        [[ ! -d /etc/profile.d/ ]] && mkdir -p /etc/profile.d/ 
        [[ -f /etc/profile.d/itom-cdf.sh ]] && exec_cmd "${CP} -rpf /etc/profile.d/itom-cdf.sh ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/."
        exec_cmd "${CP} -rpf ${UPGRADE_TEMP}/itom-cdf.sh /etc/profile.d/." || write_log "fatal" "Failed to copy itom-cdf.sh to /etc/profile.d/"

        #copy itom-cdf-alias.sh to /etc/profile.d/.
        write_log "info" "     Copying itom-cdf-alias.sh to /etc/profile.d/ ..."
        [[ ! -d /etc/profile.d/ ]] && mkdir -p /etc/profile.d/ 
        [[ -f /etc/profile.d/itom-cdf-alias.sh ]] && exec_cmd "${CP} -rpf /etc/profile.d/itom-cdf-alias.sh ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/."
        exec_cmd "${CP} -rpf ${CURRENT_DIR}/cdf/scripts/itom-cdf-alias.sh /etc/profile.d/. && chmod 700 /etc/profile.d/itom-cdf-alias.sh" || write_log "fatal" "Failed to copy itom-cdf-alias.sh  to /etc/profile.d/"

        [[ ${SUDO_UID} != 0 ]] && [[ ${SUDO_UID} != "" ]] && exec_cmd "sed -i 's@kubectl@sudo kubectl@g' /etc/profile.d/itom-cdf-alias.sh"

        exec_cmd "touch ${UPGRADE_TEMP}/env_complete"
    else
        write_log "debug" "Set env already completed."
    fi
}

removeAndCopy(){
    countRemainingSteps
    write_log "info" "\n** Removing old data and copying installation files to ${CDF_HOME} ... ${STEP_CONT}"
    if [[ ! -f ${UPGRADE_TEMP}/removeandcopy_complete ]] ; then
        exec_cmd "touch ${UPGRADE_TEMP}/removeandcopy_start"

        cd ${CURRENT_DIR}
        if checkSupportVersion "$SUPPORT_CONTAINERD_VERSION" "$CURRENT_CONTAINERD_VERSION" ; then
            write_log "info" "     Copy containerd files to ${CDF_HOME}..."
            local folderListWithExceptions=
            #get folder under containerd folder except bin folder
            folderListWithExceptions=$(exec_cmd "${LS} ./cri | grep -v bin | xargs" -p =true)
            for temp_folder in ${folderListWithExceptions} ; do
                exec_cmd "${CP} -rf cri/${temp_folder} ${CDF_HOME}/."
                if [[ $? != 0 ]] ; then
                    write_log "fatal" "Failed to copy containerd folders."
                fi
            done
        elif [[ $CURRENT_CONTAINERD_VERSION == $TARGET_CONTAINERD_VERSION ]] ; then
            write_log "debug" "containerd version didn't change. No need to update related files."
        else
            write_log "debug" "Unsupported containerd verison. Skipped"
        fi

        if checkSupportVersion "$SUPPORT_K8S_VERSION" "$CURRENT_K8S_VERSION" ; then
            write_log "info" "     Copy k8s files to ${CDF_HOME}..."
            local folderListWithExceptions=
            local fileListinBin=
            local fileListinCfg=
            local fileListinControllerManager=
            local fileListinManifests=
            local fileListinObjectdefs=
            #get folder under k8s folder except bin folder
            folderListWithExceptions=$(exec_cmd "${LS} ./k8s | grep -v 'bin\|images\|manifests\|objectdefs\|cfg\|cni' | xargs" -p =true)
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to get k8s fodlers except some folders."
            fi
            #get files in bin except kubelet and kubectl
            fileListinBin=$(exec_cmd "${LS} ./k8s/bin | grep -v 'kubelet\|kubectl' | xargs" -p =true)
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to get files under bin folder."
            fi
            #get files in cfg except controller-manager
            fileListinCfg=$(exec_cmd "${LS} ./k8s/cfg | grep -v controller-manager | xargs" -p =true)
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to get files under cfg folder."
            fi
            #get files in controller-manager except recycler.yaml
            fileListinControllerManager=$(exec_cmd "${LS} ./k8s/cfg/controller-manager | grep -v recycler | xargs" -p =true)
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to get files under controller-manager folder."
            fi
            #get files in manifests, only etcd.yaml
            fileListinManifests=$(exec_cmd "${LS} ./k8s/manifests | grep etcd | xargs" -p =true)
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to get files under manifests folder."
            fi
            #get files in objectdefs except kube-proxy-config.yaml and kube-proxy.yaml
            fileListinObjectdefs=$(exec_cmd "${LS} ./k8s/objectdefs | grep -v kube-proxy | xargs" -p =true)
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to get files under objectdefs folder."
            fi
            for temp_folder in ${folderListWithExceptions} ; do
                exec_cmd "${CP} -rf k8s/${temp_folder} ${CDF_HOME}/."
                if [[ $? != 0 ]] ; then
                    write_log "fatal" "Failed to copy k8s folders."
                fi
            done
            for temp_file in ${fileListinBin[@]} ; do
                exec_cmd "${CP} -rf k8s/bin/${temp_file} ${CDF_HOME}/bin/."
                if [[ $? != 0 ]] ; then
                    write_log "fatal" "Failed to copy k8s bin files."
                fi
            done
            for temp_file in ${fileListinCfg[@]} ; do
                exec_cmd "${CP} -rf k8s/cfg/${temp_file} ${CDF_HOME}/cfg/."
                if [[ $? != 0 ]] ; then
                    write_log "fatal" "Failed to copy k8s cfg files."
                fi
            done
            for temp_file in ${fileListinControllerManager[@]} ; do
                exec_cmd "${CP} -rf k8s/cfg/controller-manager/${temp_file} ${CDF_HOME}/cfg/controller-manager/."
                if [[ $? != 0 ]] ; then
                    write_log "fatal" "Failed to copy k8s controller-manager files."
                fi
            done
            if [[ ! -d ${CDF_HOME}/manifests ]] ; then
                exec_cmd "mkdir -p ${CDF_HOME}/manifests"
            fi
            for temp_file in ${fileListinManifests[@]} ; do
                exec_cmd "${CP} -rf k8s/manifests/${temp_file} ${CDF_HOME}/manifests/."
                if [[ $? != 0 ]] ; then
                    write_log "fatal" "Failed to copy k8s manifests files."
                fi
            done
            if [[ ! -d ${CDF_HOME}/objectdefs ]] ; then
                exec_cmd "mkdir -p ${CDF_HOME}/objectdefs"
            fi
            for temp_file in ${fileListinObjectdefs[@]} ; do
                exec_cmd "${CP} -rf k8s/objectdefs/${temp_file} ${CDF_HOME}/objectdefs/."
                if [[ $? != 0 ]] ; then
                    write_log "fatal" "Failed to copy k8s objectdefs files."
                fi
            done
            #apiserver-encryption.yaml should not be updated here, otherwise api-server can't start up 
            exec_cmd "${CP} -rf ${UPGRADE_TEMP}/apiserver-encryption-orignal.yaml ${CDF_HOME}/cfg/apiserver-encryption.yaml"
        elif [[ $CURRENT_K8S_VERSION == $TARGET_K8S_VERSION ]] ; then
            write_log "debug" "K8S version didn't change. No need to update related files."
        else
            write_log "debug" "Unsupported K8S verison. Skipped"
        fi

        if checkSupportVersion "$SUPPORT_CDF_VERSION" "$CURRENT_CDF_VERSION" ; then
            write_log "info" "     Copy apphub files to ${CDF_HOME}..."
            
            k8s_charts=($(cat ${K8S_CHART_PROPERTIES} | awk -F= '{print $2}'))
            delete_charts=($(${LS} ${CDF_HOME}/charts | xargs))
            #filter out k8s charts
            for k8s_chart in ${k8s_charts[@]} ; do
                for i in ${!delete_charts[@]} ; do
                    if [[ $k8s_chart == ${delete_charts[i]} ]] ; then
                        unset 'delete_charts[i]'
                    fi
                done
            done
            #clean chart folder before update
            for chart in ${delete_charts[@]} ; do
                exec_cmd "${RM} -rf ${CDF_HOME}/charts/${chart}"
            done

            local folderListWithExceptions=
            folderListWithExceptions=$(exec_cmd "${LS} ./cdf | grep -v images | xargs" -p =true)
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to get folders under cdf fodler except some folders."
            fi
            for temp_folder in ${folderListWithExceptions} ; do
                exec_cmd "${CP} -rf cdf/${temp_folder} ${CDF_HOME}/."
                if [[ $? != 0 ]] ; then
                    write_log "fatal" "Failed to copy cdf folders."
                fi
            done
        elif [[ $CURRENT_CDF_VERSION == $TARGET_CDF_VERSION ]] ; then
            write_log "debug" "Infrastructure version didn't change. No need to update related files."
        else
            write_log "debug" "Unsupported infrastructure verison. Skipped"
        fi

        #common copy
        write_log "debug" "Copy common things on all nodes... \n"
        exec_cmd "${CP} -rf bin scripts tools install uninstall.sh node_prereq image_pack_config.json ${CDF_HOME}/." -p=false
        if [[ $? != 0 ]] ; then
            write_log "fatal" "Failed to copy common files."
        fi
        
        #common remove
        write_log "debug" "Remove common things on all nodes... \n"
        exec_cmd "${RM} -rf ${CDF_HOME}/bin/kill-all-workloads.sh"
        exec_cmd "${RM} -rf ${CDF_HOME}/bin/kubelet-umount-action.sh"
        exec_cmd "${RM} -rf ${CDF_HOME}/bin/crimgr"
        exec_cmd "${RM} -rf ${CDF_HOME}/scripts/podSecurityPolicyManager.sh"
        exec_cmd "${RM} -rf ${CDF_HOME}/scripts/upgradePreCheck"
        exec_cmd "${RM} -rf ${CDF_HOME}/images/cdf-common-images.tgz"
        exec_cmd "${RM} -rf ${CDF_HOME}/images/cdf-master-images.tgz"
        exec_cmd "${RM} -rf ${CDF_HOME}/images/cdf-phase2-images.tgz"
        exec_cmd "${RM} -rf ${CDF_HOME}/tools/cdf-doctor"
        
        #worker custom remove
        write_log "debug" "Remove things on worker... \n"
        if [[ ${IS_MASTER} != "true" ]] ; then
            if [[ ! -d ${CDF_HOME}/runconf ]] ; then
                exec_cmd "mkdir -p ${CDF_HOME}/runconf"
            fi
            exec_cmd "${RM} -rf ${CDF_HOME}/install"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/updateExternalDbInfo"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/update_kubevaulttoken"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/changeRegistry"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/aws-ecr-create-repository"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/deployment-status.sh"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/etcdctl"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/helm"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/kill-all-workloads.sh"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/notary"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/vault"
            exec_cmd "${RM} -rf ${CDF_HOME}/bin/velero"
            exec_cmd "${RM} -rf ${CDF_HOME}/manifests/"
            exec_cmd "${RM} -rf ${CDF_HOME}/rpm/"
            exec_cmd "${RM} -rf ${CDF_HOME}/runconf/*"
            local toolsList=$(${LS} ${CDF_HOME}/tools 2>/dev/null | grep -v cdf-doctor | grep -v support-tool | xargs)
            write_log "debug" "toolsList: $toolsList"
            for tool in ${toolsList[@]} ; do
                exec_cmd "${RM} -rf ${CDF_HOME}/tools/${tool}"
            done
            #leave yaml on worker nodes under objectdefs folder
            local yamlsList=$(${LS} ${CDF_HOME}/objectdefs 2>/dev/null | grep -v flannel.yaml | grep -v flannel-config.yaml | grep -v kube-proxy.yaml | grep -v kube-proxy-config.yaml | xargs)
            write_log "debug" "yamlsList: $yamlsList"
            for yaml in ${yamlsList[@]} ; do
                exec_cmd "${RM} -rf ${CDF_HOME}/objectdefs/${yaml}"
            done
            #only leave clean_images.sh on worker nodes under scripts folder
            local scriptsList=$(${LS} ${CDF_HOME}/scripts 2>/dev/null | grep -v renewCert | xargs)
            write_log "debug" "scriptsList: $scriptsList"
            for script in ${scriptsList[@]} ; do
                exec_cmd "${RM} -rf ${CDF_HOME}/scripts/${script}"
            done
        fi

        #customize settings
        exec_cmd "ln -sf ${CDF_HOME}/bin/helm /usr/bin/helm"
        exec_cmd "ln -sf ${CDF_HOME}/bin/velero /usr/bin/velero"

        #fapolicy rules
        if [[ ${IS_MASTER} == "true" ]] ; then
            local binFiles="$CDF_HOME/bin/cdfctl $CDF_HOME/scripts/cleanRegistry $CDF_HOME/bin/helm"
            updateFapolicy "$binFiles"
        fi
        
        #authorization
        exec_cmd "chmod 755 ${CDF_HOME} ${CDF_HOME}/ssl"
        
        exec_cmd "chmod 700 ${CDF_HOME}/images ${RUNTIME_CDFDATA_HOME} ${CDF_HOME}/cfg ${CDF_HOME}/bin ${CDF_HOME}/log ${CDF_HOME}/runconf ${CDF_HOME}/objectdefs"
        
        exec_cmd "chmod 755 ${CDF_HOME}/bin/aws-ecr-create-repository ${CDF_HOME}/bin/cdfctl ${CDF_HOME}/bin/changeRegistry ${CDF_HOME}/bin/cmd_wrapper ${CDF_HOME}/bin/deployment-status.sh ${CDF_HOME}/bin/env.sh ${CDF_HOME}/bin/etcdctl \
                 ${CDF_HOME}/bin/helm ${CDF_HOME}/bin/jq ${CDF_HOME}/bin/kubectl ${CDF_HOME}/bin/notary ${CDF_HOME}/bin/updateExternalDbInfo ${CDF_HOME}/bin/vault ${CDF_HOME}/bin/velero ${CDF_HOME}/bin/yq"

        exec_cmd "chmod 755 ${CDF_HOME}/scripts/alertmanager ${CDF_HOME}/scripts/cdfctl.sh ${CDF_HOME}/scripts/certCheck ${CDF_HOME}/scripts/cleanRegistry ${CDF_HOME}/scripts/common.sh ${CDF_HOME}/scripts/downloadimages.sh ${CDF_HOME}/scripts/gen_secrets.sh ${CDF_HOME}/scripts/generateCerts.sh ${CDF_HOME}/scripts/generateSilentTemplate \
                 ${CDF_HOME}/scripts/generate_secrets ${CDF_HOME}/scripts/gs_utils.sh ${CDF_HOME}/scripts/itom-cdf-alias.sh ${CDF_HOME}/scripts/jq ${CDF_HOME}/scripts/renewCert ${CDF_HOME}/scripts/replaceExternalAccessHost.sh ${CDF_HOME}/scripts/uploadimages.sh ${CDF_HOME}/scripts/volume_admin.sh"
        
        exec_cmd "chmod 755 -R ${CDF_HOME}/tools/generate-download ${CDF_HOME}/tools/postgres-backup"

        exec_cmd "chown -R ${ETCD_USER_ID} ${RUNTIME_CDFDATA_HOME}/etcd"

        exec_cmd "chown -R ${SYSTEM_USER_ID} ${CDF_HOME}/log ${CDF_HOME}/scripts ${CDF_HOME}/cfg/cdf-phase2.json"
        
        exec_cmd "chown -R ${K8S_USER_ID} ${CDF_HOME}/cfg/controller-manager ${CDF_HOME}/cfg/apiserver-encryption.yaml ${CDF_HOME}/cfg/apiserver-audit-policy.yaml ${CDF_HOME}/log/audit ${CDF_HOME}/cfg/admission-cfg.yaml"

        exec_cmd "touch ${UPGRADE_TEMP}/removeandcopy_complete"
        write_log "info" "     Remove old data and copy installation files to ${CDF_HOME} successfully."
    else
        write_log "info" "     Removing old data and copying installation files to ${CDF_HOME} have already been done. Proceeding to the next step."
    fi
}

rgxMatch() {
    local str="$1"
    local searchStr="$2"
    echo -n $str | grep -E "$searchStr" >> /dev/null 2>&1
    return $?
}

chownCertificate(){
    local cert=$1
    local path=$2
    if rgxMatch "${cert}" "^(kube-api|kube-controller|kube-scheduler)"; then
        exec_cmd "chown ${K8S_USER_ID} ${path}/${cert}.crt ${path}/${cert}.key"
    elif rgxMatch "${cert}" "^etcd"; then
        exec_cmd "chown ${ETCD_USER_ID} ${path}/${cert}.crt ${path}/${cert}.key"
    elif rgxMatch "${cert}" "^kube-serviceaccount"; then
        exec_cmd "chown ${K8S_USER_ID} ${path}/${cert}.key"
        exec_cmd "chown ${K8S_USER_ID} ${path}/${cert}.pub"
    else
        exec_cmd "chown ${SYSTEM_USER_ID} ${path}/${cert}.crt ${path}/${cert}.key"
    fi
}

getRegistryInfo(){
    local registryInfo=
    write_log "debug" "Start get registry infomation"
    local reTryTimes=0
    while true; do
        exec_cmd "kubectl get secret -n ${CDF_NAMESPACE} registrypullsecret -o json > ${UPGRADE_TEMP}/registrySecret.json"
        if [[ $? == 0 ]] ; then
            write_log "debug" "Fetch registrypullsecret successfully."
            break
        else
            if [[ $reTryTimes -le ${RETRY_TIMES} ]] ; then
                ((reTryTimes++))
                write_log "debug" "Failed to fetch registrypullsecret in ${CDF_NAMESPACE} namespace. [$reTryTimes/${RETRY_TIMES}]"
                sleep 6
            else
                write_log "fatal" "Cannot get local registry information, missing secret 'registrypullsecret' in ${CDF_NAMESPACE} namespace"
            fi
        fi
    done
    local registryInfoEncoded=
    registryInfoEncoded=$(exec_cmd "cat ${UPGRADE_TEMP}/registrySecret.json | ${JQ} --raw-output '.data.\".dockerconfigjson\"'" -p=true -m=false -o=false)
    registryInfo=$(exec_cmd "echo '$registryInfoEncoded' | base64 -d" -p=true -m=false -o=false)
    write_log "debug" "echo '\$registryInfo' | ${JQ} --raw-output '.auths'"
    AUTHS=$(exec_cmd "echo '$registryInfo' | ${JQ} --raw-output '.auths'" -p=true -m=false -o=false)
    write_log "debug" "echo '\$registryInfo' | ${JQ} --raw-output '.auths.\"localhost:5000\".auth' | base64 -d | cut -d ':' -f1"
    REGISTRY_READER_USERNAME=$(exec_cmd "echo '$registryInfo' | ${JQ} --raw-output '.auths.\"localhost:5000\".auth' | base64 -d | cut -d ':' -f1" -p=true -m=false -o=false)
    write_log "debug" "echo '\$registryInfo' | ${JQ} --raw-output '.auths.\"localhost:5000\".auth' | base64 -d | cut -d ':' -f2-"
    REGISTRY_READER_PASSWORD=$(exec_cmd "echo '$registryInfo' | ${JQ} --raw-output '.auths.\"localhost:5000\".auth' | base64 -d | cut -d ':' -f2-" -p=true -m=false -o=false)

    checkHelmalive
    REGISTRY_USERNAME=$(exec_cmd "${HELM} get values kube-registry -a -n ${CDF_NAMESPACE} -o json 2>>$LOGFILE | ${JQ} --raw-output '.credentials.username'" -p=true -m=false -o=false)
    REGISTRY_PASSWORD=$(exec_cmd "${HELM} get values kube-registry -a -n ${CDF_NAMESPACE} -o json 2>>$LOGFILE | ${JQ} --raw-output '.credentials.password'" -p=true -m=false -o=false)
    if [[ ${REGISTRY_PASSWORD} == "" ]] || [[ ${REGISTRY_PASSWORD} == "null" ]] ; then
        REGISTRY_PASSWORD=$(exec_cmd "${HELM} get values kube-registry -a -n ${CDF_NAMESPACE} -o json 2>>$LOGFILE | ${JQ} --raw-output '.credentials.b64encPassword' | base64 -d" -p=true -m=false -o=false)
    fi
    AUTH=$(exec_cmd "echo -n '${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}' | base64 -w0" -p=true -m=false -o=false)
}

updateImagePkg(){
    local type=$1
    if [[ $type == "infra" ]] ; then
        if [[ ! -f ${UPGRADE_TEMP}/copyinfraimages_complete ]] ; then
            startRolling    
            exec_cmd "${CP} ${CURRENT_DIR}/k8s/images/* ${CDF_HOME}/images/"
            exit_code=$?
            stopRolling
            if [[ $exit_code != 0 ]] ; then 
                write_log "fatal" "Failed to update K8S components images." 
            else
                exec_cmd "touch ${UPGRADE_TEMP}/copyinfraimages_complete"
                write_log "info" "     Update K8S components images successfully."
            fi
        else
            write_log "info" "     K8S components images have already been updated. Proceeding to the next step."
        fi
    elif [[ $type == "apphub" ]] ; then
        if [[ ! -f ${UPGRADE_TEMP}/copyapphubimages_complete ]] ; then
            startRolling
            exec_cmd "${CP} ${CURRENT_DIR}/cdf/images/* ${CDF_HOME}/images/" 
            exit_code=$?
            stopRolling 
            if [[ $exit_code != 0 ]] ; then
                write_log "fatal" "Failed to update Apphub components images." 
            else 
                exec_cmd "touch ${UPGRADE_TEMP}/copyapphubimages_complete"
                write_log "info" "     Update Apphub components images successfully."
            fi
        else
            write_log "info" "     Apphub components images have already been updated. Proceeding to the next step."
        fi
    else
        write_log "fatal" "Unkown type. Internal Error!"
    fi
}

tagImage(){
    local sourceImage=$1
    local targetImage=$2
    exec_cmd "${CDF_HOME}/bin/ctr -n k8s.io images tag $sourceImage $targetImage"
}

pushImagePkg() {
    if [[ $DEVELOPOR_MODE == "true" ]] && [[ $SKIP_IMAGE_OPERATION == "true" ]] ; then
        write_log "info" "     Skip pushing images..."
        return
    fi
    local type=$1

    getRegistryInfo

    if [[ ${DOCKER_REPOSITORY} != "localhost:5000" ]] ; then
        write_log "info" "     Using an external registry. No need to push images."
        if [[ $UPGRADE_INFRA == "true" ]] && [[ "$type" == "infra" ]]; then
            write_log "info" "     Pulling required images..."
            startRolling
            local data=
            data=$(getValueWithRetry "kubectl get secret registrypullsecret -n ${CDF_NAMESPACE} -o json" "10" "-o=false")
            if [[ $data == "timeout" ]] ; then
                write_log "fatal" "Failed to run kubectl command to get registry auth."
            fi
            local registry_auth=$(echo "${data}" | ${JQ} --raw-output '.data.".dockerconfigjson"' | base64 -d | ${JQ} --raw-output ".auths.\"${DOCKER_REPOSITORY}\".auth")
            pullImage "$registry_auth" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_PAUSE}"
            if [[ $IS_MASTER == "true" ]] ; then
                pullImage "$registry_auth" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_ETCD}"
                pullImage "$registry_auth" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KUBE_APISERVER}"
                pullImage "$registry_auth" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KUBE_SCHEDULER}"
                pullImage "$registry_auth" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KUBE_CONTROLLER_MANAGER}"
                if [[ ! -z ${HA_VIRTUAL_IP} ]] ; then
                    pullImage "$registry_auth" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KEEPALIVED}"
                fi
                pullImage "$registry_auth" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_ITOM_REGISTRY}"
            fi
            pullImage "$registry_auth" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KUBE_PROXY}"
            pullImage "$registry_auth" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_FLANNEL}"
            stopRolling
            write_log "info" "     Pull $type images successfully"
        fi
        return
    fi

    local package_list=()
    write_log "info" "     Pushing $type images ..."
    startRolling
    if [[ "$type" == "infra" ]]; then
        package_list=(${MASTER_PACKAGES_INFRA[@]})
    elif [[ "$type" == "apphub" ]]; then
        package_list=(${MASTER_PACKAGES_CDF[@]})
    fi

    local image_count=${#package_list[@]}
    local current_count=0
    local middlepath=
    if [[ $type == "infra" ]] ; then
        middlepath="k8s"
    elif [[ $type == "apphub" ]] ; then
        middlepath="cdf"
    fi

    # push images directly with the tgz files, master images contains all images needed
    if [[ $UPGRADE_INFRA == "true" ]] && [[ $isFirstMaster == "true" ]]; then
        # test registry connectivity
        write_log "debug" "${CURRENT_DIR}/scripts/uploadimages.sh --probe-only --auth '\$AUTH' -o '${REGISTRY_ORGNAME}' -y --silent"
        execCmdWithRetry "${CURRENT_DIR}/scripts/uploadimages.sh --probe-only --auth '$AUTH' -o '${REGISTRY_ORGNAME}' -y --silent" "" "3" "-m=false"
        [[ $? != 0 ]] && write_log "fatal" "Failed to connect to registry, please make sure your user name, password and network/proxy configuration are correct."

        for packageName in ${package_list[@]} ; do
            local result          
            result=$(exec_cmd "${CURRENT_DIR}/scripts/uploadimages.sh --image-file '${CURRENT_DIR}/${middlepath}/images/${packageName}-images.tgz' --auth '$AUTH' -o '${REGISTRY_ORGNAME}' --tmp-folder '$UPGRADE_TMP_FOLDER' -c 4 -t 10 -y --silent 1>>$LOGFILE" -p=true -ms -mre '(auth\s)\S*')
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to push $type images, $result"
            fi
        done
    fi
    stopRolling
    write_log "info" "     Push $type images successfully"

    if [[ $UPGRADE_INFRA == "true" ]] && [[ $type == "infra" ]]; then
        write_log "info" "     Pulling required images..."
        startRolling
        pullImage $AUTH ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_PAUSE}
        if [[ $IS_MASTER == "true" ]] ; then
            pullImage $AUTH ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_ETCD}
            pullImage $AUTH ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KUBE_APISERVER}
            pullImage $AUTH ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KUBE_SCHEDULER}
            pullImage $AUTH ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KUBE_CONTROLLER_MANAGER}
            if [[ ! -z ${HA_VIRTUAL_IP} ]] ; then
                pullImage $AUTH ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KEEPALIVED}
            fi
            pullImage $AUTH ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_ITOM_REGISTRY}
        fi
        pullImage $AUTH ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_KUBE_PROXY}
        pullImage $AUTH ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_FLANNEL}
        stopRolling
        write_log "info" "     Pull $type images successfully"
    fi
}

pullImage(){
    local auth=$1
    local image=$2
    local authParam="--auth $auth"
    if [[ $auth == "" ]] || [[ $auth == "null" ]]; then
        write_log "debug" "Pull images in anonymous mode"
        authParam=""
    fi
    write_log "debug" "Try to pull image : $image"
    execCmdWithRetry "crictl pull $authParam $image" "" "5" "-m=false"
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to pull image $image"
    fi
}

checkSystemdSvc(){
    local svcName=$1
    exec_cmd "systemctl status ${svcName}"
    return $?
}

isServiceActive(){
    local svcName=$1
    local output
    output="$(exec_cmd "systemctl is-active $svcName" -p=true)"
    if [[ "$output" == "active" ]] || [[ "$output" == "activating" ]];then
        return 0
    else
        return 1
    fi
}

stopSystemdSvc(){
    local svcName=$1
    local retryTimes=0
    write_log "info" "     Stopping ${svcName} service ..."
    while true ; do
        exec_cmd "systemctl stop ${svcName}"
        if [[ $? == 0 ]] ; then
            exec_cmd "systemctl disable ${svcName}" -p=false
            write_log "debug" "Stopped ${svcName} service successfully."
            break
        else
            if [[ $retryTimes -lt $RETRY_TIMES ]] ; then
                ((retryTimes++))
                write_log "debug" "Failed to stop ${svcName} service. Wait for 5 seconds and recheck: $reTryTimes"
                sleep 5
            else
                write_log "fatal" "The ${svcName} service stop failed."
            fi
        fi
    done
}

# reload & restart(optional) system svc
restartSystemdSvc(){
    svcName=$1
    write_log "info" "     Restarting ${svcName} service ..."
    exec_cmd "systemctl restart ${svcName}" -p=false
    local reTryTimes=0
    while [ $(exec_cmd "systemctl status ${svcName}" -p=false; echo $?) -ne 0 ]; do
        reTryTimes=$(( $reTryTimes + 1 ))
        if [ $reTryTimes -eq 60 ]; then
            write_log "fatal" "Failed to start ${svcName} service."
        else
            echo -ne "."
            write_log "debug" "${svcName} service is not running. Wait for 5 seconds and recheck: $reTryTimes"
        fi
        sleep 5
    done
    exec_cmd "systemctl enable ${svcName}" -p=false
}

reloadSystemdSvc(){
    svcName=$1
    write_log "info" "     Reloading ${svcName} daemon ..."
    local SECONDS=0
    while [[ $(exec_cmd "systemctl daemon-reload" -p=false; echo $?) != 0 ]]; do       
        ((SECONDS++)) 
        if [[ ${SECONDS} == ${TIMEOUT_FOR_SERVICES} ]]; then     
            write_log "fatal" "A timeout occurred while waiting for reloading ${svcName} daemon."
        fi
        sleep 1
    done
    exec_cmd "systemctl enable ${svcName}" -p=false
}

isFirstMasterNode(){
    local firstmaster=false
    local timeoutFlag=false
    local reTryTimes=0
    local this_node=
    #verify whether hostname or ip is the same as the THIS_NODE inside env.sh 
    this_node=$(getThisNode "${THIS_NODE}")
    if [[ -z $this_node ]]; then
        firstmaster=nodeInfoChange
        echo $firstmaster
        return
    fi
    while [[ $(exec_cmd "kubectl get configmap first-node-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE}"; echo $?) -ne 0 ]] ; do
        if [[ $IS_MASTER != "true" ]] ; then
            firstmaster=errorNode
            echo $firstmaster
            return
        fi
        local all_nodes=
        local foundInClusterFlag=false
        all_nodes=$(exec_cmd "kubectl get nodes --no-headers | awk '{print \$1}' | xargs | tr '[:upper:]' '[:lower:]'" -p=true)
        for temp_node in ${all_nodes} ; do
            if [[ $temp_node == $this_node ]] ; then
                foundInClusterFlag=true
            fi
        done
        if [[ $foundInClusterFlag == "false" ]] ; then
            #both this_node value inside env.sh and hostname are different from the value inside the cluster
            firstmaster=nodeInfoTotallyChange
            echo $firstmaster
            return
        fi
        exec_cmd "kubectl create configmap first-node-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE} --from-literal=FIRST_NODE=${THIS_NODE} --from-literal=UPGRADE_VERSION=${TARGET_INTERNAL_RELEASE}"
        if [[ $? != 0 ]] ;  then
            if [[ $reTryTimes -eq $RETRY_TIMES ]]; then
                timeoutFlag=true
                break
            else
                reTryTimes=$(( $reTryTimes + 1 ))
                write_log "debug" "Failed to create configmap first-node-configmap-${TARGET_INTERNAL_RELEASE}. Wait for $SLEEP_TIME seconds and recheck: $reTryTimes"
                sleep $SLEEP_TIME
            fi
        fi
    done
    local first_node=
    first_node=$(exec_cmd "kubectl get configmap first-node-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE} -o json | ${JQ} -r '.data.FIRST_NODE?'" -p=true)
    local upgrade_version=
    upgrade_version=$(exec_cmd "kubectl get configmap first-node-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE} -o json | ${JQ} -r '.data.UPGRADE_VERSION?'" -p=true)
    if [[ ${first_node} == ${THIS_NODE} ]] ; then
        firstmaster=true
    fi
    if [[ $upgrade_version != "${TARGET_INTERNAL_RELEASE}" ]] ; then
        firstmaster=errorNode
    fi
    if [[ ${timeoutFlag} == true ]] ; then
        firstmaster=timeout
    fi
    echo $firstmaster
}

isLastMasterNode(){
    local lastmaster=false
    local upgradedMasterNodes=($(getUpgradedMasterNodes "${MASTER_NODES[*]}"))
    if [ $(( ${#MASTER_NODES[@]}-1 )) -eq  ${#upgradedMasterNodes[@]} ]; then
        lastmaster=true
    fi
    echo $lastmaster
}

removePods(){
    local status=$1
    local grepString=""
    for namespace in ${CDF_NAMESPACE} ${KUBE_SYSTEM_NAMESPACE}
    do
        local flag=continue
        while [[ "${flag}" == "continue" ]]; do
            local podCount=0
            local returnCode=
            podCountTemp=$(exec_cmd "kubectl get pods -n $namespace 2>/dev/null" -p=true)
            returnCode=$?
            if [[ ${returnCode} -eq 0 ]] ; then
                flag=break
                podCount=$(exec_cmd "echo '${podCountTemp}'|grep \"$status\"${grepString}|wc -l" -p=true)
            fi
            if [[ ${podCount} -gt 0 ]]; then
                for pod in `exec_cmd "echo '${podCountTemp}'|grep \"$status\"${grepString}|awk '{print \\$1}'" -p=true`; do
                    write_log "info" "     $namespace: $pod  -- $status"
                    exec_cmd "kubectl delete pod $pod -n $namespace --grace-period=0 --force" -p=false
                done
            fi
        done
    done
}

removeAbnormalPods(){
    write_log "info" "     Removing abnormal pods ... "
    for pod_status in "Terminating" "Init:Error" "Init:CrashLoopBackOff" "Unknown" "Init:0" "ContainerCreating" "MatchNodeSelector" "Evicted" "ImageInspectError"
    do
        removePods $pod_status
    done
}

checkEtcdReady(){
    if [[ ! -f ${UPGRADE_TEMP}/upgrade_etcd_time  ]] ; then
        write_log "fatal" "Key file upgrade_etcd_time doesn't exist. Please contact CPE for help."
    fi
    local upgrade_etcd_time=$(exec_cmd "cat ${UPGRADE_TEMP}/upgrade_etcd_time" -p=true)
    local etcdContainer=
    local reTryTimes=0
    local maxReTryTimes=120
    local sleepTime=10
    echo -ne "     "
    while true; do
        etcdContainer=$(exec_cmd "crictl ps --state running --name etcd -q" -p=true)
        if [[ $etcdContainer != "" ]] ; then
            etcdJson=$(exec_cmd "crictl inspect $etcdContainer" -p=true)
            if [[ $? == 0 ]] ; then
                startTimeStamp=$(echo $etcdJson | ${JQ} -r ".status.createdAt?")
                if [[ $startTimeStamp != "" ]] || [[ $startTimeStamp != "null" ]] ; then
                    #transfer to seconds since 1970-01-01 00:00:00 UTC
                    etcd_start_time=$(exec_cmd "date \"+%s\" -d \"${startTimeStamp}\" 2>/dev/null" -p=true)
                    if [[ $? == 0 ]] ; then
                        if [[ ${etcd_start_time} -gt ${upgrade_etcd_time} ]] ; then
                            exec_cmd "${CDF_HOME}/bin/etcdctl ${ETCD_SSL_CONN_PARAM} --endpoints https://${THIS_NODE}:4001 get / --prefix --keys-only=true >/dev/null"
                            if [[ $? == 0 ]] ; then
                                break
                            fi
                        fi
                    fi
                fi
            fi
        fi
        reTryTimes=$(( $reTryTimes + 1 ))
        if [[ $reTryTimes -eq $maxReTryTimes ]]; then
            write_log "fatal" "Timeout happened when trying to start ETCD service."
        else
            write_log "debug" "This etcd node is not running. Wait for $sleepTime seconds and recheck: $reTryTimes"
            write_log "debug" "Check etcd image..." 
            local image_name=${IMAGE_ETCD%%:*}
            local image_tag=${IMAGE_ETCD##*:}
            exec_cmd "crictl images | grep $image_name | grep $image_tag"
            echo -ne "."
        fi
        sleep $sleepTime
    done
}

upgradeEtcd(){
    write_log "info" "\n     Updating Etcd service ..."
    if [[ ! -f ${UPGRADE_TEMP}/etcd_complete ]] ; then
        if [ ! -f "${CDF_HOME}/manifests/etcd.yaml" ] ; then 
            write_log "fatal" "Missing file: ${CDF_HOME}/manifests/etcd.yaml"
        fi
        # replace script placeholders
        replacePlaceHolder ${CDF_HOME}/manifests/etcd.yaml
        # upgrade check
        componentUpgradeCheck "etcd"
        if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
            write_log "info" "     ETCD version didn't change. No need to upgrade ETCD."
            exec_cmd "touch ${UPGRADE_TEMP}/etcd_complete"
            return
        fi
        exec_cmd "touch ${UPGRADE_TEMP}/etcd_upgrade_start"
        exec_cmd "chmod 700 ${RUNTIME_CDFDATA_HOME}/etcd/data"
        # record Etcd yaml apply timestamp
        if [[ ! -f ${UPGRADE_TEMP}/upgrade_etcd_time ]] ; then
            #recond time which is seconds since 1970-01-01 00:00:00 UTC
            exec_cmd "echo \$(date \"+%s\") > ${UPGRADE_TEMP}/upgrade_etcd_time"
            #check if the time exist
            local upgrade_etcd_time=$(cat ${UPGRADE_TEMP}/upgrade_etcd_time)
            write_log "debug" "upgrade_etcd_time: $upgrade_etcd_time"
            if [[ -z $upgrade_etcd_time ]] ; then
                write_log "fatal" "Failed to record etcd upgrade timestamp. Please retry for upgrade."
            fi
        fi
        # Etcd is static pod, upgrade by updating yaml file
        exec_cmd "${CP} -f ${CDF_HOME}/manifests/etcd.yaml ${CDF_HOME}/runconf/etcd.yaml"
        #restart kubelet service
        restartSystemdSvc "kubelet"
        write_log "info" "     Checking ETCD Service ..."
        # Wait for etcd to come up
        checkEtcdReady
        execCmdWithRetry "kubectl get nodes" "300"
        write_log "info" "The ETCD service is running."
        exec_cmd "touch ${UPGRADE_TEMP}/etcd_complete"
    else
        write_log "info" "     ETCD service have already been updated. Proceeding to the next step."
    fi
}

patchFlannelCfg(){
    write_log "debug" "Patch flannel-cfg cm for node ${THIS_NODE}..."
    local jsonData="export KUBERNETES_SERVICE_HOST=${K8S_MASTER_IP}"

    if [ "${IS_MASTER}" == "true" ]; then
        jsonData="export KUBERNETES_SERVICE_HOST=${THIS_NODE}"
    fi

    if [ -n "${FLANNEL_IFACE}" ]; then
        jsonData="${jsonData}\nexport FLANNELD_IFACE=${FLANNEL_IFACE}"
    fi

    execCmdWithRetry "kubectl patch cm kube-flannel-cfg -n ${KUBE_SYSTEM_NAMESPACE} -p '{\"data\": { \"${THIS_NODE}\": \"${jsonData}\" }}'" "20" "5"
    [[ $? != 0 ]] && write_log "fatal" "Failed to patch configmap kube-flannel-cfg in $KUBE_SYSTEM_NAMESPACE namespace."
    
    write_log "debug" "Patched flannel-cfg for node ${THIS_NODE}"
}

upgradeFlannel(){
    write_log "info" "\n     Updating flannel service ..."
    if [[ ! -f ${UPGRADE_TEMP}/flannel_complete ]] ; then
        if [[ ! -f "${CDF_HOME}/objectdefs/flannel.yaml" ]] ; then 
            write_log "fatal" "Missing file: ${CDF_HOME}/objectdefs/flannel.yaml"
        fi
        replacePlaceHolder ${CDF_HOME}/objectdefs/flannel-config.yaml
        replacePlaceHolder ${CDF_HOME}/objectdefs/flannel.yaml
        # upgrade check
        componentUpgradeCheck "flannel"
        if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
            write_log "info" "     Flannel version didn't change. No need to upgrade flannel."
            exec_cmd "touch ${UPGRADE_TEMP}/flannel_complete"
            return
        fi

        startRolling
        #update flannel cfg 
        redeployYamlFile ${CDF_HOME}/objectdefs/flannel-config.yaml
        patchFlannelCfg
        # notice that flannel is in LAST_NODE_YAML_LIST
        redeployYamlFile ${CDF_HOME}/objectdefs/flannel.yaml
    
        execCmdWithRetry "kubectl rollout status ds kube-flannel-ds-amd64 -n ${KUBE_SYSTEM_NAMESPACE} 1>>$LOGFILE 2>&1" "" "3"
        exit_code=$?
        stopRolling
        [[ $exit_code != 0 ]] && write_log "fatal" "Failed to rolling update daemonset flannel..." || write_log "info" "     Rolling update daemonset flannel successfully."
        exec_cmd "touch ${UPGRADE_TEMP}/flannel_complete"
    else
        write_log "info" "     Flannel service have already been updated. Proceeding to the next step."
    fi
}

tplRemoveBeginToEnd(){
    local file=$1
    local name=$2
    exec_cmd "sed -i -r -e '/# {0,}-{1,}BEGIN $name-{1,}/,/# {0,}-{1,}END $name-{1,}/d' '$file'"
}

replacePlaceHolder(){
    file=$1
    local fileName=$(basename ${file})
    local k8sImagesNameList=
    [[ -f ${K8S_IMAGE_PROPERTIES} ]] && k8sImagesNameList=$(cat ${K8S_IMAGE_PROPERTIES} | awk -F= '{print $1 }' | xargs)
    local cdfImagesNameList=
    [[ -f ${IMAGE_PROPERTIES} ]] && cdfImagesNameList=$(cat ${IMAGE_PROPERTIES} | awk -F= '{print $1 }' | xargs)
    local allImagesNameList="${k8sImagesNameList} ${cdfImagesNameList}"

    if [[ $IPV6 == "false" ]] ; then
        # enable single stack ipv4
        tplRemoveBeginToEnd "$file" "DUALSTACK"
        sed -i -e "s%,{IPV6_SERVICE_CIDR}%%g" $file
        sed -i -e "s%,{IPV6_POD_CIDR}%%g" $file
    else
        # enable single dual stack
        tplRemoveBeginToEnd "$file" "SINGLESTACK_IPV4"
    fi
    sed -i -r -e '/# {0,}-{1,}(BEGIN|END) {0,}(SINGLESTACK_IPV4|DUALSTACK)/d' "$file"
    write_log "debug" "     Replacing placeholder in file: $(${LS} ${file})"
    #notice the placeholder KUBE_SYSTEM_NAMESPACE here is by default CDF_NAMESPACE because some yamls still use it as CDF_NAMESPACE
    sed -i -e "s%{KUBE_SYSTEM_NAMESPACE}%${CDF_NAMESPACE}%g" $file
    sed -i -e "s%{CDF_NAMESPACE}%${CDF_NAMESPACE}%g" $file
    sed -i -e "s%{THIS_NODE}%${THIS_NODE}%g" $file
    sed -i -e "s%{MASTER_API_PORT}%${MASTER_API_PORT}%g" $file
    sed -i -e "s%{MASTER_API_SSL_PORT}%${MASTER_API_SSL_PORT}%g" $file
    sed -i -e "s%{SERVICE_CIDR}%${SERVICE_CIDR}%g" $file
    sed -i -e "s%{IPV6_SERVICE_CIDR}%${IPV6_SERVICE_CIDR}%g" $file
    sed -i -e "s%{K8S_HOME}%${K8S_HOME}%g" $file
    sed -i -e "s%{CDF_HOME}%${CDF_HOME}%g" $file
    sed -i -e "s%{K8S_MASTER_IP}%${K8S_MASTER_IP}%g" $file
    sed -i -e "s%{CLUSTER_NODESELECT}%${CLUSTER_NODESELECT}%g" $file
    sed -i -e "s%{BASEINFRA_VAULT_APPROLE}%${BASEINFRA_VAULT_APPROLE}%g" $file
    sed -i -e "s%{THIS_HOSTNAME}%${THIS_HOSTNAME}%g" $file
    sed -i -e "s%{DNS_SVC_IP}%${DNS_SVC_IP}%g" $file
    sed -i -e "s%{DNS_DOMAIN}%${DNS_DOMAIN}%g" $file
    sed -i -e "s%{NFS_STORAGE_SIZE}%${NFS_STORAGE_SIZE}%g" $file
    sed -i -e "s%{NFS_FOLDER}%${NFS_FOLDER}%g" $file
    sed -i -e "s%{NFS_SERVER}%${NFS_SERVER}%g" $file
    sed -i -e "s%{ETCD_ENDPOINT}%${ETCD_ENDPOINT}%g" $file
    sed -i -e "s%{MULTI_SUITE}%${MULTI_SUITE}%g" $file
    sed -i -e "s%{REGISTRY_ORGNAME}%${REGISTRY_ORGNAME}%g" $file 
    sed -i -e "s%{SYSTEM_USER_ID}%${SYSTEM_USER_ID}%g" $file
    sed -i -e "s%{SYSTEM_GROUP_ID}%${SYSTEM_GROUP_ID}%g" $file

    sed -i -e "s%{K8S_USER_ID}%${K8S_USER_ID}%g" $file
    sed -i -e "s%{K8S_GROUP_ID}%${K8S_GROUP_ID}%g" $file
    sed -i -e "s%{ETCD_USER_ID}%${ETCD_USER_ID}%g" $file
    sed -i -e "s%{ETCD_GROUP_ID}%${ETCD_GROUP_ID}%g" $file

    sed -i -e "s@{METADATA_MOUNT_DEF}@- name: suite-metadata\n          mountPath: /usr/share/nginx/html/metadata\n          subPath: suite-install\n        - name: suite-metadata\n          mountPath: /usr/share/nginx/html/download\n          subPath: suite-install/downloadzip@g" $file
    DB_SSL_ENABLED_TEMP="\"${DB_SSL_ENABLED}\""
    sed -i -e "s%{DB_SSL_ENABLED}%${DB_SSL_ENABLED_TEMP}%g" $file
    if [[ "${file}" == "${CDF_HOME}/ssl/kubeconfig" ]] ; then
        sed -i -e "s@{HOME_DIR}@/etc/kubernetes@g" $file
    elif [[ "${file}" == "${CDF_HOME}/ssl/native.kubeconfig" ]] ; then
        sed -i -e "s@{HOME_DIR}@${CDF_HOME}@g" $file
    fi
    sed -i -e "s@{POD_CIDR}@${POD_CIDR}@g" $file
    sed -i -e "s%{IPV6_POD_CIDR}%${IPV6_POD_CIDR}%g" $file
    sed -i -e "s@{FAIL_SWAP_ON}@${FAIL_SWAP_ON}@g" $file
    sed -i -e "s@{RESTART_POLICY}@${RESTART_POLICY}@g" $file
    sed -i -e "s@{NODE_LABELS}@${NODE_LABELS}@g" $file
    sed -i -e "s@{RUNTIME_CDFDATA_HOME}@${RUNTIME_CDFDATA_HOME}@g" $file
    sed -i -e "s@{KUBELET_HOME}@${KUBELET_HOME}@g" $file
    # keepalive params
    sed -i -e "s@{HA_VIRTUAL_IP}@${HA_VIRTUAL_IP}@g" $file
    sed -i -e "s@{INAME}@${INAME}@g" $file
    sed -i -e "s@{LOCAL_IP}@${LOCAL_IP}@g" $file
    sed -i -e "s@{CLOUD_PROVIDER}@${CLOUD_PROVIDER}@g" $file
    sed -i -e "s@{K8S_PROVIDER}@${K8S_PROVIDER}@g" $file
    sed -i -e "s@{AWS_REGION_OPTION}@${AWS_REGION_OPTION}@g" $file
    sed -i -e "s@{AWS_EIP_OPTION}@${AWS_EIP_OPTION}@g" $file
    sed -i -e "s@{AZURE_OPTION}@${AZURE_OPTION}@g" $file
    # etcd params
    sed -i -e "s@{initial_cluster}@${INITIAL_CLUSTER}@g" $file
    sed -i -e "s@{initial_cluster_state}@${INITIAL_CLUSTER_STATE}@g" $file
    # kubeconfig
    sed -i -e "s@{K8S_APISERVER_IP}@${K8S_APISERVER_IP}@g" $file
    # kubelet-config
    sed -i -e "s@{KUBELET_PROTECT_KERNEL_DEFAULTS}@${KUBELET_PROTECT_KERNEL_DEFAULTS}@g" $file
    sed -i -e "s@{INSTALL_MODE}@${INSTALL_MODE}@g" $file
    if [[ -n $RESOLV_CONF ]] ; then
        sed -i -e "s@{RESOLV_CONF}@${RESOLV_CONF}@g" $file
    else
        sed -i -e '/{RESOLV_CONF}/ d' $file
    fi
    sed -i -e "s@{imageGCHighThresholdPercent}@${imageGCHighThresholdPercent}@g" $file
    sed -i -e "s@{imageGCLowThresholdPercent}@${imageGCLowThresholdPercent}@g" $file
    sed -i -e "s@{nodeImagefsAvailable}@${nodeImagefsAvailable}@g" $file

    #added placeholders for flannel.yaml
    sed -i -e "s@{FLANNEL_BACKEND_TYPE}@${FLANNEL_BACKEND_TYPE}@g" $file
    sed -i -e "s@{FLANNEL_PORT}@${FLANNEL_PORT}@g" $file
    sed -i -e "s@{FLANNEL_DIRECTROUTING}@${FLANNEL_DIRECTROUTING}@g" $file
    # no directrouting option for host-gw
    if [[ "${FLANNEL_BACKEND_TYPE}" == "host-gw" ]];then
        sed -i -e '/"DirectRouting"/d' $file
    fi
    sed -i -e "s@{POD_CIDR_SUBNETLEN}@${POD_CIDR_SUBNETLEN}@g" $file
    sed -i -e "s%{IPV6_POD_CIDR_SUBNETLEN}%${IPV6_POD_CIDR_SUBNETLEN}%g" $file
    sed -i -e "s@{SUITE_REGISTRY}@${SUITE_REGISTRY}@g" $file
    sed -i -e "s@{DOCKER_REPOSITORY}@${DOCKER_REPOSITORY}@g" $file

    sed -i -e "s@{DEPLOYMENT_TYPE}@${DEPLOYMENT_TYPE}@g" $file
    sed -i -e "s@{DEPLOYMENT_NAMESPACE}@${DEPLOYMENT_NAMESPACE}@g" $file
    sed -i -e "s@{DEPLOYMENT_MODE}@${DEPLOYMENT_MODE}@g" $file

    # keepalived
    sed -i -e "s@{FIRST_MASTER_NODE_SELECTOR}@node-role.kubernetes.io/control-plane: \"\"@g" $file
    if [[ "$K8S_PROVIDER" == "cdf-azure" ]] ; then
        sed -i -e "s@{AZURE_CONFIG_VOLUME}@volumeMounts:\n        - name: cloud-azure\n          mountPath: /etc/cdf/keepalived-azure.conf\n          readOnly: true\n      volumes:\n        - name: cloud-azure\n          hostPath:\n            path: ${AZURE_CONFIG_FILE}\n            type: FileOrCreate@g" $file
    else
        sed -i -e "s@{AZURE_CONFIG_VOLUME}@@g" $file
    fi

    #For openshift only
    if [[ "$K8S_PROVIDER" == "openshift" ]]; then
        sed -i -e "s@#{FOR_OPENSHIFT}@@g" $file
    fi

    # replace image name placeholder
    for imagePlaceHolder in ${allImagesNameList} ; do
        eval sed -i -e "s@{${imagePlaceHolder}}@\$${imagePlaceHolder}@g" $file
    done

    # containerd-config
    sed -i -e "s@{SNAPSHOTTER}@overlayfs@g" $file
    sed -i -e "s@{THINPOOL_NAME}@@g" $file

    #replace tls related placeholders
    if [[ -z "$TLS_MIN_VERSION" ]] || [[ $TLS_MIN_VERSION == "null" ]] ; then
        TLS_MIN_VERSION=${DEFAULT_TLS_MIN_VERSION}
    fi
    sed -i -e "s@{TLS_MIN_VERSION}@$TLS_MIN_VERSION@g" $file
    if [[ -z "$TLS_CIPHERS" ]] || [[ $TLS_CIPHERS == "null" ]] ; then
        TLS_CIPHERS=${DEFAULT_TLS_CIPHERS}
    fi
    sed -i -e "s@{TLS_CIPHERS}@$TLS_CIPHERS@g" $file
    sed -i -e "s@{GOLANG_TLS_CIPHERS}@${GOLANG_TLS_CIPHERS}@g" $file
    ETCD_TLS_MIN_VERSION=${EtcdTLSVerMap[$TLS_MIN_VERSION]}
    sed -i -e "s@{ETCD_TLS_MIN_VERSION}@${ETCD_TLS_MIN_VERSION}@g" $file
    KUBE_TLS_MIN_VERSION=${K8sTLSVerMap[$TLS_MIN_VERSION]}
    sed -i -e "s@{KUBE_TLS_MIN_VERSION}@${KUBE_TLS_MIN_VERSION}@g" $file
}

copyOrFail() {
    srcFile=$1
    dstFile=$2
    #write_log "info" "     Copying $srcFile to $dstFile ..."
    exec_cmd "${CP} -rf $srcFile $dstFile" -p=false
    if [[ $? -ne 0 ]] ; then
        write_log "fatal" "Failed to copy $srcFile to $dstFile."
    fi
}

checkYamlChange(){
    local origin=$1
    local new=$2
    exec_cmd "diff $origin $new 2>&1 >/dev/null"
    if [[ $? != 0 ]] ; then 
        echo "true"
    else
        echo "false"
    fi
}

getLowerVersion(){
    local currentV=$1
    local expectedV=$2
    local currentVersion=
    currentVersion=$(echo "$currentV" | cut -d '-' -f1)
    local currentPreRelease=
    currentPreRelease=$(echo "$currentV" | cut -d '-' -f2)
    local expectedVersion=
    expectedVersion=$(echo "$expectedV" | cut -d '-' -f1)
    local expectedPreRelease=
    expectedPreRelease=$(echo "$expectedV" | cut -d '-' -f2)

    # grep -E '([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z]+(\.[0-9A-Za-z]+)*))?(?:\+([0-9A-Za-z]+(\.[0-9A-Za-z]+)*))?' -o
    if [[ $currentVersion != $expectedVersion ]] ; then
        [[ $(echo -e "$currentVersion\n$expectedVersion"|sort -V|head -n -1) = "$currentVersion" ]] && echo "$currentV" || echo "$expectedV"
    else
        if [[ $currentPreRelease == $currentVersion ]] ; then
            echo "$expectedV"
        elif [[ $expectedPreRelease == $expectedVersion ]] ; then
            echo "$currentV"
        else
            [[ $(echo -e "$currentPreRelease\n$expectedPreRelease"|sort -V|head -n -1) = "$currentPreRelease" ]] && echo "$currentV" || echo "$expectedV"
        fi
    fi
}

checkApiServer(){
    write_log "info" "     Checking Kubernetes API Server ..."
    local api_pod=
    local api_start_time=
    local upgrade_api_time=0
    local n=0
    local tempJson=
    local yamlChangedFlag=false

    if [[ -f ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S/runconf/kube-apiserver.yaml ]] && [[ -f ${CDF_HOME}/runconf/kube-apiserver.yaml ]] ; then
        yamlChangedFlag=$(checkYamlChange "${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S/runconf/kube-apiserver.yaml" "${CDF_HOME}/runconf/kube-apiserver.yaml")
    fi
    write_log "debug" "The result of yamlChangedFlag : $yamlChangedFlag"
    echo -ne "     "
    while true; do
        local exit_code_openapi=
        exec_cmd "curl --silent --head --fail --cacert ${CDF_HOME}/ssl/ca.crt --cert ${CDF_HOME}/ssl/kubectl-kube-api-client.crt --key ${CDF_HOME}/ssl/kubectl-kube-api-client.key --noproxy ${K8S_APISERVER_IP} https://${K8S_APISERVER_IP}:${MASTER_API_SSL_PORT}/openapi/v2" -p=false
        exit_code_openapi=$?
        if (( n > ${TIMEOUT_FOR_SERVICES} )) ; then
            write_log "fatal" "A timeout occurred while waiting for the API Server to start."
        elif [[ $exit_code_openapi == 0 ]] ; then
            api_pod=$(exec_cmd "kubectl get pods -n ${KUBE_SYSTEM_NAMESPACE} -o wide | grep apiserver | grep -v cdf-apiserver | grep -v heapster-apiserver | grep ${K8S_APISERVER_IP} | awk '{print \$1}'" -p=true)
            exec_cmd "kubectl get pod ${api_pod} -n ${KUBE_SYSTEM_NAMESPACE} -o json > ${UPGRADE_TEMP}/apiserverTempJson"
            api_start_time=$(exec_cmd "cat ${UPGRADE_TEMP}/apiserverTempJson | ${JQ} -r '.status?.containerStatuses[]?.state?.running?.startedAt?'" -p=true)
            if [[ ${api_start_time} == "null" ]] || [[ ${api_start_time} == "" ]] ; then
                write_log "debug" "The value of api_start_time is null"
                n=$((n+1))
                sleep 2
                echo -ne "."
                continue
            fi
            #transfer to seconds since 1970-01-01 00:00:00 UTC
            api_start_time=$(exec_cmd "date \"+%s\" -d \"${api_start_time}\" 2>/dev/null" -p=true)
            if [[ $? != 0 ]] ; then
                write_log "debug" "Date transfer not right."
                n=$((n+1))
                sleep 2
                echo -ne "."
                continue
            fi
            if [[ ! -f ${UPGRADE_TEMP}/upgrade_api_time ]] && [[ ${yamlChangedFlag} == "true" ]] ; then
                write_log "fatal" "Key file upgrade_api_time not found. Please contact CPE for help."
            fi
            if [[ -f ${UPGRADE_TEMP}/upgrade_api_time ]] ; then
                upgrade_api_time=$(exec_cmd "cat ${UPGRADE_TEMP}/upgrade_api_time" -p=true)
            fi
            write_log "debug" "upgrade_api_time: $upgrade_api_time"
            #If cdf api start time is newer than its upgrade time, it means the pod has restarted.
            if [[ ${yamlChangedFlag} == "true" ]] && [[ ${api_start_time} -ge ${upgrade_api_time} ]] || [[ ${yamlChangedFlag} == "false" ]]; then
                write_log "info" "The API Server is running."
                break
            fi
        fi
        n=$((n+1))
        sleep 2
        echo -ne "."
    done
}

componentUpgradeCheck(){
    COMPONENT_UPGRADE_FLAG=false
    local componentName=$1
    local currentVersion=$(cat ${CDF_HOME}/moduleVersion.json | ${JQ} -r ".[] | select (.name == \"k8s\" ) | .componentLists[] | select (.name == \"${componentName}\") | .version")
    local currentInternalVersion=$(cat ${CDF_HOME}/moduleVersion.json | ${JQ} -r ".[] | select (.name == \"k8s\" ) | .componentLists[] | select (.name == \"${componentName}\") | .internalVersion")
    local targetVersion=$(cat ${CURRENT_DIR}/moduleVersion.json | ${JQ} -r ".[] | select (.name == \"k8s\" ) | .componentLists[] | select (.name == \"${componentName}\") | .version")
    local targetInternalVersion=$(cat ${CURRENT_DIR}/moduleVersion.json | ${JQ} -r ".[] | select (.name == \"k8s\" ) | .componentLists[] | select (.name == \"${componentName}\") | .internalVersion")
    write_log "debug" "componentName: $componentName, currentVersion: $currentVersion, currentInternalVersion: $currentInternalVersion, targetVersion: $targetVersion, targetInternalVersion: $targetInternalVersion"
    
    local lowerVersion=
    local lowerInternalVersion=
    lowerVersion=$(getLowerVersion $currentVersion $targetVersion)
    write_log "debug" "lowerVersion: $lowerVersion"
    if [[ $lowerVersion == $targetVersion ]] && [[ $currentVersion != $targetVersion ]]; then
        write_log "debug" "No need to upgrade $componentName. currentVersion:$currentVersion is higher than targetVersion:$targetVersion"
    else
        if [[ $currentVersion == $targetVersion ]] ; then
            lowerInternalVersion=$(getLowerVersion $currentInternalVersion $targetInternalVersion)
            write_log "debug" "lowerInternalVersion: $lowerInternalVersion"
            if [[ $lowerInternalVersion == $currentInternalVersion ]] && [[ $currentInternalVersion != $targetInternalVersion ]]; then
                write_log "debug" "$componentName needs to upgrade. targetInternalVersion:$targetInternalVersion is higher than currentInternalVersion:$currentInternalVersion"
                COMPONENT_UPGRADE_FLAG=true
            else
                write_log "debug" "$componentName currentInternalVersion:$currentInternalVersion is higher than or equal to targetInternalVersion:$targetInternalVersion, no need to upgrade."
            fi
        else
            write_log "debug" "$componentName needs to upgrade. TargetVersion:$targetVersion is higher than CurrentVersion: $currentVersion"
            COMPONENT_UPGRADE_FLAG=true
        fi
    fi
}

upgradeApiServer(){
    write_log "info" "     Updating Kubernetes API Server ... "
    componentUpgradeCheck "apiserver"
    if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
        write_log "info" "     API Server version is up to date. No need to upgrade Kubernetes API Server."
        return
    fi

    #copy kube-apiserver.yaml from installation package to $CDF_HOME
    exec_cmd "${CP} -rf ${CURRENT_DIR}/k8s/manifests/kube-apiserver.yaml ${CDF_HOME}/manifests/."

    replacePlaceHolder "${CDF_HOME}/manifests/kube-apiserver.yaml"
    #update apiserver-encryption.yaml
    exec_cmd "${CP} -rf ${CURRENT_DIR}/k8s/cfg/apiserver-encryption.yaml ${CDF_HOME}/cfg/."
    #check encryption configuration
    if [[ ! -f ${UPGRADE_TEMP}/kube-apiserver-orignal.yaml ]] || [[ ! -f ${UPGRADE_TEMP}/apiserver-encryption-orignal.yaml ]] ; then
        write_log "fatal" "File lost detected. Please check whether ${UPGRADE_TEMP}/kube-apiserver-orignal.yaml and ${UPGRADE_TEMP}/apiserver-encryption-orignal.yaml exist or not."
    fi
    exec_cmd "cat ${UPGRADE_TEMP}/kube-apiserver-orignal.yaml | grep encryption-provider-config="
    if [[ $? != 0 ]]; then
        exec_cmd "sed -i '/encryption-provider-config/d' ${CDF_HOME}/manifests/kube-apiserver.yaml"
    else
        local secret=$(cat ${UPGRADE_TEMP}/apiserver-encryption-orignal.yaml | grep "secret:" | awk '{print $2}')
        #In encoder for Base64, you will not see special characters except:
        #[A-Z][a-z][0-9][+/] and the padding char '=' at the end to indicate the number of zero fill bytes
        #So for sed command, it is safe to use @ char.
        exec_cmd "sed -i 's@{SECRET}@${secret}@g' ${CDF_HOME}/cfg/apiserver-encryption.yaml" -m=false -o=false -d=false
    fi
    exec_cmd "chown -R ${K8S_USER_ID} ${CDF_HOME}/cfg/apiserver-encryption.yaml"
    #check k8s audit
    if [[ $ENABLE_K8S_AUDIT_LOG == "true" ]]; then
        write_log "debug" "Enable K8S ApiServer audit log"
        exec_cmd "mkdir -p ${CDF_HOME}/log/audit/kube-apiserver"
        exec_cmd "chown -R ${K8S_USER_ID} ${CDF_HOME}/log/audit/kube-apiserver"
        # Enable audit log by uncomment associated config in yaml
        exec_cmd "sed -i -e 's@#{AUDIT_LOG}@@g' ${CDF_HOME}/manifests/kube-apiserver.yaml"
    fi
    #upgrade kube-apiserver rbac configuration
    createFromYaml "${CDF_HOME}/objectdefs/k8s-rbac-config.yaml"
    #upgrade kube-apiserver
    copyOrFail "${CDF_HOME}/manifests/kube-apiserver.yaml" "${CDF_HOME}/runconf/kube-apiserver.yaml"
}

upgradeControllerManager(){
    write_log "info" "     Updating Kubernetes Controller Manager ... "
    componentUpgradeCheck "controller"
    if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
        write_log "info" "     Controller Manager version is up to date. No need to upgrade Kubernetes Controller Manager."
        return
    fi

    exec_cmd "${CP} -rf ${CURRENT_DIR}/k8s/manifests/kube-controller-manager.yaml ${CDF_HOME}/manifests/."
    exec_cmd "${CP} -rf ${CURRENT_DIR}/k8s/cfg/controller-manager/recycler.yaml ${CDF_HOME}/cfg/controller-manager/."
    replacePlaceHolder "${CDF_HOME}/manifests/kube-controller-manager.yaml"
    replacePlaceHolder "${CDF_HOME}/cfg/controller-manager/recycler.yaml"
    copyOrFail "${CDF_HOME}/manifests/kube-controller-manager.yaml" "${CDF_HOME}/runconf/kube-controller-manager.yaml"
}

upgradeScheduler(){
    write_log "info" "     Updating Kubernetes Scheduler ... "
    componentUpgradeCheck "controller"
    if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
        write_log "info" "     Scheduler version is up to date. No need to upgrade Kubernetes Scheduler."
        return
    fi
    exec_cmd "${CP} -rf ${CURRENT_DIR}/k8s/manifests/kube-scheduler.yaml ${CDF_HOME}/manifests/."
    replacePlaceHolder "${CDF_HOME}/manifests/kube-scheduler.yaml"
    copyOrFail "${CDF_HOME}/manifests/kube-scheduler.yaml" "${CDF_HOME}/runconf/kube-scheduler.yaml"
}

deleteFromYaml(){
    local yamlfile=$1
    local localApiserverFlag=$2
    write_log "info" "     Deleting resources from YAML: $yamlfile"
    local n=0
    # local k8sServer="--server=https://${K8S_MASTER_IP}:${MASTER_API_SSL_PORT}"
    # if [[ "${BYOK}" == "true" ]] || [[ $UPGRADE_CDF == "true" ]] || [[ $localApiserverFlag == "true" ]]; then
    #     k8sServer=""
    # fi
    while true
    do
        ###In case some time in one yaml include multi resouces if one resouce exists the kubectl describe -f also return 1, so we cannot check whether those resouces are all deleted or not, so we replaced tihs filter.
        if [ $(exec_cmd "kubectl ${k8sServer} describe -f $yamlfile" -p=true|grep -v "not found"|wc -l) -gt 0 ]
        then
            exec_cmd "kubectl ${k8sServer} delete -f $yamlfile" && break
            n=$((n+1))
            if [ $n -ge 3 ]; then
               write_log "fatal" "Failed to delete resources from YAML: $yamlfile"
            fi
        else
            write_log "warn" "     Resources from YAML: $yamlfile have already deleted."
            break
        fi
        sleep 5
    done
}

createFromYaml(){
    local yamlfile=$1
    local localApiserverFlag=$2
    write_log "info" "     Applying resources from YAML: $yamlfile"
    # local k8sServer="--server=https://${K8S_MASTER_IP}:${MASTER_API_SSL_PORT}"
    # if [[ "${BYOK}" == "true" ]] || [[ $UPGRADE_CDF == "true" ]] || [[ $localApiserverFlag == "true" ]]; then
    #     k8sServer=""
    # fi
    execCmdWithRetry "kubectl ${k8sServer} apply -f $yamlfile" "" "3"
    [[ $? != 0 ]] && write_log "fatal" "Failed to apply yaml $yamlfile"
}

doRedeploy() {
    local yamlfile=$1
    local filename=$(basename $yamlfile)
    local middlepath=

    local originyamlfile=
    local originfilename=
    local originmiddlepath=

    local notApplyFlag=$2
    local newYamlFlag=$3
    local localApiserverFlag=$4

    # local k8sServer="--server=https://${K8S_MASTER_IP}:${MASTER_API_SSL_PORT}"
    # if [[ ${localApiserverFlag} == "true" ]] ; then
    #     local k8sServer=""
    # fi
    
    #middlepath format example : middlepath should remove / from head and tail
    #/opt/kubernetes/objectdefs/kube-dns.yaml to /objectdefs/kube-dns.yaml then to /objectdefs/ to objectdefs
    middlepath=${yamlfile#*${CDF_HOME}}
    middlepath=${middlepath%${filename}*}
    middlepath=${middlepath#*/}
    middlepath=${middlepath%/*}

    originfilename=$(echo "$YAML_NAME_MAP" | ${JQ} -r ".\"${filename}\"?")
    if [[ ! -z $originfilename ]] && [[ $originfilename != null ]] ; then
        originyamlfile="${originfilename}"
    else
        originyamlfile="${filename}"
    fi

    #originmiddlepath should have no / on head and tail
    originmiddlepath=$(echo "$YAML_PATH_MAP" | ${JQ} -r ".\"${originfilename}\"?")
    if [[ $originmiddlepath != null ]]  ; then
        originyamlfile="${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S/${originmiddlepath}/${originyamlfile}"
    else
        originyamlfile="${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/K8S/${middlepath}/${originyamlfile}"
    fi
    write_log "debug" "originyamlfile: $originyamlfile"

    if [[ ${notApplyFlag} == "true" ]] ; then
        if [[ ${newYamlFlag} == "true" ]] ; then
            deleteFromYaml "${yamlfile}" "${localApiserverFlag}"
        else
            deleteFromYaml "${originyamlfile}" "${localApiserverFlag}"
        fi
        createFromYaml "${yamlfile}" "${localApiserverFlag}"
    else
        createFromYaml "${yamlfile}" "${localApiserverFlag}"
    fi
}

#redeployYamlFile has re-run inside
redeployYamlFile(){
    local yamlfile=$1
    local filename=$(basename $yamlfile)
    local lastFlag="false"
    local lastMasterFlag="false"
    local notApplyFlag="false"
    local newYamlFlag="false"
    local localApiserverFlag="false"

    for lastNodeYaml in ${LAST_NODE_YAML_LIST[@]} ; do
        if [[ "${lastNodeYaml}" == "${filename}" ]] ; then
            lastFlag="true"
            break
        fi
    done
    write_log "debug" "lastFlag: $lastFlag"

    for lastMasterYaml in ${LAST_MASTER_YAML_LIST[@]} ; do
        if [[ "${lastMasterYaml}" == "${filename}" ]] ; then
            lastMasterFlag="true"
            break
        fi
    done
    write_log "debug" "lastMasterFlag: $lastMasterFlag"

    for notApplyYaml in ${NOT_APPLY_YAML_LIST[@]} ; do
        if [[ "${notApplyYaml}" == "${filename}" ]] ; then
            notApplyFlag="true"
            break
        fi
    done
    write_log "debug" "notApplyFlag:$notApplyFlag"

    for newYaml in ${NEW_YAML_LIST[@]} ; do
        if [[ "${newYaml}" == "${filename}" ]] ; then
            newYamlFlag="true"
            break
        fi
    done
    write_log "debug" "newYamlFlag:$newYamlFlag"
    
    for localApiserverYaml in ${LOCAL_APISERVER_YAML_LIST[@]} ; do
        if [[ "${localApiserverYaml}" == "${filename}" ]] ; then
            localApiserverFlag="true"
            break
        fi
    done
    write_log "debug" "localApiserverFlag:$localApiserverFlag"
    
    write_log "debug" "isFirstMaster:$isFirstMaster"
    write_log "debug" "isLastMaster:$isLastMaster"
    write_log "debug" "IS_LAST_NODE:$IS_LAST_NODE"
    if [[ "$isFirstMaster" == "true" ]] && [[ ${lastFlag} == "false" ]] && [[ ${lastMasterFlag} == "false" ]] ; then
        write_log "debug" "Do components upgrade on first master node."
        doRedeploy "${yamlfile}" "${notApplyFlag}" "${newYamlFlag}" "${localApiserverFlag}"
    elif [[ ${isLastMaster} == "true"  ]]  && [[ ${lastMasterFlag} == "true" ]] ; then
        write_log "debug" "Do components upgrade on last master node."
        doRedeploy "${yamlfile}" "${notApplyFlag}" "${newYamlFlag}" "${localApiserverFlag}"
    elif [[ "$IS_LAST_NODE" == "true" ]] && [[ ${lastFlag} == "true" ]] ; then
        write_log "debug" "Do components upgrade on last node."
        doRedeploy "${yamlfile}" "${notApplyFlag}" "${newYamlFlag}" "${localApiserverFlag}"
    else
        write_log "debug" "No need to do node level components upgrade on this node."
    fi
}

upgradeKeepAlive() {
    write_log "info" "\n     Updating Keepalived ..."
    if [[ ! -f ${UPGRADE_TEMP}/keepalive_complete ]] ; then
        # Multi-master has HA option so that Keepalived should work.
        if [ ! -z ${HA_VIRTUAL_IP} ] ; then
            componentUpgradeCheck "keepalived"
            if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
                write_log "info" "     Keepalived version didn't change. No need to upgrade keepalived."
                exec_cmd "touch ${UPGRADE_TEMP}/keepalive_complete"
                return
            fi
            write_log "info" "     Starting keepalived for the API Server ..."
            replacePlaceHolder $CDF_HOME/objectdefs/keepalived.yaml

            # notice that keepalive is in LAST_MASTER_YAML_LIST
            redeployYamlFile $CDF_HOME/objectdefs/keepalived.yaml
            startRolling
            execCmdWithRetry "kubectl rollout status ds itom-cdf-keepalived -n ${KUBE_SYSTEM_NAMESPACE} 1>>$LOGFILE 2>&1" "" "3"
            exit_code=$?
            stopRolling
            [[ $exit_code != 0 ]] && write_log "fatal" "Failed to rolling update daemonset keepalive..." || write_log "info" "     Rolling update daemonset keepalive successfully."
            checkDaemontSetReady "itom-cdf-keepalived" "${KUBE_SYSTEM_NAMESPACE}"
            exec_cmd "touch ${UPGRADE_TEMP}/keepalive_complete"
        fi
    else
        write_log "info" "     Keepalived service has already been updated. Proceeding to the next step."
    fi
}

upgradeDNSSvc() {
    write_log "info" "\n     Updating Kubernetes DNS service ..."
    if [[ ! -f ${UPGRADE_TEMP}/dns_complete ]] ; then
        replacePlaceHolder $CDF_HOME/objectdefs/coredns.yaml
        if [ -z "$HA_VIRTUAL_IP" -a -z "$LOAD_BALANCER_HOST" ]; then
            HOST_ALIASES="hostAliases:\n      - ip: \"${IP_ADDRESS}\"\n        hostnames:\n        - \"${HOSTNAMES}\""
            sed -i -e "s@{HOST_ALIASES}@$HOST_ALIASES@g" $CDF_HOME/objectdefs/coredns.yaml
        else
            sed -i -e "s@{HOST_ALIASES}@@g" $CDF_HOME/objectdefs/coredns.yaml
        fi

        #check if non-dns
        if [[ $NON_DNS_ENV == "true" ]] ; then
            write_log "debug" "This is non-dns environment. Remove forward plugin from coredns conf file."
            sed -i -e '/forward.*\/etc\/resolv.conf/d' $CDF_HOME/objectdefs/coredns.yaml
        fi
        # upgrade check
        componentUpgradeCheck "coredns"
        if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
            write_log "info" "     Coredns version didn't change. No need to upgrade coredns."
            exec_cmd "touch ${UPGRADE_TEMP}/dns_complete"
            return
        fi
        startRolling
        redeployYamlFile $CDF_HOME/objectdefs/coredns.yaml
        execCmdWithRetry "kubectl rollout status ds coredns -n ${KUBE_SYSTEM_NAMESPACE} 1>>$LOGFILE 2>&1" "" "3"
        exit_code=$?
        stopRolling
        [[ $exit_code != 0 ]] && write_log "fatal" "Failed to rolling update daemonset coredns..." || write_log "info" "     Rolling update daemonset coredns successfully."
        exec_cmd "touch ${UPGRADE_TEMP}/dns_complete"
    else
        write_log "info" "     Kubernetes DNS service has already been updated. Proceeding to the next step."
    fi
}


#clean up the runtime images which are not in-use
cleanUpRuntimeImages(){
    write_log "info" "     Cleaning up local runtime images ... "
    exec_cmd "crictl rmi --prune"
    return 0
}

getVaildDir() {
    local cur_dir=$1
    if [ -z $cur_dir ]
    then
        return 1
    fi
    if [ -d $cur_dir ]
    then
        echo $cur_dir
    else
        echo $(getVaildDir $(dirname $cur_dir))
    fi
}

checkDeploymentReday(){
    local deployment=$1
    local namespace=$2
    execCmdWithRetry "kubectl rollout status deployment $deployment -n $namespace 1>>$LOGFILE 2>&1" "" "3"
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Deployment $deployment failed to start up."
    fi
}

checkDaemontSetReady(){
    local resName=$1
    local namespace=$2
    local desiredNumberScheduled=
    local numberReady=
    local updatedNumberScheduled=

    local tempJson=
    local retryTimes=0
    while true ; do
        tempJson=$(exec_cmd "kubectl get ds $resName -n $namespace -o json" -p=true)
        if [[ $? != 0 ]] ; then
            if [[ $retryTimes -lt $TIMEOUT_FOR_SERVICES ]] ; then
                ((retryTimes++))
                write_log "debug" "Failed to fetch daemonset status. Wait for 2 seconds and retry: $retryTimes ..."
                sleep 2
                continue
            else
                write_log "fatal" "Failed to fetch daemonset status. Please check kubectl command work."
            fi
        fi
        desiredNumberScheduled=$(echo "$tempJson" | ${JQ} -r '.status.desiredNumberScheduled?')
        numberReady=$(echo "$tempJson" | ${JQ} -r '.status.numberReady?')
        updatedNumberScheduled=$(echo "$tempJson" | ${JQ} -r '.status.updatedNumberScheduled?')
        checkParameters desiredNumberScheduled
        checkParameters numberReady
        checkParameters updatedNumberScheduled
        if [[ $desiredNumberScheduled == $updatedNumberScheduled ]] && [[ $desiredNumberScheduled == $numberReady ]]; then
            write_log "debug" "Daemonset $resName ready."
            break
        else
            if [[ $retryTimes -lt $TIMEOUT_FOR_SERVICES ]] ; then
                write_log "debug" "Daemonset $resName is not ready.. Wait for 2 seconds and retry: $retryTimes"
                ((retryTimes++))
                sleep 2
            else
                write_log "fatal" "Daemonset $resName is not ready."
            fi
        fi
    done
}

setBYOKENV(){
    write_log "info" "     Setting BYOK environment files ..."
    if [[ ! -f ${UPGRADE_TEMP}/set_byok_env_complete ]] ; then
        write_log "info" "     Copying itom-cdf.sh to HOME folder..."
        echo "# itom cdf env" > ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export CDF_HOME=${CDF_HOME}" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export CDF_NAMESPACE=${CDF_NAMESPACE}" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export VELERO_NAMESPACE=${CDF_NAMESPACE}" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export PATH=\${CDF_HOME}/bin:\$PATH" >> ${UPGRADE_TEMP}/itom-cdf.sh
        echo "export TMP_FOLDER=${TMP_FOLDER}" >> ${UPGRADE_TEMP}/itom-cdf.sh
        exec_cmd "chmod 644 ${UPGRADE_TEMP}/itom-cdf.sh"
        exec_cmd "${CP} -rpf ${UPGRADE_TEMP}/itom-cdf.sh  $HOME/itom-cdf.sh"
        if [[ $? != 0 ]] ; then
            write_log "fatal" "Failed to copy ${UPGRADE_TEMP}/itom-cdf.sh to '$HOME'. Please check your current user permission or sudo user configuration."
        fi
        exec_cmd "touch ${UPGRADE_TEMP}/set_byok_env_complete"
    else
        write_log "debug" "BYOK env has already been set."
    fi
}

copyBYOKBin(){
    write_log "info" "     Copying Scripts..." #rename?
    if [[ ! -f ${UPGRADE_TEMP}/copy_byok_bins_complete ]] ; then
        if [[ ! -d ${CDF_HOME} ]] ; then
            exec_cmd "mkdir -p ${CDF_HOME}" || write_log "fatal" "Failed to create ${CDF_HOME}. Please check your user permission or sudo configuraiton."
        fi
        #copy necessary scripts/binaries
        exec_cmd "${CURRENT_DIR}/copyTools.sh -y" || write_log "fatal" "Failed to copy package to ${CDF_HOME}. Please check your user permission or sudo configuraiton."
        exec_cmd "touch ${UPGRADE_TEMP}/copy_byok_bins_complete"
    else
        write_log "debug" "BYOK scripts already copied."
    fi

    exec_cmd "${RM} -rf /etc/profile.d/itom-cdf-alias.sh" || write_log "warn" "Warning! You have no permission to remove /etc/profile.d/itom-cdf-alias.sh, please contact the administrator for help."
    exec_cmd "${RM} -rf /etc/profile.d/itom-cdf.sh" || write_log "warn" "Warning! You have no permission to remove /etc/profile.d/itom-cdf.sh, please contact the administrator for help."
}

checkIfBYOK(){
    #the upgrade package on Classic and BYOK are different
    if [[ -f ${CURRENT_DIR}/k8s/bin/kubectl ]] ; then
        # IF someone runs classic upgrade on BYOK
        if [[ -z ${K8S_HOME} ]] || [[ ! -d ${K8S_HOME} ]] ; then
            echo "Sorry, you can't upgrade BYOK environment with CLASSIC upgrade package. If you are running on CLASSIC environment, K8S_HOME can not be found."
            exit 1
        fi
        BYOK=false
    else
        if [[ -n ${K8S_HOME} ]] && [[ -d ${K8S_HOME} ]] ; then
            echo "Sorry, you can't upgrade CLASSIC environment with BYOK upgrade package."
            exit 1
        fi
        BYOK=true
    fi
}

checkCDFEnv(){
    if [[ -z ${CDF_HOME} ]] || [[ ! -d ${CDF_HOME} ]]; then
        local msg
        if [[ $BYOK == "true" ]] ; then
            msg="Failed to find CDF_HOME. Please make sure CDF_HOME is in $HOME/itom-cdf.sh"
        else
            msg="Failed to find CDF_HOME. Please make sure CDF_HOME is in /etc/profile.d/itom-cdf.sh"
        fi
        echo "$msg" 
        exit 1
    fi
}

getEnvInfo(){
    if [[ "$UPGRADE_INFRA" == "true" ]]; then
        #Check CDF_NAMESPACE available
        if [[ -z ${CDF_NAMESPACE} ]] ; then
            local msg="Failed to find CDF_NAMESPACE. Please make sure CDF_NAMESPACE is in /etc/profile.d/itom-cdf.sh"
            write_log "fatal" "$msg" 
        fi
    elif [[ "$UPGRADE_CDF" == "true" ]]; then
        #Check CDF_NAMESPACE available
        if [[ -z ${CDF_NAMESPACE} ]] ; then
            checkHelmalive
            exec_cmd "${HELM} list -A | grep -E 'apphub-[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+'"
            if [[ $? != 0 ]] ; then
                #if no CDF release, and no CDF_NAMESPACE, it means user only install CDF tools
                TOOLS_ONLY=true
            fi
            if [[ $TOOLS_ONLY == "true" ]] ; then
                write_log "info" "\nCurrently, only Tools capability is enabled. Upgrade will only update tools for this environment."
                return
            else
                local msg
                if [[ $BYOK == "true" ]] ; then
                    msg="Failed to find CDF_NAMESPACE. Please make sure CDF_NAMESPACE is in $HOME/itom-cdf.sh"
                else
                    msg="Failed to find CDF_NAMESPACE. Please make sure CDF_NAMESPACE is in /etc/profile.d/itom-cdf.sh"
                fi
                write_log "fatal" "$msg" 
            fi
        fi
    fi
}

initGlobalValues(){
    getEnvInfo
    getVersionInfo
    #-i session
    if [[ "$UPGRADE_INFRA" == "true" ]]; then
        UPGRADE_TEMP="${UPGRADE_DATA}/upgrade_infra_${TARGET_INTERNAL_RELEASE}"
        
        getResource "cm" "cdf-cluster-host" "${CDF_NAMESPACE}" ".data.INFRA_VERSION"
        if [[ $? != 0 ]] ; then
            write_log "fatal" "Failed to get INFRA_VERSION."
        fi

        UPGRADE_MF_K8S_ONLY=false

        getResource "cm" "cdf" "${CDF_NAMESPACE}" ".data.PLATFORM_VERSION"
        if [[ $? != 0 ]] ; then
            UPGRADE_MF_K8S_ONLY=true
            write_log "debug" "No cdf chart deployed. MF K8S only."
        fi

    #-u session
    elif [[ "$UPGRADE_CDF" == "true" ]]; then
        #if tools-only env, no need to continue
        [[ $TOOLS_ONLY == "true" ]] && return

        UPGRADE_TEMP="${UPGRADE_DATA}/upgrade_cdf_${TARGET_INTERNAL_RELEASE}"
        BACKUP_DIR=CDF_${FROM_INTERNAL_RELEASE}_BACKUP

        checkHelmalive
        CDF_CHART_RELEASE=$(${HELM} list -n ${CDF_NAMESPACE} -a 2>/dev/null | grep -E 'apphub-[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+' | awk '{print $1}' | xargs)
        CDF_CHART_RELEASE_LIST=($CDF_CHART_RELEASE)
        [[ ${#CDF_CHART_RELEASE_LIST[@]} != 1 ]] && write_log "fatal" "Unsupported scenario! More than one Apphub chart release is found in ${CDF_NAMESPACE} namespace. CDF_CHART_RELEASE_LIST: $CDF_CHART_RELEASE"
        [[ $(${HELM} list -A 2>>$LOGFILE | grep -E 'apphub-[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+'| wc -l) -gt 1 ]] && write_log "warn" "Warning! Multiple $CDF_CHART_RELEASE instances are identified in this cluster. The upgrade will only upgrade $CDF_CHART_RELEASE in $CDF_NAMESPACE namespace ."

        checkHelmalive
        ORIGINAL_YAML=$(${HELM} get values ${CDF_CHART_RELEASE} -n ${CDF_NAMESPACE} -o yaml 2>>$LOGFILE) || write_log "fatal" "Failed to get $CDF_CHART_RELEASE chart values"

        getValueInContent ".global.services.clusterManagement" "$ORIGINAL_YAML"
        CLUSTER_MANAGEMENT=${RESULT}
        
        getValueInContent ".global.services.deploymentManagement" "$ORIGINAL_YAML"
        DEPLOYMENT_MANAGEMENT=${RESULT}

        getValueInContent ".global.services.suiteDeploymentManagement" "$ORIGINAL_YAML"
        SUITE_DEPLOYMENT_MANAGEMENT=${RESULT}

        getValueInContent ".global.services.monitoring" "$ORIGINAL_YAML"
        MONITORING=${RESULT}

        checkParameters CLUSTER_MANAGEMENT
        checkParameters DEPLOYMENT_MANAGEMENT
        checkParameters SUITE_DEPLOYMENT_MANAGEMENT
        checkParameters MONITORING
    fi
}

upgradeTools(){
    if [[ $TOOLS_ONLY == "true" ]] ; then
        #copy necessary scripts/binaries
        write_log "info" "\n** Upgrading tools in $CDF_HOME ..."
        exec_cmd "${CURRENT_DIR}/copyTools.sh -y" || write_log "fatal" "Failed to copy tools package to ${CDF_HOME}. Please check your user permission or sudo configuraiton."
        write_log "info" "     Successfully completed Tools upgrade process."
        exit 0
    fi
}

gtf(){
    echo "$1 $2" | awk '{if ($1 > $2) print 0; else print 1}'
}

gef(){
    echo "$1 $2" | awk '{if ($1 >= $2) print 0; else print 1}'
}

ltf(){
    echo "$1 $2" | awk '{if ($1 < $2) print 0; else print 1}'
}

lef(){
    echo "$1 $2" | awk '{if ($1 <= $2) print 0; else print 1}'
}

calculateInternalK8sUpgradeChain(){
    local version=$(echo "$1" | sed 's/v//g')
    #Format Version
    #Example: v1.25.2 to 1.25
    version=${version%.*}
    local found=false
    local index=0
    for i in $K8S_UPGRADE_CHAIN ; do
        if [[ $index == "0" ]] ; then
            if [[ $(ltf $version $i) -eq 0 ]] ; then
                #current version is lower than the lowest intermediate version, all verisons in the chain are requried
                found=true
            fi
        fi
        if [[ "$version" == "$i" ]] ; then
            #found start point, the ones from the next should be the intermediate version
            found=true
            ((index++))
            continue
        fi
        if [[ $found == "true" ]] ; then
            DYNAMIC_INTERNAL_UPGRADE_CHAIN="${DYNAMIC_INTERNAL_UPGRADE_CHAIN} ${i}"
        fi
        ((index++))
    done
}

printSteps(){
    local index=0
    write_log "warn" "\nWarning! You are trying to upgrade from $FROM_VERSION to $TARGET_VERSION directly, BUT some manual steps are requried."
    write_log "warn" "Please follow the steps below firstly before executing the current upgrade:"
    for folder in ${DYNAMIC_INTERNAL_UPGRADE_CHAIN} ; do
        ((index++))
        write_log "info" "$index)  Run command '$CURRENT_DIR/packages/${folder}/upgrade.sh -i' on the each control-plane nodes one after one."
        ((index++))
        write_log "info" "$index)  Run command '$CURRENT_DIR/packages/${folder}/upgrade.sh -i' on the each worker nodes one after one."
    done
    exit 2
}

#verify only when DYNAMIC_INTERNAL_UPGRADE_CHAIN is empty
verifyCurrentK8sInternalVersion(){
    local version=$(echo "$1" | sed 's/v//g')
    #Format Version
    #Example: v1.25.2 to 1.25
    version=${version%.*}
    write_log "debug" "currentK8sInternalVersion: ${version}"

    local k8sUpgradeChain=($K8S_UPGRADE_CHAIN)
    local len=${#k8sUpgradeChain[@]}
    if [[ $len -gt 0 ]] ; then
        if [[ $(gef $version ${k8sUpgradeChain[$len-1]}) -eq 0 ]] ; then
            # version >= k8sUpgradeChain[0]
            write_log "info" "     Current internal K8s version $version is higher than or equal to the highest requried intermediate K8s version ${k8sUpgradeChain[$len-1]}."
            return 0
        elif [[ $(gtf $version ${k8sUpgradeChain[0]}) -eq 0 ]] && [[ $(ltf $version ${k8sUpgradeChain[$len-1]}) -eq 0 ]]; then
            # k8sUpgradeChian[0] < version < k8sUpgradeChian[n-1], notice the chain is a array, if the version is inside the range but hit on no intermediate version in the array, it is not supported
            write_log "fatal" "     Current internal K8s version $version is not in the supported intermediate K8s version list: [$K8S_UPGRADE_CHAIN]" 
        else
            # version < k8sUpgradeChain[0], DYNAMIC_INTERNAL_UPGRADE_CHAIN is always not null in this case, it is no way to enter here.
            write_log "fatal" "     Oops! It should not to be here. Please contact CPE for help."
        fi
    fi
}

printLeastRequiredVersion(){
    local bottenFromVersion=$(cat ${CURRENT_DIR}/infrastructureDependency.json | ${JQ} -r ".[] | select ( .targetVersion == \"${TARGET_INTERNAL_RELEASE}\") | .supportedFromVersion[0]")
    write_log "error" "Current build ${TARGET_VERSION} can NOT be used to upgrade currently installed ${FROM_VERSION} cluster. "
    write_log "error" "You need to upgrade the cluster to ${ReleaseVersionMap[${bottenFromVersion}]} at least! Then you can perform the current upgrade."
}

calculateUpgradeSteps(){
    DYNAMIC_INTERNAL_UPGRADE_CHAIN=
    #calculate k8s upgrade chain
    local currentK8sInternalVersion=$(cat ${CDF_HOME}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "k8s"  )' | ${JQ} -r '.internalVersion')
    if [[ $currentK8sInternalVersion == "" ]] || [[ $currentK8sInternalVersion == "null" ]] ; then
        write_log "fatal" "failed to find K8s internalVersion in ${CDF_HOME}/moduleVersion.json"
    fi
    calculateInternalK8sUpgradeChain "${currentK8sInternalVersion}"
    write_log "debug" "DYNAMIC_INTERNAL_UPGRADE_CHAIN: ${DYNAMIC_INTERNAL_UPGRADE_CHAIN}"

    if [[ ${DYNAMIC_INTERNAL_UPGRADE_CHAIN} == "" ]] ; then
        verifyCurrentK8sInternalVersion "${currentK8sInternalVersion}"
        if [[ $? != 0 ]] ; then
            printLeastRequiredVersion
            exit 1
        fi
    else
        printSteps
    fi
}

findInternalK8sVersion(){
    for ver in $K8S_UPGRADE_CHAIN ; do
        local inVer=$(cat $CURRENT_DIR/packages/$ver/moduleVersion.json | ${JQ} -r '.[] | select ( .name == "k8s") | .internalVersion')
        K8S_INTERNAL_VERSION_LIST="$K8S_INTERNAL_VERSION_LIST $inVer"
    done
}

checkInterK8sUpgradeInProgress(){
    for k8sVer in $K8S_INTERNAL_VERSION_LIST ; do
        getResource "cm" "upgraded-nodes-configmap-$k8sVer" "${CDF_NAMESPACE}" "."
        if [[ $? == 0 ]] ; then
            write_log "fatal" "Attention! Intermediate K8s upgrade is still in progress. Please finish upgrading the cluster to K8s $k8sVer first."
        fi
    done
}

checkB2BUpgradeInProgress(){
    getResource "cm" "cdf-upgrade-in-process" "${CDF_NAMESPACE}" ".data.TARGET_INTERNAL_VERSION"
    if [[ $RESULT != "" ]] && [[ $RESULT != "null" ]] && [[ $RESULT != "$TARGET_INTERNAL_VERSION" ]] ; then
        getResource "cm" "cdf-upgrade-in-process" "${CDF_NAMESPACE}" ".data.TARGET_VERSION"
        write_log "fatal" "\nPlease make sure to finish upgrading Apphub components to build $RESULT, then you can continue to upgrade to build $TARGET_VERSION."
    fi

    getResource "cm" "infra-upgrade-in-process" "${CDF_NAMESPACE}" ".data.TARGET_INTERNAL_VERSION"
    if [[ $RESULT != "" ]] && [[ $RESULT != "null" ]] && [[ $RESULT != "$TARGET_INTERNAL_VERSION" ]] ; then
        getResource "cm" "infra-upgrade-in-process" "${CDF_NAMESPACE}" ".data.TARGET_VERSION"
        write_log "fatal" "\nPlease make sure to finish upgrading the cluster to build $RESULT, then you can continue to upgrade to build $TARGET_VERSION."
    fi
}

askForConfirm(){
    if [[ "${FORCE_YES}" == "true" ]] ; then
        input="Y"
    else
        read -p "Please confirm to continue (Y/N): " input
    fi
    if [ "$input" == "Y" -o "$input" == "y" -o "$input" == "yes" -o "$input" == "Yes" -o "$input" == "YES" ] ; then
        write_log "info" "Confirmed. Continue to upgrade."
    else
        write_log "info" "Denied. Quit upgrade."
        exit 1
    fi
}

preCheck(){
    #check infra version
    write_log "info" "\n** Pre-checking before upgrade ... ${STEP_CONT}"
    # infra version check - upgrade logic check should not be inside upgradePreCheck
    write_log "debug" "FROM_VERSION: $FROM_VERSION, FROM_INTERNAL_RELEASE: $FROM_INTERNAL_RELEASE, FROM_BUILD_NUM: $FROM_BUILD_NUM"

    if [[ "${FROM_INTERNAL_RELEASE}" == "${TARGET_INTERNAL_RELEASE}" ]] ; then
        if [[ $FROM_BUILD_NUM -eq $TARGET_BUILD_NUM ]] ; then
            write_log "info" "     Infrastructure version on this node is already ${TARGET_VERSION}. No need to upgrade."
            exit 0
        elif [[ $TARGET_BUILD_NUM -lt $FROM_BUILD_NUM ]] ; then
            write_log "fatal" "     Sorry, it is not allowed to downgrade from $FROM_VERSION to $TARGET_VERSION."
        else
            BUILD2BUILD_UPGRADE=true
            write_log "info" "     User decides to upgrade the infrastructure from build $FROM_VERSION to build $TARGET_VERSION."
        fi
    fi
    checkB2BUpgradeInProgress
    if [[ $BUILD2BUILD_UPGRADE != "true" ]] ; then
        SUPPORTTED_INFRA_FROM_RELEASE_VERSION=$(cat ${CURRENT_DIR}/infrastructureDependency.json | ${JQ} -r ".[] | select ( .targetVersion == \"${TARGET_INTERNAL_RELEASE}\") | .supportedFromVersion[]" | xargs)
        K8S_UPGRADE_CHAIN=$(cat ${CURRENT_DIR}/infrastructureDependency.json | ${JQ} -r ".[] | select ( .targetVersion == \"${TARGET_INTERNAL_RELEASE}\") | .k8sUpgradeChain[]" | xargs)
        K8S_INTERNAL_VERSION_LIST=
        findInternalK8sVersion
        checkParameters SUPPORTTED_INFRA_FROM_RELEASE_VERSION
        if [[ "$SUPPORTTED_INFRA_FROM_RELEASE_VERSION" =~ "${FROM_INTERNAL_RELEASE}" ]] ; then
            checkInterK8sUpgradeInProgress
            calculateUpgradeSteps
            write_log "info" "     Infrastructure version on this node is ${FROM_VERSION}. Ready to upgrade."
        else
            printLeastRequiredVersion
            write_log "fatal" "\nPlease follow the upgrade guidance mentioned above before proceeding with the current upgrade. More details can be found in the Upgrade Matrix section of the official document."
        fi
    fi

    createUpgradeTempFolder
    if [[ $IS_MASTER == "true" ]] ;then
        params='-p {"noderole":"master","caller":"manual"}'
    else
        params='-p {"noderole":"worker","caller":"manual"}'
    fi
    if [[ ! -f ${UPGRADE_TEMP}/upgradePreCheck_pass ]] ; then
        #TODO: support build-to-build upgrade, code changes is requried
        if [[ $BUILD2BUILD_UPGRADE != "true" ]] ; then
            ${CURRENT_DIR}/scripts/upgradePreCheck -f ${FROM_INTERNAL_RELEASE} -t ${TARGET_INTERNAL_RELEASE} ${params} --infra
        else
            ${CURRENT_DIR}/scripts/upgradePreCheck -f ${TARGET_INTERNAL_RELEASE} -t 999999 ${params} --infra
        fi
        exit_code=$?
        if [[ $exit_code != 0 ]] ; then
            if [[ $exit_code == 2 ]] ; then
                write_log "warn" "\n**Upgrade detected non-certified configurations in your setup. Certified configurations are based on default settings and supported versions of individual components. Where Company has deviated from certified configurations, OpenText reserves the right to recommend the Company to revert to a certified configuration to resolve the reported issues.**"
                askForConfirm
                exec_cmd "touch ${UPGRADE_TEMP}/upgradePreCheck_pass"
            else
                local lastPrechcekLogFile=
                lastPrechcekLogFile=$(exec_cmd "${LS} ${CDF_HOME}/log/upgradePreCheck -t | head -n1 |awk '{printf \$0}'" -p=true)
                write_log "fatal" "Precheck failed. Quit upgrade. The upgrade precheck log file is ${CDF_HOME}/log/upgradePreCheck/${lastPrechcekLogFile}"
            fi
        else
            exec_cmd "touch ${UPGRADE_TEMP}/upgradePreCheck_pass"
        fi
    fi
}

componentsPreCheck(){
    write_log "info" "\n** Pre-checking before upgrade ..."
    if [[ ${BYOK} == "false" ]] && [[ "${IS_MASTER}" == "false" ]] ; then
        write_log "fatal" "     Command 'upgrade.sh -u' must run on a control-plane node."
    fi

    #platform version check
    if [[ "${FROM_INTERNAL_RELEASE}" == "${TARGET_INTERNAL_RELEASE}" ]] ; then
        if [[ $TARGET_BUILD_NUM -eq $FROM_BUILD_NUM ]] ; then
            if [[ $TOOLS_ONLY == "false" ]] ; then
                cleanUpgradeConfigmap
                cleanUpgradeTempFolder
            fi
            write_log "info" "     Platform version is already ${TARGET_VERSION}. No need to upgrade."
            exit 0
        elif [[ $TARGET_BUILD_NUM -lt $FROM_BUILD_NUM ]] ; then
            write_log "fatal" "     Sorry, it is not allowed to downgrade from $FROM_VERSION to $TARGET_VERSION."
        else
            BUILD2BUILD_UPGRADE=true
            write_log "info" "     User decides to upgrade Apphub components from build $FROM_VERSION to build $TARGET_VERSION."
        fi
    fi
    checkB2BUpgradeInProgress
    #check current target version -i session finished or not
    if [[ "${UPGRADE_CDF}" == "true" ]] && [[ ${BYOK} != "true" ]] ; then
        exec_cmd "kubectl get cm infra-upgrade-complete-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE}"
        if [[ $? != 0 ]] && [[ $DEVELOPOR_MODE != "true" ]]; then
            write_log "fatal" "Please run command \"${CURRENT_DIR}/upgrade.sh -i\" on all nodes before upgrade Apphub when performing an on-premise upgrade."
        fi
        local ilock=
        ilock=$(exec_cmd "kubectl get cm ilock -n ${CDF_NAMESPACE} -o json" -p=true)
        if [[ $? == 0 ]] && [[ $DEVELOPOR_MODE != "true" ]]; then
            local ilocknode=
            ilocknode=$(exec_cmd "echo '${ilock}' | ${JQ} --raw-output '.data.inode'" -p=true)
            write_log "fatal" "Command \"${CURRENT_DIR}/upgrade.sh -i\" is still running on node ${ilocknode}, please wait for it to complete."
        fi
        exec_cmd "kubectl get cm upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE}"
        if [[ $? == 0 ]] ; then
            local temp_json=
            temp_json=$(getJsonFromCM "upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE}" "${CDF_NAMESPACE}")
            checkTimeOut temp_json
            local upgraded_nodes=
            upgraded_nodes=$(exec_cmd "echo '${temp_json}' | ${JQ} --raw-output '.data.UPGRADED_NODES?'" -p=true)
            allNodes=($(exec_cmd "kubectl get nodes --no-headers | awk '{print \$1}' | xargs | tr '[:upper:]' '[:lower:]'" -p=true))
            local upgradedNodeCount=0
            for cdfNode in ${allNodes[@]} ; do
                for upgradedNode in ${upgraded_nodes[@]} ; do
                    if [[ "${cdfNode}" == "${upgradedNode}" ]] ; then
                        upgradedNodeCount=$((${upgradedNodeCount} + 1 ))
                        break
                    fi
                done
            done
            if [[ ${upgradedNodeCount} != ${#allNodes[@]} ]] ; then
                write_log "warn" "Please finish the -i session on each node first."
                write_log "fatal" "Run command \"${CURRENT_DIR}/upgrade.sh -i\" on all control-plane nodes and all worker nodes before upgrade Apphub."
            fi
        else
            write_log "debug" "No in-progress -i session. Continue to Apphub upgrade."
        fi
    fi
    #if CDF not upgraded, check the upgrade order
    SUPPORTTED_CDF_FROM_RELEASE_VERSION=$(cat ${CURRENT_DIR}/componentDependency.json | ${JQ} -r "select ( .targetVersion == \"${TARGET_INTERNAL_RELEASE}\") | .supportedFromVersion[]" | xargs)
    checkParameters SUPPORTTED_CDF_FROM_RELEASE_VERSION
    if [[ "$SUPPORTTED_CDF_FROM_RELEASE_VERSION" =~ "${FROM_INTERNAL_RELEASE}" ]] ; then
        write_log "debug" "Build ${FROM_VERSION} is supported to upgrade to build ${TARGET_VERSION}."
    else
        if [[ $BUILD2BUILD_UPGRADE == "true" ]] ; then
            write_log "info" "     Current Build: $FROM_VERSION Target Build: $TARGET_VERSION"
        else
            write_log "fatal" "Build ${FROM_VERSION} is not supported to upgrade to build ${TARGET_VERSION}."
        fi
    fi

    if [[ $TOOLS_ONLY == "false" ]] ; then
        createUpgradeTempFolder
        if [[ ! -f ${UPGRADE_TEMP}/upgradePreCheck_pass ]] ; then
            if [[ $BUILD2BUILD_UPGRADE == "true" ]] ; then 
                ${CURRENT_DIR}/scripts/upgradePreCheck -f ${TARGET_INTERNAL_RELEASE} -t 999999 --cdf
            else
                ${CURRENT_DIR}/scripts/upgradePreCheck -f ${FROM_INTERNAL_RELEASE} -t ${TARGET_INTERNAL_RELEASE} --cdf
            fi
            exit_code=$?
            if [[ $exit_code != 0 ]] ; then
                if [[ $exit_code == 2 ]] ; then
                    write_log "warn" "\n**Upgrade detected non-certified configurations in your setup. Certified configurations are based on default settings and supported versions of individual components. Where Company has deviated from certified configurations, OpenText reserves the right to recommend the Company to revert to a certified configuration to resolve the reported issues.**"
                    askForConfirm
                    exec_cmd "touch ${UPGRADE_TEMP}/upgradePreCheck_pass"
                else
                    write_log "fatal" "Precheck failed. Quit upgrade."
                fi
            else
                exec_cmd "touch ${UPGRADE_TEMP}/upgradePreCheck_pass"
            fi
        fi
    fi
}

getLocalIP(){
    local local_ip=
    if [ ! -z "$FLANNEL_IFACE" ]; then
        if [[ $FLANNEL_IFACE =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            local_ip=$FLANNEL_IFACE
        else
            local_ip=$(exec_cmd "ifconfig $FLANNEL_IFACE 2>/dev/null | awk '/netmask/ {print \$2}'" -p=true)
        fi
    else
        if [[ $THIS_NODE =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            local_ip=$THIS_NODE
        else
            local_ip=$(exec_cmd "ip route get 8.8.8.8|sed 's/^.*src \([^ ]*\).*$/\1/;q'" -p=true)
        fi
    fi
    if [ -z $local_ip ]; then
        write_log "fatal" "Failed to get local ip of current node."
    else
        LOCAL_IP=$local_ip
    fi
}

getJsonFromCM() {
    local configmap=$1
    local namespace=$2
    local cmd="kubectl get cm ${configmap} -n ${namespace} -o json"
    local returnValue=
    returnValue=$(getValueWithRetry "${cmd}" "30")
    echo "${returnValue}"
}

execCmdWithRetry() {
    local cmd="$1"
    local retryTimes=1
    local maxTime=${2:-"60"}
    local waitTime=${3:-"1"}
    local cmdExtraOptions=${4:-""}
    while true; do
        exec_cmd "${cmd}" "$cmdExtraOptions"
        if [[ $? == 0 ]] ; then
            return 0
        elif (( $retryTimes >= ${maxTime} )); then
            return 1
        fi
        retryTimes=$(( $retryTimes + 1 ))
        sleep $waitTime
    done
}

getValueWithRetry() {
    local cmd=$1
    local retryTimes=0
    local maxTime=$2
    local returnValue=
    local cmdExtraOptions=${3:-""}
    while true; do
        returnValue=$(exec_cmd "${cmd}" -p=true "$cmdExtraOptions")
        if [[ $? == 0 ]] ; then
            break
        elif (( retryTimes > ${maxTime} )); then
            returnValue="timeout"
            break
        fi
        retryTimes=$(( $retryTimes + 1 ))
        sleep 1
    done
    echo "${returnValue}"
}

dec2bin() {
    local num=$1
    local s=8
    local bin=("")
    while [[ $s -ne 0 ]] ; do
        ((s--))
        if [[ ${num} -ne 0 ]] ; then
            bin[${s}]=$(( ${num} % 2 ))
            num=$(((( ${num} - ${num} % 2 )) / 2 ))
        else
            bin[${s}]=0
        fi
    done
    echo ${bin[@]}|sed s/[[:space:]]//g
}

#FLANNEL_BACKEND_TYPE=host-gw
getIpInSameSubnet() {
    local netAddress[0]=$1
    netAddress[1]=$(exec_cmd "ifconfig|grep ${netAddress[0]}|awk '{print \$4}'" -p=true)
    local all=(${netAddress[@]//[!0-9]/ })
    local a=$(( $((2#$(dec2bin ${all[0]}))) & $((2#$(dec2bin ${all[4]}))) ))
    local b=$(( $((2#$(dec2bin ${all[1]}))) & $((2#$(dec2bin ${all[5]}))) ))
    local c=$(( $((2#$(dec2bin ${all[2]}))) & $((2#$(dec2bin ${all[6]}))) ))
    local d=$(( $((2#$(dec2bin ${all[3]}))) & $((2#$(dec2bin ${all[7]}))) ))
    echo "${a}.${b}.${c}.${d}"
}

checkParameters(){
    local key=$1
    local msg=$2
    if [ "$key" == "MASTER_NODES" ]; then
        local value="${MASTER_NODES[@]}"
    else
        eval local value='$'$key
    fi
    write_log "debug" "key: $key , value: $value"
    if [ -z "$value" -o "$value" = "null" ]; then
        if [[ "$key" == "THIS_NODE" ]] ; then
            write_log "fatal" "This node '$THIS_NODE' is not in the node list [${ALL_NODES}] of the cluster."
        elif [[ -n $msg ]] ; then
            write_log "fatal" "$msg"
        else
            write_log "fatal" "Cannot get value of $key."
        fi
    fi
}

checkTimeOut(){
    local key=$1
    eval local value='$'$key
    if [[ ${value} == "timeout" ]] ; then
        write_log "fatal" "There is a timeout happened when getting the value of ${key}"
    fi
}

configTlsParameters(){
    #TLS_CIPHERS/DEFAULT_TLS_CIPHERS passed by installation is not 100% fit for golang componenets
    #Filter out the suitable ones by calling cdfctl tool 
    local ciphers=${TLS_CIPHERS}
    if [[ -z ${ciphers} ]] || [[ ${ciphers} == "null" ]] ; then
      ciphers=${DEFAULT_TLS_CIPHERS}
    fi

    GOLANG_TLS_CIPHERS=$(exec_cmd "${CURRENT_DIR}/bin/cdfctl tool filter --tls-ciphers ${ciphers}" -p)
    if [[ $? != 0 ]]; then
      write_log "fatal" "Failed to filter out input ciphers, please check params set by --tls-ciphers option."
    fi

    if [[ -z ${GOLANG_TLS_CIPHERS} ]]; then
      write_log "fatal" "No supported ciphers found for Kubernetes components, please check params set by --tls-ciphers option."
    fi
}

gatherParameters(){
    #check whether upgrade.sh -g has been executed
    if [[ -f ${UPGRADE_TEMP}/generate_complete.txt ]] && [[ "$(cat ${UPGRADE_TEMP}/generate_complete.txt)" == "${TARGET_INTERNAL_VERSION}" ]] ; then
        write_log "info" "     infrastructure parameter file was already generated. Proceeding to the next step."
        return
    fi
    getCDFEnv
    
    local file=${UPGRADE_TEMP}/CDF_infra_upgrade_parameters.txt
    local infraCM="cdf-cluster-host"
    local infraCMJson=

    infraCMJson=$(getJsonFromCM "${infraCM}" "${CDF_NAMESPACE}")
    checkTimeOut infraCMJson
    
    ##common##
    ALL_NODES=$(exec_cmd "kubectl get nodes --no-headers | awk '{print \$1}' | xargs | tr '[:upper:]' '[:lower:]'" -p=true)
    MASTER_NODES=($(exec_cmd "kubectl get nodes -l 'node-role.kubernetes.io/master' -o jsonpath='{.items[?(@.kind==\"Node\")].metadata.name}'" -p=true))
    WORKER_NODES=($(exec_cmd "kubectl get nodes -l '!node-role.kubernetes.io/master' -o jsonpath='{.items[?(@.kind==\"Node\")].metadata.name}'" -p=true))
    MASTER_NODES_NUM=${#MASTER_NODES[@]}
    local itom_pv=
    itom_pv=$(exec_cmd "kubectl get pvc -n $CDF_NAMESPACE itom-vol-claim -o json | jq --raw-output '.spec.volumeName'" -p=true)
    NFS_SERVER=$(exec_cmd "kubectl get pv $itom_pv -o json | ${JQ} --raw-output '.spec.nfs.server?'" -p=true)
    NFS_STORAGE_SIZE=$(exec_cmd "kubectl get pv $itom_pv -o json | ${JQ} --raw-output '.spec.capacity.storage?'" -p=true)
    NFS_FOLDER=$(exec_cmd "kubectl get pv $itom_pv -o json | ${JQ} --raw-output '.spec.nfs.path?'" -p=true)
    ETCD_ENDPOINT=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.ETCD_ENDPOINT?'" -p=true)
    K8S_MASTER_IP=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.API_SERVER?'" -p=true)
    CLUSTER_MGMT_ADDR=${K8S_MASTER_IP}
    REGISTRY_ORGNAME=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.REGISTRY_ORGNAME?'" -p=true)
    SYSTEM_USER_ID=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.SYSTEM_USER_ID?'" -p=true)
    SYSTEM_GROUP_ID=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.SYSTEM_GROUP_ID?'" -p=true)

    TLS_MIN_VERSION=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.TLS_MIN_VERSION?'" -p=true)
    TLS_CIPHERS=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.TLS_CIPHERS?'" -p=true)
    configTlsParameters

    K8S_USER_ID=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.K8S_USER_ID?'" -p=true)
    if [[ $K8S_USER_ID == "" ]] || [[ $K8S_USER_ID == "null" ]] ; then
        K8S_USER_ID=${SYSTEM_USER_ID}
    fi

    K8S_GROUP_ID=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.K8S_GROUP_ID?'" -p=true)
    if [[ $K8S_GROUP_ID == "" ]] || [[ $K8S_GROUP_ID == "null" ]] ; then
        K8S_GROUP_ID=${SYSTEM_GROUP_ID}
    fi
    
    ETCD_USER_ID=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.ETCD_USER_ID?'" -p=true)
    if [[ $ETCD_USER_ID == "" ]] || [[ $ETCD_USER_ID == "null" ]] ; then
        ETCD_USER_ID=${SYSTEM_USER_ID}
    fi
    
    ETCD_GROUP_ID=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.ETCD_GROUP_ID?'" -p=true)
    if [[ $ETCD_GROUP_ID == "" ]] || [[ $ETCD_GROUP_ID == "null" ]] ; then
        ETCD_GROUP_ID=${SYSTEM_GROUP_ID}
    fi

    HA_VIRTUAL_IP=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.HA_VIRTUAL_IP?'" -p=true)
    LOAD_BALANCER_HOST=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.LOAD_BALANCER_HOST?'" -p=true)
    CLOUD_PROVIDER=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.CLOUD_PROVIDER?'| tr '[:upper:]' '[:lower:]'" -p=true)
    K8S_PROVIDER=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.K8S_PROVIDER?'" -p=true)
    if [[ $K8S_PROVIDER == "" ]] || [[ $K8S_PROVIDER == "null" ]] ; then
        if [[ $INSTALL_MODE == "CLASSIC" ]] ; then
            if [[ $CLOUD_PROVIDER == "aws" ]] || [[ $CLOUD_PROVIDER == "azure" ]]; then
                K8S_PROVIDER="cdf-${CLOUD_PROVIDER}"
            else
                K8S_PROVIDER="cdf"
            fi
        fi            
    fi
    if [ "$K8S_PROVIDER" == "openshift" ];then
        EXCLUDE_NS="kube-system,default,openshift*"
    else
        EXCLUDE_NS="kube-system,default"
    fi
    AWS_REGION=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.AWS_REGION?'" -p=true)
    AWS_EIP=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.AWS_EIP?'" -p=true)
    ORIGINAL_UPGRADE_PATH=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.UPGRADE_PATH?' | sed -e 's/null//g'" -p=true)
    UPGRADE_PATH=${ORIGINAL_UPGRADE_PATH:-"${FROM_INTERNAL_RELEASE}"}",${TARGET_INTERNAL_RELEASE}"
    SUITE_REGISTRY=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.SUITE_REGISTRY?'" -p=true)
    [[ -z $TMP_FOLDER ]] && TMP_FOLDER=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.TMP_FOLDER?'" -p=true)
    DOCKER_REPOSITORY=${SUITE_REGISTRY}
    CLUSTER_NAME=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.CLUSTER_NAME?'" -p=true)

    ##node level##
    FAIL_SWAP_ON=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.FAIL_SWAP_ON?'" -p=true)
    if [[ "${FAIL_SWAP_ON}" == "null" ]] ; then
        FAIL_SWAP_ON=false
    fi
    MASTER_API_PORT=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.MASTER_API_PORT?'" -p=true)
    MASTER_API_SSL_PORT=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.MASTER_API_SSL_PORT?'" -p=true)
    IPV6=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.IPV6?'" -p=true)
    [[ -z $IPV6 ]] || [[ $IPV6 == "null" ]] && IPV6=false
    POD_CIDR=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.POD_CIDR?'" -p=true)
    IPV6_POD_CIDR=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.IPV6_POD_CIDR?'" -p=true)
    [[ -z $IPV6_POD_CIDR ]] || [[ $IPV6_POD_CIDR == "null" ]] && IPV6_POD_CIDR="fc00::/48"
    SERVICE_CIDR=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.SERVICE_CIDR?'" -p=true)
    IPV6_SERVICE_CIDR=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.IPV6_SERVICE_CIDR?'" -p=true)
    [[ -z $IPV6_SERVICE_CIDR ]] || [[ $IPV6_SERVICE_CIDR == "null" ]] && IPV6_SERVICE_CIDR="fd00::/120"
    K8S_DEFAULT_SVC_IP=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.K8S_DEFAULT_SVC_IP?'" -p=true)
    POD_CIDR_SUBNETLEN=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.POD_CIDR_SUBNETLEN?'" -p=true)
    IPV6_POD_CIDR_SUBNETLEN=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.IPV6_POD_CIDR_SUBNETLEN?'" -p=true)
    [[ -z $IPV6_POD_CIDR_SUBNETLEN ]] || [[ $IPV6_POD_CIDR_SUBNETLEN == "null" ]] && IPV6_POD_CIDR_SUBNETLEN=64
    FLANNEL_BACKEND_TYPE=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.FLANNEL_BACKEND_TYPE?'" -p=true)
    FLANNEL_PORT=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.FLANNEL_PORT?'" -p=true)
    if [[ $FLANNEL_PORT == "" ]] || [[ $FLANNEL_PORT == "null" ]] ; then
        FLANNEL_PORT="8472"
    fi
    FLANNEL_DIRECTROUTING=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.FLANNEL_DIRECTROUTING?'" -p=true)
    if [[ $FLANNEL_DIRECTROUTING == "" ]] || [[ $FLANNEL_DIRECTROUTING == "null" ]] ; then
        FLANNEL_DIRECTROUTING="false"
    fi
    RUNTIME_CDFDATA_HOME=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.RUNTIME_CDFDATA_HOME?'" -p=true)
    KUBELET_HOME=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.KUBELET_HOME?'" -p=true)
    #kube-apiserver use
    ENABLE_FIPS=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.ENABLE_FIPS?'" -p=true)

    DOCKER_HTTP_PROXY=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.DOCKER_HTTP_PROXY?'" -p=true)
    DOCKER_HTTPS_PROXY=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.DOCKER_HTTPS_PROXY?'" -p=true)
    DOCKER_NO_PROXY=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.DOCKER_NO_PROXY?'" -p=true)

    DNS_SVC_IP="$(exec_cmd "kubectl get svc kube-dns -n ${KUBE_SYSTEM_NAMESPACE} -o json | ${JQ} -r '.spec.clusterIP?'" -p=true)"

    KUBELET_PROTECT_KERNEL_DEFAULTS=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.KUBELET_PROTECT_KERNEL_DEFAULTS?'" -p=true)
    if [[ $KUBELET_PROTECT_KERNEL_DEFAULTS == "" ]] || [[ $KUBELET_PROTECT_KERNEL_DEFAULTS == "null" ]] ; then
        KUBELET_PROTECT_KERNEL_DEFAULTS="false"
    fi

    #get the value of LOCAL_IP 
    getLocalIP
    NETWORK_ADDRESS=`getIpInSameSubnet ${LOCAL_IP}`

    IP_ADDRESS=$(kubectl get ds coredns -n ${KUBE_SYSTEM_NAMESPACE} -o json | ${JQ} -r '.spec.template.spec.hostAliases[]?.ip')
    HOSTNAMES=$(kubectl get ds coredns -n ${KUBE_SYSTEM_NAMESPACE} -o json | ${JQ} -r '.spec.template.spec.hostAliases[]?.hostnames[]' | xargs)

    #k8s audit
    ENABLE_K8S_AUDIT_LOG=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.ENABLE_K8S_AUDIT_LOG?'" -p=true)
    if [[ $ENABLE_K8S_AUDIT_LOG == "" ]] || [[ $ENABLE_K8S_AUDIT_LOG == "null" ]]; then
        ENABLE_K8S_AUDIT_LOG="false"
    fi

    #FIPS_ENTROPY_THRESHOLD is 2000 by default
    FIPS_ENTROPY_THRESHOLD=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.FIPS_ENTROPY_THRESHOLD?'" -p=true)
    if [[ $FIPS_ENTROPY_THRESHOLD == "" ]] || [[ $FIPS_ENTROPY_THRESHOLD == "null" ]]; then
        FIPS_ENTROPY_THRESHOLD="2000"
    fi

    CERTIFICATE_PERIOD=$(exec_cmd "echo '${infraCMJson}' | ${JQ} --raw-output '.data.CERTIFICATE_PERIOD?'" -p=true)

    NON_DNS_ENV=false
    getResource "cm" "coredns" "kube-system" ".data.Corefile"
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to get coredns configurations."
    fi
    exec_cmd "echo '${RESULT}' | grep forward"
    if [[ $? != 0 ]] ; then
        NON_DNS_ENV=true
    fi

    #check params to make sure the following values are not null
    checkParameters ALL_NODES
    checkParameters ETCD_ENDPOINT
    checkParameters K8S_MASTER_IP
    checkParameters CLUSTER_MGMT_ADDR
    checkParameters MASTER_NODES
    checkParameters MASTER_NODES_NUM
    checkParameters MASTER_API_SSL_PORT
    checkParameters NFS_SERVER
    checkParameters NFS_STORAGE_SIZE
    checkParameters NFS_FOLDER
    checkParameters REGISTRY_ORGNAME
    checkParameters IPV6    
    checkParameters POD_CIDR
    checkParameters IPV6_POD_CIDR
    checkParameters SERVICE_CIDR
    checkParameters IPV6_SERVICE_CIDR
    checkParameters DNS_SVC_IP
    checkParameters SYSTEM_USER_ID
    checkParameters SYSTEM_GROUP_ID
    checkParameters K8S_USER_ID
    checkParameters K8S_GROUP_ID
    checkParameters ETCD_USER_ID
    checkParameters ETCD_GROUP_ID
    checkParameters NETWORK_ADDRESS
    checkParameters FLANNEL_BACKEND_TYPE
    checkParameters FLANNEL_PORT
    checkParameters FLANNEL_DIRECTROUTING
    checkParameters UPGRADE_PATH
    checkParameters FAIL_SWAP_ON
    checkParameters SUITE_REGISTRY
    checkParameters DOCKER_REPOSITORY 
    checkParameters RUNTIME_CDFDATA_HOME
    checkParameters KUBELET_HOME
    checkParameters K8S_DEFAULT_SVC_IP
    checkParameters POD_CIDR_SUBNETLEN
    checkParameters IPV6_POD_CIDR_SUBNETLEN
    checkParameters KUBELET_PROTECT_KERNEL_DEFAULTS
    checkParameters ENABLE_FIPS
    checkParameters CLUSTER_NAME

    if [ -z "$HA_VIRTUAL_IP" -a -z "$LOAD_BALANCER_HOST" ]; then
        checkParameters IP_ADDRESS
        checkParameters HOSTNAMES
    fi
    checkParameters ENABLE_K8S_AUDIT_LOG
    checkParameters FIPS_ENTROPY_THRESHOLD
    checkParameters CERTIFICATE_PERIOD

    checkParameters K8S_PROVIDER
    checkParameters EXCLUDE_NS

    if [[ $FROM_INTERNAL_RELEASE -ge "202305" ]] ; then
        checkParameters TLS_MIN_VERSION
        checkParameters TLS_CIPHERS
    fi

    #common
    checkParameters CLUSTER_NODESELECT
    checkParameters BASEINFRA_VAULT_APPROLE
    checkParameters DNS_DOMAIN
    checkParameters NON_DNS_ENV

    # record the params into the file -- upgrade_temp/CDF_infra_upgrade_parameters.txt
    echo ALL_NODES=\"${ALL_NODES}\" > $file
    echo ETCD_ENDPOINT=\"${ETCD_ENDPOINT}\" >> $file
    echo HA_VIRTUAL_IP=\"${HA_VIRTUAL_IP}\" >> $file
    echo LOAD_BALANCER_HOST=\"${LOAD_BALANCER_HOST}\" >> $file
    echo K8S_MASTER_IP=${K8S_MASTER_IP} >> $file
    echo "MASTER_NODES=(${MASTER_NODES[@]})" >> $file
    echo "WORKER_NODES=(${WORKER_NODES[@]})" >> $file
    echo "MASTER_NODES_NUM='${MASTER_NODES_NUM}'" >> $file
    echo MASTER_API_PORT=${MASTER_API_PORT} >> $file
    echo MASTER_API_SSL_PORT=${MASTER_API_SSL_PORT} >> $file
    echo NFS_SERVER=${NFS_SERVER} >> $file
    echo NFS_STORAGE_SIZE=${NFS_STORAGE_SIZE} >> $file
    echo NFS_FOLDER=${NFS_FOLDER} >> $file
    echo REGISTRY_ORGNAME=${REGISTRY_ORGNAME} >> $file
    echo IPV6=${IPV6} >> $file
    echo POD_CIDR=${POD_CIDR} >> $file
    echo IPV6_POD_CIDR=${IPV6_POD_CIDR} >> $file
    echo SERVICE_CIDR=${SERVICE_CIDR} >> $file
    echo IPV6_SERVICE_CIDR=${IPV6_SERVICE_CIDR} >> $file
    echo DNS_SVC_IP=${DNS_SVC_IP} >> $file
    echo FLANNEL_BACKEND_TYPE=\"${FLANNEL_BACKEND_TYPE}\" >> $file
    echo FLANNEL_PORT=\"${FLANNEL_PORT}\" >> $file
    echo FLANNEL_DIRECTROUTING=\"${FLANNEL_DIRECTROUTING}\" >> $file
    echo SYSTEM_USER_ID=${SYSTEM_USER_ID} >> $file
    echo SYSTEM_GROUP_ID=${SYSTEM_GROUP_ID} >> $file

    echo "K8S_USER_ID='${K8S_USER_ID}'" >> $file
    echo "K8S_GROUP_ID='${K8S_GROUP_ID}'" >> $file
    echo "ETCD_USER_ID='${ETCD_USER_ID}'" >> $file
    echo "ETCD_GROUP_ID='${ETCD_GROUP_ID}'" >> $file

    echo NETWORK_ADDRESS=${NETWORK_ADDRESS} >> $file
    echo UPGRADE_PATH=\"${UPGRADE_PATH}\" >> $file
    echo CLOUD_PROVIDER=\"${CLOUD_PROVIDER}\" >> $file
    echo "K8S_PROVIDER=\"${K8S_PROVIDER}\"" >> $file
    echo EXCLUDE_NS=\"${EXCLUDE_NS}\" >> $file
    echo AWS_REGION=\"${AWS_REGION}\" >> $file
    echo FAIL_SWAP_ON=\"${FAIL_SWAP_ON}\" >> $file
    echo SUITE_REGISTRY=\"${SUITE_REGISTRY}\" >> $file
    echo CLUSTER_MGMT_ADDR=\"${CLUSTER_MGMT_ADDR}\" >> $file
    echo RUNTIME_CDFDATA_HOME=\"${RUNTIME_CDFDATA_HOME}\" >> $file
    echo KUBELET_HOME=\"${KUBELET_HOME}\" >> $file
    echo TMP_FOLDER=\"${TMP_FOLDER}\" >> $file
    echo K8S_DEFAULT_SVC_IP=\"${K8S_DEFAULT_SVC_IP}\" >> $file
    echo POD_CIDR_SUBNETLEN=\"${POD_CIDR_SUBNETLEN}\" >> $file
    echo IPV6_POD_CIDR_SUBNETLEN=\"${IPV6_POD_CIDR_SUBNETLEN}\" >> $file
    echo DOCKER_REPOSITORY=\"${DOCKER_REPOSITORY}\" >> $file
    echo "ENABLE_FIPS=\"${ENABLE_FIPS}\"" >> $file
    echo "ENABLE_K8S_AUDIT_LOG=\"${ENABLE_K8S_AUDIT_LOG}\"" >> $file
    echo "FIPS_ENTROPY_THRESHOLD=\"${FIPS_ENTROPY_THRESHOLD}\"" >> $file
    echo "CERTIFICATE_PERIOD=\"${CERTIFICATE_PERIOD}\"" >> $file

    #common
    echo "BASEINFRA_VAULT_APPROLE=\"${BASEINFRA_VAULT_APPROLE}\"" >> $file
    echo "DNS_DOMAIN=\"${DNS_DOMAIN}\"" >> $file

    #node level
    echo "KUBELET_PROTECT_KERNEL_DEFAULTS=\"${KUBELET_PROTECT_KERNEL_DEFAULTS}\"" >> $file
    echo "DOCKER_HTTP_PROXY=\"${DOCKER_HTTP_PROXY}\"" >> $file
    echo "DOCKER_HTTPS_PROXY=\"${DOCKER_HTTPS_PROXY}\"" >> $file
    echo "DOCKER_NO_PROXY=\"${DOCKER_NO_PROXY}\"" >> $file

    #component level
    echo "CLUSTER_NAME=\"${CLUSTER_NAME}\"" >> $file
    echo "IP_ADDRESS=\"${IP_ADDRESS}\"" >> $file
    echo "HOSTNAMES=\"${HOSTNAMES}\"" >> $file

    echo GOLANG_TLS_CIPHERS=\"${GOLANG_TLS_CIPHERS}\" >> $file
    echo TLS_MIN_VERSION=${TLS_MIN_VERSION} >> $file
    echo TLS_CIPHERS=\"${TLS_CIPHERS}\" >> $file
    echo NON_DNS_ENV=\"${NON_DNS_ENV}\" >> $file

    write_log "debug" "     File CDF_infra_upgrade_parameters.txt generated under ${UPGRADE_TEMP}"
    exec_cmd "kubectl delete configmap upgrade-parameters-infra-${TARGET_INTERNAL_RELEASE} -n $CDF_NAMESPACE" -p=false
    exec_cmd "kubectl create configmap upgrade-parameters-infra-${TARGET_INTERNAL_RELEASE} --from-file=all=$file -n $CDF_NAMESPACE" -p=false
    if [ $? -eq 0 ]; then
        write_log "debug" "     Save CDF_infra_upgrade_parameters.txt into configmap successfully."
    else
        write_log "fatal" "Failed to save CDF_infra_upgrade_parameters.txt into configmap."
    fi
    exec_cmd "echo ${TARGET_INTERNAL_VERSION} > ${UPGRADE_TEMP}/generate_complete.txt"
}

updateUpgradedMastersConfigMap(){
    write_log "debug" "Update upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE}"
    local temp_json=
    cmLock "upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE}"
    temp_json=$(getJsonFromCM "upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE}" "${CDF_NAMESPACE}")
    checkTimeOut temp_json
    local upgraded_masters=
    upgraded_masters=$(exec_cmd "echo '${temp_json}' | ${JQ} --raw-output '.data.UPGRADED_MASTER_NODES?'" -p=true)
    if [[ $? == 0 ]] ; then
        if [[ ! "${upgraded_masters}" =~ "${THIS_NODE}" ]] ; then
            exec_cmd "kubectl patch cm upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE} -p '{\"data\":{\"UPGRADED_MASTER_NODES\":\"${upgraded_masters} ${THIS_NODE}\"}}'"
            cmUnLock "upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE}"
        else
            write_log "debug" "Node ${THIS_NODE} already in upgraded master array (${upgraded_masters})"
        fi
    else
        write_log "fatal" "Failed to get configmap upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE}"
    fi
}

setUpgradedMastersConfigMap(){
    #set upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE}
    if [ "$IS_MASTER" == "true" ];then
        write_log "info" "     Begin to set upgraded control-plane nodes configmap ..."
        if [[ ! -f ${UPGRADE_TEMP}/upgraded_masters_cm_complete ]] ; then
            local reTryTimes=0
            while true; do
                #3M:first master
                if [[ "${isFirstMaster}" == "true" ]] && [[ "${isLastMaster}" == "false" ]] ; then
                    deleteResource "cm" "upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE}" "${CDF_NAMESPACE}"
                    exec_cmd "kubectl create configmap upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE} --from-literal=UPGRADED_MASTER_NODES=${THIS_NODE}"
                #3M:second master
                elif [[ "${isFirstMaster}" == "false" ]] && [[ "${isLastMaster}" == "false" ]] ; then
                    updateUpgradedMastersConfigMap UPGRADED_MASTER_NODES
                #3M:last master
                elif [[ "${isFirstMaster}" == "false" ]] && [[ "${isLastMaster}" == "true" ]] ; then
                    deleteResource "cm" "upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE}" "${CDF_NAMESPACE}"
                    createResource "cm" "master-finished" "${CDF_NAMESPACE}"
                #1M:single master
                elif [[ "${isFirstMaster}" == "true" ]] && [[ "${isLastMaster}" == "true" ]] ; then
                    createResource "cm" "master-finished" "${CDF_NAMESPACE}"
                fi
                if [ $? -eq 0 ] || [ $(exec_cmd "kubectl get configmap upgraded-masters-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE}"; echo $?) -eq 0 ] ; then
                    write_log "info" "     Set up upgraded control-plane nodes configmap successfully." 
                    break
                elif [ ${reTryTimes} -eq 3 ]; then
                    write_log "fatal" "Failed to set up upgraded control-plane nodes configmap ." 
                fi
                reTryTimes=$(( $reTryTimes + 1 ))
                sleep 1
            done
            exec_cmd "touch ${UPGRADE_TEMP}/upgraded_masters_cm_complete"
        else
            write_log "info" "     Upgraded control-plane nodes configmap has already been set up. Proceeding to the next step"
        fi
    fi
}

cmLock() {
    local cmName=$1
    local reTryTimes=0
    while [[ $(exec_cmd "kubectl create cm ${cmName}-lock -n ${CDF_NAMESPACE}" -p=false; echo $?) -ne 0 ]] ; do
        write_log "debug" "Waiting for ${cmName} configmap lock. "
        if [ ${reTryTimes} -ge ${RETRY_TIMES} ]; then
            write_log "fatal" "Waiting for ${cmName} configmap lock timeout."
        fi
        reTryTimes=$(( $reTryTimes + 1 ))
        sleep 6
    done
}

cmUnLock() {
    local cmName=$1
    local reTryTimes=0
    while [[ $(exec_cmd "kubectl delete cm ${cmName}-lock -n ${CDF_NAMESPACE}" -p=false; echo $?) -ne 0 ]] && [[ $(exec_cmd "kubectl get cm ${cmName}-lock -n ${CDF_NAMESPACE}" -p=false; echo $?) -eq 0 ]] ; do
        write_log "debug" "Waiting for ${cmName} configmap unlock. "
        if [ ${reTryTimes} -ge ${RETRY_TIMES} ]; then
            write_log "fatal" "Waiting for ${cmName} configmap unlock timeout."
        fi
        reTryTimes=$(( $reTryTimes + 1 ))
        sleep 6
    done
}

updateUpgradedNodesConfigMap(){
    write_log "debug" "Update upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE}"
    local temp_json=
    cmLock "upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE}"
    temp_json=$(getJsonFromCM "upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE}" "${CDF_NAMESPACE}")
    checkTimeOut temp_json
    local upgraded_nodes=
    upgraded_nodes=$(exec_cmd "echo '${temp_json}' | ${JQ} --raw-output '.data.UPGRADED_NODES?'" -p=true)
    if [[ $? == 0 ]] ; then
        if [[ ! "${upgraded_nodes}" =~ "${THIS_NODE}" ]] ; then
            exec_cmd "kubectl patch cm upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE} -p '{\"data\":{\"UPGRADED_NODES\":\"${upgraded_nodes} ${THIS_NODE}\"}}'" -p=false
        else
            write_log "debug" "Node ${THIS_NODE} already in upgraded nodes array (${UPGRADED_NODES})"
        fi
    else
        cmUnLock "upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE}"
        write_log "fatal" "Failed to get configmap upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE}"
    fi
    cmUnLock "upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE}"
}

setUpgradedNodesConfigMap(){
    write_log "info" "     Begin to set upgraded nodes configmap ..."
    if [[ ! -f ${UPGRADE_TEMP}/upgraded_nodes_cm_complete ]] ; then
        local reTryTimes=0
        while true; do
            if [[ "${isFirstMaster}" == "true" ]] ; then
                write_log "debug" "Create upgraded nodes configmap ..."
                exec_cmd "kubectl delete configmap upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE}" -p=false
                exec_cmd "kubectl create configmap upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE} --from-literal=UPGRADED_NODES=${THIS_NODE}" -p=false
            else
                updateUpgradedNodesConfigMap
            fi
            if [ $? -eq 0 ]  ; then
                write_log "info" "     Set up upgraded nodes configmap successfully." 
                break
            elif [ ${reTryTimes} -eq 3 ]; then
                write_log "fatal" "Failed to set upgraded nodes configmap ." 
            fi
            reTryTimes=$(( $reTryTimes + 1 ))
            sleep 1
        done
        exec_cmd "touch ${UPGRADE_TEMP}/upgraded_nodes_cm_complete"
    else
        write_log "info" "     Upgraded nodes configmap has already been set up. Proceeding to the next step"
    fi
}

calculateParameters(){
    countRemainingSteps
    write_log "info" "\n** Collecting parameters ... ${STEP_CONT}"

    if [[ ! -e ${CDF_HOME}/moduleVersion.json ]] ; then
        write_log "fatal" "Failed to find moduleVersion.json in ${CDF_HOME}"
    fi
    CURRENT_CNI_VERSION=$(cat ${CDF_HOME}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "cni"  )' | ${JQ} -r '.version')
    TARGET_CNI_VERSION=$(cat ${CURRENT_DIR}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "cni"  )' | ${JQ} -r '.version')
    SUPPORT_CNI_VERSION=$(cat ${CURRENT_DIR}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "cni"  )' | ${JQ} -r '.supportVersion[]' | xargs)
    write_log "debug" "CURRENT_CNI_VERSION: $CURRENT_CNI_VERSION , TARGET_CNI_VERSION: $TARGET_CNI_VERSION"
    if [[ $TARGET_CNI_VERSION == "" ]] || [[ $TARGET_CNI_VERSION == "null" ]] ; then 
        write_log "fatal" "Failed to find the system cni verison."
    fi

    #containerd verison
    CURRENT_CONTAINERD_VERSION=$(cat ${CDF_HOME}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "containerd"  )' | ${JQ} -r '.version')
    TARGET_CONTAINERD_VERSION=$(cat ${CURRENT_DIR}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "containerd"  )' | ${JQ} -r '.version')
    SUPPORT_CONTAINERD_VERSION=$(cat ${CURRENT_DIR}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "containerd"  )' | ${JQ} -r '.supportVersion[]' | xargs)
    write_log "debug" "CURRENT_CONTAINERD_VERSION: $CURRENT_CONTAINERD_VERSION , TARGET_CONTAINERD_VERSION: $TARGET_CONTAINERD_VERSION"
    if [[ $CURRENT_CONTAINERD_VERSION == "" ]] || [[ $CURRENT_CONTAINERD_VERSION == "null" ]] ; then 
        write_log "fatal" "File moduleVersion.json missed. Failed to find the system containerd verison."
    fi
    if [[ $TARGET_CONTAINERD_VERSION == "" ]] || [[ $TARGET_CONTAINERD_VERSION == "null" ]] ; then 
        write_log "fatal" "File moduleVersion.json missed. Failed to find the system containerd verison."
    fi

    #k8s version
    CURRENT_K8S_VERSION=$(cat ${CDF_HOME}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "k8s"  )' | ${JQ} -r '.version')
    TARGET_K8S_VERSION=$(cat ${CURRENT_DIR}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "k8s"  )' | ${JQ} -r '.version')
    SUPPORT_K8S_VERSION=$(cat ${CURRENT_DIR}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "k8s"  )' | ${JQ} -r '.supportVersion[]' | xargs)
    write_log "debug" "CURRENT_K8S_VERSION: $CURRENT_K8S_VERSION , TARGET_K8S_VERSION: $TARGET_K8S_VERSION"
    if [[ $CURRENT_K8S_VERSION == "" ]] || [[ $CURRENT_K8S_VERSION == "null" ]] ; then 
        write_log "fatal" "File moduleVersion.json missed. Failed to find the system K8S verison."
    fi
    if [[ $TARGET_K8S_VERSION == "" ]] || [[ $TARGET_K8S_VERSION == "null" ]] ; then 
        write_log "fatal" "File moduleVersion.json missed. Failed to find the system K8S verison."
    fi

    #cdf version
    CURRENT_CDF_VERSION=$(cat ${CDF_HOME}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "cdf"  )' | ${JQ} -r '.version')
    TARGET_CDF_VERSION=$(cat ${CURRENT_DIR}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "cdf"  )' | ${JQ} -r '.version')
    SUPPORT_CDF_VERSION=$(cat ${CURRENT_DIR}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "cdf"  )' | ${JQ} -r '.supportVersion[]' | xargs)
    write_log "debug" "CURRENT_CDF_VERSION: $CURRENT_CDF_VERSION , TARGET_CDF_VERSION: $TARGET_CDF_VERSION"
    if [[ $CURRENT_CDF_VERSION == "" ]] || [[ $CURRENT_CDF_VERSION == "null" ]] ; then 
        write_log "fatal" "File moduleVersion.json missed. Failed to find the system infrasture verison."
    fi
    if [[ $TARGET_CDF_VERSION == "" ]] || [[ $TARGET_CDF_VERSION == "null" ]] ; then 
        write_log "fatal" "File moduleVersion.json missed. Failed to find the system infrasture verison."
    fi

    local file=${UPGRADE_TEMP}/CDF_local_upgrade_parameters.txt
    # re-run
    if [[ -f $file ]] ; then
        write_log "debug" "UPGRADE_INFRA: $UPGRADE_INFRA, UPGRADE_CDF: $UPGRADE_CDF"
        write_log "debug" "CDF_local_upgrade_parameters.txt already existed."
        source $file
    else
    # first run
        write_log "debug" "UPGRADE_INFRA: $UPGRADE_INFRA, UPGRADE_CDF: $UPGRADE_CDF"
        THIS_HOSTNAME=$(hostname -f | tr '[:upper:]' '[:lower:]')
        local this_node=
        this_node=$(getThisNode "${ALL_NODES}")
        if [[ $this_node != $THIS_NODE ]]; then
            local correct_node=
            local wrong_node=
        
            if [[ $this_node == "" ]] ; then
            #hostname value has changed
                local foundInClusterFlag=false
                for temp_node in ${ALL_NODES} ; do
                    if [[ $temp_node == $THIS_NODE ]] ; then
                        foundInClusterFlag=true
                    fi
                done
                if [[ $foundInClusterFlag == "false" ]] ; then
                    write_log "error" "We've detected that both your host name and the variable THIS_NODE stored in ${CDF_HOME}/bin/env.sh are different from the node name inside the cluster."
                    write_log "fatal" "Please fix them and rerun upgrade."
                fi
                correct_node=$THIS_NODE
                wrong_node=$(hostname -f | tr '[:upper:]' '[:lower:]')
                write_log "error" "During the installation, this host name(it's '${correct_node}') has been collected and saved with variable THIS_NODE in $CDF_HOME/bin/env.sh. The current host name is '$wrong_node'. It seems the host name is changed. "
                write_log "fatal" "Please change the host name back and rerun upgrade."
            else
            #THIS_NODE inside env.sh has changed
                correct_node=$this_node
                wrong_node=$THIS_NODE
                write_log "error" "During the installation, this host name(it's '${correct_node}') has been collected and saved with variable THIS_NODE in $CDF_HOME/bin/env.sh. The current THIS_NODE value inside env.sh is '$wrong_node'. It seems the value is changed. "
                write_log "fatal" "Please change the THIS_NODE inside $CDF_HOME/bin/env.sh back and rerun upgrade."
            fi
        fi
        THIS_NODE="${this_node}"
        local cmd="kubectl get cm kube-flannel-cfg -n ${KUBE_SYSTEM_NAMESPACE} -o json"
        local data=$(getValueWithRetry "$cmd" "10")
        if [[ $data == "timeout" ]] ; then
            write_log "fatal" "Failed to get cm kube-flannel-cfg in ${KUBE_SYSTEM_NAMESPACE} namespace."
        fi
        FLANNEL_IFACE=$(echo ${data} | ${JQ} -r ".data.\"$THIS_NODE\"" | grep FLANNEL_IFACE | awk -F= '{print $2}')

        getLocalIP
        getIsLastNode
        # master node
        if [ "$IS_MASTER" == "true" ];then
            CERTCN="kubernetes-admin"
            isFirstMaster="$(isFirstMasterNode)"
            UPGRADED_MASTER_NODES=$(getUpgradedMasterNodes "${MASTER_NODES[*]}")
            isLastMaster=$(isLastMasterNode)
            INITIAL_CLUSTER=$(getInitialCluster)
            INITIAL_CLUSTER_STATE="existing"
            checkTimeOut isFirstMaster
            checkParameters isFirstMaster
            checkParameters isLastMaster 
            checkParameters INITIAL_CLUSTER
            checkParameters INITIAL_CLUSTER_STATE
            NODE_LABELS="role=loadbalancer"
            NODE_TYPE=master
            K8S_APISERVER_IP=${THIS_NODE}
        else
        # worker node
            CERTCN="kubernetes-node"
            NODE_LABELS="Worker=label"
            NODE_TYPE=worker
            K8S_APISERVER_IP=${K8S_MASTER_IP}
        fi
        
        # IFACE_NAME
        INAME=$(exec_cmd "ip route get 8.8.8.8|head -1|awk -F\" dev \" '{print \$2}'|awk '{print \$1}'" -p=true)
        # Cloud provider specific parameters:
        # AWS_REGION, AWS_EIP, AZURE_CONFIG_FILE
        if [[ "$K8S_PROVIDER" == "cdf-aws" ]] ; then
            AWS_REGION_OPTION="--env AWS_REGION=\"${AWS_REGION}\""
            AWS_EIP_OPTION="--env AWS_EIP=\"${AWS_EIP}\""
        elif [[ "$K8S_PROVIDER" == "cdf-azure" ]] ; then
            AZURE_OPTION="-v ${AZURE_CONFIG_FILE}:/etc/cdf/keepalived-azure.conf:ro"
        fi

        # --resolv-conf is the resolver configuration file used as the basis
        # for the container DNS resolution configuration.
        # default:          "/etc/resolv.conf"
        # systemd-resolved: "/run/systemd/resolve/resolv.conf"
        if isServiceActive "systemd-resolved";then
            RESOLV_CONF="/run/systemd/resolve/resolv.conf"
        else
            RESOLV_CONF=""
        fi

        # kubelet-config 
        #   Use dynamic value for the image gc threshold
        local thresholdGB=100
        local diskSpace=$(exec_cmd "df --output=size --block-size=G / | grep -v 1G-blocks | sed 's/G//g'" -p=true)
        if [[ $diskSpace -le $thresholdGB ]] ; then
            imageGCHighThresholdPercent=80
            nodeImagefsAvailable="15%"
        else
            imageGCHighThresholdPercent=$(echo $diskSpace | awk '{print int((1-20/$1)*100)}')
            nodeImagefsAvailable="$(echo $diskSpace | awk '{print int((15/$1)*100)}')%"
        fi
        imageGCLowThresholdPercent=$(( $imageGCHighThresholdPercent - 5 ))

        checkParameters THIS_HOSTNAME
        checkParameters THIS_NODE
        checkParameters LOCAL_IP
        checkParameters NODE_TYPE
        checkParameters INAME
        checkParameters K8S_APISERVER_IP
        checkParameters IS_LAST_NODE
        checkParameters imageGCHighThresholdPercent
        checkParameters imageGCLowThresholdPercent
        checkParameters nodeImagefsAvailable

        echo isFirstMaster=\"${isFirstMaster}\" > $file
        echo isLastMaster=\"${isLastMaster}\" >> $file
        echo NODE_TYPE=\"${NODE_TYPE}\" >> $file
        echo LOCAL_IP=\"${LOCAL_IP}\" >> $file
        echo THIS_NODE=\"${THIS_NODE}\" >> $file
        echo THIS_HOSTNAME=\"${THIS_HOSTNAME}\" >> $file
        echo FLANNEL_IFACE=\"${FLANNEL_IFACE}\" >> $file
        echo INAME=\"$INAME\" >> $file
        echo AWS_REGION_OPTION=\"$AWS_REGION_OPTION\" >> $file
        echo AWS_EIP_OPTION=\"$AWS_EIP_OPTION\" >> $file
        echo AZURE_OPTION=\"$AZURE_OPTION\" >> $file
        echo INITIAL_CLUSTER=\"${INITIAL_CLUSTER}\" >> $file
        echo INITIAL_CLUSTER_STATE=\"${INITIAL_CLUSTER_STATE}\" >> $file
        echo NODE_LABELS=\"${NODE_LABELS}\" >> $file
        echo "K8S_APISERVER_IP=\"${K8S_APISERVER_IP}\"" >> $file
        echo "CERTCN=\"${CERTCN}\"" >> $file
        echo "IS_LAST_NODE=\"${IS_LAST_NODE}\"" >> $file
        echo "RESOLV_CONF=\"${RESOLV_CONF}\"" >> $file
        echo "imageGCHighThresholdPercent=\"${imageGCHighThresholdPercent}\"" >> $file
        echo "imageGCLowThresholdPercent=\"${imageGCLowThresholdPercent}\"" >> $file
        echo "nodeImagefsAvailable=\"${nodeImagefsAvailable}\"" >> $file
    fi
}

updateRBAC() {
    if [ "$IS_MASTER" == "true" -o "${BYOK}" == "true" ];then
        countRemainingSteps
        write_log "info" "\n** Updating Kubernetes RBAC ... ${STEP_CONT}"
        if [[ ! -f ${UPGRADE_TEMP}/updateRBAC_complete ]]; then
            replacePlaceHolder ${YAMLPATH}/rbac-config.yaml
            exec_cmd "kubectl apply -f ${YAMLPATH}/rbac-config.yaml"
            exec_cmd "touch ${UPGRADE_TEMP}/updateRBAC_complete"
            write_log "info" "     RBAC update successfully. "
        else
            write_log "info" "     Update RBAC already done. Proceeding to the next step."
        fi
    fi
}

pack(){
    local type_name=$1
    local base_dir=$2
    local folderListWithException=

    exec_cmd "mkdir -p ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}"
    if [ "$type_name" != "comm" ] ; then
        folderListWithException=$(exec_cmd "${LS} ${CURRENT_DIR}/${type_name} | grep -v images | xargs" -p =true)
        for temp_folder in ${folderListWithException} ; do
            exec_cmd "${CP} -rf ${CURRENT_DIR}/${type_name}/${temp_folder} ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/."
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to copy ${type_name} folders."
            fi
        done
    fi
    if [ "$type_name" == "cri" ];then
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/selinux-module ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/systemd-template ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
    elif [ "$type_name" == "k8s" ];then
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/controller-manager ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/kube-dns-hosts ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/cdf-addnode.json ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/apiserver-encryption.yaml ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/admission-cfg.yaml ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
        exec_cmd "${CP} -rf ${CDF_HOME}/objectdefs/coredns.yaml ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/objectdefs/"
        exec_cmd "${CP} -rf ${CDF_HOME}/objectdefs/flannel.yaml ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/objectdefs/"
    elif [ "$type_name" == "cdf" ];then
        local metadataDir="${base_dir}/zip/ITOM_Suite_Foundation_Node/cfg/suite-metadata"
        exec_cmd "mkdir -p ${metadataDir}/package && chmod 755 $metadataDir"
        exec_cmd "chmod 700 ${base_dir}/zip"
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/suite-metadata ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/cdf-phase1.json ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
        exec_cmd "${CP} -rf ${CDF_HOME}/cfg/cdf-phase2.json ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/cfg/"
        exec_cmd "${CP} -rf ${CDF_HOME}/objectdefs/rbac-config.yaml ${base_dir}/zip/ITOM_Suite_Foundation_Node/${type_name}/objectdefs/"
    elif [ "$type_name" == "comm" ];then
        exec_cmd "${CP} -rf ${CURRENT_DIR}/bin ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
        exec_cmd "${CP} -rf ${CURRENT_DIR}/scripts ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
        exec_cmd "${CP} -rf ${CURRENT_DIR}/tools ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
        exec_cmd "${CP} -rf ${CURRENT_DIR}/image_pack_config.json ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
        exec_cmd "${CP} -rf ${CURRENT_DIR}/install ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
        exec_cmd "${CP} -rf ${CURRENT_DIR}/version.txt ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
        exec_cmd "${CP} -rf ${CURRENT_DIR}/version_internal.txt ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
        exec_cmd "${CP} -rf ${CURRENT_DIR}/uninstall.sh ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
        exec_cmd "${CP} -rf ${CURRENT_DIR}/node_prereq ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
        exec_cmd "${CP} -rf ${CURRENT_DIR}/moduleVersion.json ${base_dir}/zip/ITOM_Suite_Foundation_Node/"
    fi

    cd ${base_dir}/zip
    exec_cmd "${TAR} -zcvf ITOM_Suite_Foundation_Node_${type_name}.tar.gz ITOM_Suite_Foundation_Node/"
    if [ $? -eq 0 ]; then
        exec_cmd "chown ${SYSTEM_USER_ID}:${SYSTEM_GROUP_ID} ${base_dir}/zip/ITOM_Suite_Foundation_Node_${type_name}.tar.gz"
        exec_cmd "chmod 644 ${base_dir}/zip/ITOM_Suite_Foundation_Node_${type_name}.tar.gz"
        exec_cmd "${RM} -rf ${base_dir}/zip/ITOM_Suite_Foundation_Node"
        cd ${CURRENT_DIR}
        write_log "debug" "Successfully pack ${type_name} installer."
    else
        write_log "fatal" "Failed to pack the ${type_name} installer."
    fi
}

packInstallerZip(){
    countRemainingSteps
    write_log "info" "\n** Packing installer used for adding nodes through UI. ${STEP_CONT}"
    if [ "${isFirstMaster}" = "true" ]; then
        if [[ ! -f ${UPGRADE_TEMP}/zip_package_complete ]] ; then
            startRolling
            [ -d ${UPGRADE_TEMP}/zip ] && exec_cmd "${RM} -rf ${UPGRADE_TEMP}/zip"
            exec_cmd "mkdir -p ${UPGRADE_TEMP}/zip"
            exec_cmd "chmod 700 ${UPGRADE_TEMP}/zip"

            if checkSupportVersion "$SUPPORT_CONTAINERD_VERSION" "$CURRENT_CONTAINERD_VERSION"; then
                write_log "debug" "Pack CRI part."
                pack "cri" "$UPGRADE_TEMP"
            fi

            if checkSupportVersion "$SUPPORT_K8S_VERSION" "$CURRENT_K8S_VERSION" ; then
                write_log "debug" "Pack K8S part."
                pack "k8s" "$UPGRADE_TEMP"
            fi

            if checkSupportVersion "$SUPPORT_CDF_VERSION" "$CURRENT_CDF_VERSION" ; then
                write_log "debug" "Pack CDF part."
                pack "cdf" "$UPGRADE_TEMP"
            fi

            pack "comm" "$UPGRADE_TEMP"
            exec_cmd "touch ${UPGRADE_TEMP}/zip_package_complete"
            stopRolling
            write_log "info" "     Installer has been packed successfully."
        else
            write_log "info" "     Installer has already been packed. Proceeding to the next step."
        fi
    fi
}

copyZipFilesToNfs() {
    if [[ "${isFirstMaster}" == "true" ]]; then
        if [[ ! -f ${UPGRADE_TEMP}/copy_zip_complete ]] ; then
            exec_cmd "mkdir -p ${UPGRADE_TEMP}/zip_nfs_tmp"
            exec_cmd "mount -t nfs -o rw ${NFS_SERVER}:${NFS_FOLDER} ${UPGRADE_TEMP}/zip_nfs_tmp" 
            if [[ $? != 0 ]] ; then
                exec_cmd "umount -f -l ${UPGRADE_TEMP}/zip_nfs_tmp" 
                exec_cmd "mount -t nfs -o rw ${NFS_SERVER}:${NFS_FOLDER} ${UPGRADE_TEMP}/zip_nfs_tmp" || write_log "fatal" "Failed to mount nfs folder."
            fi
            exec_cmd "mkdir -p ${UPGRADE_TEMP}/zip_nfs_tmp/pack"
            exec_cmd "${CP} -f ${UPGRADE_TEMP}/zip/*.tar.gz ${UPGRADE_TEMP}/zip_nfs_tmp/pack/."
            if [[ $? == 0 ]] ; then
                write_log "info" "     Successfully uploaded addNode zip files to NFS server pack folder."
            else
                write_log "fatal" "Failed to upload addNode zip files to NFS server pack folder."
            fi
            
            exec_cmd "${RM} -rf ${UPGRADE_TEMP}/zip_nfs_tmp/pack/ITOM_Suite_Foundation_Node_docker.tar.gz"
            exec_cmd "mkdir -p ${UPGRADE_TEMP}/zip_nfs_tmp/pack/images"
            if checkSupportVersion "$SUPPORT_K8S_VERSION" "$CURRENT_K8S_VERSION" ; then
                for image in ${MASTER_PACKAGES_INFRA[@]} ; do
                    exec_cmd "${CP} -f ${CURRENT_DIR}/k8s/images/${image}-images.tgz ${UPGRADE_TEMP}/zip_nfs_tmp/pack/images/."
                    if [[ $? != 0 ]] ; then
                        write_log "fatal" "Failed to copy ${image} to nfs folder."
                    fi
                done
            fi

            if checkSupportVersion "$SUPPORT_CDF_VERSION" "$CURRENT_CDF_VERSION" ; then
                local pkgs="cdf-common-images.tgz cdf-master-images.tgz cdf-phase2-images.tgz"
                for pkg in ${pkgs};do
                    if [[ -e "${UPGRADE_TEMP}/zip_nfs_tmp/pack/images/$pkg" ]];then
                        exec_cmd "${RM} -f ${UPGRADE_TEMP}/zip_nfs_tmp/pack/images/$pkg"
                    fi
                done
            fi

            write_log "info" "     Successfully uploaded addNode zip images to NFS server pack folder."
            
            exec_cmd "umount -f -l ${UPGRADE_TEMP}/zip_nfs_tmp"
            if [[ $? != 0 ]] ; then
                exec_cmd "umount -f -l ${UPGRADE_TEMP}/zip_nfs_tmp" || write_log "fatal" "Failed to umount nfs folder."
            fi

            exec_cmd "${RMDIR} ${UPGRADE_TEMP}/zip_nfs_tmp"

            
            exec_cmd "touch ${UPGRADE_TEMP}/copy_zip_complete"
        else
            write_log "info" "     AddNode zip files and images already been uploaded to NFS server pack folder. Proceeding to the next step."
        fi
    fi
}

generateParFile(){
    isFirstMaster="$(isFirstMasterNode)"
    write_log "debug" "isFirstMaster:$isFirstMaster"
    if [[ $isFirstMaster == "errorNode" ]] ; then
        exec_cmd "kubectl delete cm ilock -n ${CDF_NAMESPACE}"
        exec_cmd "${RM} -f ${UPGRADE_TEMP}/iprocesstoken"
        if [[ $IS_MASTER == "true" ]] ; then
            write_log "fatal" "Upgrade env is not clean. The configmap first-node-configmap-${TARGET_INTERNAL_RELEASE} isn't generated during $TARGET_VERSION upgrade."
        else
            write_log "error" "\n** Error upgrade order. You can't run -i on worker node first. **"
            showUpgradeSteps
            exit 1
        fi
    fi
    if [[ $isFirstMaster == "timeout" ]] ; then
        write_log "fatal" "Can not identify the first control-plane node. Please check your kubectl command if it works."
    fi
    if [[ $isFirstMaster == "nodeInfoTotallyChange" ]] ; then
        write_log "error" "We've detected that both your host name and the variable THIS_NODE stored in ${CDF_HOME}/bin/env.sh are different from the node name inside the cluster."
        write_log "fatal" "Please fix them and rerun upgrade."
    fi
    if [[ $isFirstMaster == "nodeInfoChange" ]] ; then
        local this_node=
        local all_nodes=
        all_nodes=$(exec_cmd "kubectl get nodes --no-headers | awk '{print \$1}' | xargs | tr '[:upper:]' '[:lower:]'" -p=true)
        this_node=$(getThisNode "${all_nodes}")
        local correct_node=
        local wrong_node=
        
        if [[ $this_node == "" ]] ; then
        #hostname value has changed
            local foundInClusterFlag=false
            for temp_node in ${all_nodes} ; do
                if [[ $temp_node == $THIS_NODE ]] ; then
                    foundInClusterFlag=true
                fi
            done
            if [[ $foundInClusterFlag == "false" ]] ; then
                write_log "error" "We've detected that both your host name and the variable THIS_NODE stored in ${CDF_HOME}/bin/env.sh are different from the node name inside the cluster."
                write_log "fatal" "Please fix them and rerun upgrade."
            fi
            correct_node=$THIS_NODE
            wrong_node=$(hostname -f | tr '[:upper:]' '[:lower:]')
            write_log "error" "During the installation, this host name(it's '${correct_node}') has been collected and saved with variable THIS_NODE in $CDF_HOME/bin/env.sh. The current host name is '$wrong_node'. It seems the host name is changed. "
            write_log "fatal" "Please change the host name back and rerun upgrade."
        else
        #THIS_NODE inside env.sh has changed
            correct_node=$this_node
            wrong_node=$THIS_NODE
            write_log "error" "During the installation, this host name(it's '${correct_node}') has been collected and saved with variable THIS_NODE in $CDF_HOME/bin/env.sh. The current THIS_NODE value inside env.sh is '$wrong_node'. It seems the value is changed. "
            write_log "fatal" "Please change the THIS_NODE inside $CDF_HOME/bin/env.sh back and rerun upgrade."
        fi
    fi
    countRemainingSteps
    write_log "info" "\n** Generating parameter file ... ${STEP_CONT}"
    if [[ ${isFirstMaster} == "true" ]] ; then
        createInfraUpgradeInProcessMark
        gatherParameters
        write_log "info" "     Generate parameters completed."
    else
        write_log "info" "     No need to generate parameters on this node."
    fi
}

loadParameters(){
    # parameter_file is optional from command line
    if [ -z $parameter_file ]; then
        if [ -f ${UPGRADE_TEMP}/CDF_infra_upgrade_parameters.txt ]; then
            write_log "debug" "CDF_infra_upgrade_parameters.txt already existed."
            source ${UPGRADE_TEMP}/CDF_infra_upgrade_parameters.txt
        else
            #gather from config-map
            exec_cmd "kubectl get cm upgrade-parameters-infra-${TARGET_INTERNAL_RELEASE} -n $CDF_NAMESPACE -o json" -p=true > ${UPGRADE_TEMP}/upgrade_params.json
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to get configmap upgrade-parameters-infra-${TARGET_INTERNAL_RELEASE}."
            fi
            exec_cmd "cat ${UPGRADE_TEMP}/upgrade_params.json | ${JQ} -r '.data.all?'" -p=true > ${UPGRADE_TEMP}/CDF_infra_upgrade_parameters.txt
            if [ $? -eq 0 -a $(exec_cmd "grep 'UPGRADE_PATH' ${UPGRADE_TEMP}/CDF_infra_upgrade_parameters.txt | wc -l" -p=true) -eq 1 ]; then
                source ${UPGRADE_TEMP}/CDF_infra_upgrade_parameters.txt
            else
                write_log "fatal" "Failed to get upgrade parameters from configmap."
            fi
        fi
    else
        if [ -f "$parameter_file" ]; then
            source $parameter_file
        else
            write_log "fatal" "Parameter file $parameter_file not found."
        fi
    fi
}

drainNode(){
    if [ "$IS_MASTER" = "false" -a "$DRAIN" = "true" ]; then
        write_log "info" "     Drain node before upgrade..."
        if [[ ! -f ${UPGRADE_TEMP}/drain_node_complete  ]] ; then
            [[ -z $DRAIN_TIMEOUT ]] && DRAIN_TIMEOUT=3600
            exec_cmd "kubectl drain $THIS_NODE --ignore-daemonsets=true --delete-emptydir-data --timeout=${DRAIN_TIMEOUT}s"
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to drain node $THIS_NODE. Please make sure the pods can be drained gracefully and notice the length of time is enough to drain this node."
            fi
            touch ${UPGRADE_TEMP}/drain_node_complete
            write_log "info" "     Drain node successfully."
        else
            write_log "info" "     Drain node already executed."
        fi
    fi
}

uncordonNode(){
    if [ "$IS_MASTER" = "false" -a "$DRAIN" = "true" ]; then
        write_log "info" "     Uncordon node after upgrade..."
        exec_cmd "kubectl uncordon $THIS_NODE" -p=false
        if [ $? -ne 0 ]; then
            write_log "error" "Failed to uncordon node."
            write_log "info" "     Please try to uncordon node manually using command: kubectl uncordon $THIS_NODE"
        fi
    fi
}

getValidityPeriod(){
    local cert=
    #before 2021.05
    if [[ -f ${CDF_HOME}/ssl/kubernetes.crt ]] ; then
        cert=${CDF_HOME}/ssl/kubernetes.crt
    #after 2021.05
    elif [[ -f ${CDF_HOME}/ssl/kubelet-server.crt ]] ; then
        cert=${CDF_HOME}/ssl/kubelet-server.crt
    else
        write_log "fatal" "Failed to find certificates."
    fi

    local caCert=${CDF_HOME}/ssl/ca.crt

    local startdate=$(openssl x509 -in $cert -noout -startdate 2>/dev/null | awk -F= {'print $2'})
    local enddate=$(openssl x509 -in $cert -noout -enddate 2>/dev/null | awk -F= {'print $2'})

    local ca_enddate=$(openssl x509 -in $caCert -noout -enddate 2>/dev/null | awk -F= {'print $2'})

    write_log "debug" "startdate: $startdate, enddate: $enddate"
    if [[ $startdate == "" ]] || [[ $enddate == "" ]] ; then
        VALIDITY_PERIOD=365
    else
        currentdate=$(date +%s)
        ca_enddate=$(date -d "$ca_enddate" +%s)
        startdate=$(date -d "$startdate" +%s)
        enddate=$(date -d "$enddate" +%s)
        VALIDITY_OF_CA=$((($ca_enddate - $currentdate)/86400 ))
        VALIDITY_PERIOD=$((($enddate - $startdate)/86400 ))
        write_log "debug" "VALIDITY_OF_CA: $VALIDITY_OF_CA"
        write_log "debug" "VALIDITY_PERIOD: $VALIDITY_PERIOD"
        if [[ $VALIDITY_OF_CA -lt $VALIDITY_PERIOD ]] ; then
            write_log "warn" "Warning! Your current certificates validity period($VALIDITY_PERIOD days) is larger than the validity of CA($VALIDITY_OF_CA days). Upgrade will update current certificates with the lower period."
            VALIDITY_PERIOD=$VALIDITY_OF_CA
        fi
        [[ $VALIDITY_PERIOD == "0" ]] && VALIDITY_PERIOD=365
    fi
}

updateClusterCertificate(){
    if [[ ! -f ${UPGRADE_TEMP}/update_crt_complete ]] ; then
        write_log "debug" "Refresh cluster certificates..."
        getValidityPeriod

        startRolling
        exec_cmd "${CURRENT_DIR}/cdf/scripts/renewCert --renew -t cluster -V ${VALIDITY_PERIOD} --local -y >>$LOGFILE 2>&1"
        exit_code=$?
        stopRolling
        [[ $exit_code != 0 ]] && write_log "fatal" "Failed to renew cluster certificates." || write_log "info" "     Renewing cluster certificates..."

        if [[ $IS_MASTER == "true" ]] && [[ ! -f ${CDF_HOME}/ssl/kube-serviceaccount.pub ]] ; then
            write_log "debug" "Generate public key..."
            exec_cmd "openssl rsa -in ${CDF_HOME}/ssl/kube-serviceaccount.key -out ${CDF_HOME}/ssl/kube-serviceaccount.pub"
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to generate the public key ${CDF_HOME}/ssl/kube-serviceaccount.pub "
            fi
            exec_cmd "chmod 400 ${CDF_HOME}/ssl/kube-serviceaccount.pub"
        fi

        #chown certs owner
        for cert in ${TLS_CERTS} ; do
            chownCertificate "$cert" "${CDF_HOME}/ssl"
        done

        exec_cmd "touch ${UPGRADE_TEMP}/update_crt_complete"
    else
        write_log "debug" "cluster certificates have been updated already."
    fi
}

updateIngressCertificate(){
    if [[ ! -f ${UPGRADE_TEMP}/update_crt_complete ]] ; then
        if [[ $UPGRADE_CDF == "true" ]]; then
            if [[ $DEPLOYMENT_MANAGEMENT == "true" ]] || [[ $CLUSTER_MANAGEMENT == "true" ]] || [[ $MONITORING == "true" ]] ; then
                local selfsigned=false
                getResource "secret" "nginx-default-secret" "${CDF_NAMESPACE}" '.data."tls.crt"'
                if [[ $? == 0 ]] ; then
                    local issuer=
                    issuer=$(echo "$RESULT" | base64 -d | openssl x509 -issuer -noout)
                    exec_cmd "echo '$issuer' | grep 'MF RE CA on Vault'"
                    if [[ $? == 0 ]] ; then
                        selfsigned=true
                    fi
                fi

                if [[ $selfsigned == "true" ]] ; then
                    write_log "info" "     Refreshing ingress certificates..."
                    exec_cmd "${CDF_HOME}/scripts/renewCert --renew -t ingress -V 365 -y >>$LOGFILE 2>&1"
                    if [[ $? != 0 ]] ; then
                        write_log "fatal" "Failed to renew ingress certificates."
                    fi
                else
                    write_log "info" "     Customer certificates can only be managed by user themselves and cannot be renewed by upgrade."
                fi
            else
                write_log "debug" "No need to update ingress certs."
            fi
        fi
        exec_cmd "touch ${UPGRADE_TEMP}/update_crt_complete"
    else
        write_log "debug" "ingress certificates have been updated already."
    fi
}

specialSettingExample(){
    local fromVersion=
    fromVersion=${FROM_INTERNAL_RELEASE}
    if [[ $fromVersion == "" ]] || [[ $fromVersion == "null" ]] ; then
        write_log "fatal" "Failed to get current release verison."
    fi
    if [[ ! -f ${UPGRADE_TEMP}/xxx_complete ]] ; then
        if [[ ${fromVersion} == "xxxxxx" ]] || [[ ${fromVersion} == "xxxxxx" ]] || [[ ${fromVersion} == "xxxxxx" ]]; then
            echo "Pretend to do something"
            exec_cmd "touch ${UPGRADE_TEMP}/xxx_complete"
        else
            write_log "debug" "${FUNCNAME[0]}: Nothing to do in this release."
        fi
    else
        write_log "debug" "Already done. Func: ${FUNCNAME[0]}"
    fi
}

specialSettings(){
    countRemainingSteps
    write_log "info" "\n** Configurations before upgrade ... ${STEP_CONT}"
    updateClusterCertificate
    addDNSForNewNodes
    removeEndpointPermission
    addTlsRelatedParam
    enableFirewallForward
    updateClusterHostCM
}

updateClusterHostCM(){
    if [[ $FROM_INTERNAL_RELEASE -lt "202411" ]] && [[ $isFirstMaster == "true" ]]; then
        reconfigResource "cm" "cdf-cluster-host" "${CDF_NAMESPACE}" "-p '{\"data\":{\"FLANNEL_DIRECTROUTING\":\"${FLANNEL_DIRECTROUTING}\"}}'"
        reconfigResource "cm" "cdf-cluster-host" "${CDF_NAMESPACE}" "-p '{\"data\":{\"FLANNEL_PORT\":\"${FLANNEL_PORT}\"}}'"
    fi
}

addTlsRelatedParam(){
    if [[ $FROM_INTERNAL_RELEASE -lt "202305" ]] && [[ $isFirstMaster == "true" ]]; then
        reconfigResource "cm" "cdf-cluster-host" "${CDF_NAMESPACE}" "-p '{\"data\":{\"TLS_MIN_VERSION\":\"${DEFAULT_TLS_MIN_VERSION}\" , \"TLS_CIPHERS\": \"${DEFAULT_TLS_CIPHERS}\" }}'"
    fi
}

enableFirewallForward(){
    if [[ $FROM_INTERNAL_RELEASE -ge "202405" ]] ; then
        write_log "debug" "No need to execute ${FUNCNAME[0]}"
        return 0
    fi

    if isServiceActive "firewalld"; then
        local firewall_version="$(exec_cmd "firewall-cmd --version" -p=true)"
        local requried_version="0.9.0"
        local lowerVersion=$(getLowerVersion $firewall_version $requried_version)
        #if firewalld version is >= 0.9.0, enable packets forwarding
        if [[ $lowerVersion == $requried_version ]]; then
            exec_cmd "firewall-cmd --add-forward --permanent"
            exec_cmd "firewall-cmd --add-forward"
            exec_cmd "firewall-cmd --add-interface=cni0 --permanent"
            exec_cmd "firewall-cmd --add-interface=cni0"
            exec_cmd "firewall-cmd --list-all"
        fi
    else
        write_log "debug" "firewalld service is not started. No action."
    fi
}

patchDnsServiceIp(){
    if [[ $FROM_INTERNAL_RELEASE -ge "202305" ]] ; then
        write_log "debug" "No need to execute ${FUNCNAME[0]}"
        return 0
    fi
    if [ "${isFirstMaster}" == "true" ]; then
        reconfigResource "cm" "cdf-cluster-host" "${CDF_NAMESPACE}" "-p '{\"data\":{\"DNS_SVC_IP\":\"${DNS_SVC_IP}\"}}'"
    fi
}

patchHelmMark(){
    reconfigResource "secret" "nginx-frontend-secret" "$CDF_NAMESPACE" "-p '{ \"metadata\": { \"annotations\": { \"meta.helm.sh/release-name\": \"$CDF_CHART_RELEASE\", \"meta.helm.sh/release-namespace\": \"$CDF_NAMESPACE\" }, \"labels\": { \"app.kubernetes.io/managed-by\": \"Helm\" } } }'"
    reconfigResource "secret" "nginx-default-secret" "$CDF_NAMESPACE" "-p '{ \"metadata\": { \"annotations\": { \"meta.helm.sh/release-name\": \"$CDF_CHART_RELEASE\", \"meta.helm.sh/release-namespace\": \"$CDF_NAMESPACE\" }, \"labels\":{ \"app.kubernetes.io/managed-by\": \"Helm\" } } }'"
}

patchUninstallLabel() {
    # [Doc] OCTCR19S1753547
    # add "deployments.microfocus.com/cleanup=uninstall" label to manage all k8s objects of OMT by helm for external K8s
    local cmList=("yaml-templates" "feature-gates")
    for configmap in ${cmList[@]} ; do
        reconfigResource "cm" "$configmap" "${CDF_NAMESPACE}" "-p '{ \"metadata\": { \"labels\": { \"deployments.microfocus.com/cleanup\": \"uninstall\" } } }'"
    done
    reconfigResource "secret" "velero-restic-credentials" "${CDF_NAMESPACE}" "-p '{ \"metadata\": { \"labels\": { \"deployments.microfocus.com/cleanup\": \"uninstall\" } } }'"
    # registrypullsecret exist under both kube-system&CDF_NAMESPACE ns in normal; in byok env, registrypullsecret only exist under CDF_NAMESPACE ns
    if [[ ${BYOK} == "true" ]] ; then
        reconfigResource "secret" "registrypullsecret" "${CDF_NAMESPACE}" "-p '{ \"metadata\": { \"labels\": { \"deployments.microfocus.com/cleanup\": \"uninstall\" } } }'"
    else
        reconfigResource "secret" "registrypullsecret" "${CDF_NAMESPACE}" "-p '{ \"metadata\": { \"labels\": { \"deployments.microfocus.com/cleanup\": \"uninstall\" } } }'"
        reconfigResource "secret" "registrypullsecret" "kube-system" "-p '{ \"metadata\": { \"labels\": { \"deployments.microfocus.com/cleanup\": \"uninstall\" } } }'"
    fi
}

componentSpecialSettings(){
    patchHelmMark
    if [[ ${BYOK} == "true" ]] ; then
        switchHelmRepo
    fi
    patchUninstallLabel
}

getIsLastNode(){
    local all_nodes=
    local upgraded_nodes=
    local nodes_num=
    local upgraded_nodes_num=0
    all_nodes=$(exec_cmd "kubectl get nodes --no-headers 2>/dev/null | awk '{print \$1}' | xargs | tr '[:upper:]' '[:lower:]'" -p=true)
    upgraded_nodes=$(exec_cmd "kubectl get cm upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE} -n ${CDF_NAMESPACE} -o json 2>/dev/null | ${JQ} -r '.data.UPGRADED_NODES?'" -p=true)
    nodes_num=(${all_nodes})
    nodes_num=${#nodes_num[@]}
    write_log "debug" "all_nodes: ${all_nodes} , nodes_num: ${nodes_num} , upgraded_nodes: ${upgraded_nodes}"
    if [[ ${all_nodes} == "" ]] ; then
        write_log "fatal" "Failed to get nodes information. Check if the kubectl command works."
    fi
    for node in $upgraded_nodes ; do 
        if [[ ${all_nodes} =~ ${node} ]] ; then
            (( upgraded_nodes_num++ ))
        fi
    done
    write_log "debug" "upgraded_nodes_num: ${upgraded_nodes_num}"
    if [[ ${nodes_num} == $(($upgraded_nodes_num + 1)) ]] ; then
        IS_LAST_NODE=true
    else
        IS_LAST_NODE=false
    fi
}

setInfraUpgradeConfigMap(){
    if [[ ${IS_LAST_NODE} == "true" ]] ; then
        if [[ $UPGRADE_MF_K8S_ONLY == "false" ]] ; then
            createResource "cm" "infra-upgrade-complete-${TARGET_INTERNAL_RELEASE}" "${CDF_NAMESPACE}" "" "30"
        fi
    fi
}

setInfraVersion(){
    if [[ ${IS_LAST_NODE} == "true" ]] ; then
        reconfigResource "cm" "cdf-cluster-host" "${CDF_NAMESPACE}" "-p '{\"data\":{\"INFRA_VERSION\":\"$TARGET_VERSION\"}}'"
        reconfigResource "cm" "cdf-cluster-host" "${CDF_NAMESPACE}" "-p '{\"data\":{\"INTERNAL_VERSION\":\"$TARGET_INTERNAL_VERSION\"}}'"
    fi
}

updateYamlTemplateConfigmap(){
    if [[ ! -f ${UPGRADE_TEMP}/yalm_temp_cm_complete ]] ; then
        write_log "info" "     Updating yaml-templates configmap ..."
        local yaml="$CURRENT_DIR/cdf/objectdefs/itom-cdf-deployer.yaml"
        local phase2_yaml="$CURRENT_DIR/cdf/objectdefs/itom-cdf-deployer-phase2.yaml"

        deleteResource "cm" "yaml-templates" "${CDF_NAMESPACE}"
        createResource "cm" "yaml-templates" "${CDF_NAMESPACE}" "--from-file=itom-cdf-deployer.yaml=$yaml --from-file=itom-cdf-deployer-phase2.yaml=$phase2_yaml"
        exec_cmd "touch ${UPGRADE_TEMP}/yalm_temp_cm_complete"
    else
        write_log "info" "     Configmap yaml-templates has already been updated. Proceeding to the next step."
    fi
}

updateAddNodeConfigmap(){
    if [ "${isFirstMaster}" == "true" ]; then
        if [[ ! -f ${UPGRADE_TEMP}/addnode_cm_complete ]] ; then
            write_log "info" "     Updating add-node configmap ..."
            local installConfigFile=${CDF_HOME}/cfg/cdf-addnode.json
            local cmName="addnode-configmap"

            if [ $(exec_cmd "kubectl get configmap ${cmName} -n ${CDF_NAMESPACE}" -p=false; echo $?) -eq 0 ] ; then
                exec_cmd "kubectl delete configmap ${cmName} -n ${CDF_NAMESPACE}" -p=false
            fi
            if [ -f $installConfigFile ]; then
                local reTryTimes=0
                while true;do
                    if exec_cmd "kubectl get cm $cmName -n ${CDF_NAMESPACE}"; then
                        write_log "info" "     Update addnode configmap successfully"
                        break
                    else
                        exec_cmd "kubectl create configmap $cmName --from-file=INSTALL_CONFIG=$installConfigFile -n ${CDF_NAMESPACE}"
                        if [ $reTryTimes -ge 5 ]; then
                            if [ $? -ne 0 ]; then
                                write_log "fatal" "Failed to create configmap: $cmName"
                            fi
                        else
                            write_log "debug" "Failed to create $cmName configmap. Wait for $SLEEP_TIME seconds and retry: $reTryTimes"
                        fi
                        reTryTimes=$(( $reTryTimes + 1 ))
                        sleep $SLEEP_TIME
                    fi
                done
            else
                write_log "fatal" "Missing file: $installConfigFile"
            fi
            exec_cmd "touch ${UPGRADE_TEMP}/addnode_cm_complete"
        else
            write_log "info" "     Images configmap has already been created. Proceeding to the next step."
        fi
    fi
}

configureNodeManagerRBAC(){
    if [ "${isFirstMaster}" == "true" ]; then
        local saName=itom-node-manager
        if [[ ! -f ${UPGRADE_TEMP}/$saName_complete ]] ; then
            write_log "info" "     Configuring $saName RBAC ..."
            local file=${CDF_HOME}/objectdefs/$saName.yaml
            exec_cmd "$CP -f ${CURRENT_DIR}/cdf/objectdefs/$saName.yaml $file"
            replacePlaceHolder $file
            createFromYaml $file
            write_log "info" "     Configure $saName RBAC successfully."  
            exec_cmd "touch ${UPGRADE_TEMP}/$saName_complete"
        else
            write_log "info" "     $saName service account has been created. Proceeding to the next step."
        fi
    fi
}

cleanKubeCache(){
    exec_cmd "${RM} -rf ~/.kube/http-cache/"
    exec_cmd "${RM} -rf ~/.kube/cache/"
}

updateKubernetesService(){
    write_log "info" "\n     Updating K8S service ..."
    if [[ ! -f ${UPGRADE_TEMP}/kubernetes_service_complete ]] ; then
        #upgrade apiserver,controller,scheduler
        upgdateK8SComponent
        if [[ "${IS_MASTER}" == "true" ]] ; then
            checkApiServer
        fi
        #clean cache
        cleanKubeCache
        #create cache
        execCmdWithRetry "kubectl get nodes" "60"
        if [[ $? != 0 ]] ; then
            cleanKubeCache
            execCmdWithRetry "kubectl get nodes" "60" "3"
            [[ $? != 0 ]] && write_log "fatal" "Failed to run kubectl command. Please make sure kubectl works."
        fi

        #upgrade kubectl 
        write_log "info" "     Updating kubectl components..."
        local currentV=$(exec_cmd "${CDF_HOME}/bin/kubectl version -o json 2>>$LOGFILE | ${JQ} -r '.clientVersion.gitVersion'" -p=true)
        local expectedV=$(exec_cmd "${CURRENT_DIR}/k8s/bin/kubectl version -o json 2>>$LOGFILE | ${JQ} -r '.clientVersion.gitVersion'" -p=true)
        local lowerVersion=$(getLowerVersion $currentV $expectedV)
        if [[ $lowerVersion != $currentV ]] ; then
            write_log "info" "     Kubectl version is up to date. No need to upgrade Kubectl Service."
        else
            exec_cmd "${CP} -rf ${CURRENT_DIR}/k8s/bin/kubectl ${CDF_HOME}/bin/."
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to upgrade kubectl."
            fi
        fi

        #upgrade kubelet
        write_log "info" "     Updating kubelet components..."
        componentUpgradeCheck "kubelet"       
        if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
            write_log "info" "     Kubelet version is up to date. No need to upgrade kubelet Service."
        else
            write_log "info" "     Updating kubelet service file..."
            local svcTmpFile=${CDF_HOME}/cfg/systemd-template/kubelet.service
            local cnfTmpFile=${CDF_HOME}/cfg/systemd-template/kubelet-config
            local svcFile=/usr/lib/systemd/system/kubelet.service
            local cnfFile=${CDF_HOME}/cfg/kubelet-config
            if [[ -f "${svcTmpFile}" ]] ; then
                exec_cmd "${CP} -f ${svcTmpFile} ${svcFile}"
                replacePlaceHolder ${svcFile}
            fi
            if [[ -f "${cnfTmpFile}" ]] ; then
                if [[ ${IS_MASTER} != "true" ]] ; then
                    exec_cmd "sed -i -e '/^staticPodPath\s*:/d' $cnfTmpFile"
                    exec_cmd "${RM} -rf ${CDF_HOME}/runconf"
                fi
                exec_cmd "${CP} -f ${cnfTmpFile} ${cnfFile}"
                replacePlaceHolder ${cnfFile}
            fi
            write_log "info" "     Updating kubelet service..."
            stopSystemdSvc kubelet
            write_log "info" "     Replacing kubelet executable file..."
            exec_cmd "${RM} -f ${CDF_HOME}/bin/kubelet"
            exec_cmd "${CP} -f ${CURRENT_DIR}/k8s/bin/kubelet ${CDF_HOME}/bin/kubelet"
            chmod 700 ${CDF_HOME}/bin/kubelet
            if [[ $? -eq 0 ]] && [[ -f ${CDF_HOME}/bin/kubelet ]] ; then
                write_log "info" "     Replace kubelet executable file completed. "
            else
                write_log "fatal" "Replace kubelet executable file failed. "
            fi
            #reload and restart kubelet service
            reloadSystemdSvc "kubelet"
            restartSystemdSvc "kubelet"
        fi
        exec_cmd "touch ${UPGRADE_TEMP}/kubernetes_service_complete"
    else
        write_log "info" "     Kubelet Service has already been updated. Proceeding to the next step."
    fi
}

updateCniPlugin() {
    if [[ ! -f ${UPGRADE_TEMP}/updateCni_complete ]] ; then
        #replace binaries
        local cniDir=${CURRENT_DIR}/k8s/cni
        exec_cmd "${CP} -rf ${cniDir} ${CDF_HOME}/."
        if [[ $? != 0 ]] ; then
            write_log "fatal" "Failed to copy cni folders."
        fi
        
        exec_cmd "chown -R ${SYSTEM_USER_ID} ${CDF_HOME}/cni"

        #update fapolicy rules
        local cniFiles=$(find $CDF_HOME/cni -maxdepth 1 -type f)
        updateFapolicy "$cniFiles"

        exec_cmd "touch ${UPGRADE_TEMP}/updateCni_complete"
        write_log "info" "     Cni-plugin upgrade completed on this node."
    else
        write_log "info" "     Cni-plugin already upgraded. Proceeding to the next step."
    fi    
}

# handle the case when updating pause images
updateNonPrunedImage() {
    # only need to handle the case for pause:3.2 when the option '--pod-infra-container-image' exists
    exec_cmd "grep 'pod-infra-container-image' /usr/lib/systemd/system/kubelet.service | grep '${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/pause:3.2'"
    if [[ $? == 0 ]] ; then
        exec_cmd "sed -i 's@pod-infra-container-image=${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/pause:3.2@pod-infra-container-image=${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_PAUSE}@g' /usr/lib/systemd/system/kubelet.service"
        if [[ $? != 0 ]] ; then
            write_log "fatal" "Failed to update non-pruned sandbox image."
        fi
    fi
    #load pause image in case cornor case happened
    loadpauseImage
}

loadpauseImage(){
    # check pause image and load if not exist
    exec_cmd "${CDF_HOME}/bin/ctr -n k8s.io images list | grep ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_PAUSE}"
    if [[ $? != 0 ]] ; then
        exec_cmd "${CDF_HOME}/bin/ctr -n k8s.io images import --snapshotter overlayfs <(gzip --decompress --stdout ${CURRENT_DIR}/k8s/images/infra-common-images.tgz)"
        tagImage "localhost:5000/${IMAGE_PAUSE}" "${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_PAUSE}"
        exec_cmd "${CDF_HOME}/bin/ctr -n k8s.io images label ${DOCKER_REPOSITORY}/${REGISTRY_ORGNAME}/${IMAGE_PAUSE} io.cri-containerd.pinned=pinned"
    fi
}

updateContainerdService() {
    if [[ ! -f ${UPGRADE_TEMP}/updateContainerd_complete ]] ; then
        write_log "info" "     Updating Containerd service ..."
        exec_cmd "touch ${UPGRADE_TEMP}/updateContainerd_start"
        #load pause image
        loadpauseImage
        
        local fromVersion=$(cat ${CDF_HOME}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "containerd"  ) | .internalVersion')
        local targetVersion=$(cat ${CURRENT_DIR}/moduleVersion.json 2>/dev/null | ${JQ} -r '.[] | select ( .name == "containerd"  ) | .internalVersion')
        getPatchUpgradeFlag "$fromVersion" "$targetVersion"
        write_log "debug" "COMPONENT_PATCH_UPGRADE: $COMPONENT_PATCH_UPGRADE"

        # replace containerd service file and config file
        local svcTmpFile=${CDF_HOME}/cfg/systemd-template/containerd.service
        local svcFile=/usr/lib/systemd/system/containerd.service
        if [[ -f "${svcTmpFile}" ]] ; then
            exec_cmd "${CP} -f ${svcTmpFile} ${svcFile}"
            [[ $? != 0 ]] &&  write_log "fatal" "Failed to copy service file from ${svcTmpFile} to ${svcFile}."
            replacePlaceHolder ${svcFile}
        fi
        local configTmpFile=${CDF_HOME}/cfg/systemd-template/containerd-config.toml
        local configFile=${CDF_HOME}/cfg/containerd-config.toml
        if [[ -f "${configTmpFile}" ]] ; then
            exec_cmd "${CP} -f ${configTmpFile} ${configFile}"
            [[ $? != 0 ]] &&  write_log "fatal" "Failed to copy config file from ${configTmpFile} to ${configFile}."
            replacePlaceHolder ${configFile}
        fi
        local registryTmpCfgFolder=${CDF_HOME}/cfg/registry-template/certs.d
        local cdfCfgFolder=${CDF_HOME}/cfg
        local registryCfgFolder=${cdfCfgFolder}/certs.d
        local localregistryCfgFile=${registryCfgFolder}/localhost:5000/hosts.toml
        exec_cmd "${CP} -rf ${registryTmpCfgFolder} ${cdfCfgFolder}"
        exec_cmd "${RM} -rf ${registryCfgFolder}/localhost:5000" 
        exec_cmd "${MV} ${registryCfgFolder}/localhost_5000 ${registryCfgFolder}/localhost:5000" || write_log "fatal" "Failed to set containerd configurations for local registry."
        replacePlaceHolder "$localregistryCfgFile"

        # reload containerd service
        reloadSystemdSvc "containerd"

        stopSystemdSvc kubelet

        if [[ $COMPONENT_PATCH_UPGRADE != "true" ]] ; then
            # kill all pods
            execCmdWithRetry "crictl rmp -af" "6" "10"
            if [[ $? != 0 ]] ; then
                # OCTCR19S1748504: sometimes suite pods can't be killed forcely, restarting containerd service can help to walkaround
                restartSystemdSvc "containerd"
                execCmdWithRetry "crictl rmp -af" "6" "10"
                if [[ $? != 0 ]] && [[ -n "$(${LS} -A $RUNTIME_CDFDATA_HOME/containerd/state/io.containerd.runtime.v2.task/k8s.io 2>>$LOGFILE)" ]] ; then
                    #dir not empty => container bundles left => not all containers are killed
                    write_log "warn" "Warning! Unable to kill all pods forcely."
                fi     
            fi
        fi

        #update sandbox image in kubelet service in advance to prevent being pruned before K8s upgrade
        updateNonPrunedImage

        stopSystemdSvc containerd

        # update file system of state directory if it's not tmpfs
        local stateDir=${RUNTIME_CDFDATA_HOME}/containerd/state
        local stateBackup=${RUNTIME_CDFDATA_HOME}/containerd/state.backup
        local fstype=$(exec_cmd "df --output=fstype ${stateDir} | grep -v Type" -p=true)
        if [[ ${fstype} != "tmpfs" ]] ; then
            # change filesystem to tmpfs
            if [ ! -d ${stateBackup} ] ; then
                exec_cmd "${MV}  ${stateDir} ${stateBackup}"
                exec_cmd "mkdir  ${stateDir}"
                exec_cmd "mount -t tmpfs tmpfs ${stateDir}"
                exec_cmd "${CP} -rf ${stateBackup}/* ${stateDir}"
            fi
            # add tmpfs path to /etc/fstab to make it work when restart OS
            local tmpfstab=$(cat /etc/fstab | grep ${stateDir})
            [[ $tmpfstab == "" ]] && exec_cmd "echo 'tmpfs    ${stateDir}    tmpfs    defaults    0 0' >> /etc/fstab"
        fi

        #replace binaries
        exec_cmd "${CP} -rf ${CURRENT_DIR}/cri/bin/* ${CDF_HOME}/bin/"
        if [[ $? != 0 ]] ; then
            write_log "fatal" "Failed to copy cri folders."
        fi

        #update fapolicy rules
        local runcFiles="$CDF_HOME/bin/containerd-shim-runc-v2 $CDF_HOME/bin/runc"
        updateFapolicy "$runcFiles"

        restartSystemdSvc "containerd"
        reloadSystemdSvc "kubelet"
        restartSystemdSvc "kubelet"
        
        if [[ $IS_MASTER == "true" ]] ; then
            checkApiServer
            [[ ${DOCKER_REPOSITORY} == "localhost:5000" ]] && checkDeploymentReday "kube-registry" "${CDF_NAMESPACE}"
        fi
        exec_cmd "touch ${UPGRADE_TEMP}/updateContainerd_complete"
        write_log "info" "     Containerd service upgrade completed on this node."
        [[ -d ${stateBackup} ]] && exec_cmd "${RM} -rf ${stateBackup}"
    else
        write_log "info" "     Containerd service already upgraded. Proceeding to the next step."
    fi
}

patchKubeProxyCfg(){
    if [[ $isFirstMaster == "true" ]] ; then
        write_log "debug" "Patch kube-proxy-cfg cm..."
        local masterNodes=${MASTER_NODES[*]}
        local workNerNodes=${WORKER_NODES[*]}
        local json=

        for node in $masterNodes ; do
            execCmdWithRetry "kubectl patch cm kube-proxy-cfg -n ${KUBE_SYSTEM_NAMESPACE} -p '{\"data\": { \"$node\": \"export KUBERNETES_SERVICE_HOST=$node\" }}'" "20" "5"
            [[ $? != 0 ]] && write_log "fatal" "Failed to patch configmap kube-proxy-cfg in $KUBE_SYSTEM_NAMESPACE namespace."
        done

        for node in $workNerNodes ; do
            execCmdWithRetry "kubectl patch cm kube-proxy-cfg -n ${KUBE_SYSTEM_NAMESPACE} -p '{\"data\": { \"$node\": \"export KUBERNETES_SERVICE_HOST=$K8S_MASTER_IP\" }}'" "20" "5"
            [[ $? != 0 ]] && write_log "fatal" "Failed to patch configmap kube-proxy-cfg in $KUBE_SYSTEM_NAMESPACE namespace."
        done
    else
        write_log "debug" "No need to patch kube-proxy-cfg cm on this node."
    fi
}

upgradeKubeProxy(){
    write_log "info" "\n     Updating Kubernetes Proxy ..."
    if [[ ! -f ${UPGRADE_TEMP}/kube_proxy_complete ]] ; then
        componentUpgradeCheck "kube-proxy"
        if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
            write_log "info" "     Kubernetes component kube-proxy version is up to date. No need to upgrade kube-proxy."
            exec_cmd "touch ${UPGRADE_TEMP}/kube_proxy_complete"
            return
        fi

        startRolling
        exec_cmd "${CP} -rf ${CURRENT_DIR}/k8s/objectdefs/kube-proxy-config.yaml ${CDF_HOME}/objectdefs/."
        exec_cmd "${CP} -rf ${CURRENT_DIR}/k8s/objectdefs/kube-proxy.yaml ${CDF_HOME}/objectdefs/."
        replacePlaceHolder $CDF_HOME/objectdefs/kube-proxy-config.yaml
        replacePlaceHolder $CDF_HOME/objectdefs/kube-proxy.yaml

        #upgrade kube-proxy configuration
        redeployYamlFile $CDF_HOME/objectdefs/kube-proxy-config.yaml

        patchKubeProxyCfg

        #upgrade kube-proxy daemon-set
        redeployYamlFile $CDF_HOME/objectdefs/kube-proxy.yaml
        
        execCmdWithRetry "kubectl rollout status ds kube-proxy -n ${KUBE_SYSTEM_NAMESPACE} 1>>$LOGFILE 2>&1" "" "3"
        exit_code=$?
        stopRolling
        [[ $exit_code != 0 ]] && write_log "fatal" "Failed to rolling update daemonset kube-proxy..." || write_log "info" "     Rolling update daemonset kube-proxy successfully."
        exec_cmd "touch ${UPGRADE_TEMP}/kube_proxy_complete"
    else
        write_log "info" "     Kubernetes Proxy service has already been updated. Proceeding to the next step."
    fi
}

upgradeMetricsServer(){
    write_log "info" "\n     Updating Metrics Server ..."
    if [[ ! -f ${UPGRADE_TEMP}/metrics_server_complete ]] ; then
        replacePlaceHolder $CDF_HOME/objectdefs/metrics-server.yaml
        # componentUpgradeCheck "metrics-server"
        # if [[ $COMPONENT_UPGRADE_FLAG != "true" ]] ; then
        #     write_log "info" "     Kubernetes component metrics-server version didn't change. No need to upgrade metrics-server."
        #     exec_cmd "touch ${UPGRADE_TEMP}/metrics_server_complete"
        #     return
        # fi

        #upgrade metrics-server deployment
        redeployYamlFile $CDF_HOME/objectdefs/metrics-server.yaml

        execCmdWithRetry "kubectl rollout status deployment metrics-server -n ${KUBE_SYSTEM_NAMESPACE} 1>>$LOGFILE 2>&1" "" "3"
        [[ $? != 0 ]] && write_log "fatal" "Failed to rolling update deployment metrics-server..."
        exec_cmd "touch ${UPGRADE_TEMP}/metrics_server_complete"
    else
        write_log "info" "     Kubernetes Proxy service has already been updated. Proceeding to the next step."
    fi
}

checkK8Salive(){
    exec_cmd "kubectl get nodes"
    if [[ $? != 0 ]] ; then
        write_log "fatal" "kubectl command doesn't work, please make sure kubectl command works."
    fi
}

checkHelmalive(){
    local msg=
    msg=$(exec_cmd "${HELM} list -A -a" -p true)
    if [[ $? != 0 ]] ; then
        write_log "fatal" "helm command doesn't work, please make sure helm command works. Error: $msg"
    fi
}

#Usage: getResource <Resource> <ResourceName> <Namespace> <Path> <totalReTryTimes>
getResource(){
    checkK8Salive

    local rs="$1"
    local rsName="$2"
    local namespace="$3"
    local path="$4"
    local totalReTryTimes="${5:-${RETRY_TIMES}}"
    local rsop="$6"

    if [[ $namespace != "-A" ]] && [[ $namespace != "--all-namespaces" ]] && [[ $namespace != "" ]] ; then
        namespace="-n $namespace"
    fi

    local reTryTimes=0
    local rawData=
    RESULT=
    while true ; do
        rawData=$(kubectl get ${rs} ${rsName} ${namespace} ${rsop} -o json 2>>${LOGFILE})
        if [[ $? == 0 ]] ; then
            RESULT=$(echo $rawData | ${JQ} -r "$path?")
            if [[ $? == 0 ]] ;then
                if [[ $RESULT == "null" ]] || [[ $RESULT == "" ]]; then
                    return 1
                fi 
                break
            else
                if [[ $reTryTimes -gt $totalReTryTimes ]] ; then
                    write_log "fatal" "Failed to get result by using commond 'echo "${rawData}" | ${process}'"
                else
                    ((reTryTimes++))
                    sleep 2
                fi
            fi
        else
            return 1
        fi
    done
}

#Usage: createResource <Resource> <ResourceName> <Namespace> <ExtraOptions> <totalReTryTimes> <rsop>
createResource(){
    local rs="$1"
    local rsName="$2"
    local ns="$3"
    local op="$4"
    local totalReTryTimes="${5:-${RETRY_TIMES}}"
    local rsop="$6"
    
    local reTryTimes=0
    while true ; do
        exec_cmd "kubectl get ${rs} ${rsName} -n ${ns}"
        if [[ $? == 0 ]] ; then
            write_log "debug" "The ${rs} ${rsName} found. No need to create."
            break
        else
            exec_cmd "kubectl create ${rs} ${rsop} ${rsName} -n ${ns} ${op}"
            if [[ $? == 0 ]] ; then
                write_log "debug" "The ${rs} ${rsName} was created successfully."
                break
            elif [[ $reTryTimes -gt $totalReTryTimes ]] ; then
                write_log "fatal" "Failed to create ${rs} ${rsName}."
            else
                ((reTryTimes++))
                sleep 2
            fi
        fi
    done
}

#Usage: deleteResource <Resource> <ResourceName> <Namespace> <totalReTryTimes>
deleteResource(){
    local rs="$1"
    local rsName="$2"
    local ns="$3"
    local totalReTryTimes="${4:-${RETRY_TIMES}}"
    
    if [[ ! -z $ns ]] ; then
        ns="-n $ns"
    fi

    local reTryTimes=0
    while true ; do
        exec_cmd "kubectl get ${rs} ${rsName} ${ns}"
        if [[ $? == 0 ]] ; then
            exec_cmd "kubectl delete ${rs} ${rsName} ${ns}"
            if [[ $? == 0 ]] ; then
                write_log "debug" "The ${rs} ${rsName} was deleted successfully."
                break
            elif [[ $reTryTimes -gt $totalReTryTimes ]] ; then
                write_log "fatal" "Failed to delete ${rs} ${rsName}."
            else
                ((reTryTimes++))
                sleep 2
            fi
        else
            write_log "debug" "The ${rs} ${rsName} wasn't found. No need to clean."
            break
        fi
    done
}

#Usage: reconfigResource <Resource> <ResourceName> <Namespace> <Params> <totalReTryTimes>
reconfigResource(){
    local rs="$1"
    local rsName="$2"
    local ns="$3"
    local params="$4"
    local totalReTryTimes="${5:-${RETRY_TIMES}}"
    local reTryTimes=0
    while true ; do
        exec_cmd "kubectl get ${rs} ${rsName} -n ${ns}"
        if [[ $? == 0 ]] ; then
            exec_cmd "kubectl patch ${rs} ${rsName} -n ${ns} ${params}"
            if [[ $? == 0 ]] ; then
                write_log "debug" "The ${rs} ${rsName} was edited successfully."
                break
            elif [[ $reTryTimes -gt $totalReTryTimes ]] ; then
                write_log "fatal" "Failed to edit ${rs} ${rsName}."
            else
                ((reTryTimes++))
                sleep 2
            fi
        else
            write_log "debug" "The ${rs} ${rsName} wasn't found. No need to edit."
            break
        fi
    done
}

# createConfigMapFromFile <configmapName> <namespace> <keyName> <filePath>
createConfigMapFromFile(){
    local configmap=$1
    local namespace=$2
    local keyName=$3=
    local filePath=$4

    #if keyName is null， clean the =
    if [[ ${keyName} == "=" ]] ; then
        keyName=
    fi

    # check if already exsits
    if [ $(exec_cmd "kubectl get configmap ${configmap} -n ${namespace}"; echo $?) -eq 0 ]; then
        if [[ ! -f ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/${configmap}.json ]] ; then
            write_log "info" "     Configmap $configmap has a old version. Save and delete..."
            exec_cmd "kubectl get configmap ${configmap} -n ${namespace} -o json > ${UPGRADE_TMP_FOLDER}/${BACKUP_DIR}/${configmap}.json"
            if [ $? -ne 0 ]; then
                write_log "error" "Failed to export the old configmap ${configmap}. "
            fi
        fi
        #add --force when delete this configmap
        exec_cmd "kubectl delete configmap ${configmap} -n ${namespace} --grace-period=0 --force"
        if [ $? -ne 0 ]; then
            write_log "error" "Failed to delete the configmap ${configmap}. "
        fi
    fi

    write_log "info" "     Start to create configmap $configmap ..."
    # create configmap from file
    local reTryTimes=0
    while true;do
        exec_cmd "kubectl create configmap ${configmap} -n ${namespace} --from-file=${keyName}${filePath}"
        if [ $? -ne 0 ]; then
            if [ $reTryTimes -ge 5 ]; then
                    write_log "fatal" "Failed to create configmap: ${configmap}"
            else
                write_log "debug" "Failed to create configmap ${configmap}. Wait for $SLEEP_TIME seconds and retry: $reTryTimes"
            fi
            reTryTimes=$(( $reTryTimes + 1 ))
            sleep $SLEEP_TIME
        else
            write_log "info" "     Configmap $configmap has been created."
            break
        fi
    done
}

getInitialCluster(){
    local initial_cluster=
    local symbol=
    for master in ${MASTER_NODES[@]}
    do
        initial_cluster="${initial_cluster}${symbol}${master}=https://${master}:2380"
        symbol=","
    done
    echo $initial_cluster
}

upgdateK8SComponent(){
    if [[ ! -f ${UPGRADE_TEMP}/upgrade_api_time ]] ; then
        #recond time which is seconds since 1970-01-01 00:00:00 UTC
        exec_cmd "echo \$(date \"+%s\") > ${UPGRADE_TEMP}/upgrade_api_time"
        local upgrade_api_time=$(cat ${UPGRADE_TEMP}/upgrade_api_time)
        write_log "debug" "upgrade_api_time: $upgrade_api_time"
        if [[ -z $upgrade_api_time ]] ; then
            write_log "fatal" "Failed to record k8s upgrade timestamp. Please retry for upgrade."
        fi
    fi
    if [ "$IS_MASTER" == "true" ];then
        if [[ ! -f ${UPGRADE_TEMP}/updateK8SComponent_complete ]] ; then
            upgradeApiServer
            upgradeControllerManager
            upgradeScheduler
            exec_cmd "touch ${UPGRADE_TEMP}/updateK8SComponent_complete"
            #reload and restart kubelet service
            reloadSystemdSvc "kubelet"
            restartSystemdSvc "kubelet"
        else
            write_log "     Updating kubernetes components already done."
        fi
    fi
}

preUpgrade(){
    backupUpgrade
    setenv
    removeAndCopy
    #work on the worker node
    drainNode
    #special settings before upgrade, need to remove after a major release
    specialSettings
}

shiftVIP(){
    if [[ ! -f ${UPGRADE_TEMP}/shiftVIP_complete ]] ; then
        if [[ ! -z ${HA_VIRTUAL_IP} ]] && [[ $MASTER_NODES_NUM -gt 1 ]]; then
            write_log "info" "\n     Shifting Virtual IP to other control-plane nodes..."
            local keepalived_pod=
            keepalived_pod=$(exec_cmd "kubectl get pods -n ${KUBE_SYSTEM_NAMESPACE} -o wide 2>/dev/null | grep -i ${THIS_NODE} | grep -i keepalive | awk '{print \$1}'" -p true)
            if [[ -n $keepalived_pod ]] ; then
                exec_cmd "kubectl delete pod $keepalived_pod -n $KUBE_SYSTEM_NAMESPACE"
            fi
            exec_cmd "touch ${UPGRADE_TEMP}/shiftVIP_complete"
        fi
    fi
}

upgrade(){
    source /etc/profile.d/itom-cdf.sh 2>/dev/null || source /etc/profile
    # distinguish master node or worker node
    if [ "$IS_MASTER" == "true" ];then
        shiftVIP
        upgradeEtcd
        updateKubernetesService
        upgradeFlannel
        upgradeKubeProxy
        upgradeDNSSvc
        upgradeMetricsServer
        upgradeKeepAlive
        #wait for the current node status ready!
        write_log "info" "     Waiting for the current node status ready"
        startRolling
        sleep 60
        stopRolling
        write_log "info" "     The current node is ready"
    else
        # worker node upgrade process
        updateKubernetesService
        upgradeFlannel
        upgradeKubeProxy
    fi
}

#process after upgrade
postUpgrade(){
    countRemainingSteps
    write_log "info" "\n** Post upgrade process ... ${STEP_CONT}"
    patchDnsServiceIp
    switchHelmRepo
    removeAbnormalPods
    removeRedundantSvc
    setUpgradedMastersConfigMap
    setUpgradedNodesConfigMap
    uncordonNode
    setInfraUpgradeConfigMap
    checkEPStatus
    cleanUpRuntimeImages
}

checkEPStatus(){
    write_log "info" "     Checking endpoints status ... "
    local retryTimes=0
    local retryTimesForEP=0
    local totalRetryTimesForEP=60
    local sleep_time=
    local reWaitFlag=false
    echo -ne "     "
    while true ; do
        sleep_time=6
        while true ; do
            exec_cmd "kubectl get ep -n ${CDF_NAMESPACE} -o json > ${UPGRADE_TEMP}/epStatus.json"
            if [[ $? == 0 ]] ; then
                write_log "debug" "Succeed to get endpoints information. "
                break
            else
                if [[ ${retryTimes} -lt ${RETRY_TIMES} ]] ; then
                    echo -ne "."
                    write_log "debug" "Failed to get endpoints information. Wait for $sleep_time seconds and recheck: $retryTimes"
                    sleep ${sleep_time}
                else
                    write_log "fatal" "\n     Failed to get endpoints information. Please make sure kubectl command work and try again."
                fi
                (( retryTimes++ ))
            fi
        done
        if [[ $reWaitFlag == "true" ]] ; then
            sleep_time=30
        else
            sleep_time=10
        fi
        local epLength=$(cat ${UPGRADE_TEMP}/epStatus.json | ${JQ} -r '.items | length')
        local index=0
        local notReadyEp=
        local reCheckFlag=false
        while [[ $index -lt $epLength ]] ; do
            notReadyEp=$(cat ${UPGRADE_TEMP}/epStatus.json | ${JQ} -r ".items[${index}]?.subsets[]?.notReadyAddresses?")
            if [[ $notReadyEp == "" ]] || [[ $notReadyEp == "null" ]] ; then
                notReadyEp=$(cat ${UPGRADE_TEMP}/epStatus.json | ${JQ} -r ".items[${index}]?.metadata.name")
                write_log "debug" "Endpoint $notReadyEp is ready."
            else
                notReadyEp=$(cat ${UPGRADE_TEMP}/epStatus.json | ${JQ} -r ".items[${index}]?.metadata.name")
                if [[ $notReadyEp =~ "suite-conf-svc" ]] || [[ $notReadyEp =~ "prometheus" ]] || [[  $notReadyEp =~ "grafana" ]] || [[ $notReadyEp =~ "alertmanager-operated" ]] || [[ $notReadyEp =~ "apphub-ui" ]] || [[ $notReadyEp =~ "apphub-apiserver" ]] || [[ $notReadyEp =~ "local-volume-provisioner" ]]; then
                    write_log "debug" "Not need to check ${notReadyEp}."
                    ((index++))
                    continue
                fi
                write_log "debug" "Endpoint $notReadyEp is not ready."
                reCheckFlag=true
            fi
            ((index++))
        done
        if [[ $reCheckFlag == true ]] ; then
            if [[ $retryTimesForEP -lt $totalRetryTimesForEP ]] ; then
                echo -ne "."
                write_log "debug" "     Not all endpoints are ready."
                sleep ${sleep_time}
                ((retryTimesForEP++))
            else
                if [[ $reWaitFlag == "false" ]] ; then
                    write_log "info" "     Not all endpoints are ready after ${sleep_time}*$RETRY_TIMES seconds. Restart kubelet service."
                    stopSystemdSvc kubelet
                    restartSystemdSvc kubelet
                    reWaitFlag=true
                    retryTimesForEP=0
                else
                    write_log "fatal" "     Not all endpoints are ready after restarting kubelet service. Please restart kubelet service manually on node ${THIS_NODE} and wait until the endpints ready, then you can re-run upgrade."
                fi
            fi
        else
            write_log "info" "     All endpoints are ready."
            break;
        fi
    done
}

showUpgradeSteps(){
    write_log "info" "\n** [NOTE] Please run the steps below in the following order:"
    if [[ $UPGRADE_MF_K8S_ONLY == "false" ]] ; then
    write_log "info" "
1)  Run command '${CURRENT_DIR}/upgrade.sh -i' on each control-plane node one by one.
2)  Run command '${CURRENT_DIR}/upgrade.sh -i' on each worker node one by one.
3)  Run command '${CURRENT_DIR}/upgrade.sh -u' on one of the control-plane nodes inside the cluster.
"
    else
        write_log "info" "
1)  Run command '$COMMAND_RECORD' on the each control-plane node one by one.
2)  Run command '$COMMAND_RECORD' on the each worker node one by one.
"
    fi
}

cleanUpgradeConfigmap() {
    write_log "info" "     Cleaning up upgrade configmaps ..."
    local interUpgradeCmList=()
    for ver in $K8S_INTERNAL_VERSION_LIST ; do
        interUpgradeCmList+=("$ver")
    done
    local upgradeCmList=
    if [[ "$UPGRADE_INFRA" == "true" ]] ; then
        upgradeCmList=("first-node-configmap-${TARGET_INTERNAL_RELEASE}" "master-finished" "upgraded-nodes-configmap-${TARGET_INTERNAL_RELEASE}" "module-version" ${interUpgradeCmList[@]})
    elif [[ "$UPGRADE_CDF" == "true" ]] ; then
        #base-configmap must be ahead of cdf-upgrade-in-process
        upgradeCmList=("infra-upgrade-complete-${TARGET_INTERNAL_RELEASE}" "upgrade-finished" "cdf-upgrade-in-process" "infra-upgrade-in-process")
    fi
    for configmap in ${upgradeCmList[@]} ; do
        deleteResource "cm" "$configmap" "${CDF_NAMESPACE}"
    done
}


createUpgradeTempFolder(){
    exec_cmd "mkdir -p ${UPGRADE_TEMP}"
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to create upgrade temp folder: ${UPGRADE_TEMP}"
    fi
}

cleanUpgradeTempFolder(){
    exec_cmd "${RM} -rf ${UPGRADE_TEMP}"
    exec_cmd "${RM} -rf ${UPGRADE_DATA}"

    # it should clean the parent folder created by upgrade
    # for on-premise, if data folder is not the same, it means the data folder is created by upgrade, then clean it
    # for byok, there is no RUNTIME_CDFDATA_HOME, always delete it
    if [[ ${DEFAULT_CDFDATA_HOME} != ${RUNTIME_CDFDATA_HOME} ]]; then
        if [[ -n "$(${LS} -A ${DEFAULT_CDFDATA_HOME} 2>>$LOGFILE)" ]]; then
            write_log "debug" "$DEFAULT_CDFDATA_HOME is not Empty. Skip cleaning."
        else
            write_log "debug" "$DEFAULT_CDFDATA_HOME is Empty. Try to clean it."
            #only remove directory, if it contains contents, it is safe to fail and exit
            exec_cmd "rmdir ${DEFAULT_CDFDATA_HOME}"
        fi
    fi
}

#only do on the first master node
createInfraUpgradeInProcessMark(){
    createResource "cm" "infra-upgrade-in-process" "${CDF_NAMESPACE}" "--from-literal=FROM_INTERNAL_INFRA_VERSION=${FROM_INTERNAL_VERSION} --from-literal=TARGET_INTERNAL_VERSION=${TARGET_INTERNAL_VERSION} --from-literal=FROM_INFRA_VERSION=$FROM_VERSION --from-literal=TARGET_VERSION=$TARGET_VERSION"
}

createUpgradeInProcessMark(){
    createResource "cm" "cdf-upgrade-in-process" "${CDF_NAMESPACE}" "--from-literal=FROM_INTERNAL_PLATFORM_VERSION=${FROM_INTERNAL_VERSION} --from-literal=TARGET_INTERNAL_VERSION=${TARGET_INTERNAL_VERSION} --from-literal=FROM_PLATFORM_VERSION=$FROM_VERSION --from-literal=TARGET_VERSION=$TARGET_VERSION"
    # Add uninstall label for cdf-upgrade-in-process once created; in case user executed uninstallation before it has been labeled, it impact next upgrade process
    reconfigResource "cm" "cdf-upgrade-in-process" "${CDF_NAMESPACE}" "-p '{ \"metadata\": { \"labels\": { \"deployments.microfocus.com/cleanup\": \"uninstall\" } } }'"
}

getCDFEnv(){
    UPGRADE_TMP_FOLDER_NEW=$UPGRADE_TMP_FOLDER
    if [[ -f ${CDF_HOME}/bin/env.sh ]] ; then
        source ${CDF_HOME}/bin/env.sh 2>>$LOGFILE
    else
        write_log "fatal" "${CDF_HOME}/bin/env.sh not found."
    fi
    #prevent the value of UPGRADE_TMP_FOLDER in env.sh to overwrite the default value/user set value
    UPGRADE_TMP_FOLDER=$UPGRADE_TMP_FOLDER_NEW
    DOCKER_REPOSITORY=${SUITE_REGISTRY}
}

updateModuleVersion(){
    exec_cmd "${CP} -rf ${CURRENT_DIR}/moduleVersion.json ${CDF_HOME}/moduleVersion.json"
}

showWarningMsgAfterUpgrade(){
    if [[ -n ${WARNING_MSG_AFTER_UPGRADE} ]] ; then
        write_log "warn" "${WARNING_MSG_AFTER_UPGRADE}"
    fi
}

getValueInContent(){
    local key="$1"
    local content="$2"
    RESULT=

    RESULT=$(echo "$content" | ${YQ} e $key -)
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to get value of key : $key"
    fi
    write_log "debug" "Get value from content. Key: $key , Value: $RESULT"
}

getValueInYaml(){
    local key="$1"
    local file="$2"
    RESULT=

    RESULT=$(${YQ} e $key $file)
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to get value of key : $key"
    fi
    write_log "debug" "Get value from file $file. Key: $key , Value: $RESULT"
}

updateValueInYaml(){
    local key="$1"
    local value="$2"
    local file="$3"
    local mark='"'
    local re='^[0-9]+$'
    if [[ $value == "true" ]] || [[ $value == "false" ]] || [[ $value =~ $re ]]; then
        #make it empty
        mark=''
    fi
    if rgxMatch ${key} "Key|tls\.key|tls\.crt"; then
        write_log "debug" "${YQ} -i e ${key}=*** $file"
    else
        write_log "debug" "${YQ} -i e ${key}=${mark}${value}${mark} $file"
    fi
    ${YQ} -i e ${key}=${mark}${value}${mark} $file
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to update the key '$key' inside the file $file"
    fi
}

deleteValueInYaml(){
    local key="$1"
    local file="$2"

    write_log "debug" "${YQ} -i e 'del('$key')' $file"
    ${YQ} -i e 'del('$key')' $file
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to delete the key '$key' inside the file $file"
    fi
}

specialSettingsOnValuesYaml(){
    local file="$1"
    if [[ $FROM_INTERNAL_RELEASE -le "202205" ]] ; then
        deleteValueInYaml ".global.database.tlsTruststore" $file
        getValueInYaml ".global.services" $file
        if [[ $RESULT == "null" ]] ; then 
            exec_cmd "${YQ} -i e '.global.services=.tags' $file"
            [[ $? != 0 ]] && write_log "fatal" "Failed to update .global.services in $file."
            deleteValueInYaml ".tags" $file
        fi
        getValueInYaml ".global.persistence.storageClasses.default" $file
        if [[ $RESULT != "null" ]] ; then 
            updateValueInYaml ".global.persistence.storageClasses.default-rwx" "$RESULT" $file
            deleteValueInYaml ".global.persistence.storageClasses.default" $file
        fi
        #Due to OCTCR19S1653905 - apphub-apiserver fails to start after performing an upgrade from 2022.05 to 2022.11
        #Thus, upgrade will force to set tlsEnabled to true for internal pg here
        getValueInYaml ".global.database.internal" $file
        if [[ $RESULT == "true" ]] ; then
            updateValueInYaml ".global.database.tlsEnabled" "true" $file
        fi
    fi
    #Due to OCTCR19S1750048 - suppport upgrade from the env which both suitedb and defaultdb are internal
    if [[ $FROM_INTERNAL_RELEASE -lt "202305" ]] ; then
        # Due to OCTCR19S1748808 - remove cdfapiserver-postgresql pod in bosun upgrade env
        if [[ $SUITE_DEPLOYMENT_MANAGEMENT == "false" ]] ; then
            deleteValueInYaml ".cdfapiserver" $file
            deleteValueInYaml ".cdfapiserverdb" $file
        else
            getValueInYaml ".cdfapiserver.deployment.database.internal" $file
            if [[ $RESULT == "" ]] || [[ $RESULT == "null" ]] ; then 
                getValueInYaml ".global.database.internal" $file
                if [[ $RESULT == "" ]] || [[ $RESULT == "null" ]] ; then
                    write_log "debug" "Both cdfapiserver.database.internal and global.database.internal are invaild in apphub helm yaml"
                else
                    updateValueInYaml ".cdfapiserver.deployment.database.internal" "$RESULT" $file
                fi
            fi
        fi
        # Due to OCTCR19S1762143 - set pgbackup.enabled to true when any one of 'global.database.internal','idm.deployment.database.internal','cdfapiserver.deployment.database.internal' is true
        getValueInYaml ".global.database.internal" $file
        if [[ $RESULT == "" ]] || [[ $RESULT == "null" ]] || [[ $RESULT == "false" ]] ; then
            getValueInYaml ".idm.deployment.database.internal" $file
            if [[ $RESULT == "" ]] || [[ $RESULT == "null" ]] || [[ $RESULT == "false" ]] ; then
                getValueInYaml ".cdfapiserver.deployment.database.internal" $file
                if [[ $RESULT == "true" ]] ; then
                    updateValueInYaml ".pgbackup.enabled" "true" $file
                fi
            else
                updateValueInYaml ".pgbackup.enabled" "true" $file
            fi
        else
            updateValueInYaml ".pgbackup.enabled" "true" $file
        fi

        # OCTCR19S1762219: [Upgrade] Fix vault-int certificate issue which block the SMA installation
        getValueInYaml ".global.vault.realmList" "$file"
        if [[ $RESULT != "" ]] && [[ $RESULT != "null" ]] ; then
            if [[ $CDF_NAMESPACE != "core" ]] ; then
                local tempRealmList=${RESULT//,/ }
                local newRealmList=
                local mark=
                for i in ${tempRealmList} ; do
                    if [[ $i =~ "RIC" ]] ; then
                        continue
                    fi
                    newRealmList="${newRealmList}${mark}${i}"
                    mark=","
                done
                updateValueInYaml ".global.vault.realmList" "$newRealmList" "$file"
            fi
        fi
        # OCTCR19S1766232: [upgrade] deprecate '.global.platformVersion' value in apphub helm values
        getValueInYaml ".global.platformVersion" "$file"
        if [[ $RESULT != "" ]] && [[ $RESULT != "null" ]] ; then
            deleteValueInYaml ".global.platformVersion" $file
        fi
    fi

    if [[ $FROM_INTERNAL_RELEASE -lt "202311" ]] ; then
        #OCTCR19S1936417：set default values for vault realmlist
        getValueInYaml ".global.vault.realmList" "$file"
        if [[ $RESULT == "" ]] || [[ $RESULT == "null" ]] ; then
            #for incremental upgrade env before 202105, set default vault realmlist for core/non-core namespace
            #core, ric,rid,re
            #non-core, rid,re
            if [[ "$CDF_NAMESPACE" == "core" ]]; then
                updateValueInYaml ".global.vault.realmList" "RIC:365,RID:365,RE:365" "$file"
            else
                updateValueInYaml ".global.vault.realmList" "RID:365,RE:365" "$file"
            fi
        fi
    fi
}

cdfChartUpgrade(){
    countRemainingSteps
    write_log "info" "\n** Start to upgrade Apphub chart ... ${STEP_CONT}"

    local releaseName=${CDF_CHART_RELEASE}
    local params=
    local chart=${CURRENT_DIR}/cdf/charts/${CHART_ITOM_APPHUB}
    local file=${UPGRADE_TEMP}/original-values.yaml

    #get original value
    if [[ $CPE_MODE == "true" ]] && [[ $KEEP_VALUES_YAML == "true" ]] ; then
        if [[ ! -f ${file} ]] ; then
            exec_cmd "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > ${file}"
            exec_cmd "chmod 600 ${file}"
        else
            write_log "debug" "Keep the last original-values.yaml in CPE mode."
        fi
    else
        exec_cmd "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > ${file}"
        exec_cmd "chmod 600 ${file}"
    fi

    params="$params -f ${file}"
    
    specialSettingsOnValuesYaml "${file}"

    if [[ -n $CUSTOMIZED_APPHUB_HELM_VALUES ]] ; then
        params="$params -f $CUSTOMIZED_APPHUB_HELM_VALUES"
    fi

    helmChartUpgrade "${releaseName}" "${CDF_NAMESPACE}" "${params}" "${chart}" "45m"
    #backup values.yaml
    if [[ ! -d $UPGRADE_TMP_FOLDER/$BACKUP_DIR ]] ; then
        exec_cmd "mkdir -p $UPGRADE_TMP_FOLDER/$BACKUP_DIR"
    fi
    local date=`date "+%Y%m%d%H%M%S"`
    exec_cmd "${CP} ${file} $UPGRADE_TMP_FOLDER/${BACKUP_DIR}/upgrade-values-$date.yaml"
    write_log "info" "     Apphub chart has been successfully updated."
    updateIngressCertificate
}

checkoutNotReady(){
    local res="$1"
    local op="$2"
    local data=

    data=$(getValueWithRetry "kubectl get $res -n ${CDF_NAMESPACE} $op -o json" "10")
    if [[ $data == "timeout" ]] ; then
        write_log "error" "Failed to run kubectl command."
        return 1
    fi

    local length=$(echo "$data" | ${JQ} -r '.items | length')
    local index=0
    while [[ $index -lt $length ]] ; do
        local tempJson=$(echo "$data" | ${JQ} -r ".items[${index}]")
        resName=$(echo "$tempJson" | ${JQ} -r ".metadata.name")
        if [[ $res == "daemonset" ]] ; then
            desiredNumberScheduled=$(echo "$tempJson" | ${JQ} -r '.status.desiredNumberScheduled?')
            if [[ $desiredNumberScheduled == "" ]] || [[ $desiredNumberScheduled == "null" ]] ; then
                desiredNumberScheduled=0
            fi
            numberReady=$(echo "$tempJson" | ${JQ} -r '.status.numberReady?')
            if [[ $numberReady == "" ]] || [[ $numberReady == "null" ]] ; then
                numberReady=0
            fi
            updatedNumberScheduled=$(echo "$tempJson" | ${JQ} -r '.status.updatedNumberScheduled?')
            if [[ $updatedNumberScheduled == "" ]] || [[ $updatedNumberScheduled == "null" ]] ; then
                updatedNumberScheduled=0
            fi
            checkParameters desiredNumberScheduled
            checkParameters numberReady
            checkParameters updatedNumberScheduled
            if [[ $desiredNumberScheduled == $updatedNumberScheduled ]] && [[ $desiredNumberScheduled == $numberReady ]]; then
                write_log "debug" "$res $resName ready."
            else
                write_log "error" "$res $resName is not ready. DESIRED: $desiredNumberScheduled  READY: $numberReady  UP-TO-DATE: $updatedNumberScheduled"
            fi
        elif [[ $res == "deployment" ]] || [[ $res == "statefulset" ]] ; then
            replicas=$(echo "$tempJson" | ${JQ} -r '.status.replicas?')
            if [[ $replicas == "" ]] || [[ $replicas == "null" ]] ; then
                replicas=0
            fi
            readyReplicas=$(echo "$tempJson" | ${JQ} -r '.status.readyReplicas?')
            if [[ $readyReplicas == "" ]] || [[ $readyReplicas == "null" ]] ; then
                readyReplicas=0
            fi
            updatedReplicas=$(echo "$tempJson" | ${JQ} -r '.status.updatedReplicas?')
            if [[ $updatedReplicas == "" ]] || [[ $updatedReplicas == "null" ]] ; then
                updatedReplicas=0
            fi
            checkParameters replicas
            checkParameters readyReplicas
            checkParameters updatedReplicas
            if [[ $replicas == $readyReplicas ]] && [[ $readyReplicas == $updatedReplicas ]]; then
                write_log "debug" "$res $resName ready."
            else
                write_log "error" "$res $resName is not ready. DESIRED: $replicas  READY: $readyReplicas  UP-TO-DATE: $updatedReplicas"
            fi
        elif [[ $res == "pvc" ]] ; then
            local phase=
            phase=$(echo "$tempJson" | ${JQ} -r '.status.phase?')
            if [[ $phase == "Bound" ]] ; then
                write_log "debug" "$res $resName ready."
            else
                write_log "error" "$res $resName is not ready. DESIRED: Bound  Current: $phase"
            fi
        else
            write_log "fatal" "Internal usage error. Exit!"
        fi
        
        ((index++))
    done
}

checkChartInstalled(){
    local releaseName=$1
    local namespace=$2

    RESULT=
    local data=
    data=$(getValueWithRetry "${HELM} list -n ${namespace} -o json 2>>$LOGFILE" "10")
    if [[ $data == "timeout" ]] ; then
        write_log "fatal" "Failed to get helm list in ${namespace} namespace."
    fi
    local release=
    release=$(echo "$data" | ${JQ} ".[] | select ( .name == \"$releaseName\")")
    if [[ $release == "" ]] || [[ $release == "null" ]]; then
        RESULT=false
    else
        RESULT=true
    fi
}

logHelmResStatus(){
    local namespace=$1
    write_log "info" "******************************************************************************************"
    exec_cmd "${HELM} list -n ${namespace} -a" -p true
    write_log "info" "******************************************************************************************"
}

helmChartUpgrade(){
    local releaseName=$1
    local namespace=$2
    local params=$3
    local chart=$4
    local timeout=${5:-"15m"}

    local exit_code
    write_log "debug" "Excuting helm upgrade command..."
    write_log "debug" "http_proxy : $http_proxy"
    write_log "debug" "https_proxy: $https_proxy"
    write_log "debug" "Helm Command: helm upgrade --install ${releaseName} -n ${namespace} ${params} ${chart} --wait --timeout $timeout"
    local msg=
    startRolling
    exec_cmd "${HELM} upgrade --install ${releaseName} -n ${namespace} ${params} ${chart} --wait --timeout $timeout --debug" -ms -mre "(?i)(Key|tls\.key|tls\.crt)(\"?\s*[:=]\s*)[^',}\s]*"
    exit_code=$?
    stopRolling
    if [[ $exit_code != 0 ]] ; then
        HELM_HISTORY=$(getValueWithRetry "${HELM} history ${releaseName} -n ${namespace} -o json" "180")
        HELM_DESCRIPTION=$(echo "${HELM_HISTORY}" | ${JQ} -r '.[-1].description')
        HELM_STATUS=$(echo "${HELM_HISTORY}" | ${JQ} -r '.[-1].status')
        if [[ $HELM_STATUS == "pending-upgrade" ]] ; then
            logHelmResStatus ${namespace}
            write_log "fatal" "Failed to upgrade $releaseName chart.DESCRIPTION: $HELM_DESCRIPTION\nUnfortunately, you cannot resolve this issue by re-running the upgrade command. Please contact OpenText support for further assistance."
        fi
        if [[ $HELM_DESCRIPTION =~ "etcd" ]] ; then
            write_log "error" "     Retry for known issue. [Error]: $HELM_DESCRIPTION"
            write_log "debug" "     Helm known issue detected. Don't worry, upgrade will handle it..."
            startRolling
            execCmdWithRetry "${HELM} upgrade --install ${releaseName} -n ${namespace} ${params} ${chart} --wait --timeout 5m" "5" "30"
            exit_code=$?
            stopRolling
            if [[ $exit_code != 0 ]] ; then
                logHelmResStatus ${namespace}
                HELM_DESCRIPTION=$(${HELM} history ${releaseName} -n ${namespace} -o json | ${JQ} -r ".[-1].description")
                write_log "fatal" "Oops! Still failed to upgrade ${releaseName} chart. DESCRIPTION: $HELM_DESCRIPTION"
            fi
        else
            logHelmResStatus ${namespace}
            write_log "fatal" "Failed to upgrade $releaseName chart.$HELM_DESCRIPTION"
        fi
    fi
}

kuberegistryChartUpgrade(){
    if [[ $isFirstMaster == "true" ]] ; then
        local releaseName=
        local chart=
        local params=
        local file=
        #notice that some components' release names are not fixed, do not hard code the release name case by case
        releaseName=kube-registry

        #normal process without migration
        checkChartInstalled "$releaseName" "${CDF_NAMESPACE}"
        if [[ $RESULT == "false" ]] ; then
            write_log "info" "Chart $releaseName is not deployed. No need to upgrade."
            return 0
        fi
        
        file="${UPGRADE_TEMP}/${releaseName}-original-values.yaml"
        execCmdWithRetry "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > $file"
        if [[ $? != 0 ]] ; then
            write_log "fatal" "Failed to get $releaseName chart info."
        fi

        params="-f $file"

        local data=
        data=$(getValueWithRetry "kubectl get secret cdf-internal-registry -n ${CDF_NAMESPACE} -o json" "10" "-o=false")
        if [[ $data == "timeout" ]] ; then
            write_log "error" "Failed to run kubectl command."
            return 1
        fi
        local signKey=$(echo "$data" | ${JQ} -r '.data."sign-key"' | base64 -d)

        updateValueInYaml ".credentials.signKey" "${signKey}" $file

        if [[ $MASTER_NODES_NUM -gt 1 ]] ; then
            params="$params --set deployment.replicas=3"
        fi

        chart="${CURRENT_DIR}/k8s/charts/${CHART_ITOM_KUBE_REGISTRY}"

        helmChartUpgrade "$releaseName" "${CDF_NAMESPACE}" "${params}" "${chart}"
    fi
}

logrotateChartUpgrade(){
    if [[ $isFirstMaster == "true" ]] ; then
        local releaseName=
        local chart=
        local params=
        #notice that some components' release names are not fixed, do not hard code the release name case by case
        releaseName=itom-logrotate

        #normal process without migration
        checkChartInstalled "$releaseName" "${CDF_NAMESPACE}"
        if [[ $RESULT == "false" ]] ; then
            write_log "info" "Chart $releaseName is not deployed. No need to upgrade."
            return 0
        fi

        file="${UPGRADE_TEMP}/${releaseName}-original-values.yaml"
        execCmdWithRetry "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > $file"
        if [[ $? != 0 ]] ; then
            write_log "fatal" "Failed to get $releaseName chart info."
        fi

        params="-f $file"
        chart="${CURRENT_DIR}/cdf/charts/${CHART_ITOM_LOG_ROTATE}"

        helmChartUpgrade "$releaseName" "${CDF_NAMESPACE}" "${params}" "${chart}"
    fi
}

crdChartUpgrade(){
    if [[ $MONITORING == "true" ]] ; then
        local releaseName=
        local chart=
        local params=
        #notice that some components' release names are not fixed, do not hard code the release name case by case
        checkHelmalive
        releaseName=$(${HELM} list -n ${CDF_NAMESPACE} -a 2>/dev/null | grep -E 'itom-prometheus-crds-[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $1}' | xargs)
        if [[ -z $releaseName ]] ; then
            releaseName=itom-prometheus-crds
        fi

        chart="${CURRENT_DIR}/cdf/charts/${CHART_ITOM_PROMETHEUS_CRDS}"

        file="${UPGRADE_TEMP}/${releaseName}-original-values.yaml"
        execCmdWithRetry "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > $file"
        if [[ $? != 0 ]] ; then
            getValueInContent ".global.docker.registry" "$ORIGINAL_YAML"
            local registry=${RESULT}
            if [[ $registry != "" ]] && [[ $registry != "null" ]] ; then
                params="$params --set global.docker.registry=$registry"
            fi

            getValueInContent ".global.docker.orgName" "$ORIGINAL_YAML"
            local orgName=${RESULT}
            if [[ $orgName != "" ]] && [[ $orgName != "null" ]] ; then
                params="$params --set global.docker.orgName=$orgName"
            fi

            getValueInContent ".global.securityContext.user" "$ORIGINAL_YAML"
            local user=${RESULT}
            if [[ $user != "" ]] && [[ $user != "null" ]] ; then
                params="$params --set global.securityContext.user=$user"
            fi

            getValueInContent ".global.securityContext.fsGroup" "$ORIGINAL_YAML"
            local fsGroup=${RESULT}
            if [[ $fsGroup != "" ]] && [[ $fsGroup != "null" ]] ; then
                params="$params --set global.securityContext.fsGroup=$fsGroup"
            fi

            getValueInContent ".global.persistence.logVolumeClaim" "$ORIGINAL_YAML"
            local logVolumeClaim=${RESULT}
            if [[ $logVolumeClaim != "" ]] && [[ $logVolumeClaim != "null" ]] ; then
                params="$params --set global.persistence.logVolumeClaim=$logVolumeClaim"
            fi
        else
            params="-f $file"
        fi

        if [[ $FROM_INTERNAL_RELEASE -lt "202405" ]] && [[ $BYOK == "false" ]] ; then
            local labelKey="$(echo "$MASTER_NODELABEL_KEY"|sed 's/\./\\./g')"          
            local labelVal="$(echo "$MASTER_NODELABEL_VAL"|sed 's/\./\\./g')"
            params="$params --set global.cluster.tolerations[0].key=$TAINT_MASTER_KEY"
            params="$params --set global.cluster.tolerations[0].operator=Exists"
            params="$params --set global.cluster.tolerations[0].effect=NoSchedule"
            params="$params --set-string global.nodeSelector.\"$labelKey\"=\"$labelVal\""
        fi

        helmChartUpgrade "$releaseName" "${CDF_NAMESPACE}" "${params}" "${chart}"
    else
        write_log "debug" "No need to upgrade itom-prometheus-crds chart."
    fi
}

k8sAddsOnChartUpgrade(){
    write_log "info" "\n** Start to upgrade K8S add-on charts ..."
    kuberegistryChartUpgrade
    write_log "info" "     K8S add-on charts have been successfully updated."
}

cdfAddsonChartUpgrade(){
    write_log "info" "\n** Start to upgrade Infrastructure add-on charts ..."
    logrotateChartUpgrade
    write_log "info" "     Infrastructure add-on charts have been successfully updated."
}

componentAddsonChartUpgrade(){
    countRemainingSteps
    write_log "info" "\n** Start to upgrade Apphub add-on charts ... ${STEP_CONT}"
    crdChartUpgrade
    sccChartUpgrade
    nfsProvisionerChartUpgrade
    localStorageProvisonerChartUpgrade
    k8sBackupChartUpgrade
    write_log "info" "     Apphub add-on charts have been successfully updated."
}

popWarningMsg(){
    local msg=
    if [[ -n $CUSTOMIZED_APPHUB_HELM_VALUES ]] ; then
        msg="Warning! The values you set by using the --apphub-helm-values option will overwrite the default configurations used during the upgrade. Do not use this option unless you fully understand the consequences of the values you set."
    fi
    if [[ -n $msg ]] ; then
        if [[ "${FORCE_YES}" == "true" ]] ; then
            input="Y"
        else
            write_log "warn" "$msg"
            read -p "Please confirm to continue (Y/N): " input
        fi
        if [ "$input" == "Y" -o "$input" == "y" -o "$input" == "yes" -o "$input" == "Yes" -o "$input" == "YES" ] ; then
            write_log "info" "Upgrade starts in with advanced settings."
        else
            write_log "info" "Quit upgrade." 
            exit 0
        fi
    fi
}

getPodName(){
    local podname=$1
    local name
    name=$(exec_cmd "kubectl get pods -n $CDF_NAMESPACE -o custom-columns=NAME:.metadata.name,STATUS:.status.phase 2>/dev/null | grep -i ' running$' |grep -E '$podname' | head -n1 | awk '{print \$1}'" -p=true)
    echo -n "$name"
}

getHtPasswd(){
    #generate htpasswd for inputing user/passwd
    local podname=$1
    local username=$2
    local passwd=$3
    local htpwd
    htpwd=$(exec_cmd "kubectl exec $podname -n $CDF_NAMESPACE -- htpasswd -nbB $username $passwd 2>/dev/null" -p=true -ms -mre '(nbB\s\S*\s*)\S*' -o=false)
    echo -n "$htpwd"
}

checkBslStatus(){
    #check bsl status is Available
    local reTryTimes=0
    local checkBslSleepTime=6
    while true
    do
        local bslStatus=$(exec_cmd "kubectl get bsl default -n $CDF_NAMESPACE -o json | ${JQ} -r '.status.phase'" -p=true)
        if [[ "$bslStatus" == "Available" ]]; then
            break
        elif [[ $reTryTimes -eq $RETRY_TIMES ]]; then
            write_log "fatal" "The bsl status is $bslStatus; please check cloudserver pod log." "failed"
        else
            write_log "debug" "The bsl status is $bslStatus. Wait for $SLEEP_TIME seconds and retry: $reTryTimes"
        fi
        reTryTimes=$(( $reTryTimes + 1 ))
        sleep $checkBslSleepTime
    done
}

enableK8sBackup(){
    if [[ $isLastMaster == "true" ]] ; then
        local releaseName=itom-velero
        local chart="${CURRENT_DIR}/cdf/charts/${CHART_ITOM_VELERO}"
        local params=
        local file=

        local accessKey='cloudserver'
        local s3Cert='itom-cloudserver'
        if [[ ! -f ${UPGRADE_TEMP}/velero_secretkey ]] ; then
            local secretKey=$(date +%s | sha1sum | cut -c 1-32)
            echo "$secretKey" > ${UPGRADE_TEMP}/velero_secretkey
        else
            local secretKey=$(cat ${UPGRADE_TEMP}/velero_secretkey)
        fi
        if [[ ! -f ${UPGRADE_TEMP}/velero_customerkey ]] ; then
            local customerKey=$(echo $secretKey | sha1sum | cut -c 1-32)
            echo "$customerKey" > ${UPGRADE_TEMP}/velero_customerkey
        else
            local customerKey=$(cat ${UPGRADE_TEMP}/velero_customerkey)
        fi
        
        if [[ ${FROM_INTERNAL_RELEASE} -le "202205" ]]; then
            write_log "info" "     Enabling kubernetes backup ..."

            params="--set global.docker.imagePullSecret=registrypullsecret \
                    --set global.docker.registry=${DOCKER_REPOSITORY} \
                    --set global.docker.orgName=${REGISTRY_ORGNAME} \
                    --set global.securityContext.user=${SYSTEM_USER_ID} \
                    --set global.securityContext.fsGroup=${SYSTEM_GROUP_ID} \
                    --set global.cluster.tolerations[0].key=${TAINT_MASTER_KEY} \
                    --set global.cluster.tolerations[0].operator=Exists \
                    --set global.cluster.tolerations[0].effect=NoSchedule \
                    --set global.nodeSelector.\"node-role\.kubernetes\.io/control-plane\"=\"\" \
                    --set fullnameOverride=velero \
                    --set configuration.provider=aws \
                    --set snapshotsEnabled=false \
                    --set cleanUpCRDs=true \
                    --set upgradeCRDs=true \
                    --set cloudserver.deployment.accessKey=${accessKey} \
                    --set cloudserver.deployment.secretKey=${secretKey} \
                    --set cloudserver.deployment.masterKey=${customerKey} \
                    --set cloudserver.deployment.tls.crt=$(cat $CDF_HOME/ssl/$s3Cert.crt | base64 -w0) \
                    --set cloudserver.deployment.tls.key=$(cat $CDF_HOME/ssl/$s3Cert.key | base64 -w0) \
                    --set cloudserver.deployment.tls.ca=$(cat $CDF_HOME/ssl/ca.crt | base64 -w0) \
                    --set configuration.backupStorageLocation.caCert=$(cat $CDF_HOME/ssl/ca.crt | base64 -w0)"
            helmChartUpgrade "$releaseName" "${CDF_NAMESPACE}" "${params}" "${chart}" "30m"

            local k8s_backup=k8s-backup
            exec_cmd "${CDF_HOME}/bin/velero get schedule ${k8s_backup} -n ${CDF_NAMESPACE}" -p=false
            if [[ $? != 0 ]] ; then 
                exec_cmd "${CDF_HOME}/bin/velero schedule create ${k8s_backup} --schedule=\"0 0 * * *\" --exclude-namespaces='$EXCLUDE_NS'" -p=false
                [[ $? != 0 ]] && write_log "fatal" "Failed to create schedule backup." 
            fi
            checkBslStatus
            
            #create a test backup
            local backupName="installer-test-velero-backup"
            local veleroSleepTime=5
            if velero get backup $backupName >/dev/null 2>&1; then
                exec_cmd "echo 'Y' | ${CDF_HOME}/bin/velero delete backup $backupName"
                sleep $veleroSleepTime
            fi
            exec_cmd "${CDF_HOME}/bin/velero get backup $backupName"
            if [[ $? != 0 ]] ; then 
                exec_cmd "${CDF_HOME}/bin/velero backup create $backupName --exclude-namespaces='$EXCLUDE_NS'"
                if [[ $? != 0 ]]; then
                    write_log "fatal" "Failed to create test backup."
                fi
            fi
            #check backup status, raise error if status is not Completed finally
            local reTryTimes=0
            while true
            do
                local backupJson=$(kubectl get backup $backupName -n $CDF_NAMESPACE -o json 2>/dev/null)
                local backupStatus=$(exec_cmd "echo '$backupJson' | $JQ -r '.status.phase'" -p=true)
                if [ "$backupStatus" = "Completed" ]; then
                    break
                elif [ "$backupStatus" = "Failed" -o "$backupStatus" = "PartiallyFailed" ]; then
                    local reason=$(exec_cmd "echo '$backupJson' | $JQ -r '.status.failureReason'" -p=true)
                    #internal server error, maybe server is not available now, need to retry.
                    if [[ $reason =~ "status code: 500" ]]; then 
                        write_log "debug" "Failed to create backup: $reason. Wait for $veleroSleepTime seconds and retry: $reTryTimes"
                        #delete && create
                        exec_cmd "echo 'Y' | ${CDF_HOME}/bin/velero delete backup $backupName"
                        sleep $veleroSleepTime
                        exec_cmd "${CDF_HOME}/bin/velero backup create $backupName --exclude-namespaces='$EXCLUDE_NS'"
                    else
                        write_log "fatal" "Create backup failed, please make sure you provide the correct backup parameters for installation." "failed"
                    fi
                elif [ $reTryTimes -eq 60 ]; then
                    write_log "fatal" "Failed to create backup: time out."
                else
                    write_log "debug" "Failed to create backup or backup is still in progress. Wait for 5 seconds and retry: $reTryTimes"
                fi
                reTryTimes=$(( $reTryTimes + 1 ))
                sleep $veleroSleepTime
            done
            #delete test backup
            exec_cmd "echo 'Y' | ${CDF_HOME}/bin/velero delete backup ${backupName}"
            if [ $? -ne 0 ]; then
                write_log "warn" "Failed to delete test backup ${backupName}; you can delete it manually later."
            fi
            write_log "info" "     Enable kubernetes backup successfully."
        else
            checkChartInstalled "$releaseName" "${CDF_NAMESPACE}"
            if [[ $RESULT == "false" ]] ; then
                write_log "info" "     Chart $releaseName is not deployed. No need to upgrade."
                return 0
            fi
            write_log "info" "     Updating kubernetes backup component ..."
            file="${UPGRADE_TEMP}/${releaseName}-original-values.yaml"
            execCmdWithRetry "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > $file"
            if [[ $? != 0 ]] ; then
                write_log "fatal" "Failed to get $releaseName chart info."
            fi
            # special yaml settings for replace minio with cloudServer
            getValueInYaml ".cloudserver.deployment.accessKey" $file
            if [[ $RESULT == "" ]] || [[ $RESULT == "null" ]] ; then
                updateValueInYaml ".cloudserver.deployment.accessKey" "${accessKey}" $file
                updateValueInYaml ".cloudserver.deployment.secretKey" "${secretKey}" $file
                updateValueInYaml ".cloudserver.deployment.masterKey" "${customerKey}" $file
                updateValueInYaml ".cloudserver.deployment.tls.crt" "$(cat $CDF_HOME/ssl/$s3Cert.crt | base64 -w0)" $file
                updateValueInYaml ".cloudserver.deployment.tls.key" "$(cat $CDF_HOME/ssl/$s3Cert.key | base64 -w0)" $file
                updateValueInYaml ".cloudserver.deployment.tls.ca" "$(cat $CDF_HOME/ssl/ca.crt | base64 -w0)" $file
                deleteValueInYaml ".minio" $file
            fi
            params="-f $file"
            helmChartUpgrade "$releaseName" "${CDF_NAMESPACE}" "${params}" "${chart}" "30m"
        fi
    fi
}

rgxMatch() {
    local str=$1
    local searchStr=$2
    echo -n $str | grep -E "$searchStr" >> /dev/null 2>&1
    return $?
}

sccChartUpgrade(){
    local releaseName=
    local chart=
    local params=

    releaseName=$(${HELM} list -n ${CDF_NAMESPACE} -a 2>/dev/null | grep -E 'itom-openshift-scc-[0-9]+\.[0-9]+\.[0-9]+*' | awk '{print $1}' | xargs)
    local list=($releaseName)
    [[ ${#list[@]} -gt 1 ]] && write_log "fatal" "Unsupported scenario! More than one scc chart release is found in ${CDF_NAMESPACE} namespace. LIST: $releaseName"
    checkChartInstalled "$releaseName" "${CDF_NAMESPACE}"
    if [[ $RESULT == "false" ]] ; then
        write_log "debug" "Chart $releaseName is not deployed. No need to upgrade."
        return 0
    fi
    chart="${CURRENT_DIR}/cdf/charts/${CHART_ITOM_OPENSHIFT_CC}"
    file="${UPGRADE_TEMP}/${releaseName}-original-values.yaml"
    execCmdWithRetry "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > $file"
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to get $releaseName chart info."
    fi
    params="-f $file --disable-openapi-validation"
    helmChartUpgrade "$releaseName" "${CDF_NAMESPACE}" "${params}" "${chart}"
}

nfsProvisionerChartUpgrade(){
    local releaseName=
    local chart=
    local params=

    releaseName=nfs-provisioner
    checkChartInstalled "$releaseName" "${CDF_NAMESPACE}"
    if [[ $RESULT == "false" ]] ; then
        write_log "debug" "Chart $releaseName is not deployed. No need to upgrade."
        return 0
    fi
    chart="${CURRENT_DIR}/cdf/charts/${CHART_ITOM_NFS_PROVISIONER}"
    file="${UPGRADE_TEMP}/${releaseName}-original-values.yaml"
    execCmdWithRetry "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > $file"
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to get $releaseName chart info."
    fi
    params="-f $file"
    helmChartUpgrade "$releaseName" "${CDF_NAMESPACE}" "${params}" "${chart}"
}

localStorageProvisonerChartUpgrade(){
    local releaseName=
    local chart=
    local params=
    local file=
    #notice that some components' release names are not fixed, do not hard code the release name case by case
    releaseName=$(${HELM} list -n ${CDF_NAMESPACE} -a 2>/dev/null | grep -E 'itom-kubernetes-local-storage-provisioner-[0-9]+\.[0-9]+\.[0-9]\-[0-9]+' | awk '{print $1}' | xargs)
    if [[ -z $releaseName ]] ; then
        write_log "debug" "Chart local-storage-provisoner is not deployed. No need to upgrade."
        return 0
    fi
    
    file="${UPGRADE_TEMP}/${releaseName}-original-values.yaml"
    execCmdWithRetry "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > $file"
    if [[ $? != 0 ]] ; then
        write_log "fatal" "Failed to get $releaseName chart info."
    fi

    params="-f $file"
    chart="${CURRENT_DIR}/cdf/charts/${CHART_ITOM_KUBERNETES_LOCAL_STORAGE_PROVISIONER}"
    helmChartUpgrade "$releaseName" "${CDF_NAMESPACE}" "${params}" "${chart}"
}

k8sBackupChartUpgrade(){
    if [[ ${BYOK} == "true" ]] ; then
        local releaseName=
        local chart=
        local params=

        releaseName=itom-velero
        checkChartInstalled "$releaseName" "${CDF_NAMESPACE}"
        if [[ $RESULT == "false" ]] ; then
            write_log "debug" "Chart $releaseName is not deployed. No need to upgrade."
            return 0
        fi
        chart="${CURRENT_DIR}/cdf/charts/${CHART_ITOM_VELERO}"
        file="${UPGRADE_TEMP}/${releaseName}-original-values.yaml"
        execCmdWithRetry "${HELM} get values ${releaseName} -n ${CDF_NAMESPACE} -o yaml > $file"
        if [[ $? != 0 ]] ; then
            write_log "fatal" "Failed to get $releaseName chart info."
        fi
        params="-f $file --set metrics.enabled=false --set cloudserver.deployment.enabled=false"
        helmChartUpgrade "$releaseName" "${CDF_NAMESPACE}" "${params}" "${chart}" "30m"
    fi
}

updateFapolicy(){
    local files=$1
    local serviceName=fapolicyd
    local serviceStatus=$(exec_cmd "systemctl is-active $serviceName | tr [:upper:] [:lower:]" -p=true)
    if [[ "$serviceStatus" == "active" ]]; then
        write_log "info" "     Update the $serviceName service ..."
        # update fapolicyd.trust file  
        for f in $files ; do
            local result
            result=$(exec_cmd "cat /etc/fapolicyd/fapolicyd.trust | grep $f" -p=true)
            if [[ $result != "" ]] ; then 
                result=$(exec_cmd "fapolicyd-cli -f update $f" -p=true)
            else
                result=$(exec_cmd "fapolicyd-cli -f add $f" -p=true)
            fi
            if [ $? -ne 0 ] ; then
                if [[ "$result" =~ "Cannot open" ]] ; then
                    write_log "fatal" "Failed to update $serviceName: $result"
                fi
            fi
        done
        exec_cmd "fapolicyd-cli --update"
        # restart fapolicyd service
        exec_cmd "systemctl restart $serviceName"
        if [ $? -ne 0 ]; then
            write_log "fatal" "Failed to update the $serviceName service."
        fi
    fi
}

switchHelmRepo(){
    if [[ $FROM_INTERNAL_RELEASE -ge "202305" ]] ; then
        write_log "debug" "No need to execute ${FUNCNAME[0]}"
        return 0
    fi

    local repoName=cdfinternal
    local helmRepo=
    helmRepo=$(exec_cmd "${HELM} repo list 2>/dev/null | grep ${repoName} | awk '{print \$1}'" -p=true)
    if [[ $helmRepo == ${repoName} ]] ; then
        write_log "info" "     Switching chart repository ..."
        local repoConfigYaml="$HOME/.config/helm/repositories.yaml"
        local helmRepoUrl
        helmRepoUrl=$(exec_cmd "${HELM} repo list 2>/dev/null | grep ${repoName} | awk '{print \$2}'" -p=true)
        helmRepoUrl=$(exec_cmd "echo ${helmRepoUrl} | sed -e 's@suiteInstaller@apphub-apiserver@g'" -p=true) 
        exec_cmd "${YQ} -i e '.repositories[select(.name==\"${repoName}\")].url=\"${helmRepoUrl}\"'  $repoConfigYaml"        
        [[ $? != 0 ]] && write_log "fatal" "Failed to update chart repository"
    fi
}

addDNSForNewNodes(){
    if [[ $FROM_INTERNAL_RELEASE -ge "202305" ]] ; then
        write_log "debug" "No need to execute ${FUNCNAME[0]}"
        return 0
    fi

    if [[ $isFirstMaster == "true" ]] ; then
        local nodeDNS=
        for node in ${ALL_NODES} ; do
            if [[ $node == $THIS_NODE ]] ; then
                nodeDNS=$(exec_cmd "cat ${CDF_HOME}/cfg/kubelet-config | ${YQ} e '.clusterDNS[]' -" -p=true) 
            else
                local configFile="${UPGRADE_TEMP}/${node}-proxy-config.json"
                execCmdWithRetry "kubectl get --raw /api/v1/nodes/${node}/proxy/configz > $configFile" "" "3"
                [[ $? != 0 ]] && write_log "fatal" "Failed to get proxy config of node:${node}."
                nodeDNS=$(exec_cmd "cat $configFile| ${JQ} .kubeletconfig.clusterDNS[] | sed 's/\"//g'" -p=true)
            fi
            
            if [[ $nodeDNS != $DNS_SVC_IP ]] ; then
                # add DNS service for each inconsistent node
                local compatibleDNSSvc=$(exec_cmd "kubectl get svc -A | grep $nodeDNS" -p=true)
                [[ $compatibleDNSSvc != "" ]] && write_log "fatal" "Compatible DNS service IP for new-added node is already allocated, please refer to the Troubleshooting Guide for help on how to resolve this error."
                local svcName=$(exec_cmd "echo kube-dns-$nodeDNS | sed 's@\.@-@g'" -p=true)
                local yamlFile="${UPGRADE_TEMP}/${svcName}.yaml"
                execCmdWithRetry "kubectl get svc kube-dns -n ${KUBE_SYSTEM_NAMESPACE} -o yaml > $yamlFile"
                updateValueInYaml ".metadata.name" "${svcName}" $yamlFile
                updateValueInYaml ".spec.clusterIP" "${nodeDNS}" $yamlFile
                updateValueInYaml ".spec.clusterIPs[]" "${nodeDNS}" $yamlFile
                execCmdWithRetry "kubectl apply -f $yamlFile" "" "3"
                [[ $? != 0 ]] && write_log "fatal" "Failed to create DNS services for new-added."
            fi
        done
    fi

    # if DNS_IP in kubelet-config is not the same as $DNS_SVC_IP, update it
    local kubeletConfigDNSIP=$(exec_cmd "cat ${CDF_HOME}/cfg/kubelet-config | ${YQ} e '.clusterDNS[]' -" -p=true) 
    if [[ $kubeletConfigDNSIP != $DNS_SVC_IP ]] ; then
        updateValueInYaml ".clusterDNS[]" "${DNS_SVC_IP}" ${CDF_HOME}/cfg/kubelet-config
        restartSystemdSvc "kubelet"
    fi
}

removeRedundantSvc(){
    if [[ $FROM_INTERNAL_RELEASE -ge "202305" ]] ; then
        write_log "debug" "No need to execute ${FUNCNAME[0]}"
        return 0
    fi

    if  [[ $IS_LAST_NODE == "true" ]] ; then
        local services=
        services=$(exec_cmd "kubectl get svc -n ${KUBE_SYSTEM_NAMESPACE} | grep -Eo '(kube-dns-[0-9-]*)' | xargs" -p=true)
        for svc in ${services} ; do
            exec_cmd "kubectl delete svc $svc -n ${KUBE_SYSTEM_NAMESPACE}"
            [[ $? != 0 ]] && write_log "fatal" "Failed to delete redundant DNS services."
        done
    fi
}

# Fix issue about Endpoint & EndpointSlice permissions allow cross-Namespace
removeEndpointPermission() {
    if [[ $FROM_INTERNAL_RELEASE -ge "202305" ]] ; then
        write_log "debug" "No need to execute ${FUNCNAME[0]}"
        return 0
    fi

    if [[ $BYOK == "false" ]] && [[ "${isFirstMaster}" == "true" ]]; then
        # Set rbac.authorization.kubernetes.io/autoupdate to true and keep it
        exec_cmd "kubectl annotate --overwrite clusterrole/system:aggregate-to-edit rbac.authorization.kubernetes.io/autoupdate=true"
        exec_cmd "kubectl get clusterroles system:aggregate-to-edit -o yaml > ${UPGRADE_TEMP}/aggregate_to_edit_no_endpoints.yaml"
        exec_cmd "grep endpoints ${UPGRADE_TEMP}/aggregate_to_edit_no_endpoints.yaml"
        if [[ $? == 0 ]]; then
            exec_cmd "sed -i '/endpoints/d' ${UPGRADE_TEMP}/aggregate_to_edit_no_endpoints.yaml"
            exec_cmd "sed -i '/endpointslices/d' ${UPGRADE_TEMP}/aggregate_to_edit_no_endpoints.yaml"
            # Restricting write access to Endpoints and EndpointSlices by updating the system:aggregate-to-edit role
            exec_cmd "kubectl auth reconcile --remove-extra-permissions -f ${UPGRADE_TEMP}/aggregate_to_edit_no_endpoints.yaml"
        fi
    fi
}

verifyCommand(){
    if [[ ${#NOTFOUND_COMMANDS[@]} != 0 ]] ; then
        write_log "warn" "! Warning: The '${NOTFOUND_COMMANDS[*]}' commands are not in the /bin or /usr/bin directory, the script will use variable in the current user's system environment."
        if [[ "${FORCE_YES}" == "true" ]] ; then
            confirm="Y"
        else
            read -p "Are you sure to continue(Y/N)?" confirm
        fi
        if [ "$confirm" != 'y' -a "$confirm" != 'Y' ]; then
            exit 1
        fi
    fi
}

verifySemver(){
    local version=$1
    #regex format:  v1.7.1/1.7.1
    if [[ $version =~ ^(v[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        return 0
    fi
    return 1
}

getPatchUpgradeFlag(){
    local fromVersion=$1
    local targetVersion=$2

    COMPONENT_PATCH_UPGRADE=false
    verifySemver $fromVersion
    if [[ $? != 0 ]] ; then
        write_log "debug" "The fromVersion is not following SemVer rules: $fromVersion"
        return
    fi

    verifySemver $targetVersion
    if [[ $? != 0 ]] ; then
        write_log "debug" "The targetVersion is not following SemVer rules: $targetVersion"
        return
    fi

    local majorFrm=$(echo "${fromVersion#v}" | awk -F '.' '{print $1}')
    local minorFrm=$(echo "$fromVersion" | awk -F '.' '{print $2}')
    local patchFrm=$(echo "$fromVersion" | awk -F '.' '{print $3}')

    local majorTgt=$(echo "${targetVersion#v}" | awk -F '.' '{print $1}')
    local minorTgt=$(echo "$targetVersion" | awk -F '.' '{print $2}')
    local patchTgt=$(echo "$targetVersion" | awk -F '.' '{print $3}')
    write_log "debug" "fromVersion: $fromVersion, majorFrm: $majorFrm, minorFrm: $minorFrm, patchFrm: $patchFrm"
    write_log "debug" "targetVersion: $targetVersion, majorTgt: $majorTgt, minorTgt: $minorTgt, patchTgt: $patchTgt"

    if [[ $majorFrm -eq $majorTgt ]] && [[ $minorFrm -eq $minorTgt ]] && [[ $patchFrm -le $patchTgt ]] ; then
        COMPONENT_PATCH_UPGRADE=true
    fi
}

checkSupportVersion(){
    local supportVersionList="$1"
    local currrentVersion="$2"
    if [[ $currrentVersion == "" ]] || [[ $currrentVersion == "null" ]] ; then
        return 0
    fi
    for supportVer in $supportVersionList ; do
        exec_cmd "echo $currrentVersion | grep '$supportVer'"
        if [[ $? == 0 ]] ; then
            return 0
        fi
    done
    return 1
}

getVersionInfo(){
    ##-i session##
    if [[ "$UPGRADE_INFRA" == "true" ]]; then
        local versionFile=$CDF_HOME/version.txt
        local internalVersionFile=$CDF_HOME/version_internal.txt

        # check if versionfile exist
        [[ ! -f $internalVersionFile ]] && [[ ! -f $versionFile ]] && write_log "fatal" "Failed to find version related files under $CDF_HOME"

        # if no version_internal.txt, it means it upgraded from old versions which don't have this file.
        if [[ ! -f $internalVersionFile ]]; then
            internalVersionFile=$versionFile
        fi

        FROM_VERSION=$(cat $versionFile)
        FROM_INTERNAL_VERSION=$(cat $internalVersionFile)

    ##-u session##
    elif [[ "$UPGRADE_CDF" == "true" ]] && [[ $TOOLS_ONLY == "false" ]]; then
        #not tools-only env
        checkHelmalive
        getResource "cm" "cdf-upgrade-in-process" "${CDF_NAMESPACE}" "."
        if [[ $? == 0 ]] ; then
            write_log "info" "This is re-run of upgrade."
            getResource "cm" "cdf-upgrade-in-process" "${CDF_NAMESPACE}" ".data.FROM_PLATFORM_VERSION"
            [[ $? != 0 ]] && write_log "fatal" "Failed to get FROM_PLATFORM_VERSION in cdf-upgrade-in-process configmap."
            FROM_VERSION="$RESULT"
            getResource "cm" "cdf-upgrade-in-process" "${CDF_NAMESPACE}" ".data.FROM_INTERNAL_PLATFORM_VERSION"
            [[ $? != 0 ]] && write_log "fatal" "Failed to get FROM_INTERNAL_PLATFORM_VERSION in cdf-upgrade-in-process configmap."
            FROM_INTERNAL_VERSION="$RESULT"
        else
            getResource "cm" "cdf" "${CDF_NAMESPACE}" ".data.PLATFORM_VERSION"
            if [[ $? == 0 ]] ; then
                FROM_VERSION="$RESULT"
                FROM_INTERNAL_VERSION="$FROM_VERSION"
                getResource "cm" "cdf" "${CDF_NAMESPACE}" ".data.INTERNAL_VERSION"
                if [[ $? == 0 ]] ; then
                    FROM_INTERNAL_VERSION="$RESULT"
                fi
            else
                #check if Apphub chart is deployed, regex format: apphub-1.18.0+20210500
                exec_cmd "${HELM} list -n ${CDF_NAMESPACE} | grep -E 'apphub-[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+'"
                if [[ $? == 0 ]] ; then
                    write_log "fatal" "Failed to get both PLATFORM_VERSION in cdf configmap."
                else
                    write_log "info" "No Apphub chart detected. No need to run 'upgrade.sh -u'."
                    exit 0
                fi
            fi
        fi
    elif [[ "$UPGRADE_CDF" == "true" ]] && [[ $TOOLS_ONLY == "true" ]]; then
        #tools-only env 
        #version realted codes are same as those in -i session, but keep them seperated and decoupled
        local versionFile=$CDF_HOME/version.txt
        local internalVersionFile=$CDF_HOME/version_internal.txt

        # check if versionfile exist
        [[ ! -f $internalVersionFile ]] && [[ ! -f $versionFile ]] && write_log "fatal" "Failed to find version related files under $CDF_HOME"

        # if no version_internal.txt, it means it upgraded from old versions which don't have this file.
        if [[ ! -f $internalVersionFile ]]; then
            internalVersionFile=$versionFile
        fi

        FROM_VERSION=$(cat $versionFile)
        FROM_INTERNAL_VERSION=$(cat $internalVersionFile)
    fi
    
    if [[ "$FROM_INTERNAL_VERSION" =~ "-" ]] ; then
        FROM_INTERNAL_RELEASE=$(echo "$FROM_INTERNAL_VERSION" | awk -F- '{print $1}' | awk -F. '{print $1$2}')
        FROM_BUILD_NUM=$(echo "$FROM_INTERNAL_VERSION" | awk -F- '{print $2}')
    else
        FROM_INTERNAL_RELEASE=$(echo "$FROM_INTERNAL_VERSION" | awk -F. '{print $1$2}')
        FROM_BUILD_NUM=$(echo "$FROM_INTERNAL_VERSION" | awk -F. '{print $3}')
    fi

    #2023.11-001
    checkParameters FROM_INTERNAL_VERSION
    #202311
    checkParameters FROM_INTERNAL_RELEASE
    #001
    checkParameters FROM_BUILD_NUM

}

### Main ###
CURRENT_PID=$$

if [[ -f /etc/profile.d/itom-cdf.sh ]] ; then
    source /etc/profile.d/itom-cdf.sh 2>/dev/null || source /etc/profile
else
    source $HOME/itom-cdf.sh 2>/dev/null
fi

checkIfBYOK
checkCDFEnv

source ${CHART_PROPERTIES}
[[ $? != 0 ]] && echo "Failed to read $CHART_PROPERTIES. Please check your user permssion and verify the integrity of the upgrade package." && exit 1
source ${IMAGE_PROPERTIES}
[[ $? != 0 ]] && echo "Failed to read $IMAGE_PROPERTIES. Please check your user permssion and verify the integrity of the upgrade package." && exit 1
#INSTALL_MODE : CLASSIC/BYOK
if [[ "$BYOK" == "true" ]] ; then
    INSTALL_MODE="BYOK"
else
    source ${K8S_IMAGE_PROPERTIES}
    source ${K8S_CHART_PROPERTIES}
    INSTALL_MODE="CLASSIC"
fi
YAMLPATH=${CURRENT_DIR}/cdf/objectdefs
if [[ ! -d ${CDF_HOME}/log/upgrade ]] ; then
    mkdir -p ${CDF_HOME}/log/upgrade
fi
LOGFILE=${CDF_HOME}/log/upgrade/upgrade-`date "+%Y%m%d%H%M%S"`.log

write_log "debug" "INSTALL_MODE: $INSTALL_MODE"
write_log "debug" "CURRENT_DIR: $CURRENT_DIR"
write_log "debug" "User input command: $0 $*"
COMMAND_RECORD="$0 $*"

if [[ -f "$HOME/.upgrade-lock" ]] ; then
    write_log "error" "Error: one instance is already running and only one instance is allowed on this node at a time. "
    write_log "error" "Check to see if another instance is running."
    write_log "fatal" "If the instance stops running, delete $HOME/.upgrade-lock file."
else
    echo "$$" > $HOME/.upgrade-lock
fi

UPGRADE_TMP_FOLDER="${CDF_HOME}/backup"
readonly DEFAULT_CDFDATA_HOME="${CDF_HOME}/data"
readonly UPGRADE_DATA="${DEFAULT_CDFDATA_HOME}/.upgrade"

while [ $# -gt 0 ];do
    case "$1" in
    -i|--infra) UPGRADE_INFRA=true
        shift;;
    -u|--upgrade) UPGRADE_CDF=true
        shift;;
    --drain) DRAIN=true
        shift;;
    --drain-timeout)
        case "$2" in
          -*) echo "--drain-timeout option requires a value." ; exit 1 ;;
          *)  if [[ -z "$2" ]] ; then echo "--drain-timeout option requires a length of time.(second)" ; exit 1 ; fi ; DRAIN_TIMEOUT=$2 ; shift 2 ;;
        esac ;;
    -c|--clean) CLEAN=true
        shift;;
    -y|--yes) FORCE_YES=true
        shift;;
    -t|--temp)
        case "$2" in
          -*) echo "-t|--temp option requires a value." ; exit 1 ;;
          *)  if [[ -z "$2" ]] ; then echo "-t|--temp option needs to provide an absolute path. " ; exit 1 ; fi ; UPGRADE_TMP_FOLDER=$2 ; shift 2 ;;
        esac ;;
    --apphub-helm-values) 
        case "$2" in
          -*) echo "--apphub-helm-values option requires a value." ; exit 1 ;;
          *)  
            [[ -z "$2" ]] && echo "--apphub-helm-values option needs to provide customized yaml file path." && exit 1;  
            [[ ! -f "$2" ]] && echo "$2 is not a file. Please correct your usage and try again." && exit 1;
            CUSTOMIZED_APPHUB_HELM_VALUES=$2 ; shift 2 ;;
        esac ;;
    -dev|--developerMode) DEVELOPOR_MODE=true
        shift;;
    -sio|--skipImageOperation) SKIP_IMAGE_OPERATION=true
        shift;;
    -cpe|--cpeMode) CPE_MODE=true
        shift;;
    #cpe mode option
    -kvy|--keepValuesYaml) KEEP_VALUES_YAML=true
        shift;;
    -h|--help)
        usage;;
    *) 
        echo -e "The input parameter $1 is not a supported parameter or not used in a correct way. Please refer to the following usage.\n"
        usage;;
    esac
done
verifyCommand

# if path ends with /, remove it
if [[ "$UPGRADE_TMP_FOLDER" == "/" ]]; then
    write_log "fatal" "Please don't use '/' for -t/--temp option."
fi
if [[ "${UPGRADE_TMP_FOLDER:$((${#UPGRADE_TMP_FOLDER}-1)):1}" == / ]] ; then
    UPGRADE_TMP_FOLDER=${UPGRADE_TMP_FOLDER:0:$((${#UPGRADE_TMP_FOLDER}-1))}
fi
#validate UPGRADE_TMP_FOLDER
if [[ "$UPGRADE_TMP_FOLDER" != /* ]]; then
    write_log "fatal" "Please provide an absolute path with -t/--temp option."
fi
if [[ ! -d $UPGRADE_TMP_FOLDER ]] ; then
    mkdir -p $UPGRADE_TMP_FOLDER || write_log "fatal" "Failed to create directory $UPGRADE_TMP_FOLDER. Please check whether the folder path is correct and whether the current user has permission to create this folder."
fi
touch $UPGRADE_TMP_FOLDER/test || write_log "fatal" "Failed to create files under $UPGRADE_TMP_FOLDER. Please check whether you have write permission under this folder."
${RM} -rf $UPGRADE_TMP_FOLDER/test

if [[ $DEVELOPOR_MODE == "true" ]] ; then
    write_log "warn" "******************************************************************************************************************"
    write_log "warn" "** Warning: Developer mode is ACTIVATED. If you are not a relevant developer or QA, please quit at this moment. **"
    write_log "warn" "******************************************************************************************************************"
    read -p "Please confirm to continue?(Y/N)" stdin
    if [[ $stdin == "Y" ]] || [[ $stdin == "y" ]] ; then
        write_log "info" "Upgrade starts in developer mode."
    else
        write_log "info" "Quit upgrade." 
        exit 0
    fi
fi

if [[ $CPE_MODE == "true" ]] ; then
    write_log "warn" "*************************************************************************************************************"
    write_log "warn" "** Warning: CPE_MODE mode is ACTIVATED. If you are not a relevant CPE expert, please quit at this moment. **"
    write_log "warn" "*************************************************************************************************************"
    read -p "Please confirm to continue?(Y/N)" stdin
    if [[ $stdin == "Y" ]] || [[ $stdin == "y" ]] ; then
        write_log "info" "Upgrade starts in CPE mode."
    else
        write_log "info" "Quit upgrade." 
        exit 0
    fi
fi

#BYOK doesn't need to upgrade infrastructures
if [[ ${BYOK} != "true" ]] ; then
    getCDFEnv
    #distinguish master node (true) or worker node (false)
    IS_MASTER=$(isMasterNode)
    write_log "debug" "IS_MASTER: $IS_MASTER"
    #prepare etcd cacert cert key for connecting etcd
    ETCD_SSL_CONN_PARAM=" --cacert ${CDF_HOME}/ssl/ca.crt --cert ${CDF_HOME}/ssl/common-etcd-client.crt --key ${CDF_HOME}/ssl/common-etcd-client.key "
    ETCD_SSL_CONN_PARAM_V2=" --ca-file ${CDF_HOME}/ssl/ca.crt --cert-file ${CDF_HOME}/ssl/common-etcd-client.crt --key-file ${CDF_HOME}/ssl/common-etcd-client.key "
fi

# -i session
if [ "$UPGRADE_INFRA" == "true" -a -z "$UPGRADE_CDF" -a -z "$CLEAN" ];then
    if [[ ${BYOK} == "true" ]] ; then
        write_log "fatal" "Sorry, you can't execute upgrade.sh -i on BYOK environment."
    fi
    write_log "warn" "
***********************************************************************************
   WARNING: This step is used to upgrade Infrastructure to build ${TARGET_VERSION}. 
            The upgrade process is irreversible. You can NOT roll back.
            Make sure that all nodes in your cluster are in Ready status.
            Make sure that all Pods and Services are Running.

***********************************************************************************"
    if [[ "${FORCE_YES}" == "true" ]] ; then
        input="Y"
    else
        read -p "Please confirm to continue (Y/N): " input
    fi
    if [ "$input" == "Y" -o "$input" == "y" -o "$input" == "yes" -o "$input" == "Yes" -o "$input" == "YES" ] ; then
        #initialize global values
        initGlobalValues

        #precheck before upgrade
        preCheck    

        # i session lock, -i need to upgrade one node by one node
        #if re-run, kubectl maynot work, read the token file
        if [[ -f ${UPGRADE_TEMP}/iprocesstoken ]] ; then
            write_log "debug" "This time is re-run, this node is still in -i session."
        #lock not found, go head to execute -i
        elif [[ $(exec_cmd "kubectl get cm ilock -n ${CDF_NAMESPACE}"; echo $?) -ne 0 ]] ; then
            #Usage: createResource <Resource> <ResourceName> <Namespace> <ExtraOptions> <totalReTryTimes>
            createResource "cm" "ilock" "${CDF_NAMESPACE}" "--from-literal=inode=${THIS_NODE}"
            exec_cmd "touch ${UPGRADE_TEMP}/iprocesstoken"
            write_log "debug" "THIS_NODE: ${THIS_NODE}"
            echo "${THIS_NODE}" > ${UPGRADE_TEMP}/iprocesstoken
        #if lock existed, check whether this node is not the lock owner
        elif [[ $(exec_cmd "kubectl get cm ilock -n ${CDF_NAMESPACE} -o json|${JQ} -r .data.inode" -p=true) == "${THIS_NODE}" ]] ; then
            write_log "debug" "This time may be re-run."
        else
            infraNode=$(exec_cmd "kubectl get cm ilock -n ${CDF_NAMESPACE} -o json|${JQ} -r .data.inode" -p=true)
            write_log "fatal" "\nWarning! Node \"${infraNode}\" upgrade.sh -i is not finished, please run this command on node ${infraNode} first."
        fi

        #only do on first master
        generateParFile
        loadParameters
        calculateParameters

        preUpgrade

        countRemainingSteps
        write_log "info" "\n** Upgrade Cni components ... ${STEP_CONT}"
        if [[ $CURRENT_CNI_VERSION == $TARGET_CNI_VERSION ]] ; then
            write_log "info" "     CNI version didn't change. No need to upgrade cni components."
        elif checkSupportVersion "$SUPPORT_CNI_VERSION" "$CURRENT_CNI_VERSION" ; then
            write_log "debug" "     CNI version changed. Start to upgrade cni..."
            updateCniPlugin
        else
            write_log "fatal" "     CNI version not in supported list."
        fi

        #-i containerd
        countRemainingSteps
        write_log "info" "\n** Upgrade Containerd components ... ${STEP_CONT}"
        if [[ $CURRENT_CONTAINERD_VERSION == $TARGET_CONTAINERD_VERSION ]] ; then
            write_log "info" "     Containerd version didn't change. No need to upgrade containerd components."
        elif checkSupportVersion "$SUPPORT_CONTAINERD_VERSION" "$CURRENT_CONTAINERD_VERSION" ; then
            write_log "debug" "     Containerd version changed. Start to upgrade containerd..."
            updateContainerdService
        else
            write_log "fatal" "     Containerd version not in supported list."
        fi

        #-i --k8s
        countRemainingSteps
        write_log "info" "\n** Upgrade K8S components ... ${STEP_CONT}"
        if checkSupportVersion "$SUPPORT_K8S_VERSION" "$CURRENT_K8S_VERSION" ; then
            updateImagePkg "infra"
            pushImagePkg "infra"
            #upgrade the k8s components
            upgrade
            k8sAddsOnChartUpgrade
            updateAddNodeConfigmap
        elif [[ $CURRENT_K8S_VERSION == $TARGET_K8S_VERSION ]] ; then
            write_log "info" "     K8S version didn't change. No need to update related files."
        else
            write_log "fatal" "     Unsupported K8S verison."
        fi

        #-i --apphub
        countRemainingSteps
        write_log "info" "\n** Upgrade Infrastructure components ... ${STEP_CONT}"
        if checkSupportVersion "$SUPPORT_CDF_VERSION" "$CURRENT_CDF_VERSION" ; then
            updateImagePkg "apphub"
            pushImagePkg "apphub"
            cdfAddsonChartUpgrade
            configureNodeManagerRBAC
        elif [[ $CURRENT_CDF_VERSION == $TARGET_CDF_VERSION ]] ; then
            write_log "info" "     Infrastructure version didn't change. No need to update related files."
        else
            write_log "fatal" "     Unsupported infrastructure verison."
        fi

        enableK8sBackup 
        packInstallerZip
        copyZipFilesToNfs

        updateModuleVersion
        
        postUpgrade
        setInfraVersion
        write_log "debug" "IS_LAST_NODE: ${IS_LAST_NODE}"
        if [[ "${IS_LAST_NODE}" == "true" ]] ; then
            cleanUpgradeConfigmap
        fi
 
        cleanUpgradeTempFolder
        ${CP} -f ${CURRENT_DIR}/version.txt ${CDF_HOME}/.
        ${CP} -f ${CURRENT_DIR}/version_internal.txt ${CDF_HOME}/.
        exec_cmd "kubectl delete cm ilock -n ${CDF_NAMESPACE}"
        exec_cmd "${RM} -f ${UPGRADE_TEMP}/iprocesstoken"
        write_log "info" "\n** Successfully completed Infrastructure upgrade on this node."

        showUpgradeSteps
    fi
# -u session
elif [ "$UPGRADE_CDF" == "true" -a -z "$UPGRADE_INFRA" -a -z "$CLEAN" ];then
    write_log "warn" "
***********************************************************************************
   WARNING: This step is used to upgrade AppHub components to build ${TARGET_VERSION}. 
            The upgrade process is irreversible. You can NOT roll back.
            Make sure that all nodes in your cluster are in Ready status.
            Make sure that all Pods and Services are Running.

***********************************************************************************"
    if [[ "${FORCE_YES}" == "true" ]] ; then
        input="Y"
    else
        read -p "Please confirm to continue (Y/N): " input
    fi
    if [ "$input" == "Y" -o "$input" == "y" -o "$input" == "yes" -o "$input" == "Yes" -o "$input" == "YES" ] ; then
        write_log "debug" "User confirmed the prompt. Continue to upgrade."
    else
        write_log "info" "Quit AppHub components upgrade."
        exit 0
    fi
    popWarningMsg
    #initialize global values
    initGlobalValues

    componentsPreCheck
    #only upgrade tools
    upgradeTools
    countRemainingSteps
    write_log "info" "\n** Prerequisite tasks for Apphub components upgrade... ${STEP_CONT}"
    createUpgradeInProcessMark
    if [[ ${BYOK} != "true" ]] ; then
        getCDFEnv
    else
        setBYOKENV
        copyBYOKBin
    fi
    updateRBAC
    updateYamlTemplateConfigmap
    componentSpecialSettings
    componentAddsonChartUpgrade
    cdfChartUpgrade

    countRemainingSteps
    write_log "info" "\n** Post tasks for Apphub components upgrade... ${STEP_CONT}"
    cleanUpgradeConfigmap
    cleanUpgradeTempFolder
    write_log "info" "     Successfully completed AppHub components upgrade process."
    showWarningMsgAfterUpgrade
    exit 0
else
    usage
fi
