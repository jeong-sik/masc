(** The armed SSE deadline must be anchored to the last PAYLOAD-bearing line,
    not to the last line read.

    [Llm_provider.Http_client.read_sse] consumes keepalive comments inside one
    [with_timeout_exn] window so a comment-only stream still trips its budget.
    Three other line shapes carry no payload and used to escape that window,
    each one arming a fresh full budget: [id]/[retry] fields, unknown field
    names, and bare blank dispatch delimiters. A provider emitting one of them
    just under each budget could hold a stream open indefinitely without ever
    producing an event.

    These tests drive a mock clock from inside the mock flow's read, so they
    assert the deadline arithmetic itself with no wall-clock sleeping. *)

open Alcotest
open Llm_provider

(* The budget is deliberately not a multiple of the gap: the third read must
   land past the anchor's deadline while each individual gap stays well under
   a full budget, which is exactly the shape a per-read window would miss. *)
let first_event_budget_s = 1.0
let idle_budget_s = 1.0
let line_gap_s = 0.4

(* Advancing the clock only queues the due sleeper; the read must reach a
   scheduling point for the cancellation to be delivered. *)
let emit_after_gap ~clock ~now line () =
  now := !now +. line_gap_s;
  Eio_mock.Clock.set_time clock !now;
  Eio.Fiber.yield ();
  line
;;

let read_sse_over ~budget_kind lines =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  let now = ref 0.0 in
  Eio_mock.Clock.set_time clock !now;
  let flow = Eio_mock.Flow.make "sse-budget-anchor" in
  let actions : string Eio_mock.Handler.actions =
    List.map (fun line -> `Run (emit_after_gap ~clock ~now line)) lines
    @ [ `Raise End_of_file ]
  in
  Eio_mock.Flow.on_read flow actions;
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  let read () =
    match budget_kind with
    | `First_event ->
      Http_client.read_sse
        ~clock
        ~first_event_timeout:first_event_budget_s
        ~reader
        ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
        ()
    | `Idle ->
      Http_client.read_sse
        ~clock
        ~idle_timeout:idle_budget_s
        ~reader
        ~on_data:(fun ~event_type data -> events := (event_type, data) :: !events)
        ()
  in
  match read () with
  | () -> Ok (List.rev !events)
  | exception Eio.Time.Timeout -> Error `Timed_out
;;

let check_timed_out label result =
  match result with
  | Error `Timed_out -> ()
  | Ok events ->
    failf
      "%s: stream ran to EOF instead of tripping its budget (%d events delivered)"
      label
      (List.length events)
;;

let test_ignored_fields_do_not_renew_first_event_budget () =
  (* [id] and [retry] are spec-valid fields this client does not consume. *)
  read_sse_over
    ~budget_kind:`First_event
    [ "id: 1\n"; "retry: 5000\n"; "id: 2\n"; "id: 3\n" ]
  |> check_timed_out "id/retry fields"
;;

let test_unknown_fields_do_not_renew_first_event_budget () =
  read_sse_over
    ~budget_kind:`First_event
    [ "x-vendor: a\n"; "x-vendor: b\n"; "x-vendor: c\n"; "x-vendor: d\n" ]
  |> check_timed_out "unknown field names"
;;

let test_blank_delimiters_do_not_renew_first_event_budget () =
  (* A blank line with nothing accumulated dispatches nothing. *)
  read_sse_over ~budget_kind:`First_event [ "\n"; "\n"; "\n"; "\n" ]
  |> check_timed_out "bare dispatch delimiters"
;;

let test_event_fields_do_not_end_first_event_budget () =
  (* An [event] field only selects the dispatch type. Until a [data] field
     arrives, the EventSource parser has no payload-bearing event to deliver. *)
  read_sse_over
    ~budget_kind:`First_event
    [ "event: message\n"; "\n"; "event: future\n"; "\n" ]
  |> check_timed_out "event fields without data"
;;

let test_ignored_fields_do_not_renew_idle_budget () =
  (* Same hole after the stream has produced: the inter-token budget must
     measure from the last payload, not from the last ignorable line. *)
  read_sse_over
    ~budget_kind:`Idle
    [ "data: hello\n"; "\n"; "id: 1\n"; "id: 2\n"; "id: 3\n" ]
  |> check_timed_out "ignorable lines after first event"
;;

let test_data_fields_do_renew_the_idle_budget () =
  (* Positive control: real payload at the same cadence must NOT trip the
     budget, so the anchoring above cannot be satisfied by simply arming an
     absolute deadline over the whole stream. *)
  match
    read_sse_over
      ~budget_kind:`Idle
      [ "data: one\n"; "\n"; "data: two\n"; "\n"; "data: three\n"; "\n" ]
  with
  | Ok events ->
    check
      (list (pair (option string) string))
      "every event delivered"
      [ None, "one"; None, "two"; None, "three" ]
      events
  | Error `Timed_out -> fail "payload-bearing lines must renew the inter-token budget"
;;

let () =
  run
    "SSE budget anchor"
    [ ( "first_event"
      , [ test_case
            "id/retry fields do not renew"
            `Quick
            test_ignored_fields_do_not_renew_first_event_budget
        ; test_case
            "unknown fields do not renew"
            `Quick
            test_unknown_fields_do_not_renew_first_event_budget
        ; test_case
            "bare delimiters do not renew"
            `Quick
            test_blank_delimiters_do_not_renew_first_event_budget
        ; test_case
            "event fields without data do not end first-event budget"
            `Quick
            test_event_fields_do_not_end_first_event_budget
        ] )
    ; ( "idle"
      , [ test_case
            "ignorable lines do not renew"
            `Quick
            test_ignored_fields_do_not_renew_idle_budget
        ; test_case
            "data fields do renew"
            `Quick
            test_data_fields_do_renew_the_idle_budget
        ] )
    ]
;;
