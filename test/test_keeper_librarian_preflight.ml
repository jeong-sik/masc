open Masc
module Fixture = Exact_output_fixture
module Current = Keeper_memory_os_current
module Memory = Keeper_memory_os_types
module Runs = Exact_lane_run_registry

let answer_with_probabilities choice probabilities = Yojson.Safe.to_string (`Assoc
  [ "model", `String "fixture-jev"
  ; "answers", `Assoc ["memory_change", `Assoc
      [ "type", `String "choice"; "choice", `String choice
      ; "confidence", `Float 1.0
      ; "probabilities", `Assoc (List.map (fun (name, probability) -> name, `Float probability) probabilities) ]] ])

let answer choice = answer_with_probabilities choice
  (List.map (fun name -> name, if name = choice then 1.0 else 0.0)
    ["keep_current"; "needs_generation"; "uncertain"])

let generated = Yojson.Safe.to_string (`Assoc
  [ "new_claims", `List [`Assoc
      [ "claim", `String "A newly established constraint must remain remembered."
      ; "category", `String "architecture_decision"
      ; "board_post_id", `Null; "board_comment_id", `Null
      ; "supersedes", `Null; "absorbs", `List [] ]]
  ; "dropped", `List []; "working_contexts", `List []; "working_state", `Null ])

(* The working-context input a pass carries. [Live_nothing_pending] is what
   [Keeper_librarian_context_io.capture] returns for a running Keeper whose
   pending inputs were all consumed: no source, yet a prior snapshot and an
   execution basis, neither of which the prompt shows. *)
type context_shape = No_context | Pending_source | Unavailable_source | Live_nothing_pending

let consumed_source =
  {Keeper_librarian_context.reference="consumed"; content=`String "An answered question"}

let run_case ~base_path ~registry ?(enabled = true) ?(excluded = false)
    ?(context_only = false) ?(context = No_context) ?(lane_enabled = true)
    ?(disable_during_preflight = false) ~name ~status ~body
    ~expected_jev ~expected_llm () =
  Fixture.with_official_client_runtimes @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs env#fs;
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let jev_calls = ref 0 and llm_calls = ref 0 in
  let before_reply = ref (fun () -> ()) in
  let socket = Eio.Net.listen env#net ~sw ~backlog:8 ~reuse_addr:true
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | _ -> Alcotest.fail "no loopback port" in
  let handler _ _ incoming =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int incoming |> take_all));
    incr jev_calls;
    (* The runtime's source record must exist before this effect. *)
    Alcotest.(check bool) "source persisted before JEV"
      true (List.exists (fun (run : Runs.run) -> run.actor = name) (Runs.list_runs registry));
    !before_reply ();
    Cohttp_eio.Server.respond_string ~status ~body () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket (Cohttp_eio.Server.make ~callback:handler ())
      ~on_error:(fun exn -> raise exn));
  let destination : Runtime_schema.typesafeai_destination =
    {endpoint=Printf.sprintf "http://127.0.0.1:%d" port;
     model="fixture-requested-jev"; api_key_env="MASC_PREFLIGHT_FIXTURE_KEY"} in
  let policy = {Runtime_schema.default_typesafeai with
    destinations=(destination, []); librarian_preflight=enabled;
    excluded_keepers=(if excluded then [name] else [])} in
  Masc_test_deps.with_process_env "MASC_PREFLIGHT_FIXTURE_KEY" (Some "fixture-key") @@ fun () ->
  Masc_test_deps.with_typesafeai_policy policy @@ fun () ->
  let resolver = Fixture.resolver_snapshot ~source:"preflight-fixture" [] in
  let initial = Fixture.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[]
    ~cli_slot_ids:[Fixture.cli_primary_runtime] resolver in
  let declaration = match Runtime_exact_output_registry.declared_lane initial ~lane_id:"librarian_exact" with
    | Some declaration -> declaration | None -> Alcotest.fail "no fixture lane" in
  let set_activity enabled =
    match Runtime_exact_output_registry.publish ~lanes:[{declaration with enabled}] resolver with
    | Ok _ -> () | Error error -> Alcotest.fail (Runtime_exact_output_registry.publication_error_to_string error) in
  set_activity lane_enabled;
  if disable_during_preflight then before_reply := (fun () -> set_activity false);
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let fact : Memory.fact = Memory.observed ~claim:"The established constraint is still valid."
    ~category:Memory.Constraint ~now:1000.
    ~origin:{Memory.kind=Memory.Authored; trace_id=name} in
  let stored = match Current.replace ~keepers_dir ~keeper_id:name ~expected_revision:None
    ~now:1000. ~source:{Current.kind=Current.Librarian;trace_id=name} ~facts:[fact] () with
    | Ok stored -> stored | Error detail -> Alcotest.fail detail in
  let working_context = match context with
    | No_context -> Keeper_librarian_context.empty
    | Pending_source ->
      {Keeper_librarian_context.empty with sources=
        [{Keeper_librarian_context.reference="pending"; content=`String "An unresolved obligation"}]}
    | Unavailable_source ->
      {Keeper_librarian_context.empty with unavailable=["events: fixture store unavailable"]}
    | Live_nothing_pending ->
      let prior = match Keeper_librarian_context.commit ~keepers_dir ~keeper_id:name
          ~expected_version:None ~sources:[consumed_source]
          [{Keeper_librarian_context.id="fixture"; merge_contexts=[]; sources=["consumed"];
            context="The answered question"; next_steps=["Close the thread"];
            completeness=Current}] with
        | Ok snapshot -> snapshot | Error detail -> Alcotest.fail detail in
      {Keeper_librarian_context.sources=[]; previous=Some prior; unavailable=[];
       execution_basis=Some "fixture-live-basis"} in
  let input : Keeper_librarian.input =
    {turn_ref=Ids.Turn_ref.make ~trace_id:name ~absolute_turn:1;
     historical_task_contexts=[];goal_context=Keeper_librarian.No_task;
     keeper_id=Masc_test_deps.keeper_id_fixture name;
     keeper_instructions="Keep explicit constraints.";
     current=Some {Keeper_librarian.facts=stored.facts};working_context;
     messages=[Agent_core.Types.user_msg "The already remembered constraint still holds."];
     tool_observations=[];counterpart_observations=[]} in
  let range : Current.durable_range_id =
    {receipt_scope="preflight-fixture";trace_id=name;history_start_boundary_line=1;
     start_atom=0;end_atom=1;last_atom_digest=String.make 64 'a';
     end_boundary_line=2;boundary_lines_seen=2} in
  let runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    incr llm_calls; Ok (if context_only then {|{"working_contexts":[]}|} else generated) in
  let committed = ref false in
  Keeper_librarian_runtime.run_best_effort
    ~write_scope:(if context_only then Keeper_librarian_runtime.Context_only else Context_and_memory)
    ?durable_range_id:(if context_only then None else Some range)
    ~cli_runner:runner ~on_memory_committed:(fun () -> committed := true)
    ~base_path ~keepers_dir ~keeper_id:name ~expected_revision:(Some stored.revision) input;
  Alcotest.(check int) "actual JEV dispatches" expected_jev !jev_calls;
  Alcotest.(check int) "actual generation dispatches" expected_llm !llm_calls;
  if not lane_enabled then (
    Alcotest.(check bool) "off must not acknowledge memory consumption" false !committed;
    (match Current.committed_durable_range ~keepers_dir ~keeper_id:name ~receipt_scope:range.receipt_scope with
     | Ok None -> () | Ok (Some _) -> Alcotest.fail "off consumed the range" | Error detail -> Alcotest.fail detail);
    match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:name with
    | Ok (Some snapshot) -> Alcotest.(check int) "off retains prior revision" stored.revision snapshot.revision
    | Ok None -> Alcotest.fail "off removed memory" | Error detail -> Alcotest.fail detail)
  else if not context_only then (
    Alcotest.(check bool) "normal commit observer ran" true !committed;
    (match Current.committed_durable_range ~keepers_dir ~keeper_id:name
      ~receipt_scope:range.receipt_scope with
     | Ok (Some receipt) -> Alcotest.(check bool) "normal receipt proves the range" true (receipt = range)
     | Ok None -> Alcotest.fail "no receipt" | Error detail -> Alcotest.fail detail);
    (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:name with
     | Ok (Some snapshot) ->
       Alcotest.(check int) "current facts retained, or generation applied"
         (if expected_llm = 0 then 1 else 2) (List.length snapshot.facts);
       if expected_llm = 0 then Alcotest.(check int) "no-change keeps revision"
         stored.revision snapshot.revision
     | Ok None -> Alcotest.fail "snapshot missing" | Error detail -> Alcotest.fail detail));
  (match lane_enabled, context, context_only with
   | false, No_context, _ ->
     (* Nothing runs while the lane is off, so no working context is written. *)
     (match Keeper_librarian_context.read ~keepers_dir ~keeper_id:name with
      | Ok None -> ()
      | Ok (Some _) -> Alcotest.fail "off wrote a working context"
      | Error detail -> Alcotest.fail detail)
   | false, (Live_nothing_pending | Pending_source | Unavailable_source), _ -> ()
   | true, No_context, false ->
     (* The empty input has no snapshot yet; every route writes the first. *)
     (match Keeper_librarian_context.read ~keepers_dir ~keeper_id:name with
      | Ok (Some snapshot) ->
        Alcotest.(check int) "first working context written" 1 snapshot.revision;
        Alcotest.(check int) "with no context" 0 (List.length snapshot.pockets)
      | Ok None -> Alcotest.fail "working context missing"
      | Error detail -> Alcotest.fail detail)
   | true, Live_nothing_pending, _ ->
     (* Both routes write the only valid organization of nothing pending,
        which retires the consumed source's context. *)
     (match Keeper_librarian_context.read ~keepers_dir ~keeper_id:name with
      | Ok (Some snapshot) ->
        Alcotest.(check int) "working context advanced once" 2 snapshot.revision;
        Alcotest.(check int) "consumed context retired" 0 (List.length snapshot.pockets)
      | Ok None -> Alcotest.fail "working context missing"
      | Error detail -> Alcotest.fail detail)
   | true, No_context, true | true, (Pending_source | Unavailable_source), _ -> ());
  let run = List.filter (fun (run : Runs.run) -> run.actor = name) (Runs.list_runs registry) in
  match run with
  | [] when not lane_enabled -> ()
  | [{Runs.status=Runs.Completed {outcome=Runs.Succeeded;selected_slot;_};run_id;_}] ->
    Alcotest.(check (option string)) "JEV never claims a catalog or CLI slot"
      (if expected_llm = 0 then None else Some Fixture.cli_primary_runtime) selected_slot;
    (match context, context_only with
     | (No_context | Live_nothing_pending), false ->
       (* The listing omits payloads; one run is read whole. *)
       let output = match Runs.get registry ~run_id with
         | Some {Runs.status=Runs.Completed {output;_};_} -> output
         | Some _ | None -> Alcotest.fail "completed run not readable" in
       let open Yojson.Safe.Util in
       Alcotest.(check string) "the run records the working-context write" "committed"
         (output |> member "context_write" |> member "status" |> to_string);
       Alcotest.(check string) "an empty organization needs no review" "no_contexts"
         (output |> member "context_review" |> member "reason" |> to_string)
     | (No_context | Live_nothing_pending), true | (Pending_source | Unavailable_source), _ -> ())
  | _ -> Alcotest.fail "expected one successful terminal run"

let () =
  let base_path = Filename.temp_dir "librarian-preflight-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let registry = Runs.create ~path:(Filename.concat base_path Runs.storage_filename) () in
  (match Runs.install_global registry with
   | Ok () -> () | Error Runs.Already_installed -> Alcotest.fail "registry already installed");
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  let case ?enabled ?excluded ?context_only ?context ?lane_enabled ?disable_during_preflight name status body jev llm =
    Alcotest.test_case name `Quick
      (run_case ~base_path ~registry ?enabled ?excluded ?context_only ?context ?lane_enabled ?disable_during_preflight
        ~name ~status ~body ~expected_jev:jev ~expected_llm:llm) in
  let prompt_shape name input expected =
    Alcotest.test_case name `Quick (fun () ->
      Alcotest.(check bool) "eligibility reads the prompt" expected
        (Keeper_librarian_context.shows_no_working_context input);
      Alcotest.(check bool) "the prompt matches the empty projection" expected
        (Yojson.Safe.equal (Keeper_librarian_context.prompt_json input)
           (Keeper_librarian_context.prompt_json Keeper_librarian_context.empty))) in
  let prior = {Keeper_librarian_context.generation="fixture"; revision=1;
    execution_basis=Some "fixture-old-basis"; sources=[consumed_source];
    pockets=[{Keeper_librarian_context.id="fixture"; merge_contexts=[]; sources=["consumed"];
      context="The answered question"; next_steps=[]; completeness=Current}]} in
  Alcotest.run "Librarian JEV preflight"
    ["prompt projection", [
      prompt_shape "empty" Keeper_librarian_context.empty true;
      prompt_shape "running keeper with nothing pending"
        {Keeper_librarian_context.sources=[]; previous=Some prior; unavailable=[];
         execution_basis=Some "fixture-live-basis"} true;
      prompt_shape "pending source"
        {Keeper_librarian_context.empty with sources=[consumed_source]} false;
      prompt_shape "unavailable source"
        {Keeper_librarian_context.empty with unavailable=["events: fixture"]} false];
     "real dispatch and commit", [
      case ~lane_enabled:false "off-skips-jev-and-consumption" `OK (answer "keep_current") 0 0;
      case ~disable_during_preflight:true "accepted-pass-keeps-cli-after-off" `OK (answer "needs_generation") 1 1;
      case ~disable_during_preflight:true "accepted-no-change-finishes-after-off" `OK (answer "keep_current") 1 0;
      case "keep-current" `OK (answer "keep_current") 1 0;
      case "needs-generation" `OK (answer "needs_generation") 1 1;
      case "uncertain" `OK (answer "uncertain") 1 1;
      case "invalid-answer" `OK {|{"model":"fixture","answers":{}}|} 1 1;
      case "missing-option" `OK
        (answer_with_probabilities "keep_current" ["keep_current", 1.0]) 1 1;
      case "duplicate-option" `OK
        (answer_with_probabilities "keep_current"
          ["keep_current", 1.0; "keep_current", 0.0; "needs_generation", 0.0; "uncertain", 0.0]) 1 1;
      case "out-of-range" `OK
        (answer_with_probabilities "keep_current"
          ["keep_current", -1.0; "needs_generation", 2.0; "uncertain", 0.0]) 1 1;
      case "inconsistent-choice" `OK
        (answer_with_probabilities "keep_current"
          ["keep_current", 0.0; "needs_generation", 1.0; "uncertain", 0.0]) 1 1;
      case "invalid-total" `OK
        (answer_with_probabilities "keep_current"
          ["keep_current", 0.5; "needs_generation", 0.0; "uncertain", 0.0]) 1 1;
      case "provider-failed" `Service_unavailable {|{"error":"fixture unavailable"}|} 1 1;
      case ~enabled:false "opt-out" `OK (answer "keep_current") 0 1;
      case ~excluded:true "excluded" `OK (answer "keep_current") 0 1;
      case ~context:Live_nothing_pending "live-nothing-pending-keep-current" `OK
        (answer "keep_current") 1 0;
      case ~context:Live_nothing_pending "live-nothing-pending-needs-generation" `OK
        (answer "needs_generation") 1 1;
      case ~context:Pending_source "pending-context" `OK (answer "keep_current") 0 1;
      case ~context:Unavailable_source "unavailable-context" `OK (answer "keep_current") 0 1;
      case ~context_only:true "context-only" `OK (answer "keep_current") 0 1]]
