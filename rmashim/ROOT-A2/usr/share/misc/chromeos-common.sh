#!/bin/sh
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This contains common constants and functions for installer scripts. This must
# evaluate properly for both /bin/bash and /bin/sh, since it's used both to
# create the initial image at compile time and to install or upgrade a running
# image.

# The GPT tables describe things in terms of 512-byte sectors, but some
# filesystems prefer 4096-byte blocks. These functions help with alignment
# issues.

# Call sudo when not root already. Otherwise, add usual path before calling a
# command, as sudo does.
# This way we avoid using sudo when running on a device in verified mode.
maybe_sudo() {
   if [ "${UID:-$(id -u)}" = "0" ]; then
     PATH="${PATH}:/sbin:/usr/sbin" "$@"
   else
     sudo "$@"
   fi
}

# This returns the size of a file or device in physical sectors, rounded up if
# needed.
# Invoke as: subshell
# Args: FILENAME
# Return: whole number of sectors needed to fully contain FILENAME
numsectors() {
  local block_size
  local sectors
  local path="$1"

  if [ -b "${path}" ]; then
    local dev="${path##*/}"
    block_size="$(blocksize "${path}")"

    if [ -e "/sys/block/${dev}/size" ]; then
      sectors="$(cat "/sys/block/${dev}/size")"
    else
      part="${path##*/}"
      block="$(get_block_dev_from_partition_dev "${path}")"
      block="${block##*/}"
      sectors="$(cat "/sys/block/${block}/${part}/size")"
    fi
  else
    local bytes="$(stat -c%s "${path}")"
    local rem=$(( bytes % 512 ))
    block_size=512
    sectors=$(( bytes / 512 ))
    if [ "${rem}" -ne 0 ]; then
      sectors=$(( sectors + 1 ))
    fi
  fi

  echo $(( sectors * 512 / block_size ))
}

# This returns the block size of a file or device in byte
# Invoke as: subshell
# Args: FILENAME
# Return: block size in bytes
blocksize() {
  local path="$1"
  if [ -b "${path}" ]; then
    local dev="${path##*/}"
    local sys="/sys/block/${dev}/queue/logical_block_size"
    if [ -e "${sys}" ]; then
      cat "${sys}"
    else
      local part="${path##*/}"
      local block="$(get_block_dev_from_partition_dev "${path}")"
      local block="${block##*/}"
      cat "/sys/block/${block}/${part}/queue/logical_block_size"
    fi
  else
    echo 512
  fi
}

# Locate the cgpt tool. It should already be installed in the build chroot,
# but some of these functions may be invoked outside the chroot (by
# image_to_usb or similar), so we need to find it.
GPT=""

locate_gpt() {
  if [ -z "$GPT" ]; then
    if [ -x "${DEFAULT_CHROOT_DIR:-}/usr/bin/cgpt" ]; then
      GPT="${DEFAULT_CHROOT_DIR:-}/usr/bin/cgpt"
    else
      GPT=$(which cgpt 2>/dev/null) || /bin/true
      if [ -z "$GPT" ]; then
        echo "can't find cgpt tool" 1>&2
        exit 1
      fi
    fi
  fi
}

# Read GPT table to find the starting location of a specific partition.
# Invoke as: subshell
# Args: DEVICE PARTNUM
# Returns: offset (in sectors) of partition PARTNUM
partoffset() {
  maybe_sudo $GPT show -b -i $2 $1
}

# Read GPT table to find the size of a specific partition.
# Invoke as: subshell
# Args: DEVICE PARTNUM
# Returns: size (in sectors) of partition PARTNUM
partsize() {
  maybe_sudo $GPT show -s -i $2 $1
}

# Extract the whole disk block device from the partition device.
# This works for /dev/sda3 (-> /dev/sda) as well as /dev/mmcblk0p2
# (-> /dev/mmcblk0).
get_block_dev_from_partition_dev() {
  local partition=$1
  if ! (expr match "$partition" ".*[0-9]$" >/dev/null) ; then
    echo "Invalid partition name: $partition" >&2
    exit 1
  fi
  # Removes any trailing digits.
  local block=$(echo "$partition" | sed -e 's/[0-9]*$//')
  # If needed, strip the trailing 'p'.
  if (expr match "$block" ".*[0-9]p$" >/dev/null); then
    echo "${block%p}"
  else
    echo "$block"
  fi
}

# Extract the partition number from the partition device.
# This works for /dev/sda3 (-> 3) as well as /dev/mmcblk0p2 (-> 2).
get_partition_number() {
  local partition=$1
  if ! (expr match "$partition" ".*[0-9]$" >/dev/null) ; then
    echo "Invalid partition name: $partition" >&2
    exit 1
  fi
  # Extract the last digit.
  echo "$partition" | sed -e 's/^.*\([0-9]\)$/\1/'
}

# Construct a partition device name from a whole disk block device and a
# partition number.
# This works for [/dev/sda, 3] (-> /dev/sda3) as well as [/dev/mmcblk0, 2]
# (-> /dev/mmcblk0p2).
make_partition_dev() {
  local block=$1
  local num=$2
  # If the disk block device ends with a number, we add a 'p' before the
  # partition number.
  if (expr match "$block" ".*[0-9]$" >/dev/null) ; then
    echo "${block}p${num}"
  else
    echo "${block}${num}"
  fi
}

# Return the type of device.
#
# The type can be:
# MMC, SD for device managed by the MMC stack
# ATA for ATA disk
# NVME for NVMe device
# OTHER for other devices.
get_device_type() {
  local dev="$(basename "$1")"
  local vdr
  local type_file
  local vendor_file
  # True device path of a NVMe device is just a simple PCI device.
  # (there are no other buses),
  # Use the device name to identify the type precisely.
  case "${dev}" in
    nvme*)
      echo "NVME"
      return
      ;;
  esac

  type_file="/sys/block/${dev}/device/type"
  # To detect device managed by the MMC stack
  case $(readlink -f "${type_file}") in
    *mmc*)
      cat "${type_file}"
      ;;
    *usb*)
      # Now if it contains 'usb', it is managed through
      # a USB controller.
      echo "USB"
      ;;
    *ufs*)
        # Check if it is a UFS device.
        echo "UFS"
        ;;
    *target*)
      # Other SCSI devices.
      # Check if it is an ATA device.
      vdr="$(cat "/sys/block/${dev}/device/vendor")"
      if [ "${vdr%% *}" = "ATA" ]; then
        echo "ATA"
      else
        echo "OTHER"
      fi
      ;;
    *)
      echo "OTHER"
  esac
}

# ATA disk have ATA as vendor.
# They may not contain ata in their device path if behind a SAS
# controller.
# Exclude disks with size 0, it means they did not spin up properly.
list_fixed_ata_disks() {
  local sd
  local remo
  local vdr
  local size

  for sd in /sys/block/sd*; do
    if [ ! -r "${sd}/size" ]; then
      continue
    fi
    size=$(cat "${sd}/size")
    remo=$(cat "${sd}/removable")
    vdr=$(cat "${sd}/device/vendor")
    if [ "${vdr%% *}" = "ATA" -a ${remo:-0} -eq 0 -a ${size:-0} -gt 0 ]; then
      echo "${sd##*/}"
    fi
  done
}

# We assume we only have eMMC devices, not removable MMC devices.
# also, do not consider special hardware partitions on the eMMC, like boot.
# These devices are built on top of the eMMC sysfs path:
# /sys/block/mmcblk0 -> .../mmc_host/.../mmc0:0001/.../mmcblk0
# /sys/block/mmcblk0boot0 -> .../mmc_host/.../mmc0:0001/.../mmcblk0/mmcblk0boot0
# /sys/block/mmcblk0boot1 -> .../mmc_host/.../mmc0:0001/.../mmcblk0/mmcblk0boot1
# /sys/block/mmcblk0rpmb -> .../mmc_host/.../mmc0:0001/.../mmcblk0/mmcblk0rpmb
#
# Their device link points back to mmcblk0, not to the hardware
# device (mmc0:0001). Therefore there is no type in their device link.
# (it should be /device/device/type)
list_fixed_mmc_disks() {
  local mmc
  local type_file
  for mmc in /sys/block/mmcblk*; do
    type_file="${mmc}/device/type"
    if [ -r "${type_file}" ]; then
      if [ "$(cat "${type_file}")" = "MMC" ]; then
        echo "${mmc##*/}"
      fi
    fi
  done
}

# NVMe device
# Exclude disks with size 0, it means they did not spin up properly.
list_fixed_nvme_disks() {
  local nvme remo size nvme_base
  local all_nvme=''

  for nvme in /sys/block/nvme*; do
    if [ ! -r "${nvme}/size" ]; then
      continue
    fi
    size=$(cat "${nvme}/size")
    remo=$(cat "${nvme}/removable")
    if [ ${remo:-0} -eq 0 -a ${size:-0} -gt 0 ]; then
       nvme_base="${nvme##*/}"
       # Store in all_nvme names of nvme devices, without namespace.
       # In case of nvme device with several namespaces, we will have
       # redundancy.
       all_nvme="${all_nvme} ${nvme_base%n*}"
    fi
  done
  echo "${all_nvme}" | tr '[:space:]' '\n' | sort -u
}

# UFS device
# Exclude disks with size 0, it means they did not spin up properly.
list_fixed_ufs_disks() {
  local sd
  local remo
  local size
  local type

  for sd in /sys/block/sd*; do
    if [ ! -r "${sd}/size" ]; then
      continue
    fi
    type=$(get_device_type "${sd}")
    size=$(cat "${sd}/size")
    remo=$(cat "${sd}/removable")
    if [ "${type}" = "UFS" -a ${remo:-0} -eq 0 -a ${size:-0} -gt 0 ]; then
      echo "${sd##*/}"
    fi
  done
}

# Find the drive to install based on the build write_cgpt.sh
# script. If not found, return ""
get_fixed_dst_drive() {
  local dev rootdev

  if [ -n "${DEFAULT_ROOTDEV}" ]; then
    # No " here, the variable may contain wildcards.
    for rootdev in ${DEFAULT_ROOTDEV}; do
      dev="/dev/$(basename "${rootdev}")"
      if [ -b "${dev}" ]; then
        break
      else
        dev=""
      fi
    done
  else
    dev=""
  fi
  echo "${dev}"
}

edit_mbr() {
  locate_gpt
  # TODO(icoolidge): Get this from disk_layout somehow.
  local PARTITION_NUM_EFI_SYSTEM=12
  local start_esp=$(partoffset "$1" ${PARTITION_NUM_EFI_SYSTEM})
  local num_esp_sectors=$(partsize "$1" ${PARTITION_NUM_EFI_SYSTEM})
  maybe_sudo sfdisk -w never -X dos "${1}" <<EOF
unit: sectors

disk1 : start=   $start_esp, size=    $num_esp_sectors, Id= c, bootable
disk2 : start=   1, size=    1, Id= ee
EOF
}

install_hybrid_mbr() {
  # Creates a hybrid MBR which points the MBR partition 1 to GPT
  # partition 12 (ESP). This is useful on ARM boards that boot
  # from MBR formatted disks only.
  #
  # Currently, this code path is used principally to install to
  # SD cards using chromeos-install run from inside the chroot.
  # In that environment, `sfdisk` can be racing with udev, leading
  # to EBUSY when it calls BLKRRPART for the target disk.  We avoid
  # the conflict by using `udevadm settle`, so that udev goes first.
  # cf. crbug.com/343681.

  echo "Creating hybrid MBR"
  if ! edit_mbr "${1}"; then
    udevadm settle
    maybe_sudo blockdev --rereadpt "${1}"
  fi
}

ext4_dir_encryption_supported() {
  # Can be set in the ebuild.
  local direncryption_enabled=true

  # Return true if kernel support ext4 directory encryption.
  ${direncryption_enabled} && \
  ! LC_LANG=C e4crypt get_policy / | grep -qF \
    -e "Operation not supported" \
    -e "Inappropriate ioctl for device"
}
