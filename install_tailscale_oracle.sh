#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TAG="tag:srv-es-linux"
ENABLE_TAILSCALE_SSH="true"
ACCEPT_DNS="false"

TAG="${1:-$DEFAULT_TAG}"

echo "=========================================="
echo " Tailscale Oracle Linux Installer"
echo "=========================================="
echo "当前默认 tag: ${TAG}"
echo

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 执行，或使用：sudo bash $0"
  exit 1
fi

if [ ! -f /etc/os-release ]; then
  echo "错误：无法识别系统版本，未找到 /etc/os-release"
  exit 1
fi

. /etc/os-release
OL_MAJOR="${VERSION_ID%%.*}"

case "${OL_MAJOR}" in
  7|8|9)
    echo "检测到 Oracle Linux ${OL_MAJOR}"
    ;;
  *)
    echo "错误：当前脚本仅支持 Oracle Linux 7/8/9，检测到 VERSION_ID=${VERSION_ID}"
    exit 1
    ;;
esac

echo
echo "请输入 Tailscale auth key。输入时不会显示："
read -r -s AUTHKEY
echo

if [ -z "${AUTHKEY}" ]; then
  echo "错误：auth key 不能为空"
  exit 1
fi

if [[ "${AUTHKEY}" != tskey-auth-* ]]; then
  echo "警告：你输入的 auth key 看起来不像 tskey-auth- 开头，请确认是否正确。"
  echo "继续请输入 y，否则退出："
  read -r CONFIRM
  if [ "${CONFIRM}" != "y" ]; then
    echo "已退出"
    exit 1
  fi
fi

echo
echo "即将执行以下配置："
echo "Oracle Linux 版本: ${OL_MAJOR}"
echo "Tailscale tag: ${TAG}"
echo "开启 Tailscale SSH: ${ENABLE_TAILSCALE_SSH}"
echo "accept-dns: ${ACCEPT_DNS}"
echo
echo "确认继续请输入 y："
read -r CONFIRM

if [ "${CONFIRM}" != "y" ]; then
  echo "已取消"
  exit 1
fi

echo
echo "开始安装 Tailscale..."

if command -v dnf >/dev/null 2>&1; then
  dnf install -y dnf-plugins-core || true
  dnf config-manager --add-repo "https://pkgs.tailscale.com/stable/oracle/${OL_MAJOR}/tailscale.repo"
  dnf install -y tailscale
elif command -v yum >/dev/null 2>&1; then
  yum install -y yum-utils || true
  yum-config-manager --add-repo "https://pkgs.tailscale.com/stable/oracle/${OL_MAJOR}/tailscale.repo"
  yum install -y tailscale
else
  echo "错误：未找到 dnf 或 yum"
  exit 1
fi

echo
echo "启动 tailscaled..."
systemctl enable --now tailscaled

echo
echo "等待 tailscaled 就绪..."
sleep 2

UP_ARGS=(
  up
  "--auth-key=${AUTHKEY}"
  "--advertise-tags=${TAG}"
  "--accept-dns=${ACCEPT_DNS}"
)

if [ "${ENABLE_TAILSCALE_SSH}" = "true" ]; then
  UP_ARGS+=("--ssh")
fi

echo
echo "加入 Tailscale..."
tailscale "${UP_ARGS[@]}"

unset AUTHKEY

echo
echo "===== Tailscale 状态 ====="
tailscale status || true

echo
echo "===== Tailscale IPv4 ====="
tailscale ip -4 || true

echo
echo "完成。"
echo "请去 Tailscale 后台 Machines 页面确认这台机器显示 tag：${TAG}"
