#!/bin/sh
set -e
trim_all() {
    # Usage: trim_all "   example   string    "

    # Disable globbing to make the word-splitting below safe.
    set -f

    # Set the argument list to the word-splitted string.
    # This removes all leading/trailing white-space and reduces
    # all instances of multiple spaces to a single ("  " -> " ").
    # shellcheck disable=SC2086,SC2048
    set -- $*

    # Print the argument list as a string.
    printf '%s\n' "$*"

    # Re-enable globbing.
    set +f
}
codename="$1"; version="$2"

# first figure out what disk is /
while read -r line || [ "$line" ]; do
  case "$line" in
    *'/mnt/stateful_partition '*)
      disk="$line"; disk="${disk%% /mnt/stateful_partition ext4*}"
      # above is disk followed by a partition number
      while {
        case "$disk" in
          *[0-9][0-9]|*[0-9]) true ;;
          *) false ;;
        esac
      }; do
        disk="${disk%?}"
      done
      # remove partition number; supports up to 2 numbers
    ;;
  esac
done < /proc/mounts
disk="${disk%p}"
[ -e "$disk" -o -e "${disk%p}p1" ] || {
  printf 'Failed to detect disk; Was %s...\n' "$disk"
  exit 1
}
unset line; printf '%s\n' "Active disk is $disk"

[ "$(type cgpt)" ] || {
  printf 'Unable to find cgpt...\n'
  exit 1
}
# next confirm which rootfs is active
# this is done by parsing cgpt show $disk
# to grab the kernel, dumping it and reading its config
while IFS= read -r line || [ "$line" ]; do
  line="$(trim_all "$line")"
  case "$line" in
    *[0-9][0-9]" Label"*|*[0-9]" Label"*)
      unset kernel attr rootfs partnum tries priority successful label
      partnum="${line#* * }"; partnum="${partnum%% Label*}"
      label="${line##*Label: \"}"; label="${label%\"}"
    ;;
    # matches line containing disk number and its label
    # only the disk number is really needed here
    ##
    # should also be used to detect when a new item has began
    *"Type: ChromeOS kernel"*) kernel=true; kernel_partnum="$partnum";;
    # if matches then current item is kernel
    *"Type: ChromeOS rootfs"*) rootfs=true; rootfs_partnum="$partnum";;
    # if matches then current item is rootfs
    *"Attr:"*)
      kernel_label="$label"
      # shellcheck disable=SC2086
      attr="${line##*Attr: }"; IFS=" "; set -- $attr
      while [ "$1" ]; do
        eval "$1"
        shift 1
      done
      # shellcheck disable=SC2154
      [ "$successful" = 1 ] && {
        active_kernel_label="$label"
        active_kernel_partnum="$partnum"
        active_kernel_priority="$priority"
      } || {
        [ "$inactive_kernel_label" ] || inactive_kernel_label="$label"
        [ "$inactive_kernel_partnum" ] || inactive_kernel_partnum="$partnum"
        # kern_c is given 15 tries, but kern_c is not an actual kernel
      }
    ;;
    # if matches then current item has an attribute
  esac
done << EOF
$(cgpt show "$disk")
EOF
printf '%s\n' "Current Kernel is $active_kernel_label on $disk at part number $active_kernel_partnum"
printf '%s\n' "Opposing Kernel is $inactive_kernel_label with part number $inactive_kernel_partnum"
case "$disk" in
  *"mmcblk"*) disk="${disk}p"
esac
kernel="${disk}${active_kernel_partnum}"
inactive_kernel="${disk}${inactive_kernel_partnum}"
[ "$USER" = "root" ] || {
  printf '%s\n' "root needed..."
  exit 1
}
printf '%s\n' "Dumping kernels..."
cd /usr/local || {
  printf '%s\n' "/usr/local missing..."
  exit 1
}
[ "$(type vbutil_kernel)" ] ||{
  printf '%s\n' "Missing vbuilt_kernel... Unable to proceed..."
  exit 1
}
[ -b "$kernel" ] && dd status=none < "$kernel" > "$active_kernel_label".blob
[ -b "$inactive_kernel" ] && dd status=none < "$inactive_kernel" > "$inactive_kernel_label".blob
local_kernel="${PWD}/${active_kernel_label}.blob"
local_inactive_kernel="${PWD}/${inactive_kernel_label}.blob"
# dump config with vbutil_kernel --verify
unset prev_line
while read -r line || [ "$line" ]; do
  case "$prev_line" in
    *"Config:"*)
      if [ "${line}" != "${line##*PARTNROFF=}" ]; then
        line="${line##*PARTNROFF=}"; line="${line%% *}"
        # line should now only contain an offset number
        rootfs_partnum=$((inactive_kernel_partnum+line))
        printf '%s\n' "Inactive rootfs is at ${disk}${rootfs_partnum}"
        inactive_rootfs_part="${disk}${rootfs_partnum}"
        break
      else
        printf 'Could not determine rootfs partition...\n'
        exit 1
      fi
    ;;
  esac
  prev_line="$line"
done << EOF
$(vbutil_kernel --verify "$local_inactive_kernel")
EOF
unset prev_line
while read -r line || [ "$line" ]; do
  case "$prev_line" in
    *"Config:"*)
      #printf '%s\n' "$line"
      if [ "${line}" != "${line##*PARTNROFF=}" ]; then
        line="${line##*PARTNROFF=}"; line="${line%% *}"
        # line should now only contain an offset number
        rootfs_partnum=$((active_kernel_partnum+line))
        printf '%s\n' "Active rootfs is at ${disk}${rootfs_partnum}"
        active_rootfs_part="${disk}${rootfs_partnum}"
        break
      else
        printf 'Could not determine rootfs partition...\n'
        exit 1
      fi
    ;;
  esac
  prev_line="$line"
done << EOF
$(vbutil_kernel --verify "$local_kernel")
EOF
# check if rootfs's match somehow
# if not copy current to inactive
# then download alpine rootfs, release image
# chroot and unzip
if [ ! "$(type unzip 2>/dev/null)" ]; then
  [ "$(type curl)" ] || {
    printf 'Curl is missing...\n'
    exit 1
  }
  [ "$(type uname)" ] || {
    printf 'uname is missing...\n'
    exit 1
  }
  arch="$(uname -m)"
  arch="${arch%l}"
  unset line item
  while read -r line || [ "$line" ]; do
    line="$(trim_all "$line")"
    case "$line" in
      'title: "Mini root filesystem"') item="rootfs" ;;
      'title: '*) unset item ;;
      'file:'*) [ "$item" = "rootfs" ] && {
          file="${line##*file: }"
          break
        }
      ;;
    esac
  done << EOF
$(curl -skL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/latest-releases.yaml")
EOF
  printf '%s\n' "Downloading alpine latest release mini rootfs for $arch @ $file"
  curl -kLO "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch/$file"
  [ -f "./$file" ] || {
    printf '%s\n' "$file did not download correctly..."
    exit 1
  }
  printf 'Downloaded %s for chroot\n' "$file"
  mkdir -p /usr/local/chroot; [ -d "/usr/local/chroot" ] || {
    printf 'Failed to mkdir ./chroot ...\n'
    exit 1
  }
  [ "$(type tar)" ] || {
    printf 'tar is missing...\n'
    exit
  }
  tar -C /usr/local/chroot -xf $file
  cd /usr/local/chroot || {
    printf 'Failed to change path to /usr/local/chroot...\n'
    exit 1
  }
else
  unzip=true
fi
while read -r line || [ "$line" ]; do
  case "$line" in
    *"data-chrome="*)
      line="${line##*data-chrome="$version"}"; line="${line%%.zip*}"
      line="${line##*href=}"; recovery_link="$line.zip"
      recovery_file="${recovery_link#*recovery/}"
      printf 'Found recovery image for %s with chrome version %s at %s\n' "$codename" "$version" "$recovery_link"
      break
      ;;
  esac
done << EOF
$(curl -skL "https://chrome100.dev/board/$codename")
EOF
printf 'Downloading recovery image...\n'
if [ ! -f "$recovery_file" ]; then
  curl -kLO --progress-bar "$recovery_link"
fi
if [ -f "${recovery_file%.zip}" ]; then
  [ "$(type rm)" ] && rm -f "${recovery_file%.zip}"
fi
[ "$unzip" ] && unzip="unzip $recovery_file"
[ "$unzip" ] || chroot /usr/local/chroot ./bin/sh -c "unzip $recovery_file"
[ -f "${recovery_file%.zip}" ] || {
  ${unzip}
}
[ -f "${recovery_file%.zip}" ] || {
  printf 'Failed to unzip %s...\n' "${recovery_file}"
  exit 1
}

printf 'Overwriting inactive rootfs with active one... This will take a while...\n'
printf 'Proceed? [y/n]: '
read -r answer
printf '%s\n' "$answer"
[ "$answer" != "y" ] && exit 1
dd status=progress < "$active_rootfs_part" > "$inactive_rootfs_part"
printf '\nContinuing...\n'

printf 'Beginning conversion on %s... This will take a while...\n' "$inactive_rootfs_part"
mkdir -p /usr/local/inactive-local-rootfs/opt/google/touch
inactive_local_rootfs="/usr/local/inactive-local-rootfs"
mkdir -p /usr/local/chromeos-image-rootfs
chromeos_image_rootfs="/usr/local/chromeos-image-rootfs"
mount -o rw  "${inactive_rootfs_part}" "$inactive_local_rootfs"
restore_rootfs() {
  umount "$inactive_local_rootfs" || exit 1
  umount "$chromeos_image_rootfs" || exit 1
  dd status=progress < "$active_rootfs_part" > "$inactive_rootfs_part"
}
bail() {
  umount "$inactive_local_rootfs"
  umount "$chromeos_image_rootfs"
  [ "$rootfs_edited" ] && {
    printf 'Restoring %s due to error...\n' "$inactive_rootfs_part"
    restore_rootfs
  }
  [ -b "$loop_device" ] && losetup -d "$loop_device"
  exit 1
}
printf '%s\n' "Mounted $inactive_rootfs_part at $inactive_local_rootfs..."
[ "$(type losetup)" ] || {
  printf 'losetup is missing... Confirm you are logged in as root...\n'
  bail
}
loop_device="$(losetup --show -fP "${recovery_file%.zip}")"
printf 'Mounted %s on %s...\n' "$recovery_file" "$loop_device"
mount -o ro,loop "${loop_device}p3" "$chromeos_image_rootfs" || {
  printf 'Failed to mount %s... There was likely an issue with the loop device initialization... Please Try Again...\n' "${loop_device}p3"
  bail
}

printf 'Copy of ChromeOS recovery image will being now...
Any text on this console will likely be lost as cp(1) will fill the screen with copy operations...
Do you wish to continue? [y/n]: '
read -r answer
[ "$answer" != "y" ] && bail
printf '\nContinuing...\n'

[ "$(type cp)" ] || {
  printf 'cp is missing...\n'
  bail
}
cd $chromeos_image_rootfs || {
  printf 'Failed to change path to %s\n' "$chromeos_image_rootfs"
  exit 1
}
cp -arvf ./ "$inactive_local_rootfs"/ || bail
printf 'Restoring /opt/google/touch...\n'
cp -arvf "/opt/google/touch/*" "$inactive_local_rootfs/opt/google/touch/" || bail
printf 'Restoring /lib...\n'
cp -arvf "/lib/*" "$inactive_local_rootfs/lib" || bail
printf 'Finished Copy...\n'
cd /usr/local || bail
umount "$inactive_local_rootfs" || :
umount "$chromeos_image_rootfs" || :
cgpt add -i "${inactive_kernel_partnum}" -T 2 -S 0 -P $((active_kernel_priority+1)) "${disk%%p*}"
printf 'Modified Kernel Attempts... \n'
printf 'Reboot to test the modified rootfs...
If boot is successful run:
cgpt add -i %s -S1 %s\n' "${inactive_kernel_partnum}" "${disk%%p*}"
exit 0