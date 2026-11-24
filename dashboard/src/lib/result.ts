// Lean Result<A, E> and Option<A> primitives replacing `effect` runtime usage.

export type Result<A, E> =
  | { readonly ok: true; readonly value: A }
  | { readonly ok: false; readonly error: E }

export function ok<A, E = never>(value: A): Result<A, E> {
  return { ok: true, value }
}

export function err<E, A = never>(error: E): Result<A, E> {
  return { ok: false, error }
}

export function isOk<A, E>(result: Result<A, E>): result is { readonly ok: true; readonly value: A } {
  return result.ok
}

export function isErr<A, E>(result: Result<A, E>): result is { readonly ok: false; readonly error: E } {
  return !result.ok
}

export function mapResult<A, B, E>(result: Result<A, E>, fn: (value: A) => B): Result<B, E> {
  return result.ok ? ok(fn(result.value)) : result
}

export function mapError<A, E, F>(result: Result<A, E>, fn: (error: E) => F): Result<A, F> {
  return result.ok ? result : err(fn(result.error))
}

export function unwrapResult<A, E>(result: Result<A, E>): A {
  if (result.ok) return result.value
  throw result.error
}

export function unwrapResultError<A, E>(result: Result<A, E>): E {
  if (!result.ok) return result.error
  throw new Error('Expected Result error, got Ok')
}

export function flatMapResult<A, B, E, F>(
  result: Result<A, E>,
  fn: (value: A) => Result<B, F>,
): Result<B, E | F> {
  return result.ok ? fn(result.value) : result
}

export type Either<A, E> =
  | { readonly _tag: 'Right'; readonly right: A }
  | { readonly _tag: 'Left'; readonly left: E }

export const Either = {
  right<A, E = never>(right: A): Either<A, E> {
    return { _tag: 'Right', right }
  },
  left<E, A = never>(left: E): Either<A, E> {
    return { _tag: 'Left', left }
  },
  isRight<A, E>(e: Either<A, E>): e is { readonly _tag: 'Right'; readonly right: A } {
    return e._tag === 'Right'
  },
  isLeft<A, E>(e: Either<A, E>): e is { readonly _tag: 'Left'; readonly left: E } {
    return e._tag === 'Left'
  },
} as const

export type Option<A> =
  | { readonly _tag: 'Some'; readonly value: A }
  | { readonly _tag: 'None' }

const NONE: Option<never> = Object.freeze({ _tag: 'None' })

export const Option = {
  some<A>(value: A): Option<A> {
    return { _tag: 'Some', value }
  },
  none<A = never>(): Option<A> {
    return NONE
  },
  fromNullable<A>(value: A | null | undefined): Option<A> {
    return value === null || value === undefined ? NONE : { _tag: 'Some', value }
  },
  isSome<A>(option: Option<A>): option is { readonly _tag: 'Some'; readonly value: A } {
    return option._tag === 'Some'
  },
  isNone<A>(option: Option<A>): option is { readonly _tag: 'None' } {
    return option._tag === 'None'
  },
  match<A, B, C>(
    option: Option<A>,
    handlers: { readonly onNone: () => B; readonly onSome: (value: A) => C },
  ): B | C {
    return option._tag === 'Some' ? handlers.onSome(option.value) : handlers.onNone()
  },
  map<A, B>(option: Option<A>, fn: (value: A) => B): Option<B> {
    return option._tag === 'Some' ? { _tag: 'Some', value: fn(option.value) } : NONE
  },
  orElse<A, B>(option: Option<A>, fallback: () => Option<B>): Option<A | B> {
    return option._tag === 'Some' ? option : fallback()
  },
  getOrElse<A, B>(option: Option<A>, fallback: () => B): A | B {
    return option._tag === 'Some' ? option.value : fallback()
  },
  getOrNull<A>(option: Option<A>): A | null {
    return option._tag === 'Some' ? option.value : null
  },
  getOrUndefined<A>(option: Option<A>): A | undefined {
    return option._tag === 'Some' ? option.value : undefined
  },
  getOrThrow<A>(option: Option<A>): A {
    if (option._tag === 'Some') return option.value
    throw new Error('Option.getOrThrow called on None')
  },
} as const

export namespace Option {
  export type Option<A> =
    | { readonly _tag: 'Some'; readonly value: A }
    | { readonly _tag: 'None' }
}

export function TaggedError<Tag extends string>(tag: Tag) {
  return function <Props extends Record<string, unknown>>() {
    return class TaggedErrorImpl extends Error {
      readonly _tag: Tag = tag
      constructor(props: Props) {
        const msg = typeof props.message === 'string' ? props.message : tag
        super(msg)
        this.name = tag
        Object.assign(this, props)
      }
    } as unknown as new (props: Props) => Error & { readonly _tag: Tag } & Readonly<Props>
  }
}
