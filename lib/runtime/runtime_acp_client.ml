(** Unified persistent ACP v1 (Agent Client Protocol) JSON-RPC 2.0 over stdio
    client for Antigravity, Kimi Code, Mistral Vibe, and Muse Code. *)

open Result.Syntax

(* ── Closed driver algebra & declarative profiles ─────────────────────────── *)

type driver =
  | Antigravity
  | Kimi_code
  | Mistral_vibe
  | Muse_code
[@@deriving show, eq]

let all_drivers = [ Antigravity; Kimi_code; Mistral_vibe; Muse_code ]

let driver_to_string = function
  | Antigravity -> "antigravity"
  | Kimi_code -> "kimi_code"
  | Mistral_vibe -> "mistral_vibe"
  | Muse_code -> "muse_code"
;;

let driver_of_string = function
  | "antigravity" -> Some Antigravity
  | "kimi_code" -> Some Kimi_code
  | "mistral_vibe" -> Some Mistral_vibe
  | "muse_code" -> Some Muse_code
  | _ -> None
;;

type model_selection =
  | Keep_cli_default
  | Explicit_model of string
[@@deriving show, eq]

let keep_cli_default = Keep_cli_default

let model_selection_of_string raw =
  let trimmed = String.trim raw in
  if trimmed = "" || String.equal (String.lowercase_ascii trimmed) "default"
  then Keep_cli_default
  else Explicit_model trimmed
;;

let model_selection_to_string = function
  | Keep_cli_default -> "default"
  | Explicit_model m -> m
;;

(* Single driver-scoped effort alias SSOT shared by both runtime.toml parsing
   and ACP session/new configOptions parsing.
   Live-verified CLI configOptions (2026-11-23):
   - agy acp 1.5.14: thought_level = [low; medium; high; xhigh]
   - kimi acp 2.7.2: thinking = [low; high; max]
   - vibe-acp 3.1.0: thinking = [off; high]
   - muse acp 1.4.25 (2026-11-24): no effort option in session/new configOptions
     (only [mode] and [model]); effort is the process setting
     [-c reasoning_effort="<level>"]. *)
let effort_of_driver_string ~driver (raw : string) : Llm_provider.Reasoning_effort.t option =
  let normalized = String.lowercase_ascii (String.trim raw) in
  match Llm_provider.Reasoning_effort.of_string normalized with
  | Some _ as eff -> eff
  | None ->
    (match driver, normalized with
     | Mistral_vibe, "off" -> Some Llm_provider.Reasoning_effort.None_
     | (Antigravity | Kimi_code | Mistral_vibe | Muse_code), _ -> None)
;;

let effort_values_for_log ~driver =
  match driver with
  | Mistral_vibe -> Llm_provider.Reasoning_effort.values_for_log ^ "/off"
  | Antigravity | Kimi_code | Muse_code -> Llm_provider.Reasoning_effort.values_for_log
;;

let resolve_effective_effort ?turn_effort ?model_effort ?provider_effort () =
  match turn_effort with
  | Some _ as eff -> eff
  | None ->
    (match model_effort with
     | Some _ as eff -> eff
     | None -> provider_effort)
;;

type mcp_wiring =
  | Session_new_http_mcp
  | Gemini_dir_mcp_config

type mcp_server_isolation =
  | Single_pinned_server of string
  | Shared_or_multi_server
[@@deriving show, eq]

type system_prompt_channel =
  | Meta_antigravity_append
  | Framed_in_first_prompt

type input_accounting =
  | Inclusive_of_cached
  | Exclusive_of_cached

type output_accounting =
  | Inclusive_of_thought
  | Exclusive_of_thought

type mcp_identifier_syntax =
  | Mcp_call_wrapper
  | Mcp_paren_wrapper
  | Mcp_double_underscore
  | Mcp_dot_prefix
  | Mcp_underscore_prefix
  | Server_underscore_prefix
  | Implicit_vendor_mcp_kind
[@@deriving show, eq]

type driver_profile =
  { driver : driver
  ; default_command : string
  ; default_args : string list
  ; env_set : (string * string) list
  ; default_strip_env : string list
  ; mcp_wiring : mcp_wiring
  ; mcp_identifier_syntaxes : mcp_identifier_syntax list
  ; system_prompt_channel : system_prompt_channel
  ; input_accounting : input_accounting
  ; output_accounting : output_accounting
  ; supports_skills_dir_flag : bool
  ; mode_for_native_none : string
  ; mode_for_native_read : string
  ; mode_for_native_full : string
  ; model_config_id : string
  ; effort_config_id : string option
  }

let profile_of_driver = function
  | Antigravity ->
    { driver = Antigravity
    ; default_command = "agy"
    ; default_args = [ "acp" ]
    ; env_set = [ "AGY_CLI_DISABLE_AUTO_UPDATE", "true" ]
    ; default_strip_env = []
    ; mcp_wiring = Gemini_dir_mcp_config
    (* Live-verified against agy acp 1.5.14: call_mcp_tool (rawInput ServerName/
       ToolName), mcp(masc/<tool>) permission syntax, mcp_<server>_<tool>, and
       vendor kind="mcp". *)
    ; mcp_identifier_syntaxes =
        [ Mcp_call_wrapper
        ; Mcp_paren_wrapper
        ; Mcp_underscore_prefix
        ; Implicit_vendor_mcp_kind
        ]
    ; system_prompt_channel = Meta_antigravity_append
    (* Live-verified against agy acp 1.5.14: totalTokens = inputTokens +
       cachedReadTokens + outputTokens (outputTokens already includes thoughtTokens). *)
    ; input_accounting = Exclusive_of_cached
    ; output_accounting = Inclusive_of_thought
    ; supports_skills_dir_flag = false
    ; mode_for_native_none = "default"
    ; mode_for_native_read = "default"
    ; mode_for_native_full = "auto"
    ; model_config_id = "model"
    ; effort_config_id = Some "thought_level"
    }
  | Kimi_code ->
    { driver = Kimi_code
    ; default_command = "kimi"
    ; default_args = [ "acp" ]
    ; env_set = []
    ; default_strip_env = []
    ; mcp_wiring = Session_new_http_mcp
    (* Live-verified against kimi acp 2.7.2: session/update tool_call emits
       title = "mcp__<server>__<tool>" with kind = "other" (no _meta/name) and
       session/request_permission emits title = "mcp__<server>__<tool>" with
       kind omitted; foreign MCP servers emit mcp__<other>__<tool>. *)
    ; mcp_identifier_syntaxes = [ Mcp_double_underscore ]
    ; system_prompt_channel = Framed_in_first_prompt
    ; input_accounting = Inclusive_of_cached
    ; output_accounting = Inclusive_of_thought
    ; supports_skills_dir_flag = true
    ; mode_for_native_none = "default"
    ; mode_for_native_read = "plan"
    ; mode_for_native_full = "yolo"
    ; model_config_id = "model"
    ; effort_config_id = Some "thinking"
    }
  | Mistral_vibe ->
    { driver = Mistral_vibe
    ; default_command = "vibe-acp"
    ; default_args = []
    ; env_set = []
    (* Strip MISTRAL_API_KEY so vibe-acp uses the operator's OS-keyring
       Pro subscription rather than a budget-capped API key. *)
    ; default_strip_env = [ "MISTRAL_API_KEY" ]
    ; mcp_wiring = Session_new_http_mcp
    (* Live-verified against vibe-acp 3.1.0: _meta.tool_name emits
       mcp_<server>.<tool> and <server>_<tool> (plus mcp_<server>_<tool>).
       Implicit_vendor_mcp_kind is deliberately omitted because Vibe shares
       operator [$HOME] ([Shared_or_multi_server]) and cannot prove server
       provenance from an unqualified [kind = "mcp"] frame. *)
    ; mcp_identifier_syntaxes =
        [ Mcp_dot_prefix
        ; Mcp_underscore_prefix
        ; Server_underscore_prefix
        ]
    ; system_prompt_channel = Framed_in_first_prompt
    (* Live-verified against vibe-acp 3.1.0: totalTokens = inputTokens +
       outputTokens (inputTokens already includes cachedReadTokens). *)
    ; input_accounting = Inclusive_of_cached
    ; output_accounting = Inclusive_of_thought
    ; supports_skills_dir_flag = false
    ; mode_for_native_none = "ask"
    ; mode_for_native_read = "ask"
    ; mode_for_native_full = "auto-approve"
    ; model_config_id = "model"
    ; effort_config_id = Some "thinking"
    }
  | Muse_code ->
    { driver = Muse_code
    ; default_command = "muse"
    ; default_args = [ "acp" ]
    (* The launcher script checks for a release and replaces the installed
       binary in the background (muse launcher v4, [MUSE_NO_AUTO_UPDATE]).
       A Keeper pool child must not swap the binary under its siblings; the
       operator updates through [muse] itself. *)
    ; env_set = [ "MUSE_NO_AUTO_UPDATE", "1" ]
    ; default_strip_env = []
    ; mcp_wiring = Session_new_http_mcp
    (* Live-verified against muse acp 1.4.25 (2026-11-24): session/update
       tool_call emits title = name = "mcp__<server>__<tool>" with kind =
       "other"; native tools use plain names ("read_file", kind "read"). The
       host's default permission profile has a model run approve MCP calls and
       sends no session/request_permission frame. In five sessions each call to
       a no-argument stub tool, ordered by the prompt, added one reviewer run
       (a 4,002-token prefix in all five): the host estimated its prompt at
       13.6 to 13.7k tokens in four and 11.6k in the one whose main
       conversation had a single tool, and 1.4 to 4.8 s passed from that
       prompt to the run's tool call. Other tools and arguments were not
       tried, and what the run does with a call it rejects was not observed.
       With settings that selected permissions.default_profile ":ask-me" and
       the client in promptUnmatched, an MCP call produced a frame in both
       sessions run that way (the read call in a third produced none). MASC
       pins onRequest below, and ":ask-me" with onRequest was not tried. The
       frame carries only the toolCallId, so the identity comes from the
       tool_call frame. session/setPermissionProfile and two other method
       names return -32601, and -c permissions.default_profile is refused. *)
    ; mcp_identifier_syntaxes = [ Mcp_double_underscore ]
    ; system_prompt_channel = Framed_in_first_prompt
    (* muse acp reports no per-turn token counts: the prompt result holds only
       stopReason and usage_update holds [used]/[size] of the context window.
       The accounting fields are read only when a usage record exists. *)
    ; input_accounting = Inclusive_of_cached
    ; output_accounting = Inclusive_of_thought
    ; supports_skills_dir_flag = false
    (* Modes advertised by session/new: allowAll, promptUnmatched, onRequest
       (default), denyUnmatched. Pinning "onRequest" on every session keeps a
       resumed session from keeping a looser mode an earlier turn set. *)
    ; mode_for_native_none = "onRequest"
    ; mode_for_native_read = "onRequest"
    ; mode_for_native_full = "allowAll"
    ; model_config_id = "model"
    ; effort_config_id = None
    }
;;

let validate_session_effort ~driver effort =
  match effort, (profile_of_driver driver).effort_config_id with
  | Some requested, None ->
    Error
      (Printf.sprintf
         "%s takes reasoning effort at process start. Set -c reasoning_effort=\"%s\" in the provider args."
         (driver_to_string driver)
         (Llm_provider.Reasoning_effort.to_string requested))
  | None, _ | Some _, Some _ -> Ok ()
;;

let mode_of_posture driver (posture : Runtime_native_tools.posture) =
  let profile = profile_of_driver driver in
  match posture with
  | Runtime_native_tools.Native_none -> profile.mode_for_native_none
  | Runtime_native_tools.Native_read -> profile.mode_for_native_read
  | Runtime_native_tools.Native_full -> profile.mode_for_native_full
;;

let resolve_mode_for_posture ~driver ~(posture : Runtime_native_tools.posture) ~configured_mode =
  let profile = profile_of_driver driver in
  let desired_opt =
    match configured_mode with
    | None -> None
    | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  in
  match posture with
  | Runtime_native_tools.Native_none ->
    (match desired_opt with
     | Some m when not (String.equal m profile.mode_for_native_none) ->
       Log.Runtime_agent.warn
         "clamping configured ACP mode %S to %S for %s under Native_none posture"
         m
         profile.mode_for_native_none
         (driver_to_string driver)
     | Some _ | None -> ());
    profile.mode_for_native_none
  | Runtime_native_tools.Native_read ->
    (match desired_opt with
     | Some m
       when String.equal m profile.mode_for_native_none
            || String.equal m profile.mode_for_native_read -> m
     | Some m ->
       Log.Runtime_agent.warn
         "clamping configured ACP mode %S to %S for %s under Native_read posture"
         m
         profile.mode_for_native_read
         (driver_to_string driver);
       profile.mode_for_native_read
     | None -> profile.mode_for_native_read)
  | Runtime_native_tools.Native_full ->
    Option.value desired_opt ~default:profile.mode_for_native_full
;;

(* ── Named protocol constants ─────────────────────────────────────────────── *)

let protocol_version = 1
let default_timeout_s = 180.0
let init_timeout_s = 30.0
let cancel_write_timeout_s = 1.0
let default_reap_grace_seconds = 5.0
let max_ndjson_line_bytes = 16 * 1024 * 1024
let max_prompt_stream_bytes = 16 * 1024 * 1024
let max_outbound_queue = 256
let max_stderr_tail_bytes = 8192
let max_tracked_tool_calls = 4096

let nonneg n = if n < 0 then 0 else n

let sat_add a b =
  let a = nonneg a in
  let b = nonneg b in
  if a > max_int - b then max_int else a + b
;;

(* ── Configuration & wire types ───────────────────────────────────────────── *)

type mcp_http_server =
  { name : string
  ; url : string
  ; headers : (string * string) list
  ; tool_names : string list
  }

let mcp_http_server_of_bridge bridge =
  let { Runtime_official_client_mcp_http.url; headers } =
    Runtime_official_client_mcp_http.endpoint bridge
  in
  { name = Runtime_official_client_mcp_http.server_name bridge
  ; url
  ; headers
  ; tool_names = Runtime_official_client_mcp_http.tool_names bridge
  }
;;

type config =
  { driver : driver
  ; cli_path : string
  ; args : string list
  ; strip_env : string list
  ; skills_dirs : string list
  ; cwd : string
  ; oauth_source : string option
  ; dangerously_skip_permissions : bool
  ; admission_timeout_s : float
  }

let default_config ~driver ~cwd =
  let profile = profile_of_driver driver in
  { driver
  ; cli_path = profile.default_command
  ; args = profile.default_args
  ; strip_env = profile.default_strip_env
  ; skills_dirs = []
  ; cwd
  ; oauth_source = None
  ; dangerously_skip_permissions = false
  ; admission_timeout_s = init_timeout_s
  }
;;

type agent_capabilities =
  { load_session : bool
  ; resume_session : bool
  ; close_session : bool
  ; additional_directories : bool
  ; image_prompt : bool
  ; embedded_context : bool
  ; mcp_http : bool
  ; antigravity_system_prompt_append : bool
  ; antigravity_tier : string option
  }

type config_option =
  { id : string
  ; name : string
  ; category : string option
  ; current_value : string
  ; available_values : string list
  }

type session_info =
  { session_id : string
  ; current_mode_id : string option
  ; available_modes : string list
  ; current_model_id : string option
  ; available_models : string list
  ; config_options : config_option list
  ; antigravity_tier : string option
  ; replayed_context_used : int option
  ; replayed_context_size : int option
  }

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; cached_read_tokens : int
  ; cached_write_tokens : int
  ; thought_tokens : int
  ; total_tokens : int
  ; context_used : int option
  ; context_size : int option
  }

let empty_usage =
  { input_tokens = 0
  ; output_tokens = 0
  ; cached_read_tokens = 0
  ; cached_write_tokens = 0
  ; thought_tokens = 0
  ; total_tokens = 0
  ; context_used = None
  ; context_size = None
  }
;;

type normalized_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  }

let normalize_usage driver (u : usage) : normalized_usage =
  let profile = profile_of_driver driver in
  let in_tok = nonneg u.input_tokens in
  let out_tok = nonneg u.output_tokens in
  let cached_read = nonneg u.cached_read_tokens in
  let cached_write = nonneg u.cached_write_tokens in
  let thought = nonneg u.thought_tokens in
  let input_tokens =
    match profile.input_accounting with
    | Inclusive_of_cached -> max in_tok (sat_add cached_read cached_write)
    | Exclusive_of_cached -> sat_add in_tok (sat_add cached_read cached_write)
  in
  let output_tokens =
    match profile.output_accounting with
    | Inclusive_of_thought -> max out_tok thought
    | Exclusive_of_thought -> sat_add out_tok thought
  in
  { input_tokens
  ; output_tokens
  ; cache_creation_input_tokens = cached_write
  ; cache_read_input_tokens = cached_read
  }
;;

type stop_reason =
  | End_turn
  | Max_tokens
  | Max_turn_requests
  | Refusal
  | Cancelled
  | Other_stop_reason of string

let stop_reason_to_string = function
  | End_turn -> "end_turn"
  | Max_tokens -> "max_tokens"
  | Max_turn_requests -> "max_turn_requests"
  | Refusal -> "refusal"
  | Cancelled -> "cancelled"
  | Other_stop_reason s -> s
;;

let parse_stop_reason = function
  | "end_turn" -> End_turn
  | "max_tokens" -> Max_tokens
  | "max_turn_requests" -> Max_turn_requests
  | "refusal" -> Refusal
  | "cancelled" -> Cancelled
  | other -> Other_stop_reason other
;;

type prompt_block =
  | Text_block of string
  | Image_block of
      { mime_type : string
      ; base64_data : string
      }

type tool_kind =
  | Tool_read
  | Tool_edit
  | Tool_delete
  | Tool_move
  | Tool_search
  | Tool_execute
  | Tool_think
  | Tool_fetch
  | Tool_switch_mode
  | Tool_other
  | Tool_vendor_mcp
  | Tool_unknown of string
[@@deriving show, eq]

let tool_kind_of_string raw =
  let trimmed = String.trim raw in
  match String.lowercase_ascii trimmed with
  | "read" -> Tool_read
  | "edit" -> Tool_edit
  | "delete" -> Tool_delete
  | "move" -> Tool_move
  | "search" -> Tool_search
  | "execute" -> Tool_execute
  | "think" -> Tool_think
  | "fetch" -> Tool_fetch
  | "switch_mode" -> Tool_switch_mode
  | "other" -> Tool_other
  | "mcp" -> Tool_vendor_mcp
  | _ -> Tool_unknown trimmed
;;

let tool_kind_to_string = function
  | Tool_read -> "read"
  | Tool_edit -> "edit"
  | Tool_delete -> "delete"
  | Tool_move -> "move"
  | Tool_search -> "search"
  | Tool_execute -> "execute"
  | Tool_think -> "think"
  | Tool_fetch -> "fetch"
  | Tool_switch_mode -> "switch_mode"
  | Tool_other -> "other"
  | Tool_vendor_mcp -> "mcp"
  | Tool_unknown s -> s
;;

type mcp_server_qualifier =
  | Explicit_server of string
  | Implicit_mcp_kind

type tool_call_identity =
  | Mcp_tool of
      { server : mcp_server_qualifier
      ; tool_name : string
      }
  | Managed_mcp_schema_read of
      { mcp_server_name : string
      ; path : string
      }
  | Native_tool of
      { name : string option
      ; kind : tool_kind option
      ; locations : string list
      }

type tool_call_status =
  | Tool_pending
  | Tool_in_progress
  | Tool_completed
  | Tool_failed
  | Tool_other_status of string

type stream_event =
  | Text_delta of string
  | Thought_delta of string
  | Tool_call_started of
      { tool_call_id : string
      ; title : string
      ; kind : tool_kind option
      ; status : tool_call_status
      ; raw_input : Yojson.Safe.t option
      ; identity : tool_call_identity
      }
  | Tool_call_updated of
      { tool_call_id : string
      ; title : string option
      ; kind : tool_kind option
      ; status : tool_call_status option
      ; raw_input : Yojson.Safe.t option
      ; raw_output : Yojson.Safe.t option
      ; identity : tool_call_identity option
      }
  | Usage_updated of
      { used : int option
      ; size : int option
      ; prompt_tokens : int option
      ; completion_tokens : int option
      ; cached_tokens : int option
      ; cached_write_tokens : int option
      ; thought_tokens : int option
      ; total_tokens : int option
      }
  | Mode_updated of string
  | Config_options_updated of config_option list

type permission_policy =
  | Allow_all
  | Allow_masc_mcp_only of
      { mcp_server_name : string
      ; allowed_tool_names : string list
      }
  | Allow_read_and_masc_mcp of
      { mcp_server_name : string
      ; allowed_tool_names : string list
      }
  | Deny_all

let permission_policy_of_posture ~mcp_server_name ~allowed_tool_names = function
  | Runtime_native_tools.Native_none ->
    Allow_masc_mcp_only { mcp_server_name; allowed_tool_names }
  | Runtime_native_tools.Native_read ->
    Allow_read_and_masc_mcp { mcp_server_name; allowed_tool_names }
  | Runtime_native_tools.Native_full -> Allow_all
;;

type prompt_result =
  { session_id : string
  ; stop_reason : stop_reason
  ; text : string
  ; thought : string
  ; usage : usage
  ; tool_calls_observed : int
  ; wall_duration_s : float
  }

type error =
  | Invalid_config of string
  | Spawn_refused of Process_eio.spawn_refusal
  | Protocol_error of
      { stage : string
      ; detail : string
      }
  | Rpc_error of
      { method_name : string
      ; code : int
      ; message : string
      ; data : Yojson.Safe.t option
      ; refusal : Llm_provider.Retry.signal_refusal option
      }
  | Timeout of
      { stage : string
      ; timeout_s : float
      }
  | Process_exited of
      { detail : string
      ; stderr_tail : string
      }
  | Client_closed

let rec redact_string_value ~depth (raw : string) : string =
  let trimmed = String.trim raw in
  let looks_like_json =
    String.length trimmed > 0 && (trimmed.[0] = '{' || trimmed.[0] = '[')
  in
  if depth < 2 && looks_like_json
  then
    if String.length trimmed <= 16384
    then (
      match Yojson.Safe.from_string trimmed with
      | parsed ->
        Yojson.Safe.to_string
          (Secret_patterns.redact_json_with
             ~on_string:(redact_string_value ~depth:(depth + 1))
             parsed)
      | exception Yojson.Json_error _ ->
        Printf.sprintf "[redacted malformed JSON string (%d bytes)]" (String.length raw))
    else Printf.sprintf "[redacted oversized JSON string (%d bytes)]" (String.length raw)
  else Secret_patterns.redact_text raw
;;

let bounded_redacted_json_summary (json : Yojson.Safe.t) =
  let max_bytes = 512 in
  let redacted =
    Yojson.Safe.to_string
      (Secret_patterns.redact_json_with ~on_string:(redact_string_value ~depth:0) json)
  in
  if String.length redacted <= max_bytes
  then redacted
  else String_util.utf8_prefix ~max_bytes:(max_bytes - 3) redacted ^ "..."
;;

let error_to_string = function
  | Invalid_config detail -> "invalid ACP config: " ^ detail
  | Spawn_refused refusal ->
    "failed to start ACP client: " ^ Process_eio.spawn_refusal_to_string refusal
  | Protocol_error { stage; detail } ->
    Printf.sprintf "ACP protocol error (%s): %s" stage detail
  | Rpc_error { method_name; code; message; data; refusal = _ } ->
    (match data with
     | None -> Printf.sprintf "ACP RPC error in %s (code %d): %s" method_name code message
     | Some json ->
       Printf.sprintf
         "ACP RPC error in %s (code %d): %s (data: %s)"
         method_name
         code
         message
         (bounded_redacted_json_summary json))
  | Timeout { stage; timeout_s } ->
    Printf.sprintf "ACP timeout in %s after %.1fs" stage timeout_s
  | Process_exited { detail; stderr_tail } ->
    let tail = String.trim stderr_tail in
    if tail = ""
    then Printf.sprintf "ACP process exited: %s" detail
    else Printf.sprintf "ACP process exited: %s (stderr: %s)" detail tail
  | Client_closed -> "ACP client is closed"
;;

type jsonrpc_code =
  | Jsonrpc_parse_error
  | Jsonrpc_invalid_request
  | Jsonrpc_method_not_found
  | Jsonrpc_invalid_params
  | Jsonrpc_internal_error
  | Jsonrpc_server_error of int
  | Jsonrpc_http_status of int
  | Jsonrpc_other_code of int

let jsonrpc_code_of_int = function
  | -32700 -> Jsonrpc_parse_error
  | -32600 -> Jsonrpc_invalid_request
  | -32601 -> Jsonrpc_method_not_found
  | -32602 -> Jsonrpc_invalid_params
  | -32603 -> Jsonrpc_internal_error
  | n when n >= -32099 && n <= -32000 -> Jsonrpc_server_error n
  | n when n >= 400 && n <= 599 -> Jsonrpc_http_status n
  | n -> Jsonrpc_other_code n
;;

let rpc_error ~method_name ~code ~message ~data =
  let module Retry = Llm_provider.Retry in
  let http_status =
    match jsonrpc_code_of_int code with
    | Jsonrpc_http_status status -> Some status
    | Jsonrpc_parse_error
    | Jsonrpc_invalid_request
    | Jsonrpc_method_not_found
    | Jsonrpc_invalid_params
    | Jsonrpc_internal_error
    | Jsonrpc_server_error _
    | Jsonrpc_other_code _ -> None
  in
  let structured_data =
    match data with
    | Some (`String raw) -> Llm_provider.Json_util.from_string_bounded raw |> Result.to_option
    | other -> other
  in
  let refusal =
    Retry.classify_structured_json ?http_status ~fallback_message:message
      (Option.value ~default:`Null structured_data)
  in
  Rpc_error { method_name; code; message; data; refusal }
;;

let image_input_unsupported_detail driver =
  Printf.sprintf
    "ACP server (%s) does not advertise promptCapabilities.image support"
    (driver_to_string driver)
;;

let validate_prompt_blocks ~driver ~(capabilities : agent_capabilities) blocks =
  let images =
    List.filter_map
      (function
        | Text_block _ -> None
        | Image_block { mime_type; base64_data } ->
          Some { Runtime_official_client_tool.media_type = mime_type; base64_data })
      blocks
  in
  match images with
  | [] -> Ok ()
  | _ :: _ ->
    if not capabilities.image_prompt
    then Error (Invalid_config (image_input_unsupported_detail driver))
    else
      Runtime_official_client_tool.validate_image_inputs images
      |> Result.map_error (fun detail -> Invalid_config detail)
;;

(* ── Higher-rank polymorphic JSON decoding helpers ────────────────────────── *)

type 'a json_decoder = { decode : Yojson.Safe.t -> ('a, string) result }

let json_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let json_string_opt key json =
  match json_field key json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let json_int_opt key json =
  match json_field key json with
  | Some (`Int n) -> Some n
  | Some (`Intlit s) -> int_of_string_opt s
  | _ -> None
;;

let json_bool_or ~default key json =
  match json_field key json with
  | Some (`Bool b) -> b
  | _ -> default
;;

let json_list_opt key json =
  match json_field key json with
  | Some (`List xs) -> Some xs
  | _ -> None
;;

let parse_tool_status = function
  | "pending" -> Tool_pending
  | "in_progress" -> Tool_in_progress
  | "completed" -> Tool_completed
  | "failed" -> Tool_failed
  | other -> Tool_other_status other
;;

let parse_option_values json =
  let extract_entry item =
    match json_string_opt "value" item with
    | Some v when String.trim v <> "" -> [ v ]
    | _ ->
      (match json_list_opt "options" item with
       | Some grouped ->
         List.filter_map
           (fun sub ->
              match json_string_opt "value" sub with
              | Some v when String.trim v <> "" -> Some v
              | _ -> None)
           grouped
       | None -> [])
  in
  match json_list_opt "options" json with
  | None -> []
  | Some items -> List.concat_map extract_entry items
;;

let parse_config_option json =
  match json_string_opt "id" json, json_string_opt "currentValue" json with
  | Some id, Some current_value ->
    let name = Option.value (json_string_opt "name" json) ~default:id in
    let category = json_string_opt "category" json in
    let available_values = parse_option_values json in
    Some { id; name; category; current_value; available_values }
  | _ -> None
;;

let parse_config_options json =
  match json_list_opt "configOptions" json with
  | None -> []
  | Some items -> List.filter_map parse_config_option items
;;

let is_allowed_mcp_kind = function
  | None | Some (Tool_vendor_mcp | Tool_other) -> true
  | Some
      ( Tool_read
      | Tool_edit
      | Tool_delete
      | Tool_move
      | Tool_search
      | Tool_execute
      | Tool_think
      | Tool_fetch
      | Tool_switch_mode
      | Tool_unknown _ ) -> false
;;

let is_allowed_explicit_mcp_wrapper_kind = function
  | None | Some (Tool_vendor_mcp | Tool_other | Tool_execute) -> true
  | Some
      ( Tool_read
      | Tool_edit
      | Tool_delete
      | Tool_move
      | Tool_search
      | Tool_think
      | Tool_fetch
      | Tool_switch_mode
      | Tool_unknown _ ) -> false
;;

let is_read_only_tool_kind = function
  | Some (Tool_read | Tool_search | Tool_think) -> true
  | Some
      ( Tool_edit
      | Tool_delete
      | Tool_move
      | Tool_execute
      | Tool_fetch
      | Tool_switch_mode
      | Tool_other
      | Tool_vendor_mcp
      | Tool_unknown _ )
  | None -> false
;;

(* Partial-order security-restriction join for monotonic tool-kind merging:
   - [Branch_read_only]: [Tool_read] < ({!Tool_search}, {!Tool_think})
     ([Tool_read] additionally permits managed schema reads).
   - [Branch_mcp]: [Tool_vendor_mcp] < [Tool_other] < [Tool_execute]
     (progressively narrower MCP authorization predicates).
   - [Branch_restricted]: Edit/Delete/Move/Fetch/Switch_mode/Unknown —
     denied and effect-fenced everywhere.
   Merging within a branch takes the more restrictive kind; any cross-branch
   conflict (empty policy intersection, e.g. Read+Execute, Read+Other,
   Execute+Read) escalates to [Tool_unknown "conflict:<prior>-><incoming>"].
   Thus for every non-empty pair [(Some p, Some i)], every authorization
   predicate P satisfies [P(merge(Some p, Some i)) => P(Some p) && P(Some i)]. *)
type tool_kind_branch =
  | Branch_read_only
  | Branch_mcp
  | Branch_restricted

let branch_of_tool_kind = function
  | Tool_read | Tool_search | Tool_think -> Branch_read_only
  | Tool_vendor_mcp | Tool_other | Tool_execute -> Branch_mcp
  | Tool_edit | Tool_delete | Tool_move | Tool_fetch | Tool_switch_mode | Tool_unknown _ ->
    Branch_restricted
;;

let within_branch_rank = function
  | Tool_read -> 0
  | Tool_search | Tool_think -> 1
  | Tool_vendor_mcp -> 0
  | Tool_other -> 1
  | Tool_execute -> 2
  | Tool_edit | Tool_delete | Tool_move | Tool_fetch | Tool_switch_mode | Tool_unknown _ -> 3
;;

let merge_tool_kind ~(prior : tool_kind option) ~(incoming : tool_kind option)
  : tool_kind option
  =
  match prior, incoming with
  | None, inc -> inc
  | (Some _ as prev), None -> prev
  | Some p, Some i ->
    if equal_tool_kind p i
    then Some p
    else (
      match branch_of_tool_kind p, branch_of_tool_kind i with
      | Branch_restricted, (Branch_restricted | Branch_read_only | Branch_mcp) -> Some p
      | (Branch_read_only | Branch_mcp), Branch_restricted -> Some i
      | Branch_read_only, Branch_read_only | Branch_mcp, Branch_mcp ->
        if within_branch_rank i > within_branch_rank p then Some i else Some p
      | Branch_read_only, Branch_mcp | Branch_mcp, Branch_read_only ->
        Some
          (Tool_unknown
             (Printf.sprintf
                "conflict:%s->%s"
                (tool_kind_to_string p)
                (tool_kind_to_string i))))
;;

let trim_nonempty_opt = function
  | Some s ->
    let trimmed = String.trim s in
    if trimmed = "" then None else Some trimmed
  | None -> None
;;

let first_non_empty_json_string keys json =
  List.find_map
    (fun key -> trim_nonempty_opt (json_string_opt key json))
    keys
;;

let index_of_sub ~needle haystack =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  if n_len = 0 || n_len > h_len
  then None
  else (
    let rec scan i =
      if i > h_len - n_len
      then None
      else if String.sub haystack i n_len = needle
      then Some i
      else scan (i + 1)
    in
    scan 0)
;;

type tool_call_wire =
  { tool_call_id : string
  ; title : string option
  ; name : string option
  ; kind : tool_kind option
  ; meta_server_name : string option
  ; meta_tool_name : string option
  ; raw_input : Yojson.Safe.t option
  ; locations : string list
  }

let parse_tool_call_wire (json : Yojson.Safe.t) : tool_call_wire =
  let tool_call_id =
    Option.value (trim_nonempty_opt (json_string_opt "toolCallId" json)) ~default:""
  in
  let title = trim_nonempty_opt (json_string_opt "title" json) in
  let name = trim_nonempty_opt (json_string_opt "name" json) in
  let kind = Option.map tool_kind_of_string (trim_nonempty_opt (json_string_opt "kind" json)) in
  let meta = json_field "_meta" json in
  let meta_server_name =
    Option.bind
      meta
      (first_non_empty_json_string [ "server_name"; "serverName"; "mcp_server"; "mcpServer" ])
  in
  let meta_tool_name =
    Option.bind meta (first_non_empty_json_string [ "tool_name"; "toolName" ])
  in
  let raw_input =
    match json_field "rawInput" json with
    | Some _ as v -> v
    | None -> json_field "args" json
  in
  let locations =
    match json_list_opt "locations" json with
    | None -> []
    | Some entries ->
      List.filter_map
        (fun item -> trim_nonempty_opt (json_string_opt "path" item))
        entries
  in
  { tool_call_id; title; name; kind; meta_server_name; meta_tool_name; raw_input; locations }
;;

let is_non_empty_raw_input = function
  | None | Some (`Assoc []) | Some `Null -> false
  | Some _ -> true
;;

let has_ascii_whitespace s =
  String.exists (function ' ' | '\t' | '\n' | '\r' -> true | _ -> false) s
;;

let string_opt_conflicts prev inc =
  match prev, inc with
  | Some p, Some i -> not (String.equal p i)
  | Some _, None | None, (Some _ | None) -> false
;;

let mcp_title_identifier_conflicts prev inc =
  match prev, inc with
  | Some p, Some i ->
    (not (String.equal p i))
    && (not (has_ascii_whitespace p))
    && not (has_ascii_whitespace i)
  | Some _, None | None, (Some _ | None) -> false
;;

let raw_input_conflicts prev inc =
  if is_non_empty_raw_input prev && is_non_empty_raw_input inc
  then (
    match prev, inc with
    | Some p, Some i -> not (Yojson.Safe.equal (Yojson.Safe.sort p) (Yojson.Safe.sort i))
    | (Some _ | None), (Some _ | None) -> false)
  else false
;;

(* Monotonic merge: first-observed identity fields (meta_server_name,
   meta_tool_name, name, title, non-empty raw_input) are immutable, while [kind]
   follows {!merge_tool_kind}'s security-restriction lattice so neither a later
   downgrade (e.g. Execute -> Read) nor an initial placeholder (e.g. Other ->
   Execute/Edit) can weaken policy enforcement. Missing fields may still be
   enriched and locations are unioned. Any conflicting non-empty structured
   identity field ([name], [_meta.server_name], [_meta.tool_name], key-order-
   insensitive [raw_input]), conflicting whitespace-free MCP identifier [title]
   (under any MCP- or wrapper-eligible kind including [Tool_execute] for
   Antigravity [mcp(<srv>/<tool>)], while preserving live ACP human-display
   title progress such as [kimi acp 2.7.2] "Read" -> "Reading hello.txt"), or
   late introduction of a differing structured name after an identifier-like
   [title] escalates [kind] to [Tool_unknown "conflict:identity"]. *)
let merge_tool_call_wire ~(prior : tool_call_wire) ~(incoming : tool_call_wire) : tool_call_wire =
  let keep_first prev inc = match prev with Some _ -> prev | None -> inc in
  let has_structured_tool_name =
    Option.is_some prior.meta_tool_name
    || Option.is_some incoming.meta_tool_name
    || Option.is_some prior.name
    || Option.is_some incoming.name
  in
  let merged_kind = merge_tool_kind ~prior:prior.kind ~incoming:incoming.kind in
  let structured_name_introduced_conflict =
    is_allowed_explicit_mcp_wrapper_kind merged_kind
    && Option.is_none prior.name
    && Option.is_none prior.meta_tool_name
    &&
    match prior.title with
    | Some p when not (has_ascii_whitespace p) ->
      let differs = function
        | Some s -> not (String.equal p s)
        | None -> false
      in
      differs incoming.name || differs incoming.meta_tool_name
    | Some _ | None -> false
  in
  let identity_conflict =
    string_opt_conflicts prior.name incoming.name
    || string_opt_conflicts prior.meta_server_name incoming.meta_server_name
    || string_opt_conflicts prior.meta_tool_name incoming.meta_tool_name
    || raw_input_conflicts prior.raw_input incoming.raw_input
    || structured_name_introduced_conflict
    || ((not has_structured_tool_name)
        && is_allowed_explicit_mcp_wrapper_kind merged_kind
        && mcp_title_identifier_conflicts prior.title incoming.title)
  in
  let raw_input =
    if is_non_empty_raw_input prior.raw_input
    then prior.raw_input
    else if is_non_empty_raw_input incoming.raw_input
    then incoming.raw_input
    else keep_first prior.raw_input incoming.raw_input
  in
  let locations =
    prior.locations
    @ List.filter (fun p -> not (List.mem p prior.locations)) incoming.locations
  in
  let kind =
    if identity_conflict
    then merge_tool_kind ~prior:merged_kind ~incoming:(Some (Tool_unknown "conflict:identity"))
    else merged_kind
  in
  { tool_call_id =
      if prior.tool_call_id <> "" then prior.tool_call_id else incoming.tool_call_id
  ; title = keep_first prior.title incoming.title
  ; name = keep_first prior.name incoming.name
  ; kind
  ; meta_server_name = keep_first prior.meta_server_name incoming.meta_server_name
  ; meta_tool_name = keep_first prior.meta_tool_name incoming.meta_tool_name
  ; raw_input
  ; locations
  }
;;

let canonical_managed_schema_file ~schema_dir raw_path =
  if String.trim raw_path = ""
     || Filename.is_relative raw_path
     || String.contains raw_path '\000'
  then None
  else (
    try
      let canonical = Unix.realpath raw_path in
      let stat = Unix.lstat canonical in
      let base = Filename.basename canonical in
      if stat.Unix.st_kind = Unix.S_REG
         && String.equal (Filename.dirname canonical) schema_dir
         && Runtime_antigravity_policy.path_is_within ~root:schema_dir canonical
         && (not (String.equal canonical schema_dir))
         && (Filename.check_suffix base ".json" || String.equal base "instructions.md")
      then Some canonical
      else None
    with
    | Unix.Unix_error _ -> None)
;;

let schema_read_path_keys =
  [ "Path"
  ; "path"
  ; "file_path"
  ; "filePath"
  ; "AbsolutePath"
  ; "absolute_path"
  ; "target_file"
  ; "TargetFile"
  ; "DirectoryPath"
  ; "directory_path"
  ; "SearchPath"
  ; "search_path"
  ]
;;

let extract_schema_read_paths (wire : tool_call_wire) =
  let raw_input_paths =
    match wire.raw_input with
    | None -> Ok []
    | Some (`Assoc []) -> Ok []
    | Some (`Assoc fields) ->
      let matched =
        List.filter_map
          (fun (k, v) ->
             if List.mem k schema_read_path_keys
             then Some v
             else None)
          fields
      in
      if matched = []
      then Error ()
      else (
        let parsed =
          List.map
            (function
              | `String s when String.trim s <> "" -> Some s
              | _ -> None)
            matched
        in
        if List.for_all Option.is_some parsed
        then Ok (List.filter_map Fun.id parsed)
        else Error ())
    | Some _ -> Error ()
  in
  match raw_input_paths with
  | Error () -> None
  | Ok input_paths ->
    let combined = wire.locations @ input_paths in
    if combined = [] then None else Some combined
;;

(* Explicit [mcp(<server>/<tool>)] or [mcp(<server>:<tool>)] wrapper emitted by
   Antigravity ACP (including with [kind = "execute"]). *)
let parse_explicit_mcp_wrapper candidate =
  let trimmed = String.trim candidate in
  let len = String.length trimmed in
  if len > 5
     && not (has_ascii_whitespace trimmed)
     && String.starts_with ~prefix:"mcp(" trimmed
     && trimmed.[len - 1] = ')'
  then (
    let inner = String.sub trimmed 4 (len - 5) in
    let split_at sep =
      match String.index_opt inner sep with
      | Some idx when idx > 0 && idx + 1 < String.length inner ->
        let srv = String.sub inner 0 idx in
        let tool = String.sub inner (idx + 1) (String.length inner - idx - 1) in
        if String.contains srv '/'
           || String.contains srv ':'
           || String.contains tool '/'
           || String.contains tool ':'
           || String.contains tool '('
           || String.contains tool ')'
        then None
        else Some (Mcp_tool { server = Explicit_server srv; tool_name = tool })
      | _ -> None
    in
    match split_at '/' with
    | Some _ as m -> m
    | None -> split_at ':')
  else None
;;

let driver_allows_mcp_syntax driver syntax =
  let profile = profile_of_driver driver in
  List.exists (equal_mcp_identifier_syntax syntax) profile.mcp_identifier_syntaxes
;;

let accept_syntax_or_warn ~driver ~syntax ~candidate parsed =
  if driver_allows_mcp_syntax driver syntax
  then Some parsed
  else (
    Log.Runtime_agent.warn
      "rejecting cross-driver ACP MCP identifier %S (syntax %s not declared for driver %s)"
      candidate
      (show_mcp_identifier_syntax syntax)
      (driver_to_string driver);
    None)
;;

let match_mcp_identifier_syntax ?mcp_server_name ~(kind : tool_kind option) trimmed syntax =
  match syntax with
  | Mcp_call_wrapper | Mcp_paren_wrapper -> None
  | Mcp_double_underscore ->
    if String.starts_with ~prefix:"mcp__" trimmed
    then (
      let rest = String.sub trimmed 5 (String.length trimmed - 5) in
      match index_of_sub ~needle:"__" rest with
      | Some idx when idx > 0 && idx + 2 < String.length rest ->
        let srv = String.sub rest 0 idx in
        let tool = String.sub rest (idx + 2) (String.length rest - idx - 2) in
        Some (Mcp_tool { server = Explicit_server srv; tool_name = tool })
      | Some _ | None -> None)
    else None
  | Mcp_dot_prefix ->
    if String.starts_with ~prefix:"mcp_" trimmed
    then (
      let rest = String.sub trimmed 4 (String.length trimmed - 4) in
      match String.index_opt rest '.' with
      | Some idx when idx > 0 && idx + 1 < String.length rest ->
        let srv = String.sub rest 0 idx in
        let tool = String.sub rest (idx + 1) (String.length rest - idx - 1) in
        Some (Mcp_tool { server = Explicit_server srv; tool_name = tool })
      | Some _ | None -> None)
    else None
  | Mcp_underscore_prefix ->
    if String.starts_with ~prefix:"mcp_" trimmed
    then (
      let rest = String.sub trimmed 4 (String.length trimmed - 4) in
      match mcp_server_name with
      | Some expected_srv
        when expected_srv <> ""
             && String.starts_with ~prefix:(expected_srv ^ "_") rest
             && String.length rest > String.length expected_srv + 1 ->
        let prefix_len = String.length expected_srv + 1 in
        let tool = String.sub rest prefix_len (String.length rest - prefix_len) in
        Some (Mcp_tool { server = Explicit_server expected_srv; tool_name = tool })
      | Some _ | None -> None)
    else None
  | Server_underscore_prefix ->
    (match mcp_server_name with
     | Some expected_srv
       when expected_srv <> ""
            && String.starts_with ~prefix:(expected_srv ^ "_") trimmed
            && String.length trimmed > String.length expected_srv + 1 ->
       let prefix_len = String.length expected_srv + 1 in
       let tool = String.sub trimmed prefix_len (String.length trimmed - prefix_len) in
       Some (Mcp_tool { server = Explicit_server expected_srv; tool_name = tool })
     | Some _ | None -> None)
  | Implicit_vendor_mcp_kind ->
    (match kind with
     | Some Tool_vendor_mcp ->
       Some (Mcp_tool { server = Implicit_mcp_kind; tool_name = trimmed })
     | Some
         ( Tool_read
         | Tool_edit
         | Tool_delete
         | Tool_move
         | Tool_search
         | Tool_execute
         | Tool_think
         | Tool_fetch
         | Tool_switch_mode
         | Tool_other
         | Tool_unknown _ )
     | None -> None)
;;

let parse_qualified_mcp_identifier ~driver ?mcp_server_name ~(kind : tool_kind option) candidate =
  let trimmed = String.trim candidate in
  if trimmed = "" || has_ascii_whitespace trimmed || String.starts_with ~prefix:"mcp(" trimmed
  then None
  else (
    let profile = profile_of_driver driver in
    let explicit_declared =
      List.filter
        (fun s -> not (equal_mcp_identifier_syntax s Implicit_vendor_mcp_kind))
        profile.mcp_identifier_syntaxes
    in
    match
      List.find_map
        (match_mcp_identifier_syntax ?mcp_server_name ~kind trimmed)
        explicit_declared
    with
    | Some _ as matched -> matched
    | None ->
      (* Warn and fail closed on unambiguous cross-driver MCP prefixes
         (mcp__, mcp_<srv>., mcp_<srv>_) BEFORE considering
         [Implicit_vendor_mcp_kind] so foreign-driver prefixes paired with
         [kind = "mcp"] cannot silently skip the cross-driver warning. *)
      let explicit_cross_driver_syntaxes =
        [ Mcp_double_underscore; Mcp_dot_prefix; Mcp_underscore_prefix ]
      in
      let matched_cross_driver =
        List.fold_left
          (fun matched syntax ->
             if not (driver_allows_mcp_syntax driver syntax)
             then (
               match match_mcp_identifier_syntax ?mcp_server_name ~kind trimmed syntax with
               | Some _ ->
                 Log.Runtime_agent.warn
                   "rejecting cross-driver ACP MCP identifier %S (syntax %s not declared for driver %s)"
                   trimmed
                   (show_mcp_identifier_syntax syntax)
                   (driver_to_string driver);
                 true
               | None -> matched)
             else matched)
          false
          explicit_cross_driver_syntaxes
      in
      if matched_cross_driver
      then None
      else if driver_allows_mcp_syntax driver Implicit_vendor_mcp_kind
      then match_mcp_identifier_syntax ?mcp_server_name ~kind trimmed Implicit_vendor_mcp_kind
      else None)
;;

let classify_tool_call ~driver ?managed_schema_root ?mcp_server_name (wire : tool_call_wire)
  : tool_call_identity
  =
  let fallback () =
    let name =
      match wire.meta_tool_name with
      | Some _ as n -> n
      | None ->
        (match wire.name with
         | Some _ as n -> n
         | None -> wire.title)
    in
    Native_tool { name; kind = wire.kind; locations = wire.locations }
  in
  (* 1. Structured MCP proxy call (Antigravity [call_mcp_tool] carrying
        explicit [ServerName]/[server_name]/[mcp_server] and
        [ToolName]/[tool_name]/[name] in [rawInput]/[args]). *)
  let is_call_mcp_tool =
    match wire.meta_tool_name, wire.name, wire.title with
    | Some "call_mcp_tool", _, _ -> true
    | None, Some "call_mcp_tool", _ -> true
    | None, None, Some "call_mcp_tool" -> true
    | _ -> false
  in
  if is_call_mcp_tool
  then (
    if not (driver_allows_mcp_syntax driver Mcp_call_wrapper)
    then (
      Log.Runtime_agent.warn
        "rejecting cross-driver call_mcp_tool wrapper under driver %s"
        (driver_to_string driver);
      fallback ())
    else if not (is_allowed_explicit_mcp_wrapper_kind wire.kind)
    then fallback ()
    else (
      let server =
        Option.bind
          wire.raw_input
          (first_non_empty_json_string
             [ "ServerName"; "serverName"; "server_name"; "mcp_server" ])
      in
      let tool =
        Option.bind
          wire.raw_input
          (first_non_empty_json_string [ "ToolName"; "toolName"; "tool_name"; "name" ])
      in
      match server, tool with
      | Some srv, Some tool_name
        when (not (has_ascii_whitespace srv))
             && not (has_ascii_whitespace tool_name)
             && (match wire.meta_server_name with
                 | None -> true
                 | Some meta_srv -> String.equal meta_srv srv) ->
        Mcp_tool { server = Explicit_server srv; tool_name }
      | _ -> fallback ()))
  else (
    (* 2. Structured [_meta] server identity: whenever [_meta] names a server,
          NEVER fall through to [Implicit_mcp_kind] so a foreign server cannot
          bypass server checks by omitting [_meta.tool_name]. *)
    match wire.meta_server_name with
    | Some srv ->
      if not (is_allowed_mcp_kind wire.kind)
      then fallback ()
      else (
        let candidate_tool =
          let pick_non_empty = function
            | Some s ->
              let t = String.trim s in
              if t <> "" && not (has_ascii_whitespace t) then Some t else None
            | None -> None
          in
          match pick_non_empty wire.meta_tool_name with
          | Some _ as found -> found
          | None ->
            (match pick_non_empty wire.name with
             | Some _ as found -> found
             | None -> pick_non_empty wire.title)
        in
        match candidate_tool with
        | Some tool_name -> Mcp_tool { server = Explicit_server srv; tool_name }
        | None -> fallback ())
    | None ->
      (* 3. Read-only lazy MCP schema read strictly targeting a single direct
            child file inside this client's MASC-owned
            [<gemini_dir>/antigravity-cli/mcp/<server>] folder. *)
      let schema_read =
        let allowed_read_tool_name =
          match wire.name with
          | None | Some "read_file" -> true
          | Some _ -> false
        in
        match managed_schema_root with
        | Some (srv, schema_dir)
          when allowed_read_tool_name
               && Option.equal equal_tool_kind wire.kind (Some Tool_read) ->
          (match extract_schema_read_paths wire with
           | None -> None
           | Some paths ->
             let canonicalized =
               List.map (canonical_managed_schema_file ~schema_dir) paths
             in
             (match canonicalized with
              | Some first :: rest
                when List.for_all
                       (function
                         | Some p -> String.equal p first
                         | None -> false)
                       rest ->
                Some (Managed_mcp_schema_read { mcp_server_name = srv; path = first })
              | Some _ :: _ | None :: _ | [] -> None))
        | Some _ | None -> None
      in
      (match schema_read with
       | Some id -> id
       | None ->
         (* 4. Driver-scoped protocol-qualified MCP tool identifiers:
               4a. Explicit [mcp(<srv>/<tool>)] / [mcp(<srv>:<tool>)] wrapper
                   (Antigravity only, permitted across None/mcp/other/execute).
               4b. Driver-declared qualified identifiers gated strictly on
                   [is_allowed_mcp_kind] and [driver_profile.mcp_identifier_syntaxes]. *)
         let candidate =
           match wire.meta_tool_name with
           | Some s -> Some s
           | None ->
             (match wire.name with
              | Some s -> Some s
              | None -> wire.title)
         in
         (match Option.bind candidate parse_explicit_mcp_wrapper with
          | Some id ->
            if is_allowed_explicit_mcp_wrapper_kind wire.kind
            then (
              let cand_str = Option.value candidate ~default:"" in
              match accept_syntax_or_warn ~driver ~syntax:Mcp_paren_wrapper ~candidate:cand_str id with
              | Some accepted -> accepted
              | None -> fallback ())
            else fallback ()
          | None ->
            if is_allowed_mcp_kind wire.kind
            then (
              match
                Option.bind
                  candidate
                  (parse_qualified_mcp_identifier ~driver ?mcp_server_name ~kind:wire.kind)
              with
              | Some id -> id
              | None -> fallback ())
            else fallback ())))
;;

let classify_tool_call_json ~driver ?managed_schema_root ?mcp_server_name json =
  parse_tool_call_wire json |> classify_tool_call ~driver ?managed_schema_root ?mcp_server_name
;;

let should_allow_tool_call
      ?(server_isolation = Shared_or_multi_server)
      ~policy
      identity
  =
  let matches_pinned ~mcp_server_name ~allowed_tool_names = function
    | Mcp_tool { server = Explicit_server srv; tool_name } ->
      String.equal srv mcp_server_name && List.mem tool_name allowed_tool_names
    | Mcp_tool { server = Implicit_mcp_kind; tool_name } ->
      (match server_isolation with
       | Single_pinned_server pinned_srv ->
         String.equal pinned_srv mcp_server_name && List.mem tool_name allowed_tool_names
       | Shared_or_multi_server -> false)
    | Managed_mcp_schema_read { mcp_server_name = srv; path } ->
      String.equal srv mcp_server_name
      && allowed_tool_names <> []
      &&
      let base = Filename.basename path in
      if String.equal base "instructions.md"
      then true
      else if Filename.check_suffix base ".json"
      then List.mem (Filename.chop_suffix base ".json") allowed_tool_names
      else false
    | Native_tool _ -> false
  in
  match policy with
  | Allow_all -> true
  | Deny_all -> false
  | Allow_masc_mcp_only { mcp_server_name; allowed_tool_names } ->
    matches_pinned ~mcp_server_name ~allowed_tool_names identity
  | Allow_read_and_masc_mcp { mcp_server_name; allowed_tool_names } ->
    matches_pinned ~mcp_server_name ~allowed_tool_names identity
    ||
    (match identity with
     | Native_tool { kind; _ } -> is_read_only_tool_kind kind
     | Mcp_tool _ | Managed_mcp_schema_read _ -> false)
;;

let is_masc_mcp_tool ~driver ~mcp_server_name ~allowed_tool_names ~title ~kind =
  let wire =
    { tool_call_id = ""
    ; title = trim_nonempty_opt (Some title)
    ; name = None
    ; kind
    ; meta_server_name = None
    ; meta_tool_name = None
    ; raw_input = None
    ; locations = []
    }
  in
  let identity = classify_tool_call ~driver ~mcp_server_name wire in
  should_allow_tool_call
    ~policy:(Allow_masc_mcp_only { mcp_server_name; allowed_tool_names })
    identity
;;

let should_allow_permission ~driver ~policy ~title ~kind =
  let mcp_server_name =
    match policy with
    | Allow_masc_mcp_only { mcp_server_name; _ }
    | Allow_read_and_masc_mcp { mcp_server_name; _ } -> Some mcp_server_name
    | Allow_all | Deny_all -> None
  in
  let wire =
    { tool_call_id = ""
    ; title = trim_nonempty_opt (Some title)
    ; name = None
    ; kind
    ; meta_server_name = None
    ; meta_tool_name = None
    ; raw_input = None
    ; locations = []
    }
  in
  let identity = classify_tool_call ~driver ?mcp_server_name wire in
  should_allow_tool_call ~policy identity
;;

let tool_call_wire_has_identity_fields (w : tool_call_wire) =
  Option.is_some w.title
  || Option.is_some w.name
  || Option.is_some w.kind
  || Option.is_some w.meta_server_name
  || Option.is_some w.meta_tool_name
  || Option.is_some w.raw_input
  || w.locations <> []
;;

let parse_session_update_with ~driver ?managed_schema_root ?mcp_server_name ?merged_wire params =
  let update =
    match json_field "update" params with
    | Some u -> u
    | None -> params
  in
  match json_string_opt "sessionUpdate" update with
  | Some "agent_message_chunk" ->
    let text =
      match json_field "content" update with
      | Some content -> json_string_opt "text" content
      | None -> json_string_opt "text" update
    in
    Option.map (fun s -> Text_delta s) text
  | Some "agent_thought_chunk" ->
    let text =
      match json_field "content" update with
      | Some content -> json_string_opt "text" content
      | None -> json_string_opt "text" update
    in
    Option.map (fun s -> Thought_delta s) text
  | Some "tool_call" ->
    let wire = Option.value merged_wire ~default:(parse_tool_call_wire update) in
    let title = Option.value wire.title ~default:"tool_call" in
    let status =
      json_string_opt "status" update
      |> Option.map parse_tool_status
      |> Option.value ~default:Tool_pending
    in
    let identity = classify_tool_call ~driver ?managed_schema_root ?mcp_server_name wire in
    Some
      (Tool_call_started
         { tool_call_id = wire.tool_call_id
         ; title
         ; kind = wire.kind
         ; status
         ; raw_input = wire.raw_input
         ; identity
         })
  | Some "tool_call_update" ->
    let wire = Option.value merged_wire ~default:(parse_tool_call_wire update) in
    let tool_call_id = wire.tool_call_id in
    let title = json_string_opt "title" update in
    let status = Option.map parse_tool_status (json_string_opt "status" update) in
    let raw_output = json_field "rawOutput" update in
    let identity =
      if tool_call_wire_has_identity_fields wire
      then Some (classify_tool_call ~driver ?managed_schema_root ?mcp_server_name wire)
      else None
    in
    Some
      (Tool_call_updated
         { tool_call_id
         ; title
         ; kind = wire.kind
         ; status
         ; raw_input = wire.raw_input
         ; raw_output
         ; identity
         })
  | Some "usage_update" ->
    let nonneg_opt = Option.map nonneg in
    let used = json_int_opt "used" update |> nonneg_opt in
    let size = json_int_opt "size" update |> nonneg_opt in
    let meta = json_field "_meta" update in
    let meta_first keys =
      Option.bind meta (fun m -> List.find_map (fun k -> json_int_opt k m) keys) |> nonneg_opt
    in
    Some
      (Usage_updated
         { used
         ; size
         ; prompt_tokens = meta_first [ "promptTokens"; "inputTokens" ]
         ; completion_tokens = meta_first [ "completionTokens"; "outputTokens" ]
         ; cached_tokens = meta_first [ "cachedTokens"; "cachedReadTokens" ]
         ; cached_write_tokens = meta_first [ "cachedWriteTokens" ]
         ; thought_tokens = meta_first [ "thoughtTokens" ]
         ; total_tokens = meta_first [ "totalTokens" ]
         })
  | Some "current_mode_update" ->
    Option.map (fun m -> Mode_updated m) (json_string_opt "currentModeId" update)
  | Some "config_option_update" ->
    Some (Config_options_updated (parse_config_options update))
  | _ -> None
;;

let parse_session_update ~driver params =
  parse_session_update_with ~driver params
;;

let parse_prompt_usage result_json =
  match json_field "usage" result_json with
  | None -> empty_usage
  | Some u ->
    let i k = Option.value (json_int_opt k u) ~default:0 |> nonneg in
    let input_tokens = i "inputTokens" in
    let output_tokens = i "outputTokens" in
    let cached_read_tokens = i "cachedReadTokens" in
    let cached_write_tokens = i "cachedWriteTokens" in
    let thought_tokens = i "thoughtTokens" in
    let total_tokens =
      match json_int_opt "totalTokens" u with
      | Some n -> nonneg n
      | None ->
        sat_add
          (sat_add (sat_add input_tokens output_tokens) (sat_add cached_read_tokens cached_write_tokens))
          thought_tokens
    in
    { input_tokens
    ; output_tokens
    ; cached_read_tokens
    ; cached_write_tokens
    ; thought_tokens
    ; total_tokens
    ; context_used = None
    ; context_size = None
    }
;;

let capability_present key json =
  match json_field key json with
  | Some (`Bool true | `Assoc _) -> true
  | Some _ | None -> false
;;

let parse_capabilities result_json =
  let caps = Option.value (json_field "agentCapabilities" result_json) ~default:(`Assoc []) in
  let prompt_caps = Option.value (json_field "promptCapabilities" caps) ~default:(`Assoc []) in
  let session_caps = Option.value (json_field "sessionCapabilities" caps) ~default:(`Assoc []) in
  let mcp_caps = Option.value (json_field "mcpCapabilities" caps) ~default:(`Assoc []) in
  let meta_agy =
    json_field "_meta" caps
    |> Option.value ~default:(`Assoc [])
    |> json_field "antigravity"
    |> Option.value ~default:(`Assoc [])
  in
  let agy_sp_append =
    json_field "systemPrompt" meta_agy
    |> Option.value ~default:(`Assoc [])
    |> json_bool_or ~default:false "append"
  in
  let agy_tier =
    json_field "_meta" result_json
    |> Option.value ~default:(`Assoc [])
    |> json_field "antigravity"
    |> Option.value ~default:(`Assoc [])
    |> json_string_opt "tier"
  in
  { load_session = json_bool_or ~default:false "loadSession" caps
  ; resume_session = capability_present "resume" session_caps
  ; close_session = capability_present "close" session_caps
  ; additional_directories = capability_present "additionalDirectories" session_caps
  ; image_prompt = json_bool_or ~default:false "image" prompt_caps
  ; embedded_context = json_bool_or ~default:false "embeddedContext" prompt_caps
  ; mcp_http = json_bool_or ~default:false "http" mcp_caps
  ; antigravity_system_prompt_append = agy_sp_append
  ; antigravity_tier = agy_tier
  }
;;

let parse_session_modes result_json =
  let modes_obj = json_field "modes" result_json in
  let current_mode_id = Option.bind modes_obj (json_string_opt "currentModeId") in
  let available_modes =
    match Option.bind modes_obj (json_list_opt "availableModes") with
    | None -> []
    | Some entries -> List.filter_map (json_string_opt "id") entries
  in
  current_mode_id, available_modes
;;

let parse_session_models result_json =
  let models_obj = json_field "models" result_json in
  let current_model_id = Option.bind models_obj (json_string_opt "currentModelId") in
  let available_models =
    match Option.bind models_obj (json_list_opt "availableModels") with
    | None -> []
    | Some entries -> List.filter_map (json_string_opt "modelId") entries
  in
  current_model_id, available_models
;;

let parse_antigravity_tier result_json =
  json_field "_meta" result_json
  |> Option.value ~default:(`Assoc [])
  |> json_field "antigravity"
  |> Option.value ~default:(`Assoc [])
  |> json_string_opt "tier"
;;

let parse_session_info result_json =
  match json_string_opt "sessionId" result_json with
  | None -> Error "session/new response missing sessionId"
  | Some session_id ->
    let current_mode_id, available_modes = parse_session_modes result_json in
    let current_model_id, available_models = parse_session_models result_json in
    let config_options = parse_config_options result_json in
    let antigravity_tier = parse_antigravity_tier result_json in
    Ok
      { session_id
      ; current_mode_id
      ; available_modes
      ; current_model_id
      ; available_models
      ; config_options
      ; antigravity_tier
      ; replayed_context_used = None
      ; replayed_context_size = None
      }
;;

let mcp_server_to_acp_json (srv : mcp_http_server) : Yojson.Safe.t =
  `Assoc
    [ "type", `String "http"
    ; "name", `String srv.name
    ; "url", `String srv.url
    ; ( "headers"
      , `List
          (List.map
             (fun (name, value) ->
                `Assoc [ "name", `String name; "value", `String value ])
             srv.headers) )
    ]
;;

let prompt_block_to_json = function
  | Text_block text -> `Assoc [ "type", `String "text"; "text", `String text ]
  | Image_block { mime_type; base64_data } ->
    `Assoc
      [ "type", `String "image"
      ; "mimeType", `String mime_type
      ; "data", `String base64_data
      ]
;;

(* ── Environment & managed Antigravity --gemini-dir preparation ───────────── *)

let env_key_of_entry entry =
  match String.index_opt entry '=' with
  | Some idx -> String.sub entry 0 idx
  | None -> entry
;;

let build_environment ~base_env ~driver ~extra_strip_env =
  let profile = profile_of_driver driver in
  let stripped =
    List.map String.trim (profile.default_strip_env @ extra_strip_env)
    |> List.filter (fun s -> s <> "")
  in
  let override_keys = List.map fst profile.env_set in
  let filtered =
    Array.to_list base_env
    |> List.filter (fun entry ->
      let key = env_key_of_entry entry in
      (not (List.mem key stripped)) && not (List.mem key override_keys))
  in
  let additions =
    List.map (fun (k, v) -> k ^ "=" ^ v) profile.env_set
  in
  Array.of_list (filtered @ additions)
;;

let write_private_file_0600 path content =
  let fd =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600
  in
  Fs_compat.write_all_and_close fd content
;;

let read_private_oauth_file ~strict_mode source_path =
  if String.trim source_path = ""
     || Filename.is_relative source_path
     || String.contains source_path '\000'
  then Error (Printf.sprintf "oauth_source %S must be a non-empty absolute path" source_path)
  else (
    try
      let euid = Unix.geteuid () in
      let lstat = Unix.lstat source_path in
      if lstat.Unix.st_kind <> Unix.S_REG
      then
        Error
          (Printf.sprintf
             "oauth_source %S must be a regular file (not symlink or special file)"
             source_path)
      else if lstat.Unix.st_uid <> euid
      then
        Error
          (Printf.sprintf
             "oauth_source %S is owned by uid %d, expected %d"
             source_path
             lstat.Unix.st_uid
             euid)
      else if strict_mode && (lstat.Unix.st_perm land 0o077) <> 0
      then
        Error
          (Printf.sprintf
             "oauth_source %S has unsafe permissions %04o (expected 0600/0400)"
             source_path
             (lstat.Unix.st_perm land 0o7777))
      else (
        let fd =
          Unix.openfile source_path [ Unix.O_RDONLY; Unix.O_CLOEXEC; Unix.O_NONBLOCK ] 0
        in
        Fun.protect
          ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
          (fun () ->
             let fstat = Unix.fstat fd in
             if fstat.Unix.st_kind <> Unix.S_REG
                || fstat.Unix.st_dev <> lstat.Unix.st_dev
                || fstat.Unix.st_ino <> lstat.Unix.st_ino
                || fstat.Unix.st_uid <> euid
                || (strict_mode && (fstat.Unix.st_perm land 0o077) <> 0)
             then
               Error
                 (Printf.sprintf
                    "oauth_source %S changed or became unsafe during open"
                    source_path)
             else (
               let buf = Buffer.create (min (max fstat.Unix.st_size 64) 65536) in
               let tmp = Bytes.create 4096 in
               let rec read_chunk () =
                 try Unix.read fd tmp 0 (Bytes.length tmp) with
                 | Unix.Unix_error (Unix.EINTR, _, _) -> read_chunk ()
               in
               let rec loop total =
                 let n = read_chunk () in
                 if n = 0
                 then Ok (Buffer.contents buf)
                 else if total + n > 1024 * 1024
                 then Error (Printf.sprintf "oauth_source %S exceeds 1 MiB limit" source_path)
                 else (
                   Buffer.add_subbytes buf tmp 0 n;
                   loop (total + n))
               in
               loop 0)))
    with
    | Unix.Unix_error (err, fn, arg) ->
      Error
        (Printf.sprintf
           "oauth_source %S unreadable (%s: %s %s)"
           source_path
           (Unix.error_message err)
           fn
           arg))
;;

let sanitize_temp_prefix raw =
  let cleaned =
    String.to_seq raw
    |> Seq.filter (function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
      | _ -> false)
    |> String.of_seq
  in
  if cleaned = "" then "acp" else cleaned
;;

let create_isolated_workspace ~sw ?(prefix = "acp") () =
  let safe = sanitize_temp_prefix prefix in
  let tag = Printf.sprintf "masc-acp-iso-%s-%d-" safe (Unix.getpid ()) in
  let* dir =
    try
      let raw_dir = Filename.temp_dir ~perms:0o700 tag "" in
      try Ok (Unix.realpath raw_dir) with
      | Unix.Unix_error (err, fn, arg) ->
        (try Fs_compat.remove_tree raw_dir with Sys_error _ | Unix.Unix_error _ -> ());
        Error
          (Invalid_config
             (Printf.sprintf
                "failed to canonicalize isolated ACP workspace (%s: %s %s)"
                (Unix.error_message err)
                fn
                arg))
    with
    | Sys_error detail ->
      Error (Invalid_config ("failed to create isolated ACP workspace: " ^ detail))
    | Unix.Unix_error (err, fn, arg) ->
      Error
        (Invalid_config
           (Printf.sprintf
              "failed to create isolated ACP workspace (%s: %s %s)"
              (Unix.error_message err)
              fn
              arg))
  in
  let cleaned = Atomic.make false in
  Eio.Switch.on_release sw (fun () ->
    if Atomic.compare_and_set cleaned false true
    then (
      try Fs_compat.remove_tree dir with
      | Sys_error _ | Unix.Unix_error _ -> ()));
  Ok dir
;;

let prepare_antigravity_gemini_dir ~oauth_source ~mcp_server ~cwd ~native_posture =
  (* PID-tag temp dir so Orphan_hygiene_sweep reaps dead-PID leftovers on boot
     while never deleting a live persistent ACP session's --gemini-dir (>24h).
     Canonicalize via [Unix.realpath] so macOS [/var] vs [/private/var] aliases
     match Antigravity's own canonicalized paths in settings and locations. *)
  let* dir =
    try
      let raw_dir =
        Filename.temp_dir ~perms:0o700 (Printf.sprintf "masc-agy-acp-%d-" (Unix.getpid ())) ""
      in
      try Ok (Unix.realpath raw_dir) with
      | Unix.Unix_error (err, fn, arg) ->
        (try Fs_compat.remove_tree raw_dir with Sys_error _ | Unix.Unix_error _ -> ());
        Error
          (Invalid_config
             (Printf.sprintf
                "failed to canonicalize Antigravity --gemini-dir (%s: %s %s)"
                (Unix.error_message err)
                fn
                arg))
    with
    | Sys_error detail ->
      Error (Invalid_config ("failed to create Antigravity --gemini-dir: " ^ detail))
    | Unix.Unix_error (err, fn, arg) ->
      Error
        (Invalid_config
           (Printf.sprintf
              "failed to create Antigravity --gemini-dir (%s: %s %s)"
              (Unix.error_message err)
              fn
              arg))
  in
  let remove_dir_best_effort () =
    try Fs_compat.remove_tree dir with
    | Sys_error _ | Unix.Unix_error _ -> ()
  in
  try
    let mcp_server_name = Option.map (fun (srv : mcp_http_server) -> srv.name) mcp_server in
    let* deny_read_roots, deny_writes_and_commands =
      match native_posture with
      | Some Runtime_native_tools.Native_none ->
        (try
           let canonical_cwd = Unix.realpath cwd in
           let stat = Unix.lstat canonical_cwd in
           if stat.Unix.st_kind <> Unix.S_DIR
           then (
             remove_dir_best_effort ();
             Error
               (Invalid_config
                  (Printf.sprintf "Native_none ACP cwd %S is not a directory" canonical_cwd)))
           else Ok ([ canonical_cwd ], true)
         with
         | Unix.Unix_error (err, fn, arg) ->
           remove_dir_best_effort ();
           Error
             (Invalid_config
                (Printf.sprintf
                   "Native_none ACP cwd %S could not be canonicalized (%s: %s %s)"
                   cwd
                   (Unix.error_message err)
                   fn
                   arg)))
      | Some Runtime_native_tools.Native_read -> Ok ([], true)
      | Some Runtime_native_tools.Native_full | None -> Ok ([], false)
    in
    (* Validate [gemini_dir], [mcp_server.name], and [deny_read_roots]
       BEFORE creating any subdirectories or writing config files. *)
    let* settings_json =
      Runtime_antigravity_policy.acp_settings_json
        ?mcp_server_name
        ~deny_read_roots
        ~deny_writes_and_commands
        ~gemini_dir:dir
        ()
      |> Result.map_error (fun err ->
        remove_dir_best_effort ();
        Invalid_config (Runtime_antigravity_policy.error_to_string err))
    in
    (* Validate and read explicit oauth_source BEFORE materializing files.
       Never silently fall back to $HOME when an explicit oauth_source is missing or unsafe. *)
    let* oauth_bytes_opt =
      match oauth_source with
      | Some source_path ->
        (match read_private_oauth_file ~strict_mode:true source_path with
         | Ok bytes -> Ok (Some bytes)
         | Error detail ->
           remove_dir_best_effort ();
           Error (Invalid_config detail))
      | None ->
        (* Keep antigravity-cli/ isolated per child so Keeper runs never mutate
           the operator's writable ~/.gemini/antigravity-cli sessions/settings
           or inherit unrelated MCP configs. Copy only the single OAuth token
           file if present on disk (macOS agy authenticates via OS Keychain). *)
        (match Sys.getenv_opt "HOME" with
         | None -> Ok None
         | Some home ->
           let token_file =
             Filename.concat home ".gemini/antigravity-cli/antigravity-oauth-token"
           in
           (match Unix.lstat token_file with
            | _ ->
              (match read_private_oauth_file ~strict_mode:false token_file with
               | Ok bytes -> Ok (Some bytes)
               | Error detail ->
                 remove_dir_best_effort ();
                 Error (Invalid_config detail))
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
            | exception Unix.Unix_error (err, fn, arg) ->
              remove_dir_best_effort ();
              Error
                (Invalid_config
                   (Printf.sprintf
                      "failed to inspect default Antigravity OAuth token (%s: %s %s)"
                      (Unix.error_message err)
                      fn
                      arg))))
    in
    let config_dir = Filename.concat dir "config" in
    Unix.mkdir config_dir 0o700;
    let agy_cli_dir = Filename.concat dir "antigravity-cli" in
    Unix.mkdir agy_cli_dir 0o700;
    let settings_path = Filename.concat agy_cli_dir "settings.json" in
    write_private_file_0600 settings_path (Yojson.Safe.pretty_to_string settings_json);
    let managed_schema_root =
      match mcp_server with
      | None -> None
      | Some (srv : mcp_http_server) ->
        (* Deliberately omit tools.<name>.eager so agy 1.5.1+ keeps every MASC
           tool on its lazy list instead of truncating past ~62 KB. *)
        let mcp_json =
          `Assoc
            [ ( "mcpServers"
              , `Assoc
                  [ ( srv.name
                    , `Assoc
                        [ "url", `String srv.url
                        ; ( "headers"
                          , `Assoc
                              (List.map (fun (k, v) -> k, `String v) srv.headers) )
                        ] )
                  ] )
            ]
        in
        let cfg_path = Filename.concat config_dir "mcp_config.json" in
        write_private_file_0600 cfg_path (Yojson.Safe.to_string mcp_json);
        let mcp_root = Filename.concat agy_cli_dir "mcp" in
        Unix.mkdir mcp_root 0o700;
        let schema_dir = Filename.concat mcp_root srv.name in
        Unix.mkdir schema_dir 0o700;
        Some (srv.name, schema_dir)
    in
    Option.iter
      (fun content ->
         let dest = Filename.concat agy_cli_dir "antigravity-oauth-token" in
         write_private_file_0600 dest content)
      oauth_bytes_opt;
    Ok (dir, managed_schema_root)
  with
  | Eio.Cancel.Cancelled _ as exn ->
    Eio.Cancel.protect remove_dir_best_effort;
    raise exn
  | exn ->
    remove_dir_best_effort ();
    Error (Invalid_config ("failed to prepare Antigravity --gemini-dir: " ^ Printexc.to_string exn))
;;

(* ── Permission policy evaluation for session/request_permission ──────────── *)

type permission_option_kind =
  | Allow_once
  | Allow_always
  | Reject_once
  | Reject_always
  | Other_option_kind of string

let parse_permission_option_kind = function
  | "allow_once" -> Allow_once
  | "allow_always" -> Allow_always
  | "reject_once" -> Reject_once
  | "reject_always" -> Reject_always
  | other -> Other_option_kind other
;;

let choose_permission_option ~allow options_json =
  let parsed =
    List.filter_map
      (fun opt ->
         match json_string_opt "optionId" opt with
         | None -> None
         | Some option_id ->
           let kind =
             json_string_opt "kind" opt
             |> Option.map parse_permission_option_kind
             |> Option.value ~default:(Other_option_kind "")
           in
           Some (option_id, kind))
      options_json
  in
  let find_kind target =
    List.find_map (fun (id, kind) -> if kind = target then Some id else None) parsed
  in
  if allow
  then find_kind Allow_once
  else (
    match find_kind Reject_once with
    | Some id -> Some id
    | None -> find_kind Reject_always)
;;

(* ── Persistent client handle & JSON-RPC multiplexing ─────────────────────── *)

type active_turn_hooks =
  { session_id : string
  ; permission_policy : permission_policy
  ; mcp_server_name : string option
  ; tool_calls_by_id : (string, tool_call_wire) Hashtbl.t
  ; on_event : stream_event -> unit
  }

type rpc_response =
  | Rpc_ok of Yojson.Safe.t
  | Rpc_err of int * string * Yojson.Safe.t option
  | Rpc_closed of string

type t =
  { driver : driver
  ; mutable capabilities : agent_capabilities
  ; mutable init_latency_ms : int
  ; managed_schema_root : (string * string) option
  ; mcp_server_name : string option
  ; mcp_server_isolation : mcp_server_isolation
  ; mutable stderr_secrets : string list
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; signal_term : unit -> unit
  ; signal_close : unit -> unit
  ; await_reaped : unit -> unit
  ; to_stdin : [ Eio.Flow.sink_ty | Eio.Resource.close_ty ] Eio.Resource.t
  ; write_mutex : Eio.Mutex.t
  ; outbound_queue : Yojson.Safe.t Eio.Stream.t
  ; outbound_queued : int Atomic.t
  ; state_mutex : Stdlib.Mutex.t
  ; mutable next_id : int
  ; pending : (int, rpc_response Eio.Promise.u) Hashtbl.t
  ; mutable active_turn : active_turn_hooks option
  ; session_observers : (string, stream_event -> unit) Hashtbl.t
  ; mutable cached_available_modes : string list
  ; mutable cached_available_models : string list
  ; mutable cached_config_options : config_option list
  ; last_activity_ns : int64 Atomic.t
  ; in_flight_external_work : int Atomic.t
  ; alive : bool Atomic.t
  ; closed : bool Atomic.t
  ; stderr_buf : Buffer.t
  ; stderr_mutex : Stdlib.Mutex.t
  }

let with_state_lock t f =
  Stdlib.Mutex.lock t.state_mutex;
  match f () with
  | v ->
    Stdlib.Mutex.unlock t.state_mutex;
    v
  | exception exn ->
    Stdlib.Mutex.unlock t.state_mutex;
    raise exn
;;

let monotonic_now_ns () = Mtime_clock.now_ns ()

let note_activity t =
  Atomic.set t.last_activity_ns (monotonic_now_ns ())
;;

let with_external_activity t f =
  note_activity t;
  Atomic.incr t.in_flight_external_work;
  Fun.protect
    ~finally:(fun () ->
      (* Stamp liveness BEFORE decrementing in-flight count so a waking
         watchdog never observes [in_flight = 0] paired with a pre-tool timestamp. *)
      note_activity t;
      Atomic.decr t.in_flight_external_work)
    f
;;

let driver t = t.driver
let mcp_server_isolation t = t.mcp_server_isolation
let capabilities t = t.capabilities
let init_latency_ms t = t.init_latency_ms
let is_alive t = Atomic.get t.alive && not (Atomic.get t.closed)

let utf8_safe_suffix ~max_bytes s =
  let len = String.length s in
  if max_bytes <= 0
  then ""
  else if len <= max_bytes
  then s
  else (
    let i = ref (len - max_bytes) in
    while !i < len && (Char.code s.[!i] land 0xC0) = 0x80 do
      incr i
    done;
    String.sub s !i (len - !i))
;;

let replace_exact_substring ~needle ~replacement haystack =
  let n_len = String.length needle in
  let h_len = String.length haystack in
  if n_len = 0 || n_len > h_len
  then haystack
  else (
    let buf = Buffer.create h_len in
    let rec loop pos =
      if pos > h_len - n_len
      then Buffer.add_substring buf haystack pos (h_len - pos)
      else if String.sub haystack pos n_len = needle
      then (
        Buffer.add_string buf replacement;
        loop (pos + n_len))
      else (
        Buffer.add_char buf haystack.[pos];
        loop (pos + 1))
    in
    loop 0;
    Buffer.contents buf)
;;

let redact_stderr_text ?(extra_secrets = []) text =
  let scrubbed =
    List.fold_left
      (fun acc secret ->
         if String.length secret >= 8
         then replace_exact_substring ~needle:secret ~replacement:"[REDACTED]" acc
         else acc)
      text
      extra_secrets
  in
  Secret_patterns.redact_text scrubbed
;;

let stderr_secrets_of_mcp_server = function
  | None -> []
  | Some (srv : mcp_http_server) ->
    let url_secrets =
      let u = String.trim srv.url in
      if String.length u >= 8 then [ u ] else []
    in
    let header_secrets =
      List.concat_map
        (fun (_k, raw_v) ->
           let v = String.trim raw_v in
           let stripped =
             if String.length v > 7
                && String.equal (String.lowercase_ascii (String.sub v 0 7)) "bearer "
             then String.trim (String.sub v 7 (String.length v - 7))
             else ""
           in
           List.filter (fun s -> String.length s >= 8) [ v; stripped ])
        srv.headers
    in
    List.sort_uniq String.compare (url_secrets @ header_secrets)
;;

let register_stderr_secrets t mcp_server =
  let fresh = stderr_secrets_of_mcp_server mcp_server in
  if fresh <> []
  then (
    Stdlib.Mutex.lock t.stderr_mutex;
    let merged =
      List.fold_left
        (fun acc s -> if List.mem s acc then acc else s :: acc)
        t.stderr_secrets
        fresh
    in
    t.stderr_secrets <- merged;
    Stdlib.Mutex.unlock t.stderr_mutex)
;;

let stderr_tail t =
  Stdlib.Mutex.lock t.stderr_mutex;
  let s = Buffer.contents t.stderr_buf in
  let secrets = t.stderr_secrets in
  Stdlib.Mutex.unlock t.stderr_mutex;
  redact_stderr_text ~extra_secrets:secrets s
;;

let append_stderr t chunk =
  Stdlib.Mutex.lock t.stderr_mutex;
  let current_len = Buffer.length t.stderr_buf in
  let chunk_len = String.length chunk in
  if current_len + chunk_len <= max_stderr_tail_bytes
  then Buffer.add_string t.stderr_buf chunk
  else (
    let combined = Buffer.contents t.stderr_buf ^ chunk in
    (* Redact BEFORE slicing so a secret straddling the ring-buffer boundary
       cannot lose its prefix and leak an unrecognized suffix. *)
    let redacted = redact_stderr_text ~extra_secrets:t.stderr_secrets combined in
    let keep = utf8_safe_suffix ~max_bytes:max_stderr_tail_bytes redacted in
    Buffer.clear t.stderr_buf;
    Buffer.add_string t.stderr_buf keep);
  Stdlib.Mutex.unlock t.stderr_mutex
;;

let send_json t json =
  let line = Yojson.Safe.to_string json ^ "\n" in
  Eio.Mutex.use_rw ~protect:true t.write_mutex (fun () ->
    if Atomic.get t.closed
    then Error Client_closed
    else (
      try
        Eio.Flow.copy_string line t.to_stdin;
        Ok ()
      with
      | (Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _) as exn -> raise exn
      | exn ->
        Atomic.set t.alive false;
        Error
          (Process_exited
             { detail = "stdin write failed: " ^ Printexc.to_string exn
             ; stderr_tail = stderr_tail t
             })))
;;

let fail_all_pending t reason =
  let waiters =
    with_state_lock t (fun () ->
      let list = Hashtbl.fold (fun _ u acc -> u :: acc) t.pending [] in
      Hashtbl.clear t.pending;
      list)
  in
  List.iter (fun u -> Eio.Promise.resolve u (Rpc_closed reason)) waiters
;;

let close_internal ~await_reap t =
  if Atomic.compare_and_set t.closed false true
  then (
    Atomic.set t.alive false;
    Eio.Cancel.protect (fun () ->
      (try Eio.Resource.close t.to_stdin with
       | Eio.Io _ | Unix.Unix_error _ | Invalid_argument _ -> ());
      (try t.signal_term () with
       | Eio.Io _ | Unix.Unix_error _ -> ());
      fail_all_pending t "client closed";
      t.signal_close ()));
  if await_reap then t.await_reaped ()
;;

let close t = close_internal ~await_reap:true t

(* Non-blocking bounded enqueue so the stdout reader daemon never blocks on
   [write_mutex]/[to_stdin] while a large [session/prompt] is writing to stdin. *)
let enqueue_outbound t json =
  if not (Atomic.get t.closed)
  then (
    let rec try_reserve () =
      let cur = Atomic.get t.outbound_queued in
      if cur >= max_outbound_queue
      then false
      else if Atomic.compare_and_set t.outbound_queued cur (cur + 1)
      then true
      else try_reserve ()
    in
    if try_reserve ()
    then Eio.Stream.add t.outbound_queue json
    else (
      Log.Runtime_agent.warn
        "ACP outbound queue saturated (%d); closing client"
        max_outbound_queue;
      close_internal ~await_reap:false t))
;;

let record_turn_tool_call_wire (turn : active_turn_hooks) (incoming : tool_call_wire) =
  if incoming.tool_call_id = ""
  then incoming
  else (
    match Hashtbl.find_opt turn.tool_calls_by_id incoming.tool_call_id with
    | Some prior ->
      let merged = merge_tool_call_wire ~prior ~incoming in
      Hashtbl.replace turn.tool_calls_by_id incoming.tool_call_id merged;
      merged
    | None ->
      if Hashtbl.length turn.tool_calls_by_id < max_tracked_tool_calls
      then Hashtbl.replace turn.tool_calls_by_id incoming.tool_call_id incoming;
      incoming)
;;

let handle_permission_request t ~id ~params =
  let req_session_id = json_string_opt "sessionId" params in
  let tool_call = Option.value (json_field "toolCall" params) ~default:(`Assoc []) in
  let incoming_wire = parse_tool_call_wire tool_call in
  let allow, effective_wire, denied_implicit_mcp =
    let matched_turn =
      with_state_lock t (fun () ->
        match t.active_turn, req_session_id with
        | Some turn, Some sid when String.equal sid turn.session_id ->
          let effective_wire = record_turn_tool_call_wire turn incoming_wire in
          Some (turn.permission_policy, turn.mcp_server_name, effective_wire)
        | _ -> None)
    in
    match matched_turn with
    | None -> false, incoming_wire, false
    | Some (policy, mcp_server_name, effective_wire) ->
      note_activity t;
      let identity =
        classify_tool_call
          ~driver:t.driver
          ?managed_schema_root:t.managed_schema_root
          ?mcp_server_name
          effective_wire
      in
      let allowed =
        should_allow_tool_call
          ~server_isolation:t.mcp_server_isolation
          ~policy
          identity
      in
      let denied_implicit =
        (not allowed)
        &&
        match identity, t.mcp_server_isolation with
        | Mcp_tool { server = Implicit_mcp_kind; _ }, Shared_or_multi_server -> true
        | Mcp_tool { server = Implicit_mcp_kind; _ }, Single_pinned_server _
        | Mcp_tool { server = Explicit_server _; _ }, (Single_pinned_server _ | Shared_or_multi_server)
        | (Managed_mcp_schema_read _ | Native_tool _), (Single_pinned_server _ | Shared_or_multi_server) ->
          false
      in
      allowed, effective_wire, denied_implicit
  in
  if not allow
  then
    Log.Runtime_agent.warn
      "ACP permission denied: driver=%s isolation=%s%s tool_call_id=%s meta_tool=%s name=%s title=%S kind=%s session_id=%s"
      (driver_to_string t.driver)
      (show_mcp_server_isolation t.mcp_server_isolation)
      (if denied_implicit_mcp then " reason=implicit_mcp_kind_unisolated" else "")
      (if effective_wire.tool_call_id <> "" then effective_wire.tool_call_id else "<none>")
      (Option.value effective_wire.meta_tool_name ~default:"<none>")
      (Option.value effective_wire.name ~default:"<none>")
      (Option.value effective_wire.title ~default:"")
      (Option.fold ~none:"<none>" ~some:tool_kind_to_string effective_wire.kind)
      (Option.value req_session_id ~default:"<none>");
  let options = Option.value (json_list_opt "options" params) ~default:[] in
  let outcome =
    match choose_permission_option ~allow options with
    | Some option_id ->
      `Assoc [ "outcome", `String "selected"; "optionId", `String option_id ]
    | None -> `Assoc [ "outcome", `String "cancelled" ]
  in
  let response =
    `Assoc [ "jsonrpc", `String "2.0"; "id", id; "result", `Assoc [ "outcome", outcome ] ]
  in
  enqueue_outbound t response
;;

let dispatch_incoming_message t msg =
  let has_method = json_string_opt "method" msg in
  let id_field = json_field "id" msg in
  match has_method, id_field with
  | None, Some (`Int id) ->
    let resolver =
      with_state_lock t (fun () ->
        let r = Hashtbl.find_opt t.pending id in
        Hashtbl.remove t.pending id;
        r)
    in
    (match resolver with
     | None -> ()
     | Some u ->
       (match json_field "error" msg with
        | Some err_obj ->
          let code = Option.value (json_int_opt "code" err_obj) ~default:(-32603) in
          let message =
            Option.value (json_string_opt "message" err_obj) ~default:"unknown RPC error"
          in
          let data =
            match json_field "data" err_obj with
            | Some `Null | None -> None
            | Some _ as d -> d
          in
          Eio.Promise.resolve u (Rpc_err (code, message, data))
        | None ->
          let result = Option.value (json_field "result" msg) ~default:`Null in
          Eio.Promise.resolve u (Rpc_ok result)))
  | Some "session/update", None ->
    let params = Option.value (json_field "params" msg) ~default:(`Assoc []) in
    let req_session_id = json_string_opt "sessionId" params in
    let update =
      match json_field "update" params with
      | Some u -> u
      | None -> params
    in
    let update_kind = json_string_opt "sessionUpdate" update in
    let active, session_observer, merged_wire =
      with_state_lock t (fun () ->
        let merged =
          match t.active_turn, req_session_id, update_kind with
          | Some turn, Some sid, Some "tool_call"
            when String.equal sid turn.session_id ->
            Some (record_turn_tool_call_wire turn (parse_tool_call_wire update))
          | Some turn, Some sid, Some "tool_call_update"
            when String.equal sid turn.session_id ->
            Some (record_turn_tool_call_wire turn (parse_tool_call_wire update))
          | _ -> None
        in
        let observer =
          Option.bind req_session_id (fun sid -> Hashtbl.find_opt t.session_observers sid)
        in
        t.active_turn, observer, merged)
    in
    let mcp_server_name =
      match active with
      | Some turn -> turn.mcp_server_name
      | None -> t.mcp_server_name
    in
    let matches_observer = Option.is_some session_observer in
    let matches_active =
      match active, req_session_id with
      | Some turn, Some sid -> String.equal sid turn.session_id
      | _ -> false
    in
    (* Refresh idle liveness on ANY session-matched [session/update] frame,
       including non-event replay frames such as [user_message_chunk], [plan],
       and [available_commands_update]. *)
    if matches_observer || matches_active then note_activity t;
    let event_opt =
      parse_session_update_with
        ~driver:t.driver
        ?managed_schema_root:t.managed_schema_root
        ?mcp_server_name
        ?merged_wire
        params
    in
    (match event_opt with
     | Some (Config_options_updated (_ :: _ as opts))
       when matches_observer || matches_active ->
       with_state_lock t (fun () -> t.cached_config_options <- opts)
     | Some
         ( Text_delta _
         | Thought_delta _
         | Tool_call_started _
         | Tool_call_updated _
         | Usage_updated _
         | Mode_updated _
         | Config_options_updated _ )
     | None -> ());
    (match session_observer, event_opt with
     | Some obs_fn, Some event ->
       (try obs_fn event with
        | (Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _) as exn ->
          raise exn
        | _ -> ())
     | Some _, None | None, (Some _ | None) -> ());
    (match event_opt, active with
     | Some event, Some turn when matches_active ->
       (try turn.on_event event with
        | (Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _) as exn ->
          raise exn
        | _ -> ())
     | _ -> ())
  | Some "session/request_permission", Some id ->
    let params = Option.value (json_field "params" msg) ~default:(`Assoc []) in
    handle_permission_request t ~id ~params
  | Some method_name, Some id ->
    (* Unknown client-bound request: answer cleanly with JSON-RPC Method Not Found. *)
    let response =
      `Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", id
        ; ( "error"
          , `Assoc
              [ "code", `Int (-32601)
              ; "message", `String ("ACP client method not supported: " ^ method_name)
              ] )
        ]
    in
    enqueue_outbound t response
  | _ -> ()
;;

let await_promise_with_idle_timeout
      ~clock
      ~stage
      ~idle_timeout_s
      ~last_activity_ns
      ~in_flight_work
      promise
  =
  let elapsed_since_last_activity_s () =
    let last = Atomic.get last_activity_ns in
    let now = monotonic_now_ns () in
    Int64.to_float (Int64.max 0L (Int64.sub now last)) /. 1e9
  in
  let rec wait () =
    match Eio.Promise.peek promise with
    | Some resp -> Ok resp
    | None ->
      let remaining =
        if Atomic.get in_flight_work > 0
        then idle_timeout_s
        else idle_timeout_s -. elapsed_since_last_activity_s ()
      in
      if remaining <= 0.0
      then (
        match Eio.Promise.peek promise with
        | Some resp -> Ok resp
        | None -> Error (Timeout { stage; timeout_s = idle_timeout_s }))
      else (
        let slice = Float.max 0.001 remaining in
        match
          Eio.Time.with_timeout clock slice (fun () -> Ok (Eio.Promise.await promise))
        with
        | Ok resp -> Ok resp
        | Error `Timeout ->
          (match Eio.Promise.peek promise with
           | Some resp -> Ok resp
           | None ->
             if Atomic.get in_flight_work > 0
             then wait ()
             else if elapsed_since_last_activity_s () >= idle_timeout_s
             then Error (Timeout { stage; timeout_s = idle_timeout_s })
             else wait ()))
  in
  wait ()
;;

let rpc_call_with_wait
      (type a)
      t
      ~(method_name : string)
      ~(params : Yojson.Safe.t)
      ~(decoder : a json_decoder)
      ~(wait : rpc_response Eio.Promise.t -> (rpc_response, error) result)
  : (a, error) result
  =
  if not (is_alive t)
  then Error Client_closed
  else (
    let promise, resolver = Eio.Promise.create () in
    let id =
      with_state_lock t (fun () ->
        let id = t.next_id in
        t.next_id <- id + 1;
        Hashtbl.replace t.pending id resolver;
        id)
    in
    let request =
      `Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", `Int id
        ; "method", `String method_name
        ; "params", params
        ]
    in
    match send_json t request with
    | Error _ as err ->
      with_state_lock t (fun () -> Hashtbl.remove t.pending id);
      err
    | Ok () ->
      let remove_pending () =
        with_state_lock t (fun () -> Hashtbl.remove t.pending id)
      in
      let* resp = Fun.protect ~finally:remove_pending (fun () -> wait promise) in
      (match resp with
       | Rpc_ok json ->
         decoder.decode json
         |> Result.map_error (fun detail -> Protocol_error { stage = method_name; detail })
       | Rpc_err (code, message, data) ->
         Error (rpc_error ~method_name ~code ~message ~data)
       | Rpc_closed reason ->
         Error (Process_exited { detail = reason; stderr_tail = stderr_tail t })))
;;

let rpc_call_decoded
      (type a)
      t
      ~(method_name : string)
      ~(params : Yojson.Safe.t)
      ~(timeout_s : float option)
      ~(decoder : a json_decoder)
  : (a, error) result
  =
  rpc_call_with_wait t ~method_name ~params ~decoder ~wait:(fun promise ->
    match timeout_s with
    | None -> Ok (Eio.Promise.await promise)
    | Some secs when (not (Float.is_finite secs)) || secs <= 0.0 -> Ok (Eio.Promise.await promise)
    | Some secs ->
      (match Eio.Time.with_timeout t.clock secs (fun () -> Ok (Eio.Promise.await promise)) with
       | Ok resp -> Ok resp
       | Error `Timeout ->
         (match Eio.Promise.peek promise with
          | Some resp -> Ok resp
          | None -> Error (Timeout { stage = method_name; timeout_s = secs }))))
;;

let send_json_bounded t ~timeout_s json =
  let line = Yojson.Safe.to_string json ^ "\n" in
  let write_result =
    Eio.Time.with_timeout t.clock timeout_s (fun () ->
      Eio.Mutex.use_rw ~protect:true t.write_mutex (fun () ->
        if Atomic.get t.closed
        then Ok (Error Client_closed)
        else (
          match
            Eio.Time.with_timeout t.clock timeout_s (fun () ->
              try
                Eio.Flow.copy_string line t.to_stdin;
                Ok (Ok ())
              with
              | (Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _) as exn ->
                raise exn
              | exn ->
                Atomic.set t.alive false;
                Ok
                  (Error
                     (Process_exited
                        { detail = "stdin write failed: " ^ Printexc.to_string exn
                        ; stderr_tail = stderr_tail t
                        })))
          with
          | Ok res -> Ok res
          | Error `Timeout -> Error `Timeout)))
  in
  match write_result with
  | Ok res -> res
  | Error `Timeout ->
    close_internal ~await_reap:false t;
    Error (Timeout { stage = "stdin_write"; timeout_s })
;;

(* Send [session/cancel] synchronously under [write_mutex] with a strict write
   bound so it is strictly ordered on stdin before any subsequent
   [session/prompt] or [close], yet cannot hang indefinitely if a wedged child
   stops draining stdin (closing the wedged client on timeout). *)
let cancel t ~session_id =
  if is_alive t
  then (
    let notif =
      `Assoc
        [ "jsonrpc", `String "2.0"
        ; "method", `String "session/cancel"
        ; "params", `Assoc [ "sessionId", `String session_id ]
        ]
    in
    ignore (send_json_bounded t ~timeout_s:cancel_write_timeout_s notif : (unit, error) result))
;;

let install_client_of_driver = function
  | Antigravity -> Runtime_official_cli_install.Antigravity
  | Kimi_code -> Runtime_official_cli_install.Kimi_code
  | Mistral_vibe -> Runtime_official_cli_install.Mistral_vibe
  | Muse_code -> Runtime_official_cli_install.Muse_code
;;

(* ── Lifecycle: spawn + initialize ────────────────────────────────────────── *)

(* muse acp 1.4.25 ends a turn with one more model run for its bundled
   reminder observers (the run's one tool is [submit_reminder_decision]). A
   Keeper already carries its own memory, goals and verification, so the host
   runs with every observer off. Measured 2026-11-24 on turns with one tool
   call (two main model requests): 5 of the 8 sessions without the six
   switches below had the run (one of the 5 named a non-existent id instead);
   the other 3 had no run and had also passed [-c approval_judge="off"] and
   [-c reasoning_effort="minimal"], which were not tried alone. None of the 8
   sessions with the switches had it. The host estimated the run's prompt at
   5.8 to 5.9k tokens, and 1.2 to 2.9 s passed from that prompt to the run's
   tool call. Which id matters was measured with the echo provider only, one
   id at a time: the run's one-tool surface appeared with the goal reminder
   on and the other five off, and did not appear with only the goal reminder
   off; the other five changed nothing there. No live session switched one id
   at a time, so the other five switches stay on that basis: no measurement
   shows they are unneeded.
   [-c runtime_capabilities.<id>] accepts any id without checking it: the
   session that named an id the host does not have kept the run and logged no
   warning, so a renamed id fails silently and the observer stays on. *)
let muse_observer_capability_ids =
  List.map
    (fun name -> "plugin:tbh-reminders:reminder:" ^ name)
    [ "memory"
    ; "skill-reminder"
    ; "verify-reminder"
    ; "goal-reminder"
    ; "todo-reminder"
    ; "scope-reminder"
    ]
;;

(* [--trust-workspace] is what makes the host connect the MCP servers that
   session/new carries; without it the session starts with none (muse acp
   1.4.25, live-verified). It also loads the workspace's own skills, rules and
   MCP servers ([.mcp.json]), which is the Keeper workspace's content: [read]
   and [full] run in the Keeper's repository, [none] in an empty isolated
   directory. A repeated [-c] key makes the host refuse to run ("one setting,
   one occurrence"), so an operator [args] must not repeat the observer keys
   below. *)
let muse_required_args =
  "--trust-workspace"
  :: List.concat_map
       (fun id -> [ "-c"; Printf.sprintf "runtime_capabilities.%s.enabled=false" id ])
       muse_observer_capability_ids
;;

(* muse acp 1.4.25 runs its read tool in every mode tried, and workspace
   writes and sandboxed shell commands in the modes tried, without a
   session/request_permission frame, so refusing permission requests cannot
   keep its native tools off. The setting [run.toolset], a JSON array of
   names, names the tools the main conversation is offered; anything not
   named is not offered (echo provider, 2026-11-24: 29 native tools by
   default, 0 with an empty array, 2 with the two names below).
   - [none]: the MCP server's tools only.
   - [read]: [read_file] and [search] (workspace file search with ripgrep
     semantics), plus the MCP server's tools. [read_file] is not confined to
     the workspace: a live session read [/etc/hosts]. No live session called
     [search]; a kind other than read, search or think in its tool_call frame
     would make the Keeper treat the call as outside [read].
   - [full]: no setting, so the host keeps its default native tools, among
     them shell, file writes, memory, cron, sub-agents, web fetch and search.
   An unstated posture takes the [none] side.
   The MCP server's tools are named by the glob [mcp__<server>__*], which
   matched every tool of a stub server whose tool names contain underscores.
   The glob also matches the tools of any server whose name starts with
   [masc__], which a trusted workspace or the operator's muse settings can
   define. A literal list would not, but the host did not accept [-], [.],
   [:] or [/] in a listed tool name (echo provider: "unknown tool"), so the
   glob stays.
   The host refuses an unknown plain name when the session starts. A name
   that matches no tool fails the first turn with "invalid run
   configuration: unknown tool"; the message gives the name, not the cause.
   The glob of a server that lists no tool, of one session/new did not carry
   and of one the host could not connect to all end this way, so a server
   that lists no tool is left out of the list. A repeated [-c run.toolset]
   makes the host refuse to run, so an operator [args] must not set it. *)
let muse_toolset_args ?mcp_server posture =
  let restricted native_tools =
    let mcp_tools =
      match mcp_server with
      | Some { name; tool_names = _ :: _; _ } -> [ Printf.sprintf "mcp__%s__*" name ]
      | Some { tool_names = []; _ } | None -> []
    in
    let names = List.map (fun tool -> `String tool) (native_tools @ mcp_tools) in
    [ "-c"; "run.toolset=" ^ Yojson.Safe.to_string (`List names) ]
  in
  match posture with
  | Some Runtime_native_tools.Native_full -> []
  | Some Runtime_native_tools.Native_read -> restricted [ "read_file"; "search" ]
  | Some Runtime_native_tools.Native_none | None -> restricted []
;;

let build_argv ?native_posture ?mcp_server (config : config) ~temp_gemini_dir =
  let profile = profile_of_driver config.driver in
  let base_args = if config.args <> [] then config.args else profile.default_args in
  match config.driver with
  | Antigravity ->
    let gemini_args =
      match temp_gemini_dir with
      | Some dir -> [ "--gemini-dir"; dir ]
      | None -> []
    in
    let allow_skip_perm =
      match native_posture with
      | Some (Runtime_native_tools.Native_none | Runtime_native_tools.Native_read) -> false
      | Some Runtime_native_tools.Native_full | None -> config.dangerously_skip_permissions
    in
    let skip_perm =
      if allow_skip_perm then [ "--dangerously-skip-permissions" ] else []
    in
    (config.cli_path :: base_args) @ gemini_args @ skip_perm
  | Kimi_code ->
    (* kimi requires global options such as --skills-dir BEFORE the `acp` subcommand.
       Under [Native_none], suppress --skills-dir so no host filesystem paths are exposed. *)
    let suppress_skills_dir =
      match native_posture with
      | Some Runtime_native_tools.Native_none -> true
      | Some (Runtime_native_tools.Native_read | Runtime_native_tools.Native_full) | None ->
        false
    in
    let pre_args =
      if profile.supports_skills_dir_flag && not suppress_skills_dir
      then
        List.concat_map
          (fun dir -> if Sys.file_exists dir then [ "--skills-dir"; dir ] else [])
          config.skills_dirs
      else []
    in
    (config.cli_path :: pre_args) @ base_args
  | Mistral_vibe -> config.cli_path :: base_args
  | Muse_code ->
    (config.cli_path :: base_args)
    @ muse_required_args
    @ muse_toolset_args ?mcp_server native_posture
;;

let foreground_process_mgr ~clock ?(grace_seconds = default_reap_grace_seconds) () =
  Posix_spawn_process_mgr.foreground_mgr ~clock ~grace_seconds
;;

let start ~sw ~proc_mgr ~clock ?fs ~(config : config) ?mcp_server ?native_posture () =
  let profile = profile_of_driver config.driver in
  if String.trim config.cli_path = ""
  then Error (Invalid_config "cli_path must be non-empty")
  else if String.trim config.cwd = ""
  then Error (Invalid_config "cwd must be non-empty")
  else if config.driver = Muse_code && Option.is_some config.oauth_source
  then Error (Invalid_config "ACP driver muse_code requires host sign-in with the credential file binding unset")
  else (
    let* temp_gemini_dir, managed_schema_root =
      match profile.mcp_wiring with
      | Gemini_dir_mcp_config ->
        Result.map
          (fun (dir, schema_root) -> Some dir, schema_root)
          (prepare_antigravity_gemini_dir
             ~oauth_source:config.oauth_source
             ~mcp_server
             ~cwd:config.cwd
             ~native_posture)
      | Session_new_http_mcp -> Ok (None, None)
    in
    let mcp_server_name = Option.map (fun (srv : mcp_http_server) -> srv.name) mcp_server in
    let stderr_secrets = stderr_secrets_of_mcp_server mcp_server in
    let gemini_dir_cleaned = Atomic.make false in
    let cleanup_gemini_dir () =
      if Atomic.compare_and_set gemini_dir_cleaned false true
      then
        Option.iter
          (fun dir ->
             try Fs_compat.remove_tree dir with
             | Sys_error _ | Unix.Unix_error _ -> ())
          temp_gemini_dir
    in
    Eio.Switch.on_release sw cleanup_gemini_dir;
    let env =
      build_environment
        ~base_env:(Unix.environment ())
        ~driver:config.driver
        ~extra_strip_env:config.strip_env
    in
    let resolved_cli_path =
      Runtime_official_cli_install.spawn_path
        (install_client_of_driver config.driver)
        ~command:config.cli_path
    in
    let argv =
      build_argv
        ?native_posture
        ?mcp_server
        { config with cli_path = resolved_cli_path }
        ~temp_gemini_dir
    in
    let* cwd_path =
      let resolved =
        match fs with
        | Some fs_root -> Some Eio.Path.(fs_root / config.cwd)
        | None ->
          (match Eio_context.get_env_opt () with
           | Some eio_env -> Some Eio.Path.(Eio.Stdenv.fs eio_env / config.cwd)
           | None ->
             Option.map (fun fs_root -> Eio.Path.(fs_root / config.cwd)) (Fs_compat.get_fs_opt ()))
      in
      match resolved, native_posture with
      | None, Some Runtime_native_tools.Native_none ->
        cleanup_gemini_dir ();
        Error
          (Invalid_config
             "Native_none ACP isolation requires ~fs or an initialized Eio filesystem to bind child cwd")
      | None, (Some (Runtime_native_tools.Native_read | Runtime_native_tools.Native_full) | None)
      | Some _, (Some _ | None) -> Ok resolved
    in
    let started_at = Time_compat.now () in
    let close_promise, resolve_close = Eio.Promise.create () in
    let close_signalled = Atomic.make false in
    let signal_close () =
      if Atomic.compare_and_set close_signalled false true
      then Eio.Promise.resolve resolve_close ()
    in
    let reaped_promise, resolve_reaped = Eio.Promise.create () in
    let mark_reaped () =
      ignore (Eio.Promise.try_resolve resolve_reaped () : bool)
    in
    let await_reaped () =
      match Eio.Promise.peek reaped_promise with
      | Some () -> ()
      | None ->
        Eio.Cancel.protect (fun () ->
          match
            Eio.Time.with_timeout clock (default_reap_grace_seconds +. 1.0) (fun () ->
              Eio.Promise.await reaped_promise;
              Ok ())
          with
          | Ok () | Error `Timeout -> ())
    in
    let spawned_promise, resolve_spawned = Eio.Promise.create () in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Fun.protect ~finally:mark_reaped (fun () ->
        try
          Eio.Switch.run (fun child_sw ->
            Eio.Switch.on_release child_sw cleanup_gemini_dir;
            if Atomic.get close_signalled
            then (
              match Eio.Promise.peek spawned_promise with
              | None -> Eio.Promise.resolve resolve_spawned (Error Client_closed)
              | Some _ -> ())
            else (
              match Process_eio.spawn_piped_child ~sw:child_sw proc_mgr ?cwd:cwd_path ~env argv with
              | Error refusal ->
                Eio.Promise.resolve resolve_spawned (Error (Spawn_refused refusal))
              | Ok { Process_eio.process; to_stdin; from_stdout; from_stderr } ->
                let signal_term () =
                  try Eio.Process.signal process Sys.sigterm with
                  | Eio.Io _ | Unix.Unix_error _ -> ()
                in
                let mcp_server_isolation =
                  match (profile_of_driver config.driver).mcp_wiring, managed_schema_root with
                  | Gemini_dir_mcp_config, Some (pinned_srv, _) -> Single_pinned_server pinned_srv
                  | Gemini_dir_mcp_config, None | Session_new_http_mcp, _ -> Shared_or_multi_server
                in
                let t =
                  { driver = config.driver
                  ; capabilities =
                      { load_session = false
                      ; resume_session = false
                      ; close_session = false
                      ; additional_directories = false
                      ; image_prompt = false
                      ; embedded_context = false
                      ; mcp_http = false
                      ; antigravity_system_prompt_append = false
                      ; antigravity_tier = None
                      }
                  ; init_latency_ms = 0
                  ; managed_schema_root
                  ; mcp_server_name
                  ; mcp_server_isolation
                  ; stderr_secrets
                  ; clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t)
                  ; signal_term
                  ; signal_close
                  ; await_reaped
                  ; to_stdin
                  ; write_mutex = Eio.Mutex.create ()
                  ; outbound_queue = Eio.Stream.create max_int
                  ; outbound_queued = Atomic.make 0
                  ; state_mutex = Stdlib.Mutex.create ()
                  ; next_id = 1
                  ; pending = Hashtbl.create 16
                  ; active_turn = None
                  ; session_observers = Hashtbl.create 4
                  ; cached_available_modes = []
                  ; cached_available_models = []
                  ; cached_config_options = []
                  ; last_activity_ns = Atomic.make (monotonic_now_ns ())
                  ; in_flight_external_work = Atomic.make 0
                  ; alive = Atomic.make true
                  ; closed = Atomic.make false
                  ; stderr_buf = Buffer.create 512
                  ; stderr_mutex = Stdlib.Mutex.create ()
                  }
                in
                Eio.Switch.on_release child_sw (fun () -> close_internal ~await_reap:false t);
                (* Dedicated outbound writer daemon decouples stdout-reader replies
                   (permission responses, unknown-method errors, cancel) from stdin writes. *)
                Eio.Fiber.fork_daemon ~sw:child_sw (fun () ->
                  (try
                     let rec loop () =
                       let json = Eio.Stream.take t.outbound_queue in
                       Atomic.decr t.outbound_queued;
                       match send_json t json with
                       | Ok () -> loop ()
                       | Error _ -> ()
                     in
                     loop ()
                   with
                   | Eio.Cancel.Cancelled _ as exn -> raise exn);
                  `Stop_daemon);
                (* Background stderr drain daemon *)
                Eio.Fiber.fork_daemon ~sw:child_sw (fun () ->
                  (try
                     let buf = Cstruct.create 4096 in
                     let rec loop () =
                       match Eio.Flow.single_read from_stderr buf with
                       | n when n > 0 ->
                         append_stderr t (Cstruct.to_string ~len:n buf);
                         loop ()
                       | _ -> ()
                       | exception End_of_file -> ()
                     in
                     loop ()
                   with
                   | Eio.Cancel.Cancelled _ as exn -> raise exn
                   | Eio.Io _ | Unix.Unix_error _ -> ());
                  `Stop_daemon);
                (* Background NDJSON stdout reader daemon *)
                Eio.Fiber.fork_daemon ~sw:child_sw (fun () ->
                  (try
                     let reader = Eio.Buf_read.of_flow ~max_size:max_ndjson_line_bytes from_stdout in
                     let rec loop () =
                       match Eio.Buf_read.line reader with
                       | line ->
                         let trimmed = String.trim line in
                         if trimmed <> ""
                         then (
                           match Yojson.Safe.from_string trimmed with
                           | msg -> dispatch_incoming_message t msg
                           | exception (Yojson.Json_error _ | Failure _) -> ());
                         loop ()
                       | exception End_of_file ->
                         Atomic.set t.alive false;
                         fail_all_pending t "stdout EOF";
                         signal_close ()
                     in
                     loop ()
                   with
                   | (Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _) as exn ->
                     raise exn
                   | exn ->
                     Atomic.set t.alive false;
                     fail_all_pending t ("stdout reader failed: " ^ Printexc.to_string exn);
                     signal_close ());
                  `Stop_daemon);
                Eio.Promise.resolve resolve_spawned (Ok t);
                Eio.Promise.await close_promise))
        with
        | (Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _) as exn ->
          (match Eio.Promise.peek spawned_promise with
           | None -> Eio.Promise.resolve resolve_spawned (Error Client_closed)
           | Some _ -> ());
          raise exn
        | exn ->
          (match Eio.Promise.peek spawned_promise with
           | None ->
             Eio.Promise.resolve
               resolve_spawned
               (Error (Protocol_error { stage = "spawn"; detail = Printexc.to_string exn }))
           | Some _ -> ()));
      `Stop_daemon);
    let* t =
      try Eio.Promise.await spawned_promise with
      | Eio.Cancel.Cancelled _ as exn ->
        Eio.Cancel.protect (fun () ->
          signal_close ();
          match Eio.Promise.peek spawned_promise with
          | Some (Ok t) -> close t
          | Some (Error _) | None ->
            await_reaped ();
            cleanup_gemini_dir ());
        raise exn
    in
    let init_params =
      `Assoc
        [ "protocolVersion", `Int protocol_version
        ; "clientCapabilities", `Assoc []
        ; ( "clientInfo"
          , `Assoc
              [ "name", `String "masc"
              ; "version", `String Build_version.current
              ] )
        ]
    in
    let init_decoder = { decode = (fun json -> Ok (parse_capabilities json)) } in
    let init_result =
      try
        rpc_call_decoded
          t
          ~method_name:"initialize"
          ~params:init_params
          ~timeout_s:(Some config.admission_timeout_s)
          ~decoder:init_decoder
      with
      | Eio.Cancel.Cancelled _ as exn ->
        Eio.Cancel.protect (fun () -> close t);
        raise exn
    in
    match init_result with
    | Error _ as err ->
      close t;
      err
    | Ok caps ->
      let init_ms =
        Int.of_float (Float.max 0.0 ((Time_compat.now () -. started_at) *. 1000.0))
      in
      t.capabilities <- caps;
      t.init_latency_ms <- init_ms;
      Ok t)
;;

(* ── Session lifecycle RPCs ───────────────────────────────────────────────── *)

let set_mode t ~session_id ~mode_id =
  let params = `Assoc [ "sessionId", `String session_id; "modeId", `String mode_id ] in
  rpc_call_decoded
    t
    ~method_name:"session/set_mode"
    ~params
    ~timeout_s:(Some init_timeout_s)
    ~decoder:{ decode = (fun _ -> Ok ()) }
;;

let set_model t ~session_id ~model_id =
  let params = `Assoc [ "sessionId", `String session_id; "modelId", `String model_id ] in
  rpc_call_decoded
    t
    ~method_name:"session/set_model"
    ~params
    ~timeout_s:(Some init_timeout_s)
    ~decoder:{ decode = (fun _ -> Ok ()) }
;;

let set_config_option t ~session_id ~config_id ~value =
  let params =
    `Assoc
      [ "sessionId", `String session_id
      ; "configId", `String config_id
      ; "value", `String value
      ]
  in
  rpc_call_decoded
    t
    ~method_name:"session/set_config_option"
    ~params
    ~timeout_s:(Some init_timeout_s)
    ~decoder:{ decode = (fun json -> Ok (parse_config_options json)) }
;;

let close_session ?(timeout_s = init_timeout_s) t ~session_id =
  let params = `Assoc [ "sessionId", `String session_id ] in
  rpc_call_decoded
    t
    ~method_name:"session/close"
    ~params
    ~timeout_s:(Some timeout_s)
    ~decoder:{ decode = (fun _ -> Ok ()) }
;;

let with_session_observer t ~session_id ~on_event f =
  with_state_lock t (fun () -> Hashtbl.replace t.session_observers session_id on_event);
  Fun.protect
    ~finally:(fun () -> with_state_lock t (fun () -> Hashtbl.remove t.session_observers session_id))
    f
;;

let merge_with_cached_session_catalog t (info : session_info) : session_info =
  with_state_lock t (fun () ->
    if info.available_modes <> [] then t.cached_available_modes <- info.available_modes;
    if info.available_models <> [] then t.cached_available_models <- info.available_models;
    if info.config_options <> [] then t.cached_config_options <- info.config_options;
    (* When a driver returns empty [configOptions] (e.g. [{}] on [session/load] or
       [session/resume]), reuse cached option schemas/allowed values ONLY while
       clearing [current_value] so a prior session's active value never causes
       [apply_session_options] to silently skip [session/set_config_option]. *)
    let config_options =
      if info.config_options <> []
      then info.config_options
      else
        List.map
          (fun (opt : config_option) -> { opt with current_value = "" })
          t.cached_config_options
    in
    { info with
      available_modes =
        if info.available_modes <> [] then info.available_modes else t.cached_available_modes
    ; available_models =
        if info.available_models <> [] then info.available_models else t.cached_available_models
    ; config_options
    })
;;

let is_effort_category = function
  | Some ("thought_level" | "thinking") -> true
  | Some _ | None -> false
;;

let parse_wire_effort ~driver (raw : string) : Llm_provider.Reasoning_effort.t option =
  effort_of_driver_string ~driver raw
;;

let preferred_wire_value_of_effort ~driver (effort : Llm_provider.Reasoning_effort.t) : string =
  let module E = Llm_provider.Reasoning_effort in
  match driver with
  | Antigravity | Kimi_code | Muse_code -> E.to_string effort
  | Mistral_vibe ->
    (match effort with
     | E.None_ -> "off"
     | E.Minimal | E.Low | E.Medium | E.High | E.XHigh | E.Max | E.Ultra ->
       E.to_string effort)
;;

let resolve_model_option_value ~driver ~(requested : model_selection) ~(option : config_option) =
  match requested with
  | Keep_cli_default -> None
  | Explicit_model raw ->
    let trimmed = String.trim raw in
    if trimmed = ""
    then None
    else (
      let candidate =
        match option.available_values with
        | [] -> Some trimmed
        | available when List.mem trimmed available -> Some trimmed
        | available ->
          Log.Runtime_agent.warn
            "skipping unsupported ACP config option %s=%S for %s (available: [%s])"
            option.id
            trimmed
            (driver_to_string driver)
            (String.concat ", " available);
          None
      in
      match candidate with
      | Some value when not (String.equal value option.current_value) -> Some value
      | Some _ | None -> None)
;;

(* Clamp a typed {!Llm_provider.Reasoning_effort.t} against the CLI's advertised
   [available_values] using {!Llm_provider.Reasoning_effort.compare} / [rank].
   Never silently upgrades upward (e.g. Low -> Medium/High) and never silently
   disables thinking (positive effort -> None_/off); if no matching effort <=
   requested exists, logs a warning and returns [None] so the CLI keeps its
   active default. *)
let resolve_effort_option_value_with
      ~force_when_current_stale
      ~driver
      ~(requested : Llm_provider.Reasoning_effort.t)
      ~(option : config_option)
  =
  let module E = Llm_provider.Reasoning_effort in
  let candidate =
    match option.available_values with
    | [] -> Some (preferred_wire_value_of_effort ~driver requested)
    | available ->
      let parsed_rev, unrecognized_rev =
        List.fold_left
          (fun (ok_acc, bad_acc) wire ->
             match parse_wire_effort ~driver wire with
             | Some eff -> (eff, wire) :: ok_acc, bad_acc
             | None -> ok_acc, wire :: bad_acc)
          ([], [])
          available
      in
      let parsed = List.rev parsed_rev in
      let unrecognized = List.rev unrecognized_rev in
      if unrecognized <> []
      then
        Log.Runtime_agent.warn
          "ignoring unrecognized advertised ACP effort values [%s] on %s option %s"
          (String.concat ", " unrecognized)
          (driver_to_string driver)
          option.id;
      let exact_matches =
        List.filter_map
          (fun (eff, wire) -> if E.equal eff requested then Some wire else None)
          parsed
      in
      (match exact_matches with
       | first :: _ ->
         if List.mem option.current_value exact_matches
         then Some option.current_value
         else (
           let preferred = preferred_wire_value_of_effort ~driver requested in
           if List.mem preferred exact_matches then Some preferred else Some first)
       | [] ->
         if E.rank requested = 0
         then (
           Log.Runtime_agent.warn
             "skipping ACP effort %s on %s option %s (no %S value advertised in [%s])"
             (E.to_string requested)
             (driver_to_string driver)
             option.id
             (preferred_wire_value_of_effort ~driver requested)
             (String.concat ", " available);
           None)
         else (
           let below_positive =
             List.filter
               (fun (eff, _) -> E.rank eff > 0 && E.compare eff requested <= 0)
               parsed
           in
           match below_positive with
           | [] ->
             Log.Runtime_agent.warn
               "skipping ACP effort %s on %s option %s (no advertised positive effort <= requested in [%s]; keeping CLI default)"
               (E.to_string requested)
               (driver_to_string driver)
               option.id
               (String.concat ", " available);
             None
           | first :: rest ->
             let _, wire =
               List.fold_left
                 (fun ((best_eff, _) as best) ((cand_eff, _) as cand) ->
                    if E.compare cand_eff best_eff > 0 then cand else best)
                 first
                 rest
             in
             Some wire))
  in
  match candidate with
  | Some value
    when force_when_current_stale || not (String.equal value option.current_value) ->
    Some value
  | Some _ | None -> None
;;

let resolve_effort_option_value ~driver ~requested ~option =
  resolve_effort_option_value_with
    ~force_when_current_stale:false
    ~driver
    ~requested
    ~option
;;

let apply_session_options
      t
      (info : session_info)
      ~mode
      ~(model : model_selection option)
      ~(effort : Llm_provider.Reasoning_effort.t option)
  =
  let profile = profile_of_driver t.driver in
  let* current_mode_id =
    match mode with
    | None -> Ok info.current_mode_id
    | Some raw_desired ->
      let desired = String.trim raw_desired in
      if desired = ""
      then Ok info.current_mode_id
      else if Option.equal String.equal info.current_mode_id (Some desired)
      then Ok info.current_mode_id
      else if info.available_modes = [] || List.mem desired info.available_modes
      then
        let* () = set_mode t ~session_id:info.session_id ~mode_id:desired in
        Ok (Some desired)
      else
        Error
          (Protocol_error
             { stage = "session/set_mode"
             ; detail =
                 Printf.sprintf
                   "requested ACP mode %S is not advertised by %s (available: [%s])"
                   desired
                   (driver_to_string t.driver)
                   (String.concat ", " info.available_modes)
             })
  in
  let find_option options opt_id =
    List.find_opt (fun (opt : config_option) -> String.equal opt.id opt_id) options
  in
  let find_model_option options =
    match find_option options profile.model_config_id with
    | Some _ as found -> found
    | None ->
      List.find_opt
        (fun (opt : config_option) ->
           Option.equal String.equal opt.category (Some "model"))
        options
  in
  let update_option_current_value options ~config_id ~value =
    List.map
      (fun (opt : config_option) ->
         if String.equal opt.id config_id then { opt with current_value = value } else opt)
      options
  in
  let* current_model_id, config_options, effort_current_stale =
    match model with
    | None | Some Keep_cli_default -> Ok (info.current_model_id, info.config_options, false)
    | Some (Explicit_model raw_model) ->
      let m = String.trim raw_model in
      if m = ""
      then Ok (info.current_model_id, info.config_options, false)
      else if List.mem m info.available_models
      then (
        (* Protocol-level ACP [models.availableModels] selection via
           [session/set_model] (supports effort-qualified model IDs without
           parsing model names). *)
        if Option.equal String.equal info.current_model_id (Some m)
        then Ok (info.current_model_id, info.config_options, false)
        else (
          let observed_config_options = Atomic.make None in
          let* () =
            with_session_observer
              t
              ~session_id:info.session_id
              ~on_event:(function
                | Config_options_updated opts ->
                  Atomic.set observed_config_options (Some opts)
                | Text_delta _
                | Thought_delta _
                | Tool_call_started _
                | Tool_call_updated _
                | Usage_updated _
                | Mode_updated _ -> ())
              (fun () -> set_model t ~session_id:info.session_id ~model_id:m)
          in
          match Atomic.get observed_config_options with
          | Some (_ :: _ as updated) -> Ok (Some m, updated, false)
          | Some [] | None -> Ok (Some m, info.config_options, true)))
      else (
        match find_model_option info.config_options with
        | Some option ->
          (match
             resolve_model_option_value
               ~driver:t.driver
               ~requested:(Explicit_model m)
               ~option
           with
           | Some value ->
             let* updated =
               set_config_option
                 t
                 ~session_id:info.session_id
                 ~config_id:option.id
                 ~value
             in
             (match updated with
              | _ :: _ -> Ok (Some value, updated, false)
              | [] ->
                Ok
                  ( Some value
                  , update_option_current_value info.config_options ~config_id:option.id ~value
                  , true ))
           | None -> Ok (info.current_model_id, info.config_options, false))
        | None ->
          if info.available_models <> []
          then
            Log.Runtime_agent.warn
              "skipping unsupported ACP model %S for %s (availableModels: [%s])"
              m
              (driver_to_string t.driver)
              (String.concat ", " info.available_models);
          Ok (info.current_model_id, info.config_options, false))
  in
  let* config_options =
    match effort with
    | Some eff ->
      let effort_opt =
        match Option.bind profile.effort_config_id (find_option config_options) with
        | Some _ as found -> found
        | None ->
          List.find_opt
            (fun (opt : config_option) -> is_effort_category opt.category)
            config_options
      in
      (match effort_opt with
       | Some option ->
         (match
            resolve_effort_option_value_with
              ~force_when_current_stale:effort_current_stale
              ~driver:t.driver
              ~requested:eff
              ~option
          with
          | Some value ->
            let* updated =
              set_config_option t ~session_id:info.session_id ~config_id:option.id ~value
            in
            (match updated with
             | _ :: _ -> Ok updated
             | [] -> Ok (update_option_current_value config_options ~config_id:option.id ~value))
          | None -> Ok config_options)
       | None -> Ok config_options)
    | None -> Ok config_options
  in
  if config_options <> []
  then with_state_lock t (fun () -> t.cached_config_options <- config_options);
  Ok { info with current_mode_id; current_model_id; config_options }
;;

let check_requested_effort t effort =
  validate_session_effort ~driver:t.driver effort
  |> Result.map_error (fun detail -> Invalid_config detail)
;;

let reconfigure_session t info ?mode ?model ?effort () =
  let* () = check_requested_effort t effort in
  let merged = merge_with_cached_session_catalog t info in
  apply_session_options t merged ~mode ~model ~effort
;;

let mcp_servers_param_for_driver driver mcp_server =
  let profile = profile_of_driver driver in
  match profile.mcp_wiring, mcp_server with
  | Session_new_http_mcp, Some srv -> `List [ mcp_server_to_acp_json srv ]
  | Session_new_http_mcp, None -> `List []
  | Gemini_dir_mcp_config, _ -> `List []
;;

let extra_dir_fields_for_client t additional_directories =
  match additional_directories with
  | _ :: _ as dirs when t.capabilities.additional_directories || t.driver = Mistral_vibe ->
    let existing = List.filter (fun d -> String.trim d <> "" && Sys.file_exists d) dirs in
    if existing = []
    then []
    else [ "additionalDirectories", `List (List.map (fun d -> `String d) existing) ]
  | _ -> []
;;

let new_session
      t
      ~cwd
      ?system_prompt_append
      ?mcp_server
      ?(additional_directories = [])
      ?mode
      ?model
      ?effort
      ()
  =
  let* () = check_requested_effort t effort in
  register_stderr_secrets t mcp_server;
  let profile = profile_of_driver t.driver in
  let meta_fields =
    match profile.system_prompt_channel, system_prompt_append with
    | Meta_antigravity_append, Some sp when String.trim sp <> "" ->
      [ ( "_meta"
        , `Assoc
            [ ( "antigravity"
              , `Assoc [ "systemPrompt", `Assoc [ "append", `String sp ] ] )
            ] )
      ]
    | Meta_antigravity_append, (Some _ | None)
    | Framed_in_first_prompt, (Some _ | None) -> []
  in
  let extra_dir_fields = extra_dir_fields_for_client t additional_directories in
  let params =
    `Assoc
      ([ "cwd", `String cwd
       ; "mcpServers", mcp_servers_param_for_driver t.driver mcp_server
       ]
       @ extra_dir_fields
       @ meta_fields)
  in
  let* info =
    rpc_call_decoded
      t
      ~method_name:"session/new"
      ~params
      ~timeout_s:(Some init_timeout_s)
      ~decoder:{ decode = parse_session_info }
  in
  let merged = merge_with_cached_session_catalog t info in
  apply_session_options t merged ~mode ~model ~effort
;;

let fallback_session_info ~session_id json =
  let current_mode_id, available_modes = parse_session_modes json in
  let current_model_id, available_models = parse_session_models json in
  { session_id
  ; current_mode_id
  ; available_modes
  ; current_model_id
  ; available_models
  ; config_options = parse_config_options json
  ; antigravity_tier = parse_antigravity_tier json
  ; replayed_context_used = None
  ; replayed_context_size = None
  }
;;

let attach_existing_session
      t
      ~method_name
      ~use_idle_liveness
      ~session_id
      ~cwd
      ?mcp_server
      ?(additional_directories = [])
      ?mode
      ?model
      ?effort
      ()
  =
  let* () = check_requested_effort t effort in
  register_stderr_secrets t mcp_server;
  let extra_dir_fields = extra_dir_fields_for_client t additional_directories in
  let params =
    `Assoc
      ([ "sessionId", `String session_id
       ; "cwd", `String cwd
       ; "mcpServers", mcp_servers_param_for_driver t.driver mcp_server
       ]
       @ extra_dir_fields)
  in
  let replayed_mode = Atomic.make None in
  let replayed_config_options = Atomic.make None in
  let replayed_used = Atomic.make None in
  let replayed_size = Atomic.make None in
  let on_replay_event = function
    | Mode_updated m -> Atomic.set replayed_mode (Some m)
    | Config_options_updated (_ :: _ as opts) ->
      Atomic.set replayed_config_options (Some opts)
    | Usage_updated { used; size; _ } ->
      (match used with Some _ as u -> Atomic.set replayed_used u | None -> ());
      (match size with Some _ as s -> Atomic.set replayed_size s | None -> ())
    | Text_delta _
    | Thought_delta _
    | Tool_call_started _
    | Tool_call_updated _
    | Config_options_updated [] -> ()
  in
  let decoder =
    { decode =
        (fun json ->
           match parse_session_info json with
           | Ok info -> Ok info
           | Error _ -> Ok (fallback_session_info ~session_id json))
    }
  in
  note_activity t;
  let* raw_info =
    with_session_observer t ~session_id ~on_event:on_replay_event (fun () ->
      if use_idle_liveness
      then
        rpc_call_with_wait t ~method_name ~params ~decoder ~wait:(fun promise ->
          await_promise_with_idle_timeout
            ~clock:t.clock
            ~stage:method_name
            ~idle_timeout_s:init_timeout_s
            ~last_activity_ns:t.last_activity_ns
            ~in_flight_work:t.in_flight_external_work
            promise)
      else
        rpc_call_decoded t ~method_name ~params ~timeout_s:(Some init_timeout_s) ~decoder)
  in
  let with_replay =
    { raw_info with
      current_mode_id =
        (match raw_info.current_mode_id with
         | Some _ as m -> m
         | None -> Atomic.get replayed_mode)
    ; config_options =
        (match raw_info.config_options, Atomic.get replayed_config_options with
         | _ :: _, _ -> raw_info.config_options
         | [], Some opts -> opts
         | [], None -> [])
    ; replayed_context_used = Atomic.get replayed_used
    ; replayed_context_size = Atomic.get replayed_size
    }
  in
  let merged = merge_with_cached_session_catalog t with_replay in
  apply_session_options t merged ~mode ~model ~effort
;;

let load_session
      t
      ~session_id
      ~cwd
      ?mcp_server
      ?(additional_directories = [])
      ?mode
      ?model
      ?effort
      ()
  =
  attach_existing_session
    t
    ~method_name:"session/load"
    ~use_idle_liveness:true
    ~session_id
    ~cwd
    ?mcp_server
    ~additional_directories
    ?mode
    ?model
    ?effort
    ()
;;

let resume_session
      t
      ~session_id
      ~cwd
      ?mcp_server
      ?(additional_directories = [])
      ?mode
      ?model
      ?effort
      ()
  =
  attach_existing_session
    t
    ~method_name:"session/resume"
    ~use_idle_liveness:false
    ~session_id
    ~cwd
    ?mcp_server
    ~additional_directories
    ?mode
    ?model
    ?effort
    ()
;;

(* ── Prompt execution with streaming & cancellation ───────────────────────── *)

let prompt
      t
      ~session_id
      ~blocks
      ?(timeout_s = Some default_timeout_s)
      ?(permission_policy = Allow_all)
      ?(on_event = ignore)
      ()
  =
  let* () = validate_prompt_blocks ~driver:t.driver ~capabilities:t.capabilities blocks in
  let started_at = Time_compat.now () in
  let text_buf = Buffer.create 1024 in
  let thought_buf = Buffer.create 512 in
  let tool_calls = ref 0 in
  let last_context_used = ref None in
  let last_context_size = ref None in
  let streamed_usage = ref empty_usage in
  let append_bounded buf s =
    let remaining = max_prompt_stream_bytes - Buffer.length buf in
    if remaining > 0
    then (
      let len = min (String.length s) remaining in
      if len > 0 then Buffer.add_substring buf s 0 len)
  in
  let handle_event event =
    (match event with
     | Text_delta s -> append_bounded text_buf s
     | Thought_delta s -> append_bounded thought_buf s
     | Tool_call_started _ -> incr tool_calls
     | Tool_call_updated _ | Mode_updated _ | Config_options_updated _ -> ()
     | Usage_updated
         { used
         ; size
         ; prompt_tokens
         ; completion_tokens
         ; cached_tokens
         ; cached_write_tokens
         ; thought_tokens
         ; total_tokens
         } ->
       (match used with Some _ as u -> last_context_used := u | None -> ());
       (match size with Some _ as s -> last_context_size := s | None -> ());
       let prev = !streamed_usage in
       streamed_usage :=
         { input_tokens = Option.value prompt_tokens ~default:prev.input_tokens
         ; output_tokens = Option.value completion_tokens ~default:prev.output_tokens
         ; cached_read_tokens = Option.value cached_tokens ~default:prev.cached_read_tokens
         ; cached_write_tokens =
             Option.value cached_write_tokens ~default:prev.cached_write_tokens
         ; thought_tokens = Option.value thought_tokens ~default:prev.thought_tokens
         ; total_tokens = Option.value total_tokens ~default:prev.total_tokens
         ; context_used = !last_context_used
         ; context_size = !last_context_size
         });
    on_event event
  in
  let turn_mcp_server_name =
    match permission_policy with
    | Allow_masc_mcp_only { mcp_server_name; _ }
    | Allow_read_and_masc_mcp { mcp_server_name; _ } -> Some mcp_server_name
    | Allow_all | Deny_all -> t.mcp_server_name
  in
  note_activity t;
  with_state_lock t (fun () ->
    t.active_turn <-
      Some
        { session_id
        ; permission_policy
        ; mcp_server_name = turn_mcp_server_name
        ; tool_calls_by_id = Hashtbl.create 16
        ; on_event = handle_event
        });
  let clear_active_turn () =
    with_state_lock t (fun () -> t.active_turn <- None)
  in
  let params =
    `Assoc
      [ "sessionId", `String session_id
      ; "prompt", `List (List.map prompt_block_to_json blocks)
      ]
  in
  let decoder =
    { decode =
        (fun json ->
           let stop_reason =
             json_string_opt "stopReason" json
             |> Option.map parse_stop_reason
             |> Option.value ~default:End_turn
           in
           let raw_usage = parse_prompt_usage json in
           let merged_usage =
             if raw_usage.total_tokens > 0
                || raw_usage.input_tokens > 0
                || raw_usage.output_tokens > 0
             then
               { raw_usage with
                 context_used = !last_context_used
               ; context_size = !last_context_size
               }
             else
               { !streamed_usage with
                 context_used = !last_context_used
               ; context_size = !last_context_size
               }
           in
           Ok (stop_reason, merged_usage))
    }
  in
  let wait_prompt promise =
    match timeout_s with
    | None -> Ok (Eio.Promise.await promise)
    | Some secs when (not (Float.is_finite secs)) || secs <= 0.0 -> Ok (Eio.Promise.await promise)
    | Some secs ->
      await_promise_with_idle_timeout
        ~clock:t.clock
        ~stage:"session/prompt"
        ~idle_timeout_s:secs
        ~last_activity_ns:t.last_activity_ns
        ~in_flight_work:t.in_flight_external_work
        promise
  in
  let result =
    Fun.protect ~finally:clear_active_turn (fun () ->
      try
        let res =
          rpc_call_with_wait t ~method_name:"session/prompt" ~params ~decoder ~wait:wait_prompt
        in
        (match res with
         | Error (Timeout _) -> cancel t ~session_id
         | Ok _
         | Error
             ( Invalid_config _ | Spawn_refused _ | Protocol_error _
             | Rpc_error _ | Process_exited _ | Client_closed ) -> ());
        res
      with
      | Eio.Cancel.Cancelled _ as exn ->
        Eio.Cancel.protect (fun () -> cancel t ~session_id);
        raise exn)
  in
  match result with
  | Error _ as err -> err
  | Ok (stop_reason, usage) ->
    Ok
      { session_id
      ; stop_reason
      ; text = Buffer.contents text_buf
      ; thought = Buffer.contents thought_buf
      ; usage
      ; tool_calls_observed = !tool_calls
      ; wall_duration_s = Float.max 0.0 (Time_compat.now () -. started_at)
      }
;;

module For_testing = struct
  let build_environment = build_environment
  let build_argv = build_argv
  let utf8_safe_suffix = utf8_safe_suffix
  let redact_stderr_text = redact_stderr_text
  let should_allow_permission = should_allow_permission
  let classify_tool_call_json = classify_tool_call_json
  let merge_tool_kind = merge_tool_kind
  let choose_permission_option = choose_permission_option
  let parse_config_options = parse_config_options
  let parse_session_info = parse_session_info
  let resolve_model_option_value = resolve_model_option_value
  let resolve_effort_option_value = resolve_effort_option_value
  let parse_session_update = parse_session_update
  let parse_prompt_usage = parse_prompt_usage
  let parse_stop_reason = parse_stop_reason
  let max_prompt_stream_bytes = max_prompt_stream_bytes
end
