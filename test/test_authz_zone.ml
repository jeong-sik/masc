(* Checks for the writer zone of the authorization log ([Authz_zone]): what a
   commit leaves in both files, what a restart reads from them, and what each
   refusal and failure leaves behind. Every case starts from the files that the
   real bootstrap writes, in a fresh temporary directory. The cases with a
   second process start this executable again (see [hold_lock_child_flag]). *)

open Authz_types
open Authz_records
module B = Authz_bootstrap
module H = Authz_high_water
module L = Authz_log
module M = Authz_mode_event
module R = Authz_record
module S = Authz_external_store
module Z = Authz_zone

(* The child of [with_foreign_lock]: takes the lock file the way [Fs_compat]
   does, says so, and holds the lock until its input closes. *)
let hold_lock_child_flag = "--hold-store-lock"

let () =
  if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) hold_lock_child_flag
  then (
    let fd = Unix.openfile Sys.argv.(2) [ Unix.O_WRONLY ] 0o600 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        output_char stdout 'R';
        flush stdout;
        try ignore (input_char stdin) with
        | End_of_file -> ());
    exit 0)
;;

(* ---- fixtures ---- *)

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let workspace = get (Authz_types.Workspace_id.of_string "workspace-1")
let other_workspace = get (Authz_types.Workspace_id.of_string "workspace-2")
let user = Author.Authenticated (Principal.Human (get (User_id.of_string "alice")))
let at_ms = 1_700_000_000_000

(* The clock of every zone that this file opens from paths. A case sets it
   to the time of a {!timed} when it calls the commit, and the zone reads it
   once it holds its locks. Fibers that wait on the locks may move it between
   the two, so their records can get the time of a later fiber. *)
let clock = ref at_ms
let now_ms () = !clock

(* A draft, and what the clock is set to when it is committed. *)
type timed =
  { at_ms : int
  ; draft : Z.draft
  }

let timed ~at_ms ~author ~kind body = { at_ms; draft = { Z.author; kind; body } }
let with_author author timed = { timed with draft = { timed.draft with Z.author } }
let on = Authz_mode_state.Multi_account workspace
let off = Authz_mode_state.Off workspace

let mode_body ?(workspace_id = workspace) event =
  match M.to_body { M.event; workspace_id } with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

(* A mode event from the host-local operator, its only writer (design 6.3). *)
let mode_draft ?(at_ms = at_ms + 1) ?workspace_id event =
  timed ~at_ms ~author:Author.Local_operator ~kind:R.Kind.Mode_event (mode_body ?workspace_id event)
;;

let grant_body =
  match Authz_body.of_yojson (`Assoc [ "n", `Int 1 ]) with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

(* The record that a commit of [draft] at [head] builds. *)
let record_at ~head { at_ms; draft } =
  match R.make ~head ~at_ms ~author:draft.Z.author ~kind:draft.Z.kind ~body:draft.Z.body with
  | Ok record -> record
  | Error (R.Author_not_admitted _) -> Alcotest.fail "fixture author not admitted"
;;

(* The intent that a commit of [draft] at [head] writes. *)
let intent_of ~head draft event : S.intent =
  { S.previous_record_hash = R.head_hash head
  ; intended_next_record_digest = (record_at ~head draft).R.hash
  ; change = S.Change.Mode { event; workspace_id = workspace }
  }
;;

(* ---- directories and files ---- *)

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

type dirs =
  { base : string
  ; config : string
  ; store_file : string
  }

(* The zones are [Eio.Mutex]es, so every case runs in an event loop. Temporary
   directories are made 0700, which the owner check of the install record
   needs. *)
let with_dirs f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-zone-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        f
          { base
          ; config = Filename.concat root "config"
          ; store_file = Filename.concat (Filename.concat root "store") "external.jsonl"
          }))
;;

let log_file dirs = L.path_of_base_path ~base_path:dirs.base
let read_file path = In_channel.with_open_bin path In_channel.input_all
let files dirs = read_file (log_file dirs), read_file dirs.store_file

let check_files label before dirs =
  Alcotest.(check (pair string string)) label before (files dirs)
;;

let skip_for_superuser () = if Unix.geteuid () = 0 then Alcotest.skip ()

let rec make_dirs path =
  if not (Sys.file_exists path)
  then (
    make_dirs (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

(* Cuts the last line of a file, as a process that stopped before it wrote
   that line. *)
let drop_last_line path =
  let text = read_file path in
  let body = String.sub text 0 (String.length text - 1) in
  Unix.truncate
    path
    (match String.rindex_opt body '\n' with
     | Some index -> index + 1
     | None -> 0)
;;

let count_lines text = List.length (String.split_on_char '\n' text) - 1

let bootstrap dirs =
  match
    B.fresh_bootstrap
      { B.base_path = dirs.base
      ; config_dir = Some dirs.config
      ; external_store = dirs.store_file
      ; workspace_id = workspace
      ; now_ms = (fun () -> at_ms)
      }
  with
  | Ok completed -> completed
  | Error error -> Alcotest.failf "bootstrap refused: %s" (B.error_to_string error)
;;

(* Both files, opened the way a start opens them. *)
type opened =
  { store : S.t
  ; store_state : S.State.t
  ; log : L.t
  ; replay : Z.Replay.t
  }

let open_files dirs =
  let store, store_state =
    match S.open_at_start ~path:dirs.store_file ~init:S.State.empty ~step:S.apply with
    | Ok (store, state, _recovered) -> store, state
    | Error error ->
      Alcotest.failf "store not opened: %s" (S.open_error_to_string S.violation_to_string error)
  in
  match
    L.open_at_start ~path:(log_file dirs) ~init:(Z.Replay.init store_state) ~step:Z.Replay.step
  with
  | Ok (log, replay, _recovered) -> { store; store_state; log; replay = Z.Replay.finish replay }
  | Error error ->
    Alcotest.failf "log not opened: %s" (L.open_error_to_string Authz_state.refusal_to_string error)
;;

let open_error_name : Z.open_error -> string = function
  | Z.Store_not_opened _ -> "Store_not_opened"
  | Z.Log_not_opened _ -> "Log_not_opened"
  | Z.Not_bootstrapped _ -> "Not_bootstrapped"
  | Z.Log_not_checked _ -> "Log_not_checked"
  | Z.Store_not_there _ -> "Store_not_there"
  | Z.Store_not_checked _ -> "Store_not_checked"
;;

let open_zone dirs =
  match Z.open_at_start ~now_ms ~log_path:(log_file dirs) ~store_path:dirs.store_file with
  | Ok zone -> zone
  | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
;;

(* Writes through a handle that is not the zone's: another part of this
   process, or a process that ran before this one. *)
let write_store_outside opened entries =
  match S.with_writer opened.store (fun writer _state -> S.append writer entries) with
  | Ok (Ok (_ : S.State.t)) -> ()
  | Ok (Error error) -> Alcotest.failf "store append refused: %s" (S.append_error_to_string error)
  | Error stop -> Alcotest.failf "the store is stopped: %s" stop.S.reason
;;

let append_log_outside opened records =
  match L.with_writer opened.log (fun writer _head -> L.append writer records) with
  | Ok (Ok (_ : R.head)) -> ()
  | Ok (Error error) -> Alcotest.failf "log append refused: %s" (L.append_error_to_string error)
  | Error stop -> Alcotest.failf "the log is stopped: %s" stop.L.reason
;;

(* ---- a lock that another process holds ---- *)

let with_foreign_lock ~lock_path f =
  (* Close-on-exec, so that the child does not inherit the write end of the
     release pipe and the parent's close of it can reach the child as EOF. *)
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  let release_read, release_write = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process
      Sys.executable_name
      [| Sys.executable_name; hold_lock_child_flag; lock_path |]
      release_read
      ready_write
      Unix.stderr
  in
  Unix.close ready_write;
  Unix.close release_read;
  let released = ref false in
  let release () =
    if not !released
    then (
      released := true;
      Fun.protect
        ~finally:(fun () -> Unix.close release_write)
        (fun () ->
          if Unix.write_substring release_write "X" 0 1 <> 1
          then Alcotest.fail "the release byte was not written"))
  in
  let rec wait_for_child () =
    match Unix.waitpid [] pid with
    | result -> result
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
  in
  Fun.protect
    ~finally:(fun () ->
      release ();
      ignore (wait_for_child () : int * Unix.process_status))
    (fun () ->
      let ready = Bytes.create 1 in
      let count = Unix.read ready_read ready 0 1 in
      Unix.close ready_read;
      if count <> 1 || Bytes.get ready 0 <> 'R'
      then Alcotest.fail "the lock holder did not start";
      f release)
;;

(* ---- names, so that a new constructor fails to compile here ---- *)

let log_append_error_name : L.append_error -> string = function
  | L.Writer_expired -> "Writer_expired"
  | L.Stopped _ -> "Stopped"
  | L.Rejected _ -> "Rejected"
  | L.Would_not_read_back _ -> "Would_not_read_back"
  | L.Read_back_changed _ -> "Read_back_changed"
  | L.Write_locked _ -> "Write_locked"
  | L.Diverged _ -> "Diverged"
  | L.Write_failed _ -> "Write_failed"
;;

let end_error_name : L.end_error -> string = function
  | L.End_writer_expired -> "End_writer_expired"
  | L.End_stopped _ -> "End_stopped"
  | L.End_locked _ -> "End_locked"
  | L.End_moved _ -> "End_moved"
  | L.End_not_one_file _ -> "End_not_one_file"
  | L.End_unread _ -> "End_unread"
;;

let store_append_error_name : S.append_error -> string = function
  | S.Writer_expired -> "Writer_expired"
  | S.Stopped _ -> "Stopped"
  | S.Rejected _ -> "Rejected"
  | S.Would_not_read_back _ -> "Would_not_read_back"
  | S.Read_back_changed _ -> "Read_back_changed"
  | S.Write_locked _ -> "Write_locked"
  | S.Diverged _ -> "Diverged"
  | S.Write_failed _ -> "Write_failed"
;;

let reason_name : H.reason -> string = function
  | H.Digest_differs _ -> "Digest_differs"
  | H.Commit_not_in_log _ -> "Commit_not_in_log"
  | H.Intent_unplaced _ -> "Intent_unplaced"
  | H.Answers_differ _ -> "Answers_differ"
;;

let reasons_name first rest = String.concat "," (List.map reason_name (first :: rest))

let judgment_name = function
  | H.Absent -> "Absent"
  | H.Matches -> "Matches"
  | H.Mismatch (first, rest) -> "Mismatch " ^ reasons_name first rest
;;

let refusal_name : Authz_state.refusal -> string = function
  | Authz_state.Before_bootstrap _ -> "Before_bootstrap"
  | Authz_state.Mode_event_unreadable _ -> "Mode_event_unreadable"
  | Authz_state.Mode _ -> "Mode"
  | Authz_state.Invite_unreadable _ -> "Invite_unreadable"
  | Authz_state.Invite _ -> "Invite"
  | Authz_state.Admission_unreadable _ -> "Admission_unreadable"
  | Authz_state.Admission _ -> "Admission"
  | Authz_state.Revocation_pending _ -> "Revocation_pending"
  | Authz_state.Admin_assignment_unreadable _ -> "Admin_assignment_unreadable"
  | Authz_state.Admin_assignment _ -> "Admin_assignment"
  | Authz_state.Principal_unreadable _ -> "Principal_unreadable"
  | Authz_state.Principal_event _ -> "Principal_event"
  | Authz_state.Author_inactive _ -> "Author_inactive"
  | Authz_state.Accounts_off kind -> "Accounts_off " ^ R.Kind.to_string kind
  | Authz_state.Kind_not_read kind -> "Kind_not_read " ^ R.Kind.to_string kind
  | Authz_state.Admission_behind_log _ -> "Admission_behind_log"
  | Authz_state.Closes_without_reduction -> "Closes_without_reduction"
  | Authz_state.Closes_not_held _ -> "Closes_not_held"
  | Authz_state.Cancel_unreadable _ -> "Cancel_unreadable"
  | Authz_state.Canceller_is_not_an_admin _ -> "Canceller_is_not_an_admin"
  | Authz_state.Cancel_not_held _ -> "Cancel_not_held"
  | Authz_state.Cancel_subject_differs _ -> "Cancel_subject_differs"
  | Authz_state.Canceller_owns_the_subject _ -> "Canceller_owns_the_subject"
  | Authz_state.Cancel_owner_unknown _ -> "Cancel_owner_unknown"
  | Authz_state.Registration_unreadable _ -> "Registration_unreadable"
  | Authz_state.Registration _ -> "Registration"
  | Authz_state.Session_unreadable _ -> "Session_unreadable"
  | Authz_state.Session _ -> "Session"
  | Authz_state.Pat_unreadable _ -> "Pat_unreadable"
  | Authz_state.Pat _ -> "Pat"
  | Authz_state.Service_credential_unreadable _ -> "Service_credential_unreadable"
  | Authz_state.Service_credential _ -> "Service_credential"
  | Authz_state.Provider_account_unreadable _ -> "Provider_account_unreadable"
  | Authz_state.Provider_account _ -> "Provider_account"
  | Authz_state.Runtime_unreadable _ -> "Runtime_unreadable"
  | Authz_state.Runtime _ -> "Runtime"
  | Authz_state.Keeper_unreadable _ -> "Keeper_unreadable"
  | Authz_state.Keeper _ -> "Keeper"
  | Authz_state.Purge_unreadable _ -> "Purge_unreadable"
  | Authz_state.Purge _ -> "Purge"
;;

let error_name : Z.error -> string = function
  | Z.Store_stopped _ -> "Store_stopped"
  | Z.Log_stopped _ -> "Log_stopped"
  | Z.Uncertain { first; rest } -> "Uncertain " ^ reasons_name first rest
  | Z.Store_holds_no_answer -> "Store_holds_no_answer"
  | Z.Log_holds_records { next_seq } -> Printf.sprintf "Log_holds_records %d" next_seq
  | Z.Abort_not_confirmed error -> "Abort_not_confirmed " ^ end_error_name error
  | Z.Store_entry_refused _ -> "Store_entry_refused"
  | Z.Settlement_not_written error -> "Settlement_not_written " ^ store_append_error_name error
  | Z.Record_not_built (R.Author_not_admitted _) -> "Record_not_built"
  | Z.Refused refusal -> "Refused " ^ refusal_name refusal
  | Z.Intent_not_written error -> "Intent_not_written " ^ store_append_error_name error
  | Z.Record_not_appended error -> "Record_not_appended " ^ log_append_error_name error
  | Z.Answer_not_written { error; record_hash = _ } ->
    "Answer_not_written " ^ store_append_error_name error
;;

let uncertain_name : Z.uncertain -> string = function
  | Z.Log_is_stopped _ -> "log stopped"
  | Z.Store_is_stopped _ -> "store stopped"
  | Z.Files_disagree _ -> "files disagree"
  | Z.Store_answers_nothing -> "store holds no answer"
;;

let intent_name (intent : S.intent) =
  Printf.sprintf
    "%s>%s %s"
    (R.Hash.to_hex intent.S.previous_record_hash)
    (R.Hash.to_hex intent.S.intended_next_record_digest)
    (S.Change.to_string intent.S.change)
;;

let settlement_name = function
  | H.Nothing_to_settle -> "Nothing_to_settle"
  | H.Promote intent -> "Promote " ^ intent_name intent
  | H.Abort intent -> "Abort " ^ intent_name intent
;;

(* ---- checks ---- *)

let commit zone { at_ms; draft } =
  clock := at_ms;
  Z.commit zone draft
;;

let commit_ok zone timed =
  match commit zone timed with
  | Ok committed -> committed
  | Error error -> Alcotest.failf "commit refused: %s" (Z.error_detail error)
;;

let check_error label expected zone timed =
  match commit zone timed with
  | Ok _ -> Alcotest.failf "%s: the commit succeeded" label
  | Error error -> Alcotest.(check string) label expected (error_name error)
;;

(* Whether a decision may rest on the zone. The published state is the same
   one either way, and only [read] says that a file stopped. *)
let check_decision label expected zone =
  Alcotest.(check string)
    label
    expected
    (match Z.read zone with
     | Ok (_ : Z.trusted) -> "trusted"
     | Error uncertain -> uncertain_name uncertain)
;;

let check_settled label expected (committed : Z.committed) =
  Alcotest.(check string) label expected (settlement_name committed.Z.settled)
;;

let check_snapshot label ~mode ~head (snapshot : Z.snapshot) =
  Alcotest.(check string)
    (label ^ ": mode")
    (Authz_mode_state.to_string mode)
    (Authz_mode_state.to_string snapshot.Z.state.Authz_state.mode);
  Alcotest.(check string)
    (label ^ ": head")
    (R.Hash.to_hex head)
    (R.Hash.to_hex (R.head_hash snapshot.Z.head))
;;

let check_judgment label dirs expected =
  let opened = open_files dirs in
  Alcotest.(check string) label expected (judgment_name (H.judge opened.replay.Z.Replay.probe))
;;

(* What a restart reads from both files: the mode, the head, and the judgment
   of the high-water mark. *)
let check_restart label dirs ~mode ~head =
  let opened = open_files dirs in
  let replay = opened.replay in
  Alcotest.(check string)
    (label ^ ": mode")
    (Authz_mode_state.to_string mode)
    (Authz_mode_state.to_string replay.Z.Replay.state.Authz_state.mode);
  Alcotest.(check string)
    (label ^ ": head")
    (R.Hash.to_hex head)
    (R.Hash.to_hex (R.head_hash replay.Z.Replay.head));
  Alcotest.(check string)
    (label ^ ": judgment")
    "Matches"
    (judgment_name (H.judge replay.Z.Replay.probe));
  opened
;;

let check_store label opened ~pending ~last_committed ~aborted =
  let state = opened.store_state in
  Alcotest.(check (option string))
    (label ^ ": pending")
    (Option.map intent_name pending)
    (Option.map intent_name (S.State.pending state));
  Alcotest.(check (option string))
    (label ^ ": last committed")
    (Some (R.Hash.to_hex last_committed))
    (Option.map R.Hash.to_hex (S.State.last_committed state));
  Alcotest.(check (list string))
    (label ^ ": aborted")
    (List.map intent_name aborted)
    (List.map intent_name (S.State.aborted state))
;;

(* ---- commits ---- *)

(* The second commit settles what the first one left, so it fails if the probe
   did not follow the first one through both files. *)
let commits_follow_one_another () =
  with_dirs (fun dirs ->
    let completed = bootstrap dirs in
    let zone = open_zone dirs in
    check_snapshot "after the bootstrap" ~mode:on ~head:completed.B.record_hash (Z.snapshot zone);
    let first = commit_ok zone (mode_draft ~at_ms:(at_ms + 1) M.Off) in
    check_settled "the first commit closes nothing" "Nothing_to_settle" first;
    check_snapshot "the answer" ~mode:off ~head:first.Z.record_hash first.Z.snapshot;
    check_snapshot "the published state" ~mode:off ~head:first.Z.record_hash (Z.snapshot zone);
    let second = commit_ok zone (mode_draft ~at_ms:(at_ms + 2) M.Reactivate) in
    check_settled "the second commit closes nothing" "Nothing_to_settle" second;
    check_snapshot "the state after two" ~mode:on ~head:second.Z.record_hash (Z.snapshot zone);
    let opened = check_restart "a restart" dirs ~mode:on ~head:second.Z.record_hash in
    check_store "a restart" opened ~pending:None ~last_committed:second.Z.record_hash ~aborted:[])
;;

(* Commits from fibers that run at once take turns in the zone. A fiber holds
   the zone while a write runs on a system thread, so the others start and
   wait. Each event goes in only if the one before it in the list went in
   first, so this test leans on what Eio does today and its interfaces do not
   promise: [Fiber.fork] runs the new fiber until it waits, and [Eio.Mutex]
   wakes fibers in the order they waited. A commit refused with [Refused Mode]
   after an Eio upgrade means that the order changed, not that the zone let
   two commits in at once. *)
let commits_from_fibers_take_turns () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let zone = open_zone dirs in
    let lines_before = count_lines (read_file (log_file dirs)) in
    let events = [ M.Off; M.Reactivate; M.Off; M.Reactivate; M.Off; M.Reactivate ] in
    let in_flight = ref 0 in
    let most_in_flight = ref 0 in
    let results =
      Eio.Fiber.List.map
        ~max_fibers:(List.length events)
        (fun (index, event) ->
          incr in_flight;
          most_in_flight := max !most_in_flight !in_flight;
          let result = commit zone (mode_draft ~at_ms:(at_ms + 1 + index) event) in
          decr in_flight;
          result)
        (List.mapi (fun index event -> index, event) events)
    in
    Alcotest.(check bool) "the commits ran at once" true (!most_in_flight > 1);
    let committed =
      List.map
        (function
          | Ok committed -> committed
          | Error error -> Alcotest.failf "a commit was refused: %s" (Z.error_detail error))
        results
    in
    Alcotest.(check int) "every commit went in" (List.length events) (List.length committed);
    Alcotest.(check int)
      "one record for each commit"
      (lines_before + List.length events)
      (count_lines (read_file (log_file dirs)));
    let last = List.nth committed (List.length committed - 1) in
    check_snapshot "the last commit" ~mode:on ~head:last.Z.record_hash (Z.snapshot zone);
    ignore (check_restart "a restart" dirs ~mode:on ~head:last.Z.record_hash : opened))
;;

(* ---- refusals ---- *)

let refused_records_write_nothing () =
  with_dirs (fun dirs ->
    let completed = bootstrap dirs in
    let zone = open_zone dirs in
    let before = files dirs in
    List.iter
      (fun (label, draft, expected) ->
        check_error label expected zone draft;
        check_files (label ^ ": both files are as they were") before dirs;
        check_snapshot label ~mode:on ~head:completed.B.record_hash (Z.snapshot zone))
      [ "a second bootstrap", mode_draft M.Fresh_bootstrap, "Refused Mode"
      ; "a reactivation while on", mode_draft M.Reactivate, "Refused Mode"
      ; "an off for another workspace", mode_draft ~workspace_id:other_workspace M.Off, "Refused Mode"
      ; "a mode event from a user", with_author user (mode_draft M.Off), "Record_not_built"
      ; ( "a grant, which no layer reads yet"
        , timed ~at_ms ~author:user ~kind:R.Kind.Runtime_grant grant_body
        , "Refused Kind_not_read " ^ R.Kind.to_string R.Kind.Runtime_grant )
      ];
    let next = commit_ok zone (mode_draft M.Off) in
    check_settled "a refusal leaves nothing to close" "Nothing_to_settle" next;
    ignore (check_restart "a restart" dirs ~mode:off ~head:next.Z.record_hash : opened))
;;

(* The first record of a log goes through [Z.install], once the install record
   names the store. A zone opened from paths does not open a log without it,
   and opens neither file while one of the two is not there. *)
let the_zone_opens_only_a_bootstrapped_log () =
  with_dirs (fun dirs ->
    let check_refused label expected =
      match Z.open_at_start ~now_ms ~log_path:(log_file dirs) ~store_path:dirs.store_file with
      | Ok (_ : Z.t) -> Alcotest.failf "%s: a zone was opened" label
      | Error error ->
        Alcotest.(check string) (label ^ ": the refusal") expected (open_error_name error)
    in
    let store_dir = Filename.dirname dirs.store_file in
    let empty_file path =
      Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 path ignore
    in
    check_refused "no log" "Not_bootstrapped";
    Alcotest.(check bool) "no log: no store directory" false (Sys.file_exists store_dir);
    Alcotest.(check bool)
      "no log: no log directory"
      false
      (Sys.file_exists (Filename.dirname (log_file dirs)));
    make_dirs (Filename.dirname (log_file dirs));
    empty_file (log_file dirs);
    check_refused "an empty log and no store" "Store_not_there";
    Alcotest.(check bool)
      "an empty log and no store: no store directory"
      false
      (Sys.file_exists store_dir);
    make_dirs store_dir;
    empty_file dirs.store_file;
    check_refused "an empty log" "Not_bootstrapped";
    Alcotest.(check string) "an empty log: the store" "" (read_file dirs.store_file);
    Alcotest.(check string) "an empty log: the log" "" (read_file (log_file dirs)))
;;

(* A log path that cannot be looked at is not taken for a log that is not
   there. *)
let a_log_that_cannot_be_checked_is_not_opened () =
  with_dirs (fun dirs ->
    (match Z.open_at_start ~now_ms ~log_path:(log_file dirs ^ "\000") ~store_path:dirs.store_file with
     | Ok (_ : Z.t) -> Alcotest.fail "a zone was opened"
     | Error error ->
       Alcotest.(check string) "the refusal" "Log_not_checked" (open_error_name error));
    Alcotest.(check bool)
      "no store directory"
      false
      (Sys.file_exists (Filename.dirname dirs.store_file)))
;;

(* A bootstrapped log reads [Matches] with its store. A store that holds no
   answer for it reads [Absent], which design 5.1 does not let a writer go on
   from. *)
let a_store_with_no_answer_refuses_every_commit () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    Unix.truncate dirs.store_file 0;
    check_judgment "what the files say" dirs "Absent";
    let zone = open_zone dirs in
    let log_before = read_file (log_file dirs) in
    check_decision "no decision rests on it" "store holds no answer" zone;
    check_error "a commit" "Store_holds_no_answer" zone (mode_draft M.Off);
    check_error "a commit, again" "Store_holds_no_answer" zone (mode_draft ~at_ms:(at_ms + 2) M.Off);
    Alcotest.(check string) "the log" log_before (read_file (log_file dirs));
    Alcotest.(check string) "the store" "" (read_file dirs.store_file);
    check_judgment "a restart" dirs "Absent")
;;

(* A store that is not there is not opened, whether its file or its whole
   directory is gone: opening it makes the directory and the lock file, and a
   volume that is mounted again finds its mount point as it left it. *)
let a_store_that_is_not_there_is_not_opened () =
  List.iter
    (fun (label, lose_the_store) ->
      with_dirs (fun dirs ->
        ignore (bootstrap dirs : B.completed);
        let store_dir = Filename.dirname dirs.store_file in
        lose_the_store dirs.store_file;
        let where_the_store_was () =
          if Sys.file_exists store_dir
          then Some (List.sort String.compare (Array.to_list (Sys.readdir store_dir)))
          else None
        in
        let before = where_the_store_was () in
        let log_before = read_file (log_file dirs) in
        (match Z.open_at_start ~now_ms ~log_path:(log_file dirs) ~store_path:dirs.store_file with
         | Ok (_ : Z.t) -> Alcotest.failf "%s: a zone was opened" label
         | Error error ->
           Alcotest.(check string) (label ^ ": the refusal") "Store_not_there" (open_error_name error));
        Alcotest.(check (option (list string)))
          (label ^ ": where the store was")
          before
          (where_the_store_was ());
        Alcotest.(check string) (label ^ ": the log") log_before (read_file (log_file dirs))))
    [ "the file is gone", Sys.remove
    ; "the directory is gone", (fun path -> remove_tree (Filename.dirname path))
    ]
;;

(* A store path that cannot be looked at is not taken for a store that is not
   there, and is not opened either. *)
let a_store_that_cannot_be_checked_is_not_opened () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    match Z.open_at_start ~now_ms ~log_path:(log_file dirs) ~store_path:(dirs.store_file ^ "\000") with
    | Ok (_ : Z.t) -> Alcotest.fail "a zone was opened"
    | Error error ->
      Alcotest.(check string) "the refusal" "Store_not_checked" (open_error_name error))
;;

(* ---- failures ---- *)

(* The seq of the newest line of the log ring. The first line of a ring has
   seq 0, and [Log.Ring.recent ~since_seq] gives the lines after a seq, so an
   empty ring answers the seq before the first one. *)
let latest_ring_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> -1
;;

(* The lines that the zone wrote about a commit that failed, after [since_seq]. *)
let failed_commit_lines ~since_seq =
  List.filter
    (fun (entry : Log.Ring.entry) ->
      String_util.contains_substring entry.message "was not committed to the authorization zone")
    (Log.Ring.recent ~limit:50 ~module_filter:"Auth" ~since_seq ())
;;

(* What a person is told of every failure of the zone. *)
let not_recorded = "The server could not finish recording this. Try again later."

(* The reason of a failure names paths of the server. The text a caller gives
   to a person has none, the detail has them, and the zone writes the detail
   to the log when the commit fails. A record that was turned down says why
   in both texts. *)
let a_failure_is_told_without_the_paths_of_the_server () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let zone = open_zone dirs in
    let root = Filename.dirname dirs.base in
    let names_a_path text = String_util.contains_substring text root in
    let before_the_refusal = latest_ring_seq () in
    (match commit zone (mode_draft M.Fresh_bootstrap) with
     | Ok (_ : Z.committed) -> Alcotest.fail "a second bootstrap was committed"
     | Error error ->
       Alcotest.(check string) "a record that was turned down" "Refused Mode" (error_name error);
       Alcotest.(check string)
         "it says why in both texts"
         (Z.error_detail error)
         (Z.error_to_string error));
    Alcotest.(check int)
      "a record that was turned down is not written to the log"
      0
      (List.length (failed_commit_lines ~since_seq:before_the_refusal));
    let other = open_files dirs in
    let head = other.replay.Z.Replay.head in
    append_log_outside other [ record_at ~head (mode_draft ~at_ms:(at_ms + 1) M.Off) ];
    let before_the_failure = latest_ring_seq () in
    (match commit zone (mode_draft ~at_ms:(at_ms + 2) M.Off) with
     | Ok (_ : Z.committed) -> Alcotest.fail "the commit wrote over a log that moved"
     | Error error ->
       Alcotest.(check string) "a failure" "Record_not_appended Diverged" (error_name error);
       Alcotest.(check string) "what a person is told" not_recorded (Z.error_to_string error);
       Alcotest.(check bool) "the detail names the log" true (names_a_path (Z.error_detail error)));
    (match failed_commit_lines ~since_seq:before_the_failure with
     | [ line ] ->
       Alcotest.(check bool) "the line of the zone names the log" true (names_a_path line.message)
     | lines ->
       Alcotest.failf "the zone wrote %d lines about the failed commit" (List.length lines));
    match Z.read zone with
    | Ok (_ : Z.trusted) -> Alcotest.fail "a decision rests on a log that stopped"
    | Error uncertain ->
      Alcotest.(check string)
        "why no decision rests on the zone"
        "the authorization log is stopped"
        (Z.uncertain_to_string uncertain);
      Alcotest.(check bool)
        "the detail names the log"
        true
        (names_a_path (Z.uncertain_detail uncertain)))
;;

(* Every error of the zone, built by hand, the failures around a path where
   they carry one. A failure tells a person the one sentence, and its detail
   has the path. A record that was turned down says the same in both texts.
   [Authz_zone] names every constructor where it tells the two apart, so the
   compiler asks about a new one there; this is where its texts are read. *)
let the_texts_of_each_error () =
  let path = "/srv/masc-under-test/.masc/auth/authz.jsonl" in
  let names_the_path text = String_util.contains_substring text path in
  let hash = R.head_hash R.genesis in
  let log_stop = { L.path; reason = "the file was replaced" } in
  let store_stop = { S.path; reason = "the file was replaced" } in
  let failures_around_a_path =
    [ Z.Store_stopped store_stop
    ; Z.Log_stopped log_stop
    ; Z.Abort_not_confirmed (L.End_moved { path })
    ; Z.Settlement_not_written (S.Write_failed { path; detail = "No space left on device" })
    ; Z.Intent_not_written (S.Write_locked { path })
    ; Z.Record_not_appended (L.Diverged { path })
    ; Z.Answer_not_written { record_hash = hash; error = S.Stopped store_stop }
    ]
  in
  let failures_without_a_path =
    [ Z.Uncertain { first = H.Commit_not_in_log hash; rest = [] }
    ; Z.Store_holds_no_answer
    ; Z.Store_entry_refused
        { entry = S.Committed { record_hash = hash }; violation = S.Committed_without_intent }
    ]
  in
  let turned_down =
    [ Z.Log_holds_records { next_seq = 1 }
    ; Z.Record_not_built (R.Author_not_admitted { kind = R.Kind.Mode_event; author = user })
    ]
  in
  List.iter
    (fun error ->
      Alcotest.(check string)
        (error_name error ^ ": what a person is told")
        not_recorded
        (Z.error_to_string error))
    (failures_around_a_path @ failures_without_a_path);
  List.iter
    (fun error ->
      Alcotest.(check bool)
        (error_name error ^ ": the detail names the path")
        true
        (names_the_path (Z.error_detail error)))
    failures_around_a_path;
  List.iter
    (fun error ->
      Alcotest.(check string)
        (error_name error ^ ": both texts say why")
        (Z.error_detail error)
        (Z.error_to_string error))
    turned_down
;;

let a_locked_store_writes_nothing_and_stops_nothing () =
  with_dirs (fun dirs ->
    let completed = bootstrap dirs in
    let zone = open_zone dirs in
    let before = files dirs in
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path dirs.store_file) (fun release ->
      check_error
        "a commit while another process holds the store"
        "Intent_not_written Write_locked"
        zone
        (mode_draft M.Off);
      release ());
    check_files "both files are as they were" before dirs;
    check_snapshot "the published state" ~mode:on ~head:completed.B.record_hash (Z.snapshot zone);
    let next = commit_ok zone (mode_draft ~at_ms:(at_ms + 2) M.Off) in
    check_settled "the intent that was not written is not closed" "Nothing_to_settle" next;
    ignore (check_restart "a restart" dirs ~mode:off ~head:next.Z.record_hash : opened))
;;

let a_locked_log_leaves_an_intent_that_the_next_commit_aborts () =
  with_dirs (fun dirs ->
    let completed = bootstrap dirs in
    let zone = open_zone dirs in
    let first = mode_draft ~at_ms:(at_ms + 1) M.Off in
    let left = intent_of ~head:(Z.snapshot zone).Z.head first S.Change.Off in
    let log_before = read_file (log_file dirs) in
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path (log_file dirs)) (fun release ->
      check_error
        "a commit while another process holds the log"
        "Record_not_appended Write_locked"
        zone
        first;
      release ());
    Alcotest.(check string) "the log is as it was" log_before (read_file (log_file dirs));
    check_snapshot "the published state" ~mode:on ~head:completed.B.record_hash (Z.snapshot zone);
    check_store
      "the store keeps the intent"
      (open_files dirs)
      ~pending:(Some left)
      ~last_committed:completed.B.record_hash
      ~aborted:[];
    let after_failure = files dirs in
    (* The intent stays until a commit gets past its first two steps. *)
    check_error
      "a refused commit with an intent left"
      "Refused Mode"
      zone
      (mode_draft ~at_ms:(at_ms + 2) M.Reactivate);
    check_files "the refused commit wrote nothing" after_failure dirs;
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path (log_file dirs)) (fun release ->
      check_error
        "a commit while another process holds the log again"
        "Abort_not_confirmed End_locked"
        zone
        (mode_draft ~at_ms:(at_ms + 3) M.Off);
      release ());
    check_files "the abort that was not confirmed wrote nothing" after_failure dirs;
    (* The superuser reads a file of mode 0000. *)
    if Unix.geteuid () <> 0
    then (
      Unix.chmod (log_file dirs) 0o000;
      Fun.protect
        ~finally:(fun () -> Unix.chmod (log_file dirs) 0o600)
        (fun () ->
          check_error
            "a commit while the log cannot be read"
            "Abort_not_confirmed End_unread"
            zone
            (mode_draft ~at_ms:(at_ms + 3) M.Off));
      check_files "the abort that was not read wrote nothing" after_failure dirs);
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path dirs.store_file) (fun release ->
      check_error
        "a commit while another process holds the store"
        "Settlement_not_written Write_locked"
        zone
        (mode_draft ~at_ms:(at_ms + 4) M.Off);
      release ());
    check_files "the settlement that failed wrote nothing" after_failure dirs;
    let next = commit_ok zone (mode_draft ~at_ms:(at_ms + 5) M.Off) in
    check_settled "the next commit gives the intent up first" ("Abort " ^ intent_name left) next;
    let opened = check_restart "a restart" dirs ~mode:off ~head:next.Z.record_hash in
    check_store "a restart" opened ~pending:None ~last_committed:next.Z.record_hash ~aborted:[ left ])
;;

(* ---- records with no intent ---- *)

module Invite_event = Authz_invite_event

let invite_id = get (Authz_types.Invite_id.of_string "invite-1")
let second_invite_id = get (Authz_types.Invite_id.of_string "invite-2")
let third_invite_id = get (Authz_types.Invite_id.of_string "invite-3")

(* Each member has a namespace of their own, so a draft names it after the
   identity of the member. *)
let zone_membership ~sub =
  { Authz_admission_event.workspace_id = workspace
  ; account_home_namespace = get (Account_home_namespace.of_string ("ns-" ^ sub))
  }
;;

let invite_draft
  ?(author = Author.Local_operator)
  ?(at_ms = at_ms + 1)
  ?(invite_id = invite_id)
  ?(token = "token-1")
  ()
  =
  let event =
    Invite_event.Issued
      { invite_id
      ; token_digest = Invite_event.Token_digest.of_token token
      ; expires_at_ms = at_ms + 1000
      ; role = Invite_event.Admin
      }
  in
  match Invite_event.to_body event with
  | Ok body -> timed ~at_ms ~author ~kind:R.Kind.Invite body
  | Error error -> Alcotest.failf "fixture invite refused: %s" (Authz_body.error_to_string error)
;;

let check_invitation_open label (snapshot : Z.snapshot) =
  match Authz_invite_state.find snapshot.Z.state.Authz_state.invites invite_id with
  | Some { Authz_invite_state.status = Authz_invite_state.Open; _ } -> ()
  | Some _ | None -> Alcotest.failf "%s: the invitation is not open" label
;;

(* An invitation changes no epoch, so the store takes nothing for it, and the
   next intent starts at the record of the invitation. *)
let an_invite_is_appended_with_no_intent () =
  with_dirs (fun dirs ->
    let completed = bootstrap dirs in
    let zone = open_zone dirs in
    let log_before, store_before = files dirs in
    let invite = commit_ok zone (invite_draft ()) in
    check_settled "nothing to close" "Nothing_to_settle" invite;
    let log_after, store_after = files dirs in
    Alcotest.(check string) "the store is as it was" store_before store_after;
    Alcotest.(check int)
      "the log has one more line"
      (count_lines log_before + 1)
      (count_lines log_after);
    check_snapshot "the answer" ~mode:on ~head:invite.Z.record_hash invite.Z.snapshot;
    check_invitation_open "the published state" (Z.snapshot zone);
    let opened = check_restart "a restart" dirs ~mode:on ~head:invite.Z.record_hash in
    check_invitation_open
      "the replay"
      { Z.state = opened.replay.Z.Replay.state; head = opened.replay.Z.Replay.head };
    check_store
      "the store after the invitation"
      opened
      ~pending:None
      ~last_committed:completed.B.record_hash
      ~aborted:[];
    let switched = commit_ok zone (mode_draft ~at_ms:(at_ms + 2) M.Off) in
    check_settled "the mode change after it closes nothing" "Nothing_to_settle" switched;
    let opened = check_restart "a restart after both" dirs ~mode:off ~head:switched.Z.record_hash in
    check_store "after both" opened ~pending:None ~last_committed:switched.Z.record_hash ~aborted:[])
;;

(* An append moves the head, so an intent that an earlier commit left is
   settled before the invitation is appended, as before any other record. *)
let an_invite_settles_the_intent_left_before_it () =
  with_dirs (fun dirs ->
    let completed = bootstrap dirs in
    let zone = open_zone dirs in
    let first = mode_draft ~at_ms:(at_ms + 1) M.Off in
    let left = intent_of ~head:(Z.snapshot zone).Z.head first S.Change.Off in
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path (log_file dirs)) (fun release ->
      check_error
        "a commit while another process holds the log"
        "Record_not_appended Write_locked"
        zone
        first;
      release ());
    let invite = commit_ok zone (invite_draft ~at_ms:(at_ms + 2) ()) in
    check_settled "the invitation gives the intent up first" ("Abort " ^ intent_name left) invite;
    let opened = check_restart "a restart" dirs ~mode:on ~head:invite.Z.record_hash in
    check_store
      "a restart"
      opened
      ~pending:None
      ~last_committed:completed.B.record_hash
      ~aborted:[ left ])
;;

let revoke_draft ~at_ms =
  match Invite_event.to_body (Invite_event.Revoked { invite_id }) with
  | Ok body -> timed ~at_ms ~author:Author.Local_operator ~kind:R.Kind.Invite body
  | Error error -> Alcotest.failf "fixture revocation refused: %s" (Authz_body.error_to_string error)
;;

(* A revocation closes what the token of the invitation opens, so the store
   holds its answer, and a log cut back to before it no longer matches the
   store: the invitation does not come back open on a restart. *)
let a_revoked_invite_has_an_intent () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let revoked = commit_ok zone (revoke_draft ~at_ms:(at_ms + 2)) in
    check_settled "nothing to close" "Nothing_to_settle" revoked;
    let opened = check_restart "a restart" dirs ~mode:on ~head:revoked.Z.record_hash in
    check_store "a restart" opened ~pending:None ~last_committed:revoked.Z.record_hash ~aborted:[];
    drop_last_line (log_file dirs);
    check_judgment "a log cut back to before the revocation" dirs "Mismatch Commit_not_in_log")
;;

(* An Admin admission raises the role epoch of the new principal, so it goes
   through the store as an intent and its answer, after the invitation, which
   did not. *)
let an_admin_admission_has_an_intent () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let person = get (User_id.of_string "0123456789abcdef0123456789abcdef") in
    let identity = get (Authz_external_identity.google ~sub:"111") in
    let body =
      match
        Authz_admission_event.to_body
          { Authz_admission_event.user_id = person
          ; identity
          ; through = Authz_admission_event.Invite invite_id
          ; membership = zone_membership ~sub:"111"
          }
      with
      | Ok body -> body
      | Error _ -> Alcotest.fail "fixture admission refused"
    in
    let draft =
      timed
        ~at_ms:(at_ms + 2)
        ~author:(Author.Authenticated (Principal.Human person))
        ~kind:R.Kind.Admission
        body
    in
    let admitted = commit_ok zone draft in
    check_settled "nothing to close" "Nothing_to_settle" admitted;
    Alcotest.(check bool)
      "the published state has the Admin"
      true
      (Authz_principal_state.is_admin admitted.Z.snapshot.Z.state.Authz_state.principals person);
    let opened = check_restart "a restart" dirs ~mode:on ~head:admitted.Z.record_hash in
    check_store "a restart" opened ~pending:None ~last_committed:admitted.Z.record_hash ~aborted:[];
    Alcotest.(check bool)
      "the replay has the Admin"
      true
      (Authz_principal_state.is_admin opened.replay.Z.Replay.state.Authz_state.principals person))
;;

let first_admin = get (User_id.of_string "0123456789abcdef0123456789abcdef")

let admission_draft_of ~person ~sub ~invite_id ~at_ms =
  let identity = get (Authz_external_identity.google ~sub) in
  match
    Authz_admission_event.to_body
      { Authz_admission_event.user_id = person
      ; identity
      ; through = Authz_admission_event.Invite invite_id
      ; membership = zone_membership ~sub
      }
  with
  | Ok body ->
    timed ~at_ms ~author:(Author.Authenticated (Principal.Human person)) ~kind:R.Kind.Admission body
  | Error _ -> Alcotest.fail "fixture admission refused"
;;

let admission_draft ~at_ms = admission_draft_of ~person:first_admin ~sub:"111" ~invite_id ~at_ms

(* The intent that a commit of the revocation [draft] at [head] writes. *)
let revocation_intent ?(subject = Subject.Invite invite_id) ~head draft : S.intent =
  { S.previous_record_hash = R.head_hash head
  ; intended_next_record_digest = (record_at ~head draft).R.hash
  ; change = S.Change.Authz { event = S.Change.Revoke; subject }
  }
;;

let check_blocked label expected (state : Authz_state.t) =
  Alcotest.(check (list string))
    label
    expected
    (List.map (fun held -> Subject.to_string held.Authz_state.subject) state.Authz_state.revocation_pending)
;;

(* What the gate reads for a subject: the state a decision may rest on, and
   in it the reduction that holds the subject. *)
let check_gate label expected zone subject =
  Alcotest.(check string)
    label
    expected
    (match Z.read zone with
     | Error uncertain -> uncertain_name uncertain
     | Ok trusted ->
       (match Authz_state.revocation (trusted :> Z.snapshot).Z.state subject with
        | Authz_records.Revocation_state.Pending -> "pending"
        | Authz_records.Revocation_state.Not_pending -> "clear"))
;;

(* A revocation whose append failed leaves its intent, and its invitation is
   blocked from that failure on (design 8.3): the gate reads it at once, the
   holder of the token does not get in, the next entry gives the intent up as
   the same block, and a replay keeps it. *)
let an_aborted_revocation_blocks_its_invitation () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let revoke = revoke_draft ~at_ms:(at_ms + 2) in
    let left = revocation_intent ~head:(Z.snapshot zone).Z.head revoke in
    let invitation = Subject.Invite invite_id in
    check_gate "the invitation before its revocation" "clear" zone invitation;
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path (log_file dirs)) (fun release ->
      check_error
        "a revocation while another process holds the log"
        "Record_not_appended Write_locked"
        zone
        revoke;
      release ());
    check_gate "the invitation once its revocation failed" "pending" zone invitation;
    check_error
      "the token of the invitation after it"
      "Refused Revocation_pending"
      zone
      (admission_draft ~at_ms:(at_ms + 3));
    let switched = commit_ok zone (mode_draft ~at_ms:(at_ms + 4) M.Off) in
    check_settled "the next record gives the revocation up" ("Abort " ^ intent_name left) switched;
    check_blocked "the abort is the block that already stood" [ "invite:invite-1" ] (Z.snapshot zone).Z.state;
    let opened = check_restart "a restart" dirs ~mode:off ~head:switched.Z.record_hash in
    check_blocked "the replay blocks the invitation" [ "invite:invite-1" ] opened.replay.Z.Replay.state)
;;

(* The settlement puts the abort in the store before the record is appended.
   The block is published then, so an append that fails after it leaves the
   invitation blocked for the gate that reads the published state, and the
   next start blocks it too. *)
let a_block_outlives_a_commit_that_fails_after_the_abort () =
  (* The superuser writes to a file of mode 0400. *)
  skip_for_superuser ();
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let revoke = revoke_draft ~at_ms:(at_ms + 2) in
    let left = revocation_intent ~head:(Z.snapshot zone).Z.head revoke in
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path (log_file dirs)) (fun release ->
      check_error
        "a revocation while another process holds the log"
        "Record_not_appended Write_locked"
        zone
        revoke;
      release ());
    check_blocked "the failed revocation blocks at once" [ "invite:invite-1" ] (Z.snapshot zone).Z.state;
    Unix.chmod (log_file dirs) 0o400;
    Fun.protect
      ~finally:(fun () -> Unix.chmod (log_file dirs) 0o600)
      (fun () ->
        check_error
          "a commit that gives the revocation up and cannot append"
          "Record_not_appended Write_failed"
          zone
          (mode_draft ~at_ms:(at_ms + 3) M.Off));
    check_blocked "the published state blocks the invitation" [ "invite:invite-1" ] (Z.snapshot zone).Z.state;
    check_gate "a stopped log does not say" "log stopped" zone (Subject.Invite invite_id);
    let opened = open_files dirs in
    Alcotest.(check (list string))
      "the store holds the abort"
      [ intent_name left ]
      (List.map intent_name (S.State.aborted opened.store_state));
    check_blocked "the replay blocks the invitation" [ "invite:invite-1" ] opened.replay.Z.Replay.state;
    check_error
      "the token after a restart"
      "Refused Revocation_pending"
      (open_zone dirs)
      (admission_draft ~at_ms:(at_ms + 4)))
;;

(* A commit of [timed] while another process holds the log: the intent is
   written and the append is not. *)
let fail_append zone dirs timed =
  with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path (log_file dirs)) (fun release ->
    check_error "a commit while another process holds the log" "Record_not_appended Write_locked" zone timed;
    release ())
;;

let revoke_draft_of ~invite_id ~at_ms =
  match Invite_event.to_body (Invite_event.Revoked { invite_id }) with
  | Ok body -> timed ~at_ms ~author:Author.Local_operator ~kind:R.Kind.Invite body
  | Error error -> Alcotest.failf "fixture revocation refused: %s" (Authz_body.error_to_string error)
;;

(* A revocation made again after its append failed closes the blocks of the
   tries before it (design 8.3). The first try finds the log locked. The
   second gives it up, names it, and cannot write the log, which stops the
   zone. After a restart the retry gives the second up and names both: the
   gate reads the invitation clear, and so does the next restart. *)
let a_retried_revocation_closes_its_blocks () =
  (* The superuser writes to a file of mode 0400. *)
  skip_for_superuser ();
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let head = (Z.snapshot zone).Z.head in
    let invitation = Subject.Invite invite_id in
    let first = revoke_draft ~at_ms:(at_ms + 2) in
    let first_digest = (record_at ~head first).R.hash in
    fail_append zone dirs first;
    let second = revoke_draft ~at_ms:(at_ms + 3) in
    let second_intent =
      { (revocation_intent ~head second) with
        intended_next_record_digest = (R.closing (record_at ~head second) ~closes:[ first_digest ]).R.hash
      }
    in
    Unix.chmod (log_file dirs) 0o400;
    Fun.protect
      ~finally:(fun () -> Unix.chmod (log_file dirs) 0o600)
      (fun () ->
        check_error "a second try that cannot write the log" "Record_not_appended Write_failed" zone second);
    check_blocked
      "two failed tries are two blocks"
      [ "invite:invite-1"; "invite:invite-1" ]
      (Z.snapshot zone).Z.state;
    let zone = open_zone dirs in
    check_blocked
      "the restart holds both tries"
      [ "invite:invite-1"; "invite:invite-1" ]
      (Z.snapshot zone).Z.state;
    check_gate "the invitation after the restart" "pending" zone invitation;
    let retry = revoke_draft ~at_ms:(at_ms + 4) in
    let retried = commit_ok zone retry in
    check_settled "the retry gives the second try up" ("Abort " ^ intent_name second_intent) retried;
    Alcotest.(check string)
      "the record of the retry closes both tries"
      (R.Hash.to_hex
         (R.closing (record_at ~head retry) ~closes:[ first_digest; second_intent.S.intended_next_record_digest ])
           .R.hash)
      (R.Hash.to_hex retried.Z.record_hash);
    check_gate "the invitation once the retry is in the log" "clear" zone invitation;
    let opened = check_restart "a restart" dirs ~mode:on ~head:retried.Z.record_hash in
    check_blocked "the replay closes both" [] opened.replay.Z.Replay.state)
;;

(* A start that finds the intent of a failed revocation still pending blocks
   the invitation from the start, as the writer did when the append failed,
   and not only from the next entry that gives the intent up (design 8.2-3). *)
let a_restart_right_after_a_failed_revocation_keeps_the_block () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let revoke = revoke_draft ~at_ms:(at_ms + 2) in
    let left = revocation_intent ~head:(Z.snapshot zone).Z.head revoke in
    fail_append zone dirs revoke;
    let opened = open_files dirs in
    Alcotest.(check (option string))
      "the intent is still pending"
      (Some (intent_name left))
      (Option.map intent_name (S.State.pending opened.store_state));
    check_blocked "the replay blocks the invitation" [ "invite:invite-1" ] opened.replay.Z.Replay.state;
    let zone = open_zone dirs in
    check_gate "the gate after the restart" "pending" zone (Subject.Invite invite_id);
    let switched = commit_ok zone (mode_draft ~at_ms:(at_ms + 3) M.Off) in
    check_settled "the next entry gives the intent up" ("Abort " ^ intent_name left) switched;
    check_blocked "still one block" [ "invite:invite-1" ] (Z.snapshot zone).Z.state)
;;

(* A log put back to before the head of a given-up revocation holds the block
   from the start (design 8.3). A retry closes it, and the next start reads
   that retry with the block it closes instead of refusing the log. *)
let a_retry_closes_a_block_the_log_no_longer_reaches () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let invitation = Subject.Invite invite_id in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let (_ : Z.committed) =
      commit_ok zone (invite_draft ~at_ms:(at_ms + 2) ~invite_id:second_invite_id ~token:"token-2" ())
    in
    fail_append zone dirs (revoke_draft ~at_ms:(at_ms + 3));
    let (_ : Z.committed) =
      commit_ok zone (invite_draft ~at_ms:(at_ms + 4) ~invite_id:third_invite_id ~token:"token-3" ())
    in
    drop_last_line (log_file dirs);
    drop_last_line (log_file dirs);
    let zone = open_zone dirs in
    check_gate "the invitation once the log went back" "pending" zone invitation;
    let retried = commit_ok zone (revoke_draft ~at_ms:(at_ms + 5)) in
    check_gate "the invitation after the retry" "clear" zone invitation;
    let opened = check_restart "a restart" dirs ~mode:on ~head:retried.Z.record_hash in
    check_blocked "the replay closes the block" [] opened.replay.Z.Replay.state)
;;

(* A log put back to before an answered revocation disagrees with the store
   (design 8.2-4). Every commit is refused, and the gate says it does not
   know instead of reading the invitation clear. *)
let the_gate_does_not_know_when_the_files_disagree () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let (_ : Z.committed) = commit_ok zone (revoke_draft ~at_ms:(at_ms + 2)) in
    drop_last_line (log_file dirs);
    let zone = open_zone dirs in
    check_gate "the invitation once the log lost its revocation" "files disagree" zone (Subject.Invite invite_id);
    check_error "a commit" "Uncertain Commit_not_in_log" zone (mode_draft ~at_ms:(at_ms + 3) M.Off))
;;

(* A reduction of another subject closes nothing: its record names no block,
   and the invitation whose revocation failed stays blocked. *)
let a_reduction_of_another_subject_leaves_the_block () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let (_ : Z.committed) =
      commit_ok zone (invite_draft ~at_ms:(at_ms + 2) ~invite_id:second_invite_id ~token:"token-2" ())
    in
    fail_append zone dirs (revoke_draft ~at_ms:(at_ms + 3));
    let other = revoke_draft_of ~invite_id:second_invite_id ~at_ms:(at_ms + 4) in
    let head = (Z.snapshot zone).Z.head in
    let revoked = commit_ok zone other in
    Alcotest.(check string)
      "the record of the other revocation closes nothing"
      (R.Hash.to_hex (record_at ~head other).R.hash)
      (R.Hash.to_hex revoked.Z.record_hash);
    check_gate "the invitation whose revocation failed" "pending" zone (Subject.Invite invite_id);
    let opened = check_restart "a restart" dirs ~mode:on ~head:revoked.Z.record_hash in
    check_blocked "the replay keeps the block" [ "invite:invite-1" ] opened.replay.Z.Replay.state)
;;

(* ---- Admin assignments ---- *)

let second_admin = get (User_id.of_string "fedcba9876543210fedcba9876543210")

let admin_revocation_draft ~by ~user_id ~at_ms =
  match
    Authz_admin_event.to_body
      (Authz_admin_event.Revoked { user_id; cause = Authz_admin_event.Operational })
  with
  | Ok body ->
    timed ~at_ms ~author:(Author.Authenticated (Principal.Human by)) ~kind:R.Kind.Admin_assignment body
  | Error _ -> Alcotest.fail "fixture Admin revocation refused"
;;

(* Two Admins, and a revocation of the second that the store gave up. The
   second Admin joined before the revocation began, so a restart reads that
   admission as the writer did and starts the block after it: the log opens,
   the second Admin writes nothing, and the first is the last Admin who can. *)
let an_aborted_admin_revocation_starts_after_the_admission () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let (_ : Z.committed) =
      commit_ok zone (invite_draft ~at_ms:(at_ms + 2) ~invite_id:second_invite_id ~token:"token-2" ())
    in
    let (_ : Z.committed) = commit_ok zone (admission_draft ~at_ms:(at_ms + 3)) in
    let (_ : Z.committed) =
      commit_ok
        zone
        (admission_draft_of ~person:second_admin ~sub:"222" ~invite_id:second_invite_id ~at_ms:(at_ms + 4))
    in
    let revoke = admin_revocation_draft ~by:first_admin ~user_id:second_admin ~at_ms:(at_ms + 5) in
    let subject = Subject.Principal (Principal.Human second_admin) in
    let left = revocation_intent ~subject ~head:(Z.snapshot zone).Z.head revoke in
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path (log_file dirs)) (fun release ->
      check_error
        "a revocation while another process holds the log"
        "Record_not_appended Write_locked"
        zone
        revoke;
      release ());
    let issued =
      commit_ok zone (invite_draft ~at_ms:(at_ms + 6) ~invite_id:third_invite_id ~token:"token-3" ())
    in
    check_settled "the next record gives the revocation up" ("Abort " ^ intent_name left) issued;
    let opened = check_restart "a restart" dirs ~mode:on ~head:issued.Z.record_hash in
    check_blocked "the replay blocks the second Admin" [ Subject.to_string subject ] opened.replay.Z.Replay.state;
    Alcotest.(check bool)
      "the replay keeps the admission of the second Admin"
      true
      (Authz_principal_state.is_admin opened.replay.Z.Replay.state.Authz_state.principals second_admin);
    let restarted = open_zone dirs in
    check_error
      "the second Admin writes"
      "Refused Revocation_pending"
      restarted
      (admin_revocation_draft ~by:second_admin ~user_id:first_admin ~at_ms:(at_ms + 7));
    check_error
      "the first Admin revokes their own"
      "Refused Admin_assignment"
      restarted
      (admin_revocation_draft ~by:first_admin ~user_id:first_admin ~at_ms:(at_ms + 7)))
;;

(* ---- principal records ---- *)

let principal_draft ~by ~at_ms event =
  match Authz_principal_event.to_body event with
  | Ok body -> timed ~at_ms ~author:(Author.Authenticated (Principal.Human by)) ~kind:R.Kind.Principal body
  | Error _ -> Alcotest.fail "fixture principal event refused"
;;

(* Two Admins through two Admin invitations, written at [at_ms + 1] to
   [at_ms + 4]. *)
let admit_two_admins zone =
  let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
  let (_ : Z.committed) =
    commit_ok zone (invite_draft ~at_ms:(at_ms + 2) ~invite_id:second_invite_id ~token:"token-2" ())
  in
  let (_ : Z.committed) = commit_ok zone (admission_draft ~at_ms:(at_ms + 3)) in
  let (_ : Z.committed) =
    commit_ok
      zone
      (admission_draft_of ~person:second_admin ~sub:"222" ~invite_id:second_invite_id ~at_ms:(at_ms + 4))
  in
  ()
;;

(* ---- revocation cancels ---- *)

let fourth_invite_id = get (Authz_types.Invite_id.of_string "invite-4")
let fifth_invite_id = get (Authz_types.Invite_id.of_string "invite-5")
let third_person = get (User_id.of_string "00112233445566778899aabbccddeeff")

let cancel_draft ~by ~aborted ~subject ~at_ms =
  match Authz_cancel_event.to_body { Authz_cancel_event.aborted; subject } with
  | Ok body ->
    timed ~at_ms ~author:(Author.Authenticated (Principal.Human by)) ~kind:R.Kind.Revocation_cancel body
  | Error _ -> Alcotest.fail "fixture cancel refused"
;;

(* The first Admin issues an invitation, and its revocation fails. The first
   Admin owns it and does not lift its block (design 4.1); the second does,
   with a record that the store takes no intent for. A restart reads the
   cancel, and a log cut back to before it holds the block again (design 8.3). *)
let an_eligible_admin_lifts_a_block_and_a_log_cut_back_holds_it_again () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    admit_two_admins zone;
    let issued =
      commit_ok
        zone
        (invite_draft
           ~author:(Author.Authenticated (Principal.Human first_admin))
           ~at_ms:(at_ms + 5)
           ~invite_id:third_invite_id
           ~token:"token-3"
           ())
    in
    let invitation = Subject.Invite third_invite_id in
    let revoke = revoke_draft_of ~invite_id:third_invite_id ~at_ms:(at_ms + 6) in
    let left = revocation_intent ~subject:invitation ~head:(Z.snapshot zone).Z.head revoke in
    let aborted = left.S.intended_next_record_digest in
    fail_append zone dirs revoke;
    check_gate "after the failed revocation" "pending" zone invitation;
    check_error
      "the owner of the invitation"
      "Refused Canceller_owns_the_subject"
      zone
      (cancel_draft ~by:first_admin ~aborted ~subject:invitation ~at_ms:(at_ms + 7));
    check_gate "after the refused cancel" "pending" zone invitation;
    let lifted =
      commit_ok zone (cancel_draft ~by:second_admin ~aborted ~subject:invitation ~at_ms:(at_ms + 8))
    in
    check_settled "the cancel gives the revocation up first" ("Abort " ^ intent_name left) lifted;
    check_gate "after the cancel" "clear" zone invitation;
    let opened = check_restart "a restart" dirs ~mode:on ~head:lifted.Z.record_hash in
    check_blocked "the replay lifts the block" [] opened.replay.Z.Replay.state;
    Alcotest.(check (list string))
      "the store holds the abort and nothing of the cancel"
      [ intent_name left ]
      (List.map intent_name (S.State.aborted opened.store_state));
    Alcotest.(check (option string))
      "no intent is pending"
      None
      (Option.map intent_name (S.State.pending opened.store_state));
    drop_last_line (log_file dirs);
    let opened = check_restart "the log cut back" dirs ~mode:on ~head:issued.Z.record_hash in
    check_blocked "the block is back" [ "invite:invite-3" ] opened.replay.Z.Replay.state;
    check_gate "the gate after the log was cut back" "pending" (open_zone dirs) invitation)
;;

(* A block whose head the log no longer holds starts once the log is read. A
   cancel written after that lifts it, and the next start reads the cancel
   with the block it names instead of refusing the log. The token of the
   invitation then opens it, as the revocation never got in. *)
let a_cancel_lifts_a_block_the_log_no_longer_reaches () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    admit_two_admins zone;
    let invitation = Subject.Invite third_invite_id in
    let (_ : Z.committed) =
      commit_ok zone (invite_draft ~at_ms:(at_ms + 5) ~invite_id:third_invite_id ~token:"token-3" ())
    in
    let (_ : Z.committed) =
      commit_ok zone (invite_draft ~at_ms:(at_ms + 6) ~invite_id:fourth_invite_id ~token:"token-4" ())
    in
    let revoke = revoke_draft_of ~invite_id:third_invite_id ~at_ms:(at_ms + 7) in
    let left = revocation_intent ~subject:invitation ~head:(Z.snapshot zone).Z.head revoke in
    fail_append zone dirs revoke;
    let (_ : Z.committed) =
      commit_ok zone (invite_draft ~at_ms:(at_ms + 8) ~invite_id:fifth_invite_id ~token:"token-5" ())
    in
    drop_last_line (log_file dirs);
    drop_last_line (log_file dirs);
    let zone = open_zone dirs in
    check_gate "once the log went back" "pending" zone invitation;
    let lifted =
      commit_ok
        zone
        (cancel_draft
           ~by:first_admin
           ~aborted:left.S.intended_next_record_digest
           ~subject:invitation
           ~at_ms:(at_ms + 9))
    in
    check_gate "after the cancel" "clear" zone invitation;
    let opened = check_restart "a restart" dirs ~mode:on ~head:lifted.Z.record_hash in
    check_blocked "the replay lifts the block" [] opened.replay.Z.Replay.state;
    let (_ : Z.committed) =
      commit_ok
        (open_zone dirs)
        (admission_draft_of ~person:third_person ~sub:"333" ~invite_id:third_invite_id ~at_ms:(at_ms + 10))
    in
    ())
;;

(* A disable and a deletion go through the store as intents with their answers,
   and a restart reads both back. *)
let a_disable_and_a_deletion_survive_a_restart () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    admit_two_admins zone;
    let disabled =
      commit_ok
        zone
        (principal_draft ~by:first_admin ~at_ms:(at_ms + 5) (Authz_principal_event.Disabled { user_id = second_admin }))
    in
    check_settled "nothing to close" "Nothing_to_settle" disabled;
    let opened = check_restart "after the disable" dirs ~mode:on ~head:disabled.Z.record_hash in
    check_store "after the disable" opened ~pending:None ~last_committed:disabled.Z.record_hash ~aborted:[];
    Alcotest.(check bool)
      "the replay has the second Admin disabled"
      false
      (Authz_principal_state.is_active opened.replay.Z.Replay.state.Authz_state.principals second_admin);
    let deleted =
      commit_ok
        zone
        (principal_draft
           ~by:first_admin
           ~at_ms:(at_ms + 6)
           (Authz_principal_event.Deleted
              { user_id = second_admin; identity = get (Authz_external_identity.google ~sub:"222") }))
    in
    let opened = check_restart "after the deletion" dirs ~mode:on ~head:deleted.Z.record_hash in
    check_store "after the deletion" opened ~pending:None ~last_committed:deleted.Z.record_hash ~aborted:[];
    Alcotest.(check bool)
      "the replay has the second Admin deleted"
      true
      (Authz_principal_state.is_deleted opened.replay.Z.Replay.state.Authz_state.principals second_admin))
;;

let a_refused_invite_writes_nothing () =
  with_dirs (fun dirs ->
    let (_ : B.completed) = bootstrap dirs in
    let zone = open_zone dirs in
    let before = files dirs in
    check_error "an invitation by an authenticated principal" "Refused Invite" zone
      (invite_draft ~author:user ());
    check_files "the refused invitation wrote nothing" before dirs;
    let (_ : Z.committed) = commit_ok zone (mode_draft ~at_ms:(at_ms + 2) M.Off) in
    check_error "an invitation while the accounts are off" "Refused Accounts_off invite" zone
      (invite_draft ~at_ms:(at_ms + 3) ()))
;;

(* The zone writes the time of its clock, and an admission cannot be at a time
   before a record already in the log, so a clock set back cannot spend an
   invitation that had expired when that record was written (#48716). A record
   of another kind is not held to that time. *)
let an_admission_behind_the_log_writes_nothing () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let zone = open_zone dirs in
    (* The first invitation expires at [at_ms + 1001], when the second one is
       written. *)
    let (_ : Z.committed) = commit_ok zone (invite_draft ()) in
    let second =
      commit_ok
        zone
        (invite_draft ~at_ms:(at_ms + 1001) ~invite_id:second_invite_id ~token:"token-2" ())
    in
    let before = files dirs in
    let behind = admission_draft ~at_ms:(at_ms + 1000) in
    check_error "an admission before the second invitation" "Refused Admission_behind_log" zone behind;
    check_files "both files are as they were" before dirs;
    check_snapshot "the snapshot" ~mode:on ~head:second.Z.record_hash (Z.snapshot zone);
    check_error
      "the admission at the time of the second invitation"
      "Refused Admission"
      zone
      (admission_draft ~at_ms:(at_ms + 1001));
    let restarted = open_zone dirs in
    check_error "the same admission after a restart" "Refused Admission_behind_log" restarted behind;
    let switched = commit_ok restarted (mode_draft ~at_ms:(at_ms + 2) M.Off) in
    ignore
      (check_restart "an off from a clock that went back" dirs ~mode:off ~head:switched.Z.record_hash
       : opened))
;;

let a_failed_store_write_stops_every_commit () =
  (* The superuser writes to a file of mode 0400. *)
  skip_for_superuser ();
  with_dirs (fun dirs ->
    let completed = bootstrap dirs in
    let zone = open_zone dirs in
    let before = files dirs in
    Unix.chmod dirs.store_file 0o400;
    Fun.protect
      ~finally:(fun () -> Unix.chmod dirs.store_file 0o600)
      (fun () ->
        check_error
          "a commit to a store that cannot be written"
          "Intent_not_written Write_failed"
          zone
          (mode_draft M.Off));
    check_files "both files are as they were" before dirs;
    check_snapshot "the published state" ~mode:on ~head:completed.B.record_hash (Z.snapshot zone);
    check_decision "no decision rests on the stopped store" "store stopped" zone;
    check_error "the next commit" "Store_stopped" zone (mode_draft ~at_ms:(at_ms + 2) M.Off);
    check_files "the next commit wrote nothing" before dirs;
    ignore (check_restart "a restart" dirs ~mode:on ~head:completed.B.record_hash : opened))
;;

(* The process that held the log while the append of the zone waited, and
   appended a record of its own. The intent that the zone left is then not one
   to abort. *)
let a_record_appended_while_the_log_was_held_keeps_the_intent () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let zone = open_zone dirs in
    let head = (Z.snapshot zone).Z.head in
    let first = mode_draft ~at_ms:(at_ms + 1) M.Off in
    let left = intent_of ~head first S.Change.Off in
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path (log_file dirs)) (fun release ->
      check_error
        "a commit while another process holds the log"
        "Record_not_appended Write_locked"
        zone
        first;
      release ());
    append_log_outside (open_files dirs) [ record_at ~head (mode_draft ~at_ms:(at_ms + 2) M.Off) ];
    let before = files dirs in
    check_error
      "the next commit"
      "Abort_not_confirmed End_moved"
      zone
      (mode_draft ~at_ms:(at_ms + 3) M.Off);
    check_files "the next commit wrote nothing" before dirs;
    check_error "the commit after it" "Log_stopped" zone (mode_draft ~at_ms:(at_ms + 4) M.Off);
    check_files "the commit after it wrote nothing" before dirs;
    Alcotest.(check (option string))
      "the store keeps the intent"
      (Some (intent_name left))
      (Option.map intent_name (S.State.pending (open_files dirs).store_state));
    check_judgment "a restart" dirs "Mismatch Digest_differs")
;;

let a_failed_log_write_stops_every_commit () =
  (* The superuser writes to a file of mode 0400. *)
  skip_for_superuser ();
  with_dirs (fun dirs ->
    let completed = bootstrap dirs in
    let zone = open_zone dirs in
    let first = mode_draft ~at_ms:(at_ms + 1) M.Off in
    let left = intent_of ~head:(Z.snapshot zone).Z.head first S.Change.Off in
    let log_before = read_file (log_file dirs) in
    Unix.chmod (log_file dirs) 0o400;
    Fun.protect
      ~finally:(fun () -> Unix.chmod (log_file dirs) 0o600)
      (fun () ->
        check_error
          "a commit to a log that cannot be written"
          "Record_not_appended Write_failed"
          zone
          first);
    Alcotest.(check string) "the log is as it was" log_before (read_file (log_file dirs));
    check_snapshot "the published state" ~mode:on ~head:completed.B.record_hash (Z.snapshot zone);
    let before = files dirs in
    check_error "the next commit" "Log_stopped" zone (mode_draft ~at_ms:(at_ms + 2) M.Off);
    check_files "the next commit wrote nothing" before dirs;
    let next = commit_ok (open_zone dirs) (mode_draft ~at_ms:(at_ms + 3) M.Off) in
    check_settled "after a restart the intent is given up first" ("Abort " ^ intent_name left) next;
    let opened = check_restart "a restart" dirs ~mode:off ~head:next.Z.record_hash in
    check_store "a restart" opened ~pending:None ~last_committed:next.Z.record_hash ~aborted:[ left ])
;;

let a_locked_file_is_not_opened () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    List.iter
      (fun (label, lock_path, expected) ->
        with_foreign_lock ~lock_path (fun release ->
          (match Z.open_at_start ~now_ms ~log_path:(log_file dirs) ~store_path:dirs.store_file with
           | Ok (_ : Z.t) -> Alcotest.failf "%s: a zone was opened" label
           | Error error -> Alcotest.(check string) label expected (open_error_name error));
          release ()))
      [ "a locked store", Fs_compat.private_jsonl_lock_path dirs.store_file, "Store_not_opened"
      ; "a locked log", Fs_compat.private_jsonl_lock_path (log_file dirs), "Log_not_opened"
      ])
;;

(* The cases below write through a handle of their own, which moves the end of
   the file under the handle of the zone. *)
let another_handle_on_the_log_stops_the_log () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let zone = open_zone dirs in
    let other = open_files dirs in
    let head = other.replay.Z.Replay.head in
    append_log_outside other [ record_at ~head (mode_draft ~at_ms:(at_ms + 1) M.Off) ];
    let draft = mode_draft ~at_ms:(at_ms + 2) M.Off in
    let left = intent_of ~head draft S.Change.Off in
    check_error "a commit after the end of the log moved" "Record_not_appended Diverged" zone draft;
    check_snapshot "the published state" ~mode:on ~head:(R.head_hash head) (Z.snapshot zone);
    let before = files dirs in
    check_error "the next commit" "Log_stopped" zone (mode_draft ~at_ms:(at_ms + 3) M.Off);
    check_files "the next commit wrote nothing" before dirs;
    let opened = open_files dirs in
    Alcotest.(check (option string))
      "the store keeps the intent"
      (Some (intent_name left))
      (Option.map intent_name (S.State.pending opened.store_state));
    check_judgment "a restart" dirs "Mismatch Digest_differs")
;;

(* A mode event that was appended with no zone took no intent, so the store
   answers one record fewer than the log holds of those that take one: the
   epochs of the two files differ (design 5.1). A start reads a mismatch, and
   a zone that is opened over these files does not write and does not know
   its revocations. *)
let an_event_appended_with_no_intent_is_a_mismatch () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let other = open_files dirs in
    let head = other.replay.Z.Replay.head in
    check_judgment "before the append" dirs "Matches";
    append_log_outside other [ record_at ~head (mode_draft ~at_ms:(at_ms + 1) M.Off) ];
    check_judgment "a restart" dirs "Mismatch Answers_differ";
    let zone = open_zone dirs in
    let before = files dirs in
    check_error
      "a commit"
      "Uncertain Answers_differ"
      zone
      (mode_draft ~at_ms:(at_ms + 2) M.Reactivate);
    check_files "the commit wrote nothing" before dirs;
    check_gate "the gate" "files disagree" zone (Subject.Invite invite_id))
;;

(* Answers for two records that the log does not hold, which the store takes
   because they follow its own rules. *)
let another_handle_on_the_store_stops_the_store () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let zone = open_zone dirs in
    let other = open_files dirs in
    let head = other.replay.Z.Replay.head in
    let off_draft = mode_draft ~at_ms:(at_ms + 1) M.Off in
    let off_intent = intent_of ~head off_draft S.Change.Off in
    let after_off = R.head_after (record_at ~head off_draft) in
    let on_intent = intent_of ~head:after_off (mode_draft ~at_ms:(at_ms + 2) M.Reactivate) S.Change.Reactivate in
    write_store_outside
      other
      [ S.Intent_pending off_intent
      ; S.Committed { record_hash = off_intent.S.intended_next_record_digest }
      ; S.Intent_pending on_intent
      ; S.Committed { record_hash = on_intent.S.intended_next_record_digest }
      ];
    check_judgment "what the files say" dirs "Mismatch Commit_not_in_log";
    let before = files dirs in
    check_error
      "a commit after the end of the store moved"
      "Intent_not_written Diverged"
      zone
      (mode_draft ~at_ms:(at_ms + 3) M.Off);
    check_files "nothing was written" before dirs;
    check_error "the next commit" "Store_stopped" zone (mode_draft ~at_ms:(at_ms + 4) M.Off);
    check_files "the next commit wrote nothing" before dirs;
    check_judgment "a restart" dirs "Mismatch Commit_not_in_log")
;;

(* ---- what an earlier process left ---- *)

(* A process that stopped between the append and the answer. *)
let an_intent_with_its_record_is_promoted () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let earlier = open_files dirs in
    let head = earlier.replay.Z.Replay.head in
    let draft = mode_draft ~at_ms:(at_ms + 1) M.Off in
    let left = intent_of ~head draft S.Change.Off in
    write_store_outside earlier [ S.Intent_pending left ];
    append_log_outside earlier [ record_at ~head draft ];
    let zone = open_zone dirs in
    check_snapshot
      "the start reads the record"
      ~mode:off
      ~head:left.S.intended_next_record_digest
      (Z.snapshot zone);
    let next = commit_ok zone (mode_draft ~at_ms:(at_ms + 2) M.Reactivate) in
    check_settled "the commit answers the intent first" ("Promote " ^ intent_name left) next;
    let opened = check_restart "a restart" dirs ~mode:on ~head:next.Z.record_hash in
    check_store "a restart" opened ~pending:None ~last_committed:next.Z.record_hash ~aborted:[])
;;

(* A bootstrap that stopped between its append and its answer. A promoted
   [Fresh_bootstrap] is an answer (design 5.1). *)
let a_bootstrap_with_its_record_is_promoted () =
  with_dirs (fun dirs ->
    let completed = bootstrap dirs in
    drop_last_line dirs.store_file;
    let left =
      match S.State.pending (open_files dirs).store_state with
      | Some intent -> intent
      | None -> Alcotest.fail "the store holds no intent once its last line is cut"
    in
    Alcotest.(check string)
      "the intent names the bootstrap"
      (R.Hash.to_hex completed.B.record_hash)
      (R.Hash.to_hex left.S.intended_next_record_digest);
    check_judgment "what the files say" dirs "Matches";
    let zone = open_zone dirs in
    check_snapshot "the start reads the bootstrap" ~mode:on ~head:completed.B.record_hash (Z.snapshot zone);
    let next = commit_ok zone (mode_draft M.Off) in
    check_settled "the commit answers the bootstrap first" ("Promote " ^ intent_name left) next;
    let opened = check_restart "a restart" dirs ~mode:off ~head:next.Z.record_hash in
    check_store "a restart" opened ~pending:None ~last_committed:next.Z.record_hash ~aborted:[])
;;

(* An answer for a record that the log does not hold has no intent to settle,
   so only the judgment refuses it. *)
let disagreements_refuse_every_commit () =
  List.iter
    (fun (label, entries_at, expected) ->
      with_dirs (fun dirs ->
        ignore (bootstrap dirs : B.completed);
        let earlier = open_files dirs in
        write_store_outside earlier (entries_at earlier.replay.Z.Replay.head);
        let zone = open_zone dirs in
        let before = files dirs in
        check_error label expected zone (mode_draft ~at_ms:(at_ms + 3) M.Off);
        check_error (label ^ ", again") expected zone (mode_draft ~at_ms:(at_ms + 4) M.Off);
        check_files (label ^ ": both files are as they were") before dirs))
    [ ( "an answer for a record the log does not hold"
      , (fun head ->
          let intent = intent_of ~head (mode_draft ~at_ms:(at_ms + 1) M.Off) S.Change.Off in
          [ S.Intent_pending intent
          ; S.Committed { record_hash = intent.S.intended_next_record_digest }
          ])
      , "Uncertain Commit_not_in_log" )
    ; ( "an intent after a record the log does not hold"
      , (fun head ->
          let missing = record_at ~head (mode_draft ~at_ms:(at_ms + 1) M.Off) in
          [ S.Intent_pending
              (intent_of
                 ~head:(R.head_after missing)
                 (mode_draft ~at_ms:(at_ms + 2) M.Off)
                 S.Change.Off)
          ])
      , "Uncertain Intent_unplaced" )
    ]
;;

(* ---- install ---- *)

let lines entries = String.concat "" (List.map (fun entry -> S.to_line entry ^ "\n") entries)

let install opened { at_ms; draft } =
  clock := at_ms;
  Z.install ~now_ms ~log:opened.log ~store:opened.store draft
;;

let install_ok opened timed =
  match install opened timed with
  | Ok installed -> installed
  | Error error -> Alcotest.failf "install refused: %s" (Z.error_detail error)
;;

let check_install_error label expected opened timed =
  match install opened timed with
  | Ok (_ : Z.installed) -> Alcotest.failf "%s: the install succeeded" label
  | Error error -> Alcotest.(check string) label expected (error_name error)
;;

let bootstrap_draft = mode_draft ~at_ms M.Fresh_bootstrap

(* An earlier install that wrote its intent and stopped before its record. *)
let dead_draft = mode_draft ~at_ms:(at_ms - 1) M.Fresh_bootstrap
let dead_intent = intent_of ~head:R.genesis dead_draft S.Change.Fresh_bootstrap

(* Over an empty log and an empty store: the intent, the record and the answer,
   and a log that a zone then opens. *)
let an_install_writes_the_first_record () =
  with_dirs (fun dirs ->
    let installed = install_ok (open_files dirs) bootstrap_draft in
    let record = record_at ~head:R.genesis bootstrap_draft in
    Alcotest.(check string)
      "the hash of the record"
      (R.Hash.to_hex record.R.hash)
      (R.Hash.to_hex installed.Z.record_hash);
    Alcotest.(check (option string))
      "nothing was given up"
      None
      (Option.map intent_name installed.Z.aborted);
    check_snapshot "the answer" ~mode:on ~head:record.R.hash installed.Z.snapshot;
    Alcotest.(check string)
      "the store"
      (lines
         [ S.Intent_pending (intent_of ~head:R.genesis bootstrap_draft S.Change.Fresh_bootstrap)
         ; S.Committed { record_hash = record.R.hash }
         ])
      (read_file dirs.store_file);
    Alcotest.(check string) "the log" (R.to_line record ^ "\n") (read_file (log_file dirs));
    let opened = check_restart "a restart" dirs ~mode:on ~head:record.R.hash in
    check_store "a restart" opened ~pending:None ~last_committed:record.R.hash ~aborted:[];
    let next = commit_ok (open_zone dirs) (mode_draft ~at_ms:(at_ms + 1) M.Off) in
    check_snapshot "a commit after it" ~mode:off ~head:next.Z.record_hash next.Z.snapshot)
;;

(* The intent of an earlier install, whose record the log never got, is given
   up before the intent of this one. *)
let an_install_gives_up_an_intent_that_the_log_never_got () =
  with_dirs (fun dirs ->
    write_store_outside (open_files dirs) [ S.Intent_pending dead_intent ];
    let installed = install_ok (open_files dirs) bootstrap_draft in
    let record = record_at ~head:R.genesis bootstrap_draft in
    Alcotest.(check (option string))
      "the intent that was given up"
      (Some (intent_name dead_intent))
      (Option.map intent_name installed.Z.aborted);
    Alcotest.(check string)
      "the store"
      (lines
         [ S.Intent_pending dead_intent
         ; S.Aborted_intent dead_intent
         ; S.Intent_pending (intent_of ~head:R.genesis bootstrap_draft S.Change.Fresh_bootstrap)
         ; S.Committed { record_hash = record.R.hash }
         ])
      (read_file dirs.store_file);
    let opened = check_restart "a restart" dirs ~mode:on ~head:record.R.hash in
    check_store
      "a restart"
      opened
      ~pending:None
      ~last_committed:record.R.hash
      ~aborted:[ dead_intent ])
;;

(* The record of an earlier install reached the log after these handles were
   opened. The log no longer ends where its intent began, so the intent is not
   given up, the log stops, and a restart promotes the intent. *)
let an_install_keeps_an_intent_whose_record_came_late () =
  with_dirs (fun dirs ->
    write_store_outside (open_files dirs) [ S.Intent_pending dead_intent ];
    let opened = open_files dirs in
    append_log_outside (open_files dirs) [ record_at ~head:R.genesis dead_draft ];
    let before = files dirs in
    check_install_error "the install" "Abort_not_confirmed End_moved" opened bootstrap_draft;
    check_files "both files are as they were" before dirs;
    check_install_error "the next install" "Log_stopped" opened bootstrap_draft;
    check_judgment "what the files say" dirs "Matches")
;;

(* Another process holds the log while an install would give up the intent of
   an earlier one. Nothing is written and the log is not stopped, so the next
   install asks again and gives the intent up. *)
let an_install_asks_again_after_a_locked_log () =
  with_dirs (fun dirs ->
    write_store_outside (open_files dirs) [ S.Intent_pending dead_intent ];
    let opened = open_files dirs in
    let store_before = read_file dirs.store_file in
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path (log_file dirs)) (fun release ->
      check_install_error
        "an install while another process holds the log"
        "Abort_not_confirmed End_locked"
        opened
        bootstrap_draft;
      release ());
    Alcotest.(check string) "the store is as it was" store_before (read_file dirs.store_file);
    Alcotest.(check bool) "no log" false (Sys.file_exists (log_file dirs));
    let installed = install_ok opened bootstrap_draft in
    Alcotest.(check (option string))
      "the next install gives the intent up"
      (Some (intent_name dead_intent))
      (Option.map intent_name installed.Z.aborted))
;;

(* An intent that does not follow the genesis hash cannot be the intent of a
   first record, so it is not given up and nothing is written. *)
let an_install_refuses_an_intent_away_from_the_start () =
  with_dirs (fun dirs ->
    let unplaced =
      { dead_intent with
        S.previous_record_hash = (record_at ~head:R.genesis dead_draft).R.hash
      }
    in
    write_store_outside (open_files dirs) [ S.Intent_pending unplaced ];
    let store_before = read_file dirs.store_file in
    check_install_error "the install" "Uncertain Intent_unplaced" (open_files dirs) bootstrap_draft;
    Alcotest.(check string) "the store is as it was" store_before (read_file dirs.store_file);
    Alcotest.(check bool) "no log" false (Sys.file_exists (log_file dirs)))
;;

let an_install_refuses_what_it_cannot_install () =
  with_dirs (fun dirs ->
    let opened = open_files dirs in
    List.iter
      (fun (label, draft, expected) ->
        check_install_error label expected opened draft;
        Alcotest.(check bool) (label ^ ": no store") false (Sys.file_exists dirs.store_file);
        Alcotest.(check bool) (label ^ ": no log") false (Sys.file_exists (log_file dirs)))
      [ "an off", mode_draft M.Off, "Refused Mode"
      ; "a reactivation", mode_draft M.Reactivate, "Refused Mode"
      ; ( "a bootstrap from a user"
        , with_author user bootstrap_draft
        , "Record_not_built" )
      ; ( "a grant"
        , timed ~at_ms ~author:user ~kind:R.Kind.Runtime_grant grant_body
        , "Refused Before_bootstrap" )
      ];
    ignore (install_ok opened bootstrap_draft : Z.installed))
;;

(* A log with records, and a store that holds an answer over a log without it:
   neither is a log to install. *)
let an_install_refuses_an_installed_log_or_store () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let before = files dirs in
    check_install_error
      "a log with a record"
      "Log_holds_records 2"
      (open_files dirs)
      bootstrap_draft;
    check_files "a log with a record: both files are as they were" before dirs;
    Sys.remove (log_file dirs);
    let store_before = read_file dirs.store_file in
    check_install_error
      "a store with an answer"
      "Uncertain Commit_not_in_log"
      (open_files dirs)
      bootstrap_draft;
    Alcotest.(check string) "the store is as it was" store_before (read_file dirs.store_file);
    Alcotest.(check bool) "no log" false (Sys.file_exists (log_file dirs)))
;;

let () =
  Alcotest.run
    "authz_zone"
    [ ( "commit"
      , [ Alcotest.test_case "commits follow one another" `Quick commits_follow_one_another
        ; Alcotest.test_case
            "commits from fibers take turns"
            `Quick
            commits_from_fibers_take_turns
        ] )
    ; ( "records with no intent"
      , [ Alcotest.test_case "an invite has no intent" `Quick an_invite_is_appended_with_no_intent
        ; Alcotest.test_case
            "an invite settles the intent left before it"
            `Quick
            an_invite_settles_the_intent_left_before_it
        ; Alcotest.test_case "a revoked invite has an intent" `Quick a_revoked_invite_has_an_intent
        ; Alcotest.test_case "a refused invite writes nothing" `Quick a_refused_invite_writes_nothing
        ; Alcotest.test_case "an Admin admission has an intent" `Quick an_admin_admission_has_an_intent
        ; Alcotest.test_case
            "an aborted revocation blocks its invitation"
            `Quick
            an_aborted_revocation_blocks_its_invitation
        ; Alcotest.test_case
            "a block outlives a commit that fails after the abort"
            `Quick
            a_block_outlives_a_commit_that_fails_after_the_abort
        ; Alcotest.test_case
            "a retried revocation closes its blocks"
            `Quick
            a_retried_revocation_closes_its_blocks
        ; Alcotest.test_case
            "a reduction of another subject leaves the block"
            `Quick
            a_reduction_of_another_subject_leaves_the_block
        ; Alcotest.test_case
            "a restart right after a failed revocation keeps the block"
            `Quick
            a_restart_right_after_a_failed_revocation_keeps_the_block
        ; Alcotest.test_case
            "a retry closes a block the log no longer reaches"
            `Quick
            a_retry_closes_a_block_the_log_no_longer_reaches
        ; Alcotest.test_case
            "the gate does not know when the files disagree"
            `Quick
            the_gate_does_not_know_when_the_files_disagree
        ; Alcotest.test_case
            "an aborted Admin revocation starts after the admission"
            `Quick
            an_aborted_admin_revocation_starts_after_the_admission
        ; Alcotest.test_case
            "a disable and a deletion survive a restart"
            `Quick
            a_disable_and_a_deletion_survive_a_restart
        ; Alcotest.test_case
            "an eligible Admin lifts a block, and a log cut back holds it again"
            `Quick
            an_eligible_admin_lifts_a_block_and_a_log_cut_back_holds_it_again
        ; Alcotest.test_case
            "a cancel lifts a block the log no longer reaches"
            `Quick
            a_cancel_lifts_a_block_the_log_no_longer_reaches
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case "refused records write nothing" `Quick refused_records_write_nothing
        ; Alcotest.test_case
            "an admission behind the log writes nothing"
            `Quick
            an_admission_behind_the_log_writes_nothing
        ; Alcotest.test_case
            "the zone opens only a bootstrapped log"
            `Quick
            the_zone_opens_only_a_bootstrapped_log
        ; Alcotest.test_case
            "a log that cannot be checked is not opened"
            `Quick
            a_log_that_cannot_be_checked_is_not_opened
        ; Alcotest.test_case
            "a store with no answer refuses every commit"
            `Quick
            a_store_with_no_answer_refuses_every_commit
        ; Alcotest.test_case
            "a store that is not there is not opened"
            `Quick
            a_store_that_is_not_there_is_not_opened
        ; Alcotest.test_case
            "a store that cannot be checked is not opened"
            `Quick
            a_store_that_cannot_be_checked_is_not_opened
        ] )
    ; ( "failures"
      , [ Alcotest.test_case
            "a failure is told without the paths of the server"
            `Quick
            a_failure_is_told_without_the_paths_of_the_server
        ; Alcotest.test_case "the texts of each error" `Quick the_texts_of_each_error
        ; Alcotest.test_case
            "a locked store writes nothing and stops nothing"
            `Quick
            a_locked_store_writes_nothing_and_stops_nothing
        ; Alcotest.test_case
            "a locked log leaves an intent that the next commit aborts"
            `Quick
            a_locked_log_leaves_an_intent_that_the_next_commit_aborts
        ; Alcotest.test_case
            "a record appended while the log was held keeps the intent"
            `Quick
            a_record_appended_while_the_log_was_held_keeps_the_intent
        ; Alcotest.test_case
            "a failed store write stops every commit"
            `Quick
            a_failed_store_write_stops_every_commit
        ; Alcotest.test_case
            "a failed log write stops every commit"
            `Quick
            a_failed_log_write_stops_every_commit
        ; Alcotest.test_case "a locked file is not opened" `Quick a_locked_file_is_not_opened
        ; Alcotest.test_case
            "another handle on the log stops the log"
            `Quick
            another_handle_on_the_log_stops_the_log
        ; Alcotest.test_case
            "an event appended with no intent is a mismatch"
            `Quick
            an_event_appended_with_no_intent_is_a_mismatch
        ; Alcotest.test_case
            "another handle on the store stops the store"
            `Quick
            another_handle_on_the_store_stops_the_store
        ] )
    ; ( "install"
      , [ Alcotest.test_case
            "an install writes the first record"
            `Quick
            an_install_writes_the_first_record
        ; Alcotest.test_case
            "an install gives up an intent that the log never got"
            `Quick
            an_install_gives_up_an_intent_that_the_log_never_got
        ; Alcotest.test_case
            "an install keeps an intent whose record came late"
            `Quick
            an_install_keeps_an_intent_whose_record_came_late
        ; Alcotest.test_case
            "an install asks again after a locked log"
            `Quick
            an_install_asks_again_after_a_locked_log
        ; Alcotest.test_case
            "an install refuses an intent away from the start"
            `Quick
            an_install_refuses_an_intent_away_from_the_start
        ; Alcotest.test_case
            "an install refuses what it cannot install"
            `Quick
            an_install_refuses_what_it_cannot_install
        ; Alcotest.test_case
            "an install refuses an installed log or store"
            `Quick
            an_install_refuses_an_installed_log_or_store
        ] )
    ; ( "earlier process"
      , [ Alcotest.test_case
            "an intent with its record is promoted"
            `Quick
            an_intent_with_its_record_is_promoted
        ; Alcotest.test_case
            "a bootstrap with its record is promoted"
            `Quick
            a_bootstrap_with_its_record_is_promoted
        ; Alcotest.test_case
            "disagreements refuse every commit"
            `Quick
            disagreements_refuse_every_commit
        ] )
    ]
;;
