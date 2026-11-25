<script setup lang="ts">
// "新建节点" and "编辑节点", laid out like Xboard's: the protocol menu top
// right, then the node's name, traffic limit, labels, address and ports, then
// the protocol's own settings. Offers only what PSM supports; Snell and SS2022
// default to the standalone install, everything else picks one of the cores
// that runs it (the server installs a missing core itself). Editing keeps the
// protocol, how it runs, the server and the name; a stored password shows as
// •••••• and stays unless replaced.
import { computed, onMounted, reactive, ref, watch } from 'vue'
import { PROTOCOLS, ENGINE_LABELS, OWN_SITE_VARIANTS, activeFields, flagOf, validateNode, variantCanMount443, type Engine } from '@shared/protocols'
import { api, ApiError, errorText, type PanelNode, type Server } from '../api'
import { toast } from '../ui'
import InstallCommand from './InstallCommand.vue'
import Modal from './Modal.vue'

const props = defineProps<{ servers: Server[]; node?: PanelNode | null }>()
const emit = defineEmits<{ close: []; created: [] }>()
const editing = computed(() => !!props.node)

const menuOpen = ref(false)
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
// what clients show without a display name (the subscriptions' name for the node)
const defaultName = computed(() => {
  const s = props.servers.find((x) => x.id === form.server)
  const server = s?.name ?? (form.newServer.trim().toLowerCase() || '服务器')
  return [flagOf(s?.country), `${server}-${form.name.trim() || '名称'}`].filter(Boolean).join(' ')
})
const result = ref<null | { status: string; joined: boolean; install_command?: string; serverName: string; standalone: boolean }>(null)

const protocol = computed(() => PROTOCOLS.find((p) => p.id === protocolId.value))
const variant = computed(() => protocol.value?.variants.find((v) => v.id === variantId.value))
const fields = computed(() => (variant.value ? activeFields(variant.value, engine.value, params) : []))

// Sharing the public 443: only protocols Nginx can tell apart by the name in
// the TLS handshake, and only when the node is made — PSM refuses to move a
// node onto or off the shared 443 as an update, so this is fixed afterwards.
const mount443 = ref(props.node?.mount_443 ?? false)
const canMount = computed(() => !!variant.value && variantCanMount443(variant.value, engine.value))

function pickProtocol(id: string) {
  protocolId.value = id
  menuOpen.value = false
  variantId.value = PROTOCOLS.find((p) => p.id === id)!.variants[0].id
}
// a new variant starts from its defaults (never while editing: it cannot change)
watch(variantId, () => {
  if (!variant.value || editing.value) return
  engine.value = variant.value.defaultEngine
  for (const k of Object.keys(params)) delete params[k]
  for (const f of variant.value.fields) if (f.default !== undefined) params[f.key] = f.default
})
// another engine can offer other choices for the same setting (the transports
// of TLS + 传输): one the new engine lacks goes back to its default
watch(engine, () => {
  if (!variant.value || editing.value) return
  for (const f of activeFields(variant.value, engine.value, params))
    if (f.type === 'select' && !f.options?.some((o) => o.value === String(params[f.key] ?? ''))) params[f.key] = f.default
})

function addLabel() {
  const l = form.labelDraft.trim()
  if (l && !form.labels.includes(l) && form.labels.length < 10) form.labels.push(l)
  form.labelDraft = ''
}

const num = (v: string | number) => (v === '' ? undefined : Number(v))

async function submit() {
  errors.value = []
  if (!variant.value) return (errors.value = ['请选择协议类型'])
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
  const v = validateNode(input)
  if (!v.ok) return (errors.value = v.errors)
  const resetDay = num(form.resetDay) ?? 1
  if (!Number.isInteger(resetDay) || resetDay < 1 || resetDay > 28) return (errors.value = ['流量重置日：1-28'])
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
    let serverName = props.servers.find((s) => s.id === serverId)?.name ?? ''
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
    errors.value = e instanceof ApiError && e.errors.length ? e.errors : [String((e as Error).message)]
  } finally {
    busy.value = false
  }
}
const title = computed(() => (result.value ? '节点已保存' : editing.value ? `编辑节点 ${props.node!.name}` : '新建节点'))
const subtitle = computed(() => result.value ? '' : editing.value
  ? '修改会由 psm-agent 在服务器上生效；协议、运行方式、服务器和名称不能改。'
  : '填写节点信息，提交后由 psm-agent 在服务器上建好（未接入的服务器会给出一键安装命令）。')
</script>

<template>
  <Modal :title="title" :subtitle="subtitle" @close="emit('close')">
    <template #head>
        <div v-if="!result" class="proto-select">
          <button type="button" class="proto-button" data-test="protocol" :disabled="editing" @click="menuOpen = !menuOpen">
            <span v-if="protocol"><span class="dot" :style="{ background: protocol.color }" /> {{ protocol.label }}</span>
            <span v-else>选择协议类型</span>
            <span v-if="!editing">⌄</span>
          </button>
          <div v-if="menuOpen" class="proto-menu">
            <button v-for="p in PROTOCOLS" :key="p.id" type="button" :class="{ on: p.id === protocolId }" :data-test="`protocol-${p.id}`" @click="pickProtocol(p.id)">
              <span class="dot" :style="{ background: p.color }" />{{ p.label }}
            </button>
          </div>
        </div>
    </template>

      <!-- after submitting: the result and the install command -->
      <div v-if="result" class="dialog-body" data-test="result">
        <div v-if="result.status === 'queued'" class="notice ok" data-test="result-queued">
          已下发到 {{ result.serverName }}，psm-agent 会在几秒内{{ result.standalone ? '装好独立的 ' + (protocol?.id === 'snell' ? 'snell-server' : 'ss-rust') + ' 并' : '' }}建好节点（服务器还没有这个内核时会先装上）。
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
      <form v-else class="dialog-body" @submit.prevent="submit">
        <ul v-if="errors.length" class="errors" data-test="errors"><li v-for="e in errors" :key="e">{{ e }}</li></ul>
        <div v-if="!protocol" class="notice info">先在右上角选择协议类型。</div>

        <div v-if="protocol && protocol.variants.length > 1" class="field">
          <label>{{ protocol.label }} 类型</label>
          <select v-model="variantId" class="select" data-test="variant" :disabled="editing">
            <option v-for="v in protocol.variants" :key="v.id" :value="v.id">{{ v.label }}</option>
          </select>
        </div>

        <div v-if="variant" class="row2">
          <div class="field">
            <label>运行方式</label>
            <select v-model="engine" class="select" data-test="engine" :disabled="editing">
              <option v-for="e in variant.engines" :key="e" :value="e">{{ ENGINE_LABELS[e] }}{{ e === variant.defaultEngine ? '（推荐）' : '' }}</option>
            </select>
          </div>
          <div class="field">
            <label>所在服务器</label>
            <select v-model="form.server" class="select" data-test="server" :disabled="editing">
              <option v-for="s in servers" :key="s.id" :value="s.id">{{ s.name }}{{ s.status === 'pending' ? '（未接入）' : '' }}</option>
              <option value="new">＋ 新服务器</option>
            </select>
          </div>
        </div>
        <div v-if="variant && form.server === 'new'" class="field">
          <label>新服务器名称</label>
          <input v-model="form.newServer" class="input" placeholder="例如 hk1" data-test="new-server">
        </div>

        <div class="field">
          <label>节点名称</label>
          <input v-model="form.name" class="input" placeholder="请输入节点名称" data-test="name" :disabled="editing">
        </div>

        <div class="field">
          <label>显示名（可选）</label>
          <input v-model="form.displayName" class="input" :placeholder="defaultName" data-test="display-name">
          <div class="help">客户端里看到的名字，可用中文和 emoji，例如「🇭🇰 香港 01」；不填就是 {{ defaultName }}。只存在面板里，改它不会重新下发节点。</div>
        </div>

        <div class="row2">
          <div class="field">
            <label>流量限制（GB）</label>
            <input v-model="form.traffic" class="input" type="number" min="0" step="any" placeholder="0 表示不限制" data-test="traffic">
          </div>
          <div class="field">
            <label>每月重置日</label>
            <input v-model="form.resetDay" class="input" type="number" min="1" max="28" data-test="reset-day">
          </div>
        </div>

        <div class="field">
          <label>节点标签</label>
          <div class="chips">
            <span v-for="l in form.labels" :key="l" class="chip">{{ l }}<button type="button" @click="form.labels = form.labels.filter((x) => x !== l)">×</button></span>
            <input v-model="form.labelDraft" placeholder="输入后回车添加标签" data-test="label" @keydown.enter.prevent="addLabel">
          </div>
        </div>

        <div class="field">
          <label>节点地址</label>
          <input v-model="form.address" class="input" placeholder="请输入节点域名或者 IP" data-test="address">
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
            <span class="field-label" title="客户端连接的端口">连接端口 ⓘ</span>
            <input v-if="canMount && mount443" class="input" value="443" disabled data-test="public-port-443">
            <!-- a standalone server's link always carries its own port -->
            <input v-else-if="engine === 'standalone'" class="input" :value="form.port" disabled title="独立安装的服务器，连接端口就是服务端口" data-test="public-port-standalone">
            <input v-else v-model="form.publicPort" class="input" type="number" min="1" max="65535" placeholder="用户连接端口" data-test="public-port">
          </div>
          <span class="arrow">⇄</span>
          <div>
            <span class="field-label" title="节点在服务器上监听的端口">服务端口 ⓘ</span>
            <input v-model="form.port" class="input" type="number" min="1" max="65535" placeholder="请输入服务端口" data-test="port">
          </div>
        </div>

        <template v-if="variant && fields.length">
          <div class="section-title">{{ variant.label }} 设置</div>
          <div v-for="f in fields" :key="f.key" class="field">
            <label v-if="f.type !== 'bool'">{{ f.label }}<span v-if="f.required"> *</span></label>
            <select v-if="f.type === 'select'" v-model="params[f.key]" class="select" :data-test="`param-${f.key}`">
              <option v-for="o in f.options" :key="o.value" :value="o.value">{{ o.label }}</option>
            </select>
            <label v-else-if="f.type === 'bool'" class="check"><input v-model="params[f.key]" type="checkbox" :data-test="`param-${f.key}`"> {{ f.label }}</label>
            <input v-else v-model="params[f.key]" class="input" :type="f.type === 'number' ? 'number' : f.type === 'password' ? 'password' : 'text'"
              :placeholder="f.placeholder" :data-test="`param-${f.key}`">
            <div v-if="f.help" class="help">{{ f.help }}</div>
          </div>
        </template>
        <button type="submit" hidden />
      </form>

    <template #foot>
        <template v-if="result">
          <button class="btn primary" type="button" data-test="done" @click="emit('close')">完成</button>
        </template>
        <template v-else>
          <button class="btn ghost" type="button" @click="emit('close')">取消</button>
          <button class="btn primary" type="button" :disabled="busy || loading" data-test="submit" @click="submit">
            <span v-if="busy" class="spinner" />{{ busy ? '提交中…' : editing ? '保存' : '提交' }}
          </button>
        </template>
    </template>
  </Modal>
</template>
