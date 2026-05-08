# OpenTube Volunteer Helper Peer

## 0. 为什么需要 Volunteer Peer

**Foundation peer 不可能管够全网**：每个 Foundation peer 是 Foundation 出钱 / 出运维，规模化困难。等 OpenTube 用户起量后，仅靠 Foundation peer 会成为带宽瓶颈 + 单点风险。

**让任何人能贡献 helper peer 是 P2P 网络的必经之路**。但跟 Foundation peer 不一样：

| 维度 | Foundation peer | Volunteer peer |
| --- | --- | --- |
| 谁运维 | Foundation 直接运维 | 任何人，自己的 VPS |
| 域名 | `peerN.youfanstube.com`（Foundation 持有） | `<dashed-ip>.sslip.io`（公共解析，免费） |
| TLS cert | Caddy ACME，Foundation 域名 | Caddy ACME，sslip.io 域名 |
| 进 SignedPeerList？ | ✓ 立即（admin 在 console 操作 → Foundation 私钥签） | ✗ 不直接进；表现良好可被 promote |
| 客户端如何发现 | Bootstrap 通道（DoH + Gist）签名 peer list | 通过 GossipSub `opentube/exit-node-advertise/v1` topic 自播，连上 Foundation peer 后 mesh 学习 |
| 信任 tier | Tier 1（冷启动信任） | Tier 2（运行时累积） |

---

## 1. 安装一行命令

任何 Linux x86_64 / aarch64 VPS（root），跑：

```bash
curl -fsSL https://raw.githubusercontent.com/yesyoufanstube/youfanstube/main/install-helper-from-release.sh \
  | sudo VOLUNTEER_MODE=1 bash
```

脚本会：

1. 探测公网 IPv4（`api.ipify.org` / `ifconfig.me` / `icanhazip.com` 三个独立服务，任一即可）
2. 默认 hostname = `<dashed-ip>.sslip.io`（如 `1-2-3-4.sslip.io`，sslip.io 是真实公共 DNS，自动把 `1-2-3-4.sslip.io` 解析到 `1.2.3.4`）
3. 下 helper bundle from GitHub Release（已 ed25519 签名，本地 verify 后才解）
4. 装 Caddy + 写 Caddyfile，自动 ACME 拿 sslip.io cert
5. 装 systemd unit + 启动 helper 进程
6. ufw 放行 80（ACME challenge）+ 8443（WSS）+ 14001（libp2p TCP）

完成后输出 multiaddr：
```
/dns4/1-2-3-4.sslip.io/tcp/8443/tls/ws/p2p/12D3KooW...
```

---

## 2. 安全模型

### 2.1 Volunteer 不需要 Foundation 任何凭据

- 不需要 console 账号
- 不需要 CF API token
- 不需要 Foundation 私钥
- 不需要 youfanstube.com 子域名

**Volunteer peer 启动后是完全独立的 libp2p 节点**，跟 Foundation 的关系仅限：
- 把 Foundation peer 当 Bootstrap（即冷启动连第一个 peer）
- 加入 Foundation peer 维护的 GossipSub mesh
- 通过 mesh 跟其他 peer（Foundation + 其它 volunteer）通信

### 2.2 Volunteer peer 怎么"伪造" Foundation peer

**不能**。Volunteer 拿的是公开 helper bundle，里面没有 Foundation 私钥。要让自己出现在 SignedPeerList 必须：
- 拿到 Foundation 私钥（仅 Foundation 运维本机）
- 或 Foundation 主动签 volunteer 的 peerId 进新 SignedPeerList（人工 review）

客户端冷启动只信 `trustedSigners` 里 hardcoded 的 Foundation 公钥派生的签名 → volunteer peerId 不在签名 list 里 → 冷启动时不会作为初始连接对象。

### 2.3 客户端如何 weight volunteer peer

- 每次跟 peer 交互（exit-node 转发字节、ingest 验证、attestation 等）→ 累积 ingest_count / attest_count / fail_count
- score = f(成功率, 时间衰减, 历史长度)
- 客户端选 peer 时 weight = score；新 peer score 0，被选概率低，但不为 0（"optimistic unchoke" 给新 peer 试用）
- exit-node leecher 检测：volunteer 7 天内 0 ingest 贡献 → 标 leecher，其他 peer 拒为它中转

恶意 volunteer 可能行为 + 防御：
- **数据投毒**（中转篡改字节）：客户端 sourceResolver 多 ingester 比对 + manifest CID 校验 → 投毒被 attest_count 拉低 → reputation 降
- **拒绝服务 / 慢响应**：客户端 4s 握手超时熔断（已实现），自动降级到下一个 peer
- **占资源不贡献**：exit-node leecher detection 拒新流
- **冒名 SignedPeerList**：不可能，需 Foundation 私钥

---

## 3. 客户端发现 volunteer 的链路

```
客户端冷启动
  ↓
DoH (bootstrap.youfanstube.com TXT) + GitHub Gist 拉 SignedPeerList
  ↓ Foundation 公钥 verify ed25519 签名
连接 Foundation peer 1 (peer1.youfanstube.com)
  ↓ libp2p identify + GossipSub mesh formation
订阅 'opentube/exit-node-advertise/v1' topic
  ↓
收 volunteer peer 1 advertise message：
  { peerId: 12D3KooW..., multiaddrs: [...sslip.io...], capacity: ... }
  ↓ 校验 advertise 签名（volunteer 自签，证明 peerId 拥有者）
加进本地 trustedPeerCache，按 reputation 评分
  ↓
后续 P2P 操作（ingest 中转 / exit-node 出口）
   - 优先选高 reputation peer
   - volunteer peer 试用一次 → 成功 → reputation +
                        → 失败 → reputation -
```

---

## 4. Volunteer 长期路径

### 4.1 起步

- 装好 helper，确认 systemd active + Caddy cert ok
- 把 multiaddr 分享给朋友测试连接（在朋友客户端 Settings → Bootstrap → 加自定义 multiaddr）
- 朋友客户端连上后会自动通过 mesh 把 volunteer 介绍给其他 peer

### 4.2 进 SignedPeerList（promote 到 Tier 1）

如果 volunteer 长期高可用 + 无故障：

1. 在 GitHub `yesyoufanstube/youfanstube` 开 issue：
   ```
   Title: [Promote] My helper at 1-2-3-4.sslip.io
   Body:
     - PeerID: 12D3KooW...
     - 已运行: 30+ 天
     - 平均月可用度: 99.x%（/var/log 自查）
     - 提供 ssh 给 Foundation council 验证
   ```
2. Foundation council review → 决定是否 promote
3. Promote = council 在 console 走 Resign 工作流，把 volunteer peerId 加进新 SignedPeerList → Foundation 签 → 部署

### 4.3 升级 / 维护

- helper 自身：跟着 Release tag 重跑 install 脚本即可（`RELEASE_TAG=v0.2.x` 覆盖默认）
- libp2p PeerID 持久化：跨 install 保留（`PRESERVE_PEERID=1` 默认开），重装不会丢身份

---

## 5. 资源 / 网络要求

- **CPU**：单核够用，平时 <5% 占用
- **RAM**：~120 MB（bundled Node + libp2p + helia + sqlite）
- **磁盘**：~120 MB install + 视情况 < 1 GB 数据（DB + helia blockstore）
- **带宽**：默认 cap 50 MB/s upload（`OT_HELPER_BYTES_PER_SEC`），可自调
- **公网 IP**：必须有静态公网 IPv4（NAT 后不行 — 客户端 dial 进不来）
- **端口开放**：8443/tcp（WSS）+ 14001/tcp（直连 libp2p TCP）+ 80/tcp（Caddy ACME）

不需要：
- 域名注册
- TLS cert 单买（Caddy 自动 ACME sslip.io）
- 静态 IPv6（暂不用）

---

## 6. 故障排查

```bash
# 看 helper 进程状态
systemctl status opentube-helper

# 看 libp2p 启动日志（应有 "Helia + libp2p ready"）
tail -f /var/log/opentube-helper.log

# 看 Caddy 是否拿到 cert（首次 ~30s）
journalctl -u caddy --since "5 minutes ago" | grep -iE 'cert|acme|tls'

# 测自己的 hostname WSS 是否可达
curl -sI https://1-2-3-4.sslip.io:8443/ | head -3   # 应是 HTTP 200 / Caddy

# 看 advertise 是否有发出
tail -f /var/log/opentube-helper.log | grep advertise
```

常见问题：

| 现象 | 可能原因 | 解 |
| --- | --- | --- |
| Caddy 起不来 / cert 拿不到 | 80/8443 端口被占 / 没开 | `ss -tlnp \| grep -E ':80\|:8443'`; ufw 放行 |
| `OT_P2P_PUBLIC_IP` 错 | 探测的是内网 IP（NAT VPS） | `curl ifconfig.me` 看真公网；`OT_P2P_PUBLIC_IP=...` 手设重装 |
| advertise 失败 `PeerID not initialized` | helper 启动一开始的瞬态 race | 等 60s 自动重试 |
| 客户端连不上 | 防火墙阻 80/8443/14001 / sslip.io 解析慢 | `nc -zv <ip> 8443`; 换 DoH 直拉 sslip.io  |

---

## 7. 不做的事

- **不**实现 volunteer peer 自动注册到 SignedPeerList — 那需要 council review，不该是无门槛 promote
- **不**给 volunteer peer 暴露 admin console / Foundation API — volunteer 用自己的 systemd 监管自己即可
- **不**收集 volunteer peer 信息（telemetry）— peer reputation 完全本地累积
- **不**强制 volunteer 加入 Discord / Slack 等 — 完全可以匿名贡献，只发 multiaddr 给朋友也算

---

谢谢贡献！🙏  问题 / 反馈：[github.com/yesyoufanstube/youfanstube/issues](https://github.com/yesyoufanstube/youfanstube/issues)
