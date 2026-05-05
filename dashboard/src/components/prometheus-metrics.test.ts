import { describe, expect, it } from 'vitest'

import { parsePrometheusText } from './prometheus-metrics'

const SAMPLE = `# HELP masc_uptime_seconds Server uptime in seconds
# TYPE masc_uptime_seconds gauge
masc_uptime_seconds 12345.6
# HELP masc_agent_heartbeat_age_seconds Age of last agent heartbeat
# TYPE masc_agent_heartbeat_age_seconds gauge
masc_agent_heartbeat_age_seconds{keeper="janitor"} 5.2
masc_agent_heartbeat_age_seconds{keeper="guardian"} 120.0
# HELP masc_keeper_compaction_total Total compaction events
# TYPE masc_keeper_compaction_total counter
masc_keeper_compaction_total{keeper="janitor"} 42
# HELP masc_inference_duration_seconds LLM inference duration
# TYPE masc_inference_duration_seconds summary
masc_inference_duration_seconds{quantile="0.5"} 1.23
masc_inference_duration_seconds{quantile="0.99"} 5.67
# HELP masc_sse_connections Current SSE connections
# TYPE masc_sse_connections gauge
masc_sse_connections 3
`

describe('parsePrometheusText', () => {
  it('parses HELP + TYPE + sample lines', () => {
    const metrics = parsePrometheusText(SAMPLE)
    expect(metrics.length).toBe(5)

    const uptime = metrics.find(m => m.name === 'masc_uptime_seconds')!
    expect(uptime.help).toBe('Server uptime in seconds')
    expect(uptime.type).toBe('gauge')
    expect(uptime.samples.length).toBe(1)
    expect(uptime.samples[0]!.value).toBe(12345.6)
  })

  it('parses labels from samples', () => {
    const metrics = parsePrometheusText(SAMPLE)
    const heartbeat = metrics.find(m => m.name === 'masc_agent_heartbeat_age_seconds')!
    expect(heartbeat.samples.length).toBe(2)
    expect(heartbeat.samples[0]!.labels).toEqual({ keeper: 'janitor' })
    expect(heartbeat.samples[1]!.labels).toEqual({ keeper: 'guardian' })
  })

  it('handles empty input', () => {
    expect(parsePrometheusText('')).toEqual([])
    expect(parsePrometheusText('# only comments')).toEqual([])
  })
})

