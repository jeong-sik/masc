(** Shared helpers for the core MCP [tools/call] dispatcher. *)

let log_mcp_exn = Mcp_server_eio_helpers.log_mcp_exn
let wait_for_message_eio = Mcp_server_eio_helpers.wait_for_message_eio

(* RFC-0084 host-config-cleanup-D — agent runtime root migration.
   Resolves the host runtime root once at module-init from the typed
   [Host_config.agent_runtime_root] field; the 5 cross-process
   agent-identity scratch files below reference the bound name so a
   future PR can flip the typed surface to a base-path-relative
   layout without touching this module's call sites. *)
let agent_runtime_root = (Host_config.host ()).agent_runtime_root

(* #10699 Family A — "Join required" surfaces 28 / 24h events for
   masc_transition + masc_claim_next while the underlying keeper had
   joined under its canonical name at boot via
   [ensure_keeper_room_presence]. Rotation aliases (e.g.
   [nick0cave-happy-shark] vs canonical [keeper-nick0cave-agent])
   carry the join entry under the canonical name only;
   [Coord.is_agent_joined] does prefix matching against on-disk agent
   files but cannot project an alias back to the canonical without
   the [Keeper_identity] vocabulary that owns that mapping.

   When the raw [agent_name] check fails, retry once using the
   canonical [keeper_name] from
   [Keeper_identity.normalize_all_names]. The normalisation is gated
   by [canonical_keeper_name] inside [Keeper_identity], so an
   unrelated external caller ("alice-fake-bear") returns
   [Persona_not_found] and falls through to the original [false] —
   the alias-bridge only fires when the input is recognisably a
   keeper-form name.

   [check_join] is now parameterised on the candidate name so we can
   re-issue the lookup against the canonical form without rebuilding
   the closure environment. *)
let resolve_join_state ~room_initialized ~join_required ~agent_name ~base_path ~check_join
  =
  if not (room_initialized && join_required)
  then false
  else if agent_name = "unknown"
  then false
  else (
    (* [try_candidate] probes an alias only when it differs from the
       caller's own name, to avoid a redundant second lookup for the
       common case where the caller IS already using the canonical name. *)
    let try_candidate name = name <> agent_name && check_join name in
    (* Primary check: the name as supplied by the caller. *)
    if check_join agent_name
    then true
    else (
      (* Secondary check: resolve through Keeper_identity to find aliases.
         [normalize_all_names] may do filesystem I/O; we express the
         result as [Result.t] and fold both paths to a plain [bool]. *)
      let join_via_aliases () =
        let ( let* ) = Result.bind in
        let* bundle =
          Keeper_identity.normalize_all_names
            ~input_agent_name:agent_name
            ~base_path
            ~check_persona:false
            ~check_credential:false
            ()
        in
        (* Try the persona-level [keeper_name] first (e.g. [nick0cave]),
           then the canonical agent-form alias that
           [ensure_keeper_room_presence] writes to disk
           (e.g. [keeper-nick0cave-agent]). *)
        Ok
          (try_candidate bundle.keeper_name
           || try_candidate (Printf.sprintf "keeper-%s-agent" bundle.keeper_name))
      in
      match
        try join_via_aliases () with
        | Sys_error _ | Yojson.Json_error _ -> Ok false
      with
      | Ok joined -> joined
      | Error _ -> false))
;;

let silent_auth_token_error_kind err =
  Auth_error_kind.to_string (Auth_error_kind.classify err)
;;

let should_read_legacy_persisted_agent_name ~has_explicit_agent_name ~agent_name =
  (not has_explicit_agent_name) && Agent_name_kind.is_ephemeral agent_name
;;

let caller_agent_name_from_arguments arguments =
  let nonempty_nonunknown key =
    match Safe_ops.json_string_opt key arguments with
    | Some value ->
      let value = String.trim value in
      if value <> "" && value <> "unknown" then Some value else None
    | None -> None
  in
  match nonempty_nonunknown "_agent_name" with
  | Some _ as value -> value
  | None -> nonempty_nonunknown "agent_name"
;;

let mcp_session_agent_path sid =
  Filename.concat agent_runtime_root (Printf.sprintf ".masc_agent_mcp_%s" sid)
;;

let term_session_agent_path sid =
  Filename.concat agent_runtime_root (Printf.sprintf ".masc_agent_%s" sid)
;;

let read_mcp_session_agent ~mcp_session_id () =
  match mcp_session_id with
  | None -> None
  | Some sid ->
    let file = mcp_session_agent_path sid in
    (try
       let name = Fs_compat.load_file file |> String.trim in
       if name = ""
       then None
       else (
         Log.Mcp.warn
           "[deprecated] agent name resolved via /tmp file for session %s — migrate to \
            Agent_identity"
           sid;
         Some name)
     with
     | Sys_error _ | Eio.Io _ -> None)
;;

let write_mcp_session_agent ~mcp_session_id ~agent_name =
  match mcp_session_id with
  | None -> ()
  | Some sid ->
    let file = mcp_session_agent_path sid in
    (try Fs_compat.save_file file agent_name with
     | Sys_error msg -> Log.Misc.warn "write_mcp_session_agent: %s" msg
     | Eio.Io _ as exn ->
       Log.Misc.warn "write_mcp_session_agent: %s" (Printexc.to_string exn))
;;

let read_term_session_agent ~mcp_session_id () =
  if Option.is_some mcp_session_id
  then None
  else (
    match Sys.getenv_opt "TERM_SESSION_ID" with
    | None -> None
    | Some sid ->
      let file = term_session_agent_path sid in
      (try
         let name = Fs_compat.load_file file |> String.trim in
         if name = "" then None else Some name
       with
       | Sys_error _ -> None))
;;

let persisted_agent_name ~mcp_session_id ~has_explicit_agent_name ~agent_name () =
  if should_read_legacy_persisted_agent_name ~has_explicit_agent_name ~agent_name
  then (
    match read_mcp_session_agent ~mcp_session_id () with
    | Some n -> Some n
    | None ->
      if Option.is_some mcp_session_id
      then None
      else read_term_session_agent ~mcp_session_id ())
  else None
;;

let direct_call_block_message name =
  if Tool_catalog.is_on_surface Tool_catalog.Keeper_internal name
  then (
    let replacement_hint =
      match (Tool_catalog.metadata name).Tool_catalog.replacement with
      | Some replacement -> Printf.sprintf " Try `%s` instead." replacement
      | None -> ""
    in
    Printf.sprintf
      "Tool '%s' is keeper-internal and not callable from external MCP clients.%s"
      name
      replacement_hint)
  else
    Printf.sprintf
      "Tool '%s' is hidden from the default tool surface and not callable directly."
      name
;;

let cleanup_internal_keeper_runtime_resource ~during_exception ~label cleanup =
  try cleanup () with
  | Eio.Cancel.Cancelled _ as e when not during_exception -> raise e
  | exn ->
    Log.Mcp.warn
      "internal keeper runtime %s cleanup failed%s: %s"
      label
      (if during_exception then " while preserving primary exception" else "")
      (Printexc.to_string exn)
;;

let run_with_cleanup_preserving_primary ~cleanup f =
  match f () with
  | result ->
    cleanup ~during_exception:false ();
    result
  | exception exn ->
    let bt = Printexc.get_raw_backtrace () in
    cleanup ~during_exception:true ();
    Printexc.raise_with_backtrace exn bt
;;
