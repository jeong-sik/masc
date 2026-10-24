import { isRecord } from '../components/common/normalize'

type Receipt = {
  requested: number | null
  effective: number | null
  ceiling: number | null
  ceiling_source: 'catalog_model' | 'declared_capability_override' | 'provider_default' | null
  policy: 'omitted' | 'explicit' | 'explicit_clamped' | 'required_catalog_fallback' | 'required_capability_override_fallback'
  envelope: 'openai_chat_max_tokens' | 'openai_responses_max_output_tokens' | 'anthropic_messages_max_tokens' | 'gemini_generation_config_max_output_tokens' | 'ollama_options_num_predict'
}
type Serialized = { output_token_receipt: Receipt; body_bytes: number; body_sha256: string }
export type RequestProvenance =
  | { state: 'not_serialized' | 'external_unobserved' | 'interrupted_unobserved'; request: null }
  | { state: 'serialized' | 'cache_reused'; request: Serialized }
export type ProviderRequest = { node_id: string; turn: number; ordinal: number; provenance: RequestProvenance | null }
export type RequestObservation = {
  runtime_profile: string
  attempt: number
  evidence:
    | { status: 'not_dispatched' | 'no_durable_scope' | 'no_matching_call' }
    | { status: 'read_failed'; detail: string }
    | { status: 'recorded'; call_id: string; requests: ProviderRequest[] }
}
function exact(raw: Record<string, unknown>, keys: string[]): boolean {
  return Object.keys(raw).length === keys.length && keys.every(k => Object.hasOwn(raw, k))
}
function text(value: unknown): value is string { return typeof value === 'string' && value.trim().length > 0 }
function integer(value: unknown): value is number { return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 }
function optionalInteger(value: unknown): boolean { return value === null || integer(value) }
function receipt(raw: unknown): Receipt | null {
  if (!isRecord(raw) || !exact(raw, ['requested','effective','ceiling','ceiling_source','policy','envelope'])) return null
  if (!optionalInteger(raw.requested) || !optionalInteger(raw.effective) || !optionalInteger(raw.ceiling)) return null
  if (raw.ceiling !== null && (raw.ceiling as number) <= 0) return null
  if (![null,'catalog_model','declared_capability_override','provider_default'].includes(raw.ceiling_source as string | null)) return null
  if ((raw.ceiling === null) !== (raw.ceiling_source === null)) return null
  if (!['openai_chat_max_tokens','openai_responses_max_output_tokens','anthropic_messages_max_tokens','gemini_generation_config_max_output_tokens','ollama_options_num_predict'].includes(raw.envelope as string)) return null
  const required = raw.envelope === 'anthropic_messages_max_tokens'
  switch (raw.policy) {
    case 'omitted': if (required || raw.requested !== null || raw.effective !== null) return null; break
    case 'explicit': if (raw.requested === null || raw.effective !== raw.requested || (raw.ceiling !== null && (raw.effective as number) > (raw.ceiling as number))) return null; break
    case 'explicit_clamped': if (raw.requested === null || raw.ceiling === null || raw.effective !== raw.ceiling || (raw.requested as number) <= (raw.ceiling as number)) return null; break
    case 'required_catalog_fallback': if (!required || raw.requested !== null || raw.effective !== raw.ceiling || raw.ceiling === null || raw.ceiling_source !== 'catalog_model') return null; break
    case 'required_capability_override_fallback': if (!required || raw.requested !== null || raw.effective !== raw.ceiling || raw.ceiling === null || raw.ceiling_source !== 'declared_capability_override') return null; break
    default: return null
  }
  return raw as Receipt
}
function provenance(raw: unknown): RequestProvenance | null {
  if (!isRecord(raw) || !exact(raw, ['state','request'])) return null
  switch (raw.state) {
    case 'not_serialized': case 'external_unobserved': case 'interrupted_unobserved':
      return raw.request === null ? { state: raw.state, request: null } : null
    case 'serialized': case 'cache_reused': {
      const request = raw.request
      if (!isRecord(request) || !exact(request, ['output_token_receipt','body_bytes','body_sha256'])) return null
      const decision = receipt(request.output_token_receipt)
      if (decision === null || !integer(request.body_bytes) || request.body_bytes === 0 || typeof request.body_sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(request.body_sha256)) return null
      return { state: raw.state, request: { output_token_receipt: decision, body_bytes: request.body_bytes, body_sha256: request.body_sha256 } }
    }
    default: return null
  }
}
export function decodeRequestObservations(raw: unknown): RequestObservation[] | null {
  if (!Array.isArray(raw)) return null
  const decoded: RequestObservation[] = []
  for (const row of raw) {
    if (!isRecord(row) || !exact(row, ['runtime_profile','attempt','evidence']) || !text(row.runtime_profile) || !integer(row.attempt) || !isRecord(row.evidence)) return null
    const evidence = row.evidence
    switch (evidence.status) {
      case 'not_dispatched': case 'no_durable_scope': case 'no_matching_call':
        if (!exact(evidence, ['status'])) return null
        decoded.push({ runtime_profile: row.runtime_profile, attempt: row.attempt, evidence: { status: evidence.status } }); break
      case 'read_failed':
        if (!exact(evidence, ['status','detail']) || !text(evidence.detail)) return null
        decoded.push({ runtime_profile: row.runtime_profile, attempt: row.attempt, evidence: { status: 'read_failed', detail: evidence.detail } }); break
      case 'recorded': {
        if (!exact(evidence, ['status','call_id','requests']) || !text(evidence.call_id) || !Array.isArray(evidence.requests)) return null
        const requests: ProviderRequest[] = []
        const ids = new Set<string>()
        for (const req of evidence.requests) {
          if (!isRecord(req) || !exact(req, ['node_id','turn','ordinal','provenance']) || !text(req.node_id) || !integer(req.turn) || !integer(req.ordinal) || ids.has(req.node_id)) return null
          ids.add(req.node_id)
          const fact = req.provenance === null ? null : provenance(req.provenance)
          if (req.provenance !== null && fact === null) return null
          requests.push({node_id:req.node_id, turn:req.turn, ordinal:req.ordinal, provenance:fact})
        }
        decoded.push({ runtime_profile: row.runtime_profile, attempt: row.attempt, evidence: { status:'recorded', call_id:evidence.call_id, requests } }); break
      }
      default: return null
    }
  }
  return decoded
}
