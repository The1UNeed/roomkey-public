// 本机页面: talks to psm-agent's own API on this loopback address.
'use strict'

const $ = (s, el = document) => el.querySelector(s)
const STATE_LABEL = { active: '正常', disabled: '面板已停用', expired: '已过期', over_quota: '超出流量', paused_here: '本机暂停' }

async function api(path, opts = {}) {
  const res = await fetch(path, {
    method: opts.method || 'GET',
    headers: { 'Content-Type': 'application/json', 'X-PSM-Local': '1' },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
    credentials: 'same-origin',
  })
  if (res.status === 204) return null
  const data = await res.json().catch(() => ({}))
  if (!res.ok) {
    if (res.status === 401 && path !== '/api/login') showLogin()
    throw new Error(data?.error?.message || `HTTP ${res.status}`)
  }
  return data
}

function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag)
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v)
    else if (v !== false && v != null) e.setAttribute(k, v === true ? '' : v)
  }
  for (const k of kids.flat()) e.append(k instanceof Node ? k : document.createTextNode(String(k ?? '')))
  return e
}

function bytes(n) {
  if (!n) return '0'
  const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
  let i = 0
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++ }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`
}

let toastTimer
function toast(msg, bad = false) {
  const t = $('#toast')
  t.textContent = msg
  t.className = bad ? 'show bad' : 'show'
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (t.className = ''), 3500)
}

function busy(btn, on) {
  btn.disabled = on
  btn.classList.toggle('busy', on)
}

function showLogin() {
  $('#login').hidden = false
  $('#app').hidden = true
  $('#logout').hidden = true
}

async function boot() {
  const s = await api('/api/session')
  $('#host').textContent = s.hostname || '本机管理'
  $('#ver').textContent = `psm-agent ${s.agent_version}`
  if (!s.authenticated) {
    showLogin()
    if (!s.password_set) $('#login .muted').textContent += ' 本机还没有设置密码，只能用一次性代码登录。'
    return
  }
  $('#login').hidden = true
  $('#app').hidden = false
  $('#logout').hidden = false
  await Promise.all([loadOverview(), loadUsers()])
}

function ago(iso) {
  if (!iso) return '从未'
  const s = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 1000))
  return s < 60 ? `${s} 秒前` : s < 3600 ? `${Math.round(s / 60)} 分钟前` : `${Math.round(s / 3600)} 小时前`
}
function uptime(s) {
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600)
  return d ? `${d} 天 ${h} 小时` : `${h} 小时 ${Math.floor((s % 3600) / 60)} 分`
}

async function loadOverview() {
  const o = await api('/api/overview')
  const sys = o.system || {}
  const facts = [
    ['面板同步', `${ago(o.last_sync)}${o.events_pending ? `（${o.events_pending} 条修改待上报）` : ''}`],
    ['负载', sys.load ? sys.load.join(' / ') : '—'],
    ['内存', sys.mem_total ? `可用 ${bytes(sys.mem_available)} / ${bytes(sys.mem_total)}` : '—'],
    ['磁盘', sys.disk_total ? `可用 ${bytes(sys.disk_free)} / ${bytes(sys.disk_total)}` : '—'],
    ['运行时间', sys.uptime_s ? uptime(sys.uptime_s) : '—'],
    ['PSM', o.psm_version || '—'],
  ]
  if (o.events_error) facts.unshift(['⚠️ 未保存', o.events_error])
  $('#system').replaceChildren(...facts.flatMap(([k, v]) => [el('dt', {}, k), el('dd', {}, v)]))
  const cores = Array.isArray(o.cores) ? o.cores : []
  const tb = $('#cores tbody')
  tb.replaceChildren(...cores.filter((c) => c.installed).map((c) => el('tr', {},
    el('td', {}, c.core),
    // "Xray 26.3.27 (Xray, Penetrates Everything.)" → "26.3.27"; the whole line on hover
    el('td', { class: 'mono', title: c.version }, (/\d+\.\d+(\.\d+)?/.exec(c.version) || [c.version])[0]),
    el('td', {}, el('span', { class: c.active ? 'pill ok' : 'pill bad' }, c.active ? '运行中' : '已停止')),
    el('td', { class: 'actions' },
      el('button', { class: 'ghost', onclick: () => showLog(c.core) }, '日志'),
      el('button', { class: 'secondary', onclick: (e) => restart(c.core, e.currentTarget) }, '重启')),
  )))
  if (!tb.children.length) tb.append(el('tr', {}, el('td', { colspan: 4, class: 'muted' }, '没有安装内核')))

  const traffic = new Map((Array.isArray(o.traffic) ? o.traffic : []).map((t) => [t.tag, t]))
  const items = o.nodes?.items ?? []
  const nb = $('#nodes tbody')
  nb.replaceChildren(...items.map((it) => {
    const n = it.node || {}
    const t = traffic.get(it.tag)
    return el('tr', {},
      el('td', {}, n.display_name || it.tag, n.display_name ? el('div', { class: 'muted small mono' }, it.tag) : ''),
      el('td', {}, `${it.core} / ${it.protocol}`),
      el('td', { class: 'mono' }, n.public_port ?? n.port ?? ''),
      el('td', {}, t ? `${bytes(t.used_bytes)}${t.limit_bytes ? ' / ' + bytes(t.limit_bytes) : ''}${t.paused ? '（已暂停）' : ''}` : '—'),
      el('td', { class: 'actions' }, el('button', { class: 'ghost', onclick: () => editNode(it) }, '修改')))
  }))
  if (!items.length) nb.append(el('tr', {}, el('td', { colspan: 5, class: 'muted' }, '这台服务器还没有节点')))
}

async function loadUsers() {
  const u = await api('/api/users')
  const online = new Map((u.online?.users ?? []).map((x) => [x.name, x.ips]))
  const users = (u.usage?.users ?? []).filter((x) => x.managed)
  const tb = $('#users tbody')
  tb.replaceChildren(...users.map((x) => {
    const off = !!x.local_paused
    const ips = online.get(x.name) || []
    return el('tr', {},
      el('td', {}, x.name),
      el('td', {}, el('span', { class: x.state === 'active' ? 'pill ok' : 'pill bad' }, STATE_LABEL[x.state] || x.state)),
      el('td', {}, bytes(x.used_bytes)),
      el('td', { class: 'mono small' }, ips.length ? ips.join(', ') : '—'),
      el('td', { class: 'actions' }, el('button', {
        class: off ? 'secondary' : 'ghost danger',
        onclick: (e) => toggleUser(x.name, !off, e.currentTarget),
      }, off ? '在本机恢复' : '在本机暂停')))
  }))
  if (!users.length) tb.append(el('tr', {}, el('td', { colspan: 5, class: 'muted' }, '面板还没有给这台服务器分配用户')))
}

async function restart(core, btn) {
  if (!confirm(`重启 ${core}？正在使用的连接会断开几秒。`)) return
  busy(btn, true)
  try { await api(`/api/cores/${core}/restart`, { method: 'POST', body: {} }); toast(`${core} 已重启`); await loadOverview() }
  catch (e) { toast(e.message, true) }
  finally { busy(btn, false) }
}

async function showLog(core) {
  $('#log-title').textContent = `${core} 日志（最近 200 行）`
  $('#log-body').textContent = '读取中…'
  $('#log-dialog').showModal()
  try { $('#log-body').textContent = (await api(`/api/cores/${core}/logs`)).log || '（空）' }
  catch (e) { $('#log-body').textContent = e.message }
}

let editing = null
function editNode(it) {
  editing = it
  const f = $('#node-form')
  $('#node-title').textContent = `修改 ${it.tag}`
  f.port.value = it.node?.port ?? ''
  f.display_name.value = it.node?.display_name ?? ''
  $('#node-err').textContent = ''
  $('#node-dialog').showModal()
}

async function toggleUser(name, off, btn) {
  if (off && !confirm(`在本机暂停 ${name}？其他服务器不受影响，面板会收到记录。恢复只解除这里的暂停：面板停用的用户仍然停用。`)) return
  busy(btn, true)
  try { await api(`/api/users/${name}/${off ? 'disable' : 'enable'}`, { method: 'POST', body: {} }); toast(off ? `${name} 已在本机暂停` : `${name} 已在本机恢复`); await loadUsers() }
  catch (e) { toast(e.message, true) }
  finally { busy(btn, false) }
}

document.addEventListener('DOMContentLoaded', () => {
  $('#login-form').addEventListener('submit', async (e) => {
    e.preventDefault()
    const f = e.currentTarget
    $('#login-err').textContent = ''
    try {
      await api('/api/login', { method: 'POST', body: { code: f.code.value.trim(), password: f.password.value } })
      f.reset()
      await boot()
    } catch (err) { $('#login-err').textContent = err.message }
  })
  $('#logout').addEventListener('click', async () => { await api('/api/logout', { method: 'POST', body: {} }).catch(() => {}); showLogin() })
  $('#doctor-run').addEventListener('click', async (e) => {
    const btn = e.currentTarget
    busy(btn, true)
    try {
      const d = (await api('/api/doctor')).doctor
      const list = $('#doctor')
      list.replaceChildren(...(d?.checks ?? []).filter((c) => c.status !== 'skipped').map((c) =>
        el('li', { class: c.status }, el('span', { class: 'mark' }), c.message)))
      if (!list.children.length) list.append(el('li', { class: 'muted' }, '没有结果'))
    } catch (err) { toast(err.message, true) }
    finally { busy(btn, false) }
  })
  $('#check-run').addEventListener('click', async (e) => {
    const btn = e.currentTarget
    busy(btn, true)
    toast('外部检测要 1-3 分钟…')
    try {
      // psm check's report: {ipv4, ipv6} — the address, its network, and which services let it in
      const c = (await api('/api/check', { method: 'POST', body: {} })).check || {}
      const items = []
      for (const [label, f] of [['IPv4', c.ipv4], ['IPv6', c.ipv6]]) {
        if (!f) continue
        items.push(el('li', { class: 'ok' }, el('span', { class: 'mark' }),
          `${label} ${f.ip}${f.asn ? ` · AS${String(f.asn).replace(/^AS/i, '')}` : ''}${f.org ? ` ${f.org}` : ''}${f.country_name || f.country ? ` · ${f.country_name || f.country}` : ''}`))
        for (const svc of f.services ?? []) {
          const cls = svc.status === 'yes' ? 'ok' : svc.status === 'partial' ? 'warning' : svc.status === 'na' ? 'skipped' : 'critical'
          items.push(el('li', { class: cls }, el('span', { class: 'mark' }), `${svc.name}${svc.region ? ` (${svc.region})` : ''}`))
        }
      }
      $('#doctor').replaceChildren(...(items.length ? items : [el('li', { class: 'muted' }, '没有结果')]))
    } catch (err) { toast(err.message, true) }
    finally { busy(btn, false) }
  })
  $('#node-form').addEventListener('submit', async (e) => {
    e.preventDefault()
    const f = e.currentTarget
    const body = { port: Number(f.port.value), display_name: f.display_name.value }
    try {
      await api(`/api/nodes/${editing.core}/${editing.protocol}/${editing.tag}`, { method: 'POST', body })
      $('#node-dialog').close()
      toast('已保存，面板会在下次同步时更新')
      await loadOverview()
    } catch (err) { $('#node-err').textContent = err.message }
  })
  for (const b of document.querySelectorAll('[data-close]')) b.addEventListener('click', () => b.closest('dialog').close())
  boot().catch((e) => toast(e.message, true))
})
