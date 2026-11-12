(* Whether a CLI may start on an account after the accounts of the
   installation were turned off (design 5.1 row 4, 10.5). The installation is
   made by the real bootstrap and holds one person whose account, Runtime and
   Keeper the real writers recorded. The accounts are then turned off as
   masc auth off turns them off. The boot reads the base path as a
   server boot does, and the access published is the one a server publishes.
   The access is published once per process, so the executable has one case
   and it runs in order. *)

open Authz_types
module Access = Runtime_account_access
module Account = Runtime_official_account
module Layout = Runtime_account_home_layout
module Z = Authz_zone

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "a fixture value was refused"
;;

let get_text = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "a fixture step failed: %s" detail
;;

let start_ms = 1_700_000_000_000
let workspace = get (Workspace_id.of_string "workspace-1")

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

let commit zone ~author ~kind body =
  match Z.commit zone { Z.author; kind; body } with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "a record was refused: %s" (Z.error_detail error)
;;

type person =
  { user_id : User_id.t
  ; account : Provider_account_id.t
  ; runtime : Runtime_id.t
  ; keeper : string
  ; home : string  (** The Claude Code home of [account], as the layout spells it. *)
  }

(* The person joins through an invitation, links one account, makes a Runtime
   on it, and makes a Keeper on that Runtime, each through its writer. *)
let person zone ~base_path ~name ~hex =
  let user_id = get (User_id.of_string (String.make 32 hex)) in
  let invite_id = get (Invite_id.of_string ("invite-" ^ name)) in
  let namespace = get (Account_home_namespace.of_string ("ns-" ^ name)) in
  commit
    zone
    ~author:Authz_records.Author.Local_operator
    ~kind:Authz_record.Kind.Invite
    (get
       (Authz_invite_event.to_body
          (Authz_invite_event.Issued
             { invite_id
             ; token_digest = Authz_invite_event.Token_digest.of_token ("token-" ^ name)
             ; expires_at_ms = start_ms + 3_600_000
             ; role = Authz_invite_event.Admin
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
  let account = get (Provider_account_id.of_string ("account-" ^ name)) in
  (match Authz_provider_account.link zone ~user_id ~provider_account_id:account with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
  let runtime = get (Runtime_id.of_string ("account-" ^ name ^ ".model")) in
  (match
     Authz_runtime.make
       zone
       ~user_id
       ~provider_account_id:account
       ~runtime_id:runtime
       ~self_effects:Effect.(Set.of_list [ Read_state; Invoke_model; Use_tool ])
       ~draw:(fun () -> "grant-" ^ name)
   with
   | Ok (_ : Grant_id.t) -> ()
   | Error error -> Alcotest.fail (Authz_runtime.error_detail error));
  let keeper = "keeper-" ^ name in
  let keeper_id = get (Keeper_id.of_string keeper) in
  let turn_scope =
    { Authorization_scope.runtimes = Runtime_scope.all
    ; channels = Channel_scope.only (Channel.Set.of_list Channel.[ Autonomous; Direct ])
    ; allowed_effects = Effect_scope.all
    }
  in
  (match Authz_keeper.make zone ~user_id ~keeper_id ~turn_scope ~draw:(fun () -> "policy-" ^ name) with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
  (match Authz_keeper.assign zone ~user_id ~keeper_id ~runtime_id:runtime with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
  let runtime_root = Layout.person_runtime_root ~base_path ~namespace in
  Fs_compat.mkdir_p runtime_root;
  let home =
    get_text
      (Layout.home ~runtime_root Layout.Claude_home ~account_id:(Provider_account_id.to_string account))
  in
  Fs_compat.mkdir_p home;
  { user_id; account; runtime; keeper; home }
;;

let captured home =
  get_text (Account.capture ~client:Account.Claude_code ~declaration:(Some home))
;;

let allowed label request captured =
  match Access.authorize request (Access.seal captured) with
  | Ok authorized ->
    Alcotest.(check bool)
      (label ^ ": the authorized account is the one sealed")
      true
      (Account.same (Access.account authorized) captured)
  | Error refusal -> Alcotest.failf "%s: refused: %s" label (Access.refusal_to_string refusal)
;;

let refused label request captured expected =
  match Access.authorize request (Access.seal captured) with
  | Ok (_ : Account.claude_code Access.authorized) -> Alcotest.failf "%s: authorized" label
  | Error refusal ->
    if not (expected refusal)
    then
      Alcotest.failf "%s: refused for another reason: %s" label (Access.refusal_to_string refusal)
;;

let turn ~keeper ~runtime =
  Access.Keeper_turn
    { keeper_name = keeper
    ; channel = Channel.Autonomous
    ; pat = Authz_types.Pat_binding.Not_pat
    ; runtime_id = runtime
    }
;;

let operator_keeper = "keeper-operator"
let operator_runtime = "operator.model"

let test_turned_off () =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "runtime-account-access-off-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base_path = Filename.concat root "base" in
        Unix.mkdir base_path 0o700;
        let config_dir = Some (Filename.concat root "config") in
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        let now_ms () = start_ms in
        (match
           Authz_bootstrap.fresh_bootstrap
             { Authz_bootstrap.base_path; config_dir; external_store = store; workspace_id = workspace; now_ms }
         with
         | Ok (_ : Authz_bootstrap.completed) -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (Authz_bootstrap.error_to_string error));
        let zone =
          match
            Z.open_at_start
              ~now_ms
              ~log_path:(Authz_log.path_of_base_path ~base_path)
              ~store_path:store
          with
          | Ok zone -> zone
          | Error error -> Alcotest.failf "zone not opened: %s" (Z.open_error_to_string error)
        in
        let alice = person zone ~base_path ~name:"alice" ~hex:'a' in
        (match Authz_off.turn_off ~base_path ~config_dir ~now_ms with
         | Ok (_ : Workspace_id.t) -> ()
         | Error error -> Alcotest.failf "Off was refused: %s" (Authz_off.error_to_string error));
        (* No config.json asks for nothing, so the boot reads row 4. *)
        let single_user =
          match Authz_boot_mode_read.boot ~base_path ~config_dir ~anonymous_mutations:false with
          | Ok (Authz_boot_mode_read.Single_user single_user) -> single_user
          | Ok (Authz_boot_mode_read.Multi_account (_ : Authz_boot_mode_read.multi_account)) ->
            Alcotest.fail "the boot found a multi-account installation after the Off"
          | Error (first, rest) ->
            Alcotest.failf "the boot refused: %s" (String.concat "; " (first :: rest))
        in
        (match Access.publish (Access.Single_user single_user) with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Access.publish_error_to_string error));
        let operator_home =
          get_text
            (Layout.home
               ~runtime_root:(Common.masc_dir_from_base_path ~base_path)
               Layout.Claude_home
               ~account_id:"operator")
        in
        Fs_compat.mkdir_p operator_home;
        let operator = captured operator_home in
        let alice_account = captured alice.home in
        (* The person's Keeper runs no turn, even on a Runtime of the operator. *)
        refused "the person's Keeper" (turn ~keeper:alice.keeper ~runtime:operator_runtime) operator (function
          | Access.Off_keeper keeper_id -> String.equal (Keeper_id.to_string keeper_id) alice.keeper
          | _ -> false);
        (* No turn runs on the person's Runtime, even for a Keeper of the operator. *)
        refused
          "the person's Runtime"
          (turn ~keeper:operator_keeper ~runtime:(Runtime_id.to_string alice.runtime))
          operator
          (function
            | Access.Off_runtime runtime_id -> Runtime_id.equal runtime_id alice.runtime
            | _ -> false);
        (* No client starts on the person's home, for a turn or for the operator. *)
        let on_person_home = function
          | Access.Off_person_home -> true
          | _ -> false
        in
        refused
          "a turn on the person's home"
          (turn ~keeper:operator_keeper ~runtime:operator_runtime)
          alice_account
          on_person_home;
        refused "an operator call on the person's home" Access.Operator_call alice_account on_person_home;
        (* A link spells the home another way, and its real path is under the
           persons all the same. *)
        let link = Filename.concat root "alice-home" in
        Unix.symlink alice.home link;
        refused "the person's home through a link" Access.Operator_call (captured link) on_person_home;
        (* A home not made yet, spelled through a link to the person's runtime
           root, leads under the persons once the part that is there is read. *)
        let root_link = Filename.concat root "alice-root" in
        Unix.symlink (Filename.dirname (Filename.dirname (Filename.dirname alice.home))) root_link;
        refused
          "a home not made yet behind a link"
          Access.Operator_call
          (captured (List.fold_left Filename.concat root_link [ "official-clients"; "claude"; "account-later" ]))
          on_person_home;
        (* A person's own account starts nothing. *)
        refused
          "the person's own account"
          (Access.Own_account { user_id = alice.user_id; provider_account_id = alice.account })
          alice_account
          (function
            | Access.Off_own_account user_id -> User_id.equal user_id alice.user_id
            | _ -> false);
        (* The operator runs as a single user does. *)
        allowed "a turn of the operator" (turn ~keeper:operator_keeper ~runtime:operator_runtime) operator;
        allowed "an operator call" Access.Operator_call operator;
        allowed
          "an inherited home"
          Access.Operator_call
          (get_text (Account.capture ~client:Account.Claude_code ~declaration:None));
        (match Access.host_access () with
         | Ok (_ : Access.host_account) -> ()
         | Error (Access.Host_unpublished | Access.Host_not_shared) ->
           Alcotest.fail "the accounts of the host are the operator's after Off")))
;;

let () =
  Alcotest.run
    "runtime_account_access_off"
    [ "access", [ Alcotest.test_case "turned off" `Quick test_turned_off ] ]
;;
