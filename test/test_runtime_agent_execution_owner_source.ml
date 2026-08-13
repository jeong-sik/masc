(* Keep Agent Core's execution runtime at the application owner boundary.
   A Keeper turn, candidate failover, or context-shrink retry must never create
   a replacement runtime as an implicit fallback. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)
;;

let normalize_whitespace input =
  let output = Buffer.create (String.length input) in
  let pending_space = ref false in
  String.iter
    (function
      | ' ' | '\n' | '\r' | '\t' -> pending_space := Buffer.length output > 0
      | char ->
        if !pending_space then Buffer.add_char output ' ';
        pending_space := false;
        Buffer.add_char output char)
    input;
  Buffer.contents output
;;

let contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > haystack_length
    then false
    else if String.sub haystack offset needle_length = needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let assert_contains ~label source expected =
  if not (contains source expected)
  then failwith (Printf.sprintf "[%s] expected source to contain %S" label expected)
;;

let assert_not_contains ~label source unexpected =
  if contains source unexpected
  then failwith (Printf.sprintf "[%s] source must not contain %S" label unexpected)
;;

let resolve_source relative =
  let parent path = Filename.dirname path in
  let project_root = parent (parent (parent (parent Sys.executable_name))) in
  let candidates =
    [ relative; Filename.concat project_root relative; Filename.concat ".." relative ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> normalize_whitespace (read_file path)
  | None ->
    failwith
      (Printf.sprintf
         "could not resolve %s (cwd=%s, exe=%s)"
         relative
         (Sys.getcwd ())
         Sys.executable_name)
;;

let () =
  let owner = resolve_source "lib/runtime/runtime_agent_execution_owner.ml" in
  let owner_interface =
    resolve_source "lib/runtime/runtime_agent_execution_owner.mli"
  in
  let identity =
    resolve_source
      "lib/keeper_runtime/keeper_agent_core_execution_identity.mli"
  in
  let store = resolve_source "lib/keeper/keeper_agent_core_execution_store.ml" in
  let bootstrap = resolve_source "lib/server/server_runtime_bootstrap.ml" in
  let keeper = resolve_source "lib/keeper/keeper_agent_run.ml" in
  let driver = resolve_source "lib/keeper/keeper_turn_driver.ml" in
  let provider =
    resolve_source "lib/keeper/keeper_turn_driver_try_provider.ml"
  in
  assert_contains
    ~label:"typed creation"
    owner
    "Agent_core.Agent.create_execution_runtime ~sw ~domain_mgr ~domain_count";
  assert_contains
    ~label:"single owner claim"
    owner
    "Atomic.compare_and_set installed_owner None installed";
  assert_contains
    ~label:"root switch release"
    owner
    "Eio.Switch.on_release sw";
  assert_contains
    ~label:"no fallback availability"
    owner_interface
    "type availability = | Available of t | Unavailable";
  assert_contains
    ~label:"composition-root sizing"
    bootstrap
    "Runtime_agent_execution_owner.create ~sw ~domain_mgr ~domain_count:(Domain_pool.domain_count domain_pool)";
  assert_contains
    ~label:"composition-root install"
    bootstrap
    "Runtime_agent_execution_owner.install ~sw initialized.agent_core_execution_runtime";
  assert_contains
    ~label:"typed retry identity"
    identity
    "type thinking_attempt = | Runtime_thinking_policy | Force_thinking | Force_no_thinking";
  assert_contains
    ~label:"fresh versus resume"
    store
    "type execution_mode = | Fresh_scope | Crash_resume of Agent_core.Agent.execution_locator";
  assert_contains
    ~label:"exclusive locator"
    store
    "Fs_compat.create_capability_file_exclusive ~parent ~leaf:locator_leaf ~permissions:0o600";
  assert_contains
    ~label:"unknown effect keeps locator"
    store
    "Agent_core.Agent.Operator_repair_required Agent_core.Agent.Effect_outcome_unknown -> Ok ()";
  assert_contains
    ~label:"candidate ordinal ingress"
    driver
    "~run_attempt:(fun ~idx:runtime_candidate_index ~runtime_id:attempt_runtime_id candidate";
  assert_contains
    ~label:"production factory"
    keeper
    "~execution_store_factory: (Keeper_agent_core_execution_store.current_owner_factory ~base_path:config.base_path)";
  assert_contains
    ~label:"API boundary factory"
    provider
    "let run_fn () = Eio_guard.check_if_ready (); let prepared_execution =";
  assert_contains ~label:"execution-store forwarding" provider "?execution_store";
  List.iter
    (fun relative ->
       assert_not_contains
         ~label:relative
         (resolve_source relative)
         "create_execution_runtime")
    [ "lib/keeper/keeper_agent_run.ml"
    ; "lib/keeper/keeper_turn_driver.ml"
    ; "lib/keeper/keeper_turn_driver_try_provider.ml"
    ; "lib/runtime/runtime_agent.ml"
    ];
  print_endline "test_runtime_agent_execution_owner_source: OK"
;;
