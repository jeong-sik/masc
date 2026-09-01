(** Server_dashboard_http_keeper_api_types — pure routing types + helpers
    extracted from Server_dashboard_http_keeper_api (3136 LoC godfile).

    See server_dashboard_http_keeper_api_types.mli for rationale. *)

let keeper_api_prefix = "/api/v1/keepers/"
let keeper_suffix_config = "/config"
let keeper_suffix_secrets = "/secrets"
let keeper_suffix_github_identity = "/github-identity"
let keeper_suffix_github_login = "/github-login"
let keeper_suffix_oauth_login = "/oauth-login"
let keeper_suffix_identity_refresh = "/identity-refresh"
let keeper_suffix_identity_switch = "/identity-switch"
let keeper_suffix_boot = "/boot"
let keeper_suffix_up = "/up"
let keeper_suffix_shutdown = "/shutdown"
let keeper_suffix_reset = "/reset"
let keeper_suffix_clear = "/clear"
let keeper_suffix_checkpoints = "/checkpoints"
let keeper_suffix_runtime_trace = "/runtime-trace"
let keeper_suffix_directive = "/directive"
let keeper_suffix_paused_work = "/paused-work"
let keeper_suffix_raw_traces = "/raw-traces"
let keeper_suffix_raw_trace = "/raw-trace"
let keeper_suffix_provider_input = "/provider-input"
let keeper_suffix_memory_journal = "/memory-journal"
let keeper_suffix_memory_facts = "/memory-facts"
let keeper_suffix_turn_records = "/turn-records"
let keeper_suffix_file_changes = "/file-changes"
let keeper_suffix_fusion = "/fusion"
let keeper_suffix_operator_note = "/operator-note"
let keeper_suffix_trajectory = "/trajectory"

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

type keeper_board_attention_quarantine_route =
  { keeper_name : string
  ; partition_id : string
  }

type keeper_post_route_kind =
  | Keeper_post_config
  | Keeper_post_secrets
  | Keeper_post_github_login
  | Keeper_post_oauth_login
  | Keeper_post_identity_refresh
  | Keeper_post_identity_switch
  | Keeper_post_boot
  | Keeper_post_up
  | Keeper_post_shutdown
  | Keeper_post_reset
  | Keeper_post_clear
  | Keeper_post_checkpoints
  | Keeper_post_directive
  | Keeper_post_paused_work
  | Keeper_post_fusion
  | Keeper_post_operator_note
  | Keeper_post_board_attention_quarantine_recovery of
      keeper_board_attention_quarantine_route
  | Keeper_post_unknown

let keeper_board_attention_quarantine_route req_path =
  if not (String.starts_with ~prefix:keeper_api_prefix req_path)
  then None
  else
    let rest =
      String.sub
        req_path
        (String.length keeper_api_prefix)
        (String.length req_path - String.length keeper_api_prefix)
    in
    match String.split_on_char '/' rest with
    | [ keeper_name
      ; "board-attention"
      ; "quarantines"
      ; partition_id
      ; "recovery"
      ]
      when not (String.equal keeper_name "")
           && not (String.equal partition_id "") ->
      Some { keeper_name; partition_id }
    | _ -> None
;;

let classify_keeper_post_route req_path =
  match keeper_board_attention_quarantine_route req_path with
  | Some route ->
    Keeper_post_board_attention_quarantine_recovery route
  | None
    when not (String.starts_with ~prefix:keeper_api_prefix req_path) ->
    Keeper_post_unknown
  | None ->
    let plen = String.length keeper_api_prefix in
    let tlen = String.length req_path in
    let ends_with suffix =
      tlen > plen + String.length suffix
      && String.ends_with ~suffix req_path
    in
    if ends_with keeper_suffix_config then Keeper_post_config
    else if ends_with keeper_suffix_secrets then Keeper_post_secrets
    else if ends_with keeper_suffix_github_login then Keeper_post_github_login
    else if ends_with keeper_suffix_oauth_login then Keeper_post_oauth_login
    else if ends_with keeper_suffix_identity_refresh
    then Keeper_post_identity_refresh
    else if ends_with keeper_suffix_identity_switch
    then Keeper_post_identity_switch
    else if ends_with keeper_suffix_boot then Keeper_post_boot
    else if ends_with keeper_suffix_up then Keeper_post_up
    else if ends_with keeper_suffix_shutdown then Keeper_post_shutdown
    else if ends_with keeper_suffix_reset then Keeper_post_reset
    else if ends_with keeper_suffix_clear then Keeper_post_clear
    else if ends_with keeper_suffix_checkpoints then Keeper_post_checkpoints
    else if ends_with keeper_suffix_directive then Keeper_post_directive
    else if ends_with keeper_suffix_operator_note then Keeper_post_operator_note
    else if ends_with keeper_suffix_paused_work then Keeper_post_paused_work
    else if ends_with keeper_suffix_fusion then Keeper_post_fusion
    else Keeper_post_unknown

let keeper_path_ends_with req_path suffix =
  let plen = String.length keeper_api_prefix in
  let tlen = String.length req_path in
  let slen = String.length suffix in
  tlen > plen + slen
  && String.starts_with ~prefix:keeper_api_prefix req_path
  && String.ends_with ~suffix req_path

let is_valid_keeper_name = Keeper_config.validate_name

let extract_keeper_name_for_suffix req_path suffix =
  let plen = String.length keeper_api_prefix in
  let slen = String.length suffix in
  let raw =
    String.trim
      (String.sub req_path plen (String.length req_path - plen - slen))
  in
  if is_valid_keeper_name raw then raw else ""

let is_keeper_checkpoints_get_path req_path =
  keeper_path_ends_with req_path keeper_suffix_checkpoints

let is_keeper_paused_work_get_path req_path =
  keeper_path_ends_with req_path keeper_suffix_paused_work

(* [include_thinking] is not in the path, so the caller reads it and passes it
   here: this table is where a route's permission is decided, and deciding it
   somewhere else is how the two doors ended up different.

   `/raw-trace` requires CanAdmin because it returns hidden reasoning.
   `/trajectory?include_thinking=true` returns the same reasoning and required
   nothing, so the admin gate on the first door was reachable around. Same
   data, same gate. *)
let keeper_get_permission ?(include_thinking = false) req_path =
  if keeper_path_ends_with req_path keeper_suffix_trajectory && include_thinking
  then Some Masc_domain.CanAdmin
  else if keeper_path_ends_with req_path keeper_suffix_turn_records
  then Some Masc_domain.CanReadState
  else if
    is_keeper_checkpoints_get_path req_path
    || is_keeper_paused_work_get_path req_path
    || keeper_path_ends_with req_path keeper_suffix_github_identity
  then Some Masc_domain.CanAdmin
  else if
    keeper_path_ends_with req_path keeper_suffix_raw_traces
    || keeper_path_ends_with req_path keeper_suffix_raw_trace
    || keeper_path_ends_with req_path keeper_suffix_provider_input
    || keeper_path_ends_with req_path keeper_suffix_memory_journal
    (* Same data, same gate: the fact rows are the journal's committed
       content, read back as the current set. *)
    || keeper_path_ends_with req_path keeper_suffix_memory_facts
    (* Same data, same gate: [/file-changes] returns the exact text a keeper
       wrote to a file, which is part of what the raw trace above already
       holds. A lighter gate here would be a second door onto the first
       door's content. *)
    || keeper_path_ends_with req_path keeper_suffix_file_changes
  then Some Masc_domain.CanAdmin
  else None

let trim_to_opt = String_util.trim_nonempty

let truncate_text ~max_chars text =
  let len = String.length text in
  if len <= max_chars then text
  else if max_chars <= 1 then String.sub text 0 (max 0 max_chars)
  else
    String_util.utf8_safe ~max_bytes:max_chars ~suffix:"…" text
    |> String_util.to_string

let latest_preview_of_messages (messages : Agent_core.Types.message list) =
  messages
  |> List.rev
  |> List.find_map (fun (message : Agent_core.Types.message) ->
       if message.role = Agent_core.Types.System then None
       else
         Agent_core.Types.text_of_message message
         |> trim_to_opt
         |> Option.map (truncate_text ~max_chars:180))

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
       | Some path -> String_util.trim_nonempty path
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
   || string_contains_substring key "model")

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

let first_string_opt values =
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

let runtime_manifest_public_json row =
  Keeper_runtime_manifest.public_to_json row

let take_last = List_util.take_last

let error_json ?ok message =
  let fields = [ ("error", `String message) ] in
  let fields =
    match ok with
    | None -> fields
    | Some value -> ("ok", `Bool value) :: fields
  in
  `Assoc fields
