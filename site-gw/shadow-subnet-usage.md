# 影子段使用说明（运维操作手册）

> 适用：多个站点局域网网段重名（例如都是 `192.168.1.0/24`），需要让它们同时接入 VPN。
> 原理与设计：[`shadow-subnet-plan.md`](./shadow-subnet-plan.md) ｜ 安装总流程：[`README.md`](./README.md) 第 11 章
> 脚本：[`install.sh`](./install.sh)（`--alias=<CIDR>`）

---

## 0. 适用范围与前置条件

### 需要影子段的情况

| 场景 | 是否需要影子段 |
|---|---|
| 只有 1 个站点 | ❌ 不需要 |
| 多站点，且 LAN 网段各不相同 | ❌ 不需要（各站点直接互访即可） |
| 多站点，存在重名网段（都是 `192.168.1.0/24`） | ✅ **需要** |
| 现场设备 IP 写死、无法改网段 | ✅ **需要** |

### 前置条件（缺一项都无法互通）

1. 服务端 wg-easy 正常，`wg.entitycloud.cn:51820` 可从各站点访问（UDP 51820 放行）
2. 每个站点的 Armbian 网关已接入站点 LAN，且与内网设备**同二层网段**
3. 服务端能拿到各站点的握手（`wg show` 有 `latest handshake`）
4. 容器部署下，若要用 NPM 反代 VPN 内网，需先解决 `wg-easy` 的路由可见性（host 网络或 DNAT，见 README 相关章节）

---

## 1. 规划：先填这张表

**每个站点一行，绑死后再开始部署。** 别名段的第 3 段 = 站点编号，与真实 LAN 无关。

| 站点编号 | 站点名称 | 真实 LAN | 别名（影子段） | 网关 LAN IP | 隧道地址 | 备注 |
|---|---|---|---|---|---|---|
| 1 | 家里 | `192.168.1.0/24` | `10.10.1.0/24` | `192.168.1.10` | `10.8.0.10` | |
| 2 | 门店 | `192.168.1.0/24` | `10.10.2.0/24` | `192.168.1.10` | `10.8.0.20` | |
| 3 | 办公室 | `192.168.31.0/24` | `10.10.3.0/24` | `192.168.31.10` | `10.8.0.30` | |
| 4 | | | `10.10.4.0/24` | | `10.8.0.40` | |

### 规划自检清单

- [ ] 所有别名都在 `10.10.0.0/16` 内，且**互不重叠**
- [ ] 别名**掩码**与同站点真实 LAN 掩码一致（真实 `/24` → 别名 `/24`）
- [ ] 别名不与 `10.8.0.0/24`（VPN 客户端）、`10.42.42.0/24`（wg-easy 容器）、`172.16.0.0/12`（Docker）、`172.28.0.0/24`（proxy-net）重叠
- [ ] 没有站点的真实 LAN 落在 `10.10.x.x`
- [ ] 隧道地址第 3 段 = 站点编号 × 10（10 / 20 / 30…），不与已有 client 冲突
- [ ] 别名避免使用 `10.10.0.0/24`、`10.10.10.0/24`（易与厂商默认网段混淆）

> 地址换算：真实 `192.168.1.208` → 别名 `10.10.<站点号>.208`（主机位一一对应）。

---

## 2. 面板：创建站点 client

打开 `https://wg.entitycloud.cn` → 客户端管理 → 新建客户端。

| 字段 | 站点 1 填什么 | 说明 |
|---|---|---|
| 名称 | `gw-site-1` | 建议 `gw-<站点名>` |
| IPv4 | `10.8.0.10` | 落在全局 CIDR `10.8.0.0/24` 内，建议与台账一致 |
| IPv6 | 留空 | 影子段仅 IPv4 |
| 允许的IP | `10.42.42.0/24, 10.8.0.0/24, 172.16.0.0/12, 10.10.2.0/24, 10.10.3.0/24` | **对端站点的别名段**，不要写对端真实 LAN |
| **服务端允许的IP** | `10.8.0.10/32, 10.10.1.0/24` | **本站别名段**，不能写真实 LAN |

保存后 **还必须再做一步**（否则访问端永远 ping 不通别名）——在 wg-easy 的
**管理面板 → 钩子脚本 → 启动后脚本(PostUp)** 里加：

```bash
ip route replace 10.10.0.0/16 dev {{interface}}
```

停止前脚本(PostDown)：

```bash
ip route del 10.10.0.0/16 dev {{interface}} || true
```

> **为什么必须手工加**：wg-easy 只把网段写进 peer 的 `allowed-ips`（加密路由表），
> **不会**往容器系统路由表里加 `ip route`。少了这条，现象是：
> Windows 握手正常、`transfer` 里 sent 远大于 received、`ping` 全超时，
> 而 `docker exec wg-easy ip route | grep 10.10` 没有任何输出。
> 用 `/16` 一条覆盖所有站点，以后新增站点不用再改钩子。
> 容器内 `wg0` 自带 `10.8.0.1/24`，所以 `10.8.0.0/24` 无需额外加路由。
| MTU | 默认 | 脚本会把 1420 降为 1380 |
| 持久化保活 | `25` | 站点在 NAT 后必须有 |
| DNS | **留空** | 避免影响站点本地解析 |
| 客户端钩子脚本 | **全部留空** | 规则由 `--alias` 注入，避免叠加 |

保存后点 **查看配置文本 / 下载配置**，把内容存成 `1.conf`。

> 已存在的 client 也要按上表补 `服务端允许的IP` 和 `允许的IP`，否则服务端不会把流量交给它。

---

## 3. 部署网关

```bash
# 1) 上传配置
scp 1.conf root@192.168.1.10:/opt/wireguard/1.conf

# 2) 空跑（强烈建议，确认渲染结果）
cd /opt/wireguard
curl -fsSL https://wg.entitycloud.cn/dl/install.sh \
  | sudo bash -s -- --alias=10.10.1.0/24 --dry-run

# 3) 正式安装
curl -fsSL https://wg.entitycloud.cn/dl/install.sh \
  | sudo bash -s -- --alias=10.10.1.0/24
```

**`--dry-run` 时应确认：**

- 出现 `# site-gw:nm-out`、`# site-gw:nm-in`、`# site-gw:snat-lan` 三条规则
- **没有** `# site-gw:masq`（普通模式的那条，必须被移除）
- `MTU = 1380`
- 无 `DNS =` 行
- `AllowedIPs` 里**是否**有 `172.16.0.0/12` 看你的回程方案：走服务端 SNAT（见 §5.1）就删掉它；不做 SNAT 则保留

安装完成后脚本会打印「影子段模式：还需要你在面板/路由上做这些」，照它做即可。

---

## 4. 验证（按顺序，哪步断就查哪步）

```bash
# ① 服务与握手
systemctl is-active wg-quick@wg0
wg show wg0 | grep -E 'handshake|transfer'

# ② 规则就位
iptables -t nat -S | grep -E 'NETMAP|snat-lan'

# ③ 服务端路由（应在 VPS 上执行）
docker exec wg-easy ip route | grep 10.10

# ④ 地址翻译命中（本机发一次请求后再看）
conntrack -L | grep 10.10.1

# ⑤ 站内设备看到的源地址（应为本站网关 LAN IP）
tcpdump -ni br-lan host 192.168.1.208 -c 5

# ⑥ 端到端
ping -c3 10.10.1.208
curl -sI --max-time 5 http://10.10.1.208:5000
```

| 卡在 | 排查 |
|---|---|
| ① 无握手 | 面板「网络配置 → 主机」是否公网域名；UDP 51820 是否放行 |
| ② 有 `site-gw:masq` | 旧规则残留 → 重跑脚本（会自动清理） |
| ③ 无 10.10 路由 | 面板「服务端允许的IP」没填别名 / 没保存 |
| ④ 无 conntrack | NETMAP 未命中：LAN 网段或别名写错 |
| ⑤ 源是 `172.x` / `10.8.x` | `site-gw:snat-lan` 未生效（LAN 网卡名不对，重跑并加 `--lan=`） |
| ⑥ 超时 | `AllowedIPs` 缺 `172.16.0.0/12`，或对端站点没配 |

---

## 5. 接 NPM（公网通过域名访问）

| 字段 | 值 |
|---|---|
| Domain | `nas-1.entitycloud.cn` |
| Scheme | `http`（内网自签 https 才选 https） |
| Forward Hostname | **`10.10.1.208`**（别名地址） |
| Forward Port | 服务的真实端口（如 `5000`） |
| Websockets Support | 按服务需要 |
| Block Common Exploits | ✅ |

> NPM 必须能路由到 `10.10.x.x`（宿主机或 wg-easy 容器里有 `10.10.x.x dev wg0`），否则 502。

**NPM 容器内直连测试：**

```bash
docker exec npm sh -c "curl -sI --max-time 5 http://10.10.1.208:5000 | head -1"
```

### 5.1 前置：让 VPS 能路由到别名段

```bash
# 在 VPS 宿主机上执行
ip route get 10.10.1.208
```

| 输出 | 含义 | 处理 |
|---|---|---|
| `10.10.1.208 dev wg0` | ✅ 已通 | 直接进 §5.2 |
| `10.10.1.208 via ... dev eth0`（走默认路由） | ❌ 宿主机没有别名路由 | 见下方两条路 |

确认别名路由到底在哪一层：

```bash
# wg-easy 容器内（bridge 模式时路由在这里）
docker exec wg-easy ip route | grep 10.10

# NPM 容器内
docker exec npm ip route get 10.10.1.208
```

**路径 A：wg-easy 改成 host 网络**（一次性重构，之后 NPM 可直接填别名地址）

```bash
cd /opt/wg-easy

# 备份现有 compose
cp docker-compose.yml docker-compose.yml.bak

# 编辑：wg-easy 服务改成 host 网络，删掉 ports / networks / sysctls
nano docker-compose.yml

# 宿主机 sysctl（host 模式下 compose 里的 sysctls 失效）
sudo tee /etc/sysctl.d/99-wg-host.conf >/dev/null <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF
sudo sysctl --system

# 放行 Docker 的 FORWARD（默认策略是 DROP，不放行会静默丢包）
sudo iptables -I DOCKER-USER -o wg0 -j ACCEPT
sudo iptables -I DOCKER-USER -i wg0 -j ACCEPT

# 重建容器
docker compose down && docker compose up -d

# 验证
ip route get 10.10.1.208
```

**路径 B：wg-easy 里做 DNAT**（零停机，按服务逐条添加）

```bash
# 把 "NPM 访问 wg-easy:18080" 转发到 "站点1 的 192.168.1.50:5000"
docker exec wg-easy iptables -t nat -A PREROUTING -i eth1 -p tcp --dport 18080 \
  -j DNAT --to-destination 192.168.1.50:5000

# 验证
docker exec npm sh -c "curl -sI --max-time 5 http://wg-easy:18080 | head -1"
```

> 路径 B 下 NPM 的 Forward Hostname 填 `wg-easy`、Port 填 `18080`（不是别名地址）。

### 5.2 回程：必须把容器源地址改写成隧道地址

NPM 容器发起请求时源地址是 `172.x`（Docker 网段），站点网关不认识这个地址，回包会走公网丢掉。

```bash
# ① 先临时验证（容器内加，重启失效）
docker exec wg-easy iptables -t nat -A POSTROUTING -o wg0 -s 172.16.0.0/12 \
  -j SNAT --to-source 10.8.0.1

# ② 看规则在不在
docker exec wg-easy iptables -t nat -S POSTROUTING | grep SNAT

# ③ 触发一次请求后看计数
docker exec npm sh -c "curl -sI --max-time 5 http://10.10.1.208:5000 | head -1"
docker exec wg-easy iptables -t nat -L POSTROUTING -n -v | grep 10.8.0.1

# ④ 站点侧确认源地址已变成 10.8.0.1（在站点网关上执行）
tcpdump -ni wg0 host 192.168.1.50 -c 5
```

确认有效后写进面板固化（**管理面板 → 钩子脚本**）：

启动后脚本（PostUp）：

```bash
iptables -t nat -A POSTROUTING -o {{interface}} -s 172.16.0.0/12 -j SNAT --to-source 10.8.0.1
```

停止前脚本（PostDown）：

```bash
iptables -t nat -D POSTROUTING -o {{interface}} -s 172.16.0.0/12 -j SNAT --to-source 10.8.0.1
```

撤掉临时规则：

```bash
docker exec wg-easy iptables -t nat -D POSTROUTING -o wg0 -s 172.16.0.0/12 \
  -j SNAT --to-source 10.8.0.1
```

> 做了这一步之后，**站点网关的 `AllowedIPs` 里就不需要 `172.16.0.0/12`** —— 网关自己也跑 Docker 时，那条 `/12` 会被本地 `docker0` 的 `172.17.0.0/16` 抢走，反而制造"请求发得出、回包收不到"。

---

## 6. 站点互访（可选）

**默认不需要。** 只有"站点 1 的设备要主动访问站点 2 的设备"时才做这一步。

在站点 1 的**主路由**上加静态路由（站点 2/3 各一条）：

```
目的 10.10.2.0/24   下一跳 192.168.1.10
目的 10.10.3.0/24   下一跳 192.168.1.10
```

主路由没有静态路由功能时，用 DHCP option 121：

```
121,10.10.2.0/24,192.168.1.10,10.10.3.0/24,192.168.1.10
```

站点 1 的设备访问站点 2 的 `192.168.1.208` → 实际访问 **`10.10.2.208`**。

> 主路由**不需要**加 `10.8.0.0/24`、`10.42.42.0/24`、`172.16.0.0/12` —— 这些源地址都已被网关改写成同网段的网关 IP。

---

## 7. 新增站点（重复第 1~5 步）

1. 台账里加一行，选下一个空闲编号（`10.10.4.0/24`）
2. 面板新建 client（`10.8.0.40`、服务端允许的IP 填 `10.10.4.0/24`）
3. **已有所有站点的「允许的IP」追加新站点的别名段**（`10.10.4.0/24`），否则旧站点访问不到新站点
4. 新站点部署：`--alias=10.10.4.0/24`
5. 需要互访的站点，主路由追加 `10.10.4.0/24 → 网关 LAN IP`

新增站点的完整命令（网关 `192.168.1.10`、别名 `10.10.4.0/24`）：

```bash
scp 1.conf root@192.168.1.10:/opt/wireguard/1.conf
ssh root@192.168.1.10 'cd /opt/wireguard && curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash -s -- --alias=10.10.4.0/24'
```

---

## 8. 切换与回退

| 目标 | 操作 |
|---|---|
| 影子模式 → 普通模式（站点 LAN 已唯一化后） | 重跑同一脚本，**不带** `--alias`（旧规则自动清除） |
| 修改别名段 | 直接带新的 `--alias=...` 重跑（会重建规则），并同步面板字段与台账 |
| 完全卸载 | `curl -fsSL https://wg.entitycloud.cn/dl/install.sh \| sudo bash -s -- --rollback` |
| 只停隧道不停 Docker | `systemctl stop wg-quick@wg0` |

> 切换模式后务必回面板核对「服务端允许的IP」：普通模式填真实 LAN，影子模式填别名段。

---

## 9. 排障速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `NETMAP: No such file or directory` / target 不可用 | 内核缺 `xt_NETMAP` | `modprobe xt_NETMAP`；OpenWrt 装 `iptables-mod-nat-extra` |
| 站内设备完全 ping 不通别名 | 网关 PREROUTING NETMAP 未命中 | 检查 `iptables -t nat -S PREROUTING \| grep NETMAP` 的网段与 `-i wg0` |
| 请求发出、无回包（源是 `172.x`） | 网关不认识 `172.16.0.0/12` 的源地址 | 服务端做 SNAT（§5.2 的 `SNAT --to-source 10.8.0.1`），不要给网关加 `172.16.0.0/12`（会与本地 `docker0` 抢路由） |
| 请求发出、无回包（源是 `10.8.x`） | 网关 `AllowedIPs` 缺 `10.8.0.0/24` | 面板补 `10.8.0.0/24` 并重新导出配置 |
| **握手正常、sent≫received、ping 全超时** | **服务端缺别名路由**（wg-easy 不会自动加） | `docker exec wg-easy ip route add 10.10.1.0/24 dev wg0` 验证；固化到面板 PostUp：`ip route replace 10.10.0.0/16 dev {{interface}}` |
| 站内设备回包走公网 | 网关 `snat-lan` 未生效 | 检查 `-o <LAN网卡>` 名字；重跑并加 `--lan=` |
| 客户端能通、站点设备也能通，但 NPM 502 | NPM 容器没有 `10.10.x` 路由 | 见 §5.1（host 网络或 DNAT） |
| 跨站互访不通 | 主路由缺对端别名段路由 | 加静态路由或 DHCP 121 |
| 大文件传输卡死 | MTU/MSS | 确认 `MTU = 1380` 与 `site-gw:mss` 规则存在 |
| 反复重启后隧道掉线 | 缺 `network-online.target` 依赖 | 重跑脚本（自动补 drop-in） |
| 两台网关规则互相影响 | 站点编号/别名重复 | 回台账核对，别名必须全局唯一 |

---

## 10. FAQ

**Q：别名段可以随便改吗？**
可以，但改完必须同步：面板「服务端允许的IP」、各站点「允许的IP」、NPM 的 Forward Hostname、主路由（互访时）、台账。一次改动影响面较大，建议一次规划好。

**Q：两个站点的真实 LAN 掩码不同（一个 /24、一个 /16）怎么办？**
各自别名与自身真实 LAN 掩码保持一致即可（`10.10.1.0/24` 与 `10.10.2.0/16`），但要注意 `10.10.2.0/16` 会占用 `10.10.2.0`~`10.10.255.255`，把后面的编号吃掉 —— 建议把 /16 的站点排到最后，或先给它的真实 LAN 改小掩码。

**Q：设备 IP 变了（DHCP 重新分配）会怎样？**
别名随真实 IP 走（NETMAP 是整段映射），无需改配置；但如果台账里记录了具体设备 IP，记得更新。

**Q：能不能不 SNAT、保留真实源 IP？**
可以：去掉 `site-gw:snat-lan` 那条，然后主路由需要额外加 `10.8.0.0/24`、`10.42.42.0/24`（或 `172.16.0.0/12`）指向网关。取舍：日志里能看到真实来源，但主路由改动变多。

**Q：影子段会影响站点自己上网吗？**
不会。`AllowedIPs` 里没有 `0.0.0.0/0`，只把 VPN 网段与对端别名段送进隧道，默认路由仍是本地 ISP。

**Q：能不能同时用普通模式（网段唯一）+ 影子模式？**
不建议在同一体系内混用，台账会失控。建议统一：能改网段就改（普通模式），改不动就全用影子段。

---

## 11. 台账模板（复制到你的知识库）

```markdown
| 站点编号 | 站点名称 | 真实 LAN | 别名（影子段） | 网关 LAN IP | 隧道地址 | 主路由型号 | 备注 |
|---|---|---|---|---|---|---|---|
| 1 | 家里 | 192.168.1.0/24 | 10.10.1.0/24 | 192.168.1.10 | 10.8.0.10 | 小米 AX3000 | 静态路由不可用→用 121 |
| 2 | 门店 | 192.168.1.0/24 | 10.10.2.0/24 | 192.168.1.10 | 10.8.0.20 | OpenWrt | |
```

```csv
站点编号,站点名称,真实LAN,别名,网关LAN_IP,隧道地址,主路由,备注
1,家里,192.168.1.0/24,10.10.1.0/24,192.168.1.10,10.8.0.10,小米AX3000,DHCP-121
2,门店,192.168.1.0/24,10.10.2.0/24,192.168.1.10,10.8.0.20,OpenWrt,
```

---

## 12. 完整命令速查（复制即用）

下面所有命令里的地址都写死了，**换成你自己的值后可直接粘贴**。
脚本地址固定为：

```
https://wg.entitycloud.cn/dl/install.sh
```

### 12.1 站点 1 网关（真实 `192.168.1.0/24`，别名 `10.10.1.0/24`）

```bash
# 上传配置
scp 1.conf root@192.168.1.10:/opt/wireguard/1.conf

# 空跑
ssh root@192.168.1.10 'cd /opt/wireguard && curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash -s -- --alias=10.10.1.0/24 --dry-run'

# 正式安装
ssh root@192.168.1.10 'cd /opt/wireguard && curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash -s -- --alias=10.10.1.0/24'
```

在网关本机上直接执行（已在 `/opt/wireguard` 目录）：

```bash
cd /opt/wireguard
curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash -s -- --alias=10.10.1.0/24 --dry-run
curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash -s -- --alias=10.10.1.0/24
```

### 12.2 站点 2 网关（别名 `10.10.2.0/24`）

```bash
scp 1.conf root@192.168.2.10:/opt/wireguard/1.conf
ssh root@192.168.2.10 'cd /opt/wireguard && curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash -s -- --alias=10.10.2.0/24'
```

### 12.3 站点 3 网关（别名 `10.10.3.0/24`）

```bash
scp 1.conf root@192.168.3.10:/opt/wireguard/1.conf
ssh root@192.168.3.10 'cd /opt/wireguard && curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash -s -- --alias=10.10.3.0/24'
```

### 12.4 网关侧验证（在网关本机）

```bash
systemctl is-active wg-quick@wg0
wg show wg0
iptables -t nat -S | grep -E 'NETMAP|snat-lan'
ip route get 10.8.0.1
conntrack -L | grep 10.10.1
tcpdump -ni wg0 host 192.168.1.208 -c 5
```

### 12.5 服务端验证（在 VPS）

```bash
docker exec wg-easy wg show
docker exec wg-easy ip route | grep 10.10
docker exec npm ip route get 10.10.1.208
docker exec npm sh -c "curl -sI --max-time 5 http://10.10.1.208:5000 | head -1"
```

### 12.6 服务端回程 SNAT（VPS，先临时验证）

```bash
docker exec wg-easy iptables -t nat -A POSTROUTING -o wg0 -s 172.16.0.0/12 -j SNAT --to-source 10.8.0.1
docker exec wg-easy iptables -t nat -S POSTROUTING | grep SNAT
docker exec wg-easy iptables -t nat -L POSTROUTING -n -v | grep 10.8.0.1
```

撤销：

```bash
docker exec wg-easy iptables -t nat -D POSTROUTING -o wg0 -s 172.16.0.0/12 -j SNAT --to-source 10.8.0.1
```

### 12.7 客户端侧验证（Windows）

```powershell
wg show
route print | findstr 10.10
ping 10.10.1.208
curl.exe -I --max-time 5 http://10.10.1.208:5000
```

### 12.8 切换回普通模式（站点 LAN 已唯一化后）

```bash
cd /opt/wireguard
curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash
```

### 12.9 完全卸载

```bash
cd /opt/wireguard
curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash -s -- --rollback
```

### 12.10 指定 LAN 网段 / MTU（多网卡探测不准时）

```bash
curl -fsSL https://wg.entitycloud.cn/dl/install.sh | sudo bash -s -- --alias=10.10.1.0/24 --lan=192.168.1.0/24 --mtu=1380
```