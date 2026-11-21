(** Unified persistent ACP v1 (Agent Client Protocol) JSON-RPC 2.0 over stdio
    client for Antigravity, Kimi Code, and Mistral Vibe. *)

open Result.Syntax

(* ── Closed driver algebra & declarative profiles ─────────────────────────── *)

type driver =
  | Antigravity
  | Kimi_code
  | Mistral_vibe
[@@deriving show, eq]

let all_drivers = [ Antigravity; Kimi_code; Mistral_vibe ]

let driver_to_string = function
  | Antigravity -> "antigravity"
  | Kimi_code -> "kimi_code"
  | Mistral_vibe -> "mistral_vibe"
;;

let driver_of_string = function
  | "antigravity" -> Some Antigravity
  | "kimi_code" -> Some Kimi_code
  | "mistral_vibe" -> Some Mistral_vibe
  | _ -> None
;;

type mcp_wiring =
  | Session_new_http_mcp
  | Gemini_dir_mcp_config

type system_prompt_channel =
  | Meta_antigravity_append
  | Framed_in_first_prompt

type input_accounting =
  | Inclusive_of_cached
  | Exclusive_of_cached

type output_accounting =
  | Inclusive_of_thought
  | Exclusive_of_thought

type driver_profile =
  { driver : driver
  ; default_command : string
  ; default_args : string list
  ; env_set : (string * string) list
  ; default_strip_env : string list
  ; mcp_wiring : mcp_wiring
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
    ; effort_config_id = Some "reasoning_effort"
    }
  | Kimi_code ->
    { driver = Kimi_code
    ; default_command = "kimi"
    ; default_args = [ "acp" ]
    ; env_set = []
    ; default_strip_env = []
    ; mcp_wiring = Session_new_http_mcp
    ; system_prompt_channel = Framed_in_first_prompt
    ; input_accounting = Inclusive_of_cached
    ; output_accounting = Inclusive_of_thought
    ; supports_skills_dir_flag = true
    ; mode_for_native_none = "default"
    ; mode_for_native_read = "plan"
    ; mode_for_native_full = "yolo"
    ; model_config_id = "model"
    ; effort_config_id = Some "thought_level"
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
;;

let mode_of_posture driver (posture : Runtime_native_tools.posture) =
  let profile = profile_of_driver driver in
  match posture with
  | Runtime_native_tools.Native_none -> profile.mode_for_native_none
  | Runtime_native_tools.Native_read -> profile.mode_for_native_read
  | Runtime_native_tools.Native_full -> profile.mode_for_native_full
;;

(* ── Named protocol constants ─────────────────────────────────────────────── *)

let protocol_version = 1
let default_timeout_s = 180.0
let init_timeout_s = 30.0
let max_ndjson_line_bytes = 16 * 1024 * 1024
let max_stderr_tail_bytes = 8192

(* ── Configuration & wire types ───────────────────────────────────────────── *)

type mcp_http_server =
  { name : string
  ; url : string
  ; headers : (string * string) list
  }

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
  }

type session_info =
  { session_id : string
  ; current_mode_id : string option
  ; available_modes : string list
  ; config_options : config_option list
  ; antigravity_tier : string option
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
  let input_tokens =
    match profile.input_accounting with
    | Inclusive_of_cached ->
      max u.input_tokens (u.cached_read_tokens + u.cached_write_tokens)
    | Exclusive_of_cached ->
      u.input_tokens + u.cached_read_tokens + u.cached_write_tokens
  in
  let output_tokens =
    match profile.output_accounting with
    | Inclusive_of_thought -> max u.output_tokens u.thought_tokens
    | Exclusive_of_thought -> u.output_tokens + u.thought_tokens
  in
  { input_tokens
  ; output_tokens
  ; cache_creation_input_tokens = u.cached_write_tokens
  ; cache_read_input_tokens = u.cached_read_tokens
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
      ; kind : string option
      ; status : tool_call_status
      ; raw_input : Yojson.Safe.t option
      }
  | Tool_call_updated of
      { tool_call_id : string
      ; title : string option
      ; status : tool_call_status option
      ; raw_output : Yojson.Safe.t option
      }
  | Usage_updated of
      { used : int option
      ; size : int option
      ; prompt_tokens : int option
      ; completion_tokens : int option
      ; cached_tokens : int option
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

let error_to_string = function
  | Invalid_config detail -> "invalid ACP config: " ^ detail
  | Spawn_refused refusal ->
    "failed to start ACP client: " ^ Process_eio.spawn_refusal_to_string refusal
  | Protocol_error { stage; detail } ->
    Printf.sprintf "ACP protocol error (%s): %s" stage detail
  | Rpc_error { method_name; code; message } ->
    Printf.sprintf "ACP RPC error in %s (code %d): %s" method_name code message
  | Timeout { stage; timeout_s } ->
    Printf.sprintf "ACP timeout in %s after %.1fs" stage timeout_s
  | Process_exited { detail; stderr_tail } ->
    let tail = String.trim stderr_tail in
    if tail = ""
    then Printf.sprintf "ACP process exited: %s" detail
    else Printf.sprintf "ACP process exited: %s (stderr: %s)" detail tail
  | Client_closed -> "ACP client is closed"
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

let parse_config_option json =
  match json_string_opt "id" json, json_string_opt "currentValue" json with
  | Some id, Some current_value ->
    let name = Option.value (json_string_opt "name" json) ~default:id in
    let category = json_string_opt "category" json in
    Some { id; name; category; current_value }
  | _ -> None
;;

let parse_config_options json =
  match json_list_opt "configOptions" json with
  | None -> []
  | Some items -> List.filter_map parse_config_option items
;;

let parse_session_update params =
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
    let tool_call_id = Option.value (json_string_opt "toolCallId" update) ~default:"" in
    let title = Option.value (json_string_opt "title" update) ~default:"tool_call" in
    let kind = json_string_opt "kind" update in
    let status =
      json_string_opt "status" update
      |> Option.map parse_tool_status
      |> Option.value ~default:Tool_pending
    in
    let raw_input = json_field "rawInput" update in
    Some (Tool_call_started { tool_call_id; title; kind; status; raw_input })
  | Some "tool_call_update" ->
    let tool_call_id = Option.value (json_string_opt "toolCallId" update) ~default:"" in
    let title = json_string_opt "title" update in
    let status = Option.map parse_tool_status (json_string_opt "status" update) in
    let raw_output = json_field "rawOutput" update in
    Some (Tool_call_updated { tool_call_id; title; status; raw_output })
  | Some "usage_update" ->
    let used = json_int_opt "used" update in
    let size = json_int_opt "size" update in
    let meta = json_field "_meta" update in
    let meta_int k = Option.bind meta (json_int_opt k) in
    Some
      (Usage_updated
         { used
         ; size
         ; prompt_tokens = meta_int "promptTokens"
         ; completion_tokens = meta_int "completionTokens"
         ; cached_tokens = meta_int "cachedTokens"
         ; total_tokens = meta_int "totalTokens"
         })
  | Some "current_mode_update" ->
    Option.map (fun m -> Mode_updated m) (json_string_opt "currentModeId" update)
  | Some "config_option_update" ->
    Some (Config_options_updated (parse_config_options update))
  | _ -> None
;;

let parse_prompt_usage result_json =
  match json_field "usage" result_json with
  | None -> empty_usage
  | Some u ->
    let i k = Option.value (json_int_opt k u) ~default:0 in
    let input_tokens = i "inputTokens" in
    let output_tokens = i "outputTokens" in
    let cached_read_tokens = i "cachedReadTokens" in
    let cached_write_tokens = i "cachedWriteTokens" in
    let thought_tokens = i "thoughtTokens" in
    let total_tokens =
      match json_int_opt "totalTokens" u with
      | Some n -> n
      | None ->
        input_tokens + output_tokens + cached_read_tokens + cached_write_tokens
        + thought_tokens
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
  ; resume_session = Option.is_some (json_field "resume" session_caps)
  ; close_session = Option.is_some (json_field "close" session_caps)
  ; image_prompt = json_bool_or ~default:false "image" prompt_caps
  ; embedded_context = json_bool_or ~default:false "embeddedContext" prompt_caps
  ; mcp_http = json_bool_or ~default:false "http" mcp_caps
  ; antigravity_system_prompt_append = agy_sp_append
  ; antigravity_tier = agy_tier
  }
;;

let parse_session_info result_json =
  match json_string_opt "sessionId" result_json with
  | None -> Error "session/new response missing sessionId"
  | Some session_id ->
    let modes_obj = json_field "modes" result_json in
    let current_mode_id = Option.bind modes_obj (json_string_opt "currentModeId") in
    let available_modes =
      match Option.bind modes_obj (json_list_opt "availableModes") with
      | None -> []
      | Some entries -> List.filter_map (json_string_opt "id") entries
    in
    let config_options = parse_config_options result_json in
    let antigravity_tier =
      json_field "_meta" result_json
      |> Option.value ~default:(`Assoc [])
      |> json_field "antigravity"
      |> Option.value ~default:(`Assoc [])
      |> json_string_opt "tier"
    in
    Ok { session_id; current_mode_id; available_modes; config_options; antigravity_tier }
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

let prepare_antigravity_gemini_dir ~oauth_source ~mcp_server =
  let dir = Filename.temp_dir "masc-agy-acp-" "" in
  try
    let config_dir = Filename.concat dir "config" in
    Fs_compat.mkdir_p config_dir;
    (match mcp_server with
     | None -> ()
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
       Fs_compat.save_file cfg_path (Yojson.Safe.to_string mcp_json);
       Unix.chmod cfg_path 0o600);
    let agy_cli_dir = Filename.concat dir "antigravity-cli" in
    Fs_compat.mkdir_p agy_cli_dir;
    let copy_oauth_file source_path =
      let dest = Filename.concat agy_cli_dir "antigravity-oauth-token" in
      let content = Fs_compat.load_file source_path in
      Fs_compat.save_file dest content;
      Unix.chmod dest 0o600
    in
    (match oauth_source with
     | Some source_path when Sys.file_exists source_path ->
       copy_oauth_file source_path
     | Some _ | None ->
       (* Keep antigravity-cli/ isolated per child so Keeper runs never mutate
          the operator's writable ~/.gemini/antigravity-cli sessions/settings
          or inherit unrelated MCP configs. Copy only the single OAuth token
          file if present on disk (macOS agy authenticates via OS Keychain). *)
       (match Sys.getenv_opt "HOME" with
        | Some home ->
          let token_file =
            Filename.concat home ".gemini/antigravity-cli/antigravity-oauth-token"
          in
          if Sys.file_exists token_file then copy_oauth_file token_file
        | None -> ()));
    Ok dir
  with
  | Eio.Cancel.Cancelled _ as exn ->
    (try Fs_compat.remove_tree dir with Sys_error _ | Unix.Unix_error _ -> ());
    raise exn
  | exn ->
    (try Fs_compat.remove_tree dir with Sys_error _ | Unix.Unix_error _ -> ());
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

let is_disallowed_native_kind = function
  | Some ("execute" | "edit" | "delete" | "move" | "write" | "shell" | "terminal") -> true
  | Some _ | None -> false
;;

let is_read_only_tool_kind = function
  | Some ("read" | "search" | "fetch" | "think") -> true
  | Some _ | None -> false
;;

let is_masc_mcp_tool ~mcp_server_name ~allowed_tool_names ~title ~kind =
  if is_disallowed_native_kind kind || allowed_tool_names = []
  then false
  else (
    let matches_tool tool_name =
      String.equal title ("mcp__" ^ mcp_server_name ^ "__" ^ tool_name)
      || String.equal title ("mcp_" ^ mcp_server_name ^ "." ^ tool_name)
      || String.equal title (mcp_server_name ^ ":" ^ tool_name)
      || String.equal title (mcp_server_name ^ "/" ^ tool_name)
      || (match kind with
          | None | Some ("mcp" | "other") ->
            String.equal title (mcp_server_name ^ "_" ^ tool_name)
          | Some _ -> false)
      || (Option.equal String.equal kind (Some "mcp") && String.equal title tool_name)
    in
    List.exists matches_tool allowed_tool_names)
;;

let should_allow_permission ~policy ~title ~kind =
  match policy with
  | Allow_all -> true
  | Deny_all -> false
  | Allow_masc_mcp_only { mcp_server_name; allowed_tool_names } ->
    is_masc_mcp_tool ~mcp_server_name ~allowed_tool_names ~title ~kind
  | Allow_read_and_masc_mcp { mcp_server_name; allowed_tool_names } ->
    is_masc_mcp_tool ~mcp_server_name ~allowed_tool_names ~title ~kind
    || is_read_only_tool_kind kind
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
  then (
    match find_kind Allow_once with
    | Some id -> Some id
    | None -> find_kind Allow_always)
  else (
    match find_kind Reject_once with
    | Some id -> Some id
    | None -> find_kind Reject_always)
;;

(* ── Persistent client handle & JSON-RPC multiplexing ─────────────────────── *)

type active_turn_hooks =
  { session_id : string
  ; permission_policy : permission_policy
  ; on_event : stream_event -> unit
  }

type rpc_response =
  | Rpc_ok of Yojson.Safe.t
  | Rpc_err of int * string
  | Rpc_closed of string

type t =
  { driver : driver
  ; mutable capabilities : agent_capabilities
  ; mutable init_latency_ms : int
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; signal_term : unit -> unit
  ; to_stdin : [ Eio.Flow.sink_ty | Eio.Resource.close_ty ] Eio.Resource.t
  ; write_mutex : Eio.Mutex.t
  ; state_mutex : Stdlib.Mutex.t
  ; mutable next_id : int
  ; pending : (int, rpc_response Eio.Promise.u) Hashtbl.t
  ; mutable active_turn : active_turn_hooks option
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

let driver t = t.driver
let capabilities t = t.capabilities
let init_latency_ms t = t.init_latency_ms
let is_alive t = Atomic.get t.alive && not (Atomic.get t.closed)

let stderr_tail t =
  Stdlib.Mutex.lock t.stderr_mutex;
  let s = Buffer.contents t.stderr_buf in
  Stdlib.Mutex.unlock t.stderr_mutex;
  s
;;

let append_stderr t chunk =
  Stdlib.Mutex.lock t.stderr_mutex;
  let current_len = Buffer.length t.stderr_buf in
  let chunk_len = String.length chunk in
  if current_len + chunk_len <= max_stderr_tail_bytes
  then Buffer.add_string t.stderr_buf chunk
  else (
    let combined = Buffer.contents t.stderr_buf ^ chunk in
    let keep = String.sub combined (String.length combined - max_stderr_tail_bytes) max_stderr_tail_bytes in
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
      | Eio.Cancel.Cancelled _ as exn -> raise exn
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

let close t =
  if Atomic.compare_and_set t.closed false true
  then (
    Atomic.set t.alive false;
    (try Eio.Resource.close t.to_stdin with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Eio.Io _ | Unix.Unix_error _ | Invalid_argument _ -> ());
    (try t.signal_term () with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Eio.Io _ | Unix.Unix_error _ -> ());
    fail_all_pending t "client closed")
;;

let handle_permission_request t ~id ~params =
  let active = with_state_lock t (fun () -> t.active_turn) in
  let policy =
    match active with
    | Some turn -> turn.permission_policy
    | None -> Deny_all
  in
  let tool_call = Option.value (json_field "toolCall" params) ~default:(`Assoc []) in
  let title =
    match Option.bind (json_field "_meta" tool_call) (json_string_opt "tool_name") with
    | Some structured_name -> structured_name
    | None -> Option.value (json_string_opt "title" tool_call) ~default:""
  in
  let kind = json_string_opt "kind" tool_call in
  let options = Option.value (json_list_opt "options" params) ~default:[] in
  let allow = should_allow_permission ~policy ~title ~kind in
  let outcome =
    match choose_permission_option ~allow options with
    | Some option_id ->
      `Assoc [ "outcome", `String "selected"; "optionId", `String option_id ]
    | None -> `Assoc [ "outcome", `String "cancelled" ]
  in
  let response =
    `Assoc [ "jsonrpc", `String "2.0"; "id", id; "result", `Assoc [ "outcome", outcome ] ]
  in
  ignore (send_json t response)
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
          Eio.Promise.resolve u (Rpc_err (code, message))
        | None ->
          let result = Option.value (json_field "result" msg) ~default:`Null in
          Eio.Promise.resolve u (Rpc_ok result)))
  | Some "session/update", None ->
    let params = Option.value (json_field "params" msg) ~default:(`Assoc []) in
    let event_opt = parse_session_update params in
    let active = with_state_lock t (fun () -> t.active_turn) in
    (match event_opt, active with
     | Some event, Some turn ->
       let matches_session =
         match json_string_opt "sessionId" params with
         | None -> true
         | Some sid -> String.equal sid turn.session_id
       in
       if matches_session
       then (
         try turn.on_event event with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
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
    ignore (send_json t response)
  | _ -> ()
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
      let await_result () =
        Fun.protect ~finally:remove_pending (fun () ->
          match timeout_s with
          | None -> Ok (Eio.Promise.await promise)
          | Some secs ->
            (match Eio.Time.with_timeout t.clock secs (fun () -> Ok (Eio.Promise.await promise)) with
             | Ok resp -> Ok resp
             | Error `Timeout -> Error (Timeout { stage = method_name; timeout_s = secs })))
      in
      let* resp = await_result () in
      (match resp with
       | Rpc_ok json ->
         decoder.decode json
         |> Result.map_error (fun detail -> Protocol_error { stage = method_name; detail })
       | Rpc_err (code, message) -> Error (Rpc_error { method_name; code; message })
       | Rpc_closed reason ->
         Error (Process_exited { detail = reason; stderr_tail = stderr_tail t })))
;;

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
    ignore (send_json t notif))
;;

(* ── Lifecycle: spawn + initialize ────────────────────────────────────────── *)

let build_argv (config : config) ~temp_gemini_dir =
  let profile = profile_of_driver config.driver in
  let base_args = if config.args <> [] then config.args else profile.default_args in
  match config.driver with
  | Antigravity ->
    let gemini_args =
      match temp_gemini_dir with
      | Some dir -> [ "--gemini-dir"; dir ]
      | None -> []
    in
    let skip_perm =
      if config.dangerously_skip_permissions
      then [ "--dangerously-skip-permissions" ]
      else []
    in
    (config.cli_path :: base_args) @ gemini_args @ skip_perm
  | Kimi_code ->
    (* kimi requires global options such as --skills-dir BEFORE the `acp` subcommand. *)
    let pre_args =
      if profile.supports_skills_dir_flag
      then
        List.concat_map
          (fun dir -> if Sys.file_exists dir then [ "--skills-dir"; dir ] else [])
          config.skills_dirs
      else []
    in
    (config.cli_path :: pre_args) @ base_args
  | Mistral_vibe -> config.cli_path :: base_args
;;

let start ~sw ~proc_mgr ~clock ~(config : config) ?mcp_server () =
  if String.trim config.cli_path = ""
  then Error (Invalid_config "cli_path must be non-empty")
  else if String.trim config.cwd = ""
  then Error (Invalid_config "cwd must be non-empty")
  else (
    let profile = profile_of_driver config.driver in
    let* temp_gemini_dir =
      match profile.mcp_wiring with
      | Gemini_dir_mcp_config ->
        Result.map Option.some
          (prepare_antigravity_gemini_dir ~oauth_source:config.oauth_source ~mcp_server)
      | Session_new_http_mcp -> Ok None
    in
    let cleanup_gemini_dir () =
      Option.iter
        (fun dir ->
           try Fs_compat.remove_tree dir with
           | Sys_error _ | Unix.Unix_error _ -> ())
        temp_gemini_dir
    in
    let env =
      build_environment
        ~base_env:(Unix.environment ())
        ~driver:config.driver
        ~extra_strip_env:config.strip_env
    in
    let argv = build_argv config ~temp_gemini_dir in
    let cwd_path =
      match Eio_context.get_env_opt () with
      | Some eio_env -> Some Eio.Path.(Eio.Stdenv.fs eio_env / config.cwd)
      | None -> None
    in
    let started_at = Time_compat.now () in
    match Process_eio.spawn_piped_child ~sw proc_mgr ?cwd:cwd_path ~env argv with
    | Error refusal ->
      cleanup_gemini_dir ();
      Error (Spawn_refused refusal)
    | Ok { Process_eio.process; to_stdin; from_stdout; from_stderr } ->
      let t =
        { driver = config.driver
        ; capabilities =
            { load_session = false
            ; resume_session = false
            ; close_session = false
            ; image_prompt = false
            ; embedded_context = false
            ; mcp_http = false
            ; antigravity_system_prompt_append = false
            ; antigravity_tier = None
            }
        ; init_latency_ms = 0
        ; clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t)
        ; signal_term = (fun () -> Eio.Process.signal process Sys.sigterm)
        ; to_stdin
        ; write_mutex = Eio.Mutex.create ()
        ; state_mutex = Stdlib.Mutex.create ()
        ; next_id = 1
        ; pending = Hashtbl.create 16
        ; active_turn = None
        ; alive = Atomic.make true
        ; closed = Atomic.make false
        ; stderr_buf = Buffer.create 512
        ; stderr_mutex = Stdlib.Mutex.create ()
        }
      in
      (* Per-Keeper switch owns the child: release hook closes stdin, signals
         SIGTERM, and deletes temporary --gemini-dir without Eio waits. *)
      Eio.Switch.on_release sw (fun () ->
        close t;
        cleanup_gemini_dir ());
      (* Background stderr drain daemon *)
      Eio.Fiber.fork_daemon ~sw (fun () ->
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
      Eio.Fiber.fork_daemon ~sw (fun () ->
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
               fail_all_pending t "stdout EOF"
           in
           loop ()
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Atomic.set t.alive false;
           fail_all_pending t ("stdout reader failed: " ^ Printexc.to_string exn));
        `Stop_daemon);
      let init_params =
        `Assoc
          [ "protocolVersion", `Int protocol_version
          ; "clientCapabilities", `Assoc []
          ; ( "clientInfo"
            , `Assoc
                [ "name", `String "masc"
                ; "version", `String Runtime_build_version.current
                ] )
          ]
      in
      let init_decoder = { decode = (fun json -> Ok (parse_capabilities json)) } in
      (match
         rpc_call_decoded
           t
           ~method_name:"initialize"
           ~params:init_params
           ~timeout_s:(Some config.admission_timeout_s)
           ~decoder:init_decoder
       with
       | Error _ as err ->
         close t;
         err
       | Ok caps ->
         let init_ms =
           Int.of_float (Float.max 0.0 ((Time_compat.now () -. started_at) *. 1000.0))
         in
         t.capabilities <- caps;
         t.init_latency_ms <- init_ms;
         Ok t))
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

let apply_session_options t (info : session_info) ~mode ~model ~effort =
  let profile = profile_of_driver t.driver in
  let* () =
    match mode with
    | None -> Ok ()
    | Some desired when Option.equal String.equal info.current_mode_id (Some desired) ->
      Ok ()
    | Some desired ->
      (* Only request set_mode when the CLI advertises modes (or list is empty). *)
      if info.available_modes = [] || List.mem desired info.available_modes
      then set_mode t ~session_id:info.session_id ~mode_id:desired
      else Ok ()
  in
  let has_option opt_id =
    List.exists (fun (opt : config_option) -> String.equal opt.id opt_id) info.config_options
  in
  let current_value opt_id =
    List.find_map
      (fun (opt : config_option) ->
         if String.equal opt.id opt_id then Some opt.current_value else None)
      info.config_options
  in
  let* config_options =
    match model with
    | Some m
      when String.trim m <> ""
           && has_option profile.model_config_id
           && not (Option.equal String.equal (current_value profile.model_config_id) (Some m)) ->
      set_config_option t ~session_id:info.session_id ~config_id:profile.model_config_id ~value:m
    | _ -> Ok info.config_options
  in
  let* config_options =
    match effort, profile.effort_config_id with
    | Some eff, Some eff_id
      when String.trim eff <> ""
           && List.exists (fun (o : config_option) -> String.equal o.id eff_id) config_options ->
      set_config_option t ~session_id:info.session_id ~config_id:eff_id ~value:eff
    | _ -> Ok config_options
  in
  Ok { info with config_options }
;;

let mcp_servers_param_for_driver driver mcp_server =
  let profile = profile_of_driver driver in
  match profile.mcp_wiring, mcp_server with
  | Session_new_http_mcp, Some srv -> `List [ mcp_server_to_acp_json srv ]
  | Session_new_http_mcp, None -> `List []
  | Gemini_dir_mcp_config, _ -> `List []
;;

let new_session t ~cwd ?system_prompt_append ?mcp_server ?mode ?model ?effort () =
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
  let params =
    `Assoc
      ([ "cwd", `String cwd
       ; "mcpServers", mcp_servers_param_for_driver t.driver mcp_server
       ]
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
  apply_session_options t info ~mode ~model ~effort
;;

let load_session t ~session_id ~cwd ?mcp_server () =
  let params =
    `Assoc
      [ "sessionId", `String session_id
      ; "cwd", `String cwd
      ; "mcpServers", mcp_servers_param_for_driver t.driver mcp_server
      ]
  in
  rpc_call_decoded
    t
    ~method_name:"session/load"
    ~params
    ~timeout_s:(Some init_timeout_s)
    ~decoder:{ decode = (fun json ->
      match parse_session_info json with
      | Ok info -> Ok info
      | Error _ ->
        Ok
          { session_id
          ; current_mode_id = None
          ; available_modes = []
          ; config_options = parse_config_options json
          ; antigravity_tier = None
          }) }
;;

let resume_session t ~session_id ~cwd ?mcp_server () =
  let params =
    `Assoc
      [ "sessionId", `String session_id
      ; "cwd", `String cwd
      ; "mcpServers", mcp_servers_param_for_driver t.driver mcp_server
      ]
  in
  rpc_call_decoded
    t
    ~method_name:"session/resume"
    ~params
    ~timeout_s:(Some init_timeout_s)
    ~decoder:{ decode = (fun json ->
      match parse_session_info json with
      | Ok info -> Ok info
      | Error _ ->
        Ok
          { session_id
          ; current_mode_id = None
          ; available_modes = []
          ; config_options = parse_config_options json
          ; antigravity_tier = None
          }) }
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
  let started_at = Time_compat.now () in
  let text_buf = Buffer.create 1024 in
  let thought_buf = Buffer.create 512 in
  let tool_calls = ref 0 in
  let last_context_used = ref None in
  let last_context_size = ref None in
  let streamed_usage = ref empty_usage in
  let handle_event event =
    (match event with
     | Text_delta s -> Buffer.add_string text_buf s
     | Thought_delta s -> Buffer.add_string thought_buf s
     | Tool_call_started _ -> incr tool_calls
     | Tool_call_updated _ | Mode_updated _ | Config_options_updated _ -> ()
     | Usage_updated
         { used; size; prompt_tokens; completion_tokens; cached_tokens; total_tokens } ->
       (match used with Some _ as u -> last_context_used := u | None -> ());
       (match size with Some _ as s -> last_context_size := s | None -> ());
       let prev = !streamed_usage in
       streamed_usage :=
         { input_tokens = Option.value prompt_tokens ~default:prev.input_tokens
         ; output_tokens = Option.value completion_tokens ~default:prev.output_tokens
         ; cached_read_tokens = Option.value cached_tokens ~default:prev.cached_read_tokens
         ; cached_write_tokens = prev.cached_write_tokens
         ; thought_tokens = prev.thought_tokens
         ; total_tokens = Option.value total_tokens ~default:prev.total_tokens
         ; context_used = !last_context_used
         ; context_size = !last_context_size
         });
    on_event event
  in
  with_state_lock t (fun () ->
    t.active_turn <- Some { session_id; permission_policy; on_event = handle_event });
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
  let result =
    Fun.protect ~finally:clear_active_turn (fun () ->
      try
        let res =
          rpc_call_decoded t ~method_name:"session/prompt" ~params ~timeout_s ~decoder
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
  let should_allow_permission = should_allow_permission
  let parse_session_update = parse_session_update
  let parse_prompt_usage = parse_prompt_usage
  let parse_stop_reason = parse_stop_reason
end
