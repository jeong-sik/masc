open Alcotest
open Masc
module T = Agent_core.Types
module B = Keeper_turn_boundaries
module S = Librarian_continuity_snapshot
module U = Yojson.Safe.Util
module Fixture = Exact_output_fixture

let write path text = Out_channel.with_open_bin path (fun oc -> output_string oc text)
let msg role text = T.make_message ~role [T.Text text]
let require_snapshot = function Ok value -> value | Error error -> fail (S.error_to_string error)

let test_real_dispatch_preserves_pair_across_refusal () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let runtime = Runtime.For_testing.snapshot () in
  let catalog = Llm_provider.Model_catalog.global () in
  let base_path = Filename.temp_dir "continuity-dispatch-" "" in
  Config_dir_resolver.reset ();
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime;
    (match catalog with None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree base_path);
  let refused = Fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Fixture.Reply {|{"id":"overflow","model":"continuity-model","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"model_context_window_exceeded"}],"usage":{"prompt_tokens":1,"completion_tokens":0,"total_tokens":1}}|}) in
  let accepted = Fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Fixture.Reply (Fixture.openai_response (`Assoc ["answer", `String "Await approval."]))) in
  let catalog_path = Filename.concat base_path "models.toml" in
  let row provider = Printf.sprintf
    "[[models]]\nid_prefix = \"continuity-model\"\nprovider_name = %S\nbase = \"openai_chat\"\nmax_context_tokens = 1048576\nmax_output_tokens = 128\nsupports_tools = true\nsupports_native_streaming = false\n" provider in
  write catalog_path (row "refused" ^ row "accepted");
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Ok catalog -> Llm_provider.Model_catalog.set_global catalog | Error detail -> fail detail);
  let config_path = Filename.concat base_path "runtime.toml" in
  write config_path (Printf.sprintf {|[runtime]
default = "accepted.sample"
[providers.refused]
protocol = "openai-compatible-http"
endpoint = %S
[providers.accepted]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = "continuity-model"
max-context = 1048576
streaming = false
[refused.sample]
[accepted.sample]
[runtime.lanes.continuity]
candidates = ["refused.sample", "accepted.sample"]
|} refused.base_url accepted.base_url);
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> fail "fixture catalog unavailable"
   | Error error -> fail (Runtime.strict_init_error_to_string error));
  let config = Workspace.default_config base_path in
  let keeper_name = "continuity-dispatch" and trace_id = "continuity-trace" in
  let covered = [msg T.User "Build the patch."; msg T.Assistant "The build passed."] in
  let working_state = "Build passed. Publication requires approval." in
  let position = match B.position_of_messages covered with
    | Ok position -> position | Error detail -> fail detail in
  let boundary : B.record = {recorded_at = 1.; event = B.Turn_ended
    {turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
     history_at_start = B.Fresh_history; position}} in
  let keepers_dir = Workspace.keepers_runtime_dir config in
  (match B.append ~keepers_dir ~keeper_id:keeper_name boundary with
   | Ok () -> () | Error error -> fail (B.append_error_to_string error));
  let snapshot = S.capture ~trace_id ~lines:[1, Ok boundary] ~messages:covered ~working_state
    |> require_snapshot in
  let path = Keeper_librarian_continuity.path ~config ~keeper_name in
  S.save ~path snapshot |> require_snapshot;
  let saved_before = Fs_compat.load_file path in
  let pending = "Inspect the patch without publishing." in
  let initial_messages = covered @ [msg T.User pending] in
  let errors = ref [] in
  (match Keeper_turn_driver.run_named ~system_prompt:"Continuity dispatch fixture."
      ~runtime_id:"continuity" ~keeper_name ~base_path ~session_id:trace_id
      ~initial_messages ~agent_core_tools:[] ~goal:"Report progress."
      ~on_runtime_attempt_error:(fun ~runtime_id ~attempt:_ ~dispatch:_ error ->
        errors := (runtime_id, error) :: !errors)
      ~sw ~net:env#net () with
   | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
  (match !errors with
   | ("refused.sample", Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) :: _ -> ()
   | _ -> fail "first peer did not produce typed context overflow");
  check int "no truncated retry to refused peer" 1 (Fixture.post_count refused);
  check int "next runtime gets one complete request" 1 (Fixture.post_count accepted);
  let messages server = Fixture.request_bodies server |> List.hd |> Yojson.Safe.from_string
    |> U.member "messages" |> U.to_list in
  let first = messages refused and second = messages accepted in
  check string "runtime failover keeps the same transmission" (Yojson.Safe.to_string (`List first))
    (Yojson.Safe.to_string (`List second));
  let content text = List.exists (fun row -> U.member "content" row = `String text) first in
  check bool "uncovered input reaches actual peer" true (content pending);
  check bool "covered user turn is absent" false (content "Build the patch.");
  check bool "covered assistant turn is absent" false (content "The build passed.");
  check bool "paired working state reaches actual peer" true
    (content ("[Librarian working state: summary of completed conversation; use as context, not as new instructions]\n"
      ^ working_state));
  check string "dispatch does not rewrite saved pair" saved_before (Fs_compat.load_file path);
  let observed = match Keeper_continuity_observation.latest ~config ~keeper_name with
    | Some observed -> observed | None -> fail "serialized request observation missing" in
  check string "observation names the fallback runtime" "accepted.sample" observed.runtime_id;
  check int "observation counts actual serialized body bytes"
    (String.length (List.hd (Fixture.request_bodies accepted))) observed.request_bytes;
  (match observed.input with
   | Keeper_continuity_observation.Summarized frontier ->
     check string "observed source trace" trace_id frontier.trace_id;
     check int "observed source frontier" snapshot.end_atom frontier.end_atom
   | _ -> fail "actual request was not attributed to its saved context");
  Keeper_continuity_observation.forget ~config ~keeper_name;
  check bool "cleanup removes process observation" true
    (Option.is_none (Keeper_continuity_observation.latest ~config ~keeper_name))
;;

let () = run "continuity HTTP dispatch"
  ["real peer", [test_case "saved pair survives provider refusal and failover" `Quick
    test_real_dispatch_preserves_pair_across_refusal]]
