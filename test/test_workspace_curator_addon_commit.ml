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
      ~current:current.current_facts ~pending:current.new_facts ~size:Request.Fill_frame ~frame:max_int ~measure:(fun _ -> Ok 0)
      |> Result.map_error Request.error_to_string |> get with
    | Some batch -> batch | None -> fail "expected original changed facts" in
  let capture=get (Capture.classification ~request_id:(Capture.Request_id.fresh ())
    ~workspace:(get (Capture.observe_workspace ~base_path)) ~destination ~prompt ~ledger:Ledger.empty ~batch) in
  let output=`Assoc ["decisions",`List (List.map (fun (id,(fact : Ledger.pending_fact)) ->
    `Assoc ["fact_id",`String id;"kind",`String "create_claim";"value",`String fact.claim]) (Request.selected_ids batch))] in
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
      | Commit_uncertain _ | Commit_observed _ | Commit_conflicted _ | Refused _ | Successor_intended _ | Successor_observed _
      | Observer _ -> false) (Progress.events result.progress));
  settle ~save:no_save base_path store result |> accepted |> committed |> ignore)
let test_changed_or_unreadable_sources ?(on_conflict=fun _ _ _ -> ()) unreadable ()=with_workspace (fun base_path store ->
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
  else on_conflict base_path store (accepted result |> conflicted);
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
let test_briefing_pass ?(on_conflict=fun _ _ _ -> ()) modification ()=with_workspace (fun base_path store ->
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
  else on_conflict base_path store (conflicted result))
module Exact = Lane_addon_exact

(* These fixtures exercise host publication, not real provider capture. Their
   explicit synthetic CLI success never claims API-only failure coverage. *)
let executed outcome =
  let module Receipt = Masc.Keeper_exact_walk_receipt in
  let declared_cli, dispatched, result = match outcome with
    | Exact.Call_ended (Exact.Answered {slot; _}) -> [slot], [slot], Receipt.Answered slot
    | Exact.Call_ended (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
    | Exact.Call_refused _ -> [], [], Receipt.Not_reached in
  let receipt = match Receipt.make ~declared_http:[] ~excluded_http:[] ~declared_cli
      ~http:(Receipt.http_not_started ~detail:"synthetic host publication fixture")
      ~cli:(Receipt.cli ~visited:dispatched ~dispatched ~failures:[] ~result) with
    | Ok receipt -> receipt | Error detail -> Alcotest.fail detail in
  {Exact.outcome; receipt}
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
     check bool "the oldest half of the selection is kept" true
       (child.batch.selected=List.take 2 original.batch.selected);
     check bool "each kept row keeps its fact and neighbors" true
       (child.batch.rows=List.take 2 original.batch.rows);
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
  | Capture.Classification {batch;_} -> `Assoc ["decisions",`List (List.map (fun (id,(fact : Ledger.pending_fact)) ->
      `Assoc ["fact_id",`String id;"kind",`String "create_claim";"value",`String fact.claim]) (Request.selected_ids batch))]
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
let host_result base_path store capture output =
  let request=get (Server_workspace_memory_addon_validation.request capture) in
  let runner ~admission_class:_ ~lane_key:_ ~schema:_ _=Ok (fun ~validate ->
    match validate output with
    | Ok output -> executed (Exact.Call_ended (Exact.Answered {output;slot="original-host";usage=None}))
    | Error detail -> executed (Exact.Call_ended (Exact.Invalid_output {detail}))) in
  get (Exact.run ~store ~declaration_id:"curator" ~package:(package ()) ~runner
    ~authorize_request:(Server_lane_addon_exact.authorize_request ~base_path) request)
let test_original_host_terminal_recovers_without_a_live_runtime ()=with_workspace (fun base_path _ ->
  let config=Workspace.default_config base_path in
  let store=Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let capture,output=classification base_path ["Original admitted fact a";"Original admitted fact b"] in
  let pending=advance store (retain_capture store capture) Progress.Dispatch_intended in
  (match host_result base_path store capture output with
   | Exact.Final (Exact.Call_final (Exact.Answered _)) -> () | _ -> fail "fixture needs an original host terminal");
  let record=match Consumer.resume ~config ~request_id:pending.request_id |> accepted with
    | Consumer.Judgment {record;expected=Capture.Classification_commit _;_} -> record
    | _ -> fail "original host result should need no Runtime/export/worker" in
  Consumer.settle ~config ~request_id:record.request_id |> accepted |> committed |> ignore;
  check int "original host judgment commits with no new worker" 2
    (List.length (Ledger.dispositions (get (Ledger.load ~base_path))));
  (match Consumer.resume ~config ~request_id:record.request_id |> accepted with
   | Consumer.Settled _ -> () | _ -> fail "completed original must remain settled"))
let test_bad_original_host_record_cannot_fall_back_to_a_worker ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original admitted source"] in
  let record=advance store (retain_capture store capture) Progress.Dispatch_intended in
  host_result base_path store capture output |> ignore;
  let wire=match get (Store.load_exact_request store ~declaration_id:"curator" ~request_id:record.request_id) with
    | Some (`Assoc fields) -> `Assoc (("unknown",`Bool true)::fields)
    | Some _ | None -> fail "original Exact record" in
  get (Store.save_exact_request store ~declaration_id:"curator" ~request_id:record.request_id wire);
  check bool "invalid host evidence refuses before the supplied worker edge" true
    (match no_worker_resume base_path store record with Error (Consumer.Unavailable _) -> true
     | Ok _ | Error (Consumer.Rejected _ | Consumer.Uncertain _) -> false);
  check json "failed read leaves the original dispatch history unchanged" (Progress.to_json record.progress)
    (Progress.to_json (original store capture).progress))
let test_observed_host_answer_still_requires_full_domain_validation ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original source"] in
  let record=advance store (retain_capture store capture) Progress.Dispatch_intended in
  host_result base_path store capture output |> ignore;
  let wire=match get (Store.load_exact_request store ~declaration_id:"curator" ~request_id:record.request_id) with
    | Some (`Assoc fields) ->
      let final=`Assoc ["status",`String "answered";"slot",`String "original-host";
        "output",`Assoc ["decisions",`List []]] in
      `Assoc (List.map (fun (key,value) -> key,if key="final" then final else value) fields)
    | Some _ | None -> fail "original Exact record" in
  get (Store.save_exact_request store ~declaration_id:"curator" ~request_id:record.request_id wire);
  check bool "partial wire shape is never a valid original domain judgment" true
    (match no_worker_resume base_path store record with Error (Consumer.Rejected _) -> true
     | Ok _ | Error (Consumer.Unavailable _ | Consumer.Uncertain _) -> false);
  check int "no invalid original disposition is committed" 0
    (List.length (Ledger.dispositions (get (Ledger.load ~base_path)))))
let test_installation_identity_is_canonical_and_kind_bound () =
  List.iter (fun installation ->
    let encoded=Owner.installation_id installation in
    check bool "original identity round trips without losing its kind" true
      (get (Owner.installation_of_id encoded)=installation)) [Owner.Configuration "curator";Owner.Manual "curator"];
  List.iter (fun encoded -> check bool "unknown blank extra or noncanonical installation refuses" true
      (Result.is_error (Owner.installation_of_id encoded)))
    ["curator";"[\"other\",\"curator\"]";"[\"configuration\",\"\"]";
     "[\"configuration\", \"curator\"]";"[\"manual\",\"curator\",false]"]
module Observation = Workspace_memory_observation_receipt
module Receipt = Lane_addon_request_receipt
let prepare_observation_result base_path store (record:Owner.retained) ~now =
  Consumer.For_testing.prepare_observation ~store:(Store.create ~root:(Store.root store))
    ~base_path ~request_id:record.request_id ~now
let prepare_observation base_path store record ~now =
  prepare_observation_result base_path store record ~now |> accepted
let observed_completion (observation:Consumer.observation) = match observation.completion with
  | Some completion -> completion | None -> fail "expected original domain completion receipt"
let never_clock () = fail "original receipt retry must not obtain a new time"
let owner_file store (record:Owner.retained) = Filename.concat
  (Filename.concat (Filename.concat (Store.root store) "tool-request-owners") (Store.digest record.scope))
  (Store.digest record.request_id ^ ".json")
let test_typed_observer_intents_follow_original_commit_without_runtime ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original fact for observation"] in
  let root=retain_capture store capture in
  let first=prepare_observation base_path store root ~now:(fun () -> 10.) in
  check bool "captured original has no invented completion" true (first.completion=None);
  check bool "observer intent leaves original primary phase Captured" true
    (Progress.phase first.original.progress=Progress.Captured);
  check int "preparing an observation does not commit a domain judgment" 0
    (List.length (Ledger.dispositions (get (Ledger.load ~base_path))));
  let path=owner_file store first.original in
  let bytes=Fs_compat.load_file path and identity=Unix.stat path in
  let again=prepare_observation base_path store first.original ~now:never_clock in
  let current=Unix.stat path in
  check string "unchanged pending receipt preserves journal bytes" bytes (Fs_compat.load_file path);
  check bool "unchanged pending receipt preserves journal identity" true
    (identity.st_dev=current.st_dev && identity.st_ino=current.st_ino && identity.st_mtime=current.st_mtime);
  let pending=advance store again.original Progress.Dispatch_intended in
  let judgment=`Assoc ["status",`String "answered";"slot",`String "original-provider";"output",output;
    "usage",`Assoc ["input_tokens",`Int 23;"output_tokens",`Int 7]] in
  let judged=advance store pending (Progress.Judgment_retained judgment) in
  let before_save=prepare_observation base_path store judged ~now:never_clock in
  check bool "model judgment alone is not a committed completion" true (before_save.completion=None);
  let finished=settle ~save:(save base_path) base_path store before_save.original |> accepted |> committed in
  let observed=prepare_observation base_path store finished ~now:(fun () -> 8.) in
  let completion=observed_completion observed in
  check (float 0.) "first original observer time survives domain commit" 10. observed.registration.receipt.observed_at;
  check (option string) "selected slot is the original answering slot" (Some "original-provider") completion.selected_slot;
  check bool "only actually reported basic usage is retained" true
    (completion.provider_usage=Some {Exact.input_tokens=23;output_tokens=7});
  (match completion.disposition with Observation.Confirmed_commit commit -> check json "full original final remains bound" judgment commit.judgment
   | Domain_conflict _ | Before_dispatch_refusal _ | Execution_refusal _ -> fail "confirmed original commit lost its kind");
  let timing=Yojson.Safe.Util.member "timing" completion.receipt.payload in
  List.iter (fun key -> check json "unmeasured provider statistics remain absent" `Null
    (Yojson.Safe.Util.member key timing)) ["provider_started_at";"provider_elapsed_s";"cache_usage";"cost_usd"];
  let reopened=prepare_observation base_path store observed.original ~now:never_clock in
  check json "complete original receipt survives reopen without a new clock" (Receipt.to_json completion.receipt)
    (Receipt.to_json (observed_completion reopened).receipt);
  check json "complete original input survives receipt preparation" first.registration.input reopened.registration.input;
  check bool "registration may remain pending after domain completion" true
    (match (Progress.observer reopened.original.progress).registration with Receipt.Pending _ -> true
     | Unobserved | Acknowledged _ -> false))

let replace_field key value = function
  | `Assoc fields -> `Assoc (List.map (fun (name,old) -> name,if name=key then value else old) fields)
  | _ -> fail "expected an object"
module Runs = Exact_lane_run_registry
let registry_at base_path =
  let path=Filename.concat base_path Runs.storage_filename in
  path,Runs.replay path
let delivery base_path store registry (record:Owner.retained) ~now =
  Consumer.For_testing.deliver_observation ~store ~base_path ~registry ~request_id:record.request_id ~now
let observation_accepted value=get (Result.map_error Consumer.observation_error_to_string value)
let acknowledged = function Receipt.Acknowledged _ -> true | Pending _ | Unobserved -> false
let test_actual_observer_delivery_and_ack_retry ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original fact delivered to the real registry"] in
  let finished=retain store capture output |> fun record -> settle ~save:(save base_path) base_path store record
    |> accepted |> committed in
  let prepared=prepare_observation base_path store finished ~now:(fun () -> 21.) in
  let completion=observed_completion prepared in
  let path,registry=registry_at base_path in
  (* Real registry publication with the original Owner still pending models the
     durable boundary before a lost ACK; it does not inject a filesystem fault. *)
  Runs.reconcile_original registry ~run_id:prepared.registration.run_id ~lane:Runs.Workspace_curator
    ~actor:prepared.registration.actor ~started_at:prepared.registration.receipt.observed_at
    ~input:(Runs.Exact_input prepared.registration.input)
    ~completion:(Some {Runs.outcome=Runs.Succeeded;elapsed_s=None;selected_slot=completion.selected_slot;
      usage=None;output=Receipt.to_json completion.receipt})
    |> Result.map_error Runs.reconciliation_error_to_string |> get;
  let restarted=Runs.replay path in
  let bytes=Fs_compat.load_file path and stat=Unix.stat path in
  let delivered=delivery base_path store restarted prepared.original ~now:never_clock |> observation_accepted in
  let observer=Progress.observer delivered.original.progress in
  check bool "registration ACK is durable" true (acknowledged observer.registration);
  check bool "completion ACK is durable after registration" true (acknowledged observer.completion);
  check string "lost ACK retry never appends another lifecycle" bytes (Fs_compat.load_file path);
  check int "lost ACK retry preserves log inode" stat.st_ino (Unix.stat path).st_ino;
  check int "delivery never repeats a domain save" 1
    (List.length (Ledger.dispositions (get (Ledger.load ~base_path))));
  let journal=Fs_compat.load_file (owner_file store delivered.original) in
  Unix.unlink path;
  let no_authority=Runs.create () in
  ignore (delivery base_path store no_authority delivered.original ~now:never_clock |> observation_accepted);
  check bool "already ACKed work never recreates evicted history" false (Sys.file_exists path);
  check string "already ACKed work keeps original journal bytes" journal
    (Fs_compat.load_file (owner_file store delivered.original)))
let test_registration_delivery_does_not_invent_completion ()=with_workspace (fun base_path store ->
  let capture,_output=classification base_path ["Active original without a terminal"] in
  let original=retain_capture store capture in
  let path,registry=registry_at base_path in
  let delivered=delivery base_path store registry original ~now:(fun () -> 31.) |> observation_accepted in
  let observer=Progress.observer delivered.original.progress in
  check bool "start is ACKed without primary execution" true (acknowledged observer.registration);
  check bool "no terminal is fabricated" true (observer.completion=Receipt.Unobserved);
  check bool "primary stays Captured" true (Progress.phase delivered.original.progress=Progress.Captured);
  let bytes=Fs_compat.load_file path in
  ignore (delivery base_path store registry delivered.original ~now:never_clock |> observation_accepted);
  check string "ACKed active original is not re-registered" bytes (Fs_compat.load_file path))
let test_failed_registry_keeps_original_pending ()=with_workspace (fun base_path store ->
  let capture,_output=classification base_path ["Unavailable registry preserves original intention"] in
  let original=retain_capture store capture in
  let prepared=prepare_observation base_path store original ~now:(fun () -> 41.) in
  let path=owner_file store prepared.original in
  let bytes=Fs_compat.load_file path in
  (match delivery base_path store (Runs.create ()) prepared.original ~now:never_clock with
   | Error (Consumer.Registry_delivery_failed (Runs.Reconciliation_unavailable _)) -> ()
   | Error (Original_observation_failed _ | Registry_delivery_failed
       (Invalid_original _ | Original_registration_conflict | Original_completion_conflict
        | Failed_completion_conflict | Reconciliation_persistence_failed _))
   | Ok _ -> fail "volatile registry must refuse durable acknowledgement");
  check string "registry failure preserves immutable pending original" bytes (Fs_compat.load_file path);
  let log_path,registry=registry_at base_path in
  let delivered=delivery base_path store registry prepared.original ~now:never_clock |> observation_accepted in
  check bool "later exact retry acknowledges original" true
    (acknowledged (Progress.observer delivered.original.progress).registration);
  check bool "later retry uses the actual file-backed registry" true (Sys.file_exists log_path))

let test_conflicting_registry_keeps_original_pending ()=with_workspace (fun base_path store ->
  let capture,_output=classification base_path ["A registry conflict is not primary authority"] in
  let original=retain_capture store capture in
  let prepared=prepare_observation base_path store original ~now:(fun () -> 43.) in
  let path,registry=registry_at base_path in
  Runs.reconcile_original registry ~run_id:prepared.registration.run_id ~lane:Runs.Workspace_curator
    ~actor:"another-observer-actor" ~started_at:prepared.registration.receipt.observed_at
    ~input:(Runs.Exact_input prepared.registration.input) ~completion:None
    |> Result.map_error Runs.reconciliation_error_to_string |> get;
  let owner_before=Fs_compat.load_file (owner_file store prepared.original)
  and registry_before=Fs_compat.load_file path in
  (match delivery base_path store registry prepared.original ~now:never_clock with
   | Error (Consumer.Registry_delivery_failed Runs.Original_registration_conflict) -> ()
   | Error (Original_observation_failed _ | Registry_delivery_failed (Invalid_original _ | Original_completion_conflict
       | Failed_completion_conflict | Reconciliation_unavailable _ | Reconciliation_persistence_failed _)) | Ok _ ->
     fail "registry conflict must remain typed pending delivery");
  check string "conflict never acknowledges or rewrites the original" owner_before
    (Fs_compat.load_file (owner_file store prepared.original));
  check string "conflict never replaces the registry fact" registry_before (Fs_compat.load_file path))

let test_typed_observer_rejects_semantically_forged_receipt terminal ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original observation cannot be relabelled"] in
  let finished=settle ~save:(save base_path) base_path store (retain store capture output) |> accepted |> committed in
  let prepared=prepare_observation base_path store finished ~now:(fun () -> 17.) in
  let event_name,receipt=if terminal then "observer_completion_intended",(observed_completion prepared).receipt
    else "observer_registration_intended",prepared.registration.receipt in
  let payload=if terminal then replace_field "selected_slot" (`String "replacement-provider") receipt.payload
    else replace_field "run_id" (`String "another-original-run") receipt.payload in
  let forged=get (Receipt.make ~observed_at:receipt.observed_at ~payload) in
  let wire=match get (Store.load_tool_request_owner store ~scope:Capture.scope ~request_id:finished.request_id) with
    | Some wire -> wire | None -> fail "missing actual owner" in
  let history=Progress.to_json prepared.original.progress in
  let history=match history with `List events -> `List (List.map (fun event ->
    if Yojson.Safe.Util.member "event" event=`String event_name
    then replace_field "receipt" (Receipt.to_json forged) event else event) events)
    | _ -> fail "expected actual ordered history" in
  get (Store.save_tool_request_owner store ~scope:Capture.scope ~request_id:finished.request_id
    (replace_field "progress" history wire));
  let original=original store capture in
  let path=owner_file store original in
  let bytes=Fs_compat.load_file path in
  check bool "generic valid hash does not establish original domain receipt authority" true
    (match prepare_observation_result base_path store original ~now:never_clock with
     | Error (Consumer.Rejected _) -> true | Ok _ | Error (Unavailable _ | Uncertain _) -> false);
  check string "refusal preserves forged evidence without rewriting" bytes (Fs_compat.load_file path))

let test_typed_observer_rechecks_full_judgment_and_commit invalid_judgment ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original semantic receipt binding"] in
  let record=if invalid_judgment then (
    let pending=advance store (retain_capture store capture) Progress.Dispatch_intended in
    let invalid=`Assoc ["status",`String "answered";"slot",`String "original";
      "output",`Assoc ["decisions",`List []]] in
    advance store pending (Progress.Judgment_retained invalid)
  ) else retain store capture output in
  let change=if invalid_judgment then change capture output
    else {Progress.before=`Assoc ["invented",`Bool true];after=`Assoc ["invented",`Bool false]} in
  let intent=advance store record (Progress.Commit_intended change) in
  let finished=advance store intent (Progress.Commit_observed change.after) in
  check bool "generic terminal history cannot bypass full original semantic plan" true
    (match prepare_observation_result base_path store finished ~now:(fun () -> 3.) with
     | Error (Consumer.Rejected _) -> true | Ok _ | Error (Unavailable _ | Uncertain _) -> false);
  let fresh=match owned (Owner.load ~store ~scope:Capture.scope ~request_id:finished.request_id) with
    | Some record -> record | None -> fail "lost original malformed domain evidence" in
  check bool "invalid terminal has no prepared completion receipt" true
    ((Progress.observer fresh.progress).completion=Receipt.Unobserved);
  check int "observation validation never saves the forged domain plan" 0
    (List.length (Ledger.dispositions (get (Ledger.load ~base_path)))))

let test_typed_observer_keeps_parent_refusal_separate_from_child ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Whole row a";"Whole row b"] in
  let parent=refuse store capture size_input in
  let prepared=prepare_observation base_path store parent ~now:(fun () -> 2.) in
  let before=(observed_completion prepared).receipt in
  let parent,child=narrow base_path store prepared.original |> accepted |> successor in
  let recovered=prepare_observation base_path store parent ~now:never_clock in
  check json "same original refusal survives successor acknowledgement" (Receipt.to_json before)
    (Receipt.to_json (observed_completion recovered).receipt);
  (match (observed_completion recovered).disposition with Observation.Execution_refusal final ->
     check json "original typed size refusal remains exact" (Exact.final_to_json size_input) (Exact.final_to_json final)
   | Confirmed_commit _ | Domain_conflict _ | Before_dispatch_refusal _ -> fail "parent refusal became a child success");
  let child=prepare_observation base_path store child ~now:(fun () -> 4.) in
  check bool "child owns its own deterministic observation identity" true
    (child.registration.run_id<>recovered.registration.run_id && child.completion=None);
  check bool "observer preparation grants child no new admission" true
    (Progress.phase child.original.progress=Progress.Captured))

let test_typed_observer_distinguishes_conflict_and_before_dispatch_refusal ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original conflicting domain"] in
  let judged=retain store capture output in
  let intended=advance store judged (Progress.Commit_intended (change capture output)) in
  let observed=`Assoc ["kind",`String "classification";"state",Ledger.to_json (get (Ledger.load ~base_path))] in
  let conflicted=advance store intended (Progress.Commit_conflicted observed) in
  let receipt=prepare_observation base_path store conflicted ~now:(fun () -> 5.) |> observed_completion in
  (match receipt.disposition with Observation.Domain_conflict (_,actual) -> check json "actual conflict remains evidence" observed actual
   | Confirmed_commit _ | Before_dispatch_refusal _ | Execution_refusal _ -> fail "conflict was recoded as successful commit"));
  with_workspace (fun base_path store ->
    let capture,_=classification base_path ["Original pre-admission refusal"] in
    let evidence=`Assoc ["reason",`String "host refused before admission"] in
    let refused=advance store (retain_capture store capture) (Progress.Refused {stage=Progress.Before_dispatch;evidence}) in
    let receipt=prepare_observation base_path store refused ~now:(fun () -> 6.) |> observed_completion in
    check (option string) "unsent work has no invented provider slot" None receipt.selected_slot;
    check bool "unsent work has no invented usage" true (receipt.provider_usage=None);
    match receipt.disposition with Observation.Before_dispatch_refusal original -> check json "full host refusal retained" evidence original
    | Confirmed_commit _ | Domain_conflict _ | Execution_refusal _ -> fail "pre-admission refusal became an executed model failure")

let test_typed_briefing_observer_binds_the_original_prepared_commit ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original briefing source a";"Original briefing source b"] in
  let ledger=match after capture output with Capture.Classification_commit ledger -> ledger
    | Capture.Briefing_commit _ -> fail "expected ledger" in
  get (Ledger.save ~base_path ledger);
  let batch,capture,output=prepare_briefing base_path ledger Briefing.empty in
  get (Briefing.save ~directory:(Ledger.directory ~base_path) (Briefing.prepared_state batch));
  let record=retain store capture output in
  let record=settle ~save:(save base_path) base_path store record |> accepted |> committed in
  let prepared=prepare_observation base_path store record ~now:(fun () -> 7.) in
  let receipt=observed_completion prepared in
  (match receipt.disposition with Observation.Confirmed_commit commit ->
     check json "receipt contains complete actual Briefing before state" (change capture output).before commit.change.before;
     check json "receipt contains complete actual Briefing after state" (change capture output).after commit.change.after
   | Domain_conflict _ | Before_dispatch_refusal _ | Execution_refusal _ -> fail "original Briefing commit lost");
  prepare_observation base_path store prepared.original ~now:never_clock |> ignore)
let check_eligibility_conflict_observation base_path store (record:Owner.retained) =
  let evidence=match Progress.phase record.progress with
    | Progress.Conflicted (_,evidence) -> evidence
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
    | Commit_unknown _ | Finished _ | Rejected _ | Subdividing _ | Subdivided _ ->
      fail "actual settle did not retain a terminal conflict" in
  (match evidence with
   | `Assoc fields -> check (list string) "actual eligibility conflict retains its diagnostic wrapper"
       ["reason";"state"] (List.sort String.compare (List.map fst fields))
   | _ -> fail "actual conflict has no complete evidence");
  let prepared=prepare_observation base_path store record ~now:(fun () -> 11.) in
  let completion=observed_completion prepared in
  (match completion.disposition with
   | Observation.Domain_conflict (_,actual) -> check json "actual original conflict survives terminal preparation" evidence actual
   | Confirmed_commit _ | Before_dispatch_refusal _ | Execution_refusal _ ->
     fail "eligibility conflict became success or refusal");
  let reopened=prepare_observation base_path store prepared.original ~now:never_clock in
  check json "reopened conflict reuses the complete original terminal receipt"
    (Receipt.to_json completion.receipt) (Receipt.to_json (observed_completion reopened).receipt)
let test_typed_observer_preserves_opaque_conflict_reason ()=with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original opaque conflict diagnostic"] in
  let intended=advance store (retain store capture output) (Progress.Commit_intended (change capture output)) in
  let evidence=`Assoc ["state",`Assoc ["kind",`String "classification";
      "state",Ledger.to_json (get (Ledger.load ~base_path))];
    "reason",`String "A diagnostic unrelated to any control-flow keyword"] in
  let record=advance store intended (Progress.Commit_conflicted evidence) in
  check_eligibility_conflict_observation base_path store record)
let test_typed_observer_rejects_incomplete_conflict_evidence ()=
  let valid_state=`Assoc ["kind",`String "classification";"state",Ledger.to_json Ledger.empty] in
  let wrap state reason=`Assoc ["state",state;"reason",reason] in
  List.iter (fun malformed -> with_workspace (fun base_path store ->
  let capture,output=classification base_path ["Original conflict must be a complete domain observation"] in
  let judged=retain store capture output in
  let intended=advance store judged (Progress.Commit_intended (change capture output)) in
  let conflicted=advance store intended (Progress.Commit_conflicted malformed) in
  check bool "generic conflict cannot turn malformed state into a typed domain receipt" true
    (match prepare_observation_result base_path store conflicted ~now:(fun () -> 3.) with
     | Error (Consumer.Rejected _) -> true | Ok _ | Error (Unavailable _ | Uncertain _) -> false);
  check bool "malformed conflict remains original evidence without terminal receipt" true
    ((Progress.observer (original store capture).progress).completion=Receipt.Unobserved)))
    [`Assoc ["kind",`String "classification";"state",`Assoc ["other_owner",`Bool true]];
     `Assoc ["kind",`String "classification";"state",Ledger.to_json Ledger.empty;"unknown",`Bool true];
     wrap (`Assoc ["kind",`String "classification";"state",`Assoc ["other_owner",`Bool true]]) (`String "opaque");
     wrap (`Assoc ["kind",`String "briefing";"state",Briefing.to_json Briefing.empty]) (`String "opaque");
     wrap valid_state (`Bool true);
     `Assoc ["state",valid_state;"reason",`String "opaque";"unknown",`Bool true];
     wrap (wrap valid_state (`String "nested")) (`String "opaque")]
let discover base_path store = Consumer.For_testing.discover
  ~store:(Store.create ~root:(Store.root store)) ~base_path
let observed_discover base_path store ~after_inventory = Consumer.For_testing.discover_observed
  ~store:(Store.create ~root:(Store.root store)) ~base_path ~after_inventory
let discovered_id (original : Consumer.original) = original.record.request_id
let check_discovered originals capture =
  let id=Capture.Request_id.to_string (Capture.request_id capture) in
  match List.find_opt (fun (original : Consumer.original) -> original.record.request_id=id) originals with
  | None -> fail "strict discovery lost an original request"
  | Some original ->
    check json "discovered capture keeps its full original input" (Capture.to_json capture)
      (Capture.to_json original.capture);
    original.record
let bytes path = Fs_compat.load_file path
let test_discovery_empty_does_not_publish ()=with_workspace (fun base_path store ->
  let inventories=ref 0 in
  let records=accepted (observed_discover base_path store ~after_inventory:(fun () -> incr inventories)) in
  check int "empty authoritative original inventory" 0 (List.length records);
  check int "cold empty discovery performs one actual complete inventory" 1 !inventories;
  check bool "discovery does not create an owner store" false (Sys.file_exists (Store.root store)))
let test_discovery_preserves_active_original_and_fresh_resume ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Active original source"] in
  let retained=retain_capture store capture in
  let inventories=ref 0 in
  let originals=accepted (observed_discover base_path store ~after_inventory:(fun () ->
    incr inventories;
    if !inventories=1 then
      ignore (advance store retained (Progress.Refused {stage=Progress.Before_dispatch;
        evidence=`Assoc ["reason",`String "Original owner refused before admission"]})))) in
  check int "active original discovery reads one complete inventory" 1 !inventories;
  let observed=check_discovered originals capture in
  check json "discovery retains its original validated observation"
    (Progress.to_json Progress.captured) (Progress.to_json observed.progress);
  let current=original store capture in
  (match no_worker_resume base_path store observed with
   | Ok (Consumer.Settled actual) ->
     check string "resume keeps the same active owner identity" retained.request_id actual.request_id;
     check json "resume reloads current progress without worker dispatch"
       (Progress.to_json current.progress) (Progress.to_json actual.progress)
   | Ok _ | Error _ -> fail "discovery observation must not bypass fresh resume authority");
  check json "fresh resume never replaces the original capture" retained.request current.request)
let test_discovery_parks_original_without_new_successor ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Original refused source a";"Original refused source b"] in
  let parent=refuse store capture size_input in
  let path=child_record_path store parent in
  let before=bytes path in
  let inventories=ref 0 in
  let records=accepted (observed_discover base_path store ~after_inventory:(fun () -> incr inventories)) in
  check int "cold non-recovery discovery performs one actual complete inventory" 1 !inventories;
  check int "discovery cannot turn refusal into new admission" 1 (List.length records);
  let restored=check_discovered records capture in
  check json "size refusal remains without a new intent" (Progress.to_json parent.progress) (Progress.to_json restored.progress);
  check string "parked original is not rewritten" before (bytes path))
let test_discovery_recovers_existing_intent child_present ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Retained parent source a";"Retained parent source b"] in
  let _,child,_=intent store capture size_input in
  if child_present then (
    let retained=retain_capture store child in
    check bool "ordinary restore refuses before the parent ACK" true
      (Result.is_error (restore_capture base_path store retained)));
  let ledger=Ledger.to_json (get (Ledger.load ~base_path)) in
  let inventories=ref 0 in
  let records=accepted (observed_discover base_path store ~after_inventory:(fun () -> incr inventories)) in
  check int "actual recovery requires the fresh complete inventory" 2 !inventories;
  check int "recover exactly original parent and intended child" 2 (List.length records);
  let parent=check_discovered records capture in
  let retained=check_discovered records child in
  check json "child is unexecuted after local recovery" (Progress.to_json Progress.captured) (Progress.to_json retained.progress);
  (match Progress.phase parent.progress with
   | Progress.Subdivided (_,intent) -> check string "ACK keeps original child ID" retained.request_id intent.request_id
   | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
   | Finished _ | Conflicted _ | Rejected _ | Subdividing _ -> fail "existing parent intent was not acknowledged");
  let paths=List.map (fun (original : Consumer.original) -> child_record_path store original.record) records in
  let before=List.map bytes paths in
  inventories:=0;
  let again=accepted (observed_discover base_path store ~after_inventory:(fun () -> incr inventories)) in
  check int "ACKed forest needs one inventory on the next discovery" 1 !inventories;
  check (list string) "same original IDs after reopening" (List.map discovered_id records) (List.map discovered_id again);
  check (list string) "ACKed forest is not rewritten" before (List.map bytes paths);
  check json "local recovery never saves a domain" ledger (Ledger.to_json (get (Ledger.load ~base_path))))
let test_discovery_rejects_error_in_fresh_recovery_inventory ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Recovering source a";"Recovering source b"] in
  let _,child,intended=intent store capture size_input in
  let inventories=ref 0 in
  let result=observed_discover base_path store ~after_inventory:(fun () ->
    incr inventories;
    if !inventories=1 then
      (* The first strict inventory has really returned. A new published member
         is outside that snapshot and must be read after the existing recovery. *)
      get (Store.save_tool_request_owner store ~scope:Capture.scope
        ~request_id:"malformed-during-recovery" (`Assoc []))) in
  check int "failed post-recovery inventory is still an actual second read" 2 !inventories;
  (match result with
   | Error (Consumer.Unavailable _) -> ()
   | Ok _ | Error (Consumer.Rejected _ | Consumer.Uncertain _) ->
     fail "a newly unreadable original must reject the refreshed inventory");
  let parent=original store capture in
  (match Progress.phase parent.progress with
   | Progress.Subdivided (_,actual) -> check string "completed local ACK keeps the intended child"
       intended.request_id actual.request_id
   | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
   | Finished _ | Conflicted _ | Rejected _ | Subdividing _ -> fail "fixture never reached actual recovery");
  let retained=original store child in
  check json "inventory failure does not execute the recovered child"
    (Progress.to_json Progress.captured) (Progress.to_json retained.progress);
  check json "inventory failure never saves the domain" (Ledger.to_json Ledger.empty)
    (Ledger.to_json (get (Ledger.load ~base_path))))
let test_discovery_rejects_acknowledged_missing_child ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Acknowledged source a";"Acknowledged source b"] in
  let parent,child=narrow base_path store (refuse store capture size_input) |> accepted |> successor in
  let path=child_record_path store child in
  Unix.rename path (Filename.concat base_path "missing-acknowledged-child-evidence.json");
  check bool "incomplete acknowledged forest is not empty or partial" true (Result.is_error (discover base_path store));
  check bool "missing acknowledged child is never recreated" false (Sys.file_exists path);
  check json "parent history is preserved" (Progress.to_json parent.progress) (Progress.to_json (original store capture).progress))
let retain_bad_capture store capture request =
  let target=Capture.destination capture in
  owned (Owner.retain ~store ~scope:Capture.scope ~request_id:(Capture.Request_id.to_string (Capture.request_id capture))
    ~installation_id:target.installation_id ~package_id:target.package_id ~tool:target.tool ~request)
let test_discovery_validates_every_member_before_recovery ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Valid pending source a";"Valid pending source b"] in
  let parent,child,_=intent store capture size_input in
  let unrelated,_=classification base_path ["Unrelated malformed original capture"] in
  retain_bad_capture store unrelated (`Assoc ["unrelated",`Bool true]);
  let before=bytes (child_record_path store parent) in
  check bool "one malformed original rejects the entire forest before repair" true
    (Result.is_error (discover base_path store));
  check string "valid pending parent was not partially repaired" before (bytes (child_record_path store parent));
  check bool "validation failure creates no child" true
    (owned (Owner.load ~store ~scope:Capture.scope ~request_id:(Capture.Request_id.to_string (Capture.request_id child)))=None))
let test_discovery_refuses_conflicting_or_started_pending_child started ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Pending child source a";"Pending child source b"] in
  let parent,child,_=intent store capture size_input in
  if started then ignore (advance store (retain_capture store child) Progress.Dispatch_intended)
  else retain_bad_capture store child (Capture.to_json capture);
  let before=bytes (child_record_path store parent) in
  check bool "wrong or already started unacknowledged child is never repaired" true
    (Result.is_error (discover base_path store));
  check string "invalid child cannot ACK the parent" before (bytes (child_record_path store parent)))
let test_discovery_nested_existing_intents ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Nested source a";"Nested source b";"Nested source c";"Nested source d"] in
  let _,child=narrow base_path store (refuse store capture size_input) |> accepted |> successor in
  let child_capture=get (restore_capture base_path store child) in
  let _,grandchild,_=intent store child_capture size_input in
  retain_capture store grandchild |> ignore;
  let records=accepted (discover base_path store) in
  check int "one acknowledged chain with an interrupted next link" 3 (List.length records);
  check_discovered records capture |> ignore;
  check_discovered records child_capture |> ignore;
  check_discovered records grandchild |> ignore)
let test_discovery_rejects_dangling_parent ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Missing predecessor source a";"Missing predecessor source b"] in
  let child=match get (Capture.narrow ~request_id:(Capture.Request_id.fresh ()) ~final:size_input capture) with
    | Some child -> child | None -> fail "expected child" in
  let retained=retain_capture store child in
  let before=bytes (child_record_path store retained) in
  check bool "an orphan cannot become an independent root" true (Result.is_error (discover base_path store));
  check string "orphan evidence remains unchanged" before (bytes (child_record_path store retained)))
let test_discovery_rejects_foreign_workspace ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["Workspace-bound original"] in
  let request=match Capture.to_json capture with
    | `Assoc fields -> `Assoc (List.map (fun (name,value) ->
        if name="workspace" then match value with
          | `Assoc binding -> name,`Assoc (List.map (fun (key,value) ->
              if key="path" then key,`String (Filename.dirname base_path) else key,value) binding)
          | _ -> fail "expected workspace binding"
        else name,value) fields)
    | _ -> fail "expected capture" in
  retain_bad_capture store capture request;
  check bool "foreign physical workspace is not new work" true (Result.is_error (discover base_path store)))
let test_discovery_rejects_duplicate_inventory_id ()=with_workspace (fun base_path store ->
  let capture,_=classification base_path ["One original request identity"] in
  let record=retain_capture store capture in
  check bool "duplicate rows are not a valid complete forest" true
    (Result.is_error (Capture.recoverable_successors ~workspace:(get (Capture.observe_workspace ~base_path))
      [record;record])))
let test_live_briefing_contract_on_recovery after_saved ()=with_workspace (fun base_path store ->
  Eio.Switch.run @@ fun sw ->
  let prompts=Filename.concat base_path "guarded-prompts" in
  Fs_compat.mkdir_p prompts;
  let key=Prompt_names.workspace_memory_briefing in
  Out_channel.with_open_bin (Filename.concat prompts (key ^ ".md")) (fun channel ->
    output_string channel ("---\ndescription: original recovery contract\n"
      ^ "template_variables: [workspace_memory_briefing]\n---\n" ^ briefing_template));
  Prompt_registry.clear ();
  Eio_guard.enable ();
  Eio.Switch.on_release sw (fun () ->
    Fun.protect ~finally:Eio_guard.disable Prompt_registry.clear);
  Prompt_registry.set_markdown_dir prompts;
  get (Prompt_registry.set_override key briefing_template);
  let current_contract ()=Briefing.contract ~template:(Prompt_registry.resolve_prompt key).effective in
  let classification,answer=classification base_path ["Original briefing source a";"Original briefing source b"] in
  let ledger=match after classification answer with
    | Capture.Classification_commit ledger -> ledger | Briefing_commit _ -> fail "expected original ledger" in
  get (Ledger.save ~base_path ledger);
  let batch,capture,answer=prepare_briefing base_path ledger Briefing.empty in
  let directory=Ledger.directory ~base_path in
  let before=Briefing.prepared_state batch in
  get (Briefing.save ~directory before);
  let original=retain store capture answer in
  let lost expected=
    if after_saved then get (save base_path expected);
    Error "controlled original save receipt loss" in
  check bool "original failed save retains uncertainty" true
    (match settle ~briefing_contract:current_contract ~save:lost base_path store original with
     | Error (Consumer.Uncertain _) -> true
     | Ok _ | Error (Consumer.Unavailable _ | Rejected _) -> false);
  get (Prompt_registry.set_override key "Changed {{workspace_memory_briefing}}");
  check bool "live registry changed after the original failed attempt" true (current_contract ()<>contract);
  let briefing_contract=if after_saved then
      (fun () -> fail "confirmed after-state must not resolve a current prompt")
    else current_contract in
  let result=settle ~briefing_contract ~save:no_save base_path store original |> accepted in
  (match result,after_saved with
   | Consumer.Committed _,true | Commit_conflict _,false -> ()
   | Committed _,false | Commit_conflict _,true | Commit_waiting _,(false | true) ->
     fail "original recovery used the wrong contract decision");
  let expected=if after_saved then match after capture answer with
      | Capture.Briefing_commit state -> state | Classification_commit _ -> fail "expected original briefing"
    else before in
  check json "recovery does not replace the original domain bytes"
    (Briefing.to_json expected) (Briefing.to_json (get (Briefing.load ~directory))))
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
  test_case "nested refusal narrows the child without a root sibling" `Quick test_nested_successor_has_no_root_sibling;
  test_case "original host terminal recovers and commits without live Runtime" `Quick test_original_host_terminal_recovers_without_a_live_runtime;
  test_case "invalid host original refuses without worker fallback" `Quick test_bad_original_host_record_cannot_fall_back_to_a_worker;
  test_case "observed original still requires complete domain validation" `Quick test_observed_host_answer_still_requires_full_domain_validation;
  test_case "original installation kind and canonical identity" `Quick test_installation_identity_is_canonical_and_kind_bound;
  test_case "actual registry publication survives lost ACK and historical eviction" `Quick test_actual_observer_delivery_and_ack_retry;
  test_case "actual registration ACK does not invent a terminal" `Quick test_registration_delivery_does_not_invent_completion;
  test_case "unavailable registry preserves pending original and permits exact retry" `Quick test_failed_registry_keeps_original_pending;
  test_case "conflicting registry preserves pending original and registry evidence" `Quick
    test_conflicting_registry_keeps_original_pending;
  test_case "typed observer follows actual original commit without Runtime" `Quick test_typed_observer_intents_follow_original_commit_without_runtime;
  test_case "generic valid registration cannot relabel original observer" `Quick (test_typed_observer_rejects_semantically_forged_receipt false);
  test_case "generic valid completion cannot replace original provider" `Quick (test_typed_observer_rejects_semantically_forged_receipt true);
  test_case "observer rejects invented original commit plan" `Quick (test_typed_observer_rechecks_full_judgment_and_commit false);
  test_case "observer rejects schema-shaped incomplete original judgment" `Quick (test_typed_observer_rechecks_full_judgment_and_commit true);
  test_case "parent refusal and child have separate original observer identities" `Quick test_typed_observer_keeps_parent_refusal_separate_from_child;
  test_case "observer conflict differs from unsent host refusal" `Quick test_typed_observer_distinguishes_conflict_and_before_dispatch_refusal;
  test_case "observer Briefing receipt binds complete original prepared state" `Quick test_typed_briefing_observer_binds_the_original_prepared_commit;
  test_case "actual changed source conflict prepares its original terminal observation" `Quick
    (test_changed_or_unreadable_sources ~on_conflict:check_eligibility_conflict_observation false);
  test_case "actual changed Briefing contract prepares its original terminal observation" `Quick
    (test_briefing_pass ~on_conflict:check_eligibility_conflict_observation Change_contract);
  test_case "observer retains opaque eligibility conflict diagnostics" `Quick test_typed_observer_preserves_opaque_conflict_reason;
  test_case "observer rejects incomplete original conflict evidence" `Quick test_typed_observer_rejects_incomplete_conflict_evidence;
  test_case "empty discovery publishes no owner state" `Quick test_discovery_empty_does_not_publish;
  test_case "single-scan discovery preserves the active original and fresh resume" `Quick test_discovery_preserves_active_original_and_fresh_resume;
  test_case "discovery does not mint a child from a size refusal" `Quick test_discovery_parks_original_without_new_successor;
  test_case "discovery recovers durable intent before child retain" `Quick (test_discovery_recovers_existing_intent false);
  test_case "discovery recovers retained child before parent ACK" `Quick (test_discovery_recovers_existing_intent true);
  test_case "fresh recovery inventory refuses a newly malformed member" `Quick test_discovery_rejects_error_in_fresh_recovery_inventory;
  test_case "discovery refuses acknowledged missing child" `Quick test_discovery_rejects_acknowledged_missing_child;
  test_case "complete forest validation precedes every recovery write" `Quick test_discovery_validates_every_member_before_recovery;
  test_case "discovery refuses conflicting pending child" `Quick (test_discovery_refuses_conflicting_or_started_pending_child false);
  test_case "discovery refuses execution before parent ACK" `Quick (test_discovery_refuses_conflicting_or_started_pending_child true);
  test_case "discovery recovers nested original chain" `Quick test_discovery_nested_existing_intents;
  test_case "discovery refuses a missing original predecessor" `Quick test_discovery_rejects_dangling_parent;
  test_case "discovery refuses another physical workspace" `Quick test_discovery_rejects_foreign_workspace;
  test_case "discovery refuses duplicate original IDs" `Quick test_discovery_rejects_duplicate_inventory_id;
  test_case "Briefing recovery reads the changed live contract on its original fiber" `Quick
    (test_live_briefing_contract_on_recovery false);
  test_case "Briefing confirmed after-state bypasses changed live contract" `Quick
    (test_live_briefing_contract_on_recovery true)]]
