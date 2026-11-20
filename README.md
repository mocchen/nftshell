# nft-forward

一个基于 nftables 的 Linux IPv4/IPv6 端口转发脚本，支持单端口、多端口、端口范围/组合，默认同时做 DNAT 和 SNAT，并自动配置 systemd 开机恢复。

> 脚本只操作自己的表 `ip nftfwd` 和 `ip6 nftfwd`，不会执行 `flush ruleset`，也不会修改系统里其他 nftables/iptables 表。

## 功能

- 启动时自动检测 Linux、root、nft、内核 nftables 接口、IPv4/IPv6 转发、systemd
- nftables 缺失时自动调用 `apt/dnf/yum/apk/pacman/zypper` 安装
- IPv4 / IPv6 单端口转发
- 多端口转发（`80,443`）
- 端口范围（`8000-8010`）
- 端口组合/一一映射（`80,443 -> 8080,8443`）
- 多条规则指向不同目标（`--rule` 可重复，IPv6 用 `[addr]`）
- TCP / UDP，默认两者同时转发
- 默认 DNAT + SNAT，可按规则用 `--no-masquerade` 关闭 SNAT
- 默认所有入口网卡；限制网卡时自动列出本机所有网卡及其绑定 IP，供菜单选择
- 规则持久化到 `/etc/nft-forward/rules.conf`
- 添加规则时自动安装并启用 `nft-forward.service`，开机自动恢复

## 环境要求

- Linux（支持 IPv4 和 IPv6）
- root 权限（修改 nftables 必须；自动安装也必须是 root）
- nftables（`nft` 命令；缺失时脚本会尝试自动安装）
- 可选：systemd（用于开机自动恢复）
- 可选：`ip`（网卡/IP 自动识别更完整；缺失时菜单会尝试安装 iproute2）、`sysctl`、`flock`

脚本启动时会自动检测环境并显示摘要；如果需要完整诊断，可以执行：

```bash
chmod +x nft-forward.sh
sudo ./nft-forward.sh check
```

`check` 只做诊断，不会改动系统；`add` / `install` 检测到 nftables 缺失时才会自动安装。

`add` / `install` 检测到 nft 缺失时，会自动调用当前发行版的包管理器安装 `nftables`。如果自动安装失败，脚本会输出对应发行版的手动安装命令，例如：

```bash
# Debian / Ubuntu
apt-get update && apt-get install -y nftables

# RHEL / Fedora / Rocky / AlmaLinux
dnf install -y nftables

# Alpine
apk add nftables
```

## 远程运行

不需要先克隆仓库，也不需要额外启动器，直接执行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward.sh)
```

如果系统使用 `curl`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward.sh)
```

这种方式会保留终端 stdin，因此交互式菜单可以正常使用。请先确保当前是 root shell：

```bash
sudo -i
bash <(wget -qO- https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward.sh)
```

也可以通过 `sudo bash -c` 执行（进程替换由当前 shell 处理）：

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward.sh)"
```

直接带参数执行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mocchen/nftshell/refs/heads/mochen/nft-forward.sh) \
  add --listen 8080 --dest 192.168.1.10 --dest-port 80
```

> 不要使用 `wget ... | sudo bash`。管道方式会让脚本的 stdin 变成管道，交互式菜单无法读取键盘输入。
>
> 如果使用进程替换方式并添加规则，脚本会为 systemd 服务重新下载一份自身副本到 `/usr/local/sbin/nft-forward`，以保证开机自启。

生产环境如果希望固定版本，把 URL 中的 `mochen` 换成具体的 commit SHA；同时脚本内的 `SELF_RAW_URL` 也应指向同一个 commit，否则进程替换方式安装开机服务时仍会下载分支最新版。

## 交互式菜单

在终端中直接运行脚本（不带参数），或显式执行 `menu`：

```bash
sudo ./nft-forward.sh
# 或
sudo ./nft-forward.sh menu
```

菜单提供：

- 启动时自动检测环境，并在菜单顶部显示系统、root、nft、nftables、IPv4/IPv6 转发和 systemd 状态
- 添加规则时自动识别网卡及绑定 IP，选择入口网卡
- 添加单端口、多端口/范围、端口组合规则
- 添加自定义多目标规则
- 查看/删除/清空规则
- 预览 nftables 规则
- 重新应用规则
- 查看运行状态
- 安装/更新开机服务（通常添加规则时已自动完成）
- 卸载服务

界面示例：

```text
============================================================
  nft-forward 1.2.2  |  nftables IPv4/IPv6 端口转发
  用户: root    已保存规则: 2
  环境: Linux / root / nft v1.1.3
        nftables 可用 | IPv4转发: 已启用 | IPv6转发: 已启用 | systemd: 可用
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
 11) 安装/修复开机服务
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

IPv6 目标直接把地址写在 `--dest` 中：

```bash
sudo ./nft-forward.sh add \
  --listen 8443 \
  --dest 2001:db8::10 \
  --dest-port 443
```

脚本会根据目标地址自动选择 `ip` 或 `ip6` 表，并自动开启对应的 IPv4/IPv6 转发。

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

IPv6 目标在 `--rule` 中需要用方括号包住地址：

```bash
sudo ./nft-forward.sh add \
  --rule '80:192.168.1.10:80' \
  --rule '8443:[2001:db8::10]:443'
```

### 5. TCP + UDP（默认）

默认同时转发 TCP 和 UDP，不需要额外加 `--proto`：

```bash
sudo ./nft-forward.sh add \
  --listen 25565 \
  --dest 192.168.1.10 \
  --dest-port 25565
```

只转发 TCP：

```bash
sudo ./nft-forward.sh add \
  --listen 25565 \
  --dest 192.168.1.10 \
  --dest-port 25565 \
  --proto tcp
```

只转发 UDP 时使用 `--proto udp`。

### 6. 限制入口网卡 + 默认 SNAT

默认不限制入口网卡，即所有网卡。只接受从 `eth0` 进入的连接时才需要加 `--iface`。新规则默认已经开启 SNAT，不需要额外加 `--masquerade`：

```bash
sudo ./nft-forward.sh add \
  --listen 8080 \
  --dest 192.168.1.10 \
  --dest-port 80 \
  --iface eth0
```

在交互式菜单中添加规则时，选择“入口网卡”会自动列出本机所有网卡及其绑定的 IPv4/IPv6 地址，例如：

```text
可用入口网卡（显示已绑定 IP）:
   0) 所有网卡（默认）
   1) lo           127.0.0.1/8 ::1/128
   2) eth0         45.196.216.164/26 fe80::be24:11ff:fe60:4556/64
   m) 手动输入网卡名
请选择 [0]:
```

选择编号即可绑定入口网卡，不再需要手动输入网卡名。

默认 SNAT 适合：

- 内网设备通过公网 IP 访问同一内网目标（NAT 回环/hairpin）
- 目标机器的默认网关不是这台转发机，回程不对称
- 目标机器无法直接路由回客户端

如果目标回程会经过本机，并希望保留客户端真实源 IP：

```bash
sudo ./nft-forward.sh add \
  --listen 8080 \
  --dest 192.168.1.10 \
  --dest-port 80 \
  --iface eth0 \
  --no-masquerade
```

`--masquerade` 仍然可用，但现在是默认行为。开启 SNAT 后，目标机器看到的源地址会是转发机的出口地址，而不是原始客户端地址。

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
ID   FAMILY PROTO   LISTEN                   TARGET                     IFACE     MASQ
1    ip     tcp     80,443,8000-8010         192.168.1.10:80            any       yes
2    ip6    tcp     8443                      [2001:db8::10]:443          eth0      yes
```

## 开机自动恢复

添加规则成功后，脚本会自动：

- 复制脚本到 `/usr/local/sbin/nft-forward`
- 生成 `/etc/systemd/system/nft-forward.service`
- 启用并启动服务
- 服务启动时读取 `/etc/nft-forward/rules.conf` 并恢复规则

所以正常情况下不需要手动执行 `install`。

如果 systemd 不可用，或者服务配置失败，规则仍会立即生效，但会提示手动处理：

```bash
sudo ./nft-forward.sh install
```

`install` 现在主要用于手动安装/修复开机服务。

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

脚本按地址族维护独立表 `ip nftfwd` 和 `ip6 nftfwd`：

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

table ip6 nftfwd {
    chain owner { }
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        tcp dport 8443 dnat to [2001:db8::10]:443
    }
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        ip6 daddr 2001:db8::10 tcp dport 443 ct status dnat masquerade
    }
}
```

- `prerouting` 做 DNAT，把监听端口改写到目标地址/端口
- `postrouting` 默认对命中的 DNAT 流量做 SNAT；只有使用 `--no-masquerade` 的规则才不生成 SNAT 规则。空链仍会保留，以兼容 4.18 之前需要双向注册 NAT 链的内核
- `owner` 是一个空链，用来标记这张表由本脚本创建，避免误删同名表
- 添加 IPv4 规则会启用 `net.ipv4.ip_forward=1`
- 添加 IPv6 规则会启用 `net.ipv6.conf.all.forwarding=1`
- 两者都会写入 `/etc/sysctl.d/99-nft-forward.conf`
- 规则状态保存在 `/etc/nft-forward/rules.conf`

## 限制和注意事项

- 支持 IPv4 和 IPv6；目标必须是 IP 地址，不支持域名。
- 只处理 NAT，不负责绕过防火墙的 `FORWARD` 拒绝策略。如果系统本身有默认拒绝的 forward 防火墙规则，需要自行放行对应流量。
- 目标地址是回环地址（`127.0.0.0/8`、`::1`）时通常不可用；脚本会给出警告。
- 同一个“地址族 + 监听端口 + 协议 + 入口网卡”组合只能有一条规则，脚本会拒绝冲突配置。
- 端口组合的一一映射按端口从小到大排序，不支持任意乱序配对；需要任意配对时使用多条 `--rule`。
- SNAT 默认开启，会隐藏原始客户端地址；如果目标回程会经过本机，使用 `--no-masquerade` 保留客户端源 IP。
- 添加规则会自动安装开机服务；如果 systemd 不可用，会提示手动处理。
- 缺少 nftables 时，`add` / `install` 会尝试自动安装；自动安装需要 root 和可用的包管理器。
- 不要手动创建或删除 `ip nftfwd` / `ip6 nftfwd` 表；脚本依靠 `owner` 链判断归属，缺少该链时会拒绝覆盖。
- 生产环境使用前，建议先在测试机用 `--dry-run` 检查规则。

## 故障排查

```bash
# 环境是否齐全
sudo ./nft-forward.sh check

# 当前规则
sudo ./nft-forward.sh list

# 内核中的实际表
sudo nft list table ip nftfwd
sudo nft list table ip6 nftfwd

# IPv4 / IPv6 转发是否开启
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding

# systemd 日志
journalctl -u nft-forward.service -e
```

如果 `nft` 报 `Operation not permitted`，通常是容器缺少 `CAP_NET_ADMIN`，或者不是 root。
