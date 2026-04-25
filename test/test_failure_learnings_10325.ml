(** Failure learning emit produces structured per-failure data, not a
    generic boilerplate string.

    Regression for masc-mcp #10325: 97% of [outcome=failure] entries in
    [.masc/institution_episodes.jsonl] previously contained the same
    placeholder ("persist failed keeper turns ...").  This defeated the
    institution-memory contract that downstream readers (governance
    judge, anti-rationalization, future keeper turns) consume.  After
    the fix, [learnings] carries [error_kind:X] and
    [error_message:Y] tags, or the explicit [NO_LEARNING] sentinel
    when neither has signal. *)

open Alcotest
open Masc_mcp

module Oas = Agent_sdk

let with_tmp_base_dir f =
  let base = Filename.temp_file "test_failure_learnings_10325" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let result =
    Fun.protect
      ~finally:(fun () ->
        try
          let cmd = Printf.sprintf "rm -rf %s" (Filename.quote base) in
          ignore (Sys.command cmd)
        with _ -> ())
      (fun () -> f base)
  in
  result

let extract_failure_learnings ~error_kind ~error_message =
  with_tmp_base_dir (fun base ->
      let memory = Memory_oas_bridge.create_memory ~agent_name:"test" ~base_dir:base () in
      Memory_oas_bridge.store_failed_turn_episode
        ~memory ~keeper_name:"test-keeper" ~turn:1
        ~trace_id:"trace-1" ~error_kind ~error_message ();
      let episodes = Oas.Memory.recall_episodes memory ~limit:10 () in
      match episodes with
      | [] -> failwith "no episode persisted"
      | ep :: _ ->
          (match List.assoc_opt "learnings" ep.metadata with
           | Some (`List items) ->
               List.filter_map
                 (function `String s -> Some s | _ -> None) items
           | _ -> failwith "learnings field missing or wrong shape"))

let test_no_generic_boilerplate () =
  let learnings =
    extract_failure_learnings
      ~error_kind:"oas_timeout_budget"
      ~error_message:"keeper exceeded budget after 12 turns"
  in
  List.iter
    (fun s ->
       check bool
         (Printf.sprintf "learning %S is not the legacy boilerplate" s)
         false
         (String.length s > 30
          && String.equal (String.sub s 0 30)
               "persist failed keeper turns so"))
    learnings

let test_kind_and_message_emitted_as_tags () =
  let learnings =
    extract_failure_learnings
      ~error_kind:"oas_timeout_budget"
      ~error_message:"keeper exceeded budget after 12 turns"
  in
  let has_kind =
    List.exists
      (fun s -> s = "error_kind:oas_timeout_budget")
      learnings
  in
  let has_message_tag =
    List.exists
      (fun s ->
         String.length s > 14
         && String.equal (String.sub s 0 14) "error_message:")
      learnings
  in
  check bool "error_kind tag emitted" true has_kind;
  check bool "error_message tag emitted" true has_message_tag

let test_no_learning_sentinel_when_both_blank () =
  let learnings =
    extract_failure_learnings ~error_kind:"" ~error_message:""
  in
  check (list string) "explicit absence sentinel"
    [ "[NO_LEARNING]" ] learnings

let test_only_kind_when_message_blank () =
  let learnings =
    extract_failure_learnings
      ~error_kind:"resumable_cli_session" ~error_message:""
  in
  check (list string) "only kind tag emitted"
    [ "error_kind:resumable_cli_session" ] learnings

let () =
  run "failure_learnings_10325"
    [
      ("learnings_emit", [
           test_case "no generic boilerplate string" `Quick
             test_no_generic_boilerplate;
           test_case "kind and message become tag entries" `Quick
             test_kind_and_message_emitted_as_tags;
           test_case "[NO_LEARNING] sentinel when both blank" `Quick
             test_no_learning_sentinel_when_both_blank;
           test_case "only error_kind when message blank" `Quick
             test_only_kind_when_message_blank;
         ]);
    ]
