type reset_cause =
  | Reset_by_peer
  | Reset_by_us
  | Stalled
  | Out_of_capacity of Http_h2_response_ledger.refusal
  | Raised of exn

exception Stream_reset of reset_cause

(* h2 answers a second report on a stream whose first report is still being
   answered with [failwith "h2.Reqd.report_exn: NYI"] (reqd.ml, the [Exn _]
   arm of [_report_error]). A stream gets one report. Whatever the report
   itself raises stays here: the caller is ending this stream, and the
   exception would otherwise fail the switch every stream of the connection
   runs on. *)
let report reqd exn =
  match H2.Reqd.error_code reqd with
  | Some _ -> ()
  | None ->
    (try H2.Reqd.report_exn reqd exn with
     | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
     | failure ->
       Log.Http.warn "[h2] stream report raised: %s" (Printexc.to_string failure))
;;

(* h2 hands a report to the connection's error handler only on a stream with
   no response and no error yet (reqd.ml [_report_error], the [Waiting,
   No_error] arm), and the error handlers masc installs log what they get:
   the gateway's and grpc-direct's. Any other report resets a started
   response or changes nothing, and nobody else logs it. *)
let report_failure reqd exn =
  let unanswered =
    Option.is_none (H2.Reqd.error_code reqd) && Option.is_none (H2.Reqd.response reqd)
  in
  report reqd exn;
  if not (unanswered && Option.is_some (H2.Reqd.error_code reqd))
  then Log.Http.error "[h2] stream failed: %s" (Printexc.to_string exn)
;;

(* The first end wins. Failing a switch that already has an error adds the
   new one beside it, and [Eio.Switch.run] then raises [Eio.Exn.Multiple]
   instead of the stream's end. A finished switch reports an error here too. *)
let end_scope stream_sw cause =
  match Eio.Switch.get_error stream_sw with
  | Some _ -> ()
  | None -> Eio.Switch.fail stream_sw (Stream_reset cause)
;;

(* After a report the stream is either closed or answering with the error
   handler's response, which h2 opens when no response had started. That
   answer owns the stream until its END_STREAM and the RST_STREAM h2 writes
   after it (reqd.ml [close_stream]); ending the scope first would cut it.
   Only that answer has both a response and an error code. A response h2
   is still sending, a fixed body included, is reset and the stream closed,
   so it has no response (reqd.ml [_report_error], the [Streaming] and
   [Fixed] arms). A response h2 marked [Complete] ignores the report and
   gets no code (the last arm). Both scopes end here. *)
let answering reqd =
  Option.is_some (H2.Reqd.error_code reqd) && Option.is_some (H2.Reqd.response reqd)
;;

let report_then_end ~report ~stream_sw reqd cause exn ~keep_answer =
  match report reqd exn with
  | () -> if not (keep_answer && answering reqd) then end_scope stream_sw cause
  | exception (Eio.Cancel.Cancelled _ as cancelled) ->
    end_scope stream_sw cause;
    raise cancelled
;;

(* A reset the peer sent, or one h2 already wrote, is not answered with
   another: RFC 9113 §5.4.2 forbids RST_STREAM in reply to RST_STREAM, and
   the frame tap sees ours only after h2 wrote it. A stall ends the scope
   even when an error answer is in flight: that answer is what stalled. *)
let reset ~stream_sw reqd cause =
  match cause with
  | Reset_by_peer | Reset_by_us -> end_scope stream_sw cause
  | Stalled ->
    report_then_end ~report ~stream_sw reqd cause (Stream_reset cause) ~keep_answer:false
  | Out_of_capacity _ ->
    report_then_end ~report ~stream_sw reqd cause (Stream_reset cause) ~keep_answer:true
  | Raised exn ->
    report_then_end ~report:report_failure ~stream_sw reqd cause exn ~keep_answer:true
;;

(* h2 answers a flush only when the connection writer drains the body. A
   stream the peer reset, and a connection that ended while the stream's
   window was 0, are never drained, so a flush registered before that would
   wait for ever. The stream switch ends in both cases:
   Server_h2_stream_registry fails it on RST_STREAM, and the connection scope
   cancels it. That end answers every flush still waiting with [`Closed].

   A peer that keeps the stream open with its window at 0 drains nothing
   either, and nothing ends that stream. The watchdog gives the oldest flush
   still waiting [stalled_after_s] to be answered and resets the stream with
   [Stalled] when it is not (RFC-0518 D2). A body is written with a flush at
   every slice boundary (D3), so the bound is on the time between two slices
   leaving for the connection, not on the whole body, and WINDOW_UPDATEs of
   a byte or two do not stretch it (RFC-0518 §3.3). A client that opens its
   window again only after reading a large batch has to read the batch
   within the bound. *)
module Stream_end = struct
  type t =
    { stream_sw : Eio.Switch.t
    ; reqd : H2.Reqd.t
    ; meth : H2.Method.t
    ; path : string
    ; clock : float Eio.Time.clock_ty Eio.Resource.t
    ; stalled_after_s : float
    ; mutable ended : bool
    ; waiting : (int, unit -> unit) Hashtbl.t
    ; order : (int * float) Queue.t
    ; registered : Eio.Condition.t
    ; mutable last_answer : float
    ; mutable next_id : int
    ; signal : unit Eio.Promise.t
    ; resolve_signal : unit Eio.Promise.u
    }

  let key : t Eio.Fiber.key = Eio.Fiber.create_key ()
  let with_current t f = Eio.Fiber.with_binding key t f
  let current () = Eio.Fiber.get key
  let switch t = t.stream_sw
  let ended t = t.ended
  let signal t = t.signal

  let stall t =
    Log.Http.warn
      "[h2] %s %s took no response bytes for %.0fs; resetting the stream"
      (H2.Method.to_string t.meth)
      t.path
      t.stalled_after_s;
    reset ~stream_sw:t.stream_sw t.reqd Stalled
  ;;

  (* [order] keeps the flushes as they were registered, with the time of
     each registration. h2 answers a body's flushes as its bytes drain,
     oldest first, so only the oldest flush still waiting can be late. Its
     time counts from when it became the oldest: its registration, or the
     answer before it, whichever came later. *)
  let deadline t registered_at = Float.max registered_at t.last_answer +. t.stalled_after_s

  let rec watch t =
    match Queue.peek_opt t.order with
    | None ->
      Eio.Condition.await_no_mutex t.registered;
      watch t
    | Some (id, _) when not (Hashtbl.mem t.waiting id) ->
      ignore (Queue.pop t.order);
      watch t
    | Some (id, registered_at) ->
      Eio.Time.sleep_until t.clock (deadline t registered_at);
      if Hashtbl.mem t.waiting id
         && Eio.Time.now t.clock >= deadline t registered_at
      then stall t
      else watch t
  ;;

  let rec drop_answered t =
    match Queue.peek_opt t.order with
    | Some (id, _) when not (Hashtbl.mem t.waiting id) ->
      ignore (Queue.pop t.order);
      drop_answered t
    | Some _ | None -> ()
  ;;

  (* The stall line names the request from what [create] read. h2 has no
     request to give for a stream it closed itself (reqd.ml [request]), and a
     query can carry a token. *)
  let path_of_target target =
    match String.index_opt target '?' with
    | Some query -> String.sub target 0 query
    | None -> target
  ;;

  let create ~stream_sw ~clock ~stalled_after_s reqd =
    let request = H2.Reqd.request reqd in
    let signal, resolve_signal = Eio.Promise.create () in
    let t =
      { stream_sw
      ; reqd
      ; meth = request.meth
      ; path = path_of_target request.target
      ; clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t)
      ; stalled_after_s
      ; ended = false
      ; waiting = Hashtbl.create 2
      ; order = Queue.create ()
      ; registered = Eio.Condition.create ()
      ; last_answer = Float.neg_infinity
      ; next_id = 0
      ; signal
      ; resolve_signal
      }
    in
    Eio.Switch.on_release stream_sw (fun () ->
      t.ended <- true;
      (* The signal goes first: a flush answer that raised would otherwise
         leave the stream's end unreported to a waiting producer. *)
      Eio.Promise.resolve t.resolve_signal ();
      let answers = Hashtbl.fold (fun _ answer answers -> answer :: answers) t.waiting [] in
      Hashtbl.reset t.waiting;
      List.iter (fun answer -> answer ()) answers);
    (* A daemon: the stream's scope ends with its response, not with this
       fiber. *)
    Eio.Fiber.fork_daemon ~sw:stream_sw (fun () ->
      watch t;
      `Stop_daemon);
    t
  ;;

  (* [f] runs once: when h2 drains the body, or when the stream's end comes
     first. *)
  let flush t writer f =
    if t.ended
    then f `Closed
    else (
      let id = t.next_id in
      t.next_id <- id + 1;
      let answered = ref false in
      let once outcome =
        if not !answered
        then (
          answered := true;
          Hashtbl.remove t.waiting id;
          t.last_answer <- Eio.Time.now t.clock;
          drop_answered t;
          f outcome)
      in
      Hashtbl.replace t.waiting id (fun () -> once `Closed);
      Queue.push (id, Eio.Time.now t.clock) t.order;
      Eio.Condition.broadcast t.registered;
      H2.Body.Writer.flush writer once)
  ;;

  (* h2#278: see the WORKAROUND at [close_after_flush] below. *)
  let close_after_flush t writer =
    flush t writer (function
      | `Written | `Closed -> H2.Body.Writer.close writer)
  ;;

  (* One DATA frame of the default SETTINGS_MAX_FRAME_SIZE (RFC 9113 §6.5.2). *)
  let slice_bytes = 16_384

  (* RFC-0518 D3. A flush at every slice boundary inside [payload] lets the
     watchdog see each slice drain. The end of [payload] is the caller's own
     flush. *)
  let write_slices t writer payload =
    let length = String.length payload in
    let rec from off =
      let len = Int.min slice_bytes (length - off) in
      H2.Body.Writer.write_string writer ~off ~len payload;
      if off + len < length
      then (
        flush t writer ignore;
        from (off + len))
    in
    from 0
  ;;
end

let dispatch stream_end work =
  let sw = Stream_end.switch stream_end
  and reqd = stream_end.Stream_end.reqd in
  let ledger = Http_h2_response_ledger.current () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (* fork starts its child immediately. Return to h2's parser before any
       request computation, pool wait, or response mutation starts. *)
    Eio.Fiber.yield ();
    let run () =
      try work () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> reset ~stream_sw:sw reqd (Raised exn)
    in
    Stream_end.with_current stream_end (fun () ->
      match ledger with
      | Some ledger -> Http_h2_response_ledger.with_current ledger run
      | None -> run ());
    `Stop_daemon)
;;

(* WORKAROUND: h2 0.13.0 ends the stream when a closed body still has bytes
   pending and the window is 0 (anmonteiro/ocaml-h2#278). Root fix: upstream
   condition in reqd.ml/respd.ml. Remove when masc requires an h2 release with
   the fix.

   Closing right after the last write sent the first window's worth of bytes,
   then END_STREAM, and the client saw a 200 with a short body. The close here
   runs once every byte written so far has left the body, so END_STREAM only
   goes out when nothing is pending.

   While the window stays 0 the callback does not run at all, with neither
   argument: h2 reaches a response body only through Reqd.flush_response_body,
   which skips it while the window is 0, and that is the only path that drains
   the body when the connection dies. The writer is then left open and goes
   when the stream does. Measured on a peer RST_STREAM, on a connection kept
   alive for 30 pings afterwards, and on transport close.

   Http_reqd closes its writers through [Stream_end.close_after_flush], and a
   fiber with a bound [Stream_end] closes through it here, so a peer that
   never drains the body is reset after the stall bound and the writer
   closes then. h2 opens its own error answers on the connection reader,
   which has no stream fiber, and the registry reports a failure that ended
   a stream's scope after that scope; those answers wait as before
   (RFC-0518 D2, §5). *)
let close_after_flush writer =
  match Stream_end.current () with
  | Some stream_end -> Stream_end.close_after_flush stream_end writer
  | None ->
    H2.Body.Writer.flush writer (function
      | `Written | `Closed -> H2.Body.Writer.close writer)
;;
