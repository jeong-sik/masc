import { describe, expect, it } from 'vitest'
import { Option, TaggedError, err, ok } from './result'
import { createAsyncResource } from './effect-resource'

class TestError extends TaggedError('TestError')<{
  readonly message: string
}>() {}

describe('createAsyncResource', () => {
  it('keeps the previous value in a typed failure state', async () => {
    const resource = createAsyncResource<TestError, number>()

    await resource.load(async () => ok(7))
    await resource.load(async () => err(new TestError({ message: 'transport unavailable' })))

    const state = resource.state.value
    expect(state._tag).toBe('Failure')
    if (state._tag !== 'Failure') return
    expect(state.error).toBeInstanceOf(TestError)
    expect(Option.getOrThrow(state.previous)).toBe(7)
  })

  it('aborts an older request and ignores its completion', async () => {
    const resource = createAsyncResource<TestError, number>()
    let firstRequestAborted = false

    const firstLoad = resource.load(
      signal =>
        new Promise((_resolve, reject) => {
          signal.addEventListener(
            'abort',
            () => {
              firstRequestAborted = true
              reject(new DOMException('Aborted', 'AbortError'))
            },
            { once: true },
          )
        }),
    )
    const secondLoad = resource.load(async () => ok(11))
    await Promise.all([firstLoad, secondLoad])

    expect(firstRequestAborted).toBe(true)
    expect(resource.state.value).toEqual({ _tag: 'Success', value: 11 })
  })

  it('cancels the active request and returns to Initial without a value', async () => {
    const resource = createAsyncResource<TestError, number>()
    let requestAborted = false

    const load = resource.load(
      signal =>
        new Promise((_resolve, reject) => {
          signal.addEventListener(
            'abort',
            () => {
              requestAborted = true
              reject(new DOMException('Aborted', 'AbortError'))
            },
            { once: true },
          )
        }),
    )
    resource.cancel()
    await load

    expect(requestAborted).toBe(true)
    expect(resource.state.value).toEqual({ _tag: 'Initial' })
  })
})
