#!/bin/bash
# build-in qemu.sh runs build.sh in a qemu VM running the latest Arch installer iso
#
# nounset: "Treat unset variables and parameters [...] as an error when performing parameter expansion."
# errexit: "Exit immediately if [...] command exits with a non-zero status."
set -o nounset -o errexit
MIRROR="https://mirror.pkgbuild.com"

ORIG_PWD="${PWD}"
OUTPUT="${PWD}/output"
mkdir -p "tmp" "${OUTPUT}"
TMPDIR="$(mktemp --directory --tmpdir="${PWD}/tmp")"
cd "${TMPDIR}"

# Do some cleanup when the script exits
function cleanup() {
  rm -rf "${TMPDIR}"
  jobs -p | xargs --no-run-if-empty kill
}
trap cleanup EXIT

# Use local Arch iso or download the latest iso and extract the relevant files
function prepare_boot() {
  if LOCAL_ISO="$(ls "${ORIG_PWD}/"archlinux-*-x86_64.iso 2>/dev/null)"; then
    echo "Using local iso: ${LOCAL_ISO}"
    ISO="${LOCAL_ISO}"
  fi

  if [ -z "${LOCAL_ISO}" ]; then
    LATEST_ISO="$(curl -fs "${MIRROR}/iso/latest/" | grep -Eo 'archlinux-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-x86_64.iso' | head -n 1)"
    if [ -z "${LATEST_ISO}" ]; then
      echo "Error: Couldn't find latest iso'"
      exit 1
    fi
    curl -fO "${MIRROR}/iso/latest/${LATEST_ISO}"
    ISO="${PWD}/${LATEST_ISO}"
  fi

  # We need to extract the kernel and initrd so we can set a custom cmdline:
  # console=ttyS0, so the kernel and systemd sends output to the serial.
  xorriso -osirrox on -indev "${ISO}" -extract arch/boot/x86_64 .
  ISO_VOLUME_ID="$(xorriso -indev "${ISO}" |& awk -F : '$1 ~ "Volume id" {print $2}' | tr -d "' ")"
}

function start_qemu() {
  # Used to communicate with qemu
  mkfifo guest.out guest.in
  # We could use a sparse file but we want to fail early
  fallocate -l 4G scratch-disk.img

  { qemu-system-x86_64 \
    -machine accel=kvm:tcg \
    -m 768 \
    -net nic \
    -net user \
    -kernel vmlinuz-linux \
    -initrd archiso.img \
    -append "archisobasedir=arch archisolabel=${ISO_VOLUME_ID} ip=dhcp net.ifnames=0 console=ttyS0 mirror=${MIRROR}" \
    -drive file=scratch-disk.img,format=raw,if=virtio \
    -drive file="${ISO}",format=raw,if=virtio,media=cdrom,read-only \
    -virtfs "local,path=${ORIG_PWD},mount_tag=host,security_model=none" \
    -monitor none \
    -serial pipe:guest \
    -nographic || kill "${$}"; } &

  # We want to send the output to both stdout (fd1) and fd10 (used by the expect function)
  exec 3>&1 10< <(tee /dev/fd/3 <guest.out)
}

# Wait for a specific string from qemu
function expect() {
  length="${#1}"
  i=0
  # We can't use ex: grep as we could end blocking forever, if the string isn't followed by a newline
  while true; do
    # read should never exit with a non-zero exit code,
    # but it can happen if the fd is EOF or it times out
    IFS= read -r -u 10 -n 1 -t 240 c
    if [ "${1:${i}:1}" = "${c}" ]; then
      i="$((i + 1))"
      if [ "${length}" -eq "${i}" ]; then
        break
      fi
    else
      i=0
    fi
  done
}

# Send string to qemu
function send() {
  echo -en "${1}" >guest.in
}

prepare_boot
start_qemu

expect "archiso login:"
send "root\n"
expect "# "

send "bash\n"
expect "# "
send "trap \"shutdown now\" ERR\n"
expect "# "

send "mkdir /mnt/arch-boxes && mount -t 9p -o trans=virtio host /mnt/arch-boxes -oversion=9p2000.L\n"
expect "# "
send "mkfs.ext4 /dev/vda && mkdir /mnt/scratch-disk/ && mount /dev/vda /mnt/scratch-disk && cd /mnt/scratch-disk\n"
expect "# "
send "cp -a /mnt/arch-boxes/{box.ovf,build.sh,http} .\n"
expect "# "
send "mkdir pkg && mount --bind pkg /var/cache/pacman/pkg\n"
expect "# "

# Wait for pacman-init
send "until systemctl is-active pacman-init; do sleep 1; done\n"
expect "# "

send "pacman -Sy --noconfirm qemu-headless jq\n"
expect "# "

send "bash -x ./build.sh\n"
expect "# "
send "cp -r --preserve=mode,timestamps output /mnt/arch-boxes/tmp/$(basename "${TMPDIR}")/\n"
expect "# "

mv output/* "${OUTPUT}/"

send "shutdown now\n"

wait
