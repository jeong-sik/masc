(** Server_dashboard_http_keeper_api_types — pure routing types + helpers
    extracted from Server_dashboard_http_keeper_api (3136 LoC godfile).

    See server_dashboard_http_keeper_api_types.mli for rationale. *)

let keeper_api_prefix = "/api/v1/keepers/"
let keeper_suffix_tools = "/tools"
let keeper_suffix_config = "/config"
let keeper_suffix_boot = "/boot"
let keeper_suffix_shutdown = "/shutdown"
let keeper_suffix_reset = "/reset"
let keeper_suffix_clear = "/clear"
let keeper_suffix_checkpoints = "/checkpoints"
let keeper_suffix_runtime_trace = "/runtime-trace"
let keeper_suffix_directive = "/directive"
let keeper_suffix_bdi_snapshot = "/bdi-snapshot"

type keeper_post_route_kind =
  | Keeper_post_tools
  | Keeper_post_config
  | Keeper_post_boot
  | Keeper_post_shutdown
  | Keeper_post_reset
  | Keeper_post_clear
  | Keeper_post_checkpoints
  | Keeper_post_directive
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
    if ends_with keeper_suffix_tools then Keeper_post_tools
    else if ends_with keeper_suffix_config then Keeper_post_config
    else if ends_with keeper_suffix_boot then Keeper_post_boot
    else if ends_with keeper_suffix_shutdown then Keeper_post_shutdown
    else if ends_with keeper_suffix_reset then Keeper_post_reset
    else if ends_with keeper_suffix_clear then Keeper_post_clear
    else if ends_with keeper_suffix_checkpoints then Keeper_post_checkpoints
    else if ends_with keeper_suffix_directive then Keeper_post_directive
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

let trim_to_opt (value : string) =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

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

let continuity_summary_of_messages (messages : Agent_sdk.Types.message list) =
  match Keeper_memory_policy.latest_state_snapshot_from_messages messages with
  | Some snapshot ->
      Keeper_memory_policy.keeper_state_snapshot_to_summary_text snapshot
      |> trim_to_opt
  | None -> None

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
