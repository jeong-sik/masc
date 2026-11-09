(** See [server_h2_stream_registry.mli]. *)

type scope =
  | Admitted
  | Running of Eio.Switch.t

type entry =
  { mutable scope : scope
  ; response_ended : unit Eio.Promise.t
  ; end_response : unit Eio.Promise.u
  }

type t = (int, entry) Hashtbl.t

let create () : t = Hashtbl.create 16
let active_streams (t : t) = Hashtbl.length t

let owns t stream_id entry =
  match Hashtbl.find_opt t stream_id with
  | Some current -> current == entry
  | None -> false
;;

let release t stream_id entry = if owns t stream_id entry then Hashtbl.remove t stream_id

(* The stream switch stays open until the response ends, so deferred body
   callbacks and response producers forked on it outlive the header callback. *)
let run_scope entry reqd work =
  Eio.Switch.run (fun stream_sw ->
    entry.scope <- Running stream_sw;
    (try work stream_sw with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Http_h2_stream.reset ~stream_sw reqd (Http_h2_stream.Raised exn));
    Eio.Promise.await entry.response_ended)
;;

let dispatch t ~sw ~stream_id reqd work =
  let response_ended, end_response = Eio.Promise.create () in
  let entry = { scope = Admitted; response_ended; end_response } in
  Hashtbl.replace t stream_id entry;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (* fork starts its child immediately. Return to h2's parser before any
       request computation, pool wait, or response mutation starts. *)
    Eio.Fiber.yield ();
    Fun.protect
      ~finally:(fun () -> release t stream_id entry)
      (fun () ->
        if owns t stream_id entry
        then (
          match run_scope entry reqd work with
          | () -> ()
          | exception Http_h2_stream.Stream_reset _ -> ()
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          (* A fiber forked on the stream switch raised. The switch has
             finished, so only the report is left. *)
          | exception exn -> Http_h2_stream.report reqd exn));
    `Stop_daemon)
;;

(* A reset on either side leaves no response to wait for. The entry goes at
   once; a fiber that has not opened its scope yet then skips the work. *)
let end_stream t ~stream_id cause =
  match Hashtbl.find_opt t stream_id with
  | None -> ()
  | Some entry ->
    Hashtbl.remove t stream_id;
    (match entry.scope with
     | Admitted -> ()
     | Running stream_sw -> Http_h2_stream.end_scope stream_sw cause)
;;

let peer_reset t ~stream_id = end_stream t ~stream_id Http_h2_stream.Reset_by_peer
let reset_sent t ~stream_id = end_stream t ~stream_id Http_h2_stream.Reset_by_us

let response_ended t ~stream_id =
  match Hashtbl.find_opt t stream_id with
  | Some entry when not (Eio.Promise.is_resolved entry.response_ended) ->
    Eio.Promise.resolve entry.end_response ()
  | Some _ | None -> ()
;;
