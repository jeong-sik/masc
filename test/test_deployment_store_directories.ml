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
    {|{"tasks":[{"id":"task-legacy","title":"fixture","description":"","priority":1,"files":[],"created_at":"2026-07-12T23:59:00Z","status":"awaiting_verification","assignee":"producer","started_at":"2026-07-12T23:59:00Z","submitted_at":"2026-07-13T00:00:00Z","verification_id":"fixture"%s}],"delivered_completion_rejections":[],"last_updated":"2026-07-13T00:00:00Z","version":1}|}
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

(* Every path below [root] with its bytes: the check must create, change and
   remove nothing, including the gate, lease and owner files of a slot. *)
let rec tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    (path, "directory")
    :: (Sys.readdir path |> Array.to_list |> List.sort String.compare
        |> List.concat_map (fun name -> tree (Filename.concat path name)))
  | Unix.S_REG -> [path, read path]
  | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> [path, "other"]

let unchanged root f =
  let before = tree root in
  let result = f () in
  check (list (pair string string)) "the check leaves the store as it was" before (tree root);
  result

type binding_shape =
  | Current
  | Detached_history
      (** The 116 records a live workspace held on 2026-10-22: detached, naming
          their declaration, without the execution authority fields. *)
  | September  (** #44651: no lifecycle and no read authority. *)

let binding ~id shape =
  let common =
    [ "instance_id", `String id; "incarnation", `String id; "run_id", `String "dos-counter"
    ; "addon_id", `String "dos-world"; "title", `String "DOS"; "revision", `String "1"
    ; "observation_seq", `Int 0 ] in
  let owner =
    `Assoc ["id", `String "dos-counter"; "source_path", `String "/declarations/dos-counter.toml"
           ; "revision", `String "1"] in
  let readers =
    [ "visibility", `Assoc ["kind", `String "shared"]
    ; "source_access", Lane_addon_sources.access_to_json Lane_addon_sources.Unauthenticated ] in
  let lifecycle state = "lifecycle", Lane_addon_lifecycle.state_to_json state in
  `Assoc
    (match shape with
     | Current ->
       common
       @ [ "configuration", `Null
         ; lifecycle
             (Lane_addon_lifecycle.Failed
                (Lane_addon_lifecycle.failed Lane_addon_lifecycle.Previous_process))
         ; "execution_authority", `Null; "resource", `Null ]
       @ readers
     | Detached_history ->
       common
       @ ["configuration", owner; lifecycle (Lane_addon_lifecycle.Detached Lane_addon_lifecycle.Never_created)]
       @ readers
     | September -> common @ ["configuration", owner; "phase", `String "failed"; "container_id", `Null])

let test_lane_addon_bindings () = with_lane_store (fun base root ->
  let path id = Filename.concat root (Lane_addon_store.binding_path id) in
  put (path "current") (binding ~id:"current" Current);
  put (path "history") (binding ~id:"history" Detached_history);
  put (path "september") (binding ~id:"september" September);
  let refusals = unchanged root (fun () ->
    expect_refusals P.Store.Bindings ~base_path:base ~rows:3
      [path "september", P.Retained_binding]) in
  check (list (list string)) "the binding alone goes aside" [[path "september"]]
    (List.map (fun (r : P.refusal) -> r.aside) refusals))

let test_lane_addon_native_claims () = with_lane_store (fun base root ->
  let claims = Filename.concat root Lane_addon_runtime.native_claims_directory in
  Fs_compat.mkdir_p claims;
  let slot name =
    let directory = Filename.concat claims name in
    Unix.mkdir directory 0o700;
    directory in
  (* A slot as the lease leaves it: gate, lease, owner receipt, intent and the
     admitted instance's history. *)
  let reserve directory ~instance ~context ~version =
    List.iter (fun name -> write (Filename.concat directory name) "") ["gate"; "lease"; "owner.json"];
    put (Filename.concat directory "intent.json")
      (`Assoc ["instance_id", `String instance; "state", `String "admitted"]);
    let history = Filename.concat directory ("instance-" ^ Lane_addon_store.digest instance ^ ".json") in
    put history
      (`Assoc (["instance_id", `String instance; "state", `String "reserved"; "cleanup_context", context]
               @ match version with Some v -> ["version", `Int v] | None -> []));
    history in
  let descriptor instance_id =
    match Browser_addon_socket.context ~instance_id ~source:Browser_addon_socket.External_host
            ~models:None with
    | Ok json -> json
    | Error detail -> fail detail in
  let directory_of descriptor = match descriptor with
    | `Assoc fields -> List.assoc "directory" fields
    | _ -> fail "socket descriptor is not an object" in
  let current = "01a162a0-f0f5-7000-a6c5-012f6785ec2f" in
  let old = "01a162a0-f0f5-7000-a6c5-012f6785ec30" in
  let earlier = "01a162a0-f0f5-7000-a6c5-012f6785ec31" in
  let current_slot = slot (Lane_addon_store.digest "browser-work") in
  ignore (reserve current_slot ~instance:current ~context:(descriptor current) ~version:(Some 2));
  (* The socket acquisition record cleanup reads beside the history. *)
  put (Filename.concat current_slot ("browser-" ^ Lane_addon_store.digest current ^ ".json"))
    (`Assoc ["state", `String "acquired"; "incarnation", `String current
            ; "directory", directory_of (descriptor current); "device", `Int 1; "inode", `Int 2]);
  (* The Chrome child slot of an instance the installation no longer holds is
     never read again, even in a shape this build does not read. *)
  ignore (reserve (slot ("browser-" ^ Lane_addon_store.digest earlier)) ~instance:earlier
            ~context:(`Assoc ["kind", `String "browser_addon_chrome"]) ~version:None);
  (* The #45106 record: written before #44364 with only kind and directory. *)
  let old_slot = slot (Lane_addon_store.digest "browser-old") in
  let old_history = reserve old_slot ~instance:old
      ~context:(`Assoc ["kind", `String "browser_socket"; "directory", directory_of (descriptor old)])
      ~version:(Some 2) in
  let old_binding = Filename.concat root (Lane_addon_store.binding_path old) in
  put old_binding (binding ~id:old Current);
  let unversioned = slot (Lane_addon_store.digest "mcp-tools") in
  ignore (reserve unversioned ~instance:"tools" ~context:`Null ~version:None);
  let tools_binding = Filename.concat root (Lane_addon_store.binding_path "tools") in
  put tools_binding (binding ~id:"tools" Current);
  let refusals = unchanged root (fun () ->
    expect_refusals P.Store.Native_claims ~base_path:base ~rows:3
      [old_history, P.Cleanup_descriptor; unversioned, P.Native_lease]) in
  check (list (list string)) "each slot goes aside with the binding of the instance it names"
    (List.sort compare [[old_slot; old_binding]; [unversioned; tools_binding]])
    (List.sort compare (List.map (fun (r : P.refusal) -> r.aside) refusals)))

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
  (* The runtime reads a receipt by its key; one stored under another key is
     refused there. *)
  put (path "misfiled") (receipt ~instance_id:"instance" ~request_id:"elsewhere" ~executor:`Null);
  ignore (unchanged root (fun () ->
    expect_refusals P.Store.Actions ~base_path:base ~rows:3
      [path "string-executor", P.Action_receipt; path "misfiled", P.Action_receipt])))

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
  ignore (unchanged root (fun () ->
    expect_refusals P.Store.Exact_requests ~base_path:base ~rows:2
      [path "string-messages", P.Exact_record])))

let owner_request = `Assoc ["query", `String "rows"]
let owner_request_bytes = Yojson.Safe.to_string owner_request

(* The current record names its request body by digest; the body lives
   beside the scope's records. *)
let tool_request_owner ~scope ~request_id ~schema ~request_digest =
  `Assoc ["schema", `String schema; "scope", `String scope; "request_id", `String request_id
         ; "installation_id", `String {|["configuration","curator"]|}; "package_id", `String "curator"
         ; "tool", `String "read"; "request_digest", `String request_digest; "summary", `Null
         ; "progress", Lane_addon_request_progress.to_json Lane_addon_request_progress.captured]

let test_lane_addon_tool_request_owners () = with_lane_store (fun base root ->
  let path id = grouped root Lane_addon_store.tool_request_owners_directory ~group:"scope" ~id in
  let request_digest = Lane_addon_store.digest owner_request_bytes in
  let body = Filename.concat root (Lane_addon_store.tool_request_body_path ~scope:"scope" ~request_digest) in
  Fs_compat.mkdir_p (Filename.dirname body);
  write body owner_request_bytes;
  let owner = tool_request_owner ~scope:"scope" ~schema:"lane.addon.tool-request-owner.v4" in
  put (path "current") (owner ~request_id:"current" ~request_digest);
  put (path "without-body")
    (owner ~request_id:"without-body" ~request_digest:(Lane_addon_store.digest "a body never published"));
  (* Records of an earlier schema, which carry the request, are refused. *)
  let carrying_request ~request_id ~schema =
    match tool_request_owner ~scope:"scope" ~request_id ~schema ~request_digest with
    | `Assoc fields -> `Assoc (("request", owner_request) :: fields)
    | json -> json in
  put (path "v2") (carrying_request ~request_id:"v2" ~schema:"lane.addon.tool-request-owner.v2");
  put (path "v1") (carrying_request ~request_id:"v1" ~schema:"lane.addon.tool-request-owner.v1");
  (* A record that names its body but keeps no summary is refused too. *)
  put (path "v3") (match tool_request_owner ~scope:"scope" ~request_id:"v3"
      ~schema:"lane.addon.tool-request-owner.v3" ~request_digest with
    | `Assoc fields -> `Assoc (List.remove_assoc "summary" fields)
    | json -> json);
  (* Discovery fails the whole scope on an entry it does not know. *)
  let stray = Filename.concat (Filename.dirname (path "current")) "notes.txt" in
  write stray "operator notes";
  ignore (unchanged root (fun () ->
    expect_refusals P.Store.Tool_request_owners ~base_path:base ~rows:6
      [path "without-body", P.Tool_request_owner; path "v2", P.Tool_request_owner;
       path "v1", P.Tool_request_owner; path "v3", P.Tool_request_owner; stray, P.Tool_request_inventory])))


(* The check runs beside a live server, which settles an original by moving
   its record and then its body. A record read just before that move, whose
   body the check then finds gone, is absent. A body lost under a record that
   stays is still refused. *)
let test_a_record_settled_while_it_is_checked_is_absent () = with_lane_store (fun base root ->
  let path id = grouped root Lane_addon_store.tool_request_owners_directory ~group:"scope" ~id in
  let body_of request =
    let bytes = Yojson.Safe.to_string request in
    let request_digest = Lane_addon_store.digest bytes in
    let body = Filename.concat root (Lane_addon_store.tool_request_body_path ~scope:"scope" ~request_digest) in
    Fs_compat.mkdir_p (Filename.dirname body);
    write body bytes;
    request_digest, body in
  let owner = tool_request_owner ~scope:"scope" ~schema:"lane.addon.tool-request-owner.v4" in
  let settled_digest, settled_body = body_of (`Assoc ["query", `String "settled rows"]) in
  let kept_digest, kept_body = body_of (`Assoc ["query", `String "kept rows"]) in
  put (path "settled") (owner ~request_id:"settled" ~request_digest:settled_digest);
  put (path "kept") (owner ~request_id:"kept" ~request_digest:kept_digest);
  let after_read read =
    if String.equal read (path "settled") then (Sys.remove read; Sys.remove settled_body)
    else if String.equal read (path "kept") then Sys.remove kept_body in
  match P.For_testing.scan ~after_read P.Store.Tool_request_owners ~base_path:base with
  | Error detail -> fail detail
  | Ok report ->
    check int "only the record that stayed is read" 1 report.P.rows;
    check (list string) "the record whose body went under it is refused, the settled one is not"
      [path "kept"] (List.map (fun (refusal : P.refusal) -> refusal.path) report.P.refusals))

(* The deploy gate itself: a refused Lane Add-on record stops validate-stores. *)
let test_lane_addon_record_refuses_deploy exe () = with_lane_store (fun base root ->
  let path = grouped root Lane_addon_store.actions_directory ~group:"instance" ~id:"string-executor" in
  put path (receipt ~instance_id:"instance" ~request_id:"string-executor" ~executor:(`String "docker"));
  let status, output = unchanged root (fun () -> invoke exe base) in
  check bool ("an undecodable Lane Add-on record refuses deployment: " ^ output) true
    (status <> Unix.WEXITED 0);
  check bool ("the refusal names the file: " ^ output) true
    (String_util.contains_substring (diagnostic_words output) (diagnostic_words path)))

module Original = Lane_addon_tool_request_owner
module Admission = Keeper_librarian_admission_capture
module Original_gate = Keeper_librarian_admission_gate
module Absorb = Keeper_librarian_absorb_gate
module Progress = Lane_addon_request_progress
let require = function Ok value -> value | Error detail -> fail detail
let original_result result = Result.map_error Original.error_to_string result |> require
let advance_original store expected events =
  match Original.advance_events ~store ~expected ~events with
  | Ok (Original.Stored record | Already_stored record) -> record
  | Ok (Unconfirmed detail) -> fail detail
  | Error error -> fail (Original.update_error_to_string error)
let owner_path root (record:Original.retained) = grouped root Lane_addon_store.tool_request_owners_directory
  ~group:record.scope ~id:record.request_id
let replace_member name value = function
  | `Assoc fields -> `Assoc ((name,value)::List.remove_assoc name fields)
  | _ -> fail "expected an original payload object"
let replace_original_request root store (record:Original.retained) request =
  let request=Lane_addon_action.canonical request |> require in
  let bytes=Yojson.Safe.to_string request in
  let request_digest=Lane_addon_store.digest bytes in
  Lane_addon_store.save_tool_request_body store ~scope:record.scope ~request_digest bytes |> require;
  let path=owner_path root record in
  put path (Yojson.Safe.from_string (read path) |> replace_member "request_digest" (`String request_digest));
  Original.load ~store ~scope:record.scope ~request_id:record.request_id |> original_result
  |> Option.to_result ~none:"altered original disappeared" |> require
let unchanged_workspace base f =
  let state ()=tree base |> List.filter (fun (path,_) ->
    path<>Filename.concat base "stdout" && path<>Filename.concat base "stderr") in
  let before=state () in
  let result=f () in
  check (list (pair string string)) "preflight changes no workspace state, epoch, receipt or ACK" before (state ());
  result
type librarian_payload_fixture = {
  base:string; root:string; store:Lane_addon_store.t; owner:Admission.owner;
  capture:Admission.t; parent:Original.retained; gate_id:string; gate_request:Yojson.Safe.t;
}
let with_librarian_payload f = with_lane_store (fun base root ->
  let module Queue=Keeper_memory_admission_queue in
  let module L=Keeper_librarian in
  let keeper_id="preflight-librarian" in
  let keepers_dir=Filename.concat base ".masc/config/keepers" in
  Fs_compat.mkdir_p keepers_dir;
  let fact=Keeper_memory_os_types.observed ~claim:"Original pending evidence"
    ~category:Keeper_memory_os_types.Fact ~now:10.
    ~origin:{kind=Keeper_memory_os_types.Authored;trace_id="preflight-original"} in
  Queue.append ~keepers_dir ~keeper_id ~request_id:"source" fact
    |> Result.map_error Queue.append_error_to_string |> require |> ignore;
  let batch=Queue.read_pending ~keepers_dir ~keeper_id |> require
    |> Option.to_result ~none:"fixture queue absent" |> require in
  let physical path=let stat=Unix.stat path in `Assoc ["path",`String path;
    "device",`Int stat.Unix.st_dev;"inode",`Int stat.st_ino] in
  let owner=Admission.owner_of_json (`Assoc ["workspace",physical base;"keepers",physical keepers_dir;
    "keeper_id",`String keeper_id;"epoch",`String "captured-historical-epoch";
    "queue_generation",`String (List.hd (Queue.candidate_ids batch)).queue_generation]) |> require in
  (* No live Memory epoch exists. A valid captured payload must still be
     inspectable without observing/reinitializing current authority. *)
  let input:L.input={turn_ref=Ids.Turn_ref.make ~trace_id:"preflight-original" ~absolute_turn:1;
    keeper_id=Masc_test_deps.keeper_id_fixture keeper_id;keeper_instructions="Retain source evidence";
    goal_context=L.No_task;historical_task_contexts=[];current=None;
    working_context=Keeper_librarian_context.empty;messages=[];tool_observations=[];counterpart_observations=[]} in
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  let retirement=Keeper_memory_admission_judgment.Available [] in
  let preparation=Keeper_librarian_runtime.prepare_admission ~batch ~retirement input |> require in
  let destination:Admission.destination={installation_id=Original.installation_id (Original.Configuration "librarian");
    package_id=Admission.package_id;tool=Admission.tool;source_revision="source";configuration_revision="configuration"} in
  let capture=Admission.create ~request_id:(Admission.fresh_request_id owner) ~parent_part_id:"part"
    ~owner ~destination ~batch ~input ~expected_revision:None ~now:10. ~retirement ~preparation |> require in
  let request=Admission.to_json capture in
  let part=`Assoc ["schema",`Int 1;"kind",`String "candidate_part";"part_id",`String "part";
    "owner",Admission.owner_to_json owner;"destination",Yojson.Safe.Util.member "destination" request;
    "predecessor",`Null;"original_through",`Int (List.hd (Queue.candidates batch)).sequence;
    "supersession",`Null;"candidate_ids",Yojson.Safe.Util.member "candidate_ids" request;
    "batch",Queue.batch_to_json batch] in
  let store=Lane_addon_store.create ~root in
  let retain scope request_id request =
    Original.retain ~store ~scope ~request_id ~installation_id:destination.installation_id
      ~package_id:destination.package_id ~tool:destination.tool ~summary:`Null ~request |> original_result;
    Original.load ~store ~scope ~request_id |> original_result
      |> Option.to_result ~none:"fixture original absent" |> require in
  ignore (retain (Keeper_librarian_admission_parts.scope owner) "part" part);
  let parent=retain (Admission.scope owner) (Admission.request_id capture) request in
  let proposal=`Assoc ["memory",`Assoc ["new_claims",`List [`Assoc ["claim",`String fact.claim;
    "category",`String "fact";"board_post_id",`Null;"board_comment_id",`Null;
    "supersedes",`Null;"absorbs",`List []]];"dropped",`List [];"working_state",`Null;"working_contexts",`List []];
    "candidates",`List [`Assoc ["request_id",`String "source";"outcome",`String "incorporated";
      "memory_claim",`String fact.claim;"reason",`String "The original source supports this claim."]];
    "change_support",`List [`String "source"]] in
  let exact=Admission.request capture |> require in
  let output:Lane_addon_types.exact_output={name=exact.output;schema=Option.get exact.schema;
    request_schema=Lane_addon_types.Consumer_request_schema} in
  let checked=Lane_addon_exact.validate_answer ~output exact proposal |> require in
  let judgment=Lane_addon_exact.final_to_json (Lane_addon_exact.Call_final
    (Lane_addon_exact.Answered {output=checked;slot="fixture";usage=None})) in
  let parent=advance_original store parent [Progress.Dispatch_intended;Progress.Judgment_retained judgment] in
  let guidance=Absorb.resolve_guidance () |> require in
  let gate_id="captured-gate" in
  let gate_request=`Assoc ["version",`Int 3;"kind",`String "librarian-admission-gate";
    "request_id",`String gate_id;"owner",Admission.owner_to_json owner;
    "execution_id",`String parent.request_id;"execution_digest",`String parent.request_digest;
    "proposal",proposal;"authority",Absorb.replay_authority_to_yojson (Absorb.Gate_unavailable Typesafeai_config.Absorb_gate_disabled);
    "guidance",Absorb.guidance_to_yojson guidance;"predecessor",`Null] in
  f {base;root;store;owner;capture;parent;gate_id;gate_request})
let retain_gate fixture ~request_id request =
  Original.retain ~store:fixture.store ~scope:(Original_gate.scope fixture.owner) ~request_id
    ~installation_id:fixture.parent.installation_id ~package_id:fixture.parent.package_id
    ~tool:fixture.parent.tool ~summary:`Null ~request
    |> original_result;
  Original.load ~store:fixture.store ~scope:(Original_gate.scope fixture.owner) ~request_id
    |> original_result |> Option.to_result ~none:"fixture gate absent" |> require
let publish_gate fixture request =
  let parent=advance_original fixture.store fixture.parent
    [Progress.Preparation_intended {request_id=fixture.gate_id;request}] in
  let gate=retain_gate fixture ~request_id:fixture.gate_id request in
  ignore (advance_original fixture.store parent [Progress.Preparation_observed fixture.gate_id]);gate
let assert_domain_refusal exe fixture (record:Original.retained) expected =
  check int "the generic envelope/body decoder accepts this fixture" 0
    (List.length (scan P.Store.Tool_request_owners ~base_path:fixture.base).P.refusals);
  let status,output=unchanged_workspace fixture.base (fun () -> invoke exe fixture.base) in
  check bool ("domain payload refusal stops installation: " ^ output) true (status<>Unix.WEXITED 0);
  List.iter (fun text -> check bool ("reports " ^ text ^ ": " ^ output) true
    (String_util.contains_substring (diagnostic_words output) (diagnostic_words text)))
    [owner_path fixture.root record;Printf.sprintf "scope=%S" record.scope;
     Printf.sprintf "request_id=%S" record.request_id;"request_digest=" ^ record.request_digest;expected]
let test_current_librarian_payloads exe () = with_librarian_payload (fun fixture ->
  ignore (publish_gate fixture fixture.gate_request);
  let status,output=unchanged_workspace fixture.base (fun () -> invoke exe fixture.base) in
  check bool ("current captures and their captured gate pass without a live epoch: " ^ output) true
    (status=Unix.WEXITED 0);
  check bool "the actual consumer examines the part, execution and gate" true
    (String_util.contains_substring output "lane-addon tool request owners rows=3 refused=0"))
let test_old_librarian_execution exe () = with_librarian_payload (fun fixture ->
  let record=replace_original_request fixture.root fixture.store fixture.parent
    (fixture.parent.request |> replace_member "schema" (`Int 1)) in
  assert_domain_refusal exe fixture record "Unknown original Librarian execution schema/kind")
let test_missing_librarian_policy exe () = with_librarian_payload (fun fixture ->
  let prepared=Yojson.Safe.Util.member "preparation" fixture.parent.request |> Yojson.Safe.Util.to_assoc in
  let record=replace_original_request fixture.root fixture.store fixture.parent
    (fixture.parent.request |> replace_member "preparation" (`Assoc (List.remove_assoc "admission_prompt" prepared))) in
  assert_domain_refusal exe fixture record "Original Librarian capture has unknown, missing or repeated fields")
let test_librarian_source_parent exe () = with_librarian_payload (fun fixture ->
  let record=replace_original_request fixture.root fixture.store fixture.parent
    (fixture.parent.request |> replace_member "parent_part_id" (`String "missing-original-part")) in
  assert_domain_refusal exe fixture record "Original parent record is absent")
let test_librarian_host_binding exe () = with_librarian_payload (fun fixture ->
  let record=replace_original_request fixture.root fixture.store fixture.parent
    (fixture.parent.request |> replace_member "request_id" (`String (Admission.fresh_request_id fixture.owner))) in
  assert_domain_refusal exe fixture record "Original execution differs from its retained host owner")
let test_old_librarian_gate exe () = with_librarian_payload (fun fixture ->
  let gate=publish_gate fixture (fixture.gate_request |> replace_member "version" (`Int 2)) in
  assert_domain_refusal exe fixture gate "Original gate request is not version 3")
let test_old_gate_preparation exe () = with_librarian_payload (fun fixture ->
  let request=fixture.gate_request |> replace_member "version" (`Int 2) in
  let parent=advance_original fixture.store fixture.parent
    [Progress.Preparation_intended {request_id=fixture.gate_id;request}] in
  assert_domain_refusal exe fixture parent "Original gate request is not version 3")
let test_current_gate_preparation exe () = with_librarian_payload (fun fixture ->
  ignore (advance_original fixture.store fixture.parent
    [Progress.Preparation_intended {request_id=fixture.gate_id;request=fixture.gate_request}]);
  let status,output=unchanged_workspace fixture.base (fun () -> invoke exe fixture.base) in
  check bool ("a current pending preparation needs no child publication or recovery: " ^ output) true
    (status=Unix.WEXITED 0);
  ignore (retain_gate fixture ~request_id:fixture.gate_id fixture.gate_request);
  let status,output=unchanged_workspace fixture.base (fun () -> invoke exe fixture.base) in
  check bool ("an unacknowledged Captured root remains a valid retained state: " ^ output) true
    (status=Unix.WEXITED 0))
let test_orphan_gate_root exe () = with_librarian_payload (fun fixture ->
  let gate=retain_gate fixture ~request_id:fixture.gate_id fixture.gate_request in
  assert_domain_refusal exe fixture gate "Original gate root has no full parent preparation intent")
let test_mismatched_gate_root exe () = with_librarian_payload (fun fixture ->
  ignore (publish_gate fixture fixture.gate_request);
  let request_id="another-root" in
  let gate=retain_gate fixture ~request_id
    (fixture.gate_request |> replace_member "request_id" (`String request_id)) in
  assert_domain_refusal exe fixture gate "Original parent names another gate root")
let test_missing_gate_predecessor exe () = with_librarian_payload (fun fixture ->
  ignore (publish_gate fixture fixture.gate_request);
  let request_id="retry" in
  let gate=retain_gate fixture ~request_id (fixture.gate_request
    |> replace_member "request_id" (`String request_id) |> replace_member "predecessor" (`String "missing-gate")) in
  assert_domain_refusal exe fixture gate "Original predecessor gate is absent")
let test_wrong_gate_predecessor exe () = with_librarian_payload (fun fixture ->
  ignore (publish_gate fixture fixture.gate_request);
  let request_id="retry" in
  let gate=retain_gate fixture ~request_id (fixture.gate_request
    |> replace_member "request_id" (`String request_id) |> replace_member "predecessor" (`String fixture.gate_id)) in
  assert_domain_refusal exe fixture gate "Gate child has no original forward publication intent")
let test_cyclic_gate_predecessors exe () = with_librarian_payload (fun fixture ->
  ignore (publish_gate fixture fixture.gate_request);
  let request request_id predecessor=fixture.gate_request
    |> replace_member "request_id" (`String request_id) |> replace_member "predecessor" (`String predecessor) in
  let gate=retain_gate fixture ~request_id:"cycle-a" (request "cycle-a" "cycle-b") in
  ignore (retain_gate fixture ~request_id:"cycle-b" (request "cycle-b" "cycle-a"));
  assert_domain_refusal exe fixture gate "Cyclic gate retry ancestry")
let test_gate_predecessor_identity exe ~wrong_id () = with_librarian_payload (fun fixture ->
  let prior=publish_gate fixture fixture.gate_request in
  let request_id="retry" in
  let request=fixture.gate_request |> replace_member "request_id" (`String request_id)
    |> replace_member "predecessor" (`String prior.request_id) in
  let intended_id=if wrong_id then "another-retry" else request_id in
  let intended=request |> replace_member "request_id" (`String intended_id)
    |> replace_member "authority" (Absorb.replay_authority_to_yojson (Absorb.Gate_unavailable Typesafeai_config.Lane_disabled)) in
  let successor=Original.prepare_successor ~store:fixture.store ~scope:prior.scope ~request_id:intended_id
    ~request:intended |> original_result in
  ignore (advance_original fixture.store prior [Progress.Dispatch_intended;
    Progress.Refused {stage=Progress.Execution;evidence=`Null};Progress.Successor_intended successor]);
  let child=retain_gate fixture ~request_id request in
  assert_domain_refusal exe fixture child (if wrong_id then "Gate predecessor names another original child"
    else "Gate child differs from original successor intent"))
let test_unacknowledged_root_progress exe () = with_librarian_payload (fun fixture ->
  ignore (advance_original fixture.store fixture.parent
    [Progress.Preparation_intended {request_id=fixture.gate_id;request=fixture.gate_request}]);
  let gate=retain_gate fixture ~request_id:fixture.gate_id fixture.gate_request in
  let gate=advance_original fixture.store gate [Progress.Dispatch_intended] in
  assert_domain_refusal exe fixture gate "Unacknowledged original gate root has execution progress")
let test_unacknowledged_retry_child exe () = with_librarian_payload (fun fixture ->
  let gate=publish_gate fixture fixture.gate_request in
  let request_id="pending-retry" in
  let request=fixture.gate_request |> replace_member "request_id" (`String request_id)
    |> replace_member "predecessor" (`String gate.request_id) in
  let successor=Original.prepare_successor ~store:fixture.store ~scope:gate.scope ~request_id ~request |> original_result in
  ignore (advance_original fixture.store gate [Progress.Dispatch_intended;
    Progress.Refused {stage=Progress.Execution;evidence=`Null};Progress.Successor_intended successor]);
  let child=retain_gate fixture ~request_id request in
  let status,output=unchanged_workspace fixture.base (fun () -> invoke exe fixture.base) in
  check bool ("the captured pending retry is readable without publication recovery or ACK: " ^ output) true
    (status=Unix.WEXITED 0);
  let child=advance_original fixture.store child [Progress.Dispatch_intended] in
  assert_domain_refusal exe fixture child "Unacknowledged original gate child has execution progress")
let test_historical_gate_namespaces exe () =
  List.iter (fun (namespace,kind) -> with_librarian_payload (fun fixture ->
    let request_id="historical-gate" in
    let scope=namespace ^ Lane_addon_store.digest "captured-history" in
    let request=fixture.gate_request |> replace_member "version" (`Int 2)
      |> replace_member "kind" (`String kind) |> replace_member "request_id" (`String request_id) in
    Original.retain ~store:fixture.store ~scope ~request_id
      ~installation_id:fixture.parent.installation_id ~package_id:fixture.parent.package_id ~tool:fixture.parent.tool
      ~summary:`Null ~request |> original_result;
    let record=Original.load ~store:fixture.store ~scope ~request_id |> original_result |> Option.get in
    assert_domain_refusal exe fixture record "Original gate request is not version 3"))
    ["keeper-librarian-durable-gate/","librarian-durable-gate";
     "keeper-librarian-floor-step-gate/","librarian-floor-step-gate"]
let test_old_gate_successor_body exe () = with_librarian_payload (fun fixture ->
  let gate=publish_gate fixture fixture.gate_request in
  let request_id="unpublished-retry" in
  let request=fixture.gate_request |> replace_member "version" (`Int 2)
    |> replace_member "request_id" (`String request_id) |> replace_member "predecessor" (`String gate.request_id) in
  let successor=Original.prepare_successor ~store:fixture.store ~scope:gate.scope ~request_id ~request |> original_result in
  let gate=advance_original fixture.store gate [Progress.Dispatch_intended;
    Progress.Refused {stage=Progress.Execution;evidence=`Null};Progress.Successor_intended successor] in
  assert_domain_refusal exe fixture gate "Original gate request is not version 3")

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
      test_case "a record settled while it is checked is absent" `Quick
        test_a_record_settled_while_it_is_checked_is_absent;
      test_case "a refused record stops validate-stores" `Quick
        (test_lane_addon_record_refuses_deploy exe)];
     "Librarian current payloads",
     [test_case "current originals and gates need no live epoch" `Quick (test_current_librarian_payloads exe);
      test_case "old execution payload refuses deployment" `Quick (test_old_librarian_execution exe);
      test_case "absent captured policy is not reconstructed" `Quick (test_missing_librarian_policy exe);
      test_case "the original part source must exist" `Quick (test_librarian_source_parent exe);
      test_case "captured request identity must match its host record" `Quick (test_librarian_host_binding exe);
      test_case "old gate payload refuses deployment" `Quick (test_old_librarian_gate exe);
      test_case "old unpublished gate preparation refuses deployment" `Quick (test_old_gate_preparation exe);
      test_case "current unpublished gate preparation is readable" `Quick (test_current_gate_preparation exe);
      test_case "orphan roots cannot pass payload preflight" `Quick (test_orphan_gate_root exe);
      test_case "a root must match its parent's preparation" `Quick (test_mismatched_gate_root exe);
      test_case "a retry must retain its predecessor" `Quick (test_missing_gate_predecessor exe);
      test_case "retry links must be reciprocal" `Quick (test_wrong_gate_predecessor exe);
      test_case "retry ancestry cannot cycle" `Quick (test_cyclic_gate_predecessors exe);
      test_case "predecessor names the exact child ID" `Quick (test_gate_predecessor_identity exe ~wrong_id:true);
      test_case "predecessor names the exact child digest" `Quick (test_gate_predecessor_identity exe ~wrong_id:false);
      test_case "an unacknowledged root cannot have execution progress" `Quick (test_unacknowledged_root_progress exe);
      test_case "a pending retry permits only a Captured child" `Quick (test_unacknowledged_retry_child exe);
      test_case "historical gate namespaces are not skipped" `Quick (test_historical_gate_namespaces exe);
      test_case "old unpublished retry body refuses deployment" `Quick (test_old_gate_successor_body exe)]]
