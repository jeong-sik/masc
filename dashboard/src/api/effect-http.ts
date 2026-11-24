import { get } from './core'
import { ok, err, TaggedError, type Result } from '../lib/result'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export class DashboardTransportError extends TaggedError('DashboardTransportError')<{
  readonly method: 'GET'
  readonly path: string
  readonly message: string
  readonly cause: unknown
}>() {}

export interface DashboardHttpService {
  readonly getUnknown: (
    path: string,
    signal?: AbortSignal,
  ) => Promise<Result<unknown, DashboardTransportError>>
}

export const defaultDashboardHttp: DashboardHttpService = {
  async getUnknown(path: string, signal?: AbortSignal): Promise<Result<unknown, DashboardTransportError>> {
    try {
      const value = await get<unknown>(path, { signal })
      return ok(value)
    } catch (cause) {
      return err(new DashboardTransportError({
        method: 'GET',
        path,
        message: errorMessage(cause),
        cause,
      }))
    }
  },
}
