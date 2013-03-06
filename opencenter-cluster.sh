#!/usr/bin/env bash
#               OpenCenter(TM) is Copyright 2013 by Rackspace US, Inc.
##############################################################################
#
# OpenCenter is licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.  This
# version of OpenCenter includes Rackspace trademarks and logos, and in
# accordance with Section 6 of the License, the provision of commercial
# support services in conjunction with a version of OpenCenter which includes
# Rackspace trademarks and logos is prohibited.  OpenCenter source code and
# details are available at: # https://github.com/rcbops/opencenter or upon
# written request.
#
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0 and a copy, including this
# notice, is available in the LICENSE file accompanying this software.
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the # specific language governing permissions and limitations
# under the License.
#
##############################################################################
#
set -e
set -u

function mangle_name() {
    server=${1:-}

    if [[ ${server} == ${CLUSTER_PREFIX}* ]]; then
        echo ${server}
    else
        echo ${CLUSTER_PREFIX}-${server}
    fi
}

function get_image_type() {
    case $1 in
        "ubuntu") 
            IMAGE_TYPE="12.04 LTS"
            ;;
        "redhat")
            IMAGE_TYPE="Red Hat Enterprise Linux 6.1"
            ;;
        "centos")
            IMAGE_TYPE="CentOS 6.3"
            ;;
        "fedora")
            IMAGE_TYPE="Fedora 17"
            ;;
    esac
}

function ip_for() {
    server=$(mangle_name $1)

    ip=$($NOVA show ${server} | sed -En "/public network/ s/^.* ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}).*$/\1/p")
    if [[ ${ip} =~ "." ]]; then
        echo ${ip}
    else
        echo ""
    fi
}

function wait_for_ip() {
    server=$(mangle_name $1)
    count=0

    max_count=20

    echo "Waiting for IPv4 on ${server}"

    while ! ( $NOVA list | grep ${server} | grep -q "ERROR" ); do
        ip=$(ip_for ${server});
        if [ "${ip}" == "" ]; then
            sleep 20
            count=$(( count + 1 ))
            if [ ${count} -gt ${max_count} ]; then
                echo "Aborting... too slow"
                exit 1
            fi
        else
            echo "Got IPv4: ${ip} for server: ${server}"
            break
        fi
    done

    if ( $NOVA list | grep ${server} | grep -q "ERROR" ); then
        echo "${server} in ERROR state, build failed"
        exit 1
    fi
}

function wait_for_ssh() {
    server=$(mangle_name $1)
    count=0
    max_ping=60  # 10 frigging minutes.
    max_count=18 # plus 3 min (*2) for ssh and getty

    wait_for_ip ${server}

    ip=$(ip_for ${server})

    echo "Waiting for ping on ${ip}"
    count=0
    while ( ! ping -c1 ${ip} > /dev/null 2>&1 ); do
        count=$(( count + 1 ))
        if [ ${count} -gt ${max_ping} ]; then
            echo "timeout waiting for ping"
            exit 1
        fi
        sleep 10
    done

    echo "Waiting for ssh on ${ip}"
    count=0
    while ( ! nc -w 1 ${ip} 22 | grep -q "SSH" ); do
        count=$(( count + 1 ))
        if [ ${count} -gt ${max_count} ]; then
            echo "timeout waiting for ssh"
            exit 1
        fi
        sleep 10
    done

    echo "SSH ready - waiting for valid login"
    count=0

    while ( ! ssh ${SSHOPTS} root@${ip} id | grep -q "root" ); do
        count=$(( count + 1 ))
        if [ ${count} -gt ${max_count} ]; then
            echo "timeout waiting for login"
            exit 1
        fi
        sleep 10
    done
    echo "Login successful"

    #redhat servers become accessible before setup is complete
    count=0
    while !( $NOVA list | grep ${server} | grep -q "ACTIVE" ); do
        count=$(( count + 1 ))
        if [ ${count} -gt ${max_count} ]; then
            echo "timeout waiting for server to become ACTIVE"
            exit 1
        fi
        sleep 10
    done
    echo "Server Active"
}

function setup_server_as() {
    server=$(mangle_name $1)
    as=$2
    ip=$(ip_for "opencenter-server")

    if [[ ! -f ${HOME}/.ssh/id_github ]]; then
        echo "Please setup your github key in ${HOME}/.ssh/id_github"
        exit 1
    fi

    scriptName="install-dev"

    if ( $USE_PACKAGES ); then
        scriptName="install"
    fi

    scp ${SSHOPTS} ${BASEDIR}/${scriptName}.sh root@$(ip_for ${server}):/tmp
    if !( $USE_PACKAGES ); then
        echo "Loading github key"
        scp ${SSHOPTS} ${HOME}/.ssh/id_github root@$(ip_for ${server}):/root/.ssh/id_rsa
    fi

    # Upload screen.rc file if exists
    if [[ -f ${HOME}/.screenrc ]]; then
        echo "Setting up .screenrc file"
        scp ${SSHOPTS} ${HOME}/.screenrc root@$(ip_for ${server}):/root/.screenrc
    fi

    if !( $USE_PACKAGES ); then
        ssh ${SSHOPTS} root@$(ip_for ${server}) "cat /tmp/${scriptName}.sh | /bin/bash -s - --role=${as} --ip=${ip}"
        echo "removing github key"
        ssh ${SSHOPTS} root@$(ip_for ${server}) 'rm /root/.ssh/id_rsa'
    else
        ssh ${SSHOPTS} root@$(ip_for ${server}) "cat /tmp/${scriptName}.sh | /bin/bash -s - --role=${as} --ip=${ip} --password=${OPENCENTER_PASSWORD}"
    fi
}

function credentials_check(){
    #only need to source nova env if not using supernova
    if [[ "$NOVA" == "nova" ]]
    then
        if [[ -f ${HOME}/csrc ]]; then
            source ${HOME}/csrc
        else
            echo "Please setup your cloud credentials file in ${HOME}/csrc"
            exit 1
        fi
    fi
}

function boot_instances(){
    imagelist=$($NOVA image-list)
    flavorlist=$($NOVA flavor-list)

    image=$(echo "${imagelist}" | grep "${IMAGE_TYPE}" | head -n1 | awk '{ print $2 }')
    flavor_2g=$(echo "${flavorlist}" | grep 2GB | head -n1 | awk '{ print $2 }')
    flavor_4g=$(echo "${flavorlist}" | grep 4GB | head -n1 | awk '{ print $2 }')

    if ! $RERUN
    then
        if ( $NOVA list | grep -q $(mangle_name) ); then
            echo "$(mangle_name) prefix is already in use, select another, or delete existing servers"
            exit 1
        fi
    fi

    if [[ -f ${HOME}/.ssh/authorized_keys ]]; then
        instance_exists opencenter-server || $NOVA boot --flavor=${flavor_4g} --image ${image} ${network_string} --file /root/.ssh/authorized_keys=${HOME}/.ssh/authorized_keys $(mangle_name opencenter-server) > /dev/null 2>&1
        for client in $(seq 1 $CLIENT_COUNT); do
            instance_exists opencenter-client${client} || $NOVA boot --flavor=${flavor_2g} --image ${image} ${network_string} --file /root/.ssh/authorized_keys=${HOME}/.ssh/authorized_keys $(mangle_name opencenter-client${client}) > /dev/null 2>&1
        done
        instance_exists opencenter-dashboard || $NOVA boot --flavor=${flavor_2g} --image ${image} ${network_string} --file /root/.ssh/authorized_keys=${HOME}/.ssh/authorized_keys $(mangle_name opencenter-dashboard) > /dev/null 2>&1
    else
        echo "Please setup your ${HOME}/.ssh/authorized_keys file for key injection to cloud servers "
        exit 1
    fi
}

function create_network(){
    if ( $NOVA network-list | grep -q ${CLUSTER_PREFIX} ); then
        echo "Network ${CLUSTER_PREFIX}-net already exists, delete and re-run or use different prefix"
        exit 1
    fi
    if !( $NOVA network-create ${CLUSTER_PREFIX}-net ${PRIV_NETWORK} > /dev/null 2>&1 ); then
        echo "Error creating Network - run $NOVA network-create ${CLUSTER_PREFIX}-net ${PRIV_NETWORK} to diagnose"
        exit 1
    fi
    priv_network_id=$($NOVA network-list | grep ${CLUSTER_PREFIX}-net | awk '{print $2}')
    network_string="--nic net-id=${priv_network_id}"
    echo "Network ${priv_network_id} created"
}

function server_setup(){
    nodes=("opencenter-server")
    wait_for_ssh "opencenter-server"
    for client in $(seq 1 $CLIENT_COUNT); do
        wait_for_ssh "opencenter-client${client}"
        nodes=(${nodes[@]} "opencenter-client${client}")
    done
    wait_for_ssh "opencenter-dashboard"
    nodes=(${nodes[@]} "opencenter-dashboard")

    for svr in ${nodes[@]}; do
        what=agent

        if [ "${svr}" == "opencenter-server" ]; then
            what=server
        fi

        if [ "${svr}" == "opencenter-dashboard" ]; then
            what=dashboard
        fi

        setup_server_as ${svr} ${what} > /tmp/$(mangle_name ${svr}).log 2>&1 &
        echo "Setting up server $(mangle_name ${svr}) as ${what} - logging status to /tmp/$(mangle_name ${svr}).log"
        PIDS["$!"]=${svr}
    done

    for pid in ${!PIDS[@]}; do
        echo "Waiting on pid ${pid}: ${PIDS[${pid}]}"
        if [ ${pid} -ne 0 ]; then
            wait ${pid} > /dev/null 2>&1
            echo "Reaped ${pid}"
            if [ $? -ne 0 ]; then
                echo "Error setting up ${PIDS[${pid}]}"
            fi
        fi
    done
}

instance_exists(){
    name=$(mangle_name $1)
    $NOVA list |grep -q $name
}

function usage() {
cat <<EOF
usage: $0 options

This script will install opencenter packages.

OPTIONS:
  -h --help  Show this message
  -v --verbose  Verbose output
  -V --version  Output the version of this script

ARGUMENTS:
  -p --prefix=<Cluster Prefix>
         Specify the name prefix for the cluster - default "c1"
  -c --clients=<Number of Clients>
         Specify the number of clients to install, in conjunction with a server & dashboard - default 2
  -pass --password=<Opencenter Server Password>
         Specify the Opencenter Server Password - only used for package installs - default "opencentre"
  -pkg --packages
         Install using packages
  -n --network=<CIDR>
         Setup a private cloud networks, will require "nova network-create" command - default 192.168.0.0/24
  -o --os=[redhat | centos | ubuntu | fedora ]
         Specify the OS to install on the servers - default ubuntu
EOF
}


function display_version() {
cat <<EOF
$0 (version: $VERSION)
EOF
}

function licensing() {
   echo ""
   echo "
OpenCenter(TM) is Copyright 2013 by Rackspace US, Inc.
OpenCenter is licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.  This version of OpenCenter includes Rackspace trademarks and logos, and in accordance with Section 6 of the License, the provision of commercial support services in conjunction with a version of OpenCenter which includes Rackspace trademarks and logos is prohibited.  OpenCenter source code and details are available at: https://github.com/rcbops/opencenter/ or upon written request.
You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 and a copy, including this notice, is available in the LICENSE.TXT file accompanying this software.
Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
"
}

function display_info() {
    server_ip=$(ip_for opencenter-server)
    auth_string=""
    if ( $USE_PACKAGES ); then
        auth_string="admin:$OPENCENTER_PASSWORD@"
    fi
    echo -e "\n*** COMPLETE ***\n"
    echo -e "Run \"export OPENCENTER_ENDPOINT=${DASHBOARD_PROTO}://${auth_string}${server_ip}:${server_port}\" to use the opencentercli"
    dashboard_ip=$(ip_for opencenter-dashboard)
    echo -e "Or connect to \"${DASHBOARD_PROTO}://${dashboard_ip}:${DASHBOARD_PORT}\" to manage via the opencenter-dashboard interface\n"
}

####################
# Global Variables #
#command to use for nova; read from environment or "nova" by default.
#This is so you can set NOVA="supernova env" before running the script.
NOVA=${NOVA:-nova}
RERUN=${RERUN:-false}
USE_PACKAGES=false
USE_NETWORK=false
PRIV_NETWORK="192.168.0.0/24"
CLUSTER_PREFIX="c1"
CLIENT_COUNT=2
if [ -L $0 ]; then
    BASEDIR=$(dirname $(readlink $0))
else
    BASEDIR=$(dirname $0)
fi
SSHOPTS="-q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
DASHBOARD_PORT=3000
DASHBOARD_PROTO=http
server_port=8080
USAGE="Usage: opencenter-cluster.sh <Cluster-Prefix> <Number of Clients> [--packages] [--network(=<CIDR>)]"
IMAGE_TYPE=${IMAGE_TYPE:-"12.04 LTS"}
VERSION=1.0.0
OPENCENTER_PASSWORD=${OPENCENTER_PASSWORD:-"opencentre"}
declare -A PIDS
network_string=""
####################

for arg in $@; do
    flag=$(echo $arg | cut -d "=" -f1)
    value=$(echo $arg | cut -d "=" -f2)
    case $flag in
        "--prefix" | "-p")
            CLUSTER_PREFIX=$value
            ;;
        "--network" | "-n")
            if ( echo $value | egrep "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{2}$" > /dev/null 2>&1 ); then
                PRIV_NETWORK=$value
                create_network
            else
                echo "Invalid IP CIDR range specified"
                usage
                exit 1
            fi
            ;;
        "--password" | "-pass")
            OPENCENTER_PASSWORD=$value
            ;;
        "--clients" | "-c")
            if [ $value -eq $value 2>/dev/null ]; then
                CLIENT_COUNT=$value
            else
                usage
                exit 1
            fi
            ;;
        "--packages" | "-pkg")
            USE_PACKAGES=true
            DASHBOARD_PORT=443
            server_port=8443
            DASHBOARD_PROTO=https
            ;;
        "--os" | "-o")
            value=$(echo $value | tr "[:upper:]" "[:lower:]")
            if [ $value != "centos" ] && [ $value != "redhat" ] && [ $value != "fedora" ] && [ $value != "ubuntu" ]; then
                echo "Invalid OS type specified"
                usage
                exit 1
            else
                get_image_type $value
            fi
            ;;
        "--help" | "-h")
            usage
            exit 1
            ;;
        "--verbose" | "-v")
            VERBOSE=1
            set -x
            ;;
        "--version" | "-V")
            display_version
            exit 1
            ;;
        *)
            echo "Invalid option $flag"
            usage
            exit 1
            ;;
    esac
done

credentials_check
boot_instances
server_setup
licensing
display_info

exit
