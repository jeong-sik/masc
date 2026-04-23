// Dashboard error notification types

// Mirrors tool_args.ml error_code variant — same 10 categories.
export type ErrorCode =
  | 'validation_error'
  | 'not_found'
  | 'auth_required'
  | 'permission_denied'
  | 'conflict'
  | 'rate_limited'
  | 'timeout'
  | 'not_implemented'
  | 'internal_error'
  | 'precondition_failed'
  | 'unknown'

export type ErrorSeverity = 'critical' | 'warning' | 'info'

export interface DashboardError {
  id: string
  fingerprint: string
  agentName: string
  taskId: string | null
  message: string
  errorCode: ErrorCode
  severity: ErrorSeverity
  timestamp: number
  acknowledged: boolean
  count: number
  lastSeen: number
}

// Classify error message to ErrorCode.
// Matches known patterns from OAS Error.to_string and tool_args.ml responses.
const CLASSIFIERS: ReadonlyArray<[RegExp, ErrorCode]> = [
  [/not found|does not exist|no such/i, 'not_found'],
  [/timeout|timed out|deadline exceeded/i, 'timeout'],
  [/permission|forbidden/i, 'permission_denied'],
  [/unauthorized|authentication|token.*invalid|credential|auth_required/i, 'auth_required'],
  [/already claimed|conflict|already exists/i, 'conflict'],
  [/rate.?limit|too many requests/i, 'rate_limited'],
  [/validation|invalid|missing.*param|required/i, 'validation_error'],
  [/not implemented|unsupported/i, 'not_implemented'],
  [/precondition|room not joined|not in room/i, 'precondition_failed'],
  [/internal|unexpected|unhandled|exception/i, 'internal_error'],
]

export function classifyErrorCode(message: string): ErrorCode {
  for (const [pattern, code] of CLASSIFIERS) {
    if (pattern.test(message)) return code
  }
  return 'unknown'
}

// Error severity derived from code — drives toast duration and badge color.
const SEVERITY_MAP: Record<ErrorCode, ErrorSeverity> = {
  auth_required: 'critical',
  permission_denied: 'critical',
  internal_error: 'critical',
  timeout: 'warning',
  rate_limited: 'warning',
  conflict: 'warning',
  validation_error: 'warning',
  not_found: 'info',
  not_implemented: 'info',
  precondition_failed: 'info',
  unknown: 'warning',
}

export function severityForCode(code: ErrorCode): ErrorSeverity {
  return SEVERITY_MAP[code]
}
