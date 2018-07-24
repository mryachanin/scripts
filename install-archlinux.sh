#!/bin/bash

### Nukes a block device and installs archlinux
### Usage: ./install-archlinux.sh [block device] [machine hostname]
###   block device describes a linux block device such as a hard drive mounted at /dev/sdaX
###   hostname describes the hostname for the newly installed machine
### Note: You may need to increase the size of your ArchLinux boot disk's tmpfs in order to
###   install git. You can do so by running:
###   `mount -o remount,size=2G /run/archiso/cowspace`
## Command line args
EXPECTED_NUM_ARGS=2
DEVICE=$1
HOSTNAME=$2

## Device args
DEV_BY_PART="/dev/disk/by-partlabel/"
EFI_PART_LABEL="EFI"
EFI_PART_NAME=${DEV_BY_PART}${EFI_PART_LABEL}
EFI_PART_NUM=1
EFI_PART_SIZE="+512M"
EFI_PART_TYPE="ef00"

ROOT_PART_LABEL="ROOT"
ROOT_PART_NAME=${DEV_BY_PART}${ROOT_PART_LABEL}
ROOT_PART_NUM=2
ROOT_PART_SIZE=0
ROOT_PART_TYPE="8300"

CRYPT_ROOT_PART_NAME_SHORT="cryptroot"
CRYPT_ROOT_PART_NAME=/dev/mapper/${CRYPT_ROOT_PART_NAME_SHORT}
CRYPT_ROOT_MOUNT=/mnt

BOOT_DIR=/boot
EFI_DIR=${BOOT_DIR}/efi
EFI_MOUNT=${CRYPT_ROOT_MOUNT}${EFI_DIR}

KEYFILE_NAME='/crypto_keyfile.bin'

## Test params
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
    exec_cmd arch-chroot $CRYPT_ROOT_MOUNT "$*"
}

prompt() {
    read -p "$1"
    echo $REPLY
}


#################
## Validations ##
#################

if [[ $# -ne $EXPECTED_NUM_ARGS ]]
then
    echo "Expected $EXPECTED_NUM_ARGS args but got $# args"
    usage_and_exit
fi

if [[ ! -b $DEVICE ]]
then
    echo "$DEVICE is not a block device"
    usage_and_exit
fi

echo "Ensuring we are booted in UEFI mode..."
if [[ ! -d /sys/firmware/efi/efivars ]]
then
    echo "/sys/firmware/efi/efivars does not exist. Ensure you are booted in UEFI mode."
    exit 1
fi

echo "Testing network connection..."
ping -c 3 $NETWORK_TEST_HOST 1>/dev/null
if [[ $? -ne 0 ]]
then
    echo "Could not ping $NETWORK_TEST_HOST. Ensure network and DNS is working."
    exit 1
fi

read -p "Are you sure you want to nuke $DEVICE [y/N]? " NUKE_DEVICE
if [[ ! $NUKE_DEVICE = "y" ]]
then
    echo "Aborting installation."
    exit 1
fi


#############################
## Start the installation! ##
#############################

### Partition disk
## verify -> zap -> make efi partition -> make root partition -> verify
echo "Verifying disk..."
exec_cmd sgdisk -v
echo "Removing any partition info from disk..."
exec_cmd sgdisk -Z $DEVICE
echo "Creating EFI boot partition..."
exec_cmd sgdisk -n $EFI_PART_NUM:0:$EFI_PART_SIZE -t $EFI_PART_NUM:$EFI_PART_TYPE -c $EFI_PART_NUM:$EFI_PART_LABEL $DEVICE
echo "Creating root partition..."
exec_cmd sgdisk -n $ROOT_PART_NUM:0:$ROOT_PART_SIZE -t $ROOT_PART_NUM:$ROOT_PART_TYPE -c $ROOT_PART_NUM:$ROOT_PART_LABEL $DEVICE
echo "Verifing disk post partition creation..."
exec_cmd sgdisk -v

# sleep to allow /dev/disk/by-part-label to be created
sleep 1

if [[ ! -b $EFI_PART_NAME ]]
then
    echo "EFI partition was not correctly identified. Tried to use: $EFI_PART_NAME"
    exit 1
fi

if [[ ! -b $ROOT_PART_NAME ]]
then
    echo "Root partition was not correctly identified. Tried to use $ROOT_PART_NAME"
    exit 1
fi

### Create an encrypted partition
echo "Encrypting device $ROOT_PART_NAME"
exec_cmd cryptsetup --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-urandom luksFormat $ROOT_PART_NAME
echo "Opening partition $ROOT_PART_NAME at $CRYPT_ROOT_PART_NAME"
exec_cmd cryptsetup luksOpen $ROOT_PART_NAME $CRYPT_ROOT_PART_NAME_SHORT

### Format partitions
echo "Formatting EFI boot partition as FAT32"
exec_cmd mkfs.vfat $EFI_PART_NAME
echo "Formatting root partition as ext4"
exec_cmd mkfs.ext4 $CRYPT_ROOT_PART_NAME

### Mount partitions
exec_cmd mount $CRYPT_ROOT_PART_NAME $CRYPT_ROOT_MOUNT
exec_cmd mkdir -p $EFI_MOUNT
exec_cmd mount $EFI_PART_NAME $EFI_MOUNT

### Install ArchLinux
exec_cmd sed -i '/rit/!d' /etc/pacman.d/mirrorlist
exec_cmd pacstrap $CRYPT_ROOT_MOUNT base base-devel grub efibootmgr
exec_cmd genfstab -t PARTLABEL $CRYPT_ROOT_MOUNT >> ${CRYPT_ROOT_MOUNT}/etc/fstab

echo "Setting locale..."
exec_chroot_cmd ln -fs /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
exec_chroot_cmd sed -i 's/#en_US.UTF-8/en_US.UTF-8/g' /etc/locale.gen
exec_chroot_cmd locale-gen
exec_cmd echo 'LANG=en_US.UTF-8' > ${CRYPT_ROOT_MOUNT}/etc/locale.conf
echo "Setting hardware clock..."
exec_chroot_cmd hwclock --systohc
echo "Setting hostname to ${HOSTNAME}..."
exec_cmd echo $HOSTNAME >> ${CRYPT_ROOT_MOUNT}/etc/hostname
exec_cmd echo "127.0.0.1\ ${HOSTNAME}.localdomain\ $HOSTNAME" >> ${CRYPT_ROOT_MOUNT}/etc/hosts
echo "Enabling dhcpcd service..."
exec_chroot_cmd systemctl enable dhcpcd

# Set up crypto keyfile to only prompt disk encryption password once on boot
# See: https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system#Configuring_fstab_and_crypttab_2
echo "Creating crypto keyfile at ${KEYFILE_NAME}..."
exec_chroot_cmd dd bs=512 count=8 if=/dev/urandom of=$KEYFILE_NAME
echo "Changing permissions on ${KEYFILE_NAME} to 000..."
exec_chroot_cmd chmod 000 $KEYFILE_NAME
echo "Recursively changing permissions on ${BOOT_DIR} to 700..."
exec_chroot_cmd chmod -R 700 $BOOT_DIR
echo "Adding crypto keyfile to root partition so you don't need to enter your password twice on boot..."
exec_chroot_cmd cryptsetup luksAddKey $ROOT_PART_NAME $KEYFILE_NAME

echo "Configuring initramfs..."
exec_chroot_cmd sed -i 's,FILES=\"\",FILES=\"'$KEYFILE_NAME'\",g' /etc/mkinitcpio.conf
exec_chroot_cmd sed -i 's,block,keyboard\ block\ encrypt,g' /etc/mkinitcpio.conf
exec_chroot_cmd mkinitcpio -p linux

echo "Configuring grub..."
exec_chroot_cmd sed -i 's,GRUB_CMDLINE_LINUX=\"\",GRUB_CMDLINE_LINUX=\"cryptdevice=/dev/disk/by-partlabel/'${ROOT_PART_LABEL}':cryptroot\",g' /etc/default/grub
exec_cmd echo 'GRUB_ENABLE_CRYPTODISK=y' >> ${CRYPT_ROOT_MOUNT}/etc/default/grub
exec_chroot_cmd grub-mkconfig -o /boot/grub/grub.cfg
exec_chroot_cmd grub-install --target=x86_64-efi --efi-directory=$EFI_DIR --bootloader-id=grub --recheck

echo "Setting new root password..."
exec_chroot_cmd passwd

# Configure user
read -p 'Enter a username: ' USERNAME
exec_chroot_cmd useradd -G wheel -m $USERNAME
echo "Creating user account: $USERNAME"
echo "Setting new user password..."
exec_chroot_cmd passwd $USERNAME

# Allow user to run-as root - what's the worst that could happen?
exec_cmd "echo '%wheel ALL=(ALL) ALL' > ${CRYPT_ROOT_MOUNT}/etc/sudoers.d/99-run-as-root"

if [[ $(prompt 'Intel chipset? [y/N] ') = "y" ]]
then
    exec_chroot_cmd pacman -S intel-ucode
fi

echo "Done!"

# References:
#  - https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system#Encrypted_boot_partition_.28GRUB.29
