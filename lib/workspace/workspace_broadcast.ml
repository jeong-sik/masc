(** Workspace Broadcast - Message broadcasting and activity emission.

    Extracted from workspace_state.ml. Depends on Workspace_state for
    next_seq and normalized_string_list. *)

open Masc_domain
open Workspace_utils

(** RFC-0061: closed variants for broadcast envelope observability.
    rewrite_reason tracks why the original content was rewritten.
    msg_type_typed is an internal closed variant; the external [msg_type]
    field remains [string] for backward compatibility. *)
type rewrite_reason =
  | Cache_invalidated of { task_id : string; status : string }
  | Task_cache_rewrite

type rewrite_event = {
  reason : rewrite_reason;
  module_name : string;
}

type msg_type_typed =
  | Broadcast
  | Cache_invalidated of { task_id : string; status : string }

let string_of_msg_type_typed = function
  | Broadcast -> "broadcast"
  | Cache_invalidated _ -> "cache_invalidated"

let emit_message_activity config ~from_agent ~content ~mention
    ?session_id ?operation_id ?worker_run_id ?(evidence_refs = []) () =
  let evidence_refs = Workspace_state.normalized_string_list evidence_refs in
  let payload =
    `Assoc
      [
        ("content", `String content);
        ( "mention", Json_util.string_opt_to_json mention );
        ( "session_id", Json_util.string_opt_to_json_trimmed session_id );
        ( "operation_id", Json_util.string_opt_to_json_trimmed operation_id );
        ( "worker_run_id", Json_util.string_opt_to_json_trimmed worker_run_id );
        ( "evidence_refs",
          `List (List.map (fun value -> `String value) evidence_refs) );
      ]
  in
  let actor = Workspace_hooks.{ kind = "agent"; id = from_agent } in
  let emit ?subject ~kind ~tags () =
    try
      (Atomic.get Workspace_hooks.activity_emit_fn) config
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
        ~subject:Workspace_hooks.{ kind = "agent"; id = target }
        ~kind:(Event_kind.Message.to_string Event_kind.Message.Mentioned)
        ~tags:[ "message"; "mention" ] ()
  | None | Some _ -> ()

let broadcast_channel config =
  Printf.sprintf "broadcast:%s:default" (project_prefix config)

let on_broadcast_mention : (string option -> unit) ref =
  ref (fun _mention -> ())

let broadcast ?trace_context ?(msg_type = "broadcast")
    ?(task_cache_invariant_checked = false) config ~from_agent ~content =
  let started_at = Time_compat.now () in
  let observe final_msg_type =
    let elapsed_s = Float.max 0.0 (Time_compat.now () -. started_at) in
    try (Atomic.get Workspace_hooks.workspace_broadcast_observed_fn)
          ~msg_type:final_msg_type ~elapsed_s
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()
  in
  ensure_initialized config;

  (* RFC-0061: preserve original content and extract mention tokens BEFORE
     any fleet-wide invariant rewrite. This prevents stage-1 wake signal loss
     when [cache_invalidated] replaces the original broadcast text. *)
  let pre_extract_mention = Mention.extract content in

  (* Fleet-wide invariant (PR-B): if the broadcasting agent's current_task is
     terminal in the backlog, replace the original broadcast with a single
     cache_invalidated notice and clear the stale state (issue #13397).
     Only applied to regular "broadcast" messages to avoid recursion. *)
  let content, msg_type, _rewrites =
    if task_cache_invariant_checked then (content, msg_type, [])
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
                      ~module_name:"workspace_broadcast";
                    let inv_content =
                      Printf.sprintf
                        "[cache_invalidated] workspace_broadcast: task %s is %s \
                         — stale broadcast suppressed"
                        task_id (Masc_domain.task_status_to_string status)
                    in
                    ( inv_content,
                      "cache_invalidated",
                      [
                        {
                          reason =
                            Cache_invalidated
                              {
                                task_id;
                                status =
                                  Masc_domain.task_status_to_string status;
                              };
                          module_name = "workspace_broadcast";
                        };
                      ] )
                | _ ->
                    ( Workspace_task_cache_invariant.rewrite_broadcast_content
                        ~config ~from_agent ~module_name:"workspace_broadcast"
                        ~content,
                      msg_type,
                      [
                        {
                          reason = Task_cache_rewrite;
                          module_name = "workspace_broadcast";
                        };
                      ] ))
            | None ->
                ( Workspace_task_cache_invariant.rewrite_broadcast_content
                    ~config ~from_agent ~module_name:"workspace_broadcast"
                    ~content,
                  msg_type,
                  [
                    {
                      reason = Task_cache_rewrite;
                      module_name = "workspace_broadcast";
                    };
                  ] ))
        | Error _ ->
            ( Workspace_task_cache_invariant.rewrite_broadcast_content
                ~config ~from_agent ~module_name:"workspace_broadcast" ~content,
              msg_type,
              [
                {
                  reason = Task_cache_rewrite;
                  module_name = "workspace_broadcast";
                };
              ] )
      else
        ( Workspace_task_cache_invariant.rewrite_broadcast_content
            ~config ~from_agent ~module_name:"workspace_broadcast" ~content,
          msg_type,
          [
            { reason = Task_cache_rewrite; module_name = "workspace_broadcast" };
          ] )
    else (content, msg_type, [])
  in
  let seq = Workspace_state.next_seq config in
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
    expires_at = None;
    relevance = Event_kind.Relevance.(to_string Medium);
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
   | Error ((Backend_types.BackendNotSupported _
            | Backend_types.NotFound _ | Backend_types.AlreadyExists _
            | Backend_types.IOError _ | Backend_types.InvalidKey _
            | Backend_types.ConnectionFailed _) as e) ->
       Log.Misc.error "broadcast publish failed: %s" (Backend_types.show_error e));
  emit_message_activity config ~from_agent:safe_agent ~content:safe_content
    ~mention ();
  (try !on_broadcast_mention mention
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Misc.warn "on_broadcast_mention callback failed: %s"
       (Printexc.to_string exn));
  observe safe_msg_type;
  Printf.sprintf "\xF0\x9F\x93\xA2 [%s] %s" safe_agent safe_content
