let make_error_handler () =
  let h2_error_handler _client_addr ?request:_ error respond =
    let message =
      match error with
      | `Exn exn -> Printexc.to_string exn
      | `Bad_request -> "Bad request"
      | `Internal_server_error -> "Internal server error"
    in
    Log.Http.error "Error: %s" message;
    let headers = H2.Headers.of_list [ "content-type", "text/plain" ] in
    let body = respond headers in
    (match Http_h2_response_ledger.current () with
     | Some ledger ->
       (match Http_h2_response_ledger.reserve ledger ~bytes:(String.length message) with
        | Error (Capacity_exhausted | Request_closed) -> ()
        | Ok lease ->
          (* One short diagnostic line: it needs no slices. *)
          Http_h2_response_ledger.write_reserved
            lease
            ~write:(fun writer text -> H2.Body.Writer.write_string writer text)
            body
            message)
     | None ->
       (* Parser failures have no admitted application scope. Their fixed
          diagnostic is bounded separately from application payloads. *)
       H2.Body.Writer.write_string
         body
         (match error with
          | `Bad_request -> "Bad request"
          | `Internal_server_error | `Exn _ -> "Internal server error"));
    Http_h2_stream.close_after_flush body
  in
  h2_error_handler
;;

let make_request_handler ~trust_policy ~routes =
  let embedded_ledger =
    Http_h2_response_ledger.create
      ~max_pending_bytes:(H2_response_limits.max_pending_bytes ())
  in
  fun ~stream_end client_addr h2_reqd ->
    let within_request work =
      match Http_h2_response_ledger.current () with
      | Some ledger -> work ledger
      | None ->
        Http_h2_response_ledger.with_request
          embedded_ledger
          ~sw:(Http_h2_stream.Stream_end.switch stream_end)
          (fun () -> work (Http_h2_response_ledger.current_exn ()))
    in
    within_request (fun ledger ->
      let reqd = Http_reqd.of_h2 ~stream_end ~ledger h2_reqd in
      match
        Server_request_authority.classify_h2_request
          ~trust_policy
          (Http_h2_stream.Stream_end.request stream_end)
      with
      | Server_request_authority.H2_authority classification ->
        Server_http_ingress.serve ~routes ~client_addr classification reqd
      | Server_request_authority.Unsupported_asterisk_form_options ->
        Server_http_ingress.respond_request_authority_bad_request
          ~error_code:"request_target_asterisk_unsupported"
          ~message:"MASC does not support authority-free OPTIONS *"
          reqd)
;;
