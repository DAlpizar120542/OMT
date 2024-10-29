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
ITOM_CDF_FILE="$HOME/itom-cdf.sh"
if [[ -f $ITOM_CDF_FILE ]]; then
    source $ITOM_CDF_FILE 2>/dev/null
fi

CURRENTDIR=$(cd `dirname $0`; pwd)
CONFIRM="false"
MAX_RETRY=3
FAIL_CNT=0

usage() {
    echo "Usage: $0 [-y|--yes] [-H|--cdf-home <CDF home>]"
    echo "       -H|--cdf-home     CDF home folder.(Default value is \"\$HOME/cdf\")"
    echo "       -y|--yes          Answer yes for any confirmations. (Default value is \"no\")"
    echo "       -h|--help         Show help."
    exit 1
}
installCdfEnv(){
    local user_profile=""
    if [[ -f "$HOME/.bashrc" ]];then
        user_profile="$HOME/.bashrc"
    elif [[ -f "$HOME/.bash_profile" ]];then
        user_profile="$HOME/.bash_profile"
    elif [[ -f "$HOME/.profile" ]];then
        user_profile="$HOME/.profile"
    else
        user_profile="$HOME/.bash_profile"
        echo "" > "$user_profile"
        chmod 644 "$user_profile"
    fi

    if [ $(cat "$user_profile" 2>/dev/null | grep -P '^ *. \$HOME/itom-cdf.sh' | wc -l) -eq 0 ];then
        echo "
. \$HOME/itom-cdf.sh
. $CDF_HOME/scripts/itom-cdf-alias.sh
    " >> "$user_profile"
    fi
}

copyFilesFromStandard(){
    #     scripts/refresh-ecr-secret.sh
    $CP -f $CURRENTDIR/uninstall.byok.sh ${CDF_HOME}/uninstall.sh
    if [ $? -ne 0 ]; then
        echo "Fatal: Failed to copy uninstall.sh from $CURRENTDIR/uninstall.byok.sh to ${CDF_HOME}/uninstall.sh."
        FAIL_CNT=$((FAIL_CNT+1))
    fi
    chmod u+x ${CDF_HOME}/uninstall.sh

    $RM -rf $CDF_HOME/bin/*
    $RM -rf $CDF_HOME/scripts/*
    $RM -rf $CDF_HOME/tools/*
    $RM -rf $CDF_HOME/charts/* $CDF_HOME/properties/* $CDF_HOME/cfg/*

    local files="
        bin/cdfctl
        bin/cmd_wrapper
        bin/helm
        bin/jq
        bin/notary
        bin/yq
        bin/aws-ecr-create-repository
    cdf/bin/updateExternalDbInfo

    cdf/cfg/
    cdf/charts
    cdf/properties

        scripts/certCheck
        scripts/checkNFS.sh
        scripts/downloadimages.sh
        scripts/generate_secrets
        scripts/generateSilentTemplate
        scripts/uploadimages.sh
    cdf/scripts/alertmanager
    cdf/scripts/cdfctl.sh
    cdf/scripts/gen_secrets.sh
    cdf/scripts/gs_utils.sh
    cdf/scripts/itom-cdf-alias.sh
    cdf/scripts/renewCert
    cdf/scripts/replaceExternalAccessHost.sh
    cdf/scripts/setupNFS.sh
    cdf/scripts/volume_admin.sh
    cdf/scripts/backup_recover.sh

        tools/generate-download
    cdf/tools/postgres-backup
    cdf/tools/silent-install/silent_main.sh

    install
    version.txt
    version_internal.txt
    "
    for file in $(echo $files|xargs);do
        local src="$CURRENTDIR/$file"
        local dest="${CDF_HOME}/$(echo $file|sed -r 's#^cdf/##')"
        if [[ -d "$src" ]];then
            $MKDIR -p $src
            $CP -rf $src $dest
        else
            $MKDIR -p "$(dirname $dest)"
            $CP -f $src $dest
        fi
        if [ $? -ne 0 ]; then
            echo "Fatal: Failed to copy $file from $src to $dest."
            FAIL_CNT=$((FAIL_CNT+1))
        fi
    done
}

copyFilesFromBYOK(){
    local bin2bin="cdfctl  cmd_wrapper  helm  jq yq notary  updateExternalDbInfo aws-ecr-create-repository velero changeRegistry deployment-status.sh kube-common.sh cdfcert"
    local bin4AllUser="aws-ecr-create-repository cdfctl changeRegistry cmd_wrapper deployment-status.sh helm  jq notary updateExternalDbInfo velero yq cdfcert"
    local scripts2scripts="alertmanager          downloadimages.sh
                         refresh-ecr-secret.sh   uploadimages.sh              cdfctl.sh
                         gen_secrets.sh          replaceExternalAccessHost.sh generate_secrets
                         gs_utils.sh             setupNFS.sh                  certCheck
                         generateSilentTemplate  itom-cdf-alias.sh            checkNFS.sh
                         volume_admin.sh         renewCert                    backup_recover.sh
                         cleanRegistry"
    local scripts4AllUser="alertmanager cdfctl.sh certCheck downloadimages.sh generate_secrets generateSilentTemplate gen_secrets.sh
                           gs_utils.sh itom-cdf-alias.sh renewCert replaceExternalAccessHost.sh uploadimages.sh volume_admin.sh"
    local tools2tools="postgres-backup silent-install generate-download support-tool"
    local tools4AllUser="generate-download postgres-backup"
    local cdf2top="charts properties cfg"
    local top2top="install uninstall.sh image_pack_config.json version.txt version_internal.txt"

    $MKDIR -p $CDF_HOME/bin  $CDF_HOME/scripts  $CDF_HOME/tools
    $RM -rf $CDF_HOME/bin/*
    $RM -rf $CDF_HOME/scripts/*
    $RM -rf $CDF_HOME/tools/*
    $RM -rf $CDF_HOME/charts/* $CDF_HOME/properties/* $CDF_HOME/cfg/*

    for file in ${top2top[@]};do
        if [ -f "$CURRENTDIR/$file" ];then
            $CP "$CURRENTDIR/$file" $CDF_HOME/
            if [ $? -ne 0 ];then
                FAIL_CNT=$((FAIL_CNT+1))
            fi
        else
            echo "Warning: $CURRENTDIR/file not found!";
            FAIL_CNT=$((FAIL_CNT+1))
        fi
    done

    for binary in ${bin2bin}; do
        if [ -e "$CURRENTDIR/bin/$binary" ];then
            $CP $CURRENTDIR/bin/$binary $CDF_HOME/bin/$binary
            if [ $? -ne 0 ];then
                FAIL_CNT=$((FAIL_CNT+1))
            fi
        else
            echo "Warning: $CURRENTDIR/bin/$binary not found!";
            FAIL_CNT=$((FAIL_CNT+1))
        fi
    done
    chmod a+rx $CDF_HOME/bin
    for binary in ${bin4AllUser}; do
        chmod 755 $CDF_HOME/bin/$binary
    done

    for script in ${scripts2scripts}; do
        if [ -e "$CURRENTDIR/scripts/$script" ];then
            $CP $CURRENTDIR/scripts/$script $CDF_HOME/scripts/$script
            if [ $? -ne 0 ];then
                FAIL_CNT=$((FAIL_CNT+1))
            fi
        else
            echo "Warning: $CURRENTDIR/scripts/$script not found!";
            FAIL_CNT=$((FAIL_CNT+1))
        fi
    done
    chmod a+rx $CDF_HOME/scripts
    for script in ${scripts4AllUser};do
        chmod a+rx $CDF_HOME/scripts/$script
    done

    for tool in ${tools2tools}; do
        if [ -d "$CURRENTDIR/tools/$tool" ];then
            $CP -r "$CURRENTDIR/tools/$tool" $CDF_HOME/tools/
            if [ $? -ne 0 ];then
                FAIL_CNT=$((FAIL_CNT+1))
            fi
        else
            echo "Warning: $CURRENTDIR/tools/$tool not found!";
            FAIL_CNT=$((FAIL_CNT+1))
        fi
    done

    chmod -R a+rx $CDF_HOME/tools
    for tool in $tools4AllUser; do
        chmod -R a+rx $CDF_HOME/tools/$tool
    done

    for dir in ${cdf2top}; do
        if [ -d "$CURRENTDIR/cdf/$dir" ];then
            $CP -r "$CURRENTDIR/cdf/$dir" $CDF_HOME/
            if [ $? -ne 0 ];then
                FAIL_CNT=$((FAIL_CNT+1))
            fi
        else
            echo "Warning: $CURRENTDIR/cdf/$dir not found!";
            FAIL_CNT=$((FAIL_CNT+1))
        fi
    done

}

copyTools(){
    $MKDIR -p $CDF_HOME/bin  $CDF_HOME/scripts  $CDF_HOME/tools
    $RM -rf $CDF_HOME/bin/*
    $RM -rf $CDF_HOME/scripts/*
    $RM -rf $CDF_HOME/tools/*

    if [[ -d "$CURRENTDIR/k8s" ]];then
        copyFilesFromStandard
    else
        copyFilesFromBYOK
    fi

    chmod -R u+x ${CDF_HOME}/install ${CDF_HOME}/uninstall.sh ${CDF_HOME}/scripts ${CDF_HOME}/bin
    ClearCdfEnvIfExist
    installCdfEnv
}

ClearCdfEnvIfExist(){
    local profile=
    [[ -f "$HOME/.bash_profile" ]] && profile="$HOME/.bash_profile" || profile="$HOME/.profile"
    for user_profile in ${profile} "$HOME/.bashrc";do
        sed -i -r -e '/^ {0,}(\.|source) {0,}[^ ]{1,}\/itom-cdf\.sh/d' "$user_profile"
        sed -i -r -e '/^ {0,}(\.|source) {0,}[^ ]{1,}\/itom-cdf-alias\.sh/d' "$user_profile"
    done
}

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

for command_var in CP RM MKDIR ; do
    command="$(echo $command_var|tr '[:upper:]' '[:lower:]')"
    command_val=$(findCommand "$command")
    if [[ $? != 0 ]] ; then
        NOTFOUND_COMMANDS+=($command)
    fi
    eval "${command_var}=\"${command_val}\""
    export $command_var
done

if [[ ${#NOTFOUND_COMMANDS[@]} != 0 ]] ; then
    write_log "warn" "! Warning: The '${NOTFOUND_COMMANDS[*]}' commands are not in the /bin or /usr/bin directory, the script will use variable in the current user's system environment."
    read -p "Are you sure to continue(Y/N)?" confirm
    if [ "$confirm" != 'y' -a "$confirm" != 'Y' ]; then
        exit 1
    fi
fi

while [[ ! -z $1 ]] ; do
  case "$1" in
    -H|--cdf-home)
    case "$2" in
        -*) echo "-H|--cdf-home parameter requires a value. " ; exit 1 ;;
        *)  if [[ -z $2 ]] ; then echo "-H|--cdf-home parameter requires a value. " ; exit 1 ; fi ; cdf_home=$2 ; shift 2 ;;
    esac ;;
    -y|--yes)
        CONFIRM=true;shift 1;;
    *|-*|-h|--help|/?|help)
        if [[ "$1" != "-h" ]] && [[ "$1" != "--help" ]] && [[ "$1" != "help" ]] ; then
            echo "invalid parameter $1"
        fi
        usage;;
  esac
done

if [ -z "$CDF_HOME" ] && [ -z "$cdf_home" ];then
    CDF_HOME=$HOME/cdf
elif [ -z "$CDF_HOME" ] && [ -n "$cdf_home" ]; then
    CDF_HOME=$cdf_home
else
    if [ -n "$cdf_home" ];then
        if [ "$CDF_HOME" != "$cdf_home" ];then
            echo "Fatal: The provided CDF_HOME folder confilcts with the value defined in $ITOM_CDF_FILE!"; exit 1
        fi
    fi
fi

if [ ! -d $HOME ];then
    echo "Fatal: HOME folder not found!"; exit 1
fi
$MKDIR -p $CDF_HOME
if [ $? -ne 0 ];then
    echo "Fatal: failed to create folder: $CDF_HOME"; exit 1
fi
if [ "$CONFIRM" == "false" ]; then
    for((i=0;i<$MAX_RETRY;i++)); do
        echo "Warning: tools will be copied to $CDF_HOME."
        if [ -d $CDF_HOME/bin ] || [ -d $CDF_HOME/scripts ] || [ -d $CDF_HOME/tools ]; then
            echo "Warning: All the files under the following folders will be removed: $CDF_HOME/bin $CDF_HOME/scripts $CDF_HOME/tools."
        fi
        read -p "Are you sure to continue? (Y/N): " answer
        answer=$(echo "$answer" | tr '[A-Z]' '[a-z]')
        case "$answer" in
            y|yes ) break;;
            n|no )  echo "Fatal: copy tools process QUIT."; exit 1; ;;
            * )     echo "Warn: unknown input, Please input Y or N";;
        esac
        if [[ $i -eq $MAX_RETRY ]];then
            echo "fatal: error input for $MAX_RETRY times Copy tools process QUIT." ; exit 1;
        fi
    done
fi

copyTools
if [ $FAIL_CNT -eq 0 ];then
    echo "Tool copy done! Tools are copied to $CDF_HOME."
    exit 0
else
    echo "Tool copy failed!"
    exit 1
fi