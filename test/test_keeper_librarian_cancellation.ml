open Masc

module Runtime = Keeper_librarian_runtime
module Librarian = Keeper_librarian
module Runs = Exact_lane_run_registry
module Fixture = Exact_output_fixture

exception Operator_cancelled

type stage =
  | Provider
  | After_completion
  | After_failed_completion

let check_json label expected actual =
  Alcotest.(check string) label
    (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)

let test_cancel ?(observer_checks = true) ?(closed_pool = false) ~base_path ~registry stage () =
  Eio_main.run @@ fun env ->
  let previous_pool = Domain_pool_ref.get () in
  Fun.protect ~finally:(fun () -> match previous_pool with
    | None -> Domain_pool_ref.clear_for_tests ()
    | Some pool -> Domain_pool_ref.set pool) @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
  @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let keeper_id = match stage with
    | Provider -> "cancel-provider"
    | After_completion -> "cancel-after-completion"
    | After_failed_completion -> "cancel-after-failed-completion" in
  let keeper_id = if observer_checks then keeper_id else keeper_id ^ "-deferred" in
  let keeper_id = if closed_pool then keeper_id ^ "-closed-pool" else keeper_id in
  let expected_status = match stage with
    | After_completion -> "succeeded"
    | After_failed_completion -> "failed"
    | Provider -> "cancelled" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let input : Librarian.input =
    { turn_ref = Ids.Turn_ref.make ~trace_id:keeper_id ~absolute_turn:9
    ; goal_context = Librarian.No_task
    ; keeper_id = Masc_test_deps.keeper_id_fixture keeper_id
    ; keeper_instructions = "Keep both service deployment instructions."
    ; working_context = Keeper_librarian_context.empty } in
  let answer = `Assoc [ Librarian.wire_field_working_contexts, `List [] ] in
  let blocked, signal_blocked = Eio.Promise.create () in
  let block () =
    Eio.Promise.resolve signal_blocked ();
    Eio.Fiber.await_cancel () in
  let librarian = Fixture.start_server ~sw ~net ~clock
      ~on_request_before_reply:(fun () -> match stage with
        | Provider -> block ()
        | After_completion | After_failed_completion -> ())
      (Fixture.Reply (Fixture.openai_response
        (if stage = After_failed_completion then `Assoc [ "working_contexts", `String "invalid" ] else answer))) in
  let resolver = Fixture.resolver_snapshot ~source:"cancel-fixture"
    [ { Fixture.id = "cancel-librarian-fixture"; base_url = librarian.base_url } ] in
  (match Runtime_exact_output_registry.publish
      ~lanes:[ { Runtime_schema.owner = Runtime_schema.Builtin Standalone_lane.Librarian
               ; enabled = true
               ; slot_ids = [ "cancel-librarian-fixture" ]
               ; cli_slot_ids = []
               ; max_output_tokens = Some 4_096; thinking = None
               } ] resolver with
   | Ok _ -> ()
   | Error error -> Alcotest.fail
       (Runtime_exact_output_registry.publication_error_to_string error));
  let cancel_context, set_cancel_context = Eio.Promise.create () in
  let completed_before_cancellation = ref None in
  let previous_observer = Atomic.get Runs.change_observer_fn in
  Atomic.set Runs.change_observer_fn (fun () ->
    previous_observer ();
    if (stage = After_completion || stage = After_failed_completion)
       && Option.is_none !completed_before_cancellation then
      match List.find_opt (fun (run : Runs.run) ->
        run.actor = keeper_id
        && match run.status with
          | Runs.Completed _ -> true
          | Runs.Running | Runs.Completion_persistence_failed _ -> false) (Runs.list_runs registry) with
      | None -> ()
      | Some run ->
        completed_before_cancellation := Runs.get registry ~run_id:run.run_id;
        Eio.Cancel.cancel (Eio.Promise.await cancel_context) Operator_cancelled;
        if observer_checks then Eio.Fiber.check ());
  Fun.protect ~finally:(fun () ->
    Atomic.set Runs.change_observer_fn previous_observer) @@ fun () ->
  let runtime_cancelled = ref false in
  let worker = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Cancel.sub (fun cc ->
      Eio.Promise.resolve set_cancel_context cc;
      try
        Runtime.run_best_effort ~base_path ~keepers_dir ~keeper_id input
      with Eio.Cancel.Cancelled _ as exn ->
        runtime_cancelled := true;
        raise exn)) in
  let await failure = Fixture.await_within_fixture_budget ~clock ~failure in
  let cc = await "worker did not enter its cancellation scope" cancel_context in
  (match stage with
   | Provider ->
     await "the selected HTTP request did not block" blocked;
     if closed_pool then (
       Eio.Switch.run (fun pool_sw ->
         let pool = Domain_pool.create ~sw:pool_sw ~domain_count:1
             (Eio.Stdenv.domain_mgr env) in
         Domain_pool_ref.set pool);
       let refused = try
           Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () -> ()); false
         with Invalid_argument _ -> true in
       Alcotest.(check bool) "fixture executor no longer accepts work" true refused);
     Eio.Cancel.cancel cc Operator_cancelled
   | After_completion | After_failed_completion -> ());
  (match await "cancelled Librarian did not return" worker with
   | Error (Eio.Cancel.Cancelled Operator_cancelled) -> ()
   | Error exn -> Alcotest.failf "wrong cancellation: %s" (Printexc.to_string exn)
   | Ok () -> Alcotest.fail "Librarian swallowed cancellation");
  Alcotest.(check bool) "the runtime itself propagated cancellation" true !runtime_cancelled;
  Alcotest.(check int) "one actual Librarian request" 1 (Fixture.post_count librarian);
  let run = match List.filter (fun (run : Runs.run) -> run.actor = keeper_id) (Runs.list_runs registry) with
    | [ run ] -> Runs.get registry ~run_id:run.run_id |> Option.get
    | _ -> Alcotest.fail "one Librarian run must be retained" in
  Alcotest.(check string) "the live registry retains the actual terminal outcome" expected_status
    (Runs.status_label run.status);
  let replayed = Runs.replay (Filename.concat base_path Runs.storage_filename) in
  let replayed_run = Runs.get replayed ~run_id:run.run_id |> Option.get in
  Alcotest.(check string) "restart retains the actual terminal outcome"
    expected_status (Runs.status_label replayed_run.status);
  Option.iter (fun completed ->
    check_json "late cancellation preserves the complete stored run byte for byte"
      (Runs.run_to_yojson completed) (Runs.run_to_yojson replayed_run))
    !completed_before_cancellation;
  (match previous_pool with
   | None -> Domain_pool_ref.clear_for_tests ()
   | Some pool -> Domain_pool_ref.set pool);
  Librarian_run_tui_reading.check replayed_run

let () =
  let base_path = Filename.temp_dir "librarian-cancellation-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let registry = Runs.create ~path:(Filename.concat base_path Runs.storage_filename) () in
    (match Runs.install_global registry with
     | Ok () -> ()
     | Error Runs.Already_installed -> Alcotest.fail "registry already installed");
    let root = match Sys.getenv_opt "DUNE_SOURCEROOT" with
      | Some root -> root | None -> Sys.getcwd () in
    Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
    Prompt_defaults.init ();
    Alcotest.run "Librarian cancellation evidence"
      [ "working-context cancellation",
        [ Alcotest.test_case "pending provider preserves terminal evidence" `Quick
            (test_cancel ~base_path ~registry Provider)
        ; Alcotest.test_case "provider cancellation journals after shared workers exit" `Quick
            (test_cancel ~closed_pool:true ~base_path ~registry Provider)
        ; Alcotest.test_case "late notification cancellation preserves completed evidence" `Quick
            (test_cancel ~base_path ~registry After_completion)
        ; Alcotest.test_case "failed completion keeps its cancellation journal" `Quick
            (test_cancel ~base_path ~registry After_failed_completion)
        ; Alcotest.test_case "completion observer requests cancellation without checking" `Quick
            (test_cancel ~observer_checks:false ~base_path ~registry After_completion)
        ; Alcotest.test_case "failed completion observer requests cancellation without checking" `Quick
            (test_cancel ~observer_checks:false ~base_path ~registry After_failed_completion) ] ])
