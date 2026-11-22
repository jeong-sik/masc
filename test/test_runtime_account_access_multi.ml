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
  | Error error -> Alcotest.failf "a record was refused: %s" (Z.error_detail error)
;;

type person =
  { user_id : User_id.t
  ; account : Provider_account_id.t
  ; runtime : Runtime_id.t
  ; keeper : string
  ; runtime_root : string  (** The runtime root of the person's namespace. *)
  ; home : string  (** The Claude Code home of [account], as the layout spells it. *)
  }

(* A Runtime of the person on [account] and a Keeper on that Runtime, each
   through its writer. *)
let runtime_and_keeper zone ~user_id ~account ~name =
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
  (match
     Authz_keeper.make
       zone
       ~user_id
       ~keeper_id
       ~turn_scope
       ~draw:(fun () -> "policy-" ^ name)
       ~draw_engine_name:(fun () -> "kp-" ^ name)
   with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
  (match Authz_keeper.assign zone ~user_id ~keeper_id ~runtime_id:runtime with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
  runtime, keeper
;;

(* The Claude Code home of [account] under [runtime_root], as the layout
   spells it, made. *)
let claude_home ~runtime_root account =
  let home =
    get_text
      (Layout.home ~runtime_root Layout.Claude_home ~account_id:(Provider_account_id.to_string account))
  in
  Fs_compat.mkdir_p home;
  home
;;

(* The Codex home of [account] under [runtime_root], as the layout spells it,
   made. *)
let codex_home ~runtime_root account =
  let home =
    get_text
      (Layout.home ~runtime_root Layout.Codex_home ~account_id:(Provider_account_id.to_string account))
  in
  Fs_compat.mkdir_p home;
  home
;;

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
  (match
     Authz_provider_account.link
       zone
       ~user_id
       ~provider_account_id:account
       ~integration_id:(get (Integration_id.of_string "claude_code"))
   with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
  let runtime, keeper = runtime_and_keeper zone ~user_id ~account ~name in
  let runtime_root = Layout.person_runtime_root ~base_path ~namespace in
  Fs_compat.mkdir_p runtime_root;
  let home = claude_home ~runtime_root account in
  { user_id; account; runtime; keeper; runtime_root; home }
;;

let captured home =
  get_text (Account.capture ~client:Account.Claude_code ~declaration:(Some home))
;;

(* The account of [home] on the key of [key_file]. *)
let captured_on_key home ~key_file =
  match Account.capture_on_key ~declaration:(Some home) ~key_file with
  | Ok account -> account
  | Error (Account.Key_not_read error) ->
    Alcotest.failf "the key was not read: %s" (Runtime_api_key_file.read_error_to_string error)
  | Error (Account.Key_not_captured detail) -> Alcotest.failf "the account was not captured: %s" detail
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

let refused_sealed (type c) label request (sealed : c Access.sealed) expected =
  match Access.authorize request sealed with
  | Ok (_ : c Access.authorized) -> Alcotest.failf "%s: authorized" label
  | Error refusal ->
    if not (expected refusal)
    then
      Alcotest.failf "%s: refused for another reason: %s" label (Access.refusal_to_string refusal)
;;

(* What the judgment says of a client on the Codex home [home], captured as
   the home is now. *)
let codex_judged request home =
  match
    Access.authorize
      request
      (Access.seal (get_text (Account.capture ~client:Account.Codex ~declaration:(Some home))))
  with
  | Ok (_ : Account.codex Access.authorized) -> Ok ()
  | Error refusal -> Error refusal
;;

(* The judgment of a turn before its account is read ({!Access.admit}). *)
let admitted label request =
  match Access.admit request with
  | Ok () -> ()
  | Error refusal -> Alcotest.failf "%s: not admitted: %s" label (Access.refusal_to_string refusal)
;;

let not_admitted label request expected =
  match Access.admit request with
  | Ok () -> Alcotest.failf "%s: admitted" label
  | Error refusal ->
    if not (expected refusal)
    then
      Alcotest.failf "%s: refused for another reason: %s" label (Access.refusal_to_string refusal)
;;

let turn
      (who : person)
      ?(channel = Channel.Autonomous)
      ?(stored_scope = Authorization_scope.all)
      ?(pat = Pat_binding.Not_pat)
      ?(runtime = who.runtime)
      ?(keeper = who.keeper)
      ()
  =
  Access.Keeper_turn
    { owner = who.user_id
    ; keeper_id = get (Keeper_id.of_string keeper)
    ; channel
    ; stored_scope
    ; pat
    ; runtime_id = Runtime_id.to_string runtime
    }
;;

(* The name both persons give a Keeper of their own. *)
let shared_keeper = "keeper-shared"

let make_shared_keeper zone (who : person) ~policy =
  let keeper_id = get (Keeper_id.of_string shared_keeper) in
  let turn_scope =
    { Authorization_scope.runtimes = Runtime_scope.all
    ; channels = Channel_scope.only (Channel.Set.of_list Channel.[ Autonomous; Direct ])
    ; allowed_effects = Effect_scope.all
    }
  in
  (match
     Authz_keeper.make
       zone
       ~user_id:who.user_id
       ~keeper_id
       ~turn_scope
       ~draw:(fun () -> policy)
       ~draw_engine_name:(fun () -> "kp-" ^ policy)
   with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
  match Authz_keeper.assign zone ~user_id:who.user_id ~keeper_id ~runtime_id:who.runtime with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Authz_keeper.error_detail error)
;;

(* A personal access token whose scope covers a direct turn of [who]'s Keeper:
   the Runtime, the [Direct] channel, and the effects a turn asks for. Each
   argument replaces one dimension. *)
let turn_pat
      (who : person)
      ?(runtimes = Runtime_scope.only (Runtime_id.Set.singleton who.runtime))
      ?(channels = Channel_scope.only (Channel.Set.singleton Channel.Direct))
      ?(effects = Effect.[ Invoke_model; Use_tool ])
      ?expires_at
      ()
  =
  Pat_binding.Pat
    { Pat_scope.scope =
        { Authorization_scope.runtimes
        ; channels
        ; allowed_effects = Effect_scope.only (Effect.Set.of_list effects)
        }
    ; expires_at
    }
;;

let denied expected = function
  | Access.Turn_refused (Authz_keeper_turn.Denied reason) -> expected reason
  | _ -> false
;;

let own (who : person) ?(account = who.account) () =
  Access.Own_account { user_id = who.user_id; provider_account_id = account }
;;

(* An API runtime as the runtime table materializes it: an OpenAI-compatible
   endpoint on [port] with the credential its operator declared. *)
let api_runtime ~port =
  let toml =
    Printf.sprintf
      {|
[runtime]
default = "operator.first"
[providers.operator]
display-name = "Operator endpoint"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d/v1"
[providers.operator.credentials]
type = "inline"
value = "operator-key"
[models.first]
api-name = "first-model"
max-context = 4096
tools-support = true
streaming = true

[models.first.capabilities]
supports-tool-choice = true

[operator.first]
|}
      port
  in
  match Runtime_toml.parse_string toml with
  | Error _ -> Alcotest.fail "the API runtime fixture does not parse"
  | Ok config ->
    (match config.Runtime_schema.bindings with
     | [ binding ] ->
       (match Runtime_instance.of_binding config binding with
        | Ok runtime -> runtime
        | Error reason -> Alcotest.fail (Runtime_config_error.string_of_drop_reason reason))
     | [] | _ :: _ :: _ -> Alcotest.fail "the API runtime fixture declares one binding")
;;

(* The runtime.toml of the base path with one setup connection: an
   OpenAI-compatible endpoint on [port] whose key its operator declared in
   [key_variable]. *)
let setup_runtime_toml ~port ~key_variable =
  Printf.sprintf
    {|
[providers.operator]
display-name = "Operator endpoint"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d/v1"
[providers.operator.credentials]
type = "env"
key = "%s"
|}
    port
    key_variable
;;

let rec make_dirs path =
  if not (Sys.file_exists path)
  then (
    make_dirs (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

(* Sets [name] to [value] while [f] runs. OCaml has no unsetenv, so a variable
   that was not set goes back to the empty value. *)
let with_env name value f =
  let previous = Option.value (Sys.getenv_opt name) ~default:"" in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> Unix.putenv name previous) f
;;

let test_multi_account () =
  Eio_main.run (fun env ->
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
        make_shared_keeper zone alice ~policy:"policy-shared-alice";
        make_shared_keeper zone bob ~policy:"policy-shared-bob";
        let alice_account = captured alice.home in
        refused "before the publication" (own alice ()) alice_account (function
          | Access.Not_published -> true
          | _ -> false);
        (match
           Access.publish
             (Access.Multi_account
                { zone; base_path; now = (fun () -> Float.of_int start_ms /. 1000.) })
         with
         | Ok published ->
           Alcotest.(check string)
             "the published access is of the base path it was given"
             base_path
             (Access.published_base_path published)
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
        (* The Codex home of a person asks the environment of the server for
           nothing: a client starts on it until its config.toml names a
           variable. *)
        let alice_codex = codex_home ~runtime_root:alice.runtime_root alice.account in
        let on_the_codex_home =
          [ "the person's own account", own alice (); "a turn of the person's Keeper", turn alice () ]
        in
        List.iter
          (fun (label, request) ->
             match codex_judged request alice_codex with
             | Ok () -> ()
             | Error refusal ->
               Alcotest.failf
                 "%s on a Codex home that names no variable: refused: %s"
                 label
                 (Access.refusal_to_string refusal))
          on_the_codex_home;
        Out_channel.with_open_bin (Filename.concat alice_codex "config.toml") (fun channel ->
          Out_channel.output_string
            channel
            "[model_providers.made_up]\nname = \"made up\"\nenv_key = \"MADE_UP_NAME\"\n");
        List.iter
          (fun (label, request) ->
             match codex_judged request alice_codex with
             | Error (Access.Home_asks_for_environment account) ->
               Alcotest.(check bool)
                 (label ^ ": the refusal names the account of the home")
                 true
                 (Provider_account_id.equal account alice.account)
             | Ok () ->
               Alcotest.failf "%s on a Codex home that names a variable: authorized" label
             | Error refusal ->
               Alcotest.failf
                 "%s on a Codex home that names a variable: refused for another reason: %s"
                 label
                 (Access.refusal_to_string refusal))
          on_the_codex_home;
        (* The home is judged before what it asks for, so the answer to
           another person says nothing of the configuration of this home. *)
        List.iter
          (fun (label, request) ->
             match codex_judged request alice_codex with
             | Error (Access.Not_the_account_home account) ->
               Alcotest.(check bool)
                 (label ^ ": the refusal names the account that was asked for")
                 true
                 (Provider_account_id.equal account bob.account)
             | Ok () ->
               Alcotest.failf "%s on the Codex home of another person: authorized" label
             | Error refusal ->
               Alcotest.failf
                 "%s on the Codex home of another person: refused for another reason: %s"
                 label
                 (Access.refusal_to_string refusal))
          [ "another person's own account", own bob ()
          ; "a turn of another person's Keeper", turn bob ()
          ];
        allowed "a direct turn" (turn alice ~channel:Channel.Direct ()) alice_account;
        (* A turn that a personal access token asked for runs inside the scope
           of that token. *)
        let by_pat pat = turn alice ~channel:Channel.Direct ~pat () in
        allowed "a direct turn by a token that covers it" (by_pat (turn_pat alice ())) alice_account;
        allowed
          "a token of every Runtime"
          (by_pat (turn_pat alice ~runtimes:Runtime_scope.all ()))
          alice_account;
        refused
          "a token that manages Keepers and calls no model"
          (by_pat (turn_pat alice ~effects:Effect.[ Manage_own_keeper; Read_state ] ()))
          alice_account
          (denied (function
             | Authz_decision.Effects_out_of_scope missing ->
               Effect.Set.equal missing (Effect.Set.of_list Effect.[ Invoke_model; Use_tool ])
             | _ -> false));
        refused
          "a token that calls the model and uses no tool"
          (by_pat (turn_pat alice ~effects:Effect.[ Invoke_model ] ()))
          alice_account
          (denied (function
             | Authz_decision.Effects_out_of_scope missing ->
               Effect.Set.equal missing (Effect.Set.singleton Effect.Use_tool)
             | _ -> false));
        refused
          "a token of another channel"
          (by_pat
             (turn_pat
                alice
                ~channels:(Channel_scope.only (Channel.Set.singleton Channel.Schedule))
                ()))
          alice_account
          (denied (function
             | Authz_decision.Channel_out_of_scope -> true
             | _ -> false));
        refused
          "a token of another Runtime"
          (by_pat
             (turn_pat alice ~runtimes:(Runtime_scope.only (Runtime_id.Set.singleton bob.runtime)) ()))
          alice_account
          (denied (function
             | Authz_decision.Runtime_out_of_scope -> true
             | _ -> false));
        refused
          "a token that expired"
          (by_pat (turn_pat alice ~expires_at:(Float.of_int start_ms /. 1000.) ()))
          alice_account
          (denied (function
             | Authz_decision.Pat_expired -> true
             | _ -> false));
        (* A server asks whether the log gives the turn before it takes the
           call of the account, so a turn the log refuses holds no call. *)
        admitted "a direct turn by a token that covers it, before its account" (by_pat (turn_pat alice ()));
        not_admitted
          "a token of another Runtime, before its account"
          (by_pat
             (turn_pat alice ~runtimes:(Runtime_scope.only (Runtime_id.Set.singleton bob.runtime)) ()))
          (denied (function
             | Authz_decision.Runtime_out_of_scope -> true
             | _ -> false));
        not_admitted
          "a token that expired, before its account"
          (by_pat (turn_pat alice ~expires_at:(Float.of_int start_ms /. 1000.) ()))
          (denied (function
             | Authz_decision.Pat_expired -> true
             | _ -> false));
        not_admitted
          "a turn on a Runtime the Keeper is not on, before its account"
          (turn alice ~runtime:bob.runtime ())
          (function
            | Access.Not_the_assigned_runtime _ -> true
            | _ -> false);
        (* What only the account tells is left to the call. *)
        admitted "a request for one's own account, which the call judges whole" (own alice ());
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
        let not_made = function
          | Access.Turn_refused (Authz_keeper_turn.Keeper_not_made _) -> true
          | _ -> false
        in
        refused "a Keeper no record made" (turn alice ~keeper:"keeper-nobody" ()) alice_account not_made;
        (* A Keeper is its owner's: the name of another person's Keeper names
           nothing of the person who asks. *)
        refused
          "another person's Keeper asked for as one's own"
          (turn alice ~keeper:bob.keeper ())
          alice_account
          not_made;
        (* Two persons each made a Keeper of one name, and each runs their
           own, on their own Runtime and account (issue #51073). *)
        allowed "the person's Keeper of the shared name" (turn alice ~keeper:shared_keeper ()) alice_account;
        allowed
          "the other person's Keeper of the shared name"
          (turn bob ~keeper:shared_keeper ())
          (captured bob.home);
        refused
          "the other person's Keeper of the shared name on this person's account"
          (turn bob ~keeper:shared_keeper ())
          alice_account
          (function
            | Access.Not_the_account_home _ -> true
            | _ -> false);
        (* A lane runs Keepers of the operator, and multi-account mode has
           none. *)
        refused
          "a Keeper of the operator"
          (Access.Operator_keeper_turn
             { keeper_name = alice.keeper; runtime_id = Runtime_id.to_string alice.runtime })
          alice_account
          (function
            | Access.No_operator_keeper name -> String.equal name alice.keeper
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
        (* A host client starts on an account of the host, which a
           multi-account process shares with no person (plan D3b). An API
           provider of the runtime table sends with the credential its
           operator declared, an account of the host too (plan D4), and so
           do the requests outside the table (plan D4b). *)
        List.iter
          (fun client ->
            match client, Access.authorize_host client with
            | ( ( Access.Antigravity
                | Access.Acp_client _
                | Access.Api_provider
                | Access.Model_list
                | Access.Files_api
                | Access.Replacement_catalog
                | Access.Web_search
                | Access.Systemone_cloud
                | Access.Voice_endpoint )
              , Ok (_ : Access.host_account) ) -> Alcotest.fail "a host client was allowed"
            | Access.Antigravity, Error (Access.Host_account Access.Antigravity) -> ()
            | Access.Acp_client d1, Error (Access.Host_account (Access.Acp_client d2))
              when Runtime_acp_client.equal_driver d1 d2 -> ()
            | Access.Api_provider, Error (Access.Host_account Access.Api_provider)
            | Access.Model_list, Error (Access.Host_account Access.Model_list)
            | Access.Files_api, Error (Access.Host_account Access.Files_api)
            | Access.Replacement_catalog, Error (Access.Host_account Access.Replacement_catalog)
            | Access.Web_search, Error (Access.Host_account Access.Web_search)
            | Access.Systemone_cloud, Error (Access.Host_account Access.Systemone_cloud)
            | Access.Voice_endpoint, Error (Access.Host_account Access.Voice_endpoint)
              -> ()
            | ( ( Access.Antigravity
                | Access.Acp_client _
                | Access.Api_provider
                | Access.Model_list
                | Access.Files_api
                | Access.Replacement_catalog
                | Access.Web_search
                | Access.Systemone_cloud
                | Access.Voice_endpoint )
              , Error refusal ) ->
              Alcotest.failf
                "a host client was refused for another reason: %s"
                (Access.refusal_to_string refusal))
          Access.
            [ Antigravity
            ; Acp_client Runtime_acp_client.Antigravity
            ; Acp_client Runtime_acp_client.Kimi_code
            ; Acp_client Runtime_acp_client.Mistral_vibe
            ; Api_provider
            ; Model_list
            ; Files_api
            ; Replacement_catalog
            ; Web_search
            ; Systemone_cloud
            ; Voice_endpoint
            ];
        (match Access.host_access () with
         | Error Access.Host_not_shared -> ()
         | Error Access.Host_unpublished -> Alcotest.fail "the multi-account access was not published"
         | Ok (_ : Access.host_account) -> Alcotest.fail "the accounts of the host were shared");
        (* An API runtime of the table is sealed. A sender takes its config
           only through the access, which refuses it here; a reader sees the
           declaration without the credential; and a verification, a real
           sender, ends refused with nothing sent to the endpoint. *)
        Eio.Switch.run (fun sw ->
          let connections = Atomic.make 0 in
          let listening =
            Eio.Net.listen
              ~sw
              ~backlog:5
              ~reuse_addr:true
              env#net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          Eio.Fiber.fork_daemon ~sw (fun () ->
            while true do
              Eio.Net.accept_fork ~sw listening ~on_error:(fun _ -> ()) (fun _flow _addr ->
                Atomic.incr connections)
            done);
          let port =
            match Eio.Net.listening_addr listening with
            | `Tcp (_, port) -> port
            | `Unix _ -> Alcotest.fail "the endpoint is not a TCP socket"
          in
          let runtime = api_runtime ~port in
          let sealed =
            match runtime.Runtime_instance.execution with
            | Runtime_execution.Agent_core sealed -> sealed
            | Runtime_execution.Codex_app_server _
            | Runtime_execution.Claude_code _
            | Runtime_execution.Antigravity_cli _
            | Runtime_execution.Acp _ -> Alcotest.fail "the API runtime fixture is not Agent Core"
          in
          (match Access.authorize_api sealed with
           | Error (Access.Host_account Access.Api_provider) -> ()
           | Error refusal ->
             Alcotest.failf
               "an API provider was refused for another reason: %s"
               (Access.refusal_to_string refusal)
           | Ok (_ : Llm_provider.Provider_config.t) ->
             Alcotest.fail "an API provider was allowed");
          Alcotest.(check string)
            "a reader of the declaration sees no credential"
            ""
            ((Access.api_declaration sealed).Llm_provider.Provider_config.api_key :> string);
          let verified =
            Runtime_verification.verify_as_command
              ~env
              ~sw
              ~private_dir:(Filename.temp_dir ~temp_dir:root "verify-" "")
              ~timeout_s:5.
              ~account_request:Access.Operator_call
              runtime
          in
          (match verified.Runtime_verification.failure with
           | Some failure ->
             Alcotest.(check string)
               "the verification is refused for the account"
               "account_not_authorized"
               (Runtime_verification.failure_code failure)
           | None -> Alcotest.fail "the verification of an API runtime ran");
          (* Outside the table (plan D4b). A model-list request of a setup
             connection sends with the credential its operator declared, so
             the setup route is refused before it sends, though the key is
             set. *)
          let key_variable = "MASC_TEST_D4B_OPERATOR_KEY" in
          let config_dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "config" in
          make_dirs config_dir;
          Out_channel.with_open_bin (Filename.concat config_dir "runtime.toml") (fun channel ->
            Out_channel.output_string channel (setup_runtime_toml ~port ~key_variable));
          (match
             with_env key_variable "operator-key" (fun () ->
               Server_runtime_setup_actions.discover
                 ~binary:Sys.executable_name
                 ~sw
                 ~net:env#net
                 ~base_path
                 (`Assoc [ "integration_id", `String "operator" ]))
           with
           | Error
               (Server_runtime_setup_actions.Account_refused
                  (Access.Host_account Access.Model_list)) -> ()
           | Error error ->
             Alcotest.failf
               "the model list was refused for another reason: %s"
               (Server_runtime_setup_actions.error_message error)
           | Ok (_ : Yojson.Safe.t) -> Alcotest.fail "the model list of a setup connection was read");
          (* The Files API of masc_file_* is called with DEEPSEEK_API_KEY. The
             tool is refused before it reads the key, so the refusal comes
             though no key is set here. *)
          let files =
            with_env "DEEPSEEK_API_KEY" "" (fun () ->
              Eio_context.with_test_env
                ~net:env#net
                ~clock:env#clock
                ~mono_clock:env#mono_clock
                ~sw
                (fun () ->
                  Masc.Keeper_tool_in_process_runtime.handle_masc_file_with_outcome
                    ~name:"masc_file_list"
                    ~args:(`Assoc [])
                    ()))
          in
          (match Yojson.Safe.from_string files.Masc.Keeper_tool_execution.raw_output with
           | `Assoc fields ->
             Alcotest.(check (option string))
               "the Files API is refused for the account"
               (Some (Access.refusal_to_string (Access.Host_account Access.Files_api)))
               (match List.assoc_opt "error" fields with
                | Some (`String error) -> Some error
                | Some _ | None -> None)
           | _ -> Alcotest.fail "the Files API answered no JSON object");
          (* A full replacement catalog carries its own providers and their
             credentials, so its registry build is refused before the file is
             read. *)
          let replacement =
            with_env
              Runtime.agent_core_model_catalog_env_var_name
              (Filename.concat root "replacement-catalog.json")
              (fun () -> Runtime.exact_output_resolver_catalog ~exact_output_lane_decls:[] [])
          in
          (match replacement with
           | Error (Access.Host_account Access.Replacement_catalog) -> ()
           | Error refusal ->
             Alcotest.failf
               "the replacement catalog was refused for another reason: %s"
               (Access.refusal_to_string refusal)
           | Ok (_ : Runtime.exact_output_catalog) ->
             Alcotest.fail "the replacement catalog was allowed");
          (* The TypeSafe AI lane sends with the key each destination names,
             an account of the host (plan D4c). With the key set, every gate
             switched on and the local endpoint as the destination, the lane
             and its gates give no destination, and the readings an operator
             sees name the reason. *)
          let jev_key_variable = "MASC_TEST_D4C_JEV_KEY" in
          let found_policy = Runtime_typesafeai_policy.current () in
          let lane, gates, health =
            with_env jev_key_variable "jev-key" (fun () ->
              Runtime_typesafeai_policy.publish
                { Runtime_schema.default_typesafeai with
                  destinations =
                    ( { Runtime_schema.typesafe_destination with
                        endpoint = Printf.sprintf "http://127.0.0.1:%d/v1/systemone" port
                      ; api_key_env = jev_key_variable
                      }
                    , [] )
                ; context_review = true
                ; memory_recall = Runtime_schema.Memory_recall_on Runtime_schema.All_keepers
                };
              Fun.protect
                ~finally:(fun () -> Runtime_typesafeai_policy.publish found_policy)
                (fun () ->
                  ( Masc.Typesafeai_config.lane_destinations ()
                  , [ ( "Board attention"
                      , Masc.Typesafeai_config.board_attention_destinations ~keeper_id:"reader" )
                    ; ( "context review"
                      , Masc.Typesafeai_config.context_review_destinations ~keeper_id:"reader" )
                    ; ( "memory recall"
                      , Masc.Typesafeai_config.memory_recall_destinations ~keeper_id:"reader" )
                    ]
                  , Server_typesafeai_health.health_json () )))
          in
          List.iter
            (fun (label, destinations) ->
              match destinations with
              | Error Masc.Typesafeai_config.Host_account_not_shared -> ()
              | Error reason ->
                Alcotest.failf
                  "%s was refused for another reason: %s"
                  label
                  (Masc.Typesafeai_config.unavailable_reason_to_string reason)
              | Ok (_ : Masc.Typesafeai_config.destinations) ->
                Alcotest.failf "%s was given a destination with the key of the host" label)
            (("the lane", lane) :: gates);
          Alcotest.(check (option string))
            "the health of the lane names the reason"
            (Some "host_account_not_shared")
            (match health with
             | `Assoc fields ->
               (match List.assoc_opt "reason" fields with
                | Some (`String reason) -> Some reason
                | Some _ | None -> None)
             | _ -> None);
          (* MASC tools that send with a key of the host (plan D4d). Web
             search is given only a provider with a key, so it ends refused
             before a provider is asked. The cloud backend of SystemOne and a
             voice endpoint that names a key, here the local endpoint, end
             refused before they read the key. *)
          let web_search, addon_search =
            with_env "MASC_WEB_SEARCH_PROVIDER_ORDER" "brave" (fun () ->
              with_env "BRAVE_SEARCH_API_KEY" "brave-key" (fun () ->
                ( Masc.Tool_misc_web_search.handle
                    ~tool_name:"masc_web_search"
                    ~start_time:(Tool_timing.start ())
                    (`Assoc [ "query", `String "multi-account" ])
                , Masc.Tool_misc_web_search.addon_search_runner
                    ~query:"multi-account"
                    ~limit:None )))
          in
          let web_refusal = Access.refusal_to_string (Access.Host_account Access.Web_search) in
          Alcotest.(check bool)
            "web search is refused as a policy"
            true
            (Tool_result.failure_class web_search = Some Tool_result.Policy_rejection);
          Alcotest.(check bool)
            "web search names the refusal"
            true
            (String.starts_with ~prefix:web_refusal (Tool_result.message web_search));
          (match addon_search with
           | Error message ->
             Alcotest.(check bool)
               "the Lane Add-on web search names the refusal"
               true
               (String.starts_with ~prefix:web_refusal message)
           | Ok _ -> Alcotest.fail "the Lane Add-on web search was answered");
          let module Systemone = Masc.Tool_local_runtime_systemone in
          (match
             with_env Systemone.cloud_key_env "cloud-key" (fun () ->
               Systemone.decide
                 ~timeout_sec:5
                 { Systemone.model = "clef:cloud"
                 ; state = "a multi-account process"
                 ; questions =
                     [ ( "risk"
                       , Systemone.Noul
                           { instructions = "Is it risky?"
                           ; true_description = None
                           ; false_description = None
                           } )
                     ]
                 }
                 Systemone.Cloud)
           with
           | Error message ->
             Alcotest.(check string)
               "the cloud backend of SystemOne is refused"
               (Access.refusal_to_string (Access.Host_account Access.Systemone_cloud))
               message
           | Ok (_ : Yojson.Safe.t) -> Alcotest.fail "the cloud backend of SystemOne answered");
          let voice_endpoint =
            { Voice_config.id = "voice-d4d"
            ; kind = Voice_config.Elevenlabs_direct
            ; base_url = Some (Printf.sprintf "http://127.0.0.1:%d" port)
            ; mcp_url = None
            ; health_url = None
            ; api_key_env = Some "MASC_TEST_D4D_VOICE_KEY"
            ; enabled = true
            ; timeout_seconds = Some 1.
            ; default_voice = Some "voice"
            ; agent_voices = []
            ; command = None
            ; model = None
            }
          in
          let voices, spoken =
            with_env "MASC_TEST_D4D_VOICE_KEY" "voice-key" (fun () ->
              ( Masc.Voice_probe.list_voices_via_http voice_endpoint
              , Masc.Voice_speak.speak_via_http_tts_to_file
                  voice_endpoint
                  ~agent_id:"reader"
                  ~message:"hello"
                  ~voice:"voice"
                  ~model:"model"
                  ~output_file:(Filename.concat root "voice.mp3") ))
          in
          let voice_refusal = Access.refusal_to_string (Access.Host_account Access.Voice_endpoint) in
          (match voices with
           | Error message -> Alcotest.(check string) "the voice catalogue is refused" voice_refusal message
           | Ok (_ : Yojson.Safe.t) -> Alcotest.fail "the voice catalogue was read");
          (match spoken with
           | Error message -> Alcotest.(check string) "speech is refused" voice_refusal message
           | Ok (_ : int) -> Alcotest.fail "speech was synthesized");
          Alcotest.(check int) "the endpoint saw no connection" 0 (Atomic.get connections));
        (* A native tool runs as the user of the server process and reaches
           the account homes of other people, so a model turn runs here only
           without native tools (plan D3c). *)
        (match Access.authorize_native Runtime_native_tools.Native_none with
         | Ok () -> ()
         | Error refusal ->
           Alcotest.failf
             "a turn without native tools was refused: %s"
             (Access.native_refusal_to_string refusal));
        List.iter
          (fun posture ->
            match Access.authorize_native posture with
            | Error (Access.Native_tools_reach_other_homes refused) ->
              Alcotest.(check string)
                "the refusal names the posture of the turn"
                (Runtime_native_tools.to_string posture)
                (Runtime_native_tools.to_string refused)
            | Error Access.Native_unpublished ->
              Alcotest.fail "the multi-account access was not published"
            | Error
                ((Access.Native_tools_reach_person_homes _ | Access.Person_homes_unread _) as
                 refusal) ->
              Alcotest.failf
                "a multi-account process got the refusal of a single user: %s"
                (Access.native_refusal_to_string refusal)
            | Ok () ->
              Alcotest.failf
                "a turn with native %s tools was allowed"
                (Runtime_native_tools.to_string posture))
          Runtime_native_tools.[ Native_read; Native_full ];
        (match
           Access.publish
             (Access.Multi_account { zone; base_path; now = (fun () -> 0.) })
         with
         | Error Access.Already_published -> ()
         | Ok (_ : Access.published) -> Alcotest.fail "a second publication was taken");
        (* RFC a-persons-api-key-is-their-own-provider-account 3.4: a key
           account is spent on the key of the file its records say, and on
           no other. Frank has a key account, with a Runtime and a Keeper on
           it, beside the login account every person of this test has. *)
        let frank = person zone ~base_path ~name:"frank" ~hex:'f' in
        let frank_key =
          let account = get (Provider_account_id.of_string "account-frank-key") in
          (match
             Authz_provider_account.link_key
               zone
               ~user_id:frank.user_id
               ~provider_account_id:account
               ~integration_id:(get (Integration_id.of_string "claude_code"))
           with
           | Ok () -> ()
           | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
          let runtime, keeper =
            runtime_and_keeper zone ~user_id:frank.user_id ~account ~name:"frank-key"
          in
          { frank with
            account
          ; runtime
          ; keeper
          ; home = claude_home ~runtime_root:frank.runtime_root account
          }
        in
        let key_of_frank =
          (match
             Option.map
               (Runtime_api_key_file.write
                  ~runtime_root:frank.runtime_root
                  ~account_id:frank_key.account
                  ~generation:Key_generation.first)
               (Runtime_api_key_file.key_of_string "sk-test-the-key-of-frank")
           with
           | Some (Ok ()) -> ()
           | None -> Alcotest.fail "the fixture key is no key"
           | Some
               (Error
                 ( Runtime_api_key_file.Root_unavailable _
                 | Runtime_api_key_file.Folder_not_private _
                 | Runtime_api_key_file.Generation_taken
                 | Runtime_api_key_file.Not_written _ )) ->
             Alcotest.fail "the key file was not written");
          get_text
            (Layout.key_file
               ~runtime_root:frank.runtime_root
               ~account_id:frank_key.account
               ~generation:Key_generation.first)
        in
        (* A private file of this user that holds a key and is not the file
           of any account. *)
        let a_key_elsewhere =
          let path = Filename.concat frank.runtime_root "a-key-elsewhere" in
          Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 path (fun channel ->
            Out_channel.output_string channel "sk-test-a-key-elsewhere");
          Unix.chmod path 0o600;
          path
        in
        let not_the_key_of (who : person) refusal = refusal = Access.Not_the_account_key who.account in
        let on_its_key = captured_on_key frank_key.home ~key_file:key_of_frank in
        allowed "a key account, on the key of its records" (own frank_key ()) on_its_key;
        allowed "a turn on a key account, on the key of its records" (turn frank_key ()) on_its_key;
        let without_key = captured frank_key.home in
        refused "a key account, on no key" (own frank_key ()) without_key (not_the_key_of frank_key);
        refused "a turn on a key account, on no key" (turn frank_key ()) without_key (not_the_key_of frank_key);
        let on_another_file = captured_on_key frank_key.home ~key_file:a_key_elsewhere in
        refused
          "a key account, on the key of another file"
          (own frank_key ())
          on_another_file
          (not_the_key_of frank_key);
        refused
          "a turn on a key account, on the key of another file"
          (turn frank_key ())
          on_another_file
          (not_the_key_of frank_key);
        (* A file that shares a part of the spelling of the key file is not
           it: another generation in the folder of the account, the first
           generation in the folder of another account of the person, and
           the same spelling under the runtime root of another person. *)
        let key_at path =
          make_dirs (Filename.dirname path);
          Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 path (fun channel ->
            Out_channel.output_string channel "sk-test-a-key-beside");
          Unix.chmod path 0o600;
          path
        in
        List.iter
          (fun (what, path) ->
             let on_it = captured_on_key frank_key.home ~key_file:(key_at path) in
             refused ("a key account, on " ^ what) (own frank_key ()) on_it (not_the_key_of frank_key);
             refused
               ("a turn on a key account, on " ^ what)
               (turn frank_key ())
               on_it
               (not_the_key_of frank_key))
          [ "another generation of the account", Filename.concat (Filename.dirname key_of_frank) "2"
          ; ( "the first generation of another account of the person"
            , get_text
                (Layout.key_file
                   ~runtime_root:frank.runtime_root
                   ~account_id:frank.account
                   ~generation:Key_generation.first) )
          ; ( "the same spelling under the root of another person"
            , get_text
                (Layout.key_file
                   ~runtime_root:bob.runtime_root
                   ~account_id:frank_key.account
                   ~generation:Key_generation.first) )
          ];
        (* An account no record links carries no key: the home of an id of
           the person's own choosing, on a key file, is refused. *)
        let unlinked = get (Provider_account_id.of_string "account-no-record-links") in
        refused
          "an account no record links, on a key"
          (own frank ~account:unlinked ())
          (captured_on_key (claude_home ~runtime_root:frank.runtime_root unlinked) ~key_file:key_of_frank)
          (fun refusal -> refusal = Access.Not_the_account_key unlinked);
        (* The key of one's own key account is not the key of one's login
           account either: an account runs on what its records say. *)
        let login_on_a_key = captured_on_key frank.home ~key_file:key_of_frank in
        refused "a login account, on a key" (own frank ()) login_on_a_key (not_the_key_of frank);
        refused "a turn on a login account, on a key" (turn frank ()) login_on_a_key (not_the_key_of frank);
        allowed "the login account of the same person, on no key" (own frank ()) (captured frank.home);
        (* Another person names the key account, on the home their own
           namespace spells for its id and on the key file itself. The
           answer is the one of any account of another person. *)
        refused
          "the key account of another person, on its key"
          (own bob ~account:frank_key.account ())
          (captured_on_key (claude_home ~runtime_root:bob.runtime_root frank_key.account) ~key_file:key_of_frank)
          (fun refusal ->
            refusal
            = Access.Account_unavailable
                { provider_account_id = frank_key.account
                ; reason = Authz_provider_account.Linked_to_another
                });
        (* RFC a-persons-api-key-is-their-own-provider-account 3.6: from the
           start of the purge of an account on, no turn spends it, before
           anything of it is deleted. *)
        let dave = person zone ~base_path ~name:"dave" ~hex:'d' in
        let dave_account = captured dave.home in
        let erin = person zone ~base_path ~name:"erin" ~hex:'e' in
        let erin_account = captured erin.home in
        allowed "a turn before the purge of its account" (turn dave ()) dave_account;
        (* The home the layout spells for the id of dave's account under the
           namespace of erin: what a caller that did not compare the owner
           would claim. The log links the account to dave, so erin gets one
           answer for it, before the purge and after. *)
        let dave_id_under_erin =
          let home =
            get_text
              (Layout.home
                 ~runtime_root:erin.runtime_root
                 Layout.Claude_home
                 ~account_id:(Provider_account_id.to_string dave.account))
          in
          Fs_compat.mkdir_p home;
          captured home
        in
        let anothers label =
          refused label (own erin ~account:dave.account ()) dave_id_under_erin (fun refusal ->
            refusal
            = Access.Account_unavailable
                { provider_account_id = dave.account
                ; reason = Authz_provider_account.Linked_to_another
                })
        in
        anothers "the account of another person, on a home of one's own namespace";
        allowed "the person's own account before its purge" (own dave ()) dave_account;
        (match
           Authz_purge.start
             zone
             ~user_id:dave.user_id
             (Authz_purge_event.Provider_account
                { owner = dave.user_id; provider_account_id = dave.account })
         with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Authz_purge.error_detail error));
        refused
          "a turn once the purge of its account started"
          (turn dave ())
          dave_account
          (denied (fun reason ->
             reason = Authz_decision.Provider_account_unavailable Authz_decision.Resource_purged));
        refused
          "the person's own account once its purge started"
          (own dave ())
          dave_account
          (fun refusal ->
            refusal
            = Access.Account_unavailable
                { provider_account_id = dave.account
                ; reason = Authz_provider_account.Defect Authz_decision.Resource_purged
                });
        anothers "the same account once its purge started";
        (* The home is checked before the status: another person learns
           nothing of the purge from the id of the account. *)
        refused
          "the purged account of another person"
          (own erin ~account:dave.account ())
          dave_account
          (fun refusal -> refusal = Access.Not_the_account_home dave.account);
        allowed "a turn on an account no purge names" (turn erin ()) erin_account;
        allowed "the own account no purge names" (own erin ()) erin_account;
        (* RFC §3.4: credential-free person seals ([seal_person] /
           [Runtime_account_runtime.of_person_template]) carry no key or env
           at table-build time; [authorize] resolves namespace, home,
           integration, and current-generation key on demand. *)
        let grace = person zone ~base_path ~name:"grace" ~hex:'9' in
        let claude_integration = get (Integration_id.of_string "claude_code") in
        let other_integration = get (Integration_id.of_string "other_claude") in
        let codex_integration = get (Integration_id.of_string "codex") in
        let grace_key_account = get (Provider_account_id.of_string "account-grace-key") in
        (match
           Authz_provider_account.link_key
             zone
             ~user_id:grace.user_id
             ~provider_account_id:grace_key_account
             ~integration_id:claude_integration
         with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
        let grace_runtime, grace_keeper_name =
          runtime_and_keeper zone ~user_id:grace.user_id ~account:grace_key_account ~name:"grace-key"
        in
        let grace_key =
          { grace with
            account = grace_key_account
          ; runtime = grace_runtime
          ; keeper = grace_keeper_name
          ; home = claude_home ~runtime_root:grace.runtime_root grace_key_account
          }
        in
        let grace_codex_account = get (Provider_account_id.of_string "account-grace-codex") in
        (match
           Authz_provider_account.link
             zone
             ~user_id:grace.user_id
             ~provider_account_id:grace_codex_account
             ~integration_id:codex_integration
         with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
        let grace_codex_runtime, grace_codex_keeper_name =
          runtime_and_keeper zone ~user_id:grace.user_id ~account:grace_codex_account ~name:"grace-codex"
        in
        let grace_codex =
          { grace with
            account = grace_codex_account
          ; runtime = grace_codex_runtime
          ; keeper = grace_codex_keeper_name
          ; home = codex_home ~runtime_root:grace.runtime_root grace_codex_account
          }
        in
        let template_toml =
          {|
[models.sonnet]
api-name = "claude-sonnet-4"
max-context = 200000
tools-support = true
streaming = true

[models.codex]
api-name = "gpt-5-codex"
max-context = 128000
tools-support = true
streaming = true

[models.muse]
api-name = "muse-1"
max-context = 128000
tools-support = true
streaming = true

[providers.claude_code]
display-name = "Claude Code"
protocol = "claude-code"
command = "/bin/echo"
account-home = "/tmp/operator-claude-home"
is-non-interactive = true

[providers.codex]
display-name = "Codex"
protocol = "codex-app-server"
command = "/bin/echo"
is-non-interactive = true

[providers.local]
display-name = "Local HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.agy]
display-name = "Antigravity"
protocol = "antigravity-cli"
command = "/bin/echo"
is-non-interactive = true
timeout-s = 180.0

[claude_code.sonnet]
[codex.codex]
[local.sonnet]
[agy.sonnet]

[runtime]
default = "claude_code.sonnet"
|}
        in
        let template_cfg =
          match Runtime_toml.parse_string template_toml with
          | Ok cfg -> cfg
          | Error _ -> Alcotest.fail "the person template fixture does not parse"
        in
        (* Build both person seals and runtime BEFORE any key file exists on
           disk AND with an operator credential in the process env. *)
        let sealed_grace_person, grace_person_runtime =
          with_env "ANTHROPIC_API_KEY" "sk-operator-should-not-leak" (fun () ->
            let sealed =
              Access.seal_person
                ~client:Account.Claude_code
                ~provider_account_id:grace_key.account
                ~integration_id:claude_integration
                ~account_home:grace_key.home
            in
            let runtime =
              match
                Runtime_account_runtime.of_person_template
                  template_cfg
                  ~template:"claude_code"
                  ~provider_account_id:grace_key.account
                  ~integration_id:claude_integration
                  ~account_home:(Some grace_key.home)
                  ~binding:(Runtime_account_runtime.Model "sonnet")
              with
              | Ok rt -> rt
              | Error error -> Alcotest.fail (Runtime_account_runtime.error_to_string error)
            in
            sealed, runtime)
        in
        let sealed_grace_from_runtime =
          match grace_person_runtime.Runtime_instance.execution with
          | Runtime_execution.Claude_code exec -> exec.account_home
          | Runtime_execution.Agent_core _
          | Runtime_execution.Codex_app_server _
          | Runtime_execution.Antigravity_cli _
          | Runtime_execution.Acp _ ->
            Alcotest.fail "expected Claude_code execution from of_person_template"
        in
        Alcotest.(check string)
          "seal_person preserves account_home without credentials"
          grace_key.home
          (Access.home sealed_grace_person);
        Alcotest.(check bool)
          "of_person_template uses matching person seal"
          true
          (Access.same sealed_grace_person sealed_grace_from_runtime);
        Alcotest.(check string)
          "of_person_template seals passed account_home rather than operator account-home"
          grace_key.home
          (Access.home sealed_grace_from_runtime);
        (match
           List.find_opt
             (fun (b : Runtime_schema.binding) -> String.equal b.provider_id "local")
             template_cfg.Runtime_schema.bindings
         with
         | None -> Alcotest.fail "missing local HTTP fixture binding"
         | Some http_binding ->
           (match
              Runtime_instance.of_person_binding
                ~provider_account_id:grace_key.account
                ~integration_id:claude_integration
                ~account_home:(Some grace_key.home)
                template_cfg
                http_binding
            with
            | Ok (_ : Runtime_instance.t) ->
              Alcotest.fail "of_person_binding must refuse HTTP bindings with account_home"
            | Error (Runtime_config_error.Execution_unbuildable _) -> ()
            | Error reason ->
              Alcotest.failf
                "unexpected drop reason for HTTP binding with account_home: %s"
                (Runtime_config_error.string_of_drop_reason reason));
           (match
              Runtime_instance.of_person_binding
                ~provider_account_id:grace_key.account
                ~integration_id:claude_integration
                ~account_home:None
                template_cfg
                http_binding
            with
            | Error reason ->
              Alcotest.failf
                "of_person_binding must build credential-free HTTP binding with account_home=None: %s"
                (Runtime_config_error.string_of_drop_reason reason)
            | Ok http_rt ->
              (match http_rt.Runtime_instance.execution with
               | Runtime_execution.Agent_core sealed ->
                 Alcotest.(check bool)
                   "of_person_binding HTTP seals as Person_api"
                   true
                   (Access.is_person_api sealed)
               | _ -> Alcotest.fail "expected Agent_core execution from HTTP of_person_binding")));
        (match
           Runtime_account_runtime.of_person_template
             template_cfg
             ~template:"claude_code"
             ~provider_account_id:grace_key.account
             ~integration_id:claude_integration
             ~account_home:None
             ~binding:(Runtime_account_runtime.Model "sonnet")
         with
         | Ok (_ : Runtime_instance.t) ->
           Alcotest.fail "of_person_template must refuse official CLI binding with account_home=None"
         | Error _ -> ());
        let claude_cred_cfg =
          { template_cfg with
            Runtime_schema.providers =
              List.map
                (fun (p : Runtime_schema.provider) ->
                   if String.equal p.id "claude_code"
                   then { p with credentials = Some (Runtime_schema.Env "ANTHROPIC_API_KEY") }
                   else p)
                template_cfg.Runtime_schema.providers
          }
        in
        (match
           List.find_opt
             (fun (b : Runtime_schema.binding) -> String.equal b.provider_id "claude_code")
             claude_cred_cfg.Runtime_schema.bindings
         with
         | None -> Alcotest.fail "missing claude_code fixture binding"
         | Some claude_binding ->
           (match
              Runtime_instance.of_person_binding
                ~provider_account_id:grace_key.account
                ~integration_id:claude_integration
                ~account_home:(Some grace_key.home)
                claude_cred_cfg
                claude_binding
            with
            | Ok (_ : Runtime_instance.t) ->
              Alcotest.fail "of_person_binding must refuse providers declaring credentials"
            | Error (Runtime_config_error.Execution_unbuildable _) -> ()
            | Error reason ->
              Alcotest.failf
                "unexpected drop reason for credentialed provider: %s"
                (Runtime_config_error.string_of_drop_reason reason)));
        Alcotest.(check bool)
          "person seal differs from Captured seal"
          false
          (Access.same sealed_grace_person (Access.seal (captured grace_key.home)));
        Alcotest.(check bool)
          "person seal differs when integration changes"
          false
          (Access.same
             sealed_grace_person
             (Access.seal_person
                ~client:Account.Claude_code
                ~provider_account_id:grace_key.account
                ~integration_id:other_integration
                ~account_home:grace_key.home));
        (* Unlinked account refuses Own_account symmetrically with Keeper_turn
           before any key file or capture runs. *)
        let unlinked_account = get (Provider_account_id.of_string "account-grace-unlinked") in
        let unlinked_home = claude_home ~runtime_root:grace.runtime_root unlinked_account in
        refused_sealed
          "unlinked person seal refuses Own_account cleanly"
          (Access.Own_account { user_id = grace.user_id; provider_account_id = unlinked_account })
          (Access.seal_person
             ~client:Account.Claude_code
             ~provider_account_id:unlinked_account
             ~integration_id:claude_integration
             ~account_home:unlinked_home)
          (function
            | Access.Not_the_account_home id -> Provider_account_id.equal id unlinked_account
            | _ -> false);
        (* Before generation 1 exists on disk, authorize fails with Key_missing
           on demand rather than at table-build time. *)
        refused_sealed
          "person seal with missing gen-1 key file"
          (own grace_key ())
          sealed_grace_person
          (function
            | Access.Account_key_unusable
                { provider_account_id; reason = Runtime_api_key_file.Key_missing } ->
              Provider_account_id.equal provider_account_id grace_key.account
            | _ -> false);
        (* Write generation 1 and authorize with operator env still set. *)
        let write_grace_key ~generation raw =
          match
            Option.map
              (Runtime_api_key_file.write
                 ~runtime_root:grace.runtime_root
                 ~account_id:grace_key.account
                 ~generation)
              (Runtime_api_key_file.key_of_string raw)
          with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail ("failed writing grace key: " ^ raw)
        in
        write_grace_key ~generation:Key_generation.first "sk-grace-gen1";
        with_env "ANTHROPIC_API_KEY" "sk-operator-should-not-leak" (fun () ->
          (match Access.authorize (own grace_key ()) sealed_grace_person with
           | Error refusal -> Alcotest.fail (Access.refusal_to_string refusal)
           | Ok auth ->
             Alcotest.(check (option string))
               "own person seal captures gen-1 key on demand"
               (Some "sk-grace-gen1")
               (Account.environment_value (Access.account auth) "ANTHROPIC_API_KEY"));
          (match Access.authorize (turn grace_key ()) sealed_grace_person with
           | Error refusal -> Alcotest.fail (Access.refusal_to_string refusal)
           | Ok auth ->
             Alcotest.(check (option string))
               "turn person seal captures gen-1 key on demand"
               (Some "sk-grace-gen1")
               (Account.environment_value (Access.account auth) "ANTHROPIC_API_KEY")));
        (* Rotate key to generation 2; the SAME person seal refuses while gen-2
           is missing, then picks up gen-2 dynamically once written. *)
        let grace_gen2 =
          match
            Authz_provider_account.replace_key
              zone
              ~user_id:grace.user_id
              ~provider_account_id:grace_key.account
          with
          | Ok gen -> gen
          | Error _ -> Alcotest.fail "replace_key failed for grace_key"
        in
        refused_sealed
          "same person seal sees missing gen-2 after rotation"
          (own grace_key ())
          sealed_grace_person
          (function
            | Access.Account_key_unusable
                { provider_account_id; reason = Runtime_api_key_file.Key_missing } ->
              Provider_account_id.equal provider_account_id grace_key.account
            | _ -> false);
        write_grace_key ~generation:grace_gen2 "sk-grace-gen2";
        (match Access.authorize (turn grace_key ()) sealed_grace_person with
         | Error refusal -> Alcotest.fail (Access.refusal_to_string refusal)
         | Ok auth ->
           Alcotest.(check (option string))
             "same person seal picks up gen-2 key dynamically without rebuild"
             (Some "sk-grace-gen2")
             (Account.environment_value (Access.account auth) "ANTHROPIC_API_KEY"));
        (* Integration mismatch, home mismatch, operator calls refused. *)
        let wrong_integration_seal =
          Access.seal_person
            ~client:Account.Claude_code
            ~provider_account_id:grace_key.account
            ~integration_id:other_integration
            ~account_home:grace_key.home
        in
        refused_sealed
          "person seal refuses mismatched integration_id"
          (own grace_key ())
          wrong_integration_seal
          (function
            | Access.Not_the_account_integration { provider_account_id; expected; claimed } ->
              Provider_account_id.equal provider_account_id grace_key.account
              && Integration_id.equal expected claude_integration
              && Integration_id.equal claimed other_integration
            | _ -> false);
        let wrong_home_seal =
          Access.seal_person
            ~client:Account.Claude_code
            ~provider_account_id:grace_key.account
            ~integration_id:claude_integration
            ~account_home:alice.home
        in
        refused_sealed
          "person seal refuses foreign account_home"
          (turn grace_key ())
          wrong_home_seal
          (fun refusal -> refusal = Access.Not_the_account_home grace_key.account);
        refused_sealed
          "person seal refuses Operator_call"
          Access.Operator_call
          sealed_grace_person
          (fun refusal -> refusal = Access.No_operator);
        refused_sealed
          "person seal refuses Operator_keeper_turn"
          (Access.Operator_keeper_turn
             { keeper_name = alice.keeper; runtime_id = Runtime_id.to_string grace_key.runtime })
          sealed_grace_person
          (function
            | Access.No_operator_keeper name -> String.equal name alice.keeper
            | _ -> false);
        (* Codex person seal captures login when clean, refuses config.toml env_key. *)
        let sealed_grace_codex =
          match
            Runtime_account_runtime.of_person_template
              template_cfg
              ~template:"codex"
              ~provider_account_id:grace_codex.account
              ~integration_id:codex_integration
              ~account_home:(Some grace_codex.home)
              ~binding:(Runtime_account_runtime.Model "codex")
          with
          | Ok rt ->
            (match rt.Runtime_instance.execution with
             | Runtime_execution.Codex_app_server exec -> exec.account_home
             | Runtime_execution.Agent_core _
             | Runtime_execution.Claude_code _
             | Runtime_execution.Antigravity_cli _
             | Runtime_execution.Acp _ ->
               Alcotest.fail "expected Codex_app_server execution")
          | Error error -> Alcotest.fail (Runtime_account_runtime.error_to_string error)
        in
        (match Access.authorize (turn grace_codex ()) sealed_grace_codex with
         | Ok _ -> ()
         | Error refusal -> Alcotest.fail (Access.refusal_to_string refusal));
        Out_channel.with_open_text
          (Filename.concat grace_codex.home "config.toml")
          (fun oc ->
             Out_channel.output_string
               oc
               "[model_providers.custom]\nenv_key = \"OPENAI_API_KEY\"\n");
        refused_sealed
          "codex person seal asking for env_key is refused on demand"
          (turn grace_codex ())
          sealed_grace_codex
          (fun refusal -> refusal = Access.Home_asks_for_environment grace_codex.account);
        (* Purged account refuses as Account_unavailable even after key file removal. *)
        (match
           Authz_purge.start
             zone
             ~user_id:grace.user_id
             (Authz_purge_event.Provider_account
                { owner = grace.user_id; provider_account_id = grace_key.account })
         with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Authz_purge.error_detail error));
        (match
           Layout.key_file
             ~runtime_root:grace.runtime_root
             ~account_id:grace_key.account
             ~generation:grace_gen2
         with
         | Ok p when Sys.file_exists p -> Sys.remove p
         | _ -> ());
        refused_sealed
          "purged person seal fails availability before reading key file"
          (own grace_key ())
          sealed_grace_person
          (fun refusal ->
            refusal
            = Access.Account_unavailable
                { provider_account_id = grace_key.account
                ; reason = Authz_provider_account.Defect Authz_decision.Resource_purged
                });
        (* RFC a-persons-api-key-is-their-own-provider-account 3.9: person-owned
           HTTP API keys. Seal strips operator credentials/headers (Plan D4),
           authorize_api_for checks zone owner/active/availability and injects
           the person's current-generation key file, refusing Operator_call,
           Operator_keeper_turn, cross-owner, login accounts, and open keys
           without leaking filesystem paths. *)
        let op_template =
          Llm_provider.Provider_config.make
            ~kind:Llm_provider.Provider_config.Anthropic
            ~model_id:"claude-sonnet-5"
            ~base_url:"https://api.anthropic.com"
            ~api_key:"sk-operator-leaked"
            ~headers:[ "x-api-key", "op-hdr"; "x-operator-secret", "op-secret" ]
            ()
        in
        let person_sealed =
          Access.seal_person_api ~provider_account_id:frank_key.account op_template
        in
        Alcotest.(check bool) "person api seal marked" true (Access.is_person_api person_sealed);
        let decl = Access.api_declaration person_sealed in
        Alcotest.(check string) "person api declaration has empty api_key" "" (decl.api_key :> string);
        Alcotest.(check int) "person api declaration strips headers" 0 (List.length decl.headers);
        let refuse_api label request sealed expected =
          match Access.authorize_api_for request sealed with
          | Ok (_ : Llm_provider.Provider_config.t) ->
            Alcotest.failf "%s: unexpectedly authorized" label
          | Error refusal ->
            if not (expected refusal)
            then
              Alcotest.failf
                "%s: refused for another reason: %s"
                label
                (Access.refusal_to_string refusal)
        in
        refuse_api
          "host authorize_api refuses Person_api"
          Access.Operator_call
          person_sealed
          (function
            | Access.No_operator -> true
            | _ -> false);
        (match Access.authorize_api person_sealed with
         | Error Access.No_operator -> ()
         | Error refusal ->
           Alcotest.failf
             "authorize_api refused Person_api with unexpected reason: %s"
             (Access.refusal_to_string refusal)
         | Ok (_ : Llm_provider.Provider_config.t) ->
           Alcotest.fail "authorize_api allowed Person_api");
        refuse_api
          "Operator_keeper_turn refuses Person_api"
          (Access.Operator_keeper_turn { keeper_name = "k-op"; runtime_id = Runtime_id.to_string frank_key.runtime })
          person_sealed
          (function
            | Access.No_operator_keeper name -> String.equal name "k-op"
            | _ -> false);
        (match Access.authorize_api_for (own frank_key ()) person_sealed with
         | Error refusal ->
           Alcotest.failf "Own_account on person key refused: %s" (Access.refusal_to_string refusal)
         | Ok authorized_cfg ->
           Alcotest.(check string)
             "Own_account injects person key"
             "sk-test-the-key-of-frank"
             (authorized_cfg.api_key :> string);
           Alcotest.(check (option string))
             "wire default anthropic-version header present"
             (Some "2023-06-01")
             (List.assoc_opt "anthropic-version" authorized_cfg.headers);
           Alcotest.(check (option string))
             "operator custom header not carried"
             None
             (List.assoc_opt "x-operator-secret" authorized_cfg.headers));
        (match Access.authorize_api_for (turn frank_key ()) person_sealed with
         | Error refusal ->
           Alcotest.failf "Keeper_turn on person key refused: %s" (Access.refusal_to_string refusal)
         | Ok authorized_cfg ->
           Alcotest.(check string)
             "Keeper_turn injects person key"
             "sk-test-the-key-of-frank"
             (authorized_cfg.api_key :> string));
        refuse_api
          "cross-owner Own_account refuses Person_api"
          (own bob ~account:frank_key.account ())
          person_sealed
          (function
            | Access.Account_unavailable
                { provider_account_id; reason = Authz_provider_account.Linked_to_another } ->
              Provider_account_id.equal provider_account_id frank_key.account
            | _ -> false);
        refuse_api
          "mismatched Own_account id refuses Person_api"
          (own frank_key ~account:frank.account ())
          person_sealed
          (not_the_key_of frank);
        refuse_api
          "cross-owner Keeper_turn refuses Person_api"
          (turn bob ())
          person_sealed
          (fun refusal ->
             match refusal with
             | Access.Not_the_account_key id -> Provider_account_id.equal id bob.account
             | _ -> false);
        refuse_api
          "Person_api on login account is refused"
          (own frank ())
          (Access.seal_person_api ~provider_account_id:frank.account op_template)
          (not_the_key_of frank);
        Unix.chmod key_of_frank 0o640;
        (match Access.authorize_api_for (own frank_key ()) person_sealed with
         | Ok (_ : Llm_provider.Provider_config.t) ->
           Unix.chmod key_of_frank 0o600;
           Alcotest.fail "open key file was authorized"
         | Error refusal ->
           Unix.chmod key_of_frank 0o600;
           let text = Access.refusal_to_string refusal in
           Alcotest.(check bool)
             "refusal does not leak key file path"
             false
             (String.contains text '/'));
        (* Purged key account refuses Person_api. *)
        let purged_key_id = get (Provider_account_id.of_string "account-frank-purged-key") in
        (match
           Authz_provider_account.link_key
             zone
             ~user_id:frank.user_id
             ~provider_account_id:purged_key_id
             ~integration_id:(get (Integration_id.of_string "operator"))
         with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
        (match
           Option.map
             (Runtime_api_key_file.write
                ~runtime_root:frank.runtime_root
                ~account_id:purged_key_id
                ~generation:Key_generation.first)
             (Runtime_api_key_file.key_of_string "sk-test-purged-key")
         with
         | Some (Ok ()) -> ()
         | _ -> Alcotest.fail "purged fixture key not written");
        (match
           Authz_purge.start
             zone
             ~user_id:frank.user_id
             (Authz_purge_event.Provider_account
                { owner = frank.user_id; provider_account_id = purged_key_id })
         with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Authz_purge.error_detail error));
        refuse_api
          "purged key account refuses Person_api"
          (own frank ~account:purged_key_id ())
          (Access.seal_person_api ~provider_account_id:purged_key_id op_template)
          (function
            | Access.Account_unavailable
                { provider_account_id; reason = Authz_provider_account.Defect Authz_decision.Resource_purged } ->
              Provider_account_id.equal provider_account_id purged_key_id
            | _ -> false);
        (* HTTP verify_as_command against loopback HTTP with Person_api:
           Operator_call stops before connecting, person key reaches the wire
           and 401 maps to key_refused while 403 maps to provider_auth_refused. *)
        Eio.Switch.run (fun sw ->
          let reply_status = ref 401 in
          let observed_headers = ref "" in
          let connections = Atomic.make 0 in
          let listening =
            Eio.Net.listen
              ~sw
              ~backlog:5
              ~reuse_addr:true
              env#net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          Eio.Fiber.fork_daemon ~sw (fun () ->
            while true do
              Eio.Net.accept_fork ~sw listening ~on_error:(fun _ -> ()) (fun flow _addr ->
                Atomic.incr connections;
                let reader = Eio.Buf_read.of_flow ~max_size:65536 flow in
                let rec read_headers acc =
                  let line = Eio.Buf_read.line reader in
                  let trimmed =
                    let n = String.length line in
                    if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line
                  in
                  if String.equal trimmed "" then List.rev acc else read_headers (trimmed :: acc)
                in
                let header_lines = read_headers [] in
                let content_len =
                  List.find_map
                    (fun line ->
                       match String.index_opt line ':' with
                       | Some idx ->
                         let k = String.lowercase_ascii (String.trim (String.sub line 0 idx)) in
                         if String.equal k "content-length"
                         then int_of_string_opt (String.trim (String.sub line (idx + 1) (String.length line - idx - 1)))
                         else None
                       | None -> None)
                    header_lines
                  |> Option.value ~default:0
                in
                let body_str = Eio.Buf_read.take content_len reader in
                observed_headers := String.concat "\r\n" header_lines ^ "\r\n\r\n" ^ body_str;
                let status = !reply_status in
                let reason = if status = 401 then "Unauthorized" else "Forbidden" in
                let body = {|{"error":{"message":"bad auth","type":"auth_error"}}|} in
                let response =
                  Printf.sprintf
                    "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                    status
                    reason
                    (String.length body)
                    body
                in
                Eio.Flow.copy_string response flow;
                (try Eio.Flow.shutdown flow `Send with
                 | Eio.Io _ | Unix.Unix_error _ -> ()))
            done);
          let port =
            match Eio.Net.listening_addr listening with
            | `Tcp (_, port) -> port
            | `Unix _ -> Alcotest.fail "expected TCP listening socket"
          in
          let http_toml =
            Printf.sprintf
              {|
[runtime]
default = "operator.first"
[providers.operator]
display-name = "Operator endpoint"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d/v1"
[providers.operator.credentials]
type = "inline"
value = "sk-operator-must-not-leak"
[providers.operator.headers]
x-operator-secret = "op-header-must-not-leak"
[models.first]
api-name = "first-model"
max-context = 4096
tools-support = true
streaming = true
[models.first.capabilities]
supports-tool-choice = true
[operator.first]
|}
              port
          in
          let http_config =
            match Runtime_toml.parse_string http_toml with
            | Ok cfg -> cfg
            | Error _ -> Alcotest.fail "person HTTP fixture runtime.toml refused"
          in
          let operator_integration = get (Integration_id.of_string "operator") in
          let person_runtime =
            match
              Runtime_account_runtime.of_person_template
                http_config
                ~template:"operator"
                ~provider_account_id:frank_key.account
                ~integration_id:operator_integration
                ~account_home:None
                ~binding:(Runtime_account_runtime.Model "first")
            with
            | Ok rt -> rt
            | Error err -> Alcotest.fail (Runtime_account_runtime.error_to_string err)
          in
          let verify_op =
            Runtime_verification.verify_as_command
              ~env
              ~sw
              ~private_dir:(Filename.temp_dir ~temp_dir:root "verify-op-" "")
              ~timeout_s:5.
              ~account_request:Access.Operator_call
              person_runtime
          in
          (match verify_op.Runtime_verification.failure with
           | Some failure ->
             Alcotest.(check string)
               "operator verification of person runtime refused"
               "account_not_authorized"
               (Runtime_verification.failure_code failure)
           | None -> Alcotest.fail "operator verification of person runtime ran");
          Alcotest.(check int)
            "operator verification made no HTTP connections"
            0
            (Atomic.get connections);
          reply_status := 401;
          observed_headers := "";
          let verify_401 =
            Runtime_verification.verify_as_command
              ~env
              ~sw
              ~private_dir:(Filename.temp_dir ~temp_dir:root "verify-401-" "")
              ~timeout_s:5.
              ~account_request:(own frank_key ())
              person_runtime
          in
          (match verify_401.Runtime_verification.failure with
           | Some failure ->
             Alcotest.(check string)
               "HTTP 401 on person key verification maps to key_refused"
               "key_refused"
               (Runtime_verification.failure_code failure)
           | None -> Alcotest.fail "HTTP 401 verification unexpectedly succeeded");
          let contains s sub =
            let slen = String.length s and sublen = String.length sub in
            let rec loop i =
              i + sublen <= slen && (String.equal (String.sub s i sublen) sub || loop (i + 1))
            in
            sublen = 0 || loop 0
          in
          Alcotest.(check bool)
            "wire request used person key"
            true
            (contains !observed_headers "Bearer sk-test-the-key-of-frank");
          Alcotest.(check bool)
            "wire request leaked no operator inline key"
            false
            (contains !observed_headers "sk-operator-must-not-leak");
          Alcotest.(check bool)
            "wire request leaked no operator header"
            false
            (contains !observed_headers "op-header-must-not-leak");
          reply_status := 403;
          let verify_403 =
            Runtime_verification.verify_as_command
              ~env
              ~sw
              ~private_dir:(Filename.temp_dir ~temp_dir:root "verify-403-" "")
              ~timeout_s:5.
              ~account_request:(own frank_key ())
              person_runtime
          in
          (match verify_403.Runtime_verification.failure with
           | Some failure ->
             Alcotest.(check string)
               "HTTP 403 on person key verification stays provider_auth_refused"
               "provider_auth_refused"
               (Runtime_verification.failure_code failure)
           | None -> Alcotest.fail "HTTP 403 verification unexpectedly succeeded"));
        (* Bytes another writer added to the log: the next commit finds the
           end moved and stops the log. No decision rests on the state of the
           zone from then on, so no client starts for a person or for a turn
           of their Keeper. A refusal that reads no record stays as it was. *)
        Out_channel.with_open_gen
          [ Open_append; Open_binary ]
          0o600
          (Authz_log.path_of_base_path ~base_path)
          (fun channel -> Out_channel.output_string channel "{}\n");
        (match
           Authz_provider_account.link
             zone
             ~user_id:alice.user_id
             ~provider_account_id:(get (Provider_account_id.of_string "account-late"))
             ~integration_id:(get (Integration_id.of_string "claude_code"))
         with
         | Ok () -> Alcotest.fail "the zone wrote over a log another writer moved"
         | Error (_ : Authz_provider_account.error) -> ());
        let log_stopped = function
          | Access.Zone_uncertain (Z.Log_is_stopped _) -> true
          | _ -> false
        in
        refused "the person's own account in a stopped zone" (own alice ()) alice_account log_stopped;
        refused "a turn in a stopped zone" (turn alice ()) alice_account log_stopped;
        refused "an operator call in a stopped zone" Access.Operator_call alice_account (function
          | Access.No_operator -> true
          | _ -> false);
        refused_sealed
          "person seal own account in a stopped zone"
          (own grace_key ())
          sealed_grace_person
          log_stopped;
        refused_sealed
          "person seal turn in a stopped zone"
          (turn grace_key ())
          sealed_grace_person
          log_stopped;
        refused_sealed
          "person seal operator call in a stopped zone"
          Access.Operator_call
          sealed_grace_person
          (function
            | Access.No_operator -> true
            | _ -> false);
        refuse_api "Person_api in a stopped zone" (own frank_key ()) person_sealed log_stopped))
;;

let () =
  Alcotest.run
    "runtime_account_access_multi"
    [ "access", [ Alcotest.test_case "multi-account" `Quick test_multi_account ] ]
;;
