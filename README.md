# cacert-update

给 CentOS 6 和 CentOS 7 更新 CA 信任库，处理 GlobalSign Root R1 之后的 GlobalSign Root R46。

两种方式分开存放：

| 目录 | 方式 | 做什么 |
|---|---|---|
| [ansible](ansible) | Ansible 改 yum 源并升级 `ca-certificates` | CentOS 7 由此得到 R46。CentOS 6 只能升到 `2020.2.41`，没有 R46 |
| [packages](packages) | 按系统打 RPM | CentOS 6 用 `globalsign-root-r46` 把 R46 注入系统信任库 |
| [all-in-one](all-in-one) | 单个可下载的 `.bin` | 证书嵌在脚本里，到主机上直接执行 |

`ansible/files/centos-6.repo` 和 `ansible/files/centos-7.repo` 是两套 vault 源，Ansible 会下发到对应主机。CentOS 7 升到 `ca-certificates-2023.2.60` 即包含 R46。不要把 CentOS 7 的 `ca-certificates` 装到 CentOS 6 上。

## Ansible

当前 Ansible 不能在 CentOS 6/7 上跑 `copy` 和 `yum` 模块，playbook 用 `raw` 下发。默认每批 100 台。

```bash
ansible-playbook -i inventory ansible/centos-vault-repo.yml
ansible-playbook -i inventory ansible/centos-vault-repo.yml -l 'some-group' -e batch_size=50
```

SSH 用户不是 root 时加 `-b`。已经是 root 时用 `-e ansible_become=false`。

CentOS 6 跑完后还要安装 [packages/centos6](packages/centos6) 里的 RPM，系统信任库里才会有 R46。

JDK 8 的 `jre/lib/security/cacerts` 不读系统信任库。`ansible/import-jdk8-cacerts.yml` 用该 JRE 自带的 `keytool` 导入 R46。已经指向 `/etc/pki/java/cacerts` 的符号链接会跳过，避免下次 `update-ca-trust` 把这次导入冲掉。正在运行的 Java 进程要重启后才信任新根。`cacerts` 口令默认是 `changeit`。

```bash
ansible-playbook -i inventory ansible/import-jdk8-cacerts.yml
ansible-playbook -i inventory ansible/import-jdk8-cacerts.yml -e cacerts_pass=changeit
```

## All-in-one

`all-in-one/cacert-update.bin` 是 CentOS 6 上编译的 Linux x86_64 可执行文件，不是文本脚本。安装逻辑和 GlobalSign Root R46 压在文件里面。把它下载到 CentOS 6 或 7 的 x86_64 主机上，加上执行权限后直接运行。

```bash
chmod +x cacert-update.bin
./cacert-update.bin --check
./cacert-update.bin --jdk-path /usr/java/jdk1.8.0_202
./cacert-update.bin --system-only
./cacert-update.bin --jdk-only --jdk-path /usr/lib/jvm/java-1.8.0
```

`--check` 只报告系统信任库和 JDK 8 `cacerts` 里有没有 R46，不改主机。`--jdk-path` 可以重复，参数可以是 JDK 主目录，也可以是 `cacerts` 文件。不带 `--jdk-path` 时会查找 `/usr/lib/jvm`、`/usr/java`、`/opt/java`、`/usr/local/java` 和 `JAVA_HOME`。`CACERTS_PASS` 用来指定 keystore 口令，默认 `changeit`。

证书文件更换后，在仓库里重新生成这个 bin：

```bash
bash all-in-one/build.sh
```

## RPM

打包、安装和发布到 Nexus 3 的说明见 [packages/README.md](packages/README.md)。

```bash
bash packages/centos6/build.sh
NEXUS_URL=https://nexus.example.com NEXUS_USER=deploy NEXUS_PASSWORD=... \
  bash packages/publish-nexus.sh packages/centos6/RPMS/globalsign-root-r46-2019.03.20-1.el6.noarch.rpm
```
