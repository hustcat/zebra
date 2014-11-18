#!/bin/bash
#usage:./network_init.sh <bridge> <container_name> <ipaddr>/<subnet>[@default_gateway]
#ex: ./network_init.sh br1 yy1 172.16.213.180/16@172.16.213.2
set -e

#DEBUG=0
HOST_IFNAME=eth1

case "$1" in
    --wait)
      WAIT=1
      ;;
esac

IFNAME=$1

# default value set further down if not set here
CONTAINER_IFNAME=
if [ "$2" = "-i" ]; then
  CONTAINER_IFNAME=$3
  shift 2
fi

GUESTNAME=$2
IPADDR=$3

[ "$IPADDR" ] || [ "$WAIT" ] || {
    echo "Syntax:"
    echo "$0 <hostinterface> [-i containerinterface] <guest> <ipaddr>/<subnet>[@default_gateway]"
    echo "$0 --wait [-i containerinterface]"
    exit 1
}

HOST_IP=`ip addr list | grep "$HOST_IFNAME" | grep inet | awk '{print $2}'`
HOST_BRD=`ip addr list | grep "$HOST_IFNAME" | grep inet | awk '{print $4}'`
HOST_DEFAULT_GATEWAY=`ip route list | grep "default" | awk '{print $3}'`

if [ -n "$DEBUG" ]; then
    echo "host info:"
    echo "ip:       $HOST_IP"
    echo "gateway:  $HOST_DEFAULT_GATEWAY"
    echo "broadcast:$HOST_BRD"
fi

# First step: determine type of first argument (bridge, physical interface...), skip if --wait set
if [ -z "$WAIT" ]; then 
    if [ -d /sys/class/net/$IFNAME ]
    then
        if [ -d /sys/class/net/$IFNAME/bridge ]
        then
            IFTYPE=bridge
            BRTYPE=linux
        else
            echo "Only support bridge."
        fi
    else
        case "$IFNAME" in
        br*)
            IFTYPE=bridge
            BRTYPE=linux
            ;;
        *)
            echo "I do not know how to setup interface $IFNAME."
            exit 1
            ;;
        esac
    fi
fi

# Set the default container interface name to eth1 if not already set
CONTAINER_IFNAME=${CONTAINER_IFNAME:-eth1}

[ "$WAIT" ] && {
  while ! grep -q ^1$ /sys/class/net/$CONTAINER_IFNAME/carrier 2>/dev/null
  do sleep 1
  done
  exit 0
}

# Second step: find the guest (for now, we only support LXC containers)
while read dev mnt fstype options dump fsck
do
    [ "$fstype" != "cgroup" ] && continue
    echo $options | grep -qw devices || continue
    CGROUPMNT=$mnt
done < /proc/mounts

[ "$CGROUPMNT" ] || {
    echo "Could not locate cgroup mount point."
    exit 1
}

# Try to find a cgroup matching exactly the provided name.
N=$(find "$CGROUPMNT" -name "$GUESTNAME" | wc -l)
case "$N" in
    0)
	# If we didn't find anything, try to lookup the container with Docker.
	if which docker >/dev/null
	then
        RETRIES=3
        while [ $RETRIES -gt 0 ]; do
      	    DOCKERPID=$(docker inspect --format='{{ .State.Pid }}' $GUESTNAME)
            [ $DOCKERPID != 0 ] && break
            sleep 1
            RETRIES=$((RETRIES - 1))
        done

        [ "$DOCKERPID" = 0 ] && {
      		echo "Docker inspect returned invalid PID 0"
    		exit 1
      	}

        [ "$DOCKERPID" = "<no value>" ] && {
      		echo "Container $GUESTNAME not found, and unknown to Docker."
    		exit 1
      	}
	else
	    echo "Container $GUESTNAME not found, and Docker not installed."
	    exit 1
	fi
	;;
    1)
	true
	;;
    *)
	echo "Found more than one container matching $GUESTNAME."
	exit 1
	;;
esac

if [ "$IPADDR" = "dhcp" ]
then

    echo "Don't surpport dhcp now."
    exit 1
else
    # Check if a subnet mask was provided.
    echo $IPADDR | grep -q / || {
	echo "The IP address should include a netmask."
	echo "Maybe you meant $IPADDR/24 ?"
	exit 1
    }
    # Check if a gateway address was provided.
    if echo $IPADDR | grep -q @
    then
        GATEWAY=$(echo $IPADDR | cut -d@ -f2)
        IPADDR=$(echo $IPADDR | cut -d@ -f1)
    else
        GATEWAY=
    fi
fi

if [ $DOCKERPID ]; then
  NSPID=$DOCKERPID
else
  NSPID=$(head -n 1 $(find "$CGROUPMNT" -name "$GUESTNAME" | head -n 1)/tasks)
  [ "$NSPID" ] || {
      echo "Could not find a process inside container $GUESTNAME."
      exit 1
  }
fi

[ ! -d /var/run/netns ] && mkdir -p /var/run/netns
[ -f /var/run/netns/$NSPID ] && rm -f /var/run/netns/$NSPID
ln -s /proc/$NSPID/ns/net /var/run/netns/$NSPID

# Check if we need to create a bridge.
[ $IFTYPE = bridge ] && [ ! -d /sys/class/net/$IFNAME ] && {
    [ $BRTYPE = linux ] && {
        (ip link add dev $IFNAME type bridge > /dev/null 2>&1) || (brctl addbr $IFNAME)
        ip link set $IFNAME up
        ip addr del $HOST_IP dev $HOST_IFNAME
        ip addr add $HOST_IP broadcast $HOST_BRD dev $IFNAME
        brctl addif $IFNAME $HOST_IFNAME
        echo 'NM_CONTROLLED="no"' >> /etc/sysconfig/network-scripts/ifcfg-${HOST_IFNAME}
        route add default gw $HOST_DEFAULT_GATEWAY
        sleep 2
    }
}

MTU=$(ip link show $IFNAME | awk '{print $5}')
# If it's a bridge, we need to create a veth pair
[ $IFTYPE = bridge ] && {
    LOCAL_IFNAME="v${CONTAINER_IFNAME}pl${NSPID}"
    GUEST_IFNAME="v${CONTAINER_IFNAME}pg${NSPID}"
    ip link add name $LOCAL_IFNAME mtu $MTU type veth peer name $GUEST_IFNAME mtu $MTU
    case "$BRTYPE" in
        linux)
            (ip link set $LOCAL_IFNAME master $IFNAME > /dev/null 2>&1) || (brctl addif $IFNAME $LOCAL_IFNAME)
            ;;
    esac
    ip link set $LOCAL_IFNAME up
}

ip link set $GUEST_IFNAME netns $NSPID
ip netns exec $NSPID ip link set $GUEST_IFNAME name $CONTAINER_IFNAME

ip netns exec $NSPID ip addr add $IPADDR dev $CONTAINER_IFNAME
[ "$GATEWAY" ] && {
ip netns exec $NSPID ip route delete default >/dev/null 2>&1 && true
}
ip netns exec $NSPID ip link set $CONTAINER_IFNAME up
[ "$GATEWAY" ] && {
ip netns exec $NSPID ip route get $GATEWAY >/dev/null 2>&1 || \
	ip netns exec $NSPID ip route add $GATEWAY/32 dev $CONTAINER_IFNAME
ip netns exec $NSPID ip route replace default via $GATEWAY
}

# Give our ARP neighbors a nudge about the new interface
if which arping > /dev/null 2>&1
then
    IPADDR=$(echo $IPADDR | cut -d/ -f1)
    ip netns exec $NSPID arping -c 1 -A -I $CONTAINER_IFNAME $IPADDR > /dev/null 2>&1 || true
else
    echo "Warning: arping not found; interface may not be immediately reachable"
fi

# Remove NSPID to avoid `ip netns` catch it.
[ -f /var/run/netns/$NSPID ] && rm -f /var/run/netns/$NSPID
exit 0

