type upgrade =
  { switch_protocols : Httpun.Headers.t -> (unit -> unit) -> unit
  ; drive : Gluten.impl -> unit
  }

type acceptance = Transport_metrics.response_write_acceptance =
  | Accepted_by_writer
  | Rejected_by_writer

(* The h2 library answers a flush only when the connection writer drains the
   body (Http_h2_stream). A stream the peer reset, and a connection that ended
   while the stream's window was 0, are never drained, so a flush registered
   before that would wait for ever. The stream switch ends in both cases:
   Server_h2_stream_registry fails it on RST_STREAM, and the connection scope
   cancels it. That end answers every flush still waiting with [`Closed]. *)
module Stream_end = struct
  type t =
    { mutable ended : bool
    ; waiting : (int, unit -> unit) Hashtbl.t
    ; mutable next_id : int
    ; signal : unit Eio.Promise.t
    ; resolve_signal : unit Eio.Promise.u
    }

  let create ~stream_sw =
    let signal, resolve_signal = Eio.Promise.create () in
    let t =
      { ended = false; waiting = Hashtbl.create 2; next_id = 0; signal; resolve_signal }
    in
    Eio.Switch.on_release stream_sw (fun () ->
      t.ended <- true;
      (* The signal goes first: a flush answer that raised would otherwise
         leave the stream's end unreported to a waiting producer. *)
      Eio.Promise.resolve t.resolve_signal ();
      let answers = Hashtbl.fold (fun _ answer answers -> answer :: answers) t.waiting [] in
      Hashtbl.reset t.waiting;
      List.iter (fun answer -> answer ()) answers);
    t
  ;;

  let ended t = t.ended
  let signal t = t.signal

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
          f outcome)
      in
      Hashtbl.replace t.waiting id (fun () -> once `Closed);
      H2.Body.Writer.flush writer once)
  ;;
end

(* One constructor per transport that carries requests. *)
type t =
  | Http1 of
      { reqd : Httpun.Reqd.t
      ; upgrade : upgrade option
      }
  | Http2 of
      { reqd : H2.Reqd.t
      ; request : Httpun.Request.t
      ; ledger : Http_h2_response_ledger.request
      ; stream_sw : Eio.Switch.t
      ; stream_end : Stream_end.t
      }

let of_gluten (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) =
  let reqd = gluten_reqd.Gluten.Reqd.reqd in
  Http1
    { reqd
    ; upgrade =
        Some
          { switch_protocols = Httpun.Reqd.respond_with_upgrade reqd
          ; drive = gluten_reqd.Gluten.Reqd.upgrade
          }
    }
;;

let of_httpun reqd = Http1 { reqd; upgrade = None }

let http2_version = { Httpun.Version.major = 2; minor = 0 }

(* The method and target are the shared [Httpun_types] values; the pseudo
   fields h2 keeps in the header block stay there. A request without [host]
   gets one from [:authority], so handlers that read the host (canonical-host
   redirect, OAuth metadata) see the same field on both transports. *)
let request_of_h2 (h2_request : H2.Request.t) =
  let fields = H2.Headers.to_list h2_request.H2.Request.headers in
  let fields =
    match
      H2.Headers.get h2_request.headers "host", H2.Headers.get h2_request.headers ":authority"
    with
    | None, Some authority -> fields @ [ "host", authority ]
    | Some _, (Some _ | None) | None, None -> fields
  in
  Httpun.Request.create
    ~version:http2_version
    ~headers:(Httpun.Headers.of_list fields)
    h2_request.meth
    h2_request.target
;;

let of_h2 ~stream_sw ~ledger reqd =
  Http2
    { reqd
    ; request = request_of_h2 (H2.Reqd.request reqd)
    ; ledger
    ; stream_sw
    ; stream_end = Stream_end.create ~stream_sw
    }
;;

let request = function
  | Http1 { reqd; _ } -> Httpun.Reqd.request reqd
  | Http2 { request; _ } -> request
;;

let protocol = function
  | Http1 _ -> Transport_metrics.H1
  | Http2 _ -> Transport_metrics.H2
;;

let upgrade = function
  | Http1 { upgrade; _ } -> upgrade
  | Http2 _ -> None
;;

(* The [Failure] payloads are the only way httpun, h2 and their Faraday
   writers report these states, so matching their text (warning 52) is the
   dependency, kept in this one place. If a library version rewords them, a
   late write logs at warn instead of debug; nothing else changes. *)
[@@@warning "-52"]

module Late_response = struct
  let classify_write_failure = function
    | Failure msg
      when String.starts_with msg ~prefix:"httpun.Reqd.respond_with_string: invalid state" ->
      Some msg
    | Failure msg when String.equal msg "cannot write to closed writer" ->
      Some "cannot write to closed writer"
    | Failure msg when String.starts_with msg ~prefix:"h2.Reqd.respond_with_*: response already" ->
      Some msg
    | Failure msg when String.equal msg "h2.Reqd.request_body: Stream already closed" ->
      Some msg
    | _ -> None
  ;;
end

[@@@warning "+52"]

let log_rejected_write exn =
  match Late_response.classify_write_failure exn with
  | Some msg ->
    Log.Http.debug "[http] response skipped, the request can no longer take one: %s" msg
  | None ->
    let backtrace = Printexc.get_backtrace () in
    let summary = Printexc.to_string exn in
    if String.trim backtrace = ""
    then Log.Http.warn "[http] response failed: %s" summary
    else Log.Http.warn "[http] response failed: %s\n%s" summary backtrace
;;

(* RFC 9113 §8.2.2: connection-specific fields do not exist in HTTP/2, and
   field names are lowercase on the wire. *)
let connection_specific_fields =
  [ "connection"; "keep-alive"; "proxy-connection"; "transfer-encoding"; "upgrade" ]
;;

let h2_headers_of_fields fields =
  List.filter_map
    (fun (name, value) ->
       let name = String.lowercase_ascii name in
       if List.mem name connection_specific_fields then None else Some (name, value))
    fields
  |> H2.Headers.of_list
;;

let h2_response_of (response : Httpun.Response.t) =
  H2.Response.create
    ~headers:(h2_headers_of_fields (Httpun.Headers.to_list response.headers))
    (H2.Status.of_code (Httpun.Status.to_code response.status))
;;

(* The fields that described the refused payload go; the rest (CORS, vary,
   rate-limit fields) still describe this answer. *)
let payload_description_fields =
  [ "content-encoding"; "content-length"; "content-type"; "etag"; "last-modified"; "cache-control" ]
;;

(* h2#278: close only once the pending bytes are flushed. A reset stream
   never answers that flush, so the stream's end answers it (Stream_end) and
   the writer is closed either way. *)
let close_after_flush ~stream_end writer =
  Stream_end.flush stream_end writer (function
    | `Written | `Closed -> H2.Body.Writer.close writer)
;;

let h2_refuse_for_capacity ~stream_end reqd (response : Httpun.Response.t) =
  let retained =
    List.filter
      (fun (name, _) -> not (List.mem (String.lowercase_ascii name) payload_description_fields))
      (Httpun.Headers.to_list response.headers)
  in
  let headers =
    h2_headers_of_fields (("content-length", "0") :: ("cache-control", "no-store") :: retained)
  in
  let writer =
    H2.Reqd.respond_with_streaming
      reqd
      ~flush_headers_immediately:true
      (H2.Response.create ~headers `Service_unavailable)
  in
  close_after_flush ~stream_end writer
;;

let h2_respond_with_string ~stream_end reqd ledger response body =
  (* A request whose body nobody read must still release its stream. *)
  H2.Body.Reader.discard (H2.Reqd.request_body reqd);
  match Http_h2_response_ledger.reserve ledger ~bytes:(String.length body) with
  | Error (Capacity_exhausted | Request_closed) ->
    h2_refuse_for_capacity ~stream_end reqd response;
    Rejected_by_writer
  | Ok lease ->
    (try
       let writer =
         H2.Reqd.respond_with_streaming
           reqd
           ~flush_headers_immediately:true
           (h2_response_of response)
       in
       Http_h2_response_ledger.write_reserved lease writer body;
       close_after_flush ~stream_end writer;
       Accepted_by_writer
     with
     | exn ->
       Http_h2_response_ledger.release lease;
       raise exn)
;;

(* A stream masc already ended, or one that already carries an error, takes no
   response, and h2 is not asked: it raises [Failure] once an error was
   reported on the stream and hits [assert false] once the stream is closed
   (reqd.ml 276·283~285). A reset h2 made on its own is not seen here until its
   RST_STREAM leaves the socket (RFC-0518 D1). *)
let h2_stream_over ~stream_sw reqd =
  Option.is_some (Eio.Switch.get_error stream_sw) || Option.is_some (H2.Reqd.error_code reqd)
;;

let try_respond_with_string t response body =
  Cancel_safe.protect
    ~on_exn:(fun exn ->
      log_rejected_write exn;
      Rejected_by_writer)
    (fun () ->
       match t with
       | Http1 { reqd; _ } ->
         Httpun.Reqd.respond_with_string reqd response body;
         Accepted_by_writer
       | Http2 { reqd; ledger; stream_sw; stream_end; _ } ->
         if h2_stream_over ~stream_sw reqd
         then (
           Log.Http.debug "[http] response skipped, the HTTP/2 stream is already over";
           Rejected_by_writer)
         else h2_respond_with_string ~stream_end reqd ledger response body)
;;

let respond_with_string t response body =
  match try_respond_with_string t response body with
  | Accepted_by_writer | Rejected_by_writer -> ()
;;

module Body_writer = struct
  type t =
    | H1 of Httpun.Body.Writer.t
    | H2 of
        { reqd : H2.Reqd.t
        ; writer : H2.Body.Writer.t
        ; ledger : Http_h2_response_ledger.request
        ; stream_sw : Eio.Switch.t
        ; stream_end : Stream_end.t
        }
    (* An HTTP/2 stream that was over before the response opened. *)
    | Ended

  (* Exhausted capacity resets this stream, as the ledger's own drain did
     (RFC-0493 §3): the client sees a cut, never a frame reported as sent. *)
  let write_string t s =
    match t with
    | H1 writer -> Httpun.Body.Writer.write_string writer s
    | H2 { reqd; writer; ledger; stream_sw; _ } ->
      (match Http_h2_response_ledger.reserve ledger ~bytes:(String.length s) with
       | Ok lease -> Http_h2_response_ledger.write_reserved lease writer s
       | Error refusal ->
         Http_h2_stream.reset ~stream_sw reqd (Http_h2_stream.Out_of_capacity refusal);
         (* h2 closed the body of a started response it reset. A stream that
            was already closed is not reset again, so close it here too. *)
         H2.Body.Writer.close writer)
    | Ended -> ()
  ;;

  let is_closed = function
    | H1 writer -> Httpun.Body.Writer.is_closed writer
    | H2 { writer; stream_end; _ } ->
      H2.Body.Writer.is_closed writer || Stream_end.ended stream_end
    | Ended -> true
  ;;

  (* The transport's own end of the stream under the writer. h2 reports a
     peer reset and a connection end through the stream's switch; httpun
     reports nothing before the body closes. *)
  let stream_end = function
    | H1 _ -> None
    | H2 { stream_end; _ } -> Some (Stream_end.signal stream_end)
    | Ended -> Some (Eio.Promise.create_resolved ())
  ;;

  (* Both libraries answer a flush on a closed body from the connection
     writer: [`Written] once nothing is pending, and nothing at all for an h2
     stream that was reset, because a closed stream is never drained. The
     caller asks about bytes the peer will not get, so answer [`Closed]. On
     h2 the stream's end answers the flushes still waiting (Stream_end). *)
  let flush t f =
    if is_closed t
    then f `Closed
    else (
      match t with
      | H1 writer -> Httpun.Body.Writer.flush writer f
      | H2 { writer; stream_end; _ } -> Stream_end.flush stream_end writer f
      | Ended -> f `Closed)
  ;;

  let close = function
    | H1 writer -> Httpun.Body.Writer.close writer
    | H2 { writer; stream_end; _ } -> close_after_flush ~stream_end writer
    | Ended -> ()
  ;;
end

let respond_with_streaming ?flush_headers_immediately t response =
  match t with
  | Http1 { reqd; _ } ->
    Body_writer.H1 (Httpun.Reqd.respond_with_streaming ?flush_headers_immediately reqd response)
  | Http2 { reqd; ledger; stream_sw; stream_end; _ } ->
    if h2_stream_over ~stream_sw reqd
    then Body_writer.Ended
    else (
      let writer =
        H2.Reqd.respond_with_streaming reqd ?flush_headers_immediately (h2_response_of response)
      in
      Body_writer.H2 { reqd; writer; ledger; stream_sw; stream_end })
;;

type body_read_error =
  | Too_large of int
  | Internal of exn

let deliver_body ~on_body ~on_error body =
  try on_body body with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> on_error (Internal exn)
;;

(* The declared length is the peer's claim, and HTTP/2 admits up to
   max_concurrent_streams requests on one connection, so allocating the claim
   up front would let one connection hold streams x max_bytes before a byte
   arrives. The buffer doubles as bytes come in. *)
let body_buffer_initial_capacity_limit = 64 * 1024

let body_buffer ~declared =
  let initial_capacity =
    match declared with
    | Some len when len > 0 -> min len body_buffer_initial_capacity_limit
    | Some _ | None -> 1024
  in
  Http_body_buffer.create initial_capacity
;;

let read_body_h1 reqd ~max_bytes ~on_body ~on_error =
  let request = Httpun.Reqd.request reqd in
  let declared =
    match Httpun.Headers.get request.headers "content-length" with
    | Some v ->
      (match int_of_string_opt v with
       | Some n when n > 0 -> Some n
       | Some _ | None -> None)
    | None -> None
  in
  let body = Httpun.Reqd.request_body reqd in
  let stopped = ref false in
  let stop () =
    if not !stopped
    then (
      stopped := true;
      try Httpun.Body.Reader.close body with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Log.Misc.error "[http] body close failed: %s" (Printexc.to_string exn))
  in
  match declared with
  | Some len when len > max_bytes ->
    stop ();
    on_error (Too_large max_bytes)
  | Some _ | None ->
    let buf = body_buffer ~declared in
    let rec read_loop () =
      Httpun.Body.Reader.schedule_read
        body
        ~on_eof:(fun () -> deliver_body ~on_body ~on_error (Http_body_buffer.contents buf))
        ~on_read:(fun buffer ~off ~len ->
          if !stopped
          then ()
          else if Http_body_buffer.length buf + len > max_bytes
          then (
            stop ();
            on_error (Too_large max_bytes))
          else (
            Http_body_buffer.add_bigstring buf buffer ~off ~len;
            read_loop ()))
    in
    read_loop ()
;;

(* RFC-0350: body callbacks arrive on the connection reader, so the delivery
   and every refusal are deferred to the stream switch through
   [Http_h2_stream.dispatch]; completion is checked again after the deferral
   because the parser can observe a reset after EOF, before the request fiber
   gets its turn. Aborted readers never reach [on_body]. *)
let read_body_h2 reqd ~ledger ~stream_sw ~max_bytes ~on_body ~on_error =
  let dispatch work =
    Http_h2_response_ledger.with_current ledger (fun () ->
      Http_h2_stream.dispatch ~sw:stream_sw reqd work)
  in
  let body = H2.Reqd.request_body reqd in
  let reject error =
    H2.Body.Reader.discard body;
    dispatch (fun () -> on_error error)
  in
  match H2.Request.body_length (H2.Reqd.request reqd) with
  | `Error `Bad_request ->
    (* h2 answers 400 to an unparsable length before it calls the request
       handler (Server_connection, Message.body_length), so no stream reaches
       this arm; the error keeps the match total without inventing a reply. *)
    reject (Internal (Failure "h2 delivered a request whose body length it rejects"))
  | `Fixed declared when Int64.compare declared (Int64.of_int max_bytes) > 0 ->
    reject (Too_large max_bytes)
  | (`Fixed _ | `Unknown) as length ->
    let declared =
      match length with
      | `Fixed declared -> Some (Int64.to_int declared)
      | `Unknown -> None
    in
    let buf = body_buffer ~declared in
    let rec read_loop () =
      H2.Body.Reader.schedule_read
        body
        ~on_eof:(fun () ->
          match H2.Body.Reader.completion body with
          | Pending | Aborted -> ()
          | Complete ->
            dispatch (fun () ->
              match H2.Body.Reader.completion body with
              | Pending | Aborted -> ()
              | Complete -> deliver_body ~on_body ~on_error (Http_body_buffer.contents buf)))
        ~on_read:(fun bigstring ~off ~len ->
          if Http_body_buffer.length buf + len > max_bytes
          then reject (Too_large max_bytes)
          else (
            Http_body_buffer.add_bigstring buf bigstring ~off ~len;
            read_loop ()))
    in
    read_loop ()
;;

let read_body t ~max_bytes ~on_body ~on_error =
  match t with
  | Http1 { reqd; _ } -> read_body_h1 reqd ~max_bytes ~on_body ~on_error
  | Http2 { reqd; ledger; stream_sw; _ } ->
    read_body_h2 reqd ~ledger ~stream_sw ~max_bytes ~on_body ~on_error
;;

let report_exn t exn =
  match t with
  | Http1 { reqd; _ } -> Httpun.Reqd.report_exn reqd exn
  | Http2 { reqd; stream_sw; _ } -> Http_h2_stream.reset ~stream_sw reqd (Http_h2_stream.Raised exn)
;;
