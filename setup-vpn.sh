#!/bin/sh

##
## Setup OpenVPN to create the OpenStack management network.
## This script only runs on the "network" node.
##

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

DIRNAME=`dirname $0`

# Grab our libs
. "$DIRNAME/setup-lib.sh"

HOSTNAME=`hostname -s`
if [ "$HOSTNAME" != "$NETWORKMANAGER" ]; then
    exit 0;
fi

apt-get install -y openvpn easy-rsa

#
# Get our server CA config set up.
#
export EASY_RSA="/etc/openvpn/easy-rsa"

mkdir -p $EASY_RSA
cp -r /usr/share/easy-rsa/* $EASY_RSA
cd $EASY_RSA
# Batch mode
sed -i -e s/--interact/--batch/ $EASY_RSA/build-ca
sed -i -e s/--interact/--batch/ $EASY_RSA/build-key-server
sed -i -e s/--interact/--batch/ $EASY_RSA/build-key
sed -i -e s/DEBUG=0/DEBUG=1/ $EASY_RSA/pkitool

export OPENSSL="openssl"
export PKCS11TOOL="pkcs11-tool"
export GREP="grep"
export KEY_CONFIG="`$EASY_RSA/whichopensslcnf $EASY_RSA`"
export KEY_DIR="$EASY_RSA/keys"
export PKCS11_MODULE_PATH="dummy"
export PKCS11_PIN="dummy"
export KEY_SIZE=2048
export CA_EXPIRE=3650
export KEY_EXPIRE=3650

export KEY_COUNTRY="US"
export KEY_PROVINCE="UT"
export KEY_CITY="Salt Lake City"
export KEY_ORG="$EPID-$EEID"
export KEY_EMAIL="${SWAPPER_EMAIL}"
export KEY_CN="OSMgmtVPN"
export KEY_NAME=$KEY_CN
export KEY_OU=$KEY_CN
# --batch mode is unhappy if it's not this
export KEY_ALTNAMES="DNS:$NETWORKMANAGER"

mkdir -p $KEY_DIR

cd $EASY_RSA
./clean-all
./build-ca
# We needed a CN for the CA build -- but now we have to drop it cause
# the build-key* scripts don't want it set -- they set it to the first arg,
# and behave badly if it IS set.
unset KEY_CN
./build-key-server $NETWORKMANAGER
cp -p $KEY_DIR/$NETWORKMANAGER.crt $KEY_DIR/$NETWORKMANAGER.key $KEY_DIR/ca.crt \
    /etc/openvpn/

if [ -f $DIRNAME/etc/dh2048.pem ]; then
    cp $DIRNAME/etc/dh2048.pem /etc/openvpn
else
    ./build-dh
    cp -p $KEY_DIR/dh2048.pem /etc/openvpn/
fi

#
# Get openvpn setup and restarted.
#
cat <<EOF > /etc/openvpn/server.conf
local $MYIP
port 1194
proto udp
dev tun
ca ca.crt
cert $NETWORKMANAGER.crt
key $NETWORKMANAGER.key
dh dh2048.pem
server 192.168.0.0 255.255.0.0
client-config-dir /etc/openvpn/ccd
client-to-client
;duplicate-cn
keepalive 10 120
comp-lzo
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

mkdir -p /etc/openvpn/ccd

echo "192.168.0.1 $NETWORKMANAGER" > $OURDIR/mgmt-hosts

#
# Now build keys and set static IPs for the controller and the
# compute nodes.
#
o3=0
o4=3
for node in $CONTROLLER $COMPUTENODES
do
    fqdn="$node.$EEID.$EPID.$OURDOMAIN"

    ./build-key $node
    echo "ifconfig-push 192.168.$o3.$o4 255.255.0.0" \
	> /etc/openvpn/ccd/$node
    echo "192.168.$o3.$o4 $node" >> $OURDIR/mgmt-hosts

    # Skip 2 for openvpn tun tunnels
    o4=`expr $o4 + 2`
    if [ $o4 -gt 253 ] ; then
	o4=10
	o3=`expr $o3 + 1`
    fi
done

unset KEY_COUNTRY
unset KEY_PROVINCE
unset KEY_CITY
unset KEY_ORG
unset KEY_EMAIL
unset KEY_CN
unset KEY_NAME
unset KEY_OU
unset KEY_ALTNAMES

unset EASY_RSA
unset OPENSSL
unset PKCS11TOOL
unset GREP
unset KEY_CONFIG
unset PKCS11_MODULE_PATH
unset PKCS11_PIN
unset KEY_SIZE
unset CA_EXPIRE
unset KEY_EXPIRE

#
# Get the server up
#
service openvpn restart

#
# Get the hosts files setup to point to the new management network.
#
cat $OURDIR/mgmt-hosts > /etc/hosts
for node in $CONTROLLER $COMPUTENODES
do
    fqdn="$node.$EEID.$EPID.$OURDOMAIN"
    $SSH $fqdn mkdir -p $OURDIR
    scp -p -o StrictHostKeyChecking=no \
	/etc/openvpn/ca.crt $KEY_DIR/$node.crt $KEY_DIR/$node.key \
	$OURDIR/mgmt-hosts $SETTINGS $fqdn:$OURDIR
    $SSH $fqdn $DIRNAME/setup-vpn-client.sh
done

exit 0