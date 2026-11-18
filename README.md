# nft-forward

一个基于 nftables 的 Linux IPv4 端口转发脚本，支持单端口、多端口、端口范围/组合，以及可选的 systemd 开机恢复。

> 脚本只操作自己的表 `ip nftfwd`，不会执行 `flush ruleset`，也不会修改系统里其他 nftables/iptables 表。

## 功能

- 启动时自动检测 Linux、root、nft、内核 nftables 接口、IPv4 转发、systemd
- 检测 nft 缺失并给出常见发行版的安装命令
- 单端口转发
- 多端口转发（`80,443`）
- 端口范围（`8000-8010`）
- 端口组合/一一映射（`80,443 -> 8080,8443`）
- 多条规则指向不同目标（`--rule` 可重复）
- TCP / UDP / 两者
- 可限制入口网卡
- 可选 SNAT/masquerade（适合 NAT 回环、目标回程不一致的场景）
- 规则持久化到 `/etc/nft-forward/rules.conf`
- 可安装为 `nft-forward.service`，开机自动恢复
- 提供 `nft-forward-remote.sh` 远程启动器，可直接从 GitHub 拉取并运行

## 环境要求

- Linux（IPv4）
- root 权限（修改 nftables 必须）
- nftables（`nft` 命令）
- 可选：systemd（用于开机自动恢复）
- 可选：`sysctl`、`ip`、`flock`

脚本启动时会自动检测环境并显示摘要；如果需要完整诊断，可以执行：

```bash
chmod +x nft-forward.sh
sudo ./nft-forward.sh check
```

如果缺少 nftables，脚本会按发行版提示安装命令，例如：

```bash
# Debian / Ubuntu
apt-get update && apt-get install -y nftables

# RHEL / Fedora / Rocky / AlmaLinux
dnf install -y nftables

# Alpine
apk add nftables
```

## 远程运行

如果不想先克隆仓库，可以使用远程启动器 `nft-forward-remote.sh`。它会下载当前 `mochen` 分支的 `nft-forward.sh` 到临时文件，做一次 `bash -n` 语法检查，然后执行。

直接打开交互式菜单：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward-remote.sh)"
```

> 不要使用 `curl ... | sudo bash`。管道方式会让脚本的 stdin 变成管道，交互式菜单无法正常读取键盘输入。上面的 `bash -c "$(curl ...)"` 会保留终端。

非 root 用户只读查看菜单：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward-remote.sh)"
```

执行具体命令时，建议先把启动器下载到本地，再传参数：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward-remote.sh \
  -o /tmp/nft-forward-remote.sh

sudo bash /tmp/nft-forward-remote.sh check
sudo bash /tmp/nft-forward-remote.sh add --listen 8080 --dest 192.168.1.10 --dest-port 80
sudo bash /tmp/nft-forward-remote.sh list
```

启动器只负责下载和启动，实际逻辑仍然是仓库里的 `nft-forward.sh`。生产环境如果希望固定版本，需要同时把 README 里的启动器 URL 和 `nft-forward-remote.sh` 内部的 `RAW_URL` 换成具体的 commit SHA。

## 交互式菜单

在终端中直接运行脚本（不带参数），或显式执行 `menu`：

```bash
sudo ./nft-forward.sh
# 或
sudo ./nft-forward.sh menu
```

菜单提供：

- 启动时自动检测环境，并在菜单顶部显示系统、root、nft、nftables、IPv4 转发和 systemd 状态
- 添加单端口、多端口/范围、端口组合规则
- 添加自定义多目标规则
- 查看/删除/清空规则
- 预览 nftables 规则
- 重新应用规则
- 查看运行状态
- 安装/更新开机服务
- 卸载服务

界面示例：

```text
============================================================
  nft-forward 1.0.0  |  nftables IPv4 端口转发
  用户: root    已保存规则: 2
  环境: Linux / root / nft v1.0.9
        nftables 可用 | IPv4转发: 已启用 | systemd: 可用
============================================================
  1) 添加单端口规则
  2) 添加多端口/范围规则
  3) 添加端口组合规则
  4) 添加自定义多目标规则
  5) 查看规则
  6) 删除规则
  7) 清空规则
  8) 预览 nftables 规则
  9) 重新应用规则
 10) 查看运行状态
 11) 安装/更新开机服务
 12) 卸载服务
  0) 退出
------------------------------------------------------------
请选择 [0-12]:
```

输入数字后按 Enter 即可。非 root 用户可以查看规则、预览和状态；执行添加、删除、安装等操作时会提示需要 root。

如果脚本不是运行在交互式终端中，无参数执行会打印命令行帮助，不会打开菜单。

> `check` 子命令仍然保留，用于查看完整的环境检查报告；菜单和普通命令启动时只显示摘要。

## 快速开始

### 1. 单端口

把本机 `8080` 转发到 `192.168.1.10:80`：

```bash
sudo ./nft-forward.sh add --listen 8080 --dest 192.168.1.10 --dest-port 80
```

也可以使用位置参数简写：

```bash
sudo ./nft-forward.sh add 8080 192.168.1.10 80
```

### 2. 多端口 / 端口范围

把 `80`、`443`、`8000-8010` 都转发到同一个目标端口 `80`：

```bash
sudo ./nft-forward.sh add \
  --listen 80,443,8000-8010 \
  --dest 192.168.1.10 \
  --dest-port 80
```

### 3. 端口组合（一一对应）

监听 3 个端口，目标也写 3 个端口，会按从小到大一一对应：

```bash
sudo ./nft-forward.sh add \
  --listen 80,443,8000-8002 \
  --dest 192.168.1.10 \
  --dest-port 8080,8443,9000-9002
```

对应关系：

```text
80    -> 192.168.1.10:8080
443   -> 192.168.1.10:8443
8000  -> 192.168.1.10:9000
8001  -> 192.168.1.10:9001
8002  -> 192.168.1.10:9002
```

如果目标端口只写一个，则所有监听端口都转到这个端口。

### 4. 多个不同目标

`--rule` 的格式是 `监听端口:目标地址:目标端口`，可以重复：

```bash
sudo ./nft-forward.sh add \
  --rule 80:192.168.1.10:80 \
  --rule 443:192.168.1.20:443 \
  --rule 25565:192.168.1.30:25565
```

### 5. TCP + UDP

默认只转发 TCP。需要 UDP 时：

```bash
sudo ./nft-forward.sh add \
  --listen 25565 \
  --dest 192.168.1.10 \
  --dest-port 25565 \
  --proto both
```

### 6. 限制入口网卡 + SNAT

只接受从 `eth0` 进入的连接，并对转发流量做 SNAT：

```bash
sudo ./nft-forward.sh add \
  --listen 8080 \
  --dest 192.168.1.10 \
  --dest-port 80 \
  --iface eth0 \
  --masquerade
```

适用场景：

- 内网设备通过公网 IP 访问同一内网目标（NAT 回环/hairpin）
- 目标机器的默认网关不是这台转发机，回程不对称

开启后目标机器看到的源地址会是转发机的出口地址，而不是原始客户端地址。

### 7. 只预览，不修改系统

```bash
sudo ./nft-forward.sh add \
  --listen 8080 --dest 192.168.1.10 --dest-port 80 \
  --dry-run
```

会直接打印将写入 nftables 的规则。`--dry-run` 不需要真正应用规则。

## 常用命令

```bash
sudo ./nft-forward.sh list          # 查看规则和 ID
sudo ./nft-forward.sh status        # 查看运行状态
sudo ./nft-forward.sh remove 1      # 删除 ID 为 1 的规则
sudo ./nft-forward.sh remove 1 2    # 删除多条
sudo ./nft-forward.sh flush --yes   # 清空所有规则
sudo ./nft-forward.sh apply         # 重新应用状态文件
sudo ./nft-forward.sh down          # 只删除运行时表，保留规则配置
sudo ./nft-forward.sh check         # 详细环境检查
```

`list` 示例：

```text
ID   PROTO   LISTEN                   TARGET                   IFACE     MASQ
1    tcp     80,443,8000-8010         192.168.1.10:80          any       no
2    tcp+udp 25565                    192.168.1.30:25565       eth0      yes
```

## 开机自动恢复

规则默认只存在于当前运行时，重启后会消失。安装 systemd 服务：

```bash
sudo ./nft-forward.sh install
```

安装后会：

- 复制脚本到 `/usr/local/sbin/nft-forward`
- 生成 `/etc/systemd/system/nft-forward.service`
- 启用并启动服务
- 服务启动时读取 `/etc/nft-forward/rules.conf` 并恢复规则

之后新增/删除规则会自动重新应用，配置会保留。

查看服务：

```bash
systemctl status nft-forward.service
journalctl -u nft-forward.service -e
```

卸载：

```bash
sudo ./nft-forward.sh uninstall --yes
```

同时删除状态文件和 sysctl 配置：

```bash
sudo ./nft-forward.sh uninstall --purge --yes
```

卸载不会自动把 `net.ipv4.ip_forward` 改回 `0`，因为可能有其他服务依赖它。

## 工作原理

脚本维护一个独立表：

```nft
table ip nftfwd {
    chain owner { }
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        tcp dport { 80, 443 } dnat to 192.168.1.10:80
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip daddr 192.168.1.10 tcp dport 80 ct status dnat masquerade
    }
}
```

- `prerouting` 做 DNAT，把监听端口改写到目标地址/端口
- `postrouting` 做 SNAT；即使没有启用 `--masquerade` 也会保留空链，以兼容 4.18 之前需要双向注册 NAT 链的内核
- `owner` 是一个空链，用来标记这张表由本脚本创建，避免误删同名表
- 脚本会启用 `net.ipv4.ip_forward=1`，并写入 `/etc/sysctl.d/99-nft-forward.conf`
- 规则状态保存在 `/etc/nft-forward/rules.conf`

## 限制和注意事项

- 仅支持 IPv4；目标必须是 IP 地址，不支持域名。
- 只处理 NAT，不负责绕过防火墙的 `FORWARD` 拒绝策略。如果系统本身有默认拒绝的 forward 防火墙规则，需要自行放行对应流量。
- 目标地址是回环地址（`127.0.0.0/8`）时通常不可用；脚本会给出警告。
- 同一个“监听端口 + 协议 + 入口网卡”组合只能有一条规则，脚本会拒绝冲突配置。
- 端口组合的一一映射按端口从小到大排序，不支持任意乱序配对；需要任意配对时使用多条 `--rule`。
- `--masquerade` 会隐藏原始客户端地址；不需要时不要开启。
- 不要手动创建或删除 `ip nftfwd` 表；脚本依靠 `owner` 链判断归属，缺少该链时会拒绝覆盖。
- 生产环境使用前，建议先在测试机用 `--dry-run` 检查规则。

## 故障排查

```bash
# 环境是否齐全
sudo ./nft-forward.sh check

# 当前规则
sudo ./nft-forward.sh list

# 内核中的实际表
sudo nft list table ip nftfwd

# IPv4 转发是否开启
sysctl net.ipv4.ip_forward

# systemd 日志
journalctl -u nft-forward.service -e
```

如果 `nft` 报 `Operation not permitted`，通常是容器缺少 `CAP_NET_ADMIN`，或者不是 root。
