module Engine = Artifact_document_engine
let accepted = function Ok value -> value | Error error -> Alcotest.fail (Engine.error_message error)
let require_error kind = function
  | Error error when error.Engine.kind = kind -> ()
  | Error error -> Alcotest.fail ("wrong refusal: " ^ error.message)
  | Ok _ -> Alcotest.fail "unexpected acceptance"
let response status json _input = Ok (Unix.WEXITED status, Yojson.Safe.to_string json)
let state = "AAA="
let snapshot content = `Assoc ["ok", `Bool true; "state", `String state; "content", `String content]
let boundary_tests = [
  "duplicate transformer fields", `Quick, (fun () ->
    let runner = response 0 (`Assoc ["ok", `Bool true; "state", `String state; "state", `String state; "content", `String "source"]) in
    require_error Engine.Unavailable (Engine.seed ~runner "source"));
  "exit and response disagreement", `Quick, (fun () ->
    require_error Engine.Unavailable (Engine.seed ~runner:(response 2 (snapshot "source")) "source"));
  "closed refusal contract", `Quick, (fun () ->
    let runner = response 2 (`Assoc ["ok", `Bool false; "code", `String "changed_selection"; "message", `String "changed"]) in
    require_error Engine.Changed_selection (Engine.seed ~runner "source");
    let runner = response 2 (`Assoc ["ok", `Bool false; "code", `String "unknown"; "message", `String "unknown"]) in
    require_error Engine.Unavailable (Engine.seed ~runner "source"));
  "UTF16 position bounds", `Quick, (fun () ->
    let runner = response 0 (`Assoc ["ok", `Bool true; "state", `String state; "content", `String "한";
      "selection", `Assoc ["anchor", `List []; "head", `List []];
      "range", `Assoc ["anchor", `Int 2; "head", `Int 2]]) in
    require_error Engine.Unavailable (Engine.select ~runner ~state ~anchor:0 ~head:0 ()));
  "canonical state and valid source", `Quick, (fun () ->
    let called = ref false in
    let runner input = called := true; response 0 (snapshot input) input in
    require_error Engine.Invalid_request (Engine.merge ~runner ~state:"AB==" ~updates:[] ());
    require_error Engine.Invalid_request (Engine.seed ~runner "\255");
    Alcotest.(check bool) "no process for invalid command" false !called);
]
let with_runtime f = Eio_main.run (fun env ->
  Process_eio.init ~cwd_default:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.run (fun sw -> Eio.Switch.on_release sw Process_eio.reset_for_testing; f ()))
let integration_tests executable =
  let runner = Engine.default_runner ~executable in [
    "real seed select edit and stale refusal", `Quick, (fun () -> with_runtime (fun () ->
      let original = accepted (Engine.seed ~runner "한글 😀\r\n공동 편집\r\n") in
      let selected = accepted (Engine.select ~runner ~state:original.state ~anchor:7 ~head:9 ()) in
      let edited = accepted (Engine.edit ~runner ~state:original.state ~selection:selected.selection ~expected:"공동" ~replacement:"실시간 공동" ()) in
      Alcotest.(check string) "source" "한글 😀\r\n실시간 공동 편집\r\n" edited.snapshot.content;
      Alcotest.(check int) "UTF16 start" 7 edited.anchor;
      Alcotest.(check int) "UTF16 end" 13 edited.head;
      require_error Engine.Changed_selection (Engine.edit ~runner ~state:edited.snapshot.state ~selection:selected.selection ~expected:"공동" ~replacement:"overwrite" ())));
    "complete stdout beyond process preview", `Quick, (fun () -> with_runtime (fun () ->
      let content = "한글 😀\r\n" ^ String.make (128 * 1024) 'x' in
      let original = accepted (Engine.seed ~runner content) in
      let restored = accepted (Engine.merge ~runner ~state:original.state ~updates:[] ()) in
      Alcotest.(check string) "full content" content restored.content));
    "failed executable is unavailable", `Quick, (fun () -> with_runtime (fun () ->
      let runner = Engine.default_runner ~executable:(executable ^ ".missing") in
      require_error Engine.Unavailable (Engine.seed ~runner "source")));
    "hanging transformer is bounded and refused as unavailable", `Slow, (fun () -> with_runtime (fun () ->
      let dir = Filename.get_temp_dir_name () in
      let path = Filename.concat dir "masc-stub-hangs" in
      let oc = open_out_bin path in
      Printf.fprintf oc "#!/bin/sh\nsleep 600\n";
      close_out oc;
      Unix.chmod path 0o755;
      let started = Unix.gettimeofday () in
      require_error Engine.Unavailable (Engine.seed ~runner:(Engine.default_runner ~executable:path) "source");
      let took = Unix.gettimeofday () -. started in
      Alcotest.(check bool) "bounded well under the 600s hang"
        (took < 600.0) true));
  ]
let () =
  let integration, argv = if Array.length Sys.argv = 3 && Sys.argv.(1) = "--transformer"
    then integration_tests Sys.argv.(2), [|Sys.argv.(0)|] else [], Sys.argv in
  Alcotest.run ~argv "Artifact document engine" ["boundary", boundary_tests; "subprocess", integration]
