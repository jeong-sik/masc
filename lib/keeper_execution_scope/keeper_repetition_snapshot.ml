let ( let* ) = Result.bind

let exact_fields expected = function
  | `Assoc fields as json ->
      if List.sort String.compare (List.map fst fields) = List.sort String.compare expected
      then Ok json
      else Error "missing, duplicate, or unexpected fields"
  | _ -> Error "expected an object"

let require_string json name =
  match Yojson.Safe.Util.member name json with
  | `String value -> Ok value
  | _ -> Error (name ^ " must be a string")

let require_list json name =
  match Yojson.Safe.Util.member name json with
  | `List values -> Ok values
  | _ -> Error (name ^ " must be a list")

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
let scope_ids state = List.map fst (Scopes.bindings state.scopes)

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

let observations state ~scope =
  match Scopes.find_opt scope state.scopes with
  | None -> Error (Unknown_scope scope)
  | Some calls -> Ok calls

let observation_to_json observation =
  let optional = function None -> `Null | Some value -> `String value in
  `Assoc [ "tool_name", `String observation.tool_name
         ; "input_fingerprint", optional observation.input_fingerprint
         ; "output_fingerprint", optional observation.output_fingerprint ]

let observation_of_json json =
  let* json = exact_fields [ "tool_name"; "input_fingerprint"; "output_fingerprint" ] json in
  let* tool_name = require_string json "tool_name" in
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

let observation ~tool_name ~input_fingerprint ~output_fingerprint =
  observation_to_json { tool_name; input_fingerprint; output_fingerprint }
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
    let* schema = require_string json "schema" in
    let* () = if schema = "masc.keeper_repetition_scopes.v1" then Ok () else Error "unsupported schema" in
    let* rows = require_list json "scopes" in
    let* scopes = List.fold_left (fun acc row ->
      let* scopes = acc in
      let* row = exact_fields [ "id"; "observations" ] row in
      let* id = Id.of_json (Yojson.Safe.Util.member "id" row) in
      if Scopes.mem id scopes then Error "duplicate repetition scope"
      else
        let* calls = require_list row "observations" in
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

let equal a b =
  Option.equal Id.equal a.active b.active
  && Scopes.equal (List.equal (fun a b ->
       String.equal a.tool_name b.tool_name
       && Option.equal String.equal a.input_fingerprint b.input_fingerprint
       && Option.equal String.equal a.output_fingerprint b.output_fingerprint))
       a.scopes b.scopes
