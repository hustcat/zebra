#!/bin/bash
BR=br1
HOST_IFNAME=eth1

if [ $# -ne 1 ]; then
	echo "Usage: $0 <bridge>"
	echo "Ex:    $0 br1"
	exit 1
fi

BR=$1

brctl delif $BR $HOST_IFNAME
ip link set $BR down
brctl delbr $BR
service network restart

exit 0
