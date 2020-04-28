#!/bin/sh

##
## Setup a OpenStack compute node for Nova.
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

if [ "$CONTROLLER" = "$HOSTNAME" -o "$NETWORKMANAGER" = "$HOSTNAME" ]; then
    exit 0;
fi

if [ -f $OURDIR/setup-compute-done ]; then
    exit 0
fi

logtstart "compute"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

#
# This is a nasty bug in oslo_service; see 
# https://review.openstack.org/#/c/256267/
#
if [ $OSVERSION -ge $OSKILO ]; then
    maybe_install_packages ${PYPKGPREFIX}-oslo.service
    patch -d / -p0 < $DIRNAME/etc/oslo_service-liberty-sig-MAINLOOP.patch
fi

maybe_install_packages python3-pip git
maybe_install_packages nova-compute sysfsutils
maybe_install_packages libguestfs-tools libguestfs0 python-guestfs

#
# Once we install packages, if the user wants a bigger VM disk space
# area, we make that and copy anything in /var/lib/nova into it (which
# may include stuff that was just installed).  Then we bind mount it to
# /var/lib/nova .
#
ROOTDISK=
if [ -e /dev/sda ]; then
    ROOTDISK=/dev/sda
    ROOTDEV=sda
    ROOTPART=4
elif [ -e /dev/nvme0n1 ]; then
    ROOTDISK=/dev/nvme0n1
    ROOTDEV=nvme0n1
    ROOTPART=p4
fi

#
# Try to use LVM for this if possible; otherwise try to fall back to
# partition 4.
# Check to see if we already have an `emulab` VG.  This would occur
# if the user requested a temp dataset.  If this happens, we simple
# rename it to the VG name we expect.
#
mkdir -p /storage
vgdisplay emulab
if [ $? -eq 0 -a "$COMPUTE_EXTRA_NOVA_DISK_SPACE" = "1" ]; then
    LVM=1
    VGNAME="openstack-volumes"

    vgrename emulab $VGNAME
    sed -i -re "s/^(.*)(\/dev\/emulab)(.*)$/\1\/dev\/$VGNAME\3/" /etc/fstab

    lvcreate -l 75%FREE -n nova $VGNAME
    if [ -f /sbin/mkfs.ext4 ]; then
	mkfs.ext4 /dev/$VGNAME/nova
    else
	mkfs.ext3 /dev/$VGNAME/nova
    fi
    mkdir -p /mnt/var-lib-nova
    echo "/dev/$VGNAME/nova /mnt/var-lib-nova none defaults 0 0" \
	 >> /etc/fstab
    mount /dev/$VGNAME/nova /mnt/var-lib-nova
    chown nova:nova /mnt/var-lib-nova
    rsync -avz /var/lib/nova/ /mnt/var-lib-nova/
    mount -o bind /mnt/var-lib-nova /var/lib/nova
    echo "/mnt/var-lib-nova /var/lib/nova none defaults,bind 0 0" \
	 >> /etc/fstab
elif [ "$COMPUTE_EXTRA_NOVA_DISK_SPACE" = "1" ]; then
    #
    # See if we can try to use an LVM instead of just the 4th partition.
    #
    lsblk -n -P -b -o NAME,FSTYPE,MOUNTPOINT,PARTTYPE,PARTUUID,TYPE,PKNAME,SIZE | perl -e 'my %devs = (); while (<STDIN>) { $_ =~ s/([A-Z0-9a-z]+=)/;\$$1/g; eval "$_"; if (!($TYPE eq "disk" || $TYPE eq "part")) { next; }; if (exists($devs{$PKNAME})) { delete $devs{$PKNAME}; } if ($FSTYPE eq "" && $MOUNTPOINT eq "" && ($PARTTYPE eq "" || $PARTTYPE eq "0x0") && (int($SIZE) > 3221225472)) { $devs{$NAME} = "/dev/$NAME"; } }; print join(" ",values(%devs))."\n"' > /tmp/devs
    DEVS=`cat /tmp/devs`
    if [ -n "$DEVS" ]; then
	VGNAME="openstack-volumes"
	pvcreate $DEVS
	vgcreate $VGNAME $DEVS
	lvcreate -l 75%FREE -n nova $VGNAME
	if [ -f /sbin/mkfs.ext4 ]; then
	    mkfs.ext4 /dev/$VGNAME/nova
	else
	    mkfs.ext3 /dev/$VGNAME/nova
	fi
	mkdir -p /mnt/var-lib-nova
	echo "/dev/$VGNAME/nova /mnt/var-lib-nova none defaults 0 0" \
	     >> /etc/fstab
	mount /dev/$VGNAME/nova /mnt/var-lib-nova
	chown nova:nova /mnt/var-lib-nova
	rsync -avz /var/lib/nova/ /mnt/var-lib-nova/
	mount -o bind /mnt/var-lib-nova /var/lib/nova
	echo "/mnt/var-lib-nova /var/lib/nova none defaults,bind 0 0" \
	     >> /etc/fstab
    elif [ -e $ROOTDISK ]; then
	PART="${ROOTDISK}${ROOTPART}"
	mkdir -p /mnt/var-lib-nova
	FORCEARG=""
	if [ ! -e $PART ]; then
	    echo "*** WARNING: attempting to create max-size $PART from free space!"
	    START=`sfdisk -F $ROOTDISK | tail -1 | awk '{ print $1; }'`
	    SIZE=`sfdisk -F $ROOTDISK | tail -1 | awk '{ print $3; }'`
	    sfdisk -d $ROOTDISK > /tmp/nparts.out
	    if [ $? -eq 0 -a -s /tmp/nparts.out ]; then
		echo "$PART : start=$START,size=$SIZE" >>/tmp/nparts.out
		cat /tmp/nparts.out | sfdisk $ROOTDISK --force
		if [ ! $? -eq 0 ]; then
		    echo "*** ERROR: failed to create new $PART!"
		else
		    # Need to force mkextrafs.pl because sfdisk cannot set a
		    # partition type of 0, and mkextrafs.pl will only work
		    # normally with part-type 0.
		    FORCEARG="-f"
		    partprobe
		    sleep 10
		fi
	    else
		echo "*** ERROR: could not dump $PART partitions!"
	    fi
	fi
	/usr/local/etc/emulab/mkextrafs.pl $FORCEARG -r $ROOTDEV -s 4 /mnt/var-lib-nova
	if [ $? = 0 ]; then
	    chown nova:nova /mnt/var-lib-nova
	    rsync -avz /var/lib/nova/ /mnt/var-lib-nova/
	    mount -o bind /mnt/var-lib-nova /var/lib/nova
	    echo "/mnt/var-lib-nova /var/lib/nova none defaults,bind 0 0" \
		 >> /etc/fstab
	else
	    echo "*** ERROR: could not make larger Nova /var/lib/nova dir!"
	fi
    fi
fi
crudini --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
crudini --set /etc/nova/nova.conf DEFAULT my_ip ${MGMTIP}
if [ $OSVERSION -lt $OSNEWTON ]; then
    crudini --set /etc/nova/nova.conf glance host $CONTROLLER
else
    crudini --set /etc/nova/nova.conf glance api_servers http://$CONTROLLER:9292
fi
crudini --set /etc/nova/nova.conf DEFAULT verbose ${VERBOSE_LOGGING}
crudini --set /etc/nova/nova.conf DEFAULT debug ${DEBUG_LOGGING}

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/nova/nova.conf DEFAULT rabbit_host $CONTROLLER
    crudini --set /etc/nova/nova.conf DEFAULT rabbit_userid ${RABBIT_USER}
    crudini --set /etc/nova/nova.conf DEFAULT rabbit_password "${RABBIT_PASS}"
elif [ $OSVERSION -lt $OSNEWTON ]; then
    crudini --set /etc/nova/nova.conf DEFAULT rpc_backend rabbit
    crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	rabbit_host $CONTROLLER
    crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	rabbit_userid ${RABBIT_USER}
    crudini --set /etc/nova/nova.conf oslo_messaging_rabbit \
	rabbit_password "${RABBIT_PASS}"
else
    crudini --set /etc/nova/nova.conf DEFAULT transport_url $RABBIT_URL
fi

if [ $OSVERSION -lt $OSKILO ]; then
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	auth_uri http://${CONTROLLER}:5000/v2.0
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	identity_uri http://${CONTROLLER}:${KADMINPORT}
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	admin_tenant_name service
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	admin_user nova
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	admin_password "${NOVA_PASS}"
else
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	${AUTH_URI_KEY} http://${CONTROLLER}:5000
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	auth_url http://${CONTROLLER}:${KADMINPORT}
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	project_name service
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	username nova
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	password "${NOVA_PASS}"
fi

if [ $OSVERSION -ge $OSMITAKA -o $KEYSTONEUSEMEMCACHE -eq 1 ]; then
    crudini --set /etc/nova/nova.conf keystone_authtoken \
	memcached_servers ${CONTROLLER}:11211
fi

if [ $OSVERSION -ge $OSKILO ]; then
    crudini --set /etc/nova/nova.conf oslo_concurrency \
	lock_path /var/lib/nova/tmp
fi

if [ $OSVERSION -ge $OSOCATA ]; then
    crudini --set /etc/nova/nova.conf placement \
	os_region_name $REGION
    crudini --set /etc/nova/nova.conf placement \
	auth_url http://${CONTROLLER}:${KADMINPORT}/v3
    crudini --set /etc/nova/nova.conf placement \
	${AUTH_TYPE_PARAM} password
    crudini --set /etc/nova/nova.conf placement \
	${PROJECT_DOMAIN_PARAM} default
    crudini --set /etc/nova/nova.conf placement \
	${USER_DOMAIN_PARAM} default
    crudini --set /etc/nova/nova.conf placement \
	project_name service
    crudini --set /etc/nova/nova.conf placement \
	username placement
    crudini --set /etc/nova/nova.conf placement \
	password "${PLACEMENT_PASS}"
fi

if [ $OSVERSION -ge $OSLIBERTY -a $OSVERSION -lt $OSNEWTON ]; then
    crudini --set /etc/nova/nova.conf enabled_apis 'osapi_compute,metadata'
    crudini --set /etc/nova/nova.conf DEFAULT \
	network_api_class nova.network.neutronv2.api.API
    crudini --set /etc/nova/nova.conf DEFAULT \
	security_group_api neutron
    crudini --set /etc/nova/nova.conf DEFAULT \
	linuxnet_interface_driver nova.network.linux_net.NeutronLinuxBridgeInterfaceDriver
fi
if [ $OSVERSION -ge $OSLIBERTY ]; then
    crudini --set /etc/nova/nova.conf DEFAULT use_neutron True
    crudini --set /etc/nova/nova.conf DEFAULT \
	firewall_driver nova.virt.firewall.NoopFirewallDriver
fi

VNCSECTION="DEFAULT"
VNCENABLEKEY="vnc_enabled"
if [ $OSVERSION -ge $OSLIBERTY ]; then
    VNCSECTION="vnc"
    VNCENABLEKEY="enabled"
fi

cname=`getfqdn $CONTROLLER`
if [ $OSVERSION -lt $OSQUEENS ]; then
    crudini --set /etc/nova/nova.conf $VNCSECTION \
        vncserver_listen ${MGMTIP}
    crudini --set /etc/nova/nova.conf $VNCSECTION \
	vncserver_proxyclient_address ${MGMTIP}
else
    crudini --set /etc/nova/nova.conf $VNCSECTION \
        server_listen ${MGMTIP}
    crudini --set /etc/nova/nova.conf $VNCSECTION \
	server_proxyclient_address ${MGMTIP}
fi

#
# https://bugs.launchpad.net/nova/+bug/1635131
#
if [ $OSVERSION -ge $OSNEWTON ]; then
    chost=`host $cname | sed -E -n -e 's/^(.* has address )(.*)$/\\2/p'`
    crudini --set /etc/nova/nova.conf $VNCSECTION \
	novncproxy_base_url "http://${chost}:6080/vnc_auto.html"
else
    crudini --set /etc/nova/nova.conf $VNCSECTION \
	novncproxy_base_url "http://${cname}:6080/vnc_auto.html"
fi

#
# Change $VNCENABLEKEY = True for x86 -- but for aarch64, there is
# no video device, for KVM mode, anyway, it seems.
#
ARCH=`uname -m`
if [ "$ARCH" = "aarch64" ] ; then
    if [ $OSVERSION -le $OSKILO ]; then
	crudini --set /etc/nova/nova.conf $VNCSECTION $VNCENABLEKEY False
    else
	# QEMU/Nova on Liberty gives aarch64 a vga adapter/bus.
	crudini --set /etc/nova/nova.conf $VNCSECTION $VNCENABLEKEY True
    fi
else
    crudini --set /etc/nova/nova.conf $VNCSECTION $VNCENABLEKEY True
fi

if [ ${ENABLE_NEW_SERIAL_SUPPORT} = 1 ]; then
    crudini --set /etc/nova/nova.conf serial_console enabled true
    crudini --set /etc/nova/nova.conf serial_console listen $MGMTIP
    crudini --set /etc/nova/nova.conf serial_console proxyclient_address $MGMTIP
    crudini --set /etc/nova/nova.conf serial_console base_url ws://${cname}:6083/
fi

crudini --set /etc/nova/nova-compute.conf DEFAULT \
    compute_driver libvirt.LibvirtDriver
crudini --set /etc/nova/nova-compute.conf libvirt virt_type kvm

if [ ${ENABLE_HOST_PASSTHROUGH} = 1 ]; then
    # turn off MSR emulation
    echo 1 > /sys/module/kvm/parameters/ignore_msrs
    # persist the setting in case we reboot
    echo "options kvm ignore_msrs=1" >> /etc/modprobe.d/qemu-system-x86.conf

    # Set the "host-passthrough" mode for libvirt
    crudini --set /etc/nova/nova-compute.conf libvirt cpu_mode host-passthrough
fi

if [ "$ARCH" = "aarch64" ] ; then
    crudini --set /etc/nova/nova-compute.conf libvirt cpu_mode custom
    crudini --set /etc/nova/nova-compute.conf libvirt cpu_model host

    if [ $OSVERSION -ge $OSLIBERTY -a $OSVERSION -le $OSMITAKA ]; then
	crudini --set /etc/nova/nova-compute.conf libvirt video_type vga
	crudini --set /etc/nova/nova-compute.conf libvirt use_usb_tablet False
    elif [ $OSVERSION -gt $OSMITAKA -a $OSVERSION -lt $OSPIKE ]; then
	crudini --set /etc/nova/nova-compute.conf libvirt video_type vga
	crudini --set /etc/nova/nova-compute.conf libvirt use_usb_tablet False
	crudini --set /etc/nova/nova-compute.conf DEFAULT pointer_model ps2mouse
    elif [ $OSVERSION -eq $OSPIKE ]; then
	patch -d / -p0 < $DIRNAME/etc/nova-pike-aarch64-virtio-video.patch
	crudini --set /etc/nova/nova-compute.conf libvirt video_type virtio
	crudini --set /etc/nova/nova-compute.conf DEFAULT pointer_model ps2mouse
    elif [ $OSVERSION -eq $OSQUEENS ]; then
	patch -d / -p0 < $DIRNAME/etc/nova-queens-aarch64-libvirt-bios-default.patch
    elif [ $OSVERSION -eq $OSROCKY ]; then
	patch -d / -p0 < $DIRNAME/etc/nova-rocky-aarch64-libvirt-bios-default.patch
    elif [ $OSVERSION -eq $OSSTEIN ]; then
	patch -d / -p0 < $DIRNAME/etc/nova-stein-aarch64-libvirt-bios-default.patch
    fi
elif [ "$ARCH" = "ppc64le" ] ; then
    ppc64_cpu --smt=off
    if [ -e /etc/rc.local ]; then
	cat <<EOF >>/etc/rc.local

ppc64_cpu --smt=off
EOF
    else
	cat <<EOF >/etc/rc.local
#!/bin/sh

ppc64_cpu --smt=off
EOF
	chmod 755 /etc/rc.local
    fi
fi

if [ ${OSCODENAME} = "juno" ]; then
    #
    # Patch quick :(
    #
    patch -d / -p0 < $DIRNAME/etc/nova-juno-root-device-name.patch
fi

#
# Somewhere libvirt-guests.service defaulted to suspending the guests.  Fix that.
#
if [ -f /etc/default/libvirt-guests ]; then
    echo ON_SHUTDOWN=shutdown >> /etc/default/libvirt-guests
    service_restart libvirt-guests
fi

service_restart nova-compute
service_enable nova-compute
service_restart libvirt-bin
service_enable libvirt-bin

#
# Install kuryr zun compute
#

# Creating kuryr user
groupadd --system kuryr
useradd --home-dir "/var/lib/kuryr" \
      --create-home \
      --system \
      --shell /bin/false \
      -g kuryr \
      kuryr

# Creating kuryr directories
mkdir -p /etc/kuryr
chown kuryr:kuryr /etc/kuryr

# Cloning and installing kuryr-libnetwork
apt-get install -y python3-pip
cd /var/lib/kuryr
git clone -b master https://git.openstack.org/openstack/kuryr-libnetwork.git
chown -R kuryr:kuryr kuryr-libnetwork
cd kuryr-libnetwork
pip3 install -r requirements.txt
python3 setup.py install

# Generating sample config
su -s /bin/sh -c "./tools/generate_config_file_samples.sh" kuryr
su -s /bin/sh -c "cp etc/kuryr.conf.sample \
      /etc/kuryr/kuryr.conf" kuryr

# Write config
crudini --set /etc/kuryr/kuryr.conf DEFAULT \
    bindir /usr/local/libexec/kuryr
crudini --set /etc/kuryr/kuryr.conf DEFAULT \
    capability_scope global
crudini --set /etc/kuryr/kuryr.conf DEFAULT \
    process_external_connectivity False

crudini --set /etc/kuryr/kuryr.conf neutron \
    www_authenticate_uri http://$CONTROLLER:5000
crudini --set /etc/kuryr/kuryr.conf neutron \
    auth_url http://$CONTROLLER:5000
crudini --set /etc/kuryr/kuryr.conf neutron \
    username kuryr
crudini --set /etc/kuryr/kuryr.conf neutron \
    user_domain_name default
crudini --set /etc/kuryr/kuryr.conf neutron \
    password "$KURYR_PASS"
crudini --set /etc/kuryr/kuryr.conf neutron \
    project_name service
crudini --set /etc/kuryr/kuryr.conf neutron \
    project_domain_name default
crudini --set /etc/kuryr/kuryr.conf neutron \
    auth_type password

# Create service
cat <<EOF >etc/systemd/system/kuryr-libnetwork.service
[Unit]
Description = Kuryr-libnetwork - Docker network plugin for Neutron

[Service]
ExecStart = /usr/local/bin/kuryr-server --config-file /etc/kuryr/kuryr.conf
CapabilityBoundingSet = CAP_NET_ADMIN

[Install]
WantedBy = multi-user.target
EOF

# Enable and start service
service_enable kuryr-libnetwork
service_restart kuryr-libnetwork

# Restart docker
service_restart docker

# Create zun User
groupadd --system zun
useradd --home-dir "/var/lib/zun" \
      --create-home \
      --system \
      --shell /bin/false \
      -g zun \
      zun

# Create directories
mkdir -p /etc/zun
chown zun:zun /etc/zun

# Create CNI Directories
mkdir -p /etc/cni/net.d
chown zun:zun /etc/cni/net.d

# Install dependencies
apt-get install -y python3-pip git numactl

# Clone and install zun
cd /var/lib/zun
git clone https://opendev.org/openstack/zun.git
chown -R zun:zun zun
cd zun
pip3 install -r requirements.txt
python3 setup.py install

# Generate a sample configuration file
su -s /bin/sh -c "oslo-config-generator \
    --config-file etc/zun/zun-config-generator.conf" zun
su -s /bin/sh -c "cp etc/zun/zun.conf.sample \
    /etc/zun/zun.conf" zun
su -s /bin/sh -c "cp etc/zun/rootwrap.conf \
    /etc/zun/rootwrap.conf" zun
su -s /bin/sh -c "mkdir -p /etc/zun/rootwrap.d" zun
su -s /bin/sh -c "cp etc/zun/rootwrap.d/* \
    /etc/zun/rootwrap.d/" zun
su -s /bin/sh -c "cp etc/cni/net.d/* /etc/cni/net.d/" zun

# Configure sudoers for zun users
echo "zun ALL=(root) NOPASSWD: /usr/local/bin/zun-rootwrap \
    /etc/zun/rootwrap.conf *" | sudo tee /etc/sudoers.d/zun-rootwrap

# Write config
crudini --set /etc/zun/zun.conf DEFAULT \
    transport_url $RABBIT_URL
crudini --set /etc/zun/zun.conf DEFAULT \
    state_path /var/lib

crudini --set /etc/zun/zun.conf database \
    connection "mysql+pymysql://zun:$ZUN_DBPASS@$CONTROLLER/zun"
crudini --set /etc/zun/zun.conf database \
    memcached_servers $CONTROLLER:11211

crudini --set /etc/zun/zun.conf keystone_auth \
    www_authenticate_uri http://$CONTROLLER:5000
crudini --set /etc/zun/zun.conf keystone_auth \
    project_domain_name default
crudini --set /etc/zun/zun.conf keystone_auth \
    project_name service
crudini --set /etc/zun/zun.conf keystone_auth \
    user_domain_name default
crudini --set /etc/zun/zun.conf keystone_auth \
    password "$ZUN_PASS"
crudini --set /etc/zun/zun.conf keystone_auth \
    username zun
crudini --set /etc/zun/zun.conf keystone_auth \
    auth_url http://$CONTROLLER:5000
crudini --set /etc/zun/zun.conf keystone_auth \
    auth_type password
crudini --set /etc/zun/zun.conf keystone_auth \
    auth_version v3
crudini --set /etc/zun/zun.conf keystone_auth \
    auth_protocol http
crudini --set /etc/zun/zun.conf keystone_auth \
    service_token_roles_required True
crudini --set /etc/zun/zun.conf keystone_auth \
    endpoint_type internalURL

crudini --set /etc/zun/zun.conf keystone_authtoken \
    memcached_servers $CONTROLLER:11211
crudini --set /etc/zun/zun.conf keystone_authtoken \
    www_authenticate_uri http://$CONTROLLER:500
crudini --set /etc/zun/zun.conf keystone_authtoken \
    project_domain_name default
crudini --set /etc/zun/zun.conf keystone_authtoken \
    project_name service
crudini --set /etc/zun/zun.conf keystone_authtoken \
    user_domain_name default
crudini --set /etc/zun/zun.conf keystone_authtoken \
    password "$ZUN_PASS"
crudini --set /etc/zun/zun.conf keystone_authtoken \
    zun
crudini --set /etc/zun/zun.conf keystone_authtoken \
    auth_url http://$CONTROLLER:5000
crudini --set /etc/zun/zun.conf keystone_authtoken \
    password

crudini --set /etc/zun/zun.conf oslo_concurrency \
    lock_path /var/lib/zun/tmp

crudini --set /etc/zun/zun.conf compute \
    host_shared_with_nova true

# Set owner of config
chown zun:zun /etc/zun/zun.conf

# Get Node ID
NODEID=`cat /var/emulab/boot/nickname | cut -d . -f 1`

# Create docker service config
mkdir -p /etc/systemd/system/docker.service.d
cat <<EOF >/etc/systemd/system/docker.service.d/docker.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --group zun -H tcp://$NODEID:2375 -H unix:///var/run/docker.sock --cluster-store etcd://$CONTROLLER:2379
EOF

# restart docker
systemctl daemon-reload

# configure containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/gid \?=.*/gid = '$(getent group zun | cut -d: -f3)'/' /etc/containerd/config.toml
chown zun:zun /etc/containerd/config.toml

# configure CNI
mkdir -p /opt/cni/bin
curl -L https://github.com/containernetworking/plugins/releases/download/v0.7.1/cni-plugins-amd64-v0.7.1.tgz \
      | tar -C /opt/cni/bin -xzvf - ./loopback
install -o zun -m 0555 -D /usr/local/bin/zun-cni /opt/cni/bin/zun-cni

# Create upstart config for zun
cat <<EOF >/etc/systemd/system/zun-compute.service
echo "[Unit]
Description = OpenStack Container Service Compute Agent

[Service]
ExecStart = /usr/local/bin/zun-compute
User = zun

[Install]
WantedBy = multi-user.target
EOF

# Create upstart config for zun cni daemon
cat <<EOF >/etc/systemd/system/zun-cni-daemon.service
echo "[Unit]
Description = OpenStack Container Service CNI daemon

[Service]
ExecStart = /usr/local/bin/zun-cni-daemon
User = zun

[Install]
WantedBy = multi-user.target
EOF

# restart containerd
service_restart containerd

# Enable and start zun
service_enable zun-compute
service_restart zun-compute

# Enable and start zun cni daemon
service_enable zun-cni-daemon
service_restart zun-cni-daemon

# XXXX ???
# rm -f /var/lib/nova/nova.sqlite

touch $OURDIR/setup-compute-done

logtend "compute"

exit 0
