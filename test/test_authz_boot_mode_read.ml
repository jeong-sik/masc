(* What the boot reads for the account mode, on real files in a fresh temporary
   directory: config.json, the authorization log, the install record and the
   external store. Installations are made by the real Fresh_bootstrap, then
   taken back the way a restore or a lost file would. The config directory is
   an argument, so no case reads or writes the install record of the operator. *)

module B = Authz_boot_mode
module Read = Authz_boot_mode_read
module I = Authz_install_record
module L = Authz_log
module R = Authz_record

let workspace =
  match Authz_types.Workspace_id.of_string "workspace-1" with
  | Ok id -> id
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let at_ms = 1_700_000_000_000

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
  { base : string  (** The base path. It exists. *)
  ; config : string  (** The [masc] config directory. It does not exist. *)
  ; store : string  (** Where a bootstrap puts the store. *)
  }

(* The zones of the log and the store are [Eio.Mutex]es, so every case runs in
   an event loop. Directories are 0700, which the owner check of the install
   record needs. *)
let with_dirs f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-boot-mode-read-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        Unix.mkdir base 0o700;
        f
          { base
          ; config = Filename.concat root "config"
          ; store = Filename.concat (Filename.concat root "store") "external.jsonl"
          }))
;;

let write_file path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text);
  Unix.chmod path 0o600
;;

let write_config dirs text = write_file (Auth.auth_config_file dirs.base) text

let bootstrap dirs =
  match
    Authz_bootstrap.fresh_bootstrap
      { Authz_bootstrap.base_path = dirs.base
      ; config_dir = Some dirs.config
      ; external_store = dirs.store
      ; workspace_id = workspace
      ; now_ms = (fun () -> at_ms)
      }
  with
  | Ok _ -> ()
  | Error error -> Alcotest.failf "bootstrap refused: %s" (Authz_bootstrap.error_to_string error)
;;

let install_record_file dirs =
  match I.locate ~config_dir:(Some dirs.config) ~base_path:dirs.base with
  | Ok (I.Located record) -> I.file_path record
  | Ok I.No_config_dir -> Alcotest.fail "the config directory is known"
  | Error error -> Alcotest.fail (I.locate_error_to_string error)
;;

let input dirs = Read.input ~base_path:dirs.base ~config_dir:(Some dirs.config) ~anonymous_mutations:false

let decision_label = function
  | Read.Boot_single_user -> "boot single user"
  | Read.Stop (Read.Refuse (first, rest)) ->
    "refuse: " ^ String.concat "; " (List.map B.refusal_to_string (first :: rest))
  | Read.Stop Read.Activation_requested -> "activation requested"
  | Read.Stop (Read.Multi_account_not_served mode) -> "not served: " ^ B.mode_to_string mode
;;

let refused = function
  | Read.Stop (Read.Refuse (first, rest)) -> Some (first, rest)
  | Read.Boot_single_user
  | Read.Stop (Read.Activation_requested | Read.Multi_account_not_served _) -> None
;;

(* The first reason of a refusal, for the cases that care which check stopped
   the boot and not what the detail says. *)
let check_refused_by name expected dirs =
  let d = Read.decide (input dirs) in
  match refused d with
  | Some (first, _) when expected first -> ()
  | Some _ | None -> Alcotest.failf "%s: got %s" name (decision_label d)
;;

let log_unreadable = function
  | B.Authorization_log_unreadable _ -> true
  | _ -> false
;;

let store_unreadable = function
  | B.External_store_unreadable _ -> true
  | _ -> false
;;

let decision = Alcotest.testable (fun fmt d -> Format.pp_print_string fmt (decision_label d)) ( = )
let check_decision name expected dirs = Alcotest.check decision name expected (Read.decide (input dirs))

(* ---- the config directory ---- *)

(* One resolver serves the install record and the default base path record, so
   a bootstrap and a boot cannot look in two places. *)
let test_config_dir () =
  let check name expected ~xdg_config_home ~home =
    Alcotest.(check (option string))
      name
      expected
      (Env_config_core.masc_config_dir_of ~xdg_config_home ~home)
  in
  check "absolute XDG" (Some "/x/masc") ~xdg_config_home:(Some "/x") ~home:(Some "/h");
  check "XDG with spaces" (Some "/x/masc") ~xdg_config_home:(Some " /x ") ~home:(Some "/h");
  check "relative XDG falls back to HOME" (Some "/h/.config/masc") ~xdg_config_home:(Some "x") ~home:(Some "/h");
  check "empty XDG falls back to HOME" (Some "/h/.config/masc") ~xdg_config_home:(Some "") ~home:(Some "/h");
  check "nothing" None ~xdg_config_home:None ~home:None;
  check "empty HOME" None ~xdg_config_home:None ~home:(Some " ")
;;

(* ---- the member, from parsed JSON ---- *)

let requested = Alcotest.testable (fun fmt r -> Format.pp_print_string fmt (match r with
  | B.Not_set -> "not set"
  | B.Requested mode -> Masc_domain.account_mode_label mode
  | B.Unknown_value text -> "unknown " ^ text)) ( = )

let test_member_shapes () =
  let check name expected text =
    Alcotest.check requested name expected (Read.requested_of_json (Yojson.Safe.from_string text))
  in
  check "absent" B.Not_set {|{"enabled":true}|};
  check "Multi_account" (B.Requested Masc_domain.Multi_account) {|{"account_mode":"Multi_account"}|};
  check "null" (B.Unknown_value "null") {|{"account_mode":null}|};
  check "number" (B.Unknown_value "1") {|{"account_mode":1}|};
  check "object" (B.Unknown_value {|{"mode":"Multi_account"}|}) {|{"account_mode":{"mode":"Multi_account"}}|};
  check "other case" (B.Unknown_value {|"multi_account"|}) {|{"account_mode":"multi_account"}|};
  (* A reader that took the first member would boot this as a single user. *)
  check
    "twice"
    (B.Unknown_value {|"Single_user", "Multi_account"|})
    {|{"account_mode":"Single_user","account_mode":"Multi_account"}|};
  check "top-level array" B.Not_set {|[{"account_mode":"Multi_account"}]|};
  check "top-level null" B.Not_set {|null|}
;;

(* ---- config.json on disk ---- *)

let settings_label = function
  | B.Settings_read { enabled; require_token } -> Printf.sprintf "read enabled=%b require_token=%b" enabled require_token
  | B.Settings_unreadable _ -> "unreadable"
;;

let check_config name (expected_requested, expected_settings) dirs =
  let got_requested, got_settings = Read.read_config ~base_path:dirs.base in
  Alcotest.check requested (name ^ ", member") expected_requested got_requested;
  Alcotest.(check string) (name ^ ", settings") expected_settings (settings_label got_settings)
;;

let default_settings =
  settings_label
    (B.Settings_read
       { enabled = Masc_domain.default_auth_config.enabled
       ; require_token = Masc_domain.default_auth_config.require_token
       })
;;

let test_config_file () =
  with_dirs (fun dirs ->
    check_config "missing file" (B.Not_set, default_settings) dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    check_config "Multi_account" (B.Requested Masc_domain.Multi_account, "read enabled=true require_token=true") dirs;
    write_config dirs {|{"enabled":true,"account_m|};
    check_config "cut file" (B.Not_set, "unreadable") dirs;
    write_config dirs {|[1]|};
    check_config "top-level array" (B.Not_set, "unreadable") dirs;
    (* The member is read even when the decoder refuses the other fields. *)
    write_config dirs {|{"enabled":"yes","account_mode":"multi"}|};
    check_config "unknown value, wrong fields" (B.Unknown_value {|"multi"|}, "unreadable") dirs;
    check_decision "unknown value refuses" (Read.Stop (Read.Refuse (B.Unknown_account_mode {|"multi"|}, []))) dirs)
;;

(* ---- the table, on real installations ---- *)

let test_nothing_set_up () =
  with_dirs (fun dirs ->
    check_decision "no files" Read.Boot_single_user dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Single_user"}|};
    check_decision "Single_user" Read.Boot_single_user dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    check_decision "row 5" (Read.Stop Read.Activation_requested) dirs)
;;

let test_bootstrapped () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    (* Row 7: the log, the record and the store agree. *)
    check_decision "row 7" (Read.Stop (Read.Multi_account_not_served B.Multi_account)) dirs;
    (* Row 3: a config cut while it was written does not lower the mode. *)
    write_config dirs {|{"enabled":true,"acc|};
    check_decision "row 3" (Read.Stop (Read.Refuse (B.Downgraded_from_multi_account, []))) dirs)
;;

let test_restored_before_bootstrap () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    (* A restore of the base path from before the bootstrap: no log, no
       config, and the record and the store outside the base path. *)
    Sys.remove (L.path_of_base_path ~base_path:dirs.base);
    check_decision "row 2" (Read.Stop (Read.Refuse (B.Rewound_before_bootstrap, []))) dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    check_decision "row 6" (Read.Stop (Read.Refuse (B.Rewound_before_bootstrap, []))) dirs)
;;

let test_install_record_lost () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    Sys.remove (install_record_file dirs);
    (* Row 8: the log made Multi_account and the high-water mark is absent. *)
    check_decision "row 8" (Read.Stop (Read.Multi_account_not_served B.Multi_account_uncertain)) dirs)
;;

(* The way back that Read.single_user_again gives. The lock file of the log
   stays: a boot makes it anyway. *)
let test_single_user_again () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    Sys.remove (L.path_of_base_path ~base_path:dirs.base);
    Sys.remove dirs.store;
    Sys.remove (install_record_file dirs);
    write_config dirs {|{"enabled":true,"require_token":true}|};
    check_decision "row 1" Read.Boot_single_user dirs)
;;

let test_unreadable_config_dir () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_dirs (fun dirs ->
    bootstrap dirs;
    Sys.remove (L.path_of_base_path ~base_path:dirs.base);
    (* A config directory that others can write fails the owner check of the
       install record. The boot cannot tell a rewind from a fresh base path, and
       says why instead of calling it a rewind. *)
    Unix.chmod dirs.config 0o770;
    let i = input dirs in
    match Read.decide i with
    | Read.Stop (Read.Refuse (B.External_store_unreadable _, []) as stop) ->
      Alcotest.(check int) "one message" 0 (List.length (snd (Read.messages i stop)))
    | other -> Alcotest.failf "expected the store to be unreadable, got %s" (decision_label other))
;;

(* The same refusal on a base path that never had a bootstrap: the boot reads
   the install record on every boot, so it cannot tell this base path from one
   restored to before its bootstrap. masc makes the directory 0700. *)
let test_config_dir_others_can_write_without_record () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_dirs (fun dirs ->
    Unix.mkdir dirs.config 0o700;
    Unix.chmod dirs.config 0o770;
    match Read.decide (input dirs) with
    | Read.Stop (Read.Refuse (B.External_store_unreadable _, [])) -> ()
    | other -> Alcotest.failf "expected the store to be unreadable, got %s" (decision_label other))
;;

let write_log_line dirs line = write_file (L.path_of_base_path ~base_path:dirs.base) (line ^ "\n")

(* A single-user boot of a base path that has never had a log or a store makes
   no directory and no lock file. *)
let test_boot_writes_nothing () =
  with_dirs (fun dirs ->
    let auth_dir = Filename.dirname (L.path_of_base_path ~base_path:dirs.base) in
    check_decision "no files" Read.Boot_single_user dirs;
    Alcotest.(check bool) "no auth directory" false (Sys.file_exists auth_dir);
    write_config dirs {|{"enabled":true,"require_token":true}|};
    check_decision "a config" Read.Boot_single_user dirs;
    Alcotest.(check (list string)) "only the config" [ "config.json" ] (Array.to_list (Sys.readdir auth_dir)))
;;

let test_corrupt_log () =
  with_dirs (fun dirs ->
    write_log_line dirs "not a record";
    match Read.decide (input dirs) with
    | Read.Stop (Read.Refuse (B.Authorization_log_unreadable _, [])) -> ()
    | other -> Alcotest.failf "expected an unreadable log, got %s" (decision_label other))
;;

let test_corrupt_store () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    Sys.remove (L.path_of_base_path ~base_path:dirs.base);
    Out_channel.with_open_gen [ Open_append; Open_binary ] 0o600 dirs.store (fun channel ->
      Out_channel.output_string channel "not an entry\n");
    match Read.decide (input dirs) with
    | Read.Stop (Read.Refuse (B.External_store_unreadable _, [])) -> ()
    | other -> Alcotest.failf "expected an unreadable store, got %s" (decision_label other))
;;

let test_store_gone () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    let store_dir = Filename.dirname dirs.store in
    (* The store, its lock file, and the directory that held them. *)
    remove_tree store_dir;
    (* Row 8 with an absent mark: the record points where no store is. *)
    check_decision "row 8" (Read.Stop (Read.Multi_account_not_served B.Multi_account_uncertain)) dirs;
    Alcotest.(check bool) "no store directory made" false (Sys.file_exists store_dir))
;;

let test_log_of_another_bootstrap () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    (* The log of another installation: its first record is not the one the
       store committed. *)
    let body =
      match Authz_mode_event.to_body { Authz_mode_event.event = Authz_mode_event.Fresh_bootstrap; workspace_id = workspace } with
      | Ok body -> body
      | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
    in
    let record =
      match
        R.make ~head:R.genesis ~at_ms:(at_ms + 1) ~author:Authz_records.Author.Local_operator ~kind:R.Kind.Mode_event ~body
      with
      | Ok record -> record
      | Error _ -> Alcotest.fail "fixture record refused"
    in
    write_log_line dirs (R.to_line record);
    let i = input dirs in
    (match i.B.high_water with
     | B.Judged (Authz_high_water.Mismatch _) -> ()
     | B.Judged (Authz_high_water.Absent | Authz_high_water.Matches) | B.Store_unreadable _ ->
       Alcotest.fail "expected a mismatch");
    let stop = Read.Multi_account_not_served B.Multi_account_uncertain in
    Alcotest.check decision "row 8" (Read.Stop stop) (Read.decide i);
    Alcotest.(check bool)
      "the mismatch is in the message"
      true
      (snd (Read.messages i stop) <> [ Read.single_user_again ]))
;;

let test_boot_entry () =
  with_dirs (fun dirs ->
    let boot () = Read.boot ~base_path:dirs.base ~config_dir:(Some dirs.config) ~anonymous_mutations:false in
    Alcotest.(check bool) "single user" true (Result.is_ok (boot ()));
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    (match boot () with
     | Ok (_ : Read.single_user) -> Alcotest.fail "a Multi_account request booted"
     | Error (first, _) -> Alcotest.(check bool) "a reason" true (first <> ""));
    write_config dirs {|{"enabled":true,"require_token":true}|};
    Alcotest.(check bool) "anonymous mutations do not matter to a single user" true
      (Result.is_ok (Read.boot ~base_path:dirs.base ~config_dir:(Some dirs.config) ~anonymous_mutations:true)))
;;

(* Plan D2-2: a host tool judges from presence alone and writes nothing. *)
let test_tool () =
  with_dirs (fun dirs ->
    let tool () = Read.tool ~base_path:dirs.base ~config_dir:(Some dirs.config) in
    let auth_dir = Filename.dirname (L.path_of_base_path ~base_path:dirs.base) in
    Alcotest.(check bool) "nothing set up" true (Result.is_ok (tool ()));
    Alcotest.(check bool) "no auth directory" false (Sys.file_exists auth_dir);
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    (match tool () with
     | Ok (_ : Read.single_user) -> Alcotest.fail "a Multi_account request ran a tool"
     | Error (first, _) -> Alcotest.(check bool) "a reason" true (first <> ""));
    bootstrap dirs;
    let listing () = List.sort String.compare (Array.to_list (Sys.readdir auth_dir)) in
    let before = listing () in
    (match tool () with
     | Ok (_ : Read.single_user) -> Alcotest.fail "a bootstrapped base path ran a tool"
     | Error (_, found) -> Alcotest.(check int) "the log and the install record" 2 (List.length found));
    Alcotest.(check (list string)) "no file opened or made" before (listing ()))
;;

let test_log_without_mode_event () =
  with_dirs (fun dirs ->
    let body =
      match Authz_body.of_yojson (`Assoc [ "note", `String "repair" ]) with
      | Ok body -> body
      | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
    in
    let record =
      match
        R.make
          ~head:R.genesis
          ~at_ms
          ~author:Authz_records.Author.Local_operator
          ~kind:R.Kind.Local_recovery
          ~body
      with
      | Ok record -> record
      | Error _ -> Alcotest.fail "fixture record refused"
    in
    write_file (L.path_of_base_path ~base_path:dirs.base) (R.to_line record ^ "\n");
    match Read.decide (input dirs) with
    | Read.Stop (Read.Refuse (B.Authorization_log_unreadable _, [])) -> ()
    | other -> Alcotest.failf "expected an unreadable log, got %s" (decision_label other))
;;

(* A record in the chain after the bootstrap, of a kind that no layer reads. The
   store matches the log, so the fold of the log is what refuses it, at its
   line, for its kind. *)
let test_record_after_the_bootstrap () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    let body =
      match Authz_body.of_yojson (`Assoc [ "note", `String "repair" ]) with
      | Ok body -> body
      | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
    in
    let path = L.path_of_base_path ~base_path:dirs.base in
    (match L.open_at_start ~path ~init:() ~step:(fun () _record -> (Ok () : (unit, unit) result)) with
     | Error _ -> Alcotest.fail "the log of the bootstrap did not open"
     | Ok (log, (), _recovered) ->
       let appended =
         L.with_writer log (fun writer head ->
           match
             R.make
               ~head
               ~at_ms:(at_ms + 1)
               ~author:Authz_records.Author.Local_operator
               ~kind:R.Kind.Local_recovery
               ~body
           with
           | Error _ -> Alcotest.fail "fixture record refused"
           | Ok record -> L.append writer [ record ])
       in
       (match appended with
        | Ok (Ok _) -> ()
        | Ok (Error error) -> Alcotest.failf "the record was not appended: %s" (L.append_error_to_string error)
        | Error _ -> Alcotest.fail "the log stopped"));
    let expected =
      L.open_error_to_string
        Authz_state.refusal_to_string
        (L.Fold_refused { path; line_number = 2; reason = Authz_state.Kind_not_read R.Kind.Local_recovery })
    in
    (match (input dirs).B.log_mode with
     | B.Log_unreadable detail -> Alcotest.(check string) "the line and the kind" expected detail
     | B.No_mode_event | B.Made_multi_account | B.Made_off -> Alcotest.fail "expected an unreadable log");
    check_refused_by "a record that no layer reads" log_unreadable dirs)
;;

(* ---- whether a file is there ---- *)

let presence_label = function
  | Authz_presence.Not_there -> "not there"
  | Authz_presence.There -> "there"
  | Authz_presence.Cannot_check _ -> "cannot check"
;;

let check_presence name expected path =
  Alcotest.(check string) name expected (presence_label (Authz_presence.of_path path))
;;

let test_presence () =
  with_dirs (fun dirs ->
    let at name = Filename.concat (Filename.dirname dirs.base) name in
    check_presence "nothing" "not there" (at "missing");
    check_presence "below a missing directory" "not there" (Filename.concat (at "missing") "file");
    write_file (at "file") "x";
    check_presence "a file" "there" (at "file");
    Unix.symlink (at "nowhere") (at "dangling");
    check_presence "a dangling link itself" "there" (at "dangling");
    check_presence "below a dangling link" "cannot check" (Filename.concat (at "dangling") "file");
    check_presence
      "two levels below a dangling link"
      "cannot check"
      (Filename.concat (Filename.concat (at "dangling") "dir") "file");
    Unix.mkdir (at "real") 0o700;
    Unix.symlink (at "real") (at "resolving");
    check_presence "below a link that resolves" "not there" (Filename.concat (at "resolving") "file");
    check_presence "a NUL byte" "cannot check" (at "file\000x");
    if Unix.geteuid () <> 0
    then (
      Unix.mkdir (at "closed") 0o700;
      Unix.chmod (at "closed") 0o000;
      check_presence "below a directory that cannot be searched" "cannot check" (Filename.concat (at "closed") "file")))
;;

(* A restore of the base path from before its bootstrap, with the directory of
   the store behind a link to a volume that is not mounted. The store may be
   there, so the boot does not call it absent. *)
let test_store_behind_a_dangling_link () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    Sys.remove (L.path_of_base_path ~base_path:dirs.base);
    let store_dir = Filename.dirname dirs.store in
    remove_tree store_dir;
    Unix.symlink (Filename.concat (Filename.dirname store_dir) "unmounted") store_dir;
    check_refused_by "a dangling link on the way to the store" store_unreadable dirs)
;;

(* The same for the directory of the log. config.json is in that directory too,
   so nothing else would show that the base path was set up. *)
let test_log_behind_a_dangling_link () =
  with_dirs (fun dirs ->
    let auth_dir = Filename.dirname (L.path_of_base_path ~base_path:dirs.base) in
    Fs_compat.mkdir_p (Filename.dirname auth_dir);
    Unix.symlink (Filename.concat (Filename.dirname dirs.base) "unmounted") auth_dir;
    check_refused_by "a dangling link on the way to the log" log_unreadable dirs)
;;

let test_log_cannot_be_checked () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_dirs (fun dirs ->
    write_config dirs {|{"enabled":true,"require_token":true}|};
    Unix.chmod (Filename.dirname (L.path_of_base_path ~base_path:dirs.base)) 0o000;
    check_refused_by "an auth directory that cannot be searched" log_unreadable dirs)
;;

(* Something other than a file where the log is: the check calls it there, and
   the open refuses it. *)
let test_not_a_file_where_the_log_is () =
  with_dirs (fun dirs ->
    let log = L.path_of_base_path ~base_path:dirs.base in
    Fs_compat.mkdir_p log;
    check_refused_by "a directory" log_unreadable dirs;
    Unix.rmdir log;
    Unix.symlink (Filename.concat dirs.base "nowhere") log;
    check_refused_by "a dangling link" log_unreadable dirs)
;;

(* A restore of the base path from before its bootstrap, with an install record
   whose store path ends in a separator and a dangling link where the store was.
   [lstat] follows the link behind the last separator and answers ENOENT, and
   [Filename.dirname] steps over that name, so a reader that took the path as
   it is would find no store and boot as a single user. *)
let test_record_with_a_separator_at_the_end () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    Sys.remove (L.path_of_base_path ~base_path:dirs.base);
    Sys.remove dirs.store;
    Unix.symlink (Filename.concat (Filename.dirname dirs.store) "unmounted") dirs.store;
    write_file
      (install_record_file dirs)
      (Yojson.Safe.to_string
         (`Assoc
             [ "base_path", `String (Unix.realpath dirs.base)
             ; "external_store", `String (dirs.store ^ "/")
             ])
       ^ "\n");
    check_refused_by "a store path that ends in a separator" store_unreadable dirs)
;;

(* The store is judged against the log, so a log that cannot be read leaves the
   store unjudged as well. The decision stops at the log first, so the column is
   checked on the input. *)
let test_corrupt_log_beside_a_store () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    (match (input dirs).B.high_water with
     | B.Judged Authz_high_water.Matches -> ()
     | B.Judged (Authz_high_water.Absent | Authz_high_water.Mismatch _) ->
       Alcotest.fail "the store of the bootstrap does not match its log"
     | B.Store_unreadable reason -> Alcotest.failf "the store of the bootstrap was not judged: %s" reason);
    write_log_line dirs "not a record";
    check_refused_by "the log is unreadable" log_unreadable dirs;
    match (input dirs).B.high_water with
    | B.Store_unreadable _ -> ()
    | B.Judged _ -> Alcotest.fail "a store was judged against a log that cannot be read")
;;

(* A log with no lines has no mode event (design 5.1). *)
let test_empty_log () =
  with_dirs (fun dirs ->
    write_file (L.path_of_base_path ~base_path:dirs.base) "";
    check_decision "an empty log" Read.Boot_single_user dirs)
;;

let () =
  Alcotest.run
    "authz_boot_mode_read"
    [ "config dir", [ Alcotest.test_case "XDG rules" `Quick test_config_dir ]
    ; "presence", [ Alcotest.test_case "of_path" `Quick test_presence ]
    ; ( "config.json"
      , [ Alcotest.test_case "member shapes" `Quick test_member_shapes
        ; Alcotest.test_case "file" `Quick test_config_file
        ] )
    ; ( "installations"
      , [ Alcotest.test_case "nothing set up" `Quick test_nothing_set_up
        ; Alcotest.test_case "bootstrapped" `Quick test_bootstrapped
        ; Alcotest.test_case "restored before bootstrap" `Quick test_restored_before_bootstrap
        ; Alcotest.test_case "install record lost" `Quick test_install_record_lost
        ; Alcotest.test_case "single user again" `Quick test_single_user_again
        ; Alcotest.test_case "config dir others can write" `Quick test_unreadable_config_dir
        ; Alcotest.test_case "log without a mode event" `Quick test_log_without_mode_event
        ; Alcotest.test_case "record after the bootstrap" `Quick test_record_after_the_bootstrap
        ; Alcotest.test_case "a single user boot writes nothing" `Quick test_boot_writes_nothing
        ; Alcotest.test_case "corrupt log" `Quick test_corrupt_log
        ; Alcotest.test_case "corrupt store" `Quick test_corrupt_store
        ; Alcotest.test_case "store gone" `Quick test_store_gone
        ; Alcotest.test_case "log of another bootstrap" `Quick test_log_of_another_bootstrap
        ; Alcotest.test_case "boot entry" `Quick test_boot_entry
        ; Alcotest.test_case "host tool" `Quick test_tool
        ; Alcotest.test_case "same, with no record" `Quick test_config_dir_others_can_write_without_record
        ; Alcotest.test_case "store behind a dangling link" `Quick test_store_behind_a_dangling_link
        ; Alcotest.test_case
            "record with a separator at the end"
            `Quick
            test_record_with_a_separator_at_the_end
        ; Alcotest.test_case "log behind a dangling link" `Quick test_log_behind_a_dangling_link
        ; Alcotest.test_case "log cannot be checked" `Quick test_log_cannot_be_checked
        ; Alcotest.test_case "not a file where the log is" `Quick test_not_a_file_where_the_log_is
        ; Alcotest.test_case "corrupt log beside a store" `Quick test_corrupt_log_beside_a_store
        ; Alcotest.test_case "empty log" `Quick test_empty_log
        ] )
    ]
;;
