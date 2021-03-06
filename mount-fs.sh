#!/bin/bash

###############################################################################
### mount-fs.sh mounts everything set up via install-archlinux.sh
### Usage: ./mount-fs
###############################################################################

# Device constants.
DEV_BY_PART=/dev/disk/by-partlabel/
DEV_MAP=/dev/mapper/

# EFI system partition (ESP) for UEFI boot.
EFI_PART_LABEL=esp
EFI_PART_PATH=${DEV_BY_PART}${EFI_PART_LABEL}

# LUKS partition.
LUKS_PART_CRYPT_LABEL=cryptlvm
LUKS_PART_CRYPT_PATH=${DEV_BY_PART}${LUKS_PART_CRYPT_LABEL}
LUKS_PART_UNCRYPT_LABEL=lvm
LUKS_PART_UNCRYPT_PATH=${DEV_MAP}${LUKS_PART_UNCRYPT_LABEL}

# LVM.
VG_NAME=vg
ROOT_LV_NAME=root
ROOT_LV_PATH=${DEV_MAP}${VG_NAME}-${ROOT_LV_NAME}
SWAP_LV_NAME=swap
SWAP_LV_PATH=${DEV_MAP}${VG_NAME}-${SWAP_LV_NAME}

# Mount point constants.
ROOT_MOUNT_PATH=/mnt
EFI_CHROOT_MOUNT_PATH=/efi
EFI_MOUNT_PATH=${ROOT_MOUNT_PATH}${EFI_CHROOT_MOUNT_PATH}


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

#################
## Validations ##
#################

if [[ $# -ne ${EXPECTED_NUM_ARGS} ]]
then
    echo "Expected ${EXPECTED_NUM_ARGS} args but got $# args"
    usage_and_exit
fi

# Verify partitions exist.
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

######################
## Mount Everything ##
######################

# Open/mount encrypted volume for LVM.
echo "Opening volume on partition ${LUKS_PART_CRYPT_PATH} at ${LUKS_PART_UNCRYPT_PATH}"
exec_cmd cryptsetup luksOpen ${LUKS_PART_CRYPT_PATH} ${LUKS_PART_UNCRYPT_LABEL}

# Mount root partition.
echo "Mounting root partition to ${ROOT_MOUNT_PATH}"
exec_cmd mount ${ROOT_LV_PATH} ${ROOT_MOUNT_PATH}

# Mount EFI partition.
echo "Mounting EFI partition to ${EFI_MOUNT_PATH}"
exec_cmd mkdir -p ${EFI_MOUNT_PATH}
exec_cmd mount ${EFI_PART_PATH} ${EFI_MOUNT_PATH}

# Mount swap partition.
echo "Enabling swap partition"
exec_cmd swapon ${SWAP_LV_PATH}


echo "Done!"
