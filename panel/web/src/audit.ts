// The audit log's actions, as the pages name them.
export const ACTIONS: Record<string, string> = {
  login: '登录', 'login.failed': '登录失败', logout: '退出登录',
  'server.add': '添加服务器', 'server.update': '修改服务器', 'server.delete': '移除服务器', 'server.forget': '从面板移除服务器',
  'server.leave': '卸载服务器', 'server.left': '服务器已卸载', 'server.join': '服务器接入', 'server.diagnose': '诊断服务器',
  'server.upgrade-agent': '更新服务器', 'server.check': '检测 IP 质量与解锁', 'server.sni-find': '查找伪装目标', 'server.new-command': '重新生成安装命令',
  'node.add': '新建节点', 'node.update': '修改节点', 'node.delete': '删除节点', 'traffic.reset': '重置流量',
  'server.dns': '域名跟随 IP', 'server.dns_name': '设置服务器域名', 'server.local_code': '查看本机页面登录码',
  'user.add': '新建用户', 'user.update': '修改用户', 'user.delete': '删除用户', 'user.devices': '清除用户设备',
  'user.reset_credentials': '重置用户密钥', 'user.reset_link': '重置订阅链接', 'user.reset_usage': '重置用户流量',
  'panel.update': '更新面板', 'backup.export': '下载备份', 'settings.telegram': '修改 Telegram 告警',
  'relay.add': '新建中转', 'relay.update': '修改中转', 'relay.delete': '删除中转',
  'subscription.add': '新建订阅', 'subscription.update': '修改订阅', 'subscription.reset': '重置订阅地址', 'subscription.delete': '删除订阅',
  'settings.update': '修改设置', 'settings.reveal-key': '查看加密密钥', 'settings.reveal-key.failed': '查看密钥失败',
  'settings.forget-key': '删除数据库里的密钥',
  'template.add': '新建订阅模板', 'template.update': '修改订阅模板', 'template.delete': '删除订阅模板',
}
export const actionLabel = (a: string) => ACTIONS[a] ?? a
// what a settings change was about, by the key the panel logs
const TARGETS: Record<string, string> = { updates: '更新设置', panel_url: '面板地址', ipcheck_key_abuseipdb: 'AbuseIPDB Key', ipcheck_key_ipqs: 'IPQS Key', ipcheck_key_ip2location: 'IP2Location Key' }
export const targetLabel = (t: string) => TARGETS[t] ?? t
