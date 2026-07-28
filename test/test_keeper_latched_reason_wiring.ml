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

    The latch is no longer observability-only. It began that way — these tests
    originally asserted the {i reason} annotation and nothing about the
    pause/resume decision, which [meta.paused] carried alone. Since then
    admission denies by latch identity and
    [Keeper_meta_contract.mark_resumed] refuses
    [Transcript_corruption_reset_required] and [Dead_tombstone] outright, so
    the reason decides which recovery paths stay open.

    The writers were not upgraded with it, and overwriting an authority is a
    privilege change where overwriting a label was harmless: an operator pause
    could relabel a reset-required latch as ordinary and re-arm generic resume
    against a checkpoint admission still rejects (live 2026-07-27, rondo). The
    "operator pause never downgrades a stronger latch" section below pins that
    consequence, not just the annotation. *)

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

(* [agent_name] is derived, not spelled: the decoder rejects any value that is
   not [Keeper_identity.keeper_agent_name name]. Building it from the same
   function keeps the fixture correct if that convention changes. *)
let base_json name =
  `Assoc
    [ "name", `String name
    ; "agent_name", `String (Masc.Keeper_identity.keeper_agent_name name)
    ; "trace_id", `String ("trace-" ^ name)
    ]

(* [Keeper_meta_json_parse.meta_of_json] decodes the exact current shape, so a
   three-field literal no longer parses and every test in this file failed at
   the fixture ("missing required fields ... runtime reset required") — before
   asserting anything. [Masc_test_deps.meta_of_json_fixture] fills the current
   required set, which is what the sibling suites already use. *)
let make_meta name =
  match Masc_test_deps.meta_of_json_fixture (base_json name) with
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

(* The invariant is unchanged — a retired field must never manufacture
   lifecycle state — but the mechanism is stronger than when this test was
   written. [meta_of_json] used to accept the record and ignore the unknown
   key, emitting a diagnostic; it now decodes only the exact current shape, so
   the record is rejected outright (see the comment at
   [Keeper_meta_store.read_meta_file_path], which states that the separate
   unknown-key pre-scan was removed for exactly this reason). Rejection
   subsumes the old assertion: a record that never becomes a [keeper_meta]
   cannot invent a pause or a latch. *)
let test_retired_auto_resume_field_is_rejected () =
  let json =
    match base_json "retired-auto-resume-field" with
    | `Assoc fields ->
      `Assoc
        (("paused", `Bool true)
         :: ("auto_resume_after_sec", `Null)
         :: fields)
    | _ -> fail "base_json must be an object"
  in
  match Keeper_meta_json_parse.meta_of_json json with
  | Error error ->
    check
      bool
      "the rejection names the retired field"
      true
      (Astring.String.is_infix ~affix:"auto_resume_after_sec" error)
  | Ok meta ->
    failf
      "a retired field must not decode into lifecycle state (paused=%b, latch=%s)"
      meta.paused
      (Option.value ~default:"none" (latched_reason_wire meta))

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
      Keeper_registry.For_testing.clear ();
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "grpc-directive-keeper" in
       let meta = make_meta keeper_name in
       Keeper_registry.For_testing.clear ();
       ignore (Keeper_registry.For_testing.register ~base_path:config.base_path keeper_name meta);
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
         Keeper_directive.Wakeup;
       (match Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          check bool "wakeup does not resume paused keeper" true entry.meta.paused;
          check
            (option string)
            "wakeup preserves the operator pause receipt boundary"
            (Some wire_grpc_directive)
            (latched_reason_wire entry.meta)
        | None -> fail "expected registered keeper after wakeup directive");
       ())

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

(* ── Downgrade guard: the two operator-pause writers ─────────────
   Both sites used to assign [Operator_paused] unconditionally, so either one
   run against a transcript-corrupted keeper relabelled it as ordinarily
   paused — and generic resume, which refuses the reset-required latch by
   identity, was re-armed against a checkpoint admission still rejects. Live on
   2026-07-27 (rondo): masc_keeper_down at 14:54:28Z overwrote a latch set at
   14:42:11Z, and the durable record then no longer named the real cause. *)

let corrupted name =
  Keeper_meta_contract.mark_transcript_corruption_reset_required (make_meta name)
;;

let wire_transcript =
  Keeper_latched_reason.to_wire Keeper_latched_reason.Transcript_corruption_reset_required
;;

let test_keeper_down_does_not_downgrade_transcript_latch () =
  let retained =
    Masc.Keeper_shutdown_finalize.For_testing.paused_meta (corrupted "downretain-corrupt")
  in
  check bool "keeper_down still pauses the keeper" true retained.paused;
  check
    (option string)
    "keeper_down keeps the reset-required latch"
    (Some wire_transcript)
    (latched_reason_wire retained);
  (* The point of keeping it: generic resume must still refuse. *)
  let resumed = Keeper_meta_contract.mark_resumed retained in
  check bool "generic resume is still refused" true resumed.paused
;;

let test_grpc_directive_does_not_downgrade_transcript_latch () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "grpc-directive-corrupt" in
       Keeper_registry.For_testing.clear ();
       ignore
         (Keeper_registry.For_testing.register
            ~base_path:config.base_path
            keeper_name
            (corrupted keeper_name));
       Keeper_keepalive.process_directive ~agent_name:keeper_name Keeper_directive.Pause;
       match Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check bool "directive pause still pauses the keeper" true entry.meta.paused;
         check
           (option string)
           "directive pause keeps the reset-required latch"
           (Some wire_transcript)
           (latched_reason_wire entry.meta);
         let resumed = Keeper_meta_contract.mark_resumed entry.meta in
         check bool "generic resume is still refused" true resumed.paused
       | None -> fail "keeper vanished from the registry after the pause directive")
;;

let test_operator_pause_still_applies_to_an_active_keeper () =
  (* The guard must not turn every pause into a no-op. *)
  let paused =
    Masc.Keeper_shutdown_finalize.For_testing.paused_meta (make_meta "downretain-active")
  in
  check
    (option string)
    "an unlatched keeper records the operator pause"
    (Some wire_keeper_down)
    (latched_reason_wire paused);
  let resumed = Keeper_meta_contract.mark_resumed paused in
  check bool "and generic resume clears it" false resumed.paused
;;

let () =
  run
    "keeper_latched_reason_wiring"
    [ ( "serialization"
      , [ test_case "typed pause reason survives meta serialization" `Quick
            test_latched_reason_survives_serialization
        ; test_case "unset reason serializes as null and round-trips to None" `Quick
            test_no_latched_reason_serializes_as_null
        ; test_case "retired auto-resume field is rejected" `Quick
            test_retired_auto_resume_field_is_rejected
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
    ; ( "operator pause never downgrades a stronger latch"
      , [ test_case "keeper_down keeps a reset-required latch" `Quick
            test_keeper_down_does_not_downgrade_transcript_latch
        ; test_case "gRPC directive keeps a reset-required latch" `Quick
            test_grpc_directive_does_not_downgrade_transcript_latch
        ; test_case "an unlatched keeper still records the operator pause" `Quick
            test_operator_pause_still_applies_to_an_active_keeper
        ] )
    ]
