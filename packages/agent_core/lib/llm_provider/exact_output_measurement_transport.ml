open Http_client

let ( let* ) = Result.bind

type 'callback_error dispatch_intent =
  { committed : bool Atomic.t
  ; dispatch_started : bool Atomic.t
  ; commit_fence : unit -> (unit, 'callback_error) result
  ; mark_dispatch_started : unit -> unit
  }

type 'callback_error error =
  | Commit_failed of 'callback_error
  | Transport_failed of Http_client.post_sync_once_error

type connection = [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t

let create_dispatch_intent ~commit_fence ~mark_dispatch_started =
  { committed = Atomic.make false
  ; dispatch_started = Atomic.make false
  ; commit_fence
  ; mark_dispatch_started
  }
;;

let classify_unix_error = function
  | Unix.ECONNREFUSED | Unix.ECONNRESET -> Connection_refused
  | Unix.EPIPE -> End_of_file
  | Unix.ETIMEDOUT -> Timeout
  | Unix.ENETUNREACH | Unix.EHOSTUNREACH -> Dns_failure
  | Unix.EMFILE | Unix.ENFILE | Unix.ENOBUFS | Unix.EADDRNOTAVAIL ->
    Local_resource_exhaustion
  | unclassified ->
    let (_ : Unix.error) = unclassified in
    Unknown
;;

let classify_network_exn (exception_ : exn) =
  match exception_ with
  | End_of_file -> Some (NetworkError { message = "End_of_file"; kind = End_of_file })
  | Eio.Time.Timeout ->
    Some
      (TimeoutError
         { message = "exact-output measurement HTTP operation exceeded timeout"
         ; phase = Http_operation
         })
  | Unix.Unix_error (code, _, _) as exn ->
    Some
      (NetworkError { message = Printexc.to_string exn; kind = classify_unix_error code })
  | Eio.Io (_, _) as exn ->
    Some (NetworkError { message = Printexc.to_string exn; kind = Unknown })
  | (Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _) as exn ->
    Some (NetworkError { message = Printexc.to_string exn; kind = Tls_error })
  | Sys_error _ | Failure _ -> None
  | _ -> None
;;

type transport_exception_disposition =
  | Reserved_transport_exception
  | Typed_transport_error of Http_client.http_error

let transport_exception_disposition exn =
  match classify_network_exn exn with
  | Some error -> Typed_transport_error error
  | None ->
    (match exn with
     | Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _ ->
       Reserved_transport_exception
     | _ ->
       Typed_transport_error
         (ProviderFailure
            { kind = Unknown_provider_failure { reason = Some (Printexc.to_string exn) }
            ; message = "unclassified transport exception"
            }))
;;

let%test "ordinary unclassified transport exceptions remain typed" =
  let is_unknown exn =
    match transport_exception_disposition exn with
    | Typed_transport_error (ProviderFailure { kind = Unknown_provider_failure _; _ }) ->
      true
    | Reserved_transport_exception | Typed_transport_error _ -> false
  in
  is_unknown (Failure "opaque failure") && is_unknown (Sys_error "opaque sys error")
;;

let validate_uri url =
  try
    let uri = Uri.of_string url in
    match Uri.host uri with
    | Some host when String.trim host <> "" -> Ok uri
    | Some _ | None ->
      Error
        (NetworkError
           { message = Printf.sprintf "invalid URL %S: missing host" url; kind = Unknown })
  with
  | Invalid_argument detail ->
    Error
      (NetworkError
         { message = Printf.sprintf "invalid URL %S: %s" url detail; kind = Unknown })
;;

let validate_headers_and_body headers body =
  try
    let header = Http.Header.of_list headers in
    match Http.Header.get_multi header "content-length" with
    | [] -> Ok header
    | [ raw ] ->
      (match int_of_string_opt (String.trim raw) with
       | Some declared when declared = String.length body -> Ok header
       | Some declared ->
         Error
           (AcceptRejected
              { reason =
                  Printf.sprintf
                    "exact-output measurement Content-Length is %d but body is %d bytes"
                    declared
                    (String.length body)
              })
       | None ->
         Error
           (AcceptRejected
              { reason =
                  "exact-output measurement Content-Length is not a decimal integer"
              }))
    | _ ->
      Error
        (AcceptRejected
           { reason = "exact-output measurement has multiple Content-Length headers" })
  with
  | Invalid_argument reason -> Error (AcceptRejected { reason })
;;

let https_init_error_network_kind = function
  | Api_common.Ca_certs_unavailable _ | Api_common.Tls_config_unavailable _ -> Tls_error
;;

let resolve_origin net uri =
  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Resource.t) in
  let host = Option.get (Uri.host uri) in
  let service =
    match Uri.port uri with
    | Some port -> Int.to_string port
    | None -> Uri.scheme uri |> Option.value ~default:"http"
  in
  let* addr =
    try
      match Eio.Net.getaddrinfo_stream ~service net host with
      | address :: _ -> Ok address
      | [] ->
        Error
          (NetworkError
             { message = Printf.sprintf "failed to resolve hostname: %s" host
             ; kind = Dns_failure
             })
    with
    | Eio.Io (_, _) as exn ->
      Error (NetworkError { message = Printexc.to_string exn; kind = Unknown })
    | Unix.Unix_error (code, _, _) as exn ->
      Error
        (NetworkError
           { message = Printexc.to_string exn; kind = classify_unix_error code })
  in
  let* tls_wrap =
    match Uri.scheme uri with
    | Some "https" ->
      let wrap_error reason =
        NetworkError
          { message =
              Printf.sprintf
                "HTTPS requested but TLS not available for %s: %s"
                (Uri.to_string uri)
                (Api_common.https_init_error_to_string reason)
          ; kind = https_init_error_network_kind reason
          }
      in
      Result.map (fun wrap -> Some wrap)
      @@ Result.map_error wrap_error (Api_common.make_https_result ())
    | Some "http" | Some _ | None -> Ok None
  in
  Ok (net, addr, tls_wrap)
;;

let make_connection ~sw ~net ~uri =
  let* net, address, tls_wrap = resolve_origin net uri in
  try
    let socket = Eio.Net.connect ~sw net address in
    let connection : connection =
      match tls_wrap with
      | Some wrap -> (wrap uri socket :> connection)
      | None -> (socket :> connection)
    in
    Ok connection
  with
  | Eio.Io (_, _) as exn ->
    Error (NetworkError { message = Printexc.to_string exn; kind = Unknown })
  | Unix.Unix_error (code, _, _) as exn ->
    Error
      (NetworkError { message = Printexc.to_string exn; kind = classify_unix_error code })
;;

let read_response_body response_body =
  try
    Ok
      Eio.Buf_read.(
        of_flow ~max_size:Api_common.max_response_body response_body |> take_all)
  with
  | Eio.Buf_read.Buffer_limit_exceeded ->
    Error
      (ProviderFailure
         { kind = Response_body_too_large { limit_bytes = Api_common.max_response_body }
         ; message =
             Printf.sprintf
               "provider response exceeded %d bytes; connection closed without draining"
               Api_common.max_response_body
         })
;;

let retry_after_header response =
  match Http.Header.get_multi (Cohttp.Response.headers response) "retry-after" with
  | [ raw ] -> Http_client.parse_retry_after_seconds ~now:(Unix.gettimeofday ()) raw
  | [] | _ :: _ :: _ -> None
;;

let close_connection connection =
  try Eio.Cancel.protect (fun () -> Eio.Resource.close connection) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Diag.warn
      "exact_output_measurement_transport"
      "connection cleanup failed: %s"
      (Printexc.to_string exn)
;;

let post_sync_once_after_commit
      ~connect_deadline
      ~body_deadline
      ~net
      ~uri
      ~header
      ~body
      ~dispatch_intent
      ()
  =
  Eio.Switch.run
  @@ fun sw ->
  let phase = ref Before_dispatch in
  let status = ref None in
  let connection = ref None in
  let release_connection () =
    match !connection with
    | None -> ()
    | Some current ->
      connection := None;
      close_connection current
  in
  let staged_error error =
    match !phase, !status with
    | Before_dispatch, None -> Before_dispatch_error error
    | Dispatch_started, None -> Dispatch_started_error error
    | Response_received, Some status -> Response_received_error { status; error }
    | Before_dispatch, Some _ | Dispatch_started, Some _ | Response_received, None ->
      invalid_arg "exact-output measurement transport has inconsistent receipt state"
  in
  let fail_exn exn =
    let backtrace = Printexc.get_raw_backtrace () in
    match transport_exception_disposition exn with
    | Typed_transport_error error -> Error error
    | Reserved_transport_exception ->
      release_connection ();
      Printexc.raise_with_backtrace exn backtrace
  in
  let total_started_at =
    match body_deadline with
    | Unbounded -> None
    | Bounded (deadline_clock, _) -> Some (deadline_clock, Eio.Time.now deadline_clock)
  in
  let total_deadline_error timeout_s =
    TimeoutError
      { message =
          Printf.sprintf
            "exact-output measurement body_timeout_s exceeded after %.17g seconds"
            timeout_s
      ; phase = Wall_clock
      }
  in
  let headers_deadline =
    match connect_deadline, body_deadline with
    | Unbounded, Unbounded -> None
    | Bounded (deadline_clock, timeout_s), Unbounded ->
      Some (deadline_clock, timeout_s, `Connect)
    | Unbounded, Bounded (deadline_clock, timeout_s) ->
      Some (deadline_clock, timeout_s, `Total)
    | Bounded (connect_clock, connect_timeout_s), Bounded (body_clock, body_timeout_s) ->
      if connect_timeout_s <= body_timeout_s
      then Some (connect_clock, connect_timeout_s, `Connect)
      else Some (body_clock, body_timeout_s, `Total)
  in
  let with_headers_deadline f =
    match headers_deadline with
    | None -> f ()
    | Some (deadline_clock, timeout_s, owner) ->
      (match Eio.Time.with_timeout deadline_clock timeout_s (fun () -> Ok (f ())) with
       | Ok result -> result
       | Error `Timeout ->
         Error
           (match owner with
            | `Connect ->
              TimeoutError
                { message =
                    Printf.sprintf
                      "exact-output measurement connect_timeout_s exceeded after %.17g \
                       seconds"
                      timeout_s
                ; phase = Http_operation
                }
            | `Total -> total_deadline_error timeout_s))
  in
  let post_result =
    try
      with_headers_deadline (fun () ->
        let* current = make_connection ~sw ~net ~uri in
        connection := Some current;
        let client =
          Cohttp_eio.Client.make_generic (fun ~sw:_ _uri ->
            (current :> _ Eio.Flow.two_way))
        in
        let request_body = Cohttp_eio.Body.of_string body in
        phase := Dispatch_started;
        if not (Atomic.compare_and_set dispatch_intent.dispatch_started false true)
        then invalid_arg "exact-output measurement dispatch was already started";
        dispatch_intent.mark_dispatch_started ();
        let response, response_body =
          Cohttp_eio.Client.post ~sw client ~headers:header ~body:request_body uri
        in
        let response_status =
          Cohttp.Response.status response |> Cohttp.Code.code_of_status
        in
        phase := Response_received;
        status := Some response_status;
        Ok (response, response_body))
    with
    | Eio.Time.Timeout as exn ->
      release_connection ();
      raise exn
    | exn -> fail_exn exn
  in
  match post_result with
  | Error error ->
    release_connection ();
    Error (staged_error error)
  | Ok (response, response_body) ->
    let body_result =
      try
        match body_deadline, total_started_at with
        | Unbounded, None -> read_response_body response_body
        | Bounded (deadline_clock, timeout_s), Some (_, started_at) ->
          let remaining = timeout_s -. (Eio.Time.now deadline_clock -. started_at) in
          if remaining <= 0.0
          then Error (total_deadline_error timeout_s)
          else (
            match
              Eio.Time.with_timeout deadline_clock remaining (fun () ->
                Ok (read_response_body response_body))
            with
            | Ok result -> result
            | Error `Timeout -> Error (total_deadline_error timeout_s))
        | Unbounded, Some _ | Bounded _, None ->
          invalid_arg "exact-output measurement transport has inconsistent deadline state"
      with
      | Eio.Time.Timeout as exn ->
        release_connection ();
        raise exn
      | exn -> fail_exn exn
    in
    (match body_result with
     | Error error ->
       release_connection ();
       Error (staged_error error)
     | Ok response_body ->
       let response_status = Option.get !status in
       let retry_after_header = retry_after_header response in
       release_connection ();
       Ok
         ({ status = response_status; body = response_body; retry_after_header }
          : Http_client.raw_sync_response))
;;

let post_sync_once
      ?clock
      ?connect_timeout_s
      ?body_timeout_s
      ~net
      ~url
      ~headers
      ~body
      ~dispatch_intent
      ()
  =
  let before_dispatch error = Error (Transport_failed (Before_dispatch_error error)) in
  match
    Http_client.resolve_explicit_deadline
      ~operation:"exact_output_measurement"
      ~parameter:"connect_timeout_s"
      ~clock
      ~timeout_s:connect_timeout_s
  with
  | Error error -> before_dispatch error
  | Ok connect_deadline ->
    (match
       Http_client.resolve_explicit_deadline
         ~operation:"exact_output_measurement"
         ~parameter:"body_timeout_s"
         ~clock
         ~timeout_s:body_timeout_s
     with
     | Error error -> before_dispatch error
     | Ok body_deadline ->
       (match validate_uri url with
        | Error error -> before_dispatch error
        | Ok uri ->
          (match validate_headers_and_body headers body with
           | Error error -> before_dispatch error
           | Ok header ->
             if not (Atomic.compare_and_set dispatch_intent.committed false true)
             then
               invalid_arg "exact-output measurement dispatch intent was already consumed";
             (match dispatch_intent.commit_fence () with
              | Error cause -> Error (Commit_failed cause)
              | Ok () ->
                post_sync_once_after_commit
                  ~connect_deadline
                  ~body_deadline
                  ~net
                  ~uri
                  ~header
                  ~body
                  ~dispatch_intent
                  ()
                |> Result.map_error (fun error -> Transport_failed error)))))
;;
