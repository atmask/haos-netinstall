#!/bin/busybox sh

for dev in /sys/block/*; do
  name=${dev##*/}
  case "$name" in
    loop*|ram*|mtdblock*|zram*|sr*) continue ;;
  esac
  sectors=$(cat "/sys/block/$name/size")
  
  # There are 2097152 sector of size 512B in 1Gi
  size=$(awk '{printf "%.1f", $1 / 2097152}' "/sys/block/$name/size")

  echo "$name: ${size}Gi"



