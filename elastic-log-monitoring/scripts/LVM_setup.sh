#!/bin/bash

# Setup physical memory for ES
echo "Setting up volumes for Elasticsearch with lvm..."
DATA_PV_DEVICE=${ESDATA_PV_DEVICE:-/dev/sdb}
DATA_VG_NAME=esdata-vg
MOUNT_ROOT=/var/lib/elastic-stack
DISK_IMAGE=${ESDATA_LOOP_IMAGE:-/var/lib/elasticsearch-disk.img}
LOOP_DISK_SIZE=12G

# If the specified device does not exist use a loopback device
if [ ! -b "${DATA_PV_DEVICE}" ]; then
  echo "Device ${DATA_PV_DEVICE} does not exist or is not a block device."
  sudo mkdir -p "$(dirname "${DISK_IMAGE}")"
  if [ ! -e "${DISK_IMAGE}" ]; then
    echo "Creating a ${LOOP_DISK_SIZE} disk image at ${DISK_IMAGE}..."
    sudo truncate -s "${LOOP_DISK_SIZE}" "${DISK_IMAGE}"
  fi

  # Get the first loop device associated with the image (update: impossible reusing because of loopback detachment during
  # stop phase - implemented in order to avoid zombie device mappers in case of service stopping and disabling + reboot), or create one if none
  #existing_loop=$(sudo losetup -j "${DISK_IMAGE}" | cut -d: -f1 | head -n1)
  #if [ -n "${existing_loop}" ]; then
  #  echo "Reusing existing loop device ${existing_loop} for ${DISK_IMAGE}."
  #  LOOP_DEVICE=${existing_loop}
  #else
    LOOP_DEVICE=$(sudo losetup --find --show "${DISK_IMAGE}")
    if [ -z "${LOOP_DEVICE}" ]; then
      echo "Failed to attach ${DISK_IMAGE} to a loop device." >&2
      exit 1
    fi
    echo "Attached ${DISK_IMAGE} to ${LOOP_DEVICE}."
  #fi
  DATA_PV_DEVICE=${LOOP_DEVICE}
fi

# Update pvscan cache to recognize existing PVs on the device (in particular inside the disk image - maybe the exposed loop device changed but the PVs are still there)
echo "Updating pvscan cache for ${DATA_PV_DEVICE}..."
sudo pvscan --cache "${DATA_PV_DEVICE}" >/dev/null 2>&1 || true

declare -A LV_SPECS=(
  [es-master-1-data]=2G
  [es-master-2-data]=2G
  [es-master-3-data]=2G
  [es-hot-data]=3G
  [logstash-data]=1G
  [kibana-data]=1G
)

if ! sudo vgs --noheadings -o vg_name | grep -qw "${DATA_VG_NAME}"; then
  if ! sudo pvs --noheadings -o pv_name | grep -qw "${DATA_PV_DEVICE}"; then
    echo "Creating physical volume on ${DATA_PV_DEVICE}..."
    sudo pvcreate "${DATA_PV_DEVICE}"
  else
    echo "Physical volume on ${DATA_PV_DEVICE} already exists."
  fi
  echo "Creating volume group '${DATA_VG_NAME}'..."
  sudo vgcreate "${DATA_VG_NAME}" "${DATA_PV_DEVICE}"
else
  echo "Volume group '${DATA_VG_NAME}' already exists."
fi

# Activate the volume group (that is, make its LVs available - again, maybe the loop device changed so the LVs are no more seen as accessible until this command is run)
echo "Activating volume group '${DATA_VG_NAME}'..."
sudo vgchange -ay "${DATA_VG_NAME}" >/dev/null 2>&1 || true

echo "Ensuring logical volumes and mount points exist..."
for lv_name in "${!LV_SPECS[@]}"; do
  lv_size=${LV_SPECS[${lv_name}]}
  lv_path="/dev/${DATA_VG_NAME}/${lv_name}"
  mount_point="${MOUNT_ROOT}/${lv_name}"

  if ! sudo lvs "${DATA_VG_NAME}/${lv_name}" >/dev/null 2>&1; then
    echo "Creating logical volume ${lv_name} (${lv_size})..."
    sudo lvcreate -L "${lv_size}" -n "${lv_name}" "${DATA_VG_NAME}"
  else
    echo "Logical volume ${lv_name} already exists."
  fi

  existing_fs=$(sudo blkid -s TYPE -o value "${lv_path}" 2>/dev/null || true)
  if [[ "${existing_fs}" != "xfs" ]]; then
    echo "Formatting ${lv_path} with XFS filesystem (quota enabled)..."
    sudo mkfs.xfs -f "${lv_path}" >/dev/null
  else
    echo "Logical volume ${lv_name} already has XFS filesystem."
  fi

  sudo mkdir -p "${mount_point}"

  fstab_entry="${lv_path} ${mount_point} xfs defaults,uquota 0 2"
  if ! grep -qsF "${fstab_entry}" /etc/fstab; then
    echo "Registering ${lv_name} in /etc/fstab..."
    echo "${fstab_entry}" | sudo tee -a /etc/fstab >/dev/null
  fi

done

sudo mount -a

echo "Configuring XFS user quotas for stack UID (1000)..."
for lv_name in "${!LV_SPECS[@]}"; do
  lv_size=${LV_SPECS[${lv_name}]}
  mount_point="${MOUNT_ROOT}/${lv_name}"
  if mountpoint -q "${mount_point}"; then
    sudo xfs_quota -x -c "limit -u bsoft=${lv_size} bhard=${lv_size} 1000" "${mount_point}" || echo "Warning: failed to apply quota on ${mount_point}" >&2
  fi
done

sudo chown -R 1000:0 "${MOUNT_ROOT}"
echo "Volume setup completed."