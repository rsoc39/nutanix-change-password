#!/usr/bin/env bash

###############################################-----HEADER-----########################################################
#   Authors: Joel Goehring and Joseph Blake
#   version: 1.1
#   Style Guide: https://github.com/bahamas10/bash-style-guide
#######################################################################################################################

#############################################-----change-Log-----######################################################
#   Added option to change nutanix user on AHV hosts
#######################################################################################################################

###############################################-----LICENSE-----#######################################################
#   BSD 3-Clause License
#
#   Copyright (c) 2021, Joel Goehring
#   All rights reserved.
#
#   Redistribution and use in source and binary forms, with or without
#   modification, are permitted provided that the following conditions are met:
#
#   1. Redistributions of source code must retain the above copyright notice, this
#      list of conditions and the following disclaimer.
#
#   2. Redistributions in binary form must reproduce the above copyright notice,
#      this list of conditions and the following disclaimer in the documentation
#      and/or other materials provided with the distribution.
#
#   3. Neither the name of the copyright holder nor the names of its
#      contributors may be used to endorse or promote products derived from
#      this software without specific prior written permission.
#
#   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
#   AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
#   IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#   DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
#   FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
#   DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
#   SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
#   CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
#   OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#######################################################################################################################

###############################################-----PARAMETERS-----####################################################                                             
#   -a/--all:                   Specifies that all passwords will be changed
#   -h/--host:                  Specifies changing the root user's password on the host
#   -u/--nutanix:               Specifies changing the nutanix user's password on an AHV host
#   -c/--cvm:                   Specifies changing the nutanix user on the CVM
#   -e/--prism_element:         Specifies changing the admin user in Prism Element
#   -i/--ipmi:                  Specifies changing the ADMIN user in the IPMI
#   -r/--cluster:               If this flag exists, the script will be run against the entire cluster
#   -n/--nodes:                 Comma-separated list of CVM or host IPs to run against
#######################################################################################################################

###############################################-----Exit-Codes-----####################################################
#   13:     AHV host 'nutanix' user password change failed
#   12:     Virtualization host 'root' user password change failed
#   11:     CVM user 'nutanix' password change failed
#   10:     Prism Element user 'admin' password change failed
#   9:      IPMI user 'ADMIN' password change failed
#   8:      OS designation for changing IPMI 'ADMIN' user password was not matched
#   7:      List of hosts could not be determined
#   5:      The new and verification passwords do not match
#   1:      Parameters were specified incorrectly
#######################################################################################################################

###############################################-----BASH-OPTIONS-----##################################################
#######################################################################################################################

###############################################-----GLOBALS-----#######################################################
ssh_opts='-o LogLevel=error -o StrictHostKeyChecking=no'
ipmi_user_number='2'
#######################################################################################################################

###############################################-----FUNCTIONS-----#####################################################
# This function prints the parameters and general info for running this script. It takes no parameters.
function usage() {
    # Gets the file name of the script using parameter expansion instead of calling out to external programs.
    local base=${0##*/}
    # Inserts a backslash to escape the dot for a valid regex when printed below.
    local base=${base//\./\\\.}
    # Print parameters and general info.
    echo -e "\n
Takes the password on stdin and will prompt for it if one is not provided
The prompt will not echo the password back
-a/--all:\t\tSpecifies that all passwords will be changed
-h/--host:\t\tSpecifies changing the root user's password on the host
-u/--nutanix:\t\tSpecifies changing the nutanix user's password on an AHV host
-c/--cvm:\t\tSpecifies changing the nutanix user's password on the CVM
-e/--prism_element:\tSpecifies changing the admin user's password in Prism Element
-i/--ipmi:\t\tSpecifies changing the ADMIN user's password in the IPMI
-r/--cluster:\t\tRun against the entire cluster
-n/--nodes:\t\tComma-separated list of virtualization host IPs\n
**The logs can be viewed by issuing the below command:
sudo egrep -o '$base:.+' /home/log/user_info

The password must meet the following complexity requirements:
At least eight characters long
Must not be longer than 16 characters or IPMI will break
At least one lowercase letter
At least one uppercase letter
At least one number
At least one special character
At least four characters differ from the old password
Must not be among the last 5 passwords
Must not have more than 2 consecutive occurrences of a character\n"
}

# This function writes messages to the rsyslog service. As of AOS 5.20 user.info has been excluded from
# /home/log/messages in /etc/rsyslog.conf and directed to /home/log/user_info.
# This function expects two parameters. The first being a string 'info' or 'error' which is used to set the level and
# as a field in the line being logged. The second is the message being logged. 
# Error messages will also print to stderr
function log() {
    # Get's the name of this script running to be used as a field in the log.
    source=${0##*/}
    if [[ $1 == 'info' ]] && [[ $2 ]]; then
        logger "$source: $1: $2"
    elif [[ $1 == 'error' ]] && [[ $2 ]]; then
        logger -s "$source: $1: $2"
    else
        echo 'Bad parameters to logging function'
    fi
}

function host_os_discovery() {
    log 'info' "--Beginning ${FUNCNAME[0]} function"
    log 'info' "Host: $host"
    # Get the OS designation of the host. This is necessary because ipmitool is called differently in ESXi and AHV.
    # OS designation returned should be either "ESXi" or "GNU/Linux".
    local host_os=$(
        ssh ${ssh_opts} root@$host 'uname -o'
    )
    # Get the exit code of the above command.
    local host_os_exit=$(
        ssh ${ssh_opts} root@$host "echo $?"
    )
    log 'info' "host_os_exit:$host_os_exit"
    # If OS equals "GNU/Linux" then set OS to "AHV" for simplicity.
    if [[ $host_os == 'GNU/Linux' ]]; then
        local host_os='AHV'
    fi
    log 'info' "host_os:$host_os"
    log 'info' "Ending ${FUNCNAME[0]} function"
    echo $host_os
}

# This function uses the passwd command to change the 'root' user's passwsord on the host
# This function expects no parameters.
function set_host_root_password() {
    log 'info' "--Beginning ${FUNCNAME[0]} function"
    log 'info' "Host: $host"
    # No output is stored from this SSH session in order to keep it silent.
    # Echo passes the new password to the passwd command, changing the password for the 'root' user.
    ssh ${ssh_opts} root@$host "echo -e '$password\n$password' | passwd root > /dev/null 2>&1"
    # Get the exit code of the above command.
    local set_host_root_password_exit=$(
        ssh ${ssh_opts} root@$host "echo $?"
    )
    log 'info' "set_host_root_password_exit:$set_host_root_password_exit"
    # Check the exit code to determine if the password change succeeded or failed.
    if ((set_host_root_password_exit == 0)); then
        local success="Host user 'root' password change on $host SUCCEEDED"
        echo "$success"
        log 'info' "$success"
        log 'info' "Ending ${FUNCNAME[0]} function"
        return $set_host_root_password_exit
    else
        log 'error' "Host user 'root' password change on $host FAILED"
        exit 12
    fi
}

function set_host_nutanix_password () {
    log 'info' "--Beginning ${FUNCNAME[0]} function"
    log 'info' "Host: $host"
    local host_os=$(host_os_discovery)
    log 'info' "Host OS: $host_os"
    # No output is stored from this SSH session in order to keep it silent.
    # Echo passes the new password to the passwd command changing the password for the 'root' user.
    if [[ $host_os == 'AHV' ]]; then
        log 'info' "setting nutanix user password"
        ssh ${ssh_opts} root@$host "echo -e '$password\n$password' | passwd nutanix > /dev/null 2>&1"
        # Get the exit code of the above command.
        local set_host_nutanix_password_exit=$(
            ssh ${ssh_opts} root@$host "echo $?"
        )
    else
        log 'info' "Skipping set_host_nutanix_password. Host was not AHV"
        log 'info' "Ending ${FUNCNAME[0]} function"
        return
    fi
    log 'info' "set_host_nutanix_password_exit:$set_host_nutanix_password_exit"
    # Check the exit code to determine if the password change succeeded or failed.
    if ((set_host_nutanix_password_exit == 0)); then
        local success="Host user 'nutanix' password change on $host SUCCEEDED"
        echo "$success"
        log 'info' "$success"
        log 'info' "Ending ${FUNCNAME[0]} function"
        return $set_host_nutanix_password_exit
    else
        log 'error' "Host user 'nutanix' password change on $host FAILED"
        exit 13
    fi
}

# This function uses the passwd command to change the 'nutanix' user's passwsord on the localhost. This will begin a
# managed process where that password change is propogated to all CVMs in the cluster.
function set_cvm_password() {
    log 'info' "--Beginning ${FUNCNAME[0]} function"
    # No output is stored from this SSH session in order to keep it silent.
    # Echo passes the new password to the passwd command changing the password for the 'nutanix' user.
    echo -e "$password\n$password" | sudo passwd nutanix > /dev/null 2>&1
    # Get the exit code of the above command.
    local set_cvm_password_exit=$(echo $?)
    log 'info' "set_cvm_password_exit:$set_cvm_password_exit"
    # Check the exit code to determine if the password change succeeded or failed.
    if ((set_cvm_password_exit == 0)); then
        local success="CVM user 'nutanix' password change SUCCEEDED"
        echo "$success"
        log 'info' "$success"
        log 'info' "Ending ${FUNCNAME[0]} function"
        return $set_cvm_password_exit
    else
        log 'error' "CVM user 'nutanix' password change FAILED"
        exit 11
    fi
}

# This function uses ncli on the localhost to set the 'admin' user's password in prism element for the cluster.
function set_prism_element_password() {
    log 'info' "--Beginning ${FUNCNAME[0]} function"
    # No output is stored from this command in order to keep it silent.
    # ncli is a utility provided by Nutanix for managing Prism Element and is available on CVMs by default.
    # This ncli command sets the 'admin' user's password is Prism Element.
    ncli user reset-password user-name='admin' password="$password" > /dev/null 2>&1
    # Get the exit code of the above command.
    local set_prism_element_password_exit=$(echo $?)
    log 'info' "set_prism_element_password_exit:$set_prism_element_password_exit"
    # Check the exit code to determine if the password change succeeded or failed.
    if ((set_prism_element_password_exit == 0)); then
        local success="Prism Element user 'admin' password change SUCCEEDED"
        echo "$success"
        log 'info' "$success"
        log 'info' "Ending ${FUNCNAME[0]} function"
        return $set_prism_element_password_exit
    else
        log 'error' "Prism Element user 'admin' password change FAILED"
        exit 10
    fi
}

# This function uses the ipmitool utility provided by Nutanix to set the 'ADMIN' user's password for the IPMI on the
# host stored in the $host variable when it is called. This function expects no parameters.
function set_ipmi_password() {
    log 'info' "--Beginning ${FUNCNAME[0]} function"
    # Get the OS designation of the host. This is necessary because ipmitool is called differently in ESXi and AHV.
    # OS designation returned should be either "ESXi" or "GNU/Linux".
    local host_os=$(host_os_discovery)
    if [[ $host_os == 'AHV' ]]; then
        # No output is stored from this SSH session in order to keep it silent.
        # The ipmitool utility is used to set the new password for the 'ADMIN' user which is expected to be user 2.
        # This is the default but may not always be true.
        ssh ${ssh_opts} root@$host "ipmitool user set password $ipmi_user_number $password" > /dev/null 2>&1
        # Get the exit code of the above command.
        local set_ipmi_password_exit=$(
            ssh ${ssh_opts} root@$host "echo $?"
        )
    elif [[ $host_os == 'ESXi' ]]; then
        # No output is stored from this SSH session in order to keep it silent.
        # The ipmitool utility is used to set the new password for the 'ADMIN' user which is expected to be user 2.
        # This is the default but may not always be true.
        ssh ${ssh_opts} root@$host "./ipmitool user set password $ipmi_user_number $password" > /dev/null 2>&1
        # Get the exit code of the above command.
        local set_ipmi_password_exit=$(
            ssh ${ssh_opts} root@$host "echo $?"
        )
    else
        log 'error' 'OS designation was not matched'
        exit 8
    fi
    log 'info' "set_ipmi_password_exit:$set_ipmi_password_exit"
    # Check the exit code to determine if the password change succeeded or failed.
    if ((set_ipmi_password_exit == 0)); then
        local success="IPMI user 'ADMIN' password change on $host SUCCEEDED"
        echo "$success"
        log 'info' "$success"
        log 'info' "Ending ${FUNCNAME[0]} function"
        return $set_ipmi_password_exit
    else
        log 'error' "IPMI user 'ADMIN' password change on $host FAILED"
        exit 9
    fi
}
#######################################################################################################################

###############################################-----BODY-----##########################################################
# Print usage function if there are no parameters.
if (($# == 0)); then
    usage
    log 'info' '0 parameters were specified. Printing usage information'
    exit 1
fi

log 'info' '----------Beginning script----------'
log 'info' "Params: $*"

# Populate variables based on parameters.
while (($# != 0))
do
    case "$1" in
        # If the all parameter is specified, set individual functions to true.
        -a | --all)
            set_host_root_password='true'
            set_cvm_password='true'
            set_prism_element_password='true'
            set_host_nutanix_password='true'
            set_ipmi_password='true' ;;
        -h | --host) set_host_root_password='true' ;;
        -u | --nutanix) set_host_nutanix_password='true' ;;
        -c | --cvm) set_cvm_password='true' ;;
        -e | --prism_element) set_prism_element_password='true' ;;
        -i | --ipmi) set_ipmi_password='true' ;;
        # matches the nodes parameter and stores the next parameter as the list of nodes to be executed against.
        # Uses 'shift' to remove the second param so that it is not matched on the next iteration.
        -n | --nodes)
            if [[ $2 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}.*$ ]]; then
                nodes=$2
                shift
            else 
                log 'error' '--nodes cannot be empty'
                exit 1
            fi ;;
        -r | --cluster) cluster='true' ;;
        --) shift; break ;;
        # Prints the usage function if the parameter is not matched.
        *) usage; exit 1 ;;
    esac
    shift
done

# Test if --nodes and --cluster have been set at the same time.
if [[ $nodes ]] && [[ $cluster ]]; then
    log 'error' 'A node selection cannot be specified at the same time as the --cluster flag'
    exit 1
fi

# Test if --nodes and --cluster are both empty.
if [[ ( -z $nodes && -z $cluster ) &&
    ( $set_host_root_password == 'true' ||
    $set_ipmi_password == 'true' ||
    $set_host_nutanix_password == 'true' ) ]]; then
    log 'error' 'Specify either the --cluster flag or the --nodes flag with a comma-seperated list of nodes'
    exit 1
fi

# Read password from stdin or prompt for password. Will not echo password back from prompt. 
read -rsp 'Enter New Password: ' password
read -rsp 'Verify New Password: ' vpassword; echo -e '\n'
if [[ "$password" != "$vpassword" ]]; then
    log 'error' 'The new and verification passwords do not match. Exiting.'
    exit 5
fi

# A list of remote hosts is only necessary when setting the host, nutanix, and IPMI passwords.
if [[ $set_host_root_password == 'true' ||
    $set_ipmi_password == 'true' ||
    $set_host_nutanix_password == 'true' ]]; then
    if [[ $cluster == 'true' ]]; then
        # Hostips returns a space-seperated list of all hosts in the cluster which is read and stored as an array.
        read -ra hosts <<< "$(hostips)"
    elif [[ $nodes ]]; then
        # Read in the specified nodes and store them as an array. Prefer comma-seperated list but added pipe as well.
        IFS=',|' read -r -a hosts <<< "$nodes"
        log 'info' 'Setting nodes to hosts'
    else
        log 'error' 'Unable to determine nodes'
        exit 7
    fi
fi

# Set the 'root' user's password on all specified hosts.
if [[ $set_host_root_password == 'true' ]]; then
    for host in "${hosts[@]}"; do
        set_host_root_password
    done
fi

# Set the 'nutanix' user's password on all specified hosts.
if [[ $set_host_nutanix_password == 'true' ]]; then
    for host in "${hosts[@]}"; do 
        set_host_nutanix_password
    done
fi

# Set the 'nutanix' user's password on all of the CVMs in the cluster. This cannot be done on individual nodes.
if [[ $set_cvm_password == 'true' ]]; then
    set_cvm_password
fi

# Set the 'admin' user's password in Prism Element.
if [[ $set_prism_element_password == 'true' ]]; then
    set_prism_element_password
fi

# Set the 'ADMIN' user's password on all specified IPMI instances.
if [[ $set_ipmi_password == 'true' ]]; then
    for host in "${hosts[@]}"; do
        set_ipmi_password
    done
fi

log 'info' '-------------End Script-------------'
#######################################################################################################################
