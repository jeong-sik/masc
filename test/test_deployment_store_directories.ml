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

let invoke_with_args ?timeout exe root arguments =
  let stdout_path = Filename.concat root "stdout" in
  let stderr_path = Filename.concat root "stderr" in
  let output = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let errors = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let status = Fun.protect ~finally:(fun () -> Unix.close output; Unix.close errors) (fun () ->
    let pid = Unix.create_process exe
      (Array.of_list (exe :: arguments)) Unix.stdin output errors in
    match timeout with
    | None -> snd (Unix.waitpid [] pid)
    | Some seconds ->
      let deadline = Unix.gettimeofday () +. seconds in
      let rec wait () =
        match Unix.waitpid [Unix.WNOHANG] pid with
        | 0, _ when Unix.gettimeofday () < deadline ->
          ignore (Unix.select [] [] [] 0.05); wait ()
        | 0, _ ->
          (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
          ignore (Unix.waitpid [] pid);
          fail "deployment preflight did not finish while inspecting special files"
        | _, status -> status in
      wait ()) in
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

(* #51587: #51429 moved a receipt's [arguments] to [{"known": _}] or
   [{"unknown": true}] and the deploy check did not read the outbox, so an
   install passed with receipts whose [arguments] is the bare call arguments,
   and every request of their Keepers failed after the start. *)
let test_tool_outbox_receipts exe () = with_workspace (fun root _keepers _traces ->
  let module Codec = Keeper_client_tool_outbox_codec in
  let directory =
    match Keeper_official_client_paths.outbox_dir ~base_path:root ~keeper_name:"keeper" with
    | Ok directory -> directory
    | Error detail -> fail detail in
  Fs_compat.mkdir_p directory;
  let call_arguments = `Assoc ["command", `String "ls"] in
  let put json =
    let path = Filename.concat directory (Codec.filename json) in
    write path (Yojson.Safe.to_string json);
    path in
  let readable = put (Codec.to_json
    { Codec.thread_id = "thread"; turn_id = "turn"; call_id = "call-current"
    ; tool_name = "Execute"; arguments = Codec.Known call_arguments
    ; response = `Assoc ["outcome", `String "completed"] }) in
  let status, output = invoke exe root in
  check bool ("receipts this build reads do not stop deployment: " ^ output) true
    (status = Unix.WEXITED 0);
  check bool ("the outbox is counted: " ^ output) true
    (String_util.contains_substring output "keeper tool outbox receipts rows=1 refused=0");
  let earlier = `Assoc
    [ "thread_id", `String "thread"; "turn_id", `String "turn"
    ; "call_id", `String "call-earlier"; "tool_name", `String "Execute"
    ; "arguments", call_arguments
    ; "response", `Assoc ["outcome", `String "completed"] ] in
  let refused = put earlier in
  let status, output = invoke exe root in
  check bool ("a receipt this build cannot read stops deployment: " ^ output) true
    (status <> Unix.WEXITED 0);
  check bool ("both receipts are counted and one is refused: " ^ output) true
    (String_util.contains_substring output "keeper tool outbox receipts rows=2 refused=1");
  check bool ("the refusal names the file and the cause: " ^ output) true
    (String_util.contains_substring output (refused ^ ": invalid tool outbox arguments"));
  check string "the refused receipt is left as it was" (Yojson.Safe.to_string earlier)
    (read refused);
  check bool "the readable receipt is still there" true (Sys.file_exists readable))

(* #48087: #47996 made [audience] required on a Board stimulus and the deploy
   check did not read the reaction ledger. An ACK row carries the transition
   receipt with the stimulus it retired, so an install passed with ledgers
   holding earlier Board receipts, and once-only wakes of those Keepers were
   refused after the start. The rows are what the production writers leave
   for a Board post a turn consumed: its dispatch row and the projected ACK. *)
let write_consumed_board_post ~base_path ~keeper_name =
  let ok label = function Ok value -> value | Error detail -> fail (label ^ ": " ^ detail) in
  let module Queue = Keeper_event_queue_persistence in
  let source : Keeper_event_queue.stimulus =
    { post_id = "post-read-before-rollout"
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = Unix.gettimeofday ()
    ; payload = Keeper_event_queue.Board_signal
        { kind = Keeper_event_queue.Post_created; author = "operator"; title = "Ship"
        ; content = "Please react"; hearth = None; updated_at = None
        ; audience = Keeper_event_queue.Audience_discoverable } } in
  Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name source;
  let (_ : Queue.enqueue_stimulus_result) =
    Queue.enqueue_stimulus_if_absent_result ~base_path ~keeper_name source |> ok "enqueue" in
  let selection =
    match Queue.pending_selections_result ~base_path ~keeper_name |> ok "read the queue" with
    | [ selection ] -> selection
    | _ -> fail "the queue holds the one source" in
  let receipt =
    match Queue.terminalize_pending_turn_completed_result ~base_path ~keeper_name
            ~applied_at:(Unix.gettimeofday ()) ~selection () |> ok "complete the turn" with
    | Queue.Turn_terminal_committed
        (Queue.Transition_applied receipt | Queue.Transition_already_applied receipt) -> receipt
    | Queue.Turn_terminal_committed (Queue.Transition_committed_followup_failed { detail; _ }) ->
      fail detail
    | Queue.Turn_selection_withdrawn -> fail "the source was withdrawn" in
  Keeper_reaction_ledger.project_event_queue_transition_outbox_result ~base_path ~keeper_name
    ~expected_transition_id:receipt.transition_id |> ok "project the ACK";
  Dated_jsonl.range_day_file_paths_result
    (Dated_jsonl.open_store (Keeper_reaction_ledger.location ~base_path ~keeper_name))
    ~since:"1970-01-01" ~until:"9999-12-31"
  |> Result.map_error Dated_jsonl.read_error_to_string |> ok "list the ledger"

let ledger_lines paths = List.concat_map (fun path ->
  In_channel.with_open_bin path In_channel.input_lines) paths

let test_reaction_ledger_refusal exe () = with_workspace (fun root _keepers _traces ->
  let keeper_name = "keeper" in
  let paths = write_consumed_board_post ~base_path:root ~keeper_name in
  (* The receipt as a build before #47996 wrote it: its Board stimulus has no
     [audience]. *)
  let rec without_audience = function
    | `Assoc fields ->
      `Assoc (List.filter_map (fun (key, value) ->
        if String.equal key "audience" then None else Some (key, without_audience value)) fields)
    | `List items -> `List (List.map without_audience items)
    | json -> json in
  let ack = Keeper_reaction_ledger.(reaction_kind_to_string Event_queue_ack) in
  let earlier line = match Yojson.Safe.from_string line with
    | `Assoc fields ->
      (match List.assoc_opt "reaction" fields with
       | Some (`Assoc reaction) when List.assoc_opt "kind" reaction = Some (`String ack) ->
         let reaction = List.map (fun (key, value) ->
           if String.equal key "transition_receipt" then key, without_audience value
           else key, value) reaction in
         Some (Yojson.Safe.to_string (`Assoc (List.map (fun (key, value) ->
           if String.equal key "reaction" then key, `Assoc reaction else key, value) fields)))
       | Some _ | None -> None)
    | json -> fail ("a ledger row is not an object: " ^ Yojson.Safe.to_string json) in
  let changed = List.fold_left (fun changed path ->
    let lines = In_channel.with_open_bin path In_channel.input_lines in
    let rewritten = List.map (fun line -> Option.value (earlier line) ~default:line) lines in
    if rewritten = lines then changed
    else (write path (String.concat "\n" rewritten ^ "\n"); path :: changed)) [] paths in
  let refused_file = match changed with
    | [ path ] -> path
    | _ -> fail "the one ACK row is in one day file" in
  let refused_bytes = read refused_file in
  let status, output = invoke exe root in
  check bool ("a ledger row this build cannot decode stops deployment: " ^ output) true
    (status <> Unix.WEXITED 0);
  check bool ("every row is counted and the ACK is refused: " ^ output) true
    (String_util.contains_substring output
       (Printf.sprintf "keeper reaction ledger rows=%d refused=1"
          (List.length (ledger_lines paths))));
  check bool ("the refusal names the ledger and the reason once-only wakes get: " ^ output) true
    (String_util.contains_substring output
       (Keeper_reaction_ledger.store_dir ~base_path:root ~keeper_name
        ^ ": reaction ledger delivery evidence incomplete: malformed_rows=0 \
           semantic_invalid_rows=1 first_reason=invalid_transition_receipt"));
  check string "the refused row is left as it was" refused_bytes (read refused_file))

let test_reaction_ledger_reads exe () = with_workspace (fun root _keepers _traces ->
  let status, output = invoke exe root in
  check bool ("a keeper without a ledger does not stop deployment: " ^ output) true
    (status = Unix.WEXITED 0);
  check bool ("a keeper without a ledger has no rows: " ^ output) true
    (String_util.contains_substring output "keeper reaction ledger rows=0 refused=0");
  let paths = write_consumed_board_post ~base_path:root ~keeper_name:"keeper" in
  let status, output = invoke exe root in
  check bool ("a ledger this build reads does not stop deployment: " ^ output) true
    (status = Unix.WEXITED 0);
  check bool ("the dispatch and the ACK are counted: " ^ output) true
    (String_util.contains_substring output
       (Printf.sprintf "keeper reaction ledger rows=%d refused=0"
          (List.length (ledger_lines paths)))))

(* The logger stamps a line with the second it was written, and a second run
   starts a second later. *)
let without_log_stamp line =
  if String.length line > 22 && line.[0] = '[' && line.[20] = ']' && line.[21] = ' '
  then String.sub line 22 (String.length line - 22)
  else line

(* The timings differ between runs, and with several jobs the start lines come
   in another order than the reports. Everything else is the verdict. *)
let without_timing output =
  String.split_on_char '\n' output
  |> List.filter (fun line ->
    not (String_util.contains_substring line "scan_started"
         || String_util.contains_substring line "scan_elapsed_s="))
  |> List.map without_log_stamp

let test_scan_jobs_do_not_change_the_report exe () = with_workspace (fun root keepers traces ->
  write (Filename.concat keepers "keeper/turn-boundaries.jsonl") "{invalid boundary}\n";
  write (Filename.concat traces "trace/history.jsonl") "{invalid fragment}\n";
  let run jobs =
    invoke_with_args exe root
      ["validate-stores"; "--base-path"; root; "--jobs"; string_of_int jobs] in
  let sequential_status, sequential = run 1 in
  let parallel_status, parallel = run 4 in
  check bool ("one job refuses the malformed stores: " ^ sequential) true
    (sequential_status <> Unix.WEXITED 0);
  check bool ("four jobs refuse them too: " ^ parallel) true
    (parallel_status <> Unix.WEXITED 0);
  check bool "the refused rows are named" true
    (String_util.contains_substring parallel "keeper turn boundaries rows=1 refused=1");
  check (list string) "the report lines are the same" (without_timing sequential)
    (without_timing parallel))

let test_zero_scan_jobs_are_refused exe () = with_workspace (fun root _keepers _traces ->
  let status, output =
    invoke_with_args exe root ["validate-stores"; "--base-path"; root; "--jobs"; "0"] in
  check bool ("no scan runs without a process to run it: " ^ output) true
    (status <> Unix.WEXITED 0);
  check bool ("the refusal names the option: " ^ output) true
    (String_util.contains_substring (diagnostic_words output) "--jobs must be at least 1"))

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
  check (list (list string)) "fresh state deletes the binding alone" [[path "september"]]
    (List.map (fun (r : P.refusal) -> r.delete) refusals))

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
    match Browser_addon_socket.context ~instance_id ~source:Browser_addon_socket.Ego with
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
  check (list (list string)) "fresh state deletes each slot with the binding of the instance it names"
    (List.sort compare [[old_slot; old_binding]; [unversioned; tools_binding]])
    (List.sort compare (List.map (fun (r : P.refusal) -> r.delete) refusals)))

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

(* validate-stores resolves --base-path as the server resolves its workspace,
   so the workspace's .masc directory, a ./ suffix and a symlink to the
   workspace all read the store the server serves. The proof file names the
   root the server writes under, through symlinks: a check that read the store
   under another root would stop on it before it refuses the record. *)
let test_base_path_forms_read_the_served_store exe () = with_lane_store (fun base root ->
  let record = exact_record ~declaration_id:"quiz" ~request_id:"served"
      ~messages:[`Assoc ["role", `String "user"; "text", `String "hello"]] in
  let path = grouped root Lane_addon_store.exact_requests_directory ~group:"quiz" ~id:"served" in
  put path record;
  let link = match Lane_addon_exact.Retained_key.of_record record with
    | Ok key -> Filename.concat root (Lane_addon_exact.Retained_key.proof_path key)
    | Error detail -> failf "the record names no proof file: %s" detail in
  let served = Lane_addon_store.directory
      ~masc_dir:(Common.masc_dir_from_base_path ~base_path:(Unix.realpath base)) in
  (* The link holds nothing but its root. Once the root matches, the link
     does not decode, and the check refuses the record with it. *)
  put link (`Assoc ["executions", `List [`Assoc ["store_root", `String served]]]);
  let alias = Filename.temp_file "preflight-lane-addons-alias-" "" in
  Sys.remove alias;
  Unix.symlink base alias;
  Fun.protect ~finally:(fun () -> Sys.remove alias) (fun () ->
    List.iter (fun base_path ->
      let status, output = invoke_with_args exe base ["validate-stores"; "--base-path"; base_path] in
      let words = diagnostic_words output in
      check bool ("--base-path " ^ base_path ^ " refuses the record: " ^ output) true
        (status <> Unix.WEXITED 0);
      check bool ("--base-path " ^ base_path ^ " reads the served store: " ^ output) true
        (String_util.contains_substring words "lane-addon exact requests rows=1 refused=1"
         && String_util.contains_substring words (Filename.basename path)
         && String_util.contains_substring words (Filename.basename link)))
      [Filename.concat base ".masc/"; Filename.concat base "./"; alias]))

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
  let refusals = unchanged root (fun () ->
    expect_refusals P.Store.Tool_request_owners ~base_path:base ~rows:6
      [path "without-body", P.Tool_request_owner; path "v2", P.Tool_request_owner;
       path "v1", P.Tool_request_owner; path "v3", P.Tool_request_owner; stray, P.Tool_request_inventory]) in
  let scope = [Filename.dirname (path "current"); Filename.dirname body] in
  check (list (list string)) "fresh state deletes the whole scope, records and bodies"
    (List.map (fun _ -> scope) refusals)
    (List.map (fun (r : P.refusal) -> r.delete) refusals);
  check string "the fresh-state line names both scope directories"
    (Printf.sprintf "stop the server, delete %s and %s, start the new build"
       (Filename.dirname (path "current")) (Filename.dirname body))
    (P.fresh_state_step (List.hd refusals)))


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

let test_body_reuse_observes_current_bytes () =
  let module Reader=Lane_addon_tool_request_owner.Published_reader in
  let scope="scope" in
  let request_digest=Lane_addon_store.digest owner_request_bytes in
  let current=ref (Ok (Some owner_request_bytes)) and reads=ref 0 in
  let reader=Reader.create ~read_body:(fun ~scope:read_scope ~request_digest:read_digest ->
    incr reads;
    if read_scope=scope && read_digest=request_digest then !current else Ok None) in
  let request ()=Reader.request reader ~scope ~request_digest in
  let first=Result.get_ok (request ()) in
  (* A fresh string containing identical bytes can reuse the checked JSON,
     but must still go through the current read port. *)
  current:=Ok (Some (Bytes.to_string (Bytes.of_string owner_request_bytes)));
  let again=Result.get_ok (request ()) in
  check bool "unchanged bytes reuse the verified request" true (first==again);
  check int "reuse still reads current bytes" 2 !reads;
  List.iter (fun observed ->
    current:=observed;
    check bool "a previous success cannot mask changed/missing/unreadable bytes" true
      (Result.is_error (request ())))
    [Ok (Some "{\"query\":\"changed\"}");Ok None;Error "fixture read failure"];
  current:=Ok (Some owner_request_bytes);
  check bool "a recovered body is checked again" true (Result.is_ok (request ()));
  check bool "another scope cannot borrow the checked body" true
    (Result.is_error (Reader.request reader ~scope:"other" ~request_digest))

let test_body_changed_between_records_is_refused () =
  List.iter (fun remove -> with_lane_store (fun base root ->
    let scope="scope" in
    let request_digest=Lane_addon_store.digest owner_request_bytes in
    let body=Filename.concat root (Lane_addon_store.tool_request_body_path ~scope ~request_digest) in
    Fs_compat.mkdir_p (Filename.dirname body);
    write body owner_request_bytes;
    List.iter (fun request_id ->
      put (grouped root Lane_addon_store.tool_request_owners_directory ~group:scope ~id:request_id)
        (tool_request_owner ~scope ~request_id ~schema:"lane.addon.tool-request-owner.v4" ~request_digest))
      ["first";"second"];
    let reads=ref 0 in
    let after_read _ =
      incr reads;
      if !reads=2 then (if remove then Sys.remove body else write body "{}") in
    match P.For_testing.scan ~after_read P.Store.Tool_request_owners ~base_path:base with
    | Error detail -> fail detail
    | Ok report ->
      check int "both remaining records are checked" 2 report.P.rows;
      check int "changed body cannot borrow the first record's verdict" 1 (List.length report.P.refusals)))
    [false;true]

(* A record a check reads again from the bytes it was decoded from is the
   record decoded then, so the check can tell a parent that reads the same by
   identity. The record and its body are still read each time: the same bytes
   written again give the same record, a changed record is read anew, and a
   record whose body is gone is refused. *)
let test_a_record_read_again_from_the_same_bytes_is_the_same_record () = with_lane_store (fun base root ->
  let scope="scope" in
  let path id = grouped root Lane_addon_store.tool_request_owners_directory ~group:scope ~id in
  let request_digest=Lane_addon_store.digest owner_request_bytes in
  let body=Filename.concat root (Lane_addon_store.tool_request_body_path ~scope ~request_digest) in
  Fs_compat.mkdir_p (Filename.dirname body);
  write body owner_request_bytes;
  let owner ~request_id = tool_request_owner ~scope ~request_id ~schema:"lane.addon.tool-request-owner.v4" ~request_digest in
  let parent = owner ~request_id:"parent" in
  let summarized = match parent with
    | `Assoc fields -> `Assoc (List.map (fun (key, value) ->
        key, if String.equal key "summary" then `String "another summary" else value) fields)
    | json -> json in
  put (path "parent") parent;
  put (path "checked") (owner ~request_id:"checked");
  let reads = ref None in
  let validate () ~read ~read_scope:_ ~read_records:_ ~read_body:_ ~read_archive:_ ~read_fence:_ ~read_resolution:_ ~read_exact:_
      (original : P.original) =
    match original.restore () with
    | Error detail -> P.Body_unreadable detail
    | Ok record ->
    if String.equal record.request_id "checked" then begin
      let read_parent () = match read ~scope ~request_id:"parent" with
        | Ok (Some parent) -> Ok parent
        | Ok None -> Error "the parent is absent"
        | Error detail -> Error detail in
      let first = read_parent () in
      let again = read_parent () in
      put (path "parent") parent;
      let rewritten = read_parent () in
      put (path "parent") summarized;
      let changed = read_parent () in
      Sys.remove body;
      let without_body = read_parent () in
      write body owner_request_bytes;
      reads := Some (first, again, rewritten, changed, without_body)
    end;
    P.Payload_valid in
  match P.scan ~validate_tool_request:validate P.Store.Tool_request_owners ~base_path:base with
  | Error detail -> fail detail
  | Ok report ->
    check int "both records are checked" 2 report.P.rows;
    check int "and none is refused" 0 (List.length report.P.refusals);
    let read = function Ok value -> value | Error detail -> fail detail in
    match !reads with
    | None -> fail "the check never read the parent"
    | Some (first, again, rewritten, changed, without_body) ->
      let first = read first in
      check bool "a second read of unchanged bytes is the same record" true (read again == first);
      check bool "the same bytes written again are the same record" true (read rewritten == first);
      let changed = read changed in
      check bool "a changed record is read anew" true
        (changed != first && Yojson.Safe.equal changed.summary (`String "another summary"));
      check bool "a record whose body is gone is refused" true (Result.is_error without_body))

(* The deploy gate itself: a refused Lane Add-on record stops validate-stores. *)
let test_lane_addon_record_refuses_deploy exe () = with_lane_store (fun base root ->
  let path = grouped root Lane_addon_store.actions_directory ~group:"instance" ~id:"string-executor" in
  put path (receipt ~instance_id:"instance" ~request_id:"string-executor" ~executor:(`String "docker"));
  let status, output = unchanged root (fun () -> invoke exe base) in
  check bool ("an undecodable Lane Add-on record refuses deployment: " ^ output) true
    (status <> Unix.WEXITED 0);
  check bool ("the refusal names the file: " ^ output) true
    (String_util.contains_substring (diagnostic_words output) (diagnostic_words path)))

let require = function Ok value -> value | Error detail -> fail detail
let unchanged_workspace base f =
  let state ()=tree base |> List.filter (fun (path,_) ->
    path<>Filename.concat base "stdout" && path<>Filename.concat base "stderr") in
  let before=state () in
  let result=f () in
  check (list (pair string string)) "preflight changes no workspace state, epoch, receipt or ACK" before (state ());
  result

let with_memory_workspace f = with_workspace (fun base _keepers _traces ->
  let config = Filename.concat base ".masc/config" in
  let keepers_dir = Filename.concat config "keepers" in
  Fs_compat.mkdir_p keepers_dir;
  let previous = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" config;
  Fun.protect
    ~finally:(fun () -> Unix.putenv "MASC_CONFIG_DIR" (Option.value previous ~default:""))
    (fun () ->
      check string "Memory fixture uses its own config" keepers_dir
        (Config_dir_resolver.keepers_dir_for_base_path ~base_path:base);
      f base keepers_dir))

let memory_preflight base =
  let module D = Keeper_durable_store in
  let scan = match D.preflight_scan D.Id.Memory_current with
    | Some scan -> scan
    | None -> fail "Memory current has no deployment scan" in
  D.run scan ~base_path:base |> require

let test_memory_publication_preflight exe () = with_memory_workspace (fun base keepers_dir ->
  let module Current = Keeper_memory_os_current in
  let module Types = Keeper_memory_os_types in
  let source = {Current.kind = Current.Explicit_write; trace_id = "preflight"} in
  let fact claim = Types.observed ~claim ~category:Types.Fact ~now:10.
    ~origin:{kind=Types.Authored; trace_id="preflight"} in
  let old = fact "previous memory" and next = fact "next memory" in
  let cases =
    ["first-before", true, false; "first-after", true, true;
     "later-before", false, false; "later-after", false, true] in
  List.iter (fun (keeper_id, first, _) ->
    if not first then
      ignore (Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
        ~now:20. ~source ~facts:[old] () |> require)) cases;
  let wakes = ref [] in
  let unsubscribe = Keeper_memory_commit_notifications.subscribe (fun event ->
    wakes := (event.keeper_id, event.revision) :: !wakes) in
  Fun.protect ~finally:unsubscribe (fun () ->
    List.iter (fun (keeper_id, first, after_rename) ->
      let write_snapshot path content =
        Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
          ~sync_file:(fun _ -> if not after_rename then failwith "before rename")
          ~sync_parent:(fun _ -> failwith "after rename") path content in
      (match Current.For_testing.replace_with_publication_io
        ~on_committed:(fun _ _ -> ()) ~before_journal:(fun () -> ())
        ~write_snapshot ~sync_snapshot:(fun _ -> Error "durability unconfirmed")
        ~keepers_dir ~keeper_id ~now:30. ~source ~facts:[next] with
       | Error _ -> () | Ok _ -> fail "injected publication fault was hidden");
      check bool "pending receipt exists" true
        (Sys.file_exists (Current.publication_receipt_path ~keepers_dir ~keeper_id));
      check bool "snapshot existence reflects the interruption point"
        (after_rename || not first)
        (Sys.file_exists (Current.path_for_keepers_dir ~keepers_dir ~keeper_id))) cases;
    check (list (pair string int)) "interrupted publications sent no wake" [] !wakes;
    let linked_receipt = Current.publication_receipt_path ~keepers_dir ~keeper_id:"first-after" in
    let receipt_target = linked_receipt ^ ".fixture" in
    Sys.rename linked_receipt receipt_target;
    Unix.symlink (Filename.basename receipt_target) linked_receipt;
    let report = unchanged_workspace base (fun () -> memory_preflight base) in
    check int "each pending publication is inventoried" 4 report.rows;
    check int "valid pending receipts are not decode failures" 0 report.refused;
    check int "each publication awaits owner recovery" 4 (List.length report.pending_recovery);
    check (list (pair string int)) "in-process preflight sends no wake" [] !wakes;
    let status, output = unchanged_workspace base (fun () -> invoke exe base) in
    check bool ("the helper holds pending publications: " ^ output) true (status <> Unix.WEXITED 0);
    List.iter (fun (keeper_id, _, _) ->
      check bool ("helper identifies " ^ keeper_id) true
        (String_util.contains_substring output
          (Current.publication_receipt_path ~keepers_dir ~keeper_id))) cases;
    check bool "helper distinguishes pending from refused" true
      (String_util.contains_substring (diagnostic_words output)
        "0 refused row(s), 4 pending publication(s)");
    Unix.unlink linked_receipt;
    Sys.rename receipt_target linked_receipt;
    List.iter (fun (keeper_id, first, after_rename) ->
      let recovered = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require in
      let expected = if after_rename then Some [next] else if first then None else Some [old] in
      check bool "the owner can recover the untouched publication" true
        (Option.map (fun (snapshot : Current.t) -> snapshot.facts) recovered = expected);
      check bool "owner recovery completes the receipt" false
        (Sys.file_exists (Current.publication_receipt_path ~keepers_dir ~keeper_id))) cases;
    check (list (pair string int)) "only owner recovery dispatches committed wakes"
      ["first-after", 1; "later-after", 2]
      (List.sort compare !wakes);
    let linked_snapshot = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"later-after" in
    let snapshot_target = linked_snapshot ^ ".fixture" in
    Sys.rename linked_snapshot snapshot_target;
    Unix.symlink (Filename.basename snapshot_target) linked_snapshot;
    let report = unchanged_workspace base (fun () -> memory_preflight base) in
    check int "the linked snapshot remains in the inventory" 3 report.rows;
    check int "a regular snapshot symlink is readable" 0 report.refused;
    check int "completed publications no longer hold deployment" 0 (List.length report.pending_recovery)))

let test_bad_memory_publication_preflight exe () = with_memory_workspace (fun base keepers_dir ->
  let path = Keeper_memory_os_current.publication_receipt_path ~keepers_dir ~keeper_id:"broken" in
  write path "{broken";
  let report = unchanged_workspace base (fun () -> memory_preflight base) in
  check int "receipt-only owner is inventoried" 1 report.rows;
  check int "malformed receipt is refused" 1 report.refused;
  check int "malformed receipt is not a valid pending publication" 0 (List.length report.pending_recovery);
  let status, output = unchanged_workspace base (fun () -> invoke exe base) in
  check bool ("malformed receipt stops deployment: " ^ output) true (status <> Unix.WEXITED 0);
  check bool "refusal identifies the receipt" true (String_util.contains_substring output path))

let test_pending_memory_notification_preflight exe () = with_memory_workspace (fun base keepers_dir ->
  let module Current = Keeper_memory_os_current in
  let module Types = Keeper_memory_os_types in
  let keeper_id = "notification" in
  let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let receipt = Current.publication_receipt_path ~keepers_dir ~keeper_id in
  let fact = Types.observed ~claim:"memory with a pending wake" ~category:Types.Fact ~now:10.
    ~origin:{kind=Types.Authored; trace_id="preflight"} in
  Unix.mkdir journal 0o700;
  let source = {Current.kind = Current.Explicit_write; trace_id = "preflight"} in
  ignore (Current.replace ~keepers_dir ~keeper_id ~expected_revision:None ~now:20.
    ~source ~facts:[fact] () |> require);
  check bool "journal failure leaves a publication" true (Sys.file_exists receipt);
  Unix.rmdir journal;
  let cancel = Keeper_memory_commit_notifications.subscribe (fun _ ->
    raise (Eio.Cancel.Cancelled (Failure "interrupt notification"))) in
  Fun.protect ~finally:cancel (fun () ->
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
    | exception Eio.Cancel.Cancelled _ -> ()
    | Ok _ | Error _ -> fail "fixture did not interrupt notification");
  check string "fixture reached notification-pending phase" "notification_pending"
    Yojson.Safe.Util.(Yojson.Safe.from_file receipt |> member "phase" |> to_string);
  let wakes = ref 0 in
  let unsubscribe = Keeper_memory_commit_notifications.subscribe (fun _ -> incr wakes) in
  Fun.protect ~finally:unsubscribe (fun () ->
    let report = unchanged_workspace base (fun () -> memory_preflight base) in
    check int "notification remains pending" 1 (List.length report.pending_recovery);
    check int "pending notification is not malformed" 0 report.refused;
    let status, output = unchanged_workspace base (fun () -> invoke exe base) in
    check bool ("pending notification stops deployment: " ^ output) true (status <> Unix.WEXITED 0);
    check int "preflight did not dispatch the wake" 0 !wakes;
    ignore (Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require);
    check int "owner resumes the pending wake" 1 !wakes;
    check bool "owner completed the publication" false (Sys.file_exists receipt)))

let test_special_memory_paths_preflight exe () = with_memory_workspace (fun base keepers_dir ->
  let module Current = Keeper_memory_os_current in
  let broken_parent = Filename.concat base "broken-parent" in
  Unix.symlink "missing-parent" broken_parent;
  check bool "a broken inventory ancestor is not an empty store" true
    (Result.is_error (Current.list_preflight_keeper_ids
      ~keepers_dir:(Filename.concat broken_parent "keepers")));
  let receipt keeper_id = Current.publication_receipt_path ~keepers_dir ~keeper_id in
  Unix.mkfifo (receipt "a-fifo") 0o600;
  Unix.symlink "missing-target" (receipt "b-dangling");
  Unix.mkfifo (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"c-snapshot-fifo") 0o600;
  let status, output = unchanged_workspace base (fun () ->
    invoke_with_args ~timeout:30. exe base ["validate-stores"; "--base-path"; base]) in
  check bool ("special paths stop deployment: " ^ output) true (status <> Unix.WEXITED 0);
  check bool "all special paths are refused" true
    (String_util.contains_substring output "memory OS current snapshot rows=3 refused=3");
  check bool "the first refusal identifies the FIFO" true
    (String_util.contains_substring output (receipt "a-fifo")))

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
      test_case "the number of scan jobs does not change the report" `Quick
        (test_scan_jobs_do_not_change_the_report exe);
      test_case "zero scan jobs are refused" `Quick (test_zero_scan_jobs_are_refused exe);
      test_case "tool outbox receipts are read before rollout" `Quick
        (test_tool_outbox_receipts exe);
      test_case "a reaction ledger row once-only wakes refuse stops rollout" `Quick
        (test_reaction_ledger_refusal exe);
      test_case "reaction ledgers are read before rollout" `Quick
        (test_reaction_ledger_reads exe);
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
      test_case "body reuse observes current bytes" `Quick test_body_reuse_observes_current_bytes;
      test_case "a body changed between records is refused" `Quick test_body_changed_between_records_is_refused;
      test_case "a record read again from the same bytes is the same record" `Quick
        test_a_record_read_again_from_the_same_bytes_is_the_same_record;
      test_case "a record settled while it is checked is absent" `Quick
        test_a_record_settled_while_it_is_checked_is_absent;
      test_case "a refused record stops validate-stores" `Quick
        (test_lane_addon_record_refuses_deploy exe);
      test_case "--base-path forms read the store the server serves" `Quick
        (test_base_path_forms_read_the_served_store exe)];
     "Memory publication preflight",
     [test_case "preserves each interrupted publication for its owner" `Quick
        (test_memory_publication_preflight exe);
      test_case "refuses malformed receipt without a snapshot" `Quick
        (test_bad_memory_publication_preflight exe);
      test_case "preserves a pending notification for its owner" `Quick
        (test_pending_memory_notification_preflight exe);
      test_case "refuses FIFO and dangling paths without blocking" `Quick
        (test_special_memory_paths_preflight exe)]]
