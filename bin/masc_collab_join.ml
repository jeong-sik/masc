(* Terminal guest for collab rooms. Rendering is pure and total over
   the keeper event variant: anything the host can journal, the guest
   can draw or deliberately skip. *)

module Ev = Masc.Keeper_chat_events
module Log = Masc.Keeper_chat_event_log

let short_id id =
  if String.length id <= 8 then id else String.sub id 0 8
;;

let truncate ~max s =
  if String.length s <= max
  then s
  else String.sub s 0 max ^ "…"
;;

let split_lines s =
  if String.equal s "" then [] else String.split_on_char '\n' s
;;

let role_header = function
  | Ev.User -> "you:"
  | Ev.Assistant -> "keeper:"
;;

let delivery_target_text = function
  | Masc.Keeper_surface_post.Delivered_to_dashboard -> "dashboard"
  | Masc.Keeper_surface_post.Delivered_to_discord { channel_id } ->
    "discord #" ^ channel_id
  | Masc.Keeper_surface_post.Delivered_to_slack { channel_id; thread_ts } ->
    (match thread_ts with
     | None -> Printf.sprintf "slack %s" channel_id
     | Some ts -> Printf.sprintf "slack %s/%s" channel_id ts)
;;

(* Thinking stays host-side: guests watch speech and tools, not the
   chain of thought behind them. Usage counters, pings, and stream
   bookkeeping are skipped for the same reason chat skips them. *)
let rec render_event (event : Ev.keeper_chat_event) : string list =
  match event with
  | Ev.Run_started { run_id; _ } -> [ "── run " ^ short_id run_id ^ " ──" ]
  | Ev.Batch_bound _ -> []
  | Ev.Text_message_start { role; _ } -> [ role_header role ]
  | Ev.Text_delta delta -> split_lines delta
  | Ev.Text_message_end -> [ "" ]
  | Ev.External_effect_completed { target } ->
    [ "(already delivered to " ^ delivery_target_text target ^ ")" ]
  | Ev.Run_finished { run_id } -> [ "── run " ^ short_id run_id ^ " done ──" ]
  | Ev.Event_error { message } -> [ "error: " ^ message ]
  | Ev.Reply_details _ -> []
  | Ev.Continuation_checkpoint { message; _ } -> [ "(checkpoint) " ^ message ]
  | Ev.Agent_core_stream_connected -> []
  | Ev.Agent_core_runtime_attempt_started { runtime_id; attempt_index } -> (
    match attempt_index with
    | Some 0 | None -> []
    | Some n ->
      let via =
        match runtime_id with
        | None -> ""
        | Some id -> " via " ^ short_id id
      in
      [ Printf.sprintf "(retrying: attempt %d%s)" n via ])
  | Ev.Agent_core_stream_message_start _ -> []
  | Ev.Agent_core_stream_message_delta _ -> []
  | Ev.Agent_core_stream_message_stop -> []
  | Ev.Agent_core_stream_ping -> []
  | Ev.Agent_core_content_block_start _ -> []
  | Ev.Agent_core_content_block_stop _ -> []
  | Ev.Agent_core_thinking_delta _ -> []
  | Ev.Agent_core_thinking_signature_delta _ -> []
  | Ev.Agent_core_media_delta { media_type; media_ref; _ } ->
    [ "(media " ^ media_type ^ ": " ^ media_ref ^ ")" ]
  | Ev.Agent_core_stream_protocol_error _ -> [ "(stream protocol error)" ]
  | Ev.Tool_call_start { tool_call_name; _ } -> [ "tool: " ^ tool_call_name ]
  | Ev.Tool_call_args _ -> []
  | Ev.Tool_call_args_snapshot { snapshot; _ } ->
    [ "  args: " ^ truncate ~max:500 snapshot ]
  | Ev.Tool_call_end _ -> []
  | Ev.Tool_approval_requested { tool_call_name; question; because; _ } ->
    [ "approval needed (host only): "
      ^ tool_call_name
      ^ " — "
      ^ question
      ^ " ("
      ^ because
      ^ ")"
    ]
  | Ev.Tool_approval_settled { outcome; _ } -> [ "approval settled: " ^ outcome ]
  | Ev.Tool_result_ready _ -> [ "(tool finished)" ]
  | Ev.Link_block { url; title; _ } -> [ "link: " ^ title ^ " <" ^ url ^ ">" ]
  | Ev.Image_block { url; caption } -> (
    match caption with
    | None -> [ "image: " ^ url ]
    | Some text -> [ "image: " ^ url ^ " (" ^ text ^ ")" ])
  | Ev.Status_block status ->
    [ "(status) " ^ Masc.Keeper_chat_blocks.status_kind_connector_text status.Masc.Keeper_chat_blocks.kind ]
  | Ev.Audio_block { message_text; _ } -> [ "audio: " ^ message_text ]
  | Ev.Tool_context_block { name; args_summary; result_summary } -> (
    let head = "tool: " ^ name ^ " (" ^ truncate ~max:300 args_summary ^ ")" in
    match result_summary with
    | None -> [ head ]
    | Some result -> [ head; "  = " ^ truncate ~max:500 result ])
;;

let render_snapshot_row json =
  match Log.journaled_event_of_json json with
  | Error detail -> [ "(unreadable snapshot row: " ^ detail ^ ")" ]
  | Ok row -> render_event row.Log.event
;;

let render_live_event json =
  match Log.keeper_chat_event_of_json json with
  | Error detail -> [ "(unreadable live event: " ^ detail ^ ")" ]
  | Ok event -> render_event event
;;

(* -- line UI ---------------------------------------------------------- *)

let default_fetch_bytes = 65536

type error =
  | Resolve_failed of Collab_guest_join.resolve_error
  | Connect_failed of Collab_guest_session.connect_error

let error_to_string = function
  | Resolve_failed err -> Collab_guest_join.resolve_error_to_string err
  | Connect_failed err -> Collab_guest_session.connect_error_to_string err
;;

let run ~env ~link ~relay ~label =
  match Collab_guest_join.resolve ~link ~relay with
  | Error err -> Error (Resolve_failed err)
  | Ok target ->
    Eio.Switch.run (fun sw ->
        let print_mutex = Eio.Mutex.create () in
        let say line =
          Eio.Mutex.use_rw ~protect:true print_mutex (fun () ->
              print_endline line;
              flush stdout)
        in
        let done_promise, done_resolver = Eio.Promise.create () in
        (* The reader and input fibers race to finish; the loser's
           resolve is dropped, never an exception. *)
        let finish code =
          match Eio.Promise.peek done_promise with
          | Some _ -> ()
          | None -> (
            try Eio.Promise.resolve done_resolver code with
            | Invalid_argument _ -> ())
        in
        let bye_seen = ref false in
        let on_event = function
          | Collab_guest_session.Frame_event event -> (
            match event with
            | Collab_guest_join.Snapshot_row row ->
              List.iter say (render_snapshot_row row)
            | Collab_guest_join.Live_entry entry ->
              List.iter say (render_live_event entry.Collab_frame.event)
            | Collab_guest_join.State state ->
              say
                (Printf.sprintf "(%s · %d guest%s)"
                   (if state.Collab_frame.active then "live" else "idle")
                   state.Collab_frame.guests
                   (if state.Collab_frame.guests = 1 then "" else "s"))
            | Collab_guest_join.Transcript transcript -> (
              match transcript.Collab_frame.error with
              | Some detail -> say ("(transcript error: " ^ detail ^ ")")
              | None ->
                say transcript.Collab_frame.text;
                if transcript.Collab_frame.new_size > String.length transcript.Collab_frame.text
                then
                  say
                    (Printf.sprintf "(%d of %d bytes shown)"
                       (String.length transcript.Collab_frame.text)
                       transcript.Collab_frame.new_size))
            | Collab_guest_join.Bye reason ->
              bye_seen := true;
              say ("(host ended the share: " ^ reason ^ ")")
            | Collab_guest_join.Error_frame message -> say ("(host error: " ^ message ^ ")"))
          | Collab_guest_session.Transport_closed { code; reason } ->
            say
              (match code with
               | Some code -> Printf.sprintf "(disconnected %d: %s)" code reason
               | None -> "(disconnected without status)");
            finish (if !bye_seen then 0 else 1)
        in
        (match
           Collab_guest_session.connect ~sw ~env ~target ~label ~on_event
         with
         | Error err -> Error (Connect_failed err)
         | Ok handle ->
           say
             (Printf.sprintf "joined as %s — /abort /fetch /quit"
                (match Collab_guest_session.capability handle with
                 | Collab_link.View -> "view-only guest"
                 | Collab_link.Control -> "control guest"));
           let req_id = ref 0 in
           let stdin = Eio.Stdenv.stdin env in
           (* One stdin line, read directly: EOF is a precise quit, and a
              [Buf_read] result would conflate it with a parse error. *)
           (* Bytes past the newline stay pending for the next line, so
              a paste never eats its own tail. *)
           let pending = ref "" in
           let read_line () =
             let buf = Buffer.create 256 in
             Buffer.add_string buf !pending;
             pending := "";
             let chunk = Cstruct.create 1024 in
             let rec loop () =
               let so_far = Buffer.contents buf in
               match String.index_opt so_far '\n' with
               | Some nl ->
                 pending := String.sub so_far (nl + 1) (String.length so_far - nl - 1);
                 String.sub so_far 0 nl
               | None -> (
                 match Eio.Flow.single_read stdin chunk with
                 | exception End_of_file ->
                   (* A final line without its newline still counts; the
                      next read raises again and quits. *)
                   if Buffer.length buf = 0 then raise End_of_file else Buffer.contents buf
                 | n ->
                   Buffer.add_string buf
                     (Cstruct.to_string (Cstruct.sub chunk 0 n));
                   loop ())
             in
             loop ()
           in
           let rec input_loop () =
             match read_line () with
             | exception End_of_file -> finish 0
             | line -> (
               let text = String.trim line in
               if String.equal text "/quit"
               then finish 0
               else (
                 (if String.equal text "/abort"
                  then (
                    match Collab_guest_session.send_abort handle with
                    | Ok () -> ()
                    | Error err -> say (Collab_guest_session.send_error_to_string err))
                  else if String.equal text "/fetch" || String.starts_with ~prefix:"/fetch " text
                  then (
                    let max_bytes =
                      match String.split_on_char ' ' text with
                      | [ _; n ] -> (
                        match int_of_string_opt (String.trim n) with
                        | Some b when b > 0 -> b
                        | _ -> default_fetch_bytes)
                      | _ -> default_fetch_bytes
                    in
                    incr req_id;
                    (match
                       Collab_guest_session.fetch_transcript handle ~req_id:!req_id
                         ~max_bytes
                     with
                     | Ok () -> ()
                     | Error err -> say (Collab_guest_session.send_error_to_string err)))
                  else if String.equal text ""
                  then ()
                  else if String.starts_with ~prefix:"/" text
                  then say "(unknown command — /abort /fetch /quit)"
                  else (
                    match Collab_guest_session.send_prompt handle text with
                    | Ok () -> ()
                    | Error err -> say (Collab_guest_session.send_error_to_string err)));
                 input_loop ()))
           in
           Eio.Fiber.fork ~sw input_loop;
           let code = Eio.Promise.await done_promise in
           Collab_guest_session.close handle;
           Ok code))
;;
