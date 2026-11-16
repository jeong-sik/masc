import { Schema } from 'effect'

export const hwpImportResult = Schema.Struct({ content: Schema.String, notices: Schema.Array(Schema.String) })
export type HwpImportResult = typeof hwpImportResult.Type
export const hwpWorkerResponse = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('converted'), result: hwpImportResult }),
  Schema.Struct({ kind: Schema.Literal('failed'), message: Schema.String }),
)
export type HwpWorkerResponse = typeof hwpWorkerResponse.Type
