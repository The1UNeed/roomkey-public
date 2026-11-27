<script setup lang="ts">
// "新建节点" and "编辑节点", in tabs the way 3x-ui lays out an inbound: 基本
// (the server first, then name, address, ports, traffic, labels), the
// protocol's own settings, 伪装 / TLS (REALITY's camouflage, certificates)
// and 出口分流. The protocol is the second field, beside the server. Wherever there is a sensible
// set of answers it is a dropdown you can still type into: the server's own
// addresses, ports, traffic limits, labels already in use, the sites people
// borrow for REALITY (probed from the chosen server). Editing keeps the
// protocol, how it runs, the server and the name; a stored password shows as
// •••••• and stays unless replaced.
import { computed, nextTick, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { PROTOCOLS, ENGINE_LABELS, EXIT_FIELDS, OWN_SITE_VARIANTS as OWN_SITE, REALITY_TARGETS, activeFields, flagOf, isSiteDomain, validateNode, variantCanMount443, type Engine, type Field } from '@shared/protocols'
import { api, ApiError, errorText, type PanelNode, type Server } from '../api'
import { toast } from '../ui'
import ComboBox, { type ComboOption } from './ComboBox.vue'
import Icon from './Icon.vue'
import InstallCommand from './InstallCommand.vue'
import Modal from './Modal.vue'

const props = defineProps<{
  servers: Server[]; node?: PanelNode | null
  /** the panel's nodes: their labels are suggested, their names kept unique */
  nodes?: Pick<PanelNode, 'server_id' | 'name' | 'labels'>[]
}>()
const emit = defineEmits<{ close: []; created: [] }>()
const editing = computed(() => !!props.node)

// a new node opens with the protocols laid out to pick from
const menuOpen = ref(!props.node)
const protocolId = ref(props.node?.protocol ?? '')
const variantId = ref(props.node?.variant ?? '')
const engine = ref<Engine>((props.node?.engine as Engine) ?? 'xray')
const form = reactive({
  server: (props.node?.server_id ?? (props.servers[0]?.id ?? 'new')) as string | number,   // a server id, or 'new'
  newServer: '',
  name: props.node?.name ?? '',
  displayName: props.node?.display_name ?? '',
  address: props.node?.address ?? '',
  publicPort: (props.node?.public_port ?? props.node?.port ?? '') as string | number,
  port: (props.node?.port ?? '') as string | number,
  traffic: (props.node?.traffic_limit_gb || '') as string | number,
  resetDay: (props.node?.reset_day ?? 1) as string | number,
  labels: [...(props.node?.labels ?? [])] as string[],
  labelDraft: '',
})
const params = reactive<Record<string, unknown>>({ ...(props.node?.params ?? {}) })
const errors = ref<string[]>([])
const busy = ref(false)
// the list has no settings: an edit reads them first (passwords come masked)
const loading = ref(editing.value && !props.node?.params)
onMounted(async () => {
  if (!loading.value) return
  try {
    const full = await api<PanelNode>(`/api/nodes/${props.node!.id}`)
    Object.assign(params, full.params ?? {})
    // a setting left at its default is not stored: show the default the
    // server runs with (validateNode applies the same), not an empty field
    for (const f of variant.value?.fields ?? []) {
      if (params[f.key] === undefined && f.default !== undefined) params[f.key] = f.default
    }
  } catch (e) {
    errors.value = [errorText(e)]
  } finally {
    loading.value = false
  }
})

const server = computed(() => props.servers.find((x) => x.id === form.server))
// what clients show without a display name (the subscriptions' name for the node)
const defaultName = computed(() => {
  const name = server.value?.name ?? (form.newServer.trim().toLowerCase() || '服务器')
  return [flagOf(server.value?.country), `${name}-${form.name.trim() || '名称'}`].filter(Boolean).join(' ')
})
const result = ref<null | { status: string; joined: boolean; install_command?: string; serverName: string; standalone: boolean }>(null)

const protocol = computed(() => PROTOCOLS.find((p) => p.id === protocolId.value))
const variant = computed(() => protocol.value?.variants.find((v) => v.id === variantId.value))
const fields = computed(() => (variant.value ? activeFields(variant.value, engine.value, params) : []))

// ── tabs ─────────────────────────────────────────────────────────────────────
type Tab = 'basic' | 'protocol' | 'security' | 'exit'
const tab = ref<Tab>('basic')
const SECURITY_KEYS = ['camouflage', 'server_name', 'target', 'accept_risk', 'domain', 'sni', 'cert_path', 'key_path', 'insecure', 'vless_enc']
const EXIT_KEYS = EXIT_FIELDS.map((f) => f.key)
const tabOf = (f: Field): Tab => (SECURITY_KEYS.includes(f.key) ? 'security' : EXIT_KEYS.includes(f.key) ? 'exit' : 'protocol')
const fieldsIn = (t: Tab) => fields.value.filter((f) => tabOf(f) === t)
const tabs = computed(() => {
  const all: { id: Tab; label: string }[] = [
    { id: 'basic', label: '基本' },
    { id: 'protocol', label: `${protocol.value?.label ?? '协议'} 设置` },
    { id: 'security', label: OWN_SITE.includes(variantId.value) ? '伪装' : 'TLS / 安全' },
    { id: 'exit', label: '出口分流' },
  ]
  return all.filter((t) => t.id === 'basic' || fieldsIn(t.id).length)
})
// which tab an error belongs to (an error starts with its field's label)
const BASIC_LABELS = ['节点名称', '节点地址', '服务端口', '连接端口', '流量限制', '流量重置日', '显示名', '独立安装', '挂到 443', '请选择协议']
function tabOfError(e: string): Tab {
  const f = fields.value.find((x) => e.startsWith(x.label))
  if (f) return tabOf(f)
  if (e.startsWith('借用其他网站') || e.startsWith('借用的网站') || e.startsWith('本机域名')) return 'security'
  return 'basic'
}
const errorTabs = computed(() => new Set(errors.value.map(tabOfError)))
watch(tabs, (ts) => { if (!ts.some((t) => t.id === tab.value)) tab.value = 'basic' })

// Sharing the public 443: only protocols Nginx can tell apart by the name in
// the TLS handshake, and only when the node is made — PSM refuses to move a
// node onto or off the shared 443 as an update, so this is fixed afterwards.
const mount443 = ref(props.node?.mount_443 ?? false)
const canMount = computed(() => !!variant.value && variantCanMount443(variant.value, engine.value))

// ── dropdowns: what each field can sensibly be ──────────────────────────────
const looksLikeDomain = (s: string | null | undefined) => !!s && /^[a-z0-9.-]+\.[a-z]{2,}$/i.test(s) && !/^\d+(\.\d+)+$/.test(s)
const addressOptions = computed<ComboOption[]>(() => {
  const s = server.value
  if (!s) return []
  const out: ComboOption[] = []
  if (s.dns_name) out.push({ value: s.dns_name, note: '域名跟随 IP（推荐）' })
  if (s.last_ip) out.push({ value: s.last_ip, note: '服务器 IP' })
  if (looksLikeDomain(s.hostname) && s.hostname !== s.dns_name) out.push({ value: s.hostname!, note: '主机名' })
  return out
})
const ownSiteOptions = computed<ComboOption[]>(() => {
  const s = server.value
  const out: ComboOption[] = []
  if (s?.dns_name) out.push({ value: s.dns_name, note: '已解析到这台服务器' })
  if (looksLikeDomain(form.address) && form.address !== s?.dns_name) out.push({ value: form.address, note: '节点地址' })
  return out
})
const randomPort = () => 20000 + Math.floor(Math.random() * 40000)
const portOptions = computed<ComboOption[]>(() => [
  { value: '443', note: 'HTTPS 端口，最像普通网站' },
  { value: '8443', note: '常见的备用 HTTPS 端口' },
  { value: '2053', note: 'Cloudflare 也用的 HTTPS 端口' },
  { value: String(randomPort()), note: '随机端口' },
])
const trafficOptions: ComboOption[] = [
  { value: '0', label: '不限制', note: '0' },
  { value: '100', label: '100 GB' }, { value: '200', label: '200 GB' }, { value: '500', label: '500 GB' },
  { value: '1000', label: '1 TB' }, { value: '2000', label: '2 TB' },
]
const knownLabels = computed(() => [...new Set((props.nodes ?? []).flatMap((n) => n.labels))].filter((l) => !form.labels.includes(l)).sort())
const labelOptions = computed<ComboOption[]>(() => knownLabels.value.map((l) => ({ value: l, note: '已有标签' })))

// a new node starts with the server's address and an unused name
let autoAddress = ''
function fillAddress() {
  if (editing.value) return
  const best = addressOptions.value[0]?.value ?? ''
  if (!form.address || form.address === autoAddress) { form.address = best; autoAddress = best }
}
watch(() => form.server, fillAddress, { immediate: true })
function freeName(base: string) {
  const taken = new Set((props.nodes ?? []).filter((n) => n.server_id === form.server).map((n) => n.name))
  for (let i = 1; ; i++) { const n = i === 1 ? base : `${base}-${i}`; if (!taken.has(n)) return n }
}
let autoName = ''
function fillName() {
  if (editing.value || !variant.value) return
  if (!form.name || form.name === autoName) { form.name = freeName(variant.value.id); autoName = form.name }
}

function pickProtocol(id: string) {
  protocolId.value = id
  menuOpen.value = false
  errors.value = []
  toTop()
  variantId.value = PROTOCOLS.find((p) => p.id === id)!.variants[0].id
}
// a new variant starts from its defaults (never while editing: it cannot change)
watch(variantId, () => {
  if (!variant.value || editing.value) return
  engine.value = variant.value.defaultEngine
  for (const k of Object.keys(params)) delete params[k]
  for (const f of variant.value.fields) if (f.default !== undefined) params[f.key] = f.default
  if (OWN_SITE.includes(variant.value.id) && ownSiteOptions.value[0]) params.server_name = ownSiteOptions.value[0].value
  if (!form.port) form.port = OWN_SITE.includes(variant.value.id) ? 443 : randomPort()
  fillName()
})
// another engine can offer other choices for the same setting (the transports
// of TLS + 传输): one the new engine lacks goes back to its default
watch(engine, () => {
  if (!variant.value || editing.value) return
  for (const f of activeFields(variant.value, engine.value, params))
    if (f.type === 'select' && !f.options?.some((o) => o.value === String(params[f.key] ?? ''))) params[f.key] = f.default
})

function addLabel(l = form.labelDraft) {
  l = l.trim()
  if (l && !form.labels.includes(l) && form.labels.length < 10) form.labels.push(l)
  form.labelDraft = ''
}
// a suggestion picked from the list is added at once

// ── REALITY: the camouflage, and probing borrowed sites from the server ────
const borrowing = computed(() => OWN_SITE.includes(variantId.value) && params.camouflage === 'borrow')
type Probe = { host: string; ok: boolean; reason?: string | null; rtt_ms?: number | null; h2?: boolean; shared_frontend?: boolean; shared_by?: string | null }
const probes = reactive<Record<string, Probe>>({})
const probing = ref<'' | 'one' | 'all'>('')
const probeError = ref('')
// another server: its own probes, an unused name there
// (a probe still running for the old server is dropped: probeGen)
let probeGen = 0
watch(() => form.server, () => {
  probeGen++
  probing.value = ''
  for (const k of Object.keys(probes)) delete probes[k]
  probeError.value = ''
  errors.value = []
  fillName()
})
const REASONS: Record<string, string> = {
  tcp_failed: '连不上 443 端口', tls_timeout: '握手超时', tls13_unsupported: '不支持 TLS 1.3', tls13_failed: 'TLS 1.3 握手失败',
  no_x25519: '不支持 X25519', no_certificate: '没有拿到证书', sni_cert_mismatch: '证书和域名不符', bad_dest: '地址不对',
}
function probeNote(p: Probe | undefined): Pick<ComboOption, 'note' | 'tone'> {
  if (!p) return {}
  if (!p.ok) return { note: `✗ ${REASONS[p.reason ?? ''] ?? p.reason ?? '不可用'}`, tone: 'err' }
  const base = `✓ ${p.rtt_ms ?? '?'} ms${p.h2 ? ' · h2' : ''}`
  return p.shared_frontend ? { note: `${base} · ⚠ CDN 共享`, tone: 'warn' } : { note: base, tone: 'ok' }
}
// once probed: the sites that work first (fastest first), then the shared-CDN
// ones, the ones not probed, and the ones that failed last
const targetOptions = computed<ComboOption[]>(() => {
  const rank = (h: string) => { const p = probes[h]; return !p ? 2 : !p.ok ? 3 : p.shared_frontend ? 1 : 0 }
  return REALITY_TARGETS.map((t, i) => ({ t, i })).sort((a, b) => rank(a.t.value) - rank(b.t.value)
    || ((probes[a.t.value]?.rtt_ms ?? 1e9) - (probes[b.t.value]?.rtt_ms ?? 1e9)) || a.i - b.i).map(({ t }) => {
    const p = probeNote(probes[t.value])
    return { value: t.value, label: t.label, note: p.note ?? t.note, tone: p.tone ?? (t.note ? 'warn' : undefined) }
  })
})
const target = computed(() => String(params.target ?? '').trim().toLowerCase())
const targetProbe = computed(() => probes[target.value])
const canProbe = computed(() => !!server.value && server.value.status !== 'pending')
let alive = true
onUnmounted(() => { alive = false })
async function probe(hosts: string[], which: 'one' | 'all') {
  probeError.value = ''
  if (!server.value) return
  probing.value = which
  const gen = probeGen
  try {
    const { task_id } = await api<{ task_id: number }>(`/api/servers/${server.value.id}/probe`, { method: 'POST', body: JSON.stringify({ hosts }) })
    // the server picks the task up at its next sync; each site takes a few seconds
    const deadline = Date.now() + (which === 'all' ? 4 : 2) * 60_000
    while (alive && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 2000))
      if (gen !== probeGen) return
      const t = await api<{ status: string; error: string | null; result: { sites?: Probe[] } | null }>(`/api/tasks/${task_id}`)
      if (gen !== probeGen) return
      if (t.status === 'done') { for (const p of t.result?.sites ?? []) probes[p.host] = p; return }
      if (t.status === 'failed') { probeError.value = t.error ?? '探测失败'; return }
    }
    if (alive && gen === probeGen) probeError.value = '服务器还没有回答（它离线了，或者正在忙）：稍后再试'
  } catch (e) {
    if (gen === probeGen) probeError.value = errorText(e)
  } finally {
    if (gen === probeGen) probing.value = ''
  }
}
const probeRows = computed(() => Object.values(probes).sort((a, b) =>
  Number(b.ok && !b.shared_frontend) - Number(a.ok && !a.shared_frontend) || Number(b.ok) - Number(a.ok) || (a.rtt_ms ?? 1e9) - (b.rtt_ms ?? 1e9)))

const num = (v: string | number) => (v === '' || v === undefined || v === null ? undefined : Number(v))

async function submit() {
  errors.value = []
  if (!variant.value) return (errors.value = ['请选择协议类型'])
  if (form.labelDraft.trim()) addLabel()
  const port = num(form.port)
  const shared443 = canMount.value && mount443.value
  const input = {
    protocol: protocolId.value, variant: variantId.value, engine: engine.value,
    name: form.name.trim(), address: form.address.trim(),
    // on the shared 443 the node listens on 127.0.0.1 and clients reach 443
    port: port as number, public_port: shared443 ? 443 : engine.value === 'standalone' ? port as number : num(form.publicPort) ?? port,
    traffic_limit_gb: num(form.traffic) ?? 0, labels: form.labels, params: { ...params },
    mount_443: shared443, display_name: form.displayName.trim(),
  }
  if (borrowing.value) input.params.target = target.value
  const v = validateNode(input)
  if (!v.ok) { showErrors(v.errors); return }
  const resetDay = num(form.resetDay) ?? 1
  if (!Number.isInteger(resetDay) || resetDay < 1 || resetDay > 28) { errors.value = ['流量重置日：1-28']; tab.value = 'basic'; return }
  busy.value = true
  try {
    if (editing.value) {
      const saved = await api<PanelNode>(`/api/nodes/${props.node!.id}`, {
        method: 'PATCH',
        body: JSON.stringify({ address: input.address, port: input.port, public_port: input.public_port,
          traffic_limit_gb: input.traffic_limit_gb, reset_day: resetDay, labels: input.labels, params: input.params,
          display_name: input.display_name }),
      })
      // only the display name changed: the panel keeps that, nothing goes to the server
      toast(saved.status === 'queued' ? `已保存 ${props.node!.name}，正在下发到服务器` : `已保存 ${props.node!.name}`)
      emit('close')
      return
    }
    let serverId = form.server
    let serverName = server.value?.name ?? ''
    if (serverId === 'new') {
      const s = await api<{ id: number }>('/api/servers', { method: 'POST', body: JSON.stringify({ name: form.newServer.trim() }) })
      serverId = s.id
      serverName = form.newServer.trim().toLowerCase()
    }
    const r = await api<{ status: string; joined: boolean; install_command?: string }>('/api/nodes', {
      method: 'POST', body: JSON.stringify({ ...input, reset_day: resetDay, server_id: serverId }),
    })
    result.value = { ...r, serverName, standalone: engine.value === 'standalone' }
    emit('created')
  } catch (e) {
    showErrors(e instanceof ApiError && e.errors.length ? e.errors : [String((e as Error).message)])
  } finally {
    busy.value = false
  }
}
// the errors, on the tab of the first one, with the field it names in view
// (the list sits at the top; the field may be far below it)
function showErrors(list: string[]) {
  errors.value = list
  tab.value = tabOfError(list[0])
  void nextTick(() => {
    // the risk box is far down its tab; anything else: the tab from its top (the list stays pinned above)
    const el = list[0]?.includes('我知道风险') ? document.querySelector<HTMLElement>('[data-test=param-accept_risk]') : null
    if (el) { el.scrollIntoView({ block: 'center', behavior: 'smooth' }); el.focus({ preventScroll: true }) }
    else if (body.value) body.value.scrollTop = 0
  })
}
// a tab or a protocol picked by hand starts at the top of the form (not a tab
// opened by showErrors: that one scrolls to the field instead)
const body = ref<HTMLElement | null>(null)
function toTop() { void nextTick(() => { if (body.value) body.value.scrollTop = 0 }) }
function openTab(t: Tab) { tab.value = t; toTop() }
// ticked: its error goes at once (the rest wait for the next 提交)
watch(() => params.accept_risk, (v) => { if (v) errors.value = errors.value.filter((e) => !e.includes('我知道风险')) })
watch(() => params.camouflage, () => { errors.value = errors.value.filter((e) => !e.startsWith('借用') && !e.startsWith('本机')) })
const riskError = computed(() => errors.value.some((e) => e.includes('我知道风险')))
const title = computed(() => (result.value ? '节点已保存' : editing.value ? `编辑节点 ${props.node!.name}` : '新建节点'))
const subtitle = computed(() => result.value ? '' : editing.value
  ? '修改几秒内在服务器上生效；协议、运行方式、服务器和名称不能改。'
  : '先选服务器和协议，其余大多从下拉里选；提交后几秒内在服务器上建好。')
const serverLabel = (s: Server) => `${flagOf(s.country) ? flagOf(s.country) + ' ' : ''}${s.name}${s.status === 'pending' ? '（未接入）' : s.status === 'offline' ? '（离线）' : ''}${s.last_ip ? ' · ' + s.last_ip : ''}`
// a select whose every choice explains itself is shown as cards
const asCards = (f: Field) => f.type === 'select' && !!f.options?.length && f.options.length <= 3 && f.options.every((o) => o.note)
</script>

<template>
  <Modal :title="title" :subtitle="subtitle" size="wide" :sticky="!result" @close="emit('close')">

      <!-- after submitting: the result and the install command -->
      <div v-if="result" class="dialog-body" data-test="result">
        <div v-if="result.status === 'queued'" class="notice ok" data-test="result-queued">
          已下发到 {{ result.serverName }}，几秒内{{ result.standalone ? '装好独立的 ' + (protocol?.id === 'snell' ? 'snell-server' : 'ss-rust') + ' 并' : '' }}建好节点（服务器还没有这个内核时会先装上）。
          <div style="margin-top: 6px">接下来：在节点列表点「链接」复制给自己用，或在「用户」里按标签把它分给朋友。</div>
        </div>
        <div v-else class="notice warn" data-test="result-waiting">
          节点已保存。在 {{ result.serverName }} 上以 root 执行下面的命令，安装 PSM（没装过也可以）、接入面板并建好节点：
        </div>
        <div v-if="result.install_command" class="field">
          <span class="field-label">一键安装命令</span>
          <InstallCommand :command="result.install_command" />
          <div class="help">命令 24 小时内有效，只能用一次；需要时可以在服务器页重新生成。</div>
        </div>
      </div>

      <div v-else-if="loading" class="dialog-body"><div class="skeleton-rows"><div v-for="i in 5" :key="i" class="skeleton" style="height: 34px" /></div></div>
      <form v-else ref="body" class="dialog-body" @submit.prevent="submit">
        <!-- the tabs and the errors stay in view while the form scrolls -->
        <div v-if="variant || errors.length" class="dialog-sticky">
          <nav v-if="variant" class="tabs" data-test="tabs">
            <button v-for="t in tabs" :key="t.id" type="button" :class="{ on: tab === t.id }" :data-test="`tab-${t.id}`" @click="openTab(t.id)">
              {{ t.label }}<span v-if="errorTabs.has(t.id)" class="dot-err" />
            </button>
          </nav>
          <ul v-if="errors.length" class="errors" data-test="errors"><li v-for="e in errors" :key="e">{{ e }}</li></ul>
        </div>

        <!-- 基本 -->
        <template v-if="tab === 'basic'">
          <div class="row2">
            <div class="field">
              <label>所在服务器</label>
              <select v-model="form.server" class="select" data-test="server" :disabled="editing">
                <option v-for="s in servers" :key="s.id" :value="s.id">{{ serverLabel(s) }}</option>
                <option value="new">＋ 新服务器（之后用安装命令接入）</option>
              </select>
            </div>
            <div class="field">
              <label>协议</label>
              <div class="proto-select">
                <button type="button" class="proto-button" :class="{ empty: !protocol }" data-test="protocol" :disabled="editing" :aria-expanded="menuOpen" @click="menuOpen = !menuOpen">
                  <span v-if="protocol"><span class="dot" :style="{ background: protocol.color }" /> {{ protocol.label }}</span>
                  <span v-else>选择协议，例如 VLESS</span>
                  <span v-if="!editing" aria-hidden="true">{{ menuOpen ? '⌃' : '⌄' }}</span>
                </button>
              </div>
            </div>
          </div>
          <!-- the protocols, laid out in the form (a menu would be clipped by the scrolling body) -->
          <div v-if="menuOpen && !editing" class="proto-menu" role="listbox" aria-label="协议" @keydown.esc.stop.prevent="menuOpen = false">
            <button v-for="p in PROTOCOLS" :key="p.id" type="button" role="option" :aria-selected="p.id === protocolId" :class="{ on: p.id === protocolId }" :data-test="`protocol-${p.id}`" @click="pickProtocol(p.id)">
              <span class="dot" :style="{ background: p.color }" />{{ p.label }}
            </button>
          </div>
          <div v-if="variant && protocol && protocol.variants.length > 1" class="field">
            <label>{{ protocol.label }} 类型</label>
            <select v-model="variantId" class="select" data-test="variant" :disabled="editing">
              <option v-for="v in protocol.variants" :key="v.id" :value="v.id">{{ v.label }}</option>
            </select>
          </div>
          <div v-if="form.server === 'new'" class="field">
            <label>新服务器名称</label>
            <input v-model="form.newServer" class="input" placeholder="例如 hk1" data-test="new-server">
          </div>
          <div v-if="!protocol" class="help">选好协议后，下面会出现它的设置。</div>

          <template v-if="variant">
            <div class="row2">
              <div class="field">
                <label>节点名称</label>
                <input v-model="form.name" class="input" placeholder="请输入节点名称" data-test="name" :disabled="editing">
              </div>
              <div v-if="variant.engines.length > 1" class="field">
                <label>运行方式 <span class="tip" tabindex="0" role="img" aria-label="哪个内核运行这个节点；服务器上没有时会自动装上">ⓘ</span></label>
                <select v-model="engine" class="select" data-test="engine" :disabled="editing">
                  <option v-for="e in variant.engines" :key="e" :value="e">{{ ENGINE_LABELS[e] }}{{ e === variant.defaultEngine ? '（推荐）' : '' }}</option>
                </select>
              </div>
            </div>

            <div class="field">
              <label>显示名（可选） <span class="tip" tabindex="0" role="img" aria-label="只存在面板里，改它不会重新下发节点">ⓘ</span></label>
              <input v-model="form.displayName" class="input" :placeholder="defaultName" data-test="display-name">
              <div class="help">客户端里看到的名字，可用中文和 emoji，例如「🇭🇰 香港 01」；不填就是 {{ defaultName }}。</div>
            </div>

            <div class="field">
              <label>节点地址 <span class="tip" tabindex="0" role="img" aria-label="客户端连接的域名或 IP">ⓘ</span></label>
              <ComboBox v-model="form.address" :options="addressOptions" placeholder="请输入节点域名或者 IP" test="address" />
            </div>

            <div v-if="canMount" class="field">
              <label class="check">
                <input v-model="mount443" type="checkbox" :disabled="editing" data-test="mount-443"> 挂到 443 端口复用
              </label>
              <div class="help">
                节点监听本机回环地址，Nginx 按 TLS 握手里的域名把公网 443 转给它，可以和其他节点、伪装网站共用一个 443。
                服务器上没有 Nginx 会自动装上。<b>建好之后不能再改</b>：改用直连端口要删掉重建。
              </div>
            </div>

            <div class="ports field">
              <div>
                <span class="field-label">服务端口 <span class="tip" tabindex="0" role="img" aria-label="节点在服务器上监听的端口">ⓘ</span></span>
                <ComboBox v-model="form.port" :options="portOptions" type="number" placeholder="请输入服务端口" test="port" />
              </div>
              <span class="arrow">⇄</span>
              <div>
                <span class="field-label">连接端口 <span class="tip" tabindex="0" role="img" aria-label="客户端连接的端口；经过端口转发时才和服务端口不同">ⓘ</span></span>
                <input v-if="canMount && mount443" class="input" value="443" disabled data-test="public-port-443">
                <!-- a standalone server's link always carries its own port -->
                <input v-else-if="engine === 'standalone'" class="input" :value="form.port" disabled title="独立安装的服务器，连接端口就是服务端口" data-test="public-port-standalone">
                <input v-else v-model="form.publicPort" class="input" type="number" min="1" max="65535" placeholder="同服务端口" data-test="public-port">
              </div>
            </div>

            <div class="row2">
              <div class="field">
                <label>流量限制（GB）</label>
                <ComboBox v-model="form.traffic" :options="trafficOptions" type="number" placeholder="不限制" test="traffic" />
              </div>
              <div class="field">
                <label>每月重置日</label>
                <select v-model.number="form.resetDay" class="select" data-test="reset-day">
                  <option v-for="d in 28" :key="d" :value="d">每月 {{ d }} 日</option>
                </select>
              </div>
            </div>

            <div class="field">
              <label>节点标签 <span class="tip" tabindex="0" role="img" aria-label="用户按标签拿到节点">ⓘ</span></label>
              <div v-if="form.labels.length" class="chips" style="margin-bottom: 6px">
                <span v-for="l in form.labels" :key="l" class="chip">{{ l }}<button type="button" @click="form.labels = form.labels.filter((x) => x !== l)">×</button></span>
              </div>
              <ComboBox v-model="form.labelDraft" :options="labelOptions" placeholder="选择已有标签，或输入后回车添加" test="label" @pick="addLabel" @keydown.enter.prevent="addLabel()" />
            </div>
          </template>
        </template>

        <!-- the protocol's own settings, 伪装 / TLS, 出口分流 -->
        <template v-for="t in (['protocol', 'security', 'exit'] as const)" :key="t">
          <template v-if="tab === t && variant">
            <template v-for="f in fieldsIn(t)" :key="f.key">
              <div class="field">
                <label v-if="f.type !== 'bool'">{{ f.label }}<span v-if="f.required"> *</span> <span v-if="f.tip" class="tip" tabindex="0" role="img" :aria-label="f.tip">ⓘ</span></label>
                <div v-if="asCards(f)" class="choice-cards" :data-test="`param-${f.key}`">
                  <button v-for="o in f.options" :key="o.value" type="button" class="choice-card" :class="{ on: String(params[f.key] ?? f.default) === o.value }"
                    :data-test="`param-${f.key}-${o.value}`" @click="params[f.key] = o.value">
                    <b>{{ o.label }}</b><span>{{ o.note }}</span>
                  </button>
                </div>
                <select v-else-if="f.type === 'select'" v-model="params[f.key]" class="select" :data-test="`param-${f.key}`">
                  <option v-for="o in f.options" :key="o.value" :value="o.value">{{ o.label }}</option>
                </select>
                <div v-else-if="f.key === 'accept_risk'" class="notice" :class="riskError && !params[f.key] ? 'err' : 'warn'" data-test="risk-box">
                  <label class="check"><input v-model="params[f.key]" type="checkbox" :data-test="`param-${f.key}`"> {{ f.label }}</label>
                  <div v-if="riskError && !params[f.key]" class="err-text" style="margin-top: 6px" data-test="risk-error">借用别人的网站要先勾选这一项，才能提交。</div>
                  <div v-if="targetProbe?.shared_frontend" style="margin-top: 6px">
                    <b>{{ target }} 在共享 CDN 上</b>（探测时用 {{ targetProbe.shared_by }} 也拿到了有效证书）：没有密钥的人能经这台服务器访问整个 CDN。会给回落连接限速，但仍最容易被投诉。
                  </div>
                </div>
                <label v-else-if="f.type === 'bool'" class="check"><input v-model="params[f.key]" type="checkbox" :data-test="`param-${f.key}`"> {{ f.label }}</label>
                <div v-else-if="f.key === 'target'" class="input-btn">
                  <ComboBox :model-value="params[f.key] as string" :options="targetOptions" :placeholder="f.placeholder" :test="`param-${f.key}`" @update:model-value="(v) => (params[f.key] = v)" />
                  <button type="button" class="btn" :disabled="!canProbe || !!probing || !isSiteDomain(target)" data-test="probe-one" @click="probe([target], 'one')">
                    <span v-if="probing === 'one'" class="spinner" />探测
                  </button>
                  <button type="button" class="btn" :disabled="!canProbe || !!probing" data-test="probe-all" @click="probe(REALITY_TARGETS.map((x) => x.value), 'all')">
                    <span v-if="probing === 'all'" class="spinner" />扫描全部
                  </button>
                </div>
                <ComboBox v-else-if="f.type === 'combo'" :model-value="params[f.key] as string" :options="f.key === 'server_name' ? ownSiteOptions : (f.options ?? [])"
                  :placeholder="f.placeholder" :test="`param-${f.key}`" @update:model-value="(v) => (params[f.key] = v)" />
                <input v-else v-model="params[f.key]" class="input" :type="f.type === 'number' ? 'number' : f.type === 'password' ? 'password' : 'text'"
                  :placeholder="f.placeholder" :data-test="`param-${f.key}`">
                <div v-if="f.help" class="help">{{ f.help }}</div>
                <template v-if="f.key === 'target'">
                  <div v-if="!canProbe" class="help">服务器接入面板后，可以从它那里探测这些网站能不能用。</div>
                  <div v-else-if="probing" class="help">正在从 {{ server?.name }} 探测{{ probing === 'all' ? `全部 ${REALITY_TARGETS.length} 个网站，约一两分钟` : '' }}…</div>
                  <div v-if="probeError" class="error-text" data-test="probe-error">{{ probeError }}</div>
                  <div v-if="probeRows.length" class="probe-scroll">
                  <table class="probe-table" data-test="probe-results">
                    <thead><tr><th>网站</th><th>结果（从 {{ server?.name }}）</th></tr></thead>
                    <tbody>
                      <tr v-for="p in probeRows" :key="p.host" :class="{ pickable: p.ok, picked: p.host === target }" @click="p.ok && (params.target = p.host)">
                        <td>{{ p.host }}</td>
                        <td :class="probeNote(p).tone === 'ok' ? 'ok-text' : probeNote(p).tone === 'warn' ? 'warn-text' : 'err-text'">{{ probeNote(p).note }}</td>
                      </tr>
                    </tbody>
                  </table>
                  </div>
                </template>
              </div>
            </template>
          </template>
        </template>
        <div v-if="variant && OWN_SITE.includes(variantId) && tab !== 'security'" class="help" style="margin-top: -4px">
          伪装：{{ borrowing ? `借用 ${target || '其他网站'}` : `本机网站 ${params.server_name || ''}` }}
          <span v-if="!borrowing && !params.server_name" class="badge warn" data-test="own-site-missing">还要填本机域名</span>
          · <button type="button" class="link-btn" @click="openTab('security')">修改</button>
        </div>
        <button type="submit" hidden />
      </form>

    <template #foot>
        <template v-if="result">
          <a class="btn" href="#/users" data-test="to-users" @click="emit('close')"><Icon name="key" />分给用户</a>
          <button class="btn primary" type="button" data-test="done" @click="emit('close')">完成</button>
        </template>
        <template v-else>
          <button class="btn ghost" type="button" @click="emit('close')">取消</button>
          <button class="btn primary" type="button" :disabled="busy || loading || !variant" data-test="submit" @click="submit">
            <span v-if="busy" class="spinner" />{{ busy ? '提交中…' : editing ? '保存' : '提交' }}
          </button>
        </template>
    </template>
  </Modal>
</template>
