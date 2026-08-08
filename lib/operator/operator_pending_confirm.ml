type 'a context = 'a Tool_operator.context


let operator_dir config =
  Filename.concat (Workspace.masc_dir config) "operator"

let pending_confirms_path config =
  Filename.concat (operator_dir config) "pending_confirms.json"

let trace_id prefix =
  let entropy =
    Printf.sprintf "%s|%d|%.6f|%d"
      prefix (Unix.getpid ()) (Unix.gettimeofday ()) (Random.bits ())
  in
  let digest = Digestif.SHA256.(digest_string entropy |> to_hex) in
  prefix ^ "_" ^ String.sub digest 0 16

let normalized_actor ~context_actor = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed <> "" then trimmed
      else
        let trimmed = String.trim context_actor in
        if trimmed = "" || String.equal trimmed "unknown" then "unknown" else trimmed
  | None ->
      let trimmed = String.trim context_actor in
      if trimmed = "" || String.equal trimmed "unknown" then "unknown" else trimmed

type pending_confirm = Workspace_hooks.operator_pending_confirm_request = {
  confirm_token : string;
  trace_id : string;
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
  delegated_tool : string;
  created_at : string;
  expires_at : string option;
}

type pending_confirm_scope = {
  actor_filter : string option;
  all_entries : pending_confirm list;
  visible_entries : pending_confirm list;
  hidden_entries : pending_confirm list;
}

exception Store_error of string

let () =
  Printexc.register_printer (function
    | Store_error _ -> Some "Operator_pending_confirm.Store_error"
    | _ -> None)

let raise_store_error reason = raise (Store_error reason)

type available_action = {
  action_type : string;
  tool_name : string;
  target_type : string;
  description : string;
  confirm_required : bool;
}

type target =
  { target_type : Operator_action_constants.target_type
  ; target_id : string option
  }

let target_gate_callback
    : (Workspace.config -> target -> (unit, string) result) option Atomic.t
  =
  Atomic.make None
;;

let register_target_gate gate = Atomic.set target_gate_callback (Some gate)

let target_of_entry (entry : pending_confirm) =
  match Operator_action_constants.target_type_of_string entry.target_type with
  | Some target_type -> Ok { target_type; target_id = entry.target_id }
  | None -> Error (Printf.sprintf "invalid pending-confirm target type: %S" entry.target_type)
;;

let make_available_action ~action_type ~tool_name ~target_type ~description =
  { action_type; tool_name; target_type; description;
    confirm_required = Operator_action_catalog.requires_confirmation action_type }

let available_actions : available_action list =
  [
    make_available_action ~action_type:"broadcast" ~tool_name:"masc_broadcast"
      ~target_type:Operator_action_constants.workspace_target_type
      ~description:"Namespace-wide operator broadcast.";
    make_available_action ~action_type:"namespace_pause" ~tool_name:"masc_pause"
      ~target_type:Operator_action_constants.workspace_target_type
      ~description:"Pause namespace automation and spawning.";
    make_available_action ~action_type:"namespace_resume" ~tool_name:"masc_resume"
      ~target_type:Operator_action_constants.workspace_target_type
      ~description:"Resume a paused namespace.";
    make_available_action ~action_type:"task_inject" ~tool_name:"masc_add_task"
      ~target_type:Operator_action_constants.workspace_target_type
      ~description:"Inject a backlog task into the namespace.";
    make_available_action ~action_type:"keeper_message" ~tool_name:"masc_keeper_delegate"
      ~target_type:Operator_action_constants.keeper_target_type
      ~description:"Send a direct operator message to a keeper.";
    make_available_action ~action_type:"keeper_probe" ~tool_name:"masc_keeper_status"
      ~target_type:Operator_action_constants.keeper_target_type
      ~description:"Immediate keeper diagnostic snapshot.";
    make_available_action
      ~action_type:Operator_action_constants.keeper_recover
      ~tool_name:"masc_keeper_recover"
      ~target_type:Operator_action_constants.keeper_target_type
      ~description:"Safe down/up recovery for stale/degraded keeper.";
  ]

let validate_pending_confirm_identity
      ~action_type
      ~target_type
      ~target_id
      ~delegated_tool
  =
  let action =
    match Operator_action_catalog.of_string action_type with
    | None -> None
    | Some _ ->
      List.find_opt
        (fun (action : available_action) ->
           String.equal action.action_type action_type)
        available_actions
  in
  match action with
  | None ->
    Error (Printf.sprintf "unsupported pending-confirm action_type: %S" action_type)
  | Some action when not (String.equal action.tool_name delegated_tool) ->
    Error
      (Printf.sprintf
         "pending-confirm delegated_tool mismatch for %s"
         action_type)
  | Some action when not (String.equal action.target_type target_type) ->
    Error
      (Printf.sprintf
         "pending-confirm target_type mismatch for %s"
         action_type)
  | Some action ->
    (match Operator_action_constants.target_type_of_string action.target_type, target_id with
     | Some Operator_action_constants.Workspace, None -> Ok ()
     | Some Operator_action_constants.Workspace, Some _ ->
       Error "workspace pending-confirm must not carry target_id"
     | Some Operator_action_constants.Keeper, Some keeper_name
       when String.trim keeper_name <> "" -> Ok ()
     | Some Operator_action_constants.Keeper, _ ->
       Error "keeper pending-confirm requires a non-empty target_id"
     | Some Operator_action_constants.Goal, Some goal_id
       when String.trim goal_id <> "" -> Ok ()
     | Some Operator_action_constants.Goal, _ ->
       Error "goal pending-confirm requires a non-empty target_id"
     | None, _ -> Error "pending-confirm action has an invalid target contract")

let pending_confirm_common_fields (entry : pending_confirm) =
  [
    ("trace_id", `String entry.trace_id);
    ("actor", `String entry.actor);
    ("action_type", `String entry.action_type);
    ("target_type", `String entry.target_type);
    ("target_id", Json_util.string_option_to_yojson entry.target_id);
    ("payload", entry.payload);
    ("delegated_tool", `String entry.delegated_tool);
    ("created_at", `String entry.created_at);
    ("expires_at", Json_util.string_option_to_yojson entry.expires_at);
  ]

let pending_confirm_to_yojson (entry : pending_confirm) =
  `Assoc
    (("confirm_token", `String entry.confirm_token)
     :: pending_confirm_common_fields entry)

let pending_confirm_store_to_yojson (entry : pending_confirm) =
  `Assoc
    (("confirm_token", `String entry.confirm_token)
     :: pending_confirm_common_fields entry)

let parse_timestamp ~surface ~field value =
  match Masc_domain.parse_iso8601_opt value with
  | Some timestamp when Float.is_finite timestamp -> Ok timestamp
  | _ -> Error (Printf.sprintf "%s.%s must be an RFC3339 timestamp" surface field)

let pending_confirm_of_yojson = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "pending_confirm" in
    let* () =
      Json_util.reject_unknown_fields
        ~surface
        ~allowed:
          [ "confirm_token"
          ; "trace_id"
          ; "actor"
          ; "action_type"
          ; "target_type"
          ; "target_id"
          ; "payload"
          ; "delegated_tool"
          ; "created_at"
          ; "expires_at"
          ]
        fields
    in
    let required_string field =
      Json_util.require_field_string ~surface field fields
    in
    let required_nullable_string field =
      match List.assoc_opt field fields with
      | Some `Null -> Ok None
      | Some (`String value) -> Ok (Some value)
      | Some _ ->
        Error (Printf.sprintf "%s.%s must be a string or null" surface field)
      | None -> Error (Printf.sprintf "%s.%s is required" surface field)
    in
    let* confirm_token = required_string "confirm_token" in
    let* trace_id = required_string "trace_id" in
    let* actor = required_string "actor" in
    let* action_type = required_string "action_type" in
    let* target_type = required_string "target_type" in
    let* target_id = required_nullable_string "target_id" in
    let* payload =
      match List.assoc_opt "payload" fields with
      | Some (`Assoc _ as payload) -> Ok payload
      | Some _ -> Error "pending_confirm.payload must be an object"
      | None -> Error "pending_confirm.payload is required"
    in
    let* delegated_tool = required_string "delegated_tool" in
    let* created_at = required_string "created_at" in
    let* expires_at = required_nullable_string "expires_at" in
    let* created_at_timestamp =
      parse_timestamp ~surface ~field:"created_at" created_at
    in
    let* () =
      match expires_at with
      | None -> Ok ()
      | Some value ->
        let* expires_at_timestamp =
          parse_timestamp ~surface ~field:"expires_at" value
        in
        if Float.compare expires_at_timestamp created_at_timestamp > 0
        then Ok ()
        else Error "pending_confirm.expires_at must be later than created_at"
    in
    let* () =
      validate_pending_confirm_identity
        ~action_type
        ~target_type
        ~target_id
        ~delegated_tool
    in
    Ok
      { confirm_token
      ; trace_id
      ; actor
      ; action_type
      ; target_type
      ; target_id
      ; payload
      ; delegated_tool
      ; created_at
      ; expires_at
      }
  | _ -> Error "pending_confirm must be a JSON object"

let decode_pending_confirm_entries entries =
  let module Confirm_token_set = Set.Make (String) in
  let rec loop index seen acc = function
    | [] -> Ok (List.rev acc)
    | json :: rest ->
      (match pending_confirm_of_yojson json with
       | Ok entry when Confirm_token_set.mem entry.confirm_token seen ->
         Error
           (Printf.sprintf
              "pending_confirms[%d] duplicates confirm_token %S"
              index
              entry.confirm_token)
       | Ok entry ->
         loop
           (index + 1)
           (Confirm_token_set.add entry.confirm_token seen)
           (entry :: acc)
           rest
       | Error msg ->
         Error
           (Printf.sprintf
              "pending_confirms[%d] decode failed: %s"
              index
              msg))
  in
  loop 0 Confirm_token_set.empty [] entries

let raw_pending_confirms_result config : (pending_confirm list, string) result =
  let path = pending_confirms_path config in
  if not (Workspace_utils.path_exists config path)
  then Ok []
  else
    match Workspace_utils.read_json_result config path with
    | Error msg -> Error (Printf.sprintf "pending confirms read failed: %s" msg)
    | Ok (`List entries) -> decode_pending_confirm_entries entries
    | Ok _ -> Error "pending confirms decode failed: expected JSON list"

let raw_pending_confirms config : pending_confirm list =
  match raw_pending_confirms_result config with
  | Ok entries -> entries
  | Error msg -> raise_store_error msg

let pending_confirms_to_yojson entries =
  `List (List.map pending_confirm_store_to_yojson entries)

let write_pending_confirms config (entries : pending_confirm list) =
  match
    decode_pending_confirm_entries
      (List.map pending_confirm_store_to_yojson entries)
  with
  | Error _ as error -> error
  | Ok validated_entries ->
    Workspace_utils.write_json_result config (pending_confirms_path config)
      (pending_confirms_to_yojson validated_entries)

let with_store_lock config f =
  File_lock_eio.with_mutex (pending_confirms_path config) f
;;

let pending_confirm_expired (entry : pending_confirm) =
  match entry.expires_at with
  | Some value ->
    (match parse_timestamp ~surface:"pending_confirm" ~field:"expires_at" value with
     | Ok expires_at_timestamp ->
       Float.compare (Time_compat.now ()) expires_at_timestamp >= 0
     | Error reason -> raise_store_error reason)
  | None -> false

let read_pending_confirms_result_unlocked config =
  match raw_pending_confirms_result config with
  | Error _ as error -> error
  | Ok entries ->
  let active = List.filter (fun entry -> not (pending_confirm_expired entry)) entries in
  if List.length active <> List.length entries then
    match write_pending_confirms config active with
    | Ok () -> Ok active
    | Error msg ->
      Error
        (Printf.sprintf
           "failed to persist expired pending-confirm cleanup: %s"
           msg)
  else Ok active

let read_pending_confirms_result config =
  with_store_lock config (fun () -> read_pending_confirms_result_unlocked config)
;;

let read_pending_confirms config : pending_confirm list =
  match read_pending_confirms_result config with
  | Ok entries -> entries
  | Error msg -> raise_store_error msg

let upsert_pending_confirm config entry =
  with_store_lock config (fun () ->
    let ( let* ) = Result.bind in
    let* target = target_of_entry entry in
    let* target_gate =
      match Atomic.get target_gate_callback with
      | Some target_gate -> Ok target_gate
      | None -> Error "pending-confirm target gate is not registered"
    in
    let* () = target_gate config target in
    let* entries = read_pending_confirms_result_unlocked config in
    let remaining =
      entries
      |> List.filter (fun existing ->
             not (String.equal existing.confirm_token entry.confirm_token))
    in
    write_pending_confirms config (entry :: remaining))

let remove_pending_confirm config confirm_token =
  with_store_lock config (fun () ->
    match read_pending_confirms_result_unlocked config with
    | Error _ as error -> error
    | Ok entries ->
      let remaining =
        entries
        |> List.filter (fun existing ->
               not (String.equal existing.confirm_token confirm_token))
      in
      write_pending_confirms config remaining)

let remove_pending_confirms_by_typed_target config target =
  with_store_lock config (fun () ->
    match raw_pending_confirms_result config with
    | Error _ as error -> error
    | Ok all ->
      let target_type =
        Operator_action_constants.target_type_to_string target.target_type
      in
      let remaining =
        List.filter
          (fun (entry : pending_confirm) ->
             not
               (String.equal entry.target_type target_type
                && entry.target_id = target.target_id))
          all
      in
      let removed = List.length all - List.length remaining in
      if removed > 0
      then write_pending_confirms config remaining |> Result.map (fun () -> removed)
      else Ok 0)

let remove_pending_confirms_by_target config ~target_type ~target_id =
  match Operator_action_constants.target_type_of_string target_type with
  | None -> Error (Printf.sprintf "invalid pending-confirm target type: %S" target_type)
  | Some target_type ->
    remove_pending_confirms_by_typed_target config { target_type; target_id }

let normalize_pending_confirm_actor_filter = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let pending_confirm_scope_of_entries ?actor entries =
  let actor_filter =
    normalize_pending_confirm_actor_filter actor
  in
  let all_entries =
    entries
    |> List.sort (fun (a : pending_confirm) (b : pending_confirm) ->
           let timestamp entry =
             match
               parse_timestamp
                 ~surface:"pending_confirm"
                 ~field:"created_at"
                 entry.created_at
             with
             | Ok value -> value
             | Error reason -> raise_store_error reason
           in
           Float.compare (timestamp b) (timestamp a))
  in
  let visible_entries =
    match actor_filter with
    | None -> all_entries
    | Some value ->
        List.filter (fun (entry : pending_confirm) -> String.equal value entry.actor) all_entries
  in
  let hidden_entries =
    match actor_filter with
    | None -> []
    | Some value ->
        List.filter (fun (entry : pending_confirm) -> not (String.equal value entry.actor)) all_entries
  in
  { actor_filter; all_entries; visible_entries; hidden_entries }

let pending_confirm_scope ?actor config =
  pending_confirm_scope_of_entries ?actor (read_pending_confirms config)

let available_action_to_yojson (entry : available_action) =
  `Assoc
    [
      ("action_type", `String entry.action_type);
      ("tool_name", `String entry.tool_name);
      ("target_type", `String entry.target_type);
      ("description", `String entry.description);
      ("confirm_required", `Bool entry.confirm_required);
    ]

let available_actions_json =
  `List (List.map available_action_to_yojson available_actions)

let pending_confirm_summary_json_of_scope scope =
  let hidden_actors =
    scope.hidden_entries
    |> List.map (fun (entry : pending_confirm) -> entry.actor)
    |> List.sort_uniq String.compare
    |> List.map (fun value -> `String value)
  in
  let confirm_required_actions =
    available_actions
    |> List.filter (fun (entry : available_action) -> entry.confirm_required)
    |> List.map available_action_to_yojson
  in
  `Assoc
    [
      ("actor_filter", Json_util.string_option_to_yojson scope.actor_filter);
      ("filter_active", `Bool (Option.is_some scope.actor_filter));
      ("visible_count", `Int (List.length scope.visible_entries));
      ("total_count", `Int (List.length scope.all_entries));
      ("hidden_count", `Int (List.length scope.hidden_entries));
      ("hidden_actors", `List hidden_actors);
      ("confirm_required_actions", `List confirm_required_actions);
    ]

let pending_confirm_summary_json ?actor config =
  pending_confirm_summary_json_of_scope (pending_confirm_scope ?actor config)
