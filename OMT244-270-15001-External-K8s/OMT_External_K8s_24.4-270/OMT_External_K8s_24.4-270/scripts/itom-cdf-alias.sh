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

# CDF alias definitions
#
# Copy this file to /etc/profile.d
#
# Then:
#
# chmod 700 /etc/profile.d/itom-cdf-alias.sh; source /etc/profile.d/itom-cdf-alias.sh
# _OR_
# chmod 700 /etc/profile.d/itom-cdf-alias.sh and log out and back in


#see feature: OCTFT19S1761772
if [[ "bash" != "$(readlink /proc/$$/exe|xargs basename)" ]];then
        echo "! Warning: The current user's default shell is $(readlink /proc/$$/exe), OMT script only supports \"bash\". Please use the following command to change the current user's default shell to bash: chsh -s /bin/bash ${USER:-"$(whoami)"}; then, log out and back in."
else
        set +o posix
fi

_cdf_help(){
        echo "cdf-top               Show CPU/memory usage by node"
        echo "cdf-top-core          Show CPU/memory usage for pods in the $CDF_NAMESPACE namespace"
        echo "cdf-desc-nodes        Describe all nodes"
        echo "cdf-version           Show CDF version"
        echo "cdf-watch             Watch all pods in namespace"
        echo "cdf-watch-all         Watch all pods in all namespaces"
        echo "cdf-watch-core        Watch all pods in the $CDF_NAMESPACE namespace"
        echo "cdf-getpods           Get pods in namespace"
        echo "cdf-getpods-all       Get pods in all namespaces"
        echo "cdf-getpods-core      Get pods in the $CDF_NAMESPACE namespace"
        echo "cdf-editcm            Edit a configmap"
        echo "cdf-exec              Get a shell into a selected pod"
        echo "cdf-exec-idm          Exec into the IDM pod"
        echo "cdf-exec-cdfapi       Exec into the CDF API server pod"
        echo "cdf-exec-apphub       Exec into the CDF App Hub API server pod"
        echo "cdf-bad-pods          List all pods not running well in namespace"
        echo "cdf-bad-pods-all      List all pods not running well in all namespaces"
        echo "cdf-logs              Get logs of a specific container in a pod"
        echo "cdf-logsf             Follow logs of a specific container in a pod"
        echo "cdf-containers        List all pods/container/images in namespace"
        echo "cdf-containers-all    List all pods/container/images in all namespaces"
        echo "cdf-imglist           List all images of all running containers in namespace"
        echo "cdf-imglist-all       List all images of all running containers in all namespaces"
        echo "cdf-copyin            Copy SOURCE local file to DEST in a remote pod in a specific container"
        echo "cdf-copyout           Copy SOURCE from a remote pod to DEST locally"
}

_cdf_selectns(){
        # 1. _cdf_selectns -n core
        # 2. _cdf_selectns core
        _namespace=
        if [[ "$1" == "-n" ]] && [[ -n "$2" ]];then
                _namespace=$2
        elif [[ -n "$1" ]] && [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]];then
                _namespace=$1
        fi
        if [[ -z "$_namespace" ]];then
                PS3="Select Namespace: "
                select namespace_name in $(kubectl get namespaces --no-headers|awk '{print $1}')
                do if [[ -n "$namespace_name" ]];then echo "$namespace_name"; export _namespace=$namespace_name; break; fi; done
        fi
}

_cdf_selectpod(){
        local status=$1
        local posds=
        PS3="Select POD: "
        _pod=
        if [[ -n "$status" ]];then
                posds=$(kubectl get pods -n $_namespace --no-headers|awk -v s="$status" '$3==s{print $1}')
        else
                posds=$(kubectl get pods -n $_namespace --no-headers|awk '{print $1}')
        fi
        [[ -z "$posds" ]] && return
        select pod_name in $posds
        do if [[ -n "$pod_name" ]];then echo "$pod_name"; export _pod=$pod_name; break; fi; done
}

_cdf_selectcontainer(){
        _container=
        [[ -z "$_pod" ]] && return
        local containers;containers=$(_cdf_ls_cont)
        local count;count=$(echo "$containers"|awk '{print NF}')
        if [[ "$count" == "1" ]];then
                export _container=$containers
        else
                PS3="Select Container: "
                select container_name in $containers
                do if [[ -n "$container_name" ]];then echo "$container_name"; export _container=$container_name; break; fi; done
        fi
}

_cdf_ls_cont(){
        kubectl get pods -n $_namespace -o jsonpath='{.spec.containers[*].name}' $_pod | awk '{print $1 "\n" $2}'
}

_cdf_selectcm(){
        PS3="Select Configmap: "
        _configmap=
        local cms;cms=$(kubectl get configmaps -n $_namespace --no-headers|awk '{print $1}')
        [[ -z "$cms" ]] && return
        select configmap_name in $cms
        do if [[ -n "$configmap_name" ]];then echo "$configmap_name"; export _configmap=$configmap_name; break; fi; done
}

_cdf_checkshell(){
        [[ -z "$_pod" ]] && return
        if kubectl exec -it $_pod -n $_namespace -c $_container -- ls /bin/bash 1>/dev/null 2>&1;then
                export _cont_shell="bash"
        else
                export _cont_shell="sh"
        fi
}

_cdf_highlight(){
        echo -e "\033[1m\033[32m$1\033[?25h\033[0m"
        eval "$1"
}

_cdf_runcmd(){
        [[ -z "$_pod" ]] && return
        echo -e "\033[1m\033[32m$1\033[?25h\033[0m"
        eval "$1"
}

_cdf_fromfile(){
        [[ -z "$_pod" ]] && return
        local from=$1
        while true;do
                if [[ "$from" == "container" ]];then
                        read -r -p "Input SOURCE file in $_pod in $_container: " _cont_file
                        if kubectl exec -it $_pod -n $_namespace -c $_container -- ls $_cont_file 1>/dev/null 2>&1;then
                                if [[ "${_cont_file:0:1}" == "/" ]];then
                                        _cont_file=${_cont_file:1}
                                fi
                                break
                        fi
                else
                        read -r -p "Input SOURCE file in local: " _local_file
                        if ls $_local_file 1>/dev/null 2>&1;then
                                break
                        fi
                fi
        done
}

_cdf_tofile(){
        [[ -z "$_pod" ]] && return
        local to=$1
        while true;do
                if [[ "$to" == "container" ]];then
                        read -r -p "Input DEST file in $_pod in $_container: " _cont_file
                        if [[ -n "$_cont_file" ]];then
                                break
                        fi
                else
                        read -r -p "Input DEST file in local: " _local_file
                        if [[ -n "$_local_file" ]];then
                                break
                        fi
                fi
        done
}

_getCdfEnv(){
        if [[ -f /etc/profile.d/itom-cdf.sh ]];then
                source /etc/profile.d/itom-cdf.sh
        elif [[ -f "$HOME/itom-cdf.sh" ]];then
                source $HOME/itom-cdf.sh
        fi
}

_cdf_version(){
        if ! kubectl get cm -n $CDF_NAMESPACE cdf-cluster-host --no-headers -o custom-columns=:.data.INFRA_VERSION 2>/dev/null;then
                kubectl get cm -n $CDF_NAMESPACE cdf --no-headers -o custom-columns=:.data.PLATFORM_VERSION
        fi
}

_cdf_watch(){
        _cdf_selectns "$1" "$2"
        watch kubectl get pods -n $_namespace -o wide
}

_cdf_getpods(){
        _cdf_selectns "$1" "$2"
        kubectl get pods -n $_namespace -o wide
}

_cdf_editcm(){
        _cdf_selectns "$1" "$2"
        _cdf_selectcm
        [[ -n "$_configmap" ]] && _cdf_highlight "kubectl edit cm -n $_namespace $_configmap"
}

_cdf_bad_pods(){
        _cdf_selectns "$1" "$2"
        kubectl get pods -n $_namespace -o wide | awk -F " *|/" '($2!=$3 || $4!="Running") && $4!="Completed" {print $0}'
}

_cdf_bad_pods_all(){
        kubectl get pods --all-namespaces -o wide | awk -F " *|/" '($3!=$4 || $5!="Running") && $5!="Completed" {print $0}'
}

_cdf_exec(){
        _cdf_selectns
        _cdf_selectpod "Running"
        _cdf_selectcontainer
        _cdf_checkshell
        _cdf_runcmd "kubectl exec -ti $_pod -n $_namespace -c $_container -- $_cont_shell"
}

_cdf_logs(){
        _cdf_selectns
        _cdf_selectpod
        _cdf_selectcontainer
        _cdf_runcmd "kubectl -n $_namespace logs $_pod -c $_container"
}

_cdf_logsf(){
        _cdf_selectns
        _cdf_selectpod
        _cdf_selectcontainer
        _cdf_runcmd "kubectl -n $_namespace logs $_pod -c $_container -f"
}

_cdf_containers(){
        _cdf_selectns "$1" "$2"
        kubectl describe pod -n $_namespace | awk '/Container ID:/ {container_name = last_line_c } /Namespace:/ {ns = $2; pod = last_line_p} /Image:/ {im = $2; if (pod == last_pod) {printf "\t%s %s\n", container_name, im} else {printf "\nPod:  %s\n\t%s %s\n", pod, container_name, im}; last_pod = pod} {last_line_c = $1; last_line_p = $2} '
}

_cdf_containers_all(){
        kubectl describe pod --all-namespaces | awk '/Container ID:/ {container_name = last_line_c } /Namespace:/ {ns = $2; pod = last_line_p} /Image:/ {im = $2; if (pod == last_pod) {printf "\t%s %s\n", container_name, im} else {printf "\nPod:  %s\n\t%s %s\n", pod, container_name, im}; last_pod = pod} {last_line_c = $1; last_line_p = $2} '
}

_cdf_imglist(){
        _cdf_selectns "$1" "$2"
        kubectl describe pods -n $_namespace|awk '$1=="Image:"{print $2}'|sort|uniq
}

_cdf_imglist_all(){
        kubectl describe pods --all-namespaces|awk '$1=="Image:"{print $2}'|sort|uniq
}

_cdf_copyin(){
        _cdf_selectns
        _cdf_selectpod "Running"
        _cdf_selectcontainer
        _cdf_fromfile
        _cdf_tofile "container"
        _cdf_runcmd "kubectl cp $_local_file -n $_namespace -c $_container $_pod:$_cont_file"
}

_cdf_copyout(){
        _cdf_selectns
        _cdf_selectpod "Running"
        _cdf_selectcontainer
        _cdf_fromfile "container"
        _cdf_tofile
        _cdf_runcmd "kubectl cp $_pod:$_cont_file -n $_namespace -c $_container $_local_file"
}

_cdf_exec_idm(){
        _pod="$(kubectl get pod -n $CDF_NAMESPACE -ocustom-columns=NAME:.metadata.name 2>/dev/null |grep idm|head -1)"
        if [[ -n "$_pod" ]];then
                kubectl exec -it $_pod -n $CDF_NAMESPACE -- sh
        else
                echo "No IDM found in $CDF_NAMESPACE namespace."
        fi
}

_cdf_exec_cdfapi(){
        _pod="$(kubectl get pod -n $CDF_NAMESPACE -ocustom-columns=NAME:.metadata.name |grep cdf-apiserver|head -1)"
        if [[ -n "$_pod" ]];then
                kubectl exec -it $_pod -n $CDF_NAMESPACE -- sh
        else
                echo "No cdf-apiserver found in $CDF_NAMESPACE namespace."
        fi
}

_cdf_exec_apphub(){
        _pod="$(kubectl get pod -n $CDF_NAMESPACE -ocustom-columns=NAME:.metadata.name |grep apphub-apiserver|head -1)"
        if [[ -n "$_pod" ]];then
                kubectl exec -it $_pod -n $CDF_NAMESPACE -- sh
        else
                echo "No apphub-apiserver found in $CDF_NAMESPACE namespace."
        fi
}

_getCdfEnv

# alias start
if [[ -n "$CDF_NAMESPACE" ]];then

alias cdf-help='_cdf_help'
alias cdf-top='kubectl top nodes'
alias cdf-top-core='kubectl top pods -n $CDF_NAMESPACE'
alias cdf-desc-nodes='kubectl describe nodes'
alias cdf-version='_cdf_version'
alias cdf-watch='_cdf_watch'
alias cdf-watch-all='watch kubectl get pods --all-namespaces -o wide'
alias cdf-watch-core='watch kubectl get pods -n $CDF_NAMESPACE -o wide'
alias cdf-getpods='_cdf_getpods'
alias cdf-getpods-all='kubectl get pods --all-namespaces -o wide'
alias cdf-getpods-core='kubectl get pods -n $CDF_NAMESPACE -o wide'
alias cdf-editcm='_cdf_editcm'
alias cdf-exec-idm='_cdf_exec_idm'
alias cdf-exec-cdfapi='_cdf_exec_cdfapi'
alias cdf-exec-apphub='_cdf_exec_apphub'
alias cdf-bad-pods='_cdf_bad_pods'
alias cdf-bad-pods-all='_cdf_bad_pods_all'
alias cdf-exec='_cdf_exec'
alias cdf-logs='_cdf_logs'
alias cdf-logsf='_cdf_logsf'
alias cdf-containers='_cdf_containers'
alias cdf-containers-all='_cdf_containers_all'
alias cdf-imglist='_cdf_imglist'
alias cdf-imglist-all='_cdf_imglist_all'
alias cdf-copyin='_cdf_copyin'
alias cdf-copyout='_cdf_copyout'

fi
# alias end