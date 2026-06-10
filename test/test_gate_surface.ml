(* RFC-0223 P2 — Gate_surface unit tests.

   - [label]/[of_source] round-trip over known labels and the
     unknown-label -> [Gate] case (RFC-0223 §6).
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
(* label / of_source round-trip                                     *)
(* ---------------------------------------------------------------- *)

let of_source_plain source =
  Surface.of_source ~source ~workspace_id:None ~channel_id:None

let test_builtin_labels_parse_to_builtin_variants () =
  check surface "dashboard" Surface.Dashboard (of_source_plain "dashboard");
  check surface "discord"
    (Surface.Discord { workspace_id = None; channel_id = None })
    (of_source_plain "discord");
  check surface "slack"
    (Surface.Slack { workspace_id = None; channel_id = None })
    (of_source_plain "slack")

let test_unknown_label_maps_to_gate_not_a_builtin () =
  (* Honest reading: every non-builtin source IS a gate channel
     label. "agent" (keeper's own output) and connector labels both
     land here. *)
  List.iter
    (fun source ->
      check surface source
        (Surface.Gate { channel = source; channel_id = None })
        (of_source_plain source))
    [ "openclaw"; "agent"; "imessage"; "telegram" ]

let test_label_round_trips_every_source () =
  List.iter
    (fun source ->
      check string source source (Surface.label (of_source_plain source)))
    [ "dashboard"; "discord"; "slack"; "openclaw"; "agent"; "imessage" ]

let test_of_source_carries_lane_ids () =
  check surface "discord lane"
    (Surface.Discord
       { workspace_id = Some "guild-1"; channel_id = Some "chan-1" })
    (Surface.of_source ~source:"discord" ~workspace_id:(Some "guild-1")
       ~channel_id:(Some "chan-1"));
  check surface "gate lane"
    (Surface.Gate { channel = "openclaw"; channel_id = Some "room-9" })
    (Surface.of_source ~source:"openclaw" ~workspace_id:None
       ~channel_id:(Some "room-9"))

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
      check (list presence) "dashboard only"
        [ { Surface.surface = Surface.Dashboard; alive = true } ]
        surfaces)

let test_bound_discord_channel_listed_offline_without_gateway () =
  register_discord ();
  with_binding_store
    [ ("98791450001", "surface-keeper"); ("12300000000", "other-keeper") ]
    (fun () ->
      let surfaces =
        Surface.connected_surfaces_for_keeper ~keeper_name:"surface-keeper"
      in
      check (list presence) "dashboard + own discord channel, not alive"
        [ { Surface.surface = Surface.Dashboard; alive = true }
        ; { Surface.surface =
              Surface.Discord
                { workspace_id = None; channel_id = Some "98791450001" }
          ; alive = false
          }
        ]
        surfaces)

let test_bound_channels_blank_keeper_is_empty () =
  with_binding_store
    [ ("98791450001", "surface-keeper") ]
    (fun () ->
      check (list string) "blank name" []
        (Channel_gate_discord_state.bound_channels ~keeper_name:"  ");
      check (list string) "bound name" [ "98791450001" ]
        (Channel_gate_discord_state.bound_channels
           ~keeper_name:"surface-keeper"))

let test_discord_not_connected_without_run_loop () =
  check bool "no gateway => not connected" false
    (Channel_gate_discord_state.connected ())

let () =
  run "gate_surface"
    [
      ( "of_source/label",
        [
          test_case "builtin labels parse to builtin variants" `Quick
            test_builtin_labels_parse_to_builtin_variants;
          test_case "unknown label maps to Gate" `Quick
            test_unknown_label_maps_to_gate_not_a_builtin;
          test_case "label round-trips every source" `Quick
            test_label_round_trips_every_source;
          test_case "of_source carries lane ids" `Quick
            test_of_source_carries_lane_ids;
        ] );
      ( "presence",
        [
          test_case "dashboard always present" `Quick
            test_dashboard_always_present;
          test_case "bound discord channel listed, offline without gateway"
            `Quick test_bound_discord_channel_listed_offline_without_gateway;
          test_case "bound_channels blank keeper" `Quick
            test_bound_channels_blank_keeper_is_empty;
          test_case "discord not connected without run loop" `Quick
            test_discord_not_connected_without_run_loop;
        ] );
    ]
