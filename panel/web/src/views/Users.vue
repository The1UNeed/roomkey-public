<script setup lang="ts">
// 用户: the people who use the nodes — their state, this period's traffic,
// expiry, devices online, and their own subscription link.
import { computed, onMounted, ref } from 'vue'
import { api, ago, beijingDate, errorText, formatBytes, localTime, USER_STATE_CLASS, type PanelNode, type PanelUser, type Server } from '../api'
import { confirmAction, toast, usePoll } from '../ui'
import Icon from '../components/Icon.vue'
import Modal from '../components/Modal.vue'
import SecretText from '../components/SecretText.vue'
import UserDialog from '../components/UserDialog.vue'
import BarChart from '../components/BarChart.vue'

const users = ref<PanelUser[]>([])
const servers = ref<Server[]>([])
const nodes = ref<PanelNode[]>([])
const loaded = ref(false)
const query = ref('')
const dialog = ref<{ user: PanelUser | null } | null>(null)
const detail = ref<PanelUser | null>(null)

async function load() {
  try {
    ;[users.value, servers.value, nodes.value] = await Promise.all([
      api<PanelUser[]>('/api/users'), api<Server[]>('/api/servers'), api<PanelNode[]>('/api/nodes')])
  } catch (e) {
    toast(errorText(e), 'err')
  } finally {
    loaded.value = true
  }
}
onMounted(load)
usePoll(load, 30000)

const shown = computed(() => {
  const q = query.value.trim().toLowerCase()
  return q ? users.value.filter((u) => u.name.includes(q) || u.note.toLowerCase().includes(q)) : users.value
})
const counts = computed(() => ({
  active: users.value.filter((u) => u.state === 'active').length,
  paused: users.value.filter((u) => u.state !== 'active' && u.state !== 'disabled').length,
  online: users.value.reduce((a, u) => a + (u.online > 0 ? 1 : 0), 0),
}))
const pct = (u: PanelUser) => (u.quota_total_bytes ? Math.min(100, Math.round((u.used_total_bytes / u.quota_total_bytes) * 100)) : 0)
const expiryText = (u: PanelUser) => u.expires_at ? beijingDate(u.expires_at)
  : u.first_use_days ? `首次使用后 ${u.first_use_days} 天` : '长期'
const daysLeft = (u: PanelUser) => {
  if (!u.expires_at) return null
  const d = Math.ceil((Date.parse(u.expires_at.replace(' ', 'T') + 'Z') - Date.now()) / 86_400_000)
  return d
}
const tokenOf = (url?: string) => url?.split('/sub/')[1] ?? ''

async function open(u: PanelUser) {
  try {
    detail.value = await api<PanelUser>(`/api/users/${u.id}`)
  } catch (e) {
    toast(errorText(e), 'err')
  }
}
async function act(u: PanelUser, path: string, msg: string, confirm?: { title: string; body: string; ok: string }) {
  if (confirm && !(await confirmAction({ ...confirm, danger: true }))) return
  try {
    const r = await api<PanelUser>(`/api/users/${u.id}/${path}`, { method: 'POST' })
    toast(msg)
    if (detail.value?.id === u.id) detail.value = r
    await load()
  } catch (e) {
    toast(errorText(e), 'err')
  }
}
async function toggle(u: PanelUser) {
  try {
    await api(`/api/users/${u.id}`, { method: 'PATCH', body: JSON.stringify({ enabled: !u.enabled }) })
    toast(u.enabled ? `已停用 ${u.name}` : `已启用 ${u.name}`)
    await load()
  } catch (e) {
    toast(errorText(e), 'err')
  }
}
async function remove(u: PanelUser) {
  if (!(await confirmAction({ title: `删除用户 ${u.name}？`, body: '所有服务器上都会删掉这个用户，订阅链接失效。', ok: '删除', danger: true, typed: u.name }))) return
  try {
    await api(`/api/users/${u.id}`, { method: 'DELETE' })
    toast(`已删除 ${u.name}`)
    detail.value = null
    await load()
  } catch (e) {
    toast(errorText(e), 'err')
  }
}
function saved(u: PanelUser) {
  dialog.value = null
  load()
  if (detail.value?.id === u.id || !detail.value) detail.value = u
}
const accessText = (u: PanelUser) => u.access.some((a) => a.kind === 'all') ? '全部节点'
  : u.access.filter((a) => a.kind === 'label').map((a) => a.value).join('、') || `${u.access.length} 个指定节点`
</script>

<template>
  <div class="page-head">
    <div><h1>用户</h1><p>每个用户一个订阅链接，在分到的节点上用同一套密钥。流量、期限、设备数到了就自动暂停。</p></div>
    <button class="btn primary" type="button" data-test="user-new" @click="dialog = { user: null }"><Icon name="plus" />新建用户</button>
  </div>

  <div class="stats section">
    <div class="card stat"><span class="l">用户</span><span class="n">{{ users.length }}</span><span class="s">{{ counts.active }} 个正常</span></div>
    <div class="card stat"><span class="l">已暂停</span><span class="n">{{ counts.paused }}</span><span class="s">流量用完、过期或设备超限</span></div>
    <div class="card stat"><span class="l">在线</span><span class="n">{{ counts.online }}</span><span class="s">最近 15 分钟有连接</span></div>
  </div>

  <div class="card table-wrap">
    <div class="table-tools">
      <input v-model="query" class="input small" placeholder="搜索用户名或备注" style="max-width: 240px" data-test="user-search">
    </div>
    <table>
      <thead><tr><th>用户</th><th>状态</th><th>本周期流量</th><th>到期</th><th>节点</th><th>设备</th><th class="actions">操作</th></tr></thead>
      <tbody>
        <tr v-for="u in shown" :key="u.id" class="clickable" :data-test="`user-${u.name}`" @click="open(u)">
          <td><b>{{ u.name }}</b><div v-if="u.note" class="muted small">{{ u.note }}</div></td>
          <td>
            <span class="status" :class="USER_STATE_CLASS[u.state]"><span class="dot" />{{ u.state_label }}</span>
            <div v-if="u.blocked_reason && u.state === 'devices'" class="muted small">{{ u.blocked_reason }}</div>
          </td>
          <td style="min-width: 150px">
            {{ formatBytes(u.used_total_bytes) }}<span v-if="u.quota_total_bytes" class="muted"> / {{ formatBytes(u.quota_total_bytes) }}</span>
            <div v-if="u.quota_total_bytes" class="meter" style="margin-top: 3px"><span :class="{ over: pct(u) >= 80, full: pct(u) >= 100 }" :style="{ width: `${pct(u)}%` }" /></div>
            <div v-if="u.period_end" class="muted small">{{ u.period_end }} 重置</div>
          </td>
          <td>
            {{ expiryText(u) }}
            <div v-if="daysLeft(u) !== null && daysLeft(u)! >= 0 && daysLeft(u)! <= 7" class="small" style="color: var(--warn)">还剩 {{ daysLeft(u) }} 天</div>
          </td>
          <td class="small">{{ accessText(u) }}</td>
          <td class="small">{{ u.online }}{{ u.device_limit ? ` / ${u.device_limit}` : '' }}</td>
          <td class="actions" @click.stop>
            <button class="btn small ghost" :data-test="`user-edit-${u.name}`" @click="dialog = { user: u }"><Icon name="edit" />编辑</button>
            <button class="btn small ghost" @click="toggle(u)">{{ u.enabled ? '停用' : '启用' }}</button>
          </td>
        </tr>
      </tbody>
    </table>
    <div v-if="loaded && !users.length" class="empty">
      <div class="big">👤</div><p>还没有用户。新建一个，把订阅链接发给对方就能用。</p>
      <button class="btn primary" @click="dialog = { user: null }"><Icon name="plus" />新建用户</button>
    </div>
  </div>

  <UserDialog v-if="dialog" :user="dialog.user" :servers="servers" :nodes="nodes" @close="dialog = null" @saved="saved" />

  <Modal v-if="detail" :title="detail.name" size="wide" @close="detail = null">
    <template #subtitle>
      <p><span class="status" :class="USER_STATE_CLASS[detail.state]"><span class="dot" />{{ detail.state_label }}</span>
        <span v-if="detail.note" class="muted"> · {{ detail.note }}</span>
        <span class="muted"> · {{ detail.last_sub_at ? `客户端 ${ago(detail.last_sub_at)}更新过订阅` : '还没有客户端用过订阅' }}</span></p>
    </template>
    <div class="dialog-body">
      <div class="field">
        <label>订阅链接</label>
        <SecretText :value="detail.subscription!" :secret="tokenOf(detail.subscription)" test="user-sub-url" copied="已复制订阅链接" />
        <div class="help">发给 {{ detail.name }}。用浏览器打开会看到用量、到期和一键导入（Shadowrocket、Clash Verge、sing-box）；Throne 等客户端直接粘贴这个链接。</div>
      </div>
      <div class="row3 section">
        <div class="card stat"><span class="l">本周期</span><span class="n">{{ formatBytes(detail.used_total_bytes) }}</span>
          <span class="s">{{ detail.quota_total_bytes ? `共 ${formatBytes(detail.quota_total_bytes)}` : detail.servers.some((s) => s.quota_bytes) ? '只有单台服务器限额' : '不限流量' }}{{ detail.period_end ? ` · ${detail.period_end} 重置` : '' }}</span></div>
        <div class="card stat"><span class="l">到期</span><span class="n" style="font-size: 18px">{{ expiryText(detail) }}</span>
          <span class="s">{{ detail.first_used_at ? `首次使用 ${detail.first_used_at.slice(0, 10)}` : `创建于 ${localTime(detail.created_at)}` }}</span></div>
        <div class="card stat"><span class="l">在线设备</span><span class="n">{{ detail.online }}</span>
          <span class="s">{{ detail.device_limit ? `上限 ${detail.device_limit}` : '不限' }}</span></div>
      </div>
      <div v-if="detail.daily?.length" class="field">
        <label>最近 30 天</label>
        <BarChart :daily="detail.daily" :days="30" :since="detail.period_start" test="user-daily" />
      </div>
      <div v-if="detail.servers.length" class="field">
        <label>各服务器</label>
        <table class="compact">
          <thead><tr><th>服务器</th><th>本周期</th><th>单独限额</th></tr></thead>
          <tbody><tr v-for="s in detail.servers" :key="s.server_id">
            <td>{{ s.name }} <span v-if="s.paused_here" class="badge warn" title="这台服务器的本机页面暂停了这个用户">本机暂停</span>
              <span v-else-if="!s.nodes" class="badge" title="这个用户在这台服务器上没有分到节点（只剩用量或限额记录）">无节点</span>
              <span v-else-if="s.synced" class="badge ok" title="这台服务器已经有这个用户的密钥和节点">已下发</span>
              <span v-else class="badge warn" title="服务器还没接受这个用户（或新分到的节点）：这些节点暂时不在订阅里，几秒后再看">等待服务器</span></td>
            <td>{{ formatBytes(s.used_bytes) }}</td>
            <td>{{ s.quota_bytes ? formatBytes(s.quota_bytes) : '—' }}<span v-if="s.quota_bytes && s.used_bytes >= s.quota_bytes" class="badge err">已暂停</span></td>
          </tr></tbody>
        </table>
      </div>
      <div v-if="detail.online_ips?.length" class="field">
        <label>在线 IP</label>
        <div v-for="o in detail.online_ips" :key="o.server" class="small"><b>{{ o.server }}</b> <span class="mono">{{ o.ips.join(', ') }}</span></div>
      </div>
    </div>
    <template #foot>
      <button class="btn ghost danger" type="button" @click="remove(detail)"><Icon name="trash" />删除</button>
      <span class="spacer" />
      <button class="btn ghost" type="button" @click="act(detail, 'reset-usage', '本周期流量已清零', { title: `清零 ${detail.name} 本周期的流量？`, body: '所有服务器上这个周期已用的流量都从零开始算，流量用完而暂停的会恢复。', ok: '清零' })"><Icon name="refresh" />清零流量</button>
      <button class="btn ghost" type="button" @click="act(detail, 'reset-link', '订阅链接已更换', { title: `更换 ${detail.name} 的订阅链接？`, body: '旧链接立即失效，要把新链接重新发给对方。链接泄露了就换。', ok: '更换链接' })"><Icon name="link" />更换链接</button>
      <button class="btn ghost" type="button" @click="act(detail, 'reset-credentials', '密钥已更换', { title: `更换 ${detail.name} 的密钥？`, body: '新的 UUID 和密码几秒内下发到服务器，对方的客户端要更新订阅才能继续用。', ok: '更换密钥' })"><Icon name="key" />更换密钥</button>
      <button class="btn primary" type="button" @click="dialog = { user: detail }"><Icon name="edit" />编辑</button>
    </template>
  </Modal>
</template>

<style scoped>
.table-tools { padding: 12px 14px 0 }
tr.clickable { cursor: pointer }
tr.clickable:hover td { background: var(--hover) }
table.compact td, table.compact th { padding: 6px 8px }
</style>
