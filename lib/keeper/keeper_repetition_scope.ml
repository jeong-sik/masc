let ( let* ) = Result.bind
module Snapshot = Keeper_repetition_snapshot
module Id = Keeper_execution_scope_id

let observation_of_call (call : Keeper_agent_result.tool_call_detail) =
  Snapshot.observation ~tool_name:call.tool_name
    ~input_fingerprint:call.input_fingerprint
    ~output_fingerprint:call.output_fingerprint

let tool_calls state ~scope =
  let* calls = Snapshot.observations state ~scope in
  Ok (List.map (fun (observation : Snapshot.observation) ->
    { Keeper_agent_result.tool_name = observation.tool_name
    ; provider = "repetition_checkpoint"
    ; execution_outcome = Tool_result.Unknown
    ; typed_outcome = None
    ; latency_ms = 0.
    ; task_id = None
    ; route_evidence = None
    ; input_fingerprint = observation.input_fingerprint
    ; output_fingerprint = observation.output_fingerprint
    }) calls)

let context_key = "keeper_repetition_scopes"

let load context =
  match Agent_core.Context.get_scoped context Agent_core.Context.Session context_key with
  | None -> Ok Snapshot.empty
  | Some json -> Snapshot.of_json json

let save context state =
  Agent_core.Context.set_scoped context Agent_core.Context.Session context_key (Snapshot.to_json state)

let restore ~source ~target =
  let* state = load source in
  (* No checkpoint freshness order can be inferred from counts or an active
     scope. Restore into an empty key, or replay the exact same projection. *)
  match Agent_core.Context.get_scoped target Agent_core.Context.Session context_key with
  | None -> save target state; Ok state
  | Some _ ->
      let* existing = load target in
      if Snapshot.equal state existing then Ok existing
      else Error Snapshot.Restore_target_conflict

module Execution = struct
  type snapshot = Snapshot.t
  type t =
    { scope : Id.t
    ; mutable current : (snapshot, Snapshot.error) result option
    }

  let direct_operation operation_id =
    { scope = Id.direct_operation operation_id; current = None }

  let install ~target state =
    match Agent_core.Context.get_scoped target Agent_core.Context.Session context_key with
    | None -> save target state; Ok ()
    | Some _ ->
      let* existing = load target in
      if Snapshot.equal existing state then Ok ()
      else Error Snapshot.Restore_target_conflict

  let prepare execution ~source ~target =
    let result =
      let* state = match execution.current with
        | Some state -> state
        | None ->
          let* state = load source in
          Snapshot.admit state (Snapshot.Fresh execution.scope)
      in
      let* () = install ~target state in
      Ok state
    in
    execution.current <- Some result;
    let* state = result in
    tool_calls state ~scope:execution.scope

  let observe execution ~target call =
    let result =
      let* state = match execution.current with
        | Some state -> state
        | None -> Error (Snapshot.Invalid_snapshot "repetition execution was not prepared")
      in
      let* observation = observation_of_call call in
      let* state = Snapshot.record state ~scope:execution.scope observation in
      save target state;
      Ok state
    in
    execution.current <- Some result

  let snapshot execution = match execution.current with
    | Some state -> state
    | None -> Error (Snapshot.Invalid_snapshot "direct execution was not prepared")

  let resume execution state =
    match Snapshot.active state with
    | Some scope when Id.equal scope execution.scope ->
      (match execution.current with
       | None -> execution.current <- Some (Ok state); Ok ()
       | Some (Ok current) when Snapshot.active current = Some execution.scope -> Ok ()
       | Some _ -> Error Snapshot.Restore_target_conflict)
    | Some _ | None -> Error (Snapshot.Invalid_snapshot "native Gate frame belongs to another operation")

  let failure execution = match execution.current with
    | Some (Error error) -> Some error
    | None | Some (Ok _) -> None
end
