#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TAG="tag:srv-es-linux"
DEFAULT_ACCEPT_DNS="false"
TAILSCALE_REPO_ID="tailscale-stable"

TAG="${1:-$DEFAULT_TAG}"
ACCEPT_DNS="${ACCEPT_DNS:-$DEFAULT_ACCEPT_DNS}"

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --max-time 60 -o "${output}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "${output}" "${url}"
  else
    echo "错误：未找到 curl 或 wget，无法下载文件。"
    exit 1
  fi
}

install_on_rpm_linux() {
  local repo_family="$1"
  local rpm_major="$2"
  local repo_url="https://pkgs.tailscale.com/stable/${repo_family}/${rpm_major}/tailscale.repo"
  local repo_file="/etc/yum.repos.d/tailscale.repo"
  local pkg_mgr=""
  local install_rc=0

  echo
  echo "1/5 下载 Tailscale repo 文件..."
  echo "${repo_url}"
  download_file "${repo_url}" "${repo_file}"

  if [ ! -s "${repo_file}" ]; then
    echo "错误：repo 文件下载失败或为空：${repo_file}"
    exit 1
  fi

  echo
  echo "2/5 确认 Tailscale repo id..."
  if grep -q "^\[tailscale-stable\]" "${repo_file}"; then
    TAILSCALE_REPO_ID="tailscale-stable"
  else
    TAILSCALE_REPO_ID="$(grep -m1 '^\[' "${repo_file}" | tr -d '[]' || true)"
  fi

  if [ -z "${TAILSCALE_REPO_ID}" ]; then
    echo "错误：无法识别 Tailscale repo id。"
    cat "${repo_file}"
    exit 1
  fi

  echo "Tailscale repo id: ${TAILSCALE_REPO_ID}"

  echo
  echo "3/5 安装 Tailscale，只启用 Tailscale 仓库，避免 Oracle 仓库超时..."
  if command -v dnf >/dev/null 2>&1; then
    pkg_mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then
    pkg_mgr="yum"
  else
    echo "错误：未找到 dnf 或 yum。"
    exit 1
  fi

  set +e
  "${pkg_mgr}" install -y tailscale \
    --disablerepo='*' \
    --enablerepo="${TAILSCALE_REPO_ID}"
  install_rc=$?
  set -e

  if [ "${install_rc}" -ne 0 ]; then
    echo
    echo "仅启用 Tailscale 仓库安装失败，开始 fallback。"
    echo "fallback 会禁用常见超时仓库：ol8_ksplice、ol8_MySQL80、ol7_ksplice、ol7_MySQL80、ol9_ksplice、ol9_MySQL80。"
    "${pkg_mgr}" install -y tailscale \
      --disablerepo=ol7_ksplice \
      --disablerepo=ol7_MySQL80 \
      --disablerepo=ol8_ksplice \
      --disablerepo=ol8_MySQL80 \
      --disablerepo=ol9_ksplice \
      --disablerepo=ol9_MySQL80 \
      --setopt=timeout=20 \
      --setopt=retries=1
  fi
}

install_on_ubuntu() {
  local codename="$1"
  local keyring_dir="/usr/share/keyrings"
  local keyring_file="${keyring_dir}/tailscale-archive-keyring.gpg"
  local source_file="/etc/apt/sources.list.d/tailscale.list"
  local key_url="https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg"
  local source_url="https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list"

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "错误：检测到 Ubuntu，但未找到 apt-get。"
    exit 1
  fi

  echo
  echo "1/5 创建 Tailscale keyring 目录..."
  install -d -m 0755 "${keyring_dir}"

  echo
  echo "2/5 下载 Tailscale GPG key 和 apt 源..."
  echo "${key_url}"
  download_file "${key_url}" "${keyring_file}"
  echo "${source_url}"
  download_file "${source_url}" "${source_file}"

  if [ ! -s "${keyring_file}" ]; then
    echo "错误：GPG key 下载失败或为空：${keyring_file}"
    exit 1
  fi

  if [ ! -s "${source_file}" ]; then
    echo "错误：apt 源文件下载失败或为空：${source_file}"
    exit 1
  fi

  echo
  echo "3/5 更新 apt 缓存并安装 Tailscale..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
}

echo "=========================================="
echo " Tailscale Oracle Linux / CentOS / Ubuntu Installer"
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

# shellcheck disable=SC1091
. /etc/os-release

OS_ID="${ID:-}"
OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
OS_VERSION="${VERSION_ID:-}"
OS_MAJOR="${OS_VERSION%%.*}"
UBUNTU_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
RPM_REPO_FAMILY=""

case "${OS_ID}" in
  ol|oracle|oraclelinux)
    case "${OS_MAJOR}" in
      7|8|9|10)
        DISTRO="oracle"
        RPM_REPO_FAMILY="oracle"
        echo "检测到 Oracle Linux ${OS_MAJOR}"
        ;;
      *)
        echo "错误：当前脚本仅支持 Oracle Linux 7/8/9/10，检测到 VERSION_ID=${OS_VERSION}"
        exit 1
        ;;
    esac
    ;;
  centos)
    case "${OS_MAJOR}" in
      7)
        DISTRO="centos"
        RPM_REPO_FAMILY="centos"
        echo "检测到 CentOS ${OS_MAJOR}"
        ;;
      *)
        echo "错误：当前脚本仅支持 CentOS 7，检测到 VERSION_ID=${OS_VERSION}"
        exit 1
        ;;
    esac
    ;;
  ubuntu)
    if [ -z "${UBUNTU_CODENAME}" ]; then
      echo "错误：检测到 Ubuntu，但无法从 /etc/os-release 读取 VERSION_CODENAME。"
      exit 1
    fi
    DISTRO="ubuntu"
    echo "检测到 ${OS_NAME}，codename=${UBUNTU_CODENAME}"
    ;;
  *)
    echo "错误：当前脚本仅支持 Oracle Linux 7/8/9/10、CentOS 7 和 Ubuntu，检测到 ID=${OS_ID} VERSION_ID=${OS_VERSION}"
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
case "${DISTRO}" in
  oracle)
    echo "Oracle Linux: ${OS_MAJOR}"
    ;;
  centos)
    echo "CentOS: ${OS_MAJOR}"
    ;;
  ubuntu)
    echo "Ubuntu: ${OS_VERSION} (${UBUNTU_CODENAME})"
    ;;
esac
echo "Tailscale tag: ${TAG}"
echo "Tailscale SSH: enabled"
case "${DISTRO}" in
  oracle|centos)
    echo "Tailscale repo only install: yes"
    ;;
  ubuntu)
    echo "Tailscale apt repo: stable"
    ;;
esac
echo
echo "确认继续请输入 y："
read -r CONFIRM
if [ "${CONFIRM}" != "y" ]; then
  echo "已取消。"
  exit 1
fi

case "${DISTRO}" in
  oracle|centos)
    install_on_rpm_linux "${RPM_REPO_FAMILY}" "${OS_MAJOR}"
    ;;
  ubuntu)
    install_on_ubuntu "${UBUNTU_CODENAME}"
    ;;
esac

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
echo " ssh opc@机器名"
echo " ssh ubuntu@机器名"
echo " ssh root@机器名"
