(* test_connector_reactive_wake_throttle.ml —
   RFC-connector-ambient-attention-wake P4.

   The ambient-connector wake is gated by
   Keeper_keepalive_signal.connector_reactive_wakeup_allowed, which reuses the
   board-reactive primitive (RFC-0246 tombstone gate + per-key debounce) with a
   per-channel dedup key. This pins the throttle: a chatty channel wakes the
   keeper at most once per debounce window, while a different channel debounces
   independently (so distinct conversations are not collapsed). *)

open Alcotest
open Masc

let rm_rf path =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote path)))

let make_meta ~name ~agent_name =
  let json =
    `Assoc
      [ ("name", `String name)
      ; ("agent_name", `String agent_name)
      ; ("trace_id", `String ("trace-" ^ name))
      ; ("goal", `String "connector reactive wake throttle test")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta failed: " ^ err)

let test_per_channel_debounce () =
  let base_path = Filename.temp_dir "connector-throttle" "" in
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      ignore (Workspace.init config ~agent_name:None : string);
      let keeper_name = "throttle-keeper" in
      let meta = make_meta ~name:keeper_name ~agent_name:"throttle-keeper-agent" in
      ignore (Keeper_registry.register ~base_path keeper_name meta);
      Fun.protect
        ~finally:(fun () -> Keeper_registry.unregister ~base_path keeper_name)
        (fun () ->
          let allowed channel_id =
            Keeper_keepalive_signal.connector_reactive_wakeup_allowed ~base_path
              ~keeper_name ~channel_id
          in
          check bool "first ambient wake on a channel is allowed" true
            (allowed "chan-1");
          check bool "immediate second wake on the same channel is debounced"
            false (allowed "chan-1");
          check bool "a different channel debounces independently" true
            (allowed "chan-2");
          check bool "the second channel then debounces too" false
            (allowed "chan-2")))

let () =
  run "connector_reactive_wake_throttle"
    [ ( "throttle",
        [ test_case "per-channel debounce" `Quick test_per_channel_debounce ] )
    ]
