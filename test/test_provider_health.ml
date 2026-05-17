open Alcotest
open Masc_mcp

let provider ?endpoint ?(interval = 1) ?(unhealthy_threshold = 3)
    ?(recovery_threshold = 2) provider_id
  : Provider_health.For_testing.provider
  =
  { provider_id
  ; endpoint
  ; probe_interval_seconds = interval
  ; unhealthy_threshold
  ; recovery_threshold
  }
;;

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
       Unix.setsockopt socket Unix.SO_REUSEADDR true;
       (match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
        | () -> ()
        | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) ->
          Alcotest.skip ());
       match Unix.getsockname socket with
       | Unix.ADDR_INET (_, port) -> port
       | _ -> failwith "unexpected socket family")
;;

let start_flipping_server ~sw ~net ~port status_code =
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:1024 body |> take_all) in
    let status = Atomic.get status_code |> Cohttp.Code.status_of_code in
    Cohttp_eio.Server.respond_string ~status ~body:"ok" ()
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()))
;;

let wait_until ~clock ~timeout_s predicate =
  let deadline = Eio.Time.now clock +. timeout_s in
  let rec loop () =
    if predicate () then true
    else if Eio.Time.now clock >= deadline then false
    else begin
      Eio.Time.sleep clock 0.05;
      loop ()
    end
  in
  loop ()
;;

let test_in_band_failure_threshold_marks_unhealthy () =
  Eio_main.run @@ fun _env ->
  let health =
    Provider_health.For_testing.create
      [ provider "runpod" ~unhealthy_threshold:3 ~recovery_threshold:2 ]
  in
  for _ = 1 to 3 do
    Provider_health.record_attempt_result health ~provider_id:"runpod"
      ~success:false ~http_status:(Some 502)
  done;
  check bool "provider unhealthy after threshold" false
    (Provider_health.is_healthy health ~provider_id:"runpod")
;;

let test_in_band_recovery_threshold_marks_healthy () =
  Eio_main.run @@ fun _env ->
  let health =
    Provider_health.For_testing.create
      [ provider "runpod" ~unhealthy_threshold:3 ~recovery_threshold:2 ]
  in
  for _ = 1 to 3 do
    Provider_health.record_attempt_result health ~provider_id:"runpod"
      ~success:false ~http_status:(Some 502)
  done;
  for _ = 1 to 2 do
    Provider_health.record_attempt_result health ~provider_id:"runpod"
      ~success:true ~http_status:None
  done;
  check bool "provider healthy after recovery threshold" true
    (Provider_health.is_healthy health ~provider_id:"runpod")
;;

let test_probe_loop_tracks_http_transition () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  Eio_context.set_switch sw;
  Eio_context.set_net net;
  Eio_context.set_clock clock;
  Eio_context.set_env env;
  let port = find_free_port () in
  let status_code = Atomic.make 502 in
  start_flipping_server ~sw ~net ~port status_code;
  let endpoint = Printf.sprintf "http://127.0.0.1:%d/health" port in
  let health =
    Provider_health.For_testing.create
      [ provider "runpod" ~endpoint ~interval:1 ~unhealthy_threshold:2
          ~recovery_threshold:2
      ]
  in
  Provider_health.start_probe_fiber ~sw ~env health;
  check bool "probe marks 502 unhealthy" true
    (wait_until ~clock ~timeout_s:3.5 (fun () ->
       not (Provider_health.is_healthy health ~provider_id:"runpod")));
  Atomic.set status_code 200;
  check bool "probe marks 200 healthy" true
    (wait_until ~clock ~timeout_s:3.5 (fun () ->
       Provider_health.is_healthy health ~provider_id:"runpod"))
;;

let test_filter_healthy_skips_unhealthy_candidate () =
  Eio_main.run @@ fun _env ->
  let health =
    Provider_health.For_testing.create
      [ provider "A" ~unhealthy_threshold:1 ~recovery_threshold:1
      ; provider "B" ~unhealthy_threshold:1 ~recovery_threshold:1
      ; provider "C" ~unhealthy_threshold:1 ~recovery_threshold:1
      ]
  in
  Provider_health.record_attempt_result health ~provider_id:"A" ~success:false
    ~http_status:(Some 502);
  let filtered =
    Provider_health.filter_healthy health ~provider_id:(fun x -> x) [ "A"; "B"; "C" ]
  in
  check (list string) "unhealthy A removed" [ "B"; "C" ] filtered
;;

let test_parser_clamps_probe_interval_to_minimum () =
  let toml =
    {|
[providers.runpod]
protocol = "openai-http"
endpoint = "https://runpod.example/v1"

[providers.runpod.healthcheck]
enabled = true
endpoint = "https://runpod.example/health"
probe_interval_seconds = 1
unhealthy_threshold = 2
recovery_threshold = 2

[models.qwen]
api-name = "qwen"
max-context = 32768

[runpod.qwen]
|}
  in
  let cfg =
    match Cascade_declarative_parser.parse_string toml with
    | Ok cfg -> cfg
    | Error errs ->
      errs
      |> List.map (fun (err : Cascade_declarative_parser.parse_error) ->
             Printf.sprintf "%s: %s" err.path err.message)
      |> String.concat "; "
      |> failwith
  in
  match cfg.providers with
  | [ { Cascade_declarative_types.healthcheck = Some healthcheck; _ } ] ->
    check int "probe interval clamped" 60 healthcheck.probe_interval_seconds
  | _ -> failwith "expected one provider with healthcheck"
;;

let () =
  run "provider_health"
    [ ( "state"
      , [ test_case "failures trip unhealthy threshold" `Quick
            test_in_band_failure_threshold_marks_unhealthy
        ; test_case "successes trip recovery threshold" `Quick
            test_in_band_recovery_threshold_marks_healthy
        ; test_case "candidate filter skips unhealthy provider" `Quick
            test_filter_healthy_skips_unhealthy_candidate
        ; test_case "parser clamps probe interval" `Quick
            test_parser_clamps_probe_interval_to_minimum
        ] )
    ; ( "probe"
      , [ test_case "probe fiber tracks 502 to 200 transition" `Quick
            test_probe_loop_tracks_http_transition
        ] )
    ]
;;
