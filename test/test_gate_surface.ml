(* RFC-0223 P2 — Gate_surface unit tests.

   - [label] projects the current typed presence variants.
   - [connected_surfaces_for_keeper] presence derivation against a
     temp Discord binding store: dashboard always present, bound
     channel listed, liveness false while no gateway runs.

   Minimal-deps executable (masc.gate only), mirroring
   test_channel_gate_discord_state_in_process. *)

open Alcotest

module Surface = Gate_surface

let surface_pp fmt (s : Surface.t) =
  match s with
  | Surface.Dashboard -> Format.fprintf fmt "Dashboard"
  | Surface.Discord { workspace_id; channel_id } ->
      Format.fprintf fmt "Discord{ws=%s;ch=%s}"
        (Option.value workspace_id ~default:"-")
        (Option.value channel_id ~default:"-")
  | Surface.Slack { workspace_id; channel_id } ->
      Format.fprintf fmt "Slack{ws=%s;ch=%s}"
        (Option.value workspace_id ~default:"-")
        (Option.value channel_id ~default:"-")
  | Surface.Gate { channel; channel_id } ->
      Format.fprintf fmt "Gate{%s;ch=%s}" channel
        (Option.value channel_id ~default:"-")

let surface : Surface.t testable = testable surface_pp ( = )

let presence_pp fmt (p : Surface.surface_presence) =
  Format.fprintf fmt "{%a alive=%b}" surface_pp p.surface p.alive

let presence : Surface.surface_presence testable = testable presence_pp ( = )

(* ---------------------------------------------------------------- *)
(* label projection                                                 *)
(* ---------------------------------------------------------------- *)

let test_current_variant_labels () =
  let cases =
    [ Surface.Dashboard, "dashboard"
    ; Surface.Discord { workspace_id = None; channel_id = Some "d1" }, "discord"
    ; Surface.Slack { workspace_id = None; channel_id = Some "s1" }, "slack"
    ; Surface.Gate { channel = "openclaw"; channel_id = Some "g1" }, "openclaw"
    ]
  in
  List.iter
    (fun (surface, expected) ->
      check string expected expected (Surface.label surface))
    cases

(* ---------------------------------------------------------------- *)
(* connected_surfaces_for_keeper                                    *)
(* ---------------------------------------------------------------- *)

let with_binding_store entries f =
  let path = Filename.temp_file "gate-surface-bindings" ".json" in
  let json =
    `Assoc (List.map (fun (ch, keeper) -> (ch, `String keeper)) entries)
  in
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc (Yojson.Safe.to_string json));
  Unix.putenv "MASC_DISCORD_BINDING_STORE_PATH" path;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_DISCORD_BINDING_STORE_PATH" "";
      try Sys.remove path with Sys_error _ -> ())
    f

let register_discord () =
  Channel_gate_connector.register (module Channel_gate_discord_state)

let test_dashboard_always_present () =
  register_discord ();
  with_binding_store [] (fun () ->
      let surfaces =
        Surface.connected_surfaces_for_keeper ~keeper_name:"unbound-keeper"
      in
      check int "no presence failures" 0 (List.length surfaces.failures);
      check (list presence) "dashboard only"
        [ { Surface.surface = Surface.Dashboard; alive = true } ]
        surfaces.surfaces)

let test_bound_discord_channel_listed_offline_without_gateway () =
  register_discord ();
  with_binding_store
    [ ("98791450001", "surface-keeper"); ("12300000000", "other-keeper") ]
    (fun () ->
      let surfaces =
        Surface.connected_surfaces_for_keeper ~keeper_name:"surface-keeper"
      in
      check int "no presence failures" 0 (List.length surfaces.failures);
      check (list presence) "dashboard + own discord channel, not alive"
        [ { Surface.surface = Surface.Dashboard; alive = true }
        ; { Surface.surface =
              Surface.Discord
                { workspace_id = None; channel_id = Some "98791450001" }
          ; alive = false
          }
        ]
        surfaces.surfaces)

let test_binding_failure_is_not_empty_presence () =
  register_discord ();
  let path = Filename.temp_file "gate-surface-bindings" ".json" in
  Yojson.Safe.to_file path (`Assoc [ ("bad", `Int 1) ]);
  Unix.putenv "MASC_DISCORD_BINDING_STORE_PATH" path;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_DISCORD_BINDING_STORE_PATH" "";
      try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let snapshot =
        Surface.connected_surfaces_for_keeper ~keeper_name:"surface-keeper"
      in
      check int "dashboard remains present" 1 (List.length snapshot.surfaces);
      match snapshot.failures with
      | [ failure ] ->
        check string "connector identity retained" "discord" failure.connector_id
      | failures ->
        failf "expected one typed presence failure, got %d" (List.length failures))

let test_bound_channels_blank_keeper_is_empty () =
  with_binding_store
    [ ("98791450001", "surface-keeper") ]
    (fun () ->
      check (list string) "blank name" []
        (Channel_gate_discord_state.bound_channels_result ~keeper_name:"  "
         |> Result.get_ok);
      check (list string) "bound name" [ "98791450001" ]
        (Channel_gate_discord_state.bound_channels_result
           ~keeper_name:"surface-keeper"
         |> Result.get_ok))

let test_discord_not_connected_without_run_loop () =
  check bool "no gateway => not connected" false
    (Channel_gate_discord_state.connected ())

let () =
  run "gate_surface"
    [
      ( "label",
        [ test_case "current variant labels" `Quick test_current_variant_labels ] );
      ( "presence",
        [
          test_case "dashboard always present" `Quick
            test_dashboard_always_present;
          test_case "bound discord channel listed, offline without gateway"
            `Quick test_bound_discord_channel_listed_offline_without_gateway;
          test_case "bound_channels blank keeper" `Quick
            test_bound_channels_blank_keeper_is_empty;
          test_case "binding failure is not empty presence" `Quick
            test_binding_failure_is_not_empty_presence;
          test_case "discord not connected without run loop" `Quick
            test_discord_not_connected_without_run_loop;
        ] );
    ]
