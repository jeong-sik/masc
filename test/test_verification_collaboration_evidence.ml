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
      let task = VAT.create ~config ~producer:"producer" |> require "Task surface" in
      let goal = VAT.create_goal_proof ~config |> require "Goal surface" in
      f config task goal)
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
                  source=Some source; fusion_run_id=Some run_id}
    content

let test_shared_thread_and_pagination () = with_fixture (fun _config task goal ->
  let p = post ~author:"peer" ~visibility:Board.Internal "Exact peer objection" in
  let c1 = Board_dispatch.add_comment ~post_id:(Board.Post_id.to_string p.id)
      ~author:"producer" ~content:"Reply with measured rationale" ~ttl_hours:0 () |> require "comment" in
  let c2 = Board_dispatch.add_comment ~post_id:(Board.Post_id.to_string p.id)
      ~author:"peer" ~content:"Final clarification" ~ttl_hours:0 () |> require "comment2" in
  let args = `Assoc ["post_id", `String (Board.Post_id.to_string p.id); "comment_limit", `Int 1] in
  let one = read task "masc_board_post_get" args in
  let open Yojson.Safe.Util in
  let current = Board_dispatch.get_post ~post_id:(Board.Post_id.to_string p.id) |> require "current post" in
  check bool "original post identity, author, body and metadata" true
    (member "post" one = Board.post_to_yojson current);
  check bool "actual comment ID and content" true
    (member "comments" one = `List [Board.comment_to_yojson c1]);
  check bool "pagination states omitted comments" true
    (one |> member "pagination" |> member "has_more" |> to_bool);
  let two = read goal "masc_board_post_get"
    (`Assoc ["post_id", `String (Board.Post_id.to_string p.id); "comment_offset", `Int 1; "comment_limit", `Int 1]) in
  check bool "Goal reads the next actual peer comment" true
    (member "comments" two = `List [Board.comment_to_yojson c2]);
  check bool "complete page is explicit" false
    (two |> member "pagination" |> member "has_more" |> to_bool))

let test_direct_authority_and_unknown () = with_fixture (fun _config task goal ->
  let own = post ~author:"producer" ~visibility:Board.Direct "@peer private author-owned evidence" in
  let other = post ~author:"peer" ~visibility:Board.Direct "@producer mutable address is not a stored readership grant" in
  ignore (read task "masc_board_post_get" (post_args own));
  check string "a padded post id reads the post the canonical handler reads" (Board.Post_id.to_string own.id)
    Yojson.Safe.Util.(read task "masc_board_post_get"
      (`Assoc ["post_id", `String (" " ^ Board.Post_id.to_string own.id ^ "\n")])
      |> member "post" |> member "id" |> to_string);
  denied task "masc_board_post_get" (post_args other) "verification_source_access_denied";
  denied goal "masc_board_post_get" (post_args own) "verification_source_access_denied";
  denied goal "masc_board_post_get" (post_args other) "verification_source_access_denied";
  denied task "masc_board_post_get" (`Assoc ["post_id", `String "p-00000000000000000000000000000000"]) "verification_source_unavailable";
  List.iter (fun visibility ->
    let shared = post ~author:"peer" ~visibility "Shared evidence" in
    ignore (read task "masc_board_post_get" (post_args shared));
    ignore (read goal "masc_board_post_get" (post_args shared))) [Board.Public; Board.Unlisted; Board.Internal])

let test_pagination_input_contract () = with_fixture (fun config task goal ->
  let p = post ~author:"peer" ~visibility:Board.Internal "Paginated review evidence" in
  let id = Board.Post_id.to_string p.id in
  let comments = List.init (Board.Limits.default_comment_page_limit + 1) (fun i ->
    Board_dispatch.add_comment ~post_id:id ~author:"peer"
      ~content:(Printf.sprintf "Evidence entry %d" i) ~ttl_hours:0 () |> require "comment") in
  let args fields = `Assoc (("post_id", `String id) :: fields) in
  let open Yojson.Safe.Util in
  List.iter (fun (surface, authority) ->
    let reject_pagination fields =
      let input = args fields in
      invalid_input surface "masc_board_post_get" input;
      (* Descriptor validation can reject before the reader runs. Check its
         independent parser too so a malformed optional field cannot default. *)
      match Verification_collaboration_evidence.read_board ~config ~authority ~args:input with
      | Error (Verification_collaboration_evidence.Invalid_request _) -> ()
      | Error _ -> fail "malformed pagination returned the wrong source error"
      | Ok _ -> fail "reader silently defaulted malformed pagination" in
    let first = read surface "masc_board_post_get" (args []) in
    check int "omitted offset starts at zero" 0
      (first |> member "pagination" |> member "offset" |> to_int);
    check int "omitted limit uses the descriptor default" Board.Limits.default_comment_page_limit
      (first |> member "comments" |> to_list |> List.length);
    let next = first |> member "pagination" |> member "next_offset" |> to_int in
    let rest = read surface "masc_board_post_get" (args ["comment_offset", `Int next]) in
    check bool "default pages preserve every original comment in order" true
      (to_list (member "comments" first) @ to_list (member "comments" rest)
       = List.map Board.comment_to_yojson comments);
    let all = read surface "masc_board_post_get"
      (args ["comment_limit", `Int Board.Limits.max_comment_page_limit]) in
    check bool "maximum descriptor limit is accepted" true
      (member "comments" all = `List (List.map Board.comment_to_yojson comments));
    let past_end = read surface "masc_board_post_get" (args ["comment_offset", `Int max_int]) in
    check bool "valid offset beyond the thread produces an empty final page" true
      (member "comments" past_end = `List [] &&
       member "next_offset" (member "pagination" past_end) = `Null);
    List.iter (fun field ->
      List.iter (fun value ->
        reject_pagination [field, value])
        [`Null; `String "1"; `Float 1.; `Bool true; `List []; `Assoc [];
         `Intlit "999999999999999999999999999999"])
      ["comment_offset"; "comment_limit"];
    List.iter (fun (field, value) ->
      reject_pagination [field, `Int value])
      ["comment_offset", -1; "comment_limit", 0;
       "comment_limit", Board.Limits.max_comment_page_limit + 1])
    [task, Verification_collaboration_evidence.Task_producer "producer";
     goal, Verification_collaboration_evidence.Goal_workspace])

let test_fusion_original_and_separate_decision () = with_fixture (fun config task goal ->
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

let test_fusion_foreign_wrong_origin_and_no_write () = with_fixture (fun config task goal ->
  let id = "foreign-opaque-source" in
  let source = fusion ~author:"peer" ~visibility:Board.Internal ~source:"fusion" id in
  let source_comment = Board_dispatch.add_comment ~post_id:(Board.Post_id.to_string source.id)
      ~author:"producer" ~content:"Original workspace comment" ~ttl_hours:0 () |> require "source comment" in
  denied task "masc_fusion_status" (run_args id) "verification_source_access_denied";
  ignore (read goal "masc_fusion_status" (run_args id));
  ignore (fusion ~author:"peer" ~visibility:Board.Direct ~source:"fusion"
    ~content:"@producer Original private independent advice" "private-source");
  denied task "masc_fusion_status" (run_args "private-source") "verification_source_access_denied";
  denied goal "masc_fusion_status" (run_args "private-source") "verification_source_access_denied";
  ignore (fusion ~author:"producer" ~visibility:Board.Unlisted ~source:"not-fusion" "wrong-origin");
  denied task "masc_fusion_status" (run_args "wrong-origin") "verification_source_unavailable";
  denied goal "masc_fusion_status" (run_args "absent") "verification_source_unavailable";
  (* The verifier schema requires run_id, so {} is refused at the advertised
     boundary; the reader's own parser refuses it and a blank id as well. *)
  invalid_input goal "masc_fusion_status" (`Assoc []);
  (match Verification_collaboration_evidence.read_fusion ~config
     ~authority:Verification_collaboration_evidence.Goal_workspace ~args:(`Assoc []) with
   | Error (Verification_collaboration_evidence.Invalid_request _) -> ()
   | Error _ | Ok _ -> fail "reader accepted a Fusion lookup without run_id");
  denied goal "masc_fusion_status" (run_args "  ") "verification_source_invalid_request";
  List.iter (fun name -> match call task name (`Assoc []) with
    | Tool_result.Failed _ -> () | _ -> fail "verifier gained a write or execution tool")
    ["Execute"; "Write"; "masc_board_post"; "masc_fusion"; "masc_fusion_decision"];
  check int "lookup did not record a decision" 0
    (List.length (Fusion_decision.read ~config ~run_id:id |> require "read decisions"));
  let different = Workspace.default_config (Filename.concat config.base_path "different-workspace") in
  check bool "fixture selects a genuinely different workspace" false
    (String.equal (Fs_compat.realpath_lenient (Workspace.masc_dir config))
       (Fs_compat.realpath_lenient (Workspace.masc_dir different)));
  let Board_dispatch.Jsonl active_store = Board_dispatch.backend () in
  check (option string) "active store retains its original workspace after config resolution"
    (Some (Fs_compat.realpath_lenient (Workspace.masc_dir config))) active_store.Board.workspace_masc_dir;
  let reloaded = { (Board.create_store ()) with workspace_masc_dir = active_store.workspace_masc_dir } in
  ignore (Masc_board_handlers.Board_votes_json.load_persisted_posts reloaded |> require "bound post reload");
  ignore (Masc_board_handlers.Board_votes_json.load_persisted_comments reloaded |> require "bound comment reload");
  let loaded_source = Board.get_post reloaded ~post_id:(Board.Post_id.to_string source.id) |> require "bound original post" in
  check string "store loads the original workspace source despite changed environment"
    (Board.Post_id.to_string source.id) (Board.Post_id.to_string loaded_source.id);
  check bool "store loads the original workspace comment despite changed environment" true
    (Hashtbl.mem reloaded.comments (Board.Comment_id.to_string source_comment.id));
  let other_task = VAT.create ~config:different ~producer:"peer" |> require "other Task" in
  let other_goal = VAT.create_goal_proof ~config:different |> require "other Goal" in
  List.iter (fun surface ->
    denied surface "masc_board_post_get" (post_args source) "verification_source_access_denied";
    denied surface "masc_fusion_status" (run_args id) "verification_source_access_denied")
    [other_task; other_goal];
  ignore (read task "masc_board_post_get" (post_args source));
  ignore (read goal "masc_board_post_get" (post_args source));
  ignore (read goal "masc_fusion_status" (run_args id)))

let test_corrupt_decision_storage () = with_fixture (fun config task _goal ->
  ignore (fusion ~author:"producer" ~visibility:Board.Unlisted ~source:"fusion" "corrupt-events");
  let directory = Filename.concat (Workspace.masc_dir config) "events/2026-09" in
  Fs_compat.mkdir_p directory;
  Out_channel.with_open_bin (Filename.concat directory "corrupt.jsonl")
    (fun out -> output_string out "{invalid json\n");
  denied task "masc_fusion_status" (run_args "corrupt-events") "verification_source_storage_failed")

let test_large_sources_survive_actual_bridge () = with_fixture (fun config task goal ->
  let open Yojson.Safe.Util in
  let payload = String.concat "" (List.init 5000 (fun _ -> "한글\"\\\n")) in
  let metadata = `Assoc ["panel", `String payload] in
  let board = post ~author:"producer" ~visibility:Board.Internal ~meta_json:metadata "Large Board source" in
  let run_id = "large-fusion-source" in
  let fusion_post = post ~author:"producer" ~visibility:Board.Unlisted ~meta_json:metadata
    ~origin:Board.{turn_ref=None; source=Some "fusion"; fusion_run_id=Some run_id}
    "Large Fusion source" in
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
  let private_page = bridge task "masc_board_post_get" (post_args private_post) in
  denied goal "masc_board_post_get"
    (cursor_args (post_args private_post) (member "next_cursor" private_page))
    "verification_source_access_denied";
  let first = bridge task "masc_board_post_get" (post_args board) in
  let cursor = member "next_cursor" first in
  ignore (Board_dispatch.add_comment ~post_id:(Board.Post_id.to_string board.id)
    ~author:"producer" ~content:"New source revision" ~ttl_hours:0 () |> require "changed source");
  denied task "masc_board_post_get" (cursor_args (post_args board) cursor) "verification_source_unavailable")

let test_corrupt_board_store_remains_storage_failure () =
  List.iter (fun comments -> with_fixture (fun _config task goal ->
    let source = fusion ~author:"producer" ~visibility:Board.Unlisted ~source:"fusion" "storage-health" in
    let Board_dispatch.Jsonl store = Board_dispatch.backend () in
    let path = if comments then Board.comments_path () else Board.persist_path () in
    Out_channel.with_open_bin path (fun channel ->
      output_string channel (if comments then "{}\n" else "{bad-json\n"));
    let loaded = if comments then Masc_board_handlers.Board_votes_json.load_persisted_comments store
      else Masc_board_handlers.Board_votes_json.load_persisted_posts store in
    (match loaded with Error _ -> () | Ok _ -> fail "corrupt fixture unexpectedly loaded");
    List.iter (fun surface ->
      denied surface "masc_board_post_get" (post_args source) "verification_source_storage_failed";
      denied surface "masc_fusion_status" (run_args "storage-health") "verification_source_storage_failed")
      [task; goal])) [false; true]

let () = run "Verifier collaboration sources" ["dispatch", [
  test_case "corrupt Board storage is never absent evidence" `Quick test_corrupt_board_store_remains_storage_failure;
  test_case "large Board and Fusion sources remain fully readable through bridge" `Quick test_large_sources_survive_actual_bridge;
  test_case "unreadable decision journal remains a storage failure" `Quick test_corrupt_decision_storage;
  test_case "shared peer post and exact paginated comments" `Quick test_shared_thread_and_pagination;
  test_case "pagination defaults apply only to omitted fields" `Quick test_pagination_input_contract;
  test_case "Direct authority and missing source remain explicit" `Quick test_direct_authority_and_unknown;
  test_case "original Fusion source and separate recorded decision" `Quick test_fusion_original_and_separate_decision;
  test_case "foreign source, wrong origin and no write authority" `Quick test_fusion_foreign_wrong_origin_and_no_write]]
