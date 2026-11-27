<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { api, errorText } from '../api'
import { confirmAction, toast } from '../ui'
import SecretText from '../components/SecretText.vue'
import Icon from '../components/Icon.vue'
import UpdatesCard from '../components/UpdatesCard.vue'

type Settings = {
  version: string; agent_version: string; panel_url: string; effective_panel_url: string; sync_interval: number
  token_key: 'panel' | 'secret' | 'both' | 'mismatch'
  ipcheck_keys: Record<string, boolean>
}
const settings = ref<Settings | null>(null)
async function load() {
  try {
    settings.value = await api<Settings>('/api/settings')
    panelUrl.value = settings.value.panel_url
  } catch (e) {
    toast(errorText(e), 'err')
  }
}
onMounted(load)

// ── roomkey: alerts, DNS, backup ─────────────────────────────────────────────
const rk = ref<{ telegram_chat: string; telegram_token_set: boolean; dns_token_set: boolean; dns_zone_set: boolean
  admin_hosts: string[]; install_ready: boolean } | null>(null)
const tg = reactive({ token: '', chat: '', error: '', busy: false })
async function loadRoomkey() {
  try {
    rk.value = await api('/api/roomkey/settings')
    tg.chat = rk.value!.telegram_chat
  } catch (e) {
    toast(errorText(e), 'err')
  }
}
onMounted(loadRoomkey)
async function saveTelegram(clear = false) {
  tg.error = ''
  tg.busy = true
  try {
    const body = clear ? { telegram_token: '', telegram_chat: '' } : { ...(tg.token ? { telegram_token: tg.token } : {}), telegram_chat: tg.chat }
    await api('/api/roomkey/settings', { method: 'PUT', body: JSON.stringify(body) })
    tg.token = ''
    toast(clear ? '已关闭 Telegram 告警' : '已保存')
    await loadRoomkey()
  } catch (e) {
    tg.error = errorText(e)
  } finally {
    tg.busy = false
  }
}
async function testTelegram() {
  tg.error = ''
  try {
    await api('/api/roomkey/telegram-test', { method: 'POST' })
    toast('测试消息已发出，去 Telegram 看看')
  } catch (e) {
    tg.error = errorText(e)
  }
}

// ── the panel's address ──────────────────────────────────────────────────────
const panelUrl = ref('')
const urlError = ref('')
// what the Worker accepts: https, or http for this machine or a LAN (a test panel)
const urlHint = computed(() => {
  const u = panelUrl.value.trim()
  if (!u || u.startsWith('https://')) return ''
  return /^http:\/\/(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|[^./:]+(:|$))/.test(u)
    ? 'http:// 只适合本机或内网的测试面板' : '要用 https://：节点的密钥和服务器的令牌经这个地址传输'
})
async function saveUrl() {
  urlError.value = ''
  try {
    await api('/api/settings', { method: 'PUT', body: JSON.stringify({ panel_url: panelUrl.value }) })
    toast('已保存。之后生成的安装命令和订阅地址都用这个地址')
    await load()
  } catch (e) {
    urlError.value = errorText(e)
  }
}

// ── the key D1 is encrypted with ─────────────────────────────────────────────
const reveal = reactive({ password: '', key: '', error: '', busy: false })
async function revealKey() {
  Object.assign(reveal, { error: '', busy: true })
  try {
    const r = await api<{ token_key: string }>('/api/settings/token-key/reveal', { method: 'POST', body: JSON.stringify({ password: reveal.password }) })
    Object.assign(reveal, { key: r.token_key, password: '' })
  } catch (e) {
    Object.assign(reveal, { error: errorText(e), password: '' })
  } finally {
    reveal.busy = false
  }
}
async function forgetKey() {
  const ok = await confirmAction({
    title: '删除数据库里的密钥副本？', danger: true, ok: '删除副本', typed: 'TOKEN_KEY',
    body: '之后密钥只在 Cloudflare 的 TOKEN_KEY 机密里：导出的数据库单独拿走也解不开。\n这个机密以后不能删也不能改——没有它，面板里的节点、订阅都读不出来。',
  })
  if (!ok) return
  try {
    await api('/api/settings/token-key/forget', { method: 'POST' })
    reveal.key = ''
    toast('数据库里的密钥副本已删除')
    await load()
  } catch (e) {
    toast(errorText(e), 'err')
  }
}


// ── the IP check's optional databases (their free API keys) ─────────────────
const IPCHECK_DBS = [
  { id: 'abuseipdb', label: 'AbuseIPDB', help: '滥用置信度、使用类型、Tor', url: 'https://www.abuseipdb.com/account/api' },
  { id: 'ipqs', label: 'IPQualityScore', help: '欺诈分、代理、VPN、Tor、近期滥用、机器人', url: 'https://www.ipqualityscore.com/create-account' },
  { id: 'ip2location', label: 'IP2Location.io', help: '额度更高；付费套餐还有使用类型和代理细项', url: 'https://www.ip2location.io/sign-up' },
]
const ipKeys = reactive<Record<string, string>>({ abuseipdb: '', ipqs: '', ip2location: '' })
const ipKeysError = ref('')
async function saveIpKeys(clear?: string) {
  ipKeysError.value = ''
  const body = clear ? { [clear]: '' } : Object.fromEntries(Object.entries(ipKeys).filter(([, v]) => v.trim()))
  if (!Object.keys(body).length) return
  try {
    await api('/api/settings', { method: 'PUT', body: JSON.stringify({ ipcheck_keys: body }) })
    for (const k of Object.keys(ipKeys)) ipKeys[k] = ''
    toast(clear ? '已清除' : '已保存。之后的 IP 检测会多这几家数据库')
    await load()
  } catch (e) {
    ipKeysError.value = errorText(e)
  }
}

// ── sessions ─────────────────────────────────────────────────────────────────
async function signOutEverywhere() {
  if (!(await confirmAction({ title: '退出所有设备？', body: '所有浏览器里的登录（包括这一个）都会失效，需要重新输入密码。', ok: '全部退出', danger: true }))) return
  await api('/api/logout', { method: 'POST' }).catch(() => undefined)
  window.dispatchEvent(new Event('psm:signed-out'))
}
</script>

<template>
  <div class="page-head">
    <div><h1>系统设置</h1></div>
  </div>

  <!-- updates first: what this page is visited for most -->
  <UpdatesCard v-if="settings" />

  <div v-if="settings" class="grid-2 section">
    <div class="card card-pad">
      <form class="field" style="margin: 0" @submit.prevent="saveUrl">
        <label>面板地址</label>
        <div class="cmd">
          <input v-model="panelUrl" class="input" :placeholder="settings.effective_panel_url" data-test="panel-url">
          <button class="btn primary" type="submit" :disabled="panelUrl.trim() === (settings.panel_url ?? '')" data-test="save-settings">保存</button>
        </div>
        <div v-if="urlError" class="error-text" data-test="panel-url-error">{{ urlError }}</div>
        <div v-else-if="urlHint" class="help" style="color: var(--warn)">{{ urlHint }}</div>
        <div class="help">安装命令和订阅地址用它；留空用当前访问的地址（{{ settings.effective_panel_url }}）。</div>
      </form>
    </div>
    <div class="card card-pad">
      <dl class="facts">
        <dt>同步间隔</dt><dd>空闲时每 {{ settings.sync_interval }} 秒，有任务时每 3 秒</dd>
        <dt>源代码</dt><dd><a href="https://github.com/The1UNeed/roomkey-public" target="_blank" rel="noopener noreferrer">github.com/The1UNeed/roomkey-public</a>（基于 <a href="https://github.com/jinqians/proxy-stack" target="_blank" rel="noopener noreferrer">PSM</a>）</dd>
      </dl>
    </div>
  </div>

  <!-- where the key lives -->
  <div v-if="settings" class="card card-pad section" data-test="token-key">
    <div class="hstack" style="margin-bottom: 10px"><Icon name="key" /><strong>数据加密密钥</strong>
      <span class="badge" :class="{ ok: settings.token_key === 'secret', warn: settings.token_key === 'panel' || settings.token_key === 'both', err: settings.token_key === 'mismatch' }"
            :data-test="`token-key-${settings.token_key}`">
        {{ { secret: '只在机密里', panel: '保存在数据库里', both: '机密里也有了', mismatch: '机密和数据不一致' }[settings.token_key] }}
      </span>
    </div>
    <p v-if="settings.token_key === 'secret'" class="muted" style="margin: 0">节点的密码、链接和订阅地址用 Cloudflare 机密 <code>TOKEN_KEY</code> 加密后存进 D1；数据库里没有密钥，单独拿走解不开。这个机密不能删也不能改。</p>
    <template v-else>
      <div v-if="settings.token_key === 'panel'" class="notice warn">
        <strong>密钥和它加密的数据放在同一个数据库里。</strong>
        一键部署时面板自己生成了密钥并存进 D1：谁拿到数据库的导出，就能解开所有节点的密码。
        把它挪进 Cloudflare 机密：① 输入管理员密码查看密钥；② 在 Worker 的“设置 → 变量和机密”里添加机密 <code>TOKEN_KEY</code>，值就是这把密钥（一字不差）；③ 部署生效后回到这里删除数据库里的副本。
      </div>
      <div v-else-if="settings.token_key === 'both'" class="notice info">
        <strong>TOKEN_KEY 机密已经和数据库里的密钥一致。</strong>现在可以删除数据库里的副本。
      </div>
      <div v-else class="notice err">
        <strong>TOKEN_KEY 机密不是写入数据时用的那把密钥。</strong>之前保存的节点、订阅现在解不开。把 TOKEN_KEY 改成数据库里的这把（下面可以查看），或者删掉这个机密。
      </div>
      <div v-if="reveal.key" class="field">
        <label>密钥（base64）</label>
        <SecretText :value="reveal.key" test="token-key-value" copied="已复制密钥" />
        <div class="help">只给 Cloudflare 的机密用，不要贴到别处。</div>
      </div>
      <form v-else class="cmd" style="max-width: 520px" @submit.prevent="revealKey">
        <input v-model="reveal.password" class="input" type="password" autocomplete="current-password" placeholder="管理员密码" data-test="reveal-password">
        <button class="btn" type="submit" :disabled="!reveal.password || reveal.busy" data-test="reveal-key">查看密钥</button>
      </form>
      <div v-if="reveal.error" class="error-text">{{ reveal.error }}</div>
      <button v-if="settings.token_key === 'both'" class="btn danger" type="button" style="margin-top: 12px" data-test="forget-key" @click="forgetKey">
        <Icon name="trash" />删除数据库里的副本
      </button>
    </template>
  </div>

  <div v-if="settings" class="grid-2 section">
    <div class="card card-pad" data-test="ipcheck-keys">
      <form class="field" style="margin: 0" @submit.prevent="saveIpKeys()">
        <label>IP 质量检测的数据库（可选）</label>
        <div v-for="d in IPCHECK_DBS" :key="d.id" class="ipk">
          <span class="ipk-name"><a :href="d.url" target="_blank" rel="noopener noreferrer">{{ d.label }}</a></span>
          <input v-model="ipKeys[d.id]" class="input" type="password" autocomplete="off" :data-test="`ipcheck-key-${d.id}`"
                 :placeholder="settings.ipcheck_keys?.[d.id] ? '已保存（留空不修改）' : `API Key：${d.help}`">
          <button v-if="settings.ipcheck_keys?.[d.id]" class="link-btn" type="button" @click="saveIpKeys(d.id)">清除</button>
        </div>
        <div v-if="ipKeysError" class="error-text">{{ ipKeysError }}</div>
        <div class="help">不填也能检测。填了免费 Key，服务器页的「IP 质量与解锁」会多这几家的风险分和风险因子。Key 加密保存，检测时经标准输入交给服务器。</div>
        <div><button class="btn primary" type="submit" :disabled="!Object.values(ipKeys).some((v) => v.trim())" data-test="save-ipcheck-keys">保存</button></div>
      </form>
    </div>
    <div v-if="rk" class="card card-pad" data-test="telegram">
      <form class="field" style="margin: 0" @submit.prevent="saveTelegram()">
        <label>Telegram 告警（可选）</label>
        <div class="row2">
          <input v-model="tg.token" class="input" type="password" autocomplete="off" data-test="tg-token"
                 :placeholder="rk.telegram_token_set ? '已保存（留空不修改）' : 'Bot Token，从 @BotFather 拿'">
          <input v-model="tg.chat" class="input" placeholder="Chat ID，例如 123456789" data-test="tg-chat">
        </div>
        <div v-if="tg.error" class="error-text">{{ tg.error }}</div>
        <div class="help">服务器离线和恢复、用户流量用完 / 过期 / 设备超限、有人登录本机页面时发消息。先给机器人发一条消息，它才能给你发。</div>
        <div class="hstack">
          <button class="btn primary" type="submit" :disabled="tg.busy || (!tg.token && tg.chat === rk.telegram_chat)" data-test="tg-save">保存</button>
          <button v-if="rk.telegram_token_set" class="btn" type="button" data-test="tg-test" @click="testTelegram">发测试消息</button>
          <button v-if="rk.telegram_token_set" class="link-btn" type="button" @click="saveTelegram(true)">关闭</button>
        </div>
      </form>
    </div>
    <div v-if="rk" class="card card-pad" data-test="deploy-state">
      <div class="field-label">部署</div>
      <p class="muted" style="margin: 0">
        <span class="status" :class="rk.install_ready ? 'ok' : 'err'"><span class="dot" />{{ rk.install_ready ? 'INSTALL_URL 已设置' : '没有设置 INSTALL_URL：安装命令不可用' }}</span><br>
        <span class="status" :class="rk.admin_hosts.length ? 'ok' : 'pending'"><span class="dot" />{{ rk.admin_hosts.length ? `后台只在 ${rk.admin_hosts.join('、')} 上开放` : '没有设置 ADMIN_HOSTS：后台在每个域名上都能打开' }}</span><br>
        新服务器用安装命令从 INSTALL_URL / PSM_REPO 装上 roomkey 版的 PSM 和服务器组件；部署脚本会自动设好这两个变量。订阅域名只提供订阅和服务器接入的接口。
      </p>
    </div>
    <div v-if="rk" class="card card-pad">
      <div class="field-label">域名跟随 IP</div>
      <p class="muted" style="margin: 0">
        <span class="status" :class="rk.dns_token_set ? 'ok' : 'pending'"><span class="dot" />{{ rk.dns_token_set ? 'CF_DNS_TOKEN 已设置' : '没有设置 CF_DNS_TOKEN' }}</span><br>
        在「服务器 → ⋯ → 域名跟随 IP」给每台服务器设一个域名，面板会在它换 IP 后自动改 DNS。需要 Worker 密钥 <code>CF_DNS_TOKEN</code>：Cloudflare API 令牌，权限「区域 · DNS · 编辑」，只给服务器用的那一个域名（区域）；再设变量 <code>CF_ZONE_ID</code>{{ rk.dns_zone_set ? '（已设置）' : '' }}，或者给令牌加上「区域 · 区域 · 读取」让面板自己找。
      </p>
    </div>
    <div class="card card-pad">
      <div class="field-label">备份</div>
      <p class="muted" style="margin: 0 0 12px">导出服务器、节点、订阅、用户和设置，是可以直接恢复的 SQL（<code>wrangler d1 execute --file</code>，文件开头有步骤）。节点和用户的密钥仍是加密的，恢复时要用同一个 TOKEN_KEY（见上面「数据加密密钥」），请分开保存；流量历史和任务不在里面。Cloudflare D1 自带 Time Travel，也可以回到过去 7 天（免费版）或 30 天（付费版）内的任意时刻。</p>
      <a class="btn" href="/api/backup" download data-test="backup"><Icon name="download" />下载备份</a>
    </div>
    <div class="card card-pad">
      <div class="field-label">登录</div>
      <p class="muted" style="margin: 0 0 12px">登录保持 7 天。退出登录会让所有设备上的登录一起失效；修改 ADMIN_PASSWORD 也一样。</p>
      <button class="btn" type="button" data-test="sign-out-everywhere" @click="signOutEverywhere"><Icon name="logout" />退出所有设备</button>
    </div>
  </div>
</template>

<style scoped>
.ipk { display: grid; grid-template-columns: 120px minmax(0, 1fr) auto; gap: 8px; align-items: center; margin-bottom: 8px }
.ipk-name { font-size: 13px }
@media (max-width: 640px) { .ipk { grid-template-columns: minmax(0, 1fr) auto } .ipk-name { grid-column: 1 / -1 } }
</style>
