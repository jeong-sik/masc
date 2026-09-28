let snapshot_chunk_bytes = 524288
let snapshot_total_bytes = 8388608
let live_queue_cap = 4096
let max_guest_label_bytes = 64

type live_item = {
  op : string;
  seq : int;
  ts : float;
  event : Keeper_chat_events.keeper_chat_event;
}

type session = {
  room : Collab_link.room;
  key : Collab_seal.key;
  keeper : string;
  base_dir : string;
  send : room:Collab_relay.room_id -> string -> unit;
  injector : Server_collab_inject.injector;
  mutable last_op : string option;
  queue : live_item Queue.t;
  queue_mutex : Eio.Mutex.t;
  queue_cond : Eio.Condition.t;
  mutable queue_closed : bool;
  mutable queue_len : int;
  mutable queue_dropped : int;
  auth : (Collab_relay.peer, Collab_link.capability) Hashtbl.t;
  labels : (Collab_relay.peer, string) Hashtbl.t;
  joined : (Collab_relay.peer, unit) Hashtbl.t;
  unfinished_runs : (string, string) Hashtbl.t;
      (* run_id -> operation, for op-scoped failure clearing *)
  mutable guests : int;
  state_mutex : Stdlib.Mutex.t;
  hello_mutex : Eio.Mutex.t;
}

(* Process registries under one Stdlib mutex. Never nested with a session
   queue mutex: collect under one, act under the other. *)
let registry_mutex = Stdlib.Mutex.create ()
let sessions_by_keeper : (string, session list) Hashtbl.t = Hashtbl.create 16
let latest_operation : (string, string) Hashtbl.t = Hashtbl.create 64

type start_error =
  | Room_conflict
  | Seal_key_rejected

(* -- sealing ----------------------------------------------------------- *)

(* Seal one frame and pack it for [target]. The pack cannot fail: callers
   pass 0 (broadcast) or a relay-assigned peer id. *)
let seal_for s ~target frame =
  let sealed = Collab_seal.seal s.key (Collab_frame.frame_to_string frame) in
  match Collab_envelope.pack ~peer:target sealed with
  | Ok envelope -> Some envelope
  | Error (Collab_envelope.Peer_id_out_of_range _) ->
    Log.Server.debug "collab host %s: target %d unencodable" s.keeper target;
    None
;;

let send_frame s ~target frame =
  match seal_for s ~target frame with
  | None -> ()
  | Some envelope -> s.send ~room:s.room.Collab_link.id envelope
;;

let broadcast_state s =
  let active, guests =
    Stdlib.Mutex.protect s.state_mutex (fun () ->
        ( Hashtbl.length s.unfinished_runs > 0,
          if s.guests < 0 then 0 else s.guests ))
  in
  send_frame s ~target:Collab_envelope.broadcast_peer
    (Collab_frame.Live_state { active; guests })
;;

(* -- run liveness ------------------------------------------------------ *)

(* Only run-boundary constructors affect liveness; every other event keeps
   the current state. A new boundary-like constructor would need an arm
   here — the chat event type is journaled and versioned, so such additions
   are rare and reviewed. A miss sticks [active] until the next boundary,
   and guests see the live events either way. *)
type run_boundary =
  | Run_started of string
  | Run_finished of string
  | Run_failed
  | Other

let run_boundary_of_event : Keeper_chat_events.keeper_chat_event -> run_boundary
  = function
  | Keeper_chat_events.Run_started { run_id; _ } -> Run_started run_id
  | Keeper_chat_events.Run_finished { run_id } -> Run_finished run_id
  | Keeper_chat_events.Event_error _ -> Run_failed
  | _ -> Other
;;

let note_run_boundary s ~op boundary =
  let flipped =
    Stdlib.Mutex.protect s.state_mutex (fun () ->
        let before = Hashtbl.length s.unfinished_runs > 0 in
        (match boundary with
         | Run_started id -> Hashtbl.replace s.unfinished_runs id op
         | Run_finished id -> Hashtbl.remove s.unfinished_runs id
         | Run_failed ->
           Hashtbl.filter_map_inplace
             (fun _ run_op ->
               if String.equal run_op op then None else Some run_op)
             s.unfinished_runs
         | Other -> ());
        let after = Hashtbl.length s.unfinished_runs > 0 in
        before <> after)
  in
  if flipped then broadcast_state s
;;

(* -- snapshot ---------------------------------------------------------- *)

(* Latest operation for a snapshot: the hook's exact record when this keeper
   has published since boot, else the most recently modified journal
   (mtime, ties by name — journals carry no cross-file order). Runs in a
   systhread: readdir/stat must not stall the domain. *)
let resolve_snapshot_op ~base_dir ~keeper =
  Eio_unix.run_in_systhread (fun () ->
      let from_hook =
        Stdlib.Mutex.protect registry_mutex (fun () ->
            Hashtbl.find_opt latest_operation keeper)
      in
      match from_hook with
      | Some op -> Some op
      | None ->
        let keeper_dir =
          Filename.concat
            (Keeper_chat_event_log.events_dir ~base_dir)
            (Workspace_utils_backend_setup.sanitize_namespace_segment keeper)
        in
        (match Sys.readdir keeper_dir with
         | files ->
           let best = ref None in
           Array.iter
             (fun name ->
               if Filename.check_suffix name ".jsonl"
               then (
                 match Unix.stat (Filename.concat keeper_dir name) with
                 | { st_mtime; _ } ->
                   let op = Filename.chop_suffix name ".jsonl" in
                   (match !best with
                    | None -> best := Some (st_mtime, op)
                    | Some (mtime, prev) ->
                      if
                        st_mtime > mtime
                        || (Float.equal st_mtime mtime
                           && String.compare op prev > 0)
                      then best := Some (st_mtime, op))
                 | exception Unix.Unix_error _ -> ()))
             files;
           Option.map snd !best
         | exception Sys_error _ -> None))
;;

(* Read the tail window of an oversize journal: the last [snapshot_total_bytes]
   bytes from the first line boundary inside the window. Bypasses the locked
   journal reader (which materializes the whole file); a torn tail row from a
   concurrent append fails JSON validation downstream and is skipped like any
   other unparsable row. *)
let read_tail_window path =
  match Unix.stat path with
  | exception Unix.Unix_error _ -> None
  | { st_size; _ } when st_size <= snapshot_total_bytes -> None
  | { st_size; _ } ->
    (match open_in_bin path with
     | exception Sys_error _ -> Some ""
     | ic ->
       Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
           try
             seek_in ic (st_size - snapshot_total_bytes);
             (try
                let rec skip_partial () =
                  match input_char ic with
                  | '\n' -> ()
                  | _ -> skip_partial ()
                in
                skip_partial ()
              with End_of_file -> ());
             Some
               (try In_channel.input_all ic
                with End_of_file | Sys_error _ -> "")
           with
           (* The journal shrank or vanished between stat and read: fall
              back to the locked full reader, which re-stats and reads
              whatever is there now. *)
           | Sys_error _ | Invalid_argument _ -> None))
;;

(* Read one operation's journal as validated JSON rows. Unreadable journals
   and unparsable rows are skipped (rows are counted after the skip, so the
   count always matches what goes out). Journals past [snapshot_total_bytes]
   snapshot their tail only — a guest hello must never page a gigabyte of
   history into the host. Runs in a systhread: file IO must not stall the
   domain. *)
let read_snapshot_rows ~base_dir ~keeper ~operation =
  Eio_unix.run_in_systhread (fun () ->
      let path =
        Keeper_chat_event_log.journal_path ~base_dir ~keeper_name:keeper
          ~operation_id:operation
      in
      let rows =
        match read_tail_window path with
        | Some tail -> tail
        | None ->
          (match Keeper_chat_event_log.read_journal_rows_path path with
           | Error _ -> ""
           | Ok rows -> rows)
      in
      (match rows with
       | "" -> []
       | rows ->
         (* Rows arrive newline-terminated, so the split leaves one
            trailing blank; blank rows are skipped like the journal pager
            skips them. *)
         let valid, skipped =
           List.fold_left
             (fun (valid, skipped) row ->
               if String.equal (String.trim row) ""
               then valid, skipped
               else (
                 match Yojson.Safe.from_string row with
                 | json -> (json, String.length row) :: valid, skipped
                 | exception Yojson.Json_error _ -> valid, skipped + 1))
             ([], 0)
             (String.split_on_char '\n' rows)
         in
         if skipped > 0
         then
           Log.Server.warn
             "collab host %s: snapshot skipped %d unparsable journal rows"
             keeper
             skipped;
         List.rev valid))
;;

(* Pack rows into chunks under [snapshot_chunk_bytes]; rows are measured by
   their wire bytes. A single row past the cap is skipped with a warning.
   Always yields at least one (possibly empty, final) chunk. *)
let chunk_rows ~keeper rows =
  let chunks, current, _ =
    List.fold_left
      (fun (chunks, current, size) (json, bytes) ->
        if bytes > snapshot_chunk_bytes
        then (
          Log.Server.warn
            "collab host %s: snapshot skipped an oversize journal row (%d bytes)"
            keeper
            bytes;
          chunks, current, size)
        else if size + bytes > snapshot_chunk_bytes && current <> []
        then List.rev current :: chunks, [ json ], bytes
        else chunks, json :: current, size + bytes)
      ([], [], 0)
      rows
  in
  let ordered = List.rev chunks in
  let ordered =
    if current = [] then ordered else ordered @ [ List.rev current ]
  in
  match ordered with
  | [] -> [ [] ]
  | _ :: _ -> ordered
;;

(* -- guest frames ------------------------------------------------------ *)

let verify_token s presented =
  (* 16 bytes encode to exactly 22 unpadded characters: reject anything
     else before paying for a base64 decode of unbounded guest input. *)
  if String.length presented <> 22
  then None
  else (
    (match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet presented with
     | Error (`Msg _) -> None
     | Ok raw ->
       if String.length raw <> 16
       then None
       else if Eqaf.equal raw s.room.Collab_link.write_token
       then Some ()
       else None))
;;

(* [active] is tracked from the live stream only, never seeded from the
   snapshot: merging old snapshot boundaries against concurrent live
   updates races (a finish landing before its seed sticks forever), while
   the unseeded lie is bounded to the in-flight turn and self-heals on the
   next boundary. *)
let send_snapshot_chunks ~peer s chunks =
  let total = List.length chunks in
  List.iteri
    (fun i entries ->
      send_frame s ~target:peer
        (Collab_frame.Snapshot_chunk { entries; final = i = total - 1 }))
    chunks
;;

let snapshot_entry_count chunks =
  List.fold_left (fun acc entries -> acc + List.length entries) 0 chunks
;;

let handle_hello_locked s ~peer (hello : Collab_frame.hello) =
  if hello.proto <> Collab_wire.proto_version
  then
    send_frame s ~target:peer
      (Collab_frame.Error_frame
         (Printf.sprintf
            "unsupported collab protocol %d (host speaks %d)"
            hello.proto
            Collab_wire.proto_version))
  else (
    let capability =
      match hello.write_token with
      | None -> Collab_link.View
      | Some presented ->
        (match verify_token s presented with
         | Some () -> Collab_link.Control
         | None ->
           Log.Server.debug
             "collab host %s: peer %d presented a bad write token; view-only"
             s.keeper
             peer;
           Collab_link.View)
    in
    (* The hello label is guest-chosen display text: trim it, and drop it
       (not truncate — a half-grapheme name is worse than none) past the
       cap or when blank, so prompts always carry a sane speaker name. *)
    let label =
      match hello.Collab_frame.label with
      | None -> None
      | Some raw ->
        let trimmed = String.trim raw in
        if String.equal trimmed "" || String.length trimmed > max_guest_label_bytes
        then (
          if String.length trimmed > max_guest_label_bytes
          then
            Log.Server.debug
              "collab host %s: peer %d hello label over %d bytes; dropped"
              s.keeper
              peer
              max_guest_label_bytes;
          None)
        else Some trimmed
    in
    Stdlib.Mutex.protect s.state_mutex (fun () ->
        Hashtbl.replace s.auth peer capability;
        (match label with
         | None -> Hashtbl.remove s.labels peer
         | Some name -> Hashtbl.replace s.labels peer name));
    let operation =
      match resolve_snapshot_op ~base_dir:s.base_dir ~keeper:s.keeper with
      | Some op ->
        Workspace_utils_backend_setup.sanitize_namespace_segment op
      | None -> ""
    in
    let rows =
      if String.equal operation ""
      then []
      else read_snapshot_rows ~base_dir:s.base_dir ~keeper:s.keeper ~operation
    in
    let chunks = chunk_rows ~keeper:s.keeper rows in
    let entry_count = snapshot_entry_count chunks in
    let active, guests =
      Stdlib.Mutex.protect s.state_mutex (fun () ->
          ( Hashtbl.length s.unfinished_runs > 0,
            if s.guests < 0 then 0 else s.guests ))
    in
    send_frame s ~target:peer
      (Collab_frame.Welcome
         { proto = Collab_wire.proto_version
         ; header = { keeper = s.keeper; operation }
         ; state = { active; guests }
         ; entry_count
         ; read_only = capability = Collab_link.View
         });
    send_snapshot_chunks ~peer s chunks)
;;

let is_control s ~peer =
  Stdlib.Mutex.protect s.state_mutex (fun () ->
      Hashtbl.find_opt s.auth peer)
  = Some Collab_link.Control
;;

let send_error s ~peer message =
  send_frame s ~target:peer (Collab_frame.Error_frame message)
;;

(* Injection entries may raise (registry defects, store faults); a raising
   guest frame must answer with an error, not kill the guest fiber.
   Cancellation still propagates. *)
let guard_inject s ~peer ~op f =
  match f () with
  | result -> result
  | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
  | exception ex ->
    Log.Server.warn
      "collab host %s: guest %d %s raised: %s"
      s.keeper
      peer
      op
      (Printexc.to_string ex);
    (* The guest gets a generic failure: exception text carries host
       internals (paths, backtraces) that a guest must never read.
       Curated injector errors pass through {!guard_inject} untouched. *)
    Error (Printf.sprintf "%s failed; the host log has detail" op)
;;

let handle_prompt s ~peer text =
  if not (is_control s ~peer)
  then send_error s ~peer "control link required to prompt"
  else (
    let label =
      Stdlib.Mutex.protect s.state_mutex (fun () ->
          Hashtbl.find_opt s.labels peer)
    in
    match
      guard_inject s ~peer ~op:"prompt" (fun () ->
          Result.map_error
            Server_collab_inject.prompt_error_to_string
            (s.injector.submit_prompt
               ~base_dir:s.base_dir
               ~keeper:s.keeper
               ~room:s.room.Collab_link.id
               ~peer
               ~label
               ~text))
    with
    | Ok operation_id ->
      (* Silent success: the turn announces itself on the live stream. *)
      Log.Server.debug
        "collab host %s: guest %d prompt queued as %s"
        s.keeper
        peer
        operation_id
    | Error detail -> send_error s ~peer detail)
;;

let handle_abort s ~peer =
  if not (is_control s ~peer)
  then send_error s ~peer "control link required to abort"
  else (
    let latest_op =
      Stdlib.Mutex.protect s.state_mutex (fun () -> s.last_op)
    in
    match
      guard_inject s ~peer ~op:"abort" (fun () ->
          Ok
            (s.injector.abort_current
               ~base_dir:s.base_dir
               ~keeper:s.keeper
               ~latest_op))
    with
    | Ok (Server_collab_inject.Aborted operation_id) ->
      Log.Server.debug
        "collab host %s: guest %d aborted %s"
        s.keeper
        peer
        operation_id
    | Ok Server_collab_inject.Nothing_running ->
      Log.Server.debug
        "collab host %s: guest %d abort found nothing running"
        s.keeper
        peer
    | Ok (Server_collab_inject.Abort_failed detail)
    | Error detail -> send_error s ~peer detail)
;;

let handle_fetch s ~peer (req : Collab_frame.fetch_transcript) =
  (* Reads are view-safe: guests need scrollback. *)
  match
    guard_inject s ~peer ~op:"fetch-transcript" (fun () ->
        Ok
          (s.injector.fetch_transcript
             ~base_dir:s.base_dir
             ~keeper:s.keeper
             ~max_bytes:req.max_bytes))
  with
  | Ok fetched ->
    let error =
      if fetched.Server_collab_inject.capped
      then Some "transcript exceeds walk caps; showing newest"
      else None
    in
    send_frame s ~target:peer
      (Collab_frame.Transcript
         { req_id = req.req_id
         ; text = fetched.text
         ; new_size = fetched.total_bytes
         ; error
         })
  | Error detail ->
    send_frame s ~target:peer
      (Collab_frame.Transcript
         { req_id = req.req_id; text = ""; new_size = 0; error = Some detail })
;;

let handle_frame s ~peer ~payload =
  match Collab_seal.open_sealed s.key payload with
  | Error _ ->
    (* Hosts discard undecryptable guest frames without closing the room. *)
    Log.Server.debug "collab host %s: undecryptable frame from %d" s.keeper peer
  | Ok text ->
    (match Collab_frame.frame_of_string text with
     | None ->
       Log.Server.debug
         "collab host %s: malformed frame from %d"
         s.keeper
         peer
     | Some (Collab_frame.Hello hello) ->
       (* Hellos each re-read the snapshot: serialize them per session
          so a burst of joins never stacks concurrent multi-megabyte
          reads. A key-holding guest can still re-hello serially; the
          host stops sharing if that becomes abuse. *)
       Eio.Mutex.use_rw ~protect:false s.hello_mutex (fun () ->
           handle_hello_locked s ~peer hello)
     | Some (Collab_frame.Prompt text) -> handle_prompt s ~peer text
     | Some Collab_frame.Abort -> handle_abort s ~peer
     | Some (Collab_frame.Fetch_transcript req) -> handle_fetch s ~peer req
     | Some (Collab_frame.Welcome _)
     | Some (Collab_frame.Snapshot_chunk _)
     | Some (Collab_frame.Entry _)
     | Some (Collab_frame.Live_state _)
     | Some (Collab_frame.Transcript _)
     | Some (Collab_frame.Bye _)
     | Some (Collab_frame.Error_frame _) ->
       (* Host-to-guest frames from a guest: protocol violation, no close. *)
       Log.Server.debug
         "collab host %s: unexpected frame kind from %d"
         s.keeper
         peer)
;;

let handle_envelope s envelope =
  match Collab_envelope.unpack envelope with
  | None ->
    Log.Server.debug "collab host %s: malformed envelope" s.keeper
  | Some (peer, _) when peer <= 0 || peer > Collab_envelope.max_peer ->
    (* The relay rewrites guest envelopes to the sender's nonzero peer id, so
       zero or out-of-range can only arrive off-path; accepting zero would
       unicast the welcome to the broadcast target. *)
    Log.Server.debug "collab host %s: impossible guest peer %d" s.keeper peer
  | Some (peer, payload) -> handle_frame s ~peer ~payload
;;

(* -- membership -------------------------------------------------------- *)

let peer_joined s peer =
  let fresh =
    Stdlib.Mutex.protect s.state_mutex (fun () ->
        if Hashtbl.mem s.joined peer
        then false
        else (
          Hashtbl.replace s.joined peer ();
          s.guests <- s.guests + 1;
          true))
  in
  if fresh then broadcast_state s
;;

let peer_left s peer =
  let departed =
    Stdlib.Mutex.protect s.state_mutex (fun () ->
        Hashtbl.remove s.auth peer;
        Hashtbl.remove s.labels peer;
        if Hashtbl.mem s.joined peer
        then (
          Hashtbl.remove s.joined peer;
          s.guests <- s.guests - 1;
          true)
        else false)
  in
  if departed then broadcast_state s
;;

(* -- live forward ------------------------------------------------------ *)

(* Every item here passed {!Keeper_chat_event_log.journalable} at the
   publish hook, so the live stream never carries an event the journal
   refused to keep (and its JSON always encodes). *)
let forward_item s ~room_seq item =
  (* The raw op id (pre-sanitize: sanitize folds '.' which op ids allow)
     so guest aborts name the exact operation they watched. *)
  Stdlib.Mutex.protect s.state_mutex (fun () -> s.last_op <- Some item.op);
  (* Sanitize here (not on the publish hook) so live op ids match the
     snapshot op exactly for guest-side overlap joins. *)
  let op =
    Workspace_utils_backend_setup.sanitize_namespace_segment item.op
  in
  note_run_boundary s ~op (run_boundary_of_event item.event);
  let event_json =
    Keeper_chat_event_log.keeper_chat_event_to_json item.event
  in
  send_frame s ~target:Collab_envelope.broadcast_peer
    (Collab_frame.Entry
       { seq = room_seq; op; op_seq = item.seq; ts = item.ts; event = event_json })
;;

let forwarder s =
  let room_seq = ref 1 in
  let rec loop () =
    Eio.Mutex.use_ro s.queue_mutex (fun () ->
        while Queue.is_empty s.queue && not s.queue_closed do
          Eio.Condition.await s.queue_cond s.queue_mutex
        done);
    let batch, closed =
      Eio.Mutex.use_rw ~protect:false s.queue_mutex (fun () ->
          let rec drain acc =
            match Queue.take_opt s.queue with
            | None -> List.rev acc
            | Some item ->
              s.queue_len <- s.queue_len - 1;
              drain (item :: acc)
          in
          let batch = drain [] in
          (* The drain takes everything, so a clean queue re-arms the
             overflow warning: one warning per overflow episode, not one per
             session and not one per dropped event. *)
          s.queue_dropped <- 0;
          batch, s.queue_closed)
    in
    let send_item item =
      let seq = !room_seq in
      room_seq := seq + 1;
      match forward_item s ~room_seq:seq item with
      | () -> ()
      | exception (Eio.Cancel.Cancelled _ as ex) -> raise ex
      | exception ex ->
        (* One poison event (a seal defect, a store fault mid-send) must
           not end the room: skip it loudly. The failure modes are not
           enumerated, so this stays a guarded catch-all with
           cancellation re-raised. *)
        Log.Server.warn
          "collab host %s: dropped unforwardable event (op %s seq %d): %s"
          s.keeper
          item.op
          item.seq
          (Printexc.to_string ex)
    in
    let rec send_batch = function
      | [] -> ()
      | item :: rest ->
        (* Stop may land mid-batch; entries must not follow the bye. A
           send already inside the socket write can still complete after
           it (unfixable without acks — guests ignore post-bye frames),
           but nothing new starts once closed. *)
        let closed_now =
          Eio.Mutex.use_ro s.queue_mutex (fun () -> s.queue_closed)
        in
        if closed_now
        then
          Log.Server.debug
            "collab host %s: dropping live batch after stop" s.keeper
        else (
          send_item item;
          send_batch rest)
    in
    send_batch batch;
    if closed then () else loop ()
  in
  loop ()
;;

(* -- publish hook ------------------------------------------------------ *)

let notify_published ~keeper ~operation ~seq ~ts event =
  let sessions =
    Stdlib.Mutex.protect registry_mutex (fun () ->
        Hashtbl.replace latest_operation keeper operation;
        match Hashtbl.find_opt sessions_by_keeper keeper with
        | None -> []
        | Some sessions -> sessions)
  in
  if not (Keeper_chat_event_log.journalable ~ts event)
  then
    Log.Server.debug
      "collab host %s: not forwarding unjournalable event (op %s seq %d)"
      keeper
      operation
      seq
  else
  List.iter
    (fun s ->
      Eio.Mutex.use_rw ~protect:false s.queue_mutex (fun () ->
          if s.queue_closed
          then ()
          else if s.queue_len >= live_queue_cap
          then (
            s.queue_dropped <- s.queue_dropped + 1;
            if s.queue_dropped = 1
            then
              Log.Server.warn
                "collab host %s: live queue full (%d); dropping newest"
                s.keeper
                live_queue_cap)
          else (
            Queue.push { op = operation; seq; ts; event } s.queue;
            s.queue_len <- s.queue_len + 1;
            Eio.Condition.broadcast s.queue_cond)))
    sessions
;;

(* -- lifecycle --------------------------------------------------------- *)

let start ~sw ~base_dir ~keeper ?(send = Server_collab_route.host_send_local)
    ?(injector = Server_collab_inject.default_injector) () =
  let room = Collab_link.generate () in
  match Collab_seal.key_of_secret room.Collab_link.key with
  | Error _ -> Error Seal_key_rejected
  | Ok key ->
    let s =
      { room
      ; key
      ; keeper
      ; base_dir
      ; send
      ; injector
      ; last_op = None
      ; queue = Queue.create ()
      ; queue_mutex = Eio.Mutex.create ()
      ; queue_cond = Eio.Condition.create ()
      ; queue_closed = false
      ; queue_len = 0
      ; queue_dropped = 0
      ; auth = Hashtbl.create 16
      ; labels = Hashtbl.create 16
      ; joined = Hashtbl.create 16
      ; unfinished_runs = Hashtbl.create 8
      ; guests = 0
      ; state_mutex = Stdlib.Mutex.create ()
      ; hello_mutex = Eio.Mutex.create ()
      }
    in
    let joined =
      Server_collab_route.host_join_local
        ~room:room.Collab_link.id
        { Server_collab_route.on_frame = handle_envelope s
        ; on_peer_joined = peer_joined s
        ; on_peer_left = peer_left s
        }
    in
    (match joined with
     | Error Collab_relay.Host_already_connected -> Error Room_conflict
     | Error Collab_relay.Join_no_such_room | Error Collab_relay.Room_full ->
       (* Unreachable for a host-role join (a fresh id is never missing or
          full); a fresh start is the safe answer to any join anomaly. *)
       Error Room_conflict
     | Ok () ->
       Stdlib.Mutex.protect registry_mutex (fun () ->
           let current =
             match Hashtbl.find_opt sessions_by_keeper keeper with
             | None -> []
             | Some sessions -> sessions
           in
           Hashtbl.replace sessions_by_keeper keeper (s :: current));
       Eio.Fiber.fork ~sw (fun () -> forwarder s);
       Ok s)
;;

let stop s =
  let already_closed =
    Eio.Mutex.use_rw ~protect:false s.queue_mutex (fun () ->
        if s.queue_closed
        then true
        else (
          s.queue_closed <- true;
          Eio.Condition.broadcast s.queue_cond;
          false))
  in
  if not already_closed
  then (
    Stdlib.Mutex.protect registry_mutex (fun () ->
        match Hashtbl.find_opt sessions_by_keeper s.keeper with
        | None -> ()
        | Some sessions ->
          Hashtbl.replace sessions_by_keeper s.keeper
            (List.filter (fun other -> other != s) sessions));
    send_frame s ~target:Collab_envelope.broadcast_peer
      (Collab_frame.Bye "host stopped sharing");
    Server_collab_route.host_leave_local ~room:s.room.Collab_link.id)
;;

let stop_all () =
  let sessions =
    Stdlib.Mutex.protect registry_mutex (fun () ->
        Hashtbl.fold (fun _ sessions acc -> sessions @ acc) sessions_by_keeper [])
  in
  List.iter stop sessions
;;

let live_for_keeper keeper =
  Stdlib.Mutex.protect registry_mutex (fun () ->
      match Hashtbl.find_opt sessions_by_keeper keeper with
      | None -> []
      | Some sessions -> sessions)
;;

let session_keeper s = s.keeper
let session_room_id s = s.room.Collab_link.id
let session_room s = s.room

(* Shutdown runs registered hooks before the switch fails, so every live
   session still has a working send path for its Bye. Priority 10 puts the
   guest notify ahead of the state flushes (20-30). This module is always
   linked into the server binary via the keeper-stream tap, so the
   top-level registration always runs there. *)
(* The hook runs first (priority 10) and one hook's Cancel aborts the
   whole chain, skipping every flush behind it — so a cancelled bye is
   logged and swallowed here. Guests of un-byed rooms still see the TCP
   close. (This is the one sanctioned Cancel swallow: shutdown-only,
   chain-preserving, loud.) *)
let shutdown_bye () =
  match stop_all () with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _) ->
    Log.Server.debug "collab_bye: cancelled during shutdown; byes skipped"
;;

let () = Shutdown.register ~name:"collab_bye" ~priority:10 shutdown_bye
;;
