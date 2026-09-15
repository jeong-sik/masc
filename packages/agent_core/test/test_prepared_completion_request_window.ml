(* The measurement spends from the window its caller opened.

   A caller that measures its request before sending it has one budget over
   both stages, and opens it once as a [Deadline_window]. These cases hand the
   measurement a window whose clock is already at its end: the measurement
   ends at the permit, as a [Queue] timeout, and the count request is not
   sent. A measurement that read the clock and added the budget again would
   send it, and would end as whatever the connection to
   [unreachable_base_url] did. *)
open Alcotest
open Llm_provider

(* Nothing listens on loopback port 1, so a request sent there never reaches
   a server. *)
let unreachable_base_url = "http://127.0.0.1:1"

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
      ~operation:"test_prepared_completion_request_window"
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

let measure_under_a_spent_window ~stream next_stage =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let prepared =
    Complete.prepare_request ~config:(config unreachable_base_url) ~messages ()
  in
  let serialized =
    match Complete.admit_request_body ~stream prepared with
    | Ok serialized -> serialized
    | Error _ -> fail "request serialization admission failed"
  in
  match
    Complete.measure_request
      ~sw
      ~net:(Eio.Stdenv.net env)
      ~next_stage:(next_stage (spent_window ()))
      serialized
  with
  | Error
      (Count_tokens_sync.Input_count_failed
         (Input_token_count.Transport
            (Http_client.TimeoutError { phase = Http_client.Queue; _ }))) -> ()
  | Error _ -> fail "a spent window ended the measurement somewhere other than the permit"
  | Ok _ -> fail "a spent window still measured the request"
;;

let test_a_spent_call_window_ends_the_measurement_at_the_permit () =
  measure_under_a_spent_window ~stream:false (fun call_window ->
    Complete.Completion { call_window })
;;

let test_a_spent_admission_window_ends_the_measurement_at_the_permit () =
  measure_under_a_spent_window ~stream:true (fun admission_window ->
    Complete.Stream { admission_window; first_event_timeout_s = None })
;;

let () =
  run
    "prepared_completion_request_window"
    [ ( "spent window"
      , [ test_case
            "a spent call window ends the measurement at the permit"
            `Quick
            test_a_spent_call_window_ends_the_measurement_at_the_permit
        ; test_case
            "a spent admission window ends the measurement at the permit"
            `Quick
            test_a_spent_admission_window_ends_the_measurement_at_the_permit
        ] )
    ]
;;
