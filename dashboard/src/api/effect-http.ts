import { Context, Data, Effect, Layer, ManagedRuntime } from 'effect'

import { get } from './core'

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export class DashboardTransportError extends Data.TaggedError(
  'DashboardTransportError',
)<{
  readonly method: 'GET'
  readonly path: string
  readonly message: string
  readonly cause: unknown
}> {}

export interface DashboardHttpService {
  readonly getUnknown: (
    path: string,
  ) => Effect.Effect<unknown, DashboardTransportError>
}

export class DashboardHttp extends Context.Tag(
  'masc/dashboard/DashboardHttp',
)<DashboardHttp, DashboardHttpService>() {}

export const DashboardHttpLive = Layer.succeed(DashboardHttp, {
  getUnknown: path =>
    Effect.tryPromise({
      try: signal => get<unknown>(path, { signal }),
      catch: cause =>
        new DashboardTransportError({
          method: 'GET',
          path,
          message: errorMessage(cause),
          cause,
        }),
    }),
})

export const dashboardRuntime = ManagedRuntime.make(DashboardHttpLive)
