(* Uses the actual durable store and all three adapters, then the production
   terminal, registry, heartbeat projection and public blocker projection.
   No client process/provider is called. This does not execute the full loop. *)
open Masc
module S = Keeper_official_client_session_store
module R = Keeper_registry
module Route = Keeper_runtime_failure_route
module I = Keeper_internal_error

let ok = function Ok value -> value | Error detail -> Alcotest.fail detail

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let run_adapter client_kind ~base_path ~keeper_name ~runtime_id ~cli_path =
  let transmitted _ = Alcotest.fail "claim rejection transmitted model input" in
  match client_kind with
  | S.Codex ->
    let config : Runtime_execution.codex_app_server =
      { cli_path; model = None; timeout_s = 1. } in
    let outcome = Keeper_codex_runtime.run
        ~accepts_image_input:false ~runtime_id ~keeper_name
        ~pre_tool_rejects:(ref []) ~base_path ~goal:"synthetic claim probe"
        ~goal_blocks:None ~system_prompt:"Synthetic claim probe."
        ~tools:[] ~initial_messages:[] ~model_input_projection:None
        ~on_transmitted_model_input:transmitted ~hooks:None
        ~context_injector:None ~context:None ~event_bus:None
        ~raw_trace:None ~on_event:None ~config () in
    outcome.result, outcome.settled_session, outcome.effect_disposition
  | S.Claude_code ->
    let config : Runtime_execution.claude_code =
      { cli_path; model = None; timeout_s = 1. } in
    let outcome = Keeper_claude_code_runtime.run
        ~accepts_image_input:false ~runtime_id ~keeper_name
        ~pre_tool_rejects:(ref []) ~base_path ~goal:"synthetic claim probe"
        ~goal_blocks:None ~system_prompt:"Synthetic claim probe."
        ~tools:[] ~initial_messages:[] ~model_input_projection:None
        ~on_transmitted_model_input:transmitted ~hooks:None
        ~context_injector:None ~context:None ~event_bus:None
        ~raw_trace:None ~on_event:None ~config () in
    outcome.result, outcome.settled_session, outcome.effect_disposition
  | S.Antigravity ->
    let config : Runtime_execution.antigravity_cli =
      { cli_path; model = "synthetic-model"; agent = None; effort = None
      ; oauth_source = Filename.concat base_path "absent-synthetic-oauth"
      ; timeout_s = 1.; add_dirs = [] } in
    let outcome = Keeper_antigravity_runtime.run
        ~accepts_image_input:false ~runtime_id ~keeper_name
        ~pre_tool_rejects:(ref []) ~base_path ~goal:"synthetic claim probe"
        ~goal_blocks:None ~system_prompt:"Synthetic claim probe."
        ~tools:[] ~initial_messages:[] ~model_input_projection:None
        ~on_transmitted_model_input:transmitted ~hooks:None
        ~context_injector:None ~context:None ~event_bus:None
        ~raw_trace:None ~on_event:None ~config () in
    outcome.result, outcome.settled_session, outcome.effect_disposition

let read_recovery ~base_path ~keeper_name =
  match S.load ~base_path ~keeper_name with
  | Ok (Some { phase = S.Recovery_required recovery; _ }) -> recovery
  | Ok _ -> Alcotest.fail "durable recovery missing"
  | Error detail -> Alcotest.fail detail

let check_preserved ~base_path ~keeper_name ~expected error =
  let raw_error = Agent_core.Error.to_string error in
  let internal = I.Official_client_recovery_required expected in
  Alcotest.(check bool) "typed adapter payload" true
    (I.classify_masc_internal_error error = Some internal);
  let terminal = Keeper_turn_terminal.of_failure ~raw_error error in
  Alcotest.(check string) "terminal identifies local session recovery"
    "official_client_recovery_required" (Keeper_turn_terminal.code terminal);
  Alcotest.(check string) "terminal retains recovery identity"
    (I.official_client_recovery_summary expected) terminal.summary;
  (match Route.route_of_error ~boundary:Route.Masc_execution error with
   | Route.Exhausted_visible_alive
       { terminal = Route.Contract_violation; provenance = Route.Masc_internal_error; _ } -> ()
   | _ -> Alcotest.fail "local refusal must not rotate, retry or claim a remote effect");
  let reason = Keeper_unified_turn_types.registry_failure_reason_of_terminal_reason
      ~core_error:error terminal ~raw_error in
  Alcotest.(check bool) "registry receives same typed payload" true
    (reason = Some (R.Official_client_recovery_required expected));
  let meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String keeper_name; "trace_id", `String "synthetic-trace"])
    |> ok in
  ignore (R.For_testing.register ~base_path keeper_name meta : R.registry_entry);
  Fun.protect
    ~finally:(fun () -> R.For_testing.unregister ~base_path keeper_name)
    (fun () ->
      Keeper_unified_turn_failure.record_failure_observation
        ~config:(Workspace.default_config base_path) ~meta ~terminal_reason:terminal
        ~err:error ~error_text:raw_error;
      let count = R.get_turn_failures ~base_path keeper_name in
      Keeper_heartbeat_loop.refresh_failure_reason_after_turn
        ~base_path ~keeper_name ~turn_fail_count:count;
      (match R.get ~base_path keeper_name with
       | Some { last_failure_reason = Some (R.Official_client_recovery_required payload as observed); _ } ->
         Alcotest.(check bool) "heartbeat retains typed claim refusal" true (payload = expected);
         let public =
           match Keeper_status_bridge.runtime_blocker_surface_of_failure_reason observed with
           | Some surface ->
             Alcotest.(check string) "public local recovery class"
               "official_client_recovery_required" surface.blocker_class;
             Alcotest.(check string) "public recovery identity"
               (I.official_client_recovery_summary expected) surface.summary;
             `Assoc
               [ "runtime_blocker_class", `String surface.blocker_class
               ; "runtime_blocker_summary", `String surface.summary ]
           | None -> Alcotest.fail "registry failure has no public blocker"
         in
         Printf.printf "CLAIM_CAUSE_PROJECTION %s\n%!"
           (Yojson.Safe.to_string (`Assoc
              [ "keeper", `String keeper_name
              ; "cause", I.masc_internal_error_to_json internal
              ; "terminal", Keeper_turn_terminal.to_json terminal
              ; "public_status_fields", public ]))
       | _ -> Alcotest.fail "registry lost local recovery cause");
      (* The existing successful-turn reset owns clearing this observation. *)
      Alcotest.(check bool) "successful-turn reset committed" true
        (Keeper_turn_failure_streak.reset ~base_path ~keeper_name);
      match R.get ~base_path keeper_name with
      | Some entry ->
        Alcotest.(check bool) "successful turn clears current cause" true
          (Option.is_none entry.last_failure_reason)
      | None -> Alcotest.fail "registry entry disappeared")

let check_case client_kind label reason () =
  let base_path = Filename.temp_dir "official-claim-cause-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let keeper_name = "claim-probe-" ^ label in
    let runtime_id = "claim-probe." ^ label in
    let marker = Filename.concat base_path "unexpected-cli-invocation" in
    let cli_path = Filename.concat base_path "never-run-client.sh" in
    write_file cli_path
      ("#!/bin/sh\n: > " ^ Filename.quote marker ^ "\nexit 97\n");
    Unix.chmod cli_path 0o700;
    let expected = S.claim ~base_path ~keeper_name ~expected:None ~client_kind
        ~owner_epoch:(S.process_epoch ()) ~runtime_id
        ~tool_surface_sha256:(S.tool_surface_sha256
          ~native_posture:Runtime_native_tools.Native_read []) ~updated_at:1. |> ok in
    ignore (S.require_recovery ~base_path ~keeper_name ~expected
      ~failure:(S.Input_rejected reason) ~detail:"synthetic rejected input"
      ~required_at:2. |> ok : S.t);
    let before = read_recovery ~base_path ~keeper_name in
    Alcotest.(check bool) "store preserves typed rejection" true
      (before.failure = S.Input_rejected reason);
    let path = S.path ~base_path ~keeper_name |> ok in
    let bytes_before = read_file path in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
          (fun () ->
            (* Inside the scope so with_test_env restores the old env too. *)
            Eio_context.set_env env;
            let result, settled, observed_effect =
              run_adapter client_kind ~base_path ~keeper_name ~runtime_id ~cli_path in
            Alcotest.(check bool) "no client process spawned" false (Sys.file_exists marker);
            Alcotest.(check bool) "no settlement" true (Option.is_none settled);
            Alcotest.(check bool) "no effect" true
              (observed_effect = Keeper_provider_attempt_effect.No_effect_observed);
            let error = match result with
              | Error error -> error
              | Ok _ -> Alcotest.fail "claim rejection unexpectedly succeeded" in
            let expected : I.official_client_recovery =
              { runtime_id; recovery_id = before.recovery_id; reason } in
            check_preserved ~base_path ~keeper_name ~expected error;
            Printf.printf "%s/%s => %s\n%!" label
              (S.recovery_failure_to_string (S.Input_rejected reason))
              (Agent_core.Error.to_string error))));
    let after = read_recovery ~base_path ~keeper_name in
    Alcotest.(check string) "durable recovery id preserved" before.recovery_id after.recovery_id;
    Alcotest.(check bool) "durable typed rejection preserved" true
      (after.failure = S.Input_rejected reason);
    Alcotest.(check string) "claim rejection leaves session bytes untouched"
      bytes_before (read_file path))

let check_codec () =
  let cause = I.Official_client_recovery_required
      { runtime_id = "synthetic-runtime"; recovery_id = "synthetic-recovery"; reason = I.Effect_fenced } in
  let json = I.masc_internal_error_to_json cause in
  Alcotest.(check bool) "codec preserves local cause" true
    (I.parse_masc_internal_error_json json = Some cause);
  let fields = match json with `Assoc fields -> fields | _ -> assert false in
  let rejected label fields =
    Alcotest.(check bool) label true
      (Option.is_none (I.parse_masc_internal_error_json (`Assoc fields))) in
  rejected "missing recovery id rejected" (List.remove_assoc "recovery_id" fields);
  rejected "empty recovery id rejected" (("recovery_id", `String "") :: List.remove_assoc "recovery_id" fields);
  rejected "unknown reason rejected" (("reason", `String "new_reason") :: List.remove_assoc "reason" fields);
  rejected "extra field rejected" (("detail", `String "not part of contract") :: fields);
  rejected "duplicate field rejected" (("recovery_id", `String "other") :: fields)

let check_remote_fence () =
  let cause = I.Provider_attempt_effect_fenced
      { runtime_id = "synthetic-runtime"
      ; effect_disposition = Keeper_provider_attempt_effect_core.Effect_attempted
      ; cause = I.Fenced_masc (I.Internal_contract_rejected { reason = "synthetic" }) } in
  let error = I.core_error_of_masc_internal_error cause in
  Alcotest.(check bool) "remote fence keeps its existing typed cause" true
    (I.classify_masc_internal_error error = Some cause);
  match Route.route_of_error ~boundary:Route.Masc_execution error with
  | Route.Exhausted_visible_alive
      { terminal = Route.Provider_attempt_effect_fenced Route.Fenced_effect_attempted; _ } -> ()
  | _ -> Alcotest.fail "remote attempt fence was conflated with local claim refusal"

let () =
  Alcotest.run "official-client claim cause"
    [ "typed contract", [ Alcotest.test_case "strict codec" `Quick check_codec
                        ; Alcotest.test_case "remote fence stays distinct" `Quick check_remote_fence ]
    ; "actual adapters",
      List.concat_map (fun (client_kind, label) ->
        List.map (fun (reason, suffix) ->
          Alcotest.test_case (label ^ "/" ^ suffix) `Quick
            (check_case client_kind label reason))
          [ S.Effect_fenced, "effect-fenced"
          ; S.Bootstrap_floor_exceeded, "bootstrap-floor" ])
        [ S.Codex, "codex"; S.Claude_code, "claude"; S.Antigravity, "antigravity" ] ]
