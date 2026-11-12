(* The host side of Service credentials on real files in a fresh temporary
   directory. On an installation the activation made active, an issued token
   acts as its service until it is revoked, and the list shows each credential
   with its status and no secret. A refused call writes nothing. The config
   directory is an argument, so no case reads or writes the install record of
   the operator. *)

module A = Authz_activation
module H = Authz_service_credential_host
module S = Authz_service_credential
module State = Authz_service_credential_state
module Token = Authz_credential_token.Service_credential
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
    let root = Filename.temp_dir "authz-service-credential-host-" "" in
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

let ask_for_multi_account dirs =
  let path = Auth.auth_config_file dirs.base in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel ->
    Out_channel.output_string
      channel
      {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|});
  Unix.chmod path 0o600
;;

let activate dirs =
  match
    A.activate
      ~base_path:dirs.base
      ~config_dir:(Some dirs.config)
      ~external_store:dirs.store
      ~anonymous_mutations:false
      ~now_ms
  with
  | Ok (_ : A.activated) -> ()
  | Error error -> Alcotest.failf "the activation was refused: %s" (A.error_to_string error)
;;

let issue dirs service =
  H.issue
    ~base_path:dirs.base
    ~config_dir:(Some dirs.config)
    ~anonymous_mutations:false
    ~now_ms
    ~service
;;

let revoke dirs credential =
  H.revoke
    ~base_path:dirs.base
    ~config_dir:(Some dirs.config)
    ~anonymous_mutations:false
    ~now_ms
    ~credential
;;

let list dirs =
  H.list ~base_path:dirs.base ~config_dir:(Some dirs.config) ~anonymous_mutations:false ~now_ms
;;

let ok_exn label = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%s was refused: %s" label (H.error_to_string error)
;;

let error_name : H.error -> string = function
  | H.Not_active _ -> "Not_active"
  | H.Zone_not_opened _ -> "Zone_not_opened"
  | H.Service_id_invalid _ -> "Service_id_invalid"
  | H.Credential_id_invalid _ -> "Credential_id_invalid"
  | H.Not_issued _ -> "Not_issued"
  | H.Not_revoked _ -> "Not_revoked"
;;

let check_refused label expected = function
  | Ok _ -> Alcotest.failf "%s went through" label
  | Error error -> Alcotest.(check string) label expected (error_name error)
;;

let log_path dirs = Authz_log.path_of_base_path ~base_path:dirs.base
let read_file path = In_channel.with_open_bin path In_channel.input_all
let id_text token = Authz_types.Service_credential_id.to_string (Token.id token)

let status_name = function
  | State.Open -> "open"
  | State.Revoked -> "revoked"
;;

(* What the request gate reads: the token against the state of a zone opened
   afresh, as the next boot opens it, on a snapshot the zone could be trusted for. *)
let authenticate dirs token =
  match Z.open_at_start ~now_ms ~log_path:(log_path dirs) ~store_path:dirs.store with
  | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
  | Ok zone ->
    (match Z.read zone with
     | Error uncertain ->
       Alcotest.failf "zone cannot be trusted: %s" (Z.uncertain_to_string uncertain)
     | Ok trusted -> S.authenticate trusted token)
;;

let check_acts label dirs token ~service =
  match authenticate dirs token with
  | Error refusal -> Alcotest.failf "%s does not act: %s" label (S.refusal_to_string refusal)
  | Ok { S.service_id; credential_id } ->
    Alcotest.(check string)
      (label ^ " acts as its service")
      service
      (Authz_types.Service_id.to_string service_id);
    Alcotest.(check string)
      (label ^ " with its credential")
      (id_text token)
      (Authz_types.Service_credential_id.to_string credential_id)
;;

let an_issued_token_acts_as_its_service_until_it_is_revoked () =
  with_dirs (fun dirs ->
    ask_for_multi_account dirs;
    activate dirs;
    let sync = ok_exn "the first issue" (issue dirs "librarian-sync") in
    let mirror = ok_exn "the second issue" (issue dirs "board-mirror") in
    check_acts "the first token" dirs sync ~service:"librarian-sync";
    check_acts "the second token" dirs mirror ~service:"board-mirror";
    ok_exn "the revoke" (revoke dirs (id_text sync));
    (match authenticate dirs sync with
     | Error S.Ended -> ()
     | Error refusal ->
       Alcotest.failf
         "the revoked token is refused as %s, not as ended"
         (S.refusal_to_string refusal)
     | Ok (_ : S.signed_in) -> Alcotest.fail "the revoked token still acts");
    check_acts "the other token after the revoke" dirs mirror ~service:"board-mirror";
    let listed =
      List.map
        (fun { H.credential_id; service_id; issued_at_ms; status } ->
          Alcotest.(check int) "issued at the time of its record" at_ms issued_at_ms;
          ( Authz_types.Service_credential_id.to_string credential_id
          , Authz_types.Service_id.to_string service_id
          , status_name status ))
        (ok_exn "the list" (list dirs))
    in
    Alcotest.(check (list (triple string string string)))
      "every credential, in the order of the ids"
      (List.sort
         compare
         [ id_text sync, "librarian-sync", "revoked"; id_text mirror, "board-mirror", "open" ])
      listed)
;;

let nothing_is_written_before_the_activation () =
  with_dirs (fun dirs ->
    check_refused "an issue with no config.json" "Not_active" (issue dirs "librarian-sync");
    ask_for_multi_account dirs;
    check_refused "an issue before the activation" "Not_active" (issue dirs "librarian-sync");
    check_refused "a revoke before the activation" "Not_active" (revoke dirs "cred-1");
    check_refused "a list before the activation" "Not_active" (list dirs);
    Alcotest.(check bool) "no log" false (Sys.file_exists (log_path dirs));
    Alcotest.(check bool) "no store" false (Sys.file_exists dirs.store))
;;

let a_refused_call_writes_nothing () =
  with_dirs (fun dirs ->
    ask_for_multi_account dirs;
    activate dirs;
    let revoked = id_text (ok_exn "the issue" (issue dirs "librarian-sync")) in
    ok_exn "the revoke" (revoke dirs revoked);
    let log = read_file (log_path dirs) in
    let store = read_file dirs.store in
    check_refused "a service name with a space" "Service_id_invalid" (issue dirs "librarian sync");
    check_refused "a credential id with a slash" "Credential_id_invalid" (revoke dirs "../cred");
    (match revoke dirs "cred-never-issued" with
     | Error
         (H.Not_revoked
            (S.Commit_failed (Z.Refused (Authz_state.Service_credential (State.Not_issued id)))))
       ->
       Alcotest.(check string)
         "an id no credential has"
         "cred-never-issued"
         (Authz_types.Service_credential_id.to_string id)
     | Error error -> Alcotest.failf "an unknown id is refused as: %s" (H.error_to_string error)
     | Ok () -> Alcotest.fail "an unknown id was revoked");
    (match revoke dirs revoked with
     | Error
         (H.Not_revoked
            (S.Commit_failed
              (Z.Refused (Authz_state.Service_credential (State.Already_revoked id)))))
       ->
       Alcotest.(check string)
         "the revoked credential"
         revoked
         (Authz_types.Service_credential_id.to_string id)
     | Error error -> Alcotest.failf "a second revoke is refused as: %s" (H.error_to_string error)
     | Ok () -> Alcotest.fail "a revoked credential was revoked again");
    Alcotest.(check string) "the log is as it was" log (read_file (log_path dirs));
    Alcotest.(check string) "the store is as it was" store (read_file dirs.store))
;;

let () =
  Alcotest.run
    "authz_service_credential_host"
    [ ( "issue and revoke"
      , [ Alcotest.test_case
            "a token acts until it is revoked"
            `Quick
            an_issued_token_acts_as_its_service_until_it_is_revoked
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case
            "nothing before the activation"
            `Quick
            nothing_is_written_before_the_activation
        ; Alcotest.test_case "a refused call writes nothing" `Quick a_refused_call_writes_nothing
        ] )
    ]
;;
