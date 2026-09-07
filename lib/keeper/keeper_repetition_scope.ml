let ( let* ) = Result.bind

let exact_fields expected = function
  | `Assoc fields as json ->
      if List.sort String.compare (List.map fst fields) = List.sort String.compare expected
      then Ok json
      else Error "missing, duplicate, or unexpected fields"
  | _ -> Error "expected an object"

module Id = Keeper_execution_scope_id

module Scopes = Map.Make (Id)

type admission = Fresh of Id.t | Resume of Id.t
type observation =
  { tool_name : string
  ; input_fingerprint : string option
  ; output_fingerprint : string option
  }
type t = { active : Id.t option; scopes : observation list Scopes.t }
type error =
  | Invalid_snapshot of string
  | Invalid_observation of string
  | Unknown_scope of Id.t
  | Restore_target_conflict

let error_to_string = function
  | Invalid_snapshot detail -> "invalid repetition scope checkpoint: " ^ detail
  | Invalid_observation detail -> "invalid repetition observation: " ^ detail
  | Unknown_scope id -> "repetition scope was not admitted: " ^ Yojson.Safe.to_string (Id.to_json id)
  | Restore_target_conflict -> "runtime context already contains different repetition scope evidence"

let empty = { active = None; scopes = Scopes.empty }
let active state = state.active

let admit state = function
  | Fresh id ->
      let scopes =
        if Scopes.mem id state.scopes then state.scopes
        else Scopes.add id [] state.scopes
      in
      Ok { active = Some id; scopes }
  | Resume id ->
      if Scopes.mem id state.scopes then Ok { state with active = Some id }
      else Error (Unknown_scope id)

let record state ~scope observation =
  match Scopes.find_opt scope state.scopes with
  | None -> Error (Unknown_scope scope)
  | Some previous ->
      Ok { state with scopes = Scopes.add scope (observation :: previous) state.scopes }

let tool_calls state ~scope =
  match Scopes.find_opt scope state.scopes with
  | None -> Error (Unknown_scope scope)
  | Some calls ->
      Ok (List.map (fun observation ->
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

let observation_to_json observation =
  let optional = function None -> `Null | Some value -> `String value in
  `Assoc [ "tool_name", `String observation.tool_name
         ; "input_fingerprint", optional observation.input_fingerprint
         ; "output_fingerprint", optional observation.output_fingerprint ]

let observation_of_json json =
  let* json = exact_fields [ "tool_name"; "input_fingerprint"; "output_fingerprint" ] json in
  let* tool_name = Json_util.require_string json "tool_name" in
  let* () = if String.trim tool_name = "" then Error "tool_name must not be blank" else Ok () in
  let fingerprint name =
    match Yojson.Safe.Util.member name json with
    | `Null -> Ok None
    | `String value ->
        (match Digestif.SHA256.consistent_of_hex_opt value with
         | Some digest -> Ok (Some (Digestif.SHA256.to_hex digest))
         | None -> Error (name ^ " must be null or a SHA-256 digest"))
    | _ -> Error (name ^ " must be null or a SHA-256 digest")
  in
  let* input_fingerprint = fingerprint "input_fingerprint" in
  let* output_fingerprint = fingerprint "output_fingerprint" in
  Ok { tool_name; input_fingerprint; output_fingerprint }

let observation_of_call (call : Keeper_agent_result.tool_call_detail) =
  observation_to_json
    { tool_name = call.tool_name
    ; input_fingerprint = call.input_fingerprint
    ; output_fingerprint = call.output_fingerprint }
  |> observation_of_json
  |> Result.map_error (fun detail -> Invalid_observation detail)

let to_json state =
  `Assoc
    [ "schema", `String "masc.keeper_repetition_scopes.v1"
    ; "active", Option.fold ~none:`Null ~some:Id.to_json state.active
    ; "scopes", `List (Scopes.bindings state.scopes |> List.map (fun (id, calls) ->
        `Assoc [ "id", Id.to_json id
               ; "observations", `List (List.map observation_to_json calls) ])) ]

let of_json json =
  let decode () =
    let* json = exact_fields [ "schema"; "active"; "scopes" ] json in
    let* schema = Json_util.require_string json "schema" in
    let* () = if schema = "masc.keeper_repetition_scopes.v1" then Ok () else Error "unsupported schema" in
    let* rows = Json_field.list json "scopes" |> Json_field.require in
    let* scopes = List.fold_left (fun acc row ->
      let* scopes = acc in
      let* row = exact_fields [ "id"; "observations" ] row in
      let* id = Id.of_json (Yojson.Safe.Util.member "id" row) in
      if Scopes.mem id scopes then Error "duplicate repetition scope"
      else
        let* calls = Json_field.list row "observations" |> Json_field.require in
        let* reversed = List.fold_left (fun acc call ->
          let* acc = acc in
          let* call = observation_of_json call in
          Ok (call :: acc)) (Ok []) calls in
        Ok (Scopes.add id (List.rev reversed) scopes)) (Ok Scopes.empty) rows in
    let* active = match Yojson.Safe.Util.member "active" json with
      | `Null -> Ok None
      | value -> Id.of_json value |> Result.map Option.some in
    match active with
    | Some id when not (Scopes.mem id scopes) -> Error "active scope was not admitted"
    | Some _ | None -> Ok { active; scopes }
  in
  decode () |> Result.map_error (fun detail -> Invalid_snapshot detail)

let context_key = "keeper_repetition_scopes"

let load context =
  match Agent_core.Context.get_scoped context Agent_core.Context.Session context_key with
  | None -> Ok empty
  | Some json -> of_json json

let save context state =
  Agent_core.Context.set_scoped context Agent_core.Context.Session context_key (to_json state)

let restore ~source ~target =
  let* state = load source in
  (* No checkpoint freshness order can be inferred from counts or an active
     scope. Restore into an empty key, or replay the exact same projection. *)
  match Agent_core.Context.get_scoped target Agent_core.Context.Session context_key with
  | None -> save target state; Ok state
  | Some _ ->
      let* existing = load target in
      if to_json state = to_json existing then Ok existing
      else Error Restore_target_conflict

module Execution = struct
  type snapshot = t
  type t =
    { scope : Id.t
    ; mutable current : (snapshot, error) result option
    }

  let direct_operation operation_id =
    { scope = Id.direct_operation operation_id; current = None }

  let install ~target state =
    match Agent_core.Context.get_scoped target Agent_core.Context.Session context_key with
    | None -> save target state; Ok ()
    | Some _ ->
      let* existing = load target in
      if to_json existing = to_json state then Ok ()
      else Error Restore_target_conflict

  let prepare execution ~source ~target =
    let result =
      let* state = match execution.current with
        | Some state -> state
        | None ->
          let* state = load source in
          admit state (Fresh execution.scope)
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
        | None -> Error (Invalid_snapshot "repetition execution was not prepared")
      in
      let* observation = observation_of_call call in
      let* state = record state ~scope:execution.scope observation in
      save target state;
      Ok state
    in
    execution.current <- Some result

  let failure execution = match execution.current with
    | Some (Error error) -> Some error
    | None | Some (Ok _) -> None
end
