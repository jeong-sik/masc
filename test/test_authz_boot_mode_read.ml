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
      ; at_ms
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
  | Read.Refuse (first, rest) -> "refuse: " ^ String.concat "; " (List.map B.refusal_to_string (first :: rest))
  | Read.Multi_account_not_activatable -> "not activatable"
  | Read.Multi_account_not_served mode -> "not served: " ^ B.mode_to_string mode
;;

let decision = Alcotest.testable (fun fmt d -> Format.pp_print_string fmt (decision_label d)) ( = )
let check_decision name expected dirs = Alcotest.check decision name expected (Read.decide (input dirs))

(* ---- config_dir ---- *)

let test_config_dir () =
  let check name expected ~xdg_config_home ~home =
    Alcotest.(check (option string)) name expected (Read.config_dir ~xdg_config_home ~home)
  in
  check "absolute XDG" (Some "/x/masc") ~xdg_config_home:(Some "/x") ~home:(Some "/h");
  check "relative XDG falls back to HOME" (Some "/h/.config/masc") ~xdg_config_home:(Some "x") ~home:(Some "/h");
  check "empty XDG falls back to HOME" (Some "/h/.config/masc") ~xdg_config_home:(Some "") ~home:(Some "/h");
  check "nothing" None ~xdg_config_home:None ~home:None;
  check "empty HOME" None ~xdg_config_home:None ~home:(Some "")
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
    check_decision "unknown value refuses" (Read.Refuse (B.Unknown_account_mode {|"multi"|}, [])) dirs)
;;

(* ---- the table, on real installations ---- *)

let test_nothing_set_up () =
  with_dirs (fun dirs ->
    check_decision "no files" Read.Boot_single_user dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Single_user"}|};
    check_decision "Single_user" Read.Boot_single_user dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    check_decision "row 5" Read.Multi_account_not_activatable dirs)
;;

let test_bootstrapped () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    (* Row 7: the log, the record and the store agree. *)
    check_decision "row 7" (Read.Multi_account_not_served B.Multi_account) dirs;
    (* Row 3: a config cut while it was written does not lower the mode. *)
    write_config dirs {|{"enabled":true,"acc|};
    check_decision "row 3" (Read.Refuse (B.Downgraded_from_multi_account, [])) dirs)
;;

let test_restored_before_bootstrap () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    (* A restore of the base path from before the bootstrap: no log, no
       config, and the record and the store outside the base path. *)
    Sys.remove (L.path_of_base_path ~base_path:dirs.base);
    check_decision "row 2" (Read.Refuse (B.Rewound_before_bootstrap, [])) dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    check_decision "row 6" (Read.Refuse (B.Rewound_before_bootstrap, [])) dirs)
;;

let test_install_record_lost () =
  with_dirs (fun dirs ->
    bootstrap dirs;
    write_config dirs {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|};
    Sys.remove (install_record_file dirs);
    (* Row 8: the log made Multi_account and the high-water mark is absent. *)
    check_decision "row 8" (Read.Multi_account_not_served B.Multi_account_uncertain) dirs)
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
    (match Read.decide i with
     | Read.Refuse (B.External_store_unreadable _, []) -> ()
     | other -> Alcotest.failf "expected the store to be unreadable, got %s" (decision_label other));
    Alcotest.(check bool) "one message" true (List.length (Read.messages i (Read.decide i)) = 1))
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
    | Read.Refuse (B.External_store_unreadable _, []) -> ()
    | other -> Alcotest.failf "expected the store to be unreadable, got %s" (decision_label other))
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
    | Read.Refuse (B.Authorization_log_unreadable _, []) -> ()
    | other -> Alcotest.failf "expected an unreadable log, got %s" (decision_label other))
;;

let () =
  Alcotest.run
    "authz_boot_mode_read"
    [ "config dir", [ Alcotest.test_case "XDG rules" `Quick test_config_dir ]
    ; ( "config.json"
      , [ Alcotest.test_case "member shapes" `Quick test_member_shapes
        ; Alcotest.test_case "file" `Quick test_config_file
        ] )
    ; ( "installations"
      , [ Alcotest.test_case "nothing set up" `Quick test_nothing_set_up
        ; Alcotest.test_case "bootstrapped" `Quick test_bootstrapped
        ; Alcotest.test_case "restored before bootstrap" `Quick test_restored_before_bootstrap
        ; Alcotest.test_case "install record lost" `Quick test_install_record_lost
        ; Alcotest.test_case "config dir others can write" `Quick test_unreadable_config_dir
        ; Alcotest.test_case "log without a mode event" `Quick test_log_without_mode_event
        ; Alcotest.test_case "same, with no record" `Quick test_config_dir_others_can_write_without_record
        ] )
    ]
;;
