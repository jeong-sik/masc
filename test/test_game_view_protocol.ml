(** GAME-VIEW protocol contract tests.

    Covers:
    - decision.create / decision.finalize flow
    - PRECONDITION_REQUIRED for experiment.start and trpg.action.submit
    - verifier WARN requires risk_ack
*)

open Alcotest
open Yojson.Safe.Util
open Masc_mcp

let rec mkdir_p path =
  if path = "" || path = "/" then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

let mk_room_config () =
  let tmp =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-game-view-test-%f" (Unix.gettimeofday ()))
  in
  mkdir_p tmp;
  let config = Room.default_config tmp in
  let _ = Room.init config ~agent_name:(Some "tester") in
  (config, tmp)

let parse_json s =
  try Yojson.Safe.from_string s
  with _ -> fail ("invalid json payload: " ^ s)

let get_payload json =
  json |> member "payload"

let expect_dispatch_some = function
  | Some v -> v
  | None -> fail "dispatch returned None"

let mk_council_ctx config =
  {
    Tool_council.base_path = config.Room_utils.base_path;
    agent_name = "tester";
    room_config = Some config;
  }

let mk_experiment_ctx config =
  {
    Tool_experiment.config;
    agent_name = "tester";
  }

let mk_trpg_ctx config =
  {
    Tool_trpg.config;
    agent_name = "tester";
  }

let test_precondition_required_without_finalize () =
  let config, tmp = mk_room_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    let exp_ctx = mk_experiment_ctx config in
    let trpg_ctx = mk_trpg_ctx config in
    let args = `Assoc [("session_id", `String "sess-precond-1")] in
    let ok_exp, out_exp =
      Tool_experiment.dispatch exp_ctx ~name:"experiment.start" ~args
      |> expect_dispatch_some
    in
    check bool "experiment should fail before finalize" false ok_exp;
    let exp_json = parse_json out_exp in
    check string "experiment error code"
      "PRECONDITION_REQUIRED"
      (exp_json |> member "payload" |> member "code" |> to_string);

    let trpg_args = `Assoc [
      ("session_id", `String "sess-precond-1");
      ("action", `String "scout area");
    ] in
    let ok_trpg, out_trpg =
      Tool_trpg.dispatch trpg_ctx ~name:"trpg.action.submit" ~args:trpg_args
      |> expect_dispatch_some
    in
    check bool "trpg should fail before finalize" false ok_trpg;
    let trpg_json = parse_json out_trpg in
    check string "trpg error code"
      "PRECONDITION_REQUIRED"
      (trpg_json |> member "payload" |> member "code" |> to_string)
  )

let test_decision_finalize_warn_requires_risk_ack () =
  let config, tmp = mk_room_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    let council_ctx = mk_council_ctx config in
    let create_args = `Assoc [
      ("session_id", `String "sess-warn-1");
      ("issue", `String "choose strategy");
      ("options", `List [`String "A"; `String "B"]);
    ] in
    let ok_create, out_create =
      Tool_council.dispatch council_ctx ~name:"decision.create" ~args:create_args
      |> expect_dispatch_some
    in
    check bool "decision.create success" true ok_create;
    let decision_id =
      out_create
      |> parse_json
      |> get_payload
      |> member "decision_id"
      |> to_string
    in

    let finalize_warn_no_ack = `Assoc [
      ("session_id", `String "sess-warn-1");
      ("decision_id", `String decision_id);
      ("selected_option", `String "A");
      ("rationale", `String "risk acceptable");
      ("verifier", `String "WARN");
    ] in
    let ok_warn, _ =
      Tool_council.dispatch council_ctx ~name:"decision.finalize" ~args:finalize_warn_no_ack
      |> expect_dispatch_some
    in
    check bool "WARN without risk_ack should fail" false ok_warn
  )

let test_finalize_then_experiment_and_trpg_success () =
  let config, tmp = mk_room_config () in
  Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
    let council_ctx = mk_council_ctx config in
    let exp_ctx = mk_experiment_ctx config in
    let trpg_ctx = mk_trpg_ctx config in

    let create_args = `Assoc [
      ("session_id", `String "sess-ok-1");
      ("issue", `String "choose next move");
      ("options", `List [`String "trade"; `String "explore"]);
      ("criteria", `List [`String "impact"; `String "risk"]);
    ] in
    let ok_create, out_create =
      Tool_council.dispatch council_ctx ~name:"decision.create" ~args:create_args
      |> expect_dispatch_some
    in
    check bool "decision.create success" true ok_create;
    let decision_id =
      out_create
      |> parse_json
      |> get_payload
      |> member "decision_id"
      |> to_string
    in

    let finalize_args = `Assoc [
      ("session_id", `String "sess-ok-1");
      ("decision_id", `String decision_id);
      ("selected_option", `String "explore");
      ("rationale", `String "best upside");
      ("confidence", `Float 0.81);
      ("verifier", `String "PASS");
    ] in
    let ok_finalize, out_finalize =
      Tool_council.dispatch council_ctx ~name:"decision.finalize" ~args:finalize_args
      |> expect_dispatch_some
    in
    check bool "decision.finalize success" true ok_finalize;
    check string "finalize status"
      "finalized"
      (out_finalize |> parse_json |> get_payload |> member "status" |> to_string);

    let exp_args = `Assoc [
      ("session_id", `String "sess-ok-1");
      ("hypothesis", `String "engagement rises");
      ("metrics", `List [`String "engagement"]);
    ] in
    let ok_exp, out_exp =
      Tool_experiment.dispatch exp_ctx ~name:"experiment.start" ~args:exp_args
      |> expect_dispatch_some
    in
    check bool "experiment.start success" true ok_exp;
    check string "experiment status"
      "running"
      (out_exp |> parse_json |> get_payload |> member "status" |> to_string);

    let trpg_args = `Assoc [
      ("session_id", `String "sess-ok-1");
      ("action", `String "inspect market");
      ("intent", `String "gather clues");
      ("stakes", `String "medium");
    ] in
    let ok_trpg, out_trpg =
      Tool_trpg.dispatch trpg_ctx ~name:"trpg.action.submit" ~args:trpg_args
      |> expect_dispatch_some
    in
    check bool "trpg.action.submit success" true ok_trpg;
    check bool "trpg has story_log" true
      (out_trpg |> parse_json |> get_payload |> member "story_log" |> to_string <> "")
  )

let () =
  Alcotest.run "GAME-VIEW Protocol" [
    ("precondition", [
      test_case "precondition_required_without_finalize" `Quick
        test_precondition_required_without_finalize;
    ]);
    ("decision_verifier", [
      test_case "warn_requires_risk_ack" `Quick
        test_decision_finalize_warn_requires_risk_ack;
    ]);
    ("happy_path", [
      test_case "finalize_then_experiment_trpg_success" `Quick
        test_finalize_then_experiment_and_trpg_success;
    ]);
  ]
