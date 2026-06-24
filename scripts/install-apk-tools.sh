#!/usr/bin/env bash
set -euo pipefail

VERSION="${APK_TOOLS_VERSION:-latest}"
ARCH="${APK_TOOLS_ARCH:-x86_64}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_DIR="${ROOT_DIR}/.tools/apk-tools"
BASE_URL="https://dl-cdn.alpinelinux.org/alpine/edge/main/${ARCH}"

if [ "${VERSION}" = "latest" ]; then
  PACKAGE="$(
    curl -fsSL "${BASE_URL}/" |
      grep -oE 'apk-tools-static-[0-9][^"]+\.apk' |
      sort -V |
      tail -n 1
  )"
else
  PACKAGE="apk-tools-static-${VERSION}.apk"
fi

[ -n "${PACKAGE}" ] || {
  echo "Unable to find apk-tools-static package in ${BASE_URL}." >&2
  exit 1
}

URL="${BASE_URL}/${PACKAGE}"

rm -rf "${TOOL_DIR}"
mkdir -p "${TOOL_DIR}"

curl -fsSL "${URL}" -o "${TOOL_DIR}/${PACKAGE}"
tar -xzf "${TOOL_DIR}/${PACKAGE}" -C "${TOOL_DIR}" sbin/apk.static
install -m 0755 "${TOOL_DIR}/sbin/apk.static" "${TOOL_DIR}/apk"

"${TOOL_DIR}/apk" --version
printf '%s\n' "${TOOL_DIR}" >> "${GITHUB_PATH:-/dev/null}"
