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

let turn
      (who : person)
      ?(channel = Channel.Autonomous)
      ?(pat = Pat_binding.Not_pat)
      ?(runtime = who.runtime)
      ?(keeper = who.keeper)
      ()
  =
  Access.Keeper_turn
    { owner = who.user_id
    ; keeper_id = get (Keeper_id.of_string keeper)
    ; channel
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
     Authz_keeper.make zone ~user_id:who.user_id ~keeper_id ~turn_scope ~draw:(fun () -> policy)
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
        (* A host client starts on an account of the host, which a
           multi-account process shares with no person (plan D3b). An API
           provider of the runtime table sends with the credential its
           operator declared, an account of the host too (plan D4), and so
           do the requests outside the table (plan D4b). *)
        List.iter
          (fun client ->
            match client, Access.authorize_host client with
            | ( ( Access.Antigravity
                | Access.Vibe
                | Access.Api_provider
                | Access.Model_list
                | Access.Files_api
                | Access.Replacement_catalog
                | Access.Web_search
                | Access.Systemone_cloud
                | Access.Voice_endpoint )
              , Ok (_ : Access.host_account) ) -> Alcotest.fail "a host client was allowed"
            | Access.Antigravity, Error (Access.Host_account Access.Antigravity)
            | Access.Vibe, Error (Access.Host_account Access.Vibe)
            | Access.Api_provider, Error (Access.Host_account Access.Api_provider)
            | Access.Model_list, Error (Access.Host_account Access.Model_list)
            | Access.Files_api, Error (Access.Host_account Access.Files_api)
            | Access.Replacement_catalog, Error (Access.Host_account Access.Replacement_catalog)
            | Access.Web_search, Error (Access.Host_account Access.Web_search)
            | Access.Systemone_cloud, Error (Access.Host_account Access.Systemone_cloud)
            | Access.Voice_endpoint, Error (Access.Host_account Access.Voice_endpoint)
              -> ()
            | ( ( Access.Antigravity
                | Access.Vibe
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
            ; Vibe
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
            | Runtime_execution.Muse_serve _
            | Runtime_execution.Vibe_cli _ -> Alcotest.fail "the API runtime fixture is not Agent Core"
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
          let lane, gates, health, standing =
            with_env jev_key_variable "jev-key" (fun () ->
              Runtime_typesafeai_policy.publish
                { Runtime_schema.default_typesafeai with
                  destinations =
                    ( { Runtime_schema.typesafe_destination with
                        endpoint = Printf.sprintf "http://127.0.0.1:%d/v1/systemone" port
                      ; api_key_env = jev_key_variable
                      }
                    , [] )
                ; absorb_gate = true
                ; memory_recall = Runtime_schema.Memory_recall_on Runtime_schema.All_keepers
                };
              Fun.protect
                ~finally:(fun () -> Runtime_typesafeai_policy.publish found_policy)
                (fun () ->
                  ( Masc.Typesafeai_config.lane_destinations ()
                  , [ ( "Board attention"
                      , Masc.Typesafeai_config.board_attention_destinations ~keeper_id:"reader" )
                    ; ( "the absorb gate"
                      , Masc.Typesafeai_config.absorb_gate_destinations ~keeper_id:"reader" )
                    ; ( "memory recall"
                      , Masc.Typesafeai_config.memory_recall_destinations ~keeper_id:"reader" )
                    ]
                  , Server_typesafeai_health.health_json ()
                  , Server_memory_recall_standing.read
                      ~keepers_dir:(Filename.temp_dir ~temp_dir:root "keepers-" "") )))
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
          (match standing with
           | Ok { Server_memory_recall_standing.lane =
                    Error Masc.Keeper_memory_recall_standing.Host_account_not_shared
                ; keepers = _
                } -> ()
           | Ok { Server_memory_recall_standing.lane = Error reason; keepers = _ } ->
             Alcotest.failf
               "the recall reading names another reason: %s"
               (Masc.Keeper_memory_recall_standing.reason_to_string reason)
           | Ok { Server_memory_recall_standing.lane = Ok (); keepers = _ } ->
             Alcotest.fail "the recall reading says the lane has a key"
           | Error detail -> Alcotest.failf "the recall reading failed: %s" detail);
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
         | Ok () -> Alcotest.fail "a second publication was taken");
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
          | _ -> false)))
;;

let () =
  Alcotest.run
    "runtime_account_access_multi"
    [ "access", [ Alcotest.test_case "multi-account" `Quick test_multi_account ] ]
;;
