#!/bin/bash -eu

CURDIR=$(cd $(dirname $0); pwd)

. ../var.conf


parted ${DEVICE} -s 'mktable gpt'
parted ${DEVICE} -s 'mkpart primary ext4 1 2'
parted ${DEVICE} -s 'set 1 bios_grub on'
parted ${DEVICE} -s 'mkpart primary xfs 2 100%'

mkfs.xfs -L root ${DEVICE}2
mkdir -p ${ROOTFS}
mount ${DEVICE}2 ${ROOTFS}


### Basic CentOS Install and necessary packages
sed -e "s/#CENTOS_VER#/${CENTOS_VER}/" ${CURDIR}/conf/yum_ami.conf.tmpl > ${CURDIR}/conf/yum_ami.conf
yum -c ${CURDIR}/conf/yum_ami.conf --installroot=${ROOTFS} \
  --disablerepo=* --enablerepo=ami-base,ami-updates  --nogpgcheck -y install /bin/sh

curl -L http://ftp.riken.jp/Linux/centos/RPM-GPG-KEY-CentOS-7 > ${ROOTFS}/RPM-GPG-KEY-CentOS-7

rpm --root=${ROOTFS} --initdb

set +e
rpm --root=$ROOTFS -ivh ${CENTOS_RELEASE_RPM_URL}
set -e

yum --installroot=${ROOTFS} --nogpgcheck -y groupinstall core
yum --installroot=${ROOTFS} --nogpgcheck -y install openssh-server grub2 acpid deltarpm nvme-cli dracut-config-generic \
    cloud-init cloud-utils-growpart gdisk


# Remove unnecessary packages
UNNECESSARY="NetworkManager firewalld linux-firmware ivtv-firmware iwl*firmware"
yum --installroot=${ROOTFS} -C -y remove $UNNECESSARY --setopt="clean_requirements_on_remove=1"

# Create homedir for root
cp -a /etc/skel/.bash* ${ROOTFS}/root

## Networking setup
cp ${CURDIR}/conf/etc/hosts ${ROOTFS}/etc/hosts

touch ${ROOTFS}/etc/resolv.conf
cp ${CURDIR}/conf/etc/sysconfig/network ${ROOTFS}/etc/sysconfig/network
cp ${CURDIR}/conf/etc/sysconfig/network-scripts/ifcfg-eth0 ${ROOTFS}/etc/sysconfig/network-scripts/ifcfg-eth0
cp /usr/share/zoneinfo/UTC ${ROOTFS}/etc/localtime
echo 'ZONE="UTC"' > ${ROOTFS}/etc/sysconfig/clock

# fstab
cp ${CURDIR}/conf/etc/fstab ${ROOTFS}/etc/fstab

#grub config taken from /etc/sysconfig/grub on RHEL7 AMI
cp ${CURDIR}/conf/etc/default/grub ${ROOTFS}/etc/default/grub
echo 'RUN_FIRSTBOOT=NO' > ${ROOTFS}/etc/sysconfig/firstboot

BINDMNTS="dev sys etc/hosts etc/resolv.conf"

for d in $BINDMNTS ; do
  mount --bind /${d} ${ROOTFS}/${d}
done
mount -t proc none ${ROOTFS}/proc
# Install grub2
chroot ${ROOTFS} grub2-mkconfig -o /boot/grub2/grub.cfg
chroot ${ROOTFS} grub2-install $DEVICE

# Startup services
chroot ${ROOTFS} systemctl enable sshd.service
chroot ${ROOTFS} systemctl enable cloud-init.service
chroot ${ROOTFS} systemctl mask tmp.mount

# Configure cloud-init
cp ${CURDIR}/conf/etc/cloud/cloud.cfg ${ROOTFS}/etc/cloud/cloud.cfg

#Disable SELinux
sed -i -e 's/^\(SELINUX=\).*/\1disabled/' ${ROOTFS}/etc/selinux/config

# Clean up
yum --installroot=$ROOTFS clean all
truncate -c -s 0 ${ROOTFS}/var/log/yum.log


# We're done!
for d in $BINDMNTS ; do
  umount ${ROOTFS}/${d}
done
umount ${ROOTFS}/proc
sync
umount ${ROOTFS}
