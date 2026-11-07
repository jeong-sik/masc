(** McpSessionStore.start_loop must restore the pre-loop state when its
    switch closes: dispatch falls back to synchronous processing and the
    drained mailbox answers stranded callers instead of leaving them
    awaiting unresolved promises forever (감사 8/8 범주 2 — session.ml
    영구 먹통).  On the pre-fix code the post-shutdown calls below hang on
    unresolved promises; with the fix they answer synchronously.  The
    session record is abstract to tests, so the round-trip is asserted
    through the probe id rather than record fields. *)

open Alcotest

let test_store_survives_loop_shutdown () =
  Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
          Masc.Session.McpSessionStore.start_loop ~sw;
          ignore (Masc.Session.McpSessionStore.create ())));
  (* The loop fiber is dead; the fallback path must answer. *)
  let id = Masc.Session.McpSessionStore.generate_id () in
  check bool "fallback serves generate_id" true (String.length id > 0);
  let known = "mcp-test-loop-shutdown-probe" in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:known ());
  let fetched = Masc.Session.McpSessionStore.get known in
  check bool "fallback get returns the probe session" true
    (Option.is_some fetched)

let () =
  run "McpSessionStore loop lifecycle"
    [ ( "lifecycle"
      , [ test_case
            "store survives loop shutdown"
            `Quick
            test_store_survives_loop_shutdown ] ) ]
;;
