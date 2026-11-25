<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue'
import { ago, api, errorText, formatBytes, localTime, type Server } from '../api'
import { confirmAction, toast, usePoll } from '../ui'
import InstallCommand from '../components/InstallCommand.vue'
import IpCheckDialog from '../components/IpCheckDialog.vue'
import Modal from '../components/Modal.vue'
import RowMenu from '../components/RowMenu.vue'
import SecretText from '../components/SecretText.vue'
import Icon from '../components/Icon.vue'

const servers = ref<Server[]>([])
const ipcheck = ref<Server | null>(null)
const loaded = ref(false)
async function load() {
  try { servers.value = await api<Server[]>('/api/servers') } catch (e) { toast(errorText(e), 'err') } finally { loaded.value = true }
}
onMounted(load)
usePoll(load, 30000, () => servers.value.some((s) => s.status === 'leaving' || s.status === 'pending'), 4000)

const statusText = { online: '在线', pending: '待接入', offline: '离线', leaving: '卸载中' } as const
const outdated = (s: Server) => !!s.agent_version && !!s.agent_latest && s.agent_version !== s.agent_latest
const flag = (cc: string | null) => (cc && /^[A-Z]{2}$/.test(cc) ? String.fromCodePoint(...[...cc].map((c) => 0x1f1a5 + c.charCodeAt(0))) : '')

// ── adding one, and its install command ──────────────────────────────────────
const add = reactive({ open: false, name: '', note: '', busy: false, error: '' })
const command = ref<{ server: string; id: number; text: string } | null>(null)
async function submitAdd() {
  Object.assign(add, { busy: true, error: '' })
  try {
    const name = add.name.trim().toLowerCase()
    const r = await api<{ id: number; install_command: string }>('/api/servers', { method: 'POST', body: JSON.stringify({ name, note: add.note.trim() }) })
    add.open = false
    command.value = { server: name, id: r.id, text: r.install_command }
    add.name = add.note = ''
    await load()
  } catch (e) {
    add.error = errorText(e)
  } finally {
    add.busy = false
  }
}
// the server's install command: the same one while it is valid; 重新生成 makes
// a new one and the old one stops working
async function newCommand(s: { id: number; name: string }, fresh = false) {
  if (fresh && !(await confirmAction({ title: '重新生成安装命令？', ok: '重新生成', danger: true,
    body: '之前给出的命令（包括新建节点时显示的）立即失效。命令被别人看到了才需要这样做。' }))) return
  try {
    const r = await api<{ install_command: string }>(`/api/servers/${s.id}/install-command`, { method: 'POST', body: JSON.stringify({ fresh }) })
    command.value = { server: s.name, id: s.id, text: r.install_command }
    if (fresh) toast('已重新生成，旧命令已失效')
  } catch (e) {
    toast(errorText(e), 'err')
  }
}

// ── editing: the note ────────────────────────────────────────────────────────
const edit = reactive({ server: null as Server | null, note: '', error: '', busy: false })
function openEdit(s: Server) {
  Object.assign(edit, { server: s, note: s.note, error: '', busy: false })
}
async function saveEdit() {
  const s = edit.server!
  Object.assign(edit, { busy: true, error: '' })
  try {
    await api(`/api/servers/${s.id}`, { method: 'PATCH', body: JSON.stringify({ note: edit.note }) })
    edit.server = null
    toast(`已保存 ${s.name}`)
    await load()
  } catch (e) {
    edit.error = errorText(e)
  } finally {
    edit.busy = false
  }
}

// ── removing ─────────────────────────────────────────────────────────────────
// A joined, online server uninstalls on it what the panel made (its nodes,
// standalone Snell / ss-rust, psm-agent); an offline one (or one stuck
// leaving) can only be removed from the panel.
async function remove(s: Server) {
  // one already leaving that still syncs is asked again (the panel re-sends
  // its leave if it never went out); one that stopped syncing can only be forgotten
  const recent = !!s.last_seen && Date.now() - new Date(s.last_seen.replace(' ', 'T') + 'Z').getTime() < 3 * 60_000
  const retry = s.status === 'leaving' && recent
  const onServer = s.status === 'online' || retry
  const ok = await confirmAction(s.status === 'pending'
    ? { title: `移除服务器 ${s.name}？`, body: '它还没有接入，节点记录会一起删除。', ok: '移除', danger: true }
    : retry
      ? { title: `再次卸载 ${s.name}？`, ok: '再次卸载',
          body: `${s.name} 正在卸载面板建的内容。没有进展的话，这会重新发出卸载。` }
    : onServer
      ? { title: `移除服务器 ${s.name}？`, danger: true, ok: '卸载并移除', typed: s.name,
          body: '服务器上由面板建的节点、独立安装的 Snell / ss-rust 和 psm-agent 会被卸载。\nPSM 本身、内核和在服务器命令行里建的节点会保留。' }
      : { title: `只从面板移除 ${s.name}？`, danger: true, ok: '只从面板移除',
          body: `${s.name} 现在${s.status === 'leaving' ? '没有回应' : '离线'}，无法在服务器上卸载。\n服务器上的节点和 psm-agent 会保留；之后可以在服务器上执行 psm agent remove --yes 卸载 psm-agent。` })
  if (!ok) return
  try {
    await api(`/api/servers/${s.id}${onServer || s.status === 'pending' ? '' : '?force=1'}`, { method: 'DELETE' })
    toast(onServer ? `正在卸载 ${s.name} 上由面板建的内容，完成后它会从列表里消失` : `${s.name} 已移除`)
  } catch (e) {
    toast(errorText(e), 'err')
  }
  await load()
}

// ── psm-agent and PSM on the server ──────────────────────────────────────────
// The same task: PSM is updated first, then the psm-agent PSM names is
// installed (a current one stays). The panel asks for the nodes' links again
// once the server reports the new PSM version.
async function upgrade(s: Server) {
  const agent = outdated(s)
  const ok = await confirmAction(agent
    ? { title: `升级 ${s.name} 的 psm-agent？`, ok: '升级', body: `从 ${s.agent_version} 升级到 ${s.agent_latest}。服务器上会先更新 PSM，检查内核的启动检查并撤下中转（运行中的内核会重启一下），再替换 psm-agent 并重启它。` }
    : { title: `更新 ${s.name} 上的 PSM？`, ok: '更新', body: '更新到最新版；会先检查内核的启动检查并撤下中转（运行中的内核会重启一下）。更新后面板会重新取一次节点的链接和订阅（服务器下次报告版本时，最多一小时；点「诊断」立即生效）。' })
  if (!ok) return
  try {
    await api(`/api/servers/${s.id}/upgrade-agent`, { method: 'POST' })
    toast(agent ? `已通知 ${s.name} 升级 psm-agent，完成后版本列会变成 ${s.agent_latest}` : `已通知 ${s.name} 更新 PSM`)
  } catch (e) {
    toast(errorText(e), 'err')
  }
}

// ── diagnostics ──────────────────────────────────────────────────────────────
type Check = { id?: string; status?: string; message?: string }
type Report = {
  psm_version?: string; agent_version?: string
  cores?: { core: string; installed: boolean; version: string; active: boolean }[] | null
  doctor?: { checks?: Check[]; results?: Check[] } | null
  nodes?: { items?: unknown[] } | null
  snell?: { installed: boolean; active: boolean; port: number | null; version: string } | null
  ss2022?: { installed: boolean; active: boolean; port: number | null; method: string } | null
}
const diag = ref<{ server: Server; at: string | null; pending: boolean; report: Report | null } | null>(null)
let poll: ReturnType<typeof setInterval> | undefined
async function readStatus(s: Server) {
  const r = await api<{ at: string | null; pending: boolean; report: Report | null }>(`/api/servers/${s.id}/status`)
  if (diag.value?.server.id !== s.id) return
  diag.value = { server: s, ...r }
  if (!r.pending) clearInterval(poll)
}
async function diagnose(s: Server) {
  clearInterval(poll)
  diag.value = { server: s, at: null, pending: true, report: null }
  try {
    await api(`/api/servers/${s.id}/status`, { method: 'POST' })
    await readStatus(s)
    poll = setInterval(() => readStatus(s).catch(() => undefined), 3000)
  } catch (e) {
    diag.value = null
    toast(errorText(e), 'err')
  }
}
function closeDiag() {
  clearInterval(poll)
  diag.value = null
}
onUnmounted(() => clearInterval(poll))
const checks = (r: Report) => r.doctor?.checks ?? r.doctor?.results ?? []
// psm doctor says ok, skipped (nothing there to check), warning or critical
const QUIET = ['ok', 'pass', 'skipped', 'info']
const problems = (r: Report) => checks(r).filter((c) => c.status && !QUIET.includes(c.status))
const skipped = (r: Report) => checks(r).filter((c) => c.status === 'skipped').length
const leavingLong = (s: Server) => s.status === 'leaving'
// ── roomkey: the host name and the local page ─────────────────────────────────
const dns = ref<{ server: Server; name: string; busy: boolean; error: string } | null>(null)
async function saveDns() {
  const d = dns.value!
  d.busy = true
  d.error = ''
  try {
    const r = await api<{ dns_name: string | null; dns_ip: string | null; dns_error: string | null }>(`/api/servers/${d.server.id}/dns`,
      { method: 'PUT', body: JSON.stringify({ dns_name: d.name }) })
    if (r.dns_error) d.error = r.dns_error
    else {
      toast(r.dns_name ? `${r.dns_name} → ${r.dns_ip ?? '下次同步时更新'}` : '已关闭域名跟随')
      dns.value = null
    }
    await load()
  } catch (e) {
    d.error = errorText(e)
  } finally {
    d.busy = false
  }
}
const local = ref<{ server: string; code: string; ssh: string | null; url: string; expires: number } | null>(null)
async function localPage(s: Server) {
  try {
    const r = await api<{ code: string; ssh: string | null; url: string; expires_in: number }>(`/api/servers/${s.id}/local-code`, { method: 'POST' })
    local.value = { server: s.name, code: r.code, ssh: r.ssh, url: r.url, expires: r.expires_in }
  } catch (e) {
    toast(errorText(e), 'err')
  }
}

const counts = computed(() => ({
  online: servers.value.filter((s) => s.status === 'online').length,
  outdated: servers.value.filter((s) => s.status === 'online' && outdated(s)).length,
}))
</script>

<template>
  <div class="page-head">
    <div>
      <h1>服务器</h1>
      <p>{{ servers.length }} 台，{{ counts.online }} 台在线<template v-if="counts.outdated">，{{ counts.outdated }} 台的 psm-agent 可升级</template>。服务器由 psm-agent 主动连接面板，不需要开放端口。</p>
    </div>
    <div class="page-actions">
      <button class="btn primary" data-test="add-server-open" @click="add.open = true"><Icon name="plus" />添加服务器</button>
    </div>
  </div>

  <div class="card">
    <div class="table-wrap">
      <table>
        <thead><tr><th>服务器</th><th>状态</th><th>地址</th><th>PSM / Agent</th><th class="num">节点</th><th class="num">本月流量</th><th class="actions">操作</th></tr></thead>
        <tbody>
          <tr v-for="s in servers" :key="s.id" :data-test="`server-${s.name}`" :data-status="s.status">
            <td><b>{{ s.name }}</b><span class="sub">{{ s.hostname ?? (s.note || '—') }}</span></td>
            <td>
              <span class="status" :class="s.status"><span class="dot" />{{ statusText[s.status] }}</span>
              <span v-if="s.leave_error" class="badge err" :title="s.leave_error">卸载失败</span>
              <span class="sub" :title="localTime(s.last_seen)">{{ s.last_seen ? `同步于 ${ago(s.last_seen)}` : '从未同步' }}</span>
            </td>
            <td>
              <span class="mono">{{ s.last_ip ?? '—' }}</span>
              <span v-if="s.dns_name" class="sub mono" :title="s.dns_error ?? (s.dns_ip ? `已指向 ${s.dns_ip}` : '下次同步时更新')">
                {{ s.dns_name }}<span v-if="s.dns_error" class="badge err">DNS 出错</span></span>
              <span v-if="s.asn" class="sub">{{ flag(s.country) }} AS{{ s.asn }}{{ s.country ? ` · ${s.country}` : '' }}</span>
              <span v-if="s.users_error" class="badge warn" :title="s.users_error">用户未下发</span>
            </td>
            <td>
              <span class="small">{{ s.psm_version ?? '—' }}</span>
              <span class="sub">agent {{ s.agent_version ?? '—' }}
                <button v-if="outdated(s) && s.status === 'online'" class="badge accent link-btn" style="border: 0" :title="`可升级到 ${s.agent_latest}`"
                        :data-test="`upgrade-badge-${s.name}`" @click="upgrade(s)">可升级</button></span>
            </td>
            <td class="num">{{ s.node_count }}</td>
            <td class="num">{{ formatBytes(s.traffic_used) }}</td>
            <td class="actions">
              <span class="row-actions">
                <button class="btn small ghost" :disabled="s.status === 'pending'" :data-test="`diagnose-${s.name}`" @click="diagnose(s)"><Icon name="stethoscope" />诊断</button>
                <button class="btn small ghost" :data-test="`command-${s.name}`" @click="newCommand(s)"><Icon name="terminal" />安装命令</button>
                <RowMenu :test="`more-${s.name}`">
                  <button v-if="outdated(s)" type="button" :disabled="s.status !== 'online'" :data-test="`upgrade-agent-${s.name}`" @click="upgrade(s)"><Icon name="upload" />升级 psm-agent</button>
                  <button v-else type="button" :disabled="s.status !== 'online'" :data-test="`update-psm-${s.name}`" @click="upgrade(s)"><Icon name="upload" />更新 PSM</button>
                  <button type="button" :disabled="s.status !== 'online'" :data-test="`ipcheck-${s.name}`" @click="ipcheck = s"><Icon name="nodes" />IP 质量与解锁</button>
                  <button type="button" :data-test="`edit-server-${s.name}`" @click="openEdit(s)"><Icon name="edit" />备注</button>
                  <button type="button" :data-test="`dns-${s.name}`" @click="dns = { server: s, name: s.dns_name ?? '', busy: false, error: '' }"><Icon name="link" />域名跟随 IP</button>
                  <button type="button" :disabled="s.status !== 'online'" :data-test="`local-${s.name}`" @click="localPage(s)"><Icon name="terminal" />本机页面</button>
                  <hr>
                  <button type="button" class="danger" :data-test="`remove-${s.name}`" @click="remove(s)"><Icon name="trash" />{{ leavingLong(s) ? '只从面板移除' : '移除' }}</button>
                </RowMenu>
              </span>
            </td>
          </tr>
        </tbody>
      </table>
      <div v-if="!loaded" class="skeleton-rows"><div v-for="i in 3" :key="i" class="skeleton" style="height: 26px" /></div>
      <div v-else-if="!servers.length" class="empty">
        <div class="big">▤</div>
        <p>还没有服务器。添加一台，在它上面以 root 执行给出的命令即可接入（没装 PSM 也可以）。</p>
        <button class="btn primary" @click="add.open = true"><Icon name="plus" />添加服务器</button>
      </div>
    </div>
  </div>

  <!-- roomkey: the host name that follows the server's address -->
  <Modal v-if="dns" :title="`${dns.server.name} 的域名`" size="narrow" @close="dns = null">
    <template #subtitle><p>面板把这个域名的 A 记录一直指向服务器当前的 IPv4（{{ dns.server.last_ip ?? '还没同步过' }}），不走 Cloudflare 代理。节点地址填这个域名，换 IP 后客户端不用改。</p></template>
    <div class="dialog-body">
      <div class="field">
        <label>域名</label>
        <input v-model="dns.name" class="input mono" placeholder="n1.myroom.asia" data-test="dns-name" @keydown.enter.prevent="saveDns">
        <div class="help">要在 Cloudflare 管理的域名下，并设置 Worker 密钥 CF_DNS_TOKEN（权限：区域 · DNS · 编辑）。留空关闭。不要用带 vpn 的名字。</div>
      </div>
      <div v-if="dns.error" class="notice err">{{ dns.error }}</div>
    </div>
    <template #foot>
      <button class="btn ghost" type="button" @click="dns = null">取消</button>
      <button class="btn primary" type="button" :disabled="dns.busy" data-test="dns-save" @click="saveDns">{{ dns.busy ? '更新中…' : '保存' }}</button>
    </template>
  </Modal>

  <Modal v-if="local" :title="`${local.server} 的本机页面`" size="narrow" @close="local = null">
    <template #subtitle><p>本机页面只监听服务器的 127.0.0.1，要先用 SSH 转发端口，再在自己电脑的浏览器里打开。</p></template>
    <div class="dialog-body">
      <div class="field"><label>1. 在自己电脑上运行</label>
        <SecretText v-if="local.ssh" :value="local.ssh" test="local-ssh" copied="已复制命令" />
        <code v-else class="mono">ssh -L 2096:127.0.0.1:2096 root@&lt;服务器地址&gt;</code>
      </div>
      <div class="field"><label>2. 浏览器打开</label><code class="mono">{{ local.url }}</code></div>
      <div class="field"><label>3. 输入一次性代码</label>
        <div class="local-code" data-test="local-code">{{ local.code }}</div>
        <div class="help">{{ Math.round(local.expires / 60) }} 分钟内有效，只能用一次。服务器在下次同步（几秒内）后才认这个代码。</div>
      </div>
    </div>
    <template #foot><button class="btn primary" type="button" @click="local = null">好</button></template>
  </Modal>

  <!-- add a server -->
  <Modal v-if="add.open" title="添加服务器" subtitle="添加后会给出一键命令：在服务器上以 root 执行，安装 PSM（已有也可以）和 psm-agent 并接入面板。" size="narrow" @close="add.open = false">
    <form class="dialog-body" @submit.prevent="submitAdd">
      <div v-if="add.error" class="errors">{{ add.error }}</div>
      <div class="field">
        <label>名称</label>
        <input v-model="add.name" class="input" placeholder="例如 hk1" data-test="server-name">
        <div class="help">小写字母、数字和 -，1-32 位；节点和订阅里用它称呼这台服务器。</div>
      </div>
      <div class="field"><label>备注（可选）</label><input v-model="add.note" class="input" placeholder="例如 香港 CN2，月付"></div>
      <button type="submit" hidden />
    </form>
    <template #foot>
      <button class="btn ghost" type="button" @click="add.open = false">取消</button>
      <button class="btn primary" type="button" :disabled="add.busy || !add.name.trim()" data-test="add-server" @click="submitAdd">添加</button>
    </template>
  </Modal>

  <!-- the install command -->
  <Modal v-if="command" :title="`${command.server} 的安装命令`" @close="command = null">
    <div class="dialog-body" data-test="server-command">
      <p style="margin-top: 0">在 {{ command.server }} 上以 root 执行：</p>
      <InstallCommand :command="command.text" />
      <p class="help">24 小时内有效，只能用一次；再点“安装命令”看到的还是这一条。命令里的令牌能让一台机器以这台服务器的身份接入，不要外传。</p>
    </div>
    <template #foot>
      <button class="btn ghost danger left" type="button" data-test="regenerate-command" @click="newCommand({ id: command.id, name: command.server }, true)">重新生成</button>
      <button class="btn primary" type="button" @click="command = null">完成</button>
    </template>
  </Modal>

  <!-- the note -->
  <Modal v-if="edit.server" :title="`${edit.server.name}`" subtitle="备注" size="narrow" @close="edit.server = null">
    <form class="dialog-body" @submit.prevent="saveEdit">
      <div v-if="edit.error" class="errors">{{ edit.error }}</div>
      <div class="field"><label>备注</label><input v-model="edit.note" class="input" data-test="server-note"></div>
      <button type="submit" hidden />
    </form>
    <template #foot>
      <button class="btn ghost" type="button" @click="edit.server = null">取消</button>
      <button class="btn primary" type="button" :disabled="edit.busy" data-test="save-server" @click="saveEdit">保存</button>
    </template>
  </Modal>

  <IpCheckDialog v-if="ipcheck" :server="ipcheck" @close="ipcheck = null" />

  <!-- diagnostics -->
  <Modal v-if="diag" :title="`${diag.server.name} 的诊断`" @close="closeDiag">
    <div class="dialog-body" data-test="diagnostics">
      <p class="muted" style="margin-top: 0">
        <span v-if="diag.pending"><span class="spinner" /> 正在收集（psm doctor、内核、节点）…</span>
        <span v-else>收集于 {{ localTime(diag.at) }}</span>
      </p>
      <dl v-if="diag.report" class="facts">
        <dt>PSM 版本</dt><dd>{{ diag.report.psm_version || '—' }}</dd>
        <dt>psm-agent</dt><dd>{{ diag.report.agent_version || '—' }}</dd>
        <dt>内核</dt>
        <dd data-test="diag-cores">
          <span v-for="c in diag.report.cores ?? []" :key="c.core" class="label-chip">
            {{ c.core }}：{{ c.installed ? `${c.version}${c.active ? '（运行中）' : '（未运行）'}` : '未安装' }}
          </span>
        </dd>
        <dt>独立 Snell</dt><dd>{{ diag.report.snell?.installed ? `v${diag.report.snell.version}，端口 ${diag.report.snell.port}，${diag.report.snell.active ? '运行中' : '未运行'}` : '未安装' }}</dd>
        <dt>独立 SS2022</dt><dd>{{ diag.report.ss2022?.installed ? `${diag.report.ss2022.method}，端口 ${diag.report.ss2022.port}，${diag.report.ss2022.active ? '运行中' : '未运行'}` : '未安装' }}</dd>
        <dt>节点</dt><dd>{{ diag.report.nodes?.items?.length ?? 0 }} 个（PSM 里）</dd>
        <dt>psm doctor</dt>
        <dd data-test="diag-doctor">
          {{ checks(diag.report).length }} 项检查，{{ problems(diag.report).length ? `${problems(diag.report).length} 项需要注意` : '都正常' }}<span v-if="skipped(diag.report)" class="muted">（{{ skipped(diag.report) }} 项没有可查的，跳过）</span>
          <ul v-if="problems(diag.report).length" class="problems">
            <li v-for="p in problems(diag.report)" :key="p.id" :style="p.status === 'critical' ? { color: 'var(--err)' } : undefined">
              {{ p.status === 'critical' ? '严重' : '注意' }}：{{ p.message }}
            </li>
          </ul>
        </dd>
      </dl>
      <div v-else-if="!diag.pending" class="muted">还没有诊断结果。</div>
    </div>
    <template #foot><button class="btn primary" type="button" data-test="diag-close" @click="closeDiag">关闭</button></template>
  </Modal>
</template>

<style scoped>
.local-code { font: 600 26px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: .12em; padding: 10px 0 }
</style>
