open Alcotest

module ES = Masc_mcp.Keeper_exec_status
module KT = Masc_mcp.Keeper_types

let make_meta ?(name = "keeper-exec-status-test")
    ?(trace_id = "trace-keeper-exec-status") () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("cascade_name", `String "keeper_unified");
          ("last_model_used", `String "llama:auto");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let test_keeper_surface_status_preserves_live_agent_states () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "busy") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "healthy") ])
  in
  check string "healthy busy keeper stays busy" "busy" status

let test_keeper_surface_status_maps_stale_to_inactive () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "active") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "stale") ])
  in
  check string "stale keeper is not surfaced as active" "inactive" status

let test_keeper_surface_status_maps_degraded_to_inactive () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "listening") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "degraded") ])
  in
  check string "degraded keeper is not surfaced as listening" "inactive" status

let test_keeper_surface_status_maps_zombie_to_inactive () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "active") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "zombie") ])
  in
  check string "zombie keeper is not surfaced as active" "inactive" status

let test_keeper_surface_status_maps_dead_to_inactive () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "busy") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "dead") ])
  in
  check string "dead keeper is not surfaced as busy" "inactive" status

let test_derive_pipeline_stage_treats_inactive_as_offline () =
  let meta =
    let base = make_meta () in
    {
      base with
      runtime =
        {
          base.runtime with
          usage = { base.runtime.usage with last_turn_ts = Time_compat.now () };
        };
    }
  in
  let stage =
    ES.derive_pipeline_stage ~meta ~surface_status:"inactive"
      ~now_ts:(Time_compat.now ())
  in
  check string "inactive keeper does not advertise a live pipeline stage"
    "offline" stage

let () =
  run "keeper_exec_status"
    [
      ( "surface_status",
        [
          test_case "preserves live agent states" `Quick
            test_keeper_surface_status_preserves_live_agent_states;
          test_case "maps stale to inactive" `Quick
            test_keeper_surface_status_maps_stale_to_inactive;
          test_case "maps degraded to inactive" `Quick
            test_keeper_surface_status_maps_degraded_to_inactive;
          test_case "maps zombie to inactive" `Quick
            test_keeper_surface_status_maps_zombie_to_inactive;
          test_case "maps dead to inactive" `Quick
            test_keeper_surface_status_maps_dead_to_inactive;
          test_case "inactive pipeline stage becomes offline" `Quick
            test_derive_pipeline_stage_treats_inactive_as_offline;
        ] );
    ]
