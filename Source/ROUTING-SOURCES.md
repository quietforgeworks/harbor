# Harbor 第一版规则来源与边界

核对日期：2026-11-06。此文件记录实现依据，不包含用户订阅数据。

- Mihomo 官方仓库：https://github.com/MetaCubeX/mihomo 。官方 Releases API 本次返回 v1.19.33，发布时间 2026-10-21。许可证以仓库 LICENSE 为准，是 GPL v3；不要采用第三方页面的 MIT 标签。
- 控制接口：https://wiki.metacubex.one/en/config/general/ 。本实现只监听 127.0.0.1，随机 secret、禁用浏览器跨域来源，不使用免密 Unix API。
- 代理 provider 载荷：https://wiki.metacubex.one/en/config/proxy-providers/content/ 。内核支持 YAML、URI、Base64；Harbor 第一版明确只导入含 proxies 列表的 YAML，且提取节点与用于节点域名解析的 HTTPS DNS 端点。没有把 URI/Base64 转换能力冒称为已实现。
- 路由规则：https://wiki.metacubex.one/en/config/rules/ 。顺序匹配；采用 DOMAIN / DOMAIN-SUFFIX / IP-CIDR / IP-CIDR6 / MATCH。所有 IP 条目 no-resolve，不下载 GEOIP/GEOSITE 数据。产品全局模式仍令内核处于 rule 模式，以保留局域网例外。
- OpenAI 官方网络说明：https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps 。涵盖 OpenAI / ChatGPT / 静态资源 / 上传域名，以及精确的 WorkOS、Cloudflare challenge 等共享端点。官方清单中 humb.apple.com 按用户当前明确要求直连，没有历史 Siri 例外。精确列出的 Intercom 静态资源、Sentry 和 Datadog 主机也纳入代理。官方泛域名 *.intercom.io、*.intercomcdn.com、*.ct.sendgrid.net 涉及共享客服/邮件服务，第一版没有整体接管，只代理官方列明的精确 js.intercomcdn.com；这些附加服务的其余域名仍按自定义规则或默认 DIRECT。ws.chatgpt.com 和 ChatGPT/Codex WebSocket 由 chatgpt.com 后缀覆盖。
- Claude 官方网络要求：https://code.claude.com/docs/en/network-config 与 https://support.claude.com/en/articles/13198485-enforce-network-level-access-control-with-tenant-restrictions 。另见桌面版明确域名清单 https://code.claude.com/docs/en/desktop#network-access-requirements 。覆盖 claude.ai、claude.com、claude.app、anthropic.com、claudeusercontent.com、claudemcpcontent.com，包括动态 artifact、预览与 MCP widget 子域名。文档明确列出的 artifact 库源 cdnjs.cloudflare.com、cdn.jsdelivr.net、cdn.tailwindcss.com、code.jquery.com 和 unpkg.com 采用精确 DOMAIN。CLI 包安装的 registry.npmjs.org 和可选外部遥测没有额外接管。Claude Code 可用 HTTPS_PROXY 指向 Harbor 的本机 HTTP 代理，且需按官方说明在启动前配置。
- Google 官方 https://knowledge.workspace.google.com/admin/security/firewall-and-proxy-settings 的 Gemini hosts 一节，页面标注 2026-10-26 更新。Google、Google APIs、Google user content、gstatic、Drive 与 Gmail/YouTube 后缀覆盖登录、主页面、图片/视频与字体。补充清单中的精确 csp.withgoogle.com、www.googletagmanager.com、www.google-analytics.com、static.doubleclick.net、td.doubleclick.net、googleads.g.doubleclick.net。Gemini API https://ai.google.dev/api 与文件上传 https://ai.google.dev/api/files 使用 generativelanguage.googleapis.com，上传路径 /upload/v1beta/files；均由 googleapis.com 覆盖。没有将 Google Cloud IP 网段或 amazonaws.com、azure.com、cloudflare.com、akamai.net、jsdelivr.net 等共享云/CDN后缀整体代理。
- Apple 官方：https://support.apple.com/en-us/101555 。Apple Account、iCloud/CloudKit、系统升级域名直连；另保护该页列出的精确共享中继和证书状态端点。Apple 共用域名规则在自定义规则前，规则模式默认 DIRECT。

第一版导入自定义规则支持 rules/payload YAML、纯 YAML 列表或逐行文本。允许 DOMAIN、DOMAIN-SUFFIX、IP-CIDR、IP-CIDR6，目标 DIRECT 或 PROXY（内部 SELECT）。规则模式顺序为 LAN DIRECT、Apple DIRECT、内置服务 SELECT、自定义规则、MATCH DIRECT。内置服务优先于导入的 DIRECT，防止主页面、登录与资源使用不同出口；MATCH,DIRECT 可保留但会统一移到末尾；不接受 MATCH,PROXY、远程 rule-provider 或任意机场策略组名。无效文件整体拒绝，调用方必须在内核验证成功后原子替换旧配置。

验证只证明配置隔离、规则排列和内核可解析；真实服务业务成功、地区限制、账号登录及 UDP/QUIC 不在静态规则测试可证明的范围内。


## AI 连通性检查与结果含义

检查使用明确的本机代理地址发送无凭据 HTTPS GET。首轮仅请求服务主页面 https://chatgpt.com/ 、https://claude.ai/ 、https://gemini.google.com/app 。可进一步检查 https://auth.openai.com/ 与 https://accounts.google.com/ 的登录入口，以及 API https://api.openai.com/v1/models 、https://api.anthropic.com/v1/models 、https://generativelanguage.googleapis.com/v1beta/models 。不发送用户 cookie、API key、聊天内容或上传文件。

- 200 表示该 URL 返回响应。主页面 HTML 不能证明账户登录、模型调用或上传可用。
- 3xx 表示入口返回重定向，需要检查目标与后续响应。
- API 的 400/401 表示收到了服务响应，通常仍需合法凭据或请求参数；不能显示为业务成功。
- 403 表示拒绝、挑战或访问受限，需要保留状态；不能显示为服务可用。若为代理 CONNECT 的 403，则目标服务尚未收到请求。
- 429 表示限流，5xx 表示服务或上游错误，DNS/TLS/超时分别记录连接问题。

上传路径需要有效账户和真实上传流程验证。资源根路径的 404 不能证明上传失败或成功。WebSocket、长时间流式输出、语音 UDP、QUIC、第三方身份提供商/连接器及任意外部工具站点需各自实际验证。账号、出口地区、风控与套餐限制独立于域名路由，无法由静态配置保证。

静态回归测试 AICoverageTests 通过生成配置的入口检查内置服务优先级，并逐项覆盖官方 Gemini 主机清单、Claude 动态内容与共享库源、Apple/LAN 和未列出域名的 DIRECT 行为。测试本身不修改系统代理、DNS、TUN、路由或运行服务。


## 订阅节点 DNS 兼容性

订阅导入保留 `dns.proxy-server-nameserver`，未提供该字段时使用 `dns.nameserver` 中的有效 HTTPS DNS URL，最多八个。URL 禁止凭据、片段、空白和无效端口，其他 DNS 协议与无效项目丢弃。持久化字段为可选，旧存档仍使用系统 DNS。构建运行配置时重新校验持久化端点。

端点仅用于 `proxy-server-nameserver`。内部 DNS 开启并采用 `redir-host`，`listen` 为空，`default-nameserver`、`nameserver`、`direct-nameserver` 均为 `system`，`respect-rules` 和 `direct-nameserver-follow-policy` 关闭。未保留订阅 DNS 策略、监听、fake-IP、TUN 或全局规则。无有效端点时保持 `dns.enable: false`。

依据 Mihomo v1.19.33 官方源码 `config/config.go` 对 `system` 的解析与默认 DNS 校验豁免、`hub/executor/executor.go` 的内部解析器初始化，以及 `dns/server.go` 对空监听地址的提前返回。官方文档明确 `proxy-server-nameserver` 仅用于节点域名。

- https://wiki.metacubex.one/en/config/dns/#proxy-server-nameserver
- https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.33/config/config.go
- https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.33/hub/executor/executor.go
- https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.33/dns/server.go


0.2.0 更新：默认规则和旧式片段导入继续使用上述优先级。完整规则编辑器允许用户明确覆盖整个规则模式表；保存前校验格式、目标与终止 MATCH，并由内核校验。全局模式仍独立保留 LAN→DIRECT、MATCH→SELECT 的逻辑。速率使用 /connections 的累计字节与单调时钟差计算，不把累计流量当作网速。
