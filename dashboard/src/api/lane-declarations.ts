import { Option, Schema } from 'effect'
import { ApiRequestError, get, post } from './core'

const text = Schema.NonEmptyString
const documentSchema = Schema.Struct({
  file_name: text, source_path: text, source_text: Schema.String, source_revision: text,
  desired_revision: Schema.NullOr(text),
  validation: Schema.Struct({ valid: Schema.Boolean, messages: Schema.Array(Schema.String) }),
})
const receiptSchema = Schema.Struct({
  document: documentSchema,
  write: Schema.Struct({
    state: Schema.Literal('created', 'saved', 'unchanged'),
    durability: Schema.Literal('durable', 'unconfirmed'), detail: Schema.NullOr(Schema.String),
  }),
  application: Schema.Literal('pending_reconciliation'),
})
const failureSchema = Schema.Struct({
  error: Schema.String,
  code: Schema.Literal('invalid_request', 'not_found', 'revision_conflict', 'invalid_declaration', 'io_error'),
  current: Schema.NullOr(documentSchema),
})
export type LaneDeclarationDocument = Schema.Schema.Type<typeof documentSchema>
export type LaneDeclarationReceipt = Schema.Schema.Type<typeof receiptSchema>
export type LaneDeclarationWrite = { file_name: string; source_text: string } & (
  | { mode: 'create' }
  | { mode: 'save'; expected_source_revision: string }
)
type Failure = Schema.Schema.Type<typeof failureSchema>
export class LaneDeclarationError extends Error {
  constructor(readonly failure: Failure) { super(failure.error); this.name = 'LaneDeclarationError' }
}
const parseDocument = Schema.decodeUnknownSync(documentSchema)
const parseReceipt = Schema.decodeUnknownSync(receiptSchema)
const parseFailure = Schema.decodeUnknownOption(failureSchema)

function declarationError(error: unknown): unknown {
  if (error instanceof ApiRequestError) {
    const parsed = parseFailure(error.responseData)
    if (Option.isSome(parsed)) return new LaneDeclarationError(parsed.value)
  }
  return error
}

export async function fetchLaneDeclaration(sourcePath: string, signal?: AbortSignal): Promise<LaneDeclarationDocument> {
  try {
    const params = new URLSearchParams({ source_path: sourcePath })
    const document = parseDocument(await get<unknown>(`/api/v1/lane-addons/declaration?${params}`, { signal }))
    if (document.source_path !== sourcePath) throw new Error('The returned TOML file does not match the requested path.')
    return document
  } catch (error) {
    const failure = declarationError(error)
    if (failure instanceof LaneDeclarationError && failure.failure.current !== null && failure.failure.current.source_path !== sourcePath) {
      throw new Error('The conflict document does not match the requested TOML path.')
    }
    throw failure
  }
}

export async function saveLaneDeclaration(request: LaneDeclarationWrite): Promise<LaneDeclarationReceipt> {
  try {
    const receipt = parseReceipt(await post<unknown>('/api/v1/lane-addons/declaration', request))
    if (receipt.document.file_name !== request.file_name || receipt.document.source_text !== request.source_text) {
      throw new Error('The file receipt does not match the submitted TOML. Read the current file before saving again.')
    }
    return receipt
  } catch (error) {
    const failure = declarationError(error)
    if (failure instanceof LaneDeclarationError && failure.failure.current !== null && failure.failure.current.file_name !== request.file_name) {
      throw new Error('The conflict document does not match the submitted TOML file.')
    }
    throw failure
  }
}
