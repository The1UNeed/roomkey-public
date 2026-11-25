import { describe, expect, it } from 'vitest'
import {
  activeOn, canReach, counterDelta, needsMetering, linkFor, localCode, periodEnd, periodId, periodStart, proxyFor, userinfoHeader, userNodes, userState,
} from './users'

const cred = { uuid: '11111111-2222-4333-8444-555555555555', password: 'userpass_123' }
const at = (s: string) => new Date(s)

describe('periods', () => {
  it('monthly starts on the reset day, this month or the last', () => {
    expect(periodStart(at('2026-11-24T10:00:00Z'), 'monthly', 1)).toBe('2026-11-01')
    expect(periodStart(at('2026-11-24T10:00:00Z'), 'monthly', 25)).toBe('2026-10-25')
    expect(periodStart(at('2026-11-25T00:00:00Z'), 'monthly', 25)).toBe('2026-11-25')
    expect(periodStart(at('2026-01-10T00:00:00Z'), 'monthly', 15)).toBe('2025-12-15')   // across the year
    expect(periodStart(at('2026-03-31T00:00:00Z'), 'monthly', 31)).toBe('2026-03-28')   // capped at 28
  })
  it('weekly starts on the given weekday (1 = Monday)', () => {
    // 2026-11-24 is a Tuesday
    expect(periodStart(at('2026-11-24T10:00:00Z'), 'weekly', 1)).toBe('2026-11-23')
    expect(periodStart(at('2026-11-24T10:00:00Z'), 'weekly', 2)).toBe('2026-11-24')
    expect(periodStart(at('2026-11-24T10:00:00Z'), 'weekly', 7)).toBe('2026-11-22')
  })
  it('daily, never, and the ends', () => {
    // days are Beijing days: 23:59 UTC is 07:59 the next morning there
    expect(periodStart(at('2026-11-24T15:59:59Z'), 'daily', 1)).toBe('2026-11-24')
    expect(periodStart(at('2026-11-24T16:00:00Z'), 'daily', 1)).toBe('2026-11-25')
    expect(periodStart(at('2026-11-30T16:00:00Z'), 'monthly', 1)).toBe('2026-12-01')
    expect(periodStart(at('2026-11-24T10:00:00Z'), 'never', 1)).toBeNull()
    expect(periodEnd('2026-11-01', 'monthly')).toBe('2026-12-01')
    expect(periodEnd('2026-12-15', 'monthly')).toBe('2027-01-15')
    expect(periodEnd('2026-11-23', 'weekly')).toBe('2026-11-30')
    expect(periodEnd(null, 'never')).toBeNull()
    expect(periodId('monthly', '2026-11-01')).toBe('monthly:2026-11-01')
    expect(periodId('never', null)).toBe('never')
  })
})

describe('state', () => {
  const now = Date.parse('2026-11-24T10:00:00Z')
  const base = { enabled: 1, expires_at: null, quota_total_bytes: null, used_total_bytes: 0, blocked_until: null }
  it('reads every reason a user is off', () => {
    expect(userState(base, now)).toBe('active')
    expect(userState({ ...base, enabled: 0 }, now)).toBe('disabled')
    expect(userState({ ...base, expires_at: '2026-11-24 09:59:59' }, now)).toBe('expired')
    expect(userState({ ...base, expires_at: '2026-11-24 10:00:01' }, now)).toBe('active')
    expect(userState({ ...base, quota_total_bytes: 100, used_total_bytes: 100 }, now)).toBe('over_quota')
    expect(userState({ ...base, quota_total_bytes: 100, used_total_bytes: 99 }, now)).toBe('active')
    expect(userState({ ...base, blocked_until: '2026-11-24 10:10:00' }, now)).toBe('devices')
    expect(userState({ ...base, blocked_until: '2026-11-24 09:00:00' }, now)).toBe('active')
  })
  it('a per-server quota pauses that server only', () => {
    expect(activeOn('active', undefined)).toBe(true)
    expect(activeOn('active', { quota_bytes: null, used_bytes: 1e12 })).toBe(true)
    expect(activeOn('active', { quota_bytes: 500, used_bytes: 500 })).toBe(false)
    expect(activeOn('expired', { quota_bytes: null, used_bytes: 0 })).toBe(false)
  })
  it('counters only grow; a smaller one started over', () => {
    expect(counterDelta(100, 150)).toBe(50)
    expect(counterDelta(100, 100)).toBe(0)
    expect(counterDelta(100, 30)).toBe(30)
  })
})

describe('access', () => {
  const nodes = [
    { id: 1, labels: ['hk'], psm_protocol: 'reality', engine: 'xray' },
    { id: 2, labels: ['jp'], psm_protocol: 'anytls', engine: 'sing-box' },
    { id: 3, labels: ['hk'], psm_protocol: 'ss2022', engine: 'xray' },
    { id: 4, labels: [], psm_protocol: 'hysteria2', engine: 'xray' },
  ]
  it('by everything, label or node', () => {
    expect(canReach([{ kind: 'all', value: '' }], nodes[0])).toBe(true)
    expect(canReach([{ kind: 'label', value: 'jp' }], nodes[0])).toBe(false)
    expect(canReach([{ kind: 'node', value: '1' }], nodes[0])).toBe(true)
    expect(canReach([], nodes[0])).toBe(false)
  })
  it('leaves out single-key protocols, and unmetered nodes for users with a quota', () => {
    const all = [{ kind: 'all' as const, value: '' }]
    expect(userNodes(all, nodes, { needsMetering: false, unmetered: false }).map((n) => n.id)).toEqual([1, 2, 4])
    expect(userNodes(all, nodes, { needsMetering: true, unmetered: false }).map((n) => n.id)).toEqual([1, 4])
    expect(userNodes(all, nodes, { needsMetering: true, unmetered: true }).map((n) => n.id)).toEqual([1, 2, 4])
  })
  it('metering is needed for quotas and for a first-use term not yet started', () => {
    const u = { quota_total_bytes: null, first_use_days: null, first_used_at: null }
    expect(needsMetering(u, false)).toBe(false)
    expect(needsMetering(u, true)).toBe(true)
    expect(needsMetering({ ...u, quota_total_bytes: 1 }, false)).toBe(true)
    expect(needsMetering({ ...u, first_use_days: 30 }, false)).toBe(true)
    expect(needsMetering({ ...u, first_use_days: 30, first_used_at: '2026-11-01 00:00:00' }, false)).toBe(false)
  })
})

describe('credentials in links and proxies', () => {
  it('VLESS REALITY keeps everything but the UUID', () => {
    const l = 'vless://00000000-0000-4000-8000-000000000000@n1.myroom.asia:443?security=reality&sni=n1.myroom.asia&pbk=abc&sid=01#PSM-hk'
    expect(linkFor(l, cred)).toBe(`vless://${cred.uuid}@n1.myroom.asia:443?security=reality&sni=n1.myroom.asia&pbk=abc&sid=01#PSM-hk`)
  })
  it('passwords for Trojan, Hysteria2 (both schemes), AnyTLS; both for TUIC', () => {
    expect(linkFor('trojan://owner@h:443?sni=h#n', cred)).toBe('trojan://userpass_123@h:443?sni=h#n')
    expect(linkFor('hysteria2://owner@h:443/?sni=h&obfs=salamander#n', cred)).toBe('hysteria2://userpass_123@h:443/?sni=h&obfs=salamander#n')
    expect(linkFor('hy2://owner@h:443#n', cred)).toBe('hy2://userpass_123@h:443#n')
    expect(linkFor('anytls://ow%40ner@h:443?sni=h#n', cred)).toBe('anytls://userpass_123@h:443?sni=h#n')
    expect(linkFor('tuic://00000000-0000-4000-8000-000000000000:owner@h:443?congestion_control=bbr#n', cred))
      .toBe(`tuic://${cred.uuid}:userpass_123@h:443?congestion_control=bbr#n`)
  })
  it('an @ in the query is not the credentials', () => {
    expect(linkFor('trojan://owner@h:443?path=/a@b#x@y', cred)).toBe('trojan://userpass_123@h:443?path=/a@b#x@y')
  })
  it('VMess carries the UUID inside its JSON', () => {
    const j = { v: '2', ps: 'n', add: 'h', port: '443', id: '00000000-0000-4000-8000-000000000000', net: 'ws' }
    const out = linkFor('vmess://' + btoa(JSON.stringify(j)), cred)!
    expect(JSON.parse(atob(out.slice(8)))).toEqual({ ...j, id: cred.uuid })
  })
  it('single-key and unknown links are not for users', () => {
    expect(linkFor('ss://YWVzOnBhc3M@h:443#n', cred)).toBeNull()
    expect(linkFor('not a link', cred)).toBeNull()
    expect(linkFor('vless://h:443', cred)).toBeNull()
  })
  it('sing-box outbounds and mihomo proxies', () => {
    expect(proxyFor({ type: 'vless', uuid: 'o', server: 'h' }, cred)).toEqual({ type: 'vless', uuid: cred.uuid, server: 'h' })
    expect(proxyFor({ type: 'hysteria2', password: 'o' }, cred)).toEqual({ type: 'hysteria2', password: cred.password })
    expect(proxyFor({ type: 'tuic', uuid: 'o', password: 'o' }, cred)).toEqual({ type: 'tuic', uuid: cred.uuid, password: cred.password })
    expect(proxyFor({ type: 'shadowsocks', password: 'o' }, cred)).toBeNull()
    expect(proxyFor(null, cred)).toBeNull()
  })
})

describe('header and codes', () => {
  it('Subscription-Userinfo', () => {
    expect(userinfoHeader(1234.7, 10_000, '2026-12-01 00:00:00')).toBe('upload=0; download=1234; total=10000; expire=1796083200')
    expect(userinfoHeader(5, null, null)).toBe('upload=0; download=5; total=0')
  })
  it('local codes look like XXXX-XXXX without look-alikes', () => {
    const c = localCode(new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7]))
    expect(c).toMatch(/^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$/)
  })
})
