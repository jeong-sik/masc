(** Regression test for SSE keepalive comment handling in
    [Llm_provider.Http_client.read_sse].

    Per the W3C EventSource spec, lines starting with [':'] are
    comments / keepalives and carry no event payload.  They must
    not trigger [on_data] callbacks and (in the timeout-aware code
    path) must not reset the idle deadline — otherwise a provider
    emitting only keepalives would never trip [idle_timeout] and the
    stream would only terminate on the upstream consumer's hard cap.

    This test pins the [on_data] skip invariant via in-memory
    payloads.  The deadline-preservation invariant is asserted
    directly in [test_sse_budget_anchor.ml], which drives a mock clock
    from inside the read and covers the other non-payload line shapes
    ([id]/[retry], unknown fields, bare dispatch delimiters) that must
    not renew the armed budget either. *)

open Alcotest
open Agent_sdk
open Llm_provider

let collect_sse_events payload =
  Eio_main.run
  @@ fun _env ->
  let flow = Eio.Flow.string_source payload in
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
  let calls = ref [] in
  let on_data ~event_type data = calls := (event_type, data) :: !calls in
  Http_client.read_sse ~reader ~on_data ();
  List.rev !calls
;;

let test_keepalive_lines_skipped_between_real_events () =
  let payload =
    ": keepalive 1\n\
     : keepalive 2\n\
     event: ping\n\
     data: hello\n\n\
     : trailing keepalive\n\
     event: pong\n\
     data: world\n\n"
  in
  let calls = collect_sse_events payload in
  check int "two real events delivered" 2 (List.length calls);
  let expected = [ Some "ping", "hello"; Some "pong", "world" ] in
  check
    (list (pair (option string) string))
    "events match (keepalives skipped)"
    expected
    calls
;;

let test_keepalive_only_stream_produces_no_events () =
  let payload = ": ka1\n: ka2\n: ka3\n: ka4\n" in
  let calls = collect_sse_events payload in
  check int "keepalive-only stream produces no on_data calls" 0 (List.length calls)
;;

let test_bare_colon_line_treated_as_keepalive () =
  (* A lone ":" with no following text is still a comment per spec. *)
  let payload = ":\n:\nevent: ready\ndata: ok\n\n" in
  let calls = collect_sse_events payload in
  check int "one event after bare-colon keepalives" 1 (List.length calls);
  match calls with
  | [ (Some "ready", "ok") ] -> ()
  | _ -> fail "expected exactly (Some \"ready\", \"ok\")"
;;

let () =
  run
    "SSE keepalive idle timer"
    [ ( "keepalive_skip"
      , [ test_case
            "events delivered, keepalives skipped"
            `Quick
            test_keepalive_lines_skipped_between_real_events
        ; test_case
            "keepalive-only stream produces no events"
            `Quick
            test_keepalive_only_stream_produces_no_events
        ; test_case
            "bare colon line treated as keepalive"
            `Quick
            test_bare_colon_line_treated_as_keepalive
        ] )
    ]
;;
