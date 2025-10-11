#!/bin/bash

# This script is intended to reset the Elastic Stack volumes (it deletes all data)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="${SCRIPT_DIR}"
MOUNT_ROOT=/var/lib/elastic-stack
VG_NAME=esdata-vg
DISK_IMAGE=${ESDATA_LOOP_IMAGE:-/var/lib/elasticsearch-disk.img}

read -r -a LV_NAMES <<< "es-master-1-data es-master-2-data es-master-3-data es-hot-data logstash-data kibana-data"

log() {
  printf '\n%s\n' "$*"
}

if command -v docker >/dev/null 2>&1; then
  ( cd "${PROJ_DIR}" && docker compose down --volumes --remove-orphans >/dev/null 2>&1 ) || true
fi

log "Unmounting filesystems and cleaning up /etc/fstab..."
for lv in "${LV_NAMES[@]}"; do
  mount_point="${MOUNT_ROOT}/${lv}"
  if mountpoint -q "${mount_point}"; then
    umount "${mount_point}" || true
  fi
  if [[ -f /etc/fstab ]]; then
    sed -i "\|^/dev/${VG_NAME}/${lv}[[:space:]]\+/var/lib/elastic-stack/${lv}[[:space:]]|d" /etc/fstab
  fi
  rm -rf "${mount_point}"
done

if [[ -d "${MOUNT_ROOT}" ]]; then
  find "${MOUNT_ROOT}" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
  rmdir "${MOUNT_ROOT}" 2>/dev/null || true
fi

log "Removing logical volumes and volume group..."
if vgdisplay "${VG_NAME}" >/dev/null 2>&1; then
  for lv in "${LV_NAMES[@]}"; do
    if lvdisplay "/dev/${VG_NAME}/${lv}" >/dev/null 2>&1; then
      lvremove -f "/dev/${VG_NAME}/${lv}" >/dev/null 2>&1 || true
    fi
  done
  vgremove -f "${VG_NAME}" >/dev/null 2>&1 || true
fi

pv_list=$(pvs --noheadings -o pv_name --select "vg_name=${VG_NAME}" 2>/dev/null | awk 'NF') || true
if [[ -n "${pv_list}" ]]; then
  while IFS= read -r pv; do
    pvremove -ff -y "${pv}" >/dev/null 2>&1 || true
  done <<< "${pv_list}"
fi

log "Removing any loop device and disk image..."
if [[ -f "${DISK_IMAGE}" ]]; then
  loopdev=$(losetup -j "${DISK_IMAGE}" | cut -d: -f1 | head -n1)
  if [[ -n "${loopdev}" ]]; then
    losetup -d "${loopdev}" >/dev/null 2>&1 || true
  fi
  rm -f "${DISK_IMAGE}"
fi

log "Reset completed."
