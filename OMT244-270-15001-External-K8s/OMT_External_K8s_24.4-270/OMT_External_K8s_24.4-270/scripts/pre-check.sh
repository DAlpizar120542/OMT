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

#set -x
export LC_ALL="C"
export PRODUCT_SHORT_NAME="OMT"

usage(){
    echo  -e "pre-check.sh checks if a server (and optionally an existing kubernetes infrastructure) is ready for node installation.
\nUsage: $0 [Options]
\nOptions:
    --api-port                         Specify the HTTPS port of the Kubernetes API server.
                                       For the first master node, it is optional. The default value is '8443'.
                                       For the remaining nodes, it is mandatory, get the value from the cdf-cluster-host: MASTER_API_SSL_PORT.
    --api-server                       Specify the Kubernetes API server. For the first master node, this parameter is not required.
                                       For the remaining nodes, it is mandatory. You can get the value from the cdf-cluster-host: API_SERVER.
    --auto-configure-firewall          Flag to indicate whether automatically configure the firewall rules.
                                       For the first master node, it is optional. The default value is 'true'.
                                       For the remaining nodes, it is not required.
    --cacert                           Specify the absolute path of the ca.crt file. For the first master node, it is not required.
                                       For the remaining nodes, it is mandatory.
    --ca-file                          Same as \"--cacert\", but deprecated.
    --cdf-home                         Specify the absolute path of the installation directory.
                                       By default, the installation directory is '/opt/cdf'.
    --clientcert                       Specify the absolute path of the client cert file. For the first master node, it is not required.
                                       For the remaining nodes, it is mandatory.
    --cert-file                        Same as \"--clientcert\", but deprecated.
    --cpu                              Specify the required CPU (number) on the node. It is optional for all nodes. The default value is '2'.
    --external-access-port             Specify the external access port.
    --fips-entropy-threshold           Specify the entropy threshold when FIPS mode is enabled. It is optional for all nodes. The default value is '2000'.
    --disk                             Specify the required free disk (GB) on the node. It is optional for all nodes. The default value is '20'.
    --flannel-backend-type             Specify the type of Flannel backend. For the first master node, this is optional. The default vaule is 'host-gw'.
                                       Allowed values: host-gw, vxlan.
    --flannel-iface                    Specify the Flannel iface (IPv4 address or network interface name). It is optional for all nodes.
    --fluentd-log-receiver-url         Specify the Fluentd log receiver url.
                                       It is optional for the first master node and not required for the remaining nodes.
    --fluentd-log-receiver-user        Specify the user for connecting to the Fluentd log receiver.
                                       It is optional for the first master node and not required for the remaining nodes.
    --fluentd-log-receiver-pwd         Specify the password for connecting to the Fluentd log receiver.
                                       It is optional for the first master node and not required for the remaining nodes.
    --fluentd-log-receiver-ca          Specify the ca file for connecting to the Fluentd log receiver.
                                       It is optional for the first master node and not required for the remaining nodes.
    --gid                              Specify the system group ID. It is optional for all nodes.
    -h|--help                          Print this help list.
    --ipv6                             Indicates ipv6 enabled or not. Allowed values: true, false. The default value is 'false'.
    --ipv6-pod-cidr                    Specify the IPV6_POD_CIDR when ipv6 is enabled.
    --ipv6-pod-cidr-subnetlen          Specifies the size of the subnet allocated to each host for pod network addresses when ipv6 is enabled.
    --ipv6-service-cidr                Specify the IPV6_SERVICE_CIDR when ipv6 is enabled.
    --clientkey                        Specify the absolute path of the client key file. For the first master node, it is not required.
                                       For the remaining nodes, it is mandatory.
    --key-file                         Same as \"--clientkey\", but deprecated.
    --load-balancer-host               Specify a single IPV4 address or FQDN used for connection redundancy by providing fail-over
                                       for master nodes in multiple subnet.
                                       For the first master node, it is mandatory when plan to install multiple masters in multiple subnet.
                                       For the remaining nodes, it is not required.
    --mem                              Specify the required memory (GB) on the node. It is optional for all nodes. The default value is '8'.
    --node-type                        Specify the type of the node. Allowed values: first, master, worker.
    --pod-cidr                         Specify the POD_CIDR. It is optional for the first master node. The default value is '172.16.0.0/16'.
                                       For the remaining nodes, it is not required.
    --runtime-home                     Specify the directory for placing the kubernetes infrastructure runtime data.
                                       For the first master node, it is optional. The default vaule is '/opt/cdf/data'.
                                       For the remaining nodes, it is not required.
    --service-cidr                     Specify the SERVICE_CIDR. It is optional for the first master node. The default value is '172.17.17.0/24'.
                                       For the remaining nodes, it is not required.
    --k8s-provider                     Specify the cloud provider. It is optional for all nodes.
    --kubelet-protect-kernel-defaults  Option used to enable kubelet protectKernelDefaults. Use '--kubelet-protect-kernel-defaults' option to enable.
    --skip-warning                     Specify the flag for skipping warning or not. It is optinal for all nodes.
    --tls-min-version                  Specifies minimum accepted TLS version. The allowed values: 'TLSv1.2', 'TLSv1.3'.
    --tmp                              Specify the absolute path of the temp folder. It is optional for all nodes. The default value is '/tmp'.
    --uid                              Specify the system user ID. It is optional for all nodes.
    --user                             Specify the nonroot username. It is optional for all nodes, only required when install kubernetes infrastructure with nonroot user.
    --virtual-ip                       Specify a single IPV4 address used for connection redundancy by providing fail-over
                                       for master nodes in single subnet.
                                       For the first master node, it is mandatory when plan to install multiple masters in single subnet.
                                       For the remaining nodes, it is not required.\n"
    exit 1;
}
#   --node-host              Specifies the IPv4 or FQDN of the node  (Mandatory for all nodes for non-standalone mode; for standalone mode, it's not required.)
#   --network-address        value from base-configmap: NETWORK_ADDRESS (Mandatory for extending nodes)
#   -l|--logfile             Specify the absolute path of filename of precheck log. It's optinal for all nodes.

getRfcTime(){
    date --rfc-3339=ns|sed 's/ /T/'
}

log(){
    local status=$(echo $1|tr [:lower:] [:upper:])
    local msg="$2"
    local errMsg="$3"
    local comment="$4" #add this for printing more messages when check is PASS.
    local logTimeFmt=$(getRfcTime)
    case $status in
        PASS|DISABLED)
            if [ -n "$comment" ]; then
                uniformMsgFormat "$status" "$msg" "$comment"
                [ -n "$logfile" ] && echo -e "$logTimeFmt INFO     $msg ..... [ $status ] ($comment)" >>$logfile
            else
                uniformMsgFormat "$status" "$msg"
                [ -n "$logfile" ] && echo -e "$logTimeFmt INFO     $msg ..... [ $status ]" >>$logfile
            fi
            ;;
        FAILED)
            PRECHECK_FAILURE=$(( $PRECHECK_FAILURE + 1 ))
            uniformMsgFormat "$status" "$msg" "$errMsg"
            [ -n "$logfile" ] && echo -e "$logTimeFmt ERROR     $msg ..... [ $status ] ($errMsg)" >>$logfile ;;
        WARNING)
            PRECHECK_WARNING=$(( $PRECHECK_WARNING + 1 ))
            uniformMsgFormat "$status" "$msg" "$errMsg"
            [ -n "$logfile" ] && echo -e "$logTimeFmt WARN     $msg ..... [ $status ] ($errMsg)" >>$logfile ;;
        SKIP)
            uniformMsgFormat "$status" "$msg" "$errMsg"
            [ -n "$logfile" ] && echo -e "$logTimeFmt SKIP     $msg ..... [ $status ] ($errMsg)" >>$logfile ;;
        CATALOG)
            [ "$VERBOSE" != "false" ] && echo -e "$msg"
            [ -n "$logfile" ] && echo -e "$logTimeFmt INFO $msg" >>$logfile ;;
        ERROR)
            echo -e $msg
            [ -n "$logfile" ] && echo -e "$logTimeFmt ERROR $msg" >>$logfile ;;
        FATAL)
            echo -e $msg
            [ -n "$logfile" ] && echo -e "$logTimeFmt FATAL $msg" >>$logfile
            exit 1 ;;
        *)
            uniformMsgFormat "$status" "$msg"
            [ -n "$logfile" ] && echo -e "$logTimeFmt INFO     $msg ..... [ $status ]" >>$logfile ;;
    esac
}

uniformMsgFormat(){
    local status=$(echo $1|tr [:lower:] [:upper:])
    # when no-info is set, only print warning/error/fatal message
    if [ "$VERBOSE" = "false" ] && [[ "$status" =~ PASS|DISABLED|SKIP|CATALOG ]]; then
        return 0
    fi
    local msg="   $2"
    local errMsg="$3"
    local maxLen=65
    local dots=""
    [ ${#msg} -gt $maxLen ] && dotLen=3 || dotLen=$(($maxLen-${#msg}))
    while [ $dotLen -gt 0 ]
    do
        dots="${dots}."
        dotLen=$((dotLen-1))
    done
    [ -n "$errMsg" ] && { echo -e "$msg $dots [ $status ]"; echo -e "($errMsg)"|fold -sw 75; } || echo -e "$msg $dots [ $status ]"
}

while [ "$1" != "" ]; do
    case $1 in
      -l|--logfile)
        logfile=$2
        shift 2
        ;;
      --api-port )
        case "$2" in
          -*) log "fatal" "--api-port parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--api-port parameter requires a value. "; fi; MASTER_API_SSL_PORT=$2; shift 2;;
        esac  ;;
      --api-server )
        case "$2" in
          -*) log "fatal" "--api-server parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--api-server parameter requires a value. "; fi; K8S_MASTER_IP=$2; shift 2;;
        esac ;;
      --auto-configure-firewall )
        case "$2" in
          -*) log "fatal" "--auto-configure-firewall parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--auto-configure-firewall requires a value. "; fi; AUTO_CONFIGURE_FIREWALL=$2; shift 2;;
        esac  ;;
      --ca-file )
        case "$2" in
          -*) log "fatal" "--ca-file parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--ca-file parameter requires a value. "; elif [ ! -f "$2" ];then log "fatal" "CA file $2 does not exist. "; fi; CA_FILE_DEPRECATED=$2; shift 2;;
        esac ;;
      --cacert )
        case "$2" in
          -*) log "fatal" "--cacert parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--cacert parameter requires a value. "; elif [ ! -f "$2" ];then log "fatal" "CA file $2 does not exist. "; fi; CA_FILE=$2; shift 2;;
        esac ;;
      --cert-file )
        case "$2" in
          -*) log "fatal" "--cert-file parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--cert-file parameter requires a value. "; elif [ ! -f "$2" ];then log "fatal" "Cert file $2 does not exist. "; fi; CERT_FILE_DEPRECATED=$2; shift 2;;
        esac ;;
      --clientcert )
        case "$2" in
          -*) log "fatal" "--clientcert parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--clientcert parameter requires a value. "; elif [ ! -f "$2" ];then log "fatal" "Cert file $2 does not exist. "; fi; CERT_FILE=$2; shift 2;;
        esac ;;
      --k8s-provider )
        case "$2" in
          -*) log "fatal" "--k8s-provider parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--k8s-provider parameter requires a value. "; fi; K8S_PROVIDER=$(echo $2|tr '[:upper:]' '[:lower:]'); shift 2;;
        esac ;;
      --enable-fips )
        case "$2" in
          -*)  log "fatal" "--enable-fips parameter requires a value. ";;
          * )  if [ "$2" != "true" -a "$2" != "false" ];then log "fatal" "--enable-fips parameter allowed values: 'true', 'false' "; fi; ENABLE_FIPS=$2; shift 2;;
        esac ;;
      --external-access-port )
        case "$2" in
          -*)  log "fatal" "--external-access-port parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--external-access-port parameter requires a value. "; fi; EXTERNAL_ACCESS_PORT=$2; shift 2;;
        esac ;;
      --fips-entropy-threshold )
        case "$2" in
          -*)  log "fatal" "--fips-entropy-threshold parameter requires a value. ";;
          * )  if [ -z $2 ];then log "fatal" "--fips-entropy-threshold requires a value. "; fi; FIPS_ENTROPY_THRESHOLD=$2; shift 2;;
        esac ;;
      --fail-swap-on )
        case "$2" in
          -*)  log "fatal" "--fail-swap-on parameter requires a value. ";;
          * )  if [ "$2" != "true" -a "$2" != "false" ];then log "fatal" "--fail-swap-on parameter allowed values: 'true', 'false' "; fi; FAIL_SWAP_ON=$2; shift 2;;
        esac ;;
      --flannel-iface )
        case "$2" in
          -*) log "fatal" "--flannel-iface parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--flannel-iface parameter requires a value. "; fi; FLANNEL_IFACE=$2; shift 2;;
        esac ;;
      --first-node-time )
        case "$2" in
          -*) log "fatal" "--first-node-time parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--first-node-time parameter requires a value. "; fi; CURRENT_NODE_TIME=$(date +%s); FIRST_NODE_TIME=$2; shift 2;;
        esac ;;
      --virtual-ip )
        case "$2" in
          -*) log "fatal" "--virtual-ip parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--virtual-ip parameter requires a value. "; fi; HA_VIRTUAL_IP=$2; shift 2;;
        esac ;;
      --load-balancer-host )
        case "$2" in
          -*) log "fatal" "--load-balancer-host parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--load-balancer-host parameter requires a value. "; fi; LOAD_BALANCER_HOST=$2; shift 2;;
        esac ;;
      --cdf-home )
        case "$2" in
          -*) log "fatal" "--cdf-home parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--cdf-home parameter requires a value. "; fi; CDF_HOME=$2; shift 2;;
        esac ;;
      --runtime-home )
        case "$2" in
          -*) log "fatal" "--runtime-home parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--runtime-home parameter requires a value. "; fi; RUNTIME_CDFDATA_HOME=$2; shift 2;;
        esac ;;
      --key-file )
        case "$2" in
          -*) log "fatal" "--key-file parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--key-file parameter requires a value. "; elif [ ! -f "$2" ];then log "fatal" "Key file $2 does not exist. "; fi; KEY_FILE_DEPRECATED=$2; shift 2;;
        esac ;;
      --clientkey )
        case "$2" in
          -*) log "fatal" "--clientkey parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--clientkey parameter requires a value. "; elif [ ! -f "$2" ];then log "fatal" "Key file $2 does not exist. "; fi; KEY_FILE=$2; shift 2;;
        esac ;;
      --node-host )
        case "$2" in
          -*) log "fatal" "--node-host parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--node-host parameter requires a value. "; fi; THIS_NODE=$2; shift 2;;
        esac ;;
      --node-type )
        case "$2" in
          -*)  log "fatal" "--node-type parameter requires a value. ";;
          * )  if [ "$2" != "master" -a "$2" != "worker" -a "$2" != "first" ];then log "fatal" "--node-type parameter allowed values: 'first', 'master', 'worker' "; fi; NODE_TYPE=$2; shift 2;;
        esac ;;
      --uid )
        case "$2" in
          -*) log "fatal" "--uid parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--uid parameter requires a value. "; fi; SYSTEM_USER_ID=$2; shift 2;;
        esac  ;;
      --gid )
        case "$2" in
          -*) log "fatal" "--gid parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--gid parameter requires a value. "; fi; SYSTEM_GROUP_ID=$2; shift 2;;
        esac  ;;
      --device-type )
        case "$2" in
          -*) log "fatal" "--device-type parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--device-type parameter requires a value. "; fi; DEVICE_TYPE="${2// /}"; shift 2;;
        esac ;;
      --network-address )
        case "$2" in
          -*) log "fatal" "--network-address parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--network-address parameter requires a value. "; fi; NETWORK_ADDRESS=$2; shift 2;;
        esac ;;
      --flannel-backend-type )
        case "$2" in
          -*) log "fatal" "--flannel-backend-type parameter requires a value. ";;
          * ) if [ "$2" != "host-gw" -a "$2" != "vxlan" ];then log "fatal" "--flannel-backend-type parameter allowed values: 'host-gw', 'vxlan' "; fi; FLANNEL_BACKEND_TYPE=$2; shift 2;;
        esac ;;
      --cpu )
        case "$2" in
          -*) log "fatal" "--cpu parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--cpu parameter requires a value. "; fi; CLI_CPU=$2; shift 2;;
        esac ;;
      --mem )
        case "$2" in
          -*) log "fatal" "--mem parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--mem parameter requires a value. "; fi; CLI_MEM=$2; shift 2;;
        esac ;;
      --disk )
        case "$2" in
          -*) log "fatal" "--disk parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--disk parameter requires a value. "; fi; CLI_DISK=$2; shift 2;;
        esac ;;
      --tmp )
        case "$2" in
          -*) log "fatal" "--tmp parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--tmp parameter requires a value. "; fi; TMP_FOLDER=$2; shift 2;;
        esac ;;
      --pod-cidr )
        case "$2" in
          -*) log "fatal" "--pod-cidr parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--pod-cidr parameter requires a value. "; fi; POD_CIDR=$2; shift 2;;
        esac ;;
      --ipv6 )
        case "$2" in
          -*) log "fatal" "--ipv6 parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--ipv6 parameter requires a value. "; fi; ENABLE_IPV6=$2; shift 2;;
        esac ;;
      --ipv6-pod-cidr )
        case "$2" in
          -*) log "fatal" "--ipv6-pod-cidr parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--ipv6-pod-cidr parameter requires a value. "; fi; IPV6_POD_CIDR=$2; shift 2;;
        esac ;;
      --pod-cidr-subnetlen )
        case "$2" in
          -*) log "fatal" "--pod-cidr-subnetlen parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--pod-cidr-subnetlen parameter requires a value. "; fi; POD_CIDR_SUBNETLEN=$2; shift 2;;
        esac ;;
      --ipv6-pod-cidr-subnetlen )
        case "$2" in
          -*) log "fatal" "--ipv6-pod-cidr-subnetlen parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--ipv6-pod-cidr-subnetlen parameter requires a value. "; fi; IPV6_POD_CIDR_SUBNETLEN=$2; shift 2;;
        esac ;;
      --service-cidr )
        case "$2" in
          -*) log "fatal" "--service-cidr parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--service-cidr parameter requires a value. "; fi; SERVICE_CIDR=$2; shift 2;;
        esac ;;
      --ipv6-service-cidr )
        case "$2" in
          -*) log "fatal" "--ipv6-service-cidr parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--ipv6-service-cidr parameter requires a value. "; fi; IPV6_SERVICE_CIDR=$2; shift 2;;
        esac ;;
      --user )
        case "$2" in
          -*) log "fatal" "--user parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--user parameter requires a value. "; fi; NOROOT_USER=$2; shift 2;;
        esac ;;
      --fluentd-log-receiver-url )
        case "$2" in
          -*) log "fatal" "--fluentd-log-receiver-url parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--fluentd-log-receiver-url parameter requires a value. "; fi; FLUENTD_LOG_RECEIVER_URL=$2; shift 2;;
        esac ;;
      --fluentd-log-receiver-user )
        case "$2" in
          -*) log "fatal" "--fluentd-log-receiver-user parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--fluentd-log-receiver-user parameter requires a value. "; fi; FLUENTD_LOG_RECEIVER_USER=$2; shift 2;;
        esac ;;
      --fluentd-log-receiver-pwd )
        case "$2" in
          -*) log "fatal" "--fluentd-log-receiver-pwd parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--fluentd-log-receiver-pwd parameter requires a value. "; fi; FLUENTD_LOG_RECEIVER_PWD=$2; shift 2;;
        esac ;;
      --fluentd-log-receiver-ca )
        case "$2" in
          -*) log "fatal" "--fluentd-log-receiver-ca parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--fluentd-log-receiver-user parameter requires a value. "; fi; FLUENTD_LOG_RECEIVER_CA=$2; shift 2;;
        esac ;;
      --fluentd-log-receiver-type )
        case "$2" in
          -*) log "fatal" "--fluentd-log-receiver-type parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--fluentd-log-receiver-type parameter requires a value. "; fi; FLUENTD_LOG_RECEIVER_TYPE=$2; shift 2;;
        esac ;;
      --nfs-folder )
        case "$2" in
          -*) log "fatal" "--nfs-folder parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--nfs-folder parameter requires a value. "; fi; NFS_DIR=$2; shift 2;;
        esac ;;
      --tls-min-version )
        case "$2" in
          -*) log "fatal" "--tls-min-version parameter requires a value. ";;
          * ) if [ -z $2 ];then log "fatal" "--tls-min-version parameter requires a value. "; fi; TLS_MIN_VERSION=$(echo $2 | tr [:upper:] [:lower:]); shift 2;;
        esac ;;
      --kubelet-protect-kernel-defaults ) CLI_KUBELET_PROTECT_KERNEL_DEFAULTS="true"; shift ;;
      --skip-warning ) CLI_SKIP_WARNING="true"; shift ;;
      --integrated ) STANDALONE_FLAG="false"; shift ;;
      --inner-check ) INNER_CHECK="true"; shift ;;
      --existed ) EXISTED_NODE="true"; shift ;;
      --no-verbose) VERBOSE="false"; shift ;;
      -h|--help )
        usage; exit 0 ;;
      *) log "error" "Invalid parameter: $1"
         usage ;;
    esac
done

CURRENTDIR=$(cd `dirname $0`; pwd)
OS_NO_PROXY=${NO_PROXY}
OS_no_proxy=${no_proxy}
export no_proxy=${K8S_MASTER_IP},${THIS_NODE},\$no_proxy
PRECHECK_FAILURE=0
PRECHECK_WARNING=0

TMP_DISK=10
VAR_DISK=1
ROOT_DISK=1
NODE_CPU=${CLI_CPU:-"2"}
NODE_MEM=${CLI_MEM:-"8"}
NODE_DISK=${CLI_DISK:-"20"}
STATIC_DISK=8
TMP_FOLDER=${TMP_FOLDER:-"/tmp"}
KUBELET_PROTECT_KERNEL_DEFAULTS=${CLI_KUBELET_PROTECT_KERNEL_DEFAULTS:-"false"}
SKIP_WARNING=${CLI_SKIP_WARNING:-"false"}
STANDALONE_FLAG=${STANDALONE_FLAG:-"true"}
EXTERNAL_ACCESS_PORT=${EXTERNAL_ACCESS_PORT:-"5443"}
STEPS_FILE=$TMP_FOLDER/.cdfInstallCompletedSteps.tmp
readonly AZURE_CONFIG_FILE="/etc/cdf/keepalived/keepalived-azure.conf"
[[ $TLS_MIN_VERSION == "tlsv1.3" ]] && CURL_TLS='--tlsv1.3' || CURL_TLS='--tlsv1.2'
HINT_MSG="Notes: All the external resources, such as external databases, external image repositories, NFS servers, etc., will be checked by install script later during installation progress."
VERBOSE=${VERBOSE:-"true"}

getDataFromBaseConfigMap(){
  local BASE_URL="https://${K8S_MASTER_IP}:${MASTER_API_SSL_PORT}"
  local api_url="/api/v1/namespaces/core/configmaps/cdf-cluster-host"

  local apiResponse=$(curl $CURL_TLS -s -k -X GET  \
                -w '%{http_code}' \
                --header 'Content-Type: application/json' \
                --header 'Accept: application/json' \
                "${BASE_URL}${api_url}" \
                --cacert "$CA_FILE" \
                --cert "$CERT_FILE" \
                --key "$KEY_FILE")
  local http_code=${apiResponse:0-3}
  #echo "Response code: $http_code"
  if [ "$http_code" != "200" ]; then
    log "fatal" "Failed get data from cdf-cluster-host"
    exit 1
  else
    BASE_CONFIGMAP=$(echo ${apiResponse:0:-3} |jq -r '.data')
  fi
}

getThisNode() {
    local first_node_fqdn=$(hostname -f | tr '[:upper:]' '[:lower:]')
    if [ ${#first_node_fqdn} -gt 63 ]; then
        THIS_NODE=$(getLocalIP)
    else
        THIS_NODE=$first_node_fqdn
        if [ -z "$(echo $THIS_NODE | grep -P '(?=^.{1,254}$)(^(?>(?!\d+\.)[a-zA-Z0-9\-]{1,63}\.?)+(?:[a-zA-Z0-9\-]{1,63})$)')" ]; then
            log "fatal" "Get unqualified FQDN:\"$THIS_NODE\" with command 'hostname -f' on current node."
        fi
    fi
}

validateIPv4Formate(){
  local node=$1;shift
  local result="false"
  if [[ $node =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      local old_ifs=$IFS
      IFS='.'
      local n=0
      for quad in ${node}
      do
          if [ "$quad" -gt 255 ]; then n=$((n+1)); fi
      done
      if [ $n -gt 0 ]; then
         result="false"
      else
         result="true"
      fi
      IFS=$old_ifs
  fi
  echo "$result"
}

validateFqdnIPFormat(){
  local node_list=$1
  local invalid_nodes=
  for node in ${node_list}
  do
      if [[ $node =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
          local result=$(validateIPv4Formate "$node")
          if [ "$result" = "false" ]; then
              invalid_nodes="${invalid_nodes}, $node"
          fi
      else
          if [ -z "$(echo $node | grep -P '(?=^.{1,254}$)(^(?>(?!\d+\.)[a-zA-Z0-9\-]{1,63}\.?)+(?:[a-zA-Z0-9\-]{1,63})$)')" ]; then
              invalid_nodes="${invalid_nodes}, $node"
          fi
      fi
  done
  invalid_nodes=${invalid_nodes:2}
  if [ ! -z "$invalid_nodes" ]; then
      log "fatal" "Invalid FQDN(s) or IP(s): ${invalid_nodes}"
  fi
}

initParametersForStandalone() {
    # THIS_NODE
    getThisNode
    NODE_TYPE=${NODE_TYPE:-"first"}
    MASTER_API_SSL_PORT=${MASTER_API_SSL_PORT:-"8443"}
    DEVICE_TYPE="overlayfs"
    CDF_HOME=${CDF_HOME:-"/opt/cdf"}
    RUNTIME_CDFDATA_HOME=${RUNTIME_CDFDATA_HOME:-"$CDF_HOME/data"}
    if [ "$NODE_TYPE" = "first" ]; then
        ###########################################################################
        # Bellow parametes get from CLI, need default value #
        ###########################################################################
        MASTER_API_SSL_PORT=${MASTER_API_SSL_PORT:-"8443"}
        FLANNEL_BACKEND_TYPE=${FLANNEL_BACKEND_TYPE:-"host-gw"}
        K8S_PROVIDER=${K8S_PROVIDER:-"cdf"}
        SERVICE_CIDR=${SERVICE_CIDR:-"172.17.17.0/24"}
        FAIL_SWAP_ON=${FAIL_SWAP_ON:-"true"}
        AUTO_CONFIGURE_FIREWALL=${AUTO_CONFIGURE_FIREWALL:-"true"}
        ENABLE_FIPS=${ENABLE_FIPS:-"false"}
        FIPS_ENTROPY_THRESHOLD=${FIPS_ENTROPY_THRESHOLD:-"2000"}

        # FLANNEL_IFACE
        FLANNEL_IFACE=${FLANNEL_IFACE}

        # K8S_MASTER_IP
        if [ -z "$HA_VIRTUAL_IP" ]; then
            if [ -z "$LOAD_BALANCER_HOST" ]; then
                K8S_MASTER_IP=${THIS_NODE}
            else
                K8S_MASTER_IP=$LOAD_BALANCER_HOST
            fi
        else
            K8S_MASTER_IP=$HA_VIRTUAL_IP
            validateFqdnIPFormat "$K8S_MASTER_IP"
        fi

        # POD_CIDR
        if [ -z "$POD_CIDR" ]; then
            POD_CIDR="172.16.0.0/16"
            if [ -z "$POD_CIDR_SUBNETLEN" ]; then
                POD_CIDR_SUBNETLEN=24
            fi
        else
            if [ -z "$POD_CIDR_SUBNETLEN" ]; then
                local podprefixlen=$(echo $POD_CIDR | awk -F/ '{print $NF}')
                if [[ "$podprefixlen" =~ [^0-9] ]]; then
                    echo "Error: invalid pod cidr prefix: $podprefixlen. It must be an integer greater than 0."
                    exit 1
                elif [ $podprefixlen -lt 22 ]; then
                    POD_CIDR_SUBNETLEN=24
                else
                    POD_CIDR_SUBNETLEN=$(($podprefixlen + 3))
                fi
            fi
        fi

        # DNS_SVC_IP
        local svcipaddress=$(echo $SERVICE_CIDR | awk -F/ '{print $1}')
        local svcprefixlen=$(echo $SERVICE_CIDR | awk -F/ '{print $NF}')
        local svcnetmask=$(cidr2mask $svcprefixlen)
        local svcnetworkaddress=$(getIpInSameSubnet $svcipaddress $svcnetmask)
        if [ $svcprefixlen -le 24 ]; then
            DNS_SVC_IP="$(echo $svcnetworkaddress | cut -d. -f1-3).78"
        else
            DNS_SVC_IP="$(echo $svcnetworkaddress | cut -d. -f1-3).$(($(echo $svcnetworkaddress | cut -d. -f4)+2))"
        fi
        # IPV6_CIDR
        IPV6_POD_CIDR=${IPV6_POD_CIDR:-"fd00:1234:5678::/64"}
        IPV6_POD_CIDR_SUBNETLEN=${IPV6_POD_CIDR_SUBNETLEN:-"80"}
        IPV6_SERVICE_CIDR=${IPV6_SERVICE_CIDR:-"fd00:1234:5678:1::/108"}
    else
        # master or worker node precheck
        if [ ! -z "$K8S_MASTER_IP" -a ! -z "$MASTER_API_SSL_PORT" -a ! -z "$CERT_FILE" -a ! -z "$KEY_FILE" -a ! -z "$CA_FILE" ]; then
            # get parameters from base-configmap
             # check jq command
            local res=$( which jq > /dev/null 2>& 1; echo $? )
            if [[ $res -ne 0 ]] ; then
                log "fatal" "Command jq is not found in the PATH: $PATH"
            fi

            getDataFromBaseConfigMap
            ###########################################################################
            # Bellow parametes get from base-configmap #
            ###########################################################################
            CDF_HOME=$(echo $BASE_CONFIGMAP |jq -r '.CDF_HOME')

            AUTO_CONFIGURE_FIREWALL=$(echo $BASE_CONFIGMAP |jq -r '.AUTO_CONFIGURE_FIREWALL')
            K8S_PROVIDER=$(echo $BASE_CONFIGMAP |jq -r '.K8S_PROVIDER')
            FLANNEL_IFACE=${FLANNEL_IFACE}
            HA_VIRTUAL_IP=$(echo $BASE_CONFIGMAP |jq -r '.HA_VIRTUAL_IP')
            POD_CIDR=$(echo $BASE_CONFIGMAP |jq -r '.POD_CIDR')
            POD_CIDR_SUBNETLEN=$(echo $BASE_CONFIGMAP |jq -r '.POD_CIDR_SUBNETLEN')
            SERVICE_CIDR=$(echo $BASE_CONFIGMAP |jq -r '.SERVICE_CIDR')
            FAIL_SWAP_ON=$(echo $BASE_CONFIGMAP |jq -r '.FAIL_SWAP_ON')
            FLANNEL_BACKEND_TYPE=$(echo $BASE_CONFIGMAP |jq -r '.FLANNEL_BACKEND_TYPE')
            TMP_FOLDER=$(echo $BASE_CONFIGMAP |jq -r '.TMP_FOLDER')
            RUNTIME_CDFDATA_HOME=$(echo $BASE_CONFIGMAP |jq -r '.RUNTIME_CDFDATA_HOME')
            NETWORK_ADDRESS=$(echo $BASE_CONFIGMAP |jq -r '.NETWORK_ADDRESS')
            ENABLE_FIPS=$(echo $BASE_CONFIGMAP |jq -r '.ENABLE_FIPS')
            FIPS_ENTROPY_THRESHOLD=$(echo $BASE_CONFIGMAP |jq -r '.FIPS_ENTROPY_THRESHOLD')
            IPV6_POD_CIDR=$(echo $BASE_CONFIGMAP |jq -r '.IPV6_POD_CIDR')
            IPV6_POD_CIDR_SUBNETLEN=$(echo $BASE_CONFIGMAP |jq -r '.IPV6_POD_CIDR_SUBNETLEN')
            IPV6_SERVICE_CIDR=$(echo $BASE_CONFIGMAP |jq -r '.IPV6_SERVICE_CIDR')
        fi
    fi
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

checkUser(){
    #check user
    local msg="Checking installation is running with root or sudo user"
    local errMsg="The install must run as root or sudo user."
    if [[ $EUID -ne 0 ]]; then
        log "failed" "$msg" "$errMsg"
    else
        log "pass" "$msg"
    fi
}

checkPort() {
    #Check if a port is in use
    local PORT_NO=$1
    local expectPro=$2
    local msg="Checking port ${PORT_NO}"
    local res=
    local process=
    local errMsg=

    res=`netstat -ntulp | grep LISTEN|grep ":${PORT_NO} "`
    if [ -z "$res"  ]; then
        log "pass" "$msg"
    else
        process=$(echo $res | awk '{print $7}')
        local pid=${process%%/*}
        if [ "$pid" = '-' ] || [[ ! "$pid" =~ ^[0-9]+$ ]]; then
            errMsg="Port $PORT_NO is used by a process (PID/Program name: ${pid}). Stop and disable or reconfigure the process that is using this port to use another port. If that is not possible then you will need to contact Support."
            log "failed" "$msg" "$errMsg"
        else
            local pname=$(ps -p "$pid" -o comm=)
            if [ -n "$expectPro" ] && [ "$pname" = "$expectPro" ]; then
                log "pass" "$msg" "" "Port $PORT_NO is used by process $expectPro."
            else
                errMsg="Port $PORT_NO is used by process ${pname} (PID: $pid). Stop and disable or reconfigure the process that is using this port to use another port. If that is not possible then you will need to contact Support."
                log "failed" "$msg" "$errMsg"
            fi
        fi
    fi
}

checkUnexpectedPkgs(){
    local pkgs="kubelet docker containerd"
    for pkg in $pkgs
    do
        local msg="Checking package $pkg"
        res=$(rpm -qa $pkg)
        if [ -n "$res" ]; then
            log "warning" "$msg" "Package $pkg has been installed which may conflict with OMT service. Please uninstall the package with dnf/yum. "
        fi
    done
}

checkPackage(){
    #Check if a package is installed
    local package=$1
    local expectVersion=$2
    local expectArch=${3:-"x86_64"}
    local mandatory=${4:-"true"}
    local pkg_purpose=$5
    local checkPkgRelease=${6:-"false"}
    local msg="Checking package ${package}"
    local res=`rpm -q --qf "%{NAME} %{ARCH}\n" $package | grep $expectArch | wc -l`
    if [ $res -eq 0 ] ; then
        if [[ "${mandatory}" = "true" ]]; then
            log "failed" "$msg" "Package $package is not installed. Please install the package with dnf/yum."
        else
            log "warning" "$msg" "Package $package is not installed. ${pkg_purpose}"
        fi
    else
        if [ -n "$expectVersion" ]; then
            if [ "$checkPkgRelease" = "true" ]; then
                local packVersion=$(rpm -q --qf "%{VERSION}-%{RELEASE}" $package)
            else
                local packVersion=$(rpm -q --qf "%{VERSION}" $package)
            fi
            local lowVersion=$(getLowVersion $packVersion $expectVersion)
            if [ "$lowVersion" = "$expectVersion" ] ; then
                log "pass" "$msg"
            else
                if [ "$package" = "fapolicyd" ]; then
                    log "failed" "$msg" "The $package service is actived, but the version of installed package $package is $packVersion; however the version must be equal to or greater than $expectVersion. Please upgrade the package or disable the $package service."
                else
                    log "failed" "$msg" "Version of installed package $package is $packVersion; the version must be equal to or greater than $expectVersion. Please upgrade the package."
                fi
            fi
        else
            log "pass" "$msg"
        fi
    fi
}

getLowVersion(){
    local v1=$1
    local v2=$2
    [ $(echo -e "$v1\n$v2"|sort -V|head -n -1) = "$v1" ] && echo "$v1" || echo "$v2"
}

checkCommand(){
    #Check if a command is installed
    local command=$1
    local expectedVersion=$2
    local package=$3
    local msg="Checking command ${command}"
    local res=$( which $command > /dev/null 2>& 1; echo $? )
    if [[ $res -ne 0 ]] ; then
        if [ "$command" = "conntrack" ]; then
            log "warning" "$msg" "Please run the tool \"node_prereq\" to fix any potential issues or dnf/yum install the $package package."
        else
            log "failed" "$msg" "Please run the tool \"node_prereq\" to fix any potential issues or dnf/yum install the $package package."
        fi
    else
        if [ "$command" = "curl" ]; then
            local actualVersion=$(rpm -q --qf "%{VERSION}" $command)
            local lowVersion=$(getLowVersion $expectedVersion $actualVersion)
            [ "$lowVersion" = "$expectedVersion" ] && CURL_HTTP="--http1.1"
            log "pass" "$msg"
        else
            log "pass" "$msg"
        fi
    fi
}

validateIPFormat(){
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local n=0
        for quad in ${ip//./ }
        do
            if [ "$quad" -gt 255 ]; then n=$((n+1)); fi
        done
        if [ $n -gt 0 ]; then
            return 1
        else
            return 0
        fi
    else
        return 1
    fi
}

cidr2mask() {
   [ $1 -gt 1 ] && shift $1 || shift
   echo ${1-0}.${2-0}.${3-0}.${4-0}
}

mask2cidr(){
   # Assumes there's no "255." after a non-255 byte in the mask
   local netmask=$1
   local sub_netmask=${netmask##*255.}
   local x='0^^^128^192^224^240^248^252^254^'
   local y=$(( (${#netmask} - ${#sub_netmask})*2 ))
   local z=${sub_netmask%%.*}
   local r=${x%%$z*}
   echo $(( $y + (${#r}/4) ))
}

getIpRange(){
    local ip=$1
    local len=$2
    local octets=(${ip//./ })
    local host=$((32-$len))
    local minIp=$((${octets[0]}*256*256*256 + ${octets[1]}*256*256 + ${octets[2]}*256 + ${octets[3]}))
    local maxIp=$(($minIp+(2**host)-1))
    echo $minIp $maxIp
}

validateIpv6(){
    local ipv6=$(echo "$1" | tr [:lower:] [:upper:])
    if [[ "$ipv6" =~ .*::.*::.*|::: ]]||[[ "$ipv6" =~ [^:0-9A-F] ]]||[ -z "$ipv6" ]; then
        return 1
    elif [[ "$ipv6" =~ ^::.|.::$ ]] && [ $(echo $ipv6 | awk -F: '{print NF}') -gt 9 ]; then
        return 1
    elif [[ "$ipv6" =~ .::. ]] && [ $(echo $ipv6 | awk -F: '{print NF}') -gt 8 ]; then
        return 1
    elif [[ ! "$ipv6" =~ :: ]] && [ $(echo $ipv6 | awk -F: '{print NF}') -gt 8 ]; then
        return 1
    else
        local n=0
        for col in $(echo $ipv6 | tr : ' ')
        do
            if [ ${#col} -gt 4 ]; then n=$((n + 1));fi
        done
        if [ "$n" -gt 0 ]; then
            return 1
        fi
    fi
    return 0
}

convert2FullIpv6(){
    local ipv6=$1
    if [ "$ipv6" = "::" ]; then
        echo "0:0:0:0:0:0:0:0"
    elif [[ "$ipv6" =~ ^::. ]]; then
        local colNum=$(echo $ipv6|awk -F: '{print NF - 2}')
        local missNum=$((8 - $colNum))
        local missCols=$(for((i=0;i<$missNum;i++));do echo -n "0:";done)
        echo $ipv6 | sed "s/::/$missCols/g"
    elif [[ "$ipv6" =~ .::$ ]]; then
        local colNum=$(echo $ipv6|awk -F: '{print NF - 2}')
        local missNum=$((8 - $colNum))
        local missCols=$(for((i=0;i<$missNum;i++));do echo -n ":0";done)
        echo $ipv6 | sed "s/::/$missCols/g"
    elif [[ "$ipv6" =~ .::. ]]; then
        local colNum=$(echo $ipv6|awk -F: '{print NF - 1}')
        local missNum=$((8 - $colNum))
        local missCols=$(for((i=0;i<$missNum;i++));do echo -n ":0";done)
        echo $ipv6 | sed "s/::/${missCols}:/g"
    else
        echo $ipv6
    fi
}

hex2bin(){
    local hex=$1
    #local bin=$(echo "ibase=16 ; obase=2 ; $hex" | bc)
    local bin=$(echo $hex | awk 'BEGIN {FS="";a["f"]="1111";a["e"]="1110";a["d"]="1101";a["c"]="1100";a["b"]="1011";a["a"]="1010";a["9"]="1001";a["8"]="1000";a["7"]="0111";a["6"]="0110";a["5"]="0101";a["4"]="0100";a["3"]="0011";a["2"]="0010";a["1"]="0001";a["0"]="0000"} {for(i=1;i<=NF;i++) printf a[tolower($i)]}')
    local missNum=$((16 - ${#bin}))
    local missBits=$(for((i=0;i<$missNum;i++));do echo -n "0";done)
    echo -n "${missBits}${bin}"
}

ipv6Hex2Bin(){
    local ipv6Hex=$1
    for col in $(echo $ipv6Hex | tr : ' ');do
        hex2bin $col
    done
}

checkCIDR(){
    OLD_IFS=$IFS
    IFS=/
    read podIPAddress podPrefixLen <<<"$POD_CIDR"
    read svcIPAddress svcPrefixLen <<<"$SERVICE_CIDR"

    IFS=$OLD_IFS
    local podNetMask=$(cidr2mask $(( 5 - ($podPrefixLen / 8) )) 255 255 255 255 $(( (255 << (8 - ($podPrefixLen % 8))) & 255 )) 0 0 0)
    local podNetAddress=$(getIpInSameSubnet $podIPAddress $podNetMask)
    local podIpRange=($(getIpRange $podNetAddress $podPrefixLen))
    local svcNetMask=$(cidr2mask $(( 5 - ($svcPrefixLen / 8) )) 255 255 255 255 $(( (255 << (8 - ($svcPrefixLen % 8))) & 255 )) 0 0 0)
    local svcNetAddress=$(getIpInSameSubnet $svcIPAddress $svcNetMask)
    local svcIpRange=($(getIpRange $svcNetAddress $svcPrefixLen))

    local hostIp=$(getLocalIP)
    [ -z "$hostIp" ] && log "fatal" "Failed to get local IP of current node."
    local hostNetMask=$(ifconfig|grep ${hostIp}|awk '{print $4}')
    local hostCidr=$(mask2cidr $hostNetMask)
    local hostNetAddress=$(getIpInSameSubnet $hostIp $hostNetMask)
    local hostIpRange=($(getIpRange $hostNetAddress $hostCidr))

    local msg="Checking parameter POD_CIDR"
    if [ $(validateIPFormat "$podIPAddress"; echo $?) -eq 0 ]; then
        if [[ "$podPrefixLen" =~ [^0-9] ]]; then
            log "failed" "$msg" "The pod network prefix $podPrefixLen is invalid, it must be an integer greater than 0."
            return
        elif [ $podPrefixLen -gt 24 ]; then
            log "failed" "$msg" "The pod network prefix $podPrefixLen is too large. Allowed prefix is from /8 to /24."
        elif [ $podPrefixLen -lt 8 ]; then
            log "failed" "$msg" "The pod network prefix $podPrefixLen is too small. Allowed prefix is from /8 to /24."
        else
            log "pass" "$msg"
        fi
    else
        log "failed" "$msg" "The $POD_CIDR value for the Pod network is invalid. Please specify a valid value such as 172.16.0.0/16."
    fi

    msg="Checking parameter POD_CIDR_SUBNETLEN"
    if [ $POD_CIDR_SUBNETLEN -gt 27 ]; then
        log "failed" "$msg" "The value of the Pod network subnet length must be less than /28. Allowed value is from /(POD_CIDR prefix + 3) to /27."
    elif [ $POD_CIDR_SUBNETLEN -lt $(($podPrefixLen + 3)) -o $POD_CIDR_SUBNETLEN -gt $(($podPrefixLen + 16)) ]; then
        log "failed" "$msg" "The value of the Pod network subnet length must be greater or equal to POD_CIDR prefix + 3 and less than POD_CIDR prefix + 16. Allowed value is from /(POD_CIDR prefix + 3) to /27."
    elif [[ $POD_CIDR_SUBNETLEN -ge 26 ]]; then
        log "warning" "$msg" "The current Pod CIDR settings POD_CIDR: $POD_CIDR and POD_CIDR_SUBNETLEN: $POD_CIDR_SUBNETLEN do not provide enough IP addresses to support the fixed default Kubernetes pods-per-node capacity of 110. This may result in failures to assign Pod IP addresses and subsequently failed OMT installations and application deployments. You must decrease the prefix length for POD_CIDR or decrease POD_CIDR_SUBNETLEN to allow for more IP addresses per cluster node."
    else
        log "pass" "$msg"
    fi

    msg="Checking parameter SERVICE_CIDR"
    if [ $(validateIPFormat "$svcIPAddress"; echo $?) -eq 0 ]; then
        if [[ "$svcPrefixLen" =~ [^0-9] ]]; then
            log "failed" "$msg" "The K8s service network prefix $svcPrefixLen is invalid, it must be an integer greater than 0."
            return
        elif [ $svcPrefixLen -gt 27 ]; then
            log "failed" "$msg" "The K8s service network prefix $svcPrefixLen is too large. Allowed prefix is /12 to /27."
        elif [ $svcPrefixLen -lt 12 ]; then
            log "failed" "$msg" "The K8s service network prefix $svcPrefixLen is too small. Allowed prefix is /12 to /27."
        else
            log "pass" "$msg"
        fi
    else
        log "failed" "$msg" "The $SERVICE_CIDR value for the K8s service network is invalid. Please specify a valid value. such as 172.17.0.0/16"
    fi

    msg="Checking range overlap of POD_CIDR and SERVICE_CIDR"
    if [ "${podIpRange[1]}" -lt "${svcIpRange[0]}" -o "${svcIpRange[1]}" -lt "${podIpRange[0]}" ]; then
        log "pass" "$msg"
    else
        log "failed" "$msg" "The ranges for POD_CIDR '$POD_CIDR' and SERVICE_CIDR '$SERVICE_CIDR' overlap."
    fi

    msg="Checking range overlap of POD_CIDR and host network"
    if [ "${podIpRange[1]}" -lt "${hostIpRange[0]}" -o "${hostIpRange[1]}" -lt "${podIpRange[0]}" ]; then
        log "pass" "$msg"
    else
        log "failed" "$msg" "The ranges for POD_CIDR '$POD_CIDR' and host network '$hostIp/$hostCidr' overlap. Configure the value of POD_CIDR with --pod-cidr CLI option or in install.properties file POD_CIDR setting or change the host IP configuration."
    fi
    # check ipv6 range overlap
    checkIpv6RangeOverlap
}

checkIpv6RangeOverlap(){
    #check overlap for ipv6
    if [ "$ENABLE_IPV6" = "true" -a -n "$IPV6_POD_CIDR" -a -n "$IPV6_SERVICE_CIDR" ]; then
        OLD_IFS=$IFS
        IFS=/
        read podIPv6Address podIpv6PrefixLen <<<"$IPV6_POD_CIDR"
        read svcIPv6Address svcIpv6PrefixLen <<<"$IPV6_SERVICE_CIDR"
        IFS=$OLD_IFS

        local msg="Checking parameter IPV6_POD_CIDR"
        if validateIpv6 $podIPv6Address; then
            if [[ "$podIpv6PrefixLen" =~ [^0-9] ]]; then
                log "failed" "$msg" "IPV6_POD_CIDR=$IPV6_POD_CIDR. The pod network prefix must be an integer greater than 0."
                return
            elif [ "$podIpv6PrefixLen" -gt 120 ]; then
                log "failed" "$msg" "IPV6_POD_CIDR=$IPV6_POD_CIDR. The pod network is too small. The minimum useful network prefix is /120"
            elif [ $podIpv6PrefixLen -lt 8 ]; then
                log "failed" "$msg" "IPV6_POD_CIDR=$IPV6_POD_CIDR. The pod network is too large. The maximum useful network prefix is /8"
            else
                log "pass" "$msg"
            fi
        else
            log "failed" "$msg" "The '$IPV6_POD_CIDR' value for the Pod network is invalid. Please specify a valid value."
            return
        fi

        #The subnet mask size (pod-cidr-subnetlen) cannot be greater than 16 more than the cluster mask size (pod-cidr prefix)
        #https://github.com/kubernetes/kubernetes/blob/master/pkg/controller/nodeipam/ipam/cidrset/cidr_set.go
        msg="Checking parameter IPV6_POD_CIDR_SUBNETLEN"
        if [ $IPV6_POD_CIDR_SUBNETLEN -gt 123 ]; then
            log "failed" "$msg" "IPV6_POD_CIDR_SUBNETLEN=$IPV6_POD_CIDR_SUBNETLEN. The value of the Pod network subnet length must be less than /124"
        elif [ $IPV6_POD_CIDR_SUBNETLEN -lt $(($podIpv6PrefixLen + 3)) -o  $IPV6_POD_CIDR_SUBNETLEN -gt $(($podIpv6PrefixLen + 16)) ]; then
            log "failed" "$msg" "IPV6_POD_CIDR_SUBNETLEN=$IPV6_POD_CIDR_SUBNETLEN; IPV6_POD_CIDR=$IPV6_POD_CIDR. The value for the Pod network subnet length must be greater or equal to IPV6_POD_CIDR prefix + 3 and less than IPV6_POD_CIDR prefix + 16"
        elif [[ $IPV6_POD_CIDR_SUBNETLEN -ge 122 ]]; then
            log "warning" "$msg" "The current Pod CIDR settings IPV6_POD_CIDR: $IPV6_POD_CIDR and IPV6_POD_CIDR_SUBNETLEN: $IPV6_POD_CIDR_SUBNETLEN do not provide enough IP addresses to support the fixed default Kubernetes pods-per-node capacity of 110. This may result in failures to assign Pod IP addresses and subsequently failed OMT installations and application deployments. You must decrease the prefix length for IPV6_POD_CIDR or decrease IPv6_POD_CIDR_SUBNETLEN to allow for more IP addresses per cluster node."
        else
            log "pass" "$msg"
        fi

        msg="Checking parameter IPV6_SERVICE_CIDR"
        if validateIpv6 $svcIPv6Address; then
            if [[ "$svcIpv6PrefixLen" =~ [^0-9] ]]; then
                log "failed" "$msg" "IPV6_SERVICE_CIDR=$IPV6_SERVICE_CIDR.The service network prefix must be an integer greater than 0."
                return
            elif [ $svcIpv6PrefixLen -gt 123 ]; then
                log "failed" "$msg" "IPV6_SERVICE_CIDR=$IPV6_SERVICE_CIDR. The K8s service network is too small. The minimum useful network prefix is /123"
            #The max service cidr size is 20; means service cidr prefix must be >= 108
            #https://github.com/kubernetes/kubernetes/blob/master/cmd/kube-apiserver/app/options/validation.go
            elif [ $svcIpv6PrefixLen -lt 108 ]; then
                log "failed" "$msg" "IPV6_SERVICE_CIDR=$IPV6_SERVICE_CIDR. The K8s service network is too large. The maximum useful network prefix is /108"
            else
                log "pass" "$msg"
            fi
        else
            log "failed" "$msg" "The $IPV6_SERVICE_CIDR value for the K8s service network is invalid. Please specify a valid value."
            return
        fi

        msg="Checking range overlap of IPV6_POD_CIDR and IPV6_SERVICE_CIDR"
        if [ $podIpv6PrefixLen -le $svcIpv6PrefixLen ]; then
            local len=$podIpv6PrefixLen
        else
            local len=$svcIpv6PrefixLen
        fi
        local fullPodIPv6AddressBin=$(ipv6Hex2Bin $(convert2FullIpv6 $podIPv6Address))
        local fullSvcIPv6AddressBin=$(ipv6Hex2Bin $(convert2FullIpv6 $svcIPv6Address))
        if [ "${fullPodIPv6AddressBin:0:$len}" != "${fullSvcIPv6AddressBin:0:$len}" ]; then
            log "pass" "$msg"
        else
            log "failed" "$msg" "The ranges for IPv6_POD_CIDR '$IPV6_POD_CIDR' and IPV6_SERVICE_CIDR '$IPV6_SERVICE_CIDR' overlap."
        fi

        msg="Checking range overlap of IPV6_POD_CIDR and host ipv6 network"
        #may have multiple ipv6 addresses on interface; need check all ipv6s
        local localIpv6s=$(ip -6 a show $INTERFACE_NAME scope global | sed -n 's/^.*inet6 \([^ ]*\).*$/\1/p')
        for localIpv6 in $localIpv6s
        do
            OLD_IFS=$IFS
            IFS=/
            read localIPv6Address localIpv6PrefixLen <<<"$localIpv6"
            IFS=$OLD_IFS

            if [ $podIpv6PrefixLen -le $localIpv6PrefixLen ]; then
                len=$podIpv6PrefixLen
            else
                len=$localIpv6PrefixLen
            fi
            fullPodIPv6AddressBin=$(ipv6Hex2Bin $(convert2FullIpv6 $podIPv6Address))
            fullLocalIPv6AddressBin=$(ipv6Hex2Bin $(convert2FullIpv6 $localIPv6Address))
            if [ "${fullPodIPv6AddressBin:0:$len}" != "${fullLocalIPv6AddressBin:0:$len}" ]; then
                log "pass" "$msg"
            else
                log "failed" "$msg" "The ranges for IPV6_POD_CIDR '$IPV6_POD_CIDR' and host network '$localIpv6' overlap. Configure the value of IPV6_POD_CIDR with --ipv6-pod-cidr CLI option or in install.properties file IPV6_POD_CIDR setting or change the host IPv6 configuration."
            fi
        done
    fi
}

verifyProperties(){
    #check parameters in properties file
    if [ "$NODE_TYPE" = "first" ] ; then
        checkCIDR
    fi
    if [ "$NODE_TYPE" != "first" ] ; then
        checkFileExists CA_FILE
        checkFileExists CERT_FILE
        checkFileExists KEY_FILE
    fi
}

checkFileExists() {
    PARAM=$1
    PARAM_VALUE=$(eval "echo \$$PARAM")
    local msg="Checking parameter $PARAM"
    if [[ -z $PARAM_VALUE ]]; then
        log "skip" "$msg"
    elif [[ ! -f $PARAM_VALUE ]];then
        log "failed" "$msg" "File $PARAM_VALUE is not found. Please contact OpenText support."
    else
        log "pass" "$msg"
    fi
}

checkFolderIsEmpty(){
    local mandatory=$2
    PARAM_VALUE=$1
    PARAM=$(eval "echo \$$PARAM_VALUE")
    local msg="Checking folder ${PARAM_VALUE} '${PARAM}' is empty"
    if [ "$PARAM" = "/" ]; then
        log "failed" "$msg" "${PARAM_VALUE} cannot be the root directory '/'"
        return
    fi
    if [[ -z "$PARAM" ]];then
        log "skip" "$msg"
    elif [[ -e ${PARAM} ]]; then
        if [[ -d ${PARAM} ]]; then
            if [[ "$(ls -A ${PARAM})" ]]; then
                if [ ${mandatory} ]; then
                    log "failed" "$msg" "The folder $PARAM must be empty for the install to continue."
                else
                    log "warning" "$msg" "Folder $PARAM is not empty."
                fi
            else
                log "pass" "$msg"
            fi
        else
            log "failed" "$msg" "$PARAM is not a folder. Please specify a folder."
        fi
    else
        log "pass" "$msg"
    fi
}

checkTmpFolderPermission(){
    local msg="Checking the permission of temporary folder ${TMP_FOLDER}"
    local mountedTmpFolder=
    mountedTmpFolder=$(cat /etc/fstab | grep -vE '^#|^$' | awk '{print $2}' | grep -n "^${TMP_FOLDER}$")
    if [ -n "$mountedTmpFolder" ]; then
        local lineNum=${mountedTmpFolder%%:*}
        local configuredOptions=$(cat /etc/fstab | grep -vE '^#|^$' | awk '{print $4}' | sed -n "${lineNum}p")
        local notAllowedOptions=("noexec" "ro" "nosuid" "user")
        local hasNotAllowedOption=false
        for option in ${configuredOptions//,/ }
        do
            for notAllowedOption in ${notAllowedOptions[*]}
            do
                if [ "$notAllowedOption" = "$option" ]; then
                    hasNotAllowedOption=true
                    break
                fi
            done
            if [ "$hasNotAllowedOption" = "true" ]; then
                break
            fi
        done
        if [ "$hasNotAllowedOption" = "true" ]; then
            log "failed" "$msg" "The installation requires execute and write permissions under temporary folder $TMP_FOLDER. The mount options of this folder are \"${configuredOptions}\", those options may block the installation."
        else
            log "pass" "$msg"
        fi
    else
        log "pass" "$msg"
    fi
}

checkK8sHome() {
    #Checking if the core platform is already installed on this host
    local msg="Checking CDF_HOME"
    if [ ${CDF_HOME} = "/" ]; then
        log "failed" "$msg" "CDF_HOME cannot be the root directory '/'"
        return
    fi
    # CDF_HOME cannot be a symbolic link
    if [ -d "$CDF_HOME" ]; then
        local format=$(stat -c%F $CDF_HOME 2>/dev/null|tr [[:upper:]] [[:lower:]])
        if [[ "$format" =~ "symbolic link" ]]; then
            log "failed" "$msg" "$CDF_HOME is a symbolic link, kubernetes infrastructure cannot be installed under symbolic link directory."
            return
        fi
    fi

    if [[ -e ${CDF_HOME} ]]; then
        if [[ -d ${CDF_HOME} ]]; then
            if [[ "$(ls -A ${CDF_HOME})" ]]; then
                if [[ ${RUNTIME_CDFDATA_HOME} =~ ^$(readlink -m ${CDF_HOME})/.* ]]; then
                    local runtime_dir=${RUNTIME_CDFDATA_HOME}
                    while [[ ${runtime_dir} != $(readlink -m ${CDF_HOME}) ]]; do
                        if [[ -e ${runtime_dir} && $(ls -A $(dirname ${runtime_dir})) != $(basename ${runtime_dir}) ]]; then
                            log "warning" "$msg" "$(dirname ${runtime_dir}) is not empty. Either clean this folder manually or explicitly skip the warning and then the installer will clean this folder."
                            return
                        fi
                        runtime_dir=$(dirname ${runtime_dir})
                    done
                    log "pass" "$msg"
                else
                    log "warning" "$msg" "Folder ${CDF_HOME} is not empty. Either clean this folder manually or explicitly skip the warning and then the installer will clean this folder."
                fi
            else
                log "pass" "$msg"
            fi
        else
            log "failed" "$msg" "${CDF_HOME} is not a folder. Please specify a folder."
        fi
    else
        log "pass" "$msg"
    fi
}

cleanK8sHome() {
    # skip removing directory in standalone mode
    if [ "$STANDALONE_FLAG" = "true" ]; then
        return 0
    fi
    rm -rf ${RUNTIME_CDFDATA_HOME}/* || return 1
    if [[ ${RUNTIME_CDFDATA_HOME} =~ ^$(readlink -m ${CDF_HOME})/.* ]]; then
        local runtime_dir=${RUNTIME_CDFDATA_HOME}
        while [[ ${runtime_dir} != $(readlink -m ${CDF_HOME}) ]]; do
            local exception=$(basename ${runtime_dir})
            runtime_dir=$(dirname ${runtime_dir})
            for item in $([[ -e ${runtime_dir} ]] && ls -A ${runtime_dir}); do
                if [[ ${item} != ${exception} ]]; then
                    rm -rf "${runtime_dir}/${item}" || return 1
                fi
            done
        done
    else
        rm -rf ${CDF_HOME}/* || return 1
    fi
}

getDropChains(){
    local dropChains
    chains=(INPUT FORWARD OUTPUT)
    for chain in ${chains[*]}
    do
        policy=$(iptables -S 2>/dev/null | grep -- "-P $chain" | awk '{print $3}')
        if [ "$policy" = "DROP" ]; then
            [ -z "$dropChains" ] && dropChains="$chain" || dropChains="$dropChains, $chain"
        fi
    done
    echo $dropChains
}

checkFireWalld(){
    #check if firewalld is disabled
    local msg="Checking firewall and iptables status"
    local comment=
    local warnMsg=
    local dropChains="$(getDropChains)"
    if [ -n "$dropChains" ]; then
        log "warning" "$msg" "In the iptables filter table the default policy of chain(s):$dropChains is DROP; refer to the installation documentation and setup the network settings manually otherwise the installation may fail."
    elif [ $(systemctl status firewalld > /dev/null 2>&1; echo $?) -eq 0 ]; then
        if [ "$NODE_TYPE" = "first" ]; then
            if [ "$AUTO_CONFIGURE_FIREWALL" = "true" ]; then
                comment="The firewalld service is enabled on this node. The required firewall settings will be configured automatically during the node deployment. You can disable the firewall auto configuration by setting the value of 'AUTO_CONFIGURE_FIREWALL' to 'false' but then you must configure firewalld manually and open the required ports."
            else
                warnMsg="The firewalld service is enabled on this node. Refer to the installation guide to configure firewalld settings manually or set AUTO_CONFIGURE_FIREWALL to true."
            fi
        else
            if [ "$AUTO_CONFIGURE_FIREWALL" = "true" ]; then
                comment="The firewalld service is enabled on this node. The required firewall settings will be configured automatically during the node deployment."
            else
                warnMsg="The firewalld service is enabled on this node. Refer to the installation guide to configure firewalld settings manually."
            fi
        fi
        if [ -n "$comment" ];then
            log "pass" "$msg" "" "$comment"
        else
            log "warning" "$msg" "$warnMsg"
        fi
    else
        log "disabled" "$msg"
    fi
}

checkFirewallSettings(){
    # check firewall settings when service is enabled and auto-config-firewall is enabled
    local msg="Checking firewall settings"
    local failFwCheck=false
    if [ $(systemctl status firewalld >/dev/null 2>&1; echo $?) -eq 0 -a "$AUTO_CONFIGURE_FIREWALL" = "true" ]; then
        # check opened ports
        if [ "$NODE_TYPE" != "worker" ]; then
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
        else
            local requiredPorts="5444/tcp
                                 8472/udp
                                 10248/tcp
                                 10249/tcp
                                 10250/tcp
                                 10256/tcp"
        fi
        local openPorts=$(firewall-cmd --list-ports 2>/dev/null)
        local missedPorts=
        for port in $requiredPorts
        do
            if [[ "$openPorts" =~ "$port" ]]; then
                continue
            else
                missedPorts="$missedPorts $port"
            fi
        done
        if [ -n "$missedPorts" ];then
            failFwCheck=true
            log "failed" "$msg" "Ports $missedPorts are not opened in firewalld. Please run command 'firewall-cmd --permanent --add-port=<port>; firewall-cmd --add-port=<port>' for each port one by one to open the ports."
        fi
        # check added rules
        local addedRules=$(firewall-cmd --get-all-rules --direct 2>/dev/null)
        #ipv4 nat POSTROUTING 1 -s 172.16.0.0/16 '!' -d 172.16.0.0/16 -j MASQUERADE
        if [ $(echo "$addedRules" | grep -E "ipv4.*nat.*POSTROUTING.*$POD_CIDR.*MASQUERADE" | wc -l) -lt 1 ]; then
            failFwCheck=true
            log "failed" "$msg" "Not found the firewall rule for POD_CIDR in nat table POSTROUTING chain. Please run command 'firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 1 -s $POD_CIDR ! -d $POD_CIDR -j MASQUERADE; firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 1 -s $POD_CIDR ! -d $POD_CIDR -j MASQUERADE' to add the rule."
        fi
        #ipv4 filter FORWARD 1 -o cni0 -j ACCEPT -m comment --comment 'flannel subnet'
        if [ $(echo "$addedRules" | grep "ipv4.*filter.*FORWARD.*cni0.*ACCEPT" | wc -l) -lt 2 ]; then
            failFwCheck=true
            log "failed" "$msg" "Not found the firewall rules for cni0 interface in filter table FORWARD chain. Please run command 'firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 1 -o cni0 -j ACCEPT -m comment --comment 'flannel subnet'; firewall-cmd --direct --add-rule ipv4 filter FORWARD 1 -o cni0 -j ACCEPT -m comment --comment 'flannel subnet'; firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 1 -i cni0 -j ACCEPT -m comment --comment 'flannel subnet'; firewall-cmd --direct --add-rule ipv4 filter FORWARD 1 -i cni0 -j ACCEPT -m comment --comment 'flannel subnet'' to add the rules."
        fi
        # check forward and interface in default zone
        local interface="cni0"
        local minVersion="0.9.0"
        local firewallVersion=$(firewall-cmd --version)
        if $(echo -e "$minVersion\n$firewallVersion" | sort -V -C); then
            # check forward
            local forward=$(firewall-cmd --query-forward)
            if [ "$forward" != "yes" ]; then
                failFwCheck=true
                log "failed" "$msg" "Forwarding of packets between interfaces are not enabled. Please run command 'firewall-cmd --permanent --add-forward; firewall-cmd --add-forward' to enable the forward."
            fi
            # check interface
            local inter=$(firewall-cmd --query-interface=$interface)
            if [ "$inter" != "yes" ]; then
                failFwCheck=true
                log  "failed" "$msg" "Interface $interface is not in default zone. Please run command 'firewall-cmd --permanent --add-interface=$interface; firewall-cmd --add-interface=$interface' to add cni0 into default zone."
            fi
        fi
        if [ "$failFwCheck" = "false" ];then
            log "pass" "$msg"
        fi
    else
        log "skip" "$msg" "Skip firewall settings check because the firewalld service is not enabled or AUTO_CONFIGURE_FIREWALL is not set to ture."
    fi
}

checkAllPorts(){
    # check below ports on master nodes
    if [ "$NODE_TYPE" != "worker" ] ; then
        checkPort 2380 #etcd
        checkPort 4001 #etcd
        checkPort $MASTER_API_SSL_PORT #k8s-apiserver
        checkPort 10257 #kube-controll
        checkPort 10259 #kube-schedule
    fi
    # check below ports on all nodes
    checkPort 3000  #frontend
    checkPort 5000  #local-registry
    checkPort $EXTERNAL_ACCESS_PORT  #mng-portal
    checkPort 5444  #mng-portal
    checkPort 10248 #kubelet
    checkPort 10249 #metric-server
    checkPort 10250 #kubelet
    checkPort 10256 #kube-proxy

    [ "$FLANNEL_BACKEND_TYPE" = "vxlan" ] && checkPort 8472
}

checkAllPortsOnInstalledNode(){
    # check below ports on master nodes
    if [ "$NODE_TYPE" != "worker" ] ; then
        checkPort 2380 "etcd"
        checkPort 4001 "etcd"
        checkPort "$MASTER_API_SSL_PORT" "kube-apiserver"
        checkPort 10257 "kube-controller"
        checkPort 10259 "kube-scheduler"
    fi
    # check below ports on all nodes
    checkPort 3000  #frontend
    checkPort 5000  #local-registry
    checkPort $EXTERNAL_ACCESS_PORT  #mng-portal
    checkPort 5444  #mng-portal
    checkPort 10248 "kubelet"
    checkPort 10250 "kubelet"
    checkPort 10249 "kube-proxy"
    checkPort 10256 "kube-proxy"

    [ "$FLANNEL_BACKEND_TYPE" = "vxlan" ] && checkPort 8472
}

checkAllCommands(){
    checkCommand showmount "" "nfs-utils"
    checkCommand curl 7.47.0 "curl"
    checkCommand unzip "" "unzip"
    checkCommand conntrack "" "conntrack-tools"
    if [ "$SELINUX_MODE" = "Enforcing" ]; then
        checkCommand checkmodule "" "checkpolicy"
        checkCommand semodule_package "" "policycoreutils"
        checkCommand semodule "" "policycoreutils"
    fi
}

checkAllPackages(){
    checkPackage device-mapper-libs 1.02.97
    checkPackage libgcrypt
    #check libseccomp 2.5.1 on 8.x or higher OS version and 2.3.1-4 on other OS version
    #if [[ $(cat /etc/system-release) =~ Oracle|CentOS|"Red Hat Enterprise" ]]; then
    #    local osVersion=$(cat /etc/system-release | sed -n 's/.* \([0-9][^ ]*\).*$/\1/p')
    #    [ $(getLowVersion $osVersion "8.0") = "8.0" ] && local pkVersion="2.5.1" ||  local pkVersion="2.3.1-4.el7"
    #    checkPackage libseccomp $pkVersion "" "" "" true
    #fi
    checkPackage libtool-ltdl
    checkPackage nfs-utils
    checkPackage systemd-libs 219
    checkPackage container-selinux 2.74 noarch
    checkPackage net-tools
    checkPackage bash-completion "" noarch false "Can not enable auto-completion of kubectl later."
    checkPackage socat
    checkPackage tar
    local osMainVersion=$(cat /etc/system-release | sed -n 's/.* \([0-9][^ ]*\).*$/\1/p'|cut -d. -f1)
    if [ "$osMainVersion" -ge "9" ]; then
        checkPackage iptables-nft
    else
        checkPackage iptables
    fi
    # check fapolicyd package version if the service is up
    local serviceName="fapolicyd"
    local serviceStatus=$(systemctl is-active $serviceName | tr [:upper:] [:lower:])
    if [ "$serviceStatus" = "active" ]; then
        checkPackage $serviceName 1.0
    fi
}

checkMem() {
    local local_mem=$(free --si -k|grep "^Mem:"|awk '{printf "%.2f", $2/1000/1000}')
    local msg="Checking required memory ${NODE_MEM} GB"
    if [ $(echo "$local_mem $NODE_MEM"|awk '{print $1<$2}') = 1 ]
    then
        log "failed" "$msg" "This node only has $local_mem GB of RAM. Check the hardware requirements and add more RAM."
    else
        log "pass" "$msg"
    fi
}

checkCPU() {
    local local_cpu=$(cat /proc/cpuinfo| grep "processor"| uniq| wc -l)
    local msg="Checking required CPU number ${NODE_CPU}"
    if [ $local_cpu -lt $NODE_CPU ]
    then
        log "failed" "$msg" "This node only has $local_cpu CPUs. Check the hardware requirements and add more CPUs."
    else
        log "pass" "$msg"
    fi

}

shoud_exist_cpu_flags(){
    local check_flags="$1"
    local check_flags_num="$(echo "$check_flags"|awk '{print NF}')"
    local all_flags="$(cat /proc/cpuinfo 2>/dev/null|grep flags|head -n 1|cut -d: -f2|xargs)"
    local exp=$(echo "$check_flags"|xargs|sed 's/ /|/g')
    local actual_flags_num="$(echo "$all_flags"|xargs -n1|grep -P "^($exp)\$"|wc -l)"
    if [[ "$actual_flags_num" == "$check_flags_num" ]];then
        return 0
    else
        return 1
    fi
}

check_x86_64_level(){
    local msg="Checking required CPU supports x86-64-v2"

    # x86-64-v0
    local level=0

    while true;do
        # x86-64-v1
        # if shoud_exist_cpu_flags 'lm cmov cx8 fpu fxsr mmx syscall sse2';then
        #     level=1
        # else
        #     break
        # fi

        # x86-64-v2
        if shoud_exist_cpu_flags 'cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3';then
            level=2
        else
            break
        fi

        # x86-64-v3
        if shoud_exist_cpu_flags 'avx avx2 bmi1 bmi2 f16c fma abm movbe xsave';then
            level=3
        else
            break
        fi

        # x86-64-v4
        if shoud_exist_cpu_flags 'avx512f avx512bw avx512cd avx512dq avx512vl';then
            level=4
        else
            break
        fi

        break
    done

    if [[ "$level" -lt 2 ]];then
        log "failed" "$msg" "This CPU only supports x86-64-v${level}. Check the hardware requirements."
    else
        log "pass" "$msg"
    fi
}

checkDisk() {
    if [ "$1" = 'CDF' ]; then
        if [ "$NODE_TYPE" = "first" -a -n "$NFS_DIR" ]; then
            #When nfs server is located on first node and using local registry,
            #require additional 12GB free space for nfs server.
            #12GB is the minimal free disk requirement of nfs server for bosun
            #mode installation with local registry; it may need to adjust
            #depending on the release.
            local NFS_DISK=12
            local nfs_mount_on=$(df $NFS_DIR |sed '1d'|awk '{print $6}')
        fi
        local k8shome_basedir=$(getVaildDir $CDF_HOME)
        local k8shome_arr=($(df -mP $k8shome_basedir |sed '1d'|awk '{print $6; printf "%.2f", $4/1024}'))
        local runtimehome_basedir=$(getVaildDir $RUNTIME_CDFDATA_HOME)
        local runtimehome_arr=($(df -mP $runtimehome_basedir |sed '1d'|awk '{print $6; printf "%.2f", $4/1024; print "", $3, $2}'))
        local total_required_disk
        if [ "${k8shome_arr[0]}" = "${runtimehome_arr[0]}" ]; then #CDF_HOME and RUNTIME_CDFDATA_HOME are same mount point
            if [ "${k8shome_arr[0]}" = "$nfs_mount_on" ]; then #nfs server mount point is same as CDF_HOME
                total_required_disk=$(( NODE_DISK + STATIC_DISK + NFS_DISK ))
            else
                total_required_disk=$(( NODE_DISK + STATIC_DISK ))
            fi
            local msg="Checking required free space ${total_required_disk} GB under $CDF_HOME"
            if [ -z "$CDF_HOME" ];then
                log "skip" "Checking required free space ${total_required_disk} GB under CDF_HOME"
            elif [ $(echo "${k8shome_arr[1]} ${total_required_disk}"|awk '{print $1<$2}') = 1 ]; then
                log "failed" "$msg" "$CDF_HOME only has ${k8shome_arr[1]} GB free disk space. Check the hardware requirements and add more disk space."
            else
                log "pass" "$msg"
            fi
        else
            if [ "${runtimehome_arr[0]}" = "$nfs_mount_on" ]; then #nfs server mount point is same as RUNTIME_CDFDATA_HOME
                total_required_disk=$(( NODE_DISK + NFS_DISK ))
            else
                total_required_disk=${NODE_DISK}
            fi
            local msg="Checking required free space ${STATIC_DISK} GB under $CDF_HOME"
            if [ -z "$CDF_HOME" ];then
                log "skip" "Checking required free space ${STATIC_DISK} GB under CDF_HOME"
            elif [ $(echo "${k8shome_arr[1]} ${STATIC_DISK}"|awk '{print $1<$2}') = 1 ]; then
                log "failed" "$msg" "$CDF_HOME only has ${k8shome_arr[1]} GB free disk space. Check the hardware requirements and add more disk space."
            else
                log "pass" "$msg"
            fi
            msg="Checking required free space ${total_required_disk} GB under $RUNTIME_CDFDATA_HOME"
            if [ -z "$RUNTIME_CDFDATA_HOME" ];then
                log "skip" "Checking required free space ${total_required_disk} GB under RUNTIME_CDFDATA_HOME"
            elif [ $(echo "${runtimehome_arr[1]} ${total_required_disk}"|awk '{print $1<$2}') = 1 ]; then
                log "failed" "$msg" "$RUNTIME_CDFDATA_HOME only has ${runtimehome_arr[1]} GB free disk space. Check the hardware requirements and add more disk space."
            else
                log "pass" "$msg"
            fi
        fi
        local total_runtime_disk=$(( runtimehome_arr[3] / 1024 ))
        local imageGcThreshold=80
        if [ "$total_runtime_disk" -ge 100 ]; then
            imageGcThreshold=$(echo $total_runtime_disk | awk '{printf "%.f", (1-20/$1)*100}')
        fi
        local used_runtime_disk=$(( runtimehome_arr[2] / 1024 ))
        if [  $(echo $((total_required_disk + used_runtime_disk))  $total_runtime_disk | awk '{printf "%.f", ($1/$2)*100}' ) -ge $imageGcThreshold ]; then
            local most_used_disk=$(echo $imageGcThreshold $total_runtime_disk $total_required_disk | awk '{printf "%.f", ($1*$2)/100-$3}')
            local available_disk=${runtimehome_arr[1]}
            local need_free_disk=$(echo $used_runtime_disk $most_used_disk $available_disk | awk '{printf "%.f", ($1-$2)+$3}')
            log "failed" "Checking the possibility of triggering kubelet image gc" "The total disk space for $RUNTIME_CDFDATA_HOME is ${total_runtime_disk}GB which might be insufficient and trigger the Kubelet image garbage collection. Try to free up disk space in $RUNTIME_CDFDATA_HOME to ensure at least ${need_free_disk}G available disk space or change the RUNTIME_CDFDATA_HOME to another directory located on a larger disk."
        fi
        # check /var and / disk space
        local var_arr=($(df -mP "/var" |sed '1d'|awk '{print $6; printf "%.2f", $4/1024}'))
        local root_arr=($(df -mP "/" |sed '1d'|awk '{print $6; printf "%.2f", $4/1024}'))
        # the mount point of /var is not same as cdf_home or runtime_data_home, need to check the disk of /var separately
        if [ "${var_arr[0]}" != "${k8shome_arr[0]}" ] && [ "${var_arr[0]}" != "${runtimehome_arr[0]}" ]; then
            msg="Checking required free space under /var"
            if [ $(echo "${var_arr[1]} $VAR_DISK"|awk '{print $1<$2}') = 1 ]; then
                log "failed" "$msg" "/var only has ${var_arr[1]} GB free disk space. Check the hardware requirements and add more disk space."
            else
                log "pass" "$msg"
            fi
        fi
        # the mount point of / is not same as cdf_home or runtime_data_home, need to check the disk of / separately
        if [ "${root_arr[0]}" != "${k8shome_arr[0]}" ] && [ "${root_arr[0]}" != "${runtimehome_arr[0]}" ]; then
            msg="Checking required free space under /"
            if [ $(echo "${root_arr[1]} $ROOT_DISK"|awk '{print $1<$2}') = 1 ]; then
                log "failed" "$msg" "/ only has ${root_arr[1]} GB free disk space. Check the hardware requirements and add more disk space."
            else
                log "pass" "$msg"
            fi
        fi
    elif [ "$1" = 'TMP' ]; then
        local msg="Checking required free space ${TMP_DISK} GB under $TMP_FOLDER"
        local basedir=$(getVaildDir $TMP_FOLDER)
        local tmp_arr=($(df -mP $basedir |sed '1d'|awk '{print $6; printf "%.2f", $4/1024}'))
        if [ $(echo "${tmp_arr[1]} $TMP_DISK"|awk '{print $1<$2}') = 1 ]
        then
            log "failed" "$msg" "$TMP_FOLDER only has ${tmp_arr[1]} GB free disk space. Check the hardware requirements and add more disk space."
        else
            log "pass" "$msg"
        fi
    fi
}

checkApiServerConnection(){
#check if api server is reachable
if [ "$NODE_TYPE" = "master" -o "$NODE_TYPE" = "worker" ];then
    #echo "curl --tlsv1.2 --noproxy ${K8S_MASTER_IP} https://${K8S_MASTER_IP}:${MASTER_API_SSL_PORT} --cacert ${CA_FILE} --cert ${CERT_FILE} --key ${KEY_FILE} >/dev/null 2>&1"
    local msg="Checking kubernetes api server connection"
    if [ -z "$K8S_MASTER_IP" -o -z "$MASTER_API_SSL_PORT" -o -z "$CERT_FILE" -o -z "$KEY_FILE" -o -z "$CA_FILE" ];then
        log "skip" "$msg"
    else
        curl $CURL_TLS --head --fail --noproxy ${K8S_MASTER_IP} https://${K8S_MASTER_IP}:${MASTER_API_SSL_PORT} --cacert ${CA_FILE} --cert ${CERT_FILE} --key ${KEY_FILE} --connect-timeout 5 -m 5 >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "pass" "$msg"
        else
            [ "$TIMESYNC_CHECK" = "fail" ] && local addMsg="This issue may be caused by time inconsistency between nodes, make sure all nodes are time-synchronized."
            log "failed" "$msg" "Access to the K8s API server failed. Unable to access ${K8S_MASTER_IP}:${MASTER_API_SSL_PORT} on $THIS_NODE. Please make sure address ${K8S_MASTER_IP} is reachable on $THIS_NODE and make sure all nodes are time-synchronized."
        fi
    fi
fi
}

checkSystemTime(){
#check if local time is synchronized with the 1st node
if [ "$NODE_TYPE" != "first" ];then
    if [ -z "$K8S_MASTER_IP" -o -z "$MASTER_API_SSL_PORT" -o -z "$CERT_FILE" -o -z "$KEY_FILE" -o -z "$CA_FILE" ];then
        if [ -n "$FIRST_NODE_TIME" ];then
            dateDiff=$(echo $(( CURRENT_NODE_TIME - FIRST_NODE_TIME ))|sed 's/^-//')
            if [ $dateDiff -gt 60 ]; then
                log "failed" "Checking system time synchronized with first master node" "The time difference for this node is $dateDiff seconds. This is too big. Make sure all nodes are time-synchronized."
                TIMESYNC_CHECK=fail
            else
                log "pass" "Checking system time synchronized"
            fi
        else
            log "skip" "Checking system time synchronized"
        fi
    else
        dateFromServer=$(curl $CURL_HTTP $CURL_TLS --head --silent --noproxy ${K8S_MASTER_IP} https://${K8S_MASTER_IP}:${MASTER_API_SSL_PORT} -k --connect-timeout 5 -m 5 2>&1 | grep ^Date | sed -e 's/^Date: //')
        if [ ! -z "$dateFromServer" ]; then
            dateFromServer_s=$(date -d "$dateFromServer" +%s)
        else
            log "failed" "Checking system time synchronized" "Access to the K8s API server failed. Unable to access ${K8S_MASTER_IP}:${MASTER_API_SSL_PORT} on $THIS_NODE. Please make sure address ${K8S_MASTER_IP} is reachable on $THIS_NODE and make sure all nodes are time-synchronized."
            return 1
        fi

        dateDiff=$(echo $(( dateFromServer_s - $(date +%s) ))|sed 's/^-//')

        if [ $dateDiff -gt 60 ]; then
            log "failed" "Checking system time synchronized with first master node" "The time difference for this node is $dateDiff seconds. This is too big. Make sure all nodes are time-synchronized."
            TIMESYNC_CHECK=fail
        else
            #for fix CR#1553620
            certNotBeforeTime=$(openssl x509 -in $CERT_FILE -startdate -noout | awk -F= '{print $2}')
            certNotBeforeTime_s=$(date -d "$certNotBeforeTime" +%s)
            timeDiff=$(( certNotBeforeTime_s - dateFromServer_s ))
            if [ "$timeDiff" -gt 0 ]; then
                sleep $timeDiff
            fi
            log "pass" "Checking system time synchronized"
        fi
    fi
fi
}

checkHaVirtualIP() {
    if [[ ${HA_VIRTUAL_IP} =~ [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] ; then
        if [ $(ping -c1 -w1 ${HA_VIRTUAL_IP}>/dev/null 2>&1; echo $?) -ne 0 ] ; then
            log "pass" "Checking HA_VIRTUAL_IP format and unreachable"
        else
            log "failed" "Checking HA_VIRTUAL_IP unreachable" "Virtual IP $HA_VIRTUAL_IP is already in use. Free up the IP address or specify another one."
        fi
    else
        log "failed" "Checking HA_VIRTUAL_IP format" "The virtual IP $HA_VIRTUAL_IP is not a valid IPv4 address."
    fi
    # validate network address of virtual ip and first master node are same
    # local ip=$(getLocalIP)
    # local ip_netmask=$(ifconfig|grep $ip |awk '{print $4}')
    # local ip_network_address=$(getIpInSameSubnet $ip $ip_netmask)
    # local vip_network_address=$(getIpInSameSubnet $HA_VIRTUAL_IP $ip_netmask)
    # local msg="Checking network address of HA_VIRTUAL_IP"
    # if [ "$ip_network_address" = "$vip_network_address" ]; then
    #     log "pass" "$msg"
    # else
    #     log "failed" "$msg" "The virtual IP address is not in the same subnet as the first installed master node. Specify another IP address."
    # fi
}

checkOSVersion(){
    # 2023.05 release support matrix (x86_64)
    # RHEL        : >=7.8 & <10.0
    # Oracle Linux: >=7.8 & <10.0
    # Rocky Linux : >=8.0 & <10.0
    local msg="Checking operating system version"
    if [ "$(uname -m)" = "x86_64" ]; then
        if ! grep -iqE "Red Hat Enterprise Linux|Oracle Linux|CentOS|Rocky Linux" /etc/system-release ; then
            log "failed" "$msg" "This Linux distro is not RHEL, CentOS, Oracle Linux or Rocky Linux. Please refer to the support matrix for detailed information."
            return
        elif grep -iqE "CentOS" /etc/system-release; then
            log "warning" "$msg" "The CentOS distro is not certified and will no longer be supported in the near future. It's recommended to use Red Hat Enterprise Linux, Oracle Linux, or Rocky Linux. Please refer to the support matrix for detailed information."
            return
        fi
        # check TLS min version with OS version
        if [[ "$TLS_MIN_VERSION" == "tlsv1.3"  ]]; then
            local supportedMinOsVersion="8.0"
            local osVersion=$(cat /etc/system-release | sed -n 's/.* \([0-9][^ ]*\).*$/\1/p')
            if [[ "$(getLowVersion $osVersion $supportedMinOsVersion)" == "$osVersion" ]] && [[ "$osVersion" != "$supportedMinOsVersion" ]]; then
                log "failed" "$msg" "TLS minimum version is set to v1.3. The operation system version of node:$THIS_NODE is $osVersion, it does not support TLSv1.3; for supporting TLSv1.3, the operation system version must be greater than or equal to 8.0."
                return
            fi
        fi
        # check os version
        local noLowerVersion="7.8"
        local noHigherVersion="10.0"
        if grep -iqE "Rocky Linux" /etc/system-release; then
            local noLowerVersion="8.0"
        fi
        local osVersion=$(cat /etc/system-release | sed -n 's/.* \([0-9][^ ]*\).*$/\1/p')
        if [ $(getLowVersion $osVersion $noHigherVersion) = "$noHigherVersion" ] || [ $(getLowVersion $osVersion $noLowerVersion) = "$osVersion" -a "$osVersion" != "$noLowerVersion" ]; then
            log "warning" "$msg" "The release of this Linux distro is not certified. Please refer to the support matrix for detailed information."
        else
            log "pass" "$msg"
        fi
    else
        log "failed" "$msg" "The install must run on x86_64 system."
    fi
}

KUBELET_PROTECT_KERNEL=(
vm.overcommit_memory=1
vm.panic_on_oom=0
kernel.panic=10
kernel.panic_on_oops=1
kernel.keys.root_maxkeys=1000000
kernel.keys.root_maxbytes=25000000
)

checkKernel(){
    local msg="Checking kernel parameters"
    local failedNum=0
    #  net.bridge.bridge-nf-call-arptables
    local args="net.bridge.bridge-nf-call-ip6tables net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward"
    for arg in $args;do
        sysctl -n $arg 1>/dev/null 2>&1
        if [ $? -eq 0 ]; then
            if [ $(sysctl -n $arg) = "0" ];then
                failedNum=$(( failedNum + 1 ))
                log "failed" "$msg" "Please change the value of kernel parameter($arg) from 0 to 1."
            fi
        else
            failedNum=$(( failedNum + 1 ))
            log "failed" "$msg" "You must make sure the br_netfilter module is installed, and the system kernel parameter ($arg) is set to 1. Please refer to the system requirements for detailed information."
        fi
    done
    local param="net.ipv4.tcp_tw_recycle"
    sysctl -n $param 1>/dev/null 2>&1
    if [ $? -eq 0 ]; then
        if [ $(sysctl -n $param) = "1" ];then
            failedNum=$(( failedNum + 1 ))
            log "failed" "$msg" "Please change the value of kernel parameter($arg) from 1 to 0."
        fi
    fi
    if [ ${KUBELET_PROTECT_KERNEL_DEFAULTS} = "true" ]; then
        for param in ${KUBELET_PROTECT_KERNEL[*]}; do
            if [ $(sysctl -n "${param/=*}") != "${param#*=}" ]; then
                failedNum=$(( failedNum + 1 ))
                log "failed" "$msg" "KUBELET_PROTECT_KERNEL_DEFAULTS is enabled, you must set the kernel parameter $param or set KUBELET_PROTECT_KERNEL_DEFAULTS to false."
            fi
        done
    fi
    local param="net.ipv4.ip_local_port_range"
    local minPort=$(sysctl -n $param 2>/dev/null | awk '{print $1}')
    local expectMinPort=32768
    if [ "$minPort" -lt "$expectMinPort" ]; then
        failedNum=$(( failedNum + 1 ))
        log "warning" "$msg" "On this system the lowest allowed port number is $minPort, this may cause a port conflict and the installation or upgrade failure; the recommended lowest port number is $expectMinPort, which you can modify by changing the kernel parameter $param."
    fi
    #on 8.x OS, this parameter does not exist, no need to check it.
    #on 7.x OS, recommend set this parameter to 1
    local param="fs.may_detach_mounts"
    local value=$(sysctl -n $param 2>/dev/null )
    if [ -n "$value" -a "$value" = "0" ]; then
        failedNum=$(( failedNum + 1 ))
        log "failed" "$msg" "On this system the kernel parameter($param) is 0. Please change to 1; otherwise existing pods may get stuck in Terminating status when restarted."
    fi
    if [ $failedNum -eq 0 ]; then
        log "pass" "$msg"
    fi
}

checkFlannelIface(){
if [ ! -z $FLANNEL_IFACE ]; then
    local msg="Checking flannel interface"
    if [[ "$FLANNEL_IFACE" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local n=0
        for quad in ${FLANNEL_IFACE//./ }
        do
            if [ $quad -gt 255 ]; then n=$((n+1)); fi
        done
        if [ $n -ne 0 ]; then
            log "failed" "$msg" "$FLANNEL_IFACE is not a valid IPv4 address."
        else
            if [ $(hostname -I | grep $FLANNEL_IFACE | wc -l) -ne 0 ]; then
                IFACE="ipv4"
                log "pass" "$msg"
            else
                log "failed" "$msg" "'$FLANNEL_IFACE' is not the IP address of this host."
            fi
        fi
    elif [ "$FLANNEL_IFACE" = "lo" ]; then
            log "failed" "$msg" "'lo' is the loopback network interface which is not supported. Please provide a valid network interface."
    else # check network interface name
        if [ $(ifconfig $FLANNEL_IFACE >/dev/null 2>&1; echo $? ) -ne 0 ]; then
            log "failed" "$msg" "'${FLANNEL_IFACE}' is not the interface of this host."
        else
            IFACE="name"
            log "pass" "$msg"
        fi
    fi
elif [ "$INNER_CHECK" != "true" ]; then
    if [ "$STANDALONE_FLAG" = "true" ]; then
        log "skip" "Checking flannel interface"
    else
        checkDefaultRoute
    fi
fi
}

getLocalIP(){
    local local_ip=
    if [ ! -z "$FLANNEL_IFACE" ]; then
        if [[ $FLANNEL_IFACE =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            local_ip=$FLANNEL_IFACE
        else
            local_ip=$(ifconfig $FLANNEL_IFACE 2>/dev/null | awk '/netmask/ {print $2}')
        fi
    else
        if [[ $THIS_NODE =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            local_ip=$THIS_NODE
        else
            local_ip=$(ip route get 8.8.8.8|sed 's/^.*src \([^ ]*\).*$/\1/;q')
        fi
    fi
    if [ -z $local_ip ]; then
        log "fatal" "Failed to get local ip of current node."
    else
        echo $local_ip
    fi
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

#FLANNEL_BACKEND_TYPE=host-gw 16.155.197.50 255.255.248.0
getIpInSameSubnet() {
    if [ $# -eq 1 ]; then
        local netAddress[0]=$1
        local netAddress[1]=$(ifconfig|grep ${netAddress[0]}|awk '{print $4}')
    elif [ $# -eq 2 ]; then
        local netAddress[0]=$1
        local netAddress[1]=$2
    fi
    local all=(${netAddress[@]//[!0-9]/ })
    local a=$(( $((2#$(dec2bin ${all[0]}))) & $((2#$(dec2bin ${all[4]}))) ))
    local b=$(( $((2#$(dec2bin ${all[1]}))) & $((2#$(dec2bin ${all[5]}))) ))
    local c=$(( $((2#$(dec2bin ${all[2]}))) & $((2#$(dec2bin ${all[6]}))) ))
    local d=$(( $((2#$(dec2bin ${all[3]}))) & $((2#$(dec2bin ${all[7]}))) ))
    echo "${a}.${b}.${c}.${d}"
}

checkIpInSameSubnet() {
    LOCAL_IP=$(getLocalIP)
    NETWORK_ADDRESS_THIS_NODE=`getIpInSameSubnet ${LOCAL_IP}`
    local msg="Checking network address"
    local err_msg=$1
    if [ "$STANDALONE_FLAG" = "true" -a -z "$NETWORK_ADDRESS" ];then
        log "skip" "$msg"
    else
        if [[ "${NETWORK_ADDRESS_THIS_NODE}" == "${NETWORK_ADDRESS}" ]] ; then
            log "pass" "$msg"
        else
            log "failed" "$msg" "$err_msg"
        fi
    fi
}

checkKernelVersion4Overlay2(){ #overlay2 is supported in kernel version 3.10.0-514 and up
    local kernel_version=$(uname -r)
    local versions=${kernel_version//./ }
    versions=(${versions//-/ })
    local bases=("3" "10" "0" "514")
    if [[ ${versions[0]} -lt ${bases[0]} ]];then
      echo "false"
    elif [[ ${versions[0]} -eq ${bases[0]} ]];then
      if [[ ${versions[1]} -lt ${bases[1]} ]];then
        echo "false"
      elif [[ ${versions[1]} -eq ${bases[1]} ]]; then
        if [[ ${versions[2]} -lt ${bases[2]} ]];then
          echo "false"
        elif [[ ${versions[2]} -eq ${bases[2]} ]]; then
          if [[ ${versions[3]} -lt ${bases[3]} ]]; then
            echo "false"
          else
            echo "true"
          fi
        else
          echo "true"
        fi
      else
        echo "true"
      fi
    else
      echo "true"
    fi
}
checkOverlayfs(){
  local valid_dir=$(getVaildDir "${RUNTIME_CDFDATA_HOME}")
  local mount_point=$(df --output=target ${valid_dir} | grep -v "Mounted on")
  local fs_type=$(df --output=fstype ${mount_point}|grep -v "Type")
  if [ "$fs_type" == "ext4" ];then
      ol2_support="true"
  elif [[ "$fs_type" == "xfs" ]]; then
      local ftype=$(xfs_info "${mount_point}" | grep "ftype" | awk -F' ' '{print $6}')
      ftype=${ftype#*=}
      if [ "$ftype" == "1" ];then
          ol2_support="true"
      else
          ol2_support="false"
      fi

  else
      ol2_support="false"
  fi

  local kernel_support=$(checkKernelVersion4Overlay2)

  if [ "$ol2_support" == "false" ];then
      log "failed" "Checking overlayfs device is used on containerd" "The backing file system of ${valid_dir} is ${fs_type} [with ftype=0] which is not supported. Allowed backing file system type is ext4 or xfs with ftype=1.";
  elif [ "$kernel_support" == "false" ];then
      log "failed" "Checking overlayfs device is used on containerd" "This operating system kernel version is too low; please upgrade the kernel to 3.10.0-514 or higher.";
  else
      log "pass" "Checking overlayfs device is used on containerd";
  fi
}

checkDssPerformance(){
    if [ -n "$RUNTIME_CDFDATA_HOME" ]; then
        local msg="Checking local disk I/O performance"
        local needClean=false
        if [ ! -d "$RUNTIME_CDFDATA_HOME" ]; then
            mkdir -p "$RUNTIME_CDFDATA_HOME"
            if [ "$?" -ne 0 ]; then
                 log "warning" "$msg" "Cannot create $RUNTIME_CDFDATA_HOME directory, please manually create this directory and ensure it has read and write permissions."
                 return
            fi
            needClean=true
        fi
        local startTime endTime writeTime
        local blockSize="128K"
        startTime=$(date "+%s")
        timeout 60 dd if=/dev/zero of=$RUNTIME_CDFDATA_HOME/dssCheck bs=$blockSize count=1 >/dev/null 2>&1
        endTime=$(date "+%s")
        writeTime=$(( $endTime - $startTime ))
        if [ "$writeTime" -gt "2" ]; then
            log "warning" "$msg" "The I/O performance of local disk may be inadequate. Writing $blockSize data takes $writeTime seconds."
        else
            log "pass" "$msg"
        fi
        if [ "$needClean" = "true" ]; then
            rm -rf $RUNTIME_CDFDATA_HOME
        else
            rm -f $RUNTIME_CDFDATA_HOME/dssCheck
        fi
    fi
}

checkHostnameLen(){
    # check the length of hostname, max size is 63
    # otherwise kubelet unable to registry node
    if [[ ! $THIS_NODE =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && [ ${#THIS_NODE} -gt 63 ]; then
        log "failed" "Checking length of hostname" "The length of hostname $THIS_NODE is ${#THIS_NODE}, it must be equal to or lower than 63 characters."
    fi
}

checkSvcNotInstalled(){
    # check the service is not installed.
    for svc in $*
    do
        local msg="Checking $svc service not installed"
        local exist=0
        for dir in "/etc/systemd/system" "/usr/lib/systemd/system" "/etc/systemd/system/multi-user.target.wants"
        do
            if [ -f $dir/${svc}.service -o $(ls $dir/${svc}.service.d 2>/dev/null | wc -w) -ne 0 ]; then
                exist=$(( exist + 1 ))
                log "failed" "$msg" "Found $svc service which conflicts with OMT install. Please uninstall the $svc first."
                break
            fi
        done
        if [ $exist -eq 0 ]; then
            log "pass" "$msg"
        fi
    done
}

checkMultiMasterOptions(){
    local msg="Checking HA_VIRTUAL_IP and LOAD_BALANCER_HOST"
    if [ "$NODE_TYPE" = "first" -a ! -z "${HA_VIRTUAL_IP}" ]; then
        if [ ! -z "${LOAD_BALANCER_HOST}" ]; then
            log "failed" "$msg" "The options HA_VIRTUAL_IP and LOAD_BALANCERH_HOST cannot be used together."
        else
            checkHaVirtualIP
        fi
    elif [ "$NODE_TYPE" = "master" ]; then
        if [ "$STANDALONE_FLAG" = "true" ];then
            if [ -z "${HA_VIRTUAL_IP}" -a -z "${LOAD_BALANCER_HOST}" ]; then
                log "skip" "$msg"
            fi
        else
            if [ -z "${HA_VIRTUAL_IP}" -a -z "${LOAD_BALANCER_HOST}" ]; then
                log "failed" "$msg" "You must set either HA_VIRTUAL_IP or LOAD_BALANCER_HOST."
            fi
        fi
    fi

    if [ "$NODE_TYPE" = "master" ]; then
        local err_msg="Not in the same subnetwork as the first control plane node with flannel backend type \"${FLANNEL_BACKEND_TYPE}\". Please make sure all control plane nodes are in the same subnetwork."
    elif [ "$NODE_TYPE" = "worker" ]; then
        local err_msg="Not in the same subnetwork as the first control plane node with flannel backend type \"${FLANNEL_BACKEND_TYPE}\". Please change flannel backend type to \"vxlan\" or make sure all the nodes are in the same subnetwork."
    fi
    if [ -z "${FLANNEL_BACKEND_TYPE}" ];then
        if [ "$NODE_TYPE" = "master" -o "$NODE_TYPE" = "worker" ]; then
            checkIpInSameSubnet "$err_msg"
        fi
    elif [ "${FLANNEL_BACKEND_TYPE}" = "host-gw" ]; then
        if [ "$NODE_TYPE" = "master" -o "$NODE_TYPE" = "worker" ]; then
            checkIpInSameSubnet "$err_msg"
        fi
    else
        if [ "$NODE_TYPE" = "master" -a -z "${LOAD_BALANCER_HOST}" ]; then
            checkIpInSameSubnet "$err_msg"
        fi
    fi
}

checkSwap(){
    local msg="Checking swap is disabled"
    if [ "$FAIL_SWAP_ON" = "false" ]; then
        log "warning" "$msg" "The value of FAIL_SWAP_ON is false which is not recommended. Please consult the product installation documentation for guidance on running cluster nodes with swap on or off and make sure you set FAIL_SWAP_ON=false accordingly."
    elif [ "$FAIL_SWAP_ON" = "true" ]; then
        local swap_fstab=$(grep -v '^#' /etc/fstab | awk '{print $3}' | grep 'swap' | wc -l)
        local swap_proc=$(swapon --noheadings | wc -l)
        if [ $swap_fstab -ne 0 -o $swap_proc -ne 0 ]; then
            log "failed" "$msg" "Swap is enabled on this node but FAIL_SWAP_ON is set to false. This is an invalid combination. You can disable swap with the command 'swapoff -a' and disable swap permanently in /etc/fstab. Or you can set FAIL_SWAP_ON to false."
        else
            log "pass" "$msg"
        fi
    fi
}

checkFipsEntropy(){
    local msg="Checking system entropy"
    local kernelVersion=$(uname -r)
    local kernelSkipCheck='5.10.0-119'
    local lv=$(getLowVersion $kernelVersion $kernelSkipCheck)
    if [ "$lv" = "$kernelVersion" ];then
        local entropy=$(tail -1 /proc/sys/kernel/random/entropy_avail)
        if [ "$entropy" -lt "$FIPS_ENTROPY_THRESHOLD" ]; then
            log "warning" "$msg" "The system entropy ($entropy) is lower than ${FIPS_ENTROPY_THRESHOLD}. As a result AppHub and other application components which consumes a lot of entropy such as processing certificates may be very slow or not able to start until enough entropy is available. If the entropy generation tools neither \"rngd\" nor \"havegd\" service is not already active on your systems, then please install one of entropy generation tools such as \"rngd\" using \"yum install rng-tools\" or \"dnf install rng-tools\" and start & enable the rngd service to increase the system entropy."
        else
            log "pass" "$msg"
        fi
    else
        log "skip" "$msg" "The system kernel version is $kernelVersion, which is equal to or higher than $kernelSkipCheck; no need to check the entropy value."
    fi
}

checkSudoer(){
    if [ -n "$NOROOT_USER" -a "$NOROOT_USER" != "root" ]; then
        local msg="Checking sudoers NOPASSWD commands setting"
        local install_cmd
        if [ "$NODE_TYPE" == "first" ]; then
            if [ "$STANDALONE_FLAG" != "false" ]; then
                log "warning" "$msg" "Make sure '<installation package directory>/install' is added into executable command list for sudo user $NOROOT_USER; or run 'node_prereq' to configure sudo."
            fi
        else
            install_cmd="${TMP_FOLDER}/ITOM_Suite_Foundation_Node/install"
        fi

        # check cmnd settings
        local missing_cmds=""
        local install_required_cmds="/usr/bin/mkdir
                                     /usr/bin/cp
                                     /bin/rm
                                     /bin/chmod
                                     /bin/chown
                                     /bin/tar
                                     ${install_cmd}"
        local all_cmds=$(sudo -n -l -U $NOROOT_USER | awk -F: '/NOPASSWD:/ {print $2}' | tr -d ',')
        local errMsg="Make sure NOPASSWD is enabled for sudo user $NOROOT_USER and check the product installation documentation how to add all required commands into the executable command list; or run 'node_prereq' to configure sudo."
        if [ -n "$all_cmds" -a "$all_cmds" != ' ALL' ]; then
            for cmd in $install_required_cmds
            do
                local cmd_found="false"
                local all_found="false"
                for i in $all_cmds
                do
                   if [ "$cmd" = "$i" ]; then
                       cmd_found="true"; break;
                   elif [ "$i" = "ALL" ]; then
                       all_found="true"; break;
                   fi
                done
                if [ "$all_found" = "true" ]; then break; fi
                if [ "$cmd_found" = "false" ]; then
                    [ -z "$missing_cmds" ] && missing_cmds="$cmd" || missing_cmds="${missing_cmds}, $cmd"
                fi
            done
            if [ -n "$missing_cmds" -a "$all_found" = "false" ]; then
                log "failed" "$msg" "$errMsg"
            fi
        elif [ -z "$all_cmds" ]; then
            log "failed" "$msg" "$errMsg"
        fi
        # check secure_path setting
        local missing_paths=""
        local required_paths="/sbin
                              /bin
                              /usr/sbin
                              /usr/bin"
        local all_paths=$(sudo -n -l -U $NOROOT_USER | grep 'secure_path' | tr ',' '\n' | awk -F= '/secure_path/ {print $2}' | sed 's@\\:@\n@g')
        for path in $required_paths
        do
            local found_path="false"
            for i in $all_paths
            do
                if [ "$path" = "$i" ]; then found_path="true"; break; fi
            done
            if [ "$found_path" = "false" ]; then
                [ -z "$missing_paths" ] && missing_paths="$path" || missing_paths="$missing_paths, $path"
            fi
        done
        if [ -n "$missing_paths" ]; then
                log "failed" "Make sure '$missing_paths' is added in the secure_path; or run 'node_prereq' to configure sudo."
        fi
    fi
}

checkLogReceiver(){
    if [ -n "$FLUENTD_LOG_RECEIVER_URL" ]; then
        local msg="Checking log receiver url is reachable"
        if [ "$FLUENTD_LOG_RECEIVER_TYPE" = "oba" -o "$FLUENTD_LOG_RECEIVER_TYPE" = "splunk" ]; then
            local healthUrl=$FLUENTD_LOG_RECEIVER_URL
        else
            [ "${FLUENTD_LOG_RECEIVER_URL: -1}" = "/" ] && local healthUrl=${FLUENTD_LOG_RECEIVER_URL}_cluster/health || local healthUrl=${FLUENTD_LOG_RECEIVER_URL}/_cluster/health
        fi
        [ -n "$FLUENTD_LOG_RECEIVER_CA" ] && local cacert="--cacert $FLUENTD_LOG_RECEIVER_CA "
        [ -n "$FLUENTD_LOG_RECEIVER_USER" -a -n "$FLUENTD_LOG_RECEIVER_PWD" ] && local cred="-u ${FLUENTD_LOG_RECEIVER_USER}:${FLUENTD_LOG_RECEIVER_PWD}"
        if [ "$FLUENTD_LOG_RECEIVER_TYPE" = "splunk" ]; then
            local rtnCode=$(curl -s -k -o /dev/null --connect-timeout 20 --max-time 20 -w %{http_code} $healthUrl)
        else
            local rtnCode=$(curl -s -o /dev/null --connect-timeout 20 --max-time 20 -w %{http_code} $cred $cacert $healthUrl)
        fi
        if [ "$FLUENTD_LOG_RECEIVER_TYPE" = "splunk" -a "$rtnCode" -gt "100" ]; then
            log "pass" "$msg"
        elif [ "$rtnCode" = "200" ]; then
            log "pass" "$msg"
        else
            log "failed" "$msg" "The log receiver $FLUENTD_LOG_RECEIVER_URL is unreachable; return code: $rtnCode."
        fi
    fi
}

checkLocalhost(){
    local ipAddrList=($(grep -v '^\s*#' /etc/hosts  2>/dev/null | grep -E '\slocalhost$|\slocalhost\s' | awk '{print $1}'))
    local msg="Checking localhost is resolved to 127.0.0.1 in /etc/hosts"

    if [ ${#ipAddrList[*]} -eq 0 ]; then
        log "failed" "$msg" "Make sure '127.0.0.1 localhost' is added into /etc/hosts."
    else
        local ipAddr ipv4Found="false" othersFound="false"
        for ipAddr in ${ipAddrList[@]};do
            if [ "$ipAddr" == "127.0.0.1" ];then
                ipv4Found="true"
            elif [ "$ipAddr" != "::1" ];then
                othersFound="true"
            fi
        done

        if [ "$ipv4Found" == "false" ];then
            log "failed" "$msg" "Make sure '127.0.0.1 localhost' is added into /etc/hosts."
        else
            if [ "$othersFound" == "false" ];then
                log "pass" "$msg"
            else
                log "failed" "$msg" "localhost resolved to more than one IP address '${ipAddrList[*]}'. localhost can only be resolved to '127.0.0.1, ::1'"
            fi
        fi
    fi
}

checkDefaultRoute(){
    local msg="Checking default route exists on this server"
    case $(ip route | grep -c ^default) in
    1 ) log "pass" "$msg"; return ;;
    0 ) log "failed" "$msg" "No default route found when running 'ip route'. Please add a default route or specify the Flannel interface with --flannel-iface." ;;
    * ) log "failed" "$msg" "More than one default route found when running 'ip route'. Please configure just one default route or specify the Flannel interface with --flannel-iface." ;;
    esac
    (( PRECHECK_FAILURE += 1 ))
}

checkHostnameResolving(){
    if [[ ! "$THIS_NODE" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local localIp=$(getLocalIP)
        local ipAddrList=($(grep -v '^\s*#' /etc/hosts 2>/dev/null | grep -Ei "\s${THIS_NODE}$|\s${THIS_NODE}\s" | awk '{print $1}' | grep -vE ':|^127.'))
        local msg="Checking node hostname resolving in /etc/hosts"
        if [ "${#ipAddrList[*]}" -eq 0 ] || [ "${#ipAddrList[*]}" -eq 1 -a "$localIp" = "${ipAddrList}" ]; then
            log "pass" "$msg"
        elif [ "${#ipAddrList[*]}" -eq 1 -a "$localIp" != "${ipAddrList}" ]; then
            log "failed" "$msg" "Make sure IP <--> hostname mapping is aligned between DNS server and local /etc/hosts. This hostname $THIS_NODE is mapped to $localIp on DNS server but is mapped to different IP $ipAddrList in /etc/hosts."
        else
            log "failed" "$msg" "$THIS_NODE is resolved to more than one IP address '${ipAddrList[*]}'. Make sure $THIS_NODE entry appears only once in /etc/hosts."
        fi
    fi
}

checkMinReq() {
    check_x86_64_level
    if [ "$NODE_TYPE" != "worker" ] || [ "$NODE_TYPE" = "worker" -a ! -z "$CLI_CPU" -a ! -z "$CLI_MEM" -a ! -z "$CLI_DISK" ]; then
        checkMem
        checkCPU
        checkDisk "CDF"
    fi
    [ "$NODE_TYPE" != "first" ] && checkDisk "TMP"
}

isServiceActive(){
  local svcName=$1
  local output
  output="$(systemctl is-active $svcName)"
  if [[ "$output" == "active" ]] || [[ "$output" == "activating" ]];then
    return 0
  else
    return 1
  fi
}

checkDNSServer(){
    local msg="Checking DNS servers resolution on this node"
    local dnsServers=
    local invalidDNS=
    local nxDomainDns=
    local resolvConf=
    local parseConfFailed=
    if [ $(which nslookup > /dev/null 2>&1; echo $?) -eq 0 ]; then
        if isServiceActive "systemd-resolved";then
            resolvConf="/run/systemd/resolve/resolv.conf"
        else
            resolvConf="/etc/resolv.conf"
        fi

        dnsServers=$(grep -v '^\s*#' $resolvConf|grep nameserver|awk '{print $2}')
        if [ -z "$dnsServers" ]; then
            log "warning" "$msg" "No nameservers found in $resolvConf."
        else
            for dns in $dnsServers
            do
                local res=
                res=$(nslookup $THIS_NODE $dns 2>/dev/null)
                if [ $? -eq 10 ]; then
                    parseConfFailed="true"
                    break
                elif [ $? -ne 0 ] && [[ "$res" =~ "NXDOMAIN" ]]; then
                    nxDomainDns="$dns $nxDomainDns"
                elif [ $? -ne 0 ] && [[ "$res" =~ "no servers could be reached" ]]; then
                    invalidDNS="$dns $invalidDNS"
                fi
            done
            if [ "$parseConfFailed" = "true" ]; then
                log "failed" "$msg" "nslookup: parse of $resolvConf failed. $resolvConf file may be corrupted which cause this error, please check this file."
            elif [ -z "$invalidDNS" ]; then
                if [ -z "$nxDomainDns" ]; then
                    log "pass" "$msg"
                else
                    log "warning" "$msg" "$THIS_NODE cannot be resolved to valid IP address through DNS server $nxDomainDns. (NXDOMAIN)"
                fi
            else
                log "failed" "$msg" "DNS server(s) $invalidDNS connection timed out; no server(s) could be reached. This will likely create host name resolution problems in the K8s cluster. Please remove $invalidDNS from $resolvConf and configure valid nameserver(s)."
            fi
        fi
    else
        log "warning" "$msg" "The nslookup command was not found; cannot validate any DNS resolution. You can run 'yum install bind-utils' or 'dnf install bind-utils' to install this command."
    fi
}

checkUserGroupIDs(){
    if [ "$NODE_TYPE" = "first" ]; then
        local msg="Checking SYSTEM_USER_ID and SYSTEM_GROUP_ID"
        if [ -z "$SYSTEM_USER_ID" -o -z "$SYSTEM_GROUP_ID" ];then
            log "skip" "$msg"
        else
            local n=0
            for id in SYSTEM_USER_ID SYSTEM_GROUP_ID
            do
                eval local value=\$$id
                if [ "$value" -ne 1999 ] && [ "$value" -lt 100000 -o "$value" -gt 2000000000 ]; then
                    n=$((n+1))
                fi
            done
            if [ $n -gt 0 ]; then
                log "warning" "$msg" "SYSTEM_USER_ID is $SYSTEM_USER_ID, SYSTEM_GROUP_ID is $SYSTEM_GROUP_ID; the recommended value is 1999 or any value between 100000 and 2000000000."
            else
                log "pass" "$msg"
            fi
        fi
    fi
}

checkHttpProxy(){
    local msg="Checking http proxy settings on this node"
    local proxy=$(env | grep -E '^http_proxy=|^https_proxy=|^all_proxy=|^HTTP_PROXY=|^HTTPS_PROXY=|^ALL_PROXY=')
    local domain_name=".$(hostname -d)"
    local items="no_proxy"
    [[ -n ${OS_NO_PROXY} ]] && items="${items} NO_PROXY"

    if [[ -n ${proxy} ]]; then
        local old_value=${PRECHECK_WARNING}
        for np in ${items}; do
            local expected_no_proxy=""
            eval local noProxy=\$OS_${np}
            if [[ ! ${noProxy} =~ (^|,)\ *localhost\ *(,|$) ]]; then
                expected_no_proxy="${expected_no_proxy},localhost"
            fi
            if [[ ! ${noProxy} =~ (^|,)\ *127\.0\.0\.1\ *(,|$) ]]; then
                expected_no_proxy="${expected_no_proxy},127.0.0.1"
            fi
            if [[ ! ${noProxy} =~ (^|,)\ *\*?${domain_name//'.'/'\.'}\ *(,|$) ]]; then
                expected_no_proxy="${expected_no_proxy},domain-name(${domain_name})"
            fi
            if [[ -n ${HA_VIRTUAL_IP} && ! ${noProxy} =~ (^|,)\ *${HA_VIRTUAL_IP//'.'/'\.'}\ *(,|$) ]]; then
                expected_no_proxy="${expected_no_proxy},VIP(${HA_VIRTUAL_IP})"
            fi
            if [[ -n ${LOAD_BALANCER_HOST} && ! ${noProxy} =~ (^|,)\ *${LOAD_BALANCER_HOST//'.'/'\.'}\ *(,|$) ]]; then
                expected_no_proxy="${expected_no_proxy},load-balance(${LOAD_BALANCER_HOST})"
            fi
            if [[ -n ${expected_no_proxy} ]]; then
                log "warning" "$msg" "Proxy is enabled. It's recommended to exclude local addresses, such as no_proxy=${expected_no_proxy:1} or NO_PROXY=${expected_no_proxy:1}"
            fi
        done
        [[ ${old_value} = ${PRECHECK_WARNING} ]] && log "pass" "$msg"
    else
        log "pass" "$msg"
    fi
}

getSSHConfValue() {
    case $(grep -cE "^\s*${1}" /etc/ssh/sshd_config) in
        0)
            echo 0;;
        1)
            local tmp=($(grep -E "^\s*${1}" /etc/ssh/sshd_config))
            if [[ ${#tmp[@]} = 2 ]]; then
                echo "${tmp[1]}"
            else
                echo "unexpected value of ${1}"
            fi
            ;;
        *)
            echo "duplicated ${1} found";;
    esac
}
checkSSH() {
    local msg="Checking SSH auth methods"
    local is_root=${1:-"true"}
    local tmp
    local detail
    local auth_passwd=false
    local auth_pubkey=false

    tmp=$(getSSHConfValue PasswordAuthentication)
    case ${tmp} in
        yes|0)
            auth_passwd=true;;
        no)
            auth_passwd=false;;
        *)
            detail="${detail}; ${tmp}";;
    esac

    tmp=$(getSSHConfValue PubkeyAuthentication)
    case ${tmp} in
        yes|0)
            auth_pubkey=true;;
        no)
            auth_pubkey=false;;
        *)
            detail="${detail}; ${tmp}";;
    esac

    if [[ ${is_root} = "true" ]]; then
        tmp=$(getSSHConfValue PermitRootLogin)
        case ${tmp} in
            0)
                ;;
            yes)
                ;;
            no)
                auth_passwd=false
                auth_pubkey=false
                ;;
            prohibit-password)
                auth_passwd=false
                ;;
            *)
                auth_passwd=false
                auth_pubkey=false
                detail="${detail}; ${tmp}"
                ;;
        esac
    fi

    detail="${detail}. To enable password login, set 'PasswordAuthentication yes'"
    if [[ ${is_root} = "true" ]]; then
        detail="${detail} and 'PermitRootLogin yes'"
    fi
    detail="${detail}. To enable public key login, set 'PubkeyAuthentication yes'"
    if [[ ${is_root} = "true" ]]; then
        detail="${detail} and 'PermitRootLogin prohibit-password'"
    fi
    detail="${detail}. Then restart sshd."

    if [[ ${auth_passwd} = "true" || ${auth_pubkey} = "true" ]]; then
        if [[ ${auth_passwd} = "true" ]]; then
            log "pass" "$msg: password auth enabled"
        else
            log "warning" "$msg: password auth disabled" "${detail:2}"
        fi
        if [[ ${auth_pubkey} = "true" ]]; then
            log "pass" "$msg: public key auth enabled"
        else
            log "warning" "$msg: public key auth disabled" "${detail:2}"
        fi
    else
        log "failed" "$msg" "${detail:2}"
    fi
}

checkIpv6Settings(){
    if [ "$ENABLE_IPV6" = "true" ]; then
        #get interface name
        local interfaceName=
        if [ -n "$FLANNEL_IFACE" ]; then
            if [ "$IFACE" = "ipv4" ]; then
                interfaceName=$(ip route|grep "src $FLANNEL_IFACE" | sed 's/^.*dev \([^ ]*\).*$/\1/;q')
            elif [ "$IFACE" = "name" ]; then
                interfaceName=$FLANNEL_IFACE
            fi
        else
            interfaceName=$(ip route get 8.8.8.8| sed 's/^.*dev \([^ ]*\).*$/\1/;q')
        fi
        if [ -z "$interfaceName" ];then
            local msg="Checking ipv6 related settings"
            log "failed" "$msg" "Could not find available network interface. Please make sure there is a functional default network interface on this host, or verify that the 'flannel iface' value is accurate if you provided."
            return
        fi
        INTERFACE_NAME=$interfaceName
        #should have one default route for ipv6 address
        local msg="Checking default route for ipv6 on network dev $interfaceName"
        if route -n6 | grep "$interfaceName" | grep '^::/0' >/dev/null 2>&1; then
            log "pass" "$msg"
        else
            log "failed" "$msg" "Could not find default route for ipv6 address available on network dev $interfaceName"
        fi
        #the interface should have ipv6 address
        local msg="Checking global scoped ipv6 address on network dev $interfaceName"
        if ip -6 a show $interfaceName scope global | grep inet6 >/dev/null 2>&1; then
            log "pass" "$msg"
        else
            log "failed" "$msg" "Could not find global scoped ipv6 address available on network dev $interfaceName"
        fi
        #flannel dual-stack: vxlan support ipv6 tunnel require kernel version >= 3.12
        #https://github.com/flannel-io/flannel/blob/master/Documentation/configuration.md
        if [ "$FLANNEL_BACKEND_TYPE" = "vxlan" ]; then
            local msg="Checking kernel version when ipv6 is enabled"
            local expectedV="3.12.0"
            local actualV=$(uname -r | cut -d- -f1)
            local lv=$(getLowVersion $expectedV $actualV)
            if [ "$lv" != "$expectedV" ]; then
                log "failed" "$msg" "Kernel version $actualV must be equal to or higher than $expectedV."
            else
                log "pass" "$msg"
            fi
        fi
    fi
}

checkOpensslSecLevel(){
    local msg="Checking openssl security level on this node"
    local opensslDir=$(openssl version -d | awk -F\" '{print $2}')
    local openssCnfFile="$opensslDir/openssl.cnf"
    local checkFile
    if [ -n "$opensslDir" ]; then
        if [ -f "$openssCnfFile" ]; then
            # try to get the include config file under [ crypto_policy ] section and check SECLEVEL on first included file
            includeFiles=$(sed -n '/\[ crypto_policy \]/,/\[/p ' $openssCnfFile | grep -v '^#' | grep '\.include ' | grep -oP "(?:\s)/.*")
            if [ -n "$includeFiles" ]; then
                for file in $includeFiles
                do
                    checkFile=$file
                    break
                done
            else #no include files, try to check SECLEVEL setting in openssl.cnf file
                 checkFile=$openssCnfFile
            fi
        fi
        if [ -n "$checkFile" ]; then
            local level=$(grep -oP '(?<=@SECLEVEL=)\d+' $checkFile)
            if [ -n "$level" ] && [ "$level" -gt 2 ]; then
                log "failed" "$msg" "The openssl security level is $level in $checkFile on this node; it's not supported by the application. You must change openssl SECLEVEL to 2 or lower level."
            else
                log "pass" "$msg"
            fi
        fi
    else
        log "pass" "$msg"
    fi
}

checkIpv6ItemsOnly(){
    # for internal usage
    # ./$0 --inner-check --ipv6 true \
    #                    --ipv6-pod-cidr <v1> \
    #                    --ipv6-pod-cidr-subnetlen <v2> \
    #                    --ipv6-service-cidr <v3> \
    #                    --flannel-backend-type <v4> \
    #                    --flannel-iface <iface>
    # flannel-iface is optional parameter
    checkFlannelIface
    checkIpv6Settings
    checkIpv6RangeOverlap
    [ $PRECHECK_FAILURE -gt 0 ] && exit 1 || exit 0
}

printHintMsg(){
    if [ "$STANDALONE_FLAG" = "true" ]; then
        echo "$HINT_MSG"
    fi
}

checkAll(){
log "catalog" "Check node hardware configurations"
  checkMinReq
  checkOverlayfs
  checkDssPerformance
log "catalog" "Check operation system user permission"
  checkUser
  checkSudoer
log "catalog" "Check operation system network related settings"
  checkFireWalld
  checkAllPorts
  checkLocalhost
  checkHostnameResolving
  checkDNSServer
  checkFlannelIface
  checkHttpProxy
  checkIpv6Settings
log "catalog" "Check operation system basic settings"
  checkOSVersion
  checkKernel
  checkAllCommands
  checkAllPackages
  checkOpensslSecLevel
  [ "$STANDALONE_FLAG" = "true" ] && checkSSH $([[ ${SUDO_UID} =~ ^(0|)$ ]] && echo true || echo false)
log "catalog" "Check operation system other settings"
  checkSwap
  checkFipsEntropy
  checkSvcNotInstalled containerd kubelet
  checkSystemTime
  checkHostnameLen
  checkTmpFolderPermission
log "catalog" "Check $PRODUCT_SHORT_NAME related settings"
  checkFolderIsEmpty RUNTIME_CDFDATA_HOME
  checkK8sHome
  verifyProperties
  checkMultiMasterOptions
  checkApiServerConnection
  checkLogReceiver
  checkUserGroupIDs
}

#check items for installed node only
checkItemsOnInstalledNode(){
    checkAllPortsOnInstalledNode
    checkAllCommands
    checkAllPackages
    checkUnexpectedPkgs
    checkFipsEntropy
    checkKernel
    checkFirewallSettings
    checkDNSServer
}
## check items on installed node only
if [ "$EXISTED_NODE" = "true" ];then
    #
    checkItemsOnInstalledNode
    #
    if [[ $PRECHECK_FAILURE -gt 0 ]]; then
        exit 1
    elif [[ $PRECHECK_WARNING -gt 0 ]]; then
        echo -e "! Got $PRECHECK_WARNING warning(s) during precheck;\nEither fix the configuration or explicitly enable the skip warnings option."
        exit 2
    else
        exit 0
    fi
fi

#new option take precedenct over deprecated option
if [ -z "$CA_FILE" ] && [ -n "$CA_FILE_DEPRECATED" ];then
    CA_FILE=$CA_FILE_DEPRECATED
fi
if [ -z "$CERT_FILE" ] && [ -n "$CERT_FILE_DEPRECATED" ];then
    CERT_FILE=$CERT_FILE_DEPRECATED
fi
if [ -z "$KEY_FILE" ] && [ -n "$KEY_FILE_DEPRECATED" ];then
    KEY_FILE=$KEY_FILE_DEPRECATED
fi
# check ipv6 items only
[ "$INNER_CHECK" = "true" ] && checkIpv6ItemsOnly
#

if [ -f "$STEPS_FILE" ]; then # for extending node through UI
    echo -e "$PRODUCT_SHORT_NAME installation pre-check ...... [ ALREADY DONE ]"
    exit 0
fi
[ ! -d "$TMP_FOLDER" ] && mkdir -p $TMP_FOLDER
[ "$NODE_TYPE" != "first" -a -f "$logfile" ] && /usr/bin/rm -f $logfile
[ "$STANDALONE_FLAG" = "true" ] && initParametersForStandalone
checkAll
if [[ $PRECHECK_FAILURE -gt 0 ]]; then
    printHintMsg
    exit 1
else
    if [ $PRECHECK_WARNING -gt 0 ]; then
        if [ "$SKIP_WARNING" = "true" ]; then
            printHintMsg
            cleanK8sHome && exit 0 || log "fatal" "Failed to clean $CDF_HOME. Please clean it manually."
        else
            if [ "$NODE_TYPE" = "first" -a "$STANDALONE_FLAG" = "false" ]; then
                echo -e "! Got $PRECHECK_WARNING warning(s) during precheck;\nEither fix the configuration or explicitly enable the skip warnings option."
                cleanK8sHome && exit 2 || log "fatal" "Failed to clean $CDF_HOME. Please clean it manually."
                # read -p "! Got $PRECHECK_WARNING warning(s) during precheck; do you want to skip and continue (Y/N):" confirm
                # if [ "$confirm" != 'y' -a "$confirm" != 'Y' ]; then
                #     exit 2
                # else
                #     cleanK8sHome && exit 0 || log "fatal" "Failed to clean $CDF_HOME. Please clean it manually."
                # fi
            else
                printHintMsg
                echo -e "! Got $PRECHECK_WARNING warning(s) during precheck;\nEither fix the configuration or explicitly enable the skip warnings option."
                exit 2
            fi
        fi
    else
        printHintMsg
    fi
fi
