# packages

按目标系统分目录打包。每个目录只服务一个发行版，避免把 CentOS 6 和 CentOS 7 的包混在一起。

| 目录 | 目标系统 | 内容 |
|---|---|---|
| [centos6](centos6) | CentOS 6 | `el6-ca-trust-extras`，把 7 张新的公共 TLS 根加进系统信任库 |

以后给其他系统打包时，在这里并列加目录，例如 `centos7/`。不要把新 spec 放进 `centos6/`。

## centos6 / el6-ca-trust-extras

CentOS 6 官方 `ca-certificates` 最新是 `2020.2.41`。这个包把下面 7 张根放进 `/etc/pki/ca-trust/source/anchors/`。它们在 CentOS 7 `ca-certificates-2023.2.60_v7.0.306` 里有，CentOS 6 没有，而且是新的密钥。它不替换 `ca-certificates`。

- GlobalSign Root R46
- GlobalSign Root E46
- DigiCert TLS RSA4096 Root G5
- DigiCert TLS ECC P384 Root G5
- ISRG Root X2
- Microsoft RSA Root Certificate Authority 2017
- Microsoft ECC Root Certificate Authority 2017

同钥重签不装。CentOS 6 已经信任旧的 GTS Root R1–R4 和 GlobalSign ECC Root CA - R4。地区根也不装，包括 TunTrust Root CA。JDK 8 那 22 张里更晚的根也不放进这个 RPM，例如 GlobalSign R6、Sectigo R46 和 E46、四张 TrustAsia、Amazon Root CA 1–4。Amazon 和 CFCA EV ROOT 已经在 CentOS 6 的系统信任库里。

不要在 CentOS 6 上安装 CentOS 7 的 `ca-certificates`。CentOS 6 的 `p11-kit` 是 0.18，读不了 CentOS 7 的信任库，装上去之后信任锚会变少。

证书从那份 CentOS 7 RPM 抽出，清单在 [sources/fingerprints.txt](centos6/sources/fingerprints.txt)。打包时按 SHA-256 再核对一次，不一致就失败。

下面 7 张当时在 CentOS 7 的包里，Mozilla 后来已经移除，这个包不带：

- E-Tugra Global Root CA RSA v3
- E-Tugra Global Root CA ECC v3
- GLOBALTRUST 2020
- Security Communication RootCA3
- Trustwave Global Certification Authority
- Trustwave Global ECC P256 Certification Authority
- Trustwave Global ECC P384 Certification Authority

`update-ca-trust` 把 anchor 当成完整 CA。Mozilla 的 serverAuth 限制、名称约束和 distrust-after 不会留下来。

已经装过 `globalsign-root-r46` 的机器，这个包 `Obsoletes` 它。R46 改由本包提供，anchor 路径仍是 `globalsign-root-r46.crt`。

### 构建

在仓库根目录执行。需要本机 Docker，镜像默认是 `docker.syscube.dev/centos:6`。

```bash
bash packages/centos6/build.sh
```

产物：

```text
packages/centos6/RPMS/el6-ca-trust-extras-2023.2.60-1.el6.noarch.rpm
```

脚本会先把容器里的 `ca-certificates` 升到 `2020.2.41`，安装这个包，按指纹确认 7 张根都进入 `ca-bundle.crt`，并确认旧的 GTS Root R1 还在。卸载后再确认这 7 张消失，旧的 GTS Root R1 仍在。

指纹只说明证书写进了 bundle。根是否有用、系统信任库是否真的用了它们，不在 `build.sh` 里做，而是在 CentOS 6 容器里单独做。主机名在 [trust-targets.txt](centos6/trust-targets.txt)。交叉签名演示站不用。容器里的 `fetch-chains.sh` 抓叶子和中间证书。握手里如果只带着交叉证书，会再按 AIA 的 CA Issuers 把直链中间证书补上，校验时只留通向这一张根的路径。

`check-system-trust.sh` 用 CentOS 6 的 `openssl verify -purpose sslserver` 做三次对比：

- 安装前保存的 `ca-certificates-2020.2.41` bundle 必须失败。失败说明旧信任库没有另一条可用路径。
- 只把包里的这一张根当作信任锚必须成功。成功说明链接到的是这一张证书。
- 安装后的 `/etc/pki/tls/certs/ca-bundle.crt` 必须是符号链接，并且校验成功。成功说明应用程序读到的系统信任库已经信任这条链。

卸载扩展包后，系统 bundle 对同一条链必须再次失败。

容器里还会用 `openssl s_client` 探一次实时握手，结果只打印，不决定 `openssl verify` 是否通过。看到 `Verify return code: 0 (ok)` 表示握手时系统信任库也接受了证书。如果输出是「信任已通过，实时握手未完成」，前面的 `openssl verify` 已经通过，失败来自 TLS 版本或套件，不是信任库拒绝了这张根。`curl` 走 NSS，能连上会另外记一行；连不上同样不推翻 `openssl verify`。

### 安装

```bash
rpm -Uvh el6-ca-trust-extras-2023.2.60-1.el6.noarch.rpm
```

也可以在跑完 `ansible/centos-vault-repo.yml` 之后，用 Ansible 安装同一份 RPM。CentOS 7 和其他系统会跳过。

```bash
ansible-playbook -i inventory ansible/install-el6-ca-trust-extras.yml
```

`%post` 会执行 `update-ca-trust enable`，然后 `update-ca-trust extract`。如果这台机器的 `/etc/pki/tls/certs/ca-bundle.crt` 曾经被手工改过，`enable` 会拒绝执行，以免丢掉原来追加的证书。先把那些证书挪进 `anchors`，再装这个包。

这个包更新的是系统信任库。JDK 8 的独立 `jre/lib/security/cacerts` 用 `ansible/import-jdk8-cacerts.yml`：先报告 JDK 路径和 Java 监听地址，再执行 `jdk8/cacert-update.bin`。bin 的打包见仓库根目录 README 的 JDK 8 打包一节。

### 发布到 Nexus 3

`publish-nexus.sh` 把 RPM 传到 yum hosted 仓库。不要传到 proxy 或 group。仓库名默认是 `yum-el6`，用 `NEXUS_REPOSITORY` 改。账号从环境变量读取，不要写进仓库。

```bash
NEXUS_URL=https://nexus.example.com \
NEXUS_USER=deploy \
NEXUS_PASSWORD=... \
  bash packages/publish-nexus.sh \
  packages/centos6/RPMS/el6-ca-trust-extras-2023.2.60-1.el6.noarch.rpm
```

这个 RPM 没有 GPG 签名。客户端仓库要么关掉 `gpgcheck`，要么上传前先 `rpmsign`。上传后如果 `yum makecache` 看不到包，在 Nexus 里执行一次 Rebuild yum metadata。
