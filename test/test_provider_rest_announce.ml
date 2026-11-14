(* RFC-0481 §3.2: a provider rest record tells the workspace's roster readers
   which Keepers' shown rest moved, and only those. A record that changes a
   runtime's standing in the resolved document announces that standing, and a
   record that changes nothing announces nothing. *)

open Alcotest
open Masc

let runtime_toml =
  {|
[runtime]
default = "p.m1"

[providers.p]
display-name = "P"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.m1]
api-name = "m1"
max-context = 8192
tools-support = true
streaming = true

[p.m1]
is-default = true
max-concurrent = 1
|}
;;

(* Long enough for the fiber to wake on an idle machine. *)
let signal_wait_s = 5.0

(* Long enough that a rest noted in the test does not end during it. *)
let rest_retry_after_s = 3600.0

(* How long the test listens to show that a record moved nothing. *)
let quiet_wait_s = 0.5

let test_the_seven_writers_report_a_record () =
  let calls = ref 0 in
  Runtime_path_rest_signal.install (fun () -> incr calls);
  Fun.protect ~finally:(fun () -> Runtime_path_rest_signal.install ignore) (fun () ->
    let candidate =
      Runtime_candidate_backpressure.create_candidate
        ~binding:Runtime_candidate_backpressure.Official_client_binding
    in
    Runtime_candidate_backpressure.note_rate_limit ~candidate ~retry_after:(Some rest_retry_after_s);
    Runtime_candidate_backpressure.note_failed_attempt ~candidate
      ~failure:Runtime_candidate_backpressure.Server_error
      ~recorded_by:(Runtime_candidate_backpressure.keeper_recorder ~keeper_name:"alpha");
    Runtime_candidate_backpressure.note_candidate_success ~candidate;
    let scope = Runtime_quota_window.scope_of_muse_home "provider-rest-announce" in
    Runtime_quota_window.note_observed_exhausted ~source:Runtime_quota_window.Provider_quota_refused ~scope;
    Runtime_quota_window.note_read_without_reset ~scope;
    Runtime_quota_window.note_succeeded ~scope;
    Runtime_quota_window.note_exhausted ~source:Runtime_quota_window.Provider_quota_refused ~scope ~resets_at:(Unix.gettimeofday () +. rest_retry_after_s);
    check int "each write reports once" 7 !calls)
;;

let test_moved_rests_announce_their_keepers () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  let base_path = Unix.realpath (Filename.temp_dir "provider-rest-announce-" "") in
  let original = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore original;
      Runtime_path_rest_signal.install ignore;
      Keeper_registry.For_testing.clear ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      let path = Filename.concat base_path "runtime.toml" in
      Out_channel.with_open_bin path (fun oc -> output_string oc runtime_toml);
      (match Runtime.init_default ~config_path:path with
       | Ok () -> ()
       | Error error -> failf "runtime.toml did not load: %s" error);
      let config = Workspace.default_config base_path in
      ignore (Workspace.init config ~agent_name:None);
      (match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String "alpha" ]) with
       | Ok meta -> ignore (Keeper_registry.For_testing.register ~base_path "alpha" meta)
       | Error error -> failf "meta fixture: %s" error);
      let candidate =
        match Runtime.get_runtime_by_id "p.m1" with
        | Some (runtime : Runtime_instance.t) -> runtime.candidate_backpressure
        | None -> fail "the default runtime is not loaded"
      in
      let heard = Eio.Stream.create max_int in
      let standings = Eio.Stream.create max_int in
      let id = "provider-rest-announce" in
      let standing_name =
        Workspace_dataset_event.dataset_to_wire Workspace_dataset_event.Provider_standing
      in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          match
            Json_util.assoc_string_opt "type" event.ext_payload,
            Json_util.assoc_string_opt "name" event.ext_payload,
            Json_util.assoc_string_opt "dataset" event.ext_payload
          with
          | Some kind, Some name, _ when String.equal kind Keeper_row_broadcast.row_changed_event ->
            Eio.Stream.add heard name
          | Some kind, _, Some dataset
            when String.equal kind Workspace_dataset_event.event_type
                 && String.equal dataset standing_name ->
            Eio.Stream.add standings ()
          | (Some _ | None), (Some _ | None), (Some _ | None) -> ())
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        Eio.Switch.run @@ fun sw ->
        Server_provider_rest_broadcast.install ~sw ~clock ~config;
        let expect_row label =
          match Eio.Time.with_timeout clock signal_wait_s (fun () -> Ok (Eio.Stream.take heard)) with
          | Ok name -> check string label "alpha" name
          | Error `Timeout -> failf "%s: no row signal" label
        in
        let expect_standing label =
          match Eio.Time.with_timeout clock signal_wait_s (fun () -> Ok (Eio.Stream.take standings)) with
          | Ok () -> ()
          | Error `Timeout -> failf "%s: no standing announced" label
        in
        Runtime_candidate_backpressure.note_rate_limit ~candidate
          ~retry_after:(Some rest_retry_after_s);
        expect_row "a rate limit rests the Keeper's walk";
        expect_standing "a rate limit changes the runtime's standing";
        Runtime_candidate_backpressure.note_failed_attempt ~candidate
          ~failure:Runtime_candidate_backpressure.Server_error
          ~recorded_by:(Runtime_candidate_backpressure.keeper_recorder ~keeper_name:"alpha");
        Runtime_candidate_backpressure.note_candidate_success ~candidate;
        expect_row "a success ends the rest";
        Runtime_candidate_backpressure.note_failed_attempt ~candidate
          ~failure:Runtime_candidate_backpressure.Server_error
          ~recorded_by:(Runtime_candidate_backpressure.keeper_recorder ~keeper_name:"alpha");
        (* A one-runtime walk keeps serving the same runtime after a failed
           attempt, so the shown rest does not move. *)
        (match Eio.Time.with_timeout clock quiet_wait_s (fun () -> Ok (Eio.Stream.take heard)) with
         | Ok name -> failf "a record that moves nothing announced %s" name
         | Error `Timeout -> ());
        (* Every standing announced so far is taken; a signal that changed no
           record leaves the standing as it was. *)
        let rec drain () =
          match Eio.Stream.take_nonblocking standings with
          | Some () -> drain ()
          | None -> ()
        in
        drain ();
        Runtime_path_rest_signal.recorded ();
        (match Eio.Time.with_timeout clock quiet_wait_s (fun () -> Ok (Eio.Stream.take standings)) with
         | Ok () -> fail "a signal that changed no standing announced one"
         | Error `Timeout -> ())))
;;

(* A quota observation without a reset stops showing the runtime exhausted
   at its fallback cap, and nothing is written then. The time the runtime
   document names for its next change must be that end, or the loop sleeps
   past it and the Usage view keeps the stale standing. *)
let test_an_observation_without_a_reset_names_its_end_as_the_next_change () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "provider-rest-standing-" "") in
  let original = Runtime.For_testing.snapshot () in
  Runtime_quota_window.reset_for_testing ();
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore original;
      Runtime_quota_window.reset_for_testing ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      let path = Filename.concat base_path "runtime.toml" in
      Out_channel.with_open_bin path (fun oc -> output_string oc runtime_toml);
      (match Runtime.init_default ~config_path:path with
       | Ok () -> ()
       | Error error -> failf "runtime.toml did not load: %s" error);
      let runtime =
        match Runtime.get_runtime_by_id "p.m1" with
        | Some (runtime : Runtime_instance.t) -> runtime
        | None -> fail "the default runtime is not loaded"
      in
      (* A rate limit an earlier case left would name its own end first. *)
      Runtime_candidate_backpressure.note_candidate_success
        ~candidate:runtime.candidate_backpressure;
      let scope = Runtime_instance.quota_scope_of_runtime runtime in
      Runtime_quota_window.note_observed_exhausted ~source:Runtime_quota_window.Provider_quota_refused ~scope;
      let now = Unix.gettimeofday () in
      match Runtime_quota_window.rest ~scope ~now with
      | Some (Runtime_quota_window.Observed_until ends_at) ->
        check (option (float 0.0)) "the next change is the observation's end" (Some ends_at)
          (Server_dashboard_runtime_resolved_json.next_standing_change_at ~now)
      | Some (Runtime_quota_window.Reset_stated _) | None ->
        fail "an observation without a reset rests until its fallback cap")
;;

let () =
  run "provider_rest_announce"
    [ ( "records"
      , [ test_case "the seven writers report a record" `Quick
            test_the_seven_writers_report_a_record ] )
    ; ( "rows"
      , [ test_case "moved rests announce their Keepers" `Quick
            test_moved_rests_announce_their_keepers ] )
    ; ( "standing"
      , [ test_case "an observation without a reset names its end as the next change" `Quick
            test_an_observation_without_a_reset_names_its_end_as_the_next_change ] )
    ]
;;
