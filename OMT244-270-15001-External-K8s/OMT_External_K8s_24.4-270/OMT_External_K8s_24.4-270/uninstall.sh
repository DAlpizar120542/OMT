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

#Const
export PRODUCT_SHORT_NAME="OMT"
export PRODUCT_INFRA_NAME="Infrastructure"
export PRODUCT_APP_NAME="Apphub"

CURRENTDIR=$(cd "$(dirname "$0")";pwd)
CURRENT_PID=$$

#function for write log
write_log() {
    level=$1
    msg=$2
    case $level in
        info)
            echo "[INFO] `date "+%Y-%m-%d %H:%M:%S"` : $msg  "
            echo "[INFO] `date "+%Y-%m-%d %H:%M:%S"` : $msg" >> $LOG
            ;;
        trace)
            echo "[TRACE] `date "+%Y-%m-%d %H:%M:%S"` : $msg" >> $LOG
            ;;
        warn)
            echo "[WARN] `date "+%Y-%m-%d %H:%M:%S"` : $msg  "
            echo "[WARN] `date "+%Y-%m-%d %H:%M:%S"` : $msg" >> $LOG
            ;;
        error)
            echo -e "\n[ERROR] `date "+%Y-%m-%d %H:%M:%S"` : $msg  "
            echo "[ERROR] `date "+%Y-%m-%d %H:%M:%S"` : $msg" >> $LOG
            ;;
        fatal)
            echo "[FATAL] `date "+%Y-%m-%d %H:%M:%S"` : $msg  "
            echo "[FATAL] `date "+%Y-%m-%d %H:%M:%S"` : $msg" >> $LOG
            exit 1 ;;
    esac
}

trust_cmd(){
    local cmd="$1"
    local msg="$2"
    local exit_code=
    [[ -n "$msg" ]] && write_log "trace" "Start: $msg ..."
    for (( i=0; i<10; i++));do
        echo "trust_cmd: $cmd" >> $LOG
        $cmd 2>>$LOG
        exit_code=$?
        echo "exit_code: $exit_code" >> $LOG
        if [[ "$exit_code" == "0" ]];then
            [[ -n "$msg" ]] && write_log "trace" "End: $msg ... [ok]"
            return 0
        fi
        sleep 1
    done
    [[ -n "$msg" ]] && write_log "trace" "Failed: $msg ..."
    kill -s SIGTERM $CURRENT_PID
    exit 1
}

TIMEOUT_SECONDS=15
   
if [[ -x "/usr/bin/rm" ]] ; then
    RM="/usr/bin/rm"
elif [[ -x "/bin/rm" ]] ; then
    RM="/bin/rm"
else
    cmd=$(which rm 2>/dev/null | xargs -n1 | grep '^/')
    if [[ -n "$cmd" ]] && [[ -x "$cmd" ]] ; then
        RM="$cmd"
    else
        RM="rm"
    fi
fi   
UNINSTALL_TMP=${TMP_FOLDER:-"/tmp"}/.uninstall.tmp

if [ -f $HOME/itom-cdf.sh ];then
    source $HOME/itom-cdf.sh
fi
if [ -f $UNINSTALL_TMP ];then
    source $UNINSTALL_TMP
fi

TMP_FOLDER="${TMP_FOLDER:-"/tmp"}"
LOG="$TMP_FOLDER/uninstall.cdf.$(date "+%Y%m%d%H%M%S").log"

cleanCaches(){
    write_log "trace" "cleanCaches ..."
    if [[ -d "$TMP_FOLDER" ]];then
        $RM -rf $TMP_FOLDER/.cdf*
        write_log "trace" "remove all temp cdf file"
        # remove tmp log symbolic links for install
        for tmp_log in $(find $TMP_FOLDER -maxdepth 1 -name install.*.log|xargs);do
            if grep -P '##FLAG_CDF_LOG_OWER:' "$tmp_log" -q 2>>$LOG;then
                $RM -f $tmp_log
            fi
            if [[ -L "$tmp_log" ]] && [[ ! -f "$tmp_log" ]];then
                $RM -f $tmp_log
            fi
        done
    fi
    [ -d "$HOME/.cdf" ] && $RM -rf "$HOME/.cdf"

    [[ -d "$CDF_HOME" ]] && $RM -rf $CDF_HOME
    if [[ -f $HOME/itom-cdf.sh ]];then
        $RM -f $HOME/itom-cdf.sh
    fi
    local profile=
    [[ -f "$HOME/.bash_profile" ]] && profile="$HOME/.bash_profile" || profile="$HOME/.profile"
    for user_profile in ${profile} "$HOME/.bashrc";do
        sed -i -r -e '/^ {0,}(\.|source) {0,}[^ ]{1,}\/itom-cdf\.sh/d' "$user_profile"
        sed -i -r -e '/^ {0,}(\.|source) {0,}[^ ]{1,}\/itom-cdf-alias\.sh/d' "$user_profile"
    done

    write_log "trace" "cleanCaches ...OK"
}

# byok
check_namespace_via_sa(){
    local ns="$CDF_NAMESPACE"
    local reTryTimes=0

    if [ -z "$ns" ];then #tool capability
        cleanCaches
        exit 0
    fi

    while true; do
        if [ $(kubectl get sa default -n ${ns} 1>>$LOG 2>&1; echo $?) -eq 0 ]; then
            break
        elif [ $reTryTimes -eq 5 ]; then
            cleanCaches
            write_log "info" "Namespaces \"${ns}\" not found. Uninstall completed."
            exit 0
        else
            write_log "warn" "Failed to get default serviceaccount on ${ns} namespace. Wait for 2 seconds and retry: $reTryTimes "
        fi
        reTryTimes=$(( $reTryTimes + 1 ))
        sleep 2
    done
}

tryGetCdfAdminTask(){
    local previous_install_config="$TMP_FOLDER/.cdf_previous_install_$(cat ${CDF_HOME}/version.txt).properties"
    if [[ -f "$previous_install_config" ]];then
        source "$previous_install_config"
        CDF_ADMIN_TASKS="$(echo "$ESCAPE_CLI_ARGS_BASE64"|base64 -d|grep -Po '\-\-cat\s+\S+'|awk '{print $2}'|sed -e 's/"//g' -e "s/'//g")"
        if [[ -z "$CDF_ADMIN_TASKS" ]];then
            CDF_ADMIN_TASKS="$(echo "$ESCAPE_CLI_ARGS_BASE64"|base64 -d|grep -Po '\-\-cdf\-admin\-tasks\s+\S+'|awk '{print $2}'|sed -e 's/"//g' -e "s/'//g")"
        fi
        local isExistParams=false
        if echo "$ESCAPE_CLI_ARGS_BASE64"|base64 -d|grep -Pq '\-\-cat\s+\S+';then
            isExistParams=true
        fi
        if echo "$ESCAPE_CLI_ARGS_BASE64"|base64 -d|grep -Pq '\-\-cdf\-admin\-tasks\s+\S+';then
            isExistParams=true
        fi
        write_log "trace" "get CDF_ADMIN_TASKS=$CDF_ADMIN_TASKS from $previous_install_config"
        if [[ -z "$CDF_ADMIN_TASKS" ]] && [[ "$isExistParams" == "false" ]];then
            CDF_ADMIN_TASKS="ns,no,pv,cr,pc"
        fi
    fi
}

uninstallChartRelease(){
    local release=$1
    local namespace=$2
    write_log "trace" "Uninstall helm release: $namespace/$release"
    for (( i=0; i<10; i++));do
        local is_exist="$(helm list -n $namespace 2>/dev/null|tail -n +2|awk -v name=$release '$1 == name {print $1}')"
        if [[ -z "$is_exist" ]];then
            break
        fi
        helm uninstall $release -n $namespace 1>>$LOG 2>>$LOG
        local exit_code=$?
        echo "exit_code: $exit_code" >> $LOG
        if [ "$exit_code" -eq 0 ];then
            break
        fi
        sleep 1
    done

    local is_exist="$(helm list -n $namespace 2>/dev/null|tail -n +2|awk -v name=$release '$1 == name {print $1}')"
    if [[ -n "$is_exist" ]];then
        write_log "fatal" "Failed to uninstall the release: $namespace/$release"
    fi
    write_log "trace" "Uninstalled helm release: $namespace/$release"
}

uninstallByok(){
    write_log "trace" "Check the system environment: $(helm list -A -a 2>&1 || helm list -n $CDF_NAMESPACE -a 2>&1)"
    write_log "trace" "Check the system environment: $(kubectl get ns 2>&1 || kubectl get ns $CDF_NAMESPACE 2>&1)"
    write_log "trace" "Check the system environment: $(kubectl get po -A 2>&1 || kubectl get po -n $CDF_NAMESPACE 2>&1)"
    write_log "trace" "Check the system environment: $(kubectl get pvc -A 2>&1 || kubectl get pvc -n $CDF_NAMESPACE 2>&1)"
    write_log "trace" "Check the system environment: $(kubectl get pv -A 2>&1 || kubectl get pv -n $CDF_NAMESPACE 2>&1)"

    if [ -z "$CDF_ADMIN_TASKS" ];then
        #in case of upgrade, .cdf.uninstall.cfg not exits, we can't rely on it
        #but we can get CDF_ADMIN_TASKS from cdf configmap,we should try to get it before helm uninstall
        CDF_ADMIN_TASKS=$(trust_cmd "kubectl get cm cdf -n ${CDF_NAMESPACE} -o json --ignore-not-found" | jq -r '.data.CDF_ADMIN_TASKS')
        write_log "trace" "CDF_ADMIN_TASKS=$CDF_ADMIN_TASKS"
        if [ "$CDF_ADMIN_TASKS" == "null" ];then
            CDF_ADMIN_TASKS=""
        fi
        if [ -f $UNINSTALL_TMP ];then
            sed -i -e "/CDF_ADMIN_TASKS/ d" $UNINSTALL_TMP
        fi
        echo "CDF_ADMIN_TASKS=\"$CDF_ADMIN_TASKS\"" >> $UNINSTALL_TMP
    fi

    if [ -z "$CDF_ADMIN_TASKS" ];then
        write_log "trace" "Not found CDF_ADMIN_TASKS in ${CDF_NAMESPACE}/configmap/cdf ..."
        tryGetCdfAdminTask
        echo "CDF_ADMIN_TASKS=$CDF_ADMIN_TASKS"
    fi

    write_log "trace" "PRIMARY_NAMESPACE=$PRIMARY_NAMESPACE".
    if [ -z "$PRIMARY_NAMESPACE" ];then
        PRIMARY_DEPLOYMENT_UUID=$(trust_cmd "kubectl get ns ${CDF_NAMESPACE} -o json --ignore-not-found" | jq -r '.metadata.labels."deployments.microfocus.com/deployment-uuid"')
        write_log "trace" "PRIMARY_DEPLOYMENT_UUID=$PRIMARY_DEPLOYMENT_UUID"
        if [ -n "$PRIMARY_DEPLOYMENT_UUID" ] && [ "$PRIMARY_DEPLOYMENT_UUID" != "null" ];then
            PRIMARY_NAMESPACE=$(trust_cmd "kubectl get ns --no-headers --ignore-not-found -l deployments.microfocus.com/deployment-uuid=$PRIMARY_DEPLOYMENT_UUID" | awk '{print $1}' | grep -v "$CDF_NAMESPACE")
            write_log "trace" "PRIMARY_NAMESPACE=$PRIMARY_NAMESPACE"
            if [ "$PRIMARY_NAMESPACE" == "null" ];then
                PRIMARY_NAMESPACE=""
            fi
        fi
        if [ -f $UNINSTALL_TMP ];then
            sed -i -e "/PRIMARY_NAMESPACE/ d" $UNINSTALL_TMP
        fi
        echo "PRIMARY_NAMESPACE=\"$PRIMARY_NAMESPACE\"" >> $UNINSTALL_TMP
    fi

    local nss
    if [ -z "$PRIMARY_NAMESPACE" ];then
        nss=("$CDF_NAMESPACE")
    else
        nss=("$CDF_NAMESPACE" "$PRIMARY_NAMESPACE")
    fi
    write_log "trace" "nss=${nss[@]}, CDF_NAMESPACE=$CDF_NAMESPACE, PRIMARY_NAMESPACE=$PRIMARY_NAMESPACE"

    if [ -z "$NFS_PROVISIONER" ];then
        local nfs_provisioner=
        nfs_provisioner=$(trust_cmd "helm list -n $CDF_NAMESPACE -o json" | jq -r '.[] | select ( .name == "nfs-provisioner")')
        if [[ -n $nfs_provisioner ]] ; then
            NFS_PROVISIONER="true"
        else
            NFS_PROVISIONER="false"
        fi
        if [ -f $UNINSTALL_TMP ];then
            sed -i -e "/NFS_PROVISIONER/ d" $UNINSTALL_TMP
        fi
        write_log "trace" "NFS_PROVISIONER=$NFS_PROVISIONER"
        echo "NFS_PROVISIONER=\"$NFS_PROVISIONER\"" >> $UNINSTALL_TMP
    fi

    if [ -z "$PVS" ];then
        local vols
        for ns in ${nss[@]}; do
            vols=$(trust_cmd "kubectl get pvc -n $ns --no-headers --ignore-not-found --output=custom-columns=NAME:.spec.volumeName" | xargs)
            PVS="$PVS $vols"
            write_log "trace" "Get pvs from $ns: $vols"
        done
        if [ -f $UNINSTALL_TMP ];then
            sed -i -e "/PVS/ d" $UNINSTALL_TMP
        fi
        echo "PVS=\"$PVS\"" >> $UNINSTALL_TMP
    fi

    for ns in ${nss[@]}; do
        #helm install resources should be unintalled though helm
        #need uninstall crds resources at last - both crds and apphub chart will cleanup the crds
        local releases=
        local crdsReleaseName=
        local apphubReleaseName=
        local crdsChartName="prometheus-crds"
        local apphubChartName="apphub-"
        releases=($(trust_cmd "helm list -n $ns -q" | xargs))
        write_log "trace" "releases=${releases[@]}"
        if [[ -n "$releases" ]];then
            write_log "info" "Uninstall all releases through helm under namespace: $ns ..."
            for release in ${releases[@]};do
                local usedChart=$(trust_cmd "helm list -n $ns --filter $release -o json" | jq -r '.[].chart')
                if [[ ! "$usedChart" =~ "$crdsChartName"  ]] && [[ ! "$usedChart" =~ "$apphubChartName" ]]; then
                    uninstallChartRelease "$release" "$ns"
                elif [[ "$usedChart" =~ "$crdsChartName" ]]; then
                    crdsReleaseName="$release"
                elif echo $usedChart | grep -E '^apphub(-.*)?-[0-9]+\.[0-9]+\.[0-9]\+[0-9]+' >>$LOG; then
                    apphubReleaseName="$release"
                fi
            done
            for r in $apphubReleaseName $crdsReleaseName
            do
                uninstallChartRelease "$r" "$ns"
            done
        fi

        if [ -z "$CDF_ADMIN_TASKS" ] || [[ -z "$(echo "$CDF_ADMIN_TASKS"|grep -Po '\bns\b')" ]];then
            #then, iterate over all resources under namespace, and remove them
            write_log "info" "NS-ADMIN mode, remove all resources under namespace: $ns ..."
            for src in "sts" "deploy" "ds" "jobs" "cronjobs" "rc" "po";do
                trust_cmd "kubectl delete $src --all -n $ns --grace-period=0 --force --ignore-not-found" \
                    "Removing k8s resource: $src under namespace: $ns"
            done

            local namespacedRes=
            namespacedRes="$(trust_cmd "kubectl api-resources --namespaced=true --verbs=delete --no-headers -o name")"
            write_log "trace" "namespacedRes=$namespacedRes ."
            for nRes in $namespacedRes;do
                trust_cmd "kubectl delete $nRes -n $ns -l deployments.microfocus.com/cleanup=uninstall --grace-period=0 --force --ignore-not-found" \
                    "Remove $ns/$nRes"
            done

            trust_cmd "kubectl delete pvc --all -n $ns --grace-period=0 --force --ignore-not-found" \
                    "Removing k8s resource: pvc under namespace: $ns"

            if [ $(trust_cmd "kubectl get ns $ns --no-headers --ignore-not-found" | wc -l) -ne 0 ];then
                trust_cmd "kubectl annotate sa default -n $ns deployment.microfocus.com/is-primary-" \
                    "Remove annotate 'deployment.microfocus.com/is-primary'"

                trust_cmd "kubectl annotate sa default -n $ns deployment.microfocus.com/namespace-" \
                    "Remove annotate 'deployment.microfocus.com/namespace'"
            fi
        fi
    done

    #remove ns if needed
    echo "NSS=${nss[@]}"
    if [ -n "$CDF_ADMIN_TASKS" ] && [[ "$(echo "$CDF_ADMIN_TASKS"|grep -Po '\bns\b')" == "ns" ]];then
        for ns in ${nss[@]}; do
            if [ $(trust_cmd "kubectl get ns $ns --no-headers --ignore-not-found" | wc -l) -ne 0 ];then
                trust_cmd "kubectl delete ns $ns --grace-period=0 --force --ignore-not-found" \
                    "Removing namespace: $ns"
            fi
        done
    fi

    #reomve pv if needed
    echo "PVS=$PVS"
    if ([[ -n "$CDF_ADMIN_TASKS" && "$(echo "$CDF_ADMIN_TASKS"|grep -Po '\bpv\b')" == "pv" ]] || [[ "$NFS_PROVISIONER" == "true" ]]) && [ -n "$PVS" ];then
        for vol in $PVS;do
            if [ $(trust_cmd "kubectl get pv $vol --no-headers --ignore-not-found" | wc -l) -ne 0 ];then
                trust_cmd "kubectl delete pv $vol --ignore-not-found" \
                    "Removing persistent volume: $vol"
            fi
        done
    fi

    # reomve pv if pv create by install
    local label_pv_vals="$(trust_cmd "kubectl get pv --no-headers --ignore-not-found -l pv_pvc_label --output=custom-columns=NAME:.metadata.labels.pv_pvc_label")"
    write_log "info" "pv_pvc_labels: $(echo $label_pv_vals|xargs)"

    #then, remove global resource
    if [[ -n "$CDF_ADMIN_TASKS" && "$(echo "$CDF_ADMIN_TASKS"|grep -Po '\bcr\b')" == "cr" ]];then
        write_log "info" "Remove all serviceaccounts, clusterroles and clusterrolebindings ..."
        if [[ -f "$CURRENTDIR/objectdefs/rbac-config.yaml" ]];then
            trust_cmd "kubectl delete -f $CURRENTDIR/objectdefs/rbac-config.yaml --ignore-not-found" \
                "Remove rbac-config"
        fi

        local clusterrole_list
        clusterrole_list="$(trust_cmd "kubectl get clusterrole --ignore-not-found" | grep -iE "cdf" | awk '{print $1}'|xargs)"
        if [ -n "$clusterrole_list" ];then
            for clusterrole in ${clusterrole_list}; do
                trust_cmd "kubectl delete Clusterrole $clusterrole --grace-period=0 --force --ignore-not-found" \
                    "Remove Clusterrole $clusterrole"
            done
        fi


        local clusterrolebinding_list
        clusterrolebinding_list="$(trust_cmd "kubectl get clusterrolebinding --ignore-not-found" | grep -iE "cdf|suite-config|$CDF_NAMESPACE|suite-installer|kubernetes-vault-role|velero-server" | grep -v "$CDF_NAMESPACE" | awk '{print $1}'|xargs)"
        if [ -n "$clusterrolebinding_list" ];then
            for clusterrolebinding in ${clusterrolebinding_list}; do
                trust_cmd "kubectl delete Clusterrolebinding $clusterrolebinding --grace-period=0 --force --ignore-not-found" \
                    "Remove Clusterrolebinding $clusterrolebinding"
            done
        fi
    fi

    if [[ -n "$PRIMARY_NAMESPACE" ]];then
        trust_cmd "kubectl delete clusterrolebinding $PRIMARY_NAMESPACE:cluster-admin --grace-period=0 --force --ignore-not-found" \
            "Remove clusterrolebinding $PRIMARY_NAMESPACE:cluster-admin"
    fi

    #last step, remove ns and pv if needed
    write_log "info" "Remove all temporary cache files."
    cleanCaches
}


# byok
usage_byok(){
    echo "Usage: $0 [Options]"
    echo -e "\nOptions:"
    echo -e "  -h, --help           Print this help list. "
    echo -e "  -f, -y, --yes        Answer yes for any confirmations during uninstalltion."
}

# byok
example_byok(){
    echo -e "\nExamples: "
    echo -e "  ./uninstall.sh -h    Show help."
    echo -e "  ./uninstall.sh -y    No prompt confirmation message before uninstalltion."
    echo -e "  ./uninstall.sh -f    No prompt confirmation message before uninstalltion."
    echo ""
}



############################################
# BYOK
############################################

while [[ ! -z "$1" ]]
do
    case $1 in
    -f|-y|--yes) NOPROMPT=true; shift 1;;
    -x) LOG="$TMP_FOLDER/uninstall.cdf.$(date "+%Y%m%d%H%M%S").log"; KEEPLOG=true; shift 1;;
    -h|--help)
        usage_byok; example_byok; exit 0;;
    # to keep compatable for CI/CD, we just shift out the args
    *) shift 1;;
    esac
done

if [ "$NOPROMPT" != "true" ]; then
    echo -e "Uninstall process would remove all $PRODUCT_SHORT_NAME components."
    read -p "Are you sure to uninstall $PRODUCT_SHORT_NAME? (Y/N): " yn
    case $yn in
        YES|Yes|yes|Y|y )
            ;;
        NO|No|N|n )
            echo -e "Uninstall process QUIT." && exit 1
            ;;
        * )
            echo -e "Unknown input, Please input Y or N" && exit 1
            ;;
    esac
fi

write_log "info" "Uninstall log: $LOG"

check_namespace_via_sa
uninstallByok
write_log "info" "Uninstallation completed successfully."
write_log "warn" "Warning! Uninstallation will not uninstall the helm applications on exteranal Kubernetes. Users need to uninstall their own applications by themselves if they want."
$RM -f $UNINSTALL_TMP

if [[ "$KEEPLOG" == "true" ]]; then
    write_log "info" "The log of uninstall is kept in $LOG"
else
    if [[ "$NOPROMPT" != "true" ]];then
        read -p "Are you sure to remove uninstall log $LOG? (Y/N): " yn
        case $yn in
            YES|Yes|yes|Y|y )
                $RM -f $LOG
                echo "[INFO] `date "+%Y-%m-%d %H:%M:%S"` : Remove uninstall log: $LOG"
                ;;
            * )
                write_log "info" "The log of uninstall is kept in $LOG"
                ;;
        esac
    else
        $RM -f $LOG
        echo "[INFO] `date "+%Y-%m-%d %H:%M:%S"` : Remove uninstall log: $LOG"
    fi
fi