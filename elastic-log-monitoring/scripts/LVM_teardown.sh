#!/bin/bash

DATA_VG_NAME=esdata-vg
MOUNT_ROOT=/var/lib/elastic-stack
DISK_IMAGE=/var/lib/elasticsearch-disk.img

read -r -a LV_NAMES <<< "es-master-1-data es-master-2-data es-master-3-data es-hot-data logstash-data kibana-data"

log() {
  echo "$*"
}

# Stop all Elasticsearch LVM mounts
log "Stopping Elasticsearch LVM mounts..."
for lv in "${LV_NAMES[@]}"; do
  mount_point="${MOUNT_ROOT}/${lv}"
  lv_path="/dev/${DATA_VG_NAME}/${lv}"
  if mountpoint -q "${mount_point}"; then
    umount "${mount_point}" || true
  fi
  if [[ -f /etc/fstab ]]; then
    sed -i "\|^${lv_path}[[:space:]]\+${mount_point}[[:space:]]|d" /etc/fstab
  fi
  rm -rf "${mount_point}"
 done

if vgdisplay "${DATA_VG_NAME}" >/dev/null 2>&1; then
  log "Deactivating volume group ${DATA_VG_NAME}..."
  vgchange -an "${DATA_VG_NAME}" >/dev/null 2>&1 || true
fi

if [[ -f "${DISK_IMAGE}" ]]; then
  loopdev=$(losetup -j "${DISK_IMAGE}" | cut -d: -f1 | head -n1)
  if [[ -n "${loopdev}" ]]; then
    log "Detaching loop device ${loopdev}"
    losetup -d "${loopdev}" >/dev/null 2>&1 || true
  fi
fi

log "LVM teardown completed."
