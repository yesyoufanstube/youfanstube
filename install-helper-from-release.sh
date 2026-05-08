#!/usr/bin/env bash
# YouFansTube Helper Peer 一键安装（从 GitHub Release）
#
# ┌──────────────────────────────────────────────────────────────────┐
# │ 模式 A：Foundation 流程（admin 通过 console wizard 触发）         │
# │   sudo PEER_HOSTNAME=peer3.youfanstube.com PEER_IPV4=1.2.3.4 bash  │
# │   - 域名由 Foundation 持有 + CF DNS                                │
# │   - 不在脚本里装 Caddy，Foundation peer VPS 已经装过                 │
# │   - 装完 admin 把 PeerID 进 console，Foundation 签 SignedPeerList   │
# │                                                                    │
# │ 模式 B：Volunteer 流程（任何人，零域名零 console 权限）              │
# │   sudo VOLUNTEER_MODE=1 bash                                       │
# │   - 自动拿公网 IP → <ip-with-dashes>.sslip.io 当 hostname            │
# │   - 顺便装 Caddy + 自动 ACME（sslip.io 是真实 DNS，能颁 cert）        │
# │   - bind libp2p WS 到 localhost:14002，Caddy 反代 :8443 → :14002    │
# │   - 不进 SignedPeerList — 通过 GossipSub exitNodeAdvertise 自播     │
# │   - 客户端先连 Foundation peers（Bootstrap），通过 mesh 学到你         │
# │   - reputation 累积良好 → Foundation 可能 promote 进 SignedPeerList │
# └──────────────────────────────────────────────────────────────────┘
#
# 共同步骤：
#   1. 探测 arch (x86_64 → x64, aarch64 → arm64)
#   2. 下 helper-bundle-linux-<arch>.tar.gz + .sig.json from GitHub Release
#   3. 验 sha256（防传输损坏）
#   4. 验 ed25519 签名（防部署链投毒；trusted Foundation pubkey hardcoded 下方）
#   5. 解到 /opt/youfanstube-helper（备份现有 libp2p-key.bin）
#   6. 写 systemd unit + start
#
# Volunteer 额外步骤：
#   7. apt install caddy + 写 Caddyfile + ufw allow 8443/14001/80
#   8. 输出 multiaddr / 让 volunteer 分享给朋友 / 加进个人 settings

set -euo pipefail

# ─── 受信 Foundation 公钥（同 client app trustedSigners） ───
# PeerID 1AhjvaqGKX1ws3neeR8CazJeUfApUxKXCNnfNUQieiCfnx
# Algo:  ed25519
# 派生于 ~/.youfanstube-foundation/keys/foundation-bootstrap.seed (2026-05-06)
FOUNDATION_TRUSTED_PEERIDS=("1AhjvaqGKX1ws3neeR8CazJeUfApUxKXCNnfNUQieiCfnx")
FOUNDATION_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAqUcIj0RRs60cWYJFx0rLRPS3cSkNtGN4QFn999gls+k=
-----END PUBLIC KEY-----'

# ─── 配置（env 可覆写） ──────────────────────────────────
VOLUNTEER_MODE=${VOLUNTEER_MODE:-0}

# Volunteer 模式：自动拿公网 IP → sslip.io hostname；其它字段后面再 default
if [ "$VOLUNTEER_MODE" = "1" ]; then
  if [ -z "${PEER_IPV4:-}" ]; then
    echo "▶ 自动探测公网 IPv4..."
    # 三个独立 echo IP 的服务，任一成功即可（避免单点）
    for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
      PEER_IPV4=$(curl -fsSL --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]')
      [ -n "${PEER_IPV4:-}" ] && echo "  $url → $PEER_IPV4" && break
    done
    if [ -z "${PEER_IPV4:-}" ]; then
      echo "✗ 拿不到公网 IP — 手动设 PEER_IPV4=1.2.3.4 重跑"
      exit 1
    fi
  fi
  if [ -z "${PEER_HOSTNAME:-}" ]; then
    PEER_HOSTNAME="${PEER_IPV4//./-}.sslip.io"
    echo "▶ Volunteer hostname：$PEER_HOSTNAME（sslip.io 通用解析，不需配 DNS）"
  fi
fi

: "${PEER_HOSTNAME:?PEER_HOSTNAME required (Foundation 流程：peer3.youfanstube.com / Volunteer 流程：跑 VOLUNTEER_MODE=1 自动)}"
: "${PEER_IPV4:?PEER_IPV4 required (this VPS public ipv4)}"
RELEASE_TAG=${RELEASE_TAG:-v0.1.0-helper}
RELEASE_REPO=${RELEASE_REPO:-yesyoufanstube/youfanstube}
SERVICE_NAME=${SERVICE_NAME:-youfanstube-helper}
P2P_TCP_PORT=${P2P_TCP_PORT:-14001}
P2P_WS_PORT=${P2P_WS_PORT:-14002}
INSTALL_DIR=${INSTALL_DIR:-/opt/youfanstube-helper}
DATA_DIR=${DATA_DIR:-/var/lib/youfanstube-helper}
PRESERVE_PEERID=${PRESERVE_PEERID:-1}

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ 需要 root（systemd unit + /opt 写入）"
  exit 1
fi

# ─── 1. arch 探测 ──────────────────────────────────────
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64)  ARCH=x64   ;;
  aarch64) ARCH=arm64 ;;
  arm64)   ARCH=arm64 ;;
  *) echo "✗ 不支持的 arch: $HOST_ARCH"; exit 1 ;;
esac
PLATFORM="linux-${ARCH}"
TARBALL_NAME="helper-bundle-${PLATFORM}.tar.gz"
SIG_NAME="${TARBALL_NAME}.sig.json"
BASE_URL="https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}"

echo "▶ Helper Peer install"
echo "  arch:        $HOST_ARCH → $ARCH"
echo "  release:     $RELEASE_TAG @ $RELEASE_REPO"
echo "  hostname:    $PEER_HOSTNAME"
echo "  ipv4:        $PEER_IPV4"
echo "  ports:       TCP=$P2P_TCP_PORT WS=$P2P_WS_PORT"

# ─── 2. apt deps（最小：curl、jq、openssl，几乎所有发行版都已自带）──
need_pkgs=()
command -v curl >/dev/null    || need_pkgs+=(curl)
command -v jq >/dev/null      || need_pkgs+=(jq)
command -v openssl >/dev/null || need_pkgs+=(openssl)
command -v sha256sum >/dev/null || need_pkgs+=(coreutils)
if [ ${#need_pkgs[@]} -gt 0 ]; then
  echo "▶ apt install ${need_pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${need_pkgs[@]}" 2>&1 | tail -3
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ─── 3. 下 tarball + sig ────────────────────────────────
echo "▶ download $TARBALL_NAME"
curl -fsSL --output "$TMPDIR/$TARBALL_NAME" "$BASE_URL/$TARBALL_NAME"
echo "▶ download $SIG_NAME"
curl -fsSL --output "$TMPDIR/$SIG_NAME" "$BASE_URL/$SIG_NAME"

# ─── 4. 验 sha256 ───────────────────────────────────────
EXPECTED_SHA=$(jq -r .sha256 "$TMPDIR/$SIG_NAME")
ACTUAL_SHA=$(sha256sum "$TMPDIR/$TARBALL_NAME" | awk '{print $1}')
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  echo "✗ sha256 mismatch:"
  echo "  expected $EXPECTED_SHA"
  echo "  actual   $ACTUAL_SHA"
  exit 1
fi
echo "✓ sha256 ok ($ACTUAL_SHA)"

# ─── 5. 验 ed25519 签名 ─────────────────────────────────
SIGNER_PEERID=$(jq -r .signerPeerId "$TMPDIR/$SIG_NAME")
TRUSTED=0
for p in "${FOUNDATION_TRUSTED_PEERIDS[@]}"; do
  [ "$SIGNER_PEERID" = "$p" ] && TRUSTED=1 && break
done
if [ "$TRUSTED" -ne 1 ]; then
  echo "✗ signerPeerId 不在受信列表: $SIGNER_PEERID"
  echo "  trusted: ${FOUNDATION_TRUSTED_PEERIDS[*]}"
  exit 1
fi

# 重建 SUBJECT 行（与 sign-bundle.mjs::buildSubject 必须逐字节等价）
NAME=$(jq -r .name "$TMPDIR/$SIG_NAME")
VERSION=$(jq -r .version "$TMPDIR/$SIG_NAME")
SIG_PLATFORM=$(jq -r .platform "$TMPDIR/$SIG_NAME")
SHA256=$(jq -r .sha256 "$TMPDIR/$SIG_NAME")
SIZE=$(jq -r .size "$TMPDIR/$SIG_NAME")
BUILT_AT=$(jq -r .builtAt "$TMPDIR/$SIG_NAME")
{
  printf 'youfanstube-helper-bundle-v1\n'
  printf 'name=%s\n' "$NAME"
  printf 'version=%s\n' "$VERSION"
  printf 'platform=%s\n' "$SIG_PLATFORM"
  printf 'sha256=%s\n' "$SHA256"
  printf 'size=%s\n' "$SIZE"
  printf 'builtAt=%s\n' "$BUILT_AT"
  printf 'signerPeerId=%s\n' "$SIGNER_PEERID"
} > "$TMPDIR/subject.txt"

# 校验：sig.json 内嵌的 subject 字段必须跟我们重建的一致（防攻击者改字段保留 subject）
EMBEDDED=$(jq -r .subject "$TMPDIR/$SIG_NAME")
if [ "$EMBEDDED" != "$(cat $TMPDIR/subject.txt)" ]; then
  echo "✗ sig.json 内嵌 subject 跟字段重建不一致 — 攻击者改了字段没重新签"
  exit 1
fi

# 写 trusted PEM + decode signature
echo "$FOUNDATION_PEM" > "$TMPDIR/trusted.pem"
jq -r .signature "$TMPDIR/$SIG_NAME" | base64 -d > "$TMPDIR/sig.bin"

# openssl ed25519 verify（rawin 模式不再做 hash，原文直接验）
if ! openssl pkeyutl -verify -pubin -inkey "$TMPDIR/trusted.pem" -rawin -in "$TMPDIR/subject.txt" -sigfile "$TMPDIR/sig.bin" >/dev/null 2>&1; then
  echo "✗ ed25519 签名验证失败"
  exit 1
fi
echo "✓ ed25519 ok（signer ${SIGNER_PEERID:0:12}…）"

# ─── 6. 备份 libp2p-key（保 PeerID） ─────────────────────
KEY_BACKUP=""
if [ "$PRESERVE_PEERID" = "1" ] && [ -f "$DATA_DIR/libp2p-key.bin" ]; then
  KEY_BACKUP=$(mktemp)
  cp -p "$DATA_DIR/libp2p-key.bin" "$KEY_BACKUP"
  echo "✓ backed up libp2p-key.bin"
fi

# ─── 7. 停 service + 解 tarball ─────────────────────────
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  systemctl stop "${SERVICE_NAME}.service" || true
fi
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
chmod 700 "$DATA_DIR"
find "$INSTALL_DIR" -mindepth 1 -delete
tar -xzf "$TMPDIR/$TARBALL_NAME" -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/node"
echo "✓ extracted to $INSTALL_DIR"

# ─── 8. 还原 libp2p-key ────────────────────────────────
if [ -n "$KEY_BACKUP" ]; then
  cp -p "$KEY_BACKUP" "$DATA_DIR/libp2p-key.bin"
  chmod 600 "$DATA_DIR/libp2p-key.bin"
  rm "$KEY_BACKUP"
fi

# ─── 8.5. Volunteer 模式：装 Caddy + Caddyfile + ufw ────
if [ "$VOLUNTEER_MODE" = "1" ]; then
  echo "▶ Volunteer 模式：装 Caddy + 配 sslip.io ACME"

  if ! command -v caddy >/dev/null; then
    echo "  ⌥ apt install caddy（用 Cloudsmith 官方源）"
    apt-get install -qq -y debian-keyring debian-archive-keyring apt-transport-https gpg 2>&1 | tail -3
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -qq 2>&1 | tail -3
    DEBIAN_FRONTEND=noninteractive apt-get install -qq -y caddy 2>&1 | tail -3
  fi

  # 写最小 Caddyfile —— 单 host: <ip>.sslip.io:8443 反代 WS → :14002，
  # 同时做静态根目录给 /speedtest 之类 health probe 用
  CADDY_EMAIL=${CADDY_EMAIL:-volunteer-${PEER_IPV4//./-}@noreply.sslip.io}
  cat > /etc/caddy/Caddyfile <<CADDY
{
    email ${CADDY_EMAIL}
    https_port 8443
    http_port 80
}

${PEER_HOSTNAME}:8443 {
    @websockets {
        header_regexp Connection (?i)upgrade
        header_regexp Upgrade (?i)websocket
    }
    handle @websockets {
        reverse_proxy 127.0.0.1:${P2P_WS_PORT} {
            flush_interval -1
            transport http {
                versions 1.1
            }
        }
    }
    handle {
        header Content-Type text/html
        respond "<!DOCTYPE html><html><body>YouFansTube Volunteer Helper — see github.com/${RELEASE_REPO}</body></html>" 200
    }
}
CADDY
  systemctl enable --now caddy 2>&1 | tail -3 || systemctl restart caddy
  echo "  ✓ Caddy 配好（ACME 会在后台拿 cert，~30s 内完成）"

  # ufw 开端口：8443 (Caddy WSS)、14001 (libp2p TCP)、80 (ACME http-01 challenge)
  if command -v ufw >/dev/null; then
    for port in 80 8443 14001; do
      ufw allow ${port}/tcp >/dev/null 2>&1 || true
    done
    echo "  ✓ ufw allow 80/8443/14001"
  else
    echo "  ⚠ 没 ufw — 自己确保 80/8443/14001 出入站放行"
  fi
fi

# ─── 9. 写 systemd unit + start ─────────────────────────
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=YouFansTube Helper Peer (release: ${RELEASE_TAG} ${PLATFORM})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=OT_HELPER_DATA_DIR=${DATA_DIR}
Environment=OT_P2P_DISABLE_BOOTSTRAP=1
Environment=OT_P2P_LISTEN_TCP=${P2P_TCP_PORT}
Environment=OT_P2P_LISTEN_WS=${P2P_WS_PORT}
Environment=OT_P2P_PUBLIC_IP=${PEER_IPV4}
Environment=OT_P2P_WS_LOCALHOST_ONLY=1
Environment=OT_HELPER_EXIT_ENABLED=1
Environment=OT_HELPER_MAX_STREAMS=32
Environment=OT_HELPER_BYTES_PER_SEC=52428800
ExecStart=${INSTALL_DIR}/node ${INSTALL_DIR}/helper.mjs
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/log/${SERVICE_NAME}.log
StandardError=append:/var/log/${SERVICE_NAME}.log
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"
sleep 4

if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
  echo "✓ ${SERVICE_NAME}.service active"
  # 抓自己的 PeerID — 必须是 "Helia + libp2p ready, peerId: ..." 那行（其他行
  # 可能是远程 peer 提示，会误匹配）
  PEERID=$(grep -oE 'libp2p ready, peerId: 12D3KooW[a-zA-Z0-9]+' "/var/log/${SERVICE_NAME}.log" 2>/dev/null \
    | tail -1 | grep -oE '12D3KooW[a-zA-Z0-9]+' || echo "(pending — tail /var/log/${SERVICE_NAME}.log)")
  MULTIADDR="/dns4/${PEER_HOSTNAME}/tcp/8443/tls/ws/p2p/${PEERID}"

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "✓ Helper Peer installed + signed-verified"
  echo "════════════════════════════════════════════════════════════"
  echo "  PeerID:    $PEERID"
  echo "  hostname:  $PEER_HOSTNAME"
  echo "  release:   $RELEASE_TAG"
  echo "  systemd:   systemctl status ${SERVICE_NAME}"
  echo "  log:       tail -f /var/log/${SERVICE_NAME}.log"
  echo ""
  echo "  multiaddr:"
  echo "    $MULTIADDR"
  echo ""

  if [ "$VOLUNTEER_MODE" = "1" ]; then
    cat <<EOL
🎉 你已经是 Volunteer Helper Peer！

下一步（30 秒内 Caddy 会拿到 sslip.io cert）：
  1. 等 ~30s，验证 cert：
       curl -sI https://${PEER_HOSTNAME}:8443/ | head
  2. 你的 helper 会自动发 GossipSub 'youfanstube/exit-node-advertise/v1' 公告
     —— 客户端连上 Foundation peer 后会通过 mesh 学到你
  3. （可选）把 multiaddr 分享给朋友 / 加进他们的客户端 settings：
       Settings → Bootstrap → "添加自定义 multiaddr"
  4. 监控自己服务质量：
       tail -f /var/log/${SERVICE_NAME}.log | grep -iE 'connect|exit|stream'
  5. 长期表现良好（>30 天 / 高可用）→ 联系 Foundation 申请进 SignedPeerList

谢谢贡献！🙏  问题/反馈：github.com/${RELEASE_REPO}/issues
EOL
  else
    cat <<EOL
Next: 把 PeerID + IPv4 + hostname 录入 console (/peers/new)
EOL
  fi
else
  echo "✗ ${SERVICE_NAME}.service 启动失败 — see journalctl -u ${SERVICE_NAME}"
  exit 1
fi
