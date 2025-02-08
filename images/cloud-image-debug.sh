#!/bin/bash
# shellcheck disable=SC2034,SC2154
IMAGE_NAME="AOSC-OS-x86_64-cloudimg-debug-${build_version}.qcow2"
DISK_SIZE="16G"
PACKAGES=(cloud-utils)

function pre() {
  local NEWUSER="aosc"
  arch-chroot "${MOUNT}" /usr/bin/useradd -m -U "${NEWUSER}"
  echo -e "${NEWUSER}\n${NEWUSER}" | arch-chroot "${MOUNT}" /usr/bin/passwd "${NEWUSER}"
  echo "${NEWUSER} ALL=(ALL) NOPASSWD: ALL" >"${MOUNT}/etc/sudoers.d/${NEWUSER}"
  sed -Ei 's/^(GRUB_CMDLINE_LINUX_DEFAULT=.*)"$/\1 console=tty0 console=ttyS0,115200"/' "${MOUNT}/etc/default/grub"
  echo 'GRUB_TERMINAL="serial console"' >>"${MOUNT}/etc/default/grub"
  echo 'GRUB_SERIAL_COMMAND="serial --speed=115200"' >>"${MOUNT}/etc/default/grub"
  arch-chroot "${MOUNT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
  # cloud-init topic
  export cloud_init_topic=$(curl https://repo.aosc.io/debs/manifest/topics.json | jq '.[] | select(.name | test("^cloud-init.*"))' | jq -r -s 'max_by(.name) | .name')
  if [ -n "${cloud-init-topic}" ]; then
    arch-chroot "${MOUNT}" /usr/bin/oma topics --no-check-dbus --opt-in "${cloud_init_topic}"
  fi
  arch-chroot "${MOUNT}" /usr/bin/oma install -y --no-check-dbus cloud-init
  systemctl --root="${MOUNT}" enable cloud-init-main cloud-init-local cloud-init-network cloud-config cloud-final
}

function post() {
  qemu-img convert -c -f raw -O qcow2 "${1}" "${2}"
  rm "${1}"
}
