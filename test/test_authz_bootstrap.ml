(* Checks for the fresh bootstrap: what a first run leaves behind, which
   refusals leave every file as it was, and where a second run goes on after
   each way a first run can stop. Every case runs on real files in a fresh
   temporary directory, through the production path of [Fs_compat]. The config
   directory is an argument of the request, so no case reads or writes the
   install record of the operator. *)

module B = Authz_bootstrap
module S = Authz_external_store
module L = Authz_log
module I = Authz_install_record
module R = Authz_record
module H = Authz_high_water
module M = Authz_mode_event
module A = Authz_records.Author

(* ---- fixtures ---- *)

let workspace =
  match Authz_types.Workspace_id.of_string "workspace-1" with
  | Ok id -> id
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let other_workspace =
  match Authz_types.Workspace_id.of_string "workspace-2" with
  | Ok id -> id
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let at_ms = 1_700_000_000_000
let earlier_ms = at_ms - 60_000
let genesis_hash = R.head_hash R.genesis
let bootstrap_change = S.Change.Mode { event = S.Change.Fresh_bootstrap; workspace_id = workspace }

(* The record that a run at [at_ms] writes, made without running one. *)
let first_record at_ms =
  let body =
    match M.to_body { M.event = M.Fresh_bootstrap; workspace_id = workspace } with
    | Ok body -> body
    | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
  in
  match R.make ~head:R.genesis ~at_ms ~author:A.Local_operator ~kind:R.Kind.Mode_event ~body with
  | Ok record -> record
  | Error _ -> Alcotest.fail "fixture record refused"
;;

let intent_with digest : S.intent =
  { S.previous_record_hash = genesis_hash
  ; intended_next_record_digest = digest
  ; change = bootstrap_change
  }
;;

(* The intent that a run which died left behind, and its record. *)
let dead_record = first_record earlier_ms
let dead_intent = intent_with dead_record.R.hash

(* An intent that names a record after the genesis. Over an empty log, the
   record that it follows is not there. *)
let unplaced_intent = { dead_intent with S.previous_record_hash = dead_record.R.hash }

(* The same intent, for the workspace that an earlier attempt named and that
   this run does not. *)
let dead_intent_of_another_workspace =
  { dead_intent with
    S.change = S.Change.Mode { event = S.Change.Fresh_bootstrap; workspace_id = other_workspace }
  }
;;

(* ---- files ---- *)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
;;

(* Files of the installation are private. *)
let write_private path text =
  write_file path text;
  Unix.chmod path 0o600
;;

let permissions path = (Unix.stat path).Unix.st_perm land 0o777

(* A file that the process cannot touch is not refused for the superuser. *)
let skip_for_superuser () = if Unix.geteuid () = 0 then Alcotest.skip ()

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

type dirs =
  { root : string
  ; base : string  (** The base path. It exists. *)
  ; config : string  (** The [masc] config directory. It does not exist. *)
  ; store : string  (** Where the store goes. Neither it nor its directory exists. *)
  }

(* The zones of the log and the store are [Eio.Mutex]es, so every case runs in
   an event loop. Temporary directories are made 0700, which the owner check of
   the install record needs. *)
let with_dirs f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-bootstrap-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        f
          { root
          ; base
          ; config = Filename.concat root "config"
          ; store = Filename.concat (Filename.concat root "store") "external.jsonl"
          }))
;;

let log_file dirs = L.path_of_base_path ~base_path:dirs.base

let locate dirs ~base_path =
  match I.locate ~config_dir:(Some dirs.config) ~base_path with
  | Ok located -> located
  | Error error -> Alcotest.fail (I.locate_error_to_string error)
;;

let record_file dirs =
  match locate dirs ~base_path:dirs.base with
  | I.Located record -> I.file_path record
  | I.No_config_dir -> Alcotest.fail "the config directory is known"
;;

let write_record dirs ~base_path ~external_store =
  match I.write (locate dirs ~base_path) ~external_store with
  | Ok () -> ()
  | Error error -> Alcotest.fail (I.write_error_to_string error)
;;

let read_record dirs =
  match I.read (locate dirs ~base_path:dirs.base) with
  | Ok recorded -> recorded
  | Error error -> Alcotest.fail (I.read_error_to_string error)
;;

(* What a path holds, in one line, so that two lines tell whether anything
   changed: the kind, the mode, and the bytes of a file, the names in a
   directory, the target of a link. *)
let describe path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> "absent"
  | exception Unix.Unix_error (error, _, _) -> "not inspected: " ^ Unix.error_message error
  | { Unix.st_kind = Unix.S_REG; st_perm; _ } ->
    let digest =
      match Digest.file path with
      | digest -> Digest.to_hex digest
      | exception Sys_error _ -> "unreadable"
    in
    Printf.sprintf "file %o %s" (st_perm land 0o777) digest
  | { Unix.st_kind = Unix.S_DIR; st_perm; _ } ->
    (* The lock file that opening a file leaves next to it is not a write of
       the installation. *)
    let names =
      match Sys.readdir path with
      | names ->
        List.filter (fun name -> not (Filename.check_suffix name ".lock")) (Array.to_list names)
      | exception Sys_error _ -> [ "unreadable" ]
    in
    Printf.sprintf
      "directory %o [%s]"
      (st_perm land 0o777)
      (String.concat " " (List.sort String.compare names))
  | { Unix.st_kind = Unix.S_LNK; _ } -> "link to " ^ Unix.readlink path
  | { Unix.st_kind = Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK; _ } -> "special file"
;;

(* Every place that a run writes to, and the place that the request names for
   the store. *)
let touched ?(requested = "") dirs =
  let places =
    [ "log", log_file dirs
    ; "store", dirs.store
    ; "store directory", Filename.dirname dirs.store
    ; "install record", record_file dirs
    ; "config directory", dirs.config
    ; "requested store", requested
    ; "requested store directory", Filename.dirname requested
    ]
  in
  List.map (fun (label, path) -> label, if String.equal path "" then "none" else describe path) places
;;

let check_touched label before dirs ~requested =
  Alcotest.(check (list (pair string string))) label before (touched ~requested dirs)
;;

(* ---- the request and its answers ---- *)

let request dirs : B.request =
  { B.base_path = dirs.base
  ; config_dir = Some dirs.config
  ; external_store = dirs.store
  ; workspace_id = workspace
  ; at_ms
  }
;;

let run dirs = B.fresh_bootstrap (request dirs)

let problem_name = function
  | B.Not_absolute -> "Not_absolute"
  | B.Holds_nul -> "Holds_nul"
  | B.Not_normal -> "Not_normal"
  | B.Inside_base_path -> "Inside_base_path"
  | B.Is_install_record -> "Is_install_record"
;;

(* Why an append failed. The injected failures below must be a moved end and
   nothing else, which a lock that another process holds is not. *)
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

(* Named here so that a new constructor fails to compile until it is placed. *)
let error_name : B.error -> string = function
  | B.External_store_path_invalid { problem; _ } ->
    "External_store_path_invalid " ^ problem_name problem
  | B.No_config_dir -> "No_config_dir"
  | B.Install_record_not_located _ -> "Install_record_not_located"
  | B.Install_record_unreadable _ -> "Install_record_unreadable"
  | B.Install_record_changed _ -> "Install_record_changed"
  | B.Path_not_inspected _ -> "Path_not_inspected"
  | B.External_store_in_the_way _ -> "External_store_in_the_way"
  | B.Log_not_opened _ -> "Log_not_opened"
  | B.Log_not_empty { lines } -> Printf.sprintf "Log_not_empty %d" lines
  | B.External_store_not_opened _ -> "External_store_not_opened"
  | B.Not_a_fresh_installation _ -> "Not_a_fresh_installation"
  | B.Install_record_not_written _ -> "Install_record_not_written"
  | B.External_store_not_created _ -> "External_store_not_created"
  | B.Store_stopped _ -> "Store_stopped"
  | B.Log_stopped _ -> "Log_stopped"
  | B.Dead_intent_not_closed error -> "Dead_intent_not_closed " ^ store_append_error_name error
  | B.Intent_not_written error -> "Intent_not_written " ^ store_append_error_name error
  | B.Record_not_appended error -> "Record_not_appended " ^ log_append_error_name error
  | B.Answer_not_written { error; _ } -> "Answer_not_written " ^ store_append_error_name error
  | B.Mode_event_not_built _ -> "Mode_event_not_built"
  | B.Record_not_built _ -> "Record_not_built"
;;

let completed_exn = function
  | Ok completed -> completed
  | Error error -> Alcotest.failf "the bootstrap failed: %s" (B.error_to_string error)
;;

let refused label expected = function
  | Ok _ -> Alcotest.failf "%s: the bootstrap succeeded" label
  | Error error ->
    Alcotest.(check string)
      (Printf.sprintf "%s (%s)" label (B.error_to_string error))
      expected
      (error_name error)
;;

(* ---- what the files say, read the way a boot reads them ---- *)

let records_of_log dirs =
  match
    L.open_at_start
      ~path:(log_file dirs)
      ~init:[]
      ~step:(fun seen record -> (Ok (record :: seen) : (R.t list, unit) result))
  with
  | Ok (_log, seen, _recovered) -> List.rev seen
  | Error error ->
    Alcotest.failf "the log did not open: %s" (L.open_error_to_string (fun () -> "") error)
;;

let store_state path =
  match
    S.open_at_start ~path ~init:() ~step:(fun () _entry -> (Ok () : (unit, unit) result))
  with
  | Error error ->
    Alcotest.failf "the store did not open: %s" (S.open_error_to_string (fun () -> "") error)
  | Ok (store, (), _recovered) ->
    (match S.with_writer store (fun _writer state -> state) with
     | Ok state -> state
     | Error { S.path; reason } -> Alcotest.failf "the store %s is stopped: %s" path reason)
;;

let probe_of dirs =
  List.fold_left H.Probe.add (H.Probe.create (store_state dirs.store)) (records_of_log dirs)
;;

let reason_name = function
  | H.Digest_differs _ -> "Digest_differs"
  | H.Commit_not_in_log _ -> "Commit_not_in_log"
  | H.Intent_unplaced _ -> "Intent_unplaced"
;;

let value_name = function
  | H.Absent -> "absent"
  | H.Matches -> "matches"
  | H.Mismatch (first, rest) ->
    "mismatch " ^ String.concat "," (List.map reason_name (first :: rest))
;;

let store_text entries = String.concat "" (List.map (fun entry -> S.to_line entry ^ "\n") entries)
let aborted_line intent = S.to_line (S.Aborted_intent intent)

(* What a finished run leaves: the install record names the store, the store
   holds what it held before the run (less a torn last line), the intent that
   was given up, the intent of the run and its answer, and the log holds the
   record, byte for byte. The mark reads as set up. *)
let check_installed ~before ~closed dirs (completed : B.completed) =
  let record = first_record at_ms in
  Alcotest.(check bool)
    "the hash of the record"
    true
    (R.Hash.equal completed.B.record_hash record.R.hash);
  Alcotest.(check (option string)) "the install record names the store" (Some dirs.store) (read_record dirs);
  Alcotest.(check int) "the store is private" 0o600 (permissions dirs.store);
  Alcotest.(check string)
    "the store"
    (store_text
       (before
        @ (match closed with
           | Some intent -> [ S.Aborted_intent intent ]
           | None -> [])
        @ [ S.Intent_pending (intent_with record.R.hash)
          ; S.Committed { record_hash = record.R.hash }
          ]))
    (read_file dirs.store);
  Alcotest.(check string) "the log" (R.to_line record ^ "\n") (read_file (log_file dirs));
  Alcotest.(check string) "the high-water mark" "matches" (value_name (H.judge (probe_of dirs)));
  Alcotest.(check (option string))
    "the intent that was given up"
    (Option.map aborted_line closed)
    (Option.map aborted_line completed.B.closed_intent)
;;

(* ---- a first run ---- *)

let a_first_run_sets_the_installation_up () =
  with_dirs (fun dirs ->
    let completed = completed_exn (run dirs) in
    check_installed ~before:[] ~closed:None dirs completed;
    (* The record that the log holds, read as a boot reads it. *)
    match records_of_log dirs with
    | [ record ] ->
      Alcotest.(check int) "the first record of the log" 1 record.R.seq;
      Alcotest.(check int) "the time of the request" at_ms record.R.at_ms;
      Alcotest.(check string) "the kind" "mode_event" (R.Kind.to_string record.R.kind);
      (match record.R.author with
       | A.Local_operator -> ()
       | A.Authenticated _ | A.System_cron | A.System_maintenance | A.System_migration ->
         Alcotest.fail "the author is not the local operator");
      (match M.of_body record.R.body with
       | Ok mode_event ->
         Alcotest.(check bool)
           "the body is a bootstrap of the workspace"
           true
           (M.equal mode_event { M.event = M.Fresh_bootstrap; workspace_id = workspace })
       | Error error -> Alcotest.failf "the body is not a mode event: %s" (M.error_to_string error))
    | records -> Alcotest.failf "the log holds %d records" (List.length records))
;;

(* ---- refusals: every file stays as it was ---- *)

type refusal =
  { label : string
  ; expected : string  (** The name of the error. *)
  ; prepare : dirs -> B.request
        (** Sets the files up and gives the request. *)
  }

let first_run_then_log_lost dirs =
  ignore (completed_exn (run dirs) : B.completed);
  Sys.remove (log_file dirs)
;;

let refusals =
  [ { label = "a relative path for the store"
    ; expected = "External_store_path_invalid Not_absolute"
    ; prepare =
        (fun dirs -> { (request dirs) with B.external_store = "relative/external.jsonl" })
    }
  ; { label = "no config directory"
    ; expected = "No_config_dir"
    ; prepare = (fun dirs -> { (request dirs) with B.config_dir = None })
    }
  ; { label = "a relative config directory"
    ; expected = "Install_record_not_located"
    ; prepare = (fun dirs -> { (request dirs) with B.config_dir = Some "relative/masc" })
    }
  ; { label = "an install record that is not JSON"
    ; expected = "Install_record_unreadable"
    ; prepare =
        (fun dirs ->
          Unix.mkdir dirs.config 0o700;
          write_private (record_file dirs) "not json";
          request dirs)
    }
  ; { label = "an install record of another base path"
    ; expected = "Install_record_unreadable"
    ; prepare =
        (fun dirs ->
          let other = Filename.concat dirs.root "other-base" in
          Unix.mkdir other 0o700;
          write_record dirs ~base_path:other ~external_store:dirs.store;
          let other_file =
            match locate dirs ~base_path:other with
            | I.Located record -> I.file_path record
            | I.No_config_dir -> Alcotest.fail "the config directory is known"
          in
          let text = read_file other_file in
          Sys.remove other_file;
          write_private (record_file dirs) text;
          request dirs)
    }
  ; { label = "a config directory that is a file"
    ; expected = "Install_record_unreadable"
    ; prepare =
        (fun dirs ->
          write_private dirs.config "not a directory";
          request dirs)
    }
  ; { label = "a file at the path of the store"
    ; expected = "External_store_in_the_way"
    ; prepare =
        (fun dirs ->
          write_private dirs.store "an old store\n";
          request dirs)
    }
  ; { label = "a directory at the path of the store"
    ; expected = "External_store_in_the_way"
    ; prepare =
        (fun dirs ->
          Fs_compat.mkdir_p dirs.store;
          request dirs)
    }
  ; { label = "a link that leads nowhere at the path of the store"
    ; expected = "External_store_in_the_way"
    ; prepare =
        (fun dirs ->
          Fs_compat.mkdir_p (Filename.dirname dirs.store);
          Unix.symlink "nowhere" dirs.store;
          request dirs)
    }
  ; { label = "a link to a file at the path of the store"
    ; expected = "External_store_in_the_way"
    ; prepare =
        (fun dirs ->
          let target = Filename.concat dirs.root "old-store.jsonl" in
          write_private target "an old store\n";
          Fs_compat.mkdir_p (Filename.dirname dirs.store);
          Unix.symlink target dirs.store;
          request dirs)
    }
  ; { label = "a file at the new path of the store while the install record names another"
    ; expected = "External_store_in_the_way"
    ; prepare =
        (fun dirs ->
          write_record
            dirs
            ~base_path:dirs.base
            ~external_store:(Filename.concat dirs.root "other-store.jsonl");
          write_private dirs.store "an old store\n";
          request dirs)
    }
  ; { label = "a NUL byte in the path of the store"
    ; expected = "External_store_path_invalid Holds_nul"
    ; prepare = (fun dirs -> { (request dirs) with B.external_store = dirs.store ^ "\000x" })
    }
  ; { label = "the install record as the store"
    ; expected = "External_store_path_invalid Is_install_record"
    ; prepare = (fun dirs -> { (request dirs) with B.external_store = record_file dirs })
    }
  ; { label = "the install record as the store, through a link to the config directory"
    ; expected = "External_store_path_invalid Is_install_record"
    ; prepare =
        (fun dirs ->
          Unix.mkdir dirs.config 0o700;
          let through_link = Filename.concat dirs.root "config-link" in
          Unix.symlink dirs.config through_link;
          { (request dirs) with
            B.external_store = Filename.concat through_link (Filename.basename (record_file dirs))
          })
    }
  ; { label = "the authorization log as the store"
    ; expected = "External_store_path_invalid Inside_base_path"
    ; prepare = (fun dirs -> { (request dirs) with B.external_store = log_file dirs })
    }
  ; { label = "the lock file of the authorization log as the store"
    ; expected = "External_store_path_invalid Inside_base_path"
    ; prepare =
        (fun dirs ->
          { (request dirs) with B.external_store = log_file dirs ^ ".lock" })
    }
  ; { label = "the install record, which exists, through a link"
    ; expected = "External_store_path_invalid Is_install_record"
    ; prepare =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          let through_link = Filename.concat dirs.root "record-link" in
          Unix.symlink (record_file dirs) through_link;
          { (request dirs) with B.external_store = through_link })
    }
  ; { label = "the directory of the log, which a link puts outside the base path"
    ; expected = "External_store_path_invalid Inside_base_path"
    ; prepare =
        (fun dirs ->
          let elsewhere = Filename.concat dirs.root "elsewhere" in
          Fs_compat.mkdir_p (Filename.concat elsewhere "auth");
          Unix.symlink elsewhere (Filename.concat dirs.base ".masc");
          { (request dirs) with
            B.external_store = Filename.concat (Filename.concat elsewhere "auth") "authz.jsonl"
          })
    }
  ; { label = "the directory of the log, which a link puts outside the base path, before it is made"
    ; expected = "External_store_path_invalid Inside_base_path"
    ; prepare =
        (fun dirs ->
          let elsewhere = Filename.concat dirs.root "elsewhere" in
          Fs_compat.mkdir_p elsewhere;
          Unix.symlink elsewhere (Filename.concat dirs.base ".masc");
          { (request dirs) with
            B.external_store = Filename.concat (Filename.concat elsewhere "auth") "authz.jsonl"
          })
    }
  ; { label = "a store inside the base path"
    ; expected = "External_store_path_invalid Inside_base_path"
    ; prepare =
        (fun dirs ->
          { (request dirs) with
            B.external_store = Filename.concat (Filename.concat dirs.base "store") "external.jsonl"
          })
    }
  ; { label = "a store inside the base path, through a link to it"
    ; expected = "External_store_path_invalid Inside_base_path"
    ; prepare =
        (fun dirs ->
          let through_link = Filename.concat dirs.root "base-link" in
          Unix.symlink dirs.base through_link;
          { (request dirs) with B.external_store = Filename.concat through_link "external.jsonl" })
    }
  ; { label = "a store inside the base path, through a link to a folder of it"
    ; expected = "External_store_path_invalid Inside_base_path"
    ; prepare =
        (fun dirs ->
          let folder = Filename.concat dirs.base "folder" in
          Fs_compat.mkdir_p folder;
          let through_link = Filename.concat dirs.root "folder-link" in
          Unix.symlink folder through_link;
          { (request dirs) with B.external_store = Filename.concat through_link "external.jsonl" })
    }
  ; { label = "the base path itself as the store"
    ; expected = "External_store_path_invalid Inside_base_path"
    ; prepare = (fun dirs -> { (request dirs) with B.external_store = dirs.base })
    }
  ; { label = "a dot segment in the path of the store"
    ; expected = "External_store_path_invalid Not_normal"
    ; prepare =
        (fun dirs ->
          { (request dirs) with
            B.external_store = Filename.concat (Filename.dirname dirs.store) "./external.jsonl"
          })
    }
  ; { label = "a dot dot segment in the path of the store"
    ; expected = "External_store_path_invalid Not_normal"
    ; prepare =
        (fun dirs ->
          { (request dirs) with
            B.external_store = Filename.concat (Filename.dirname dirs.store) "../store/external.jsonl"
          })
    }
  ; { label = "an empty segment in the path of the store"
    ; expected = "External_store_path_invalid Not_normal"
    ; prepare =
        (fun dirs ->
          { (request dirs) with
            B.external_store = Filename.dirname dirs.store ^ "//external.jsonl"
          })
    }
  ; { label = "a separator at the end of the path of the store"
    ; expected = "External_store_path_invalid Not_normal"
    ; prepare = (fun dirs -> { (request dirs) with B.external_store = dirs.store ^ "/" })
    }
  ; { label = "a dot at the end of the path of the store"
    ; expected = "External_store_path_invalid Not_normal"
    ; prepare = (fun dirs -> { (request dirs) with B.external_store = dirs.store ^ "/." })
    }
  ; { label = "a link that leads nowhere at the path that the install record names"
    ; expected = "External_store_in_the_way"
    ; prepare =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          Fs_compat.mkdir_p (Filename.dirname dirs.store);
          Unix.symlink "nowhere" dirs.store;
          request dirs)
    }
  ; { label = "a link to a file at the path that the install record names"
    ; expected = "External_store_in_the_way"
    ; prepare =
        (fun dirs ->
          let target = Filename.concat dirs.root "old-store.jsonl" in
          write_private target "an old store\n";
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          Fs_compat.mkdir_p (Filename.dirname dirs.store);
          Unix.symlink target dirs.store;
          request dirs)
    }
  ; { label = "a directory at the path that the install record names"
    ; expected = "External_store_in_the_way"
    ; prepare =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          Fs_compat.mkdir_p dirs.store;
          request dirs)
    }
  ; { label = "the install record names another path that holds a directory"
    ; expected = "External_store_in_the_way"
    ; prepare =
        (fun dirs ->
          let other = Filename.concat dirs.root "other-store.jsonl" in
          write_record dirs ~base_path:dirs.base ~external_store:other;
          Fs_compat.mkdir_p other;
          request dirs)
    }
  ; { label = "a pending intent that follows a record the empty log does not have"
    ; expected = "Not_a_fresh_installation"
    ; prepare =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          write_private dirs.store (store_text [ S.Intent_pending unplaced_intent ]);
          request dirs)
    }
  ; { label = "a file where the directory of the store should be"
    ; expected = "Path_not_inspected"
    ; prepare =
        (fun dirs ->
          write_private (Filename.dirname dirs.store) "not a directory";
          request dirs)
    }
  ; { label = "a log that holds a record"
    ; expected = "Log_not_empty 1"
    ; prepare =
        (fun dirs ->
          write_private (log_file dirs) (R.to_line dead_record ^ "\n");
          request dirs)
    }
  ; { label = "a log with a line that the chain refuses"
    ; expected = "Log_not_opened"
    ; prepare =
        (fun dirs ->
          write_private (log_file dirs) "{}\n";
          request dirs)
    }
  ; { label = "a log that cannot be read"
    ; expected = "Log_not_opened"
    ; prepare =
        (fun dirs ->
          skip_for_superuser ();
          write_private (log_file dirs) "";
          Unix.chmod (log_file dirs) 0o000;
          request dirs)
    }
  ; { label = "a store that the install record names and that does not read"
    ; expected = "External_store_not_opened"
    ; prepare =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          write_private dirs.store "not a line of the store\n";
          request dirs)
    }
  ; { label = "a log that went back, the same path for the store"
    ; expected = "Not_a_fresh_installation"
    ; prepare =
        (fun dirs ->
          first_run_then_log_lost dirs;
          request dirs)
    }
  ; { label = "a log that went back, another path for the store"
    ; expected = "Not_a_fresh_installation"
    ; prepare =
        (fun dirs ->
          first_run_then_log_lost dirs;
          { (request dirs) with
            B.external_store = Filename.concat dirs.root "other-store.jsonl"
          })
    }
  ]
;;

let a_refusal_writes_nothing refusal () =
  with_dirs (fun dirs ->
    let asked = refusal.prepare dirs in
    let requested = asked.B.external_store in
    let before = touched ~requested dirs in
    refused refusal.label refusal.expected (B.fresh_bootstrap asked);
    check_touched "every place is as it was" before dirs ~requested)
;;

(* The two helpers name every constructor, so that a new one fails to compile
   until it is placed. *)
let not_a_fresh_installation : B.error -> (string * H.t) option = function
  | B.Not_a_fresh_installation { store; value } -> Some (store, value)
  | B.External_store_path_invalid _
  | B.No_config_dir
  | B.Install_record_not_located _
  | B.Install_record_unreadable _
  | B.Install_record_changed _
  | B.Path_not_inspected _
  | B.External_store_in_the_way _
  | B.Log_not_opened _
  | B.Log_not_empty _
  | B.External_store_not_opened _
  | B.Install_record_not_written _
  | B.External_store_not_created _
  | B.Store_stopped _
  | B.Log_stopped _
  | B.Dead_intent_not_closed _
  | B.Intent_not_written _
  | B.Record_not_appended _
  | B.Answer_not_written _
  | B.Mode_event_not_built _
  | B.Record_not_built _ -> None
;;

let only_lost_commit : H.t -> R.Hash.t option = function
  | H.Mismatch (H.Commit_not_in_log lost, []) -> Some lost
  | H.Mismatch ((H.Digest_differs _ | H.Intent_unplaced _), _)
  | H.Mismatch (H.Commit_not_in_log _, _ :: _)
  | H.Absent
  | H.Matches -> None
;;

(* A store that holds an answered event while the log holds nothing is not a
   new installation, and the refusal says which record the log lost. *)
let a_log_that_went_back_names_the_lost_commit () =
  with_dirs (fun dirs ->
    let completed = completed_exn (run dirs) in
    Sys.remove (log_file dirs);
    match run dirs with
    | Ok _ -> Alcotest.fail "a second bootstrap succeeded over a log that went back"
    | Error error ->
      (match not_a_fresh_installation error with
       | None -> Alcotest.failf "the refusal is another one: %s" (B.error_to_string error)
       | Some (store, value) ->
         Alcotest.(check string) "the store" dirs.store store;
         (match only_lost_commit value with
          | Some lost ->
            Alcotest.(check bool)
              "the record that the log lost"
              true
              (R.Hash.equal completed.B.record_hash lost)
          | None -> Alcotest.failf "the reason is another one: %s" (value_name value))))
;;

(* macOS shows its data volume twice: [/Users/x] and
   [/System/Volumes/Data/Users/x] are one directory, and [realpath] does not join
   them. Only the files tell that two such paths are one. The case runs where the
   volume is. *)
let a_firmlink_spelling_of_the_installation_is_refused () =
  let volume = "/System/Volumes/Data" in
  if not (Sys.file_exists volume) then Alcotest.skip ();
  with_dirs (fun dirs ->
    write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
    let spelled path = volume ^ Unix.realpath path in
    List.iter
      (fun (label, expected, store) ->
        if not (Sys.file_exists (Filename.dirname store)) then Alcotest.skip ();
        let asked = { (request dirs) with B.external_store = store } in
        let before = touched ~requested:store dirs in
        refused label expected (B.fresh_bootstrap asked);
        check_touched (label ^ ": every place is as it was") before dirs ~requested:store)
      [ "the install record", "External_store_path_invalid Is_install_record", spelled (record_file dirs)
      ; ( "a place inside the base path"
        , "External_store_path_invalid Inside_base_path"
        , Filename.concat (spelled dirs.base) "external.jsonl" )
      ])
;;

(* The log has the record, so the second run stops there, for the same store
   path and for another one. The install record keeps naming the first store. *)
let a_second_run_is_refused () =
  with_dirs (fun dirs ->
    ignore (completed_exn (run dirs) : B.completed);
    let other = Filename.concat (Filename.concat dirs.root "other") "external.jsonl" in
    List.iter
      (fun (label, asked) ->
        let requested = asked.B.external_store in
        let before = touched ~requested dirs in
        refused label "Log_not_empty 1" (B.fresh_bootstrap asked);
        check_touched (label ^ ": every place is as it was") before dirs ~requested)
      [ "the same store path", request dirs
      ; "another store path", { (request dirs) with B.external_store = other }
      ];
    Alcotest.(check (option string))
      "the install record names the first store"
      (Some dirs.store)
      (read_record dirs))
;;

(* ---- a first run that stopped, and the run after it ---- *)

type recovery =
  { situation : string
  ; set_up : dirs -> unit -> unit
        (** Sets up what the dead run left. The function it returns checks what
            the new run must not have touched. *)
  ; before : S.entry list  (** What the store holds when the run starts, after the open cuts a torn line. *)
  ; closed : S.intent option  (** The intent that the run gives up. *)
  }

let no_check () = ()

let torn_half text = String.sub text 0 (String.length text / 2)

let recoveries =
  [ { situation = "only the install record was written"
    ; set_up =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          no_check)
    ; before = []
    ; closed = None
    }
  ; { situation = "the install record and an empty store were written"
    ; set_up =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          write_private dirs.store "";
          no_check)
    ; before = []
    ; closed = None
    }
  ; { situation = "an intent is pending"
    ; set_up =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          write_private dirs.store (store_text [ S.Intent_pending dead_intent ]);
          no_check)
    ; before = [ S.Intent_pending dead_intent ]
    ; closed = Some dead_intent
    }
  ; { situation = "the intent was given up and no new one was written"
    ; set_up =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          write_private
            dirs.store
            (store_text [ S.Intent_pending dead_intent; S.Aborted_intent dead_intent ]);
          no_check)
    ; before = [ S.Intent_pending dead_intent; S.Aborted_intent dead_intent ]
    ; closed = None
    }
  ; { situation = "an intent for another workspace is pending"
    ; set_up =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          write_private
            dirs.store
            (store_text [ S.Intent_pending dead_intent_of_another_workspace ]);
          no_check)
    ; before = [ S.Intent_pending dead_intent_of_another_workspace ]
    ; closed = Some dead_intent_of_another_workspace
    }
  ; { situation = "an intent of the same millisecond is pending"
    ; set_up =
        (fun dirs ->
          let same = intent_with (first_record at_ms).R.hash in
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          write_private dirs.store (store_text [ S.Intent_pending same ]);
          no_check)
    ; before = [ S.Intent_pending (intent_with (first_record at_ms).R.hash) ]
    ; closed = Some (intent_with (first_record at_ms).R.hash)
    }
  ; { situation = "the intent was being written"
    ; set_up =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          write_private dirs.store (torn_half (S.to_line (S.Intent_pending dead_intent)));
          no_check)
    ; before = []
    ; closed = None
    }
  ; { situation = "the record was being written"
    ; set_up =
        (fun dirs ->
          write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
          write_private dirs.store (store_text [ S.Intent_pending dead_intent ]);
          write_private (log_file dirs) (torn_half (R.to_line dead_record));
          no_check)
    ; before = [ S.Intent_pending dead_intent ]
    ; closed = Some dead_intent
    }
  ; { situation = "the install record names a store that does not exist"
    ; set_up =
        (fun dirs ->
          write_record
            dirs
            ~base_path:dirs.base
            ~external_store:(Filename.concat dirs.root "other-store.jsonl");
          no_check)
    ; before = []
    ; closed = None
    }
  ; { situation = "the install record names another store that is empty"
    ; set_up =
        (fun dirs ->
          let other = Filename.concat dirs.root "other-store.jsonl" in
          write_record dirs ~base_path:dirs.base ~external_store:other;
          write_private other "";
          let before = describe other in
          fun () -> Alcotest.(check string) "the other store is as it was" before (describe other))
    ; before = []
    ; closed = None
    }
  ]
;;

let a_run_goes_on_after_a_run_that_stopped recovery () =
  with_dirs (fun dirs ->
    let check_after = recovery.set_up dirs in
    let completed = completed_exn (run dirs) in
    check_installed ~before:recovery.before ~closed:recovery.closed dirs completed;
    check_after ())
;;

(* The record reached the log and the answer did not. A second run refuses,
   because the log holds a record, and the next boot promotes the intent. *)
let a_missing_answer_is_promoted_at_the_next_boot () =
  with_dirs (fun dirs ->
    let completed = completed_exn (run dirs) in
    let intent = intent_with completed.B.record_hash in
    write_private dirs.store (store_text [ S.Intent_pending intent ]);
    let requested = dirs.store in
    let before = touched ~requested dirs in
    refused "a second run" "Log_not_empty 1" (run dirs);
    check_touched "every place is as it was" before dirs ~requested;
    let probe = probe_of dirs in
    Alcotest.(check string) "the high-water mark" "matches" (value_name (H.judge probe));
    match H.settle probe with
    | Ok (H.Promote promoted) ->
      Alcotest.(check string)
        "the intent that the boot promotes"
        (S.to_line (S.Intent_pending intent))
        (S.to_line (S.Intent_pending promoted))
    | Ok (H.Nothing_to_settle | H.Abort _) | Error _ ->
      Alcotest.fail "the boot does not promote the intent")
;;

(* ---- writes that fail ---- *)

(* The directory of the store cannot be made. The install record is written
   before, so a second run finds it, and goes on once the directory can be made. *)
let a_store_that_cannot_be_created_leaves_the_record () =
  skip_for_superuser ();
  with_dirs (fun dirs ->
    let locked = Filename.concat dirs.root "locked" in
    Unix.mkdir locked 0o500;
    let dirs = { dirs with store = Filename.concat (Filename.concat locked "store") "external.jsonl" } in
    refused "the first run" "External_store_not_created" (run dirs);
    Alcotest.(check (option string)) "the install record names the store" (Some dirs.store) (read_record dirs);
    Alcotest.(check string) "no store" "absent" (describe dirs.store);
    Alcotest.(check string) "no log" "absent" (describe (log_file dirs));
    Unix.chmod locked 0o700;
    let completed = completed_exn (run dirs) in
    check_installed ~before:[] ~closed:None dirs completed)
;;

(* The install record cannot be written, so nothing after it is. *)
let an_install_record_that_cannot_be_written_stops_the_run () =
  skip_for_superuser ();
  with_dirs (fun dirs ->
    let locked = Filename.concat dirs.root "locked" in
    Unix.mkdir locked 0o500;
    let dirs = { dirs with config = Filename.concat locked "masc" } in
    refused "the run" "Install_record_not_written" (run dirs);
    Alcotest.(check string) "no store" "absent" (describe dirs.store);
    Alcotest.(check string) "no store directory" "absent" (describe (Filename.dirname dirs.store));
    Alcotest.(check string) "no log" "absent" (describe (log_file dirs)))
;;

(* ---- writes that fail: a file changes between the two steps ---- *)

let prepare_exn request =
  match B.prepare request with
  | Ok prepared -> prepared
  | Error error -> Alcotest.failf "the checks failed: %s" (B.error_to_string error)
;;

let append_to_file path text =
  Out_channel.with_open_gen
    [ Open_wronly; Open_append; Open_binary ]
    0o600
    path
    (fun channel -> Out_channel.output_string channel text)
;;

(* Another writer appends a record to the log after the checks. The intent was
   written before the record, so it is in the store, and the answer is not. The
   boot that reads the files sees the other record where the intent expected
   its own. *)
let a_log_that_moved_fails_after_the_intent () =
  with_dirs (fun dirs ->
    let prepared = prepare_exn (request dirs) in
    write_private (log_file dirs) (R.to_line dead_record ^ "\n");
    refused "the write" "Record_not_appended Diverged" (B.write prepared);
    Alcotest.(check string)
      "the store holds the intent and no answer"
      (store_text [ S.Intent_pending (intent_with (first_record at_ms).R.hash) ])
      (read_file dirs.store);
    Alcotest.(check string)
      "the log holds the other record only"
      (R.to_line dead_record ^ "\n")
      (read_file (log_file dirs));
    Alcotest.(check string)
      "the boot sees the record that is not the one of the intent"
      "mismatch Digest_differs"
      (value_name (H.judge (probe_of dirs)));
    refused "a call after it" "Log_not_empty 1" (run dirs))
;;

(* Another writer appends to the store after the checks. The intent is refused
   before the record, so the log is not written. A call after it goes on from the
   line that the other writer left. *)
let a_store_that_moved_fails_before_the_record () =
  with_dirs (fun dirs ->
    write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
    write_private dirs.store "";
    let prepared = prepare_exn (request dirs) in
    append_to_file dirs.store (S.to_line (S.Intent_pending dead_intent) ^ "\n");
    refused "the write" "Intent_not_written Diverged" (B.write prepared);
    Alcotest.(check string) "the log is not written" "absent" (describe (log_file dirs));
    Alcotest.(check string)
      "the store holds the line of the other writer only"
      (store_text [ S.Intent_pending dead_intent ])
      (read_file dirs.store);
    let completed = completed_exn (run dirs) in
    check_installed
      ~before:[ S.Intent_pending dead_intent ]
      ~closed:(Some dead_intent)
      dirs
      completed)
;;

(* Another writer gives up the pending intent after the checks. Nothing else is
   written, and a call after it goes on from the store as it is. *)
let a_store_that_moved_fails_before_the_dead_intent_is_given_up () =
  with_dirs (fun dirs ->
    write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
    write_private dirs.store (store_text [ S.Intent_pending dead_intent ]);
    let prepared = prepare_exn (request dirs) in
    append_to_file dirs.store (aborted_line dead_intent ^ "\n");
    refused "the write" "Dead_intent_not_closed Diverged" (B.write prepared);
    Alcotest.(check string) "the log is not written" "absent" (describe (log_file dirs));
    Alcotest.(check string)
      "the store holds the lines of the other writer only"
      (store_text [ S.Intent_pending dead_intent; S.Aborted_intent dead_intent ])
      (read_file dirs.store);
    let completed = completed_exn (run dirs) in
    check_installed
      ~before:[ S.Intent_pending dead_intent; S.Aborted_intent dead_intent ]
      ~closed:None
      dirs
      completed)
;;

(* Another bootstrap ran after the checks and wrote the install record.
   Replacing it would point the installation at a store without an answer, so
   the write stops before it writes anything. *)
let an_install_record_that_changed_is_not_replaced () =
  with_dirs (fun dirs ->
    let prepared = prepare_exn (request dirs) in
    let other = Filename.concat dirs.root "other-store.jsonl" in
    write_record dirs ~base_path:dirs.base ~external_store:other;
    let before = touched ~requested:dirs.store dirs in
    refused "the write" "Install_record_changed" (B.write prepared);
    check_touched "every place is as it was" before dirs ~requested:dirs.store;
    Alcotest.(check (option string))
      "the record still names the other store"
      (Some other)
      (read_record dirs))
;;

(* The install record that the checks read is gone at the write. *)
let an_install_record_that_was_removed_is_not_written_over_nothing () =
  with_dirs (fun dirs ->
    write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
    write_private dirs.store "";
    let prepared = prepare_exn (request dirs) in
    Sys.remove (record_file dirs);
    refused "the write" "Install_record_changed" (B.write prepared);
    Alcotest.(check string) "no record" "absent" (describe (record_file dirs));
    Alcotest.(check string) "the log is not written" "absent" (describe (log_file dirs)))
;;

(* A bootstrap that was written does not write again from the same checks. *)
let a_prepared_that_was_written_cannot_be_written_again () =
  with_dirs (fun dirs ->
    let prepared = prepare_exn (request dirs) in
    ignore (completed_exn (B.write prepared) : B.completed);
    let before = touched ~requested:dirs.store dirs in
    refused "the second write" "Install_record_changed" (B.write prepared);
    check_touched "every place is as it was" before dirs ~requested:dirs.store)
;;

(* Two checks that saw an empty installation, for two stores. The first write
   wins and the second leaves the install record and its store alone. *)
let two_checks_for_different_stores_do_not_both_write () =
  with_dirs (fun dirs ->
    let other = Filename.concat (Filename.concat dirs.root "other") "external.jsonl" in
    let first = prepare_exn (request dirs) in
    let second = prepare_exn { (request dirs) with B.external_store = other } in
    let completed = completed_exn (B.write first) in
    refused "the second write" "Install_record_changed" (B.write second);
    Alcotest.(check string) "the other store is not made" "absent" (describe other);
    check_installed ~before:[] ~closed:None dirs completed)
;;

(* The install record is written again when it names the path already, so that
   a record whose earlier write did not finish its sync is written whole. *)
let an_install_record_that_names_the_path_is_written_again () =
  with_dirs (fun dirs ->
    write_record dirs ~base_path:dirs.base ~external_store:dirs.store;
    let written = read_file (record_file dirs) in
    write_private (record_file dirs) (written ^ "\n\n");
    ignore (completed_exn (run dirs) : B.completed);
    Alcotest.(check string)
      "the record holds the bytes of a write"
      written
      (read_file (record_file dirs)))
;;

(* A file appears at the path of the store after the checks. The exclusive
   creation refuses it, and its bytes stay. *)
let a_store_that_appeared_is_not_taken () =
  with_dirs (fun dirs ->
    let prepared = prepare_exn (request dirs) in
    write_private dirs.store "an old store\n";
    refused "the write" "External_store_not_created" (B.write prepared);
    Alcotest.(check string) "its bytes" "an old store\n" (read_file dirs.store))
;;

(* ---- texts ---- *)

let contains ~sub text =
  let sub_length = String.length sub
  and length = String.length text in
  let rec at index =
    index + sub_length <= length
    && (String.equal (String.sub text index sub_length) sub || at (index + 1))
  in
  at 0
;;

(* Not the wording: the path, the count, or the hash that the one who reads a
   refusal needs to find the files. *)
let texts_name_what_they_are_about () =
  let hash = dead_record.R.hash in
  List.iter
    (fun (error, needle) ->
      Alcotest.(check bool)
        (error_name error ^ " names " ^ needle)
        true
        (contains ~sub:needle (B.error_to_string error)))
    [ ( B.External_store_path_invalid { path = "relative/store"; problem = B.Not_absolute }
      , "relative/store" )
    ; B.Path_not_inspected { path = "/p/store"; detail = "detail" }, "/p/store"
    ; B.External_store_in_the_way { path = "/p/store" }, "/p/store"
    ; B.Log_not_empty { lines = 7 }, "7"
    ; B.Not_a_fresh_installation { store = "/p/store"; value = H.Absent }, "/p/store"
    ; B.Install_record_changed { expected = Some "/p/before"; found = Some "/p/after" }, "/p/before"
    ; B.Install_record_changed { expected = Some "/p/before"; found = Some "/p/after" }, "/p/after"
    ; B.External_store_not_created { path = "/p/store"; detail = "detail" }, "/p/store"
    ; B.Answer_not_written { record_hash = hash; error = S.Writer_expired }, R.Hash.to_hex hash
    ]
;;

let () =
  Alcotest.run
    "authz_bootstrap"
    [ "first run", [ Alcotest.test_case "sets the installation up" `Quick a_first_run_sets_the_installation_up ]
    ; ( "refusals"
      , Alcotest.test_case "a second run" `Quick a_second_run_is_refused
        :: Alcotest.test_case
             "a log that went back names the lost commit"
             `Quick
             a_log_that_went_back_names_the_lost_commit
        :: Alcotest.test_case
             "a firmlink spelling of the installation"
             `Quick
             a_firmlink_spelling_of_the_installation_is_refused
        :: List.map
             (fun refusal ->
               Alcotest.test_case refusal.label `Quick (a_refusal_writes_nothing refusal))
             refusals )
    ; ( "recovery"
      , Alcotest.test_case
          "a missing answer is promoted at the next boot"
          `Quick
          a_missing_answer_is_promoted_at_the_next_boot
        :: List.map
             (fun recovery ->
               Alcotest.test_case
                 recovery.situation
                 `Quick
                 (a_run_goes_on_after_a_run_that_stopped recovery))
             recoveries )
    ; ( "failures"
      , [ Alcotest.test_case
            "a store that cannot be created leaves the record"
            `Quick
            a_store_that_cannot_be_created_leaves_the_record
        ; Alcotest.test_case
            "an install record that cannot be written stops the run"
            `Quick
            an_install_record_that_cannot_be_written_stops_the_run
        ; Alcotest.test_case
            "a log that moved fails after the intent"
            `Quick
            a_log_that_moved_fails_after_the_intent
        ; Alcotest.test_case
            "a store that moved fails before the record"
            `Quick
            a_store_that_moved_fails_before_the_record
        ; Alcotest.test_case
            "a store that moved fails before the dead intent is given up"
            `Quick
            a_store_that_moved_fails_before_the_dead_intent_is_given_up
        ; Alcotest.test_case
            "an install record that changed is not replaced"
            `Quick
            an_install_record_that_changed_is_not_replaced
        ; Alcotest.test_case
            "an install record that was removed is not written over nothing"
            `Quick
            an_install_record_that_was_removed_is_not_written_over_nothing
        ; Alcotest.test_case
            "a prepared that was written cannot be written again"
            `Quick
            a_prepared_that_was_written_cannot_be_written_again
        ; Alcotest.test_case
            "two checks for different stores do not both write"
            `Quick
            two_checks_for_different_stores_do_not_both_write
        ; Alcotest.test_case
            "an install record that names the path is written again"
            `Quick
            an_install_record_that_names_the_path_is_written_again
        ; Alcotest.test_case
            "a store that appeared is not taken"
            `Quick
            a_store_that_appeared_is_not_taken
        ] )
    ; "texts", [ Alcotest.test_case "name what they are about" `Quick texts_name_what_they_are_about ]
    ]
;;
