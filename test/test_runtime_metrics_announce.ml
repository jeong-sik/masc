(* The runtime history is announced as [runtime_metrics] when a Keeper
   decision row is written, when a cost ledger row lands in the server's own
   workspace, and when a row the history keeps leaves its window. *)

open Alcotest
open Masc

let settle () =
  for _ = 1 to 5 do
    Eio.Fiber.yield ()
  done

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)

let decision_row ~ts =
  `Assoc
    [ "ts_unix", `Float ts
    ; "provider_context", `Assoc [ "executed_runtime_id", `String "account.model" ]
    ; "telemetry", `Assoc [ "outcome", `String "success" ]
    ]

let test_writes_and_leaving_rows_announce () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "runtime-metrics-announce-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    ignore (Workspace.init config ~agent_name:None);
    mkdir_p (Common.keepers_runtime_dir_of_base ~base_path);
    let heard = ref 0 in
    let id = "runtime-metrics-announce" in
    let name = Workspace_dataset_event.dataset_name Workspace_dataset_event.Runtime_metrics in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (event : Sse.external_event) ->
        match
          ( Json_util.assoc_string_opt "type" event.ext_payload
          , Json_util.assoc_string_opt "dataset" event.ext_payload )
        with
        | Some kind, Some dataset
          when String.equal kind Workspace_dataset_event.event_type
               && String.equal dataset name -> incr heard
        | (Some _ | None), (Some _ | None) -> ())
      ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      let now = Unix.gettimeofday () in
      let window_s = Float.of_int Server_runtime_metrics.window_minutes *. 60.0 in
      Keeper_types_support.append_decision_record config "alpha"
        (decision_row ~ts:(now -. window_s +. 100.0));
      check int "a decision row is announced" 1 !heard;
      let clock = Eio_mock.Clock.make () in
      Eio_mock.Clock.set_time clock now;
      Eio.Fiber.first
        (fun () ->
          Eio.Switch.run (fun sw ->
            Server_runtime_metrics.install ~sw ~clock ~config;
            Eio.Fiber.await_cancel ()))
        (fun () ->
          settle ();
          Cost_ledger_row_signal.appended
            ~masc_root:(Common.masc_dir_from_base_path ~base_path);
          check int "a cost row in this workspace is announced" 2 !heard;
          Cost_ledger_row_signal.appended ~masc_root:"/elsewhere/.masc";
          check int "a cost row in another workspace is not" 2 !heard;
          (* A read keeps the decision row; the watcher then sleeps until it
             leaves the window. *)
          ignore (Server_runtime_metrics.read ~base_path ~now);
          settle ();
          check int "a read announces nothing" 2 !heard;
          Eio_mock.Clock.advance clock;
          settle ();
          check int "the kept row leaving the window is announced" 3 !heard)))

let () =
  run "runtime_metrics_announce"
    [ ( "announce"
      , [ test_case "writes and leaving rows announce" `Quick
            test_writes_and_leaving_rows_announce
        ] )
    ]
