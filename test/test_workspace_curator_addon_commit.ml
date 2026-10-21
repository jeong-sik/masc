(** Real original journal and domain storage. Save-edge faults below explicitly
    simulate receipt loss; they do not claim a filesystem-stage fault. *)
open Alcotest
open Masc
module Capture = Workspace_memory_execution_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Store = Lane_addon_store
module Ledger = Workspace_memory_ledger
module Briefing = Workspace_memory_briefing
module Request = Workspace_memory_request
module Context = Workspace_memory_context
module Current = Keeper_memory_os_current
module Types = Keeper_memory_os_types
module Consumer = Server_workspace_memory_addon
let get = function Ok value -> value | Error detail -> fail detail
let accepted value=get (Result.map_error Consumer.error_to_string value)
let owned value=get (Result.map_error Owner.error_to_string value)
let json=testable Yojson.Safe.pp Yojson.Safe.equal
let ()=Mirage_crypto_rng_unix.use_default ()
let resolution effective : Prompt_registry.prompt_resolution =
  {effective;source=Prompt_registry.Override;file_value=None;override_value=Some effective;
   file_path=None;file_exists=false;has_override=true}
let briefing_template="Summarize {{workspace_memory_briefing}}"
let contract=Briefing.contract ~template:briefing_template
let with_workspace f =
  let base_path=Filename.temp_dir "curator-domain-commit-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config")) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
        f base_path (Store.create ~root:(Filename.concat base_path "host-store")))))))
let commit_facts base_path claims =
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let keeper_id="writer" in
  let expected_revision=match get (Current.read_for_keepers_dir ~keepers_dir ~keeper_id) with
    | None -> None | Some snapshot -> Some snapshot.revision in
  let now=1_700_000_000. in
  let facts=List.map (fun claim -> Types.observed ~claim ~category:Types.Fact ~now
    ~origin:{kind=Types.Authored;trace_id="original-domain-commit"}) claims in
  get (Current.replace ~keepers_dir ~keeper_id ~expected_revision ~now
    ~source:{kind=Current.Librarian;trace_id="original-domain-commit"} ~facts ()) |> ignore
let destination : Capture.destination = {
  installation_id=Owner.installation_id (Owner.Configuration "curator");package_id="workspace-curator";
  tool="curate";source_revision="domain-fixture";configuration_revision="original"}
let classification base_path claims =
  commit_facts base_path claims;
  let context=get (Context.collect ~base_path) in
  let current=Ledger.reconcile Ledger.empty (Context.keepers context) in
  let prompt=resolution "Classify {{workspace_memory_changes}}" in
  let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_curator
    prompt ["workspace_memory_changes",Yojson.Safe.to_string input] in
  let batch=match Request.prepare ~neighbor_limit:0 ~render ~ledger:Ledger.empty
      ~current:current.current_facts ~pending:current.new_facts |> Result.map_error Request.error_to_string |> get with
    | Some batch -> batch | None -> fail "expected original changed facts" in
  let capture=get (Capture.classification ~request_id:(Capture.Request_id.fresh ())
    ~workspace:(get (Capture.observe_workspace ~base_path)) ~destination ~prompt ~ledger:Ledger.empty ~batch) in
  let output=`Assoc ["decisions",`List (List.map (fun (fact : Ledger.pending_fact) ->
    `Assoc ["fact_id",`String (Request.fact_id fact.fact);"kind",`String "create_claim";"value",`String fact.claim]) batch.selected)] in
  capture,output
let after capture output=get (Capture.validate_output capture output)
let save base_path = function
  | Capture.Classification_commit ledger -> Ledger.save ~base_path ledger
  | Capture.Briefing_commit state -> Briefing.save ~directory:(Ledger.directory ~base_path) state
let advance store record event=match Owner.advance ~store ~expected:record ~event
    |> Result.map_error Owner.update_error_to_string |> get with
  | Owner.Stored record -> record
  | Owner.Already_stored _ | Owner.Unconfirmed _ -> fail "fixture needs a fresh recorded fact"
let retain_capture store capture =
  let request_id=Capture.Request_id.to_string (Capture.request_id capture) in
  owned (Owner.retain ~store ~scope:Capture.scope ~request_id ~installation_id:destination.installation_id
    ~package_id:destination.package_id ~tool:destination.tool ~request:(Capture.to_json capture));
  let record=match owned (Owner.load ~store ~scope:Capture.scope ~request_id) with
    | Some record -> record | None -> fail "missing original capture" in
  record
let retain store capture output =
  let record=advance store (retain_capture store capture) Progress.Dispatch_intended in
  advance store record (Progress.Judgment_retained (`Assoc ["status",`String "answered";
    "slot",`String "original";"output",output]))
let settle ?(briefing_contract=(fun () -> contract)) ~save base_path store (record : Owner.retained) =
  Consumer.For_testing.settle ~store:(Store.create ~root:(Store.root store)) ~base_path
    ~request_id:record.request_id ~briefing_contract ~save
let committed = function
  | Consumer.Committed record -> record
  | Consumer.Commit_waiting _ | Consumer.Commit_conflict _ -> fail "original commit was not confirmed"
let conflicted = function
  | Consumer.Commit_conflict record -> record
  | Consumer.Commit_waiting _ | Consumer.Committed _ -> fail "changed state was not preserved as conflict"
let no_save _=fail "recovery must not repeat a domain write"
let change capture output : Progress.change = match Capture.work capture,after capture output with
  | Capture.Classification {ledger;_},Capture.Classification_commit after ->
    {before=`Assoc ["kind",`String "classification";"state",Ledger.to_json ledger];
     after=`Assoc ["kind",`String "classification";"state",Ledger.to_json after]}
  | Capture.Briefing batch,Capture.Briefing_commit after ->
    {before=`Assoc ["kind",`String "briefing";"state",Briefing.to_json (Briefing.prepared_state batch)];
     after=`Assoc ["kind",`String "briefing";"state",Briefing.to_json after]}
  | Capture.Classification _,Capture.Briefing_commit _ | Capture.Briefing _,Capture.Classification_commit _ -> fail "domain differs"
let test_classification_commit_and_reopen ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["First original fact"] in
  let record=retain store capture output in
  let record=settle ~save:(save base_path) base_path store record |> accepted |> committed in
  (match after capture output with
   | Capture.Classification_commit expected -> check json "actual ledger equals the full original judgment"
       (Ledger.to_json expected) (Ledger.to_json (get (Ledger.load ~base_path)))
   | Capture.Briefing_commit _ -> fail "classification changed domain");
  settle ~save:no_save base_path store record |> accepted |> committed |> ignore)
let test_lost_save_receipt_after_publication ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original fact before lost receipt"] in
  let record=retain store capture output in
  let lost expected=let _=get (save base_path expected) in Error "simulated lost receipt after real save" in
  check bool "lost save receipt is uncertain" true
    (match settle ~save:lost base_path store record with Error (Consumer.Uncertain _) -> true
     | Ok _ | Error (Consumer.Unavailable _ | Consumer.Rejected _) -> false);
  (* After wins even when source freshness changes while the owner is down. *)
  commit_facts base_path [];
  settle ~save:no_save base_path store record |> accepted |> committed |> ignore)
let test_save_exception_preserves_original_intent ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original fact before save exception"] in
  let record=retain store capture output in
  let raised expected=get (save base_path expected);raise Exit in
  (match settle ~save:raised base_path store record with
   | Ok _ | Error _ -> fail "original save exception was swallowed"
   | exception Exit -> ());
  settle ~save:no_save base_path store record |> accepted |> committed |> ignore)
let test_malformed_domain_retains_one_uncertainty ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original fact before corrupt domain read"] in
  let record=retain store capture output in
  let directory=Ledger.directory ~base_path in
  Fs_compat.mkdir_p directory;
  let path=Filename.concat directory "ledger.json" in
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel "malformed domain state");
  let read ()=check bool "unreadable domain is uncertain, never a before-state" true
    (match settle ~save:no_save base_path store record with
     | Error (Consumer.Uncertain _) -> true | Ok _ | Error (Consumer.Rejected _ | Consumer.Unavailable _) -> false) in
  let current ()=match owned (Owner.load ~store ~scope:Capture.scope ~request_id:record.request_id) with
    | Some record -> Progress.to_json record.progress | None -> fail "uncertainty lost original record" in
  read ();let first=current () in
  List.iter (fun () -> read ();check json "equal unreadable-state evidence does not grow the journal" first (current ())) [();();()];
  check string "malformed domain bytes are untouched" "malformed domain state" (In_channel.with_open_bin path In_channel.input_all))
let test_refused_write_and_recovered_intent retry_only ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original fact before interrupted commit"] in
  let record=retain store capture output in
  let record=if retry_only then advance store record (Progress.Commit_intended (change capture output)) else record in
  if not retry_only then
    check bool "save-edge refusal remains uncertain" true
      (match settle ~save:(fun _ -> Error "simulated failure before domain save") base_path store record with
       | Error (Consumer.Uncertain _) -> true | Ok _ | Error (Consumer.Unavailable _ | Consumer.Rejected _) -> false);
  let result=settle ~save:(save base_path) base_path store record |> accepted |> committed in
  check bool "fresh retry observation survives actual journal reopen" true
    (List.exists (function Progress.Commit_retry_observed _ -> true
      | Dispatch_intended | Admission_declined _ | Execution_observed _ | Judgment_retained _ | Commit_intended _
      | Commit_uncertain _ | Commit_observed _ | Commit_conflicted _ | Refused _ | Successor_intended _ | Successor_observed _ -> false) (Progress.events result.progress));
  settle ~save:no_save base_path store result |> accepted |> committed |> ignore)
let test_changed_or_unreadable_sources unreadable ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original selected source"] in
  let record=retain store capture output in
  if unreadable then (
    let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let path=Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"writer" in
    Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel "malformed"))
  else commit_facts base_path ["Changed source while the model was running"];
  let result=settle ~save:no_save base_path store record in
  if unreadable then check bool "unreadable source is not authoritative absence" true
    (match result with Error (Consumer.Unavailable _) -> true | Ok _ | Error (Consumer.Uncertain _ | Consumer.Rejected _) -> false)
  else accepted result |> conflicted |> ignore;
  check json "old judgment never overwrites the ledger" (Ledger.to_json Ledger.empty) (Ledger.to_json (get (Ledger.load ~base_path))))
let test_other_domain_state_or_tampered_intent tampered ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original selected source"] in
  let record=retain store capture output in
  if tampered then (
    let change=change capture output in
    let record=advance store record (Progress.Commit_intended {change with after=`Assoc []}) in
    check bool "journal cannot substitute an arbitrary after-state" true
      (match settle ~save:no_save base_path store record with Error (Consumer.Rejected _) -> true
       | Ok _ | Error (Consumer.Unavailable _ | Consumer.Uncertain _) -> false))
  else (
    let other,answer=classification base_path ["Another owner published this ledger"] in
    get (save base_path (after other answer));
    let original=Ledger.to_json (get (Ledger.load ~base_path)) in
    settle ~save:no_save base_path store record |> accepted |> conflicted |> ignore;
    check json "other owner's full state survives" original (Ledger.to_json (get (Ledger.load ~base_path)))))
let prepare_briefing base_path ledger state =
  let prompt=resolution briefing_template in
  let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_briefing
    prompt ["workspace_memory_briefing",Yojson.Safe.to_string input] in
  let full=match get (Briefing.prepare ~sources:(Ledger.briefing_sources ledger) ~contract ~render state) with
    | Briefing.Prepared batch -> batch | Briefing.Unchanged | Briefing.Cleanup _ -> fail "expected original briefing" in
  let batch=match get (Briefing.narrow ~render full) with Some batch -> batch | None -> full in
  let capture=get (Capture.briefing ~request_id:(Capture.Request_id.fresh ())
    ~workspace:(get (Capture.observe_workspace ~base_path)) ~destination ~prompt ~batch) in
  batch,capture,`Assoc ["briefing",`String "Original partial semantic summary"]
type briefing_change = Keep_sources | Add_source | Remove_source | Change_contract | Missing_preparation
let test_briefing_pass modification ()=with_workspace (fun base_path store ->
  let first,answer=classification base_path ["Previously published fact"] in
  let old_ledger=match after first answer with Capture.Classification_commit ledger -> ledger
    | Capture.Briefing_commit _ -> fail "expected ledger" in
  let old_sources=Ledger.briefing_sources old_ledger in
  let old_batch,_,_=prepare_briefing base_path old_ledger Briefing.empty in
  let published=get (Briefing.accept old_batch ~text:"Previous complete publication") in
  let all,answer=classification base_path ["Previously published fact";"New fact a";"New fact b"] in
  let ledger=match after all answer with Capture.Classification_commit ledger -> ledger
    | Capture.Briefing_commit _ -> fail "expected ledger" in
  get (Ledger.save ~base_path ledger);
  let batch,capture,output=prepare_briefing base_path ledger published in
  check int "partial chunk retains another whole source" 1 (Briefing.remaining_count batch);
  let directory=Ledger.directory ~base_path in
  get (Briefing.save ~directory (match modification with Missing_preparation -> published
    | Keep_sources | Add_source | Remove_source | Change_contract -> Briefing.prepared_state batch));
  let record=retain store capture output in
  (match modification with
   | Add_source -> let extra,out=classification base_path ["Previously published fact";"New fact a";"New fact b";"Later addition"] in
     get (save base_path (after extra out))
   | Remove_source -> get (Ledger.save ~base_path old_ledger)
   | Keep_sources | Change_contract | Missing_preparation -> ());
  let changed_contract ()=match modification with Change_contract -> Briefing.contract ~template:"New effective template"
    | Keep_sources | Add_source | Remove_source | Missing_preparation -> contract in
  let permitted=match modification with Keep_sources | Add_source -> true
    | Remove_source | Change_contract | Missing_preparation -> false in
  let result=settle ~briefing_contract:changed_contract ~save:(if permitted then save base_path else no_save) base_path store record |> accepted in
  if permitted then (
    let result=committed result in
    let state=get (Briefing.load ~directory) in
    (match Briefing.observe ~sources:old_sources ~contract state with
     | Briefing.Current summary -> check string "partial commit preserves previous publication" "Previous complete publication" summary.text
     | Briefing.Missing | Briefing.Stale _ -> fail "previous publication disappeared");
    check bool "partial pass advances the complete original state" true
      (match after capture output with Capture.Briefing_commit expected -> Yojson.Safe.equal (Briefing.to_json expected) (Briefing.to_json state)
       | Capture.Classification_commit _ -> false);
    settle ~briefing_contract:changed_contract ~save:no_save base_path store result |> accepted |> committed |> ignore;
    let final_batch,final_capture,_=prepare_briefing base_path ledger state in
    check int "only the original remaining chunk is prepared" 0 (Briefing.remaining_count final_batch);
    get (Briefing.save ~directory (Briefing.prepared_state final_batch));
    let final_record=retain store final_capture (`Assoc ["briefing",`String "Completed original fixed pass"]) in
    settle ~briefing_contract:changed_contract ~save:(save base_path) base_path store final_record |> accepted |> committed |> ignore;
    let complete=get (Briefing.load ~directory) in
    (match Briefing.observe ~sources:(Ledger.briefing_sources ledger) ~contract complete with
     | Briefing.Current summary -> check string "final chunk alone replaces the publication" "Completed original fixed pass" summary.text
     | Briefing.Missing | Briefing.Stale _ -> fail "complete original pass was not published");
    if modification=Add_source then
      let fresh=get (Ledger.load ~base_path) in
      check bool "later additions still require a separate pass" true
        (Briefing.needs_refresh ~sources:(Ledger.briefing_sources fresh) ~contract complete))
  else conflicted result |> ignore)
module Exact = Lane_addon_exact
let size_input=Exact.Call_final (Exact.Input_refused Exact.Input_capacity)
let size_output=Exact.Call_final (Exact.Output_limit_reached {detail="Actual provider output limit"})
let refuse store capture final =
  let record=advance store (retain_capture store capture) Progress.Dispatch_intended in
  advance store record (Progress.Refused {stage=Progress.Execution;evidence=Exact.final_to_json final})
let narrow base_path store (record : Owner.retained) =
  Consumer.For_testing.narrow ~store:(Store.create ~root:(Store.root store)) ~base_path ~request_id:record.request_id
let successor = function
  | Consumer.Successor_ready {parent;child} -> parent,child
  | Consumer.Indivisible _ | Consumer.Successor_waiting _ -> fail "expected one confirmed original child"
let restore_capture base_path store record = Capture.restore
  ~workspace:(get (Capture.observe_workspace ~base_path))
  ~load:(fun ~request_id -> Owner.load ~store ~scope:Capture.scope ~request_id
    |> Result.map_error Owner.error_to_string) record
let original store capture = match owned (Owner.load ~store ~scope:Capture.scope
    ~request_id:(Capture.Request_id.to_string (Capture.request_id capture))) with
  | Some record -> record | None -> fail "expected original retained request"
let intent store capture final =
  let parent=refuse store capture final in
  let child=match get (Capture.narrow ~request_id:(Capture.Request_id.fresh ()) ~final capture) with
    | Some child -> child | None -> fail "expected a smaller whole batch" in
  let request=get (Lane_addon_action.canonical (Capture.to_json child)) in
  let intent : Progress.successor = {request_id=Capture.Request_id.to_string (Capture.request_id child);request} in
  advance store parent (Progress.Successor_intended intent),child,intent
let no_call ~arguments:_=fail "successor linkage cannot call a worker"
let no_worker_resume base_path store (record : Owner.retained) =
  Consumer.For_testing.resume ~store ~base_path ~request_id:record.request_id ~call:no_call
let test_successor_keeps_whole_rows_and_one_child final ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Original entire fact a";"Original entire fact b";
    "Original entire fact c";"Original entire fact d"] in
  let parent=refuse store capture final in
  let ledger_before=Ledger.to_json (get (Ledger.load ~base_path)) in
  let parent,child=narrow base_path store parent |> accepted |> successor in
  check bool "child ID differs from the terminal original" true (parent.request_id<>child.request_id);
  let smaller=get (restore_capture base_path store child) in
  check string "immutable predecessor identifies the original parent" parent.request_id
    (match Capture.predecessor smaller with Some id -> Capture.Request_id.to_string id | None -> fail "missing predecessor");
  check bool "original destination and revisions survive narrowing" true
    (Capture.destination smaller=Capture.destination capture);
  (match Capture.work capture,Capture.work smaller with
   | Capture.Classification original,Capture.Classification child ->
     check bool "whole selected prefix and unconsumed suffix are conserved" true
       (child.batch.selected=List.take 2 original.batch.selected
        && child.batch.remaining=List.drop 2 original.batch.selected @ original.batch.remaining);
     check json "complete original row payloads survive" (match original.batch.input with
       | `Assoc fields -> `List (List.take 2 (match List.assoc "new_facts" fields with `List rows -> rows | _ -> fail "rows"))
       | _ -> fail "original input") (Yojson.Safe.Util.member "new_facts" child.batch.input);
     check json "captured classification ledger stays unchanged" (Ledger.to_json original.ledger) (Ledger.to_json child.ledger)
   | Capture.Classification _,Capture.Briefing _ | Capture.Briefing _,(Capture.Classification _ | Capture.Briefing _) -> fail "wrong domain");
  check json "linking never saves a domain state" ledger_before (Ledger.to_json (get (Ledger.load ~base_path)));
  let parent_again,child_again=narrow base_path store parent |> accepted |> successor in
  check string "reopened parent reuses the same child" child.request_id child_again.request_id;
  check json "repeated linkage does not append a parent fact" (Progress.to_json parent.progress) (Progress.to_json parent_again.progress);
  check json "unstarted child remains Captured" (`List []) (Progress.to_json child_again.progress);
  check int "strict discovery contains only the original and one child" 2
    (List.length (owned (Owner.discover ~store ~scope:Capture.scope)));
  (match no_worker_resume base_path store parent with
   | Ok (Consumer.Terminal (restored,_)) -> check json "parent keeps its original terminal" (Exact.final_to_json final) (Exact.final_to_json restored)
   | Ok _ | Error _ -> fail "parent terminal changed"))
let test_successor_recovers_intent child_published ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Original fact a";"Original fact b";"Original fact c"] in
  let parent,child,intended=intent store capture size_input in
  if child_published then (
    let child_record=retain_capture store child in
    check bool "child cannot execute before parent acknowledgement" true
      (match no_worker_resume base_path store child_record with Error (Consumer.Rejected _) -> true
       | Ok _ | Error (Consumer.Unavailable _ | Consumer.Uncertain _) -> false);
    check bool "ordinary capture restore has no unacknowledged escape" true
      (Result.is_error (restore_capture base_path store child_record)));
  let parent,child=narrow base_path store parent |> accepted |> successor in
  check string "recovery uses the durably selected ID" intended.request_id child.request_id;
  check json "recovery keeps the complete original child bytes" intended.request child.request;
  check bool "strict parent has acknowledged that child" true (match Progress.phase parent.progress with
    | Progress.Subdivided (_,actual) -> actual=intended
    | _ -> false);
  get (restore_capture base_path store child) |> ignore)
let test_successor_pending_and_non_size_refuse ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Source a";"Source b"] in
  let parent=retain_capture store capture in
  let unchanged record=check bool "non-size authority cannot mint a child" true (Result.is_error (narrow base_path store record)) in
  unchanged parent;
  let pending=advance store parent Progress.Dispatch_intended in
  unchanged pending;
  let unknown=advance store pending (Progress.Execution_observed (Progress.Outcome_unknown (`Assoc ["detail",`String "lost"]))) in
  unchanged unknown;
  let refused=advance store unknown (Progress.Refused {stage=Progress.Execution;
    evidence=Exact.final_to_json (Exact.Call_final (Exact.Invalid_output {detail="invalid JSON, not a size refusal"}))}) in
  unchanged refused;
  check int "no unrelated request was invented" 1 (List.length (owned (Owner.discover ~store ~scope:Capture.scope))))
let test_indivisible_terminal ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["One indivisible entire source, including all of its text"] in
  let parent=refuse store capture size_input in
  check bool "single original fact is reported without truncation or new work" true
    (match narrow base_path store parent |> accepted with Consumer.Indivisible record -> record.request_id=parent.request_id
     | Consumer.Successor_ready _ | Consumer.Successor_waiting _ -> false);
  check int "singleton remains one terminal capture" 1 (List.length (owned (Owner.discover ~store ~scope:Capture.scope))))
let child_record_path store (record : Owner.retained) = Filename.concat (Store.root store)
  (Filename.concat "tool-request-owners" (Filename.concat (Store.digest Capture.scope) (Store.digest record.request_id ^ ".json")))
let test_acknowledged_missing_child_is_not_recreated ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Original source a";"Original source b"] in
  let parent,child=narrow base_path store (refuse store capture size_input) |> accepted |> successor in
  let dispatched=advance store child Progress.Dispatch_intended in
  let path=child_record_path store child in
  Unix.rename path (path ^ ".removed");
  check bool "lost child dispatch history is not new admission permission" true
    (match narrow base_path store parent with Error (Consumer.Unavailable _) -> true
     | Ok _ | Error (Consumer.Rejected _ | Consumer.Uncertain _) -> false);
  check bool "acknowledged absent child remains absent" true
    (owned (Owner.load ~store ~scope:Capture.scope ~request_id:child.request_id)=None);
  Unix.rename (path ^ ".removed") path;
  let _,recovered=narrow base_path store parent |> accepted |> successor in
  check json "restored child keeps its dispatch uncertainty" (Progress.to_json dispatched.progress) (Progress.to_json recovered.progress))
let test_conflicting_child_cannot_change_parent_intent ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Original source a";"Original source b"] in
  let parent,child,intended=intent store capture size_input in
  let destination=Capture.destination child in
  owned (Owner.retain ~store ~scope:Capture.scope ~request_id:intended.request_id
    ~installation_id:destination.installation_id ~package_id:destination.package_id ~tool:destination.tool
    ~request:(`Assoc ["unrelated",`Bool true]));
  check bool "conflict cannot retarget or mint another child" true (Result.is_error (narrow base_path store parent));
  check json "original intent remains authoritative" (Progress.to_json parent.progress)
    (Progress.to_json (original store capture).progress);
  check int "no replacement sibling was minted" 2 (List.length (owned (Owner.discover ~store ~scope:Capture.scope))))
let test_briefing_successor_keeps_prepared_state output_limit ()=with_workspace (fun base_path store ->
  let classification,answer=classification base_path ["Source a";"Source b";"Source c";"Source d"] in
  let ledger=match after classification answer with Capture.Classification_commit ledger -> ledger
    | Capture.Briefing_commit _ -> fail "ledger expected" in
  get (Ledger.save ~base_path ledger);
  let batch,capture,_=prepare_briefing base_path ledger Briefing.empty in
  let directory=Ledger.directory ~base_path in
  get (Briefing.save ~directory (Briefing.prepared_state batch));
  let before=Briefing.to_json (get (Briefing.load ~directory)) in
  let parent=refuse store capture (if output_limit then size_output else size_input) in
  if output_limit then check bool "Briefing output limit never authorizes input reduction" true
    (Result.is_error (narrow base_path store parent))
  else (
    let _,child=narrow base_path store parent |> accepted |> successor in
    let child=get (restore_capture base_path store child) in
    match Capture.work child with
    | Capture.Briefing child ->
      check int "whole original entries are bisected" 1 (Briefing.selected_count child);
      check int "all unconsumed original sources remain" 3 (Briefing.remaining_count child);
      check json "child has the identical original prepared state" before (Briefing.to_json (Briefing.prepared_state child))
    | Capture.Classification _ -> fail "Briefing child changed domain");
  check json "linking does not save or advance briefing" before (Briefing.to_json (get (Briefing.load ~directory))))
let output_for capture = match Capture.work capture with
  | Capture.Classification {batch;_} -> `Assoc ["decisions",`List (List.map (fun (fact : Ledger.pending_fact) ->
      `Assoc ["fact_id",`String (Request.fact_id fact.fact);"kind",`String "create_claim";"value",`String fact.claim]) batch.selected)]
  | Capture.Briefing _ -> `Assoc ["briefing",`String "Original child semantic result"]
let test_child_can_answer_and_commit_only_its_original_prefix ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Original fact a";"Original fact b";"Original fact c";"Original fact d"] in
  let parent,child=narrow base_path store (refuse store capture size_input) |> accepted |> successor in
  let smaller=get (restore_capture base_path store child) in
  let output=output_for smaller in
  let call ~arguments =
    let state,fields=match Yojson.Safe.Util.member "kind" arguments with
      | `String "read" -> "absent",[]
      | `String "submit" -> "finished",["result",`Assoc ["status",`String "answered";"slot",`String "child-slot";"output",output]]
      | _ -> fail "unexpected child RPC" in
    Ok {(Mcp_protocol.Mcp_types.tool_result_of_text "child fixture reply") with
      structured_content=Some (`Assoc (["request_id",`String child.request_id;"state",`String state] @ fields))} in
  let result=Consumer.For_testing.resume ~store ~base_path ~request_id:child.request_id ~call |> accepted in
  let judgment=match result with Consumer.Judgment {record;_} -> record | _ -> fail "child did not retain its original judgment" in
  settle ~save:(save base_path) base_path store judgment |> accepted |> committed |> ignore;
  let current=get (Ledger.load ~base_path) in
  check int "only the original child prefix was applied" 2 (List.length (Ledger.dispositions current));
  let _,again=narrow base_path store parent |> accepted |> successor in
  settle ~save:no_save base_path store again |> accepted |> committed |> ignore)
let package ()=Lane_addon_manifest.load ~path:"../addons/workspace-curator/lane.toml"
  |> Result.map_error Lane_addon_manifest.error_to_string |> get
let authorize base_path store capture =
  let request=get (Server_workspace_memory_addon_validation.request capture) in
  Server_workspace_memory_addon_validation.authorize ~base_path ~store ~declaration_id:"curator" ~package:(package ()) request
let test_direct_exact_authority_requires_acknowledged_ancestry ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Source a";"Source b"] in
  let parent,child,_=intent store capture size_input in
  retain_capture store child |> ignore;
  check bool "direct Exact cannot bypass an unacknowledged predecessor" true
    (Result.is_error (authorize base_path store child));
  narrow base_path store parent |> accepted |> successor |> ignore;
  let validate=get (authorize base_path store child) in
  get (validate (output_for child)))
let test_missing_or_cyclic_parent_refuses missing ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Source a";"Source b"] in
  let parent,child=narrow base_path store (refuse store capture size_input) |> accepted |> successor in
  let smaller=get (restore_capture base_path store child) in
  if missing then (
    let path=child_record_path store parent in Unix.rename path (path ^ ".removed"))
  else (
    let request=match parent.request with
      | `Assoc fields -> `Assoc (List.map (fun (key,value) -> key,
          if key="predecessor" then `String child.request_id else value) fields)
      | _ -> fail "original parent capture" in
    let request=get (Lane_addon_action.canonical request) in
    let wire=match get (Store.load_tool_request_owner store ~scope:Capture.scope ~request_id:parent.request_id) with
      | Some (`Assoc fields) -> `Assoc (List.map (fun (key,value) -> key,
          if key="request" then request else if key="request_digest" then `String (Store.digest (Yojson.Safe.to_string request)) else value) fields)
      | Some _ | None -> fail "original parent wire" in
    get (Store.save_tool_request_owner store ~scope:Capture.scope ~request_id:parent.request_id wire));
  check bool "child resume cannot borrow missing or cyclic ancestry" true
    (match no_worker_resume base_path store child with Error (Consumer.Rejected _) -> true
     | Ok _ | Error (Consumer.Unavailable _ | Consumer.Uncertain _) -> false);
  check bool "direct Exact rejects the same broken ancestry" true (Result.is_error (authorize base_path store smaller)))
let test_nested_successor_has_no_root_sibling ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Source a";"Source b";"Source c";"Source d"] in
  let root,child=narrow base_path store (refuse store capture size_input) |> accepted |> successor in
  let child_capture=get (restore_capture base_path store child) in
  let child=refuse store child_capture size_output in
  let _,grandchild=narrow base_path store child |> accepted |> successor in
  let grandchild_capture=get (restore_capture base_path store grandchild) in
  check string "nested child links to its immediate original parent" child.request_id
    (match Capture.predecessor grandchild_capture with Some id -> Capture.Request_id.to_string id | None -> fail "missing parent");
  let _,same_child=narrow base_path store root |> accepted |> successor in
  check string "the root still names its first child" child.request_id same_child.request_id;
  check int "one root, one child, one grandchild only" 3 (List.length (owned (Owner.discover ~store ~scope:Capture.scope))))
let ()=run "Curator original domain commit and recovery" ["domain",[
  test_case "classification applies once and survives journal reopen" `Quick test_classification_commit_and_reopen;
  test_case "real save with lost receipt confirms after without another write" `Quick test_lost_save_receipt_after_publication;
  test_case "save exception preserves intent and propagates before recovery" `Quick test_save_exception_preserves_original_intent;
  test_case "malformed domain preserves one original uncertainty without writing" `Quick test_malformed_domain_retains_one_uncertainty;
  test_case "save-edge refusal retries only from freshly recorded before" `Quick (test_refused_write_and_recovered_intent false);
  test_case "recovered intent records unknown and fresh retry before write" `Quick (test_refused_write_and_recovered_intent true);
  test_case "changed selected source conflicts without writing" `Quick (test_changed_or_unreadable_sources false);
  test_case "unreadable selected source cannot become absence" `Quick (test_changed_or_unreadable_sources true);
  test_case "another owner's state is not overwritten" `Quick (test_other_domain_state_or_tampered_intent false);
  test_case "altered commit intent cannot authorize a domain write" `Quick (test_other_domain_state_or_tampered_intent true);
  test_case "partial briefing preserves its previous complete publication" `Quick (test_briefing_pass Keep_sources);
  test_case "source additions wait outside the original fixed pass" `Quick (test_briefing_pass Add_source);
  test_case "removed briefing target prevents old publication" `Quick (test_briefing_pass Remove_source);
  test_case "changed briefing contract prevents old publication" `Quick (test_briefing_pass Change_contract);
  test_case "missing prepared state is not created after the model" `Quick (test_briefing_pass Missing_preparation);
  test_case "input size successor conserves whole rows and survives reopen" `Quick (test_successor_keeps_whole_rows_and_one_child size_input);
  test_case "output size classification successor keeps one child" `Quick (test_successor_keeps_whole_rows_and_one_child size_output);
  test_case "intent without child recovers the same durable ID" `Quick (test_successor_recovers_intent false);
  test_case "retained child cannot execute before acknowledgement" `Quick (test_successor_recovers_intent true);
  test_case "pending unknown and invalid output cannot create a successor" `Quick test_successor_pending_and_non_size_refuse;
  test_case "one indivisible original fact is never truncated" `Quick test_indivisible_terminal;
  test_case "acknowledged missing child is not recreated as undispatched" `Quick test_acknowledged_missing_child_is_not_recreated;
  test_case "conflicting child cannot replace a durable parent intent" `Quick test_conflicting_child_cannot_change_parent_intent;
  test_case "input size Briefing child preserves prepared state" `Quick (test_briefing_successor_keeps_prepared_state false);
  test_case "Briefing output limit cannot reduce input" `Quick (test_briefing_successor_keeps_prepared_state true);
  test_case "acknowledged child answers and commits only its prefix" `Quick test_child_can_answer_and_commit_only_its_original_prefix;
  test_case "direct Exact authority cannot bypass parent acknowledgement" `Quick test_direct_exact_authority_requires_acknowledged_ancestry;
  test_case "missing predecessor refuses resume and direct Exact" `Quick (test_missing_or_cyclic_parent_refuses true);
  test_case "cyclic predecessor refuses resume and direct Exact" `Quick (test_missing_or_cyclic_parent_refuses false);
  test_case "nested refusal narrows the child without a root sibling" `Quick test_nested_successor_has_no_root_sibling]]
