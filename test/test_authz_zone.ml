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
let on = Authz_mode_state.Multi_account workspace
let off = Authz_mode_state.Off workspace

let mode_body ?(workspace_id = workspace) event =
  match M.to_body { M.event; workspace_id } with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

(* A mode event from the host-local operator, its only writer (design 6.3). *)
let mode_draft ?(at_ms = at_ms + 1) ?workspace_id event : Z.draft =
  { Z.at_ms
  ; author = Author.Local_operator
  ; kind = R.Kind.Mode_event
  ; body = mode_body ?workspace_id event
  }
;;

let grant_body =
  match Authz_body.of_yojson (`Assoc [ "n", `Int 1 ]) with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

(* The record that a commit of [draft] at [head] builds. *)
let record_at ~head (draft : Z.draft) =
  match
    R.make ~head ~at_ms:draft.Z.at_ms ~author:draft.Z.author ~kind:draft.Z.kind ~body:draft.Z.body
  with
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
      ; at_ms
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
  | Ok (log, replay, _recovered) -> { store; store_state; log; replay }
  | Error error ->
    Alcotest.failf "log not opened: %s" (L.open_error_to_string Authz_state.refusal_to_string error)
;;

let open_error_name : Z.open_error -> string = function
  | Z.Store_not_opened _ -> "Store_not_opened"
  | Z.Log_not_opened _ -> "Log_not_opened"
  | Z.Not_bootstrapped _ -> "Not_bootstrapped"
  | Z.Log_not_checked _ -> "Log_not_checked"
;;

let open_zone dirs =
  match Z.open_at_start ~log_path:(log_file dirs) ~store_path:dirs.store_file with
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
  | L.End_unknown _ -> "End_unknown"
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
  | Authz_state.Kind_not_read kind -> "Kind_not_read " ^ R.Kind.to_string kind
;;

let error_name : Z.error -> string = function
  | Z.Store_stopped _ -> "Store_stopped"
  | Z.Log_stopped _ -> "Log_stopped"
  | Z.Uncertain { first; rest } -> "Uncertain " ^ reasons_name first rest
  | Z.Store_holds_no_answer -> "Store_holds_no_answer"
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

let commit_ok zone draft =
  match Z.commit zone draft with
  | Ok committed -> committed
  | Error error -> Alcotest.failf "commit refused: %s" (Z.error_to_string error)
;;

let check_error label expected zone draft =
  match Z.commit zone draft with
  | Ok _ -> Alcotest.failf "%s: the commit succeeded" label
  | Error error -> Alcotest.(check string) label expected (error_name error)
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

(* Commits from fibers that run at once take turns in the zone. In whatever
   order they run, each mode event either goes in or is refused by the state
   it meets, every one that goes in appends one record, and a restart reads the
   state that was published last. *)
let commits_from_fibers_take_turns () =
  with_dirs (fun dirs ->
    ignore (bootstrap dirs : B.completed);
    let zone = open_zone dirs in
    let lines_before = count_lines (read_file (log_file dirs)) in
    let events = [ M.Off; M.Reactivate; M.Off; M.Reactivate; M.Off; M.Reactivate ] in
    let results =
      Eio.Fiber.List.map
        ~max_fibers:(List.length events)
        (fun (index, event) -> Z.commit zone (mode_draft ~at_ms:(at_ms + 1 + index) event))
        (List.mapi (fun index event -> index, event) events)
    in
    let committed =
      List.filter_map
        (function
          | Ok committed -> Some committed
          | Error error ->
            Alcotest.(check string) "a commit that did not go in" "Refused Mode" (error_name error);
            None)
        results
    in
    Alcotest.(check bool) "a commit went in" true (committed <> []);
    Alcotest.(check int)
      "one record for each commit that went in"
      (lines_before + List.length committed)
      (count_lines (read_file (log_file dirs)));
    let published = Z.snapshot zone in
    ignore
      (check_restart
         "a restart"
         dirs
         ~mode:published.Z.state.Authz_state.mode
         ~head:(R.head_hash published.Z.head)
       : opened))
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
      ; "a mode event from a user", { (mode_draft M.Off) with Z.author = user }, "Record_not_built"
      ; ( "a grant, which no layer reads yet"
        , { Z.at_ms; author = user; kind = R.Kind.Runtime_grant; body = grant_body }
        , "Refused Kind_not_read " ^ R.Kind.to_string R.Kind.Runtime_grant )
      ];
    let next = commit_ok zone (mode_draft M.Off) in
    check_settled "a refusal leaves nothing to close" "Nothing_to_settle" next;
    ignore (check_restart "a restart" dirs ~mode:off ~head:next.Z.record_hash : opened))
;;

(* A zone over a log without a bootstrap would take a [Fresh_bootstrap] and
   create a store that no install record names. *)
let the_zone_opens_only_a_bootstrapped_log () =
  with_dirs (fun dirs ->
    let check_refused label =
      match Z.open_at_start ~log_path:(log_file dirs) ~store_path:dirs.store_file with
      | Ok (_ : Z.t) -> Alcotest.failf "%s: a zone was opened" label
      | Error error ->
        Alcotest.(check string) (label ^ ": the refusal") "Not_bootstrapped" (open_error_name error)
    in
    check_refused "no log";
    Alcotest.(check bool)
      "no log: no store directory"
      false
      (Sys.file_exists (Filename.dirname dirs.store_file));
    Alcotest.(check bool)
      "no log: no log directory"
      false
      (Sys.file_exists (Filename.dirname (log_file dirs)));
    make_dirs (Filename.dirname (log_file dirs));
    Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 (log_file dirs) ignore;
    check_refused "an empty log";
    Alcotest.(check bool) "an empty log: no store file" false (Sys.file_exists dirs.store_file);
    Alcotest.(check string) "an empty log: the log" "" (read_file (log_file dirs)))
;;

(* A bootstrapped log reads [Matches] with its store. A store that holds no
   answer for it reads [Absent], which design 5.1 does not let a writer go on
   from. *)
let a_store_with_no_answer_refuses_every_commit () =
  List.iter
    (fun (label, empty_the_store, store_after) ->
      with_dirs (fun dirs ->
        ignore (bootstrap dirs : B.completed);
        empty_the_store dirs.store_file;
        check_judgment (label ^ ": what the files say") dirs "Absent";
        let zone = open_zone dirs in
        let log_before = read_file (log_file dirs) in
        check_error label "Store_holds_no_answer" zone (mode_draft M.Off);
        check_error
          (label ^ ", again")
          "Store_holds_no_answer"
          zone
          (mode_draft ~at_ms:(at_ms + 2) M.Off);
        Alcotest.(check string) (label ^ ": the log") log_before (read_file (log_file dirs));
        Alcotest.(check (option string))
          (label ^ ": the store")
          store_after
          (if Sys.file_exists dirs.store_file then Some (read_file dirs.store_file) else None);
        check_judgment (label ^ ": a restart") dirs "Absent"))
    [ "an emptied store", (fun path -> Unix.truncate path 0), Some ""
    ; "a store that is not there", Sys.remove, None
    ]
;;

(* ---- failures ---- *)

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
    (* The intent stays until a commit writes an intent after it. *)
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
          (match Z.open_at_start ~log_path:(log_file dirs) ~store_path:dirs.store_file with
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
    ; ( "refusals"
      , [ Alcotest.test_case "refused records write nothing" `Quick refused_records_write_nothing
        ; Alcotest.test_case
            "the zone opens only a bootstrapped log"
            `Quick
            the_zone_opens_only_a_bootstrapped_log
        ; Alcotest.test_case
            "a store with no answer refuses every commit"
            `Quick
            a_store_with_no_answer_refuses_every_commit
        ] )
    ; ( "failures"
      , [ Alcotest.test_case
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
            "another handle on the store stops the store"
            `Quick
            another_handle_on_the_store_stops_the_store
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
