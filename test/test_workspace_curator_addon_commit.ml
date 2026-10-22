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
let retain store capture output =
  let request_id=Capture.Request_id.to_string (Capture.request_id capture) in
  owned (Owner.retain ~store ~scope:Capture.scope ~request_id ~installation_id:destination.installation_id
    ~package_id:destination.package_id ~tool:destination.tool ~request:(Capture.to_json capture));
  let record=match owned (Owner.load ~store ~scope:Capture.scope ~request_id) with
    | Some record -> record | None -> fail "missing original capture" in
  let record=advance store record Progress.Dispatch_intended in
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
      | Commit_uncertain _ | Commit_observed _ | Commit_conflicted _ | Refused _ -> false) (Progress.events result.progress));
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
  test_case "missing prepared state is not created after the model" `Quick (test_briefing_pass Missing_preparation)]]
