#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"
IPK_ARCH="${IPK_ARCH:-x86_64}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

GOARM=""
GOMIPS=""

case "${IPK_ARCH}" in
  x86_64)
    GOARCH="amd64"
    ;;
  aarch64|aarch64_generic|aarch64_cortex-a53|aarch64_cortex-a72|aarch64_cortex-a76)
    GOARCH="arm64"
    ;;
  arm_arm1176jzf-s_vfp)
    GOARCH="arm"
    GOARM="6"
    ;;
  arm_cortex-a5_vfpv4|arm_cortex-a7|arm_cortex-a7_neon-vfpv4|arm_cortex-a8_vfpv3|arm_cortex-a9|arm_cortex-a15_neon-vfpv4|arm_cortex-a53_neon-vfpv4)
    GOARCH="arm"
    GOARM="7"
    ;;
  mips_24kc)
    GOARCH="mips"
    GOMIPS="softfloat"
    ;;
  mipsel_24kc|mipsel_74kc)
    GOARCH="mipsle"
    GOMIPS="softfloat"
    ;;
  riscv64|riscv64_riscv64)
    GOARCH="riscv64"
    ;;
  *)
    echo "Unsupported IPK_ARCH=${IPK_ARCH}. Add a GOARCH mapping in scripts/build-ipk.sh." >&2
    exit 1
    ;;
esac

rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

control_value() {
  local file="$1"
  local key="$2"
  awk -F': ' -v k="${key}" '$1 == k { print $2; exit }' "${file}"
}

make_tar() {
  local source_dir="$1"
  local output_file="$2"
  (
    cd "${source_dir}"
    tar --sort=name \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -czf "${output_file}" .
  )
}

make_ipk() {
  local pkg="$1"
  local arch="$2"
  local data_src="$3"
  local control_src="$4"

  local work="${BUILD_DIR}/ipk-${pkg}"
  local data_dir="${work}/data"
  local control_dir="${work}/control"
  local version
  local installed_size
  local output

  version="$(control_value "${control_src}/control" "Version")"
  output="${DIST_DIR}/${pkg}_${version}_${arch}.ipk"

  mkdir -p "${data_dir}" "${control_dir}"
  cp -a "${data_src}/." "${data_dir}/"
  cp -a "${control_src}/." "${control_dir}/"

  installed_size="$(du -sk "${data_dir}" | awk '{ print $1 }')"
  sed -i \
    -e "s/^Architecture:.*/Architecture: ${arch}/" \
    -e "s/^Installed-Size:.*/Installed-Size: ${installed_size}/" \
    "${control_dir}/control"

  make_tar "${data_dir}" "${work}/data.tar.gz"
  make_tar "${control_dir}" "${work}/control.tar.gz"
  printf '2.0\n' > "${work}/debian-binary"

  (
    cd "${work}"
    rm -f "${output}"
    ar rcs "${output}" debian-binary control.tar.gz data.tar.gz >/dev/null
  )
  echo "Built ${output}"
}

build_go_package() {
  local pkg="$1"
  local binary="$2"
  local src="${ROOT_DIR}/packages/${pkg}/src"
  local data_dir="${BUILD_DIR}/${pkg}-data"

  mkdir -p "${data_dir}/usr/bin"
  (
    cd "${src}"
    go mod download
    GOOS=linux GOARCH="${GOARCH}" GOARM="${GOARM}" GOMIPS="${GOMIPS}" CGO_ENABLED=0 \
      go build -trimpath -ldflags="-s -w" -o "${data_dir}/usr/bin/${binary}" .
  )
  chmod 0755 "${data_dir}/usr/bin/${binary}"
  make_ipk "${pkg}" "${IPK_ARCH}" "${data_dir}" "${ROOT_DIR}/packages/${pkg}/control"
}

build_root_package() {
  local pkg="$1"
  local arch="$2"
  local root="${ROOT_DIR}/packages/${pkg}/root"
  local data_dir="${BUILD_DIR}/${pkg}-data"

  mkdir -p "${data_dir}"
  cp -a "${root}/." "${data_dir}/"

  find "${data_dir}/usr/bin" -type f -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true
  chmod 0755 "${data_dir}/etc/init.d/uestc_authclient" 2>/dev/null || true
  find "${data_dir}/etc/uci-defaults" -type f -exec chmod 0755 {} + 2>/dev/null || true

  make_ipk "${pkg}" "${arch}" "${data_dir}" "${ROOT_DIR}/packages/${pkg}/control"
}

build_go_package "qsh-telecom-autologin" "qsh-telecom-autologin"
build_go_package "go-nd-portal" "go-nd-portal"
build_root_package "luci-app-uestc-authclient" "all"
build_root_package "luci-i18n-uestc-authclient-zh-cn" "all"

(cd "${DIST_DIR}" && sha256sum *.ipk | sed 's/ \*/  /' > SHA256SUMS)
echo "Checksums written to ${DIST_DIR}/SHA256SUMS"
