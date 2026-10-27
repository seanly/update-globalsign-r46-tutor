# cacert-update

给 CentOS 6 和 CentOS 7 更新 CA 信任库。CentOS 7 升级 `ca-certificates`。CentOS 6 用 RPM 补上 7 张新的公共 TLS 根。这些根在 CentOS 7 `2023.2.60` 里有，CentOS 6 `2020.2.41` 里没有。

按用途分开存放：

| 目录 | 方式 | 做什么 |
|---|---|---|
| [ansible](ansible) | Ansible 下发 | CentOS 7 升级 `ca-certificates`。CentOS 6 再装 `el6-ca-trust-extras`。JDK 8 下发 `cacert-update.bin` |
| [packages](packages) | 按系统打 RPM | CentOS 6 用 `el6-ca-trust-extras` 把 7 张新的公共 TLS 根注入系统信任库 |
| [jdk8](jdk8) | 指定 JDK 路径的脚本，或单个 `.bin` | 给 JDK 8u201 这类旧 `cacerts` 追加 22 张公共信任根 |

`ansible/files/centos-6.repo` 和 `ansible/files/centos-7.repo` 是两套 vault 源，Ansible 会下发到对应主机。CentOS 7 升到 `ca-certificates-2023.2.60` 即包含 R46。不要把 CentOS 7 的 `ca-certificates` 装到 CentOS 6 上。

## Ansible

当前 Ansible 不能在 CentOS 6/7 上跑 `copy` 和 `yum` 模块，playbook 用 `raw` 下发。默认每批 100 台。SSH 用户不是 root 时加 `-b`。已经是 root 时用 `-e ansible_become=false`。

先改 vault 源并升级 `ca-certificates`。CentOS 7 升到 `2023.2.60` 即包含新的公共根。CentOS 6 只能升到 `2020.2.41`，接着单独安装 `el6-ca-trust-extras`。这个 RPM 要先在本机打好，playbook 读取 `packages/centos6/RPMS/el6-ca-trust-extras-2023.2.60-1.el6.noarch.rpm`。CentOS 7 和其他系统会跳过。

```bash
ansible-playbook -i inventory ansible/centos-vault-repo.yml
ansible-playbook -i inventory ansible/centos-vault-repo.yml -l 'some-group' -e batch_size=50
ansible-playbook -i inventory ansible/install-el6-ca-trust-extras.yml
```

装完后系统信任库里有 GlobalSign Root R46 和 E46、两张 DigiCert G5、ISRG Root X2，以及 Microsoft 2017 的 RSA 和 ECC 根。同钥重签和地区根不在这个包里。

JDK 8 的 `jre/lib/security/cacerts` 不读系统信任库。`ansible/import-jdk8-cacerts.yml` 先报告节点上的 JDK 8 路径、证书库是普通文件还是符号链接，以及正在运行的 Java 进程和监听地址，再下发 `jdk8/cacert-update.bin` 并执行。已经在库里的证书按 SHA-256 跳过。指向 `/etc/pki/java/cacerts` 的符号链接会跳过，避免下次 `update-ca-trust` 把这次导入冲掉。正在运行的 Java 进程要重启后才信任新根。`cacerts` 口令默认是 `changeit`。执行前先 `bash jdk8/build.sh` 生成这个 bin。

```bash
ansible-playbook -i inventory ansible/import-jdk8-cacerts.yml
ansible-playbook -i inventory ansible/import-jdk8-cacerts.yml -e cacerts_pass=changeit
ansible-playbook -i inventory ansible/import-jdk8-cacerts.yml -e jdk_check=true
ansible-playbook -i inventory ansible/import-jdk8-cacerts.yml -e jdk_paths='/usr/java/jdk1.8.0_201'
```

`-e jdk_check=true` 只报告缺哪些根。`jdk_paths` 是空格分隔的 JDK 主目录或 `cacerts` 文件，不传时由 bin 自己查找。

## JDK 8

[jdk8/import-roots.sh](jdk8/import-roots.sh) 把 22 张公共信任根追加进指定 JDK 8 的 `cacerts`。这些根来自 Temurin 8u504，8u201 里没有，而且服务器经常不附带指向旧根的交叉证书。包括 GlobalSign R46、E46、R6，两张 DigiCert G5，Sectigo R46、E46，ISRG Root X2，Amazon Root CA 1–4，GTS Root R1、R3、R4，四张 TrustAsia 根，CFCA EV ROOT，以及 Microsoft 2017 的 RSA 和 ECC 根。证书和指纹清单在脚本旁边，把 `jdk8/` 目录拷到主机上即可执行。已有条目保留。导入前会用目标 JDK 的 `keytool` 列出库里每张证书的 SHA-256。指纹已经在库里的证书直接跳过，不看别名，重复执行不会再插一条。

各国和地区 CA、4 张 emSign 根没有收入这个包。GlobalSign ECC Root CA - R4 的新证书也没有收入：8u201 里已经有同一把密钥的旧证书。

```bash
bash jdk8/import-roots.sh --check --jdk-path /usr/java/jdk1.8.0_201
bash jdk8/import-roots.sh --jdk-path /usr/java/jdk1.8.0_201
bash jdk8/import-roots.sh --jdk-path /usr/java/jdk1.8.0_201/jre/lib/security/cacerts
```

`--jdk-path` 可以重复，参数可以是 JDK 主目录，也可以是 `cacerts` 文件。不带 `--jdk-path` 时会查找 `/usr/lib/jvm`、`/usr/java`、`/opt/java`、`/usr/local/java` 和 `JAVA_HOME`。脚本用目标 JDK 自带的 `keytool`，并且只处理 JDK 8。`CACERTS_PASS` 用来指定 keystore 口令，默认 `changeit`。指向别处的符号链接会跳过。导入完成后要重启 Java 进程。

### 打包

`jdk8/cacert-update.bin` 把 `import-roots.sh`、`fingerprints.txt` 和 `certs/` 里的 22 张证书打成一个 Linux x86_64 可执行文件。下载到主机上直接运行，效果和上面的脚本相同，已经在库里的证书同样按 SHA-256 跳过。

在仓库根目录执行。本机需要 `openssl`、`python3`、`gzip` 和 Docker。镜像默认是 `docker.syscube.dev/centos:6`，平台默认 `linux/amd64`。换镜像用 `CENTOS6_IMAGE`，换平台用 `DOCKER_PLATFORM`。

```bash
bash jdk8/build.sh
```

产物：

```text
jdk8/cacert-update.bin
```

脚本先按 `jdk8/fingerprints.txt` 核对 22 张 PEM 的 SHA-256，不一致就失败。核对通过后把导入脚本、指纹清单和证书打成 tar，再 gzip，嵌进 `jdk8/launcher.c`。CentOS 6 容器里安装 gcc，编译出这个文件。它不是文本脚本，在 x86_64 Linux 上运行，依赖目标机上的 `/bin/bash` 和 `/bin/gzip`。

```bash
chmod +x cacert-update.bin
./cacert-update.bin --check --jdk-path /usr/java/jdk1.8.0_201
./cacert-update.bin --jdk-path /usr/java/jdk1.8.0_201
```

证书、指纹清单或 `import-roots.sh` 改过之后，重新执行 `bash jdk8/build.sh`。CentOS 6 系统信任库的 RPM 另行打包，见 [packages/README.md](packages/README.md)。

## RPM

打包、安装和发布到 Nexus 3 的说明见 [packages/README.md](packages/README.md)。

```bash
bash packages/centos6/build.sh
NEXUS_URL=https://nexus.example.com NEXUS_USER=deploy NEXUS_PASSWORD=... \
  bash packages/publish-nexus.sh packages/centos6/RPMS/el6-ca-trust-extras-2023.2.60-1.el6.noarch.rpm
```
