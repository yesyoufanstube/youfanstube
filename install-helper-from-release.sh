#!/usr/bin/env bash
# OpenTube Helper Peer 一键安装（从 GitHub Release）
#
# 在 helper peer VPS 上跑：
#   curl -fsSL https://raw.githubusercontent.com/yesyoufanstube/youfanstube/main/install-helper-from-release.sh \
#     | PEER_HOSTNAME=peer3.youfanstube.com PEER_IPV4=1.2.3.4 \
#       sudo bash
#
# 步骤：
#   1. 探测 arch (x86_64 → x64, aarch64 → arm64)
#   2. 下 helper-bundle-linux-<arch>.tar.gz + .sig.json from GitHub Release
#   3. 验 sha256（防传输损坏）
#   4. 验 ed25519 签名（防部署链投毒；trusted Foundation pubkey hardcoded 下方）
#   5. 解到 /opt/opentube-helper（备份现有 libp2p-key.bin）
#   6. 写 systemd unit + start

set -euo pipefail

# ─── 受信 Foundation 公钥（同 client app trustedSigners） ───
# PeerID 1AhjvaqGKX1ws3neeR8CazJeUfApUxKXCNnfNUQieiCfnx
# Algo:  ed25519
# 派生于 ~/.opentube-foundation/keys/foundation-bootstrap.seed (2026-05-06)
FOUNDATION_TRUSTED_PEERIDS=("1AhjvaqGKX1ws3neeR8CazJeUfApUxKXCNnfNUQieiCfnx")
FOUNDATION_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAqUcIj0RRs60cWYJFx0rLRPS3cSkNtGN4QFn999gls+k=
-----END PUBLIC KEY-----'

# ─── 配置（env 可覆写） ──────────────────────────────────
: "${PEER_HOSTNAME:?PEER_HOSTNAME required (e.g. peer3.youfanstube.com)}"
: "${PEER_IPV4:?PEER_IPV4 required (this VPS public ipv4)}"
RELEASE_TAG=${RELEASE_TAG:-v0.1.0-helper}
RELEASE_REPO=${RELEASE_REPO:-yesyoufanstube/youfanstube}
SERVICE_NAME=${SERVICE_NAME:-opentube-helper}
P2P_TCP_PORT=${P2P_TCP_PORT:-14001}
P2P_WS_PORT=${P2P_WS_PORT:-14002}
INSTALL_DIR=${INSTALL_DIR:-/opt/opentube-helper}
DATA_DIR=${DATA_DIR:-/var/lib/opentube-helper}
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
  printf 'opentube-helper-bundle-v1\n'
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

# ─── 9. 写 systemd unit + start ─────────────────────────
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=OpenTube Helper Peer (release: ${RELEASE_TAG} ${PLATFORM})
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
  PEERID=$(grep -oE '12D3KooW[a-zA-Z0-9]+' "/var/log/${SERVICE_NAME}.log" | tail -1 || echo "(pending)")
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "✓ Helper Peer installed + signed-verified"
  echo "════════════════════════════════════════════════════════════"
  echo "  PeerID:    $PEERID"
  echo "  release:   $RELEASE_TAG"
  echo "  systemd:   systemctl status ${SERVICE_NAME}"
  echo "  log:       tail -f /var/log/${SERVICE_NAME}.log"
  echo ""
  echo "Next: 把 PeerID + IPv4 + hostname 录入 console (/peers/new)"
else
  echo "✗ ${SERVICE_NAME}.service 启动失败 — see journalctl -u ${SERVICE_NAME}"
  exit 1
fi
