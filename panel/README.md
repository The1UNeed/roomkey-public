<p align="center"><img src="web/public/logo.svg" width="72" alt="roomkey"></p>

# roomkey 面板

roomkey 的管理面板：一群朋友共用的几台 VPS，每人一个订阅地址，带流量额度、到期日和可用节点。基于 [psm-panel](https://github.com/jinqians/psm-panel) 和 [PSM](https://github.com/jinqians/proxy-stack) 改出来，部署在你自己的 Cloudflare Workers + D1 上。

- **用户**：每人一个订阅；总流量额度、单台服务器额度、到期日（可从第一次使用算起）、同时在线设备数；按节点标签决定能用哪些节点。到期和单台服务器额度由服务器自己执行，面板离线时也一样；总额度要汇总各台用量，由面板执行（最多晚一次上报，约 10 分钟）。
- **订阅**：Shadowrocket、Throne 拿通用链接，Clash Verge 拿 mihomo 配置，按客户端自动识别；订阅页显示用量和到期日，暂停时说明原因。
- **服务器和节点**：面板给一条命令，在新 VPS 上装好 PSM 并接入；节点在面板里新建、修改、删除，psm-agent 主动连面板领任务，VPS 不用开管理端口。每台服务器有一个 `nN.myroom.asia`，IP 变了面板自动改 DNS（Cloudflare API，灰云）。
- **不做开放中转**：REALITY 只回落到节点自己的网站（127.0.0.1:8443，节点自己的证书）；没有中转（relay）、没有 SOCKS 节点；内核启动前拒绝公开的无账号监听、回落到别处和公开的控制接口；nginx 不转发到本机以外。
- **流量**：每个节点和每个用户的用量、每日图表（北京时间），节点额度超了自动暂停，到重置日或手动重置后恢复。
- **记录和提醒**：所有操作有审计记录；设置 Telegram 后，用户被暂停（到期、超额、设备超限）和恢复、服务器离线和恢复、有人登录服务器的本机页面，都会发提醒。

部署和日常维护见仓库里的 [docs/DEPLOY.md](../docs/DEPLOY.md)，设计说明见 [docs/PLAN.md](../docs/PLAN.md)。

## 部署

用一个**新的、空的 D1**（不接管 psm-panel 的数据库），步骤见 [docs/DEPLOY.md](../docs/DEPLOY.md)。

## 接入服务器

在面板"服务器"页添加服务器（或新建节点时选"＋ 新服务器"），复制面板给出的命令（它指向 roomkey 自己的安装脚本和仓库），在 VPS 上以 root 执行。

- 接入前会先做检查：每个内核都要用 PSM 自己的服务和配置启动，服务器上不能有 PSM 以外的代理（3x-ui、Marzban、别的 Xray 实例或开机自启的代理服务/容器）、不能已经装了 nginx，配置里不能有 PSM 没建的入站；中转规则和 realm / gost 会被删掉。检查不通过时服务器原样不动，命令会说明原因。
- 请用一台全新的 VPS。

令牌 24 小时内有效、只能用一次。接入后服务器显示"在线"，面板上的节点几秒内在服务器上建好。

## 安全

- 管理员密码来自 Worker 机密 `ADMIN_PASSWORD`；面板第一次读到它时，会把**加盐的 PBKDF2 哈希**存进 D1，这样重新部署丢了机密也不会被锁在门外。机密还在时以机密为准，改机密即改密码。登录会话是签名的 HttpOnly、SameSite=Strict Cookie，**退出登录会让所有设备上的登录一起失效**；同一地址（IPv6 按 /64）15 分钟内失败 10 次后暂停登录；改动数据的请求必须来自面板自己的页面；后台只在 `ADMIN_HOSTS` 上应答。
- 节点密码、客户端链接、下发的任务、订阅和安装命令的令牌在 D1 里都加密保存；agent 令牌和加入令牌的查找只用哈希。加密密钥若在 D1 里，系统设置会提示并按步骤把它挪进 Cloudflare 机密 `TOKEN_KEY`。
- 页面带 Content-Security-Policy 等安全头；订阅地址、节点链接和安装命令在页面上默认遮住，点开或直接复制。
- psm-agent 只执行白名单校验过的 `psm` 命令，参数以数组传递，从不经过 shell。

## 测试

```bash
npm ci
npm run typecheck && npm test && npm run build
npm run e2e        # 本地 wrangler + 模拟的 Cloudflare / Telegram API + 模拟的 psm-agent，约 145 项检查
```

## 许可

AGPL-3.0（沿用 psm-panel）。
