(* Whether a CLI may start on an account in a multi-account process, by the
   access the preview publishes. The zone is on real files, made by the real
   bootstrap, and holds two persons whose accounts, Runtimes and Keepers the
   real writers recorded. The homes are spelled by the layout and captured as
   a client captures them. The access is published once per process, so the
   executable has one case and it runs in order. *)

open Authz_types
module Access = Runtime_account_access
module Account = Runtime_official_account
module Layout = Runtime_account_home_layout
module B = Authz_bootstrap
module E = Authz_invite_event
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
  | Error error -> Alcotest.failf "a record was refused: %s" (Z.error_to_string error)
;;

type person =
  { user_id : User_id.t
  ; account : Provider_account_id.t
  ; runtime : Runtime_id.t
  ; keeper : string
  ; runtime_root : string  (** The runtime root of the person's namespace. *)
  ; home : string  (** The Claude Code home of [account], as the layout spells it. *)
  }

(* One person joins through an invitation, links one account, makes a Runtime
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
   | Error error -> Alcotest.fail (Authz_runtime.error_to_string error));
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
   | Error error -> Alcotest.fail (Authz_keeper.error_to_string error));
  (match Authz_keeper.assign zone ~user_id ~keeper_id ~runtime_id:runtime with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_to_string error));
  let runtime_root = Layout.person_runtime_root ~base_path ~namespace in
  Fs_compat.mkdir_p runtime_root;
  let home =
    get_text
      (Layout.home ~runtime_root Layout.Claude_home ~account_id:(Provider_account_id.to_string account))
  in
  Fs_compat.mkdir_p home;
  { user_id; account; runtime; keeper; runtime_root; home }
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

(* The Muse home of the person's account, as the layout spells it. *)
let muse_path (who : person) =
  get_text
    (Layout.home
       ~runtime_root:who.runtime_root
       Layout.Muse_home
       ~account_id:(Provider_account_id.to_string who.account))
;;

let muse (who : person) =
  Access.Declared_home (get_text (Access.declare_muse_home (muse_path who)))
;;

let muse_allowed label request (who : person) =
  match Access.authorize_muse request (muse who) with
  | Ok authorized ->
    Alcotest.(check string)
      (label ^ ": the authorized home is the one declared")
      (muse_path who)
      (Access.declared_muse_home authorized)
  | Error refusal -> Alcotest.failf "%s: refused: %s" label (Access.refusal_to_string refusal)
;;

let muse_refused (type where) label request (account : where Access.muse_account) expected =
  match Access.authorize_muse request account with
  | Ok (_ : where Access.muse_authorized) -> Alcotest.failf "%s: authorized" label
  | Error refusal ->
    if not (expected refusal)
    then
      Alcotest.failf "%s: refused for another reason: %s" label (Access.refusal_to_string refusal)
;;

let turn (who : person) ?(channel = Channel.Autonomous) ?(runtime = who.runtime) () =
  Access.Keeper_turn
    { keeper_name = who.keeper; channel; runtime_id = Runtime_id.to_string runtime }
;;

let own (who : person) ?(account = who.account) () =
  Access.Own_account { user_id = who.user_id; provider_account_id = account }
;;

let test_multi_account () =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "runtime-account-access-multi-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
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
        let bob = person zone ~base_path ~name:"bob" ~hex:'b' in
        let alice_account = captured alice.home in
        refused "before the publication" (own alice ()) alice_account (function
          | Access.Not_published -> true
          | _ -> false);
        (match
           Access.publish
             (Access.Multi_account
                { zone; base_path; now = (fun () -> Float.of_int start_ms /. 1000.) })
         with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Access.publish_error_to_string error));
        (* A person checks and verifies their own account. *)
        allowed "the person's own account" (own alice ()) alice_account;
        refused
          "another account of the person"
          (own alice ~account:bob.account ())
          alice_account
          (function
            | Access.Not_the_account_home _ -> true
            | _ -> false);
        refused "the account of another person" (own bob ~account:alice.account ()) alice_account
          (function
          | Access.Not_the_account_home _ -> true
          | _ -> false);
        let carol = get (User_id.of_string (String.make 32 'c')) in
        refused
          "a person the log does not have"
          (Access.Own_account { user_id = carol; provider_account_id = alice.account })
          alice_account
          (function
            | Access.Not_active _ -> true
            | _ -> false);
        (* A Keeper turn runs on the account of the Runtime its owner gave it. *)
        allowed "a turn of the person's Keeper" (turn alice ()) alice_account;
        allowed "a direct turn" (turn alice ~channel:Channel.Direct ()) alice_account;
        refused "a turn of another person's Keeper" (turn bob ()) alice_account (function
          | Access.Not_the_account_home _ -> true
          | _ -> false);
        refused
          "a turn on another Runtime"
          (turn alice ~runtime:bob.runtime ())
          alice_account
          (function
            | Access.Not_the_assigned_runtime _ -> true
            | _ -> false);
        refused
          "a channel the policy does not name"
          (turn alice ~channel:Channel.Delegate ())
          alice_account
          (function
            | Access.Turn_refused (Authz_keeper_turn.Denied _) -> true
            | _ -> false);
        refused
          "a Keeper no record made"
          (Access.Keeper_turn
             { keeper_name = "keeper-nobody"
             ; channel = Channel.Autonomous
             ; runtime_id = Runtime_id.to_string alice.runtime
             })
          alice_account
          (function
            | Access.Turn_refused (Authz_keeper_turn.Keeper_not_made _) -> true
            | _ -> false);
        refused
          "a Keeper name that is not an id"
          (Access.Keeper_turn
             { keeper_name = "not an id"
             ; channel = Channel.Autonomous
             ; runtime_id = Runtime_id.to_string alice.runtime
             })
          alice_account
          (function
            | Access.Not_a_keeper_id _ -> true
            | _ -> false);
        (* No operator owns the account of a person, and an inherited home
           carries the credentials of the process environment. *)
        refused "an operator call" Access.Operator_call alice_account (function
          | Access.No_operator -> true
          | _ -> false);
        let inherited =
          get_text (Account.capture ~client:Account.Claude_code ~declaration:None)
        in
        refused "an inherited home" (own alice ()) inherited (function
          | Access.Not_a_declared_home -> true
          | _ -> false);
        (* The spelling of a home is the identity of its account: the layout
           spells every home from the real path of the runtime root, a
           declaration keeps its spelling, and another spelling of the same
           directory is another account. *)
        let link = Filename.concat root "alice-home-link" in
        Unix.symlink alice.home link;
        refused "another spelling of her home" (own alice ()) (captured link) (function
          | Access.Not_the_account_home _ -> true
          | _ -> false);
        (* A Muse home is judged by the same rule (plan D3): the Muse home of
           the person's account under their namespace, and no other. *)
        muse_allowed "the Muse home of the person's account" (own alice ()) alice;
        muse_allowed "a turn of the person's Keeper" (turn alice ()) alice;
        muse_refused "the Muse home of another person" (own alice ()) (muse bob) (function
          | Access.Not_the_account_home _ -> true
          | _ -> false);
        muse_refused "a turn of another person's Keeper" (turn bob ()) (muse alice) (function
          | Access.Not_the_account_home _ -> true
          | _ -> false);
        muse_refused
          "the Claude Code home of her account"
          (own alice ())
          (Access.Declared_home (get_text (Access.declare_muse_home alice.home)))
          (function
            | Access.Not_the_account_home _ -> true
            | _ -> false);
        muse_refused "the environment of the process" (own alice ()) Access.Process_environment
          (function
          | Access.Not_a_declared_home -> true
          | _ -> false);
        muse_refused "an operator call on her Muse home" Access.Operator_call (muse alice) (function
          | Access.No_operator -> true
          | _ -> false);
        match
          Access.publish
            (Access.Multi_account { zone; base_path; now = (fun () -> 0.) })
        with
        | Error Access.Already_published -> ()
        | Ok () -> Alcotest.fail "a second publication was taken"))
;;

let () =
  Alcotest.run
    "runtime_account_access_multi"
    [ "access", [ Alcotest.test_case "multi-account" `Quick test_multi_account ] ]
;;
