(* The official-client idle window keeps a line that arrived as it passed.

   [Runtime_official_client_json.Make(E).with_idle_timeout] bounds every
   read of the claude code, codex app-server and antigravity lanes. It raced
   the read against a timer with [Eio.Time.with_timeout], which keeps
   whichever arm finished first: a line that arrived as the window passed
   ended the turn as an idle timeout. The mock clock queues the timer's
   wake-up ahead of the read's on purpose. *)
open Alcotest

module Stderr = Runtime_official_client_json.Stderr

let test_stderr_masks_across_reads_and_lines () =
  List.iter
    (fun (label, chunks, secret) ->
      let captured = Stderr.create ~limit:4096 in
      List.iter (Stderr.append captured) chunks;
      let text = Stderr.contents captured in
      check bool (label ^ ": credential hidden") false
        (Astring.String.is_infix ~affix:secret text);
      check bool (label ^ ": reason retained") true
        (Astring.String.is_infix ~affix:"authentication failed" text);
      check bool (label ^ ": masking is visible") true
        (Astring.String.is_infix ~affix:"[REDACTED]" text))
    [ "bearer", [ "authentication failed: Authorization: be"; "arer fixture-secret" ], "fixture-secret"
    ; "assignment", [ "authentication failed: VENDOR_API_"; "KEY=opaque-fixture" ], "opaque-fixture"
    ; "quoted", [ {|authentication failed: token="prefix\"|}; {|secret-tail"|} ], "secret-tail"
    ; "PEM", [ "authentication failed\n-----BEGIN PRIVATE KEY-----\n";
                "PRIVATE-FIXTURE-BODY\n"; "-----END PRIVATE KEY-----" ], "PRIVATE-FIXTURE-BODY"
    ]
;;

let test_stderr_overflow_never_exposes_a_suffix_without_its_prefix () =
  let captured = Stderr.create ~limit:64 in
  Stderr.append captured "Authorization: Bearer ";
  Stderr.append captured (String.make 96 's');
  Stderr.append captured "credential-tail";
  check string "over-limit bytes are discarded, not returned as a raw tail"
    "[stderr omitted: byte limit]" (Stderr.contents captured);
  let pem = Stderr.create ~limit:64 in
  Stderr.append pem "-----BEGIN PRIVATE KEY-----\n";
  Stderr.append pem (String.make 96 'k');
  Stderr.append pem "\n-----END PRIVATE KEY-----";
  check string "multiline overflow is also omitted"
    "[stderr omitted: byte limit]" (Stderr.contents pem)
;;

let test_stderr_preserves_short_diagnostics_without_newline () =
  let captured = Stderr.create ~limit:64 in
  Stderr.append captured "연결 ";
  Stderr.append captured "refused";
  check string "short diagnostic intact" "연결 refused" (Stderr.contents captured);
  let second = Stderr.create ~limit:64 in
  check string "another client starts empty" "" (Stderr.contents second)
;;

module Shared_json = Runtime_official_client_json.Make (struct
    type t = string

    let protocol ~stage ~detail = stage ^ ": " ^ detail
  end)

let window_s = 1.0

let test_a_line_that_arrived_as_the_window_passed_is_the_line () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let line, arrive = Eio.Promise.create () in
  let read =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Shared_json.with_idle_timeout clock window_s (fun () -> Eio.Promise.await line))
  in
  Eio_mock.Clock.set_time clock window_s;
  Eio.Promise.resolve arrive {|{"type":"result"}|};
  match Eio.Promise.await read with
  | Ok line -> check string "the line that arrived is the result" {|{"type":"result"}|} line
  | Error (Shared_json.Idle_timeout seconds) ->
    failf "a line that arrived as the %.1fs window passed was dropped" seconds
  | Error exn -> raise exn
;;

let test_a_read_nothing_answers_is_an_idle_timeout () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let never, _ = Eio.Promise.create () in
  let read =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Shared_json.with_idle_timeout clock window_s (fun () -> Eio.Promise.await never))
  in
  Eio_mock.Clock.set_time clock window_s;
  match Eio.Promise.await read with
  | Error (Shared_json.Idle_timeout seconds) -> check (float 0.0) "the window it names" window_s seconds
  | Ok () -> fail "nothing arrived, yet the read did not end as an idle timeout"
  | Error exn -> raise exn
;;

let () =
  Alcotest.run
    "runtime official client json"
    [ ( "stderr diagnostics"
      , [ test_case "credentials across reads and lines" `Quick
            test_stderr_masks_across_reads_and_lines
        ; test_case "overflow never exposes a prefixless credential" `Quick
            test_stderr_overflow_never_exposes_a_suffix_without_its_prefix
        ; test_case "short diagnostics need no newline" `Quick
            test_stderr_preserves_short_diagnostics_without_newline ])
    ; ( "the idle window"
      , [ test_case
            "a line that arrived as the window passed is the line"
            `Quick
            test_a_line_that_arrived_as_the_window_passed_is_the_line
        ; test_case
            "a read nothing answers is an idle timeout"
            `Quick
            test_a_read_nothing_answers_is_an_idle_timeout
        ] )
    ]
;;
