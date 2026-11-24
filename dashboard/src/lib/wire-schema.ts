// Zero-dependency strict wire-boundary schema decoder.
// Replaces `effect/Schema` with strict excess-property checking and structured path issues.

import { Either, Option, ok, err, type Result } from './result'

export interface SchemaIssue {
  readonly path: ReadonlyArray<PropertyKey>
  readonly message: string
}

export class WireParseError extends Error {
  readonly _tag = 'ParseError' as const
  constructor(readonly issues: ReadonlyArray<SchemaIssue>) {
    const details = issues
      .map(i => `${i.path.length > 0 ? i.path.join('.') : '<root>'}: ${i.message}`)
      .join('; ')
    super(details || 'Invalid wire payload')
    this.name = 'WireParseError'
  }
}

export interface DecodeOptions {
  readonly errors?: 'first' | 'all'
  readonly onExcessProperty?: 'ignore' | 'error' | 'preserve'
}

export interface WireSchema<A> {
  readonly _tag: 'WireSchema'
  readonly Type: A
  readonly fields?: Record<string, FieldSpec>
  readonly literals?: readonly unknown[]
  readonly _structFields?: Record<string, FieldSpec>
  readonly _decode: (input: unknown, path: PropertyKey[], opts: DecodeOptions) => InternalResult<A>
  pipe<B>(fn: (schema: WireSchema<A>) => WireSchema<B>): WireSchema<B>
  pipe<B, C>(f1: (s: WireSchema<A>) => WireSchema<B>, f2: (s: WireSchema<B>) => WireSchema<C>): WireSchema<C>
  pipe<B, C, D>(
    f1: (s: WireSchema<A>) => WireSchema<B>,
    f2: (s: WireSchema<B>) => WireSchema<C>,
    f3: (s: WireSchema<C>) => WireSchema<D>,
  ): WireSchema<D>
}

export interface LiteralWireSchema<T extends ReadonlyArray<string | number | boolean | null>> extends WireSchema<T[number]> {
  readonly literals: T
}

export interface StructWireSchema<Fields extends Record<string, FieldSpec>> extends WireSchema<DecodedStruct<Fields>> {
  readonly fields: Fields
}

interface OptionalField<A> {
  readonly _tag: 'OptionalField'
  readonly schema: WireSchema<A>
  readonly mode: 'undefined' | 'option' | 'default'
  readonly defaultFn?: () => A
}

type FieldSpec = WireSchema<unknown> | OptionalField<unknown>

type InternalResult<A> =
  | { readonly ok: true; readonly value: A }
  | { readonly ok: false; readonly issues: SchemaIssue[] }

function iOk<A>(value: A): InternalResult<A> {
  return { ok: true, value }
}

function iErr<A = never>(path: PropertyKey[], message: string): InternalResult<A> {
  return { ok: false, issues: [{ path: [...path], message }] }
}

function makeSchema<A>(
  decode: (input: unknown, path: PropertyKey[], opts: DecodeOptions) => InternalResult<A>,
  structFields?: Record<string, FieldSpec>,
  literals?: readonly unknown[],
): WireSchema<A> {
  const schema: WireSchema<A> = {
    _tag: 'WireSchema',
    Type: undefined as unknown as A,
    fields: structFields,
    literals,
    _structFields: structFields,
    _decode: decode,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    pipe(...fns: Array<(s: WireSchema<any>) => WireSchema<any>>): WireSchema<any> {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return fns.reduce<WireSchema<any>>((acc, fn) => fn(acc), schema as WireSchema<any>)
    },
  }
  return schema
}

function isPlainRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

type InferField<F> =
  F extends OptionalField<infer A> ? A :
  F extends WireSchema<infer A> ? A :
  never

type OptionalKeys<Fields extends Record<string, FieldSpec>> = {
  [K in keyof Fields]: Fields[K] extends OptionalField<unknown> ? K : never
}[keyof Fields]

type RequiredKeys<Fields extends Record<string, FieldSpec>> = Exclude<keyof Fields, OptionalKeys<Fields>>

type StructType<Fields extends Record<string, FieldSpec>> = {
  readonly [K in RequiredKeys<Fields>]: InferField<Fields[K]>
} & {
  readonly [K in OptionalKeys<Fields>]?: InferField<Fields[K]>
}

// Preserve optionality cleanly for Option-returning optionalWith fields
type ResolveFieldType<F> =
  F extends { readonly _mode: 'option'; readonly _valueType: infer A } ? Option<A> :
  F extends { readonly _mode: 'default'; readonly _valueType: infer A } ? A :
  F extends OptionalField<infer A> ? A | undefined :
  F extends WireSchema<infer A> ? A :
  never

type AlwaysPresentKeys<Fields extends Record<string, FieldSpec>> = {
  [K in keyof Fields]:
    Fields[K] extends { readonly _mode: 'option' | 'default' } ? K :
    Fields[K] extends OptionalField<unknown> ? never : K
}[keyof Fields]

type TrulyOptionalKeys<Fields extends Record<string, FieldSpec>> = Exclude<keyof Fields, AlwaysPresentKeys<Fields>>

type Simplify<T> = { [K in keyof T]: T[K] } & {}

type DecodedStruct<Fields extends Record<string, FieldSpec>> = Simplify<{
  readonly [K in AlwaysPresentKeys<Fields>]: ResolveFieldType<Fields[K]>
} & {
  readonly [K in TrulyOptionalKeys<Fields>]?: Exclude<ResolveFieldType<Fields[K]>, undefined>
}>

type FilterReturn = boolean | string | ReadonlyArray<{ readonly path: ReadonlyArray<PropertyKey>; readonly message: string }>

export namespace WireSchemaTypes {
  export type Type<S> = S extends WireSchema<infer A> ? A : never
}

const StringSchema: WireSchema<string> = makeSchema((input, path) =>
  typeof input === 'string' ? iOk(input) : iErr(path, 'Expected a string'),
)

const NonEmptyStringSchema: WireSchema<string> = makeSchema((input, path) =>
  typeof input === 'string' && input.length > 0 ? iOk(input) : iErr(path, 'Expected a non-empty string'),
)

const NumberSchema: WireSchema<number> = makeSchema((input, path) =>
  typeof input === 'number' && !Number.isNaN(input) ? iOk(input) : iErr(path, 'Expected a number'),
)

const FiniteSchema: WireSchema<number> = makeSchema((input, path) =>
  typeof input === 'number' && Number.isFinite(input) ? iOk(input) : iErr(path, 'Expected a finite number'),
)

const IntSchema: WireSchema<number> = makeSchema((input, path) =>
  typeof input === 'number' && Number.isInteger(input) ? iOk(input) : iErr(path, 'Expected an integer'),
)

const NonNegativeIntSchema: WireSchema<number> = makeSchema((input, path) =>
  typeof input === 'number' && Number.isInteger(input) && input >= 0
    ? iOk(input)
    : iErr(path, 'Expected a non-negative integer'),
)

const PositiveSchema: WireSchema<number> = makeSchema((input, path) =>
  typeof input === 'number' && Number.isFinite(input) && input > 0
    ? iOk(input)
    : iErr(path, 'Expected a positive number'),
)

const BooleanSchema: WireSchema<boolean> = makeSchema((input, path) =>
  typeof input === 'boolean' ? iOk(input) : iErr(path, 'Expected a boolean'),
)

const NullSchema: WireSchema<null> = makeSchema((input, path) =>
  input === null ? iOk(null) : iErr(path, 'Expected null'),
)

const UnknownSchema: WireSchema<unknown> = makeSchema(input => iOk(input))

const NeverSchema: WireSchema<never> = makeSchema((_input, path) => iErr(path, 'Expected never'))

export const Schema = {
  String: StringSchema,
  NonEmptyString: NonEmptyStringSchema,
  Number: NumberSchema,
  Finite: FiniteSchema,
  JsonNumber: FiniteSchema,
  Int: IntSchema,
  NonNegativeInt: NonNegativeIntSchema,
  Positive: PositiveSchema,
  Boolean: BooleanSchema,
  Null: NullSchema,
  Unknown: UnknownSchema,
  Never: NeverSchema,

  Literal<const T extends ReadonlyArray<string | number | boolean | null>>(...literals: T): LiteralWireSchema<T> {
    const allowed = new Set<unknown>(literals)
    return makeSchema((input, path) =>
      allowed.has(input)
        ? iOk(input as T[number])
        : iErr(path, `Expected one of ${literals.map(v => JSON.stringify(v)).join(', ')}, actual ${JSON.stringify(input)}`),
    undefined, literals) as LiteralWireSchema<T>
  },

  NullOr<A>(inner: WireSchema<A>): WireSchema<A | null> {
    return makeSchema((input, path, opts) =>
      input === null ? iOk(null) : inner._decode(input, path, opts),
    )
  },

  OptionFromNullOr<A>(inner: WireSchema<A>): WireSchema<Option<A>> {
    return makeSchema((input, path, opts) => {
      if (input === null) return iOk(Option.none<A>())
      const decoded = inner._decode(input, path, opts)
      return decoded.ok ? iOk(Option.some(decoded.value)) : decoded
    })
  },

  Array<A>(item: WireSchema<A>): WireSchema<readonly A[]> {
    return makeSchema((input, path, opts) => {
      if (!Array.isArray(input)) return iErr(path, 'Expected an array')
      const out: A[] = []
      const issues: SchemaIssue[] = []
      for (let i = 0; i < input.length; i++) {
        const r = item._decode(input[i], [...path, i], opts)
        if (r.ok) {
          out.push(r.value)
        } else {
          issues.push(...r.issues)
          if (opts.errors !== 'all') break
        }
      }
      return issues.length > 0 ? { ok: false, issues } : iOk(out)
    })
  },

  NonEmptyArray<A>(item: WireSchema<A>): WireSchema<readonly [A, ...A[]]> {
    const base = Schema.Array(item)
    return makeSchema((input, path, opts) => {
      const r = base._decode(input, path, opts)
      if (!r.ok) return r
      if (r.value.length === 0) return iErr(path, 'Expected a non-empty array')
      return iOk(r.value as unknown as readonly [A, ...A[]])
    })
  },

  Record<K extends string, V>(spec: { readonly key: WireSchema<K>; readonly value: WireSchema<V> }): WireSchema<Readonly<Record<K, V>>> {
    return makeSchema((input, path, opts) => {
      if (!isPlainRecord(input)) return iErr(path, 'Expected an object')
      const out: Record<string, V> = {}
      const issues: SchemaIssue[] = []
      for (const [k, v] of Object.entries(input)) {
        const kr = spec.key._decode(k, [...path, k], opts)
        if (!kr.ok) {
          issues.push(...kr.issues)
          if (opts.errors !== 'all') break
          continue
        }
        const vr = spec.value._decode(v, [...path, k], opts)
        if (vr.ok) {
          out[kr.value] = vr.value
        } else {
          issues.push(...vr.issues)
          if (opts.errors !== 'all') break
        }
      }
      return issues.length > 0 ? { ok: false, issues } : iOk(out as Readonly<Record<K, V>>)
    })
  },

  optional<A>(schema: WireSchema<A>): OptionalField<A> & { readonly _mode: 'undefined'; readonly _valueType: A } {
    return { _tag: 'OptionalField', schema, mode: 'undefined', _mode: 'undefined', _valueType: undefined as unknown as A }
  },

  optionalWith<A, O extends { readonly as?: 'Option'; readonly exact?: boolean; readonly default?: () => A }>(
    schema: WireSchema<A>,
    options: O,
  ): O extends { readonly as: 'Option' }
    ? OptionalField<Option<A>> & { readonly _mode: 'option'; readonly _valueType: A }
    : O extends { readonly default: () => A }
      ? OptionalField<A> & { readonly _mode: 'default'; readonly _valueType: A }
      : OptionalField<A> & { readonly _mode: 'undefined'; readonly _valueType: A } {
    if (options.as === 'Option') {
      return {
        _tag: 'OptionalField',
        schema: schema as WireSchema<unknown>,
        mode: 'option',
        _mode: 'option',
        _valueType: undefined as unknown as A,
      } as never
    }
    if (options.default) {
      return {
        _tag: 'OptionalField',
        schema,
        mode: 'default',
        defaultFn: options.default,
        _mode: 'default',
        _valueType: undefined as unknown as A,
      } as never
    }
    return {
      _tag: 'OptionalField',
      schema,
      mode: 'undefined',
      _mode: 'undefined',
      _valueType: undefined as unknown as A,
    } as never
  },

  Struct<Fields extends Record<string, FieldSpec>>(fields: Fields): StructWireSchema<Fields> {
    const fieldKeys = Object.keys(fields)
    const allowed = new Set(fieldKeys)
    return makeSchema((input, path, opts) => {
      if (!isPlainRecord(input)) return iErr(path, 'Expected an object')
      const out: Record<string, unknown> = {}
      const issues: SchemaIssue[] = []

      if (opts.onExcessProperty === 'error') {
        for (const key of Object.keys(input)) {
          if (!allowed.has(key)) {
            issues.push({ path: [...path, key], message: 'is unexpected' })
            if (opts.errors !== 'all') return { ok: false, issues }
          }
        }
      }

      for (const key of fieldKeys) {
        const spec = fields[key]!
        const present = Object.prototype.hasOwnProperty.call(input, key) && input[key] !== undefined
        if (spec._tag === 'OptionalField') {
          if (!present) {
            if (spec.mode === 'option') out[key] = Option.none()
            else if (spec.mode === 'default' && spec.defaultFn) out[key] = spec.defaultFn()
            continue
          }
          const r = spec.schema._decode(input[key], [...path, key], opts)
          if (r.ok) {
            out[key] = spec.mode === 'option' ? Option.some(r.value) : r.value
          } else {
            issues.push(...r.issues)
            if (opts.errors !== 'all') break
          }
        } else {
          if (!present) {
            issues.push({ path: [...path, key], message: 'is missing' })
            if (opts.errors !== 'all') break
            continue
          }
          const r = spec._decode(input[key], [...path, key], opts)
          if (r.ok) {
            out[key] = r.value
          } else {
            issues.push(...r.issues)
            if (opts.errors !== 'all') break
          }
        }
      }

      return issues.length > 0 ? { ok: false, issues } : iOk(out as DecodedStruct<Fields>)
    }, fields) as StructWireSchema<Fields>
  },

  extend<A, B>(left: WireSchema<A>, right: WireSchema<B>): WireSchema<Simplify<A & B>> {
    if (left._structFields && right._structFields) {
      return Schema.Struct({ ...left._structFields, ...right._structFields }) as unknown as WireSchema<Simplify<A & B>>
    }
    return makeSchema((input, path, opts) => {
      const l = left._decode(input, path, opts)
      if (!l.ok) return l
      const r = right._decode(input, path, opts)
      if (!r.ok) return r
      return iOk({ ...(l.value as object), ...(r.value as object) } as Simplify<A & B>)
    })
  },

  Union<Members extends ReadonlyArray<WireSchema<unknown>>>(
    ...members: Members
  ): WireSchema<Members[number] extends WireSchema<infer A> ? A : never> {
    return makeSchema((input, path, opts) => {
      let bestIssues: SchemaIssue[] | null = null
      for (const member of members) {
        const r = member._decode(input, path, opts)
        if (r.ok) return r as InternalResult<Members[number] extends WireSchema<infer A> ? A : never>
        if (!bestIssues || r.issues.length < bestIssues.length) {
          bestIssues = r.issues
        }
      }
      return { ok: false, issues: bestIssues ?? [{ path: [...path], message: 'No union member matched' }] }
    })
  },

  declare<A>(predicate: (input: unknown) => input is A): WireSchema<A> {
    return makeSchema((input, path) =>
      predicate(input) ? iOk(input) : iErr(path, 'Failed predicate'),
    )
  },

  filter<A>(
    predicate: (value: NoInfer<A>) => FilterReturn,
    annotation?: { readonly message?: () => string; readonly description?: string },
  ): (schema: WireSchema<A>) => WireSchema<A> {
    return (schema: WireSchema<A>): WireSchema<A> =>
      makeSchema((input, path, opts) => {
        const r = schema._decode(input, path, opts)
        if (!r.ok) return r
        const check = predicate(r.value)
        if (check === true) return r
        if (check === false) {
          return iErr(path, annotation?.message?.() ?? annotation?.description ?? 'Failed filter check')
        }
        if (typeof check === 'string') {
          return iErr(path, check)
        }
        if (Array.isArray(check)) {
          if (check.length === 0) return r
          return {
            ok: false,
            issues: check.map(issue => ({
              path: [...path, ...issue.path],
              message: issue.message,
            })),
          }
        }
        return r
      }, schema._structFields)
  },

  nonEmptyString(): (schema: WireSchema<string>) => WireSchema<string> {
    return Schema.filter<string>(v => v.length > 0, { description: 'Expected a non-empty string' })
  },

  pattern(re: RegExp): (schema: WireSchema<string>) => WireSchema<string> {
    return Schema.filter<string>(v => re.test(v), { description: `Expected a string matching ${re}` })
  },

  finite(): (schema: WireSchema<number>) => WireSchema<number> {
    return Schema.filter<number>(Number.isFinite, { description: 'Expected a finite number' })
  },

  positive(): (schema: WireSchema<number>) => WireSchema<number> {
    return Schema.filter<number>(v => Number.isFinite(v) && v > 0, { description: 'Expected a positive number' })
  },

  nonNegative(): (schema: WireSchema<number>) => WireSchema<number> {
    return Schema.filter<number>(v => Number.isFinite(v) && v >= 0, { description: 'Expected a non-negative number' })
  },

  greaterThan(n: number): (schema: WireSchema<number>) => WireSchema<number> {
    return Schema.filter<number>(v => Number.isFinite(v) && v > n, { description: `Expected number > ${n}` })
  },

  lessThanOrEqualTo(n: number): (schema: WireSchema<number>) => WireSchema<number> {
    return Schema.filter<number>(v => Number.isFinite(v) && v <= n, { description: `Expected number <= ${n}` })
  },

  between(min: number, max: number): (schema: WireSchema<number>) => WireSchema<number> {
    return Schema.filter<number>(v => Number.isFinite(v) && v >= min && v <= max, {
      description: `Expected number between ${min} and ${max}`,
    })
  },

  decodeUnknownSync<A>(schema: WireSchema<A>, opts: DecodeOptions = {}): (input: unknown) => A {
    return input => {
      const r = schema._decode(input, [], opts)
      if (r.ok) return r.value
      throw new WireParseError(r.issues)
    }
  },

  decodeUnknownEither<A>(schema: WireSchema<A>, opts: DecodeOptions = {}): (input: unknown) => Either<A, WireParseError> {
    return input => {
      const r = schema._decode(input, [], opts)
      return r.ok ? Either.right(r.value) : Either.left(new WireParseError(r.issues))
    }
  },

  decodeUnknownResult<A>(schema: WireSchema<A>, opts: DecodeOptions = {}): (input: unknown) => Result<A, WireParseError> {
    return input => {
      const r = schema._decode(input, [], opts)
      return r.ok ? ok(r.value) : err(new WireParseError(r.issues))
    }
  },

  decodeUnknownOption<A>(schema: WireSchema<A>, opts: DecodeOptions = {}): (input: unknown) => Option<A> {
    return input => {
      const r = schema._decode(input, [], opts)
      return r.ok ? Option.some(r.value) : Option.none()
    }
  },

  decodeUnknownPromise<A>(schema: WireSchema<A>, opts: DecodeOptions = {}): (input: unknown) => Promise<A> {
    return async input => {
      const r = schema._decode(input, [], opts)
      if (r.ok) return r.value
      throw new WireParseError(r.issues)
    }
  },
}

export namespace Schema {
  export type Schema<A, _I = A, _R = never> = WireSchema<A>
  export namespace Schema {
    export type Type<S> = S extends WireSchema<infer A> ? A : never
  }
}

export const ParseResult = {
  ArrayFormatter: {
    formatErrorSync(error: WireParseError): ReadonlyArray<SchemaIssue> {
      return error.issues
    },
  },
} as const

export namespace ParseResult {
  export type ArrayFormatterIssue = SchemaIssue
  export type ParseError = WireParseError
}

export type ArrayFormatterIssue = SchemaIssue
export type ParseError = WireParseError
export type { StructType }
