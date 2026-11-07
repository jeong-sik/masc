(** McpSessionStore.start_loop must restore the pre-loop state when its
    switch closes: dispatch falls back to synchronous processing and the
    drained mailbox answers stranded callers instead of leaving them
    awaiting unresolved promises forever (감사 8/8 범주 2 — session.ml
    영구 먹통).  On the pre-fix code the post-shutdown calls below hang on
    unresolved promises; with the fix they answer synchronously. *)

open Alcotest

let test_store_survives_loop_shutdown () =
  Eio_main.run (fun _env ->
      Eio.Switch.run (fun sw ->
          Masc.Session.McpSessionStore.start_loop ~sw;
          let live = Masc.Session.McpSessionStore.create () in
          check string "loop serves create" "mcp_"
            (String.sub live.id 0 4)));
  (* The loop fiber is dead; the fallback path must answer. *)
  let id = Masc.Session.McpSessionStore.generate_id () in
  check string "fallback serves generate_id" "mcp_" (String.sub id 0 4);
  let session = Masc.Session.McpSessionStore.create () in
  check string "fallback serves create" "mcp_"
    (String.sub session.id 0 4);
  let fetched = Masc.Session.McpSessionStore.get session.id in
  check (option string) "fallback get returns the created id"
    (Some session.id)
    (Option.map (fun s -> s.id) fetched)

let () =
  run "McpSessionStore loop lifecycle"
    [ ( "lifecycle"
      , [ test_case
            "store survives loop shutdown"
            `Quick
            test_store_survives_loop_shutdown ] ) ]
;;
