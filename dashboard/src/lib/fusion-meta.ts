// Fusion sink compatibility helpers shared by Board/Fusion evidence renderers
// and keeper chat cards. The legacy constructor path is only for board posts
// emitted before fusion_sink serialized reason_detail/reason_code.

function decodeOcamlStringLiteral(value: string): string {
  return value
    .replace(/\\\\/g, '\u0000')
    .replace(/\\"/g, '"')
    .replace(/\\n/g, '\n')
    .replace(/\\t/g, '\t')
    .replace(/\u0000/g, '\\')
}

function normalizeProviderAttribution(model: string, reason: string): string {
  const unknownPrefix = "Provider 'unknown'"
  if (model === '?' || !reason.startsWith(unknownPrefix)) return reason
  return `Provider '${model}'${reason.slice(unknownPrefix.length)}`
}

export function normalizeFusionPanelReason(model: string, reason: string | undefined): string | undefined {
  if (!reason) return undefined
  const trimmed = reason.trim()
  const providerMatch = trimmed.match(/^\(?\s*Fusion_types\.Provider_error\s+"([\s\S]*)"\s*\)?$/)
  if (providerMatch) {
    return normalizeProviderAttribution(model, decodeOcamlStringLiteral(providerMatch[1] ?? '').trim())
  }
  if (/^\(?\s*Fusion_types\.Timeout\s*\)?$/.test(trimmed)) return 'timeout'
  if (/^\(?\s*Fusion_types\.Empty_response\s*\)?$/.test(trimmed)) return 'empty response'
  return normalizeProviderAttribution(model, trimmed)
}
