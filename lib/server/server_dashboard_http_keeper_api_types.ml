(** Server_dashboard_http_keeper_api_types — pure routing types + helpers
    extracted from Server_dashboard_http_keeper_api (3136 LoC godfile).

    See server_dashboard_http_keeper_api_types.mli for rationale. *)

let keeper_api_prefix = "/api/v1/keepers/"
let keeper_suffix_config = "/config"
let keeper_suffix_secrets = "/secrets"
let keeper_suffix_boot = "/boot"
let keeper_suffix_shutdown = "/shutdown"
let keeper_suffix_reset = "/reset"
let keeper_suffix_clear = "/clear"
let keeper_suffix_checkpoints = "/checkpoints"
let keeper_suffix_runtime_trace = "/runtime-trace"
let keeper_suffix_directive = "/directive"
let keeper_suffix_catchup_judge = "/catchup-judge"
let keeper_suffix_create = "/create"

let cache_key_string_segment value =
  Printf.sprintf "s%d:%s" (String.length value) value
;;

let cache_key_string_opt_segment = function
  | Some value -> "some:" ^ cache_key_string_segment value
  | None -> "none"
;;

let cache_key_int_opt_segment = function
  | Some value -> "some:i:" ^ string_of_int value
  | None -> "none"
;;

let keeper_config_cache_key (config : Workspace.config) name =
  Printf.sprintf
    "keeper:config:%s:%s"
    (cache_key_string_segment (Workspace.masc_root_dir config))
    (cache_key_string_segment name)
;;

let keeper_composite_cache_key (config : Workspace.config) name =
  Printf.sprintf
    "keeper:composite:%s:%s"
    (cache_key_string_segment (Workspace.masc_root_dir config))
    (cache_key_string_segment name)
;;

let keeper_runtime_trace_cache_key (config : Workspace.config) name ?trace_id
      ?turn_id ~limit ()
  =
  Printf.sprintf
    "keeper:runtime-trace:%s:%s:%s:%s:%d"
    (cache_key_string_segment (Workspace.masc_root_dir config))
    (cache_key_string_segment name)
    (cache_key_string_opt_segment trace_id)
    (cache_key_int_opt_segment turn_id)
    limit
;;

type keeper_post_route_kind =
  | Keeper_post_config
  | Keeper_post_secrets
  | Keeper_post_boot
  | Keeper_post_shutdown
  | Keeper_post_reset
  | Keeper_post_clear
  | Keeper_post_checkpoints
  | Keeper_post_directive
  | Keeper_post_catchup_judge
  | Keeper_post_create
  | Keeper_post_unknown

let classify_keeper_post_route req_path =
  if not (String.starts_with ~prefix:keeper_api_prefix req_path) then
    Keeper_post_unknown
  else
    let plen = String.length keeper_api_prefix in
    let tlen = String.length req_path in
    let ends_with suffix =
      tlen > plen + String.length suffix
      && String.ends_with ~suffix req_path
    in
    if ends_with keeper_suffix_config then Keeper_post_config
    else if ends_with keeper_suffix_secrets then Keeper_post_secrets
    else if ends_with keeper_suffix_boot then Keeper_post_boot
    else if ends_with keeper_suffix_shutdown then Keeper_post_shutdown
    else if ends_with keeper_suffix_reset then Keeper_post_reset
    else if ends_with keeper_suffix_clear then Keeper_post_clear
    else if ends_with keeper_suffix_checkpoints then Keeper_post_checkpoints
    else if ends_with keeper_suffix_directive then Keeper_post_directive
    else if ends_with keeper_suffix_catchup_judge then Keeper_post_catchup_judge
    else if ends_with keeper_suffix_create then Keeper_post_create
    else Keeper_post_unknown

let keeper_path_ends_with req_path suffix =
  let plen = String.length keeper_api_prefix in
  let tlen = String.length req_path in
  let slen = String.length suffix in
  tlen > plen + slen
  && String.starts_with ~prefix:keeper_api_prefix req_path
  && String.ends_with ~suffix req_path

let extract_keeper_name_for_suffix req_path suffix =
  let plen = String.length keeper_api_prefix in
  let slen = String.length suffix in
  let raw =
    String.trim
      (String.sub req_path plen (String.length req_path - plen - slen))
  in
  let valid =
    String.length raw > 0
    && String.length raw <= 128
    && String.to_seq raw
       |> Seq.for_all (fun c ->
            (c >= 'a' && c <= 'z')
            || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9')
            || c = '_' || c = '-')
  in
  if valid then raw else ""

let is_keeper_checkpoints_get_path req_path =
  keeper_path_ends_with req_path keeper_suffix_checkpoints

let is_keeper_runtime_trace_get_path req_path =
  keeper_path_ends_with req_path keeper_suffix_runtime_trace

let trim_to_opt = String_util.trim_to_option

let truncate_text ~max_chars text =
  let len = String.length text in
  if len <= max_chars then text
  else if max_chars <= 1 then String.sub text 0 (max 0 max_chars)
  else
    String_util.utf8_safe ~max_bytes:max_chars ~suffix:"…" text
    |> String_util.to_string

let latest_preview_of_messages (messages : Agent_sdk.Types.message list) =
  messages
  |> List.rev
  |> List.find_map (fun (message : Agent_sdk.Types.message) ->
       if message.role = Agent_sdk.Types.System then None
       else
         Agent_sdk.Types.text_of_message message
         |> trim_to_opt
         |> Option.map (truncate_text ~max_chars:180))

let is_valid_keeper_name name =
  String.length name > 0
  && String.length name <= 128
  && String.to_seq name
     |> Seq.for_all (fun c ->
          (c >= 'a' && c <= 'z')
          || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9')
          || c = '_' || c = '-')

let extract_keeper_name_for_post req_path suffix =
  let plen = String.length keeper_api_prefix in
  let slen = String.length suffix in
  let raw =
    String.trim
      (String.sub req_path plen (String.length req_path - plen - slen))
  in
  if is_valid_keeper_name raw then raw else ""

let manifest_row_matches ?turn_id keeper_name trace_id
    (row : Keeper_runtime_manifest.t) =
  String.equal row.keeper_name keeper_name
  && String.equal row.trace_id trace_id
  &&
  match turn_id with
  | None -> true
  | Some wanted -> row.keeper_turn_id = Some wanted

let unique_present_paths paths =
  paths
  |> List.filter_map (fun value ->
       match value with
       | Some path -> String_util.trim_to_option path
       | _ -> None)
  |> Json_util.dedupe_keep_order

let provider_attempt_row_json (row : Keeper_runtime_manifest.t) =
  let decision_string key = Json_util.get_string row.decision key in
  `Assoc
    [
      ("ts", `String row.ts);
      ("event", `String (Keeper_runtime_manifest.event_kind_to_string row.event));
      ("runtime_id", Json_util.string_opt_to_json row.runtime_id);
      ("model_source", Json_util.string_opt_to_json (decision_string "model_source"));
      ( "resolved_model_source",
        Json_util.string_opt_to_json (decision_string "resolved_model_source") );
      ("capability_source", Json_util.string_opt_to_json (decision_string "capability_source"));
      ("fallback_authority", Json_util.string_opt_to_json (decision_string "fallback_authority"));
      ( "provider_source_runtime",
        Json_util.string_opt_to_json (decision_string "provider_source_runtime") );
      ("status", `String row.status);
      ("error", Json_util.string_opt_to_json (decision_string "error"));
      ( "exception_kind",
        Json_util.string_opt_to_json (decision_string "exception_kind") );
    ]

let string_contains_substring = String_util.contains_substring

let runtime_trace_keeps_provider_attempt_provenance_key = function
  | "model_source"
  | "resolved_model_source"
  | "capability_source"
  | "fallback_authority"
  | "provider_source_runtime"
  | "terminal_model_source"
  | "terminal_resolved_model_source"
  | "terminal_capability_source"
  | "terminal_fallback_authority"
  | "terminal_provider_source_runtime"
  ->
    true
  | _ -> false

let runtime_trace_redacts_provider_model_key key =
  let key = String.lowercase_ascii key in
  (not (runtime_trace_keeps_provider_attempt_provenance_key key))
  &&
  (string_contains_substring key "provider"
   || string_contains_substring key "model"
   || String.equal key "configured_labels")

let rec runtime_trace_public_json = function
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.filter_map (fun (key, value) ->
               if runtime_trace_redacts_provider_model_key key then None
               else Some (key, runtime_trace_public_json value)))
  | `List values -> `List (List.map runtime_trace_public_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
      value

let tool_call_output_text_opt json =
  match Json_util.assoc_member_opt "output" json with
  | Some (`String value) -> Some value
  | Some (`Assoc _ as output) -> (
    match Json_util.assoc_member_opt "_blob" output with
    | Some blob -> Json_util.get_string blob "preview"
    | None -> None)
  | None | Some _ -> None

let parse_tool_output_json_opt json =
  match tool_call_output_text_opt json with
  | None -> None
  | Some output -> (
    match Safe_ops.parse_json_safe ~context:"runtime_lens.tool_output" output with
    | Ok parsed -> Some parsed
    | Error _ -> None)

let tool_call_runtime_contract json =
  match Json_util.assoc_member_opt "runtime_contract" json with
  | Some contract -> contract
  | None -> `Assoc []

let tool_call_matches_trace ?turn_id ~keeper_name ~trace_id json =
  let contract = tool_call_runtime_contract json in
  let keeper_matches =
    match Json_util.get_string json "keeper" with
    | Some keeper -> String.equal keeper keeper_name
    | None -> true
  in
  let trace_matches =
    match
      ( Json_util.get_string json "trace_id",
        Json_util.get_string contract "trace_id" )
    with
    | Some value, _ | _, Some value -> String.equal value trace_id
    | None, None -> false
  in
  let turn_matches =
    match turn_id with
    | None -> true
    | Some wanted ->
      Json_util.assoc_int_opt "keeper_turn_id" json = Some wanted
      || Json_util.assoc_int_opt "keeper_turn_id" contract = Some wanted
  in
  keeper_matches && trace_matches && turn_matches

let first_string_opt values =
  List.find_map (fun value -> value) values

let first_int_opt values =
  List.find_map (fun value -> value) values

let string_has_prefix = Server_dashboard_http_json_utils.string_has_prefix

let claim_status_of_output output =
  let result =
    match Json_util.get_string output "result" with
    | Some value -> String.trim value
    | None -> ""
  in
  match Json_util.assoc_member_opt "claimed_task" output with
  | Some _ -> "claimed"
  | None when string_has_prefix ~prefix:"No eligible tasks" result -> "no_eligible"
  | None when string_has_prefix ~prefix:"No unclaimed tasks" result -> "no_unclaimed"
  | None when string_has_prefix ~prefix:"Error:" result -> "error"
  | None when result = "" -> "unknown"
  | None -> "observed"

let claim_scope_summary_absent =
  `Assoc
    [ ("present", `Bool false)
    ; ("source", `String "keeper_task_claim_tool_call")
    ; ("status", `String "not_observed")
    ; ("result", `Null)
    ; ("mode", `Null)
    ; ("scoped", `Null)
    ; ("active_goal_ids", `List [])
    ; ("effective_goal_ids", `List [])
    ; ("fallback_reason", `Null)
    ; ("matched_goal_id", `Null)
    ; ("excluded_count", `Null)
    ; ("claimed_task_id", `Null)
    ; ("claimed_goal_id", `Null)
    ; ("trace_id", `Null)
    ; ("keeper_turn_id", `Null)
    ]

let internal_history_json_to_trajectory_line (json : Yojson.Safe.t)
    : Trajectory.trajectory_line option =
  let source = Safe_ops.json_string ~default:"" "source" json in
  (* History rows persist message text as typed [content_blocks], not a flat
     [content] string (Keeper_context_core_message_json: "Structured
     content_blocks is the only supported message-content shape"). Reading a
     flat [content] field decoded to "" for every persisted internal_assistant
     row, so the whole keeper reasoning history was skipped and invisible in the
     dashboard trace. Use the SSOT extractor (shared with history routing /
     memory recall) so content_blocks rows decode to their text. *)
  let content = Keeper_context_core.text_of_history_jsonl_json json in
  if source <> "internal_assistant" || String.trim content = "" then None
  else
    let ts =
      match Safe_ops.json_float_opt "ts_unix" json with
      | Some value when value > 0.0 -> value
      | _ ->
          match Safe_ops.json_float_opt "timestamp" json with
          | Some value when value > 0.0 -> value
          | _ -> 0.0
    in
    if ts <= 0.0 then None
    else
      let ts_iso =
        match Safe_ops.json_string_opt "ts_iso" json with
        | Some value when Option.is_some (String_util.trim_to_option value) -> value
        | _ ->
            match Safe_ops.json_string_opt "ts" json with
            | Some value when Option.is_some (String_util.trim_to_option value) -> value
            | _ -> Masc_domain.iso8601_of_unix_seconds ts
      in
      Some
        (Trajectory.Thinking
           {
             ts;
             ts_iso;
             turn = Safe_ops.json_int ~default:0 "turn" json;
             content;
             content_length = String.length content;
             redacted = Safe_ops.json_bool ~default:false "redacted" json;
           })

let runtime_manifest_public_json row =
  Keeper_runtime_manifest.public_to_json row

let take_last = List_util.take_last
