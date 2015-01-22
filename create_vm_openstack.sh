#!/bin/bash
getopts f mode
case $mode in
    f)
      force="yes"
      ;;
esac


# Declarations of functions to be used

function check_pcs_status {
    which pcs >/dev/null 2>&1
    if [ "$?" != "0" ]; then
    #if [ "${PIPESTATUS[0]}" != "0" ]; then
        echo "There's an ERROR running the pcs command! Check the deployment status. Exiting..."
        exit 1
    else
        echo "Checking if the are failed PCS services."
        count=`pcs status|awk '/Failed/{flag=1;next}/PCSD/{flag=0}flag'| awk '/[a-z]/ {print}'|wc -l`
        if [ $count -gt 0 ]; then
            echo "PCS reports the following failed actions:"
            for i in `pcs status|awk '/Failed/{flag=1;next}/PCSD/{flag=0}flag'| awk -F"_" '/[a-z]/ {print $1}'`; do 
                echo "    $i"
            done
            if [ "$force" != "yes" ]; then
                echo "Please clean the failed actions manually and restart the script or run the script with "-f". Exiting."
                exit 1
            else
                echo "Attempting to clean the failed actions (force mode)."
                for i in `pcs status|awk '/Failed/{flag=1;next}/PCSD/{flag=0}flag'| awk -F"_" '/[a-z]/ {print $1}'`; do 
                    echo "cleaning $i"
                    timeout 10 pcs resource cleanup $i
                    if [ "$?" != "0" ]; then
                        echo "Failed to clean $i. It may help to rerun the script the same way."
                        echo "To continue running the script despite the error? y/n"
                        read answer
                        if [ "$answer" != "y" ]; then
                            echo "Exiting." 
                            exit 1
                        fi
                    fi
                done
            fi
        else
            echo "PCS reports no failed actions"
        fi
    fi
}

function neutron_or_nova {
    pcs status 2>/dev/null|grep -q neutron 
    if [ "$?" == "0" ]; then
        echo "This is a neutron deployment"
        deployment="neutron"
    else
        echo "This is a Nova deployment"
        deployment="nova"
    fi
}
    
function keystonerc_admin {
    keystonrc="/root/keystonerc_admin"
    echo "Attempting to source the $keystonrc"
    if [ -f $keystonrc ]; then 
        source $keystonrc
    else
        echo "$keystonrc file wasn't found. Exiting..."
        exit 1
    fi
}

function test {
    if [ "$?" != "0" ]; then
        echo "There was an error with ${1}. Exiting...."
        exit 1
    fi
}

function clean {
    echo "Deleting the created instance" 
    instance1=`nova list|awk -F"|" '/Running/ {print $3}'`
    if [ "$instance1" == "" ]; then
        echo "No instances appear to be running. Exiting..."
    else
        nova delete $instance1
        test "nova-delete"
    fi
}
function check_IP {
    OIFS=$IFS
    IFS='.'
    ip=($1)
    IFS=$OIFS
    if [ ${ip[0]} -le 255 -a ${ip[1]} -le 255 -a ${ip[2]} -le 255 -a ${ip[3]} -le 255 ]; then
        echo "Validated IP successfully."
    else
        echo "IP validation failed. Exiting..."
        exit 1
   fi
}
function set_network_settings {
    echo "Select type of network for tenant?"
    echo " (1) VXLAN"
    echo " (2) GRE"
    echo " (3) VLAN"
    read  NETWORK_TYPE
    if [ "$NETWORK_TYPE" != "1" -a "$NETWORK_TYPE" != "2" -a "$NETWORK_TYPE" != "3" ]; then
        echo "Error! The selection can be either 1 or 2 only."
        set_network_settings
    fi
    echo "Please provide the external Network Address using CIDR notation (eg. 192.168.100.0/24). This value will be used to set the external network in RHOS."
    read NETADDR
    OIFS=$IFS # save the value aside
    IFS="/"
    NETWORK=($NETADDR)
    IFS=$OIFS # return to the previous value
    if [ -z ${NETWORK[1]} ]; then #missing cidr
        echo "Error! Must use the CIDR notation (eg. 192.168.100.0/24)"
        exit 1
    fi
    check_IP ${NETWORK[0]}
    echo "Please provide the gateway for the external Network Address"
    read GATEWAY
    check_IP $GATEWAY
    echo "Please provide the allocation pool start IP"
    read START_IP
    check_IP $START_IP
    echo "Please provide the allocation pool end IP"
    read END_IP
    check_IP $END_IP
}

function glance-image-create {
    echo "Checking if the cirros image was already created."
    glance image-list|grep -q cirros
    if [ "$?" == "0" ]; then
        echo "The image already exists... Skipping."
    else
        echo "Creating the glance image"
        glance image-create --name cirros --disk-format qcow2 --container-format bare --is-public 1 --copy-from https://launchpad.net/cirros/trunk/0.3.0/+download/cirros-0.3.0-x86_64-disk.img
        test "glance image-create"
    fi
}

function keypair {
    echo "Checking if the \"oskey\" keypair was created."
    nova keypair-list|grep -q oskey
    if [ "$?" == "0" ]; then
        echo "The keypair was already created... Skipping."
    else
        echo "Creating the keypair"
        nova keypair-add oskey > oskey.priv
        test keypair
        chmod 600 oskey.priv
    fi
}

function external-network {
    echo "Creating the external network"
    neutron net-create public --provider:network_type flat --provider:physical_network physnet-external --router:external=True
    test "neutron net-create public"
}

function external-subnet {
    echo "Creating the subnet for the external network"
    neutron subnet-create public --gateway $GATEWAY $NETADDR  --enable_dhcp=False --allocation-pool start=${START_IP},end=${END_IP}
    test "neutron subnet-create public"
}

function tenant-network {
    #  for VXLAN
    echo "Creating the tenant network"
    if [ "$NETWORK_TYPE" == "1" ]; then
        neutron net-create tenant --provider:network_type vxlan --provider:segmentation_id 10 --router:external False
        test "neutron net-create tenant (VXLAN)"
    #  for GRE
    elif [ "$NETWORK_TYPE" == "2" ]; then
        neutron net-create tenant --provider:network_type gre --provider:segmentation_id 10 --router:external False
        test "neutron net-create tenant (GRE)"
    # for VLAN
    else
        neutron net-create tenant --provider:network_type vlan --provider:segmentation_id 10 --router:external False
        test "neutron net-create tenant (VLAN)"
    fi
}
function tenant-subnet {
    echo "Creating a subnet under the tenant network"
    neutron subnet-create tenant --gateway 192.168.32.1 192.168.32.0/24 --enable_dhcp=True --allocation-pool start=192.168.32.2,end=192.168.32.100 --dns 8.8.8.8
    test "neutron subnet-create tenant"
}

function router {
    echo "Creating the router"
    neutron router-create r1
    test "router-create"
}

function router-interface {
    echo "Adding an interface to the router on the tenant subnet"
    neutron router-interface-add r1 `neutron subnet-list|awk -F"|" '/192.168.32/ {print $2}'` ip_address 192.168.32.1
    test "neutron router-interface-add"
}

function router-gateway {
    echo "Seting the gateway for router"
    neutron router-gateway-set r1 public
    test "neutron router-gateway-set"
}

function instance {
    echo "booting an instance"
    if [ "$deployment" == "nova" ]; then
        netid="novanetwork"
    else
        netid="tenant"
    fi
    while ! glance image-list|grep -q active; do 
        echo "The glance image isn't active yet. Sleeping for 1 second."
        sleep 1
    done
    nova boot --flavor 1 --key_name oskey --image `glance image-list|awk -F"|" '/cirros/ {print $2}'`  --nic net-id=`nova net-list|awk -F"|" "/$netid/ {print substr(\\$2,2,length(\\$2))}"`  nisim1
    test "nova boot nisim1"
}

function security {
    echo "Security - adding ICMP and SSH to the default security group"
    nova secgroup-add-rule default icmp -1 -1  0.0.0.0/0
    test "nova secgroup icmp"
    nova secgroup-add-rule default tcp 22 22  0.0.0.0/0
    test "nova secgroup ssh"
}

function floating-create {
    echo "Creating the floating IP in the public network"
    nova floating-ip-create public
    test "nova floating-ip-create"
}

function floating-asoc {
    echo "Associating the floating IP with the instance"
    while ! nova list|awk -F"|" '/nisim1/ {print $(NF-1)}'|grep -q 192.168.32; do 
        echo "The instance doesn't have a tenant IP assigned yet. Sleeping 1 second."
        sleep 1
   done
    
    nova floating-ip-associate --fixed-address `nova list|awk -F"|" '/nisim1/ {print $(NF-1)}'|awk -F"=" '{print $2}'`  `nova list|awk -F"|" '/nisim1/ {print $2}'`  `nova floating-ip-list|awk -F"|" '/public/ {print $2}'`
    test "nova floating-ip-associate"
}

# start running the functions
if [ "$1" == "clean" ]; then
    keystonerc_admin
    clean
    exit 0
fi
check_pcs_status
neutron_or_nova
if [ "$deployment" == "neutron" ]; then
    set_network_settings
fi
keystonerc_admin
glance-image-create
keypair
if [ "$deployment" == "neutron" ]; then
    external-network
    external-subnet
    tenant-network
    tenant-subnet
    router
    router-interface
    router-gateway
fi
instance
security
if [ "$deployment" == "neutron" ]; then
   floating-create
   floating-asoc
fi
