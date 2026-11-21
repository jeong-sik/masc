(* Multi-account Keeper turn seams (A2-2):
   - source.v3 person_caller encoding/decoding and strict source.v2 hard-cut
   - batch non-coalescing across operator vs person, distinct users, and distinct stored_scopes
   - PAT checked at admit vs per-attempt stored_scope/owner/assignment recheck
   - exhaustive channel & caller routing via Keeper_agent_run.resolve_turn_walk_owner
   - Runtime_account_call.call_in_turn_of acquired before authorize_account + cancellation safety. *)

open Authz_types
module Access = Runtime_account_access
module Account = Runtime_official_account
module B = Authz_bootstrap
module Batch = Masc.Keeper_chat_operation_batch
module Channel_k = Keeper_continuation_channel
module Driver = Masc.Keeper_turn_driver
module E = Authz_invite_event
module Eq = Keeper_event_queue
module Keeper_registry = Masc.Keeper_registry
module Op = Keeper_chat_operation
module Payload = Masc.Keeper_chat_operation_payload
module Store = Keeper_chat_operation_store
module Z = Authz_zone

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture Authz value refused"
;;

let get_text = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "fixture step failed: %s" detail
;;

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

let start_ms = 1_700_000_000_000
let workspace = get (Workspace_id.of_string "workspace-1")

let commit zone ~author ~kind body =
  match Z.commit zone { Z.author; kind; body } with
  | Ok (_ : Z.committed) -> ()
  | Error error -> Alcotest.failf "record refused: %s" (Z.error_detail error)
;;

type person_fixture =
  { user_id : User_id.t
  ; namespace : Account_home_namespace.t
  ; account : Provider_account_id.t
  ; runtime_id : Runtime_id.t
  ; keeper_id : Keeper_id.t
  ; engine_name : string
  }

let setup_person zone ~name ~hex =
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
  let runtime_id = get (Runtime_id.of_string ("account-" ^ name ^ ".claude-sonnet-5")) in
  (match
     Authz_runtime.make
       zone
       ~user_id
       ~provider_account_id:account
       ~runtime_id
       ~self_effects:Effect.(Set.of_list [ Read_state; Invoke_model; Use_tool ])
       ~draw:(fun () -> "grant-" ^ name)
   with
   | Ok (_ : Grant_id.t) -> ()
   | Error error -> Alcotest.fail (Authz_runtime.error_detail error));
  let keeper_id = get (Keeper_id.of_string ("keeper-" ^ name)) in
  let engine_name = "kp-" ^ name in
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
       ~draw_engine_name:(fun () -> engine_name)
   with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
  (match Authz_keeper.assign zone ~user_id ~keeper_id ~runtime_id with
   | Ok () -> ()
   | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
  { user_id; namespace; account; runtime_id; keeper_id; engine_name }
;;

let write_runtime_toml path ~cli_script ~operator_home =
  let text =
    Printf.sprintf
      {|
[runtime]
default = "operator.first"

[providers.operator]
display-name = "Operator"
protocol = "claude-code"
command = %S
account-home = %S
is-non-interactive = true

[providers.claude_code]
display-name = "Claude Code"
protocol = "claude-code"
command = %S
account-home = %S
is-non-interactive = true

[models.first]
api-name = "first-model"
max-context = 4096
tools-support = true
streaming = true

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 200000
tools-support = true
streaming = true

[operator.first]

[claude_code."claude-sonnet-5"]
|}
      cli_script
      operator_home
      cli_script
      operator_home
  in
  Out_channel.with_open_bin path (fun ch -> Out_channel.output_string ch text)
;;

let write_fail_marker_script path ~marker =
  let text = Printf.sprintf "#!/bin/sh\ntouch %S\nexit 1\n" marker in
  Out_channel.with_open_bin path (fun ch -> Out_channel.output_string ch text);
  Unix.chmod path 0o700
;;

let make_dashboard_source ~person_caller () =
  get_text
    (Payload.source_to_json_with_person_caller
       ~person_caller
       ~submitted_by:"user"
       ~thread_id:"thread-1"
       ~continuation_channel:(get_text (Channel_k.dashboard ~thread_id:"thread-1"))
       ~surface:(Masc.Surface_ref.Dashboard { session_id = None })
       ~channel:"dashboard"
       ~channel_user_id:""
       ~channel_user_name:""
       ~channel_workspace_id:""
       ~conversation_id:None
       ~external_message_id:None
       ~workspace_id:None
       ~extra_mentions:[]
       ~sender_keeper:None
       ~user_row_origin:Masc.Keeper_chat_store.Needs_append)
;;

let make_input msg =
  Payload.input_to_json
    ~message:msg
    ~user_blocks:[]
    ~turn_instructions:None
    ~surface_context:None
    ~attachments:[]
;;

let op_id s = get_text (Op.Operation_id.of_string s)

let accepted = function
  | Store.Accepted op -> op
  | Store.Existing _ -> Alcotest.fail "unexpected idempotent replay"
;;

let test_a2_2_person_turn_seams () =
  (* 1. Unpublished before Access.publish: resolve_turn_walk_owner treats
        person_caller=None as fleet and rejects explicit person_caller. *)
  (match
     Masc.Keeper_agent_run.resolve_turn_walk_owner
       ~keeper_name:"kp-any"
       ~turn_kind:Turn_record.Direct
       ~wake_reason:(Some Keeper_registry.Chat_request)
       ~person_caller:None
   with
   | Ok (Driver.Fleet_keeper_turn { keeper_name = "kp-any" }) -> ()
   | Ok _ -> Alcotest.fail "expected Fleet_keeper_turn when unpublished"
   | Error err ->
     Alcotest.failf "expected Ok before publish, got %s" (Agent_core.Error.to_string err));
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_context.with_test_env
        ~net:env#net
        ~clock:env#clock
        ~mono_clock:env#mono_clock
        ~sw
        (fun () ->
      let root = Filename.temp_dir "keeper-person-turn-seams-" "" in
      Fun.protect
        ~finally:(fun () -> remove_tree root)
        (fun () ->
          let base_path = Filename.concat root "base" in
          Unix.mkdir base_path 0o700;
          let store_path = Filename.concat (Filename.concat root "store") "external.jsonl" in
          let now_sec_ref = ref (Float.of_int start_ms /. 1000.) in
          let now_ms () = Int.of_float (!now_sec_ref *. 1000.) in
          (match
             B.fresh_bootstrap
               { B.base_path
               ; config_dir = Some (Filename.concat root "config")
               ; external_store = store_path
               ; workspace_id = workspace
               ; now_ms
               }
           with
           | Ok (_ : B.completed) -> ()
           | Error error -> Alcotest.fail (B.error_to_string error));
          let zone =
            match
              Z.open_at_start
                ~now_ms
                ~log_path:(Authz_log.path_of_base_path ~base_path)
                ~store_path
            with
            | Ok z -> z
            | Error e -> Alcotest.fail (Z.open_error_to_string e)
          in
          let alice = setup_person zone ~name:"alice" ~hex:'a' in
          let bob = setup_person zone ~name:"bob" ~hex:'b' in
          (match
             Access.publish
               (Access.Multi_account { zone; base_path; now = (fun () -> !now_sec_ref) })
           with
           | Ok (_ : Access.published) -> ()
           | Error e -> Alcotest.fail (Access.publish_error_to_string e));

          (* 2. PAT admission vs per-attempt recheck (RFC §6.4). *)
          let scope_full =
            { Authorization_scope.runtimes = Runtime_scope.all
            ; channels = Channel_scope.only (Channel.Set.singleton Channel.Direct)
            ; allowed_effects = Effect_scope.all
            }
          in
          let scope_alice_only =
            { Authorization_scope.runtimes =
                Runtime_scope.only (Runtime_id.Set.singleton alice.runtime_id)
            ; channels = Channel_scope.only (Channel.Set.singleton Channel.Direct)
            ; allowed_effects =
                Effect_scope.only
                  (Effect.Set.of_list Effect.[ Read_state; Invoke_model; Use_tool ])
            }
          in
          let scope_bob_only =
            { Authorization_scope.runtimes =
                Runtime_scope.only (Runtime_id.Set.singleton bob.runtime_id)
            ; channels = Channel_scope.only (Channel.Set.singleton Channel.Direct)
            ; allowed_effects = Effect_scope.all
            }
          in
          let pat_expiring =
            Pat_binding.Pat
              { Pat_scope.scope = scope_alice_only
              ; expires_at = Some (!now_sec_ref +. 60.0)
              }
          in
          let caller_alice =
            match
              Payload.admit_person_caller
                ~engine_name:alice.engine_name
                ~user_id:alice.user_id
                ~channel:Channel.Direct
                ~pat:pat_expiring
            with
            | Ok caller -> caller
            | Error e -> Alcotest.failf "admit alice failed: %s" (Access.refusal_to_string e)
          in
          Alcotest.(check bool)
            "stored_scope captures PAT scope"
            true
            (Authorization_scope.equal caller_alice.stored_scope scope_alice_only);
          let caller_alice_full =
            match
              Payload.admit_person_caller
                ~engine_name:alice.engine_name
                ~user_id:alice.user_id
                ~channel:Channel.Direct
                ~pat:(Pat_binding.Pat { scope = scope_full; expires_at = None })
            with
            | Ok caller -> caller
            | Error e -> Alcotest.fail (Access.refusal_to_string e)
          in
          let caller_bob =
            match
              Payload.admit_person_caller
                ~engine_name:bob.engine_name
                ~user_id:bob.user_id
                ~channel:Channel.Direct
                ~pat:(Pat_binding.Pat { scope = scope_bob_only; expires_at = None })
            with
            | Ok caller -> caller
            | Error e -> Alcotest.fail (Access.refusal_to_string e)
          in
          (* Wrong user cannot admit turn for alice's keeper and gets uniform
             No_operator_keeper (no cross-person existence oracle). *)
          let assert_no_operator_keeper label ~engine_name ~user_id =
            match
              Payload.admit_person_caller
                ~engine_name
                ~user_id
                ~channel:Channel.Direct
                ~pat:Pat_binding.Not_pat
            with
            | Error (Access.No_operator_keeper name) when String.equal name engine_name -> ()
            | Error other ->
              Alcotest.failf
                "%s: expected No_operator_keeper %S, got %s"
                label
                engine_name
                (Access.refusal_to_string other)
            | Ok _ -> Alcotest.fail (label ^ ": must not be admitted")
          in
          assert_no_operator_keeper
            "wrong owner invoking alice keeper"
            ~engine_name:alice.engine_name
            ~user_id:bob.user_id;
          assert_no_operator_keeper
            "nonexistent engine name"
            ~engine_name:"kp-nonexistent"
            ~user_id:bob.user_id;
          (* Even when both Alice and Bob own a Keeper sharing the same Keeper_id,
             Bob invoking Alice's engine_name fails uniformly at admission. *)
          let shared_keeper_id = get (Keeper_id.of_string "shared-main") in
          let shared_scope =
            { Authorization_scope.runtimes = Runtime_scope.all
            ; channels = Channel_scope.only (Channel.Set.of_list Channel.[ Autonomous; Direct ])
            ; allowed_effects = Effect_scope.all
            }
          in
          let setup_shared who suffix =
            let engine_name = "kp-" ^ suffix ^ "-shared" in
            (match
               Authz_keeper.make
                 zone
                 ~user_id:who.user_id
                 ~keeper_id:shared_keeper_id
                 ~turn_scope:shared_scope
                 ~draw:(fun () -> "policy-shared-" ^ suffix)
                 ~draw_engine_name:(fun () -> engine_name)
             with
             | Ok () -> ()
             | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
            (match Authz_keeper.assign zone ~user_id:who.user_id ~keeper_id:shared_keeper_id ~runtime_id:who.runtime_id with
             | Ok () -> ()
             | Error error -> Alcotest.fail (Authz_keeper.error_detail error));
            engine_name
          in
          let alice_shared_engine = setup_shared alice "alice" in
          let bob_shared_engine = setup_shared bob "bob" in
          assert_no_operator_keeper
            "cross-owner shared keeper_id blocked without oracle"
            ~engine_name:alice_shared_engine
            ~user_id:bob.user_id;
          (match
             Payload.admit_person_caller
               ~engine_name:bob_shared_engine
               ~user_id:bob.user_id
               ~channel:Channel.Direct
               ~pat:Pat_binding.Not_pat
           with
           | Ok _ -> ()
           | Error other ->
             Alcotest.failf
               "owner should still admit own shared-keeper_id keeper, got %s"
               (Access.refusal_to_string other));
          (* PAT limited to Autonomous channel is refused at Direct admit. *)
          (match
             Payload.admit_person_caller
               ~engine_name:alice.engine_name
               ~user_id:alice.user_id
               ~channel:Channel.Direct
               ~pat:
                 (Pat_binding.Pat
                    { scope =
                        { scope_full with
                          channels = Channel_scope.only (Channel.Set.singleton Channel.Autonomous)
                        }
                    ; expires_at = None
                    })
           with
           | Error (Access.Turn_refused (Authz_keeper_turn.Denied Authz_decision.Channel_out_of_scope)) ->
             ()
           | Error other ->
             Alcotest.failf "unexpected channel admit error: %s" (Access.refusal_to_string other)
           | Ok _ -> Alcotest.fail "Autonomous-only PAT must not admit Direct");

          (* 3. source.v3 encoding/decoding & strict source.v2 hard-cut. *)
          let src_with_caller = make_dashboard_source ~person_caller:(Some caller_alice) () in
          (match Payload.source_of_json src_with_caller with
           | Error e -> Alcotest.failf "source.v3 with caller failed to decode: %s" e
           | Ok decoded ->
             Alcotest.(check bool)
               "source.v3 person_caller round-trips"
               true
               (Payload.equal_person_caller (Some caller_alice) decoded.person_caller));
          let src_operator = make_dashboard_source ~person_caller:None () in
          (match Payload.source_of_json src_operator with
           | Error e -> Alcotest.failf "source.v3 operator failed to decode: %s" e
           | Ok decoded ->
             Alcotest.(check bool)
               "source.v3 None person_caller round-trips"
               true
               (Option.is_none decoded.person_caller));
          let bad_v2 =
            match src_operator with
            | `Assoc fields ->
              `Assoc
                (fields
                 |> List.filter (fun (k, _) -> k <> "person_caller")
                 |> List.map (fun (k, v) ->
                   if k = "schema"
                   then k, `String "masc.keeper_chat_operation.source.v2"
                   else k, v))
            | _ -> Alcotest.fail "expected JSON object"
          in
          (match Payload.source_of_json bad_v2 with
           | Error _ -> ()
           | Ok _ -> Alcotest.fail "source.v2 must fail hard cut");
          let missing_caller_v3 =
            match src_operator with
            | `Assoc fields ->
              `Assoc (List.filter (fun (k, _) -> k <> "person_caller") fields)
            | _ -> Alcotest.fail "expected JSON object"
          in
          (match Payload.source_of_json missing_caller_v3 with
           | Error _ -> ()
           | Ok _ -> Alcotest.fail "source.v3 missing person_caller must fail");
          (match
             Payload.source_to_json_with_person_caller
               ~person_caller:(Some caller_alice)
               ~submitted_by:"user"
               ~thread_id:"thread-1"
               ~continuation_channel:(get_text (Channel_k.dashboard ~thread_id:"thread-1"))
               ~surface:(Masc.Surface_ref.Dashboard { session_id = None })
               ~channel:"dashboard"
               ~channel_user_id:""
               ~channel_user_name:""
               ~channel_workspace_id:""
               ~conversation_id:None
               ~external_message_id:None
               ~workspace_id:None
               ~extra_mentions:[]
               ~sender_keeper:(Masc.Keeper_identity.Keeper_id.of_string "other-keeper")
               ~user_row_origin:Masc.Keeper_chat_store.Needs_append
           with
           | Error _ -> ()
           | Ok _ -> Alcotest.fail "mixing person_caller and sender_keeper must fail");

          (* 4. Keeper_chat_operation_batch non-coalescing across callers and stored_scopes. *)
          let db_path = Filename.concat root "ops.sqlite3" in
          let op_store = get_text (Store.open_or_create ~path:db_path |> Result.map_error Store.error_to_string) in
          Fun.protect
            ~finally:(fun () -> ignore (Store.close op_store : (unit, Store.error) result))
            (fun () ->
              let submit id_str source msg =
                accepted
                  (get_text
                     (Store.submit
                        op_store
                        ~now:1.0
                        ~operation_id:(op_id id_str)
                        ~source
                        ~input:(make_input msg)
                      |> Result.map_error Store.error_to_string))
              in
              ignore (submit "op-alice-narrow" src_with_caller "m1");
              ignore (submit "op-alice-full" (make_dashboard_source ~person_caller:(Some caller_alice_full) ()) "m3");
              ignore (submit "op-operator" src_operator "m2");
              ignore (submit "op-bob-1" (make_dashboard_source ~person_caller:(Some caller_bob) ()) "m4");
              ignore (submit "op-bob-2" (make_dashboard_source ~person_caller:(Some caller_bob) ()) "m5");
              let claim_batch label =
                let head =
                  match
                    get_text (Store.claim_next ~batch:Batch.select op_store ~now:2.0 |> Result.map_error Store.error_to_string)
                  with
                  | Some op -> op
                  | None -> Alcotest.fail ("expected operation for " ^ label)
                in
                let members =
                  get_text
                    (Store.batch_operations op_store ~operation_id:head.operation_id
                     |> Result.map_error Store.error_to_string)
                in
                ignore
                  (get_text
                     (Store.succeed_running
                        op_store
                        ~now:2.5
                        ~operation_id:head.operation_id
                        ~outcome_ref:("done-" ^ label)
                      |> Result.map_error Store.error_to_string));
                List.map (fun (m : Op.t) -> Op.Operation_id.to_string m.operation_id) members
              in
              Alcotest.(check (list string))
                "alice narrow does not coalesce with alice full (different stored_scope)"
                [ "op-alice-narrow" ]
                (claim_batch "alice-narrow");
              Alcotest.(check (list string))
                "alice full does not coalesce with operator"
                [ "op-alice-full" ]
                (claim_batch "alice-full");
              Alcotest.(check (list string))
                "operator does not coalesce with bob"
                [ "op-operator" ]
                (claim_batch "operator");
              Alcotest.(check (list string))
                "bob operations with matching caller and stored_scope coalesce"
                [ "op-bob-1"; "op-bob-2" ]
                (claim_batch "bob-pair"));

          (* Advance clock past pat_expiring's deadline: admit now fails, but
             already-admitted caller_alice still passes resolve_turn_walk_owner and
             authorizes via Not_pat + stored_scope! *)
          now_sec_ref := !now_sec_ref +. 300.0;
          (match
             Payload.admit_person_caller
               ~engine_name:alice.engine_name
               ~user_id:alice.user_id
               ~channel:Channel.Direct
               ~pat:pat_expiring
           with
           | Error (Access.Turn_refused (Authz_keeper_turn.Denied Authz_decision.Pat_expired)) -> ()
           | Error other ->
             Alcotest.failf "expected Pat_expired on late admit, got %s" (Access.refusal_to_string other)
           | Ok _ -> Alcotest.fail "expired PAT must be rejected at admit");

          (* 5. Exhaustive channel & caller routing via resolve_turn_walk_owner. *)
          let check_walk label ~keeper_name ~turn_kind ~wake_reason ~person_caller check_fn =
            check_fn
              label
              (Masc.Keeper_agent_run.resolve_turn_walk_owner
                 ~keeper_name
                 ~turn_kind
                 ~wake_reason
                 ~person_caller)
          in
          let expect_person ~channel ~owner label = function
            | Ok (Driver.Person_keeper_turn turn) ->
              Alcotest.(check bool)
                (label ^ ": channel")
                true
                (Channel.equal channel turn.channel);
              Alcotest.(check bool)
                (label ^ ": owner")
                true
                (User_id.equal owner turn.owner);
              Alcotest.(check bool)
                (label ^ ": attempt uses Not_pat")
                true
                (turn.pat = Pat_binding.Not_pat)
            | Ok _ -> Alcotest.fail (label ^ ": expected Person_keeper_turn")
            | Error e -> Alcotest.failf "%s: unexpected error %s" label (Agent_core.Error.to_string e)
          in
          let expect_refused label = function
            | Error _ -> ()
            | Ok _ -> Alcotest.fail (label ^ ": expected refusal")
          in
          check_walk
            "direct with owner caller (Chat_request)"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Direct
            ~wake_reason:(Some Keeper_registry.Chat_request)
            ~person_caller:(Some caller_alice)
            (expect_person ~channel:Channel.Direct ~owner:alice.user_id);
          check_walk
            "direct with owner caller (None wake)"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Direct
            ~wake_reason:None
            ~person_caller:(Some caller_alice)
            (expect_person ~channel:Channel.Direct ~owner:alice.user_id);
          check_walk
            "direct with mismatched caller refused"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Direct
            ~wake_reason:(Some Keeper_registry.Chat_request)
            ~person_caller:(Some caller_bob)
            expect_refused;
          check_walk
            "direct without person_caller refused"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Direct
            ~wake_reason:(Some Keeper_registry.Chat_request)
            ~person_caller:None
            expect_refused;
          check_walk
            "direct with Proactive_tick refused"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Direct
            ~wake_reason:(Some Keeper_registry.Proactive_tick)
            ~person_caller:(Some caller_alice)
            expect_refused;
          check_walk
            "direct for operator keeper refused"
            ~keeper_name:"kp-operator"
            ~turn_kind:Turn_record.Direct
            ~wake_reason:(Some Keeper_registry.Chat_request)
            ~person_caller:(Some caller_alice)
            expect_refused;
          check_walk
            "autonomous Proactive_tick allowed"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Autonomous
            ~wake_reason:(Some Keeper_registry.Proactive_tick)
            ~person_caller:None
            (expect_person ~channel:Channel.Autonomous ~owner:alice.user_id);
          check_walk
            "autonomous Woken [Bootstrap] allowed"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Autonomous
            ~wake_reason:(Some (Keeper_registry.Woken [ Eq.Bootstrap ]))
            ~person_caller:None
            (expect_person ~channel:Channel.Autonomous ~owner:alice.user_id);
          check_walk
            "autonomous Woken [] refused fail-closed"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Autonomous
            ~wake_reason:(Some (Keeper_registry.Woken []))
            ~person_caller:None
            expect_refused;
          check_walk
            "autonomous Woken [Schedule_due] refused"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Autonomous
            ~wake_reason:
              (Some
                 (Keeper_registry.Woken
                    [ Eq.Schedule_due
                        { occurrence_id = "occ-1"
                        ; schedule_instance_id = "inst-1"
                        ; schedule_id = "sched-1"
                        ; due_at = 1.0
                        ; payload_digest = "digest"
                        ; title = None
                        ; message = "tick"
                        ; result_delivery = None
                        }
                    ]))
            ~person_caller:None
            expect_refused;
          check_walk
            "autonomous None wake refused"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Autonomous
            ~wake_reason:None
            ~person_caller:None
            expect_refused;
          check_walk
            "autonomous Chat_request refused"
            ~keeper_name:alice.engine_name
            ~turn_kind:Turn_record.Autonomous
            ~wake_reason:(Some Keeper_registry.Chat_request)
            ~person_caller:None
            expect_refused;

          (* Verify already-admitted caller_alice still authorizes against
             a captured Claude home after PAT expiry (Not_pat + stored_scope). *)
          let operator_home = Filename.concat root "operator-home" in
          Unix.mkdir operator_home 0o700;
          let cli_marker = Filename.concat root "cli-ran.marker" in
          let cli_script = Filename.concat root "fake-claude.sh" in
          write_fail_marker_script cli_script ~marker:cli_marker;
          let toml_path = Filename.concat root "runtime.toml" in
          write_runtime_toml toml_path ~cli_script ~operator_home;
          let rt_snapshot = Runtime.For_testing.snapshot () in
          Fun.protect
            ~finally:(fun () -> Runtime.For_testing.restore rt_snapshot)
            (fun () ->
              get_text (Runtime.init_default_strict ~config_path:toml_path);
              ignore (Runtime.get_runtime_by_id (Runtime_id.to_string alice.runtime_id));
              let alice_home =
                get_text
                  (Runtime_account_home_layout.home
                     ~runtime_root:
                       (Runtime_account_home_layout.person_runtime_root
                          ~base_path
                          ~namespace:alice.namespace)
                     Runtime_account_home_layout.Claude_home
                     ~account_id:(Provider_account_id.to_string alice.account))
              in
              let captured_alice =
                get_text (Account.capture ~client:Account.Claude_code ~declaration:(Some alice_home))
              in
              (match
                 Access.authorize
                   (Access.Keeper_turn
                      { owner = alice.user_id
                      ; keeper_id = alice.keeper_id
                      ; runtime_id = Runtime_id.to_string alice.runtime_id
                      ; channel = Channel.Direct
                      ; stored_scope = caller_alice.stored_scope
                      ; pat = Pat_binding.Not_pat
                      })
                   (Access.seal captured_alice)
               with
               | Ok _ -> ()
               | Error e ->
                 Alcotest.failf
                   "admitted turn should remain authorized after PAT expiry: %s"
                   (Access.refusal_to_string e));

              (* 6. Runtime_account_call.call_in_turn_of acquired BEFORE authorize_account:
                    holding Alice's call slot prevents Fiber 2 from reaching authorize_account;
                    purging Alice's account while Fiber 2 waits in the call queue causes
                    post-wait authorize_account to refuse before launching CLI. *)
              let alice_walk =
                Driver.Person_keeper_turn
                  { owner = alice.user_id
                  ; keeper_id = alice.keeper_id
                  ; engine_name = alice.engine_name
                  ; channel = Channel.Direct
                  ; stored_scope = caller_alice.stored_scope
                  ; pat = Pat_binding.Not_pat
                  }
              in
              let slot_held_p, slot_held_u = Eio.Promise.create () in
              let release_slot_p, release_slot_u = Eio.Promise.create () in
              let attempt_done = ref false in
              let attempt_result = ref None in
              Eio.Fiber.both
                (fun () ->
                  Runtime_account_call.call_in_turn_of alice.account (fun _call ->
                    Eio.Promise.resolve slot_held_u ();
                    Eio.Promise.await release_slot_p))
                (fun () ->
                  Eio.Promise.await slot_held_p;
                  Eio.Fiber.both
                    (fun () ->
                      let res =
                        Driver.run_named
                          ~input_source:
                            (Masc.Keeper_request_source.Keeper_history { trace_id = "trace-order" })
                          ~raw_trace:None
                          ~walk_owner:alice_walk
                          ~runtime_id:(Runtime_id.to_string alice.runtime_id)
                          ~base_path
                          ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
                          ~goal:"test"
                          ~system_prompt:"sys"
                          ~agent_core_tools:[]
                          ()
                      in
                      attempt_result := Some res;
                      attempt_done := true)
                    (fun () ->
                      for _ = 1 to 10 do
                        Eio.Fiber.yield ()
                      done;
                      Alcotest.(check bool)
                        "turn blocked in call slot before authorize_account"
                        false
                        !attempt_done;
                      (match
                         Authz_purge.start
                           zone
                           ~user_id:alice.user_id
                           (Authz_purge_event.Provider_account
                              { owner = alice.user_id
                              ; provider_account_id = alice.account
                              })
                       with
                       | Ok () -> ()
                       | Error e -> Alcotest.fail (Authz_purge.error_detail e));
                      Eio.Promise.resolve release_slot_u ()));
              (match !attempt_result with
               | Some (Error _) -> ()
               | Some (Ok _) -> Alcotest.fail "post-purge turn must be refused"
               | None -> Alcotest.fail "expected attempt result after call slot release");
              Alcotest.(check bool)
                "CLI never spawned when post-wait authorize refused"
                false
                (Sys.file_exists cli_marker);

              (* 7. Eio.Cancel.Cancelled propagates cleanly while queued on call slot. *)
              let bob_walk =
                Driver.Person_keeper_turn
                  { owner = bob.user_id
                  ; keeper_id = bob.keeper_id
                  ; engine_name = bob.engine_name
                  ; channel = Channel.Direct
                  ; stored_scope = caller_bob.stored_scope
                  ; pat = Pat_binding.Not_pat
                  }
              in
              let bob_held_p, bob_held_u = Eio.Promise.create () in
              let bob_release_p, bob_release_u = Eio.Promise.create () in
              let cancelled = ref false in
              let failed_cb = ref 0 in
              Eio.Fiber.both
                (fun () ->
                  Runtime_account_call.call_in_turn_of bob.account (fun _call ->
                    Eio.Promise.resolve bob_held_u ();
                    Eio.Promise.await bob_release_p))
                (fun () ->
                  Eio.Promise.await bob_held_p;
                  Eio.Fiber.first
                    (fun () ->
                      try
                        ignore
                          (Driver.run_named
                             ~input_source:
                               (Masc.Keeper_request_source.Keeper_history { trace_id = "trace-cancel" })
                             ~raw_trace:None
                             ~walk_owner:bob_walk
                             ~runtime_id:(Runtime_id.to_string bob.runtime_id)
                             ~base_path
                             ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
                             ~goal:"test"
                             ~system_prompt:"sys"
                             ~agent_core_tools:[]
                             ~on_runtime_attempt_error:(fun ~runtime_id:_ ~attempt:_ ~dispatch:_ _err ->
                               incr failed_cb)
                             ());
                        Alcotest.fail "cancelled queued turn must not return normally"
                      with
                      | Eio.Cancel.Cancelled _ as exn ->
                        cancelled := true;
                        raise exn)
                    (fun () ->
                      for _ = 1 to 10 do
                        Eio.Fiber.yield ()
                      done);
                  Eio.Promise.resolve bob_release_u ());
              Alcotest.(check bool) "Eio.Cancel.Cancelled propagated" true !cancelled;
              Alcotest.(check int) "no attempt failure recorded on cancel" 0 !failed_cb;
              Alcotest.(check bool) "CLI never spawned on cancel" false (Sys.file_exists cli_marker);
              Alcotest.(check string)
                "account call slot remains reusable after cancellation"
                "reusable"
                (Runtime_account_call.call_in_turn_of bob.account (fun _ -> "reusable"));

              (* 8. P1 (A2-3): Agent_core Person_api HTTP 401 -> Key_refused (keeping 403 as Not_signed_in)
                    and candidate_access_should_try_next lane rotation. *)
              let module Krf = Keeper_request_failure in
              let read_one_request flow =
                let reader = Eio.Buf_read.of_flow ~max_size:65536 flow in
                let rec headers content_length =
                  match Eio.Buf_read.line reader with
                  | "" | "\r" -> content_length
                  | line ->
                    (match String.index_opt line ':' with
                     | Some colon
                       when String.equal
                              (String.lowercase_ascii (String.trim (String.sub line 0 colon)))
                              "content-length" ->
                       let next_len =
                         String.sub line (colon + 1) (String.length line - colon - 1)
                         |> String.trim
                         |> int_of_string_opt
                         |> Option.value ~default:content_length
                       in
                       headers next_len
                     | Some _ | None -> headers content_length)
                in
                let content_length = headers 0 in
                ignore (Eio.Buf_read.take content_length reader : string)
              in
              let start_http_status ~status_line ~body =
                let listening =
                  Eio.Net.listen
                    ~sw
                    ~backlog:8
                    ~reuse_addr:true
                    env#net
                    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
                in
                let hits = Atomic.make 0 in
                Eio.Fiber.fork_daemon ~sw (fun () ->
                  while true do
                    Eio.Net.accept_fork
                      ~sw
                      listening
                      ~on_error:(fun _ -> ())
                      (fun flow _addr ->
                        try
                          read_one_request flow;
                          ignore (Atomic.fetch_and_add hits 1 : int);
                          let response =
                            Printf.sprintf
                              "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                              status_line
                              (String.length body)
                              body
                          in
                          Eio.Flow.copy_string response flow;
                          (try Eio.Flow.shutdown flow `Send with
                           | Eio.Io _ | Unix.Unix_error _ -> ())
                        with
                        | End_of_file | Eio.Io _ -> ())
                  done);
                let port =
                  match Eio.Net.listening_addr listening with
                  | `Tcp (_, port) -> port
                  | `Unix _ -> Alcotest.fail "expected TCP listening addr"
                in
                port, hits
              in
              let port_401, hits_401 =
                start_http_status
                  ~status_line:"401 Unauthorized"
                  ~body:
                    {|{"error":{"message":"invalid x-api-key reading /Users/alice/.masc/key","type":"authentication_error"}}|}
              in
              let port_403, hits_403 =
                start_http_status
                  ~status_line:"403 Forbidden"
                  ~body:
                    {|{"error":{"message":"account forbidden","type":"permission_error"}}|}
              in
              let alice_runtime_root =
                Runtime_account_home_layout.person_runtime_root
                  ~base_path
                  ~namespace:alice.namespace
              in
              let setup_http_key_keeper ~acct_name ~integration_name ~keeper_name_str ~engine_name =
                let acct = get (Provider_account_id.of_string acct_name) in
                let integ = get (Integration_id.of_string integration_name) in
                (match
                   Authz_provider_account.link_key
                     zone
                     ~user_id:alice.user_id
                     ~provider_account_id:acct
                     ~integration_id:integ
                 with
                 | Ok () -> ()
                 | Error e -> Alcotest.fail (Authz_provider_account.error_to_string e));
                let key =
                  match Runtime_api_key_file.key_of_string ("sk-person-" ^ acct_name) with
                  | Some k -> k
                  | None -> Alcotest.fail "fixture person key refused"
                in
                (match
                   Runtime_api_key_file.write
                     ~runtime_root:alice_runtime_root
                     ~account_id:acct
                     ~generation:Key_generation.first
                     key
                 with
                 | Ok () -> ()
                 | Error _ -> Alcotest.fail "fixture person key write failed");
                let rt_id = get (Runtime_id.of_string (acct_name ^ ".first")) in
                (match
                   Authz_runtime.make
                     zone
                     ~user_id:alice.user_id
                     ~provider_account_id:acct
                     ~runtime_id:rt_id
                     ~self_effects:Effect.(Set.of_list [ Read_state; Invoke_model; Use_tool ])
                     ~draw:(fun () -> "grant-" ^ acct_name)
                 with
                 | Ok (_ : Grant_id.t) -> ()
                 | Error e -> Alcotest.fail (Authz_runtime.error_detail e));
                let kp_id = get (Keeper_id.of_string keeper_name_str) in
                (match
                   Authz_keeper.make
                     zone
                     ~user_id:alice.user_id
                     ~keeper_id:kp_id
                     ~turn_scope:shared_scope
                     ~draw:(fun () -> "policy-" ^ acct_name)
                     ~draw_engine_name:(fun () -> engine_name)
                 with
                 | Ok () -> ()
                 | Error e -> Alcotest.fail (Authz_keeper.error_detail e));
                (match Authz_keeper.assign zone ~user_id:alice.user_id ~keeper_id:kp_id ~runtime_id:rt_id with
                 | Ok () -> ()
                 | Error e -> Alcotest.fail (Authz_keeper.error_detail e));
                kp_id, rt_id
              in
              let kp_401, rt_401 =
                setup_http_key_keeper
                  ~acct_name:"acct-http-401"
                  ~integration_name:"http_401"
                  ~keeper_name_str:"keeper-http-401"
                  ~engine_name:"kp-http-401"
              in
              let kp_403, rt_403 =
                setup_http_key_keeper
                  ~acct_name:"acct-http-403"
                  ~integration_name:"http_403"
                  ~keeper_name_str:"keeper-http-403"
                  ~engine_name:"kp-http-403"
              in
              let http_toml_path = Filename.concat root "runtime-http.toml" in
              let http_toml =
                Printf.sprintf
                  {|
[runtime]
default = "operator.first"

[providers.operator]
display-name = "Operator"
protocol = "claude-code"
command = %S
account-home = %S
is-non-interactive = true

[providers.http_401]
display-name = "HTTP 401"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d/v1"

[providers.http_401.credentials]
type = "inline"
value = "op-unused"

[providers.http_403]
display-name = "HTTP 403"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d/v1"

[providers.http_403.credentials]
type = "inline"
value = "op-unused"

[models.first]
api-name = "first-model"
max-context = 16384
tools-support = true
streaming = true

[operator.first]
[http_401.first]
[http_403.first]
|}
                  cli_script
                  operator_home
                  port_401
                  port_403
              in
              Out_channel.with_open_bin http_toml_path (fun ch -> Out_channel.output_string ch http_toml);
              get_text (Runtime.init_default ~config_path:http_toml_path);
              let run_http_keeper ~keeper_id ~engine_name ~runtime_id ~trace_id =
                let walk =
                  Driver.Person_keeper_turn
                    { owner = alice.user_id
                    ; keeper_id
                    ; engine_name
                    ; channel = Channel.Direct
                    ; stored_scope = shared_scope
                    ; pat = Pat_binding.Not_pat
                    }
                in
                Driver.run_named
                  ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id })
                  ~raw_trace:None
                  ~keeper_name:engine_name
                  ~walk_owner:walk
                  ~runtime_id:(Runtime_id.to_string runtime_id)
                  ~base_path
                  ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
                  ~goal:"ping"
                  ~system_prompt:"sys"
                  ~agent_core_tools:[]
                  ()
              in
              let err_401 =
                match
                  run_http_keeper
                    ~keeper_id:kp_401
                    ~engine_name:"kp-http-401"
                    ~runtime_id:rt_401
                    ~trace_id:"trace-http-401"
                with
                | Ok _ -> Alcotest.fail "HTTP 401 Person_api turn must fail"
                | Error err -> err
              in
              if Atomic.get hits_401 < 1
              then
                Alcotest.failf
                  "HTTP 401 endpoint was not contacted (err=%s)"
                  (Agent_core.Error.to_string err_401);
              let failure_401 = Krf.of_core_error err_401 in
              Alcotest.(check string)
                "Agent_core Person_api 401 -> Key_refused"
                "key_refused"
                (Krf.Failure_kind.to_wire (Krf.failure_kind failure_401));
              Alcotest.(check bool)
                "lane_should_retry rotates past Person_api Key_refused"
                true
                (Driver.For_testing.lane_should_retry
                   ~is_last:false
                   ~allow_retry:true
                   ~allow_accept_no_progress_retry:true
                   err_401);
              let err_403 =
                match
                  run_http_keeper
                    ~keeper_id:kp_403
                    ~engine_name:"kp-http-403"
                    ~runtime_id:rt_403
                    ~trace_id:"trace-http-403"
                with
                | Ok _ -> Alcotest.fail "HTTP 403 Person_api turn must fail"
                | Error err -> err
              in
              if Atomic.get hits_403 < 1
              then
                Alcotest.failf
                  "HTTP 403 endpoint was not contacted (err=%s)"
                  (Agent_core.Error.to_string err_403);
              let failure_403 = Krf.of_core_error err_403 in
              Alcotest.(check string)
                "Agent_core Person_api 403 stays Not_signed_in"
                "not_signed_in"
                (Krf.Failure_kind.to_wire (Krf.failure_kind failure_403));
              let person_cfg_stub =
                Llm_provider.Provider_config.make
                  ~kind:Llm_provider.Provider_config.OpenAI_compat
                  ~model_id:"first-model"
                  ~base_url:(Printf.sprintf "http://127.0.0.1:%d/v1" port_401)
                  ~api_key:"unused"
                  ()
              in
              let person_sealed_stub =
                Access.seal_person_api
                  ~provider_account_id:(get (Provider_account_id.of_string "acct-http-401"))
                  person_cfg_stub
              in
              let tried_candidates = ref [] in
              let rotated_res =
                Driver.For_testing.attempt_runtime_candidates
                  ~walk_owner:
                    (Driver.Person_keeper_turn
                       { owner = alice.user_id
                       ; keeper_id = kp_401
                       ; engine_name = "kp-http-401"
                       ; channel = Channel.Direct
                       ; stored_scope = shared_scope
                       ; pat = Pat_binding.Not_pat
                       })
                  ~runtime_id:"lane-http"
                  ~runtime_id_of:(fun id -> id)
                  ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
                  ~run_attempt:(fun ~idx:_ ~runtime_id _ ->
                    tried_candidates := runtime_id :: !tried_candidates;
                    if String.equal runtime_id "cand-401"
                    then
                      ( Driver.For_testing.translate_person_api_result
                          ~sealed:person_sealed_stub
                          ~provider:"http_401"
                          (Error
                             (Agent_core.Error.Api
                                (Llm_provider.Retry.AuthError { message = "401 bad key" })))
                      , None
                      , Masc.Keeper_provider_attempt_effect.No_effect_observed
                      , Masc.Keeper_attempt_dispatch.Dispatched )
                    else
                      ( Ok "cand-2-ok"
                      , None
                      , Masc.Keeper_provider_attempt_effect.No_effect_observed
                      , Masc.Keeper_attempt_dispatch.Dispatched ))
                  [ "cand-401"; "cand-2" ]
              in
              (match rotated_res with
               | Ok "cand-2-ok" -> ()
               | Ok other -> Alcotest.failf "expected cand-2-ok, got %s" other
               | Error e ->
                 Alcotest.failf
                   "expected rotation past Key_refused to cand-2, got %s"
                   (Agent_core.Error.to_string e));
              Alcotest.(check (list string))
                "both candidates attempted in order"
                [ "cand-401"; "cand-2" ]
                (List.rev !tried_candidates);

              (* 7. Multi-account admission, keeper_up guards, and Librarian guards (A3-1). *)
              (match Access.engine_keeper_admission alice.engine_name with
               | Access.Active_person_keeper { owner; keeper_id; runtime_assigned } ->
                 Alcotest.(check bool) "alice owner matches" true
                   (User_id.equal owner alice.user_id);
                 Alcotest.(check bool) "alice keeper_id matches" true
                   (Keeper_id.equal keeper_id alice.keeper_id);
                 Alcotest.(check bool) "alice runtime matches" true
                   (runtime_assigned = Some alice.runtime_id)
               | _ -> Alcotest.fail "expected Active_person_keeper for alice");
              Alcotest.(check bool)
                "unregistered keeper yields Unknown_person_keeper"
                true
                (Access.engine_keeper_admission "unregistered-keeper" = Access.Unknown_person_keeper);
              let active_names = Access.active_authz_keeper_names () in
              Alcotest.(check bool) "active_authz_keeper_names includes alice" true
                (List.mem alice.engine_name active_names);
              Alcotest.(check bool) "active_authz_keeper_names includes bob" true
                (List.mem bob.engine_name active_names);
              let cfg = Masc.Workspace.default_config base_path in
              Unix.putenv "MASC_CONFIG_DIR" "";
              let keepers_dir =
                Filename.concat
                  (Filename.concat (Filename.concat base_path ".masc") "config")
                  "keepers"
              in
              Fs_compat.mkdir_p keepers_dir;
              let write_keeper_toml engine_name =
                Out_channel.with_open_bin
                  (Filename.concat keepers_dir (engine_name ^ ".toml"))
                  (fun ch -> Out_channel.output_string ch "[keeper]\ninstructions = \"fixture\"\n")
              in
              write_keeper_toml alice.engine_name;
              write_keeper_toml bob.engine_name;
              let ctx : _ Masc.Keeper_types_profile.context =
                { config = cfg
                ; agent_name = "tester"
                ; sw
                ; clock = env#clock
                ; proc_mgr = None
                ; net = None
                ; publication_recovery_provider =
                    Masc.Keeper_publication_recovery_availability.non_runtime_provider
                }
              in
              List.iter
                (fun (label, json) ->
                   match Masc.Keeper_turn_up_args.parse ctx json with
                   | Error _ -> ()
                   | Ok _ -> Alcotest.failf "%s should be refused in Multi_account" label)
                [ "unregistered keeper", `Assoc [ "name", `String "unregistered-keeper" ]
                ; ( "tools.masc_enabled = true on person keeper"
                  , `Assoc
                      [ "name", `String alice.engine_name
                      ; "tools", `Assoc [ "masc_enabled", `Bool true ]
                      ] )
                ; ( "tools.native = read on person keeper"
                  , `Assoc
                      [ "name", `String alice.engine_name
                      ; "tools", `Assoc [ "native", `String "read" ]
                      ] )
                ];
              Alcotest.(check bool)
                "Librarian submit_durable returns Dropped in Multi_account"
                true
                (Masc.Keeper_librarian_queue_refresh.submit_durable
                   ~base_path
                   ~keeper_name:alice.engine_name
                 = Masc.Keeper_memory_lane.Dropped);
              Alcotest.(check (list string))
                "Librarian submit_durable_for_unlaunched returns empty in Multi_account"
                []
                (Masc.Keeper_librarian_queue_refresh.submit_durable_for_unlaunched
                   ~base_path
                   ~persisted:[ alice.engine_name ]
                   ~launched:[]);
              Alcotest.(check bool)
                "Keeper_memory_cleanup.run returns Disabled in Multi_account"
                true
                (Masc.Keeper_memory_cleanup.run ~base_path ~keeper_name:alice.engine_name
                 = Masc.Keeper_memory_cleanup.Disabled);
              Alcotest.(check bool)
                "autoboot_exclusion_reason excludes unregistered keeper in Multi_account"
                true
                (Masc.Keeper_runtime.autoboot_exclusion_reason cfg "unregistered-keeper"
                 = Some Masc.Keeper_runtime.Autoboot_disabled);
              (* Disable bob and verify owner-disabled exclusion across admission/keeper_up/boot *)
              commit
                zone
                ~author:(Authz_records.Author.Authenticated (Principal.Human alice.user_id))
                ~kind:Authz_record.Kind.Principal
                (get
                   (Authz_principal_event.to_body
                      (Authz_principal_event.Disabled { user_id = bob.user_id })));
              (match Access.engine_keeper_admission bob.engine_name with
               | Access.Owner_disabled { owner; keeper_id } ->
                 Alcotest.(check bool) "disabled owner matches bob" true
                   (User_id.equal owner bob.user_id);
                 Alcotest.(check bool) "disabled keeper matches bob" true
                   (Keeper_id.equal keeper_id bob.keeper_id)
               | _ -> Alcotest.fail "expected Owner_disabled after disabling bob");
              Alcotest.(check bool)
                "active_authz_keeper_names drops disabled bob"
                false
                (List.mem bob.engine_name (Access.active_authz_keeper_names ()));
              Alcotest.(check bool)
                "autoboot_exclusion_reason excludes disabled-owner keeper"
                true
                (Masc.Keeper_runtime.autoboot_exclusion_reason cfg bob.engine_name
                 = Some Masc.Keeper_runtime.Autoboot_disabled);
              Alcotest.(check bool)
                "keepalive_keeper_names excludes disabled-owner keeper"
                false
                (List.mem bob.engine_name (Masc.Keeper_meta_store.keepalive_keeper_names cfg));
              (match
                 Masc.Keeper_turn_up_args.parse ctx (`Assoc [ "name", `String bob.engine_name ])
               with
               | Error _ -> ()
               | Ok _ -> Alcotest.fail "keeper_up should refuse disabled-owner keeper"))))))
;;

let () =
  Alcotest.run
    "keeper_person_turn_seams"
    [ ( "seams"
      , [ Alcotest.test_case "person turn seams" `Quick test_a2_2_person_turn_seams ] )
    ]
