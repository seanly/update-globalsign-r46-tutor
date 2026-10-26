# cacert-update

给 CentOS 6 和 CentOS 7 更新 CA 信任库，处理 GlobalSign Root R1 之后的 GlobalSign Root R46。

两种方式分开存放：

| 目录 | 方式 | 做什么 |
|---|---|---|
| [ansible](ansible) | Ansible 改 yum 源并升级 `ca-certificates` | CentOS 7 由此得到 R46。CentOS 6 只能升到 `2020.2.41`，没有 R46 |
| [packages](packages) | 按系统打 RPM | CentOS 6 用 `globalsign-root-r46` 把 R46 注入系统信任库 |

`ansible/files/centos-6.repo` 和 `ansible/files/centos-7.repo` 是两套 vault 源，Ansible 会下发到对应主机。CentOS 7 升到 `ca-certificates-2023.2.60` 即包含 R46。不要把 CentOS 7 的 `ca-certificates` 装到 CentOS 6 上。

## Ansible

当前 Ansible 不能在 CentOS 6/7 上跑 `copy` 和 `yum` 模块，playbook 用 `raw` 下发。默认每批 100 台。

```bash
ansible-playbook -i inventory ansible/centos-vault-repo.yml
ansible-playbook -i inventory ansible/centos-vault-repo.yml -l 'some-group' -e batch_size=50
```

SSH 用户不是 root 时加 `-b`。已经是 root 时用 `-e ansible_become=false`。

CentOS 6 跑完后还要安装 [packages/centos6](packages/centos6) 里的 RPM，系统信任库里才会有 R46。

## RPM

打包、安装和发布到 Nexus 3 的说明见 [packages/README.md](packages/README.md)。

```bash
bash packages/centos6/build.sh
NEXUS_URL=https://nexus.example.com NEXUS_USER=deploy NEXUS_PASSWORD=... \
  bash packages/publish-nexus.sh packages/centos6/RPMS/globalsign-root-r46-2019.03.20-1.el6.noarch.rpm
```
