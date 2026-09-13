open Alcotest
open Masc
module VAT = Verification_authority_tools
let () = Mirage_crypto_rng_unix.use_default ()
let require label = function Ok value -> value | Error _ -> fail label
let rec remove path =
  if Sys.is_directory path then (Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path); Unix.rmdir path)
  else Unix.unlink path
let with_fixture f = Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_test_deps.init_unified_tool_registry ();
  let base = Filename.temp_dir "verification-collaboration-" "" in
  let old = Sys.getenv_opt "MASC_BASE_PATH" and old_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  Unix.putenv "MASC_BASE_PATH" base; Unix.putenv "MASC_BASE_PATH_INPUT" base;
  Board.reset_global_for_test (); Board_dispatch.reset_for_test ();
  Fun.protect ~finally:(fun () ->
    Board.reset_global_for_test (); Board_dispatch.reset_for_test ();
    Unix.putenv "MASC_BASE_PATH" (Option.value old ~default:"");
    Unix.putenv "MASC_BASE_PATH_INPUT" (Option.value old_input ~default:""); remove base)
    (fun () ->
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some "producer"));
      f config)
let call surface name args = VAT.dispatch surface ~name ~args
let read surface name args =
  match call surface name args with
  | Tool_result.Completed _ as result -> Yojson.Safe.from_string (Tool_result.message result)
  | result -> failf "source read failed: %s" (Tool_result.message result)
let denied surface name args code =
  match call surface name args with
  | Tool_result.Failed _ as result ->
    let expected_class = match code with
      | "verification_source_access_denied" -> Tool_result.Policy_rejection
      | "verification_source_storage_failed" -> Tool_result.Runtime_failure
      | _ -> Tool_result.Workflow_rejection in
    check bool "failure preserves its authority or storage classification" true
      (Tool_result.failure_class result = Some expected_class);
    check string "explicit source failure" code
      Yojson.Safe.Util.(Tool_result.message result |> Yojson.Safe.from_string |> member "code" |> to_string)
  | _ -> fail "source lookup unexpectedly succeeded"
let invalid_input surface name args =
  match call surface name args with
  | Tool_result.Failed _ as result ->
    check bool "invalid descriptor input is a workflow rejection" true
      (Tool_result.failure_class result = Some Tool_result.Workflow_rejection);
    check bool "input rejection explains the error" true
      (String.trim (Tool_result.message result) <> "")
  | _ -> fail "malformed source input unexpectedly succeeded"
let post ~author ~visibility ?origin ?meta_json content =
  match Board_dispatch.create_post ~author ~content ~post_kind:Board.System_post
    ~visibility ~ttl_hours:0 ?origin ?meta_json () with
  | Ok post -> post
  | Error error -> failf "post: %s" (Board_tool.board_error_to_string error)
let post_args (post : Board.post) = `Assoc ["post_id", `String (Board.Post_id.to_string post.id)]
let run_args id = `Assoc ["run_id", `String id]
let metadata = `Assoc
  [ "source_context", `Assoc ["question", `String "compare the designs"; "task", `Null; "goals", `List []]
  ; "panel", `List [ `Assoc ["model", `String "first"; "answer", `String "Keep A"];
                       `Assoc ["model", `String "second"; "answer", `String "B preserves the constraint"] ]
  ; "judge", `Assoc ["status", `String "synthesized"; "decision", `String "Choose A"] ]
let fusion ~author ~visibility ~source ?(content="Original independent advice") run_id =
  post ~author ~visibility ~meta_json:metadata
    ~origin:Board.{turn_ref=Some (Ids.Turn_ref.make ~trace_id:"origin-trace" ~absolute_turn:7);
                  source=Some source; fusion_run_id=Some run_id; fusion_producer=Some author}
    content

module Store = Workspace_verification_store
module Evidence = Verification_collaboration_evidence
let board_ref (post : Board.post) = "board:" ^ Board.Post_id.to_string post.Board.id
let capture config authority references =
  Evidence.capture ~config ~authority ~references |> require "capture submission"
let surfaces config references =
  let task = VAT.create ~config ~producer:"producer"
    ~submitted_evidence:(capture config (Evidence.Task_producer "producer") references)
    |> require "Task snapshot surface" in
  let goal = VAT.create_goal_proof ~config
    ~submitted_evidence:(capture config Evidence.Goal_workspace references)
    |> require "Goal snapshot surface" in
  task, goal
let restored items =
  let bytes = Yojson.Safe.to_string (`List (List.map Store.submitted_evidence_item_to_yojson items)) in
  match Yojson.Safe.from_string bytes with
  | `List rows -> List.map (fun row -> Store.submitted_evidence_item_of_yojson row |> require "persisted item") rows
  | _ -> fail "snapshot array"

let test_submission_freezes_sources () = with_fixture (fun config ->
  let p = post ~author:"producer" ~visibility:Board.Internal "Original objection" in
  let id = Board.Post_id.to_string p.id in
  let comment = Board_dispatch.add_comment ~post_id:id ~author:"peer" ~content:"Original criticism"
    ~ttl_hours:0 () |> require "original comment" in
  let run_id = "immutable-fusion" in
  let f = fusion ~author:"producer" ~visibility:Board.Unlisted ~source:"fusion" run_id in
  let refs = [board_ref p; "fusion:" ^ run_id] in
  let task, goal = surfaces config refs in
  let original = read task "masc_board_post_get" (post_args p) in
  let original_fusion = read task "masc_fusion_status" (run_args run_id) in
  ignore (Board_dispatch.update_post ~post_id:id ~editor:"producer" ~content:"Rewritten claim"
    ~new_author:"peer" () |> require "rewrite and transfer");
  ignore (Board_dispatch.add_comment ~post_id:id ~author:"peer" ~content:"Later friendly comment"
    ~ttl_hours:0 () |> require "later comment");
  ignore (Board_dispatch.update_post ~post_id:(Board.Post_id.to_string f.id) ~editor:"producer"
    ~content:"New advice" ~new_author:"peer" () |> require "transfer Fusion");
  Board_dispatch.delete_post ~post_id:(Board.Post_id.to_string f.id) |> require "remove expiring projection";
  List.iter (fun surface ->
    check bool "post and comments are submission bytes" true
      (read surface "masc_board_post_get" (post_args p) = original);
    check bool "Fusion survives author transfer and projection removal" true
      (read surface "masc_fusion_status" (run_args run_id) = original_fusion)) [task;goal];
  check bool "only original criticism is visible" true
    (Yojson.Safe.Util.member "comments" original = `List [Board.comment_to_yojson comment]);
  let empty = VAT.create_goal_proof ~config ~submitted_evidence:[] |> require "other request" in
  denied empty "masc_board_post_get" (post_args p) "verification_source_access_denied")

let test_capture_failures_and_corruption () = with_fixture (fun config ->
  let p = post ~author:"producer" ~visibility:Board.Direct "@recipient Private original" in
  let require_error label = function Error _ -> () | Ok _ -> fail label in
  Evidence.capture ~config ~authority:Evidence.Goal_workspace ~references:[board_ref p]
    |> require_error "Goal captured private source";
  Evidence.capture ~config ~authority:(Evidence.Task_producer "peer") ~references:[board_ref p]
    |> require_error "other producer captured private source";
  Evidence.capture ~config ~authority:Evidence.Goal_workspace ~references:["fusion:absent"]
    |> require_error "missing source captured";
  let items = capture config (Evidence.Task_producer "producer") [board_ref p] |> restored in
  let item_json = List.hd items |> Store.submitted_evidence_item_to_yojson in
  let operator = `Assoc ["result", `Assoc ["evidence", `Assoc ["access", `String "available"; "items", `List [item_json]]]] in
  (match Tui_decode.decode_verification_evidence operator with
   | Ok (Tui_decode.Evidence_items [Tui_decode.Ev_collaboration _]) -> ()
   | _ -> fail "operator cannot decode submitted collaboration");
  let metadata = List.hd items |> Store.submitted_evidence_item_metadata_to_yojson in
  check bool "metadata does not carry full source body" true
    (Yojson.Safe.Util.member "content" metadata = `Null);
  let task = VAT.create ~config ~producer:"producer" ~submitted_evidence:items |> require "restored surface" in
  ignore (read task "masc_board_post_get" (post_args p));
  let item = List.hd items |> Store.submitted_evidence_item_to_yojson in
  let corrupt = match item with `Assoc fields ->
    `Assoc (("content", `String "{}") :: List.remove_assoc "content" fields) | _ -> fail "item" in
  Store.submitted_evidence_item_of_yojson corrupt |> require_error "changed snapshot digest accepted";
  List.iter (fun input -> invalid_input task "masc_board_post_get" input)
    [`Assoc ["post_id", `String (Board.Post_id.to_string p.id); "comment_limit", `Null];
     `Assoc ["post_id", `String (Board.Post_id.to_string p.id); "comment_offset", `Int (-1)]];
  let Board_dispatch.Jsonl store = Board_dispatch.backend () in
  store.Board.posts_load_result <- Error "unreadable persisted source";
  Evidence.capture ~config ~authority:(Evidence.Task_producer "producer") ~references:[board_ref p]
    |> require_error "corrupt source captured";
  ignore (read task "masc_board_post_get" (post_args p)))

let test_fusion_original_and_separate_decision () = with_fixture (fun config ->
  let id = "opaque-source-id" in
  let p = fusion ~author:"producer" ~visibility:Board.Unlisted ~source:"fusion" id in
  let goal_record, _ = Goal_store.upsert_goal config ~title:"Compare designs" ~metric:"verified designs" ~target_value:"1" () |> require "goal" in
  let work = Task.Goal_assignment.add_task_with_result config ~goal_id:goal_record.id
      ~title:"Make a decision" ~priority:2 ~description:"Compare the evidence" |> require "task" in
  Workspace.claim_task_r config ~agent_name:"producer" ~task_id:work.task_id () |> require "claim" |> ignore;
  let proposal = Fusion_decision.parse (`Assoc ["run_id", `String id; "task_id", `String work.task_id;
    "decision", `String "modified"; "choice", `String "Choose B"; "reason", `String "B preserves measured behavior"]) |> require "proposal" in
  let recorded = Fusion_decision.record ~config ~keeper:"producer"
      ~turn_ref:(Ids.Turn_ref.make ~trace_id:"decision" ~absolute_turn:8) proposal |> require "decision" in
  let task, goal = surfaces config ["fusion:" ^ id] in
  List.iter (fun surface ->
    let wire = read surface "masc_fusion_status" (run_args id) in
    let open Yojson.Safe.Util in
    check bool "full original source metadata" true (wire |> member "post" |> member "meta" = metadata);
    check string "original source ID" (Board.Post_id.to_string p.id)
      (wire |> member "post" |> member "id" |> to_string);
    check string "same evidence hash as decision" (Fusion_decision.evidence_sha256 p)
      (wire |> member "evidence_sha256" |> to_string);
    check bool "actual Keeper choice is separately attributed" true
      (wire |> member "keeper_decisions" = `List [recorded.event]);
    let padded = read surface "masc_fusion_status" (run_args (" " ^ id ^ "\n")) in
    check string "a padded run id reads the run the canonical handler reads" (Board.Post_id.to_string p.id)
      (padded |> member "post" |> member "id" |> to_string);
    check string "the echoed run id is the exact one" id (padded |> member "run_id" |> to_string)) [task; goal];
  check int "reads do not adopt or duplicate choices" 1
    (List.length (Fusion_decision.read ~config ~run_id:id |> require "read decisions")))

let test_original_fusion_producer_before_submit () = with_fixture (fun config ->
  let run_id = "transferred-before-submit" in
  let post = fusion ~author:"producer" ~visibility:Board.Unlisted ~source:"fusion" run_id in
  let moved = Board_dispatch.update_post ~post_id:(Board.Post_id.to_string post.id)
    ~editor:"producer" ~content:post.body ~new_author:"peer" () |> require "transfer" in
  let durable = Board.post_to_yojson moved in
  let restored_post = Board.post_of_yojson durable |> Option.get in
  check bool "original producer persists independently from mutable author" true
    (Option.bind restored_post.origin (fun origin -> origin.Board.fusion_producer) = Some "producer");
  let items = capture config (Evidence.Task_producer "producer") ["fusion:" ^ run_id] in
  let task = VAT.create ~config ~producer:"producer" ~submitted_evidence:items |> require "original producer surface" in
  ignore (read task "masc_fusion_status" (run_args run_id));
  (match Evidence.capture ~config ~authority:(Evidence.Task_producer "peer") ~references:["fusion:" ^ run_id] with
   | Error (Evidence.Access_denied _) -> () | _ -> fail "new Board author became Fusion producer");
  let missing_identity = match durable with
    | `Assoc fields -> (match List.assoc "origin" fields with
      | `Assoc origin -> `Assoc (("origin", `Assoc (List.remove_assoc "fusion_producer" origin)) :: List.remove_assoc "origin" fields)
      | _ -> fail "origin")
    | _ -> fail "post" in
  check bool "old Fusion origin never guesses producer from current author" true
    (Board.post_of_yojson missing_identity = None))

let test_goal_request_freezes_sources () = with_fixture (fun config ->
  let post = post ~author:"peer" ~visibility:Board.Internal "Goal proof source" in
  let goal, _ = Goal_store.upsert_goal config ~title:"Frozen Goal proof" ~metric:"proof" ~target_value:"1" () |> require "Goal" in
  let ctx : Tool_workspace.context = {config; agent_name="producer"} in
  let result = Tool_workspace.dispatch ctx ~name:"masc_goal_transition"
    ~args:(`Assoc ["goal_id", `String goal.id; "action", `String "request_complete";
      "evidence_refs", `List [`String (board_ref post)]]) |> Option.get in
  (match result with Tool_result.Completed _ -> () | _ -> fail (Tool_result.message result));
  let record = Goal_verification.get_record_authoritative config ~goal_id:goal.id |> require "Goal request" |> Option.get in
  let items = match record.completion with
    | Goal_verification.Proof_pending _ -> restored record.submitted_evidence
    | _ -> fail "Goal proof request not pending" in
  Board_dispatch.delete_post ~post_id:(Board.Post_id.to_string post.id) |> require "remove live Goal source";
  let surface = VAT.create_goal_proof ~config ~submitted_evidence:items |> require "Goal snapshot surface" in
  let result = read surface "masc_board_post_get" (post_args post) in
  check string "Goal reads original body after deletion" post.body
    Yojson.Safe.Util.(result |> member "post" |> member "body" |> to_string))

let test_task_request_persists_snapshot () = with_fixture (fun config ->
  let p = post ~author:"producer" ~visibility:Board.Internal "Submitted body" in
  ignore (Workspace.add_task config ~title:"Submission source" ~priority:1 ~description:"");
  let task = List.hd (Workspace.read_backlog config).tasks in
  Verification_protocol.create_submit_request ~config ~task ~assignee:"producer"
    ~verification_id:"snapshot-request" ~claim:(Masc_domain.Completion_evidence {evidence_refs=[board_ref p]})
    |> require "submit request";
  let request = Verification.load_request config.base_path "snapshot-request" |> require "load request" in
  let items = match Yojson.Safe.Util.member "submitted_evidence" request.output with
    | `List rows -> List.map (fun row -> Store.submitted_evidence_item_of_yojson row |> require "decode request item") rows
    | _ -> fail "missing submission snapshot" in
  let surface = VAT.create ~config ~producer:"producer" ~submitted_evidence:items |> require "request-bound surface" in
  Board_dispatch.delete_post ~post_id:(Board.Post_id.to_string p.id) |> require "remove source";
  ignore (read surface "masc_board_post_get" (post_args p));
  (match Verification_protocol.create_submit_request ~config ~task ~assignee:"producer"
    ~verification_id:"missing-request" ~claim:(Masc_domain.Completion_evidence {evidence_refs=[board_ref p]}) with
   | Error _ -> () | Ok _ -> fail "submission with missing source committed");
  check bool "failed capture writes no verification request" true
    (Result.is_error (Verification.load_request config.base_path "missing-request")))

let test_large_sources_survive_actual_bridge () = with_fixture (fun config ->
  let open Yojson.Safe.Util in
  let payload = String.concat "" (List.init 5000 (fun _ -> "한글\"\\\n")) in
  let metadata = `Assoc ["panel", `String payload] in
  let board = post ~author:"producer" ~visibility:Board.Internal ~meta_json:metadata "Large Board source" in
  let run_id = "large-fusion-source" in
  let fusion_post = post ~author:"producer" ~visibility:Board.Unlisted ~meta_json:metadata
    ~origin:Board.{turn_ref=None; source=Some "fusion"; fusion_run_id=Some run_id; fusion_producer=Some "producer"}
    "Large Fusion source" in
  let task, goal = surfaces config [board_ref board; "fusion:" ^ run_id] in
  let cursor_args args cursor = match args with
    | `Assoc fields -> `Assoc (("cursor", cursor) :: fields) | _ -> assert false in
  let bridge surface name args =
    let result = call surface name args in
    let content = match Tool_bridge.to_agent_core_typed_result ~base_path:config.Workspace.base_path result with
      | Ok result -> result.Agent_core.Types.content
      | Error error -> failf "bridge refused source page: %s" error.Agent_core.Types.message in
    check bool "actual model content stays within bridge budget" true
      (String.length content <= Tool_bridge.default_externalize_threshold_bytes);
    (* A spilled blob marker cannot parse as the source-page JSON contract. *)
    Yojson.Safe.from_string content in
  let reconstruct surface name args =
    let first = bridge surface name args in
    check string "large source advertises lossless continuation" "source_json_page"
      (first |> member "representation" |> to_string);
    let expected_digest = first |> member "source_sha256" |> to_string in
    let rec collect offset page parts =
      check int "pages are contiguous bytes" offset (page |> member "byte_offset" |> to_int);
      check string "all pages bind one source observation" expected_digest
        (page |> member "source_sha256" |> to_string);
      let content = page |> member "content" |> to_string in
      check bool "every page makes progress" true (String.length content > 0);
      let offset = offset + String.length content in
      match member "next_cursor" page with
      | `Null ->
        check int "complete byte count" offset (page |> member "total_bytes" |> to_int);
        let bytes = String.concat "" (List.rev (content :: parts)) in
        check string "reconstructed digest matches exact original" expected_digest
          Digestif.SHA256.(digest_string bytes |> to_hex);
        Yojson.Safe.from_string bytes, member "next_cursor" first
      | cursor -> collect offset (bridge surface name (cursor_args args cursor)) (content :: parts) in
    collect 0 first [] in
  List.iter (fun surface ->
    List.iter (fun (name, args, original) ->
      let reconstructed, cursor = reconstruct surface name args in
      let expected = if String.equal name "masc_board_post_get" then
        `Assoc ["source", `String "board"; "post", Board.post_to_yojson original;
          "comments", `List []; "pagination", `Assoc ["offset", `Int 0; "returned", `Int 0;
            "total", `Int 0; "has_more", `Bool false; "next_offset", `Null]]
      else `Assoc ["source", `String "fusion"; "run_id", `String run_id;
        "evidence_sha256", `String (Fusion_decision.evidence_sha256 original);
        "post", Board.post_to_yojson original; "keeper_decisions", `List []] in
      check bool "entire original source including escapes and Unicode survives" true
        (reconstructed = expected);
      let invalid_hash = match cursor with `Assoc fields ->
        `Assoc (("source_sha256", `String (String.make 64 '0')) :: List.remove_assoc "source_sha256" fields)
        | _ -> fail "large source lacks continuation" in
      denied surface name (cursor_args args invalid_hash) "verification_source_unavailable";
      invalid_input surface name (cursor_args args (`Assoc ["source_sha256", `String "bad"; "byte_offset", `Int 0])))
      ["masc_board_post_get", post_args board, board; "masc_fusion_status", run_args run_id, fusion_post])
    [task; goal];
  let private_post = post ~author:"producer" ~visibility:Board.Direct ~meta_json:metadata "@peer Private source" in
  let task_private = VAT.create ~config ~producer:"producer"
    ~submitted_evidence:(capture config (Evidence.Task_producer "producer") [board_ref private_post])
    |> require "private snapshot" in
  let private_page = bridge task_private "masc_board_post_get" (post_args private_post) in
  denied goal "masc_board_post_get"
    (cursor_args (post_args private_post) (member "next_cursor" private_page))
    "verification_source_access_denied";
  let first = bridge task "masc_board_post_get" (post_args board) in
  let cursor = member "next_cursor" first in
  ignore (Board_dispatch.add_comment ~post_id:(Board.Post_id.to_string board.id)
    ~author:"producer" ~content:"New source revision" ~ttl_hours:0 () |> require "changed source");
  let continued = bridge task "masc_board_post_get" (cursor_args (post_args board) cursor) in
  check string "live edits cannot invalidate submission paging" "source_json_page"
    (continued |> member "representation" |> to_string))

let () = run "Verifier submitted collaboration sources" ["submission", [
  test_case "submission freezes author, comments and expiring Fusion source" `Quick test_submission_freezes_sources;
  test_case "capture authority, corruption and persistence roundtrip" `Quick test_capture_failures_and_corruption;
  test_case "original Fusion advice and separately attributed decisions" `Quick test_fusion_original_and_separate_decision;
  test_case "original Fusion producer survives pre-submission author transfer" `Quick test_original_fusion_producer_before_submit;
  test_case "Goal request owns source before completion proof" `Quick test_goal_request_freezes_sources;
  test_case "Task request owns snapshot before commit" `Quick test_task_request_persists_snapshot;
  test_case "full Board and Fusion bytes survive actual bridge paging" `Quick test_large_sources_survive_actual_bridge]]
