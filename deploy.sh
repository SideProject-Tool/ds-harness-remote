#!/usr/bin/env bash
# 自部署 DSH Remote Server 发布脚本（控制机执行，勿在目标机构建）
#
#   控制机构建镜像 → docker save|gzip|ssh load → 切换远端 compose 的 image tag
#   → docker compose up -d --force-recreate → 公网校验
#
# 用法：
#   ./deploy.sh                     # tag 自动生成：<根 package 版本>-g<短 SHA>[-dirty]
#   ./deploy.sh --tag 0.6.3-custom2 # 指定 tag
#   ./deploy.sh --skip-build        # 复用本机已有镜像（只做传输、切换、校验）
#   ./deploy.sh --no-verify         # 跳过公网校验
#   ./deploy.sh --dry-run           # 只打印计划，不构建不部署
#
# 环境变量：
#   DEPLOY_SSH        目标机 ssh 别名/地址（默认 papamemo = 47.98.121.243）
#   DEPLOY_REMOTE_DIR 目标机部署目录（默认 /opt/dsh-remote-server）
#   PUBLIC_URL        公网地址（默认 https://remote.papafeiji.cn，仅用于校验）
#   KEEP_LOCAL_TAR    1 = 保留本机导出的镜像包（默认删除）
set -euo pipefail

SSH_TARGET="${DEPLOY_SSH:-papamemo}"
REMOTE_DIR="${DEPLOY_REMOTE_DIR:-/opt/dsh-remote-server}"
PUBLIC_URL="${PUBLIC_URL:-https://remote.papafeiji.cn}"
DOCKERFILE="apps/server/Dockerfile"

BUILD=1
VERIFY=1
DRY_RUN=0
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:?--tag 需要一个值}"; shift 2 ;;
    --skip-build) BUILD=0; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1（--help 查看用法）" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 前置检查 ---------------------------------------------------------------
command -v docker >/dev/null || die "找不到 docker"
[[ -f "$DOCKERFILE" ]] || die "请在仓库根目录运行（缺少 $DOCKERFILE）"

if [[ -z "$TAG" ]]; then
  # 用仓库根版本（产品版本，如 0.6.3）而非 apps/server 的包版本（0.5.21），与线上 tag 习惯一致
  VERSION="$(python3 -c 'import json;print(json.load(open("package.json"))["version"])' 2>/dev/null || echo 0.0.0)"
  SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
  DIRTY=""
  if ! git diff --quiet HEAD -- 2>/dev/null; then DIRTY="-dirty"; fi
  TAG="${VERSION}-g${SHA}${DIRTY}"
fi
IMAGE="dsh-remote-server:${TAG}"

log "目标机        : $SSH_TARGET:$REMOTE_DIR"
log "镜像 tag      : $IMAGE"
log "校验地址      : $PUBLIC_URL"

if [[ $BUILD -eq 0 && -z "$(docker image ls -q "$IMAGE" 2>/dev/null)" ]]; then
  die "本机没有镜像 $IMAGE，不能 --skip-build"
fi
if [[ $DRY_RUN -eq 1 ]]; then
  log "dry-run：只显示计划，不执行"
  exit 0
fi

# --- 构建 -------------------------------------------------------------------
if [[ $BUILD -eq 1 ]]; then
  log "构建镜像（控制机，node:22-alpine + npmmirror）"
  docker build -f "$DOCKERFILE" -t "$IMAGE" .
  # 构建产物自检：确保自托管补丁确实进了镜像
  docker run --rm --entrypoint sh "$IMAGE" -c \
    "grep -q 'devices/rename' dist/server.js && grep -q \"startsWith('/app/')\" dist/server.js" \
    || die "镜像自检失败：自托管补丁不在 dist/server.js 里"
  log "镜像自检通过"
fi

# --- 传输 -------------------------------------------------------------------
TARBALL="$(mktemp -t dsh-remote-image.XXXXXX.tar.gz)"
log "打包并传输镜像（$(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}')）"
docker save "$IMAGE" | gzip -1 > "$TARBALL"
ssh "$SSH_TARGET" "gunzip -c | docker load" < "$TARBALL"
rm -f "$TARBALL"

# --- 切换 -------------------------------------------------------------------
PREV_IMAGE="$(ssh "$SSH_TARGET" "grep -m1 '^    image:' '$REMOTE_DIR/compose.yaml' | awk '{print \$2}'" || true)"
log "远端当前镜像 : ${PREV_IMAGE:-未知}"

ssh "$SSH_TARGET" "set -e
  cd '$REMOTE_DIR'
  cp -f compose.yaml compose.yaml.bak.\$(date +%Y%m%d-%H%M%S)
  sed -i 's|^    image: .*|    image: $IMAGE|' compose.yaml
  docker compose up -d --force-recreate server >/dev/null
  echo swapped"

log "等待容器 healthy"
for i in $(seq 1 40); do
  STATUS="$(ssh "$SSH_TARGET" "docker inspect -f '{{.State.Health.Status}}' \$(docker compose -f '$REMOTE_DIR/compose.yaml' ps -q server) 2>/dev/null" || true)"
  [[ "$STATUS" == "healthy" ]] && break
  sleep 3
  [[ $i -eq 40 ]] && { warn "容器未在 120s 内 healthy（最后状态: ${STATUS:-unknown}）"; }
done

# --- 校验 -------------------------------------------------------------------
if [[ $VERIFY -eq 1 ]]; then
  log "公网校验 $PUBLIC_URL"
  fail=0
  for path in / /app/login /app/remote; do
    code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "$PUBLIC_URL$path" || echo 000)"
    printf '   %-14s %s\n' "$path" "$code"
    [[ "$code" == "200" ]] || fail=1
  done
  hz="$(curl -sS -m 15 "$PUBLIC_URL/healthz" || true)"
  printf '   %-14s %s\n' "/healthz" "$hz"
  [[ "$hz" == *'"ok"'* ]] || fail=1

  asset="$(curl -sS -m 15 "$PUBLIC_URL/" | grep -o 'assets/index-[^"]*\.js' | head -1 || true)"
  if [[ -n "$asset" ]]; then
    curl -sS -m 20 "$PUBLIC_URL/$asset" -o /tmp/dsh-remote-asset.$$.js
    if grep -q 'devices/rename' /tmp/dsh-remote-asset.$$.js; then
      printf '   %-14s %s（含自托管补丁）\n' "$asset" ok
    else
      printf '   %-14s %s（缺少自托管补丁！）\n' "$asset" FAIL
      fail=1
    fi
    rm -f /tmp/dsh-remote-asset.$$.js
  fi

  if [[ $fail -ne 0 ]]; then
    warn "校验未通过；回滚命令："
    echo "  ssh $SSH_TARGET \"sed -i 's|^    image: .*|    image: ${PREV_IMAGE:-<旧tag>}|' $REMOTE_DIR/compose.yaml && cd $REMOTE_DIR && docker compose up -d --force-recreate server\""
    exit 1
  fi
fi

log "发布完成：$IMAGE"
[[ -n "$PREV_IMAGE" && "$PREV_IMAGE" != "$IMAGE" ]] && echo "   回滚：ssh $SSH_TARGET \"sed -i 's|^    image: .*|    image: $PREV_IMAGE|' $REMOTE_DIR/compose.yaml && cd $REMOTE_DIR && docker compose up -d --force-recreate server\""
echo "   日志：ssh $SSH_TARGET 'cd $REMOTE_DIR && docker compose logs -f --tail 100 server'"
