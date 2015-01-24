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
                    timeout 5 pcs resource cleanup $i
                    if [ "$?" != "0" ]; then
                        echo "Failed to clean $i. It may help to rerun the script the same way."
                        echo -n "To continue running the script despite the error? [y/n] "
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
    test "glance image-list"
    if [ "$?" == "0" ]; then
        echo "The image already exists... Skipping."
    else
        echo "Creating the glance image"
        glance image-create --name cirros --disk-format qcow2 --container-format bare --is-public 1 --copy-from https://launchpad.net/cirros/trunk/0.3.0/+download/cirros-0.3.0-x86_64-disk.img
        test "glance image-create"
    fi
}

function keypair {
    echo "Checking if the \"oskey\" keypair was already created."
    nova keypair-list|grep -q oskey
    test keypair-list
    if [ "$?" == "0" ]; then
        echo "The keypair was already created... Skipping."
    else
        echo "Creating the keypair"
        nova keypair-add oskey > oskey.priv
        test keypair-add
        chmod 600 oskey.priv
    fi
}

function external-network {
    echo "Checking if the external network was already created."
    neutron net-list|grep -q public
    test "neutron net-list"
    if [ "$?" == "0" ]; then
        echo "The external network was already created... Skipping."
    else
        echo "Creating the external network"
        neutron net-create public --provider:network_type flat --provider:physical_network physnet-external --router:external=True
        test "neutron net-create public"
    fi
}

function external-subnet {
    echo "Checking if the subnet for the external network was already created."
    neutron subnet-list|grep -q $NETADDR
    test "neutron subnet-list"
    if [ "$?" == "0" ]; then
        echo "The subnet for the external network was already created... Skipping."
    else
        echo "Creating the subnet for the external network"
        neutron subnet-create public --gateway $GATEWAY $NETADDR  --enable_dhcp=False --allocation-pool start=${START_IP},end=${END_IP}
        test "neutron subnet-create public"
    fi
}

function tenant-network {
    echo "Checking if the tenant network was already created."
    neutron net-list|grep -q tenant 
    test "neutron net-list"
    if [ "$?" == "0" ]; then
        echo "The tenant network was already created... Skipping."
    else
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
    fi
}
function tenant-subnet {
    echo "Checking if the subnet for the tenant network was already created."
    neutron subnet-list|grep -q 192.168.32
    test "neutron subnet-list"
    if [ "$?" == "0" ]; then
        echo "The subnet for the tenant network was already created... Skipping."
    else
        echo "Creating a subnet under the tenant network"
        neutron subnet-create tenant --gateway 192.168.32.1 192.168.32.0/24 --enable_dhcp=True --allocation-pool start=192.168.32.2,end=192.168.32.100 --dns 8.8.8.8
        test "neutron subnet-create tenant"
    fi
}

function router {
    echo "Checking if the router was already created."
    neutron router-list|grep -q r1
    test "router-list"
    if [ "$?" == "0" ]; then
        echo "The router was already created... Skipping."
    else
        echo "Creating the router"
        neutron router-create r1
        test "router-create"
    fi
}

function router-interface {
    echo "Checking if the interface was already added to the router."
    neutron port-list|grep -q 192.168.32.1
    test "neutron port-list"
    if [ "$?" == "0" ]; then
        echo "The interface was already added to the router... Skipping."
    else
        echo "Adding an interface to the router on the tenant subnet"
        neutron router-interface-add r1 `neutron subnet-list|awk -F"|" '/192.168.32/ {print $2}'` ip_address 192.168.32.1
        test "neutron router-interface-add"
    fi
}

function router-gateway {
    echo "Checking if the gateway was already set for the router."
    neutron router-show r1|grep "external_gateway_info.*true"
    test "neutron router-show"
    if [ "$?" == "0" ]; then
        echo "The gateway was already set for the router... Skipping."
    else
        echo "Seting the gateway for router"
        neutron router-gateway-set r1 public
        test "neutron router-gateway-set"
    fi
}

function instance {
    if [ "$deployment" == "nova" ]; then
        netid="novanetwork"
    else
        netid="tenant"
    fi
    while ! glance image-list|grep -q active; do 
        echo "The glance image isn't active yet. Sleeping for 1 second."
        sleep 1
    done
    echo "Checking if the instance was already launched."
    nova list|grep -q nisim
    test "nova list"
    if [ "$?" == "0" ]; then
        echo "The instance was already launched.... Exiting."
        exit 1
    else
        echo "booting an instance"
        nova boot --flavor 1 --key_name oskey --image `glance image-list|awk -F"|" '/cirros/ {print $2}'`  --nic net-id=`nova net-list|awk -F"|" "/$netid/ {print substr(\\$2,2,length(\\$2))}"|head -n 1`  nisim1
        test "nova boot nisim1"
    fi
}

function security {
    echo "Checking if ICMP was already added to the default security group."
    nova secgroup-list-rules default|grep -q icmp
    test "nova secgroup-list-rules icmp"
    if [ "$?" == "0" ]; then
        echo "The ICMP was already added to the default security group...Skipping."
    else
        echo "Security - adding ICMP to the default security group"
        nova secgroup-add-rule default icmp -1 -1  0.0.0.0/0
        test "nova secgroup icmp"
    fi
    echo "Checking if SSH was already added to the default security group."
    nova secgroup-list-rules default|grep -q 22
    test "nova secgroup-list-rules ssh"
    if [ "$?" == "0" ]; then
        echo "SSH was already added to the default security group...Skipping."
    else
        echo "Security - adding SSH to the default security group"
        nova secgroup-add-rule default tcp 22 22  0.0.0.0/0
        test "nova secgroup ssh"
    fi
}

function floating-create {
    echo "Checking if the floating IP was already created in the public network."
    nova floating-ip-list|grep -q public
    test "nova floating-ip-list"
    if [ "$?" == "0" ]; then
        echo "The floating IP was already created in the public network...Skipping."
    else
        echo "Creating the floating IP in the public network"
        nova floating-ip-create public
        test "nova floating-ip-create"
    fi
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
echo "Completed."
