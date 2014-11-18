#!/bin/bash

BR=br1
HOST_IFNAME=eth1

if [ $# -ne 1 ]; then
	echo "Usage: $0 <bridge>"
	echo "Ex:    $0 br1"
	exit 1
fi

BR=$1

HOST_IP=`ip addr show $HOST_IFNAME | grep inet | awk '{print $2}'`
HOST_BRD=`ip addr show $HOST_IFNAME | grep inet | awk '{print $4}'`
HOST_GW=`ip route list | grep "default" | awk '{print $3}'`


brctl addbr $BR
#echo "ip addr add $HOST_IP broadcast $HOST_BRD dev $BR"
ip addr add $HOST_IP broadcast $HOST_BRD dev $BR

ip link set $BR up
brctl addif $BR $HOST_IFNAME

sleep 1

echo "ip addr del ${HOST_IP} dev ${HOST_IFNAME}"
ip addr del ${HOST_IP} dev ${HOST_IFNAME}
ifconfig $HOST_IFNAME

route add default gw $HOST_GW
exit 0
