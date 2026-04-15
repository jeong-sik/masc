(** Room Broadcast - Message broadcasting and activity emission.

    Extracted from room_state.ml. Depends on Room_state for
    next_seq and normalized_string_list. *)

open Types
open Room_utils

let emit_message_activity config ~from_agent ~content ~mention
    ?session_id ?operation_id ?worker_run_id ?(evidence_refs = []) () =
  let evidence_refs = Room_state.normalized_string_list evidence_refs in
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
  let actor = Room_hooks.{ kind = "agent"; id = from_agent } in
  let emit ?subject ~kind ~tags () =
    try
      !Room_hooks.activity_emit_fn config
        ~actor ?subject ~kind ~payload ~tags ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Misc.warn "message activity emit failed (%s): %s" kind
          (Printexc.to_string exn)
  in
  emit ~kind:"message.broadcast" ~tags:[ "message"; "broadcast" ] ();
  match mention with
  | Some target when String.trim target <> "" ->
      emit
        ~subject:Room_hooks.{ kind = "agent"; id = target }
        ~kind:"message.mentioned"
        ~tags:[ "message"; "mention" ] ()
  | _ -> ()

let broadcast_channel config =
  Printf.sprintf "broadcast:%s:default" (project_prefix config)

let on_broadcast_mention : (string option -> unit) ref =
  ref (fun _mention -> ())

let broadcast ?trace_context config ~from_agent ~content =
  ensure_initialized config;
  let seq = Room_state.next_seq config in
  let mention = Mention.extract content in
  let safe_content = sanitize_message content in
  let safe_agent = sanitize_agent_name from_agent in
  let msg = {
    seq;
    from_agent = safe_agent;
    msg_type = "broadcast";
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
  Printf.sprintf "\xF0\x9F\x93\xA2 [%s] %s" safe_agent safe_content
