(** See [server_h2_stream_registry.mli]. *)

type scope =
  | Admitted
  | Running of Eio.Switch.t

type entry =
  { mutable scope : scope
  ; response_ended : unit Eio.Promise.t
  ; end_response : unit Eio.Promise.u
  }

type t =
  { entries : (int, entry) Hashtbl.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; stalled_after_s : float
  }

let create ~clock ~stalled_after_s () =
  { entries = Hashtbl.create 16
  ; clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t)
  ; stalled_after_s
  }
;;

let active_streams t = Hashtbl.length t.entries

let owns t stream_id entry =
  match Hashtbl.find_opt t.entries stream_id with
  | Some current -> current == entry
  | None -> false
;;

let release t stream_id entry =
  if owns t stream_id entry then Hashtbl.remove t.entries stream_id
;;

(* The stream switch stays open until the response ends, so deferred body
   callbacks and response producers forked on it outlive the header callback.
   The work gets the stream's end and also runs with it bound: h2 calls the
   connection's error handler inside the call that reports a failure, and that
   handler has no other way to reach the stream's flush bound. *)
let run_scope t entry ~request reqd work =
  Eio.Switch.run (fun stream_sw ->
    entry.scope <- Running stream_sw;
    let stream_end =
      Http_h2_stream.Stream_end.create
        ~stream_sw
        ~clock:t.clock
        ~stalled_after_s:t.stalled_after_s
        ~request
        reqd
    in
    Http_h2_stream.Stream_end.with_current stream_end (fun () ->
      try work stream_end with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Http_h2_stream.reset ~stream_sw reqd (Http_h2_stream.Raised exn));
    Eio.Promise.await entry.response_ended)
;;

let dispatch t ~sw ~stream_id reqd work =
  (* h2 is inside its request handler here, the one place where it promises
     a request for [reqd]: a stream it closed has none (reqd.ml [request]).
     The stream's fiber runs later and reads this one. *)
  let request = H2.Reqd.request reqd in
  let response_ended, end_response = Eio.Promise.create () in
  let entry = { scope = Admitted; response_ended; end_response } in
  Hashtbl.replace t.entries stream_id entry;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (* fork starts its child immediately. Return to h2's parser before any
       request computation, pool wait, or response mutation starts. *)
    Eio.Fiber.yield ();
    Fun.protect
      ~finally:(fun () -> release t stream_id entry)
      (fun () ->
        if owns t stream_id entry
        then (
          match run_scope t entry ~request reqd work with
          | () -> ()
          | exception Http_h2_stream.Stream_reset _ -> ()
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          (* A fiber forked on the stream switch raised, or a fiber turned
             the stream's end into another exception ([Eio.Exn.Multiple]).
             The switch has finished, so only the report and its log are
             left. *)
          | exception exn -> Http_h2_stream.report_failure reqd exn));
    `Stop_daemon)
;;

(* A reset on either side leaves no response to wait for. The entry goes at
   once; a fiber that has not opened its scope yet then skips the work. *)
let end_stream t ~stream_id cause =
  match Hashtbl.find_opt t.entries stream_id with
  | None -> ()
  | Some entry ->
    Hashtbl.remove t.entries stream_id;
    (match entry.scope with
     | Admitted -> ()
     | Running stream_sw -> Http_h2_stream.end_scope stream_sw cause)
;;

let peer_reset t ~stream_id = end_stream t ~stream_id Http_h2_stream.Reset_by_peer
let reset_sent t ~stream_id = end_stream t ~stream_id Http_h2_stream.Reset_by_us

let response_ended t ~stream_id =
  match Hashtbl.find_opt t.entries stream_id with
  | Some entry when not (Eio.Promise.is_resolved entry.response_ended) ->
    Eio.Promise.resolve entry.end_response ()
  | Some _ | None -> ()
;;
