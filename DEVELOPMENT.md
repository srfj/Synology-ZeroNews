# 开发与排错记录

本文记录把 ZeroNews 客户端打包为群晖 DSM 套件过程中踩过的坑、定位过程与最终结论，
供后续维护与在其他 DSM 版本上移植时参考。

目标环境：**DSM 6.2.3 / x86_64（Intel & AMD 机型）**

---

## 1. 套件格式：为什么自制的 .spk 会被拒

### 症状

套件中心手动安装时报「**套件文件格式不正确**」。

### 原因

DSM 6 的 `.spk` 实际上是一个**未压缩的 tar**，且对归档条目名有要求。以下写法都会导致解析失败：

| 错误写法 | 后果 |
|----------|------|
| 用 `tar -czf`（gzip 压缩）打包 `.spk` | 套件中心无法识别 |
| 归档条目带 `./` 前缀（`tar cf x.spk .`） | 套件中心无法识别 |
| `INFO` 缺少 `checksum` 字段 | 校验失败 |
| `INFO` 结尾没有换行符 | `checksum` 被拼到上一行，`INFO` 解析异常 |

### 正确做法

```bash
SPK_CONTENT="package.tgz INFO scripts conf WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG"
( cd "${BUILD_DIR}" && tar cf "${OUT_FILE}" ${TAR_OPTS} ${SPK_CONTENT} )
```

要点：

- 未压缩 `tar cf`，**不要** `-z`/`-j`
- 归档条目为具名条目（`package.tgz`、`INFO`…），不带 `./`
- `INFO` 中的 `checksum` 必须是 `package.tgz` 的 **md5**
- 写入 `checksum` 前先确保 `INFO` 以换行结尾：

  ```bash
  [ -n "$(tail -c 1 "${BUILD_DIR}/INFO")" ] && printf '\n' >> "${BUILD_DIR}/INFO"
  printf 'checksum="%s"\n' "${PKG_MD5}" >> "${BUILD_DIR}/INFO"
  ```

- `os_min_ver` 必须不高于目标 DSM 版本（本包为 `6.2-23739`）
- **`INFO` 中不要写注释行**，否则会被 DSM 的简单 k/v 解析器误读

### 关于版本号

DSM 判断「能否覆盖安装」看的是 `INFO` 里的 `version`，**不是文件名**。
若版本号写死，改了文件名也会被当成同版本而拒绝升级。因此构建时动态替换：

```bash
sed "s/^version=\"[^\"]*\"/version=\"${ZERONEWS_VERSION}-${PKG_BUILD}\"/" \
    "${SCRIPT_DIR}/INFO" > "${BUILD_DIR}/INFO"
```

---

## 2. 安装失败：`Failed to set default owner`（残留用户/组）

### 症状

安装退出码 255，日志出现：

```
privilege_api.cpp:343 Failed to set default owner of zeronews [0x2000 bdb_get.c:40]
```

### 原因

上一次卸载后 `/etc/passwd`、`/etc/group` 中仍残留套件专用用户/组：

```
/etc/passwd:ZeroNews:x:194191:194191:...
```

DSM 安装时会创建套件专属用户/组，已存在同名条目时创建失败，进而中断安装。

### 解决

```bash
sudo synouser --del ZeroNews
sudo synogroup --del ZeroNews
```

重装前确认：

```bash
grep -i zeronews /etc/passwd /etc/group
```

> 经验：**卸载套件后残留用户/组**是第三方套件重装失败的常见原因；排查时先看
> `/var/log/packages/<包名>.log` 里的 `privilege_api.cpp` 报错。

---

## 3. 启动失败：`Permission denied` 与 `run-as`

### 症状

启动失败，日志出现：

```
mkdir: cannot create directory '/var/packages/zeronews/var': Permission denied
```

### 原因

`conf/privilege` 中 `run-as` 为 `package` 时，套件以**非 root** 用户运行，
而 `/var/packages/<包名>` 属于 root，无法在其下创建 `var` 目录。

### 解决

`conf/privilege` 改为以 root 运行：

```json
{
  "defaults": {
    "run-as": "root"
  }
}
```

> 说明：`run-as` 只接受 `package` / `root` 两个取值。需要维护 pid 文件、创建运行目录、
> 或操作 `/var/packages/<包名>/var` 的套件通常都使用 `root`。

---

## 4. 显示「正在运行」但设备不上线：Token 从未绑定

### 症状

套件状态显示运行中，但 ZeroNews 云端看不到设备上线。

### 原因

`postinst` 中把 `authtoken` 的输出重定向到 `var/logs/authtoken.log`，但该目录**当时还不存在**。
POSIX shell 在**打不开重定向目标时会跳过整条命令**（不是只丢日志），因此 `authtoken` 根本没执行。

```sh
# 有问题的写法：目录不存在 → 整条命令不执行
"${BIN}" --workdir "${VAR_DIR}" authtoken "${TOKEN}" >"${VAR_DIR}/logs/authtoken.log" 2>&1
```

### 解决

先建目录，并保留不打重定向的退路：

```sh
mkdir -p "${VAR_DIR}/logs" "${PKG_DIR}/ui/data" 2>/dev/null

if [ -d "${VAR_DIR}/logs" ]; then
    "${BIN}" --workdir "${VAR_DIR}" authtoken "${TOKEN}" >"${VAR_DIR}/logs/authtoken.log" 2>&1
else
    "${BIN}" --workdir "${VAR_DIR}" authtoken "${TOKEN}" >/dev/null 2>&1
fi
```

### 另一个坑：认证失败也返回 0

`zeronews authtoken` **认证失败时退出码仍为 0**，不能靠退出码判断成败。
正确做法是查询状态并解析 `configured` 字段：

```sh
if "${BIN}" --workdir "${VAR_DIR}" status --json 2>/dev/null \
        | grep -qE '"configured"[[:space:]]*:[[:space:]]*true'; then
    echo "ZeroNews Token 认证成功，账号已绑定。"
else
    echo "警告：ZeroNews Token 认证失败，请确认 Token 是否正确。"
fi
```

> 经验：**重定向目标目录不存在会导致整条命令不执行**，这是排查「脚本明明写了却没生效」时
> 最容易被忽略的一类问题。

---

## 5. 桌面图标：`dsmuidir` 与入口 URL

### 注册机制

DSM 依据 `INFO` 中的 `dsmuidir` 自动建立软链接：

```
/usr/syno/synoman/webman/3rdparty/zeronews -> /var/packages/zeronews/target/ui
```

`ui/` 目录必须在 `package.tgz` 内，安装后位于 `/var/packages/zeronews/target/ui`。

`INFO` 相关字段：

```
dsmuidir="ui"
dsmappname="com.zeronews.packages.zeronews"
```

`ui/config` 定义入口（`.url` 的 key 必须与 `dsmappname` 一致）：

```json
{
  ".url": {
    "com.zeronews.packages.zeronews": {
      "title": "ZeroNews",
      "desc": "ZeroNews 零讯客户端：查看运行状态与运行日志",
      "icon": "images/zeronews-{0}.png",
      "type": "url",
      "url": "/webman/3rdparty/zeronews/index.html",
      "allUsers": true,
      "grantPrivilege": "all",
      "advanceGrantPrivilege": true
    }
  }
}
```

### 坑：入口 URL 少了 `/webman` 前缀

**症状**：点开图标显示 DSM 的「**您所指定的页面不存在**」，地址栏为

```
http://192.168.0.86:5000/3rdparty/zeronews/index.html
```

**原因**：第三方应用实际挂在 `/usr/syno/synoman/webman/3rdparty/<包名>`，
URL 必须包含 `webman` 这一段。写成 `3rdparty/zeronews/index.html` 会被解析为
`/3rdparty/...`，DSM 找不到页面。

**解决**：`url` 写成 **`/webman/3rdparty/zeronews/index.html`**（以 `/` 开头的绝对路径）。

### 图标文件命名

`icon` 模板中的 `{0}` 会被依次替换为 **16/24/32/48/64/72/256**，因此需要准备同名的多尺寸 PNG：

```
ui/images/zeronews-16.png
ui/images/zeronews-24.png
ui/images/zeronews-32.png
ui/images/zeronews-48.png
ui/images/zeronews-64.png
ui/images/zeronews-72.png
ui/images/zeronews-256.png
```

> 注意：`PACKAGE_ICON.PNG` / `PACKAGE_ICON_256.PNG`（`icons/`）仅用于**套件中心列表**，
> 与 DSM 主菜单图标无关。

### 修改图标后的缓存

DSM 桌面可能缓存旧的入口地址，改完 `ui/config` 后需**重新登录 DSM 或整页刷新**才会生效。

### 无 ImageMagick / Pillow 时生成图标

`tools/make-ui-icons.py` 用纯 Python（`struct` + `zlib`）解码/缩放 PNG，
从 `icons/PACKAGE_ICON_256.PNG` 派生上面 7 个尺寸，避免引入外部依赖。

---

## 6. 面板数据：客户端 API 只监听 127.0.0.1

### 问题

客户端自带 HTTP API（默认 `127.0.0.1:37271`）：

- 即使改绑 `0.0.0.0`，来自其他主机的请求仍返回 **HTTP 403**，且**不返回 CORS 头**
- 浏览器运行在用户电脑上，因此**无法直接访问该 API**

### 方案

在 NAS 端把状态与日志落成**静态文件**，交给 DSM 自己的 web 服务对外提供，
桌面页面以**同源相对路径**读取，从而绕开跨域与 127.0.0.1 限制：

```
/usr/syno/synoman/webman/3rdparty/zeronews/data/status.json
/usr/syno/synoman/webman/3rdparty/zeronews/data/service.log
```

`scripts/ui-publish.sh` 负责生成，用到的接口：

| 用途 | 命令 |
|------|------|
| 运行状态 | `zeronews --workdir <var> status --json` |
| 隧道列表 | `zeronews --workdir <var> endpoints --json` |
| 服务状态（HTTP） | `GET /api/v1/status` |
| 认证状态（HTTP） | `GET /api/v1/auth/status` |
| 配置认证（HTTP） | `POST /api/v1/auth/configure`（字段名 **`auth_token`**） |

页面侧（`ui/index.html`）刻意使用**相对路径**，保持同源：

```js
var BASE = "data/";   // 即 /webman/3rdparty/zeronews/data/
```

### 细节处理

- **仅在状态变化时写盘**：空闲时不再每 10 秒唤醒一次磁盘（先写 `.tmp` 再 `mv` 原子替换）
- **容错**：`status`/`endpoints` 输出异常时退化为 `{}`，避免把报错文本写进 `status.json` 导致页面解析失败
- **日志**：只保留最近 200 行（`tail -n 200`）

---

## 7. 守护进程的信号处理

### 症状

停止套件后，`ui-publish.sh` 的守护进程仍残留最多 10 秒。

### 原因

`while sleep 10` 期间 shell 正阻塞在 `sleep`，**不会立即处理 TERM 信号**，要等 `sleep` 结束才退出。

### 解决

`trap` + 分片 sleep：

```sh
trap 'exit 0' TERM INT
while :; do
    publish
    _i=0
    while [ "${_i}" -lt "${INTERVAL}" ]; do
        sleep 1
        _i=$((_i + 1))
    done
done
```

`start-stop-status` 的 `stop_ui_publisher` 侧再加一层超时兜底（等待数秒后 `kill -9`），
并额外调用一次 `ui-publish.sh`，让面板立刻显示「已停止」。

> 另一个排查期踩到的小坑：用 `pkill -f "ui-publish"` 清理测试进程时，
> 命令自身的命令行也包含该字符串，**会把自己杀掉**。改用变量拼接规避自匹配。

---

## 8. DSM 6.x 的服务管理

DSM 6.x 上**没有 systemd**，`zeronews service install` 之类依赖 systemd 的子命令不可用。
因此 `scripts/start-stop-status` 直接以常驻前台进程方式启动客户端，并自行维护 pid 文件：

```sh
cd "${PKG_DIR}" || return 1
HOME="${VAR_DIR}" nohup "${BIN}" --workdir "${VAR_DIR}" start >>"${LOGFILE}" 2>&1 &
echo $! > "${PIDFILE}"
```

`status` 必须遵循 DSM 约定：

```sh
status)
    if is_running; then exit 0; fi   # 运行中
    exit 3                            # 未运行
    ;;
```

---

## 9. 常用排查命令

```bash
# 安装/卸载日志
cat /var/log/packages/zeronews.log

# 套件状态与启动
sudo synopkg status zeronews
sudo synopkg start zeronews

# Token 是否绑定、是否连上云端
sudo /var/packages/zeronews/target/bin/zeronews \
  --workdir /var/packages/zeronews/var status --json

# 手动绑定 Token
sudo /var/packages/zeronews/target/bin/zeronews \
  --workdir /var/packages/zeronews/var authtoken "<Token>"

# 桌面入口软链接
ls -l /usr/syno/synoman/webman/3rdparty/zeronews

# 残留套件用户/组
grep -i zeronews /etc/passwd /etc/group

# 卸载并清理残留
sudo synopkg uninstall zeronews
sudo synouser --del ZeroNews
sudo synogroup --del ZeroNews
```

---

## 10. 检查清单

打包/发版前逐项确认：

- [ ] `.spk` 为**未压缩 tar**，条目**不带 `./` 前缀**
- [ ] `INFO` 的 `checksum` 与 `package.tgz` 的 md5 一致
- [ ] `INFO` 的 `version` 跟随构建号变化
- [ ] `INFO` **无注释行**，且以换行结尾
- [ ] `os_min_ver` 不高于目标 DSM 版本
- [ ] `ui/config` 中 `url` 为 `/webman/3rdparty/zeronews/index.html`
- [ ] `ui/config` 的 `.url` key 与 `INFO` 的 `dsmappname` 一致
- [ ] 7 个尺寸的主菜单图标齐全
- [ ] `package.tgz` 内包含 `ui/` 目录
- [ ] `conf/privilege` 的 `run-as` 满足运行目录权限需求