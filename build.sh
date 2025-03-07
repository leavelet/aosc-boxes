#!/bin/bash
# Build virtual machine images (cloud image, vagrant boxes)

# nounset: "Treat unset variables and parameters [...] as an error when performing parameter expansion."
# errexit: "Exit immediately if [...] command exits with a non-zero status."
set -o nounset -o errexit
shopt -s extglob
readonly DEFAULT_DISK_SIZE="16G"
readonly IMAGE="image.img"
# shellcheck disable=SC2016
readonly MIRROR='https://repo.aosc.io/debs'
readonly AOSC_ARCH=$(dpkg --print-architecture)

function init() {
  readonly ORIG_PWD="${PWD}"
  readonly OUTPUT="${PWD}/output"
  local tmpdir
  tmpdir="$(mktemp --dry-run --directory --tmpdir="${PWD}/tmp")"
  readonly TMPDIR="${tmpdir}"
  mkdir -p "${OUTPUT}" "${TMPDIR}"
  if [ -n "${SUDO_UID:-}" ] && [[ -n "${SUDO_GID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${OUTPUT}" "${TMPDIR}"
  fi
  cd "${TMPDIR}"

  readonly MOUNT="${PWD}/mount"
  mkdir "${MOUNT}"
}

# Do some cleanup when the script exits
function cleanup() {
  # We want all the commands to run, even if one of them fails.
  set +o errexit
  if [ -n "${LOOPDEV:-}" ]; then
    losetup -d "${LOOPDEV}"
  fi
  if [ -n "${MOUNT:-}" ] && mountpoint -q "${MOUNT}"; then
    # We do not want risking deleting ex: the package cache
    umount --recursive "${MOUNT}" || exit 1
  fi
  if [ -n "${TMPDIR:-}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

# Create the disk, partitions it, format the partition and mount the filesystem
function setup_disk() {
  truncate -s "${DEFAULT_DISK_SIZE}" "${IMAGE}"
  sgdisk --align-end \
    --clear \
    --new 0:0:+1M --typecode=0:ef02 --change-name=0:'BIOS boot partition' \
    --new 0:0:+300M --typecode=0:ef00 --change-name=0:'EFI system partition' \
    --new 0:0:0 --typecode=0:8304 --change-name=0:'AOSC OS root' \
    "${IMAGE}"

  LOOPDEV=$(losetup --find --partscan --show "${IMAGE}")
  # Partscan is racy
  wait_until_settled "${LOOPDEV}"
  mkfs.fat -F 32 -S 4096 "${LOOPDEV}p2"
  mkfs.ext4 "${LOOPDEV}p3"
  mount "${LOOPDEV}p3" "${MOUNT}"
  mount --mkdir "${LOOPDEV}p2" "${MOUNT}/efi"
}

# Install AOSC to the filesystem (bootstrap)
function bootstrap() {
  aoscbootstrap stable "${MOUNT}" --arch=$AOSC_ARCH --config=/usr/share/aoscbootstrap/config/aosc-mainline.toml --include-files="/usr/share/aoscbootstrap/recipes/base.lst" "${MIRROR}" --force
}

# Cleanup the image and trim it
function image_cleanup() {
  sync -f "${MOUNT}/etc/os-release"
  fstrim --verbose "${MOUNT}"
  fstrim --verbose "${MOUNT}/efi"
}

# Helper function: wait until a given loop device has settled
# ${1} - loop device
function wait_until_settled() {
  udevadm settle
  blockdev --flushbufs --rereadpt "${1}"
  until test -e "${1}p3"; do
    echo "${1}p3 doesn't exist yet..."
    sleep 1
  done
}

# Mount image helper (loop device + mount)
function mount_image() {
  LOOPDEV=$(losetup --find --partscan --show "${1:-${IMAGE}}")
  # Partscan is racy
  wait_until_settled "${LOOPDEV}"
  mount "${LOOPDEV}p3" "${MOUNT}"
  mkdir -p "${MOUNT}/efi"
  mount "${LOOPDEV}p2" "${MOUNT}/efi"
  # Setup bind mount to package cache
  mount --bind "/var/cache/apt/archives" "${MOUNT}/var/cache/apt/archives"
}

# Unmount image helper (umount + detach loop device)
function unmount_image() {
  umount --recursive "${MOUNT}"
  losetup -d "${LOOPDEV}"
  LOOPDEV=""
}

# Compute SHA256, adjust owner to $SUDO_UID:$SUDO_UID and move to output/
function mv_to_output() {
  sha256sum "${1}" >"${1}.SHA256"
  if [ -n "${SUDO_UID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${1}"{,.SHA256}
  fi
  mv "${1}"{,.SHA256} "${OUTPUT}/"
}

# Helper function: create a new image from the "base" image
# ${1} - final file
# ${2} - pre
# ${3} - post
function create_image() {
  local tmp_image
  tmp_image="$(basename "$(mktemp -u)")"
  cp -a "${IMAGE}" "${tmp_image}"
  if [ -n "${DISK_SIZE}" ]; then
    truncate -s "${DISK_SIZE}" "${tmp_image}"
    sgdisk --align-end --delete 3 "${tmp_image}"
    sgdisk --align-end --move-second-header \
      --new 0:0:0 --typecode=0:8304 --change-name=0:'AOSC OS root' \
      "${tmp_image}"
  fi
  mount_image "${tmp_image}"

  if [ 0 -lt "${#PACKAGES[@]}" ]; then
    arch-chroot "${MOUNT}" /usr/bin/oma install --no-check-dbus -y "${PACKAGES[@]}"
  fi
  if [ 0 -lt "${#SERVICES[@]}" ]; then
    for service in "${SERVICES[@]}"; do
      echo "enable ${service}" >>"${MOUNT}/usr/lib/systemd/system-preset/80-aosc-image.preset"
    done
  fi
  "${2}"
  image_cleanup
  unmount_image
  "${3}" "${tmp_image}" "${1}"
  mv_to_output "${1}"
}

# ${1} - Optional build version. If not set, will generate a default based on date.
function main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "root is required"
    exit 1
  fi
  init

  local build_version
  if [ -z "${1:-}" ]; then
    build_version="$(date +%Y%m%d)"
    echo "WARNING: BUILD_VERSION wasn't set!"
    echo "Falling back to $build_version"
  else
    build_version="${1}"
  fi

  setup_disk
  bootstrap
  # shellcheck source=images/base.sh
  source "${ORIG_PWD}/images/base.sh"
  pre
  unmount_image

  for image in "${ORIG_PWD}/images/"!(base).sh; do
    # shellcheck source=/dev/null
    source "${image}"
    create_image "${IMAGE_NAME}" pre post
  done
}
main "$@"
