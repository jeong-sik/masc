(** Coord Broadcast - Message broadcasting and activity emission.

    Extracted from room_state.ml. Depends on Coord_state for
    next_seq and normalized_string_list. *)

open Masc_domain
open Coord_utils

let emit_message_activity config ~from_agent ~content ~mention
    ?session_id ?operation_id ?worker_run_id ?(evidence_refs = []) () =
  let evidence_refs = Coord_state.normalized_string_list evidence_refs in
  let payload =
    `Assoc
      [
        ("content", `String content);
        ( "mention",
          match mention with
          | Some value -> `String value
          | None -> `Null );
        ( "session_id",
          match session_id with
          | Some value when String.trim value <> "" -> `String value
          | _ -> `Null );
        ( "operation_id",
          match operation_id with
          | Some value when String.trim value <> "" -> `String value
          | _ -> `Null );
        ( "worker_run_id",
          match worker_run_id with
          | Some value when String.trim value <> "" -> `String value
          | _ -> `Null );
        ( "evidence_refs",
          `List (List.map (fun value -> `String value) evidence_refs) );
      ]
  in
  let actor = Coord_hooks.{ kind = "agent"; id = from_agent } in
  let emit ?subject ~kind ~tags () =
    try
      (Atomic.get Coord_hooks.activity_emit_fn) config
        ~actor ?subject ~kind ~payload ~tags ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Misc.warn "message activity emit failed (%s): %s" kind
          (Printexc.to_string exn)
  in
  emit
    ~kind:(Event_kind.Message.to_string Event_kind.Message.Broadcast)
    ~tags:[ "message"; "broadcast" ] ();
  match mention with
  | Some target when String.trim target <> "" ->
      emit
        ~subject:Coord_hooks.{ kind = "agent"; id = target }
        ~kind:(Event_kind.Message.to_string Event_kind.Message.Mentioned)
        ~tags:[ "message"; "mention" ] ()
  | None | Some _ -> ()

let broadcast_channel config =
  Printf.sprintf "broadcast:%s:default" (project_prefix config)

let on_broadcast_mention : (string option -> unit) ref =
  ref (fun _mention -> ())

let broadcast ?trace_context ?(msg_type = "broadcast")
    ?(task_cache_invariant_checked = false) ?(bypass_dedup = false)
    config ~from_agent ~content =
  let started_at = Time_compat.now () in
  let observe final_msg_type =
    let elapsed_s = Float.max 0.0 (Time_compat.now () -. started_at) in
    try (Atomic.get Coord_hooks.coord_broadcast_observed_fn)
          ~msg_type:final_msg_type ~elapsed_s
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()
  in
  ensure_initialized config;
  (* Fleet-wide invariant (PR-B): if the broadcasting agent's current_task is
     terminal in the backlog, replace the original broadcast with a single
     cache_invalidated notice and clear the stale state (issue #13397).
     Only applied to regular "broadcast" messages to avoid recursion. *)
  let content, msg_type =
    if task_cache_invariant_checked then (content, msg_type)
    else if String.equal msg_type "broadcast" then
      let agent_file =
        Filename.concat (agents_dir config) (safe_filename from_agent ^ ".json")
      in
      if Sys.file_exists agent_file then
        match agent_of_yojson (read_json config agent_file) with
        | Ok agent -> (
            match agent.current_task with
            | Some task_id -> (
                match Task_cache_invariant.fresh_task_status config ~task_id with
                | Some status when Task_cache_invariant.is_terminal status ->
                    Task_cache_invariant.clear_stale_agent_task config
                      ~agent_name:from_agent ~task_id ~status
                      ~module_name:"coord_broadcast";
                    let inv_content =
                      Printf.sprintf
                        "[cache_invalidated] coord_broadcast: task %s is %s \
                         — stale broadcast suppressed"
                        task_id (Masc_domain.task_status_to_string status)
                    in
                    (inv_content, "cache_invalidated")
                | _ ->
                    ( Coord_task_cache_invariant.rewrite_broadcast_content
                        ~config ~from_agent ~module_name:"coord_broadcast"
                        ~content,
                      msg_type ))
            | None ->
                ( Coord_task_cache_invariant.rewrite_broadcast_content
                    ~config ~from_agent ~module_name:"coord_broadcast"
                    ~content,
                  msg_type ))
        | Error _ ->
            ( Coord_task_cache_invariant.rewrite_broadcast_content
                ~config ~from_agent ~module_name:"coord_broadcast" ~content,
              msg_type )
      else
        ( Coord_task_cache_invariant.rewrite_broadcast_content
            ~config ~from_agent ~module_name:"coord_broadcast" ~content,
          msg_type )
    else (content, msg_type)
  in
  (* RFC-0040: sender-side mention dedup.  When [Mention.extract]
     finds an [@target] and the same (from_agent, target, content_hash)
     was broadcast within [Mention_dedup.default_ttl_seconds], skip the
     entire broadcast: no msg file, no activity emit, no on_broadcast
     callback.  Keeper pull-model (keeper_prompt.ml:16
     [Mention.any_mentioned]) re-reads the board on every turn, so a
     spammy resender otherwise floods the recipient's inbox.  Set
     [~bypass_dedup:true] to override for system-level alerts. *)
  let pre_extract_mention = Mention.extract content in
  let dedup_skipped =
    (not bypass_dedup)
    && (match pre_extract_mention with
        | Some target when String.trim target <> "" ->
            let content_hash = Mention_dedup.content_topic_hash content in
            Mention_dedup.should_skip ~from_agent ~target ~content_hash
              ~now:(Time_compat.now ())
        | _ ->
            (try (Atomic.get Coord_hooks.mention_dedup_decision_fn)
                   ~outcome:(if bypass_dedup then "bypassed" else "no_target")
             with _ -> ());
            false)
  in
  if dedup_skipped then begin
    Log.Misc.info
      "[mention-dedup] skipped duplicate mention from %s to %s within %.0fs window"
      from_agent
      (Option.value ~default:"<none>" pre_extract_mention)
      Mention_dedup.default_ttl_seconds;
    observe "dedup_skipped";
    Printf.sprintf "\xF0\x9F\x93\xA2 [%s] dedup_skipped" from_agent
  end else
  let () =
    if bypass_dedup then
      try (Atomic.get Coord_hooks.mention_dedup_decision_fn)
            ~outcome:"bypassed"
      with _ -> ()
  in
  let seq = Coord_state.next_seq config in
  let mention = pre_extract_mention in
  let safe_content = sanitize_message content in
  let safe_agent = sanitize_agent_name from_agent in
  let safe_msg_type =
    match String.trim msg_type with
    | "" -> "broadcast"
    | value -> sanitize_message value
  in
  let msg = {
    seq;
    from_agent = safe_agent;
    msg_type = safe_msg_type;
    content = safe_content;
    mention;
    timestamp = now_iso ();
    trace_context;
  } in
  let msg_file =
    Filename.concat (messages_dir config)
      (Printf.sprintf "%09d_%s_broadcast.json" seq (safe_filename from_agent))
  in
  write_json config msg_file (message_to_yojson msg);
  (match backend_publish config ~channel:(broadcast_channel config)
      ~message:(Yojson.Safe.to_string (message_to_yojson msg)) with
   | Ok _ -> ()
   | Error (Backend_types.BackendNotSupported msg) when String.starts_with ~prefix:"FileSystem backend" msg ->
       Log.Misc.debug "broadcast publish skipped: %s" msg
   | Error e -> Log.Misc.error "broadcast publish failed: %s" (Backend_types.show_error e));
  emit_message_activity config ~from_agent:safe_agent ~content:safe_content
    ~mention ();
  (try !on_broadcast_mention mention
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Misc.warn "on_broadcast_mention callback failed: %s"
       (Printexc.to_string exn));
  observe safe_msg_type;
  Printf.sprintf "\xF0\x9F\x93\xA2 [%s] %s" safe_agent safe_content
