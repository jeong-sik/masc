let ( let* ) = Result.bind
module Snapshot = Keeper_repetition_snapshot

let context_key = "keeper_repetition_scopes"

let load context =
  match Agent_core.Context.get_scoped context Agent_core.Context.Session context_key with
  | None -> Ok Snapshot.empty
  | Some json -> Snapshot.of_json json

let save context state =
  Agent_core.Context.set_scoped context Agent_core.Context.Session context_key (Snapshot.to_json state)

let install ~target state =
  match Agent_core.Context.get_scoped target Agent_core.Context.Session context_key with
  | None -> save target state; Ok ()
  | Some _ ->
    let* existing = load target in
    if Snapshot.equal existing state then Ok ()
    else Error Snapshot.Restore_target_conflict

let restore ~source ~target =
  let* state = load source in
  let* () = install ~target state in
  Ok state
