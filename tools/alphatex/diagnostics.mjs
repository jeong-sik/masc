export function errorDetail(error) {
  // The official importer wraps AlphaTexErrorWithDiagnostics as its cause.
  // Its toString() includes diagnostic codes, source ranges and messages.
  const cause = error?.cause
  return typeof error?.iterateDiagnostics === 'function'
    ? String(error)
    : typeof cause?.iterateDiagnostics === 'function'
    ? String(cause)
    : String(error?.message ?? error)
}
