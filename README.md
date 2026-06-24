# UESTC OpenWrt Auth Client

OpenWrt packages for UESTC campus network authentication.

This repository contains:

- `qsh-telecom-autologin`: Go client for legacy China Telecom authentication and the newer Telecom Ruijie/CAS portal.
- `go-nd-portal`: Go client for UESTC Srun authentication.
- `luci-app-uestc-authclient`: LuCI UI and monitor scripts for managing authentication sessions.
- `luci-i18n-uestc-authclient-zh-cn`: Simplified Chinese translation package.

## Authentication Types

The LuCI page separates the Telecom flows:

- `CT authentication method (legacy qsh-telecom-autologin)`: legacy CT portal, default server `172.25.249.64`.
- `电信锐捷认证`: new Telecom Ruijie/CAS portal, default server `110.184.24.61`.
- `Srun authentication method (go-nd-portal)`: UESTC Srun portal modes.

For the new Telecom Ruijie portal, configure the session as:

```text
Authentication method: 电信锐捷认证
Authentication Host: 110.184.24.61
Interface: eth1
Heartbeat hosts: 223.5.5.5, 119.29.29.29
Check interval: 30
```

The Authentication Host field should contain only the IP address, not a full portal URL.

## Build IPKs

Build locally on Linux:

```bash
bash scripts/build-ipk.sh
```

The generated packages are written to `dist/`.

The GitHub Actions workflow in `.github/workflows/build-ipk.yml` builds IPKs on each push, pull request, and manual workflow dispatch. Download the per-architecture artifacts named `uestc-authclient-<arch>-ipk` from the workflow run.

The workflow also builds common OpenWrt package architectures:

```text
x86_64
aarch64_generic
aarch64_cortex-a53
aarch64_cortex-a72
aarch64_cortex-a76
arm_arm1176jzf-s_vfp
arm_cortex-a7_neon-vfpv4
arm_cortex-a9
arm_cortex-a15_neon-vfpv4
mips_24kc
mipsel_24kc
mipsel_74kc
riscv64_riscv64
```

Every pushed commit runs CI. Pushes to `main` also refresh the rolling `latest` GitHub Release with the newest IPKs and checksums.

## Install Order

Install the client packages before the LuCI app:

```sh
opkg install qsh-telecom-autologin_*.ipk
opkg install go-nd-portal_*.ipk
opkg install luci-app-uestc-authclient_*.ipk
opkg install luci-i18n-uestc-authclient-zh-cn_*.ipk
```

Then open:

```text
http://192.168.1.1/cgi-bin/luci/admin/services/uestc-authclient
```

## Notes

The repository intentionally does not include captured portal traffic, router backups, built IPKs, or local unpacked working directories.

## Acknowledgements

This project is developed on top of work from:

- [Aleksanaa/qsh-telecom-autologin](https://github.com/Aleksanaa/qsh-telecom-autologin)
- [chasey-dev/uestc_authclient](https://github.com/chasey-dev/uestc_authclient)

The bundled Srun client source is from [fumiama/go-nd-portal](https://github.com/fumiama/go-nd-portal).
