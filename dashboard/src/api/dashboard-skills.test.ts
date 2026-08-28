import { describe, expect, it } from 'vitest'
import {
  decodeSkillEvidenceResponse,
  SkillsContractError,
} from './dashboard-skills'

const reference = {
  identity: {
    source_id: 'workspace',
    package_id: 'release-checklist',
    name: 'release-checklist',
  },
  content_revision: 'a'.repeat(64),
}

const coverage = {
  composition_scan_limit: 5000,
  composition_rows_scanned: 17,
  instruction_ledgers_loaded: 2,
  unavailable: [],
}

describe('skill evidence contract', () => {
  it('keeps instruction activation and composition result in one exact envelope', () => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v1',
      status: 'observed',
      reference,
      activation: {
        keeper: 'rondo',
        activation: {
          activated_at: '2026-08-28T03:00:00Z',
          skill_tool_use_id: 'skill-call-1',
          delivery: null,
          actions: [],
        },
      },
      composition: {
        run: { success: true, composition_run_id: 'run-1' },
        nodes: [{ tool_name: 'keeper_time_now' }],
      },
      coverage,
    })

    expect(decoded.activation?.keeper).toBe('rondo')
    expect(decoded.composition?.nodes).toHaveLength(1)
  })

  it('rejects observed status without any observed evidence', () => {
    expect(() => decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v1',
      status: 'observed',
      reference,
      activation: null,
      composition: null,
      coverage,
    })).toThrow(SkillsContractError)
  })

  it('keeps partial ledger coverage visible when nothing was observed', () => {
    const decoded = decodeSkillEvidenceResponse({
      schema: 'masc.skill-evidence/v1',
      status: 'never_observed',
      reference,
      activation: null,
      composition: null,
      coverage: {
        ...coverage,
        unavailable: ['sangsu: ledger_unreadable'],
      },
    })

    expect(decoded.coverage.unavailable).toEqual(['sangsu: ledger_unreadable'])
  })
})
