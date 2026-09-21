open Masc

module Runtime = Keeper_librarian_runtime
module Librarian = Keeper_librarian
module Current = Keeper_memory_os_current
module Types = Keeper_memory_os_types
module Runs = Exact_lane_run_registry
module Fixture = Exact_output_fixture

exception Operator_cancelled

type stage = Provider | Second_judgment | After_commit | After_completion | After_failed_completion

let require = function Ok value -> value | Error detail -> Alcotest.fail detail
let member = Yojson.Safe.Util.member
let string = Yojson.Safe.Util.to_string
let check_json label expected actual =
  Alcotest.(check string) label
    (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)

let test_cancel ~base_path ~registry stage () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
  @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let keeper_id = match stage with
    | Provider -> "cancel-provider"
    | Second_judgment -> "cancel-second-judgment"
    | After_commit -> "cancel-after-commit"
    | After_completion -> "cancel-after-completion"
    | After_failed_completion -> "cancel-after-failed-completion" in
  let commits_memory = stage = After_commit || stage = After_completion in
  let expected_status = match stage with
    | After_completion -> "succeeded"
    | After_failed_completion -> "failed"
    | Provider | Second_judgment | After_commit -> "cancelled" in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let fact claim =
    Types.observed ~claim ~category:Types.Fact ~now:100.
      ~origin:{ kind = Types.Authored; trace_id = "cancel-fixture" } in
  let facts =
    [ fact "The alpha service deploys every Tuesday."
    ; fact "The beta service deploys every Friday." ] in
  let source : Current.source = { kind = Current.Librarian; trace_id = keeper_id } in
  let seeded =
    Current.replace ~keepers_dir ~keeper_id ~expected_revision:None
      ~now:100. ~source ~facts () |> require in
  let input : Librarian.input =
    { turn_ref = Ids.Turn_ref.make ~trace_id:keeper_id ~absolute_turn:1
    ; goal_context = Librarian.No_task
    ; keeper_instructions = "Keep both service deployment instructions."
    ; current = Some { Librarian.facts = seeded.facts }
    ; working_context = Keeper_librarian_context.empty
    ; messages = []; tool_observations = []; counterpart_observations = [] } in
  let current_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let before_bytes = Fs_compat.load_file current_path in
  let claim text token =
    `Assoc [ "claim", `String text; "category", `String "fact"
           ; "absorbs", `List [ `String token ] ] in
  let answer = `Assoc
    [ "new_claims", `List
        [ claim "Tuesday is the alpha service's deployment day." "m1"
        ; claim "Friday is the beta service's deployment day." "m2" ]
    ; "dropped", `List []; "working_contexts", `List [] ] in
  let blocked, signal_blocked = Eio.Promise.create () in
  let block () =
    Eio.Promise.resolve signal_blocked ();
    Eio.Fiber.await_cancel () in
  let librarian = Fixture.start_server ~sw ~net ~clock
      ~on_request_before_reply:(fun () -> match stage with
        | Provider -> block ()
        | Second_judgment | After_commit | After_completion | After_failed_completion -> ())
      (Fixture.Reply (Fixture.openai_response
        (if stage = After_failed_completion then `Assoc [ "new_claims", `String "invalid" ] else answer))) in
  let judgments = ref 0 in
  let jev = Fixture.start_server ~sw ~net ~clock
      ~on_request_before_reply:(fun () ->
        incr judgments;
        if stage = Second_judgment && !judgments = 2 then block ())
      (Fixture.Reply
        {|{"model":"completed-jev","answers":{"s0_0":{"type":"noul","noul":0.875}}}|}) in
  let resolver = Fixture.resolver_snapshot ~source:"cancel-fixture"
    [ { Fixture.id = "cancel-librarian-fixture"; base_url = librarian.base_url } ] in
  (match Runtime_exact_output_registry.publish
      ~lanes:[ { Runtime_schema.id = "librarian_exact"
               ; slot_ids = [ "cancel-librarian-fixture" ]; cli_slot_ids = [] } ] resolver with
   | Ok _ -> ()
   | Error error -> Alcotest.fail
       (Runtime_exact_output_registry.publication_error_to_string error));
  Masc_test_deps.with_process_env "TYPESAFEAI_API_KEY" (Some "synthetic-cancel-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy
    { Runtime_schema.default_typesafeai with
      lane_endpoint = jev.base_url
    ; lane_model = "requested-cancel-model"
    ; absorb_gate = true
    } @@ fun () ->
  let cancel_context, set_cancel_context = Eio.Promise.create () in
  let memory_committed = ref false in
  let cancel_after_commit = ref (stage = After_commit) in
  let unsubscribe = Keeper_memory_commit_notifications.subscribe (fun event ->
    if !cancel_after_commit && event.keeper_id = keeper_id then (
      cancel_after_commit := false;
      (* Inject cancellation at the real post-commit notification boundary.
         No filesystem or model work is added to the subscriber. *)
      Eio.Cancel.cancel (Eio.Promise.await cancel_context) Operator_cancelled;
      Eio.Fiber.check ())) in
  let completed_before_cancellation = ref None in
  let previous_observer = Atomic.get Runs.change_observer_fn in
  Atomic.set Runs.change_observer_fn (fun () ->
    previous_observer ();
    if (stage = After_completion || stage = After_failed_completion)
       && Option.is_none !completed_before_cancellation then
      match List.find_opt (fun (run : Runs.run) ->
        run.actor = keeper_id && match run.status with
          | Runs.Completed _ -> true
          | Runs.Running | Runs.Completion_persistence_failed _ -> false) (Runs.list_runs registry) with
      | None -> ()
      | Some run ->
        completed_before_cancellation := Runs.get registry ~run_id:run.run_id;
        Eio.Cancel.cancel (Eio.Promise.await cancel_context) Operator_cancelled;
        Eio.Fiber.check ());
  Fun.protect ~finally:(fun () ->
    (* Restore the global first: a raising unsubscribe must not leave this
       fixture's observer installed for the rest of the binary, and a raising
       finalizer would mask the body's own failure. *)
    Atomic.set Runs.change_observer_fn previous_observer;
    try unsubscribe () with _ -> ()) @@ fun () ->
  let runtime_cancelled = ref false in
  let worker = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Cancel.sub (fun cc ->
      Eio.Promise.resolve set_cancel_context cc;
      try
        Runtime.run_best_effort ~trigger:Runtime.Queue_changed
          ~on_memory_committed:(fun () -> memory_committed := true)
          ~base_path ~keepers_dir ~keeper_id
          ~expected_revision:(Some seeded.revision) input
      with Eio.Cancel.Cancelled _ as exn ->
        runtime_cancelled := true;
        raise exn)) in
  let await failure = Fixture.await_within_fixture_budget ~clock ~failure in
  let cc = await "worker did not enter its cancellation scope" cancel_context in
  (match stage with
   | Provider | Second_judgment ->
     await "the selected HTTP request did not block" blocked;
     Eio.Cancel.cancel cc Operator_cancelled
   | After_commit | After_completion | After_failed_completion -> ());
  (match await "cancelled Librarian did not return" worker with
   | Error (Eio.Cancel.Cancelled Operator_cancelled) -> ()
   | Error exn -> Alcotest.failf "wrong cancellation: %s" (Printexc.to_string exn)
   | Ok () -> Alcotest.fail "Librarian swallowed cancellation");
  Alcotest.(check bool) "the runtime itself propagated cancellation" true !runtime_cancelled;
  Alcotest.(check int) "one actual Librarian request" 1 (Fixture.post_count librarian);
  Alcotest.(check int) "only the intended JEV requests were sent"
    (match stage with Provider | After_failed_completion -> 0 | Second_judgment | After_commit | After_completion -> 2) (Fixture.post_count jev);
  let after_bytes = Fs_compat.load_file current_path in
  Printf.printf "POST_COMMIT_OBSERVATION keeper=%s callback=%b memory_changed=%b\n%!"
    keeper_id !memory_committed (after_bytes <> before_bytes);
  Alcotest.(check bool) "Memory commit callback reports the actual store commit"
    commits_memory !memory_committed;
  Alcotest.(check bool) "Memory changes only after its actual commit"
    commits_memory (after_bytes <> before_bytes);
  let run = match List.filter (fun (run : Runs.run) -> run.actor = keeper_id)
      (Runs.list_runs registry) with
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
  let journal = Current.read_journal_tail ~keepers_dir ~keeper_id ~limit:10 in
  let cancellations = List.filter (function
    | Ok (Current.Journal_failed { kind = Current.Lane_cancelled; _ }) -> true
    | Ok _ -> false
    | Error detail -> Alcotest.fail detail) journal in
  Alcotest.(check int) "pre-commit cancellation alone adds a failure journal row"
    (if commits_memory then 0 else 1) (List.length cancellations);
  let output = match replayed_run.status with
    | Runs.Completed { output; _ } -> output
    | _ -> Alcotest.fail "cancelled replay lost its output" in
  (match stage with
   | Provider | After_failed_completion -> check_json "no invented gate before a provider response" `Null
       (member "absorb_gate" output)
   | After_commit | After_completion ->
     let snapshot = Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require |> Option.get in
     Alcotest.(check int) "cancelled output retains the committed revision" snapshot.revision
       (member "revision" (member "after" output) |> Yojson.Safe.Util.to_int);
     Alcotest.(check string) "the completed gate is retained after Memory commit" "judged"
       (member "status" (member "absorb_gate" output) |> string)
   | Second_judgment ->
     let gate = member "absorb_gate" output in
     Alcotest.(check string) "partial evaluation is explicitly incomplete" "incomplete"
       (member "status" gate |> string);
     let evaluations = member "evaluations" gate |> Yojson.Safe.Util.to_list in
     Alcotest.(check int) "the pending request does not invent a response" 1
       (List.length evaluations);
     let evaluation = List.hd evaluations in
     Alcotest.(check string) "the completed reply retains its actual model" "completed-jev"
       (member "model" evaluation |> string);
     check_json "the completed raw probability survives durable replay"
       (`Assoc [ "s0_0", `Float 0.875 ]) (member "answers" evaluation);
     let sent = Fixture.request_bodies jev |> List.hd |> Yojson.Safe.from_string in
     let request = member "request" evaluation in
     List.iter (fun key -> check_json ("actual completed request " ^ key)
       (member key sent) (member key request)) [ "model"; "state"; "questions" ];
     Alcotest.(check string) "the attempted endpoint survives replay" jev.base_url
       (member "endpoint" request |> string);
     List.iter (fun key -> check_json ("partial report has no " ^ key) `Null
       (member key gate)) [ "applied_absorptions"; "left"; "conveyed" ]);
  let module Projection = Server_standalone_lane_projection in
  let detail = match Projection.For_testing.run_detail_json_with
      ~run_id:replayed_run.run_id ~exact_runs:[ replayed_run ]
      ~verification_runs:[] ~goal_verification_runs:[] with
    | Projection.Detail_found detail -> detail
    | Detail_not_found | Detail_ambiguous -> Alcotest.fail "cancelled run has no HTTP detail" in
  let page = Projection.For_testing.recent_run_page_json_with
      ~limit:1 ~before:None ~lane:(Some "librarian_exact") ~run_kind:None
      ~exact_runs:[ replayed_run ] ~verification_runs:[] ~goal_verification_runs:[]
    |> require in
  Printf.printf "CANCELLATION_FIXTURE %s\n%!"
    (Yojson.Safe.to_string (`Assoc
       [ "scenario", `String keeper_id; "detail", detail; "page", page ]));
  Printf.printf "CANCELLATION_EVIDENCE keeper=%s status=%s journal_cancelled=%d memory_unchanged=%b jev_requests=%d\n%!"
    keeper_id (Runs.status_label replayed_run.status) (List.length cancellations)
    (after_bytes = before_bytes) (Fixture.post_count jev);
  (* A cancelled observation must not make the next accepted pass stick or
     consume the original Memory. The same Keeper can finish its next pass. *)
  (match stage with
   | Provider | After_failed_completion -> ()
   | Second_judgment | After_commit | After_completion ->
     let successor_committed = ref false in
     let successor = Eio.Fiber.fork_promise ~sw (fun () ->
       Runtime.run_best_effort ~trigger:Runtime.Queue_changed
         ~on_memory_committed:(fun () -> successor_committed := true)
         ~base_path ~keepers_dir ~keeper_id
         ~expected_revision:(Some seeded.revision) input) in
     (match await "the pass after cancellation did not finish" successor with
      | Ok () -> ()
      | Error exn -> Alcotest.failf "successor raised: %s" (Printexc.to_string exn));
     Alcotest.(check bool) "the next pass commits its Memory" true !successor_committed;
     let current = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
       | Some current -> current
       | None -> Alcotest.fail "successor lost current Memory" in
     Alcotest.(check int) "each committed pass advances Memory once" (seeded.revision + if commits_memory then 2 else 1)
       current.revision;
     Alcotest.(check (list string)) "the successful pass retains both merged claims"
       [ "Friday is the beta service's deployment day."
       ; "Tuesday is the alpha service's deployment day." ]
       (List.sort String.compare (List.map (fun (f : Types.fact) -> f.claim) current.facts));
     let statuses = Runs.list_runs registry
       |> List.filter (fun (r : Runs.run) -> r.actor = keeper_id)
       |> List.map (fun (r : Runs.run) -> Runs.status_label r.status)
       |> List.sort String.compare in
     Alcotest.(check (list string)) "both attempts have terminal evidence"
       [ expected_status; "succeeded" ] statuses;
     Printf.printf "CANCELLATION_SUCCESSOR keeper=%s statuses=%s memory_revision=%d\n%!"
       keeper_id (String.concat "," statuses) current.revision)

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
      [ "durable cancellation",
        [ Alcotest.test_case "pending provider preserves terminal evidence" `Quick
            (test_cancel ~base_path ~registry Provider)
        ; Alcotest.test_case "later JEV cancellation preserves completed evaluation" `Quick
            (test_cancel ~base_path ~registry Second_judgment)
        ; Alcotest.test_case "post-commit cancellation retains Memory commit evidence" `Quick
            (test_cancel ~base_path ~registry After_commit)
        ; Alcotest.test_case "late notification cancellation preserves completed evidence" `Quick
            (test_cancel ~base_path ~registry After_completion)
        ; Alcotest.test_case "failed completion keeps its cancellation journal" `Quick
            (test_cancel ~base_path ~registry After_failed_completion) ] ])
