import { compute as before } from './before.mjs'
import { compute as timeWindow } from './time-window.mjs'
import { compute as singlePitch } from './single-pitch.mjs'
import { PerformanceObserver, performance } from 'node:perf_hooks'

// Observational CPU/wall/GC probe, without screen/layout assertions. The
// adapter's inputs are synthetic and no project, terminal or device is opened.
const variants = { before, 'time-window': timeWindow, 'single-pitch': singlePitch }
const names = Object.keys(variants)
const orders = names.flatMap((_, offset) => {
  const order = [...names.slice(offset), ...names.slice(0, offset)]
  return [order, order.toReversed()]
})
const gc = []
const observer = new PerformanceObserver(list => {
  for (const entry of list.getEntries()) gc.push({
    start_ms: entry.startTime, duration_ms: entry.duration, detail: entry.detail,
  })
})
observer.observe({ entryTypes: ['gc'] })
const records = []
let checksum = 0
for (const rows of [13, 24, 48]) for (const count of [0, 30, 300, 3000, 30000]) {
  for (const distribution of count === 0 ? ['empty'] : ['onscreen-uniform', 'onscreen-one-pitch']) {
    const notes = Array.from({ length: count }, (_, index) => ({
      id: `n${index}`, pitch: distribution === 'onscreen-uniform' ? index % 128 : 60,
      start: (4064 + index % 112) * 120, duration: 120,
      velocity: 64 + index % 64,
    }))
    const input = {
      rows, cols: 112, editor: { pitch: 60, step: 120, tick: 4096 * 120 },
      project: { length: 8192 * 120 }, playColumn: 30, first: 4064 * 120,
      track: { notes }, selection: new Set(notes.filter((_, index) => index % 13 === 0).map(note => note.id)),
      current: notes[0], percussion: false,
    }
    const iterations = count === 30000 ? 16 : 64
    for (const compute of Object.values(variants)) for (let warm = 0; warm < 16; warm++) checksum += compute(input).length
    for (let batch = 0; batch < orders.length; batch++) for (const variant of orders[batch]) {
      const compute = variants[variant], samples_us = []
      const heap_before = process.memoryUsage().heapUsed
      const cpu_start = process.cpuUsage(), start_ms = performance.now()
      const start_ns = process.hrtime.bigint()
      for (let call = 0; call < iterations; call++) {
        const call_start = process.hrtime.bigint()
        checksum += compute(input).length
        samples_us.push(Number(process.hrtime.bigint() - call_start) / 1000)
      }
      const elapsed_ns = process.hrtime.bigint() - start_ns, end_ms = performance.now()
      const cpu = process.cpuUsage(cpu_start), heap_after = process.memoryUsage().heapUsed
      records.push({ rows, count, distribution, batch, order: orders[batch], variant,
        iterations, samples_us, wall_us_per_call: Number(elapsed_ns) / 1000 / iterations,
        cpu_user_us_per_call: cpu.user / iterations, cpu_system_us_per_call: cpu.system / iterations,
        heap_used_delta: heap_after - heap_before, start_ms, end_ms,
      })
      await new Promise(resolve => setImmediate(resolve))
    }
  }
}
await new Promise(resolve => setImmediate(resolve))
observer.disconnect()
process.stdout.write(JSON.stringify({
  scope: 'Actual piano-roll loop plus synthetic arguments and String pitch labels. Per-call samples include timing overhead; CPU is a batch mean. Heap-used deltas are not allocation counts. GC entries are observations of this whole process, including warmup. No output/layout/text assertions, terminal writes, actual DAW interaction, audio/MIDI or flicker measurement.',
  node: process.version, exec_argv: process.execArgv, checksum,
  records, gc,
}) + '\n')
