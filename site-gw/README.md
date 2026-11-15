# site-gw 安装执行流程（Armbian 旁路网关）

把一台全新的 Armbian 小主机变成 **WireGuard 站点网关**：接上主路由后，该站点整个局域网就能与其它站点、以及你的手机/笔记本互通，用来替代 nps 内网穿透。

- 安装脚本：[`site-gw/install.sh`](./install.sh)
- 影子段操作手册：[`site-gw/shadow-subnet-usage.md`](./shadow-subnet-usage.md)
- 影子段设计说明：[`site-gw/shadow-subnet-plan.md`](./shadow-subnet-plan.md)
- 设计目标：**零参数、可重复执行、不碰宿主机上的 Docker（npm / nps）**
- 适用系统：Armbian（Debian/Ubuntu 系，内核自带 wireguard 模块）

---

## 0. 总览

| 步骤 | 在哪台机器 | 耗时 | 说明 |
|---|---|---|---|
| 1. 面板建 client | VPS / wg-easy 面板 | 1 分钟 | 每新增一个站点做一次 |
| 2. 上传配置 | Windows → 小主机 | 10 秒 | `scp 1.conf` |
| 3. 空跑校验 | 小主机 | 10 秒 | `--dry-run`，不改任何东西 |
| 4. 正式安装 | 小主机 | 1~3 分钟 | 一条 `curl \| sudo bash` |
| 5. 验证 | 小主机 | 1 分钟 | `wg show` / `docker ps` |
| 6. 主路由加静态路由 | 站点主路由 | 2 分钟 | **脚本管不到，必须手工** |
| 7. 重启自愈验证 | 小主机 | 2 分钟 | 确认断电重启后自动恢复 |
| 8. 下线 nps | VPS 或小主机 | — | 观察 1~2 天后再做 |

```
[站点A LAN 192.168.31.0/24]──Armbian(10.8.0.10)──┐
                                                ├─ UDP 51820 ─→ VPS wg-easy (10.42.42.42)
[站点B LAN 192.168.2.0/24]──Armbian(10.8.0.20)──┘                └─ 手机/笔记本 10.8.0.100
```

---

## 1. 在 wg-easy 面板创建站点 client

登录 `https://wg.entitycloud.cn` → 客户端管理 → **新建客户端**。

| 字段 | 示例（站点 A） | 说明 |
|---|---|---|
| 名称 | `gw-site-a` | 建议 `gw-<站点名>` |
| IPv4 | `10.8.0.10` | 必须落在全局 CIDR `10.8.0.0/24` 内；建议站点网关固定地址 |
| IPv6 | 留空或默认 | 只用 IPv4 时可忽略 |
| 允许的IP | `10.42.42.0/24, 10.8.0.0/24, 192.168.2.0/24` | **出方向**：这台网关要访问哪些网段（服务端 / 其它客户端 / 对端站点 LAN） |
| **服务端允许的IP** | `10.8.0.10/32, 192.168.31.0/24` | **入方向**：VPS 把去往这些网段的包交给这台网关（本站 LAN 必须在这） |
| MTU | 默认（1420） | 脚本安装时会自动改为 1380 |
| 持久化保活 | 25 | 站点在 NAT 后必须有 |
| DNS | 留空 | 不要给网关下发 DNS，否则会影响本地上网解析 |

> 保存后点 **查看配置文本 / 下载配置**，把整段内容复制出来，存成本地文件 `1.conf`。

---

## 2. 上传配置到小主机

```bash
# Linux / macOS / WSL
scp 1.conf root@192.168.31.10:/opt/wireguard/1.conf
```

```powershell
# Windows PowerShell
ssh root@192.168.31.10 "mkdir -p /opt/wireguard"
scp .\1.conf root@192.168.31.10:/opt/wireguard/1.conf
```

说明：

- 目录 `opt/wireguard` 不存在时先 `mkdir -p`（脚本也会自动建）。
- 文件名无所谓（`1.conf`、`site-a.conf` 都行）——脚本自动识别**当前目录里唯一的 `*.conf`**。
- 不要在配置里加 `AllowedIPs = 0.0.0.0/0`：那会让整台小主机（含 Docker 里的 npm/nps）全部流量走 VPN，脚本会直接拒绝执行（除非加 `--force`）。

---

## 3. 下载脚本并空跑校验

脚本有三个来源，任选一个：

| 来源 | 地址 | 适用 |
|---|---|---|
| **自建域名（长期推荐）** | `https://wg.entitycloud.cn/dl/install.sh` | 国内网络最稳，需先按「附录 D」配置 |
| **jsDelivr CDN** | `https://cdn.jsdelivr.net/gh/thatinjury2011/wg-easy@master/site-gw/install.sh` | 过渡期可直接用 |
| GitHub raw | `https://raw.githubusercontent.com/thatinjury2011/wg-easy/master/site-gw/install.sh` | 部分网络会被 reset |

```bash
cd /opt/wireguard

# 3.1 下载到本地（方便审阅、留档）
curl -fsSL https://cdn.jsdelivr.net/gh/thatinjury2011/wg-easy@master/site-gw/install.sh -o install.sh

# 3.2 校验完整性（可选但推荐）
sha256sum install.sh
#   期望：1a2987221f2973a5bd4ccb8b02c906157096e1e973c984705ef25c7687f714d0

# 3.3 语法检查（无输出即通过）
bash -n install.sh

# 3.4 空跑：只打印将要做的动作，不改任何文件
sudo bash install.sh --dry-run
```

`--dry-run` 的输出应当包含：使用的配置文件、探测到的 LAN 网段、将要写入的 `/etc/wireguard/wg0.conf` 全文（**私钥显示为 `<hidden>`**）、要写的三个路径、要启用的 systemd 单元。

---

## 4. 正式安装

```bash
# 直接用云端脚本（配置已在该目录）
curl -fsSL https://cdn.jsdelivr.net/gh/thatinjury2011/wg-easy@master/site-gw/install.sh | sudo bash

# 或者用已下载到本地的脚本
sudo bash install.sh
```

**脚本会做这些事：**

| 动作 | 说明 |
|---|---|
| 安装 `wireguard-tools`、`iptables` | 仅在缺失时安装；**不执行 `apt upgrade`、不动内核** |
| 探测 LAN 网段 | 取默认路由网卡的网段，用于生成 NAT 规则 |
| 规范化配置 | 去 CRLF、删除 `DNS =` 行、`MTU 1420 → 1380` |
| 注入转发规则 | 6 条 `PostUp/PostDown`（NAT / FORWARD / MSS clamp），带 `# site-gw:` 标记，重复执行不会重复注入 |
| 安装隧道配置 | 写入 `/etc/wireguard/wg0.conf`（权限 600） |
| 留存副本 | `/opt/wireguard/1.conf`（600），以后在任意目录重跑都能用 |
| 持久化转发 | `/etc/sysctl.d/99-site-gw.conf` 写入 `net.ipv4.ip_forward=1` |
| 开机顺序 | 写入 `wg-quick@wg0.service.d/50-site-gw.conf`（`After/Wants=network-online.target`） |
| 启用服务 | `systemctl enable --now wg-quick@wg0`；若配置未变化则不重启（零中断） |
| 自检输出 | 打印 `wg show` 结果与**本机公钥** |

**脚本不会碰：** Docker 容器/镜像/compose、Docker 的 iptables 链（`DOCKER`/`DOCKER-USER`）、`FORWARD` 默认策略、主机路由与 LAN IP、nps、npm。

---

## 5. 验证

```bash
# 服务在跑
systemctl is-active wg-quick@wg0          # active

# 握手与流量
wg show wg0
#   latest handshake: xx seconds ago     ← 有握手
#   transfer: 1.2 KiB received, 3.4 KiB sent  ← 双向非 0

# 转发已开
sysctl -n net.ipv4.ip_forward             # 1

# 去服务端走隧道
ip route get 10.42.42.42                  # ... dev wg0
ping -c3 10.42.42.42                      # 通

# Docker 未受影响
docker ps --format '{{.Names}}\t{{.Status}}'     # npm / nps 都 Up

# 本机上网未受影响
ip route get 223.5.5.5                    # 应是 LAN 网卡，不是 wg0
curl -sI https://www.baidu.com | head -1
```

**本机公钥**要与面板里该 client 的公钥一致：

```bash
wg pubkey < <(sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*//p' /etc/wireguard/wg0.conf)
```

---

## 6. 在站点主路由加静态路由（必做，脚本管不到）

主路由不知道"远端网段该交给这台小主机"，必须显式告诉它。以站点 A（LAN `192.168.31.0/24`，网关 `192.168.31.10`）为例：

| 目的网段 | 下一跳 |
|---|---|
| `10.42.42.0/24` | `192.168.31.10` |
| `10.8.0.0/24` | `192.168.31.10` |
| 对端站点 LAN（如 `192.168.2.0/24`） | `192.168.31.10` |

三种实现方式：

1. **主路由「静态路由」页面**（最稳）按上表逐条添加；
2. **DHCP option 121**（主路由没有静态路由功能时）：
   ```
   121,10.42.42.0/24,192.168.31.10,10.8.0.0/24,192.168.31.10,192.168.2.0/24,192.168.31.10
   ```
3. **把 DHCP 下发的默认网关改成 `192.168.31.10`**（小主机当默认网关）：完全不用改路由表，但全站流量都经小主机。

> 千万别加 `0.0.0.0/0` → 小主机，那等于全站走 VPN。

验证：

```bash
# 在站点内另一台电脑上
ping 10.42.42.42          # 通 = 主路由已把 VPN 网段指过去
ping 192.168.2.50         # 通 = 双向配置都对
```

---

## 7. 重启自愈验证

```bash
sudo reboot
# 回来后
systemctl is-active wg-quick@wg0 && wg show wg0
```

能自动起来即说明"上电即用"成立（依赖第 4 步写入的 `network-online.target` drop-in）。

---

## 8. 下线 nps（1~2 天稳定后再做）

```bash
# 在跑 nps 的那台机器上
cd /opt && docker compose stop nps        # 用 stop，不要 down，随时可回退

# 观察稳定后，再考虑从 compose 里删除该服务，释放 8024-8027/8080/8444/8081
```

回退：

```bash
cd /opt && docker compose start nps
```

---

## 9. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `systemctl is-active` 是 `failed` | `journalctl -u wg-quick@wg0 -n 50`；多为配置文件 CRLF 或权限问题（脚本已处理，手改过配置才会遇到） |
| `wg show` 无 `latest handshake` | Endpoint 不通：面板「网络配置 → 主机」必须是公网域名/IP（不能是 `10.42.42.42`）；云安全组放行 **UDP 51820** |
| 有握手 `transfer` 全是 0 | 服务端「服务端允许的IP」里缺该客户端的 `10.8.0.10/32` |
| 本机能通、站点内其它设备不通 | 主路由缺静态路由（第 6 步） |
| 能发出请求、一个回包都收不到 | 对端网关的「允许的IP」里缺本站 LAN 段（回程方向） |
| 网页能开但大文件卡死 | MTU/MSS：确认配置是 `MTU = 1380` 且注入了 `TCPMSS --clamp-mss-to-pmtu` |
| 装完本机上网变慢/断 | 配置里混进了 `AllowedIPs = 0.0.0.0/0`（脚本默认拒绝，加了 `--force` 才会装） |
| 重启后隧道没起来 | 缺 `network-online.target` 依赖（重跑脚本即可补上） |
| 小主机拉不到脚本 | 换 jsDelivr 地址，或按附录 D 挂到自己域名 |

---

## 10. 回滚

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/thatinjury2011/wg-easy@master/site-gw/install.sh | sudo bash -s -- --rollback
```

会停用并移除 `wg-quick@wg0`、`/etc/wireguard/wg0.conf`、systemd drop-in、配置哈希文件。

**保留**：`/etc/sysctl.d/99-site-gw.conf`（`ip_forward=1`，Docker 也依赖它）、`/opt/wireguard/1.conf`（配置副本）。需要彻底清理时手工删除。

---

## 11. 影子段模式（多个站点 LAN 网段重名时）

> 📘 **完整操作手册见 [shadow-subnet-usage.md](./shadow-subnet-usage.md)**（规划模板、逐站点清单、验证、排障、FAQ、台账）
> 📐 **原理与设计见 [shadow-subnet-plan.md](./shadow-subnet-plan.md)**

### 11.1 什么时候需要

前后两个站点都是 `192.168.1.0/24`（甚至都有 `192.168.1.208`）→ 三层路由无法区分 → 必须给每个站点一个**全局唯一的别名网段（影子段）**，由网关做 1:1 地址翻译。

```
站点 A: 192.168.1.208  ←─NETMAP─→  10.10.1.208
站点 B: 192.168.1.208  ←─NETMAP─→  10.10.2.208
```

站内设备**一个字节都不用改**；跨站访问用别名。

### 11.2 规划规则

| 规则 | 说明 |
|---|---|
| 别名段编号按**站点号**编 | `10.10.<站点号>.0/24`，**与真实 LAN 的第 3 段无关**（否则两个 `192.168.1.0/24` 会算出同一个别名） |
| 主机位保留 | `192.168.1.208` → `10.10.1.208` |
| 掩码必须与真实 LAN 相同 | 真实 `/24` → 别名 `/24`；真实 `/16` → 别名 `/16` |
| 不得与真实 LAN 冲突 | 包括 `10.8.0.0/24`、`10.42.42.0/24`、`172.16.0.0/12`、`172.28.0.0/24` |

示例：`10.10.1.0/24`(A)、`10.10.2.0/24`(B)、`10.10.3.0/24`(C)…

### 11.3 安装

```bash
cd /opt/wireguard
curl -fsSL <url> | sudo bash -s -- --alias=10.10.1.0/24
```

脚本自动完成：

- 探测真实 LAN 与网卡名
- 校验别名（规范网络地址 / 掩码一致 / 不与保留网段重叠 / `xt_NETMAP` 可用）
- 注入 2 条 NETMAP + 1 条入方向源改写 + FORWARD + MSS clamp
- `AllowedIPs` 自动补 `172.16.0.0/12`（Docker/NPM 回程必需）
- 打印面板与主路由需要配套填写的内容

再次执行即切换模式（普通 ↔ 影子），旧的注入规则会被自动清除，不会叠加。

### 11.4 配套要改（脚本管不到）

| 位置 | 填什么 |
|---|---|
| wg-easy 面板 → **服务端允许的IP** | `10.8.0.10/32, 10.10.1.0/24`（填别名，**不是** `192.168.1.0/24`） |
| wg-easy 面板 → 允许的IP | `10.42.42.0/24, 10.8.0.0/24, 172.16.0.0/12, <对端站点别名>` |
| 客户端钩子脚本 | **留空**（规则由 `--alias` 注入） |
| NPM → Forward Hostname | 别名地址，如 `10.10.1.208` |
| 主路由 | **仅在站内设备需要主动访问别站时**才加：`10.10.<别站号>.0/24 → 本站网关 LAN IP` |

> **纯"外 → 内"访问（NPM 反代、手机直连）时，主路由一条路由都不用加**：网关把源地址改写成自己的 LAN IP，站内设备回包是同网段直连，不经过主路由。

### 11.5 验证

```bash
# 规则是否生效
iptables -t nat -S | grep -E 'NETMAP|snat-lan'
# 地址翻译是否命中
conntrack -L | grep 10.10.1
# 站内设备侧抓包：源地址应为本站网关 LAN IP
tcpdump -ni br-lan host 192.168.1.208 -c 5
```

### 11.6 限制

- 仅 IPv4（NETMAP 不支持 IPv6）
- FTP 主动模式 / SIP / IPsec 等"载荷内含 IP"的协议可能异常
- 设备日志里看到的对端是别名或网关地址
- 需要内核 `xt_NETMAP`（Debian/Armbian 自带；OpenWrt 需 `iptables-mod-nat-extra`）

---

## 附录 A：参数说明

| 参数 | 作用 |
|---|---|
| （无参数） | 自动查找配置、自动探测 LAN 网段、MTU 1420→1380、直接安装 |
| `--alias=<CIDR>` | 影子段模式，为本站指定别名网段，如 `--alias=10.10.1.0/24` |
| `--dry-run` | 只打印动作与将要写入的配置（私钥隐藏），不改任何文件 |
| `--rollback` | 停用并移除本脚本安装的一切 |
| `--conf=<路径>` | 指定配置文件（目录里有多个 `.conf` 时使用） |
| `--lan=<CIDR>` | 指定本站 LAN 网段（多网卡探测不准时使用） |
| `--mtu=<N>` | 覆盖 MTU（默认仅把 1420 降为 1380） |
| `--force` | 允许 `AllowedIPs` 含 `0.0.0.0/0`（全流量走 VPN，慎用） |
| `-h` / `--help` | 查看用法 |

配置文件查找顺序：

```
当前目录唯一的 *.conf  →  ./1.conf  →  ./wg0.conf  →  /opt/wireguard/1.conf  →  /opt/wireguard/*.conf（唯一时）
```

---

## 附录 B：文件落点清单

| 路径 | 权限 | 作用 |
|---|---|---|
| `/etc/wireguard/wg0.conf` | 600 | 实际生效的隧道配置（含注入的 NAT 规则） |
| `/opt/wireguard/1.conf` | 600 | 配置副本，供以后重跑/排查 |
| `/etc/sysctl.d/99-site-gw.conf` | 644 | `net.ipv4.ip_forward=1` 持久化 |
| `/etc/systemd/system/wg-quick@wg0.service.d/50-site-gw.conf` | 644 | 开机顺序依赖 |
| `/var/lib/site-gw/config.sha256` | 644 | 配置哈希，用于"没变就不重启" |

---

## 附录 C：多站点地址规划

### C.1 各站点 LAN 网段唯一时（推荐，最简单）

| 站点 | 小主机 LAN IP | 站点 LAN | 隧道地址 | 允许的IP（出） | 服务端允许的IP（入） |
|---|---|---|---|---|---|
| A | `192.168.10.10` | `192.168.10.0/24` | `10.8.0.10` | `10.42.42.0/24, 10.8.0.0/24, 172.16.0.0/12, <其它站点 LAN>` | `10.8.0.10/32, 192.168.10.0/24` |
| B | `192.168.20.10` | `192.168.20.0/24` | `10.8.0.20` | `10.42.42.0/24, 10.8.0.0/24, 172.16.0.0/12, <其它站点 LAN>` | `10.8.0.20/32, 192.168.20.0/24` |
| C | … | … | `10.8.0.30` | … | … |

### C.2 各站点 LAN 网段重名时（影子段）

| 站点 | 真实 LAN | 别名（影子段） | 小主机 LAN IP | 隧道地址 | 服务端允许的IP（入） |
|---|---|---|---|---|---|
| A | `192.168.1.0/24` | `10.10.1.0/24` | `192.168.1.10` | `10.8.0.10` | `10.8.0.10/32, 10.10.1.0/24` |
| B | `192.168.1.0/24` | `10.10.2.0/24` | `192.168.1.10` | `10.8.0.20` | `10.8.0.20/32, 10.10.2.0/24` |
| C | `192.168.1.0/24` | `10.10.3.0/24` | `192.168.1.10` | `10.8.0.30` | `10.8.0.30/32, 10.10.3.0/24` |

安装命令：`sudo bash -s -- --alias=10.10.<站点号>.0/24`

### C.3 约定

- 隧道网段固定 `10.8.0.0/24`，第 3 段编号 = 站点序号 × 10（10 / 20 / 30…）；
- 别名统一放 `10.10.0.0/16`（避开 `10.10.0.0/24`、`10.10.10.0/24`）；
- 服务端地址 `10.42.42.42`、Docker 网络 `172.28.0.0/24` 不要占用；
- 有能力时**优先让各站点 LAN 网段唯一**（C.1）；改不动现场再用影子段（C.2）；
- 两种方式不要混用，否则地址台账会失控。

---

## 附录 D：把脚本挂到自己的域名（可选）

把脚本放到 VPS 上由 NPM 静态分发，避免依赖 GitHub 连通性。

```bash
# VPS 上
mkdir -p /opt/npm/data/dl
cp install.sh /opt/npm/data/dl/install.sh
chmod 644 /opt/npm/data/dl/install.sh
docker exec npm ls -l /data/dl/install.sh      # 确认容器内可见
```

NPM → Hosts → Proxy Hosts → `wg.entitycloud.cn` → Edit → **Advanced** 追加：

```nginx
location = /dl/install.sh {
    alias /data/dl/install.sh;
    default_type text/plain;
    charset utf-8;
    add_header Cache-Control "no-cache, max-age=0";
    add_header X-Content-Type-Options nosniff;
}
```

验证并改用该地址：

```bash
curl -sI https://wg.entitycloud.cn/dl/install.sh | head -3   # 期望 200 + text/plain
curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash
```

更新脚本时只需重新 `cp` 一次，无需重启容器。