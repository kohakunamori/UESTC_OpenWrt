#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
OPENWRT_VERSION="${OPENWRT_VERSION:?OPENWRT_VERSION is required}"
OPENWRT_TARGET="${OPENWRT_TARGET:-x86}"
OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:-64}"
IPK_ARCH="${IPK_ARCH:-x86_64}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/build/openwrt-smoke-${OPENWRT_VERSION}-${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}}"
SSH_HOST="${SSH_HOST:-192.168.1.1}"
SSH_PORT="${SSH_PORT:-22}"
TAP_IF="${TAP_IF:-owrt${OPENWRT_VERSION//./}$((RANDOM % 9000 + 1000))}"

for tool in curl gzip ip nc qemu-system-x86_64 ssh sshpass sudo timeout; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "Required tool not found: ${tool}" >&2
    exit 1
  }
done

mkdir -p "${WORK_DIR}"
IMAGE_GZ="${WORK_DIR}/openwrt.img.gz"
IMAGE="${WORK_DIR}/openwrt.img"
CONSOLE_LOG="${WORK_DIR}/console.log"
QEMU_PID=""
AUTH_PREFIX=()

cleanup() {
  if [ -n "${QEMU_PID}" ] && kill -0 "${QEMU_PID}" 2>/dev/null; then
    kill "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
  fi
  sudo ip link delete "${TAP_IF}" 2>/dev/null || true
}

dump_console_on_error() {
  local rc=$?
  if [ "${rc}" -ne 0 ] && [ -f "${CONSOLE_LOG}" ]; then
    echo "::group::OpenWrt console tail"
    tail -n 200 "${CONSOLE_LOG}" || true
    echo "::endgroup::"
  fi
  cleanup
  exit "${rc}"
}
trap dump_console_on_error EXIT

target_dir_url="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
target_name="${OPENWRT_TARGET}-${OPENWRT_SUBTARGET}"

echo "Discovering OpenWrt image in ${target_dir_url}"
image_name="$(
  curl -fsSL "${target_dir_url}/" |
    sed -n "s/.*href=\"\\([^\"]*${OPENWRT_VERSION}-${target_name}-generic-ext4-combined\\.img\\.gz\\)\".*/\\1/p" |
    head -n 1
)"

if [ -z "${image_name}" ]; then
  echo "Could not find generic ext4 combined image for ${OPENWRT_VERSION} ${target_name}." >&2
  echo "Available combined image candidates:" >&2
  curl -fsSL "${target_dir_url}/" |
    sed -n 's/.*href="\([^"]*combined[^"]*\.img\.gz\)".*/\1/p' >&2
  exit 1
fi

if [ ! -s "${IMAGE_GZ}" ]; then
  echo "Downloading ${image_name}"
  curl -fL "${target_dir_url}/${image_name}" -o "${IMAGE_GZ}"
fi

echo "Extracting image"
rm -f "${IMAGE}"
set +e
gzip -dc "${IMAGE_GZ}" > "${IMAGE}"
gzip_rc=$?
set -e
if [ "${gzip_rc}" -ne 0 ]; then
  if [ "${gzip_rc}" -eq 2 ] && [ -s "${IMAGE}" ]; then
    echo "gzip reported a warning while extracting; continuing because the image was produced."
  else
    echo "Failed to extract ${IMAGE_GZ}." >&2
    rm -f "${IMAGE}"
    exit "${gzip_rc}"
  fi
fi
if [ ! -s "${IMAGE}" ]; then
  echo "Extracted image is empty: ${IMAGE}" >&2
  exit 1
fi

qsh_ipk="$(ls "${DIST_DIR}"/qsh-telecom-autologin_*_"${IPK_ARCH}".ipk | head -n 1)"
go_ipk="$(ls "${DIST_DIR}"/go-nd-portal_*_"${IPK_ARCH}".ipk | head -n 1)"
luci_ipk="$(ls "${DIST_DIR}"/luci-app-uestc-authclient_*_all.ipk | head -n 1)"
i18n_ipk="$(ls "${DIST_DIR}"/luci-i18n-uestc-authclient-zh-cn_*_all.ipk | head -n 1)"

echo "Using packages:"
printf '  %s\n' "${qsh_ipk}" "${go_ipk}" "${luci_ipk}" "${i18n_ipk}"

echo "Creating TAP interface ${TAP_IF} for OpenWrt LAN access"
sudo ip tuntap add dev "${TAP_IF}" mode tap user "$(id -un)"
sudo ip addr add 192.168.1.2/24 dev "${TAP_IF}"
sudo ip link set "${TAP_IF}" up

echo "Starting OpenWrt ${OPENWRT_VERSION} VM"
qemu-system-x86_64 \
  -m 512M \
  -smp 2 \
  -drive "file=${IMAGE},format=raw,if=ide" \
  -netdev "tap,id=lan0,ifname=${TAP_IF},script=no,downscript=no" \
  -device e1000,netdev=lan0,mac=52:54:00:12:34:56 \
  -netdev "user,id=wan0" \
  -device e1000,netdev=wan0,mac=52:54:00:12:34:57 \
  -display none \
  -serial "file:${CONSOLE_LOG}" \
  -no-reboot &
QEMU_PID="$!"

ssh_common=(
  -p "${SSH_PORT}"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=5
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

try_ssh_none() {
  timeout 8s ssh "${ssh_common[@]}" \
    -o BatchMode=yes \
    -o PreferredAuthentications=none \
    -o PubkeyAuthentication=no \
    "root@${SSH_HOST}" "$@"
}

try_ssh_empty_password() {
  timeout 8s sshpass -p '' ssh "${ssh_common[@]}" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "root@${SSH_HOST}" "$@"
}

echo "Waiting for SSH"
for _ in $(seq 1 90); do
  if nc -z "${SSH_HOST}" "${SSH_PORT}" 2>/dev/null; then
    if try_ssh_none true 2>/dev/null; then
      AUTH_PREFIX=(ssh "${ssh_common[@]}" -o BatchMode=yes -o PreferredAuthentications=none -o PubkeyAuthentication=no)
      break
    fi
    if try_ssh_empty_password true 2>/dev/null; then
      AUTH_PREFIX=(sshpass -p '' ssh "${ssh_common[@]}" -o PreferredAuthentications=password -o PubkeyAuthentication=no)
      break
    fi
  fi
  sleep 2
done

if [ "${#AUTH_PREFIX[@]}" -eq 0 ]; then
  echo "OpenWrt SSH did not become reachable/authenticated." >&2
  exit 1
fi

guest_ssh() {
  "${AUTH_PREFIX[@]}" "root@${SSH_HOST}" "$@"
}

guest_upload() {
  local local_file="$1"
  local remote_file="$2"
  "${AUTH_PREFIX[@]}" "root@${SSH_HOST}" "cat > '${remote_file}'" < "${local_file}"
}

echo "Configuring guest network for package feed access"
guest_ssh 'sh -s' <<'EOF'
set -eu
iface="$(ip -o link show | awk -F': ' '/: eth[0-9]/{ print $2 }' | tail -n 1)"
[ -n "${iface}" ]
ip link set "${iface}" up
ip addr add 10.0.2.15/24 dev "${iface}" 2>/dev/null || true
ip route replace default via 10.0.2.2 dev "${iface}"
mkdir -p /tmp/resolv.conf.d
printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf.d/resolv.conf.auto
ln -sf /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf
EOF

echo "Uploading packages"
guest_ssh 'mkdir -p /tmp/uestc-smoke'
for package_path in "${qsh_ipk}" "${go_ipk}" "${luci_ipk}" "${i18n_ipk}"; do
  guest_upload "${package_path}" "/tmp/uestc-smoke/$(basename "${package_path}")"
done

echo "Installing and validating packages"
guest_ssh 'sh -s' <<'EOF'
set -eux
opkg update
opkg install --force-reinstall /tmp/uestc-smoke/qsh-telecom-autologin_*_*.ipk
opkg install --force-reinstall /tmp/uestc-smoke/go-nd-portal_*_*.ipk
opkg install --force-reinstall /tmp/uestc-smoke/luci-app-uestc-authclient_*_all.ipk
opkg install --force-reinstall /tmp/uestc-smoke/luci-i18n-uestc-authclient-zh-cn_*_all.ipk

opkg list-installed | grep -E 'uestc|qsh|go-nd'

test -x /usr/bin/qsh-telecom-autologin
test -x /usr/bin/go-nd-portal
test -x /usr/bin/uestc_authclient_script.sh
test -x /usr/bin/uestc_authclient_manager.sh

/bin/sh -n /usr/bin/uestc_authclient_script.sh
/bin/sh -n /usr/bin/uestc_authclient_monitor.sh
/bin/sh -n /etc/init.d/uestc_authclient

overview=/www/luci-static/resources/view/uestc-authclient/overview.js
test -f "${overview}"
grep -q "CT authentication method (qsh-telecom-autologin)" "${overview}"
grep -q "http://connectivitycheck.gstatic.com/generate_204" "${overview}"
! grep -q "o.value('qsh-telecom-ruijie'" "${overview}"
! grep -q "110.184.24.61" "${overview}"

/etc/init.d/rpcd restart || true
/etc/init.d/uhttpd restart || true
sleep 2
wget -qO- http://127.0.0.1/luci-static/resources/view/uestc-authclient/overview.js |
  grep -q "CT authentication method (qsh-telecom-autologin)"

/etc/init.d/uestc_authclient enable
/etc/init.d/uestc_authclient start || true
/usr/bin/uestc_authclient_manager.sh status
EOF

echo "OpenWrt ${OPENWRT_VERSION} QEMU smoke test passed."
