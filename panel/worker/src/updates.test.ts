import { describe, expect, it } from 'vitest'
import { inWindow, localHour, windowProblem } from './updates'

describe('the update window', () => {
  it('is [start, end), across midnight when end < start', () => {
    expect([3, 4, 5, 6].map((h) => inWindow(h, { start: 4, end: 6 }))).toEqual([false, true, true, false])
    expect([22, 23, 0, 1, 2].map((h) => inWindow(h, { start: 23, end: 2 }))).toEqual([false, true, true, true, false])
  })
  it('reads the hour in its time zone', () => {
    const t = new Date('2026-11-26T19:30:00Z')
    expect(localHour(t, 'UTC')).toBe(19)
    expect(localHour(t, 'Asia/Shanghai')).toBe(3)        // UTC+8: 03:30 the next day
    expect(localHour(t, 'Pacific/Auckland')).toBe(8)     // UTC+13 in summer
    expect(localHour(new Date('2026-11-26T16:00:00Z'), 'Asia/Shanghai')).toBe(0)   // midnight is 0, not 24
  })
  it('refuses a window it cannot keep', () => {
    expect(windowProblem({ start: 4, end: 6, tz: 'Asia/Shanghai' })).toBeNull()
    expect(windowProblem({ start: 4, end: 4, tz: 'UTC' })).toMatch(/同一个/)
    expect(windowProblem({ start: 4, end: 24, tz: 'UTC' })).toMatch(/0-23/)
    expect(windowProblem({ start: 1.5, end: 3, tz: 'UTC' })).toMatch(/0-23/)
    expect(windowProblem({ start: 1, end: 3, tz: 'Mars/Base' })).toMatch(/时区/)
  })
})
