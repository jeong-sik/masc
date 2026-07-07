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

let operator_judge_runtime_json (config : Workspace.config) =
  let runtime = Dashboard_operator_judge.runtime_status config.base_path in
  `Assoc
    [
      ("enabled", `Bool runtime.enabled);
      ("judge_online", `Bool runtime.judge_online);
      ("refreshing", `Bool runtime.refreshing);
      ("generated_at", Json_util.string_option_to_yojson runtime.generated_at);
      ("expires_at", Json_util.string_option_to_yojson runtime.expires_at);
      ("model_used", `Null);
      ("keeper_name", `String runtime.keeper_name);
      ("last_error", Json_util.string_option_to_yojson runtime.last_error);
    ]

type pending_confirm = {
  token : string;
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

type available_action = {
  action_type : string;
  tool_name : string;
  target_type : string;
  description : string;
  confirm_required : bool;
}

let make_available_action ~action_type ~tool_name ~target_type ~description =
  { action_type; tool_name; target_type; description;
    confirm_required = Operator_approval.confirm_required action_type }

let preview_of_pending_confirm (entry : pending_confirm) =
  `Assoc
    [
      ("trace_id", `String entry.trace_id);
      ("actor", `String entry.actor);
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("target_id", Json_util.string_option_to_yojson entry.target_id);
      ("payload", entry.payload);
    ]

let pending_confirm_to_yojson (entry : pending_confirm) =
  `Assoc
    [
      ("token", `String entry.token);
      ("confirm_token", `String entry.token);
      ("trace_id", `String entry.trace_id);
      ("actor", `String entry.actor);
      ("action_type", `String entry.action_type);
      ("target_type", `String entry.target_type);
      ("target_id", Json_util.string_option_to_yojson entry.target_id);
      ("payload", entry.payload);
      ("delegated_tool", `String entry.delegated_tool);
      ("created_at", `String entry.created_at);
      ("expires_at", Json_util.string_option_to_yojson entry.expires_at);
      ("preview", preview_of_pending_confirm entry);
    ]

let pending_confirm_of_yojson json =
  try
    let token = Json_util.get_string_with_default json ~key:"token" ~default:"" in
    let trace_id =
      match Json_util.get_string json "trace_id" with
      | Some value -> value
      | None -> trace_id "opc"
    in
    let actor = Json_util.get_string_with_default json ~key:"actor" ~default:"" in
    let action_type = Json_util.get_string_with_default json ~key:"action_type" ~default:"" in
    let target_type = Json_util.get_string_with_default json ~key:"target_type" ~default:"" in
    let target_id = Json_util.get_string json "target_id" in
    let payload =
      match Json_util.get_object json "payload" with
      | Some payload -> payload
      | None -> `Assoc []
    in
    let delegated_tool = Json_util.get_string_with_default json ~key:"delegated_tool" ~default:"" in
    let created_at = Json_util.get_string_with_default json ~key:"created_at" ~default:"" in
    let expires_at = Json_util.get_string json "expires_at" in
    Ok
      {
        token;
        trace_id;
        actor;
        action_type;
        target_type;
        target_id;
        payload;
        delegated_tool;
        created_at;
        expires_at;
      }
  with Failure msg -> Error msg

let decode_pending_confirm_entries entries =
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | json :: rest ->
      (match pending_confirm_of_yojson json with
       | Ok entry -> loop (index + 1) (entry :: acc) rest
       | Error msg ->
         Error
           (Printf.sprintf
              "pending_confirms[%d] decode failed: %s"
              index
              msg))
  in
  loop 0 [] entries

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
  | Error msg ->
    Log.Misc.warn "[operator_pending_confirm] %s" msg;
    []

let pending_confirms_to_yojson entries =
  `List (List.map pending_confirm_to_yojson entries)

let write_pending_confirms config (entries : pending_confirm list) =
  Workspace_utils.write_json_result config (pending_confirms_path config)
    (pending_confirms_to_yojson entries)

let pending_confirm_expired (entry : pending_confirm) =
  match entry.expires_at with
  | Some exp -> Masc_domain.now_iso () > exp
  | None -> false

let read_pending_confirms_result config =
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

let read_pending_confirms config : pending_confirm list =
  match read_pending_confirms_result config with
  | Ok entries -> entries
  | Error msg ->
    Log.Misc.warn "[operator_pending_confirm] %s" msg;
    []

let upsert_pending_confirm config entry =
  match read_pending_confirms_result config with
  | Error _ as error -> error
  | Ok entries ->
    let remaining =
      entries
      |> List.filter (fun existing -> not (String.equal existing.token entry.token))
    in
    write_pending_confirms config (entry :: remaining)

let remove_pending_confirm config token =
  match read_pending_confirms_result config with
  | Error _ as error -> error
  | Ok entries ->
    let remaining =
      entries
      |> List.filter (fun existing -> not (String.equal existing.token token))
    in
    write_pending_confirms config remaining

let remove_pending_confirms_by_target config ~target_type ~target_id =
  let all = raw_pending_confirms config in
  let remaining =
    List.filter
      (fun (entry : pending_confirm) ->
        not
          (String.equal entry.target_type target_type
          && entry.target_id = target_id))
      all
  in
  let removed = List.length all - List.length remaining in
  if removed > 0 then
    write_pending_confirms config remaining |> Result.map (fun () -> removed)
  else Ok 0

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
           String.compare b.created_at a.created_at)
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

let pending_confirms_json ?actor config =
  let scope = pending_confirm_scope ?actor config in
  `List (List.map pending_confirm_to_yojson scope.visible_entries)

let available_actions : available_action list =
  [
    make_available_action ~action_type:"broadcast" ~tool_name:"masc_broadcast"
      ~target_type:"workspace"
      ~description:"Namespace-wide operator broadcast.";
    make_available_action ~action_type:"namespace_pause" ~tool_name:"masc_pause"
      ~target_type:"workspace"
      ~description:"Pause namespace automation and spawning.";
    make_available_action ~action_type:"namespace_resume" ~tool_name:"masc_resume"
      ~target_type:"workspace"
      ~description:"Resume a paused namespace.";
    make_available_action ~action_type:"social_sweep" ~tool_name:"social_sweep"
      ~target_type:"workspace"
      ~description:"Run one immediate social sweep across keepers.";
    make_available_action ~action_type:"task_inject" ~tool_name:"masc_add_task"
      ~target_type:"workspace"
      ~description:"Inject a backlog task into the namespace.";
    make_available_action
      ~action_type:Operator_action_constants.goal_completion_decision
      ~tool_name:Operator_action_constants.goal_transition_tool
      ~target_type:Operator_action_constants.goal_target_type
      ~description:"Approve or reject a goal completion approval gate.";
    make_available_action ~action_type:"keeper_message" ~tool_name:"masc_keeper_msg"
      ~target_type:"keeper"
      ~description:"Send a direct operator message to a keeper.";
    make_available_action ~action_type:"keeper_probe" ~tool_name:"masc_keeper_status"
      ~target_type:"keeper"
      ~description:"Immediate keeper diagnostic snapshot.";
    make_available_action
      ~action_type:Operator_action_constants.keeper_recover
      ~tool_name:"masc_keeper_recover" ~target_type:"keeper"
      ~description:"Safe down/up recovery for stale/degraded keeper.";
  ]

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

let pending_confirm_envelope_json ?actor config =
  let scope = pending_confirm_scope ?actor config in
  `Assoc
    [
      ("items", `List (List.map pending_confirm_to_yojson scope.visible_entries));
      ("summary", pending_confirm_summary_json_of_scope scope);
    ]
