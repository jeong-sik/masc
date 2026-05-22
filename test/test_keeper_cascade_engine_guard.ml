(* OAS internal cascade regression guard.

   Verifies the invariant that keeper hot path uses only single-provider
   OAS dispatch and never delegates provider fallback to OAS internal
   cascade.  See docs/keeper-turn-lifecycle.md "Autonomous vs Direct".

   The [t] type is abstract; only [keeper_managed] is exposed, which
   hardcodes the invariant.  This test pins the field values so any
   future change to the constructor or default must be deliberate.
*)

let () =
  let open Alcotest in
  run "Keeper_cascade_engine guard"
    [
      ( "guard_keeper_hot_path",
        [
          test_case "keeper_managed passes guard" `Quick (fun () ->
              let guard_result =
                Masc_mcp.Keeper_cascade_engine.guard_keeper_hot_path
                  Masc_mcp.Keeper_cascade_engine.keeper_managed
              in
              check (result unit string) "returns Ok ()" (Ok ()) guard_result);
        ] );
      ( "dispatch_mode",
        [
          test_case "to_string is stable" `Quick (fun () ->
              let s =
                Masc_mcp.Keeper_cascade_engine.to_string
                  Masc_mcp.Keeper_cascade_engine.keeper_managed
              in
              check string "engine id" "masc_keeper_named_cascade" s);
          test_case "oas_dispatch_mode_to_string is stable" `Quick (fun () ->
              let s =
                Masc_mcp.Keeper_cascade_engine.oas_dispatch_mode_to_string
                  Single_provider_agent_run
              in
              check string "mode string" "single_provider_agent_run" s);
        ] );
      ( "manifest_fields",
        [
          test_case "fields expose invariant" `Quick (fun () ->
              let fields =
                Masc_mcp.Keeper_cascade_engine.manifest_fields
                  Masc_mcp.Keeper_cascade_engine.keeper_managed
              in
              let assoc = List.to_seq fields |> Hashtbl.of_seq in
              check string "cascade_engine" "masc_keeper_named_cascade"
                ( match Hashtbl.find_opt assoc "cascade_engine" with
                | Some (`String s) -> s
                | _ -> "<missing>" );
              check string "oas_dispatch_mode" "single_provider_agent_run"
                ( match Hashtbl.find_opt assoc "oas_dispatch_mode" with
                | Some (`String s) -> s
                | _ -> "<missing>" );
              check bool "oas_internal_cascade_allowed" false
                ( match
                    Hashtbl.find_opt assoc "oas_internal_cascade_allowed"
                  with
                | Some (`Bool b) -> b
                | _ -> true ));
        ] );
    ]
