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

The GitHub Actions workflow in `.github/workflows/build-ipk.yml` builds x86_64 IPKs on each push, pull request, and manual workflow dispatch. Download the build artifact named `uestc-authclient-x86_64-ipk` from the workflow run.

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
