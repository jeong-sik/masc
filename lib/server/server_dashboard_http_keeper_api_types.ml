(** Server_dashboard_http_keeper_api_types — routing types + shared helpers
    extracted from Server_dashboard_http_keeper_api (3136 LoC godfile).

    See server_dashboard_http_keeper_api_types.mli for rationale. *)

let keeper_api_prefix = "/api/v1/keepers/"
let keeper_suffix_config = "/config"
let keeper_suffix_secrets = "/secrets"
let keeper_suffix_github_identity = "/github-identity"
let keeper_suffix_github_login = "/github-login"
let keeper_suffix_github_token = "/github-token"
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
let keeper_suffix_provider_input = "/provider-input"
let keeper_suffix_provider_input_part = "/provider-input/part"
let keeper_suffix_provider_input_continuity = "/provider-input/continuity"
let keeper_suffix_working_context = "/working-context"
let keeper_suffix_file_changes = "/file-changes"
let keeper_suffix_fusion = "/fusion"
let keeper_suffix_operator_note = "/operator-note"
let keeper_suffix_board_attention_quarantines = "/board-attention/quarantines"

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
    (cache_key_string_segment (Workspace.masc_dir config))
    (cache_key_string_segment name)
;;

let keeper_composite_cache_prefix ~base_path =
  Printf.sprintf "keeper:composite:%s:"
    (cache_key_string_segment (Common.masc_dir_from_base_path ~base_path))
;;

let keeper_composite_cache_key ~base_path name =
  keeper_composite_cache_prefix ~base_path ^ cache_key_string_segment name
;;

let fleet_composite_cache_key ~base_path =
  Printf.sprintf "dashboard:fleet-composite:%s" base_path
;;

let invalidate_fleet_composite_cache ~base_path =
  Dashboard_cache.invalidate (fleet_composite_cache_key ~base_path)
;;

let invalidate_workspace_keeper_composites ~base_path =
  Dashboard_cache.invalidate_prefix (keeper_composite_cache_prefix ~base_path);
  invalidate_fleet_composite_cache ~base_path
;;

let invalidate_keeper_composite_cache ~base_path ~name =
  Dashboard_cache.invalidate (keeper_composite_cache_key ~base_path name)
;;

let invalidate_keeper_composite_caches ~base_path ~name =
  invalidate_keeper_composite_cache ~base_path ~name;
  invalidate_fleet_composite_cache ~base_path
;;

let keeper_runtime_trace_cache_prefix ~base_path ~name =
  Printf.sprintf "keeper:runtime-trace:%s:%s:"
    (cache_key_string_segment (Common.masc_dir_from_base_path ~base_path))
    (cache_key_string_segment name)
;;

let invalidate_keeper_runtime_traces ~base_path ~name =
  Dashboard_cache.invalidate_prefix (keeper_runtime_trace_cache_prefix ~base_path ~name)
;;

let keeper_runtime_trace_cache_key (config : Workspace.config) name ?trace_id
      ?turn_id ~limit ()
  =
  Printf.sprintf
    "%s%s:%s:%d"
    (keeper_runtime_trace_cache_prefix ~base_path:config.base_path ~name)
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
  | Keeper_post_github_token
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
    else if ends_with keeper_suffix_github_token then Keeper_post_github_token
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

(* The shape is checked here, not left to the caller: a path where the
   prefix and the suffix overlap, such as [/api/v1/keepers/github-identity],
   has no name segment, and [String.sub] on it would raise. *)
let extract_keeper_name_for_suffix req_path suffix =
  if not (keeper_path_ends_with req_path suffix)
  then ""
  else (
    let plen = String.length keeper_api_prefix in
    let slen = String.length suffix in
    let raw =
      String.trim
        (String.sub req_path plen (String.length req_path - plen - slen))
    in
    if is_valid_keeper_name raw then raw else "")

(* The POST dispatcher's spelling. One grammar, so one body: a second
   definition is a rule that can drift on one side, and a test of the pair can
   only ever agree with itself. *)
let extract_keeper_name_for_post = extract_keeper_name_for_suffix

let trim_to_opt = String_util.trim_nonempty

let truncate_text ~max_chars text =
  let len = String.length text in
  if len <= max_chars then text
  else if max_chars <= 1 then String_util.utf8_prefix ~max_bytes:max_chars text
  else
    String_util.utf8_safe ~max_bytes:max_chars ~suffix:"…" text
    |> String_util.to_string

(* A turn context carrier keeps the User role it was created with, so its
   origin, not its role, says it is not conversation. *)
let preview_of_message (message : Agent_core.Types.message) =
  match message.role, message.origin with
  | Agent_core.Types.System, _
  | (User | Assistant | Tool),
    (Agent_core.Types.System_context | Agent_core.Types.Historical_system_context) -> None
  | (User | Assistant | Tool),
    ( Agent_core.Types.Conversation | Agent_core.Types.Recovery_instruction
    | Agent_core.Types.Tool_result_followup | Agent_core.Types.Agent_instruction ) ->
    Agent_core.Types.text_of_message message
    |> trim_to_opt
    |> Option.map (truncate_text ~max_chars:180)

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

let runtime_trace_keeps_provider_provenance_key = function
  | "model_source"
  | "resolved_model_source"
  | "capability_source"
  | "fallback_authority"
  | "provider_source_runtime" ->
    true
  | _ -> false

let runtime_trace_redacts_provider_model_key key =
  let key = String.lowercase_ascii key in
  (not (runtime_trace_keeps_provider_provenance_key key))
  &&
  (String_util.contains_substring key "provider"
   || String_util.contains_substring key "model")

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

let runtime_manifest_public_json row =
  Keeper_runtime_manifest.public_to_json row

let error_json ?ok message =
  let fields = [ ("error", `String message) ] in
  let fields =
    match ok with
    | None -> fields
    | Some value -> ("ok", `Bool value) :: fields
  in
  `Assoc fields

let respond_error ?(status = `Bad_request) ?request ?ok reqd message =
  Http_server_eio.Response.json_value ?request ~status
    (error_json ?ok message) reqd
