(** The armed SSE deadline is anchored to the last PAYLOAD-bearing line, not
    to the last line read, and a line counts by when it arrived.

    [Llm_provider.Http_client.read_sse] consumes keepalive comments inside one
    budgeted read so a comment-only stream still trips its budget. Three other
    line shapes carry no payload and arm no fresh budget either: [id]/[retry]
    fields, unknown field names, and bare blank dispatch delimiters, any of
    which a provider could otherwise emit just under each budget to hold a
    stream open without ever producing an event. Where the budget ends, a line
    that landed as it closed is read, and one the flow hands over after it
    closed is not.

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

(* For the [`Both] shape: an inter-token budget shorter than one line gap, so
   it trips on the very next read after it arms, beside a first-event budget
   that admits any single gap. Which budget is armed at each read then shows
   in how many events are delivered before the trip. *)
let inter_token_budget_under_one_gap_s = 0.3

(* [classify] is what the consumer tells the reader about each dispatched
   event; every event is [Output] unless a test says otherwise. *)
let read_sse_over ?(classify = fun (_ : string) -> Http_client.Output) ~budget_kind lines =
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
        ~on_data:(fun ~event_type data ->
          events := (event_type, data) :: !events;
          Http_client.Continue (classify data))
        ()
    | `Both ->
      Http_client.read_sse
        ~clock
        ~first_event_timeout:first_event_budget_s
        ~idle_timeout:inter_token_budget_under_one_gap_s
        ~reader
        ~on_data:(fun ~event_type data ->
          events := (event_type, data) :: !events;
          Http_client.Continue (classify data))
        ()
    | `Idle ->
      Http_client.read_sse
        ~clock
        ~idle_timeout:idle_budget_s
        ~reader
        ~on_data:(fun ~event_type data ->
          events := (event_type, data) :: !events;
          Http_client.Continue (classify data))
        ()
  in
  match read () with
  | () -> Ok (List.rev !events)
  | exception Eio.Time.Timeout -> Error (`Timed_out (List.rev !events))
;;

let check_timed_out label result =
  match result with
  | Error (`Timed_out _) -> ()
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

let test_prelude_event_keeps_the_first_event_budget () =
  (* A Responses stream opens with [response.created] before prefill. Each
     event arrives whole, one per gap: "created" at 0.4 is [Prelude], so the
     first-event budget (1.0, anchored at the first read) stays armed and
     "out" at 0.8 is delivered; "out" is [Output], so the inter-token budget
     (0.3) arms at that dispatch and the read for "more" at 1.2 trips it. A
     reader that switched budgets on the first data line would have armed
     0.3 at "created" and tripped before "out". *)
  let classify data =
    if String.equal data "created" then Http_client.Prelude else Http_client.Output
  in
  match
    read_sse_over
      ~classify
      ~budget_kind:`Both
      [ "data: created\n\n"; "data: out\n\n"; "data: more\n\n" ]
  with
  | Error (`Timed_out delivered) ->
    check
      (list (pair (option string) string))
      "events delivered before the inter-token budget tripped"
      [ None, "created"; None, "out" ]
      delivered
  | Ok events ->
    failf
      "prelude stream ran to EOF instead of tripping the inter-token budget (%d events)"
      (List.length events)
;;

let test_prelude_events_do_not_extend_the_first_event_budget () =
  (* The first-event budget is one window to the first token, not one per
     prelude frame. Prelude events every 0.4 keep each gap under the 1.0
     budget, and the read after the second one lands at 1.2, past the anchor
     taken at the first read: the budget trips with two prelude events
     delivered and the token never read. A reader that re-anchored on every
     payload line would read "out" at 1.6 and run to EOF. *)
  let classify data =
    if String.equal data "out" then Http_client.Output else Http_client.Prelude
  in
  match
    read_sse_over
      ~classify
      ~budget_kind:`First_event
      [ "data: created\n\n"; "data: ping\n\n"; "data: ping\n\n"; "data: out\n\n" ]
  with
  | Error (`Timed_out delivered) ->
    check
      (list (pair (option string) string))
      "prelude events delivered before the first-event budget tripped"
      [ None, "created"; None, "ping" ]
      delivered
  | Ok events ->
    failf
      "prelude frames extended the first-event budget: ran to EOF with %d events"
      (List.length events)
;;

let test_idle_standing_in_for_the_first_event_stays_a_gap () =
  (* A caller that wired only an idle deadline has it bound the first event
     too, with the meaning it always had: every payload line renews it. The
     same prelude cadence that trips a first-event budget above (events every
     0.4 under a 1.0 budget, the token at 1.6) runs to EOF here, so the total
     window is the first-event knob's meaning and not a new bound on these
     callers. *)
  let classify data =
    if String.equal data "out" then Http_client.Output else Http_client.Prelude
  in
  match
    read_sse_over
      ~classify
      ~budget_kind:`Idle
      [ "data: created\n\n"; "data: ping\n\n"; "data: ping\n\n"; "data: out\n\n" ]
  with
  | Ok events ->
    check
      (list (pair (option string) string))
      "every event delivered under the idle gap"
      [ None, "created"; None, "ping"; None, "ping"; None, "out" ]
      events
  | Error (`Timed_out delivered) ->
    failf
      "an idle budget standing in for the first event became a total: tripped after %d events"
      (List.length delivered)
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
  | Error (`Timed_out _) -> fail "payload-bearing lines must renew the inter-token budget"
;;

(* How one chunk reaches the reader. *)
type arrival =
  | After_a_gap of string
    (** the clock moves one line gap while the read waits, then the chunk
        arrives *)
  | As_the_first_event_budget_closes of string
    (** the read is waiting when the first-event budget closes, and the chunk
        lands in that same pass: the budget's wake-up is queued first and the
        read's behind it *)
  | At_once of string
    (** the flow hands the chunk over the moment the read asks *)

let output_is_out data =
  if String.equal data "out" then Http_client.Output else Http_client.Prelude
;;

(* A first-event budget alone, anchored at the first read at 0.0, so it closes
   at [first_event_budget_s]; once the consumer reports [Output] nothing else
   is armed and the stream reads to its end. *)
let read_sse_arriving arrivals =
  Eio_mock.Backend.run
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio_mock.Clock.make () in
  let now = ref 0.0 in
  Eio_mock.Clock.set_time clock !now;
  let lands_as_the_budget_closes chunk () =
    let landed, deliver = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      (* The read is left to wait first, so the chunk's wake-up queues behind
         the budget's. *)
      Eio.Fiber.yield ();
      now := first_event_budget_s;
      Eio_mock.Clock.set_time clock !now;
      Eio.Promise.resolve deliver chunk);
    Eio.Promise.await landed
  in
  let action = function
    | After_a_gap chunk -> `Run (emit_after_gap ~clock ~now chunk)
    | As_the_first_event_budget_closes chunk -> `Run (lands_as_the_budget_closes chunk)
    | At_once chunk -> `Return chunk
  in
  let flow = Eio_mock.Flow.make "sse-arrival" in
  Eio_mock.Flow.on_read flow (List.map action arrivals @ [ `Raise End_of_file ]);
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let events = ref [] in
  match
    Http_client.read_sse
      ~clock
      ~first_event_timeout:first_event_budget_s
      ~reader
      ~on_data:(fun ~event_type data ->
        events := (event_type, data) :: !events;
        Http_client.Continue (output_is_out data))
      ()
  with
  | () -> Ok (List.rev !events)
  | exception Eio.Time.Timeout -> Error (`Timed_out (List.rev !events))
;;

let test_a_first_token_that_lands_as_the_budget_closes_is_delivered () =
  (* "created" arrives at 0.4 and is [Prelude]. The token's read is waiting
     when the budget closes at 1.0 and the token lands in that pass, its
     dispatch delimiter in the same chunk. The provider sent it in time, so it
     is delivered: the token's read had started inside the budget, and the
     delimiter is read after the budget closed because it had already
     arrived. *)
  match
    read_sse_arriving
      [ After_a_gap "data: created\n\n"; As_the_first_event_budget_closes "data: out\n\n" ]
  with
  | Ok events ->
    check
      (list (pair (option string) string))
      "the token that landed as the budget closed is delivered"
      [ None, "created"; None, "out" ]
      events
  | Error (`Timed_out delivered) ->
    failf
      "a first token that landed as the first-event budget closed was dropped after %d \
       events"
      (List.length delivered)
;;

let test_a_line_handed_over_after_the_budget_closed_is_not_read () =
  (* A [Prelude] "ping" lands as the budget closes and stands, delimiter and
     all. The flow hands over the next chunk at once, but the budget had
     closed before the read asked for it: the budget ends the stream there
     and "out" is never delivered. A reader that took whatever the flow gave
     after the budget closed would read on for as long as a provider kept
     sending. *)
  match
    read_sse_arriving
      [ After_a_gap "data: created\n\n"
      ; As_the_first_event_budget_closes "data: ping\n\n"
      ; At_once "data: out\n\n"
      ]
  with
  | Error (`Timed_out delivered) ->
    check
      (list (pair (option string) string))
      "what landed by the close is delivered, and nothing after it"
      [ None, "created"; None, "ping" ]
      delivered
  | Ok events ->
    failf
      "a line handed over after the first-event budget closed was read: ran to EOF with \
       %d events"
      (List.length events)
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
    ; ( "prelude"
      , [ test_case
            "a prelude event keeps the first-event budget"
            `Quick
            test_prelude_event_keeps_the_first_event_budget
        ; test_case
            "prelude events do not extend the first-event budget"
            `Quick
            test_prelude_events_do_not_extend_the_first_event_budget
        ; test_case
            "an idle budget standing in for the first event stays a gap"
            `Quick
            test_idle_standing_in_for_the_first_event_stays_a_gap
        ] )
    ; ( "where the budget ends"
      , [ test_case
            "a first token that lands as the budget closes is delivered"
            `Quick
            test_a_first_token_that_lands_as_the_budget_closes_is_delivered
        ; test_case
            "a line handed over after the budget closed is not read"
            `Quick
            test_a_line_handed_over_after_the_budget_closed_is_not_read
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
