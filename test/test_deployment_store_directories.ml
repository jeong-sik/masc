open Alcotest
open Masc

let read path = In_channel.with_open_bin path In_channel.input_all
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)

(* Cmdliner may wrap between any diagnostic words, including the cause. *)
let diagnostic_words text =
  String.map (function '\r' | '\n' | '\t' -> ' ' | c -> c) text
  |> String.split_on_char ' '
  |> List.filter (fun word -> not (String.equal word ""))
  |> String.concat " "

let invoke_with_args exe root arguments =
  let stdout_path = Filename.concat root "stdout" in
  let stderr_path = Filename.concat root "stderr" in
  let output = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let errors = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let status = Fun.protect ~finally:(fun () -> Unix.close output; Unix.close errors) (fun () ->
    let pid = Unix.create_process exe
      (Array.of_list (exe :: arguments)) Unix.stdin output errors in
    snd (Unix.waitpid [] pid)) in
  status, read stdout_path ^ read stderr_path

let invoke exe root = invoke_with_args exe root ["validate-stores"; "--base-path"; root]

let with_workspace f =
  let root = Filename.temp_dir "preflight-directories-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let keepers = Filename.concat root ".masc/keepers" in
    let traces = Filename.concat root ".masc/traces" in
    Fs_compat.mkdir_p (Filename.concat keepers "keeper");
    Fs_compat.mkdir_p (Filename.concat traces "trace");
    write (Filename.concat keepers "keeper.decisions.jsonl") "not a directory\n";
    write (Filename.concat traces "trace.checkpoint.lock") "lock metadata\n";
    f root keepers traces)

let test_regular_siblings exe () = with_workspace (fun root keepers traces ->
  let status, output = invoke exe root in
  check bool ("regular siblings must not become stores: " ^ output) true (status = Unix.WEXITED 0);
  check string "journal unchanged" "not a directory\n"
    (read (Filename.concat keepers "keeper.decisions.jsonl"));
  check string "lock unchanged" "lock metadata\n"
    (read (Filename.concat traces "trace.checkpoint.lock")))

let test_real_store_refusals exe () = with_workspace (fun root keepers traces ->
  let boundary = Filename.concat keepers "keeper/turn-boundaries.jsonl" in
  let fragment = Filename.concat traces "trace/history.jsonl" in
  write boundary "{invalid boundary}\n";
  write fragment "{invalid fragment}\n";
  let status, output = invoke exe root in
  check bool "malformed real stores still refuse deployment" true (status <> Unix.WEXITED 0);
  List.iter (fun expected ->
    check bool ("reports " ^ expected) true (String_util.contains_substring output expected))
    ["keeper turn boundaries rows=1 refused=1";
     "keeper official-client turn fragments rows=1 refused=1"];
  check string "refused boundary preserved" "{invalid boundary}\n" (read boundary);
  check string "refused fragment preserved" "{invalid fragment}\n" (read fragment))

let test_transcript_inventory_failure_stops_preflight exe () =
  with_workspace (fun root _keepers _traces ->
    let dir = Keeper_chat_store.chat_dir root in
    write dir "not a directory";
    let status, output = invoke exe root in
    check bool ("a file cannot pass as an empty transcript store: " ^ output) true
      (status <> Unix.WEXITED 0);
    check bool ("the scan failure names the store: " ^ output) true
      (String_util.contains_substring output "keeper chat transcripts scan_failed=");
    check bool ("the scan failure names the path and reason: " ^ output) true
      (String_util.contains_substring (diagnostic_words output)
         (diagnostic_words (dir ^ ": not a directory")));
    check string "failed inventory is untouched" "not a directory" (read dir);
    Unix.unlink dir;
    Unix.mkdir dir 0o700;
    Fun.protect ~finally:(fun () -> Unix.chmod dir 0o700) (fun () ->
      Unix.chmod dir 0o000;
      if Unix.geteuid () <> 0 then (
        let status, output = invoke exe root in
        check bool ("unreadable transcript inventory must stop deployment: " ^ output)
          true (status <> Unix.WEXITED 0);
        check bool ("unreadable directory is named: " ^ output) true
          (String_util.contains_substring output (dir ^ ":")))))

(* Every Memory write for a keeper reconciles its range receipt ledger before
   it builds, so a ledger this build cannot decode must stop the rollout here,
   not every Memory write after it. *)
let test_range_receipt_ledger exe () = with_workspace (fun root _keepers _traces ->
  let config_keepers = Filename.concat root ".masc/config/keepers" in
  Fs_compat.mkdir_p config_keepers;
  let ledger = Filename.concat config_keepers "keeper.librarian-range-commit.json" in
  write ledger {|{"receipts":[]}|};
  let status, output = invoke exe root in
  check bool ("a readable ledger passes: " ^ output) true (status = Unix.WEXITED 0);
  check bool ("the readable ledger is read: " ^ output) true
    (String_util.contains_substring output "Librarian range receipt ledger rows=1 refused=0");
  write ledger {|{"receipts":{}}|};
  let status, output = invoke exe root in
  check bool "an undecodable ledger refuses deployment" true (status <> Unix.WEXITED 0);
  check bool ("reports the ledger: " ^ output) true
    (String_util.contains_substring output "Librarian range receipt ledger rows=1 refused=1");
  check string "refused ledger preserved" {|{"receipts":{}}|} (read ledger))

let test_symlink_refusal exe () = with_workspace (fun root keepers _traces ->
  Unix.symlink (Filename.concat keepers "keeper") (Filename.concat keepers "linked");
  let status, output = invoke exe root in
  check bool "links are not silently skipped or followed" true (status <> Unix.WEXITED 0);
  check bool "uninspectable store is explicit" true
    (String_util.contains_substring output "store entry cannot be inspected safely"))

let assert_transcript_scan_failed dir (status, output) =
  check bool ("transcript inventory failure refuses deployment: " ^ output) true
    (status <> Unix.WEXITED 0);
  List.iter (fun expected ->
    check bool ("reports " ^ expected ^ ": " ^ output) true
      (String_util.contains_substring output expected))
    ["keeper chat transcripts scan_failed="; dir];
  check bool "unread inventory is not reported as an empty success" false
    (String_util.contains_substring output "keeper chat transcripts rows=0 refused=0")

let test_transcript_directory_kind exe () = with_workspace (fun root _keepers _traces ->
  let dir = Keeper_chat_store.chat_dir root in
  let status, output = invoke exe root in
  check bool ("an absent transcript directory is valid: " ^ output) true
    (status = Unix.WEXITED 0);
  check bool "the absent inventory is reported" true
    (String_util.contains_substring output "keeper chat transcripts rows=0 refused=0");
  write dir "not a transcript directory\n";
  assert_transcript_scan_failed dir (invoke exe root);
  check string "invalid inventory is not rewritten" "not a transcript directory\n" (read dir))

let test_unreadable_transcript_directory exe () = with_workspace (fun root _keepers _traces ->
  let dir = Keeper_chat_store.chat_dir root in
  Fs_compat.mkdir_p dir;
  let transcript = Filename.concat dir "keeper.jsonl" in
  let contents = {|{"id":"row","role":"user","content":"hello","ts":1.0}|} ^ "\n" in
  write transcript contents;
  Unix.chmod dir 0o000;
  Fun.protect ~finally:(fun () -> Unix.chmod dir 0o700) (fun () ->
    (* Ensure this process actually cannot list the fixture; a privileged
       runner must not silently turn this into an empty-store test. *)
    (match Sys.readdir dir with
     | _ -> fail "permission fixture unexpectedly readable"
     | exception Sys_error _ -> ());
    assert_transcript_scan_failed dir (invoke exe root));
  check string "unread transcript remains intact" contents (read transcript))

let test_task_backlog_original_bytes exe () = with_workspace (fun root _keepers _traces ->
  let tasks = Filename.concat root ".masc/tasks" in
  Fs_compat.mkdir_p tasks;
  let document intent = Printf.sprintf
    {|{"tasks":[{"id":"task-legacy","title":"fixture","description":"","priority":1,"files":[],"created_at":"2026-07-12T23:59:00Z","status":"awaiting_verification","assignee":"producer","started_at":"2026-07-12T23:59:00Z","submitted_at":"2026-07-13T00:00:00Z","verification_id":"fixture"%s}],"last_updated":"2026-07-13T00:00:00Z","version":1}|}
    intent in
  List.iter (fun filename ->
    let path = Filename.concat tasks filename in
    List.iter (fun (intent, accepted, message) ->
      let raw = document intent in
      write path raw;
      let status, output = invoke_with_args exe root ["validate-task-backlog"; path] in
      check bool (filename ^ ": " ^ output) accepted (status = Unix.WEXITED 0);
      check bool ("diagnostic names the cause: " ^ output) true
        (String_util.contains_substring (diagnostic_words output) message);
      check bool ("diagnostic names the file: " ^ output) true
        (String_util.contains_substring (diagnostic_words output) (diagnostic_words path));
      check string "preflight does not rewrite task state" raw (read path))
      [ {|,"intent":"complete"|}, false, "does not accept intent"
      ; {|,"intent":"cancel"|}, false, "does not accept intent"
      ; {|,"intent":"cancel","intent":"complete"|}, false, "does not accept intent"
      ; {|,"intent":"unknown","intent":"complete"|}, false, "does not accept intent"
      ; {|,"intent":"unknown"|}, false, "does not accept intent"
      ]) ["backlog.json"; "backlog.json.last-good"])

(* Lane Add-on records (#45106): for each kind, a record this build writes is
   read and the shape a live workspace still held on 2026-10-22 is refused,
   named by its file and the runtime decoder that refused it. *)
module P = Lane_addon_store_preflight

let with_lane_store f =
  let base = Filename.temp_dir "preflight-lane-addons-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let root = Filename.concat base ".masc/lane-addons" in
    Fs_compat.mkdir_p root;
    f base root)

let put path json =
  Fs_compat.mkdir_p (Filename.dirname path);
  write path (Yojson.Safe.to_string json)

let scan store ~base_path =
  match P.scan store ~base_path with
  | Ok report -> report
  | Error detail -> failf "%s scan failed: %s" (P.name store) detail

let expect_refusals store ~base_path ~rows expected =
  let report = scan store ~base_path in
  let by_path = List.sort (fun (a, _) (b, _) -> String.compare a b) in
  let actual = by_path (List.map (fun (r : P.refusal) -> r.path, r.decoder) report.P.refusals) in
  check int (P.name store ^ " records read") rows report.P.rows;
  check (list string) (P.name store ^ " refused files") (List.map fst (by_path expected))
    (List.map fst actual);
  check bool (P.name store ^ " refusing decoders") true
    (List.map snd (by_path expected) = List.map snd actual);
  report.P.refusals

let unchanged path f =
  let before = read path in
  let result = f () in
  check string ("the check leaves " ^ path ^ " as it was") before (read path);
  result

let binding ~id ~current =
  let common =
    [ "instance_id", `String id; "incarnation", `String id; "run_id", `String "dos-counter"
    ; "addon_id", `String "dos-world"; "title", `String "DOS"; "revision", `String "1"
    ; "observation_seq", `Int 0; "configuration", `Null ] in
  `Assoc
    (if current
     then
       common
       @ [ "lifecycle",
           Lane_addon_lifecycle.state_to_json
             (Lane_addon_lifecycle.Failed
                (Lane_addon_lifecycle.failed Lane_addon_lifecycle.Previous_process))
         ; "execution_authority", `Null; "resource", `Null
         ; "visibility", `Assoc ["kind", `String "shared"]
         ; "source_access", Lane_addon_sources.access_to_json Lane_addon_sources.Unauthenticated ]
     (* The September shape of #44651: no lifecycle and no read authority. *)
     else common @ ["phase", `String "failed"; "container_id", `Null])

let test_lane_addon_bindings () = with_lane_store (fun base root ->
  let path id = Filename.concat root (Lane_addon_store.binding_path id) in
  put (path "current") (binding ~id:"current" ~current:true);
  put (path "september") (binding ~id:"september" ~current:false);
  let refusals = unchanged (path "september") (fun () ->
    expect_refusals P.Store.Bindings ~base_path:base ~rows:2
      [path "september", P.Retained_binding]) in
  check (list (list string)) "the binding alone goes aside" [[path "september"]]
    (List.map (fun (r : P.refusal) -> r.aside) refusals))

let test_lane_addon_native_claims () = with_lane_store (fun base root ->
  let slot name = Filename.concat (Filename.concat root Lane_addon_runtime.native_claims_directory) name in
  let reserve directory ~instance ~context ~version =
    put (Filename.concat directory "intent.json")
      (`Assoc ["instance_id", `String instance; "state", `String "admitted"]);
    let history = Filename.concat directory ("instance-" ^ Lane_addon_store.digest instance ^ ".json") in
    put history
      (`Assoc (["instance_id", `String instance; "state", `String "reserved"; "cleanup_context", context]
               @ match version with Some v -> ["version", `Int v] | None -> []));
    history in
  let descriptor instance_id =
    match Browser_addon_socket.context ~instance_id ~automation:None ~stagehand:None
            ~live_bidi:None ~models:None with
    | Ok json -> json
    | Error detail -> fail detail in
  let current = "01a162a0-f0f5-7000-a6c5-012f6785ec2f" in
  let old = "01a162a0-f0f5-7000-a6c5-012f6785ec30" in
  ignore (reserve (slot (Lane_addon_store.digest "browser-work")) ~instance:current
            ~context:(descriptor current) ~version:(Some 2));
  (* A child slot holds the descriptor its parent compares; the host never
     reads it as a socket descriptor. *)
  ignore (reserve (slot ("browser-" ^ Lane_addon_store.digest current)) ~instance:current
            ~context:(`Assoc ["kind", `String "browser_addon_chrome"]) ~version:(Some 2));
  (* The #45106 record: written before #44364 with only kind and directory. *)
  let old_slot = slot (Lane_addon_store.digest "browser-old") in
  let old_directory = match descriptor old with
    | `Assoc fields -> List.assoc "directory" fields
    | _ -> fail "socket descriptor is not an object" in
  let old_history = reserve old_slot ~instance:old
      ~context:(`Assoc ["kind", `String "browser_socket"; "directory", old_directory])
      ~version:(Some 2) in
  let old_binding = Filename.concat root (Lane_addon_store.binding_path old) in
  put old_binding (binding ~id:old ~current:true);
  let unversioned = slot (Lane_addon_store.digest "mcp-tools") in
  ignore (reserve unversioned ~instance:"tools" ~context:`Null ~version:None);
  let refusals = unchanged old_history (fun () ->
    expect_refusals P.Store.Native_claims ~base_path:base ~rows:4
      [old_history, P.Cleanup_descriptor; unversioned, P.Native_lease]) in
  check bool "the slot goes aside with the binding of the instance it holds" true
    (List.exists (fun (r : P.refusal) -> r.aside = [old_slot; old_binding]) refusals);
  check bool "the old binding is read, not moved" true (Sys.file_exists old_binding))

let receipt ~instance_id ~request_id ~executor =
  let action = `Assoc ["press", `String "start"] in
  let normalized =
    match Lane_addon_action.canonical (Lane_addon_action.arguments ~instance_id ~request_id ~action) with
    | Ok json -> json
    | Error detail -> fail detail in
  match
    Lane_addon_action.to_json
      { Lane_addon_action.instance_id; incarnation = instance_id; request_id; requester = "keeper"
      ; executor = None; input_sha256 = Lane_addon_action.input_digest normalized; action
      ; state = Lane_addon_action.Queued; result = None; detail = None }
  with
  | `Assoc fields -> `Assoc (("executor", executor) :: List.remove_assoc "executor" fields)
  | _ -> fail "receipt is not an object"

let grouped root directory ~group ~id =
  Filename.concat root
    (Filename.concat directory
       (Filename.concat (Lane_addon_store.digest group) (Lane_addon_store.digest id ^ ".json")))

let test_lane_addon_actions () = with_lane_store (fun base root ->
  let path id = grouped root Lane_addon_store.actions_directory ~group:"instance" ~id in
  put (path "current") (receipt ~instance_id:"instance" ~request_id:"current" ~executor:`Null);
  (* Before #44214 the executor was a string. *)
  put (path "string-executor")
    (receipt ~instance_id:"instance" ~request_id:"string-executor" ~executor:(`String "docker"));
  ignore (unchanged (path "string-executor") (fun () ->
    expect_refusals P.Store.Actions ~base_path:base ~rows:2
      [path "string-executor", P.Action_receipt])))

let exact_record ~declaration_id ~request_id ~messages =
  let request =
    `Assoc ["kind", `String "exact_output"; "request_id", `String request_id
           ; "output", `String "answer"; "messages", `List messages] in
  let digest =
    match Lane_addon_exact.request_of_json request with
    | Ok request -> Lane_addon_exact.digest request
    | Error _ -> Lane_addon_store.digest (Yojson.Safe.to_string request) in
  `Assoc ["declaration_id", `String declaration_id; "request_id", `String request_id
         ; "digest", `String digest; "request", request; "attempts", `List []; "final", `Null]

let test_lane_addon_exact_requests () = with_lane_store (fun base root ->
  let path id = grouped root Lane_addon_store.exact_requests_directory ~group:"quiz" ~id in
  put (path "current")
    (exact_record ~declaration_id:"quiz" ~request_id:"current"
       ~messages:[`Assoc ["role", `String "user"; "text", `String "hello"]]);
  (* Before #44407 a message was a bare string. *)
  put (path "string-messages")
    (exact_record ~declaration_id:"quiz" ~request_id:"string-messages" ~messages:[`String "hello"]);
  ignore (unchanged (path "string-messages") (fun () ->
    expect_refusals P.Store.Exact_requests ~base_path:base ~rows:2
      [path "string-messages", P.Exact_record])))

let tool_request_owner ~scope ~request_id ~schema =
  let request = `Assoc ["query", `String "rows"] in
  `Assoc ["schema", `String schema; "scope", `String scope; "request_id", `String request_id
         ; "installation_id", `String {|["configuration","curator"]|}; "package_id", `String "curator"
         ; "tool", `String "read"; "request_digest", `String (Lane_addon_store.digest (Yojson.Safe.to_string request))
         ; "request", request
         ; "progress", Lane_addon_request_progress.to_json Lane_addon_request_progress.captured]

let test_lane_addon_tool_request_owners () = with_lane_store (fun base root ->
  let path id = grouped root Lane_addon_store.tool_request_owners_directory ~group:"scope" ~id in
  put (path "current")
    (tool_request_owner ~scope:"scope" ~request_id:"current" ~schema:"lane.addon.tool-request-owner.v2");
  (* #44911 moved the record to schema v2. *)
  put (path "v1")
    (tool_request_owner ~scope:"scope" ~request_id:"v1" ~schema:"lane.addon.tool-request-owner.v1");
  ignore (unchanged (path "v1") (fun () ->
    expect_refusals P.Store.Tool_request_owners ~base_path:base ~rows:2
      [path "v1", P.Tool_request_owner])))

(* The deploy gate itself: a refused Lane Add-on record stops validate-stores. *)
let test_lane_addon_record_refuses_deploy exe () = with_lane_store (fun base root ->
  let path = grouped root Lane_addon_store.actions_directory ~group:"instance" ~id:"string-executor" in
  put path (receipt ~instance_id:"instance" ~request_id:"string-executor" ~executor:(`String "docker"));
  let status, output = unchanged path (fun () -> invoke exe base) in
  check bool ("an undecodable Lane Add-on record refuses deployment: " ^ output) true
    (status <> Unix.WEXITED 0);
  check bool ("the refusal names the file: " ^ output) true
    (String_util.contains_substring (diagnostic_words output) (diagnostic_words path)))

let () =
  let exe = Sys.getenv "MASC_TEST_DEPLOYMENT_PREFLIGHT_EXE" in
  let permission_tests =
    if Unix.geteuid () = 0 then (
      prerr_endline "SKIP unreadable transcript directory: root bypasses directory permissions";
      [])
    else [test_case "unreadable transcript inventory refuses deployment" `Quick
            (test_unreadable_transcript_directory exe)]
  in
  run "deployment store directories"
    ["live layout", ([test_case "regular journals and locks are not stores" `Quick (test_regular_siblings exe);
      test_case "real decoder failures remain visible" `Quick (test_real_store_refusals exe);
      test_case "transcript inventory failure stops deployment" `Quick
        (test_transcript_inventory_failure_stops_preflight exe);
      test_case "symlink remains a refusal" `Quick (test_symlink_refusal exe);
      test_case "range receipt ledger is read before rollout" `Quick
        (test_range_receipt_ledger exe);
      test_case "task backlog bytes retain duplicate intent fields" `Quick
        (test_task_backlog_original_bytes exe);
      test_case "transcript directory absence differs from a wrong-kind path" `Quick
        (test_transcript_directory_kind exe)] @ permission_tests);
     "lane-addon records",
     [test_case "bindings" `Quick test_lane_addon_bindings;
      test_case "native claims" `Quick test_lane_addon_native_claims;
      test_case "action receipts" `Quick test_lane_addon_actions;
      test_case "exact requests" `Quick test_lane_addon_exact_requests;
      test_case "tool request owners" `Quick test_lane_addon_tool_request_owners;
      test_case "a refused record stops validate-stores" `Quick
        (test_lane_addon_record_refuses_deploy exe)]]
