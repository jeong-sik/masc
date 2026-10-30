open Alcotest
open Masc

module R = Keeper_librarian_runtime
module L = Keeper_librarian
module T = Agent_core.Types
module C = Keeper_librarian_context
module M = Keeper_librarian_maintenance_capture
module Memory = Keeper_memory_os_current

let get = function Ok value -> value | Error detail -> fail detail

let unwrap = function
  | Ok value -> value
  | Error e -> fail (M.error_to_string e)

let fact claim =
  Keeper_memory_os_types.observed ~claim ~category:Keeper_memory_os_types.Fact
    ~now:10.
    ~origin:{kind=Keeper_memory_os_types.Authored;trace_id="maintenance-capture"}

let input () : L.input =
  {turn_ref=Ids.Turn_ref.make ~trace_id:"maintenance-capture" ~absolute_turn:8;
   keeper_id=Masc_test_deps.keeper_id_fixture "maintenance-owner";
   keeper_instructions="Retain the original maintenance answer";
   goal_context=L.Task_goals
     {task_id="original-task";criteria=Error "original goal read failed"};
   historical_task_contexts=[];
   current=Some {L.facts=[fact "Original source"]};
   working_context=
     {C.empty with
      sources=[{C.reference="queued-source";content=`String "Unconsumed source"}]};
   messages=[T.user_msg "Original completed user message"];
   tool_observations=[{L.tool_name="browser_read";outcome=L.Succeeded}];
   counterpart_observations=[]}

let answer = `Assoc
  [ "new_claims",
    `List
      [ `Assoc
          [ "claim", `String "Original source plus maintenance observation"
          ; "category", `String "fact"
          ; "board_post_id", `Null
          ; "board_comment_id", `Null
          ; "supersedes", `Null
          ; "absorbs", `List [`String "m1"] ] ]
  ; "dropped", `List []
  ; "working_state", `Null
  ; "working_contexts", `List [] ]

let with_fixture f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "librarian-maintenance-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.base_path_env_key
      (Some base_path) (fun () ->
        let keeper_name = "maintenance-owner" in
        let config = Workspace.default_config base_path in
        ignore (Workspace.init config ~agent_name:(Some keeper_name));
        Masc_test_deps.declare_fixture_keeper ~sandbox_image:"base"
          ~base_path
          ~sandbox_profile:(Some Keeper_types_profile.Docker) keeper_name;
        Keeper_types_profile.invalidate_keeper_profile_snapshots ();
        let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
        let () =
          match Memory.ensure_epoch ~keepers_dir ~keeper_id:keeper_name with
          | Ok _ -> ()
          | Error detail -> fail ("the Memory epoch could not be created: " ^ detail) in
        let owner =
          M.observe_owner ~base_path
            ~keepers_dir
            ~keeper_id:keeper_name
          |> get in
        let destination : M.destination =
          { Keeper_librarian_durable_request.installation_id = "inst-1"
          ; package_id = Keeper_librarian_durable_request.package_id
          ; tool = Keeper_librarian_durable_request.tool
          ; source_revision = "1111111111111111111111111111111111111111"
          ; configuration_revision = "2222222222222222222222222222222222222222" }
        in
        Prompt_registry.set_markdown_dir "../config/prompts";
        Prompt_defaults.init ();
        let prepared = R.prepare_durable ~now:123. (input ()) |> get in
        f ~owner ~destination ~prepared))

let test_create_and_roundtrip ~owner ~destination ~prepared =
  let captured =
    M.create ~request_id:"req-1" ~owner ~destination ~preparation:prepared
      ~answer_text:"{not json}" ~captured_at:123.
    |> unwrap in
  let restored = captured |> M.to_json |> M.of_json |> unwrap in
  check string "request id survives" "req-1" (M.request_id restored);
  check string "answer bytes survive verbatim" "{not json}"
    (M.answer_text restored);
  check string "the digest follows the exact answer bytes"
    (M.answer_digest captured) (M.answer_digest restored);
  check bool "the original preparation is retained structurally" true
    (M.preparation restored = prepared);
  (match M.matches_owner_json restored owner with
   | Ok () -> ()
   | Error detail -> fail detail)

let test_create_rejections ~owner ~destination ~prepared =
  let bad_tool =
    {destination with Keeper_librarian_durable_request.tool =
                       "not-the-maintenance-tool"} in
  (match M.create ~request_id:"req-2" ~owner ~destination:bad_tool
           ~preparation:prepared ~answer_text:"x" ~captured_at:123. with
   | Error _ -> ()
   | Ok _ -> fail "a relabeled tool must not be a maintenance destination");
  (match M.create ~request_id:"req-3" ~owner ~destination ~preparation:prepared
           ~answer_text:"" ~captured_at:123. with
   | Error _ -> ()
   | Ok _ -> fail "the empty answer must be rejected")

let test_proposal_validation ~owner ~destination ~prepared =
  let captured =
    M.create ~request_id:"req-4" ~owner ~destination ~preparation:prepared
      ~answer_text:(Yojson.Safe.to_string answer) ~captured_at:123.
    |> unwrap in
  let judged = M.validate_proposal captured answer |> unwrap in
  let expected =
    L.selection_of_json_result ~now:123. prepared.source_input answer
    |> Result.map_error L.parse_error_to_string
    |> get in
  check bool "the original selection parser owns the proposal" true
    (judged.accepted.selection = expected);
  check bool "the maintenance answer cannot acquire explicit-candidate authority"
    true
    (judged.accepted.continuity_answer = R.Memory_only
     && judged.accepted.required_memory_ids = []
     && judged.accepted.explicit_candidate_ids = []
     && judged.accepted.admission_support = []
     && judged.accepted.admission_recall_bindings = []);
  (match M.validate_proposal captured `Null with
   | Error _ -> ()
   | Ok _ -> fail "a non-object answer must be rejected")

let () =
  run "Keeper_librarian_maintenance_capture"
    [ ( "boundary",
        [ test_case "create and JSON roundtrip" `Quick
            (fun () -> with_fixture test_create_and_roundtrip)
        ; test_case "create rejects a relabeled tool and the empty answer" `Quick
            (fun () -> with_fixture test_create_rejections)
        ; test_case "proposal validation recombines through the original parser"
            `Quick (fun () -> with_fixture test_proposal_validation) ] ) ]
