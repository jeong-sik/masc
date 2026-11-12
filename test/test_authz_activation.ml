(* The host-local activation on real files in a fresh temporary directory: it
   writes only where config.json asks for Multi_account and nothing was set up,
   and then the log holds the bootstrap and one open Admin invitation whose
   digest is that of the token it returns. The config directory is an argument,
   so no case reads or writes the install record of the operator. *)

module A = Authz_activation
module E = Authz_invite_event
module L = Authz_log
module Z = Authz_zone

let at_ms = 1_700_000_000_000
let now_ms () = at_ms

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
  { base : string  (** The base path. It exists. *)
  ; config : string  (** The [masc] config directory. It does not exist. *)
  ; store : string  (** Where the activation puts the store. *)
  }

(* The zones are [Eio.Mutex]es, so every case runs in an event loop.
   Directories are 0700, which the owner check of the install record needs. *)
let with_dirs f =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-activation-" "" in
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

let ask_for_multi_account dirs =
  write_file
    (Auth.auth_config_file dirs.base)
    {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|}
;;

let activate ?(anonymous_mutations = false) dirs =
  A.activate
    ~base_path:dirs.base
    ~config_dir:(Some dirs.config)
    ~external_store:dirs.store
    ~anonymous_mutations
    ~now_ms
;;

let error_name : A.error -> string = function
  | A.Not_asked -> "Not_asked"
  | A.Config_unreadable _ -> "Config_unreadable"
  | A.Already_active -> "Already_active"
  | A.Turned_off -> "Turned_off"
  | A.Boot_stops _ -> "Boot_stops"
  | A.Workspace_id_not_built _ -> "Workspace_id_not_built"
  | A.Bootstrap_failed _ -> "Bootstrap_failed"
  | A.Invitation_not_written _ -> "Invitation_not_written"
;;

let activated_exn dirs =
  match activate dirs with
  | Ok activated -> activated
  | Error error -> Alcotest.failf "the activation was refused: %s" (A.error_to_string error)
;;

let check_refused label expected result =
  match result with
  | Ok (_ : A.activated) -> Alcotest.failf "%s: the activation went through" label
  | Error error -> Alcotest.(check string) label expected (error_name error)
;;

let log_path dirs = L.path_of_base_path ~base_path:dirs.base
let read_file path = In_channel.with_open_bin path In_channel.input_all
let count_lines text = List.length (String.split_on_char '\n' text) - 1

let contains ~sub text =
  let sub_length = String.length sub in
  let rec at index =
    index + sub_length <= String.length text
    && (String.equal (String.sub text index sub_length) sub || at (index + 1))
  in
  at 0
;;

let is_lowercase_hex text =
  String.for_all
    (function
      | '0' .. '9' | 'a' .. 'f' -> true
      | _ -> false)
    text
;;

(* The link with an empty base is the path, [#], and the token. *)
let token_of invitation =
  let prefix = A.invitation_path ^ "#" in
  let link = A.link ~base_url:"" invitation in
  if not (String.starts_with ~prefix link)
  then Alcotest.failf "the link %s does not start with %s" link prefix;
  String.sub link (String.length prefix) (String.length link - String.length prefix)
;;

(* ---- an activation ---- *)

let an_activation_writes_the_bootstrap_and_one_admin_invitation () =
  with_dirs (fun dirs ->
    ask_for_multi_account dirs;
    let { A.workspace_id; invitation } = activated_exn dirs in
    let token = token_of invitation in
    Alcotest.(check string)
      "the link"
      ("https://masc.example/accounts/invite#" ^ token)
      (A.link ~base_url:"https://masc.example" invitation);
    Alcotest.(check int) "the token is 32 bytes in hex" 64 (String.length token);
    Alcotest.(check bool) "the token is lowercase hex" true (is_lowercase_hex token);
    Alcotest.(check int)
      "the invitation expires a day after the clock"
      (at_ms + (24 * 60 * 60 * 1000))
      (A.expires_at_ms invitation);
    Alcotest.(check int) "two records" 2 (count_lines (read_file (log_path dirs)));
    Alcotest.(check bool)
      "the token is not on disk"
      false
      (contains ~sub:token (read_file (log_path dirs) ^ read_file dirs.store));
    match Z.open_at_start ~now_ms ~log_path:(log_path dirs) ~store_path:dirs.store with
    | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
    | Ok zone ->
      let state = (Z.snapshot zone).Z.state in
      (match state.Authz_state.mode with
       | Authz_mode_state.Multi_account id ->
         Alcotest.(check bool)
           "the workspace of the activation"
           true
           (Authz_types.Workspace_id.equal id workspace_id)
       | Authz_mode_state.Off _ | Authz_mode_state.Not_bootstrapped ->
         Alcotest.fail "the log does not hold Multi_account");
      (match Authz_invite_state.find state.Authz_state.invites (A.invite_id invitation) with
       | None -> Alcotest.fail "the invitation is not in the state"
       | Some found ->
         Alcotest.(check bool)
           "the digest of the token"
           true
           (E.Token_digest.equal found.Authz_invite_state.token_digest (E.Token_digest.of_token token));
         Alcotest.(check int)
           "the expiry"
           (A.expires_at_ms invitation)
           found.Authz_invite_state.expires_at_ms;
         Alcotest.(check bool)
           "an Admin invitation"
           true
           (match found.Authz_invite_state.role with
            | E.Admin -> true
            | E.Member -> false);
         Alcotest.(check bool)
           "open"
           true
           (match found.Authz_invite_state.status with
            | Authz_invite_state.Open -> true
            | Authz_invite_state.Revoked | Authz_invite_state.Consumed _ -> false)))
;;

(* ---- refusals ---- *)

let nothing_is_written_unless_config_json_asks () =
  with_dirs (fun dirs ->
    check_refused "no config.json" "Not_asked" (activate dirs);
    write_file (Auth.auth_config_file dirs.base) {|{"enabled":true,"require_token":true}|};
    check_refused "a config.json with no account mode" "Not_asked" (activate dirs);
    Alcotest.(check bool) "no log" false (Sys.file_exists (log_path dirs));
    Alcotest.(check bool) "no store" false (Sys.file_exists dirs.store);
    Alcotest.(check bool) "no config directory" false (Sys.file_exists dirs.config))
;;

(* A config.json the decoder refuses boots a single user, and the refusal
   says why instead of reading as a config that asks for nothing. *)
let a_config_json_that_does_not_decode_is_named () =
  with_dirs (fun dirs ->
    write_file (Auth.auth_config_file dirs.base) "{";
    check_refused "a config.json that does not decode" "Config_unreadable" (activate dirs);
    Alcotest.(check bool) "no log" false (Sys.file_exists (log_path dirs));
    Alcotest.(check bool) "no store" false (Sys.file_exists dirs.store))
;;

(* Design 5.1 refuses Multi_account with anonymous mutations, and an activation
   would leave an installation that does not boot. *)
let a_boot_that_would_stop_writes_nothing () =
  with_dirs (fun dirs ->
    ask_for_multi_account dirs;
    check_refused "anonymous mutations" "Boot_stops" (activate ~anonymous_mutations:true dirs);
    Alcotest.(check bool) "no log" false (Sys.file_exists (log_path dirs));
    Alcotest.(check bool) "no store" false (Sys.file_exists dirs.store))
;;

let a_second_activation_is_refused () =
  with_dirs (fun dirs ->
    ask_for_multi_account dirs;
    let (_ : A.activated) = activated_exn dirs in
    let log = read_file (log_path dirs) in
    let store = read_file dirs.store in
    check_refused "the second activation" "Already_active" (activate dirs);
    Alcotest.(check string) "the log is as it was" log (read_file (log_path dirs));
    Alcotest.(check string) "the store is as it was" store (read_file dirs.store))
;;

(* ---- one more invitation ---- *)

let invite dirs =
  A.invite ~base_path:dirs.base ~config_dir:(Some dirs.config) ~anonymous_mutations:false ~now_ms
;;

let invite_error_name : A.invite_error -> string = function
  | A.Not_activated -> "Not_activated"
  | A.Accounts_turned_off -> "Accounts_turned_off"
  | A.Not_served_as_active _ -> "Not_served_as_active"
  | A.Store_not_located _ -> "Store_not_located"
  | A.Invite_not_written _ -> "Invite_not_written"
;;

let check_invite_refused label expected result =
  match result with
  | Ok (_ : A.invitation) -> Alcotest.failf "%s: the invitation was written" label
  | Error error -> Alcotest.(check string) label expected (invite_error_name error)
;;

let an_invite_adds_one_open_admin_invitation () =
  with_dirs (fun dirs ->
    ask_for_multi_account dirs;
    let { A.invitation = first; workspace_id = _ } = activated_exn dirs in
    match invite dirs with
    | Error error -> Alcotest.failf "the invite was refused: %s" (A.invite_error_to_string error)
    | Ok second ->
      Alcotest.(check int) "three records" 3 (count_lines (read_file (log_path dirs)));
      Alcotest.(check bool)
        "another invite id"
        false
        (Authz_types.Invite_id.equal (A.invite_id first) (A.invite_id second));
      Alcotest.(check bool)
        "another token"
        false
        (String.equal (token_of first) (token_of second));
      (match Z.open_at_start ~now_ms ~log_path:(log_path dirs) ~store_path:dirs.store with
       | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
       | Ok zone ->
         let invites = (Z.snapshot zone).Z.state.Authz_state.invites in
         List.iter
           (fun (label, (invitation : A.invitation)) ->
             match Authz_invite_state.find invites (A.invite_id invitation) with
             | Some { Authz_invite_state.status = Authz_invite_state.Open; role = E.Admin; token_digest; _ } ->
               Alcotest.(check bool)
                 (label ^ ": the digest of its token")
                 true
                 (E.Token_digest.equal token_digest (E.Token_digest.of_token (token_of invitation)))
             | Some _ | None -> Alcotest.failf "%s is not an open Admin invitation" label)
           [ "the first invitation", first; "the second invitation", second ]))
;;

let an_invite_needs_an_active_installation () =
  with_dirs (fun dirs ->
    check_invite_refused "no config.json" "Not_activated" (invite dirs);
    ask_for_multi_account dirs;
    check_invite_refused "before the activation" "Not_activated" (invite dirs);
    Alcotest.(check bool) "no log" false (Sys.file_exists (log_path dirs));
    Alcotest.(check bool) "no store" false (Sys.file_exists dirs.store);
    let (_ : A.activated) = activated_exn dirs in
    let log = read_file (log_path dirs) in
    Sys.remove dirs.store;
    check_invite_refused "a store that is gone" "Not_served_as_active" (invite dirs);
    Alcotest.(check string) "the log is as it was" log (read_file (log_path dirs));
    Alcotest.(check bool) "no store is made" false (Sys.file_exists dirs.store))
;;

(* The local operator commits Off through the zone, as masc auth off does. *)
let turn_off dirs workspace_id =
  let zone =
    match Authz_zone.open_at_start ~now_ms ~log_path:(log_path dirs) ~store_path:dirs.store with
    | Ok zone -> zone
    | Error error -> Alcotest.failf "the zone did not open: %s" (Authz_zone.open_error_to_string error)
  in
  let body =
    match Authz_mode_event.to_body { Authz_mode_event.event = Authz_mode_event.Off; workspace_id } with
    | Ok body -> body
    | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
  in
  match
    Authz_zone.commit
      zone
      { Authz_zone.author = Authz_records.Author.Local_operator
      ; kind = Authz_record.Kind.Mode_event
      ; body
      }
  with
  | Ok (_ : Authz_zone.committed) -> ()
  | Error error -> Alcotest.failf "Off was refused: %s" (Authz_zone.error_to_string error)
;;

(* Design 10.5: after Off a boot starts a single user, and neither a bootstrap
   nor an invitation writes anything. *)
let nothing_is_written_after_off () =
  with_dirs (fun dirs ->
    ask_for_multi_account dirs;
    let { A.workspace_id; invitation = (_ : A.invitation) } = activated_exn dirs in
    turn_off dirs workspace_id;
    write_file (Auth.auth_config_file dirs.base) {|{"enabled":true,"require_token":true}|};
    let log = read_file (log_path dirs) in
    let store = read_file dirs.store in
    check_refused "an activation" "Turned_off" (activate dirs);
    check_invite_refused "an invitation" "Accounts_turned_off" (invite dirs);
    Alcotest.(check string) "the log is as it was" log (read_file (log_path dirs));
    Alcotest.(check string) "the store is as it was" store (read_file dirs.store))
;;

let () =
  Alcotest.run
    "authz_activation"
    [ ( "activation"
      , [ Alcotest.test_case
            "the bootstrap and one Admin invitation"
            `Quick
            an_activation_writes_the_bootstrap_and_one_admin_invitation
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case
            "nothing unless config.json asks"
            `Quick
            nothing_is_written_unless_config_json_asks
        ; Alcotest.test_case
            "a config.json that does not decode"
            `Quick
            a_config_json_that_does_not_decode_is_named
        ; Alcotest.test_case
            "a boot that would stop"
            `Quick
            a_boot_that_would_stop_writes_nothing
        ; Alcotest.test_case "a second activation" `Quick a_second_activation_is_refused
        ] )
    ; ( "invite"
      , [ Alcotest.test_case
            "one more open Admin invitation"
            `Quick
            an_invite_adds_one_open_admin_invitation
        ; Alcotest.test_case
            "an active installation"
            `Quick
            an_invite_needs_an_active_installation
        ] )
    ; "after Off", [ Alcotest.test_case "nothing is written" `Quick nothing_is_written_after_off ]
    ]
;;
