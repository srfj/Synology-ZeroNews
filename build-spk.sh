#!/bin/bash
# 构建 ZeroNews 群晖（Synology）套件 (.spk)
#
# 目标平台：DSM 6.2.3 / x86_64（Intel & AMD 机型）
# 套件形式：原生二进制套件（直接运行 zeronews 客户端，不依赖 Docker）
#
# 用法：
#   ./build-spk.sh
#   ZERONEWS_VERSION=4.0.8 PKG_BUILD=0002 ./build-spk.sh
#
# 产物：<repo>/zeronews-<version>-<build>-x86_64.spk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ZERONEWS_VERSION="${ZERONEWS_VERSION:-4.0.8}"
PKG_BUILD="${PKG_BUILD:-0001}"
PKG_NAME="zeronews"
SPK_ARCH="x86_64"
CLIENT_ARCH_PATH="x86_x64"
DOWNLOAD_BASE="${ZERONEWS_DOWNLOAD_BASE:-https://download.v2.zeronews.cc}"
CLIENT_TARBALL="zeronews-linux-${ZERONEWS_VERSION}.tar"

BUILD_DIR="${SCRIPT_DIR}/build"
PAYLOAD_DIR="${SCRIPT_DIR}/.payload"
CACHE_DIR="${SCRIPT_DIR}/.cache"
ICON_DIR="${SCRIPT_DIR}/icons"
OUT_FILE="${REPO_ROOT}/${PKG_NAME}-${ZERONEWS_VERSION}-${PKG_BUILD}-${SPK_ARCH}.spk"

info() { echo -e "\033[0;34m[i]\033[0m $*"; }
ok()   { echo -e "\033[0;32m[✓]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[0;31m[✗]\033[0m $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v tar  >/dev/null 2>&1 || die "需要 tar"

# ---------------------------------------------------------------- 1. 下载客户端
info "准备 ZeroNews 客户端：${CLIENT_TARBALL}"
mkdir -p "${CACHE_DIR}"
CLIENT_TAR="${CACHE_DIR}/${CLIENT_TARBALL}"

if [ ! -s "${CLIENT_TAR}" ]; then
    URL="${DOWNLOAD_BASE}/linux/${CLIENT_ARCH_PATH}/${CLIENT_TARBALL}"
    info "下载 ${URL}"
    curl -fSLk --retry 3 -m 600 "${URL}" -o "${CLIENT_TAR}" \
        || die "客户端下载失败：${URL}"
else
    info "使用缓存：${CLIENT_TAR}"
fi

# ---------------------------------------------------------------- 2. 解包 payload
info "解包并组装 package.tgz"
rm -rf "${PAYLOAD_DIR}" "${BUILD_DIR}"
mkdir -p "${PAYLOAD_DIR}/bin" "${BUILD_DIR}"

TMP_EXTRACT="$(mktemp -d)"
trap 'rm -rf "${TMP_EXTRACT}"' EXIT
tar -xf "${CLIENT_TAR}" -C "${TMP_EXTRACT}" || die "解包客户端失败"

CLIENT_BIN="$(find "${TMP_EXTRACT}" -type f -name zeronews | head -n1)"
[ -n "${CLIENT_BIN}" ] || die "客户端压缩包中未找到 zeronews 可执行文件"

cp "${CLIENT_BIN}" "${PAYLOAD_DIR}/bin/zeronews"
chmod 0755 "${PAYLOAD_DIR}/bin/zeronews"

# 校验是 x86-64 静态可执行文件（DSM 6.2.3 x86_64 无 glibc 依赖问题）
if command -v file >/dev/null 2>&1; then
    file "${PAYLOAD_DIR}/bin/zeronews" | grep -q "x86-64" \
        || die "客户端架构与目标 (x86_64) 不匹配"
fi

echo "zeronews ${ZERONEWS_VERSION}" > "${PAYLOAD_DIR}/VERSION"

# 桌面 UI：DSM 按 INFO 的 dsmuidir 把 target/ui 链接到
# /usr/syno/synoman/webman/3rdparty/<包名>，主菜单图标由此出现
info "准备桌面 UI（状态 / 日志页面）"
[ -f "${SCRIPT_DIR}/ui/config" ] || die "缺少桌面 UI 配置：${SCRIPT_DIR}/ui/config"
if [ ! -f "${SCRIPT_DIR}/ui/images/zeronews-256.png" ]; then
    python3 "${SCRIPT_DIR}/tools/make-ui-icons.py" >/dev/null \
        || die "生成桌面 UI 图标失败（需要 python3）"
fi
mkdir -p "${PAYLOAD_DIR}/ui/data"
cp -a "${SCRIPT_DIR}/ui/." "${PAYLOAD_DIR}/ui/"
# ui 目录必须 world-readable，否则 DSM 的 web 服务读不到，图标/页面会 404
find "${PAYLOAD_DIR}/ui" -type d -exec chmod 0755 {} +
find "${PAYLOAD_DIR}/ui" -type f -exec chmod 0644 {} +

tar -czf "${BUILD_DIR}/package.tgz" -C "${PAYLOAD_DIR}" .
ok "package.tgz 已生成（$(du -h "${BUILD_DIR}/package.tgz" | cut -f1)）"

# ---------------------------------------------------------------- 3. 套件元数据
info "拷贝套件元数据"
# INFO 的 version 必须跟着构建号走：DSM 判断「能否覆盖安装」看的是 INFO 里的版本，
# 不是文件名。写死会导致新包被当成同版本而拒绝升级。
sed "s/^version=\"[^\"]*\"/version=\"${ZERONEWS_VERSION}-${PKG_BUILD}\"/" \
    "${SCRIPT_DIR}/INFO" > "${BUILD_DIR}/INFO"
grep -q "^version=\"${ZERONEWS_VERSION}-${PKG_BUILD}\"$" "${BUILD_DIR}/INFO" \
    || die "写入 INFO 版本号失败"
mkdir -p "${BUILD_DIR}/conf" "${BUILD_DIR}/scripts" "${BUILD_DIR}/WIZARD_UIFILES"
cp "${SCRIPT_DIR}/conf/privilege"           "${BUILD_DIR}/conf/privilege"
cp "${SCRIPT_DIR}/scripts/postinst"         "${BUILD_DIR}/scripts/postinst"
cp "${SCRIPT_DIR}/scripts/start-stop-status" "${BUILD_DIR}/scripts/start-stop-status"
cp "${SCRIPT_DIR}/scripts/ui-publish.sh"    "${BUILD_DIR}/scripts/ui-publish.sh"
cp "${SCRIPT_DIR}/WIZARD_UIFILES/install_uifile" "${BUILD_DIR}/WIZARD_UIFILES/install_uifile"
chmod 0755 "${BUILD_DIR}/scripts/postinst" "${BUILD_DIR}/scripts/start-stop-status" "${BUILD_DIR}/scripts/ui-publish.sh"
chmod 0644 "${BUILD_DIR}/INFO" "${BUILD_DIR}/conf/privilege" "${BUILD_DIR}/WIZARD_UIFILES/install_uifile"

# ---------------------------------------------------------------- 4. 图标
info "准备套件图标"
mkdir -p "${ICON_DIR}"
if [ -f "${ICON_DIR}/PACKAGE_ICON.PNG" ] && [ -f "${ICON_DIR}/PACKAGE_ICON_256.PNG" ]; then
    :
elif python3 -c "import PIL" >/dev/null 2>&1 && [ -f "${REPO_ROOT}/icon.png" ]; then
    python3 - "${REPO_ROOT}/icon.png" "${ICON_DIR}" <<'PY'
import sys
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
im.resize((72, 72), Image.LANCZOS).save(f"{out}/PACKAGE_ICON.PNG", "PNG")
im.resize((256, 256), Image.LANCZOS).save(f"{out}/PACKAGE_ICON_256.PNG", "PNG")
PY
else
    die "缺少套件图标（${ICON_DIR}/PACKAGE_ICON.PNG、PACKAGE_ICON_256.PNG），且无法从 icon.png 生成（需 python3 + Pillow）"
fi
cp "${ICON_DIR}/PACKAGE_ICON.PNG"     "${BUILD_DIR}/PACKAGE_ICON.PNG"
cp "${ICON_DIR}/PACKAGE_ICON_256.PNG" "${BUILD_DIR}/PACKAGE_ICON_256.PNG"

# ---------------------------------------------------------------- 5. 写入 checksum
# INFO 中的 checksum 必须是 package.tgz 的 md5，DSM 安装时会校验。
PKG_MD5="$(md5sum "${BUILD_DIR}/package.tgz" | cut -d' ' -f1)"
# 确保 INFO 以换行结尾，否则 checksum 会被拼接到上一行，导致 INFO 解析失败
[ -n "$(tail -c 1 "${BUILD_DIR}/INFO")" ] && printf '\n' >> "${BUILD_DIR}/INFO"
printf 'checksum="%s"\n' "${PKG_MD5}" >> "${BUILD_DIR}/INFO"
ok "checksum=${PKG_MD5}"

# ---------------------------------------------------------------- 6. 打包 spk
# 注意：DSM 6 的 spk 是「未压缩的 tar」，且归档条目不能带 ./ 前缀，
# 否则套件中心会报「套件文件格式不正确」。这里与官方 spksrc 的打包方式一致：
#   (cd WORK_DIR && tar cf out.spk package.tgz INFO scripts conf ...)
info "打包 spk（未压缩 tar，条目无 ./ 前缀）"
rm -f "${OUT_FILE}"

# 仅在 GNU tar 上使用属主/排序参数（macOS 的 bsdtar 不支持）
TAR_OPTS=""
if tar --version 2>/dev/null | grep -q GNU; then
    TAR_OPTS="--owner=root --group=root --numeric-owner"
fi

SPK_CONTENT="package.tgz INFO scripts conf WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG"
( cd "${BUILD_DIR}" && tar cf "${OUT_FILE}" ${TAR_OPTS} ${SPK_CONTENT} )

ok "构建完成：${OUT_FILE}"
ls -lh "${OUT_FILE}"
echo
echo "安装方式：DSM「套件中心」→ 手动安装 → 选择该 .spk 文件"
echo "适用：DSM 6.2.x（含 6.2.3）x86_64 机型"
echo "提示：未签名的第三方套件需在 套件中心 → 设置 → 常规 → 信任层级 选择「任何发行者」"