import { expect, test } from 'claude-code/testing'

import { describeCall, endedTasks, redact, fmtSeconds, fmtTokens, fmtUntil, fmtUsd, levelOf, limitLabel, meterFill, plural } from '../hooks/core'

test('gauges turn amber at 70% and red at 90%', () => {
  expect(levelOf(69)).toBe('ok')
  expect(levelOf(70)).toBe('warn')
  expect(levelOf(89.9)).toBe('warn')
  expect(levelOf(90)).toBe('high')
})

test('figures are shortened for one line', () => {
  expect(fmtTokens(950)).toBe('950')
  expect(fmtTokens(84_300)).toBe('84k')
  expect(fmtTokens(1_000_000)).toBe('1.0M')
  expect(fmtUsd(1.234)).toBe('$1.23')
  expect(fmtUsd(140.6)).toBe('$141')
  expect(fmtSeconds(41)).toBe('41s')
  expect(fmtSeconds(125)).toBe('2m05s')
  expect(plural(1, 'tool')).toBe('1 tool')
  expect(plural(2, 'edit')).toBe('2 edits')
})

test('rate-limit windows get short labels', () => {
  expect(limitLabel('five_hour')).toBe('5-hour limit')
  expect(limitLabel('seven_day')).toBe('Weekly limit')
  expect(limitLabel('some_other')).toBe('some other')
})

test('a meter shows any use as one cell and never overflows', () => {
  expect(meterFill(0, 8)).toBe(0)
  expect(meterFill(1, 8)).toBe(1)
  expect(meterFill(50, 8)).toBe(4)
  expect(meterFill(100, 8)).toBe(8)
  expect(meterFill(130, 8)).toBe(8)
})

test('time until a reset is short and empty once passed', () => {
  expect(fmtUntil(-5)).toBe('')
  expect(fmtUntil(42 * 60_000)).toBe('42m')
  expect(fmtUntil((2 * 60 + 14) * 60_000)).toBe('2h 14m')
  expect(fmtUntil((3 * 24 + 4) * 3_600_000)).toBe('3d 4h')
})

test('a running call is described by its command, file or tool', () => {
  expect(describeCall('Bash', { command: 'sleep 8;   date +%T' })).toBe('sleep 8; date +%T')
  expect(describeCall('Read', { file_path: '/Users/me/project/src/app.ts' })).toBe('Read app.ts')
  expect(describeCall('Grep', { pattern: 'TODO' })).toBe('Grep TODO')
  expect(describeCall('mcp__github__list_issues', {})).toBe('list_issues')
  expect(describeCall('Bash', { command: 'x'.repeat(80) }).length).toBe(48)
})

test('secrets in a command are not shown', () => {
  expect(redact('curl -H "Authorization: Bearer abc.def.123" x')).not.toContain('abc.def')
  expect(redact('API_KEY=sk-12345 run')).not.toContain('sk-12345')
  expect(redact('psql postgres://bob:hunter2@db/x')).not.toContain('hunter2')
})

test('a notification names the tasks that ended', () => {
  const note = '<task-notification>\n<task-id>b07e1xt38</task-id>\n<output-file>/tmp/x</output-file>\n<status>completed</status>\n</task-notification>'
  expect(endedTasks(note)).toEqual([{ id: 'b07e1xt38', isFailed: false }])
  expect(endedTasks(note.replace('completed', 'failed'))).toEqual([{ id: 'b07e1xt38', isFailed: true }])
  expect(endedTasks('just a prompt')).toEqual([])
})
