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
  type t =
    { scope : Id.t
    ; mutable current : (snapshot, Snapshot.error) result option
    }

  let direct_operation operation_id =
    { scope = Id.direct_operation operation_id; current = None }

  let install = Keeper_repetition_context.install

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
