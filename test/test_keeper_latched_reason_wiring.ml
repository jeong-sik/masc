(** Pin that typed owner commands retain pause latches, serialization, and
    the status bridge without any stale-snapshot merge path.

    Sites under test:
    - gRPC pause directive -> Owner [Pause]
    - keeper_down retain -> Owner [Retain_shutdown_latch Operator_stopped]

    Observability only: these tests assert the {i reason} annotation, not
    any change to the pause/resume decision (which stays carried by
    [meta.paused]). *)

open Alcotest
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_json = Masc.Keeper_meta_json
module Keeper_meta_json_parse = Masc.Keeper_meta_json_parse
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_owner_reducer = Masc.Keeper_owner_reducer
module Keeper_owner_registry = Masc.Keeper_owner_registry
module Keeper_registry = Masc.Keeper_registry
module Keeper_keepalive = Masc.Keeper_keepalive
module Keeper_directive = Masc.Keeper_directive
module Keeper_turn_lifecycle = Masc.Keeper_turn_lifecycle
module Keeper_status_bridge = Masc.Keeper_status_bridge
module Keeper_supervisor_types = Masc.Keeper_supervisor_types

let base_json name =
  `Assoc
    [ "schema", `String "masc.keeper_meta.v2"
    ; "name", `String name
    ; "trace_id", `String ("trace-" ^ name)
    ]

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
    [ ( "operator paused"
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
  Eio.Switch.run @@ fun sw ->
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
       Keeper_meta_store.replace_snapshot config meta
       |> Result.get_ok;
       Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config
       |> Result.get_ok
       |> ignore;
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

let apply_reducer_command meta command =
  let state =
    Keeper_owner_reducer.create ~keeper_name:meta.Keeper_meta_contract.name (Some meta)
    |> Result.get_ok
  in
  let transition = Keeper_owner_reducer.apply_meta state command |> Result.get_ok in
  (Keeper_owner_reducer.projection transition.state).meta |> Option.get
;;

let test_reflected_operator_pause_reconciles_registry_phase () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "reflected-operator-pause" in
       let meta =
         { (make_meta keeper_name) with
           paused = true
         ; latched_reason =
             Some
               (Keeper_latched_reason.Operator_paused
                  { operator_actor = Keeper_latched_reason.operator_actor_grpc_directive })
         }
       in
       Keeper_meta_store.replace_snapshot config meta |> Result.get_ok;
       Keeper_owner_registry.install_from_store
         ~sw
         ~operation_runner:None
         ~on_turn_slot_released:None
         config
       |> Result.get_ok
       |> ignore;
       Keeper_registry.For_testing.clear ();
       ignore (Keeper_registry.For_testing.register ~base_path:config.base_path keeper_name meta);
       Keeper_keepalive.process_directive ~agent_name:keeper_name Keeper_directive.Pause;
       match Keeper_registry.get ~base_path:config.base_path keeper_name with
       | Some entry ->
         check
           string
           "reflected pause reconciles the registry phase"
           "paused"
           (Keeper_state_machine.phase_to_string entry.phase);
         check
           (option string)
           "reflected pause preserves the durable latch"
           (Some wire_grpc_directive)
           (latched_reason_wire entry.meta)
       | None -> fail "expected registered keeper after reflected pause")

let test_keeper_down_retain_records_reason () =
  let retained =
    apply_reducer_command
      (make_meta "downretain-owner")
      (Keeper_owner_reducer.Retain_shutdown_latch
         { latch = Keeper_owner_reducer.Operator_stopped; updated_at = "retained" })
  in
  check bool "keeper_down retain pauses keeper" true retained.paused;
  check
    (option string)
    "keeper_down retain records keeper_down operator pause"
    (Some wire_keeper_down)
    (latched_reason_wire retained)

(* ── Site 1: supervisor cleanup ─────────────────────────────── *)


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

        ; test_case "reflected operator pause reconciles registry phase" `Quick
            test_reflected_operator_pause_reconciles_registry_phase
        ] )
    ]
