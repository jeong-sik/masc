type upgrade =
  { switch_protocols : Httpun.Headers.t -> (unit -> unit) -> unit
  ; drive : Gluten.impl -> unit
  }

type acceptance = Transport_metrics.response_write_acceptance =
  | Accepted_by_writer
  | Rejected_by_writer

module Stream_end = Http_h2_stream.Stream_end
module Response_body = Http_h2_stream.Response_body

(* One constructor per transport that carries requests. [streaming] is the
   body writer [respond_with_streaming] opened: neither library hands it back,
   and [response_state] needs to know whether it is still open. [reported]
   is set once [report_exn] reported the request failed. *)
type t =
  | Http1 of
      { reqd : Httpun.Reqd.t
      ; upgrade : upgrade option
      ; mutable streaming : Httpun.Body.Writer.t option
      ; mutable reported : bool
      }
  | Http2 of
      { reqd : H2.Reqd.t
      ; request : Httpun.Request.t
      ; ledger : Http_h2_response_ledger.request
      ; stream_end : Stream_end.t
      ; mutable streaming : Response_body.t option
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
    ; streaming = None
    ; reported = false
    }
;;

let of_httpun reqd = Http1 { reqd; upgrade = None; streaming = None; reported = false }

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

let of_h2 ~stream_end ~ledger reqd =
  Http2
    { reqd
    ; request = request_of_h2 (Stream_end.request stream_end)
    ; ledger
    ; stream_end
    ; streaming = None
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

(* The answer was computed and is not sent. The client sees only a 503
   without a body, so the line here is the trace of what happened. *)
let h2_refuse_for_capacity ~stream_end ~bytes reqd (response : Httpun.Response.t) =
  Log.Http.warn
    "[h2] %s: the response ledger has no room for %d bytes; answering 503"
    (Stream_end.request_line stream_end)
    bytes;
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
  Stream_end.close_after_flush stream_end writer
;;

let h2_respond_with_string ~stream_end reqd ledger response body =
  (* A request whose body nobody read must still release its stream. *)
  H2.Body.Reader.discard (H2.Reqd.request_body reqd);
  let bytes = String.length body in
  match Http_h2_response_ledger.reserve ledger ~bytes with
  (* The ledger closes a request when its stream switch is released: the
     stream is over, and h2 has nothing left to answer on. *)
  | Error Request_closed ->
    Log.Http.debug "[http] response skipped, the HTTP/2 stream is already over";
    Rejected_by_writer
  | Error Capacity_exhausted ->
    h2_refuse_for_capacity ~stream_end ~bytes reqd response;
    Rejected_by_writer
  | Ok lease ->
    (* With no headers out there is no response, so the reservation goes
       back here. After the headers a failure is the stream's to handle,
       and the end of its scope releases the reservation (RFC-0518 D3). *)
    (match
       H2.Reqd.respond_with_streaming
         reqd
         ~flush_headers_immediately:true
         (h2_response_of response)
     with
     | exception exn ->
       Http_h2_response_ledger.release lease;
       raise exn
     | writer ->
       let out = Response_body.create stream_end writer in
       Response_body.write out ~sent:(fun () -> Http_h2_response_ledger.release lease) body;
       Response_body.close out;
       Accepted_by_writer)
;;

(* A stream masc already ended, or one that already carries an error, takes no
   response, and h2 is not asked: it raises [Failure] once an error was
   reported on the stream and hits [assert false] once the stream is closed
   (reqd.ml 276·283~285). Two closed streams are not seen here while masc's
   scope is still open: one h2 reset on its own, until its RST_STREAM leaves
   the socket (RFC-0518 D1), and one whose response already ended. *)
let h2_stream_over ~stream_end reqd =
  Option.is_some (Eio.Switch.get_error (Stream_end.switch stream_end))
  || Option.is_some (H2.Reqd.error_code reqd)
;;

let h2_body_closed ~stream_end reqd body =
  Response_body.is_closed body || h2_stream_over ~stream_end reqd
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
       | Http2 { reqd; ledger; stream_end; _ } ->
         if h2_stream_over ~stream_end reqd
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
        ; body : Response_body.t
        ; ledger : Http_h2_response_ledger.request
        ; stream_end : Stream_end.t
        }
    (* An HTTP/2 stream that was over before the response opened. *)
    | Ended

  let is_closed = function
    | H1 writer -> Httpun.Body.Writer.is_closed writer
    | H2 { reqd; body; stream_end; _ } -> h2_body_closed ~stream_end reqd body
    | Ended -> true
  ;;

  (* Exhausted capacity resets this stream, as the ledger's own drain did
     (RFC-0493 §3): the client sees a cut, never a frame reported as sent.
     The reset leaves no line of its own once a response has started, so the
     refusal is logged here. *)
  let write_string t s =
    match t with
    | H1 writer -> Httpun.Body.Writer.write_string writer s
    | H2 { reqd; body; ledger; stream_end } ->
      if not (is_closed t)
      then (
        let bytes = String.length s in
        match Http_h2_response_ledger.reserve ledger ~bytes with
        | Ok lease ->
          Response_body.write body ~sent:(fun () -> Http_h2_response_ledger.release lease) s
        (* The ledger closes a request with its stream's scope, and
           [is_closed] saw that scope end first. *)
        | Error Request_closed -> ()
        | Error Capacity_exhausted ->
          Log.Http.warn
            "[h2] %s: the response ledger has no room for %d bytes; resetting the stream"
            (Stream_end.request_line stream_end)
            bytes;
          Http_h2_stream.reset
            ~stream_sw:(Stream_end.switch stream_end)
            reqd
            (Http_h2_stream.Out_of_capacity Capacity_exhausted);
          (* h2 closed the body of a started response it reset. A stream
             that was already closed is not reset again, so close the body
             here too. *)
          Response_body.close body)
    | Ended -> ()
  ;;

  (* The transport's own end of the stream under the writer. h2 reports a
     peer reset, a stall and a connection end through the stream's switch;
     httpun reports nothing before the body closes. *)
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
      | H2 { body; _ } -> Response_body.flush body f
      | Ended -> f `Closed)
  ;;

  let close = function
    | H1 writer -> Httpun.Body.Writer.close writer
    | H2 { body; _ } -> Response_body.close body
    | Ended -> ()
  ;;
end

let respond_with_streaming ?flush_headers_immediately t response =
  match t with
  | Http1 http1 ->
    let writer =
      Httpun.Reqd.respond_with_streaming ?flush_headers_immediately http1.reqd response
    in
    http1.streaming <- Some writer;
    Body_writer.H1 writer
  | Http2 http2 ->
    let reqd = http2.reqd
    and stream_end = http2.stream_end in
    if h2_stream_over ~stream_end reqd
    then Body_writer.Ended
    else (
      let writer =
        H2.Reqd.respond_with_streaming reqd ?flush_headers_immediately (h2_response_of response)
      in
      let body = Response_body.create stream_end writer in
      http2.streaming <- Some body;
      Body_writer.H2 { reqd; body; ledger = http2.ledger; stream_end })
;;

type response_state =
  | Not_started
  | Streaming_open
  | Answered

let response_state = function
  | Http1 { reqd; streaming; _ } ->
    (match streaming, Httpun.Reqd.response reqd with
     | Some writer, _ ->
       if Httpun.Body.Writer.is_closed writer then Answered else Streaming_open
     | None, Some _ -> Answered
     | None, None -> Not_started)
  | Http2 { reqd; stream_end; streaming; _ } ->
    (match streaming, H2.Reqd.response reqd with
     | Some body, _ ->
       if h2_body_closed ~stream_end reqd body then Answered else Streaming_open
     | None, Some _ -> Answered
     | None, None -> Not_started)
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

(* httpun ends a request body the same way whether its parser finished it
   or a report cut it short: the reader closes, and a read still pending sees
   its end with the bytes so far. Only a body that ended whole is delivered.
   A body with a length is whole when that many bytes arrived; the length is
   the one httpun's parser reads the body by. A chunked body leaves a trace
   only when its cut was reported: by masc ([reported]), or by httpun before
   a response started, which sets the request's error code. httpun's own
   report after a response started leaves none, and that body is taken as
   whole: httpun keeps no completion state, unlike h2's reader. *)
let ended_whole reqd ~reported ~received =
  match Httpun.Request.body_length (Httpun.Reqd.request reqd) with
  | `Fixed length -> Int64.equal length (Int64.of_int received)
  | `Chunked | `Error `Bad_request ->
    (not (reported ())) && Option.is_none (Httpun.Reqd.error_code reqd)
;;

let read_body_h1 reqd ~reported ~max_bytes ~on_body ~on_error =
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
        ~on_eof:(fun () ->
          if ended_whole reqd ~reported ~received:(Http_body_buffer.length buf)
          then deliver_body ~on_body ~on_error (Http_body_buffer.contents buf))
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
let read_body_h2 reqd ~ledger ~stream_end ~max_bytes ~on_body ~on_error =
  let dispatch work =
    Http_h2_response_ledger.with_current ledger (fun () ->
      Http_h2_stream.dispatch stream_end work)
  in
  let body = H2.Reqd.request_body reqd in
  let reject error =
    H2.Body.Reader.discard body;
    dispatch (fun () -> on_error error)
  in
  match H2.Request.body_length (Stream_end.request stream_end) with
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
  | Http1 http1 ->
    read_body_h1
      http1.reqd
      ~reported:(fun () -> http1.reported)
      ~max_bytes
      ~on_body
      ~on_error
  | Http2 { reqd; ledger; stream_end; _ } ->
    read_body_h2 reqd ~ledger ~stream_end ~max_bytes ~on_body ~on_error
;;

(* masc's HTTP/1.1 error handler writes the 500 without logging, and a cut
   body calls no handler at all, so the HTTP/1.1 failure is logged here. *)
let report_exn t exn =
  match t with
  | Http1 http1 ->
    Log.Http.error "[http] request failed: %s" (Printexc.to_string exn);
    http1.reported <- true;
    Httpun.Reqd.report_exn http1.reqd exn
  | Http2 { reqd; stream_end; _ } ->
    Http_h2_stream.reset
      ~stream_sw:(Stream_end.switch stream_end)
      reqd
      (Http_h2_stream.Raised exn)
;;
