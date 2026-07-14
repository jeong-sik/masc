(** task-1664 (audit Wave F1): pin that the three bool-only pause sites
    record a typed [Keeper_latched_reason.t] in keeper_meta, that the
    reason survives serialization and the operator-pause merge, and that
    the status bridge surfaces it.

    Sites under test:
    - gRPC pause directive ([Keeper_keepalive.process_directive Pause]
      -> [directive_paused_meta]) -> [Operator_paused {grpc_directive}]
    - keeper_down retain ([Keeper_shutdown_finalize.For_testing.paused_meta],
      remove_meta=false) -> [Operator_paused {keeper_down}]
    - durable dead-tombstone final meta
      ([Keeper_shutdown_finalize.For_testing.dead_tombstone_meta])
      -> [Dead_tombstone]

    Observability only: these tests assert the {i reason} annotation, not
    any change to the pause/resume decision (which stays carried by
    [meta.paused]). *)

open Alcotest
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_json = Masc.Keeper_meta_json
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Keeper_meta_merge = Masc.Keeper_meta_merge
module Keeper_registry = Masc.Keeper_registry
module Keeper_keepalive = Masc.Keeper_keepalive
module Keeper_directive = Masc.Keeper_directive
module Keeper_turn_lifecycle = Masc.Keeper_turn_lifecycle
module Keeper_status_bridge = Masc.Keeper_status_bridge
module Keeper_supervisor_types = Masc.Keeper_supervisor_types

let base_json name =
  `Assoc
    [ "name", `String name
    ; "agent_name", `String (name ^ "-agent")
    ; "trace_id", `String ("trace-" ^ name)
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

let test_retired_auto_resume_field_is_diagnostic_only () =
  let before =
    Masc.Otel_metric_store.metric_total
      Keeper_metrics.(to_string MetaReadFailures)
  in
  let json =
    match base_json "retired-auto-resume-field" with
    | `Assoc fields ->
      `Assoc
        (("paused", `Bool true)
         :: ("auto_resume_after_sec", `Null)
         :: fields)
    | _ -> fail "base_json must be an object"
  in
  let parsed =
    match Keeper_meta_json_parse.meta_of_json json with
    | Ok meta -> meta
    | Error error -> failf "retired field parse failed: %s" error
  in
  let after =
    Masc.Otel_metric_store.metric_total
      Keeper_metrics.(to_string MetaReadFailures)
  in
  check bool "retired field does not activate paused keeper" true parsed.paused;
  check (option string) "retired field does not invent a latch" None
    (latched_reason_wire parsed);
  check (float 0.001) "retired field emits migration-needed diagnostic"
    (before +. 1.0) after

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
       Keeper_keepalive.process_directive
         ~agent_name:keeper_name
         Keeper_directive.Pause;
       (match Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          check bool "pause directive pauses keeper" true entry.meta.paused;
          check
            (option string)
            "pause directive records grpc_directive operator pause"
            (Some wire_grpc_directive)
            (latched_reason_wire entry.meta)
        | None -> fail "expected registered keeper after pause directive");
       Keeper_keepalive.process_directive
         ~agent_name:keeper_name
         Keeper_directive.Resume;
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
  let retained =
    Masc.Keeper_shutdown_finalize.For_testing.paused_meta
      (make_meta "downretain-owner")
  in
  check bool "keeper_down retain pauses keeper" true retained.paused;
  check
    (option string)
    "keeper_down retain records keeper_down operator pause"
    (Some wire_keeper_down)
    (latched_reason_wire retained)

(* ── Site 1: dead-tombstone cleanup ─────────────────────────── *)

let test_dead_tombstone_final_meta_records_reason () =
  let timeout_blocker =
    Keeper_meta_contract.blocker_info_of_class
      ~detail:"stale pause before durable dead finalization"
      Keeper_meta_contract.Stale_turn_timeout
  in
  let input =
    { (make_meta "dead-tombstone-final-meta") with
      paused = true
    ; latched_reason =
        Some
          (Keeper_latched_reason.Operator_paused
             { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })
    ; runtime =
        { (make_meta "dead-tombstone-final-meta").runtime with
          last_blocker = Some timeout_blocker
        }
    }
  in
  let finalized =
    Masc.Keeper_shutdown_finalize.For_testing.dead_tombstone_meta input
  in
  check bool "dead final meta remains paused" true finalized.paused;
  check
    (option string)
    "dead final meta records Dead_tombstone"
    (Some wire_dead_tombstone)
    (latched_reason_wire finalized);
  check bool "dead final meta clears stale blocker" true
    (Option.is_none finalized.runtime.last_blocker)

let test_heartbeat_merge_preserves_typed_latched_pause () =
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
  let latest_dead_tombstone =
    { latest_operator_pause with
      latched_reason = Some Keeper_latched_reason.Dead_tombstone
    }
  in
  let dead_preserved =
    Keeper_meta_merge.heartbeat_fields_from_disk
      ~latest:latest_dead_tombstone
      ~caller
  in
  check bool "typed dead tombstone remains paused" true dead_preserved.paused;
  check
    (option string)
    "typed dead tombstone preserves terminal reason"
    (Some wire_dead_tombstone)
    (latched_reason_wire dead_preserved);
  let latest_unlabeled_pause =
    { latest_operator_pause with latched_reason = None }
  in
  let unclassified_preserved =
    Keeper_meta_merge.heartbeat_fields_from_disk
      ~latest:latest_unlabeled_pause
      ~caller
  in
  check bool "unclassified pause remains durable" true unclassified_preserved.paused;
  check
    (option string)
    "unclassified pause remains explicitly unlabeled"
    None
    (latched_reason_wire unclassified_preserved)

let () =
  run
    "keeper_latched_reason_wiring"
    [ ( "serialization"
      , [ test_case "typed pause reason survives meta serialization" `Quick
            test_latched_reason_survives_serialization
        ; test_case "unset reason serializes as null and round-trips to None" `Quick
            test_no_latched_reason_serializes_as_null
        ; test_case "retired auto-resume field is diagnostic only" `Quick
            test_retired_auto_resume_field_is_diagnostic_only
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
        ; test_case "dead final meta records terminal tombstone reason" `Quick
            test_dead_tombstone_final_meta_records_reason
        ; test_case "heartbeat merge preserves typed latch, not pause shape" `Quick
            test_heartbeat_merge_preserves_typed_latched_pause
        ] )
    ]
