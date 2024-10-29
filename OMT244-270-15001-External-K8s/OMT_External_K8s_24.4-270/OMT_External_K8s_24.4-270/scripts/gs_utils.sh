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

export HELM="${K8S_HOME:-'/opt/kubernetes'}/bin/helm"
export KCTL="${K8S_HOME:-'/opt/kubernetes'}/bin/kubectl"
export JQ="${K8S_HOME:-'/opt/kubernetes'}/bin/jq"
export YQ="${K8S_HOME:-'/opt/kubernetes'}/bin/yq"
# In the case of BYOK the path is /usr/bin/kubectl
[[ -x "$HELM" ]] || HELM="/usr/bin/helm"
[[ -x "$KCTL" ]] || KCTL="/usr/bin/kubectl"
[[ -x "$JQ" ]] || JQ="/usr/bin/jq"
[[ -x "$YQ" ]] || YQ="/usr/bin/yq"
# Default to what is set in the path if we still don't have an executable
[[ -x "$HELM" ]] || HELM=helm
[[ -x "$KCTL" ]] || KCTL=kubectl
[[ -x "$JQ" ]] || JQ=jq
[[ -x "$YQ" ]] || YQ=yq

###
# Colors used for echo parameters
NO_COLOR='""'
BLACK=0
RED=1
GREEN=2
YELLOW=3
BLUE=4
PURPLE=5
TEAL=6
LIGHT_GREY=7
### Echo with colors (expects MESSAGE,COLOR,NUMBER_OF_INDENTS)
ECHO()
{
local MSG="$1"
local ON OFF INDENT

   [[ -n "$3" ]] && INDENT="$(printf %${3}s '')"
   [[ -n "$2" ]] && ON=$(GET_COLOR "$2") && OFF=$(GET_COLOR)
   echo -e "${INDENT}${ON}${MSG}${OFF}" >&2
}

EXIT()
{
    [[ -n "$1" ]] && echo "ERROR: $1" >&2
    #kill 0
    exit ${2:-0}
}

### Logging (expects LOGFILE,USECOLOR as exported vars)
GET_COLOR()
{
   [[ -n "$USECOLOR" ]] || return
   local c=${1:-0}
   local b=${2:-0}
   [[ -n "$1" ]] && c="3$c"
   echo "[${b};${c}m"
}

LOG()
{
local MSG NOW=$(date +%F_%T.%N | sed 's/......$//')
local ON OFF

   [[ -n "$3" ]] && ON=$(GET_COLOR "$3") && OFF=$(GET_COLOR)

   MSG="${NOW} ${1}"
   [[ "$2" ==  "nolog" ]] || echo -e "${MSG}" >> "$LOGFILE"
   [[ "$2" ==  "noecho" ]] || echo -e "${ON}${MSG}${OFF}" >&2
}

ERR()
{
   LOG "[ ERR] $1" "$2" $RED
}

WARN()
{
   LOG "[WARN] $1" "$2" $YELLOW
}

INFO()
{
   LOG "[INFO] $1" "$2" $TEAL
}

GET_VAULT_VALUE()
{
local KEY="${1:-idm_transport_admin_password}" apphub_api_pod VAULT_VALUE
apphub_api_pod=$("$KCTL" get pod -n ${CDF_NAMESPACE} | grep "apphub-apiserver" | awk '{print $1}')
VAULT_VALUE=$("$KCTL" exec $apphub_api_pod -n ${CDF_NAMESPACE} -c apphub-apiserver -- get_secret $KEY)

   # VALIDATE
   [[ -z "$VAULT_VALUE" ]] && EXIT "Unable to retrieve $KEY" 1
   [[ $VAULT_VALUE =~ ^PASS= ]] || EXIT "Bad format for value of $KEY" 1
   VAULT_VALUE=${VAULT_VALUE#*=}
   [[ -z "$VAULT_VALUE" ]] && EXIT "$KEY is empty" 1
   echo "$VAULT_VALUE"
}

GET_XAUTH_FILE()
{
   echo "$(cd; pwd -P)/.xauth.$1"
}

CLEAR_XAUTH()
{
local XAUTH_FILE=$(GET_XAUTH_FILE "$1")
   rm -f "$XAUTH_FILE"
}

GEN_XAUTH_TOKEN()
{
local PASS="${1:-Pla+eSpin1}"
local USER="${2:-admin}"
local CREDS='{"passwordCredentials":{'
local TENANT='},"tenantName":"Provider"}'
local DATA="${CREDS}\"username\":\"${USER}\",\"password\":\"${PASS}\"${TENANT}"
local UTA=transport_admin
local HOST_PORT=$(GET_HOST_PORT "itom-idm")
if [[ -z "$HOST_PORT" ]] ;then
    INFO "itom-idm is not running"
    EXIT "Cannot generate XAuth token" 1
fi

local URL="https://${HOST_PORT}/idm-service/v3.0/tokens"
local FILE=$(mktemp .AT.$$.XXX -p /tmp)
local IDM_TAP
local CMD

   IDM_TAP=$(GET_VAULT_VALUE) || exit $?
   CMD=$(CREATE_CURL_CMD "$URL" "@$FILE" POST)
   echo "$DATA" > $FILE
   trap 'echo "removing tempfile" >&2 && rm -f '$FILE 0
   local REPLY_JSON=$(echo -n "user=\"${UTA}:${IDM_TAP}\"" | eval $CMD -K -)
   rm -f $FILE
   trap 0

   # VALIDATE
   [[ -n $REPLY_JSON ]] || EXIT "Use -k option to bypass certs and make insecure SSL connection" 1
   local isSuccessful=$(echo "$REPLY_JSON" | $JQ -r ".isSuccessful?")
   if [ "$isSuccessful" == "false" ];then
      EXIT "Failed to authenticate!" 1
   fi

   local tokenId=$(echo "$REPLY_JSON" | $JQ -r ".token.id?")
   if [ -z "$tokenId" ] || [ "$tokenId" == "null" ];then
      EXIT "Unknown Error::Bad format for value of REPLY_JSON: $REPLY_JSON" 1
   fi

   # CACHE
   local XAUTH=$(echo "$REPLY_JSON" | $JQ -r ".token.id")
   local XAUTH_FILE=$(GET_XAUTH_FILE "$USER")
   echo "X-AUTH-TOKEN: $XAUTH" > "$XAUTH_FILE"
   echo "$XAUTH_FILE"
}

CHECK_XAUTH_TOKEN()
{
local XAUTH_FILE=$(GET_XAUTH_FILE "$1")
local VALID_FOR="${2:-1800}"
local NOW=$(date +%s)
local FTIME=0

   [[ -r "$XAUTH_FILE" ]] && FTIME=$(stat -c %Y "$XAUTH_FILE")
   (( NOW - FTIME > VALID_FOR )) && rm -f "$XAUTH_FILE" && return
   echo "$XAUTH_FILE"
}

GET_HOST_PORT()
{
local SVC="${1:-apphub-apiserver}"
local HELMVALS HOST PORT KIND HOST_PORT

   if [ -n "$CDF_NAMESPACE" ];then
      # Check if we have helm deployment of apphub
      RELEASE_NAME=$("$HELM" list -n $CDF_NAMESPACE | awk '/apphub-[0-9]/ { print $1 }')

      if [[ -n $RELEASE_NAME ]] ;then
         HELMVALS=$("$HELM" get values -n $CDF_NAMESPACE $RELEASE_NAME)

         HOST=$(echo "$HELMVALS" | "$YQ" eval '.global.externalAccessHost' -)
         [[ $DEBUG -ge 2 ]] && INFO "Found external access host: '$HOST'"

         PORT=$(echo "$HELMVALS" | "$YQ" eval '.global.externalAccessPort' -)
         [[ $DEBUG -ge 2 ]] && INFO "Found external access port: '$PORT'"

         HOST_PORT="${HOST}:${PORT}"

         # VALIDATE running service
         "$KCTL" get services -n $CDF_NAMESPACE $SVC >/dev/null 2>&1
         [[ $? -ne 0 ]] && HOST_PORT=""

      else
      # otherwise try service approach (which takes longer)
         KIND="Service"
         local HOST_PORT=$("$KCTL" get services -n $CDF_NAMESPACE |
            awk '$2~/'"^$SVC$"'/ {print}' |
            awk '$1~/'"^$CDF_NAMESPACE$"'/ {split($6,t,/[:/]/); print $4":"t[1]}')

         # VALIDATE
         [[ -z "$HOST_PORT" ]] ||
            [[ "$HOST_PORT" =~ ^([1-9][0-9]{0,2}\.?){4}:[1-9][0-9]*$ ]] ||
            EXIT "Bad format for service address: $HOST_PORT" 1
      fi
   fi

   [[ -n "$HOST_PORT" ]] && INFO "Service $SVC using $KIND HOST_PORT: ${HOST_PORT}" noecho
   echo "${HOST_PORT}"
}

GET_SERVICE_ADDR()
{
local SVC="${1:-apphub-apiserver}"
local HOST_PORT=$(GET_HOST_PORT "$SVC")

   [[ -n "$HOST_PORT" ]] && echo "https://$HOST_PORT/$SVC"
}

GET_CA_INFO()
{
local HOST=${1:?host is required}
local PORT=${2:?port is required}

   echo "quit" |
      openssl s_client -showcerts -servername ${HOST} -connect ${HOST}:${PORT}
}

CURL_SUPPORTS_FILE_HEADER()
{
local CURL="${1:-curl}"

   $CURL --help | grep -qs -- '--header.*@file'
}

CURL_TRUSTS_SERVICE_CERT()
{
   local SVC="${1:?'service required for checking trust'}"
   local CURL="${2:-curl}"

   [[ "$SVC" =~ http: ]] && return 0
   $CURL "$SVC" >/dev/null 2>&1
   return $?
}

GET_PASS()
{
local INFO="$1"
local DFLT="$2"
local USER
local PASS

   [[ -n "$INFO" ]] && echo "$INFO" >&2
   read -p "username [$DFLT]:" USER >&2
   [[ -z "$USER" ]] && USER="$DFLT"
   [[ -z "$PASS" ]] && read -r -s -p "${USER}'s password:" PASS >&2 && echo >&2
   echo "$USER" "$PASS"
}

CREATE_CURL_CMD_AUTH()
{
local URL="${1:?URL_REQUIRED}"
local TOK="${2:?CACHED_XAUTH_TOKEN_REQUIRED}"

   CREATE_CURL_CMD2 "$@"
}

CREATE_CURL_CMD2()
{
local URL="${1:?URL_REQUIRED}"
local TOK="${2}"
local DATA="${3}"
local REQ="${4:-GET}"
local CURL="${5:-curl}"

local FCMD CMD="'$CURL' -s -S $CURLOPT -K - "
local FCFG CFG="
   request=\"$REQ\"
   url=\"$URL\"
   header=\"content-type: application/json;charset=UTF-8\""

   FCMD="$CMD"
   [[ -n "$DATA" ]] && FCMD="$CMD --data '$DATA'" && CMD="$CMD --data '%data%'"

   if [[ -n "$TOK" ]] ;then
   local HDR="@${TOK}"
      CURL_SUPPORTS_FILE_HEADER "$CURL" || HDR=$(cat $TOK)
      FCFG="$CFG
   header=\"$HDR\""
   fi

   FCMD="printf '%s' '$FCFG' | $FCMD"
   CMD="printf '%s' '$CFG' | $CMD"
   [[ $DEBUG -ge 6 ]] && [[ $DEBUG -lt 9 ]] && INFO "CURL CMD: $CMD"
   [[ $DEBUG -gt 9 ]] && INFO "CURL FCMD: $FCMD" nolog
   echo "$FCMD"
}

CREATE_CURL_CMD()
{
local URL="${1:?URL_REQUIRED}"
local DATA="${2}"
local REQ="${3:-GET}"
local CURL="${4:-curl}"

local CMD="'$CURL' -s -S $CURLOPT \
   --request $REQ \
   --url '$URL' \
   --header 'content-type: application/json;charset=UTF-8'" \

   [[ -n "$DATA" ]] && CMD="$CMD \
   --data '$DATA'"

   [[ $DEBUG -ge 6 ]] && INFO "CURL CMD: $CMD" nolog
   echo "$CMD"
}

EXEC_CURL_CMD_CHECK_STATUS()
{
local CMD="$1"
local ACT="$2"
local EMSG="$3"
local FMSG="$4"
local JSON="$5"
local MSG FAILMSG PRE= POST STATUS

   POST="'\n,\"status\": %{http_code}}'"
   [[ -n "$JSON" ]] && PRE='{"data": '

   VALUE=${PRE}$(eval "$CMD --write-out ${POST}")
   [[ $? -ne 0 ]] &&
      ERR "Failed to execute curl when $ACT -- curl error" &&
      echo "VALUE='$VALUE'" && exit 1

   # Handle case where returned data is not JSON
   STATUS=$(echo "$VALUE" | tail -1)
   [[ -z "$JSON" ]] && VALUE=$(echo "$VALUE" | head -n -1)
      #sed -e 's@^\({"data": \)@\1"@' -e 's@^\(,"status": \)\(.*\)}@"\1"\2"}@')

   #-------------------------------------------------------------------------
   # Check http STATUS
   #
   STATUS=$(echo "$STATUS" | awk -F: '{print $2}' | tr -d \} | xargs)
   INFO "HTTP STATUS: $STATUS"

   if [[ $? -ne 0 ]] || [[ "$STATUS" -eq 400 ]]; then
      ERR "$EMSG"
      FAILMSG=$(eval echo "$FMSG")
      WARN "$FAILMSG"

      MSG=$(echo "$VALUE" |
         $JQ -e '..|.message|select(length>0)' 2>/dev/null | $TR) &&
         FAILMSG=$(B64_DECODE_VAL "${MSG}")

      CODE=$(echo "$VALUE" |
         $JQ -e '..|.code|select(length>0)' 2>/dev/null | $TR | xargs) &&
         FAILMSG="[${FAILMSG}] [${CODE}]\n"

   elif [[ -n "$STATUS" ]] && [[ "$STATUS" -ne 200 ]] && [[ "$STATUS" -ne 201 ]] && [[ "$STATUS" -ne 204 ]] ;then
      FAILMSG="Bad Status ($STATUS) when $ACT"
   fi

   [[ -n "$FAILMSG" ]] &&
      ERR "$FAILMSG" &&
      exit 1

   echo "$VALUE"
}

export B64="b64:"
GET_VK_YAML_CONTENTS()
{
local FILE="${1}"
local NAME="${FILE##*/}"
local VKY_CNAME=${2:-YAML}
local VKY_FNAME=${3}
local VKYAML_CONT
local CYAML_CONT
local VYAML_CONT
local VKYAML
local TOPDIR
local TMPF=$(mktemp .VY.$$.XXX -p /tmp)

    #Get the VKYAML contents from the tgz
    INFO "Obtaining the required information from ${NAME}..."
    VKYAML=$(tar tf "${FILE}" 2>/dev/null | grep -m1 '/_.*vk.yaml')

    [[ -z "$VKYAML" ]] &&
       WARN "Cannot find the _vk.yaml file in '${NAME}' and check suite document if it needs." &&
       exit 1

    if [[ -n "$VKYAML" ]]; then
       # Find vk_yaml -- there must only be one
       TOPDIR=${VKYAML%%/*}
       [[ $DEBUG -ge 2 ]] && INFO "TOPDIR: $TOPDIR" nolog

       [[ -n "$CUST_SEC_NAME" ]] &&
          INFO "Using SECRET name: $CUST_SEC_NAME"

       # Get initSecrets name from values.yaml
       [[ -z "$CUST_SEC_NAME" ]] &&
       VYAML_CONT=$(tar -zxOf "${FILE}" "${TOPDIR}/values.yaml")
       [[ $? -eq 0 ]] &&
          CUST_SEC_NAME=$(echo "$VYAML_CONT" |
             awk '/^ +initSecrets: ?/ {print $2}') &&
          [[ -n "$CUST_SEC_NAME" ]] &&
          INFO "Found SECRET name: $CUST_SEC_NAME"

       # Get Suite name from Chart.yaml
       [[ -z "$CUST_SEC_NAME" ]] &&
       CYAML_CONT=$(tar -zxOf "${FILE}" "${TOPDIR}/Chart.yaml")
       [[ $? -ne 0 ]] && [[ -z "$CUST_SEC_NAME" ]] &&
           ERR "Failed to read 'Chart.yaml' in '${NAME}'" &&
           LOG "Partial: '${CYAML_CONT}'" nolog &&
           EXIT "" 1

       # set global SUITE for use when creating secrets
       [[ -z "$CUST_SEC_NAME" ]] &&
       SUITE=$(echo "${CYAML_CONT}" | sed -n 's/^name://p' | xargs) &&
       INFO "Found SUITE name: $SUITE"
    fi
    [[ -n "${VKYAML}" ]] && INFO "Using the detected yaml file ${VKYAML}"

    VKYAML_CONT=$(if [[ -n "$VKYAML" ]]; then
       tar -zxOf "${FILE}" "$VKYAML"
    else
       cat "${FILE}"
    fi |
        awk -F: 'BEGIN {tmpf='\"$TMPF\"'; sep=": "; comment="[ 	]+#.*$"; }
        /^[ 	]*#/ { next; }
        $0~comment {
               i= index($0, sep);
               key= substr($0, 1, i-1);
               val= substr($0, i+2);
               sub("^[ 	]*", "", val);
               if (!sub(comment, "", val)) sub("^#.*", "", val);
               $0= sprintf("%s%s%s\n", key, sep, val);
           };
        /description:/  {gsub('"/'/"',"\\x27"); gsub(/"/,"\\x22")};
        /specialChars:/ {split($0, t, /:[       ]+/);
           cmd= sprintf("base64 > %s",tmpf);
           printf("%s", t[2])| cmd; close(cmd);
           getline x <tmpf; close(tmpf);
           printf("%s: '$B64'%s\n",$1,x);
           next;
        }
        {print}')


    [[ $? -ne 0 ]] &&
        ERR "Failed to read the Vault Keys yaml file in '${FILE}'" &&
        LOG "Partial: '${VKYAML_CONT}'" nolog &&
        exit 1
    rm -f "$TMPF"

    [[ -z "$VKYAML" ]] && VKYAML="$FILE"
    eval "$VKY_CNAME='${VKYAML_CONT}'"
    [[ -n "${VKY_FNAME}" ]] && eval "$VKY_FNAME='${VKYAML}'"
    INFO "Done\n"

}

CREATE_K8S_SECRET()
{
local SECRETS="$1"
local PRESERVE="${2:-YES}"
local SNAME=$(echo $3 | sed -e 's%\"%%g')
local MSG="Failed to create the K8s secret"
local OUT

   INFO "Creating K8s secret '${SNAME}'..."

   if [[ "YES" == "$PRESERVE" ]] ;then
      INFO "Checking if K8s secret already exists..."
      "$KCTL" get secrets/$SNAME -n "$NAMESPACE" >&/dev/null
      [[ $? -eq 0 ]] &&
         ERR "$MSG: $SNAME. Secret name already exists." nolog &&
         ERR "$MSG - Secret name already exists." noecho &&
         exit 1
   else
      WARN "Overwriting the existing K8s secrets for ${SNAME}..."
   fi

   OUT=$(echo -e "$SECRETS" |
      awk "/metadata:/,/type:/ {sub(/:.+-secret/, \": $SNAME\")}; /./" |
      "${KCTL}" apply --namespace "$NAMESPACE" -f - 2>&1 )
   [[ $? -ne 0 ]] &&
      ERR "$MSG. Reason: $OUT" && ERR "$SECRETS" nolog && exit 1

   INFO "Secret name: "${SNAME}"" nolog
   INFO "Done\n"
}

#
# READ() is based on original code from Andrei--
#        it is currently unused as chars can slip
#        in between the single char reads if typing is fast
READ()
{
local PROMPT="$1"
local VALUE="${2:-REPLY}"
local IN= _c

   echo -n "$PROMPT" >&2
   while IFS= read -r -s -n1 _c; do
      case "$_c" in
         $'\x7f')
            [[ -n "$IN" ]] && IN=${IN%?} && printf '\b \b'
            ;;
         $'\x15')
            for ((x=${#IN}; x>0; x--)); do printf '\b \b' ;done
            IN=
            ;;
         "")
            printf '\n'
            break
            ;;
         *)
            IN+=$_c
            printf '*'
            ;;
      esac
   done
   eval "$VALUE='$IN'"
}

B64_ENCODE()
{
local VAL="$1"

   [[ -n "$VAL" ]] &&
      VAL=$(echo -n "$VAL" |base64) &&
      VAL="${B64}$VAL"

   echo "$VAL"
}

B64_DECODE_VAL()
{
local PAT CHR REQ="$1"

   if [[ "$REQ" =~ :.*$B64 ]] ;then
      PAT="${REQ%$B64*}"
      CHR=$(echo "${REQ}" | sed 's@.*:[ 	]*'"$B64"'@@' | base64 -d)
      REQ="${PAT}${CHR}"
   fi
   echo "$REQ"
}

MSG1="Note: You can just press <ENTER> to generate a randomized password value."
MSG2="(In this case, a mixed-case password of at least 8 characters with 1 or"
MSG3="more digits and 1 or more printable special characters will be generated.)"
GET_INPUT_FOR_SECRET()
{
local OBJ="$1"
local FAIL="$2"
local NAME DESC CPLX PASS REQ_COLOR MK
   REQS=$(GET_SECRETS_REQS "$OBJ" YES)
   NAME=$(echo "$OBJ" |
      awk '/"name":/ {sub(/,$/,""); print $2; exit}' | xargs -0)
   DESC=$(echo "$OBJ" |
      awk '{if (sub(/^.*"description":/,"")) {sub(/,$/,""); print; exit}}' | xargs -0)
   CPLX=$(echo "$OBJ" |
      awk -F: '/"complexity":/ {sub(/,$/,""); print $2; exit}' | xargs -0)
   [[ $DEBUG -ge 8 ]] && INFO "$REQS"

   [[ -n "$FAIL" ]] &&
      WARN "Complexity Requirements Not Met-- Please try again."
   ECHO "\n->KEY: $NAME" $GREEN
   DESC=$(echo -e "$DESC")
   ECHO "$DESC" $GREEN
   ECHO "The required complexity for this password is: $CPLX" $NO_COLOR 2
   [[ "${CPLX,,}" =~ optional ]] &&
      ECHO "$MSG1" $NO_COLOR 2 && [[ "${CPLX,,}" =~ none ]] &&
      ECHO "$MSG2" $NO_COLOR 5 && ECHO "$MSG3" $NO_COLOR 5
   ECHO "The password must meet the following requirements:" $NO_COLOR 2
   echo "$REQS" | $TR | xargs -0 -l1 2>/dev/null | while read REQ
   do
      local PAT="${REQ%%:*}"
      if [[ $REQ =~ ^"Cannot contain any special" ]] ; then
         REQ=${REQ%% in:*}
      else
         REQ=$(B64_DECODE_VAL "$REQ")
      fi
      REQ_COLOR=$TEAL
      MK=''
      [[ "$FAIL" =~ "$PAT" ]] && REQ_COLOR=$YELLOW && MK='*'
      ECHO "${MK}${REQ}" $REQ_COLOR 4
   done
   # handle extra chars (not shown by default)
   [[ $DEBUG -ge 9 ]] && [[ -n "$FAIL" ]] && ECHO "$FAIL"
   [[ "$FAIL" =~ "extra" ]] && MK='*' && REQ=$(echo "$FAIL" | grep extra) &&
      REQ=$(B64_DECODE_VAL "$REQ") &&
      ECHO "${MK}${REQ}" $YELLOW 4

   while true ; do
      read -r -s -p "Password: " PASS
      ECHO
      [[ ! "$PASS" =~ ^$B64 ]] && break
      ECHO "Invalid: Password cannot begin with '$B64'" $RED
   done

   echo "$PASS"
}

GET_SECRETS_LEN()
{
local JSON="$1"

   #ARGS='.|length'
   #JQCMD="$JQ '$ARGS'"
   #[[ $DEBUG -ge 8 ]] && INFO "JQCMD is: $JQCMD"

   #echo "$JSON" | $JQ "$ARGS" | $TR | xargs
   echo "$JSON" | awk '/^[    ]*"name": "/ {count++}; END {print count}'
}

GET_SECRETS_OBJ()
{
local JSON="$1"
local IDX=${2:-0}
local JQCMD ARGS

   #ARGS=$(printf '.[%s]' "$IDX")
   #JQCMD="$JQ '$ARGS'"
   #[[ $DEBUG -ge 8 ]] && INFO "JQCMD is: $JQCMD"

   #echo "$JSON" | $JQ "$ARGS"
   echo "$JSON" |
      awk '/^  \{/ {idx=x++};
           /^  \}/ {sub(/,.*$/,"")};
           /^  \{/,/^  \}/ {if ('"$IDX"'==idx) print; if ('"$IDX"'<idx) exit;}'
}

GET_SECRETS_REQS()
{
local JSON="$1"
local RM_EX="${2:+|select(.characterType!=\"EXTRA\")}"
local JQCMD ARGS

   ARGS=$(printf '.requirements[]%s|with_entries(select(.key|match("message";"i")))[]' "$RM_EX")
   JQCMD="$JQ '$ARGS'"
   [[ $DEBUG -ge 8 ]] && INFO "JQCMD is: $JQCMD"
   echo "$JSON" | $JQ "$ARGS" |xargs -0 -l1

}

QUERY_AND_VALIDATE_SECRETS()
{
local URL="${1}"
local SECRETS="${2}"
local VK_YAML="${3}"
local INCLUDE="${4}"

local OBJ OBJ_FOR_DATA NAME CPLX FMT VALID MSG SEC MAX
local PASS PASS4DATA DATA CMD REPLY_JSON CONFIRM ESC_2Q GEN_DATA
local last x i j=0

   SEC='"secrets": {'
   MAX=$(GET_SECRETS_LEN "$SECRETS")

   if [[ $MAX -le 0 ]]; then
      [[ -n "${CHART}" ]] && WARN "No user-settable secrets to ask for in ${CHART#*/}"
      [[ -z "${CHART}" ]] && WARN "No user-settable secrets to ask for in the specified yaml"
      MAX=0
   fi

   for ((i=0; i<$MAX; i++))
   do
      OBJ=$(GET_SECRETS_OBJ "$SECRETS" $i )
      NAME=$(echo "$OBJ" | $JQ '.name' | $TR | xargs)
      # if updating, only query keys in $INCLUDE
      [[ -z "$INCLUDE" ]] || echo "$INCLUDE" | grep -q "^${NAME}\$" || continue
      ((last[j++]=i-1))

      # strip requirements data
      OBJ_FOR_DATA=$(echo "$OBJ" | $JQ '.requirements=null' |
         sed -e 's@\\*x27@@g' -e 's@\\*x22@@g')
      CPLX=$(echo "$OBJ" |
         awk -F: '/"complexity":/ {sub(/,$/,""); print $2; exit}' | xargs -0)
      FMT="[{\"secret\": $OBJ_FOR_DATA, \"value\":\"%s\"}]"

      VALID=
      MSG=
      until [[ "$VALID" =~ "true" ]] ;do
         #
         # Prompt for input
         #
         PASS=$(GET_INPUT_FOR_SECRET "$OBJ" "$MSG")
         if [[ "$PASS" =~ ^$'\x02' ]] ;then
            ECHO "Backing up..." $YELLOW
            # min for j is 1 (don't back up past the beginning)
            ((x=1==j?1:2, i=last[j-=x]))
            MSG=
            continue 2
         fi
         PASS4DATA=$(B64_ENCODE "$PASS")
         DATA=$(printf "$FMT" "$PASS4DATA")

         #
         # Validate it
         #
         [[ -z "$PASS" ]] && [[ "${CPLX,,}" =~ optional ]] && break
         CMD=$(CREATE_CURL_CMD_AUTH "$URL" "$TOK" "$DATA" GET) || exit $?
         REPLY_JSON=$(eval "$CMD")
         [[ $? -ne 0 ]] &&
            ERR "Failed to get validation reply -- curl error" && exit 1
         MSG=$(echo "$REPLY_JSON" | $JQ '.[].message' | xargs -0 echo -e)
         MSG=$(echo "$MSG" | sed -e 's@^null.?$@@' )
         [[ $DEBUG -ge 7 ]] && WARN "Unmet Requirements: ${MSG:-none}"
         VALID=$(echo "$REPLY_JSON" | $JQ '.[].valid')

         #
         # Confirm it
         #
         if [[ "$VALID" =~ "true" ]] && [[ -n "$PASS" ]] ;then
            read -r -s -p " Confirm:" CONFIRM
            ECHO
            [[ "$CONFIRM" != "$PASS" ]] && VALID=false && MSG="" &&
               WARN "Password and Confirm values didn't match, please try again."
         fi
      done
      ECHO '--OK'
      #
      # Keep validated entries for generating yaml file
      #
      SEC=$(printf '%s "%s": "%s",' "$SEC" "$NAME" "$PASS4DATA")
      #ECHO "SEC now: '$SEC'"
   done

   #-------------------------------------------------------------------------
   # Format data for yaml file generation request
   #
   # CLEANUP TRAILING COMMA & CLOSE BRACE
   SEC=$(echo "$SEC" | sed 's@,$@@')
   SEC="$SEC }"

   # HANDLE ENCLOSED DOUBLE QUOTES + strip single quotes
   ESC_2Q=$(echo -e "$VK_YAML" | sed -e 's@["]@\\"@g' -e "s@'@@g")
   # HANDLE YAML NEWLINES in JSON
   # Note also that jq does the right thing by
   # keeping only latest values in $SEC (i.e. last one in wins)
   GEN_DATA=$(printf '{ "vkYaml":"%s", %s }' "$ESC_2Q" "$SEC" |
      tr '\n' '\r' | sed 's@\r@\\n@g' | $JQ .)

   echo "$GEN_DATA"
}

GET_XAUTH_TOKEN()
{
local AUTH_USER="$1"
local FORCE_REFRESH="$2"
local USER= PASS INSTR

   INFO "Verifying Authentication Information."
   [[ -n "$FORCE_REFRESH" ]] && INFO "Clearing existing authentication tokens..." && CLEAR_XAUTH "$AUTH_USER"
   local TOK=$(CHECK_XAUTH_TOKEN "$AUTH_USER")
   if [[ -z "$TOK" ]] ;then
      if [[ "$AUTH_USER" == "integration_admin" ]] ;then
         USER="$AUTH_USER"
         PASS=$(GET_VAULT_VALUE idm_integration_admin_password) || exit $?
      fi

      [[ -z "$USER" ]] &&
         INSTR="Please login to AppHub on this cluster." &&
         read USER PASS <<<$(GET_PASS "$INSTR" "$AUTH_USER")

      INFO "Generating token..."
      TOK=$(GEN_XAUTH_TOKEN "$PASS" "$USER") || exit $?
   else
      INFO "Using cached credentials."
   fi
   INFO "Done\n"

   echo "$TOK"
}

