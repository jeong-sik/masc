import { describe, expect, it } from 'vitest'
import {
  workerRunEvidenceLabel,
  workerRunEvidenceMeta,
  workerRunEvidencePreview,
  workerRunEvidenceTone,
} from './proof-helpers'

describe('workerRunEvidence helpers', () => {
  it('marks validated raw traces as ok', () => {
    const item = {
      worker_run_id: 'worker-1',
      trace_capability: 'raw',
      trace_validated: true,
      resolved_runtime: 'local',
      resolved_model: 'qwen',
      tool_surface_names: ['file_read', 'file_write', 'shell_exec'],
      tool_call_count: 3,
    }

    expect(workerRunEvidenceTone(item)).toBe('ok')
    expect(workerRunEvidenceLabel(item)).toBe('검증됨')
    expect(workerRunEvidenceMeta(item)).toContain('local')
    expect(workerRunEvidenceMeta(item)).toContain('qwen')
    expect(workerRunEvidenceMeta(item)).toContain('surface 3')
    expect(workerRunEvidenceMeta(item)).toContain('도구 3')
  })

  it('marks unvalidated raw traces as warn', () => {
    const item = {
      worker_run_id: 'worker-raw-observed',
      trace_capability: 'raw',
      trace_validated: false,
    }

    expect(workerRunEvidenceTone(item)).toBe('warn')
    expect(workerRunEvidenceLabel(item)).toBe('raw observed')
  })

  it('marks missing tool surface explicitly in meta', () => {
    const item = {
      worker_run_id: 'worker-surface-missing',
      tool_surface_status: 'missing',
    }

    expect(workerRunEvidenceMeta(item)).toContain('surface missing')
  })

  it('prefers final text preview, then falls back to errors', () => {
    expect(
      workerRunEvidencePreview({
        worker_run_id: 'worker-2',
        final_text: 'final answer',
        output_preview: 'preview',
        error: 'boom',
      }),
    ).toBe('final answer')

    expect(
      workerRunEvidencePreview({
        worker_run_id: 'worker-3',
        success: false,
        failure_reason: 'tool timeout',
      }),
    ).toBe('tool timeout')
  })

  it('marks failed runs as bad', () => {
    const item = {
      worker_run_id: 'worker-4',
      success: false,
      error: 'subprocess crashed',
    }

    expect(workerRunEvidenceTone(item)).toBe('bad')
    expect(workerRunEvidenceLabel(item)).toBe('실패')
  })
})
