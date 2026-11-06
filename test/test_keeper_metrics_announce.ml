(* RFC-0480 §3.4: a row appended to a Keeper's metrics ledger tells its
   workspace's readers which Keeper's ledger moved. *)

open Alcotest
open Masc

let test_metrics_appends_announce_their_keeper () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "keeper-metrics-announce-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    ignore (Workspace.init config ~agent_name:None);
    let heard = ref [] in
    let id = "keeper-metrics-announce" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (event : Sse.external_event) ->
        match event.ext_payload with
        | `Assoc fields
          when Option.equal String.equal
                 (Json_util.assoc_string_opt "type" event.ext_payload)
                 (Some Workspace_dataset_event.event_type) ->
          (match Workspace_dataset_event.of_fields fields with
           | Ok (Workspace_dataset_event.Keeper_metrics { keeper }) -> heard := keeper :: !heard
           | Ok _ | Error _ -> ())
        | _ -> ())
      ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      Keeper_types_support.append_keeper_metrics config "alpha"
        (`Assoc [ "ts_unix", `Float 1.0 ]);
      check (list string) "the append names its Keeper" [ "alpha" ] !heard;
      Keeper_types_support.append_keeper_metrics config "beta"
        (`Assoc [ "ts_unix", `Float 2.0 ]);
      check (list string) "each append names its own Keeper" [ "beta"; "alpha" ] !heard))
;;

let () =
  run "keeper_metrics_announce"
    [ ( "ledger"
      , [ test_case "appends announce their Keeper" `Quick
            test_metrics_appends_announce_their_keeper ] )
    ]
;;
