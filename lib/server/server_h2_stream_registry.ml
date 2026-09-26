(** See [server_h2_stream_registry.mli]. *)

exception Peer_reset_stream

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
     | exn -> H2.Reqd.report_exn reqd exn);
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
          | exception Peer_reset_stream -> ()
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception exn -> H2.Reqd.report_exn reqd exn));
    `Stop_daemon)
;;

let peer_reset t ~stream_id =
  match Hashtbl.find_opt t stream_id with
  | None -> ()
  | Some entry ->
    Hashtbl.remove t stream_id;
    (match entry.scope with
     | Admitted -> ()
     | Running stream_sw -> Eio.Switch.fail stream_sw Peer_reset_stream)
;;

let response_ended t ~stream_id =
  match Hashtbl.find_opt t stream_id with
  | Some entry when not (Eio.Promise.is_resolved entry.response_ended) ->
    Eio.Promise.resolve entry.end_response ()
  | Some _ | None -> ()
;;
