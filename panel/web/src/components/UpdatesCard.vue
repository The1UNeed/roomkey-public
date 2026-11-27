<script setup lang="ts">
// 系统设置 → 更新: what runs now and what the newest release is, automatic
// updates in one window (hours and a time zone, from dropdowns), and the
// buttons to update the panel or every server now. The panel's own update
// goes in steps (worker/src/updates.ts): this page asks for the next one
// until it is done, then reloads into the new panel.
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { api, errorText } from '../api'
import { confirmAction, toast } from '../ui'
import Icon from './Icon.vue'

type Job = { version: string; stage: 'assets' | 'script' | 'done' | 'failed'; error?: string; uploaded?: number; total?: number; finished_at?: string }
type State = {
  auto: boolean; window: { start: number; end: number; tz: string }; local_hour: number; in_window: boolean
  panel: { version: string; agent_version: string; latest: null | { version: string; tag: string; published_at: string | null; notes_url: string }
    newer: boolean; checked_at: string; check_error: string | null; missing: string[]; job: Job | null; repo: string }
  servers: { id: number; name: string; agent_version: string | null; psm_version: string | null; online: boolean; asked: boolean }[]
}
const st = ref<State | null>(null)
const form = reactive({ auto: false, start: 4, end: 6, tz: 'Asia/Shanghai' })
const busy = ref<'' | 'check' | 'save' | 'panel' | 'servers'>('')
const error = ref('')
function take(s: State) {
  st.value = s
  Object.assign(form, { auto: s.auto, start: s.window.start, end: s.window.end, tz: s.window.tz })
}
async function load() {
  try { take(await api<State>('/api/updates')) } catch (e) { error.value = errorText(e) }
}
onMounted(load)

const HOURS = Array.from({ length: 24 }, (_, h) => h)
const pad = (h: number) => `${String(h).padStart(2, '0')}:00`
// the zones people here use, and the browser's own
const ZONES = [...new Set([Intl.DateTimeFormat().resolvedOptions().timeZone, 'Asia/Shanghai', 'Asia/Hong_Kong', 'Asia/Taipei', 'Asia/Singapore',
  'Asia/Tokyo', 'Asia/Seoul', 'Pacific/Auckland', 'Australia/Sydney', 'Europe/London', 'Europe/Berlin', 'America/Los_Angeles', 'America/New_York', 'UTC'])]
// the window cannot start and end on the same hour: moving the start onto the end moves the end on
watch(() => form.start, (s) => { if (form.end === s) form.end = (s + 2) % 24 })
const dirty = computed(() => !!st.value && (form.auto !== st.value.auto || form.start !== st.value.window.start || form.end !== st.value.window.end || form.tz !== st.value.window.tz))
// the hour there now, for the zone picked (before it is saved too)
const hourIn = (tz: string) => { try { return Number(new Intl.DateTimeFormat('en-GB', { timeZone: tz, hour: '2-digit', hourCycle: 'h23' }).format(new Date())) } catch { return st.value?.local_hour ?? 0 } }
const nowHour = computed(() => hourIn(form.tz))
const nowInWindow = computed(() => form.start < form.end ? nowHour.value >= form.start && nowHour.value < form.end : nowHour.value >= form.start || nowHour.value < form.end)
const windowText = computed(() => `${pad(form.start)}–${pad(form.end)}${form.end < form.start ? '（次日）' : ''}`)

async function save() {
  error.value = ''
  busy.value = 'save'
  try {
    take(await api<State>('/api/updates/settings', { method: 'PUT', body: JSON.stringify({ auto: form.auto, window: { start: form.start, end: form.end, tz: form.tz } }) }))
    toast('已保存')
  } catch (e) { error.value = errorText(e) } finally { busy.value = '' }
}
async function check() {
  error.value = ''
  busy.value = 'check'
  try { take(await api<State>('/api/updates/check', { method: 'POST' })) } catch (e) { error.value = errorText(e) } finally { busy.value = '' }
}

let alive = true
onUnmounted(() => { alive = false })
const job = computed(() => st.value?.panel.job ?? null)
async function updatePanel() {
  const l = st.value?.panel.latest
  if (!l || !(await confirmAction({ title: `更新面板到 ${l.version}`, body: '面板会下载新版本，上传到你的 Cloudflare 账号，再换上新代码。数据和设置都保留；换代码的一瞬间正在打开的页面会刷新。', ok: '更新' }))) return
  error.value = ''
  busy.value = 'panel'
  try {
    let j = await api<Job>('/api/updates/panel', { method: 'POST' })
    while (alive && (j.stage === 'assets' || j.stage === 'script')) {
      st.value!.panel.job = j
      j = await api<Job>('/api/updates/panel/step', { method: 'POST' })
    }
    st.value!.panel.job = j
    if (j.stage === 'done') { toast(`面板已更新到 ${j.version}，正在重新载入`); setTimeout(() => location.reload(), 1500) }
    else if (j.stage === 'failed') error.value = j.error ?? '更新失败'
  } catch (e) { error.value = errorText(e) } finally { busy.value = '' }
}
async function updateServers() {
  const n = st.value?.servers.filter((s) => s.online).length ?? 0
  if (!(await confirmAction({ title: `更新 ${n} 台服务器`, body: '每台服务器会更新服务器组件，运行中的节点会短暂重启（几秒）。', ok: '全部更新' }))) return
  error.value = ''
  busy.value = 'servers'
  try {
    const r = await api<{ asked: number }>('/api/updates/servers', { method: 'POST' })
    toast(r.asked ? `已通知 ${r.asked} 台服务器更新` : '没有在线、需要更新的服务器')
    await load()
  } catch (e) { error.value = errorText(e) } finally { busy.value = '' }
}
const ago = (iso: string) => { const m = Math.round((Date.now() - Date.parse(iso)) / 60000); return m < 1 ? '刚刚' : m < 60 ? `${m} 分钟前` : `${Math.round(m / 60)} 小时前` }
</script>

<template>
  <div class="card card-pad section" data-test="updates">
    <div class="hstack" style="margin-bottom: 12px"><Icon name="refresh" /><strong>更新</strong>
      <span v-if="st?.panel.newer" class="badge accent" data-test="update-available">有新版本 {{ st.panel.latest?.version }}</span>
      <span v-else-if="st?.panel.latest" class="badge ok">面板是最新版本</span>
      <span v-if="st?.servers.length" class="badge warn">{{ st.servers.length }} 台服务器待更新</span>
    </div>
    <div v-if="error" class="errors" data-test="updates-error">{{ error }}</div>
    <div v-if="!st" class="skeleton" style="height: 120px" />
    <template v-else>
      <div class="grid-2">
        <dl class="facts">
          <dt>面板</dt><dd>{{ st.panel.version }}<template v-if="st.panel.latest">（最新 <a :href="st.panel.latest.notes_url" target="_blank" rel="noopener noreferrer">{{ st.panel.latest.version }}</a>）</template></dd>
          <dt>服务器</dt><dd>服务器组件 {{ st.panel.agent_version }}<template v-if="st.servers.length">；待更新：{{ st.servers.map((s) => s.name + (s.online ? '' : '（离线）') + (s.asked ? '（已通知）' : '')).join('、') }}</template><template v-else>，全部已是最新</template></dd>
          <dt>上次检查</dt><dd>{{ ago(st.panel.checked_at) }}<span v-if="st.panel.check_error" class="err-text">：{{ st.panel.check_error }}</span>
            · <button type="button" class="link-btn" :disabled="!!busy" data-test="update-check" @click="check">{{ busy === 'check' ? '检查中…' : '立即检查' }}</button></dd>
          <dt>发布来源</dt><dd><a :href="`https://github.com/${st.panel.repo}/releases`" target="_blank" rel="noopener noreferrer">github.com/{{ st.panel.repo }}</a></dd>
        </dl>
        <div>
          <label class="check" style="margin-bottom: 10px"><input v-model="form.auto" type="checkbox" data-test="update-auto"> <b>在更新时段内自动更新</b></label>
          <div class="update-window" :class="{ off: !form.auto }">
            <select v-model.number="form.start" class="select" data-test="update-start" aria-label="开始" :disabled="!form.auto">
              <option v-for="h in HOURS" :key="h" :value="h">从 {{ pad(h) }}</option>
            </select>
            <select v-model.number="form.end" class="select" data-test="update-end" aria-label="结束" :disabled="!form.auto">
              <option v-for="h in HOURS" :key="h" :value="h" :disabled="h === form.start">到 {{ pad(h) }}</option>
            </select>
            <select v-model="form.tz" class="select tz" data-test="update-tz" aria-label="时区" :disabled="!form.auto">
              <option v-for="z in ZONES" :key="z" :value="z">{{ z }}</option>
            </select>
          </div>
          <div v-if="form.auto" class="help">
            每天 {{ windowText }}（{{ form.tz }}）之间：先更新面板，再逐台更新服务器（每 5 分钟最多 3 台）。现在那里是 {{ pad(nowHour) }}{{ nowInWindow ? '，在时段内' : '' }}。
          </div>
          <div v-else class="help">关着：有新版本时只在这里提示，由你点下面的按钮更新。</div>
          <button class="btn primary" type="button" style="margin-top: 10px" :disabled="!dirty || !!busy" data-test="update-save" @click="save">{{ busy === 'save' ? '保存中…' : '保存' }}</button>
        </div>
      </div>

      <div v-if="st.panel.missing.length" class="notice warn" style="margin: 14px 0 0" data-test="update-missing">
        面板还不能自己更新，缺：{{ st.panel.missing.join('、') }}。在部署面板的电脑上重新运行一键脚本、选「让面板自动更新」即可；服务器的自动更新不受影响。
      </div>
      <div v-if="job && job.stage !== 'done'" class="notice" :class="job.stage === 'failed' ? 'err' : 'info'" style="margin: 14px 0 0" data-test="update-job">
        <template v-if="job.stage === 'failed'">更新到 {{ job.version }} 失败：{{ job.error }}。面板仍是旧版本，可以再试一次。</template>
        <template v-else-if="job.stage === 'assets'">正在更新到 {{ job.version }}：上传文件 {{ job.uploaded ?? 0 }}/{{ job.total ?? '?' }}…</template>
        <template v-else>正在更新到 {{ job.version }}：换上新代码…</template>
      </div>
      <div class="hstack" style="margin-top: 14px">
        <button class="btn" :class="{ primary: st.panel.newer }" type="button" :disabled="!st.panel.newer || !!st.panel.missing.length || !!busy" data-test="update-panel" @click="updatePanel">
          <span v-if="busy === 'panel'" class="spinner" />{{ busy === 'panel' ? '更新中…' : st.panel.newer ? `立即更新面板到 ${st.panel.latest?.version}` : '面板已是最新' }}
        </button>
        <button class="btn" type="button" :disabled="!st.servers.some((s) => s.online) || !!busy" data-test="update-servers" @click="updateServers">
          <span v-if="busy === 'servers'" class="spinner" />更新所有服务器
        </button>
      </div>
    </template>
  </div>
</template>
