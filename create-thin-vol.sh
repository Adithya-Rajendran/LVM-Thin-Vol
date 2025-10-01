#!/bin/bash
#
# A script to fully partition a disk for a standard Ubuntu install with LVM thin-provisioning.
# It creates EFI, /boot, and an LVM structure for the root filesystem.
#
# Meant to be run from the shell (F2) in the Ubuntu installer.
#
# WARNING: THIS SCRIPT IS DESTRUCTIVE AND WILL WIPE THE TARGET DISK.

set -e
set -o pipefail

EFI_SIZE="1G"      # Size for the EFI System (/boot/efi) Partition
BOOT_SIZE="2G"     # Size for the /boot partition
VG_NAME="vg0"
THIN_VOL="thin_pool"
ROOT_LV_NAME="lv-0"

# --- Validation ---
if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: This script must be run as root. Please use sudo."
  exit 1
fi

if [[ -z "$1" ]]; then
  echo "Usage: $0 /dev/sdX"
  echo "Please provide the target block device as an argument."
  exit 1
fi

DEVICE=$1

if [[ ! -b "${DEVICE}" ]]; then
  echo "Error: Device '${DEVICE}' not found or is not a block device."
  exit 1
fi

echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "This script will COMPLETELY WIPE all data on the device: ${DEVICE}."
echo "It will create a GPT partition table with the following layout:"
echo "  - P1: ${EFI_SIZE} for /boot/efi"
echo "  - P2: ${BOOT_SIZE} for /boot"
echo "  - P3: LVM for the rest of the disk"
echo ""
echo "The LVM layout will be:"
echo "  - VG:           ${VG_NAME}"
echo "  - Root LV:      ${ROOT_LV_NAME} (using 80% of the pool)"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "To confirm you understand and wish to proceed, type 'YES': " CONFIRMATION

if [[ "${CONFIRMATION}" != "YES" ]]; then
  echo "Aborting script. No changes were made."
  exit 0
fi

echo ""
echo "Wiping disk and creating partition table on ${DEVICE}..."

BOOT_START_POINT=${EFI_SIZE}
BOOT_END_POINT=$((${EFI_SIZE%G} + ${BOOT_SIZE%G}))G

parted -s -a optimal -- "${DEVICE}" \
    mklabel gpt \
    mkpart "'EFI System Partition'" fat32 1MiB ${BOOT_START_POINT} \
    set 1 esp on \
    mkpart "'Boot Partition'" ext4 ${BOOT_START_POINT} ${BOOT_END_POINT} \
    mkpart "'LVM Partition'" ext4 ${BOOT_END_POINT} 100% \
    set 3 lvm on

partprobe "${DEVICE}"
sleep 2

# Determine partition naming convention (e.g., /dev/sda1 vs /dev/nvme0n1p1)
PARTITION_SUFFIX=""
if [[ "${DEVICE}" =~ "nvme" || "${DEVICE}" =~ "mmcblk" ]]; then
    PARTITION_SUFFIX="p"
fi

EFI_PARTITION="${DEVICE}${PARTITION_SUFFIX}1"
BOOT_PARTITION="${DEVICE}${PARTITION_SUFFIX}2"
LVM_PARTITION="${DEVICE}${PARTITION_SUFFIX}3"

echo "Setting up LVM on ${LVM_PARTITION}..."
pvcreate -f "${LVM_PARTITION}"
vgcreate "${VG_NAME}" "${LVM_PARTITION}"

lvcreate --type thin-pool -L 100%FREE --name "${THIN_VOL}" "${VG_NAME}"

echo "Creating root logical volume with 80% of available pool space..."
lvcreate --name "${ROOT_LV_NAME}" -V $(lvs --noheadings --units b -o lv_size ${VG_NAME}/${THIN_VOL}) "${THIN_VOL}" "${VG_NAME}"

echo ""
echo "Success! Disk is partitioned and LVM is ready."
echo "------------------------------------------------------------------"
echo "In the Ubuntu installer, choose 'Manual Partitioning' and assign:"
echo ""
echo "   Device:       ${EFI_PARTITION}"
echo "   Mount Point:  /boot/efi"
echo ""
echo "   Device:       ${BOOT_PARTITION}"
echo "   Mount Point:  /boot"
echo ""
echo "   Device:       /dev/mapper/${VG_NAME}-${ROOT_LV_NAME}"
echo "   Mount Point:  /"
echo "------------------------------------------------------------------"
echo "After assigning mount points, select 'Done' to proceed."