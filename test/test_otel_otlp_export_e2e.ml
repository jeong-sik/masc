open Alcotest

module Metrics = Opentelemetry.Proto.Metrics
module Metrics_service = Opentelemetry.Proto.Metrics_service

type captured_request =
  { request_line : string
  ; headers : (string * string) list
  ; body : string
  }

let trim_lower s = s |> String.trim |> String.lowercase_ascii

let header_value name headers =
  let wanted = trim_lower name in
  List.find_map
    (fun (k, v) -> if String.equal (trim_lower k) wanted then Some v else None)
    headers
;;

let parse_header line =
  match String.index_opt line ':' with
  | None -> line, ""
  | Some idx ->
    ( String.sub line 0 idx
    , String.sub line (idx + 1) (String.length line - idx - 1) |> String.trim )
;;

let rec read_headers reader acc =
  let line = Eio.Buf_read.line reader |> String.trim in
  match line with
  | "" -> List.rev acc
  | line -> read_headers reader (parse_header line :: acc)
;;

let content_length_opt headers =
  match header_value "content-length" headers with
  | Some value -> Some (int_of_string value)
  | None -> None
;;

let has_chunked_body headers =
  match header_value "transfer-encoding" headers with
  | Some value -> String.equal (trim_lower value) "chunked"
  | None -> false
;;

let chunk_size line =
  let token =
    match String.index_opt line ';' with
    | None -> line
    | Some idx -> String.sub line 0 idx
  in
  int_of_string ("0x" ^ String.trim token)
;;

let read_chunked_body reader =
  let buffer = Buffer.create 4096 in
  let rec loop () =
    let size = Eio.Buf_read.line reader |> String.trim |> chunk_size in
    if size = 0
    then (
      let rec drain_trailers () =
        match Eio.Buf_read.line reader |> String.trim with
        | "" -> ()
        | _ -> drain_trailers ()
      in
      drain_trailers ();
      Buffer.contents buffer)
    else (
      Buffer.add_string buffer (Eio.Buf_read.take size reader);
      let crlf = Eio.Buf_read.take 2 reader in
      check string "chunk terminator" "\r\n" crlf;
      loop ())
  in
  loop ()
;;

let read_body headers reader =
  match content_length_opt headers with
  | Some length -> Eio.Buf_read.take length reader
  | None when has_chunked_body headers -> read_chunked_body reader
  | None -> fail "collector request missing content-length or chunked transfer-encoding"
;;

let resolve_once promise resolver value =
  match Eio.Promise.peek promise with
  | Some _ -> ()
  | None -> Eio.Promise.resolve resolver value
;;

let handle_one_http_request ~captured_p ~captured_r flow =
  let reader = Eio.Buf_read.of_flow ~max_size:(2 * 1024 * 1024) flow in
  let request_line = Eio.Buf_read.line reader |> String.trim in
  let headers = read_headers reader [] in
  let body = read_body headers reader in
  resolve_once captured_p captured_r { request_line; headers; body };
  Eio.Flow.copy_string
    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    flow
;;

let listen_loopback ~sw env =
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 0) in
  Eio.Net.listen env#net ~sw ~reuse_addr:true ~backlog:4 addr
;;

let port_of_socket socket =
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) -> port
  | _ -> fail "expected TCP OTLP test socket"
;;

let run_fake_collector ~sw ~captured_p ~captured_r socket =
  Eio.Fiber.fork ~sw (fun () ->
    let flow, _client_addr = Eio.Net.accept ~sw socket in
    Eio.Switch.run (fun conn_sw ->
      Eio.Switch.on_release conn_sw (fun () -> Eio.Flow.close flow);
      handle_one_http_request ~captured_p ~captured_r flow))
;;

let metric_names_from_export body =
  let decoder = Pbrt.Decoder.of_string body in
  let request = Metrics_service.decode_pb_export_metrics_service_request decoder in
  request.resource_metrics
  |> List.concat_map (fun (rm : Metrics.resource_metrics) -> rm.scope_metrics)
  |> List.concat_map (fun (sm : Metrics.scope_metrics) -> sm.metrics)
  |> List.map (fun (metric : Metrics.metric) -> metric.name)
;;

let test_metric_store_reaches_otlp_collector () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let captured_p, captured_r = Eio.Promise.create () in
  let socket = listen_loopback ~sw env in
  run_fake_collector ~sw ~captured_p ~captured_r socket;
  let endpoint = Printf.sprintf "http://127.0.0.1:%d" (port_of_socket socket) in
  let stop = Atomic.make false in
  let backend_removed = Atomic.make false in
  let cleanup_backend () =
    if Atomic.compare_and_set backend_removed false true
    then (
      Atomic.set stop true;
      Opentelemetry.Collector.set_backend (module Opentelemetry.Collector.Noop_backend))
  in
  Eio.Switch.on_release sw cleanup_backend;
  Masc.Otel_metric_store.register_otel_source_once ();
  let metric_name =
    Printf.sprintf "masc_test_otel_otlp_export_total_%d" (Unix.getpid ())
  in
  let labels = [ "test", "otel_otlp_export_e2e" ] in
  let config =
    Opentelemetry_client_cohttp_eio.Config.make
      ~url:endpoint
      ~batch_metrics:(Some 1)
      ~batch_timeout_ms:50
      ()
  in
  Opentelemetry_client_cohttp_eio.setup ~stop ~sw ~config env;
  Masc.Otel_metric_store.inc_counter metric_name ~labels ~delta:7.0 ();
  Opentelemetry.Collector.tick ();
  let request =
    Eio.Time.with_timeout_exn env#clock 5.0 (fun () -> Eio.Promise.await captured_p)
  in
  check string
    "OTLP metrics path"
    (Printf.sprintf "POST /v1/metrics HTTP/1.1")
    request.request_line;
  check (option string)
    "OTLP protobuf content type"
    (Some "application/x-protobuf")
    (header_value "content-type" request.headers);
  check bool "OTLP body is non-empty" true (String.length request.body > 0);
  let names = metric_names_from_export request.body in
  check bool
    "OTLP protobuf contains metric-store sample"
    true
    (List.exists (String.equal metric_name) names);
  cleanup_backend ()
;;

let () =
  run
    "otel_otlp_export_e2e"
    [ ( "otlp"
      , [ test_case
            "metric store sample reaches local OTLP collector"
            `Quick
            test_metric_store_reaches_otlp_collector
        ] )
    ]
;;
