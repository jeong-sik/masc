import { describe, expect, it } from 'vitest'

import {
  parsePrometheusText,
  categorize,
  metricMatchesSearch,
} from './prometheus-metrics'

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

describe('categorize', () => {
  it('classifies keeper metrics', () => {
    expect(categorize('masc_keeper_compaction_total')).toBe('keeper')
  })

  it('classifies agent metrics', () => {
    expect(categorize('masc_agent_heartbeat_age_seconds')).toBe('agent')
  })

  it('classifies transport metrics', () => {
    expect(categorize('masc_sse_connections')).toBe('transport')
    expect(categorize('masc_grpc_requests')).toBe('transport')
  })

  it('classifies inference metrics', () => {
    expect(categorize('masc_inference_duration_seconds')).toBe('inference')
    expect(categorize('masc_llm_tokens')).toBe('inference')
  })

  it('classifies tool metrics', () => {
    expect(categorize('masc_tool_call_duration_seconds')).toBe('tool')
  })

  it('classifies server metrics', () => {
    expect(categorize('masc_uptime_seconds')).toBe('server')
    expect(categorize('masc_errors_total')).toBe('server')
  })

  it('classifies unknown as other', () => {
    expect(categorize('masc_custom_metric')).toBe('other')
  })
})

describe('metricMatchesSearch', () => {
  const metrics = parsePrometheusText(SAMPLE)

  it('matches by metric name', () => {
    const heartbeat = metrics.find(m => m.name === 'masc_agent_heartbeat_age_seconds')!
    expect(metricMatchesSearch(heartbeat, 'heartbeat')).toBe(true)
    expect(metricMatchesSearch(heartbeat, 'HEARTBEAT')).toBe(true)
  })

  it('matches by help text', () => {
    const uptime = metrics.find(m => m.name === 'masc_uptime_seconds')!
    expect(metricMatchesSearch(uptime, 'uptime')).toBe(true)
  })

  it('matches by label value', () => {
    const heartbeat = metrics.find(m => m.name === 'masc_agent_heartbeat_age_seconds')!
    expect(metricMatchesSearch(heartbeat, 'janitor')).toBe(true)
    expect(metricMatchesSearch(heartbeat, 'guardian')).toBe(true)
  })

  it('returns false for non-matching query', () => {
    const uptime = metrics.find(m => m.name === 'masc_uptime_seconds')!
    expect(metricMatchesSearch(uptime, 'nonexistent')).toBe(false)
  })

  it('matches by sample name', () => {
    const inference = metrics.find(m => m.name === 'masc_inference_duration_seconds')!
    expect(metricMatchesSearch(inference, 'inference')).toBe(true)
  })

  it('matches by quantile label value', () => {
    const inference = metrics.find(m => m.name === 'masc_inference_duration_seconds')!
    expect(metricMatchesSearch(inference, '0.99')).toBe(true)
  })
})
