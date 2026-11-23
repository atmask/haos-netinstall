
# Print the names (e.g. nvme0n1) of disks that are candidates for installing to.
candidate_disks() {
  for dev in /sys/block/*; do
    name=${dev##*/}
    case "$name" in
      # mmcblk0boot0/1 and mmcblk0rpmb are small hidden areas of an eMMC chip, not separate disks
      loop*|ram*|mtdblock*|zram*|sr*|mmcblk*boot*|mmcblk*rpmb) continue ;;
    esac
    echo "$name"
  done
}

list_disks() {
  printf '%-14s %8s  %-9s %s\n' DEVICE SIZE REMOVABLE MODEL

  for name in $(candidate_disks); do
    dev=/sys/block/$name

    # There are 2097152 sector of size 512B in 1Gi
    size=$(awk '{printf "%.1fG", $1 / 2097152}' "$dev/size")

    if [ "$(cat "$dev/removable")" = 1 ]; then removable=yes; else removable=no; fi

    model=$(cat "$dev/device/model" 2>/dev/null)
    model=${model:--}

    printf '%-14s %8s  %-9s %s\n' "/dev/$name" "$size" "$removable" "$model"
  done
}

# Succeed if the disk (e.g. nvme0n1) has a Home Assistant OS boot partition.
disk_has_haos() {
  grep -qs '^PARTNAME=hassos-boot$' /sys/block/"$1"/"$1"*/uevent
}
