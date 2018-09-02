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
###############################################################################

## Command line args
EXPECTED_NUM_ARGS=2
DEVICE=$1
HOSTNAME=$2

## Device constants
DEV_BY_PART=/dev/disk/by-partlabel/
DEV_MAP=/dev/mapper/

EFI_PART_LABEL=EFI
EFI_PART_PATH=${DEV_BY_PART}${EFI_PART_LABEL}
EFI_PART_NUM=1
EFI_PART_SIZE=+512M
EFI_PART_TYPE=ef00

SWAP_PART_CRYPT_LABEL=cryptswap
SWAP_PART_CRYPT_PATH=${DEV_BY_PART}${SWAP_PART_CRYPT_LABEL}
SWAP_PART_UNCRYPT_LABEL=swap
SWAP_PART_UNCRYPT_PATH=${DEV_MAP}${SWAP_PART_UNCRYPT_LABEL}
SWAP_PART_NUM=2
SWAP_PART_SIZE=`free -g --si | grep Mem | awk '{print $2}'`G
SWAP_PART_TYPE=8200

ROOT_PART_CRYPT_LABEL=cryptroot
ROOT_PART_CRYPT_PATH=${DEV_BY_PART}${ROOT_PART_CRYPT_LABEL}
ROOT_PART_UNCRYPT_LABEL=root
ROOT_PART_UNCRYPT_PATH=${DEV_MAP}${ROOT_PART_UNCRYPT_LABEL}
ROOT_PART_NUM=3
ROOT_PART_SIZE=0
ROOT_PART_TYPE=8300

## Mount point constants
ROOT_MOUNT=/mnt
BOOT_DIR=/boot
EFI_DIR=${BOOT_DIR}/efi
EFI_MOUNT=${ROOT_MOUNT}${EFI_DIR}

## System validation constants
NETWORK_TEST_HOST=www.google.com

## Other constants
DEFAULT_PROGRAMS="openssh git vim sudo"

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
    exec_cmd arch-chroot $ROOT_MOUNT "$*"
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
exec_cmd sgdisk --verify

echo "Removing any partition info from disk..."
exec_cmd sgdisk --zap-all $DEVICE

echo "Creating EFI boot, swap, and root partitions..."
sgdisk \
  --new=$EFI_PART_NUM:0:$EFI_PART_SIZE   --typecode=$EFI_PART_NUM:$EFI_PART_TYPE   --change-name=$EFI_PART_NUM:$EFI_PART_LABEL         \
  --new=$SWAP_PART_NUM:0:$SWAP_PART_SIZE --typecode=$SWAP_PART_NUM:$SWAP_PART_TYPE --change-name=$SWAP_PART_NUM:$SWAP_PART_CRYPT_LABEL \
  --new=$ROOT_PART_NUM:0:$ROOT_PART_SIZE --typecode=$ROOT_PART_NUM:$ROOT_PART_TYPE --change-name=$ROOT_PART_NUM:$ROOT_PART_CRYPT_LABEL \
  $DEVICE

echo "Verifing disk post partition creation..."
exec_cmd sgdisk --verify

# Sleep to allow /dev/disk/by-part-label to be created
sleep 1

# Verify new partitions exist
if [[ ! -b $EFI_PART_PATH ]]
then
    echo "EFI partition was not correctly identified. Tried to use: $EFI_PART_PATH"
    exit 1
fi

if [[ ! -b $SWAP_PART_CRYPT_PATH ]]
then
    echo "Swap partition was not correctly identified. Tried to use $SWAP_PART_CRYPT_PATH"
    exit 1
fi

if [[ ! -b $ROOT_PART_CRYPT_PATH ]]
then
    echo "Root partition was not correctly identified. Tried to use $ROOT_PART_CRYPT_PATH"
    exit 1
fi

### Create an encrypted root partition
echo "Encrypting partition $ROOT_PART_CRYPT_PATH"
exec_cmd cryptsetup --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-urandom luksFormat $ROOT_PART_CRYPT_PATH
echo "Opening partition $ROOT_PART_CRYPT_PATH at $ROOT_PART_UNCRYPT_PATH"
exec_cmd cryptsetup luksOpen $ROOT_PART_CRYPT_PATH $ROOT_PART_UNCRYPT_LABEL

echo "Creating encrypted swap partition"
cryptsetup open --type plain --key-file /dev/urandom ${SWAP_PART_CRYPT_PATH} ${SWAP_PART_UNCRYPT_LABEL}

### Format partitions
echo "Formatting EFI boot partition as FAT32"
exec_cmd mkfs.vfat $EFI_PART_PATH
echo "Formatting swap partition"
exec_cmd mkswap -L ${SWAP_PART_UNCRYPT_LABEL} ${SWAP_PART_UNCRYPT_PATH}
echo "Formatting root partition as ext4"
exec_cmd mkfs.ext4 $ROOT_PART_UNCRYPT_PATH

### Mount partitions
echo "Mounting root partition"
exec_cmd mount $ROOT_PART_UNCRYPT_PATH $ROOT_MOUNT
echo "Mounting EFI partition"
exec_cmd mkdir -p $EFI_MOUNT
exec_cmd mount $EFI_PART_PATH $EFI_MOUNT
echo "Enabling swap partition"
exec_cmd swapon -L ${SWAP_PART_UNCRYPT_LABEL}

### Install ArchLinux
# Prefer RIT's mirrorlist. Gotta show some school spirit!
exec_cmd sed -i '/rit/!d' /etc/pacman.d/mirrorlist
echo "Bootstraping ArchLinux with pacstrap"
exec_cmd pacstrap $ROOT_MOUNT base grub efibootmgr
echo "Running genfstab"
exec_cmd genfstab -t PARTLABEL $ROOT_MOUNT >> ${ROOT_MOUNT}/etc/fstab

echo "Setting locale..."
exec_chroot_cmd ln -fs /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
exec_chroot_cmd sed -i 's/#en_US.UTF-8/en_US.UTF-8/g' /etc/locale.gen
exec_chroot_cmd locale-gen
exec_cmd echo 'LANG=en_US.UTF-8' > ${ROOT_MOUNT}/etc/locale.conf
echo "Setting hardware clock..."
exec_chroot_cmd hwclock --systohc
echo "Setting hostname to ${HOSTNAME}..."
exec_cmd echo $HOSTNAME >> ${ROOT_MOUNT}/etc/hostname
exec_cmd echo "127.0.0.1\ ${HOSTNAME}.localdomain\ $HOSTNAME" >> ${ROOT_MOUNT}/etc/hosts
echo "Enabling dhcpcd service..."
exec_chroot_cmd systemctl enable dhcpcd

echo "Recursively changing permissions on ${BOOT_DIR} to 700..."
exec_chroot_cmd chmod -R 700 $BOOT_DIR

echo "Configuring initramfs..."
exec_chroot_cmd sed -i 's,block,keyboard\ block\ encrypt,g' /etc/mkinitcpio.conf
exec_chroot_cmd mkinitcpio -p linux

echo "Configuring grub..."
exec_chroot_cmd sed -i 's,GRUB_CMDLINE_LINUX=\"\",GRUB_CMDLINE_LINUX=\"cryptdevice='${ROOT_PART_CRYPT_PATH}':${ROOT_PART_UNCRYPT_LABEL}\",g' /etc/default/grub
exec_cmd echo 'GRUB_ENABLE_CRYPTODISK=y' >> ${ROOT_MOUNT}/etc/default/grub
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
mkdir -p ${ROOT_MOUNT}/etc/sudoers.d/
exec_cmd "echo '%wheel ALL=(ALL) ALL' > ${ROOT_MOUNT}/etc/sudoers.d/99-run-as-root"

if [[ $(prompt 'Intel chipset? [y/N] ') = "y" ]]
then
    exec_chroot_cmd pacman -S intel-ucode
fi

# Install default programs after the main install is done
exec_chroot_cmd pacman -S ${DEFAULT_PROGRAMS}

echo "Done!"

# References:
#  - https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system#Encrypted_boot_partition_.28GRUB.29
#  - https://wiki.archlinux.org/index.php/User:Altercation/Bullet_Proof_Arch_Install
