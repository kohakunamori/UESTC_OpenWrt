# UESTC OpenWrt 认证客户端

用于在 OpenWrt 上管理 UESTC 校园网认证，包含 LuCI 管理界面、认证监控脚本，以及电信锐捷、旧版电信、Srun 三类认证客户端。

## 安装

从 [Releases](https://github.com/kohakunamori/UESTC_OpenWrt/releases) 下载与你路由器架构匹配的包。OpenWrt 24.10 及更旧版本通常安装 `.ipk`；OpenWrt 25.12 及更新版本安装 `.apk`。路由器架构可通过以下命令查看：

```sh
opkg print-architecture
```

如果系统使用 apk 包管理，也可以查看：

```sh
apk print-arch
```

Release 中的 `<arch>` 表示 OpenWrt 架构字段。为兼容更多 OpenWrt 大版本和小版本，CI 同时构建 opkg/IPK 包与 APKv3 包；Go 客户端以静态方式交叉编译，LuCI 包不区分 CPU 架构，但仍要求固件提供 LuCI、rpcd、uci 和 procd 环境。

opkg/IPK 系统每次安装需要四个包：

```text
qsh-telecom-autologin_<version>_<arch>.ipk
go-nd-portal_<version>_<arch>.ipk
luci-app-uestc-authclient_<version>_all.ipk
luci-i18n-uestc-authclient-zh-cn_<version>_all.ipk
```

先安装两个认证客户端，再安装 LuCI 应用和中文语言包：

```sh
opkg install qsh-telecom-autologin_*.ipk
opkg install go-nd-portal_*.ipk
opkg install luci-app-uestc-authclient_*.ipk
opkg install luci-i18n-uestc-authclient-zh-cn_*.ipk
```

apk 系统每次安装对应的四个 APKv3 包：

```text
qsh-telecom-autologin_<apk-version>_<arch>.apk
go-nd-portal_<apk-version>_<arch>.apk
luci-app-uestc-authclient_<apk-version>_noarch.apk
luci-i18n-uestc-authclient-zh-cn_<apk-version>_noarch.apk
```

当前 Release 中的 APK 未签名，安装本地包时使用：

```sh
apk add --allow-untrusted ./qsh-telecom-autologin_*.apk
apk add --allow-untrusted ./go-nd-portal_*.apk
apk add --allow-untrusted ./luci-app-uestc-authclient_*.apk
apk add --allow-untrusted ./luci-i18n-uestc-authclient-zh-cn_*.apk
```

安装完成后进入：

```text
http://192.168.1.1/cgi-bin/luci/admin/services/uestc-authclient
```

## 配置

在 LuCI 页面中新建或编辑认证会话，按实际线路选择认证方式。

| 认证方式 | 适用入口 | 默认认证服务器 |
| --- | --- | --- |
| `电信锐捷认证 (qsh-telecom-ruijie)` | 新版电信锐捷 / CAS portal | `锐捷 - 清水河宿舍 (110.184.24.61)` |
| `CT authentication method (legacy qsh-telecom-autologin)` | 旧版电信 portal | `172.25.249.64` |
| `Srun authentication method (go-nd-portal)` | Srun 认证 | 按校区和运营商选择 |

`Authentication Host` 只填写服务器 IP，不填写完整 URL，也不填写 `/portal/entry`、`/cas-sso/login` 等路径。客户端会自动跟随 portal 重定向并完成 CAS 登录流程。

需要开机自动认证时，同时启用：

```text
Global / Bring up on boot
Session / Enabled
```

如果当前网络已经可用，脚本会直接返回成功并跳过重复认证：

```text
Network already reachable on eth1, skip authentication
```

这是预期行为，用于避免已认证状态下反复提交登录请求。

## 升级

升级时按安装顺序重新安装同架构的新包即可：

```sh
opkg install --force-reinstall qsh-telecom-autologin_*.ipk
opkg install --force-reinstall go-nd-portal_*.ipk
opkg install --force-reinstall luci-app-uestc-authclient_*.ipk
opkg install --force-reinstall luci-i18n-uestc-authclient-zh-cn_*.ipk
```

apk 系统升级时重新安装同架构 APK：

```sh
apk add --allow-untrusted --upgrade ./qsh-telecom-autologin_*.apk
apk add --allow-untrusted --upgrade ./go-nd-portal_*.apk
apk add --allow-untrusted --upgrade ./luci-app-uestc-authclient_*.apk
apk add --allow-untrusted --upgrade ./luci-i18n-uestc-authclient-zh-cn_*.apk
```

`/etc/config/uestc_authclient` 被声明为配置文件，正常升级不会覆盖已有账号、密码和会话配置。新版包会在缺失时自动补充 `qsh_telecom_ruijie` 会话模板，并把旧的 `ct_ruijie` 会话迁移到新名称。

## Releases 发布规律

CI 在以下场景自动执行：

```text
push
pull_request
workflow_dispatch
```

每次 CI 会构建常见 OpenWrt 架构的 IPK 和 APK：

```text
i386_geode
i386_pentium
i386_pentium4
x86_64
aarch64_generic
aarch64_cortex-a53
aarch64_cortex-a72
aarch64_cortex-a76
arm_arm926ej-s
arm_arm1176jzf-s_vfp
arm_xscale
arm_cortex-a5_vfpv4
arm_cortex-a7
arm_cortex-a7_neon-vfpv4
arm_cortex-a8_vfpv3
arm_cortex-a9
arm_cortex-a9_neon
arm_cortex-a15_neon-vfpv4
arm_cortex-a53_neon-vfpv4
mips_4kec
mips_24kc
mipsel_4kec
mipsel_24kc
mipsel_74kc
mips64_octeonplus
mips64el_mips64r2
riscv64_riscv64
loongarch64_generic
```

每次推送到 `main` 且 CI 全部通过后，会自动刷新 `latest` Release：

```text
https://github.com/kohakunamori/UESTC_OpenWrt/releases/tag/latest
```

`latest` 是滚动发布，会被后续 `main` 分支提交替换。需要可复现地定位构建来源时，以 Release 标题中的 commit 短哈希、Actions run 和 `SHA256SUMS` 为准。

Pull Request 和非 `main` 分支推送只生成 Actions artifacts，不会更新 `latest` Release。
