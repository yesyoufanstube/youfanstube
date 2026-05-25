#!/usr/bin/env bash
# YouFansTube Helper Peer 一键安装（从 GitHub Release）
#
# ┌──────────────────────────────────────────────────────────────────┐
# │ 模式 A：Foundation 流程（admin 通过 console UI 触发）             │
# │   sudo PEER_HOSTNAME=peer3.youfanstube.com PEER_IPV4=1.2.3.4 \    │
# │        PEER_ID=3 PEER_TOKEN=<64hex> CONSOLE_URL=https://… bash    │
# │   - 域名由 Foundation 持有 + CF DNS                                │
# │   - 默认装 helper + Caddy + agent（一行命令搞定）                    │
# │   - Caddy lib 兼容 peer1 / peer2 已有手配的 Caddyfile（marker-based） │
# │   - 装完 admin 把 PeerID 进 console，Foundation 签 SignedPeerList   │
# │                                                                    │
# │ 模式 B：Volunteer 流程（任何人，零域名零 console 权限）              │
# │   sudo VOLUNTEER_MODE=1 bash                                       │
# │   - 自动拿公网 IP → <ip-with-dashes>.sslip.io 当 hostname            │
# │   - 装 helper + Caddy + 自动 ACME（sslip.io 是真实 DNS，能颁 cert）   │
# │   - 不装 agent（无 console 权限，无 token 可用）                     │
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
#   7. INSTALL_CADDY=1（默认）→ 调 lib/setup-helper-caddy.sh：apt install caddy
#      + 写 Caddyfile (marker-based，老 peer 已有手配 block 时保留) + ufw 80/8443
#   8. 若 PEER_TOKEN+PEER_ID+CONSOLE_URL 全设 → 顺便装 helper-agent（Foundation
#      场景一行命令 helper+caddy+agent 全装齐；volunteer 没 token 跳过）
#   9. 输出 multiaddr

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
INSTALL_CADDY=${INSTALL_CADDY:-1}    # 默认装 Caddy（Foundation + Volunteer 都装；
                                     # setup-helper-caddy.sh 自带"已有 hostname 块就跳过"
                                     # marker-based 兼容老 peer 已手配的 Caddyfile）
INSTALL_AGENT=${INSTALL_AGENT:-auto} # auto = 检测 PEER_TOKEN+PEER_ID+CONSOLE_URL 全
                                     # 设时装；显式 0 / 1 强制控制
INSTALL_MIHOMO=${INSTALL_MIHOMO:-1}   # 默认装 mihomo binary 备用（不启 service / 不配订阅）
                                     # 让 helper 默认就具备 proxy 能力,运营者后续跑
                                     # install-helper-proxy.sh 推订阅 + 启动才真正生效。
                                     # 装好后:/opt/yfs-helper-proxy/mihomo + systemd unit (disabled)
                                     # 设 INSTALL_MIHOMO=0 跳过(节省 ~30 MB 二进制 + 1 个 systemd unit)
MIHOMO_VERSION=${MIHOMO_VERSION:-v1.18.10}

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

# ─── 5.5. M7 一次性迁移：opentube-helper → youfanstube-helper ──
# 落实 [M7-CHANNEL-MODE.md §1.3](../../docs/specs/playbooks/M7-CHANNEL-MODE.md)
# 与客户端 [`migrateUserData.ts`](../../app/src/main/services/migrateUserData.ts) 服务端对应。
#
# 已迁移过（sentinel 存在）→ 仍 sweep 残留 .timer 防遗漏（早期版本只停 .service
# 漏了 .timer，导致 opentube-helper-agent.timer 一直在跑触发 oneshot service →
# console UI 报红假警报）。
# 老 helper 部署存在 → 停 / disable 旧 unit + 复制数据 + 写 sentinel。
# 老不存在 + 无 sentinel → 跳过（全新部署）。
OLD_INSTALL_DIR=/opt/opentube-helper
OLD_DATA_DIR=/var/lib/opentube-helper
# 含 service + timer 双形态的老 unit（agent / watchdog 都是 timer-triggered oneshot）
OLD_UNITS=(opentube-helper opentube-helper-agent opentube-watchdog)
MIGRATION_SENTINEL="$DATA_DIR/.migrated-from-opentube"

# 共享 sweep 函数：停 + disable 任何残留的 opentube-* .service / .timer
# sentinel 存在场景也跑（修旧版迁移漏停 .timer 的 bug）
sweep_legacy_units() {
  local found=0
  for unit in "${OLD_UNITS[@]}"; do
    for ext in service timer; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}\.${ext}"; then
        if systemctl is-active --quiet "${unit}.${ext}" 2>/dev/null \
           || systemctl is-enabled --quiet "${unit}.${ext}" 2>/dev/null; then
          systemctl stop "${unit}.${ext}" 2>/dev/null || true
          systemctl disable "${unit}.${ext}" 2>/dev/null || true
          echo "  ✓ stopped + disabled ${unit}.${ext}"
          found=1
        fi
      fi
    done
  done
  [ "$found" = "1" ] && systemctl daemon-reload 2>/dev/null || true
}

if [ -f "$MIGRATION_SENTINEL" ]; then
  echo "ⓘ migration already done (sentinel: $MIGRATION_SENTINEL) — sweep 残留 .timer 防遗漏"
  sweep_legacy_units
elif [ -d "$OLD_INSTALL_DIR" ] || [ -d "$OLD_DATA_DIR" ]; then
  echo "▶ M7 一次性迁移：opentube-helper → youfanstube-helper"

  # 停 / disable 旧 unit（含 .service + .timer）
  sweep_legacy_units

  # 复制（不是 mv）数据目录到新路径——保 PeerID / libp2p-key / cache。
  # 旧目录保留作 fallback，操作员确认后手动清理。
  if [ -d "$OLD_DATA_DIR" ] && [ ! -d "$DATA_DIR" ]; then
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR"
    cp -a "$OLD_DATA_DIR/." "$DATA_DIR/"
    echo "  ✓ copied $OLD_DATA_DIR/ → $DATA_DIR/"
  elif [ -d "$DATA_DIR" ]; then
    echo "  ⓘ $DATA_DIR 已存在，跳过数据复制（避免覆盖）"
  fi

  # Foundation 密钥目录（仅 Foundation 操作员机器有 / 普通 helper 不动）
  if [ -d "$HOME/.opentube-foundation" ] && [ ! -d "$HOME/.youfanstube-foundation" ]; then
    cp -a "$HOME/.opentube-foundation" "$HOME/.youfanstube-foundation"
    echo "  ✓ copied ~/.opentube-foundation/ → ~/.youfanstube-foundation/"
  fi

  # 写 sentinel（避免重复迁移）
  mkdir -p "$DATA_DIR"
  cat > "$MIGRATION_SENTINEL" <<EOF_SENTINEL
{
  "fromName": "opentube-helper",
  "toName": "youfanstube-helper",
  "migratedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "oldInstallDir": "$OLD_INSTALL_DIR",
  "oldDataDir": "$OLD_DATA_DIR",
  "oldServiceNames": ["${OLD_SERVICE_NAMES[0]}", "${OLD_SERVICE_NAMES[1]}"]
}
EOF_SENTINEL
  echo "  ✓ sentinel: $MIGRATION_SENTINEL"
  echo "  ⓘ 旧目录保留作 fallback。确认 youfanstube-helper.service 稳定运行后手动清理："
  echo "      sudo rm -rf $OLD_INSTALL_DIR $OLD_DATA_DIR"
fi

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

# ─── 8.5. 装 Caddy（共享 lib，Foundation + Volunteer 都跑）───
# Caddy 安装本身共享 lib/setup-helper-caddy.sh — deploy-helper-peer.sh dev CLI
# 路径也调同一份 lib，避免两边漂移。
# 本脚本是 curl|bash 流程，VPS 上没有本仓库；从 raw.githubusercontent 拉 lib
# （信任根与本脚本一致 — 都来自 ${RELEASE_REPO}/main）。
#
# lib 是 marker-based + idempotent：peer1 / peer2 已有手配的 Caddyfile（无 marker）
# 时，lib 检测到 hostname 已配 → 不动现有配置仅 reload。新 peer 走 fresh 写入或
# marker 替换路径。
if [ "$INSTALL_CADDY" = "1" ]; then
  if [ "$VOLUNTEER_MODE" = "1" ]; then
    echo "▶ Volunteer 模式：装 Caddy + 配 ACME（sslip.io）"
    CADDY_LANDING_HTML="<!DOCTYPE html><html><body>YouFansTube Volunteer Helper — see github.com/${RELEASE_REPO}</body></html>"
  else
    echo "▶ Foundation 模式：装 Caddy + 配 ACME（${PEER_HOSTNAME}）"
    CADDY_LANDING_HTML="<!DOCTYPE html><html><body>YouFansTube Foundation Helper Peer ${PEER_HOSTNAME}</body></html>"
  fi
  LIB_REF=${LIB_REF:-main}
  LIB_URL=${LIB_URL:-https://raw.githubusercontent.com/${RELEASE_REPO}/${LIB_REF}/scripts/foundation/lib/setup-helper-caddy.sh}
  CADDY_LANDING_HTML="$CADDY_LANDING_HTML" \
    PEER_HOSTNAME="$PEER_HOSTNAME" PEER_IPV4="$PEER_IPV4" P2P_WS_PORT="$P2P_WS_PORT" \
    bash <(curl -fsSL "$LIB_URL")

  # 14001（libp2p TCP）不属于 caddy lib 的范围；这里统一放行
  if command -v ufw >/dev/null; then
    ufw allow 14001/tcp >/dev/null 2>&1 || true
    echo "  ✓ ufw allow 14001 (libp2p TCP)"
  fi
fi

# ─── 8.6. 装 mihomo binary 备用（不启 service / 不配订阅）─────────
# 让新 helper 上线默认就具备 proxy 能力。运营者后续按需:
#   1. 本机建 ~/.youfanstube-foundation/proxy/<peer>.env 填订阅 URL
#   2. 跑 scripts/foundation/install-helper-proxy.sh <peer> --apply-drop-in
# install-helper-proxy.sh 会 scp config.yaml + enable+start mihomo + 切节点 + healthcheck
# 配套 toggle-helper-tier.sh 切 helper EXIT_UPSTREAM_PROXY drop-in
#
# 这里只做 idempotent 装 binary + 写 systemd unit (disabled):
# - 已有 mihomo binary 时跳过下载(允许 install-helper-proxy 强制 --reinstall 覆盖)
# - systemd unit 写好但不 enable 不 start,等运营者真要用时再 enable
# - /opt/yfs-helper-proxy/config.yaml 不写(空目录,等 install-helper-proxy 推订阅)
if [ "$INSTALL_MIHOMO" = "1" ]; then
  echo "▶ 装 mihomo binary 备用 (${MIHOMO_VERSION},不启 service)"
  MIHOMO_DIR=/opt/yfs-helper-proxy
  mkdir -p "$MIHOMO_DIR"
  case "$ARCH" in
    x64)   MIHOMO_M=amd64 ;;
    arm64) MIHOMO_M=arm64 ;;
    *) echo "  ! mihomo: unsupported arch=$ARCH,跳过"; MIHOMO_M="" ;;
  esac
  if [ -n "$MIHOMO_M" ]; then
    if [ ! -x "$MIHOMO_DIR/mihomo" ]; then
      MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${MIHOMO_M}-${MIHOMO_VERSION}.gz"
      if curl -sL "$MIHOMO_URL" -o "$MIHOMO_DIR/mihomo.gz"; then
        gunzip -f "$MIHOMO_DIR/mihomo.gz"
        chmod +x "$MIHOMO_DIR/mihomo"
        echo "  ✓ /opt/yfs-helper-proxy/mihomo 装好"
      else
        echo "  ! mihomo binary 下载失败 (不致命,helper 主流程继续) — 重试: INSTALL_MIHOMO=1 重跑本脚本"
        rm -f "$MIHOMO_DIR/mihomo.gz"
      fi
    else
      echo "  ✓ /opt/yfs-helper-proxy/mihomo 已存在,跳过"
    fi

    # systemd unit (disabled by default,等 install-helper-proxy 时 enable+start)
    # 防止误启时缺 config.yaml 报错,加 ConditionPathExists 守卫
    cat > /etc/systemd/system/yfs-helper-proxy.service <<UNIT
[Unit]
Description=mihomo SOCKS5 upstream for yfs-helper (managed by install-helper-proxy.sh)
After=network-online.target
Wants=network-online.target
# 没 config.yaml 时启动会 fail,加 Condition 让 systemctl start 直接 skip
ConditionPathExists=${MIHOMO_DIR}/config.yaml

[Service]
Type=simple
User=root
WorkingDirectory=${MIHOMO_DIR}
ExecStart=${MIHOMO_DIR}/mihomo -d ${MIHOMO_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    echo "  ✓ /etc/systemd/system/yfs-helper-proxy.service 写好 (disabled,等 install-helper-proxy 推 config.yaml 后 enable+start)"
    echo "  下一步: 运营者本机跑 scripts/foundation/install-helper-proxy.sh <peer-name> [--apply-drop-in]"
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
# 128 并发流(2026-05-12 上调,原 32)。理由见 scripts/foundation/deploy-helper-peer.sh
# 同段注释:单 SABR client 多 itag prefetch 在 32 下密集撞 STATUS_OVER_CAPACITY。
Environment=OT_HELPER_MAX_STREAMS=128
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
    # Foundation 模式 next-steps
    cat <<EOL
Next: 把 PeerID + IPv4 + hostname 录入 console (/peers/new)
EOL
  fi

  # ─── 10. 装 helper-agent（Foundation 一体化路径） ───────
  # 仅当 PEER_TOKEN + PEER_ID + CONSOLE_URL 三个 env 全设时装；缺任意 → 跳过
  # （volunteer 没 token；console 没传齐时 operator 后续手动装也行）
  SHOULD_INSTALL_AGENT=0
  if [ "$INSTALL_AGENT" = "auto" ]; then
    if [ -n "${PEER_ID:-}" ] && [ -n "${PEER_TOKEN:-}" ] && [ -n "${CONSOLE_URL:-}" ]; then
      SHOULD_INSTALL_AGENT=1
    fi
  elif [ "$INSTALL_AGENT" = "1" ]; then
    SHOULD_INSTALL_AGENT=1
  fi

  if [ "$SHOULD_INSTALL_AGENT" = "1" ]; then
    if [ -z "${PEER_ID:-}" ] || [ -z "${PEER_TOKEN:-}" ] || [ -z "${CONSOLE_URL:-}" ]; then
      echo "▶ INSTALL_AGENT=1 但缺 env: 需 PEER_ID + PEER_TOKEN + CONSOLE_URL — 跳过 agent 安装"
    else
      echo ""
      echo "▶ 装 helper-agent（PEER_ID=$PEER_ID, CONSOLE_URL=$CONSOLE_URL）"
      AGENT_INSTALLER_URL="https://raw.githubusercontent.com/${RELEASE_REPO}/${LIB_REF:-main}/scripts/foundation/install-helper-agent.sh"
      # 强制 install-helper-agent.sh 内部 REPO_RAW 也用 RELEASE_REPO 对齐——
      # 不传时它默认 zbspace01/youfanstube 这个 legacy mirror，可能拉不到 helper-agent.sh
      AGENT_REPO_RAW="https://github.com/${RELEASE_REPO}/raw/${LIB_REF:-main}"
      PEER_ID="$PEER_ID" PEER_HOSTNAME="$PEER_HOSTNAME" \
        PEER_TOKEN="$PEER_TOKEN" CONSOLE_URL="$CONSOLE_URL" \
        YOUFANSTUBE_REPO_RAW="$AGENT_REPO_RAW" \
        bash <(curl -fsSL "$AGENT_INSTALLER_URL")
      echo ""
      echo "✓ helper-agent 装齐 — console 60s 内会出现 metrics push"
    fi
  elif [ "$VOLUNTEER_MODE" != "1" ]; then
    cat <<EOL

ⓘ 没装 agent —— Foundation peer 推荐装上让 console 看到健康指标。
  在 console 该 peer 详情页 rotate token，复制一体化命令重跑此脚本即可。
EOL
  fi
else
  echo "✗ ${SERVICE_NAME}.service 启动失败 — see journalctl -u ${SERVICE_NAME}"
  exit 1
fi
