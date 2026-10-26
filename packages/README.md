# packages

按目标系统分目录打包。每个目录只服务一个发行版，避免把 CentOS 6 和 CentOS 7 的包混在一起。

| 目录 | 目标系统 | 内容 |
|---|---|---|
| [centos6](centos6) | CentOS 6 | `globalsign-root-r46`，把 GlobalSign Root R46 加进系统信任库 |

以后给其他系统打包时，在这里并列加目录，例如 `centos7/`。不要把新 spec 放进 `centos6/`。

## centos6 / globalsign-root-r46

CentOS 6 官方 `ca-certificates` 最新是 `2020.2.41`，里面没有 GlobalSign Root R46。这个包只往 `/etc/pki/ca-trust/source/anchors/` 放一张根证书，不替换 `ca-certificates`。

不要在 CentOS 6 上安装 CentOS 7 的 `ca-certificates`。CentOS 6 的 `p11-kit` 是 0.18，读不了 CentOS 7 的信任库，装上去之后信任锚会变少，而且仍然没有 R46。

证书 SHA-256：`4FA3126D8D3A11D1C4855A4F807CBAD6CF919D3A5A88B03BEA2C6372D93C40C9`。打包时会再核对一次，不一致就失败。

### 构建

在仓库根目录执行。需要本机 Docker，镜像默认是 `docker.syscube.dev/centos:6`。

```bash
bash packages/centos6/build.sh
```

产物：

```text
packages/centos6/RPMS/globalsign-root-r46-2019.03.20-1.el6.noarch.rpm
```

脚本会在一次性容器里安装这个包，确认 `ca-bundle.crt` 出现 `GlobalSign Root R46`，再卸载并确认它被移除。

### 安装

```bash
rpm -Uvh globalsign-root-r46-2019.03.20-1.el6.noarch.rpm
```

`%post` 会执行 `update-ca-trust enable`，然后 `update-ca-trust extract`。如果这台机器的 `/etc/pki/tls/certs/ca-bundle.crt` 曾经被手工改过，`enable` 会拒绝执行，以免丢掉原来追加的证书。先把那些证书挪进 `anchors`，再装这个包。

这个包更新的是系统信任库。Java 如果使用独立的 `cacerts`，而不是指向 `/etc/pki/java/cacerts` 的符号链接，需要另外导入。

### 发布到 Nexus 3

`publish-nexus.sh` 把 RPM 传到 yum hosted 仓库。不要传到 proxy 或 group。仓库名默认是 `yum-el6`，用 `NEXUS_REPOSITORY` 改。账号从环境变量读取，不要写进仓库。

```bash
NEXUS_URL=https://nexus.example.com \
NEXUS_USER=deploy \
NEXUS_PASSWORD=... \
  bash packages/publish-nexus.sh \
  packages/centos6/RPMS/globalsign-root-r46-2019.03.20-1.el6.noarch.rpm
```

这个 RPM 没有 GPG 签名。客户端仓库要么关掉 `gpgcheck`，要么上传前先 `rpmsign`。上传后如果 `yum makecache` 看不到包，在 Nexus 里执行一次 Rebuild yum metadata。
