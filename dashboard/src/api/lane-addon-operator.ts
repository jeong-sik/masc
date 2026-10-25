import { Schema } from 'effect'
import { postControlPlane } from './core'

const text = Schema.NonEmptyString
const argumentsSchema = Schema.Record({ key: Schema.String, value: Schema.String })
const actionSchema = Schema.Struct({
  id: text, label: text, arguments: argumentsSchema,
  opens_window: Schema.optional(Schema.Boolean),
  fields: Schema.Array(Schema.Struct({ name: text, label: text, secret: Schema.Boolean })),
})
const viewSchema = Schema.Struct({
  title: text, message: text, actions: Schema.Array(actionSchema),
  open_url: Schema.optional(text),
  callback: Schema.optional(Schema.Struct({
    action: text, field: text, arguments: argumentsSchema, state: text,
  })),
  callback_receipt: Schema.optional(Schema.Struct({
    kind: Schema.Literal('captured', 'declined'), connection_id: text,
  })),
})
export type AddonOperatorView = Schema.Schema.Type<typeof viewSchema>
export type AddonOperatorAction = Schema.Schema.Type<typeof actionSchema>
export type AddonOperatorOwner = { instance_id: string; expected_incarnation: string }

// Private responses are never retained in the dashboard store, console or
// generic package observations. No deadline or automatic mutation retry.
export async function readAddonOperator(owner: AddonOperatorOwner): Promise<AddonOperatorView | null> {
  try {
    const description = Schema.decodeUnknownSync(Schema.Struct({
      schema: Schema.NullOr(Schema.Record({ key: Schema.String, value: Schema.Unknown })),
    }))(await postControlPlane<unknown>('/api/v1/lane-addons/operator', { ...owner, mode: 'describe' }))
    return description.schema === null ? null : invokeAddonOperator(owner, 'view', {})
  } catch {
    throw new Error('Private controls unavailable. Inspect the original connection before another attempt.')
  }
}

export async function invokeAddonOperator(owner: AddonOperatorOwner, action: string,
  arguments_: Record<string, string>): Promise<AddonOperatorView> {
  try {
    const view = Schema.decodeUnknownSync(viewSchema)(await postControlPlane<unknown>(
      '/api/v1/lane-addons/operator', { ...owner, mode: 'invoke', arguments: { action, arguments: arguments_ } },
    ))
    if (view.open_url !== undefined) {
      const url = new URL(view.open_url)
      const approval = url.protocol === 'onepassword:' && url.host === 'grant-brokered-access'
        && url.pathname === '' && url.hash === ''
      if ((!approval && url.protocol !== 'https:') || url.username !== '' || url.password !== '') throw new Error('unsafe link')
    }
    return view
  } catch {
    throw new Error('Private operation outcome unavailable. Inspect the original connection before another attempt.')
  }
}
