import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { decodeRequestObservations } from './request-observation'

const receipt = { requested:8192, effective:4096, policy:'explicit_clamped', ceiling:4096, ceiling_source:'catalog_model', envelope:'ollama_options_num_predict' }
const fact = {state:'serialized',request:{output_token_receipt:receipt,body_bytes:100,body_sha256:'a'.repeat(64)}}
const row = {runtime_profile:'native.fixture',attempt:0,evidence:{status:'recorded',call_id:'call-1',requests:[{node_id:'node-1',turn:0,ordinal:0,provenance:fact}]}}
describe('persisted request observation boundary', () => {
  it('retains exact requested/effective values and owning occurrence', () => {
    expect(decodeRequestObservations([row])).toEqual([row])
    const cached = structuredClone(row); cached.evidence.requests[0]!.provenance.state = 'cache_reused'
    expect(decodeRequestObservations([cached])).toEqual([cached])
  })
  it('keeps no snapshot distinct from a returned non-serialization fact', () => {
    const absent = {...row,evidence:{...row.evidence,requests:[{node_id:'node-1',turn:0,ordinal:0,provenance:null}]}}
    expect(decodeRequestObservations([absent])).toEqual([absent])
    for (const state of ['not_serialized','external_unobserved','interrupted_unobserved']) {
      const value = {...row,evidence:{...row.evidence,requests:[{node_id:'node-1',turn:0,ordinal:0,provenance:{state,request:null}}]}}
      expect(decodeRequestObservations([value])).toEqual([value])
    }
  })
  it('does not equate scope absence or read failure with a serialized request', () => {
    for (const evidence of [{status:'not_dispatched'},{status:'no_durable_scope'},{status:'no_matching_call'},{status:'read_failed',detail:'unavailable'}]) {
      const value = {...row,evidence}; expect(decodeRequestObservations([value])).toEqual([value])
    }
  })
  it('rejects corrupt or contradictory persisted facts', () => {
    for (const change of [{body_bytes:-1},{body_sha256:'00'},{output_token_receipt:{...receipt,effective:8192}}]) {
      const value = {...row,evidence:{...row.evidence,requests:[{node_id:'node-1',turn:0,ordinal:0,provenance:{state:'serialized',request:{...fact.request,...change}}}]}}
      expect(decodeRequestObservations([value])).toBeNull()
    }
    expect(decodeRequestObservations([{...row,evidence:{...row.evidence,requests:[row.evidence.requests[0],row.evidence.requests[0]]}}])).toBeNull()
    expect(decodeRequestObservations([{...row,evidence:{status:'future'}}])).toBeNull()
    expect(decodeRequestObservations(undefined)).toBeNull()
  })
  it('decodes the current shared OCaml/TypeScript turn-record fixture', () => {
    const fixture = JSON.parse(readFileSync(resolve(process.cwd(), 'src/api/fixtures/turn-record-writer.jsonl'),'utf8').split('\n')[0]!)
    const decoded = decodeRequestObservations(fixture.request_observations)
    expect(decoded).toEqual(fixture.request_observations)
    expect(decoded?.[0]?.evidence.status).toBe('recorded')
  })
})
