#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TAG="tag:srv-es-linux"
DEFAULT_ACCEPT_DNS="false"
TAILSCALE_REPO_ID="tailscale-stable"

TAG="${1:-$DEFAULT_TAG}"
ACCEPT_DNS="${ACCEPT_DNS:-$DEFAULT_ACCEPT_DNS}"

echo "=========================================="
echo " Tailscale Oracle Linux Installer"
echo "=========================================="
echo "默认/当前 tag: ${TAG}"
echo "accept-dns: ${ACCEPT_DNS}"
echo

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 执行，例如：sudo bash $0"
  exit 1
fi

if [ ! -f /etc/os-release ]; then
  echo "错误：未找到 /etc/os-release，无法识别系统。"
  exit 1
fi

. /etc/os-release
OL_MAJOR="${VERSION_ID%%.*}"

case "${OL_MAJOR}" in
  7|8|9|10)
    echo "检测到 Oracle Linux ${OL_MAJOR}"
    ;;
  *)
    echo "错误：当前脚本仅支持 Oracle Linux 7/8/9/10，检测到 VERSION_ID=${VERSION_ID}"
    exit 1
    ;;
esac

echo
echo "请输入 Tailscale auth key。输入时不会显示："
read -r -s TS_AUTHKEY
echo

if [ -z "${TS_AUTHKEY}" ]; then
  echo "错误：auth key 不能为空。"
  exit 1
fi

if [[ "${TS_AUTHKEY}" != tskey-auth-* ]]; then
  echo "警告：auth key 看起来不是 tskey-auth- 开头。"
  echo "确认继续请输入 y："
  read -r CONFIRM_KEY
  if [ "${CONFIRM_KEY}" != "y" ]; then
    echo "已取消。"
    exit 1
  fi
fi

echo
echo "即将执行："
echo "Oracle Linux: ${OL_MAJOR}"
echo "Tailscale tag: ${TAG}"
echo "Tailscale SSH: enabled"
echo "Tailscale repo only install: yes"
echo
echo "确认继续请输入 y："
read -r CONFIRM

if [ "${CONFIRM}" != "y" ]; then
  echo "已取消。"
  exit 1
fi

REPO_URL="https://pkgs.tailscale.com/stable/oracle/${OL_MAJOR}/tailscale.repo"
REPO_FILE="/etc/yum.repos.d/tailscale.repo"

echo
echo "1/5 下载 Tailscale repo 文件..."
echo "${REPO_URL}"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 20 --max-time 60 -o "${REPO_FILE}" "${REPO_URL}"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "${REPO_FILE}" "${REPO_URL}"
else
  echo "错误：未找到 curl 或 wget，无法下载 repo 文件。"
  exit 1
fi

if [ ! -s "${REPO_FILE}" ]; then
  echo "错误：repo 文件下载失败或为空：${REPO_FILE}"
  exit 1
fi

echo
echo "2/5 确认 Tailscale repo id..."
if grep -q "^\[tailscale-stable\]" "${REPO_FILE}"; then
  TAILSCALE_REPO_ID="tailscale-stable"
else
  TAILSCALE_REPO_ID="$(grep -m1 '^\[' "${REPO_FILE}" | tr -d '[]' || true)"
fi

if [ -z "${TAILSCALE_REPO_ID}" ]; then
  echo "错误：无法识别 Tailscale repo id。"
  cat "${REPO_FILE}"
  exit 1
fi

echo "Tailscale repo id: ${TAILSCALE_REPO_ID}"

echo
echo "3/5 安装 Tailscale，只启用 Tailscale 仓库，避免 Oracle 仓库超时..."

PKG_MGR=""
if command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
else
  echo "错误：未找到 dnf 或 yum。"
  exit 1
fi

set +e
${PKG_MGR} install -y tailscale \
  --disablerepo='*' \
  --enablerepo="${TAILSCALE_REPO_ID}"
INSTALL_RC=$?
set -e

if [ "${INSTALL_RC}" -ne 0 ]; then
  echo
  echo "仅启用 Tailscale 仓库安装失败，开始 fallback。"
  echo "fallback 会禁用常见超时仓库：ol8_ksplice、ol8_MySQL80、ol7_ksplice、ol7_MySQL80、ol9_ksplice、ol9_MySQL80。"
  echo

  ${PKG_MGR} install -y tailscale \
    --disablerepo=ol7_ksplice \
    --disablerepo=ol7_MySQL80 \
    --disablerepo=ol8_ksplice \
    --disablerepo=ol8_MySQL80 \
    --disablerepo=ol9_ksplice \
    --disablerepo=ol9_MySQL80 \
    --setopt=timeout=20 \
    --setopt=retries=1
fi

echo
echo "4/5 启动 tailscaled..."
systemctl enable --now tailscaled

sleep 2

if ! systemctl is-active --quiet tailscaled; then
  echo "错误：tailscaled 未正常启动。"
  systemctl status tailscaled --no-pager || true
  exit 1
fi

echo
echo "5/5 加入 Tailscale，并开启 Tailscale SSH..."

tailscale up \
  --auth-key="${TS_AUTHKEY}" \
  --advertise-tags="${TAG}" \
  --ssh \
  --accept-dns="${ACCEPT_DNS}"

unset TS_AUTHKEY

echo
echo "===== Tailscale 状态 ====="
tailscale status || true

echo
echo "===== Tailscale IPv4 ====="
tailscale ip -4 || true

echo
echo "完成。"
echo "请到 Tailscale 后台 Machines 页面确认这台机器显示 tag：${TAG}"
echo
echo "本地测试示例："
echo "  ssh opc@机器名"
echo "  ssh root@机器名"
