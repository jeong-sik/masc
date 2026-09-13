module Worker = Server_workspace_memory_curator
module Inventory = Masc.Workspace_memory_context
module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types
module Proposals = Masc.Workspace_memory_proposal
module Runs = Masc.Exact_lane_run_registry

let require = function Ok value -> value | Error detail -> Alcotest.fail detail
let field name json = Yojson.Safe.Util.member name json
let list = Yojson.Safe.Util.to_list
let string = Yojson.Safe.Util.to_string
let stored base_path = match Proposals.list ~base_path with
  | Ok rows -> rows
  | Error (Proposals.Invalid detail | Unavailable detail) -> Alcotest.fail detail

let commit ?(keeper_id = "writer") base_path claim =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let expected_revision = match Current.read_for_keepers_dir ~keepers_dir ~keeper_id |> require with
    | None -> None | Some snapshot -> Some snapshot.revision in
  let now = 1_700_000_000. in
  let fact = Types.observed ~claim ~category:Types.Fact ~now
      ~origin:{ kind = Types.Authored; trace_id = "curator-test" } in
  Current.replace ~keepers_dir ~keeper_id ~expected_revision ~now
    ~source:{ kind = Current.Librarian; trace_id = "curator-test" } ~facts:[fact] () |> require |> ignore

let proposal context =
  let ids = Inventory.to_json context |> field "sources" |> list
    |> List.map (fun source -> field "source_id" source) in
  `Assoc [ "shared_claims", `List [];
           "conflicts", `List [];
           "excluded", `List (List.map (fun source_id ->
             `Assoc [ "source_id", source_id; "reason", `String "No semantic assertion in this injected-runner test" ]) ids) ]

let await_idle ~clock ~base_path =
  (* Test harness deadline only: a broken wake/drain must fail CI, not hang it. *)
  Eio.Time.with_timeout_exn clock 5. (fun () ->
    while not (Worker.For_testing.is_idle ~base_path) do Eio.Fiber.yield () done)

let with_base f =
  Prompt_registry.set_markdown_dir "../config/prompts";
  let base_path = Filename.temp_dir "workspace-curator-lane" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Eio_main.run (fun env -> f base_path env#clock))

let test_commit_coalescing_and_restart () = with_base (fun base_path clock ->
  commit base_path "Original observation";
  let first_context = Inventory.collect ~base_path |> require in
  let started, signal_started = Eio.Promise.create () in
  let release, signal_release = Eio.Promise.create () in
  let contexts = ref [] in
  let execute ~rendered_prompt:_ context =
    contexts := !contexts @ [Inventory.fingerprint context];
    if List.length !contexts = 1 then (
      Eio.Promise.resolve signal_started ();
      Eio.Promise.await release);
    Ok (proposal context, "test.admitted-slot") in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~sw ~base_path ~execute;
    Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await started);
    commit base_path "Intermediate observation";
    commit ~keeper_id:"reviewer" base_path "Independent reviewer observation";
    commit base_path "Latest corrected observation";
    let latest = Inventory.collect ~base_path |> require in
    Eio.Promise.resolve signal_release ();
    await_idle ~clock ~base_path;
    Alcotest.(check (list string)) "in-flight input survives; pending work captures the latest commit"
      [Inventory.fingerprint first_context; Inventory.fingerprint latest] !contexts;
    Alcotest.(check int) "both immutable proposals persisted" 2 (List.length (stored base_path));
    (match Masc.Workspace_memory_publication.observe ~base_path with
     | Available descriptor -> Alcotest.(check string) "Keeper discovery points at latest captured input"
         (Inventory.fingerprint latest) descriptor.context_sha256
     | Missing | Unavailable _ -> Alcotest.fail "curator did not publish discovery");
    ignore (Worker.request ~base_path);
    await_idle ~clock ~base_path;
    Alcotest.(check int) "unchanged wake does not call a model" 2 (List.length !contexts);
    let published_id = match Masc.Workspace_memory_publication.observe ~base_path with
      | Available descriptor -> descriptor.proposal_id
      | Missing | Unavailable _ -> Alcotest.fail "missing prior publication" in
    Sys.remove (Filename.concat base_path (Common.masc_dirname ^ "/workspace-memory/publication.json"));
    ignore (Worker.request ~base_path);
    await_idle ~clock ~base_path;
    Alcotest.(check int) "missing descriptor repair does not call a model" 2 (List.length !contexts);
    (match Masc.Workspace_memory_publication.observe ~base_path with
     | Available descriptor -> Alcotest.(check string) "successful exact output repairs the same discovery id"
         published_id descriptor.proposal_id
     | Missing | Unavailable _ -> Alcotest.fail "cache did not repair missing descriptor");
    let id, _ = List.hd (stored base_path) in
    let status, response = Server_workspace_memory_proposals.get ~base_path ~id:(Some id) in
    Alcotest.(check bool) "existing reader API reaches the background result" true (status = `OK);
    Alcotest.(check string) "never claims semantic verification" "not_performed"
      (response |> field "semantic_verification" |> string);
    Worker.For_testing.stop ~base_path);
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~sw ~base_path ~execute;
    await_idle ~clock ~base_path;
    Alcotest.(check int) "startup reconciliation reuses the exact published inventory" 2 (List.length !contexts);
    Worker.For_testing.stop ~base_path))

let test_failure_then_changed_input () = with_base (fun base_path clock ->
  commit base_path "First observation";
  let fail = ref true in
  let execute ~rendered_prompt:_ context = if !fail then Error "injected provider failure" else Ok (proposal context, "test.slot") in
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~sw ~base_path ~execute;
    await_idle ~clock ~base_path;
    Alcotest.(check int) "failure writes no empty success proposal" 0 (List.length (stored base_path));
    let canonical = Unix.realpath base_path in
    Alcotest.(check bool) "failed input remains observable in the exact registry" true
      (List.exists (fun (run : Runs.run) ->
        String.equal run.actor canonical && run.lane = Runs.Workspace_curator &&
        match run.status with Runs.Completed { outcome = Runs.Failed _; _ } -> true | _ -> false)
        (Runs.list_runs (Runs.global ())));
    fail := false;
    commit base_path "New evidence after provider recovery";
    await_idle ~clock ~base_path;
    Alcotest.(check int) "next commit remains eligible after failure" 1 (List.length (stored base_path));
    let before = Masc.Workspace_memory_publication.observe ~base_path in
    fail := true;
    commit base_path "Changed facts while provider unavailable";
    await_idle ~clock ~base_path;
    Alcotest.(check bool) "failed new curation preserves prior captured publication, not current facts"
      true (before = Masc.Workspace_memory_publication.observe ~base_path);
    let live = Inventory.collect ~base_path |> require in
    (match before with
     | Available descriptor -> Alcotest.(check bool) "old descriptor is not a claim of current source currency"
         false (descriptor.context_sha256 = Inventory.fingerprint live)
     | Missing | Unavailable _ -> Alcotest.fail "recovered proposal was not published");
    Worker.For_testing.stop ~base_path))

let test_directory_alias () = with_base (fun base_path clock ->
  let alias = base_path ^ "-alias" in
  Unix.symlink base_path alias;
  Fun.protect ~finally:(fun () -> Unix.unlink alias) (fun () ->
    commit base_path "Original observation";
    let count = ref 0 in
    let execute ~rendered_prompt:_ context = incr count; Ok (proposal context, "test.slot") in
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path:alias ~execute;
      await_idle ~clock ~base_path:alias;
      commit base_path "Committed through physical directory";
      await_idle ~clock ~base_path:alias;
      Alcotest.(check int) "physical event wakes the alias-started owner" 2 !count;
      Worker.For_testing.stop ~base_path:alias)))

let test_prompt_change_is_a_new_request () = with_base (fun base_path clock ->
  let key = Prompt_names.workspace_memory_curator in
  let mutation = Server_prompt_override_mutation.apply ~base_path in
  let applied request = match mutation request with
    | Ok applied -> applied
    | Error (Server_prompt_override_mutation.Validation detail | Persistence detail) -> Alcotest.fail detail in
  let set value = Server_prompt_override_request.Set { key; value } in
  let clear = Server_prompt_override_request.Clear { key } in
  let path = Filename.concat (Filename.concat base_path Common.masc_dirname) "prompt_overrides.json" in
  let persisted () = match Prompt_override_persistence.load ~path with
    | Ok entries -> entries
    | Error error -> Alcotest.fail (Prompt_override_persistence.error_to_string error) in
  let first = "Initial override. {{workspace_memory_inventory}}" in
  let second = "Changed curator instructions. Preserve attribution. {{workspace_memory_inventory}}" in
  commit base_path "Stable source observation";
  let inventory = Inventory.collect ~base_path |> require |> Inventory.fingerprint in
  let prompts = ref [] in
  let execute ~rendered_prompt context =
    Alcotest.(check string) "all executions retain identical memory" inventory (Inventory.fingerprint context);
    prompts := rendered_prompt :: !prompts;
    Ok (proposal context, "test.slot") in
  Fun.protect ~finally:(fun () -> Prompt_registry.clear_prompt_override key) (fun () ->
    Alcotest.(check bool) "saved without an owner does not claim queued execution" true
      ((applied (set first)).curator_refresh = Some Worker.No_owner);
    Eio.Switch.run (fun sw ->
      Worker.For_testing.start ~sw ~base_path ~execute;
      await_idle ~clock ~base_path;
      let result = applied (set second) in
      Alcotest.(check bool) "successful persisted HTTP mutation queues existing owner" true
        (result.curator_refresh = Some Worker.Queued);
      Alcotest.(check bool) "new override persisted before caller sees success" true
        (List.exists (fun (entry : Prompt_override_persistence.entry) -> entry.key = key && entry.value = second) (persisted ()));
      await_idle ~clock ~base_path;
      Alcotest.(check int) "changed prompt with identical sources executes without explicit wake" 2 (List.length !prompts);
      Alcotest.(check bool) "delivered rendered prompt changed" true (List.hd !prompts <> List.nth !prompts 1);
      let canonical = Unix.realpath base_path in
      let latest = Runs.list_runs (Runs.global ()) |> List.find (fun (run : Runs.run) ->
        String.equal run.actor canonical && run.lane = Runs.Workspace_curator) in
      let full = match Runs.get (Runs.global ()) ~run_id:latest.run_id with Some run -> run | None -> Alcotest.fail "missing exact run" in
      let Runs.Exact_input input = full.input in
      Alcotest.(check string) "registry preserved the exact delivered prompt" (List.hd !prompts)
        (input |> field "prompt" |> field "rendered" |> string);
      (match mutation (set "{{unknown_curator_variable}}") with
       | Error (Server_prompt_override_mutation.Validation _) -> ()
       | _ -> Alcotest.fail "invalid template accepted");
      Alcotest.(check bool) "rejected mutation does not wake owner" true (Worker.For_testing.is_idle ~base_path);
      Alcotest.(check string) "rejected mutation preserves effective prompt" second (Prompt_registry.get_prompt key);
      Sys.rename path (path ^ ".saved");
      Unix.mkdir path 0o700;
      Fun.protect ~finally:(fun () -> Unix.rmdir path; Sys.rename (path ^ ".saved") path) (fun () ->
        List.iter (fun request ->
          (match mutation request with
           | Error (Server_prompt_override_mutation.Persistence _) -> ()
           | _ -> Alcotest.fail "blocked persisted mutation unexpectedly succeeded");
          Alcotest.(check bool) "failed persistence does not wake owner" true (Worker.For_testing.is_idle ~base_path);
          Alcotest.(check string) "failed persistence preserves effective prompt" second (Prompt_registry.get_prompt key))
          [set first; clear]);
      Alcotest.(check bool) "persisted clear queues reevaluation" true
        ((applied clear).curator_refresh = Some Worker.Queued);
      Alcotest.(check bool) "clear removed persisted override before success" false
        (List.exists (fun (entry : Prompt_override_persistence.entry) -> entry.key = key) (persisted ()));
      await_idle ~clock ~base_path;
      Alcotest.(check int) "clear executes restored file prompt with unchanged memory" 3 (List.length !prompts);
      Worker.For_testing.stop ~base_path)))

let test_failed_publication_is_not_success () = with_base (fun base_path clock ->
  commit base_path "Original source";
  let execute ~rendered_prompt:_ context = Ok (proposal context, "test.slot") in
  let directory = Filename.concat base_path (Common.masc_dirname ^ "/workspace-memory") in
  Fs_compat.mkdir_p directory;
  Fs_compat.save_file (Filename.concat directory "publication.json") "{broken descriptor";
  Eio.Switch.run (fun sw ->
    Worker.For_testing.start ~sw ~base_path ~execute;
    await_idle ~clock ~base_path;
    Alcotest.(check int) "immutable model output still exists for inspection" 1 (List.length (stored base_path));
    (match Masc.Workspace_memory_publication.observe ~base_path with
     | Unavailable _ -> () | Missing | Available _ -> Alcotest.fail "invalid latest was overwritten");
    let canonical = Unix.realpath base_path in
    let runs = Runs.list_runs (Runs.global ()) |> List.filter (fun (run : Runs.run) ->
      String.equal run.actor canonical && run.lane = Runs.Workspace_curator) in
    Alcotest.(check int) "one matching publication attempt exists" 1 (List.length runs);
    Alcotest.(check bool) "publication failure has no successful run" true
      (List.for_all (fun (run : Runs.run) -> match run.status with
       | Runs.Completed { outcome = Runs.Failed _; _ } -> true | _ -> false) runs);
    Worker.For_testing.stop ~base_path))

let () = Alcotest.run "workspace curator lane"
  [ "background proposal publication",
    [ Alcotest.test_case "failed publication retains output but never succeeds" `Quick test_failed_publication_is_not_success
    ; Alcotest.test_case "commits coalesce, reader sees proposals, restart reconciles" `Quick test_commit_coalescing_and_restart
    ; Alcotest.test_case "failure stays visible and a later commit proceeds" `Quick test_failure_then_changed_input
    ; Alcotest.test_case "canonical directory aliases share an owner" `Quick test_directory_alias
    ; Alcotest.test_case "changed prompt is delivered and recorded with unchanged facts" `Quick test_prompt_change_is_a_new_request ] ]
