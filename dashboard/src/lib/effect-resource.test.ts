import { Data, Effect, Option } from 'effect'
import { describe, expect, it } from 'vitest'

import {
  createEffectResource,
  type EffectRunner,
} from './effect-resource'

class TestError extends Data.TaggedError('TestError')<{
  readonly message: string
}> {}

const runner: EffectRunner<never> = {
  runPromiseExit: (effect, options) =>
    Effect.runPromiseExit(effect, options),
}

describe('createEffectResource', () => {
  it('keeps the previous value in a typed failure state', async () => {
    const resource = createEffectResource<never, TestError, number>(runner)

    await resource.load(Effect.succeed(7))
    await resource.load(
      Effect.fail(new TestError({ message: 'transport unavailable' })),
    )

    const state = resource.state.value
    expect(state._tag).toBe('Failure')
    if (state._tag !== 'Failure') return
    expect(state.error).toBeInstanceOf(TestError)
    expect(Option.getOrThrow(state.previous)).toBe(7)
  })

  it('interrupts an older request and ignores its completion', async () => {
    const resource = createEffectResource<never, TestError, number>(runner)
    let firstRequestAborted = false

    const first = Effect.tryPromise({
      try: signal =>
        new Promise<number>((_resolve, reject) => {
          signal.addEventListener(
            'abort',
            () => {
              firstRequestAborted = true
              reject(new DOMException('Aborted', 'AbortError'))
            },
            { once: true },
          )
        }),
      catch: () => new TestError({ message: 'first request failed' }),
    })

    const firstLoad = resource.load(first)
    const secondLoad = resource.load(Effect.succeed(11))
    await Promise.all([firstLoad, secondLoad])

    expect(firstRequestAborted).toBe(true)
    expect(resource.state.value).toEqual({ _tag: 'Success', value: 11 })
  })

  it('cancels the active fiber and returns to Initial without a value', async () => {
    const resource = createEffectResource<never, TestError, number>(runner)
    let requestAborted = false
    const pending = Effect.tryPromise({
      try: signal =>
        new Promise<number>((_resolve, reject) => {
          signal.addEventListener(
            'abort',
            () => {
              requestAborted = true
              reject(new DOMException('Aborted', 'AbortError'))
            },
            { once: true },
          )
        }),
      catch: () => new TestError({ message: 'request failed' }),
    })

    const load = resource.load(pending)
    resource.cancel()
    await load

    expect(requestAborted).toBe(true)
    expect(resource.state.value).toEqual({ _tag: 'Initial' })
  })
})
