(** OTLP HTTP/JSON span exporter.

    Uses cohttp-eio directly for HTTP transport.
    No dependency on {!Llm_provider.Http_client}.

    @since 0.102.0 *)

type export_config =
  { endpoint : string
  ; headers : (string * string) list
  ; flush_interval_sec : float
  ; max_batch_size : int
  ; max_retries : int
  ; timeout_sec : float
  }

let default_export_config ~endpoint =
  { endpoint
  ; headers = []
  ; flush_interval_sec = 5.0
  ; max_batch_size = 512
  ; max_retries = 3
  ; timeout_sec = 10.0
  }
;;

type export_result =
  | Exported of
      { span_count : int
      ; metric_count : int
      }
  | Partial_failure of
      { exported : int
      ; dropped : int
      ; metric_exported : int
      ; metric_dropped : int
      ; reason : string
      }
  | Failed of { reason : string }

(* ── TLS helper ─────────────────────────────────────────────── *)

let _log = Log.create ~module_name:"otel_export" ()

(* Reuses the process-wide cached TLS configuration
   ({!Llm_provider.Api_common.tls_client_config}). [flush_to_collector]
   builds a client per flush tick; loading the system trust store each
   time re-ran `security find-certificate` + a full PEM parse every
   [flush_interval_sec] on macOS. *)
let make_https () =
  match Llm_provider.Api_common.tls_client_config () with
  | Error err ->
    Log.warn
      _log
      "TLS client configuration unavailable"
      [ Log.S ("error", Llm_provider.Api_common.https_init_error_to_string err) ];
    None
  | Ok tls_config -> Some (fun _uri socket -> Tls_eio.client_of_flow tls_config socket)
;;

let make_client ~net = Cohttp_eio.Client.make ~https:(make_https ()) net

(* ── OTLP JSON body construction ────────────────────────────── *)

let build_otlp_body ~service_name (spans : Otel_tracer.span list) : string =
  let json =
    `Assoc
      [ ( "resourceSpans"
        , `List
            [ `Assoc
                [ ( "resource"
                  , `Assoc
                      [ ( "attributes"
                        , Otel_tracer.attrs_to_json [ "service.name", service_name ] )
                      ] )
                ; ( "scopeSpans"
                  , `List
                      [ `Assoc
                          [ ( "scope"
                            , `Assoc
                                [ "name", `String "agent_sdk.otel_export"
                                ; "version", `String Sdk_version.version
                                ] )
                          ; "spans", `List (List.map Otel_tracer.span_to_json spans)
                          ]
                      ] )
                ]
            ] )
      ]
  in
  Yojson.Safe.to_string json
;;

let build_otlp_metrics_body ~service_name (metrics : Otel_tracer.metric_entry list)
  : string
  =
  let json =
    `Assoc
      [ ( "resourceMetrics"
        , `List
            [ `Assoc
                [ ( "resource"
                  , `Assoc
                      [ ( "attributes"
                        , Otel_tracer.attrs_to_json [ "service.name", service_name ] )
                      ] )
                ; ( "scopeMetrics"
                  , `List
                      [ `Assoc
                          [ ( "scope"
                            , `Assoc
                                [ "name", `String "agent_sdk.otel_export"
                                ; "version", `String Sdk_version.version
                                ] )
                          ; ( "metrics"
                            , `List (List.map Otel_tracer.metric_entry_to_json metrics) )
                          ]
                      ] )
                ]
            ] )
      ]
  in
  Yojson.Safe.to_string json
;;

(* ── HTTP POST via cohttp-eio ───────────────────────────────── *)

let replace_suffix s ~suffix ~replacement =
  let suffix_len = String.length suffix in
  let len = String.length s in
  if len >= suffix_len && String.equal (String.sub s (len - suffix_len) suffix_len) suffix
  then String.sub s 0 (len - suffix_len) ^ replacement
  else s
;;

let endpoint_for_signal endpoint signal_path =
  let uri = Uri.of_string endpoint in
  let path = Uri.path uri in
  let path =
    match path with
    | "" | "/" -> signal_path
    | _ ->
      path
      |> replace_suffix ~suffix:"/v1/traces" ~replacement:signal_path
      |> replace_suffix ~suffix:"/v1/metrics" ~replacement:signal_path
  in
  Uri.to_string (Uri.with_path uri path)
;;

let post_otlp ~sw ~clock ~client ~config ~endpoint body =
  let uri = Uri.of_string endpoint in
  let base_headers =
    Cohttp.Header.of_list ([ "content-type", "application/json" ] @ config.headers)
  in
  let body_s = Cohttp_eio.Body.of_string body in
  try
    Eio.Time.with_timeout_exn clock config.timeout_sec (fun () ->
      let resp, resp_body =
        Cohttp_eio.Client.post ~sw ~headers:base_headers ~body:body_s client uri
      in
      let status = Cohttp.Response.status resp in
      let code = Cohttp.Code.code_of_status status in
      let _ =
        Eio.Buf_read.of_flow ~max_size:(1024 * 64) resp_body |> Eio.Buf_read.take_all
      in
      if code >= 200 && code < 300 then Ok () else Error (Printf.sprintf "HTTP %d" code))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Eio.Time.Timeout -> Error (Printf.sprintf "timeout after %.1fs" config.timeout_sec)
  | exn -> Error (Printexc.to_string exn)
;;

(* ── Batch + retry logic ────────────────────────────────────── *)

let export_batch ~sw ~clock ~client ~config ~service_name spans =
  let body = build_otlp_body ~service_name spans in
  let endpoint = endpoint_for_signal config.endpoint "/v1/traces" in
  let rec attempt n =
    try
      match post_otlp ~sw ~clock ~client ~config ~endpoint body with
      | Ok () -> Ok (List.length spans)
      | Error _ when n < config.max_retries ->
        let delay = Float.pow 2.0 (Float.of_int n) *. 0.5 in
        Eio.Time.sleep clock delay;
        attempt (n + 1)
      | Error reason -> Error reason
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
  in
  attempt 0
;;

let export_metrics ~sw ~clock ~client ~config ~service_name metrics =
  let body = build_otlp_metrics_body ~service_name metrics in
  let endpoint = endpoint_for_signal config.endpoint "/v1/metrics" in
  let rec attempt n =
    try
      match post_otlp ~sw ~clock ~client ~config ~endpoint body with
      | Ok () -> Ok (List.length metrics)
      | Error _ when n < config.max_retries ->
        let delay = Float.pow 2.0 (Float.of_int n) *. 0.5 in
        Eio.Time.sleep clock delay;
        attempt (n + 1)
      | Error reason -> Error reason
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
  in
  attempt 0
;;

let take_batch max_size lst =
  let rec go n acc rest =
    match rest with
    | [] -> List.rev acc, []
    | _ when n <= 0 -> List.rev acc, rest
    | x :: xs -> go (n - 1) (x :: acc) xs
  in
  go max_size [] lst
;;

let rec split_batches max_size acc = function
  | [] -> List.rev acc
  | spans ->
    let batch, rest = take_batch max_size spans in
    split_batches max_size (batch :: acc) rest
;;

let flush_to_collector ~sw ~clock ~net ~config instance =
  (* Telemetry is flushed from the tracer upfront. If export fails, data is
     dropped (not re-queued). Callers should treat [Partial_failure] and
     [Failed] as permanent telemetry loss for the affected batches. *)
  let spans = Otel_tracer.inst_flush instance in
  let metrics = Otel_tracer.inst_drain_metrics instance in
  if spans = [] && metrics = []
  then Exported { span_count = 0; metric_count = 0 }
  else (
    let client = make_client ~net in
    let service_name = instance.Otel_tracer.config.service_name in
    let batches = split_batches config.max_batch_size [] spans in
    let span_total = List.length spans in
    let metric_total = List.length metrics in
    let exported_spans = ref 0 in
    let exported_metrics = ref 0 in
    let last_error = ref "" in
    List.iter
      (fun batch ->
         match export_batch ~sw ~clock ~client ~config ~service_name batch with
         | Ok count -> exported_spans := !exported_spans + count
         | Error reason -> last_error := reason)
      batches;
    (match metrics with
     | [] -> ()
     | _ ->
       (match export_metrics ~sw ~clock ~client ~config ~service_name metrics with
        | Ok count -> exported_metrics := !exported_metrics + count
        | Error reason -> last_error := reason));
    let total = span_total + metric_total in
    let exported = !exported_spans + !exported_metrics in
    if exported = total
    then Exported { span_count = !exported_spans; metric_count = !exported_metrics }
    else if exported > 0
    then
      Partial_failure
        { exported = !exported_spans
        ; dropped = span_total - !exported_spans
        ; metric_exported = !exported_metrics
        ; metric_dropped = metric_total - !exported_metrics
        ; reason = !last_error
        }
    else Failed { reason = !last_error })
;;

(* ── Background daemon ──────────────────────────────────────── *)

type t =
  { config : export_config
  ; instance : Otel_tracer.instance
  ; mutable total_exported : int
  }

let start_daemon ~sw ~clock ~net ~config ?on_export instance =
  let state = { config; instance; total_exported = 0 } in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do
      Eio.Time.sleep clock config.flush_interval_sec;
      let result = flush_to_collector ~sw ~clock ~net ~config instance in
      (match result with
       | Exported { span_count; metric_count } ->
         state.total_exported <- state.total_exported + span_count + metric_count
       | Partial_failure { exported; metric_exported; _ } ->
         state.total_exported <- state.total_exported + exported + metric_exported
       | Failed _ -> ());
      match on_export with
      | Some cb -> cb result
      | None -> ()
    done;
    `Stop_daemon);
  state
;;

let force_flush ~sw ~clock ~net t =
  let result = flush_to_collector ~sw ~clock ~net ~config:t.config t.instance in
  (match result with
   | Exported { span_count; metric_count } ->
     t.total_exported <- t.total_exported + span_count + metric_count
   | Partial_failure { exported; metric_exported; _ } ->
     t.total_exported <- t.total_exported + exported + metric_exported
   | Failed _ -> ());
  result
;;

let total_exported t = t.total_exported
