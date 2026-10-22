(* Actual SQLite transactions and restart, with opaque retained references.
   Physical payload validation and real Owner/Core admission are separate. *)
open Alcotest
module Store = Keeper_chat_operation_store
module Semantic = Keeper_semantic_execution
module Scope = Keeper_execution_scope_id
module Chat = Keeper_chat_operation
let value = function Ok value -> value | Error detail -> fail detail
let stored result = result |> Result.map_error Store.error_to_string |> value
let semantic result = result |> Result.map_error Store.semantic_error_to_string |> value
let hash text = Digestif.SHA256.(digest_string text |> to_hex)
let scope n = Scope.autonomous_admission
    (Uuidm.of_string (Printf.sprintf "00000000-0000-4000-8000-%012d" n) |> Option.get)
let source n = Semantic.source_member ~post_id:(Printf.sprintf "source-%d" n)
    ~admitted_revision:(Int64.of_int n) ~checkpoint_retentions:0
    ~source_sha256:(hash (string_of_int n)) |> value
let input n = `Assoc ["original_input",`Int n]
let reference text = Keeper_checkpoint_ref.create
    ~trace_id:(Keeper_id.Trace_id.of_string "autonomous-input-trace" |> value)
    ~turn_count:2 ~canonical_checkpoint_bytes:text
    |> function Ok reference -> reference | Error _ -> fail "invalid reference fixture"
let before = reference "original source"
let owned = reference "canonical pending input"
let independent = reference "independent work input"
let pending : Agent_core.Agent_input_request.pending =
  {run_id="original-autonomous-run";request={request_id="original-input-request";
    participant_name=Some "operator";question="Which original source?";
    schema=Some (`Assoc ["type",`String "string"]);timeout_s=Some 0.1;created_at=1.}}
let waiting = Semantic.input_wait ~checkpoint:owned ~pending |> value
let rec remove path = match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | _ -> Unix.unlink path
let with_path f =
  let root=Filename.temp_dir "autonomous-input-wait-" "" in
  Fun.protect ~finally:(fun () -> Store.For_testing.clear_commit_fault ();remove root)
    (fun () -> f (Filename.concat root Store.database_file))
let with_store path f =
  let store=Store.open_or_create ~path |> stored in
  Fun.protect ~finally:(fun () -> Store.close store |> stored) (fun () -> f store)
let start store n = match Store.start_autonomous_execution store ~id:(scope n)
    ~input:(input n) ~sources:[source n] ~now:1. |> semantic with
  | Store.Semantic_created execution -> execution
  | Semantic_existing _ -> fail "new autonomous UUID was replayed"
let get store id = Store.semantic_get store id |> semantic |> Option.get
let current_input store = Store.input_checkpoint store ~trace_id:owned.trace_id |> stored
let defer store execution ~observed ~waiting = Store.defer_autonomous_input_wait store
    ~now:2. ~id:execution.Semantic.id ~input_sha256:execution.input_sha256 ~observed ~waiting
let installed = function
  | Store.Autonomous_input_wait_installed execution -> execution
  | Autonomous_input_wait_existing _ | Autonomous_input_wait_source_changed _ -> fail "wait was not installed"
let has_wait execution = match execution.Semantic.phase with
  | Semantic.Recovering {origin=Semantic.Input_wait observed;_} -> Semantic.equal_input_wait observed waiting
  | _ -> false

let test_original_wait_survives_restart_and_independent_work () = with_path @@ fun path ->
  let original=with_store path (fun store ->
    let original=start store 1 in
    let parked=defer store original ~observed:None ~waiting |> semantic |> installed in
    check bool "wait and input owner commit together" true (has_wait parked && current_input store=Store.Input_observed owned);
    check bool "no direct native retirement is invented" true (parked.native_call=Keeper_native_call.No_native_call);
    parked) in
  with_store path (fun store ->
    ignore (Store.settle_running_after_restart store ~now:1e12 |> stored);
    let restored=get store original.id in
    check bool "restart preserves complete original wait and sources" true
      (Semantic.to_json original=Semantic.to_json restored);
    let other=start store 2 in
    check bool "independent autonomous work has a distinct running scope" true
      (not (Scope.equal original.id other.id) && other.phase=Semantic.Running);
    (match Store.update_input_checkpoint store ~now:1e12 ~observed:(Some owned) ~checkpoint:independent |> stored with
     | Store.Input_checkpoint_updated -> () | Input_checkpoint_source_changed _ -> fail "independent input not published");
    check bool "independent global input cannot consume original wait" true (has_wait (get store original.id));
    (match Store.start_autonomous_execution store ~id:(scope 3) ~input:(input 3) ~sources:original.sources ~now:1e12 with
     | Error (Store.Sources_owned owners) -> check bool "original source remains reserved" true (List.exists (Scope.equal original.id) owners)
     | _ -> fail "a fresh UUID stole the parked source");
    (match defer store original ~observed:None ~waiting |> semantic with
     | Store.Autonomous_input_wait_existing observed -> check bool "exact duplicate is observation only" true (has_wait observed)
     | _ -> fail "same wait was republished");
    check bool "duplicate leaves independent input unchanged" true (current_input store=Store.Input_observed independent);
    let released=Store.take_released_checkpoints store in
    check bool "parked checkpoint never receives deletion authority" false
      (List.exists (fun released -> Keeper_checkpoint_ref.equal (Store.released_reference released) owned) released);
    (match Store.inspect_outstanding ~path |> stored with
     | Store.Stored_operations {semantic_executions;_} ->
       check bool "read-only inventory still pins the original wait" true
         (List.exists (fun execution -> Scope.equal execution.Semantic.id original.id
           && List.exists (Keeper_checkpoint_ref.equal owned) (Semantic.checkpoint_references execution)) semantic_executions)
     | Missing_store -> fail "actual journal disappeared"))

let test_stale_predecessor_and_changed_request_refuse () = with_path @@ fun path ->
  with_store path (fun store ->
    let original=start store 1 in
    ignore (Store.update_input_checkpoint store ~now:1. ~observed:None ~checkpoint:before |> stored);
    (match defer store original ~observed:None ~waiting |> semantic with
     | Store.Autonomous_input_wait_source_changed (Store.Input_observed observed) ->
       check bool "stale result names actual predecessor" true (Keeper_checkpoint_ref.equal observed before)
     | _ -> fail "stale predecessor was accepted");
    check bool "stale publication changes neither relation" true
      (Semantic.to_json (get store original.id)=Semantic.to_json original && current_input store=Store.Input_observed before);
    ignore (defer store original ~observed:(Some before) ~waiting |> semantic |> installed);
    let replacement=Semantic.input_wait ~checkpoint:owned
      ~pending:{pending with request={pending.request with question="conflicting canonical question"}} |> value in
    (match defer store original ~observed:(Some before) ~waiting:replacement with
     | Error (Store.Semantic_store_error (Store.Invalid_input _)) -> ()
     | _ -> fail "matching request IDs replaced the canonical question");
    (match Store.defer_autonomous_input_wait store ~now:3. ~id:original.id ~input_sha256:(hash "foreign input")
       ~observed:(Some before) ~waiting with
     | Error (Store.Semantic_store_error (Store.Invalid_input _)) -> ()
     | _ -> fail "changed original input digest was accepted");
    check bool "refusals preserve canonical wait and input" true
      (has_wait (get store original.id) && current_input store=Store.Input_observed owned))

let test_direct_identity_is_not_an_autonomous_alias () = with_path @@ fun path ->
  with_store path (fun store ->
    let id=Scope.direct_operation (Chat.Operation_id.of_string "direct" |> value) in
    (match Store.start_autonomous_execution store ~id ~input:(input 1) ~sources:[source 1] ~now:1. with
     | Error (Store.Semantic_store_error (Store.Invalid_input _)) -> ()
     | _ -> fail "direct identity became an autonomous admission");
    check bool "rejected alias creates no semantic record" true ((Store.semantic_get store id |> semantic) = None);
    check bool "rejected alias creates no input owner" true (current_input store=Store.Input_unobserved))

let test_wait_commit_fault after_commit () = with_path @@ fun path ->
  let original=with_store path (fun store ->
    let original=start store 1 in
    ignore (Store.update_input_checkpoint store ~now:1. ~observed:None ~checkpoint:before |> stored);
    ignore (Store.take_released_checkpoints store);
    Store.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
    (match defer store original ~observed:(Some before) ~waiting with
     | Error (Store.Semantic_store_error (Store.Store_unavailable _)) -> ()
     | _ -> fail "uncertain commit inferred successful acceptance");
    check int "uncertain result grants no retained deletion" 0 (List.length (Store.take_released_checkpoints store));
    original) in
  with_store path (fun store ->
    check bool "readback observes both relations or neither" true
      (if after_commit then has_wait (get store original.id) && current_input store=Store.Input_observed owned
       else (get store original.id).phase=Semantic.Running && current_input store=Store.Input_observed before))

let test_admission_commit_fault after_commit () = with_path @@ fun path ->
  with_store path (fun store ->
    Store.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
    (match Store.start_autonomous_execution store ~id:(scope 1) ~input:(input 1) ~sources:[source 1] ~now:1. with
     | Error (Store.Semantic_store_error (Store.Store_unavailable _)) -> ()
     | _ -> fail "uncertain admission granted dispatch authority"));
  with_store path (fun store ->
    let observed=Store.semantic_get store (scope 1) |> semantic in
    check bool "admission readback is all-or-none" after_commit (Option.is_some observed);
    (match Store.start_autonomous_execution store ~id:(scope 1) ~input:(input 1) ~sources:[source 1] ~now:2. |> semantic with
     | Store.Semantic_created execution when not after_commit ->
       check bool "confirmed absence admits same original UUID" true (Scope.equal execution.id (scope 1))
     | Semantic_existing execution when after_commit ->
       check bool "committed admission remains observation only" true
         (execution.input=Some (input 1) && execution.sources=[source 1] && execution.phase=Semantic.Running)
     | Semantic_created _ | Semantic_existing _ -> fail "uncertainty replaced or duplicated original admission");
    check bool "admission alone invents no input checkpoint" true (current_input store=Store.Input_unobserved))

let () = run "autonomous input wait journal"
  ["ownership",[
    test_case "restart and independent work preserve original waiting source" `Quick test_original_wait_survives_restart_and_independent_work;
    test_case "stale predecessors and changed canonical requests refuse" `Quick test_stale_predecessor_and_changed_request_refuse;
    test_case "direct identities cannot alias autonomous admissions" `Quick test_direct_identity_is_not_an_autonomous_alias];
   "commit uncertainty",[
    test_case "admission precommit fault reuses confirmed original identity" `Quick (test_admission_commit_fault false);
    test_case "admission acknowledgement loss preserves original identity" `Quick (test_admission_commit_fault true);
    test_case "precommit fault preserves both original relations" `Quick (test_wait_commit_fault false);
    test_case "lost commit acknowledgement preserves actual parked relations" `Quick (test_wait_commit_fault true)]]
