
list_disks() {
  printf '%-14s %8s  %-9s %s\n' DEVICE SIZE REMOVABLE MODEL

  for dev in /sys/block/*; do
    name=${dev##*/}
    case "$name" in
      loop*|ram*|mtdblock*|zram*|sr*) continue ;;
    esac
    
    # There are 2097152 sector of size 512B in 1Gi
    size=$(awk '{printf "%.1fG", $1 / 2097152}' "/sys/block/$name/size")

    if [ "$(cat "$dev/removable")" = 1 ]; then removable=yes; else removable=no; fi

    model=$(cat "$dev/device/model" 2>/dev/null)
    model=${model:--}

    printf '%-14s %8s  %-9s %s\n' "/dev/$name" "$size" "$removable" "$model" 
  done
}
