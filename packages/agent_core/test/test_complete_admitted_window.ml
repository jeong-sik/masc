(* The admitted completion spends from the same window as the measurement.

   After the count-tokens measurement, the completion is handed the window the
   caller opened before measuring, and opens none of its own. Handed a window
   the measurement left spent, it ends at the endpoint's permit as a [Queue]
   timeout and the transport is never reached. A completion that read the
   clock and added the budget again would take the free permit and reach it. *)
open Alcotest
open Llm_provider

let config ?max_concurrent_requests base_url =
  Provider_config.make
    ~kind:Provider_config.Anthropic
    ~model_id:"window-fixture"
    ~base_url
    ~api_key:"test-key"
    ~headers:[ "Content-Type", "application/json"; "anthropic-version", "2023-06-01" ]
    ~request_path:"/v1/messages"
    ~max_tokens:64
    ~max_context:512
    ?max_concurrent_requests
    ()
;;

let messages =
  [ { Types.role = Types.User
    ; content = [ Types.Text "How long may this wait?" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  ]
;;

(* Any positive budget: the window's clock is moved to its end before the
   window is handed on. *)
let spent_window_budget_s = 1.0

(* The resolver is the only door onto a deadline, here as on the call path. *)
let deadline_of ~clock ~timeout_s =
  match
    Http_client.resolve_explicit_deadline
      ~operation:"test_complete_admitted_window"
      ~parameter:"timeout_s"
      ~clock
      ~timeout_s
  with
  | Ok deadline -> deadline
  | Error _ -> failwith "the fixture budget was rejected"
;;

let spent_window () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  let window =
    Deadline_window.open_
      (deadline_of ~clock:(Some clock) ~timeout_s:(Some spent_window_budget_s))
  in
  Eio_mock.Clock.set_time clock spent_window_budget_s;
  window
;;

(* A window with no bound on it, for the measurement ahead of the case. *)
let unbounded_window : float Eio.Time.clock_ty Eio.Resource.t Deadline_window.t =
  Deadline_window.open_ (deadline_of ~clock:None ~timeout_s:None)
;;

let response =
  { Types.id = "window-response"
  ; model = "window-fixture"
  ; stop_reason = Types.EndTurn
  ; content = [ Types.Text "accepted" ]
  ; usage = None
  ; telemetry = None
  }
;;

(* A loopback count-tokens endpoint that answers every request with one
   measurement, so the case has an admitted request to hand on. *)
let with_count_endpoint f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen net ~sw ~backlog:4 ~reuse_addr:true (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> fail "expected a TCP listener"
  in
  let handler _conn _request body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) : string);
    Cohttp_eio.Server.respond_string ~status:`OK ~body:{|{"input_tokens":321}|} ()
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  f ~sw ~net ~base_url:(Printf.sprintf "http://127.0.0.1:%d" port)
;;

let complete_admitted_under_a_spent_window ~stream =
  let result, reached =
    with_count_endpoint
    @@ fun ~sw ~net ~base_url ->
    let prepared =
      Complete.prepare_request ~config:(config ~max_concurrent_requests:1 base_url) ~messages ()
    in
    let serialized =
      match Complete.admit_request_body ~stream prepared with
      | Ok serialized -> serialized
      | Error _ -> fail "request serialization admission failed"
    in
    let next_stage =
      if stream
      then Complete.Stream { admission_window = unbounded_window; first_event_timeout_s = None }
      else Complete.Completion { call_window = unbounded_window }
    in
    let admitted =
      match Complete.measure_request ~sw ~net ~next_stage serialized with
      | Error _ -> fail "expected an unbounded measurement to measure"
      | Ok measured ->
        (match Complete.admit_request ~now_unix_s:0 ~max_context_tokens:512 measured with
         | Ok admitted -> admitted
         | Error _ -> fail "expected the measured request to fit")
    in
    let reached = ref false in
    let transport =
      { Llm_transport.complete_sync =
          (fun _ ->
            reached := true;
            { Llm_transport.response = Ok response; latency_ms = None })
      ; complete_stream =
          (fun ?on_telemetry:_ ~on_event:_ _ ->
            reached := true;
            Ok response)
      }
    in
    let result =
      if stream
      then
        Complete.complete_stream_admitted
          ~sw
          ~net
          ~admission_window:(spent_window ())
          ~transport
          admitted
          ~on_event:ignore
          ()
      else
        Complete.complete_admitted
          ~sw
          ~net
          ~transport
          admitted
          ~call_window:(spent_window ())
          ()
    in
    result, !reached
  in
  (match result with
   | Error (Http_client.TimeoutError { phase = Http_client.Queue; _ }) -> ()
   | Error _ -> fail "a spent window ended the completion somewhere other than the permit"
   | Ok _ -> fail "a spent window still completed the request");
  check bool "the transport was never reached" false reached
;;

let test_a_spent_call_window_ends_the_admitted_completion_at_the_permit () =
  complete_admitted_under_a_spent_window ~stream:false
;;

let test_a_spent_admission_window_ends_the_admitted_stream_at_the_permit () =
  complete_admitted_under_a_spent_window ~stream:true
;;

let () =
  run
    "complete_admitted_window"
    [ ( "spent window"
      , [ test_case
            "a spent call window ends the admitted completion at the permit"
            `Quick
            test_a_spent_call_window_ends_the_admitted_completion_at_the_permit
        ; test_case
            "a spent admission window ends the admitted stream at the permit"
            `Quick
            test_a_spent_admission_window_ends_the_admitted_stream_at_the_permit
        ] )
    ]
;;
