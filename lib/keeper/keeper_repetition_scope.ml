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

let load = Keeper_repetition_context.load
let save = Keeper_repetition_context.save
let restore = Keeper_repetition_context.restore

module Execution = struct
  type snapshot = Snapshot.t
  type first_source = Restored_source | Shared_runtime
  type t =
    { scope : Id.t
    ; first_source : first_source
    ; mutable current : (snapshot, Snapshot.error) result option
    }

  let direct_operation operation_id =
    { scope = Id.direct_operation operation_id; first_source = Restored_source; current = None }

  let autonomous_admission uuid =
    { scope = Id.autonomous_admission uuid; first_source = Shared_runtime; current = None }

  let scope execution = execution.scope

  let install = Keeper_repetition_context.install

  let prepare execution ~source ~target =
    let result =
      let* state = match execution.current with
        | Some state ->
          let* state = state in
          let* () = install ~target state in
          Ok state
        | None ->
          let* state = match execution.first_source with
            | Restored_source -> restore ~source ~target
            | Shared_runtime ->
              (* Official clients need not produce a Core checkpoint. Keep
                 their original Session frames, and reconcile each source
                 scope without replacing different observations. All checks
                 precede publication, so a conflict leaves the target intact. *)
              let* source = load source in
              let* target = load target in
              List.fold_left (fun state scope ->
                let* target = state in
                Snapshot.restore_scope ~scope ~source ~target)
                (Ok target) (Snapshot.scope_ids source)
          in
          let* state = Snapshot.admit state (Snapshot.Fresh execution.scope) in
          save target state;
          Ok state
      in
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
    | None -> Error (Snapshot.Invalid_snapshot "execution was not prepared")

  let resume execution state =
    match Snapshot.active state with
    | Some scope when Id.equal scope execution.scope ->
      (match execution.current with
       | None -> execution.current <- Some (Ok state); Ok ()
       | Some (Ok current) when Snapshot.active current = Some execution.scope -> Ok ()
       | Some (Ok _ | Error _) -> Error Snapshot.Restore_target_conflict)
    | Some _ | None -> Error (Snapshot.Invalid_snapshot "native Gate frame belongs to another execution")

  let failure execution = match execution.current with
    | Some (Error error) -> Some error
    | None | Some (Ok _) -> None
end
