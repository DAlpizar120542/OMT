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


usage() {
    echo "Usage: ./refresh-ecr-secret.sh [-r|--region]"
    echo "       -r|--region           ECR region."
    echo "       -h|--help             Show help."
    exit 1
}
while [[ ! -z $1 ]] ; do
    case "$1" in
        -r|--region )
        case "$2" in
          -*) echo -e "-r|--region parameter requires a value";exit 1 ;;
          * ) if [ -z "$2" ];then echo -e "-r|--region parameter requires a value";exit 1; fi; REGION="$2";shift 2;;
        esac ;;   
        *|-h|--help|/?|help) usage ;;
    esac
done
if [ -z "$REGION" ]; then
    usage
fi
#some aws output its version info to stderr
ITOM_CDF_FILE="$HOME/itom-cdf.sh"
if [[ -f $ITOM_CDF_FILE ]]; then
    source $ITOM_CDF_FILE 2>/dev/null
fi
if [ -z "$CDF_NAMESPACE" ];then
    echo "Error: CDF_NAMESPACE is empty!"
    exit 1
fi
version=$(aws --version 2>&1)

#get major version
version=$(echo $version | awk '{print $1}')
version=${version#*/}
version=(${version//./ })
version=${version[0]}
if [ "$version" == "1" ];then
  loginInfo=$(aws ecr get-login --no-include-email --region $REGION)
  if [[ $? -ne 0 ]] || [[ -z "$loginInfo" ]];then
      echo "Failed to get login info!"
      exit 1
  fi
  userName=$(echo $loginInfo | awk '{print $4}')
  password=$(echo $loginInfo | awk '{print $6}')
  url=$(echo $loginInfo | awk '{print $7}' | awk -F/ '{print $3}')
  auth=$(echo $userName:$password |base64 -w 0)
elif [ "$version" == "2" ];then
  tokenInfo=$(aws ecr get-authorization-token --region $REGION)
  if [ $? -ne 0 ] || [ -z "$tokenInfo" ];then
      echo "Failed to get authorization token!"
      exit 1
  fi
  length=$(echo $tokenInfo | jq -r '.authorizationData|length')
  if [[ $length -le 0 ]];then
      echo "No authorization token found!"
      exit 1
  fi
  url=$(echo $tokenInfo | jq -r '.authorizationData[0].proxyEndpoint' | awk -F/ '{print $3}')
  auth=$(echo $tokenInfo | jq -r '.authorizationData[0].authorizationToken')
else
  echo "Unsupported aws version!"
  exit 1
fi

auths=$(cat <<EOL
{
      "auths": {
    "${url}": {
      "auth": "${auth}"
    }
  }
}
EOL
)
enAuths=$(echo -n "${auths}"|base64 -w 0)

cat > tmpSecret.yaml <<EOL
apiVersion: v1
type: kubernetes.io/dockerconfigjson
kind: Secret
metadata:
  name: registrypullsecret
  namespace: ${CDF_NAMESPACE}
data:
  .dockerconfigjson: ${enAuths}
EOL
kubectl apply -f tmpSecret.yaml