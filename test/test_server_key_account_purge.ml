(* The removal of a person's key account (RFC
   a-persons-api-key-is-their-own-provider-account 3.6), over a zone on real
   files whose records the real writers made: whose account it removes, what
   it leaves of a removal that did not go through, and what the start of the
   server ends. *)

open Authz_types
module Login = Server_setup_account_login
module Layout = Runtime_account_home_layout
module Files = Runtime_key_account_files
module Purge = Server_key_account_purge
module Purges = Authz_purge_state
module Event = Authz_purge_event
module B = Authz_bootstrap
module E = Authz_invite_event
module Z = Authz_zone

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "a fixture value was refused"
;;

let start_ms = 1_700_000_000_000
let workspace = get (Workspace_id.of_string "workspace-1")
let claude_code = get (Integration_id.of_string "claude_code")

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

let rec private_dirs path =
  if not (Sys.file_exists path)
  then (
    private_dirs (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

(* A zone a fresh bootstrap made, opened as a server opens it. *)
let with_env_zone work () =
  Eio_main.run (fun env ->
    let root = Unix.realpath (Filename.temp_dir "server-key-account-purge-" "") in
    Fun.protect
      ~finally:(fun () ->
        (* A tree that was not removed is said, and does not take the place
           of the failure of the case. *)
        try remove_tree root with
        | Unix.Unix_error (error, call, path) ->
          Printf.eprintf "the tree of the case stays: %s %s: %s\n" call path (Unix.error_message error)
        | Sys_error detail -> Printf.eprintf "the tree of the case stays: %s\n" detail)
      (fun () ->
        let base_path = Filename.concat root "base" in
        Unix.mkdir base_path 0o700;
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        let now_ms () = start_ms in
        (match
           B.fresh_bootstrap
             { B.base_path
             ; config_dir = Some (Filename.concat root "config")
             ; external_store = store
             ; workspace_id = workspace
             ; now_ms
             }
         with
         | Ok (_ : B.completed) -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (B.error_to_string error));
        match Z.open_at_start ~now_ms ~log_path:(Authz_log.path_of_base_path ~base_path) ~store_path:store with
        | Ok zone -> work ~env ~zone ~base_path
        | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)))
;;

let with_zone work =
  with_env_zone (fun ~env:(_ : Eio_unix.Stdenv.base) ~zone ~base_path -> work ~zone ~base_path)
;;

let commit zone ~author ~kind body =
  match Z.commit zone { Z.author; kind; body } with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "a record was refused: %s" (Z.error_detail error)
;;

(* One person joins through an invitation. *)
let admit zone ~name ~hex =
  let user_id = get (User_id.of_string (String.make 32 hex)) in
  let invite_id = get (Invite_id.of_string ("invite-" ^ name)) in
  let namespace = get (Account_home_namespace.of_string ("ns-" ^ name)) in
  commit
    zone
    ~author:Authz_records.Author.Local_operator
    ~kind:Authz_record.Kind.Invite
    (get
       (E.to_body
          (E.Issued
             { invite_id
             ; token_digest = E.Token_digest.of_token ("token-" ^ name)
             ; expires_at_ms = start_ms + 3_600_000
             ; role = E.Admin
             })));
  commit
    zone
    ~author:(Authz_records.Author.Authenticated (Principal.Human user_id))
    ~kind:Authz_record.Kind.Admission
    (get
       (Authz_admission_event.to_body
          { Authz_admission_event.user_id
          ; identity = get (Authz_external_identity.google ~sub:name)
          ; through = Authz_admission_event.Invite invite_id
          ; membership = { workspace_id = workspace; account_home_namespace = namespace }
          }));
  { Login.zone; user_id; namespace }
;;

type someone =
  { person : Login.person
  ; account : Provider_account_id.t
  }

let runtime_root_of ~base_path (who : someone) =
  Layout.person_runtime_root ~base_path ~namespace:who.person.namespace
;;

(* The key file and the home of the account, as the registration of a key
   makes them. The keys of this file are made up. *)
let make_files ~base_path (who : someone) =
  let runtime_root = runtime_root_of ~base_path who in
  private_dirs runtime_root;
  match Runtime_api_key_file.key_of_string "sk-test-a-key" with
  | None -> Alcotest.fail "a fixture key was refused"
  | Some key ->
    (match Files.make ~runtime_root ~account_id:who.account ~generation:Key_generation.first key with
     | Ok () -> ()
     | Error (Files.Home_not_made detail) -> Alcotest.failf "the home was not made: %s" detail
     | Error (Files.Key_not_written (_ : Runtime_api_key_file.write_error)) ->
       Alcotest.fail "the key was not written")
;;

let linked = function
  | Ok () -> ()
  | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error)
;;

(* One person joins and registers a key: the record, and then the files. *)
let with_key zone ~base_path ~name ~hex =
  let person = admit zone ~name ~hex in
  let account = get (Provider_account_id.of_string (String.make 64 hex)) in
  linked
    (Authz_provider_account.link_key
       zone
       ~user_id:person.Login.user_id
       ~provider_account_id:account
       ~integration_id:claude_code);
  let who = { person; account } in
  make_files ~base_path who;
  who
;;

let files_there label ~base_path (who : someone) expected =
  match Files.present ~runtime_root:(runtime_root_of ~base_path who) ~account_id:who.account with
  | Ok there -> Alcotest.(check bool) label expected there
  | Error detail -> Alcotest.failf "%s: not looked at: %s" label detail
;;

let account_of (who : someone) : Event.account =
  { owner = who.person.user_id; provider_account_id = who.account }
;;

let status_name (who : someone) =
  match Purges.find_account (Z.snapshot who.person.zone).Z.state.Authz_state.purges (account_of who) with
  | None -> "none"
  | Some Purges.Account_pending -> "pending"
  | Some Purges.Account_purged -> "purged"
  | Some (Purges.Account_failed { failed_stage = Event.Key_not_removed }) -> "failed:key_not_removed"
  | Some (Purges.Account_failed { failed_stage = Event.Home_not_removed }) -> "failed:home_not_removed"
;;

let stands label who expected = Alcotest.(check string) label expected (status_name who)

let result_name = function
  | Ok () -> "removed"
  | Error Purge.Not_found -> "not_found"
  | Error Purge.Not_a_key_account -> "not_a_key_account"
  | Error Purge.Account_busy -> "account_busy"
  | Error (Purge.Not_started error) -> "not_started: " ^ Authz_purge.error_detail error
  | Error (Purge.Not_ended error) -> "not_ended: " ^ Authz_purge.error_detail error
  | Error (Purge.Files_not_removed Event.Key_not_removed) -> "files_not_removed:key_not_removed"
  | Error (Purge.Files_not_removed Event.Home_not_removed) -> "files_not_removed:home_not_removed"
;;

(* [by] asks for the removal of the account of [of_]. *)
let removes label ~base_path ~(by : someone) ~(of_ : someone) expected =
  Alcotest.(check string) label expected (result_name (Purge.remove ~person:by.person ~base_path of_.account))
;;

(* Whether the judgment of a verification and of a turn gives the account to
   its owner ({!Authz_provider_account.availability}). *)
let spent label (who : someone) expected =
  let given =
    Result.is_ok
      (Authz_provider_account.availability
         (Z.snapshot who.person.zone).Z.state
         ~user_id:who.person.user_id
         who.account)
  in
  Alcotest.(check bool) label expected given
;;

(* Runs [work] while a call of the account of [who] runs. *)
let during_a_call_of (who : someone) work =
  match
    Runtime_account_call.one_call_of who.account ~busy:() (fun (_ : Runtime_account_call.t) ->
      work ();
      Ok ())
  with
  | Ok () -> ()
  | Error () -> Alcotest.fail "the call of the account was not taken"
;;

let started (who : someone) =
  match Authz_purge.start who.person.zone ~user_id:who.person.user_id (Event.Provider_account (account_of who)) with
  | Ok () -> ()
  | Error error -> Alcotest.failf "the purge was not started: %s" (Authz_purge.error_detail error)
;;

let test_removed =
  with_zone (fun ~zone ~base_path ->
    let alice = with_key zone ~base_path ~name:"alice" ~hex:'a' in
    let bob = with_key zone ~base_path ~name:"bob" ~hex:'b' in
    spent "her account, before its removal" alice true;
    removes "her account, by her" ~base_path ~by:alice ~of_:alice "removed";
    files_there "her key and her home" ~base_path alice false;
    stands "the purge of her account" alice "purged";
    spent "her account, after its removal" alice false;
    files_there "the key and the home of another person" ~base_path bob true;
    stands "the purge of his account" bob "none";
    spent "his account" bob true;
    removes "her account, by her again" ~base_path ~by:alice ~of_:alice "not_found")
;;

(* The account of another person answers as one that is not there, whether a
   call of it runs or not, and nothing of it changes. *)
let test_not_ones_own =
  with_zone (fun ~zone ~base_path ->
    let alice = with_key zone ~base_path ~name:"alice" ~hex:'a' in
    let bob = with_key zone ~base_path ~name:"bob" ~hex:'b' in
    removes "her account, by him" ~base_path ~by:bob ~of_:alice "not_found";
    during_a_call_of alice (fun () ->
      removes "her account, by him, while a call of it runs" ~base_path ~by:bob ~of_:alice "not_found";
      removes "her account, by her, while a call of it runs" ~base_path ~by:alice ~of_:alice "account_busy");
    files_there "her key and her home" ~base_path alice true;
    stands "the purge of her account" alice "none";
    spent "her account" alice true;
    removes "her account, by her, after the call" ~base_path ~by:alice ~of_:alice "removed")
;;

(* A removal whose start is in the log and whose end is not, as a commit that
   answered an error after its record went in leaves it: its owner asks
   again, and it goes on from the files. *)
let test_started =
  with_zone (fun ~zone ~base_path ->
    let alice = with_key zone ~base_path ~name:"alice" ~hex:'a' in
    started alice;
    spent "her account, its removal started" alice false;
    files_there "her key and her home" ~base_path alice true;
    removes "her account, by her" ~base_path ~by:alice ~of_:alice "removed";
    stands "the purge of her account" alice "purged";
    files_there "her key and her home, after it" ~base_path alice false)
;;

(* An account that holds a login is not removed here. *)
let test_login_account =
  with_zone (fun ~zone ~base_path ->
    let person = admit zone ~name:"carol" ~hex:'c' in
    let account = get (Provider_account_id.of_string (String.make 64 'c')) in
    linked (Authz_provider_account.link zone ~user_id:person.Login.user_id ~provider_account_id:account);
    let carol = { person; account } in
    removes "an account that holds a login" ~base_path ~by:carol ~of_:carol "not_a_key_account";
    stands "its purge" carol "none";
    spent "the account" carol true;
    (* Nor by a caller that holds the call of the account, as a registration
       holds the call of the account it made: the removal reads the kind of
       the account itself, and the home of a login is not its to remove. *)
    let in_the_call (who : someone) ~of_ =
      result_name
        (Runtime_account_call.one_call_of of_ ~busy:Purge.Account_busy (fun in_call ->
           Purge.remove_in_call in_call ~person:who.person ~base_path of_))
    in
    Alcotest.(check string)
      "an account that holds a login, inside its call"
      "not_a_key_account"
      (in_the_call carol ~of_:account);
    stands "its purge, after that" carol "none";
    spent "the account, after that" carol true;
    let dave = { person = admit zone ~name:"dave" ~hex:'d'; account } in
    Alcotest.(check string)
      "the account of another person, inside its call"
      "not_found"
      (in_the_call dave ~of_:account);
    stands "its purge, after another asked" carol "none")
;;

(* A removal that leaves the key says so in the log, nothing spends the
   account, and its owner ends it by asking again. The mode that keeps the key
   in place does not keep the superuser from it, so the case is skipped when
   the superuser runs it. *)
let test_key_stays =
  with_zone (fun ~zone ~base_path ->
    if Unix.geteuid () <> 0
    then (
      let alice = with_key zone ~base_path ~name:"alice" ~hex:'a' in
      let keys =
        match Layout.key_dir ~runtime_root:(runtime_root_of ~base_path alice) ~account_id:alice.account with
        | Ok keys -> keys
        | Error detail -> Alcotest.failf "the layout spelled no key folder: %s" detail
      in
      Unix.chmod keys 0o500;
      removes "an account whose key folder is not written" ~base_path ~by:alice ~of_:alice
        "files_not_removed:key_not_removed";
      stands "its purge" alice "failed:key_not_removed";
      files_there "its files" ~base_path alice true;
      spent "the account" alice false;
      Unix.chmod keys 0o700;
      removes "the same account, its folder written again" ~base_path ~by:alice ~of_:alice "removed";
      stands "its purge" alice "purged";
      files_there "its files" ~base_path alice false)
    else Alcotest.skip ())
;;

(* What the start of a server ends: a removal that was started and not ended,
   and one that went through whose files a restore brought back. A removal
   that failed, and an account no removal began of, are left. *)
let test_resume =
  with_env_zone (fun ~env ~zone ~base_path ->
    let alice = with_key zone ~base_path ~name:"alice" ~hex:'a' in
    let bob = with_key zone ~base_path ~name:"bob" ~hex:'b' in
    let carol = with_key zone ~base_path ~name:"carol" ~hex:'c' in
    let dave = with_key zone ~base_path ~name:"dave" ~hex:'d' in
    (* Through the one function a start calls, so a start that drops the
       removals of key accounts fails here. *)
    let resume () = Eio.Switch.run (fun sw -> Server_stopped_work.start ~sw ~env ~zone ~base_path) in
    (* A server that stopped after the record of the start. *)
    started alice;
    started dave;
    (* A removal that failed. *)
    started bob;
    (match
       Authz_purge.failed
         zone
         (Event.Account_not_purged { account = account_of bob; failed_stage = Event.Key_not_removed })
     with
     | Ok () -> ()
     | Error error -> Alcotest.failf "the failure was not recorded: %s" (Authz_purge.error_detail error));
    during_a_call_of dave (fun () -> resume ());
    stands "a pending removal" alice "purged";
    files_there "its files" ~base_path alice false;
    stands "a pending removal whose account had a call running" dave "pending";
    files_there "its files" ~base_path dave true;
    stands "a removal that failed" bob "failed:key_not_removed";
    files_there "its files" ~base_path bob true;
    stands "an account no removal began of" carol "none";
    files_there "its files" ~base_path carol true;
    resume ();
    stands "the pending removal, at the next start" dave "purged";
    files_there "its files" ~base_path dave false;
    (* A restore of a backup brings back the files of a removed account. *)
    make_files ~base_path alice;
    files_there "the files of a removed account, restored" ~base_path alice true;
    resume ();
    files_there "the restored files, after a start" ~base_path alice false;
    stands "its purge" alice "purged";
    (* The owner of the failed removal asks again. *)
    removes "the removal that failed, by its owner" ~base_path ~by:bob ~of_:bob "removed";
    files_there "its files" ~base_path bob false)
;;

let () =
  Alcotest.run
    "server_key_account_purge"
    [ ( "remove"
      , [ Alcotest.test_case "the key and the home of one's own account" `Quick test_removed
        ; Alcotest.test_case "not the account of another person" `Quick test_not_ones_own
        ; Alcotest.test_case "a removal that was started and not ended" `Quick test_started
        ; Alcotest.test_case "not an account that holds a login" `Quick test_login_account
        ; Alcotest.test_case "the key that does not go" `Quick test_key_stays
        ] )
    ; "resume", [ Alcotest.test_case "what a stopped server left" `Quick test_resume ]
    ]
;;
