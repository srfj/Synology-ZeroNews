#!/bin/sh
# ZeroNews 群晖套件 - 桌面面板数据生成脚本
#
# 客户端自带的 HTTP API 只监听 127.0.0.1：即使改用 0.0.0.0 绑定，来自其他主机的
# 请求也会被拒绝（HTTP 403），且不返回 CORS 头。也就是说浏览器（跑在用户电脑上）
# 无法直接访问该 API。
#
# 因此由本脚本在 NAS 端把「运行状态」与「运行日志」落成静态文件，交给 DSM 自己的
# web 服务对外提供，桌面图标页面从同源读取：
#   /usr/syno/synoman/webman/3rdparty/zeronews/data/status.json
#   /usr/syno/synoman/webman/3rdparty/zeronews/data/service.log
#
# 用法：
#   ui-publish.sh          生成一次
#   ui-publish.sh daemon   每 INTERVAL 秒生成一次，直到进程被终止
#
# 日志上限：客户端把每次本地 API 请求都写进 service.log（面板每 10 秒轮询一次，
# 约 6 行/10 秒 ≈ 6MB/天）。这里在超过 LOG_MAX_BYTES 时就地截断，只保留最近
# LOG_KEEP_LINES 行，避免长期运行把系统盘写满。

PKG_NAME="zeronews"
PKG_DIR="/var/packages/${PKG_NAME}/target"
VAR_DIR="/var/packages/${PKG_NAME}/var"
BIN="${PKG_DIR}/bin/zeronews"
PIDFILE="${VAR_DIR}/zeronews.pid"
LOGFILE="${VAR_DIR}/logs/service.log"
UI_DATA="${PKG_DIR}/ui/data"
LAST_BODY="${VAR_DIR}/.ui-last.json"
INTERVAL=10
LOG_MAX_BYTES=2097152
LOG_KEEP_LINES=1000

is_running() {
    [ -f "${PIDFILE}" ] || return 1
    _p=$(cat "${PIDFILE}" 2>/dev/null)
    [ -n "${_p}" ] || return 1
    kill -0 "${_p}" 2>/dev/null
}

# 日志超过上限时保留最近若干行并就地截断。
# 注意必须 `cat > LOGFILE` 而不是 mv：客户端以 >> 持续写同一个文件描述符，
# 替换 inode 会让它继续写旧文件，导致日志从此“消失”。
trim_log() {
    [ -f "${LOGFILE}" ] || return 0
    _size=$(wc -c < "${LOGFILE}" 2>/dev/null | tr -d ' ')
    [ -n "${_size}" ] && [ "${_size}" -gt "${LOG_MAX_BYTES}" ] || return 0
    _tmp="${VAR_DIR}/.service.log.trim"
    if tail -n "${LOG_KEEP_LINES}" "${LOGFILE}" > "${_tmp}" 2>/dev/null; then
        cat "${_tmp}" > "${LOGFILE}" 2>/dev/null
    fi
    rm -f "${_tmp}" 2>/dev/null
    return 0
}

publish() {
    mkdir -p "${UI_DATA}" 2>/dev/null || return 0

    trim_log

    _running=false
    _pid=0
    if is_running; then
        _running=true
        _pid=$(cat "${PIDFILE}" 2>/dev/null)
    fi

    # status/endpoints 的 --json 输出本身就是合法 JSON；异常时退化为空对象，
    # 避免把报错文本写进 status.json 导致页面解析失败
    _st=$("${BIN}" --workdir "${VAR_DIR}" status --json 2>/dev/null)
    case "${_st}" in \{*) ;; *) _st='{}' ;; esac
    _ep=$("${BIN}" --workdir "${VAR_DIR}" endpoints --json 2>/dev/null)
    case "${_ep}" in \{*) ;; *) _ep='{}' ;; esac

    _body=$(printf '{"running":%s,"pid":%s,"status":%s,"endpoints":%s}' \
        "${_running}" "${_pid}" "${_st}" "${_ep}")

    _last=""
    [ -f "${LAST_BODY}" ] && _last=$(cat "${LAST_BODY}" 2>/dev/null)

    # 仅在状态变化时写盘：空闲时不再每 10 秒唤醒一次磁盘
    if [ "${_body}" != "${_last}" ] || [ ! -f "${UI_DATA}/status.json" ]; then
        printf '{"updated":"%s","running":%s,"pid":%s,"status":%s,"endpoints":%s}\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "${_running}" "${_pid}" "${_st}" "${_ep}" \
            > "${UI_DATA}/.status.tmp" 2>/dev/null \
            && mv -f "${UI_DATA}/.status.tmp" "${UI_DATA}/status.json" 2>/dev/null
        printf '%s' "${_body}" > "${LAST_BODY}" 2>/dev/null
    fi

    if [ -f "${LOGFILE}" ]; then
        tail -n 200 "${LOGFILE}" > "${UI_DATA}/.log.tmp" 2>/dev/null
        if ! cmp -s "${UI_DATA}/.log.tmp" "${UI_DATA}/service.log" 2>/dev/null; then
            mv -f "${UI_DATA}/.log.tmp" "${UI_DATA}/service.log" 2>/dev/null
        fi
        rm -f "${UI_DATA}/.log.tmp" 2>/dev/null
    fi
}

case "${1:-once}" in
    daemon)
        # 收到 TERM/INT 立即退出。注意不能直接 `sleep 10`：shell 在 sleep 期间
        # 不会处理信号，要等 sleep 结束才退出，会导致停止套件后本进程残留最多 10 秒。
        trap 'exit 0' TERM INT
        while :; do
            publish
            _i=0
            while [ "${_i}" -lt "${INTERVAL}" ]; do
                sleep 1
                _i=$((_i + 1))
            done
        done
        ;;
    *)
        publish
        ;;
esac
