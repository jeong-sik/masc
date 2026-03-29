(** MASC Authentication & Authorization Module *)

open Types

(* ============================================ *)
(* Crypto utilities                             *)
(* ============================================ *)

(** Generate a cryptographically random token (hex string) *)
let generate_token () =
  let random_bytes = Mirage_crypto_rng.generate 32 in
  let hex = Buffer.create 64 in
  String.iter (fun c -> Buffer.add_string hex (Printf.sprintf "%02x" (Char.code c))) random_bytes;
  Buffer.contents hex

(** SHA256 hash of a string using Digestif *)
let sha256_hash input =
  Digestif.SHA256.(digest_string input |> to_hex)

(* ============================================ *)
(* Auth directory management                    *)
(* ============================================ *)

let auth_dir config = Filename.concat config ".masc/auth"
let agents_dir config = Filename.concat (auth_dir config) "agents"
let room_secret_file config = Filename.concat (auth_dir config) "room_secret.hash"
let auth_config_file config = Filename.concat (auth_dir config) "config.json"
let initial_admin_file config = Filename.concat (auth_dir config) "initial_admin"

(** Ensure auth directories exist *)
let ensure_auth_dirs config =
  let auth = auth_dir config in
  let agents = agents_dir config in
  Fs_compat.mkdir_p auth;
  Fs_compat.mkdir_p agents

(** Write the initial admin agent name (bootstrap grace).
    The agent who enables auth is always granted full permission. *)
let write_initial_admin config agent_name =
  ensure_auth_dirs config;
  let file = initial_admin_file config in
  Out_channel.with_open_text file (fun oc ->
    output_string oc (String.trim agent_name));
  Unix.chmod file 0o600

(** Read the initial admin agent name, if set. *)
let read_initial_admin config : string option =
  let file = initial_admin_file config in
  if Sys.file_exists file then
    try
      let name = String.trim (In_channel.with_open_text file In_channel.input_all) in
      if name = "" then None else Some name
    with Sys_error _ -> None
  else
    None

(* ============================================ *)
(* Auth config management                       *)
(* ============================================ *)

(** Load auth config *)
let load_auth_config config : auth_config =
  let file = auth_config_file config in
  if Sys.file_exists file then
    try
      let content = In_channel.with_open_text file In_channel.input_all in
      let json = Yojson.Safe.from_string content in
      match auth_config_of_yojson json with
      | Ok cfg -> cfg
      | Error _ -> default_auth_config
    with Sys_error _ | Yojson.Json_error _ -> default_auth_config
  else
    default_auth_config

(** Save auth config *)
let save_auth_config config (auth_cfg : auth_config) =
  ensure_auth_dirs config;
  let file = auth_config_file config in
  let json = auth_config_to_yojson auth_cfg in
  Out_channel.with_open_text file (fun oc ->
    output_string oc (Yojson.Safe.pretty_to_string json)
  )

(* ============================================ *)
(* Credential management                        *)
(* ============================================ *)

(** Get credential file path for an agent *)
let credential_file config agent_name =
  Filename.concat (agents_dir config) (agent_name ^ ".json")

(** Load agent credential *)
let load_credential config agent_name : agent_credential option =
  let file = credential_file config agent_name in
  if Sys.file_exists file then
    try
      let content = In_channel.with_open_text file In_channel.input_all in
      let json = Yojson.Safe.from_string content in
      match agent_credential_of_yojson json with
      | Ok cred -> Some cred
      | Error _ -> None
    with Sys_error _ | Yojson.Json_error _ -> None
  else
    None

(** Save agent credential *)
let save_credential config (cred : agent_credential) =
  ensure_auth_dirs config;
  let file = credential_file config cred.agent_name in
  let json = agent_credential_to_yojson cred in
  Out_channel.with_open_text file (fun oc ->
    output_string oc (Yojson.Safe.pretty_to_string json)
  )

(** Delete agent credential *)
let delete_credential config agent_name =
  let file = credential_file config agent_name in
  if Sys.file_exists file then Sys.remove file

(** List all credentials *)
let list_credentials config : agent_credential list =
  let dir = agents_dir config in
  if Sys.file_exists dir then
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.filter_map (fun f ->
        let name = Filename.chop_suffix f ".json" in
        load_credential config name
      )
  else
    []

(** Find credential by raw token (hash lookup + expiry check) *)
let find_credential_by_token config ~token : (agent_credential, masc_error) result =
  let token_hash = sha256_hash token in
  match List.find_opt (fun cred -> cred.token = token_hash) (list_credentials config) with
  | None -> Error (InvalidToken "Token mismatch")
  | Some cred ->
      (match cred.expires_at with
       | None -> Ok cred
       | Some exp_str ->
           let now = now_iso () in
           if now > exp_str then Error (TokenExpired cred.agent_name) else Ok cred)

(** Resolve agent_name from raw token *)
let resolve_agent_from_token config ~token : (string, masc_error) result =
  match find_credential_by_token config ~token with
  | Ok cred -> Ok cred.agent_name
  | Error e -> Error e

(* ============================================ *)
(* Token operations                             *)
(* ============================================ *)

(** Create a new token for an agent *)
let create_token config ~agent_name ~role : (string * agent_credential, masc_error) result =
  let auth_cfg = load_auth_config config in
  let raw_token = generate_token () in
  let token_hash = sha256_hash raw_token in
  let now = now_iso () in
  let expires_at =
    if auth_cfg.token_expiry_hours > 0 then
      let expiry = Time_compat.now () +. (float_of_int auth_cfg.token_expiry_hours *. 3600.0) in
      let tm = Unix.gmtime expiry in
      Some (Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
        tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec)
    else
      None
  in
  let cred = {
    agent_name;
    token = token_hash;
    role;
    created_at = now;
    expires_at;
  } in
  save_credential config cred;
  Ok (raw_token, cred)  (* Return raw token to user, store hash *)

(** Verify a token *)
let verify_token config ~agent_name ~token : (agent_credential, masc_error) result =
  match load_credential config agent_name with
  | None -> Error (Unauthorized ("No credential found for " ^ agent_name))
  | Some cred ->
      let token_hash = sha256_hash token in
      if cred.token <> token_hash then
        Error (InvalidToken "Token mismatch")
      else
        (* Check expiry *)
        match cred.expires_at with
        | None -> Ok cred
        | Some exp_str ->
            (* Simple ISO string comparison works for UTC *)
            let now = now_iso () in
            if now > exp_str then
              Error (TokenExpired agent_name)
            else
              Ok cred

(** Refresh a token (generate new one, update credential) *)
let refresh_token config ~agent_name ~old_token : (string * agent_credential, masc_error) result =
  match verify_token config ~agent_name ~token:old_token with
  | Error (TokenExpired _) ->
      (* Allow refresh even if expired *)
      (match load_credential config agent_name with
       | None -> Error (Unauthorized ("No credential found for " ^ agent_name))
       | Some old_cred -> create_token config ~agent_name ~role:old_cred.role)
  | Error e -> Error e
  | Ok old_cred -> create_token config ~agent_name ~role:old_cred.role

(* ============================================ *)
(* Authorization                                *)
(* ============================================ *)

(** Check if agent has permission for an action *)
let check_permission config ~agent_name ~token ~permission : (unit, masc_error) result =
  let auth_cfg = load_auth_config config in
  if not auth_cfg.enabled then
    (* Auth disabled - allow everything *)
    Ok ()
  else if (match read_initial_admin config with
           | Some admin -> String.equal agent_name admin
           | None -> false) then
    (* Bootstrap grace: the agent who enabled auth always has full access *)
    (ignore permission; Ok ())
  else if not auth_cfg.require_token then
    (* Token not required - use default role *)
    if has_permission auth_cfg.default_role permission then
      Ok ()
    else
      Error (Forbidden { agent = agent_name; action = show_permission permission })
  else
    (* Token required - verify and check role *)
    match token with
    | None -> Error (Unauthorized "Token required")
    | Some t ->
        match verify_token config ~agent_name ~token:t with
        | Error e -> Error e
        | Ok cred ->
            if has_permission cred.role permission then
              Ok ()
            else
              Error (Forbidden { agent = agent_name; action = show_permission permission })

(** Map MCP tool name to required permission *)
let permission_for_tool = function
  | "masc_init" -> Some CanInit
  | "masc_reset" -> Some CanReset
  | "masc_join" -> Some CanJoin
  | "masc_leave" -> Some CanLeave
  | "masc_status" | "masc_who" | "masc_tasks" | "masc_messages"
  | "masc_transport_status" | "masc_websocket_discovery"
  | "masc_agents" | "masc_portal_status" | "masc_pending_interrupts"
  | "masc_votes" | "masc_vote_status" | "masc_worktree_list"
  | "masc_cost_report" | "masc_task_history" | "masc_operator_snapshot"
  | "masc_operator_digest" | "masc_surface_audit"
  | "masc_collaboration_evidence"
  | "masc_persona_list"
  | "masc_keeper_status" | "masc_keeper_list"
  | "masc_keeper_trajectory" | "masc_keeper_eval"
  | "masc_persistent_agent_status" | "masc_persistent_agent_list"
  | "masc_persistent_agent_trajectory" | "masc_persistent_agent_eval"
  | "masc_local_runtime_models" | "masc_llama_models"
  | "masc_local_runtime_status" | "masc_llama_runtime_status"
  | "masc_runtime_verify" | "masc_llama_runtime_verify"
  | "masc_local_runtime_bench" | "masc_llama_runtime_bench"
  | "masc_unit_list" | "masc_operation_status"
  | "masc_policy_status" | "masc_dispatch_plan"
  | "masc_observe_topology" | "masc_observe_operations"
  | "masc_observe_swarm" | "masc_observe_capacity" | "masc_observe_alerts"
  | "masc_observe_traces"
  | "masc_voice_sessions" | "masc_voice_agent" ->
      Some CanReadState
  | "masc_autoresearch_status" -> Some CanReadState
  | "masc_add_task" -> Some CanAddTask
  | "masc_claim_next" -> Some CanClaimTask
  | "masc_done" | "masc_update_priority" | "masc_transition" | "masc_release" ->
      Some CanCompleteTask
  | "masc_broadcast" | "masc_listen" | "masc_heartbeat"
  | "masc_webrtc_offer" | "masc_webrtc_answer"
  | "masc_register_capabilities" | "masc_find_by_capability"
  | "masc_agent_update" | "masc_operator_action"
  | "masc_keeper_up" | "masc_keeper_down" | "masc_keeper_msg"
  | "masc_keeper_create_from_persona"
  | "masc_persistent_agent_create_from_persona"
  | "masc_persistent_agent_up" | "masc_persistent_agent_down"
  | "masc_persistent_agent_msg"
  | "masc_voice_speak" | "masc_voice_session_start"
  | "masc_voice_session_end" | "masc_voice_conference_start"
  | "masc_voice_conference_end"
  | "masc_operator_confirm" | "masc_unit_define"
  | "masc_unit_reparent"
  | "masc_unit_reassign" | "masc_operation_start"
  | "masc_operation_checkpoint" | "masc_operation_pause"
  | "masc_operation_resume" | "masc_operation_stop"
  | "masc_operation_finalize" | "masc_dispatch_assign"
  | "masc_dispatch_rebalance" | "masc_dispatch_escalate"
  | "masc_dispatch_recall" | "masc_policy_approve"
  | "masc_policy_deny" | "masc_policy_update" ->
      Some CanBroadcast
  | "masc_autoresearch_start" | "masc_autoresearch_swarm_start"
  | "masc_repo_synthesis_swarm_start"
  | "masc_autoresearch_cycle" | "masc_autoresearch_inject"
  | "masc_autoresearch_stop" ->
      Some CanAdmin
  (* Command-plane write operations require Admin *)
  | "masc_policy_freeze_unit" | "masc_policy_kill_switch" ->
      Some CanAdmin
  | "masc_portal_open" | "masc_portal_close" -> Some CanOpenPortal
  | "masc_portal_send" -> Some CanSendPortal
  | "masc_worktree_create" -> Some CanCreateWorktree
  | "masc_worktree_remove" -> Some CanRemoveWorktree
  | "masc_vote_create" | "masc_vote_cast" -> Some CanVote
  | "masc_interrupt" | "masc_branch" -> Some CanInterrupt
  | "masc_approve" | "masc_reject" -> Some CanApprove
  | "masc_cost_log" | "masc_cleanup_zombies" -> Some CanBroadcast (* Worker level *)
  | "masc_board_list" | "masc_board_get" | "masc_board_hearths"
  | "masc_board_search" | "masc_board_profile" | "masc_board_stats" ->
      Some CanReadState
  | "masc_board_post" | "masc_board_comment" | "masc_board_vote"
  | "masc_board_comment_vote" -> Some CanBroadcast
  | "masc_board_reclassify" -> Some CanAdmin
  (* Auth tools - special handling *)
  | "masc_auth_enable" | "masc_auth_disable"
  | "masc_auth_revoke" -> Some CanInit  (* Admin only *)
  | "masc_auth_create_token" -> Some CanAdmin  (* Allowed when auth is enabled *)
  | "masc_auth_status" | "masc_auth_refresh" -> Some CanReadState
  | "masc_tool_stats" | "masc_tool_help" | "masc_keeper_tool_catalog"
  | "masc_tool_list" -> Some CanReadState
  | "masc_tool_grant" | "masc_tool_revoke" -> Some CanAdmin
  | "masc_tool_admin_snapshot" -> Some CanReadState
  | "masc_tool_admin_update" -> Some CanAdmin
  | _ -> None

(** Strict tool auth mode:
    - 0/false: legacy fail-open for unknown tools
    - 1/true: unknown masc_* tools require at least worker-level permission *)
let is_tool_auth_strict_enabled () =
  Env_config_core.tool_auth_strict ()

let is_masc_tool_name tool_name =
  String.starts_with ~prefix:"masc_" tool_name

let is_protocol_canonical_tool_name tool_name =
  String.starts_with ~prefix:"decision." tool_name
  || String.starts_with ~prefix:"experiment." tool_name
  || String.starts_with ~prefix:"client." tool_name

(** Check permission for a tool call *)
let authorize_tool config ~agent_name ~token ~tool_name : (unit, masc_error) result =
  match permission_for_tool tool_name with
  | None ->
      if not (is_tool_auth_strict_enabled ()) then
        Ok ()  (* Legacy fail-open *)
      else if is_masc_tool_name tool_name || is_protocol_canonical_tool_name tool_name then
        (* Conservative default in strict mode for unmapped internal tools. *)
        check_permission config ~agent_name ~token ~permission:CanBroadcast
      else
        Error (Forbidden { agent = agent_name; action = "use unknown non-masc tool" })
  | Some perm -> check_permission config ~agent_name ~token ~permission:perm

(* ============================================ *)
(* Room secret (for room-level auth)            *)
(* ============================================ *)

(** Initialize room secret *)
let init_room_secret config : string =
  ensure_auth_dirs config;
  let secret = generate_token () in
  let hash = sha256_hash secret in
  Out_channel.with_open_text (room_secret_file config) (fun oc ->
    output_string oc hash
  );
  (* Update auth config with hash *)
  let cfg = load_auth_config config in
  save_auth_config config { cfg with room_secret_hash = Some hash };
  secret  (* Return raw secret to show user once *)

(** Verify room secret *)
let verify_room_secret config secret : bool =
  let hash = sha256_hash secret in
  let file = room_secret_file config in
  if Sys.file_exists file then
    let stored_hash = String.trim (In_channel.with_open_text file In_channel.input_all) in
    hash = stored_hash
  else
    false

(* ============================================ *)
(* High-level auth operations                   *)
(* ============================================ *)

(** Enable authentication for a room.
    Creates a bootstrap admin token for the enabling agent to prevent
    circular permission deadlock (BUG-025). *)
let enable_auth config ~require_token ~agent_name : string * string option =
  let secret = init_room_secret config in
  let cfg = load_auth_config config in
  save_auth_config config { cfg with enabled = true; require_token };
  let bootstrap_token =
    if agent_name <> "" then begin
      write_initial_admin config agent_name;
      match create_token config ~agent_name ~role:Admin with
      | Ok (token, _cred) -> Some token
      | Error _ -> None
    end else None
  in
  (secret, bootstrap_token)

(** Disable authentication *)
let disable_auth config =
  let cfg = load_auth_config config in
  save_auth_config config { cfg with enabled = false };
  let file = initial_admin_file config in
  if Sys.file_exists file then Sys.remove file

(** Check if auth is enabled *)
let is_auth_enabled config : bool =
  let cfg = load_auth_config config in
  cfg.enabled
