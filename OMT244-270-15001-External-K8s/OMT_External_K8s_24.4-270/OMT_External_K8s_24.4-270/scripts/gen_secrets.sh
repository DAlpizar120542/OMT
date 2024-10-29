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

umask 0177
PROG=${0##*/};
PDIR=${0%/*};  PDIR=${PDIR:-.}
export LOGFILE=/tmp/${PROG}.$(date +%F_%T).log
export USECOLOR=YES
export CURL_CA_BUNDLE
export CURLOPT=

[[ -r ${PDIR}/gs_utils.sh ]] && . ${PDIR}/gs_utils.sh
[[ $? -ne 0 ]] && echo "Missing: gs_utils.sh" >&2 && exit 1

INTRO()
{
local ON=$(GET_COLOR 4 1)
local OFF=$(GET_COLOR)

   echo -n "${ON}"
   echo "    ___                __  __      __"
   echo "   /   |  OpenText    / / / /_  __/ /_"
   echo "  / /| | / __ \/ __ \/ /_/ / / / / __ \\"
   echo " / ___ |/ /_/ / /_/ / __  / /_/ / /_/ /"
   echo "/_/  |_/ .___/ .___/_/ /_/\__,_/_.___/"
   echo "      /_/   /_/ Helm Secrets Utility"
   echo "LOG is: $LOGFILE"
   echo "${OFF}"
}

USAGE()
{
   [[ -n "$1" ]] && ECHO "$1" $BLUE
   [[ $DEBUG -eq 0 ]] &&
      ECHO "Usage: $PROG [-vNhku][-c <chart.tgz>][-y <in.yaml>][-o <out.yaml>][-n <namespace>][-s <secret>][-C <ca_cert.crt>] " $TEAL
   [[ $DEBUG -gt 0 ]] &&
      ECHO "Usage: $PROG [-vNhkufsO][-c <chart.tgz>][-y <in.yaml>][-o <out.yaml>][-n <namespace>][-s <secret>][-C <ca_cert.crt>][-d <level>][-U [<user>]] " $TEAL
   ECHO ""
   ECHO "Conditional: " $GREEN 2
   ECHO "-c|--chart        full path to the helm chart (.tgz file)" $NO_COLOR 4
   ECHO "-y|--yaml         full path to the YAML file to validate (.yaml)" $NO_COLOR 4
   ECHO "-o|--output-yaml  write secrets to YAML output file (only) and do not create secrets" $NO_COLOR 4
   ECHO "-n|--namespace    the namespace where the suite will be deployed;" $NO_COLOR 4
   ECHO "                  required when not using the --validate option" $NO_COLOR 4
   ECHO "-s|--secret       secret name for storing the password values in K8s;" $NO_COLOR 4
   ECHO "                  required if --yaml option is used without --validate" $NO_COLOR 4
   ECHO "-C|--cacert       CA cert file for your K8s external access host;" $NO_COLOR 4
   ECHO "                  required if -k option is not used, or if the environment" $NO_COLOR 4
   ECHO "                  variable CURL_CA_BUNDLE is not previously set & exported." $NO_COLOR 4
   ECHO "                  alternatively, this program will search for the file" $NO_COLOR 4
   ECHO "                  curl-ca-bundle.crt in your home dir and use it if found." $NO_COLOR 4
   ECHO "                  see https://curl.haxx.se/docs/sslcerts.html for more info." $NO_COLOR 4
   ECHO ""
   ECHO "Optional: " $BLUE 2
   ECHO "-k|--insecure     if specified passes the same option to curl;" $NO_COLOR 4
   ECHO "                  allows curl to make insecure SSL connections" $NO_COLOR 4
   ECHO "-u|--upgrade      only modifies new keys (not already present in the secret)" $NO_COLOR 4
   ECHO "--update          Key1,Key2,...KeyN OR @filename (1 key per line)" $NO_COLOR 4
   ECHO "                  only specified keys (and dependent keys) are queried/updated" $NO_COLOR 4
   ECHO "-v|--validate     exits after validating the vault key metadata" $NO_COLOR 4
   ECHO "                  no secrets are created" $NO_COLOR 4
   ECHO "-N|--nocolor      no color (don't use display colors)" $NO_COLOR 4
   ECHO "-h|--help         display this help message" $NO_COLOR 4
if [[ $DEBUG -gt 0 ]] ;then
   ECHO "--strict          update strictly specified keys only (dependent keys are NOT updated)" $NO_COLOR 4
   ECHO "-U                authenticate to idm with specified <user>" $NO_COLOR 4
   ECHO "-f                forces refresh of XAuth token" $NO_COLOR 4
   ECHO "-S                removes some initial output and minimizes messages" $NO_COLOR 4
   ECHO "-O                overwrites existing secrets, prior values are destroyed" $NO_COLOR 4
   ECHO "-d|--debug        requires a parameter for the debug message level (0-10)" $NO_COLOR 4
fi
   ECHO ""
   exit ${2:-0}
}

SVC=$(GET_SERVICE_ADDR "apphub-apiserver")
if [[ -z "$SVC" ]] ;then
   INFO "apphub-apiserver is not running - will run ${PDIR}/generate_secrets instead"
   [[ ! -x "${PDIR}/generate_secrets" ]] && EXIT "${PDIR}/generate_secrets: missing or not executable" 2

   exec ${PDIR}/generate_secrets "$@"
fi

#-------------------------------------------------------------------------
# Parse CMD Line Args
#
NAMESPACE=
CHART=
YAML=
UPDATE=
STRICT=false
AUTH_USER="integration_admin"
FORCE_REFRESH=
PRESERVE=YES
DEBUG=0
while [[ $# -gt 0 ]] ;do
   case "$1" in
      -O)   PRESERVE=NO
            shift
            ;;
      -N|--nocolor)      USECOLOR=
            shift
            ;;
      -y|--yaml)         YAML="$2"
            shift 2
            ;;
      -o|--output-yaml)  OUTPUTYAML="$2"
            shift 2
            ;;
      -k|--insecure)     CURLOPT="-k"
            shift
            ;;
      -C|--cacert)       PROVIDED_CA="$2"
            shift 2
            ;;
      -c|--chart)        CHART="$2"
            shift 2
            ;;
      -n|--namespace)    NAMESPACE="$2"
            shift 2
            ;;
      --strict)          STRICT=true
            shift
            ;;
      --update)          UPDATE=$(echo "$2"| sed 's@,@\n@g') #@filename or Key1,Key2,...KeyN
                         [[ ! "$UPDATE" =~ @.* ]] || UPDATE=$(cat ${UPDATE#?})
                         [[ $? -ne 0 ]] && USAGE "update flag $UPDATE must refer to readable file" 1
            shift 2
            ;;
      -u|--upgrade)      UPDATE=new
            shift
            ;;
      -U)   AUTH_USER="$2"
            shift 2
            ;;
      -f)   FORCE_REFRESH=YES
            shift
            ;;
      -d|--debug)
            [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]] &&
               USAGE "Invalid or missing argument ('${2}') for: $1" 1
            DEBUG="$2"
            shift 2
            ;;
      -S)   SILENT=YES
            shift
            ;;
      -s|--secret)   CUST_SEC_NAME="$2"
            shift 2
            ;;
      -v|--validate) VALIDATE=YES
            shift
            ;;
      -h*|--h*)
            USAGE ""
            ;;
      *)
            USAGE "Unknown option: $1" 1
            ;;
   esac
   [[ $? -ne 0 ]] && USAGE "Missing args for '$1'?" 1
done

# Mandatory validations
[[ -n "$CHART" ]] && [[ -n "$YAML" ]] &&
   USAGE "Specify only one of '-c <chart>' OR '-y <yaml>'" 1
[[ -z "$CHART" ]] && [[ -z "$YAML" ]] &&
   USAGE "Either '-c <chart>' or '-y <yaml>' is required" 1
[[ -z "$NAMESPACE" ]] && [[ -z "$VALIDATE" ]] &&
   USAGE "'-n <namespace>' required" 1
[[ -n "$YAML" ]] && [[ -z "$VALIDATE" ]] && [[ -z "$CUST_SEC_NAME" ]] &&
   USAGE "The '-s <secret>' is required" 1
[[ -z "$CHART" ]] || [[ -r "$CHART" ]] ||
   USAGE "The file '$CHART' not found or unreadable" 1
[[ -z "$YAML" ]] || [[ -r "$YAML" ]] ||
   USAGE "The file '$YAML' not found or unreadable" 1
[[ -n "$PROVIDED_CA" ]] && [[ ! -r "$PROVIDED_CA" ]] &&
   USAGE "The file '$PROVIDED_CA' not found or unreadable" 1
[[ -n "$PROVIDED_CA" ]] && [[ -n "$CURLOPT" ]] &&
   USAGE "Don't specify $CURLOPT in conjunction with '$PROVIDED_CA'" 1

# Hide the intro
[[ -z "$SILENT" ]] && INTRO >&2

# List debug logging
if [[ "$DEBUG" -ge 9 ]] ;then
   WARN "This is a warning."
   ERR "Here is an error."
   INFO "This is an info message."
   LOG "Here is a straight log message!\n"
fi

if [[ -n "$CURLOPT" ]];then
   WARN "Using the -k/--insecure option of curl as specified."
else
   _HOST=${SVC##*//}; _HOST=${_HOST%:*}
   _PORT=${SVC##*:};  _PORT=${_PORT%%/*}
   GS_HOST=${_HOST%%[.]*}
   if [ -n "$PROVIDED_CA" ]; then
      CURL_CA_BUNDLE=$PROVIDED_CA
      CURL_TRUSTS_SERVICE_CERT "$SVC"
      if [ $? -eq 0 ]; then
         #if the provided CA and the cached CA point to a same file, don't copy
         if [[ ! $PROVIDED_CA -ef ~/.gs.${GS_HOST}.curl-ca-bundle.crt ]]; then
            cat $PROVIDED_CA > ~/.gs.${GS_HOST}.curl-ca-bundle.crt
         fi
      else
         ERR "The authenticity of '$_HOST' can't be established with provided CA: $PROVIDED_CA."
         exit 1
      fi
   else
      # 1. Check host-specific name for gen_secrets
      HOST_SPECIFIC_BUNDLE="$(echo ~/.gs.${GS_HOST}.curl-ca-bundle.crt)"
      CURL_CA_BUNDLE=$HOST_SPECIFIC_BUNDLE
      [[ -r "$CURL_CA_BUNDLE" ]] || CURL_CA_BUNDLE=

      # 2. Check global name for curl
      [[ -z "$CURL_CA_BUNDLE" ]] && CURL_CA_BUNDLE="$(echo ~/curl-ca-bundle.crt)"
      [[ -r "$CURL_CA_BUNDLE" ]] || CURL_CA_BUNDLE=

      CURL_TRUSTS_SERVICE_CERT "$SVC"

      if [[ $? -ne 0 ]] ;then
         ECHO "The authenticity of '$_HOST' can't be established." $YELLOW
         if type openssl >&/dev/null; then
            if [ -n "$CURL_CA_BUNDLE" ];then
               ECHO "Clean the cached CA, and recreate a new one." $YELLOW
            else
               ECHO "Try to create a new CA." $YELLOW
            fi

            CERT=$(GET_CA_INFO $_HOST $_PORT 2>/dev/null)
            HEAD=$(echo "$CERT" | openssl x509 -noout -text |
               awk '/Subject:/{print; exit} /./')
            ECHO "Here is a brief summary of the x509 Certificate Information:" $YELLOW
            ECHO "$HEAD\n"
            ECHO "For the following question, you can respond as follows:" $TEAL
            ECHO "y[es], to establish trust (only for $PROG)" $TEAL 2
            ECHO "n[o], to stop" $TEAL 2
            ECHO "v[iew] to view complete x509 certificate information." $TEAL 2
            ECHO "If you are unsure, please answer 'no' and see the " $YELLOW
            ECHO "help or the product documentation for more details." $YELLOW

            #chmod 600 $HOST_SPECIFIC_BUNDLE

            until [[ "$ANS" =~ [nNyY].* ]] ;do
            read -p "Are you sure you want to trust '$_HOST' and continue connecting? [y/n/v]" ANS
               until [[ "$ANS" =~ [nNyYvV].* ]] ;do
                  read -p "Please answer with yes, no, or view [y/n/v]:" ANS
               done

               if [[ "$ANS" =~ [vV].* ]]; then
                  X509_INFO=$(echo "$CERT" | openssl x509 -noout -text)
                  ECHO "$X509_INFO"
                  ANS=
               fi
               if [[ "$ANS" =~ [yY].* ]]; then
                  GET_CA_INFO $_HOST $_PORT > "$HOST_SPECIFIC_BUNDLE" 2>/dev/null
                  chmod 600 "$HOST_SPECIFIC_BUNDLE"
                  CURL_CA_BUNDLE="$HOST_SPECIFIC_BUNDLE"
               fi
            done
         fi

         # 4. warn/err & exit
         [[ -z "$CURL_CA_BUNDLE" ]] &&
            ERR "CURL_CA_BUNDLE is unspecified, secure communication with cluster services will fail." &&
            ECHO "Please set the CURL_CA_BUNDLE environment variable, or use the" $YELLOW 2 &&
            ECHO "-C <ca_cert.crt> command line option.  See the help for more details." $YELLOW 2 &&
            ECHO "Alternatively:" $RED &&
            ECHO "You may bypass secure communication by using the -k|--insecure option of curl." $RED 2 &&
            ECHO "This is done by specifying either of the (-k|--insecure) options on the " $RED 2 &&
            ECHO "$PROG command line. This capability is provided \"as is\"," $RED 2 &&
            ECHO "please see product documentation for further information." $RED 2 &&
            exit 1
      fi
   fi
fi


#-------------------------------------------------------------------------
# Authenticate as needed...
# Get apphub apiserver URL
#
TOK=$(GET_XAUTH_TOKEN "$AUTH_USER" "$FORCE_REFRESH") || exit $?
[[ $DEBUG -ge 2 ]] && INFO "Service is: $SVC"
[[ $DEBUG -ge 2 ]] && INFO "CHART: '${CHART}', YAML: '${YAML}'"

[[ -n "$CHART" ]] && GET_VK_YAML_CONTENTS "$CHART" "VK_YAML" "VK_YAML_PATH"
[[ -n "$YAML" ]] && GET_VK_YAML_CONTENTS "$YAML" "VK_YAML"
[[ -z "$VK_YAML" ]] && exit 1
[[ $DEBUG -ge 9 ]] && INFO "$VK_YAML"

#-------------------------------------------------------------------------
# Try getting secrets info
#
export TR="tr -d '\r'"
URL="${SVC}/secrets?filter=NEEDS_INPUT"
INFO "Querying Secrets"
CMD=$(CREATE_CURL_CMD_AUTH "$URL" "$TOK" "$VK_YAML" POST) || exit $?

[[ -n "${YAML}" ]] &&
   EMSG="The Yaml file '${YAML}' failed validation (status=$STATUS)"
[[ -n "${CHART}" ]] &&
   EMSG="The file '${VK_YAML_PATH}' in '${CHART}' failed validation (status=$STATUS)"
FMSG='YAML validation failed with status=$STATUS'
SECRETS=$(EXEC_CURL_CMD_CHECK_STATUS "$CMD" "posting secrets yaml" "$EMSG" "$FMSG" YES) || exit $?
#ECHO "=SECRETS=\n$SECRETS" $RED

# When validating, if everything went well with our web call then we're done
[[ -n "${YAML}" ]] &&
   INFO "The Yaml file '${YAML}' validated successfully."
[[ -n "${CHART}" ]] &&
   INFO "The file '${VK_YAML_PATH}' in '${CHART}' validated successfully."
[[ -n "$VALIDATE" ]] &&
   exit 0

SECRETS=$(echo "$SECRETS" | $JQ -e '.data' 2>/dev/null | $TR)
[[ $? -ne 0 ]] &&
   ERR "Failed to parse secrets info." && exit 1
[[ $DEBUG -ge 7 ]] && echo "== SECRETS NEEDING INPUT ==" &&
   echo "$SECRETS" | $JQ . && echo

#-------------------------------------------------------------------------
# Determine update info, if any
#
SECRET_NAME=${CUST_SEC_NAME:-$SUITE-secret}
if [[ -n "$UPDATE" ]] ;then
   INFO "Determining Upgrade Information"
   EXIST_SEC_JSON=$(${KCTL} get -n "$NAMESPACE" "secrets/$SECRET_NAME" -o json)
   if [[ $? -ne 0 ]] ;then
      WARN "No existing secrets, cannot proceed with update; reverting to standard install steps."
      UPDATE=
   else
      EXIST_DATA=$(echo "$EXIST_SEC_JSON" | $JQ '.data' |sed 's@_B64": @": @' | $TR)
      [[ $DEBUG -ge 9 ]] && INFO "=DATA=\n$EXIST_DATA"

      if [[ "$UPDATE" == "new" ]] ;then
         UPDATE=$(echo "$SECRETS" | $JQ '.[].name' | xargs -n1 | $TR)
         EXISTING=$(echo "$EXIST_DATA" | $JQ '.|to_entries[]|join(": ")'|
            xargs -l1 | $TR)
         [[ $DEBUG -ge 8 ]] && INFO "=EXISTING=\n$EXISTING"

         INCLUDE=$(echo "$UPDATE" |
            while read CURR ;do
               echo "$EXISTING" | grep -Eq "^(${CURR})(_B64)?:" || echo "$CURR"
            done)
      else
         INCLUDE="$UPDATE"
      fi

      [[ -z "$INCLUDE" ]] &&
         WARN "No Additional Secrets found for Upgrade. Removing any deleted Secrets." &&
         INCLUDE=null

      PRESERVE=NO
   fi

   INFO "Done."
fi
[[ $DEBUG -ge 5 ]] && INFO "=INCLUDE=\n$INCLUDE"

#-------------------------------------------------------------------------
# Parse secrets info, query user, and validate...
#
URL=${SVC}/secrets/validation
GEN_DATA=$(QUERY_AND_VALIDATE_SECRETS "$URL" "$SECRETS" "$VK_YAML" "$INCLUDE")

#-------------------------------------------------------------------------
# GET SECRETS YAML
#
INFO "Requesting Secrets YAML from Server"
URL=${SVC}/secrets/yaml

if [[ -n "$INCLUDE" ]] ;then
   INCL=$(echo "$INCLUDE" | jq --raw-input --slurp 'split("\n")|map(select(length>0))' | $TR)
   GEN_DATA=$(printf '%s,\n"existing": %s,\n"include": %s,\n"strict": "%s"\n}' \
      "${GEN_DATA%??}" "$EXIST_DATA" "$INCL" "$STRICT")
   URL=${URL}-update
fi
[[ $DEBUG -ge 9 ]] && INFO "$GEN_DATA" nolog


CMD=$(CREATE_CURL_CMD_AUTH "$URL" "$TOK" "$GEN_DATA" GET) || exit $?
EMSG="failed to validate provided secrets"
SEC_YAML=$(EXEC_CURL_CMD_CHECK_STATUS "$CMD" "getting secrets yaml" "$EMSG" "$FMSG") || exit $?
[[ $? -ne 0 ]] &&
   ERR "Failed to parse validated secrets data." && exit 1

if [[ -n "$OUTPUTYAML" ]] ;then
    SECRETS_DATA=$(echo -e "$SEC_YAML" | sed -n '/^data:/,$p' | sed 's/data:/secrets:/')
    INFO "Writing the secrets YAML"
    echo "$SECRETS_DATA" > $OUTPUTYAML && exit 0
fi

[[ $DEBUG -ge 8 ]] && INFO "$SEC_YAML" nolog

CREATE_K8S_SECRET "$SEC_YAML" "$PRESERVE" "$SECRET_NAME"
