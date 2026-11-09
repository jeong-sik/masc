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
       Log.Http.debug "[h2] stream report raised: %s" (Printexc.to_string failure))
;;

(* The first end wins. Failing a switch that already has an error adds the
   new one beside it, and [Eio.Switch.run] then raises [Eio.Exn.Multiple]
   instead of the stream's end. A finished switch reports an error here too. *)
let end_scope stream_sw cause =
  match Eio.Switch.get_error stream_sw with
  | Some _ -> ()
  | None -> Eio.Switch.fail stream_sw (Stream_reset cause)
;;

(* After a report the stream is either closed (h2 reset a started response)
   or answering with the error handler's response, which h2 opens when no
   response had started. That answer owns the stream until its END_STREAM and
   the RST_STREAM h2 writes after it (reqd.ml [close_stream]); ending the scope
   first would cut it. *)
let answering reqd = Option.is_some (H2.Reqd.response reqd)

let report_then_end ~stream_sw reqd cause exn ~keep_answer =
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
  | Stalled -> report_then_end ~stream_sw reqd cause (Stream_reset cause) ~keep_answer:false
  | Out_of_capacity _ ->
    report_then_end ~stream_sw reqd cause (Stream_reset cause) ~keep_answer:true
  | Raised exn -> report_then_end ~stream_sw reqd cause exn ~keep_answer:true
;;

let dispatch ~sw reqd work =
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
    (match ledger with
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
   alive for 30 pings afterwards, and on transport close. *)
let close_after_flush writer =
  H2.Body.Writer.flush writer (function
    | `Written | `Closed -> H2.Body.Writer.close writer)
;;
