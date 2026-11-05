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

(* ---- an activation ---- *)

let an_activation_writes_the_bootstrap_and_one_admin_invitation () =
  with_dirs (fun dirs ->
    ask_for_multi_account dirs;
    let { A.workspace_id; invitation } = activated_exn dirs in
    let token = invitation.A.token in
    Alcotest.(check int) "the token is 32 bytes in hex" 64 (String.length token);
    Alcotest.(check bool) "the token is lowercase hex" true (is_lowercase_hex token);
    Alcotest.(check int)
      "the invitation expires a day after the clock"
      (at_ms + (24 * 60 * 60 * 1000))
      invitation.A.expires_at_ms;
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
      (match Authz_invite_state.find state.Authz_state.invites invitation.A.invite_id with
       | None -> Alcotest.fail "the invitation is not in the state"
       | Some found ->
         Alcotest.(check bool)
           "the digest of the token"
           true
           (E.Token_digest.equal found.Authz_invite_state.token_digest (E.Token_digest.of_token token));
         Alcotest.(check int) "the expiry" invitation.A.expires_at_ms found.Authz_invite_state.expires_at_ms;
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
    check_refused "the second activation" "Boot_stops" (activate dirs);
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
            "a boot that would stop"
            `Quick
            a_boot_that_would_stop_writes_nothing
        ; Alcotest.test_case "a second activation" `Quick a_second_activation_is_refused
        ] )
    ]
;;
