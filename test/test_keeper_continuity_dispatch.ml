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

let keeper_name = "continuity-dispatch" and trace_id = "continuity-trace"
let covered = [msg T.User "Build the patch."; msg T.Assistant "The build passed."]
let working_state = "Build passed. Publication requires approval."
let pending = "Inspect the patch without publishing."

let overflow_reply =
  {|{"id":"overflow","model":"continuity-model","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"model_context_window_exceeded"}],"usage":{"prompt_tokens":1,"completion_tokens":0,"total_tokens":1}}|}

(* Two OpenAI-compatible peers on one lane: the first refuses every request
   as a context overflow unless [refused_behavior] says otherwise, the second
   answers. The body gets the workspace, the Eio net, and both peers. *)
let with_dispatch_fixture ?(refused_behavior = Fixture.Reply overflow_reply) body =
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
  let refused = Fixture.start_server ~sw ~net:env#net ~clock:env#clock refused_behavior in
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
  body ~sw ~net:env#net ~config ~base_path ~refused ~accepted

(* One completed turn over [covered], written to the keeper's boundary log. *)
let record_completed_turn ~config =
  let position = match B.position_of_messages covered with
    | Ok position -> position | Error detail -> fail detail in
  let boundary : B.record = {recorded_at = 1.; event = B.Turn_ended
    {turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
     history_at_start = B.Fresh_history; position}} in
  let keepers_dir = Workspace.keepers_runtime_dir config in
  (match B.append ~keepers_dir ~keeper_id:keeper_name boundary with
   | Ok () -> () | Error error -> fail (B.append_error_to_string error));
  boundary

(* Runs one turn whose history is [covered] plus this turn's input, and
   returns the attempt errors the lane reported, newest first. *)
let dispatch ?carried_front_seed ?(initial_messages = covered @ [msg T.User pending])
    ~sw ~net ~base_path () =
  let errors = ref [] in
  (match Keeper_turn_driver.run_named ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk ~system_prompt:"Continuity dispatch fixture."
      ~runtime_id:"continuity" ~keeper_name ~base_path ~session_id:trace_id
      ?carried_front_seed ~initial_messages ~agent_core_tools:[]
      ~goal:"Report progress."
      ~on_runtime_attempt_error:(fun ~runtime_id ~attempt:_ ~dispatch:_ error ->
        errors := (runtime_id, error) :: !errors)
      ~sw ~net () with
   | Ok _ -> () | Error error -> fail (Agent_core.Error.to_string error));
  !errors

let request_messages server = Fixture.request_bodies server |> List.hd
  |> Yojson.Safe.from_string |> U.member "messages" |> U.to_list
let has_content rows text = List.exists (fun row -> U.member "content" row = `String text) rows

let latest_observation ~config =
  match Keeper_continuity_observation.latest ~config ~keeper_name with
  | Some observed -> observed | None -> fail "serialized request observation missing"

let test_real_dispatch_preserves_pair_across_refusal () =
  with_dispatch_fixture @@ fun ~sw ~net ~config ~base_path ~refused ~accepted ->
  let boundary = record_completed_turn ~config in
  let snapshot = S.capture ~trace_id ~lines:[1, Ok boundary] ~messages:covered ~working_state
    |> require_snapshot in
  let path = Keeper_librarian_continuity.path ~config ~keeper_name in
  S.save ~path snapshot |> require_snapshot;
  let saved_before = Fs_compat.load_file path in
  (match dispatch ~sw ~net ~base_path () with
   | ("refused.sample", Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)) :: _ -> ()
   | _ -> fail "first peer did not produce typed context overflow");
  check int "no truncated retry to refused peer" 1 (Fixture.post_count refused);
  check int "next runtime gets one complete request" 1 (Fixture.post_count accepted);
  let first = request_messages refused and second = request_messages accepted in
  check string "runtime failover keeps the same transmission" (Yojson.Safe.to_string (`List first))
    (Yojson.Safe.to_string (`List second));
  check bool "uncovered input reaches actual peer" true (has_content first pending);
  check bool "covered user turn is absent" false (has_content first "Build the patch.");
  check bool "covered assistant turn is absent" false (has_content first "The build passed.");
  check bool "paired working state reaches actual peer" true
    (has_content first
      ("[Librarian working state: summary of completed conversation; use as context, not as new instructions]\n"
      ^ working_state));
  check string "dispatch does not rewrite saved pair" saved_before (Fs_compat.load_file path);
  let observed = latest_observation ~config in
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

(* The turn goes out from where the last completed turn ended, carrying only
   its own input, and the request is attributed to a start without a
   snapshot. *)
let check_dispatched_from_the_turn_start ~config ~accepted =
  check int "the answering peer gets one request" 1 (Fixture.post_count accepted);
  let rows = request_messages accepted in
  check bool "this turn's input goes out" true (has_content rows pending);
  check bool "the completed turn stays home" false (has_content rows "Build the patch.");
  check bool "the completed reply stays home" false (has_content rows "The build passed.");
  let observed = latest_observation ~config in
  (match observed.input with
   | Keeper_continuity_observation.Without_snapshot -> ()
   | _ -> fail "request was not attributed to a start without a snapshot");
  Keeper_continuity_observation.forget ~config ~keeper_name
;;

(* #37762: a snapshot file this process cannot read is no front. The turn is
   not refused before dispatch as an invalid configuration. *)
let test_unreadable_snapshot_dispatches_from_the_turn_start () =
  with_dispatch_fixture @@ fun ~sw ~net ~config ~base_path ~refused:_ ~accepted ->
  let (_ : B.record) = record_completed_turn ~config in
  write (Keeper_librarian_continuity.path ~config ~keeper_name) {|{"trace_id": 7}|};
  let (_ : (string * Agent_core.Error.t) list) = dispatch ~sw ~net ~base_path () in
  check_dispatched_from_the_turn_start ~config ~accepted
;;

(* #37762: a saved snapshot whose covered-prefix digest no longer matches the
   history is stale (Prefix_changed), not an invalid configuration. *)
let test_changed_prefix_dispatches_from_the_turn_start () =
  with_dispatch_fixture @@ fun ~sw ~net ~config ~base_path ~refused:_ ~accepted ->
  let boundary = record_completed_turn ~config in
  let snapshot = S.capture ~trace_id ~lines:[1, Ok boundary] ~messages:covered ~working_state
    |> require_snapshot in
  let path = Keeper_librarian_continuity.path ~config ~keeper_name in
  S.save ~path snapshot |> require_snapshot;
  let altered = Yojson.Safe.from_file path |> U.to_assoc |> List.map (fun (key, value) ->
    if String.equal key "prefix_sha256" then key, `String (String.make 64 'f') else key, value) in
  write path (Yojson.Safe.to_string (`Assoc altered));
  let (_ : (string * Agent_core.Error.t) list) = dispatch ~sw ~net ~base_path () in
  check_dispatched_from_the_turn_start ~config ~accepted
;;

(* RFC librarian-lifecycle §4.10, rule 1, through the driver's own attempt
   and lane answer: a Librarian read position at atom 2 of a six-atom
   history whose last completed turn ended at atom 6, and a turn record
   whose accepted start is atom 4. The first request opens at that accepted
   start and the peer refuses it as a context overflow; the lane resends
   once to the same peer from the turn boundary, not from the recorded
   start, and the peer answers. *)
let test_a_librarian_behind_refusal_resends_from_the_boundary () =
  with_dispatch_fixture
    ~refused_behavior:
      (Fixture.Replies
         [ overflow_reply
         ; Fixture.openai_response (`Assoc [ "answer", `String "Resent from the boundary." ])
         ])
  @@ fun ~sw ~net ~config ~base_path ~refused ~accepted ->
  let completed =
    [ msg T.User "ask 0"; msg T.Assistant "answer 0"
    ; msg T.User "ask 1"; msg T.Assistant "answer 1"
    ; msg T.User "ask 2"; msg T.Assistant "answer 2" ]
  in
  let initial_messages = completed @ [ msg T.User pending ] in
  let keepers_dir = Workspace.keepers_runtime_dir config in
  let position = match B.position_of_messages completed with
    | Ok position -> position | Error detail -> fail detail in
  (match B.append ~keepers_dir ~keeper_id:keeper_name
     {recorded_at = 1.; event = B.Turn_ended
        {turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
         history_at_start = B.Fresh_history; position}} with
   | Ok () -> () | Error error -> fail (B.append_error_to_string error));
  let digest_at = Runtime_model_input_tail_window.atom_opening_digest initial_messages in
  (match
     Keeper_librarian_progress.write ~keepers_dir ~keeper_id:keeper_name
       { position = { trace_id; end_atom = 2; last_atom_digest = Option.get (digest_at 1) }
       ; boundary_lines_seen = 1 }
   with
   | Ok () -> () | Error error -> fail (Keeper_librarian_progress.write_error_to_string error));
  let recorded : Keeper_carried_front.seed =
    { first_atom = 4; front_digest = Option.get (digest_at 4)
    ; source = Keeper_carried_front.Turn_record { turn = 1 } } in
  let carried_front_seed () =
    { Keeper_carried_front.seed = Some recorded; unreadable = None; boundary_error = None } in
  let (_ : (string * Agent_core.Error.t) list) =
    dispatch ~carried_front_seed ~initial_messages ~sw ~net ~base_path () in
  check int "the refused peer is asked twice" 2 (Fixture.post_count refused);
  check int "the next peer is not reached" 0 (Fixture.post_count accepted);
  let sent n = Fixture.request_bodies refused |> Fun.flip List.nth n
    |> Yojson.Safe.from_string |> U.member "messages" |> U.to_list in
  let first = sent 0 and resent = sent 1 in
  check bool "the first request opens at the recorded start" true (has_content first "ask 2");
  check bool "and not at the Librarian point" false (has_content first "ask 1");
  check bool "the resend carries this turn's input" true (has_content resent pending);
  check bool "the resend opens at the turn boundary, not the recorded start" false
    (has_content resent "ask 2")
;;

let () = run "continuity HTTP dispatch"
  ["real peer", [test_case "saved pair survives provider refusal and failover" `Quick
    test_real_dispatch_preserves_pair_across_refusal];
   "unusable snapshot", [
    test_case "an unreadable snapshot file dispatches from the turn start" `Quick
      test_unreadable_snapshot_dispatches_from_the_turn_start;
    test_case "a snapshot whose covered prefix changed dispatches from the turn start" `Quick
      test_changed_prefix_dispatches_from_the_turn_start];
   "Librarian behind", [
    test_case "a size refusal resends from the turn boundary" `Quick
      test_a_librarian_behind_refusal_resends_from_the_boundary]]
