(* Multi-account person runtime side-table lookup, missing-dir creation,
   candidate_backpressure preservation across reload, disabled default-route
   fallback, uncertain-zone fail-closed, and RFC §6.5 operator usage isolation.
   Linked without masc_test_deps because masc_test_deps auto-publishes
   single-user access. *)

open Authz_types
module Access = Runtime_account_access
module Layout = Runtime_account_home_layout
module B = Authz_bootstrap
module E = Authz_invite_event
module Z = Authz_zone

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture Authz value refused"
;;

let get_text = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "fixture step failed: %s" detail
;;

let start_ms = 1_700_000_000_000
let workspace = get (Workspace_id.of_string "workspace-1")

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind =
        ( Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
        | Unix.S_SOCK )
    ; _
    } -> Sys.remove path
;;

let commit zone ~author ~kind body =
  match Z.commit zone { Z.author; kind; body } with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "record refused: %s" (Z.error_detail error)
;;

let admit_person zone ~name ~hex =
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
  user_id, namespace
;;

let make_keeper_with_optional_runtime zone ~user_id ~keeper_name ~policy ~engine_name ~runtime =
  let keeper_id = get (Keeper_id.of_string keeper_name) in
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
       ~draw:(fun () -> policy)
       ~draw_engine_name:(fun () -> engine_name)
   with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
  Option.iter
    (fun runtime_id ->
      match Authz_keeper.assign zone ~user_id ~keeper_id ~runtime_id with
      | Ok () -> ()
      | Error error -> Alcotest.fail (Authz_keeper.error_detail error))
    runtime
;;

let write_runtime_toml path ~operator_home ~max_context =
  let text =
    Printf.sprintf
      {|
[runtime]
default = "operator.first"

[runtime.assignments]
kp-alice = "operator.first"
kp-unassigned = "operator.first"
kp-ghost = "operator.first"

[providers.operator]
display-name = "Operator"
protocol = "claude-code"
command = "/usr/bin/true"
account-home = %S
is-non-interactive = true

[providers.claude_code]
display-name = "Claude Code"
protocol = "claude-code"
command = "/usr/bin/true"
account-home = %S
is-non-interactive = true

[models.first]
api-name = "first-model"
max-context = 4096
tools-support = true
streaming = true

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = %d
tools-support = true
streaming = true

[operator.first]

[claude_code."claude-sonnet-5"]
|}
      operator_home
      operator_home
      max_context
  in
  Out_channel.with_open_bin path (fun ch -> Out_channel.output_string ch text)
;;

let test_person_side_table () =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "runtime-person-side-table-" "" in
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
        let user_id, namespace = admit_person zone ~name:"alice" ~hex:'a' in
        let account = get (Provider_account_id.of_string "account-alice") in
        (match
           Authz_provider_account.link
             zone
             ~user_id
             ~provider_account_id:account
             ~integration_id:(get (Integration_id.of_string "claude_code"))
         with
         | Ok () -> ()
         | Error error -> Alcotest.fail (Authz_provider_account.error_to_string error));
        let runtime_id_str = "account-alice.claude-sonnet-5" in
        let runtime_id = get (Runtime_id.of_string runtime_id_str) in
        (match
           Authz_runtime.make
             zone
             ~user_id
             ~provider_account_id:account
             ~runtime_id
             ~self_effects:Effect.(Set.of_list [ Read_state; Invoke_model; Use_tool ])
             ~draw:(fun () -> "grant-alice")
         with
         | Ok (_ : Grant_id.t) -> ()
         | Error error -> Alcotest.fail (Authz_runtime.error_detail error));
        make_keeper_with_optional_runtime
          zone
          ~user_id
          ~keeper_name:"keeper-alice"
          ~policy:"policy-alice"
          ~engine_name:"kp-alice"
          ~runtime:(Some runtime_id);
        make_keeper_with_optional_runtime
          zone
          ~user_id
          ~keeper_name:"keeper-unassigned"
          ~policy:"policy-unassigned"
          ~engine_name:"kp-unassigned"
          ~runtime:None;
        (match
           Access.publish
             (Access.Multi_account
                { zone; base_path; now = (fun () -> Float.of_int start_ms /. 1000.) })
         with
         | Ok (_ : Access.published) -> ()
         | Error error -> Alcotest.fail (Access.publish_error_to_string error));
        Alcotest.(check bool) "Runtime.is_multi_account" true (Runtime.is_multi_account ());
        let operator_home = Filename.concat root "operator-claude" in
        Unix.mkdir operator_home 0o700;
        let toml_path = Filename.concat root "runtime.toml" in
        write_runtime_toml toml_path ~operator_home ~max_context:1000000;
        let runtime_snapshot = Runtime.For_testing.snapshot () in
        Fun.protect
          ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
          (fun () ->
            (match Runtime.init_default_strict ~config_path:toml_path with
             | Ok () -> ()
             | Error msg -> Alcotest.failf "init_default_strict failed: %s" msg);
            (* Note: person_runtime_root does NOT exist beforehand; lookup must create it. *)
            let person_root = Layout.person_runtime_root ~base_path ~namespace in
            Alcotest.(check bool)
              "person root absent before first lookup"
              false
              (Sys.file_exists person_root);
            (* Entrypoint 1: runtime_id_for_keeper ignores operator runtime.toml assignments & defaults. *)
            Alcotest.(check (option string))
              "assigned person keeper resolves authz runtime"
              (Some runtime_id_str)
              (Runtime.runtime_id_for_keeper "kp-alice");
            Alcotest.(check (option string))
              "unassigned person keeper gets None (no default or TOML assignment fallback)"
              None
              (Runtime.runtime_id_for_keeper "kp-unassigned");
            Alcotest.(check (option string))
              "unknown keeper gets None (no TOML assignment fallback)"
              None
              (Runtime.runtime_id_for_keeper "kp-ghost");
            (* Entrypoint 2: get_runtime_by_id builds person runtime, creates dirs, hides operator runtimes. *)
            Alcotest.(check bool)
              "operator runtime hidden in multi-account"
              true
              (Option.is_none (Runtime.get_runtime_by_id "operator.first"));
            let rt1 =
              match Runtime.get_runtime_by_id runtime_id_str with
              | Some rt -> rt
              | None -> Alcotest.fail "person runtime not resolved by get_runtime_by_id"
            in
            Alcotest.(check string) "person runtime id" runtime_id_str rt1.Runtime_instance.id;
            Alcotest.(check bool)
              "execution marks person account"
              true
              (Runtime_execution.is_person_execution rt1.Runtime_instance.execution);
            let expected_home =
              get_text
                (Layout.home
                   ~runtime_root:person_root
                   Layout.Claude_home
                   ~account_id:(Provider_account_id.to_string account))
            in
            Alcotest.(check bool)
              "missing person home dir created on lookup"
              true
              (Sys.file_exists expected_home && Sys.is_directory expected_home);
            (* Entrypoint 3: resolve_assignment resolves person runtime & misses operator runtime. *)
            (match Runtime.resolve_assignment runtime_id_str with
             | `Lane lane ->
               Alcotest.(check (list string))
                 "lane has person runtime"
                 [ runtime_id_str ]
                 (Runtime_lane.ordered_candidates lane)
             | `Unavailable _ | `Missing ->
               Alcotest.fail "resolve_assignment failed for person runtime");
            (match Runtime.resolve_assignment "operator.first" with
             | `Missing -> ()
             | `Lane _ | `Unavailable _ ->
               Alcotest.fail "operator runtime must not resolve in multi-account");
            (* Entrypoint 4 + candidate_backpressure preservation across reload. *)
            Runtime_candidate_backpressure.note_rate_limit
              ~candidate:rt1.candidate_backpressure
              ~retry_after:(Some 42.0);
            let snap1 = Runtime.keeper_dispatch_snapshot ~keeper_name:"kp-alice" in
            let snap_unassigned = Runtime.keeper_dispatch_snapshot ~keeper_name:"kp-unassigned" in
            Alcotest.(check bool)
              "unassigned dispatch snapshot has no default route fallback"
              true
              (Runtime.same_keeper_dispatch
                 snap_unassigned
                 (Runtime.keeper_dispatch_snapshot ~keeper_name:"kp-ghost"));
            write_runtime_toml toml_path ~operator_home ~max_context:1000000;
            (match Runtime.init_default_strict ~config_path:toml_path with
             | Ok () -> ()
             | Error msg -> Alcotest.failf "unchanged reload failed: %s" msg);
            let rt2 =
              match Runtime.get_runtime_by_id runtime_id_str with
              | Some rt -> rt
              | None -> Alcotest.fail "person runtime missing after unchanged reload"
            in
            Alcotest.(check bool)
              "candidate_backpressure physical cell preserved across unchanged reload"
              true
              (rt1.candidate_backpressure == rt2.candidate_backpressure);
            Alcotest.(check bool)
              "candidate_backpressure state preserved across unchanged reload"
              true
              (Option.is_some
                 (Runtime_candidate_backpressure.candidate_backpressure
                    ~now:(Float.of_int start_ms /. 1000.)
                    ~candidate:rt2.candidate_backpressure));
            let snap2 = Runtime.keeper_dispatch_snapshot ~keeper_name:"kp-alice" in
            Alcotest.(check bool)
              "keeper_dispatch_snapshot preserves candidate across unchanged reload"
              true
              (Runtime.same_keeper_dispatch snap1 snap2);
            (* Rebinding model max-context issues a fresh candidate_backpressure cell. *)
            write_runtime_toml toml_path ~operator_home ~max_context:500000;
            (match Runtime.init_default_strict ~config_path:toml_path with
             | Ok () -> ()
             | Error msg -> Alcotest.failf "modified reload failed: %s" msg);
            let rt3 =
              match Runtime.get_runtime_by_id runtime_id_str with
              | Some rt -> rt
              | None -> Alcotest.fail "person runtime missing after modified reload"
            in
            Alcotest.(check bool)
              "changed binding resets candidate_backpressure cell"
              false
              (rt2.candidate_backpressure == rt3.candidate_backpressure);
            let snap3 = Runtime.keeper_dispatch_snapshot ~keeper_name:"kp-alice" in
            Alcotest.(check bool)
              "keeper_dispatch_snapshot detects rebound candidate cell"
              false
              (Runtime.same_keeper_dispatch snap2 snap3);
            (* Default-route fallback and operator lists disabled in multi-account mode. *)
            Alcotest.(check int) "get_runtimes is empty" 0 (List.length (Runtime.get_runtimes ()));
            Alcotest.(check int) "get_runtime_ids is empty" 0 (List.length (Runtime.get_runtime_ids ()));
            Alcotest.(check bool)
              "get_default_runtime is None"
              true
              (Option.is_none (Runtime.get_default_runtime ()));
            let route, def_rt, rts = Runtime.get_default_route_and_runtimes () in
            Alcotest.(check (option string)) "default_route is None" None route;
            Alcotest.(check bool) "default_rt is None" true (Option.is_none def_rt);
            Alcotest.(check int) "runtimes list is empty" 0 (List.length rts);
            let raised_default_route =
              try
                ignore (Runtime.get_default_route ());
                false
              with Failure _ -> true
            in
            Alcotest.(check bool) "get_default_route fails in multi-account" true raised_default_route;
            let raised_default_id =
              try
                ignore (Runtime.get_default_runtime_id ());
                false
              with Failure _ -> true
            in
            Alcotest.(check bool)
              "get_default_runtime_id fails in multi-account"
              true
              raised_default_id;
            Alcotest.(check (option string))
              "Keeper_meta_contract.runtime_route_of_keeper_name returns None for unassigned"
              None
              (Masc.Keeper_meta_contract.runtime_route_of_keeper_name "kp-unassigned");
            Alcotest.(check (option string))
              "Keeper_meta_contract.runtime_route_of_keeper_name resolves assigned person keeper"
              (Some runtime_id_str)
              (Masc.Keeper_meta_contract.runtime_route_of_keeper_name "kp-alice");
            Alcotest.(check string)
              "Keeper_direct_runtime_continuation.For_testing.current_assignment returns empty for unassigned"
              ""
              (Masc.Keeper_direct_runtime_continuation.For_testing.current_assignment "kp-unassigned");
            (* RFC §6.5: person usage never updates operator usage table or sink observer. *)
            let observer_calls = ref 0 in
            Runtime_provider_usage_window.set_record_observer (fun ~scope:_ ~observed_at:_ _ ->
              incr observer_calls);
            let report : Runtime_provider_usage_window.report =
              { source = Runtime_provider_usage_window.Claude_code_rate_limit_event
              ; windows =
                  [ { limit_id = None
                    ; kind = Runtime_provider_usage_window.Five_hour
                    ; role = Runtime_provider_usage_window.Gates_model_calls
                    ; utilization = Runtime_provider_usage_window.Fraction 0.75
                    ; resets_at = Some 1_700_010_000
                    }
                  ]
              }
            in
            Runtime_provider_usage_window.record
              ~scope:(Runtime_quota_window.scope_of_claude_code_home (Some expected_home))
              ~observed_at:1_700_000_100.0
              report;
            Alcotest.(check int) "usage observer never called for person" 0 !observer_calls;
            Alcotest.(check int)
              "recorded_scopes stays empty for person"
              0
              (List.length (Runtime_provider_usage_window.recorded_scopes ()));
            Alcotest.(check bool)
              "http_read_of_runtime returns None for person runtime"
              true
              (Option.is_none (Runtime_provider_usage_read.http_read_of_runtime rt3));
            (* Stopped/uncertain authz zone must fail closed without falling back to cached entries. *)
            Out_channel.with_open_gen
              [ Open_append; Open_binary ]
              0o600
              (Authz_log.path_of_base_path ~base_path)
              (fun channel -> Out_channel.output_string channel "{}\n");
            (match
               Authz_provider_account.link
                 zone
                 ~user_id
                 ~provider_account_id:(get (Provider_account_id.of_string "account-late"))
                 ~integration_id:(get (Integration_id.of_string "claude_code"))
             with
             | Ok () -> Alcotest.fail "stopped zone allowed append"
             | Error (_ : Authz_provider_account.error) -> ());
            Alcotest.(check (option string))
              "uncertain zone runtime_id_for_keeper fails closed"
              None
              (Runtime.runtime_id_for_keeper "kp-alice");
            Alcotest.(check bool)
              "uncertain zone get_runtime_by_id fails closed"
              true
              (Option.is_none (Runtime.get_runtime_by_id runtime_id_str));
            (match Runtime.resolve_assignment runtime_id_str with
             | `Missing -> ()
             | `Lane _ | `Unavailable _ ->
               Alcotest.fail "uncertain zone resolve_assignment must fail closed")))
  )
;;

let () =
  Alcotest.run
    "runtime_person_side_table"
    [ "side_table", [ Alcotest.test_case "lookup_reload_and_isolation" `Quick test_person_side_table ] ]
;;
