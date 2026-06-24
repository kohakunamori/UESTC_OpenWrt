#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"
IPK_ARCH="${IPK_ARCH:-x86_64}"
BUILD_APK="${BUILD_APK:-0}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

GOARM=""
GO386=""
GOAMD64=""
GOMIPS=""
GOMIPS64=""

case "${IPK_ARCH}" in
  x86_64)
    GOARCH="amd64"
    GOAMD64="v1"
    ;;
  i386_pentium4)
    GOARCH="386"
    GO386="sse2"
    ;;
  i386_pentium|i386_geode)
    GOARCH="386"
    GO386="softfloat"
    ;;
  aarch64|aarch64_generic|aarch64_cortex-a53|aarch64_cortex-a72|aarch64_cortex-a76)
    GOARCH="arm64"
    ;;
  loongarch64|loongarch64_generic)
    GOARCH="loong64"
    ;;
  arm_arm926ej-s|arm_xscale)
    GOARCH="arm"
    GOARM="5"
    ;;
  arm_arm1176jzf-s_vfp)
    GOARCH="arm"
    GOARM="6"
    ;;
  arm_cortex-a5_vfpv4|arm_cortex-a7|arm_cortex-a7_neon-vfpv4|arm_cortex-a8_vfpv3|arm_cortex-a9|arm_cortex-a9_neon|arm_cortex-a15_neon-vfpv4|arm_cortex-a53_neon-vfpv4)
    GOARCH="arm"
    GOARM="7"
    ;;
  mips_24kc|mips_4kec)
    GOARCH="mips"
    GOMIPS="softfloat"
    ;;
  mipsel_24kc|mipsel_74kc|mipsel_4kec)
    GOARCH="mipsle"
    GOMIPS="softfloat"
    ;;
  mips64_octeonplus)
    GOARCH="mips64"
    GOMIPS64="softfloat"
    ;;
  mips64el_mips64r2)
    GOARCH="mips64le"
    GOMIPS64="softfloat"
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

control_depends_as_apk_args() {
  local file="$1"
  local deps dep
  deps="$(control_value "${file}" "Depends" | tr ',' ' ')"
  for dep in ${deps}; do
    dep="${dep%%(*}"
    dep="${dep%%<*}"
    dep="${dep%%>*}"
    dep="${dep%%=*}"
    dep="$(printf '%s' "${dep}" | tr -d '[:space:]')"
    [ -n "${dep}" ] && printf '%s\0' "--info" "depends:${dep}"
  done
}

apk_version_for() {
  local pkg="$1"
  local version="$2"

  case "${pkg}:${version}" in
    qsh-telecom-autologin:1.0.1-1)
      printf '1.0.1-r1'
      ;;
    go-nd-portal:0.3.1-dirty-20250903-1)
      printf '0.3.1_git20250903-r1'
      ;;
    luci-app-uestc-authclient:*)
      printf '%s-r1' "${version}"
      ;;
    luci-i18n-uestc-authclient-zh-cn:git-26.175.00001-ruijie)
      printf '26.175.1_git-r1'
      ;;
    *:*-*)
      printf '%s' "${version}" | sed -E 's/-([0-9]+)$/-r\1/'
      ;;
    *)
      printf '%s' "${version}"
      ;;
  esac
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
  find "${control_dir}" -type f \( -name preinst -o -name postinst -o -name prerm -o -name postrm -o -name postinst-pkg \) -exec chmod 0755 {} +

  installed_size="$(du -sk "${data_dir}" | awk '{ print $1 }')"
  sed -i \
    -e "s/^Architecture:.*/Architecture: ${arch}/" \
    -e "s/^Installed-Size:.*/Installed-Size: ${installed_size}/" \
    "${control_dir}/control"

  make_tar "${data_dir}" "${work}/data.tar.gz"
  make_tar "${control_dir}" "${work}/control.tar.gz"
  printf '2.0\n' > "${work}/debian-binary"

  rm -f "${output}"
  (
    cd "${work}"
    tar --sort=name \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -czf "${output}" ./debian-binary ./data.tar.gz ./control.tar.gz
  )
  tar -tzf "${output}" >/dev/null
  echo "Built ${output}"
}

make_apk_post_script() {
  local pkg="$1"
  local script="$2"

  case "${pkg}" in
    luci-app-uestc-authclient)
      cat > "${script}" <<'EOF'
#!/bin/sh
[ -x /etc/uci-defaults/99-uestc-authclient-ruijie-migrate ] && {
    /etc/uci-defaults/99-uestc-authclient-ruijie-migrate || true
    rm -f /etc/uci-defaults/99-uestc-authclient-ruijie-migrate
}
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
killall -HUP rpcd 2>/dev/null || true
exit 0
EOF
      ;;
    luci-i18n-uestc-authclient-zh-cn)
      cat > "${script}" <<'EOF'
#!/bin/sh
[ -x /etc/uci-defaults/luci-i18n-uestc-authclient-zh-cn ] && {
    /etc/uci-defaults/luci-i18n-uestc-authclient-zh-cn || true
    rm -f /etc/uci-defaults/luci-i18n-uestc-authclient-zh-cn
}
uci set luci.languages.zh_cn='简体中文 (Chinese Simplified)' 2>/dev/null || true
uci commit luci 2>/dev/null || true
rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
killall -HUP rpcd 2>/dev/null || true
exit 0
EOF
      ;;
    *)
      return 1
      ;;
  esac

  chmod 0755 "${script}"
  return 0
}

make_apk() {
  local pkg="$1"
  local apk_arch="$2"
  local data_src="$3"
  local control_src="$4"

  [ "${BUILD_APK}" = "1" ] || return 0

  command -v apk >/dev/null 2>&1 || {
    echo "BUILD_APK=1 requires apk-tools v3 in PATH." >&2
    exit 1
  }

  local work="${BUILD_DIR}/apk-${pkg}-${apk_arch}"
  local data_dir="${work}/data"
  local script_dir="${work}/scripts"
  local version apk_version installed_size description maintainer output
  local dep_args=()
  local script_args=()

  version="$(control_value "${control_src}/control" "Version")"
  apk_version="$(apk_version_for "${pkg}" "${version}")"
  description="$(control_value "${control_src}/control" "Description" | sed -E 's/^ +//; s/"/'\''/g')"
  maintainer="$(control_value "${control_src}/control" "Maintainer")"
  [ -n "${maintainer}" ] || maintainer="OpenWrt LuCI community"

  mkdir -p "${data_dir}" "${script_dir}"
  cp -a "${data_src}/." "${data_dir}/"

  if [ "${pkg}" = "luci-app-uestc-authclient" ]; then
    mkdir -p "${data_dir}/etc/apk/protected_paths.d"
    printf '!etc/config/uestc_authclient\n' > "${data_dir}/etc/apk/protected_paths.d/luci-app-uestc-authclient.list"
  fi

  installed_size="$(du -sk "${data_dir}" | awk '{ print $1 }')"
  output="${DIST_DIR}/${pkg}_${apk_version}_${apk_arch}.apk"

  while IFS= read -r -d '' arg; do
    dep_args+=("${arg}")
  done < <(control_depends_as_apk_args "${control_src}/control")

  if make_apk_post_script "${pkg}" "${script_dir}/post-install"; then
    script_args+=(--script "post-install:${script_dir}/post-install")
    script_args+=(--script "post-upgrade:${script_dir}/post-install")
  fi

  rm -f "${output}"
  apk mkpkg \
    --info "name:${pkg}" \
    --info "version:${apk_version}" \
    --info "description:${description}" \
    --info "arch:${apk_arch}" \
    --info "license:GPL-2.0-or-later" \
    --info "origin:${pkg}" \
    --info "maintainer:${maintainer}" \
    --info "url:https://github.com/kohakunamori/UESTC_OpenWrt" \
    --info "build-time:${SOURCE_DATE_EPOCH}" \
    --info "installed-size:${installed_size}" \
    "${dep_args[@]}" \
    "${script_args[@]}" \
    --files "${data_dir}" \
    --output "${output}" >/dev/null

  printf 'ADBd' | cmp -n 4 - "${output}" >/dev/null || {
    echo "Generated APK is not APKv3/ADB format: ${output}" >&2
    exit 1
  }
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
    GOOS=linux GOARCH="${GOARCH}" GOARM="${GOARM}" GO386="${GO386}" GOAMD64="${GOAMD64}" GOMIPS="${GOMIPS}" GOMIPS64="${GOMIPS64}" CGO_ENABLED=0 \
      go build -trimpath -ldflags="-s -w" -o "${data_dir}/usr/bin/${binary}" .
  )
  chmod 0755 "${data_dir}/usr/bin/${binary}"
  make_ipk "${pkg}" "${IPK_ARCH}" "${data_dir}" "${ROOT_DIR}/packages/${pkg}/control"
  make_apk "${pkg}" "${IPK_ARCH}" "${data_dir}" "${ROOT_DIR}/packages/${pkg}/control"
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
  if [ "${arch}" = "all" ]; then
    make_apk "${pkg}" "noarch" "${data_dir}" "${ROOT_DIR}/packages/${pkg}/control"
  else
    make_apk "${pkg}" "${arch}" "${data_dir}" "${ROOT_DIR}/packages/${pkg}/control"
  fi
}

build_go_package "qsh-telecom-autologin" "qsh-telecom-autologin"
build_go_package "go-nd-portal" "go-nd-portal"
build_root_package "luci-app-uestc-authclient" "all"
build_root_package "luci-i18n-uestc-authclient-zh-cn" "all"

(
  cd "${DIST_DIR}"
  shopt -s nullglob
  packages=( *.ipk *.apk )
  [ "${#packages[@]}" -gt 0 ] || {
    echo "No packages were built." >&2
    exit 1
  }
  sha256sum "${packages[@]}" | sed 's/ \*/  /' > SHA256SUMS
)
echo "Checksums written to ${DIST_DIR}/SHA256SUMS"
