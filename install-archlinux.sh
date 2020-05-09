#!/bin/bash

###############################################################################
### install-archlinux.sh nukes a block device and installs archlinux
### Usage: ./install-archlinux.sh [block device] [machine hostname]
###   block device describes a linux block device such as a hard drive mounted
###   at /dev/sdaX hostname describes the hostname for the newly installed
###   machine.
### Note: You may need to increase the size of your ArchLinux boot disk's tmpfs
###    in order to install git. You can do so by running:
###    `mount -o remount,size=2G /run/archiso/cowspace`
### TODO:
###   * Add retry loop on user entries that could fail.
###############################################################################

# Default programs to be installed at the end of setup.
DEFAULT_PROGRAMS="base base-devel dhcpcd git linux linux-firmware lvm2 man-db man-pages mkinitcpio openssh sudo texinfo vim"

# Command line args.
EXPECTED_NUM_ARGS=2
DEVICE=$1
HOSTNAME=$2

# Device constants.
DEV_BY_PART=/dev/disk/by-partlabel/
DEV_MAP=/dev/mapper/

# EFI system partition (ESP) for UEFI boot
EFI_PART_NUM=1
EFI_PART_SIZE=+550M # 550M per https://wiki.archlinux.org/index.php/EFI_system_partition#Create_the_partition
EFI_PART_TYPE=ef00  # ef00 = EFI system partition type.
EFI_PART_LABEL=esp
EFI_PART_PATH=${DEV_BY_PART}${EFI_PART_LABEL}

# LUKS partition which LVM will reside on.
LUKS_PART_NUM=2
LUKS_PART_SIZE=0    # 0 means allocate all of the remaining space.
LUKS_PART_TYPE=8300 # 8300 = linux filesystem partition type.
LUKS_PART_CRYPT_LABEL=cryptlvm
LUKS_PART_CRYPT_PATH=${DEV_BY_PART}${LUKS_PART_CRYPT_LABEL}
LUKS_PART_UNCRYPT_LABEL=lvm
LUKS_PART_UNCRYPT_PATH=${DEV_MAP}${LUKS_PART_UNCRYPT_LABEL}

# LVM
VG_NAME=vg
ROOT_LV_NAME=root
ROOT_LV_PATH=${DEV_MAP}${VG_NAME}-${ROOT_LV_NAME}
SWAP_LV_NAME=swap
SWAP_LV_PATH=${DEV_MAP}${VG_NAME}-${SWAP_LV_NAME}
SWAP_LV_SIZE=`free -g --si | grep Mem | awk '{print $2}'`G

# Mount point constants.
ROOT_MOUNT_PATH=/mnt
EFI_CHROOT_MOUNT_PATH=/boot/efi
EFI_MOUNT_PATH=${ROOT_MOUNT_PATH}${EFI_CHROOT_MOUNT_PATH}
CRYPTO_KEY_PATH=/crypto_keyfile.bin

# System validation constants.
NETWORK_TEST_HOST=www.google.com


#######################
## Utility Functions ##
#######################

usage_and_exit() {
    echo "usage: ./install-archlinux.sh [block device] [machine hostname]"
    exit 1
}

exec_cmd() {
    eval "$*"
    if [[ $? -ne 0 ]]
    then
        echo "Could not execute command: $*"
        exit 1
    fi
}

exec_chroot_cmd() {
    exec_cmd arch-chroot ${ROOT_MOUNT_PATH} "$*"
}

prompt() {
    read -p "$1"
    echo ${REPLY}
}


#################
## Validations ##
#################

if [[ $# -ne ${EXPECTED_NUM_ARGS} ]]
then
    echo "Expected ${EXPECTED_NUM_ARGS} args but got $# args"
    usage_and_exit
fi

if [[ ! -b ${DEVICE} ]]
then
    echo "${DEVICE} is not a block device"
    usage_and_exit
fi

echo "Ensuring we are booted in UEFI mode..."
if [[ ! -d /sys/firmware/efi/efivars ]]
then
    echo "/sys/firmware/efi/efivars does not exist. Ensure you are booted in UEFI mode."
    exit 1
fi

echo "Testing network connection..."
ping -c 3 ${NETWORK_TEST_HOST} 1>/dev/null
if [[ $? -ne 0 ]]
then
    echo "Could not ping ${NETWORK_TEST_HOST}. Ensure network and DNS is working."
    exit 1
fi

read -p "Are you sure you want to nuke ${DEVICE} [y/N]? " NUKE_DEVICE
if [[ ! ${NUKE_DEVICE} = "y" ]]
then
    echo "Aborting installation."
    exit 1
fi


####################
## Partition disk ##
####################

# Partition disk.
#   verify -> zap -> make efi partition -> make root partition -> verify
echo "Verifying disk..."
exec_cmd sgdisk --verify

echo "Removing any partition info from disk..."
exec_cmd sgdisk --zap-all ${DEVICE}

echo "Creating a single partition to be encrypted by LUKS. EFI boot, swap, and root partitions will be created on top of that LUKS volume using LVM."
sgdisk \
  --new=${EFI_PART_NUM}:0:${EFI_PART_SIZE}   --typecode=${EFI_PART_NUM}:${EFI_PART_TYPE}   --change-name=${EFI_PART_NUM}:${EFI_PART_LABEL} \
  --new=${LUKS_PART_NUM}:0:${LUKS_PART_SIZE} --typecode=${LUKS_PART_NUM}:${LUKS_PART_TYPE} --change-name=${LUKS_PART_NUM}:${LUKS_PART_CRYPT_LABEL} \
  ${DEVICE}

echo "Verifing disk post partition creation..."
exec_cmd sgdisk --verify

# Sleep to allow /dev/disk/by-part-label to be created.
sleep 1

# Verify new partitions exist.
if [[ ! -b ${EFI_PART_PATH} ]]
then
    echo "EFI partition was not correctly identified. Tried to use: ${EFI_PART_PATH}"
    exit 1
fi

if [[ ! -b ${LUKS_PART_CRYPT_PATH} ]]
then
    echo "LUKS partition was not correctly identified. Tried to use: ${LUKS_PART_CRYPT_PATH}"
    exit 1
fi

# Create the encrypted volume for LVM.
echo "Creating an encrypted volume on partition: ${LUKS_PART_CRYPT_PATH}"
exec_cmd cryptsetup --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-urandom --type luks1 luksFormat ${LUKS_PART_CRYPT_PATH}

# Open/mount the new encrypted volume for LVM.
echo "Opening volume on partition ${LUKS_PART_CRYPT_PATH} at ${LUKS_PART_UNCRYPT_PATH}"
exec_cmd cryptsetup luksOpen ${LUKS_PART_CRYPT_PATH} ${LUKS_PART_UNCRYPT_LABEL}


################################
## Set up LVM logical volumes ##
################################

# LVM wiki - https://wiki.archlinux.org/index.php/LVM
# Physical volume (PV)
#     Partition on hard disk (or even the disk itself or loopback file) on which you can have volume groups. It has a special header and is divided into physical extents. Think of physical volumes as big building blocks used to build your hard drive.
# Volume group (VG)
#     Group of physical volumes used as a storage volume (as one disk). They contain logical volumes. Think of volume groups as hard drives.
# Logical volume (LV)
#     A "virtual/logical partition" that resides in a volume group and is composed of physical extents. Think of logical volumes as normal partitions.

# Create LVM physical volume on the encrypted partition that was just opened.
pvcreate ${LUKS_PART_UNCRYPT_PATH}

# Create LVM volume group using the LVM physical volume just created.
vgcreate ${VG_NAME} ${LUKS_PART_UNCRYPT_PATH}

# Create LVM logical volumes for installation.
lvcreate -L ${SWAP_LV_SIZE} ${VG_NAME} -n ${SWAP_LV_NAME}
lvcreate -l +100%FREE       ${VG_NAME} -n ${ROOT_LV_NAME}

# Format logical volumes.
echo "Formatting swap partition"
exec_cmd mkswap -L ${SWAP_LV_NAME} ${SWAP_LV_PATH}
echo "Formatting root partition as ext4"
exec_cmd mkfs.ext4 ${ROOT_LV_PATH}

# Mount partitions.
echo "Mounting root partition to ${ROOT_MOUNT_PATH}"
exec_cmd mount ${ROOT_LV_PATH} ${ROOT_MOUNT_PATH}
echo "Enabling swap partition"
exec_cmd swapon ${SWAP_LV_PATH}

# Format and mount EFI partition.
echo "Formatting EFI partition as FAT32"
exec_cmd mkfs.vfat ${EFI_PART_PATH}
echo "Mounting EFI partition to ${EFI_MOUNT_PATH}"
exec_cmd mkdir -p ${EFI_MOUNT_PATH}
exec_cmd mount ${EFI_PART_PATH} ${EFI_MOUNT_PATH}


#######################
## Install Archlinux ##
#######################

# Prefer RIT's mirrorlist. Gotta show some school spirit!
exec_cmd sed -i '/rit/!d' /etc/pacman.d/mirrorlist
echo "Bootstraping ArchLinux with pacstrap"
exec_cmd pacstrap ${ROOT_MOUNT_PATH} base grub-efi-x86_64 efibootmgr ${DEFAULT_PROGRAMS}
echo "Running genfstab"
exec_cmd genfstab -t PARTLABEL ${ROOT_MOUNT_PATH} >> ${ROOT_MOUNT_PATH}/etc/fstab


############################
## Configure installation ##
############################

echo "Setting locale..."
exec_chroot_cmd ln -fs /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
exec_chroot_cmd sed -i 's/#en_US.UTF-8/en_US.UTF-8/g' /etc/locale.gen
exec_chroot_cmd locale-gen
exec_cmd echo 'LANG=en_US.UTF-8' > ${ROOT_MOUNT_PATH}/etc/locale.conf
echo "Setting hardware clock..."
exec_chroot_cmd hwclock --systohc
echo "Setting hostname to ${HOSTNAME}..."
exec_cmd echo ${HOSTNAME} >> ${ROOT_MOUNT_PATH}/etc/hostname
exec_cmd echo "127.0.0.1\ ${HOSTNAME}.localdomain\ ${HOSTNAME}" >> ${ROOT_MOUNT_PATH}/etc/hosts
echo "Enabling dhcpcd service..."
exec_chroot_cmd systemctl enable dhcpcd

echo "Recursively changing permissions on /boot to 700..."
exec_chroot_cmd chmod -R 700 /boot

# Allow logging in with single password prompt.
# https://www.pavelkogan.com/2014/05/23/luks-full-disk-encryption/#bonus-login-once
exec_cmd dd bs=512 count=4 if=/dev/urandom of=${ROOT_MOUNT_PATH}${CRYPTO_KEY_PATH}
exec_cmd chmod 000 ${ROOT_MOUNT_PATH}${CRYPTO_KEY_PATH}
exec_cmd cryptsetup luksAddKey ${LUKS_PART_CRYPT_PATH} ${ROOT_MOUNT_PATH}${CRYPTO_KEY_PATH}
exec_chroot_cmd sed -i '"s,FILES=(),FILES=(${CRYPTO_KEY_PATH}),g"' /etc/mkinitcpio.conf

echo "Configuring initramfs..."
exec_chroot_cmd sed -i 's,block,keyboard\ block\ encrypt\ lvm2\ resume,g' /etc/mkinitcpio.conf
exec_chroot_cmd mkinitcpio -p linux

echo "Configuring grub..."
exec_chroot_cmd sed -i 's,GRUB_CMDLINE_LINUX=\"\",GRUB_CMDLINE_LINUX=\"cryptdevice=${LUKS_PART_CRYPT_PATH}:${LUKS_PART_UNCRYPT_LABEL}\ resume=${SWAP_LV_PATH}\",g' /etc/default/grub
exec_chroot_cmd echo 'GRUB_ENABLE_CRYPTODISK=y' >> ${ROOT_MOUNT_PATH}/etc/default/grub
# Including the device path is not necessary.
# Per https://wiki.archlinux.org/index.php/GRUB#Installation_2
#   You might note the absence of a device_path option (e.g.: /dev/sda) in the
#   grub-install command. In fact any device_path provided will be ignored by
#   the GRUB UEFI install script. Indeed, UEFI bootloaders do not use a MBR
#   bootcode or partition boot sector at all.
exec_chroot_cmd grub-install --target=x86_64-efi --efi-directory=${EFI_CHROOT_MOUNT_PATH} --bootloader-id=GRUB --recheck
exec_chroot_cmd grub-mkconfig -o /boot/grub/grub.cfg

echo "Disabling root account in preference of a user account with sudo"
echo "Changing root password to something random..."
exec_chroot_cmd echo "root:`base64 /dev/urandom | tr -d '[:space:]' | head -c 100`" | chpasswd
# Ref: https://wiki.archlinux.org/index.php/Sudo#Disable_root_login
echo "Locking the root account too because why not!"
exec_chroot_cmd passwd -l root

# Configure a new user since the root account is now disabled.
# Allow user to run-as root - what's the worst that could happen?
echo "Creating a new user account with sudo privileges"
read -p 'Enter a username: ' USERNAME
exec_chroot_cmd useradd -G wheel -m ${USERNAME}
echo "Creating user account: ${USERNAME}"
echo "Changing password for new user account..."
exec_chroot_cmd passwd ${USERNAME}
mkdir -p ${ROOT_MOUNT_PATH}/etc/sudoers.d/
exec_cmd "echo '%wheel ALL=(ALL) ALL' > ${ROOT_MOUNT_PATH}/etc/sudoers.d/99-run-as-root"

# Install microcode updates from intel.
if [[ $(prompt 'Intel chipset? [y/N] ') = "y" ]]
then
    exec_chroot_cmd "pacman -S intel-ucode"
fi

# Install wifi drivers if this is a laptop.
if [[ $(prompt 'Is this a laptop? [y/N] ') = "y" ]]
then
    exec_chroot_cmd "pacman -S wpa_supplicant"
fi

echo "Done!"

# References:
#  - https://web.archive.org/web/20180117044934/http://www.pavelkogan.com:80/2014/05/23/luks-full-disk-encryption
#  - https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system#Encrypted_boot_partition_.28GRUB.29
#  - https://wiki.archlinux.org/index.php/User:Altercation/Bullet_Proof_Arch_Install
