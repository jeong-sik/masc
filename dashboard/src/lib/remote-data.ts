import { Option } from 'effect'

export type RemoteData<E, A> =
  | { readonly _tag: 'Initial' }
  | { readonly _tag: 'Loading'; readonly previous: Option.Option<A> }
  | { readonly _tag: 'Success'; readonly value: A }
  | {
      readonly _tag: 'Failure'
      readonly error: E
      readonly previous: Option.Option<A>
    }

export function remoteInitial<E, A>(): RemoteData<E, A> {
  return { _tag: 'Initial' }
}

export function remoteLoading<E, A>(
  previous: Option.Option<A>,
): RemoteData<E, A> {
  return { _tag: 'Loading', previous }
}

export function remoteSuccess<E, A>(value: A): RemoteData<E, A> {
  return { _tag: 'Success', value }
}

export function remoteFailure<E, A>(
  error: E,
  previous: Option.Option<A>,
): RemoteData<E, A> {
  return { _tag: 'Failure', error, previous }
}

export function remotePrevious<E, A>(
  state: RemoteData<E, A>,
): Option.Option<A> {
  switch (state._tag) {
    case 'Initial':
      return Option.none()
    case 'Loading':
    case 'Failure':
      return state.previous
    case 'Success':
      return Option.some(state.value)
  }
}
