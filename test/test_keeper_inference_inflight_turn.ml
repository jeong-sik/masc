(* The operator snapshot's [inference_inflight.active] is the number of
   Keeper provider attempts inside AGENT_CORE right now. The proof drives a
   turn through [Keeper_turn_driver.run_named] against a loopback provider
   and reads the snapshot payload at the moment the provider holds the
   request, then again after the turn ended. Until 2026-11-14 nothing on the
   turn path entered the observation, so the payload read 0 at both points
   (#49820). *)
open Alcotest
open Masc

let write path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel content)
;;

let rec remove path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let snapshot_active () =
  Yojson.Safe.Util.(
    Inference_inflight_observation.snapshot_json () |> member "active" |> to_int)
;;

(* Run one turn against [behavior] and return its result, the snapshot's
   [active] as read while the provider held each request, and the number of
   requests the provider received. *)
let run_turn_against ~label behavior =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let base_path = Filename.temp_dir ("keeper-inference-inflight-" ^ label ^ "-") "" in
  Config_boot_overrides.reset_for_tests ();
  Keeper_runtime_resolved.reset_for_tests ();
  Inference_inflight_observation.For_testing.reset ();
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    Config_boot_overrides.reset_for_tests ();
    Keeper_runtime_resolved.reset_for_tests ();
    remove base_path);
  let active_while_provider_held_request = ref [] in
  let server =
    Exact_output_fixture.start_server
      ~on_request_before_reply:(fun () ->
        active_while_provider_held_request
        := snapshot_active () :: !active_while_provider_held_request)
      ~sw
      ~net:env#net
      ~clock:env#clock
      behavior
  in
  let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname config_path);
  write
    config_path
    (Printf.sprintf
       {|[runtime]
default = "listener.sample"
[providers.listener]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = "listener-model"
max-context = 200000
[listener.sample]
|}
       server.Exact_output_fixture.base_url);
  (match Runtime.init_default ~config_path with
   | Ok () -> ()
   | Error detail -> fail detail);
  check int "nothing is in flight before the turn" 0 (snapshot_active ());
  let result =
    Eio.Time.with_timeout_exn env#clock Exact_output_fixture.fixture_wait_seconds (fun () ->
      Keeper_turn_driver.run_named
        ~input_source:(Keeper_request_source.Keeper_history { trace_id = label })
        ~raw_trace:None
        ~walk_owner:Keeper_turn_driver.One_shot_walk
        ~system_prompt:"Inference inflight proof."
        ~runtime_id:"listener.sample"
        ~keeper_name:label
        ~base_path
        ~media_store:(Tool_blob_media_store.of_base_path ~base_path)
        ~agent_core_tools:[]
        ~goal:"answer once"
        ~sw
        ~net:env#net
        ())
  in
  result, List.rev !active_while_provider_held_request, Exact_output_fixture.post_count server
;;

let check_every_held_request_was_counted ~posts observed =
  check bool "the request reached the provider" true (posts >= 1);
  check
    (list int)
    "the snapshot counts the turn while the provider holds its request"
    (List.init posts (fun _ -> 1))
    observed
;;

let test_an_answered_turn_is_counted_while_it_runs () =
  let result, observed, posts =
    run_turn_against
      ~label:"inflight-answered"
      (Exact_output_fixture.Reply
         (Exact_output_fixture.openai_response (`Assoc [ "answer", `String "done" ])))
  in
  (match result with
   | Ok _ -> ()
   | Error error -> failf "expected an answered turn, got %s" (Agent_core.Error.to_string error));
  check_every_held_request_was_counted ~posts observed;
  check int "nothing is in flight after the answer" 0 (snapshot_active ())
;;

let test_a_refused_turn_leaves_nothing_counted () =
  let result, observed, posts =
    run_turn_against
      ~label:"inflight-refused"
      (Exact_output_fixture.Reply_with
         (fun _ _ ->
            `Bad_request, {|{"error":{"message":"refused","type":"invalid_request_error"}}|}))
  in
  check bool "the provider's refusal ends the turn" true (Result.is_error result);
  check_every_held_request_was_counted ~posts observed;
  check int "nothing is in flight after the refusal" 0 (snapshot_active ())
;;

let () =
  Alcotest.run
    "keeper_inference_inflight_turn"
    [ ( "run_named"
      , [ test_case
            "a turn is counted while the provider holds its request"
            `Quick
            test_an_answered_turn_is_counted_while_it_runs
        ; test_case
            "a refused turn leaves nothing counted"
            `Quick
            test_a_refused_turn_leaves_nothing_counted
        ] )
    ]
;;
