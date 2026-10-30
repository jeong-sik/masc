let dispatch_request ~sw reqd work =
  let context = Server_h2_response_resources.current () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (* fork starts its child immediately. Return to h2's parser before any
       request computation, pool wait, or response mutation starts. *)
    Eio.Fiber.yield ();
    let run () =
      try work () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> H2.Reqd.report_exn reqd exn
    in
    (match context with
     | Some context -> Server_h2_response_resources.with_current context run
     | None -> run ());
    `Stop_daemon)

let maybe_compress ?(compress = true) h2_reqd body =
  let req = H2.Reqd.request h2_reqd in
  Http_response_payload.compress_body_on_cpu
    ~compress
    ~accept_encoding:(H2.Headers.get req.headers "accept-encoding")
    body

(* WORKAROUND: h2 0.13.0 ends the stream when a closed body still has bytes
   pending and the window is 0 (anmonteiro/ocaml-h2#278). Root fix: upstream
   condition in reqd.ml/respd.ml. Remove when masc requires an h2 release with
   the fix.

   Closing right after the last write sent the first window's worth of bytes,
   then END_STREAM, and the client saw a 200 with a short body. The close here
   runs once every byte written so far has left the body, so END_STREAM only
   goes out when nothing is pending.

   Write the whole body before calling this. A write after it is cut the same
   way the old close was, because the flush only covers the bytes already
   written.

   While the window stays 0 the callback does not run at all, with neither
   argument: h2 reaches a response body only through Reqd.flush_response_body,
   which skips it while the window is 0, and that is the only path that drains
   the body when the connection dies. The writer is then left open and goes
   when the stream does. Measured on a peer RST_STREAM, on a connection kept
   alive for 30 pings afterwards, and on transport close. *)
let h2_close_after_flush writer =
  H2.Body.Writer.flush writer (function
    | `Written | `Closed -> H2.Body.Writer.close writer)

let h2_respond_body
    ?(status = `OK)
    ?(extra_headers = [])
    ?(compress = true)
    ~content_type
    h2_reqd
    body =
  H2.Body.Reader.discard (H2.Reqd.request_body h2_reqd);
  let final_body, compression_headers = maybe_compress ~compress h2_reqd body in
  match Server_h2_response_resources.reserve
    (Server_h2_response_resources.current_exn ()) ~bytes:(String.length final_body) with
  | Error (Capacity_exhausted | Request_closed) ->
    let extra_headers = List.filter (fun (name,_) ->
      match String.lowercase_ascii name with
      | "content-encoding" | "content-length" | "content-type" | "etag"
      | "last-modified" | "cache-control" -> false
      | _ -> true) extra_headers in
    let headers=H2.Headers.of_list
      (("content-length","0") :: ("cache-control","no-store") :: extra_headers) in
    let writer=H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd
      (H2.Response.create ~headers `Service_unavailable) in
    h2_close_after_flush writer
  | Ok lease ->
  let headers = H2.Headers.of_list ([
    ("content-type", content_type);
    ("content-length", string_of_int (String.length final_body));
  ] @ compression_headers @ extra_headers) in
  let response = H2.Response.create ~headers status in
  (try
     let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
     Server_h2_response_resources.write_reserved lease writer final_body;
     h2_close_after_flush writer
   with exn -> Server_h2_response_resources.release lease; raise exn)

let h2_respond_json_string ?status ?extra_headers ?(compress = true) h2_reqd body =
  h2_respond_body
    ?status
    ?extra_headers
    ~compress
    ~content_type:"application/json; charset=utf-8"
    h2_reqd
    body

let h2_respond_json ?status ?extra_headers ?compress h2_reqd body =
  h2_respond_json_string ?status ?extra_headers ?compress h2_reqd body

(* A timeout envelope is recognized from the payload's JSON, not from its
   [origin]: a builder with a shorter ceiling of its own can return the
   envelope as its value, and the cache keeps it as a computed page. *)
let h2_respond_cached_payload ?extra_headers h2_reqd
    (payload : Dashboard_cache.cached_payload) =
  let status =
    if Dashboard_cache.is_timeout_envelope payload.json then `Gateway_timeout else `OK
  in
  h2_respond_json_string ~status ?extra_headers h2_reqd payload.raw_json

let json_value_status ?status json =
  match status with
  | None | Some `OK ->
      (Http_server_eio.Response.timeout_envelope_status_override json :> H2.Status.t)
  | Some status -> status

let h2_respond_json_value ?status ?extra_headers ?compress h2_reqd json =
  let status = json_value_status ?status json in
  h2_respond_json_string ~status ?extra_headers ?compress h2_reqd
    (Yojson.Safe.to_string json)

let h2_respond_json_value_on_cpu ?status ?(extra_headers = []) ?(compress = true)
    h2_reqd json =
  let status = json_value_status ?status json in
  let request = H2.Reqd.request h2_reqd in
  let accept_encoding = H2.Headers.get request.headers "accept-encoding" in
  let body, compression_headers =
    Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
      Http_response_payload.compress_body ~compress ~accept_encoding
        (Yojson.Safe.to_string json))
  in
  h2_respond_body ~status ~compress:false
    ~extra_headers:(compression_headers @ extra_headers)
    ~content_type:"application/json; charset=utf-8" h2_reqd body

let h2_respond_text ?(status = `OK) ?(extra_headers = []) h2_reqd body =
  h2_respond_body
    ~status
    ~extra_headers
    ~compress:true
    ~content_type:"text/plain; charset=utf-8"
    h2_reqd
    body

let h2_respond_html ?(status = `OK) ?(extra_headers = []) h2_reqd body =
  h2_respond_body
    ~status
    ~extra_headers
    ~compress:true
    ~content_type:"text/html; charset=utf-8"
    h2_reqd
    body

let h2_respond_bytes
    ?(status = `OK)
    ?(extra_headers = [])
    ?(compress = false)
    ~content_type
    h2_reqd
    body =
  h2_respond_body ~status ~extra_headers ~compress ~content_type h2_reqd body

let h2_respond_empty ?(status = `No_content) ?(extra_headers = []) h2_reqd =
  H2.Body.Reader.discard (H2.Reqd.request_body h2_reqd);
  (* A 304 has no body, but Content-Length: 0 would falsely describe the
     selected 200 representation. Omit the field on conditional responses. *)
  let headers = H2.Headers.of_list
    (if status = `Not_modified then extra_headers
     else ("content-length", "0") :: extra_headers)
  in
  let response = H2.Response.create ~headers status in
  let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
  h2_close_after_flush writer

let h2_read_body_with_limit ~sw ~max_bytes ~on_too_large ~on_bad_request
    h2_reqd callback =
  let context = Server_h2_response_resources.current_exn () in
  let dispatch work = Server_h2_response_resources.with_current context
    (fun () -> dispatch_request ~sw h2_reqd work) in
  let body = H2.Reqd.request_body h2_reqd in
  let reject respond =
    H2.Body.Reader.discard body;
    dispatch respond
  in
  match H2.Request.body_length (H2.Reqd.request h2_reqd) with
  | `Error `Bad_request -> reject on_bad_request
  | `Fixed declared when Int64.compare declared (Int64.of_int max_bytes) > 0 ->
    reject on_too_large
  | `Fixed _ | `Unknown ->
    let buf = Http_body_buffer.create 4096 in
    let rec read_loop () =
      H2.Body.Reader.schedule_read body
        ~on_eof:(fun () ->
          match H2.Body.Reader.completion body with
          | H2.Body.Reader.Pending | Aborted -> ()
          | Complete ->
              dispatch (fun () ->
                (* The parser can observe a reset after EOF, before the
                   request fiber gets its deferred turn. *)
                match H2.Body.Reader.completion body with
                | Pending | Aborted -> ()
                | Complete -> callback (Http_body_buffer.contents buf)))
        ~on_read:(fun bigstring ~off ~len ->
          if Http_body_buffer.length buf + len > max_bytes
          then reject on_too_large
          else (
            Http_body_buffer.add_bigstring buf bigstring ~off ~len;
            read_loop ()))
    in
    read_loop ()

let h2_read_body ~sw h2_reqd callback =
  let max_bytes = Http_server_eio.Request.max_body_bytes in
  h2_read_body_with_limit ~sw ~max_bytes
    ~on_too_large:(fun () ->
      h2_respond_text h2_reqd (Http_server_eio.Request.too_large_body max_bytes)
        ~status:`Payload_too_large)
    ~on_bad_request:(fun () ->
      h2_respond_text h2_reqd "Malformed request body length" ~status:`Bad_request)
    h2_reqd callback
