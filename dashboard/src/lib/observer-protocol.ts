export const OBSERVER_INSTANCE_HEADER = 'x-masc-sse-instance-id'
export const OBSERVER_IDLE_TIMEOUT_HEADER = 'x-masc-sse-idle-timeout-ms'

export class ObserverAccessError extends Error {
  constructor(readonly status: number) {
    super(`observer access refused (${status})`)
  }
}

export class ObserverScopeError extends Error {
  constructor() { super('observer generation does not match the waiting inventory') }
}

// The server accepts HTTP token characters for observer instance identities.
const HTTP_TOKEN = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/

export function isObserverInstance(value: string | null): value is string {
  return value !== null && HTTP_TOKEN.test(value)
}
