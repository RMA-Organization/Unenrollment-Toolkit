#!/bin/bash
# fakemurk.sh v1
# by coolelectronics with help from r58
# sets up all required scripts for spoofing os verification in devmode
# this script bundles crossystem.sh and vpd.sh

# crossystem.sh v3.0.0
# made by r58Playz and stackoverflow
# emulates crossystem but with static values to trick chromeos and google
# version history:
# v3.0.0 - implemented mutable crossystem values
# v2.0.0 - implemented all functionality
# v1.1.1 - hotfix for stupid crossystem
# v1.1.0 - implemented <var>?<value> functionality (searches for value in var)
# v1.0.0 - basic functionality implemented

# image_patcher.sh
# written based on the original by coolelectronics and r58, modified heavily for murkmod

CURRENT_MAJOR=6
CURRENT_MINOR=0
CURRENT_VERSION=0

# God damn, there are a lot of unused functions in here!
# future rainestorme: finally cleaned it up! :D

ascii_info() {
    echo -e " 
      888     888 88888888888 888    d8P  
      888     888     888     888   d8P   
      888     888     888     888  d8P    
      888     888     888     888d88K     
      888     888     888     8888888b    
      888     888     888     888  Y88b   
      Y88b. .d88P     888     888   Y88b  
       'Y88888P'      888     888    Y88b "
    echo "        The UTK plugin manager - v$CURRENT_MAJOR.$CURRENT_MINOR.$CURRENT_VERSION"

    # spaces get mangled by makefile, so this must be separate
}
nullify_bin() {
    cat <<-EOF >$1
#!/bin/bash
exit
EOF
    chmod 777 $1
    # shebangs crash makefile
}

. /usr/share/misc/chromeos-common.sh || :

traps() {
    set -e
    trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
    trap 'echo "\"${last_command}\" command failed with exit code $?. THIS IS A BUG, REPORT IT HERE https://github.com/MercuryWorkshop/fakemurk"' EXIT
}

leave() {
    trap - EXIT
    echo "exiting successfully"
    exit
}


sed_escape() {
    echo -n "$1" | while read -n1 ch; do
        if [[ "$ch" == "" ]]; then
            echo -n "\n"
            # dumbass shellcheck not expanding is the entire point
        fi
        echo -n "\\x$(printf %x \'"$ch")"
    done
}

move_bin() {
    if test -f "$1"; then
        mv "$1" "$1.old"
    fi
}

disable_autoupdates() {
    # thanks phene i guess?
    # this is an intentionally broken url so it 404s, but doesn't trip up network logging
    sed -i "$ROOT/etc/lsb-release" -e "s/CHROMEOS_AUSERVER=.*/CHROMEOS_AUSERVER=$(sed_escape "https://updates.gooole.com/update")/"

    # we don't want to take ANY chances
    move_bin "$ROOT/usr/sbin/chromeos-firmwareupdate"
    nullify_bin "$ROOT/usr/sbin/chromeos-firmwareupdate"

    # bye bye trollers! (trollers being cros devs)
    rm -rf "$ROOT/opt/google/cr50/firmware/" || :
}

SCRIPT_DIR=$(dirname "$0")
configure_binaries(){
  if [ -f /sbin/ssd_util.sh ]; then
    SSD_UTIL=/sbin/ssd_util.sh
  elif [ -f /usr/share/vboot/bin/ssd_util.sh ]; then
    SSD_UTIL=/usr/share/vboot/bin/ssd_util.sh
  elif [ -f "${SCRIPT_DIR}/lib/ssd_util.sh" ]; then
    SSD_UTIL="${SCRIPT_DIR}/lib/ssd_util.sh"
  else
    echo "ERROR: Cannot find the required ssd_util script. Please make sure you're executing this script inside the directory it resides in"
    exit 1
  fi
}

patch_root() { #We don't need this   
    echo "Done."
}

# https://chromium.googlesource.com/chromiumos/docs/+/main/lsb-release.md
lsbval() {
  local key="$1"
  local lsbfile="${2:-/etc/lsb-release}"

  if ! echo "${key}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
    return 1
  fi

  sed -E -n -e \
    "/^[[:space:]]*${key}[[:space:]]*=/{
      s:^[^=]+=[[:space:]]*::
      s:[[:space:]]+$::
      p
    }" "${lsbfile}"
}

get_asset() {
    curl -s -f "https://api.github.com/repos/RMA-Organization/Unenrollment-Toolkit/contents/$1" | jq -r ".content" | base64 -d
}

install() {
    TMP=$(mktemp)
    get_asset "$1" >"$TMP"
    if [ "$?" == "1" ] || ! grep -q '[^[:space:]]' "$TMP"; then
        echo "Failed to install $1 to $2"
        rm -f "$TMP"
        exit
    fi
    # Don't mv, that would break permissions
    cat "$TMP" >"$2"
    rm -f "$TMP"
}

main() {
  traps
  ascii_info
  configure_binaries
  echo $SSD_UTIL

  if [ -z $1 ] || [ ! -f $1 ]; then
    echo "\"$1\" isn't a real file, dipshit! You need to pass the path to the recovery image. Optional args: <path to custom bootsplash: path to a png> <unfuck stateful: int 0 or 1>"
    exit
  fi
  local bootsplash="0"
  

  local bin=$1
  
  echo "Creating loop device..."
  local loop=$(losetup -f)
  losetup -P "$loop" "$bin"

  echo "Disabling kernel verity..."
  $SSD_UTIL --debug --remove_rootfs_verification -i ${loop} --partitions 4
  echo "Enabling RW mount..."
  $SSD_UTIL --debug --remove_rootfs_verification --no_resign_kernel -i ${loop} --partitions 2

  # for good measure
  sync
  
  echo "Mounting target..."
  mkdir /tmp/mnt || :
  mount "${loop}p3" /tmp/mnt

  ROOT=/tmp/mnt
  patch_root

  

 

  sleep 2
  sync
  echo "Done. Have fun."

  umount "$ROOT"
  sync
  losetup -D "$loop"
  sync
  sleep 2
  rm -rf /tmp/mnt
  leave
}

if [ "$0" = "$BASH_SOURCE" ]; then
    stty sane
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root"
        exit
    fi
    main "$@"
fi