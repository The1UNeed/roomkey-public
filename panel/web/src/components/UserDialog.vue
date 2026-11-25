<script setup lang="ts">
// "新建用户" / "编辑用户": who it is, how long and how much they may use, and
// which nodes they get. Quotas can be a total over every server, a limit on
// some servers, or both — whichever runs out first pauses them (everywhere, or
// on that server only).
import { computed, reactive, ref } from 'vue'
import { api, beijingDate, errorText, GB, type PanelNode, type PanelUser, type Server, type UserAccess } from '../api'
import { userNodes } from '@shared/users'
import { toast } from '../ui'
import Modal from './Modal.vue'

const props = defineProps<{ user?: PanelUser | null; servers: Server[]; nodes: PanelNode[] }>()
const emit = defineEmits<{ close: []; saved: [PanelUser] }>()
const editing = computed(() => !!props.user)
const u = props.user

// exact enough that opening and saving never changes a quota (0.001 GB stays 0.001 GB)
const gb = (b: number | null | undefined) => (b ? +(b / GB).toPrecision(12) : '')
const accessMode = (a: UserAccess[] | undefined) => (!a || a.some((x) => x.kind === 'all') ? 'all' : a.some((x) => x.kind === 'label') ? 'label' : 'node')

const form = reactive({
  name: u?.name ?? '',
  note: u?.note ?? '',
  enabled: u?.enabled ?? true,
  expiry: (u?.first_use_days ? 'first' : u?.expires_at ? 'date' : 'never') as 'never' | 'date' | 'first',
  expires: beijingDate(u?.expires_at),
  firstDays: (u?.first_use_days ?? 30) as number | string,
  quota: gb(u?.quota_total_bytes) as number | string,
  period: u?.reset_period ?? 'monthly',
  resetDay: (u?.reset_day ?? 1) as number | string,
  devices: (u?.device_limit ?? 0) as number | string,
  unmetered: u?.unmetered ?? false,
  access: accessMode(u?.access) as 'all' | 'label' | 'node',
  labels: (u?.access ?? []).filter((a) => a.kind === 'label').map((a) => a.value),
  nodeIds: (u?.access ?? []).filter((a) => a.kind === 'node').map((a) => Number(a.value)),
  perServer: Object.fromEntries((u?.servers ?? []).filter((s) => s.quota_bytes).map((s) => [s.server_id, gb(s.quota_bytes)])) as Record<number, number | string>,
  labelDraft: '',
})
const showServers = ref(Object.keys(form.perServer).length > 0)
const errors = ref<string[]>([])
const busy = ref(false)

const allLabels = computed(() => [...new Set(props.nodes.flatMap((n) => n.labels))].sort())
const serverName = (id: number) => props.servers.find((s) => s.id === id)?.name ?? `#${id}`
// what the user would get, by the same rules the panel applies (shared/users.ts)
const accessList = computed<UserAccess[]>(() => form.access === 'all' ? [{ kind: 'all', value: '' }]
  : form.access === 'label' ? form.labels.map((value) => ({ kind: 'label' as const, value }))
    : form.nodeIds.map((id) => ({ kind: 'node' as const, value: String(id) })))
const hasQuota = computed(() => Number(form.quota) > 0 || (showServers.value && Object.values(form.perServer).some((v) => Number(v) > 0)))
const metered = computed(() => hasQuota.value || (form.expiry === 'first' && !u?.first_used_at))
// only nodes running on their servers count (not ones failed or on their way)
const running = computed(() => props.nodes.filter((n) => n.status === 'applied'))
const usable = computed(() => userNodes(accessList.value, running.value, { needsMetering: metered.value, unmetered: form.unmetered }))
const unmeteredCount = computed(() => userNodes(accessList.value, running.value, { needsMetering: false, unmetered: true })
  .filter((n) => n.engine !== 'xray').length)
const periodMoved = computed(() => !!u && (form.period !== u.reset_period || Number(form.resetDay) !== u.reset_day))

function addLabel(l = form.labelDraft.trim()) {
  if (l && !form.labels.includes(l)) form.labels.push(l)
  form.labelDraft = ''
}
function toggleNode(id: number) {
  form.nodeIds = form.nodeIds.includes(id) ? form.nodeIds.filter((x) => x !== id) : [...form.nodeIds, id]
}

async function save() {
  errors.value = []
  const access = accessList.value
  if (!access.length) { errors.value = ['可用节点：至少选一个标签或节点']; return }
  const body = {
    ...(editing.value ? {} : { name: form.name.trim() }),
    note: form.note, enabled: form.enabled,
    expires_at: form.expiry === 'date' ? form.expires || null : null,
    first_use_days: form.expiry === 'first' ? Number(form.firstDays) : null,
    quota_total_gb: Number(form.quota) || null,
    reset_period: form.period, reset_day: Number(form.resetDay) || 1,
    device_limit: Number(form.devices) || 0, unmetered: form.unmetered, access,
    servers: showServers.value ? Object.entries(form.perServer).filter(([, v]) => Number(v) > 0).map(([id, v]) => ({ server_id: Number(id), quota_gb: Number(v) })) : [],
  }
  busy.value = true
  try {
    const saved = editing.value
      ? await api<PanelUser>(`/api/users/${u!.id}`, { method: 'PATCH', body: JSON.stringify(body) })
      : await api<PanelUser>('/api/users', { method: 'POST', body: JSON.stringify(body) })
    toast(editing.value ? `已保存 ${saved.name}` : `已新建用户 ${saved.name}`)
    emit('saved', saved)
  } catch (e) {
    errors.value = [errorText(e)]
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <Modal :title="editing ? `编辑用户 ${u!.name}` : '新建用户'" size="wide" sticky @close="emit('close')">
    <template #subtitle><p>用户在每台分到节点的服务器上都用同一套 UUID 和密码。改动保存后几秒内下发到服务器。</p></template>
    <div class="dialog-body">
      <ul v-if="errors.length" class="errors" data-test="user-errors"><li v-for="e in errors" :key="e">{{ e }}</li></ul>

      <div class="row2">
        <div class="field">
          <label>用户名</label>
          <input v-model="form.name" class="input" :disabled="editing" placeholder="例如 alice" autocomplete="off" data-test="user-name">
          <div class="help">小写字母、数字、- 和 _。对方能看到：它是订阅的名字，也显示在对方的订阅页上。</div>
        </div>
        <div class="field">
          <label>备注</label>
          <input v-model="form.note" class="input" placeholder="例如 小王的手机和电脑" data-test="user-note">
        </div>
      </div>

      <div class="section-title">期限</div>
      <div class="row2">
        <div class="field">
          <label>到期</label>
          <select v-model="form.expiry" class="select" data-test="user-expiry">
            <option value="never">长期有效</option>
            <option value="date">到指定日期</option>
            <option value="first">首次使用后 N 天</option>
          </select>
        </div>
        <div v-if="form.expiry === 'date'" class="field">
          <label>到期日期</label>
          <input v-model="form.expires" class="input" type="date" data-test="user-expires">
          <div class="help">北京时间当天 23:59 到期，服务器会自己停掉，离线时也一样。</div>
        </div>
        <div v-else-if="form.expiry === 'first'" class="field">
          <label>天数</label>
          <input v-model="form.firstDays" class="input" type="number" min="1" max="3650" data-test="user-first-days">
          <div class="help">从第一次有流量时开始算{{ u?.first_used_at ? `（已于 ${beijingDate(u.first_used_at)} 开始）` : '；开始前只分到按用户计量的 Xray 节点，否则看不到第一次使用' }}。</div>
        </div>
      </div>

      <div class="section-title">流量 <span class="muted">留空或 0 为不限</span></div>
      <div class="row3">
        <div class="field">
          <label>总流量（GB）</label>
          <input v-model="form.quota" class="input" type="number" min="0" step="any" placeholder="不限" data-test="user-quota">
          <div class="help">所有服务器加起来。</div>
        </div>
        <div class="field">
          <label>重置周期</label>
          <select v-model="form.period" class="select" data-test="user-period">
            <option value="monthly">每月</option><option value="weekly">每周</option><option value="daily">每天</option><option value="never">不重置</option>
          </select>
        </div>
        <div v-if="form.period === 'monthly' || form.period === 'weekly'" class="field">
          <label>{{ form.period === 'monthly' ? '每月几号重置' : '每周几重置' }}</label>
          <select v-if="form.period === 'weekly'" v-model.number="form.resetDay" class="select">
            <option v-for="(d, i) in ['周一', '周二', '周三', '周四', '周五', '周六', '周日']" :key="i" :value="i + 1">{{ d }}</option>
          </select>
          <input v-else v-model="form.resetDay" class="input" type="number" min="1" max="28" data-test="user-reset-day">
        </div>
      </div>
      <div v-if="periodMoved" class="notice warn small">改了重置周期：保存后从现在开始一个新周期，本周期已用的流量清零。</div>
      <label class="check" style="margin-bottom: 10px">
        <input v-model="showServers" type="checkbox" data-test="user-per-server"> 另外给某些服务器单独限额
      </label>
      <div v-if="showServers" class="per-server">
        <div v-for="s in servers" :key="s.id" class="per-server-row">
          <span>{{ s.name }}</span>
          <input v-model="form.perServer[s.id]" class="input" type="number" min="0" step="any" placeholder="只受总流量限制"
                 :data-test="`user-server-quota-${s.name}`"><span class="muted small">GB</span>
        </div>
        <div class="help">用完只暂停这台服务器，其他服务器照常。和总流量同时生效，先用完哪个就按哪个。</div>
      </div>

      <div class="section-title">可用节点</div>
      <div class="field">
        <div class="seg" role="radiogroup">
          <button v-for="m in (['all', 'label', 'node'] as const)" :key="m" type="button" :class="{ on: form.access === m }" role="radio"
                  :aria-checked="form.access === m" :data-test="`user-access-${m}`" @click="form.access = m">
            {{ m === 'all' ? '全部节点' : m === 'label' ? '按标签' : '指定节点' }}
          </button>
        </div>
        <div v-if="form.access === 'label'" class="chips" style="margin-top: 8px">
          <span v-for="l in form.labels" :key="l" class="chip">{{ l }}<button type="button" @click="form.labels = form.labels.filter((x) => x !== l)">×</button></span>
          <input v-model="form.labelDraft" list="user-labels" placeholder="输入标签后回车" @keydown.enter.prevent="addLabel()">
          <datalist id="user-labels"><option v-for="l in allLabels" :key="l" :value="l" /></datalist>
        </div>
        <div v-if="form.access === 'node'" class="node-pick">
          <label v-for="n in nodes" :key="n.id" class="check">
            <input type="checkbox" :checked="form.nodeIds.includes(n.id)" @change="toggleNode(n.id)">
            {{ n.display_name || n.name }} <span class="muted small">{{ serverName(n.server_id) }}</span>
          </label>
          <div v-if="!nodes.length" class="muted small">还没有节点。</div>
        </div>
        <div class="help" data-test="user-usable">符合分配条件的运行中节点：{{ usable.length }} 个。Shadowsocks、Snell、WireGuard 只有一套密钥，不分给用户；服务器接受这个用户后（几秒）节点才出现在订阅里。</div>
      </div>
      <label v-if="metered && unmeteredCount" class="check" style="margin-bottom: 14px">
        <input v-model="form.unmetered" type="checkbox" data-test="user-unmetered">
        也给 {{ unmeteredCount }} 个不按用户计量的节点（sing-box / mihomo 运行的，比如 AnyTLS）
      </label>

      <div class="section-title">其他</div>
      <div class="row2">
        <div class="field">
          <label>同时在线设备（IP）</label>
          <input v-model="form.devices" class="input" type="number" min="0" max="100" placeholder="不限" data-test="user-devices">
          <div class="help">超出时暂停 15 分钟。只统计 Xray 节点；挂在共享 443 上的节点看不到真实 IP，不计入。暂停和恢复都会重启这个用户所在服务器的内核，其他人的连接会断一下：多数朋友留空（不限）即可。</div>
        </div>
        <div class="field">
          <label>&nbsp;</label>
          <label class="check"><input v-model="form.enabled" type="checkbox" data-test="user-enabled"> 启用</label>
        </div>
      </div>
      <div class="help" data-test="user-restart-note">保存后，这个用户能用的服务器会收到新名单并重启内核（几秒），那几台上正在用的连接会断一下再自动连回。</div>
    </div>
    <template #foot>
      <button class="btn ghost" type="button" @click="emit('close')">取消</button>
      <button class="btn primary" type="button" :disabled="busy || (!editing && !form.name.trim())" data-test="user-save" @click="save">
        {{ busy ? '保存中…' : editing ? '保存' : '新建用户' }}
      </button>
    </template>
  </Modal>
</template>

<style scoped>
.per-server { border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px; margin-bottom: 16px }
.per-server-row { display: grid; grid-template-columns: minmax(80px, 1fr) 140px auto; align-items: center; gap: 10px; margin-bottom: 6px }
.per-server-row .input { padding: 5px 8px }
.seg { display: inline-flex; border: 1px solid var(--border-strong); border-radius: 8px; overflow: hidden }
.seg button { border: 0; background: transparent; padding: 6px 14px; cursor: pointer; color: inherit; font: inherit }
.seg button + button { border-left: 1px solid var(--border) }
.seg button.on { background: var(--accent-soft); color: var(--accent) }
.node-pick { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 6px 14px; margin-top: 10px;
  max-height: 200px; overflow: auto; border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px }
@media (max-width: 640px) { .row3 { grid-template-columns: 1fr } }
</style>
