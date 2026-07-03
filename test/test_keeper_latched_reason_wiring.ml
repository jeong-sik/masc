(** task-1664 (audit Wave F1): pin that the three bool-only pause sites
    record a typed [Keeper_latched_reason.t] in keeper_meta, that the
    reason survives serialization and the operator-pause merge, and that
    the status bridge surfaces it.

    Sites under test:
    - gRPC pause directive ([Keeper_keepalive.process_directive "pause"]
      -> [directive_paused_meta]) -> [Operator_paused {grpc_directive}]
    - keeper_down retain ([Keeper_turn_lifecycle.handle_keeper_down_config],
      remove_meta=false) -> [Operator_paused {keeper_down}]
    - dead-tombstone cleanup
      ([Keeper_supervisor_cleanup_tombstone.cleanup_dead_tombstone])
      -> [Dead_tombstone]

    Observability only: these tests assert the {i reason} annotation, not
    any change to the pause/resume decision (which stays carried by
    [meta.paused]). *)

open Alcotest
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_json = Masc.Keeper_meta_json
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_meta_merge = Masc.Keeper_meta_merge
module Keeper_registry = Masc.Keeper_registry
module Keeper_keepalive = Masc.Keeper_keepalive
module Keeper_turn_lifecycle = Masc.Keeper_turn_lifecycle
module Keeper_status_bridge = Masc.Keeper_status_bridge
module Keeper_supervisor_cleanup_tombstone = Masc.Keeper_supervisor_cleanup_tombstone
module Keeper_supervisor_types = Masc.Keeper_supervisor_types
module Keeper_types_profile = Masc.Keeper_types_profile

let base_json name =
  `Assoc
    [ "name", `String name
    ; "agent_name", `String (name ^ "-agent")
    ; "trace_id", `String ("trace-" ^ name)
    ; "tool_access", `List []
    ]

let make_meta name =
  match Keeper_meta_json_parse.meta_of_json (base_json name) with
  | Ok meta -> meta
  | Error err -> failf "parse base meta: %s" err

let latched_reason_wire (meta : Keeper_meta_contract.keeper_meta) =
  match meta.latched_reason with
  | Some reason -> Some (Keeper_latched_reason.to_wire reason)
  | None -> None

let bridge_latched_reason config (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_status_bridge.attention_fields_json config meta
    |> List.assoc_opt "latched_reason"
  with
  | Some (`String value) -> Some value
  | Some `Null -> None
  | Some _ -> failf "latched_reason surfaced as a non-string, non-null JSON value"
  | None -> failf "attention_fields_json did not surface a latched_reason field"

let wire_grpc_directive =
  Keeper_latched_reason.to_wire
    (Keeper_latched_reason.Operator_paused
       { operator_actor = Keeper_latched_reason.operator_actor_grpc_directive })

let wire_keeper_down =
  Keeper_latched_reason.to_wire
    (Keeper_latched_reason.Operator_paused
       { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })

let wire_dead_tombstone = Keeper_latched_reason.to_wire Keeper_latched_reason.Dead_tombstone

(* ── Serialization + merge durability ───────────────────────── *)

let test_latched_reason_survives_serialization () =
  List.iter
    (fun (label, reason) ->
       let meta =
         { (make_meta "serial-keeper") with
           paused = true
         ; latched_reason = Some reason
         }
       in
       let reparsed =
         match Keeper_meta_json_parse.meta_of_json (Keeper_meta_json.meta_to_json meta) with
         | Ok m -> m
         | Error err -> failf "%s: roundtrip parse failed: %s" label err
       in
       check bool (label ^ ": paused survives") true reparsed.paused;
       check
         (option string)
         (label ^ ": latched_reason survives")
         (Some (Keeper_latched_reason.to_wire reason))
         (latched_reason_wire reparsed))
    [ "dead tombstone", Keeper_latched_reason.Dead_tombstone
    ; ( "operator paused"
      , Keeper_latched_reason.Operator_paused
          { operator_actor = Keeper_latched_reason.operator_actor_keeper_down } )
    ]

let test_no_latched_reason_serializes_as_null () =
  let meta = make_meta "no-reason-keeper" in
  let json = Keeper_meta_json.meta_to_json meta in
  (match json with
   | `Assoc fields ->
     check
       bool
       "latched_reason present as JSON null when unset"
       true
       (List.assoc_opt "latched_reason" fields = Some `Null)
   | _ -> fail "meta_to_json did not produce an object");
  let reparsed =
    match Keeper_meta_json_parse.meta_of_json json with
    | Ok m -> m
    | Error err -> failf "roundtrip parse failed: %s" err
  in
  check (option string) "unset latched_reason round-trips to None" None
    (latched_reason_wire reparsed)

(* ── Status bridge surfacing ────────────────────────────────── *)

let test_status_bridge_surfaces_latched_reason () =
  let config = Masc.Workspace.default_config (Masc_test_deps.setup_test_workspace ()) in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace config.base_path)
    (fun () ->
       let paused_meta =
         { (make_meta "bridge-keeper") with
           paused = true
         ; latched_reason =
             Some
               (Keeper_latched_reason.Operator_paused
                  { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })
         }
       in
       check
         (option string)
         "bridge surfaces the typed pause reason as its wire form"
         (Some wire_keeper_down)
         (bridge_latched_reason config paused_meta);
       let unset_meta = { (make_meta "bridge-keeper-unset") with paused = true } in
       check
         (option string)
         "bridge surfaces null when no reason recorded"
         None
         (bridge_latched_reason config unset_meta))

(* ── Site 3: gRPC pause directive ───────────────────────────── *)

let test_grpc_pause_directive_records_reason () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "grpc-directive-keeper" in
       let meta = make_meta keeper_name in
       Keeper_registry.clear ();
       ignore (Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       Keeper_keepalive.process_directive ~agent_name:keeper_name "pause";
       (match Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          check bool "pause directive pauses keeper" true entry.meta.paused;
          check
            (option string)
            "pause directive records grpc_directive operator pause"
            (Some wire_grpc_directive)
            (latched_reason_wire entry.meta)
        | None -> fail "expected registered keeper after pause directive");
       Keeper_keepalive.process_directive ~agent_name:keeper_name "resume";
       match Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool "resume directive resumes keeper" false entry.meta.paused;
         check
           (option string)
           "resume clears the latched reason together with the pause bit"
           None
           (latched_reason_wire entry.meta)
       | None -> fail "expected registered keeper after resume directive")

(* ── Site 2: keeper_down retain (remove_meta=false) ─────────── *)

let test_keeper_down_retain_records_reason () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       (* Avoid a leading "keeper-" — identity resolution strips that prefix
          and the write/read names would diverge. *)
       let keeper_name = "downretain-owner" in
       let meta = make_meta keeper_name in
       Keeper_registry.clear ();
       (match Keeper_meta_store.write_meta config meta with
        | Ok () -> ()
        | Error err -> failf "seed meta write: %s" err);
       ignore (Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       let args =
         `Assoc
           [ "name", `String keeper_name
           ; "remove_meta", `Bool false
           ; "remove_session", `Bool false
           ]
       in
       let _result = Keeper_turn_lifecycle.handle_keeper_down_config ~config args in
       match Keeper_meta_store.read_meta config keeper_name with
       | Ok (Some persisted) ->
         check bool "keeper_down retain pauses keeper" true persisted.paused;
         check
           (option string)
           "keeper_down retain records keeper_down operator pause"
           (Some wire_keeper_down)
           (latched_reason_wire persisted)
       | Ok None -> fail "expected retained keeper meta on disk"
       | Error err -> failf "read persisted meta: %s" err)

(* ── Site 1: dead-tombstone cleanup ─────────────────────────── *)

let run_dead_tombstone_cleanup_records_reason
      ?(paused = false)
      ?latched_reason
      ?auto_resume_after_sec
      ?last_blocker
      ?updated_at
      keeper_name
  =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let meta =
         let base =
           { (make_meta keeper_name) with
             paused
           ; latched_reason
           ; auto_resume_after_sec
           }
         in
         let base =
           match updated_at with
           | Some updated_at -> { base with updated_at }
           | None -> base
         in
         { base with runtime = { base.runtime with last_blocker } }
       in
       Keeper_registry.clear ();
       (match Keeper_meta_store.write_meta config meta with
        | Ok () -> ()
        | Error err -> failf "seed meta write: %s" err);
       let entry =
         Keeper_registry.register ~base_path:config.base_path keeper_name meta
       in
       let ctx : _ Keeper_types_profile.context =
         { config
         ; agent_name = "supervisor"
         ; sw
         ; clock = Eio.Stdenv.clock env
         ; proc_mgr = None
         ; net = None
         }
       in
       let events = ref [] in
       let publish_lifecycle ~event:_ name detail () =
         events := (name, detail) :: !events
       in
       Keeper_supervisor_cleanup_tombstone.cleanup_dead_tombstone
         ~publish_lifecycle
         ctx
         entry;
       check bool "dead-cleaned lifecycle event published" true (!events <> []);
       match Keeper_meta_store.read_meta config keeper_name with
       | Ok (Some persisted) ->
         check bool "dead tombstone persists paused=true" true persisted.paused;
         check
           (option string)
           "dead tombstone records the Dead_tombstone reason"
           (Some wire_dead_tombstone)
           (latched_reason_wire persisted);
         check
           bool
           "dead tombstone clears stale auto-resume policy"
           true
           (Option.is_none persisted.auto_resume_after_sec);
         check
           bool
           "dead tombstone clears stale blocker"
           true
           (Option.is_none persisted.runtime.last_blocker);
         check
           bool
           "dead tombstone pause is not auto-resume due"
           false
           (Keeper_supervisor_types.paused_meta_auto_resume_due
              ~now:(Unix.time () +. 7200.0)
              persisted)
       | Ok None -> fail "expected tombstone meta to remain on disk after cleanup"
       | Error err -> failf "read persisted meta: %s" err)

let test_dead_tombstone_cleanup_records_reason () =
  run_dead_tombstone_cleanup_records_reason "dead-tombstone-keeper"

let test_dead_tombstone_cleanup_overwrites_existing_pause_reason () =
  run_dead_tombstone_cleanup_records_reason
    ~paused:true
    ~latched_reason:
      (Keeper_latched_reason.Operator_paused
         { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })
    "dead-tombstone-paused-keeper"

let test_dead_tombstone_cleanup_clears_auto_resume_state () =
  let timeout_blocker =
    Keeper_meta_contract.blocker_info_of_class
      ~detail:"stale auto-pause before dead cleanup"
      Keeper_meta_contract.Turn_timeout
  in
  run_dead_tombstone_cleanup_records_reason
    ~paused:true
    ~latched_reason:
      (Keeper_latched_reason.Operator_paused
         { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })
    ~auto_resume_after_sec:1.0
    ~last_blocker:timeout_blocker
    ~updated_at:"1970-01-01T00:00:00Z"
    "dead-tombstone-auto-resume-keeper"

let test_dead_tombstone_cleanup_repairs_stale_terminal_state () =
  let timeout_blocker =
    Keeper_meta_contract.blocker_info_of_class
      ~detail:"stale dead tombstone auto-resume state"
      Keeper_meta_contract.Turn_timeout
  in
  run_dead_tombstone_cleanup_records_reason
    ~paused:true
    ~latched_reason:Keeper_latched_reason.Dead_tombstone
    ~auto_resume_after_sec:1.0
    ~last_blocker:timeout_blocker
    ~updated_at:"1970-01-01T00:00:00Z"
    "dead-tombstone-stale-terminal-keeper"

let test_dead_tombstone_latch_blocks_legacy_auto_resume () =
  let timeout_blocker =
    Keeper_meta_contract.blocker_info_of_class
      ~detail:"stale timeout pause before dead cleanup"
      Keeper_meta_contract.Turn_timeout
  in
  let meta =
    { (make_meta "dead-tombstone-legacy-auto-resume") with
      paused = true
    ; latched_reason = Some Keeper_latched_reason.Dead_tombstone
    ; auto_resume_after_sec = Some 1.0
    ; updated_at = "1970-01-01T00:00:00Z"
    ; runtime =
        { (make_meta "dead-tombstone-legacy-auto-resume").runtime with
          last_blocker = Some timeout_blocker
        }
    }
  in
  check
    bool
    "Dead_tombstone latch blocks explicit and legacy auto-resume"
    false
    (Keeper_supervisor_types.paused_meta_auto_resume_due
       ~now:(Unix.time () +. 7200.0)
       meta)

let test_heartbeat_merge_preserves_only_typed_operator_pause () =
  let caller =
    { (make_meta "typed-operator-pause-merge-caller") with
      paused = false
    ; latched_reason = None
    }
  in
  let operator_latch =
    Some
      (Keeper_latched_reason.Operator_paused
         { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })
  in
  let latest_operator_pause =
    { caller with paused = true; latched_reason = operator_latch }
  in
  let preserved =
    Keeper_meta_merge.heartbeat_fields_from_disk
      ~latest:latest_operator_pause
      ~caller
  in
  check bool "typed operator pause remains paused" true preserved.paused;
  check
    (option string)
    "typed operator pause preserves reason"
    (Some wire_keeper_down)
    (latched_reason_wire preserved);
  let latest_unlabeled_pause =
    { latest_operator_pause with latched_reason = None }
  in
  let not_preserved =
    Keeper_meta_merge.heartbeat_fields_from_disk
      ~latest:latest_unlabeled_pause
      ~caller
  in
  check bool "unlabeled pause shape no longer owns the merge" false not_preserved.paused;
  check
    (option string)
    "unlabeled pause does not copy a reason"
    None
    (latched_reason_wire not_preserved)

(* Reviewer P1 (2026-07-03): the overwrite test above only exercises the
   no-conflict write, where the merge never runs. On a CAS retry the cleanup
   re-reads disk; if that snapshot is an operator pause, reusing
   [heartbeat_fields_from_disk] copied the operator reason back over
   [Dead_tombstone] and returned [Ok ()], silently persisting the wrong reason.
   This drives the retry path deterministically without a concurrent writer: the
   caller carries a stale [meta_version] so its first write loses the CAS race
   against a seeded operator-pause snapshot, forcing the merge to run. *)
let test_dead_tombstone_cleanup_cas_retry_preserves_reason () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "dead-tombstone-cas-keeper" in
       (* Disk snapshot the retry re-reads: an operator pause with a higher turn
          count than the caller's stale snapshot. The typed
          [Operator_paused] latch is what lets the heartbeat merge preserve the
          disk pause; dead-tombstone cleanup must keep ownership with the
          caller instead. *)
       let disk_meta =
         let base =
           { (make_meta keeper_name) with
             paused = true
           ; latched_reason =
               Some
                 (Keeper_latched_reason.Operator_paused
                    { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })
           }
         in
         { base with
           runtime =
             { base.runtime with
               usage = { base.runtime.usage with total_turns = 7 }
             }
         }
       in
       (match Keeper_meta_store.write_meta config disk_meta with
        | Ok () -> ()
        | Error err -> failf "seed disk meta: %s" err);
       (* Caller: the cleanup's stale in-hand snapshot. [meta_version = 0] loses
          the CAS race against the seeded version, forcing the retry + merge. *)
       let caller =
         { disk_meta with
           meta_version = 0
         ; paused = true
         ; latched_reason = Some Keeper_latched_reason.Dead_tombstone
         ; runtime =
             { disk_meta.runtime with
               usage = { disk_meta.runtime.usage with total_turns = 3 }
             }
         }
       in
       (match
          Keeper_meta_store.write_meta_with_merge
            ~merge:Keeper_meta_merge.dead_tombstone_cleanup_from_disk
            config
            caller
        with
        | Ok () -> ()
        | Error err -> failf "write_meta_with_merge after CAS retry: %s" err);
       match Keeper_meta_store.read_meta config keeper_name with
       | Ok (Some persisted) ->
         check bool "CAS retry keeps paused=true" true persisted.paused;
         check
           (option string)
           "CAS retry persists Dead_tombstone, not the operator reason"
           (Some wire_dead_tombstone)
           (latched_reason_wire persisted);
         check
           int
           "CAS retry preserves heartbeat-owned turn count monotonically"
           7
           persisted.runtime.usage.total_turns
       | Ok None -> fail "expected meta on disk after CAS retry"
       | Error err -> failf "read persisted meta: %s" err)

let () =
  run
    "keeper_latched_reason_wiring"
    [ ( "serialization"
      , [ test_case "typed pause reason survives meta serialization" `Quick
            test_latched_reason_survives_serialization
        ; test_case "unset reason serializes as null and round-trips to None" `Quick
            test_no_latched_reason_serializes_as_null
        ] )
    ; ( "status bridge"
      , [ test_case "attention fields surface the typed pause reason wire" `Quick
            test_status_bridge_surfaces_latched_reason
        ] )
    ; ( "pause sites record reason"
      , [ test_case "gRPC pause directive records grpc_directive reason" `Quick
            test_grpc_pause_directive_records_reason
        ; test_case "keeper_down retain records keeper_down reason" `Quick
            test_keeper_down_retain_records_reason
        ; test_case "dead-tombstone cleanup records Dead_tombstone reason" `Quick
            test_dead_tombstone_cleanup_records_reason
        ; test_case "dead-tombstone cleanup overwrites existing pause reason" `Quick
            test_dead_tombstone_cleanup_overwrites_existing_pause_reason
        ; test_case "dead-tombstone cleanup clears auto-resume state" `Quick
            test_dead_tombstone_cleanup_clears_auto_resume_state
        ; test_case "dead-tombstone cleanup repairs stale terminal state" `Quick
            test_dead_tombstone_cleanup_repairs_stale_terminal_state
        ; test_case "dead-tombstone latch blocks legacy auto-resume" `Quick
            test_dead_tombstone_latch_blocks_legacy_auto_resume
        ; test_case "heartbeat merge uses typed operator latch, not pause shape" `Quick
            test_heartbeat_merge_preserves_only_typed_operator_pause
        ; test_case "dead-tombstone cleanup CAS retry preserves Dead_tombstone" `Quick
            test_dead_tombstone_cleanup_cas_retry_preserves_reason
        ] )
    ]
