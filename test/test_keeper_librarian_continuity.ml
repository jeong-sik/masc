open Alcotest
module P = Masc.Keeper_librarian_continuity
module B = Masc.Keeper_turn_boundaries
module C = Masc.Keeper_checkpoint_store
module S = Masc.Librarian_continuity_snapshot
module U = Yojson.Safe.Util
let get = function Ok value -> value | Error error -> fail error
let some = function Some value -> value | None -> fail "missing prepared continuity"
let trace_id = "producer-continuity-trace"
let keeper_name = "producer-continuity-keeper"
let checkpoint messages : Agent_core.Checkpoint.t =
  {version=Agent_core.Checkpoint.checkpoint_version; session_id=trace_id;
   agent_name=keeper_name; model="fixture"; system_prompt=None; messages;
   usage=Agent_core.Types.empty_usage; turn_count=List.length messages; created_at=1000.;
   tools=[];tool_choice=None;disable_parallel_tool_use=false;temperature=None;
   top_p=None;top_k=None;min_p=None;reasoning_effort=None;enable_thinking=None;
   preserve_thinking=None;response_format=Agent_core.Types.Off;cache_system_prompt=false;
   context=Agent_core.Context.create_sync ();pending_input = None; mcp_sessions = [];working_context=None}
let message text = Agent_core.Types.make_message ~role:Agent_core.Types.User [Agent_core.Types.Text text]
let with_source f =
  Eio_main.run @@ fun env -> Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root=Filename.temp_dir "continuity-producer-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) @@ fun () ->
  let config=Masc.Workspace.default_config root in
  let session_dir=Filename.concat (Masc.Keeper_fs.session_store_path config) trace_id in
  let save messages = match C.save_agent_core_classified ~session_dir ~history_retained:0 (checkpoint messages) with
    | Ok (C.Saved _) -> () | Ok (C.Stale_noop _) -> fail "stale fixture" | Error detail -> fail detail in
  let append event = B.append ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name {B.recorded_at=1000.;event} |> Result.map_error B.append_error_to_string |> get in
  let boundary ~fresh number messages =
    append (B.Turn_ended { task_context = Masc.Keeper_turn_task_context.No_task;turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:number;
      history_at_start=(if fresh then B.Fresh_history else B.Continued_history);
      position=B.position_of_messages messages |> get}) in
  f env config save append boundary
let prepare config = P.prepare ~config ~keeper_name ~trace_id () |> get
let record_prepared_memory config prepared =
  let range_id = P.memory_range_id ~config ~keeper_name prepared |> get in
  ignore (Masc.Keeper_memory_os_current.apply_disposition ~revisions:[] ~durable_range_id:range_id
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Masc.Workspace.base_path)
    ~keeper_id:keeper_name ~now:1000. ~source:{kind=Masc.Keeper_memory_os_current.Librarian;trace_id}
    ~absorbed:[] ~new_claims:[] () |> get)
let record_memory config = record_prepared_memory config (prepare config |> some)
let commit config prepared text =
  record_prepared_memory config prepared;
  P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared ~working_state:text |> get
let test_prefix_selection_keeps_frozen_source_and_publication_checks () =
  with_source @@ fun _env config save _append boundary ->
  let prefix = List.map message ["A"; "B"] in
  let full = prefix @ List.map message ["C"; "D"] in
  save full;
  boundary ~fresh:true 1 prefix;
  boundary ~fresh:false 2 full;
  let wide = P.prepare ~end_atom:4 ~config ~keeper_name ~trace_id () |> get |> some in
  let reread = P.prepare ~end_atom:2 ~config ~keeper_name ~trace_id () |> get |> some in
  let selected = P.select_prefix ~end_atom:2 wide |> get in
  check bool "same messages as explicit preparation" true (P.messages selected = P.messages reread);
  check bool "same historical attribution" true (P.source_spans selected = P.source_spans reread);
  check bool "same covering turn" true (Ids.Turn_ref.equal (P.turn_ref selected) (P.turn_ref reread));
  check bool "same counterpart window" true (P.turn_window selected = P.turn_window reread);
  check bool "same exact receipt" true
    (P.memory_range_id ~config ~keeper_name selected = P.memory_range_id ~config ~keeper_name reread);
  List.iter (fun end_atom ->
    let reread = P.prepare ~end_atom ~config ~keeper_name ~trace_id () |> get |> some in
    let selected = P.select_prefix ~end_atom wide |> get in
    check bool "mid-turn prefix keeps exact source attribution" true
      (P.source_spans selected = P.source_spans reread);
    check bool "mid-turn prefix keeps original covering turn" true
      (Ids.Turn_ref.equal (P.turn_ref selected) (P.turn_ref reread));
    check bool "mid-turn prefix carries no completed counterpart window" true
      (P.turn_window selected = None && P.turn_window reread = None);
    check bool "mid-turn prefix keeps exact receipt" true
      (P.memory_range_id ~config ~keeper_name selected = P.memory_range_id ~config ~keeper_name reread))
    [1; 3];
  check bool "unchanged endpoint shares original source" true
    ((P.select_prefix ~end_atom:4 wide |> get) == wide);
  check bool "empty prefix rejected" true (Result.is_error (P.select_prefix ~end_atom:0 wide));
  check bool "widening rejected" true (Result.is_error (P.select_prefix ~end_atom:5 wide));
  record_prepared_memory config selected;
  save (message "Changed A" :: List.tl full);
  let still_original = P.select_prefix ~end_atom:2 wide |> get in
  check bool "selection keeps original checkpoint after disk changes" true
    (P.messages still_original = prefix);
  check bool "changed original source still refuses publication" true
    (Result.is_error (P.commit ~new_unread_messages:[] ~config ~keeper_name
      ~prepared:still_original ~working_state:"The original A and B"));
  check bool "refusal publishes no continuation" true (Option.is_none (P.read ~config ~keeper_name |> get))
let test_append_cas_and_restart () = with_source @@ fun _env config save append boundary ->
  let prefix=[message "Keep the deployment pending approval."] in
  save prefix;boundary ~fresh:true 1 prefix;
  let prepared=prepare config |> some in
  let input=P.prompt_json prepared in
  check bool "initial state has no invented predecessor" true (U.member "previous_working_state" input=`Null);
  check int "first completed prefix supplied" 1 (List.length (P.messages prepared));
  let saved=commit config prepared "Deployment is pending approval." in
  check int "coverage ends at provided completed prefix" 1 saved.end_atom;
  check bool "quiet wake requires no new summary" true (Option.is_none (prepare config));
  let full=prefix@[message "Build passed; still awaiting approval."] in
  save full;
  check bool "in-flight suffix does not advance coverage" true (Option.is_none (prepare config));
  boundary ~fresh:false 2 full;
  let next=prepare config |> some in
  let input=P.prompt_json next in
  check string "previous saved state feeds next summary" saved.working_state
    (U.member "previous_working_state" input |> U.to_string);
  check int "only new complete suffix fed to model" 1 (List.length (P.messages next));
  let newer=commit config next "Build passed; deployment is still awaiting approval." in
  check int "prefix frontier advances with saved working state" 2 newer.end_atom;
  check bool "late previous writer cannot replace newer pair" true
    (Result.is_error (P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared ~working_state:"old"));
  let current=P.read ~config ~keeper_name |> get |> some in
  check bool "CAS preserved complete new pair" true (current=newer);
  let restored=S.restore ~trace_id ~lines:(B.read ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name |> get) ~messages:full current |> Result.map_error S.error_to_string |> get in
  check int "saved coverage excludes exactly represented atoms" 0 (List.length restored.messages);
  append (B.History_restarted {trace_id});boundary ~fresh:false 3 full;
  let restarted=prepare config |> some in
  check bool "restart does not carry old state into new generation" true
    (U.member "previous_working_state" (P.prompt_json restarted)=`Null);
  check int "restart supplies full completed prefix" 2 (List.length (P.messages restarted))
let test_failed_state_keeps_old_frontier () = with_source @@ fun _env config save _append boundary ->
  let prefix=[message "Unresolved request"] in save prefix;boundary ~fresh:true 1 prefix;
  let prepared=prepare config |> some in
  check bool "blank generated state rejected" true
    (Result.is_error (P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared ~working_state:" "));
  check bool "failure publishes no frontier" true (P.read ~config ~keeper_name |> get |> Option.is_none);
  let old=commit config prepared "Unresolved request remains." in
  let full=prefix@[message "Another unresolved request"] in save full;boundary ~fresh:false 2 full;
  let next=prepare config |> some in
  check bool "failure cannot replace previous valid frontier" true
    (Result.is_error (P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared:next ~working_state:""));
  check bool "saved pair unchanged" true (P.read ~config ~keeper_name |> get=Some old)
exception Cancel_commit
let test_worker_cancellation_waits_for_commit () = with_source @@ fun env config save _append boundary ->
  Eio.Switch.run @@ fun sw ->
  let prior=Domain_pool_ref.get () in
  Fun.protect ~finally:(fun () -> match prior with
    | None -> Domain_pool_ref.clear_for_tests () | Some pool -> Domain_pool_ref.set pool) @@ fun () ->
  Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
  let messages=[message "Pending request"] in save messages;boundary ~fresh:true 1 messages;
  record_memory config;
  let prepared=prepare config |> some in
  let entered,enter=Eio.Promise.create () and release,release_worker=Eio.Promise.create () in
  let scope,publish_scope=Eio.Promise.create () in
  let observed=ref false and finished=ref false in
  let caller_domain=(Domain.self () :> int) in
  let worker=Eio.Fiber.fork_promise ~sw (fun () ->
    Fun.protect ~finally:(fun () -> finished:=true) (fun () ->
      Eio.Cancel.sub (fun cc -> Eio.Promise.resolve publish_scope cc;
        Masc.Keeper_librarian_runtime.For_testing.commit_continuity
          ~commit:(fun () ->
            check bool "actual executor worker" true ((Domain.self () :> int)<>caller_domain);
            Eio.Promise.resolve enter ();
            Eio.Promise.await release;
            P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared ~working_state:"Pending request remains.")
          ~observe:(fun result -> ignore (get result);observed:=true)))) in
  let cc=Eio.Promise.await scope in Eio.Promise.await entered;
  Eio.Cancel.cancel cc Cancel_commit;
  Eio.Fiber.yield ();
  check bool "cancelled lane cannot finish before disk worker" false !finished;
  check bool "no premature commit observation" false !observed;
  Eio.Promise.resolve release_worker ();
  (match Eio.Promise.await worker with
   | Error (Eio.Cancel.Cancelled Cancel_commit) -> ()
   | Error error -> fail (Printexc.to_string error) | Ok () -> fail "cancellation swallowed");
  check bool "actual commit observed before cancellation propagates" true !observed;
  check bool "pair exists before lifecycle cleanup" true (Sys.file_exists (P.path ~config ~keeper_name));
  Sys.remove (P.path ~config ~keeper_name);
  Eio.Fiber.yield ();
  check bool "finished worker cannot recreate purged pair" false (Sys.file_exists (P.path ~config ~keeper_name))
let test_memory_coverage_required () = with_source @@ fun _env config save _append boundary ->
  let first=[message "First fact"] in save first;boundary ~fresh:true 1 first;
  let prepared=prepare config |> some in
  check bool "no Memory receipt cannot authorize prefix removal" true
    (Result.is_error (P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared ~working_state:"First fact"));
  record_memory config;
  check bool "exact saved Memory permits publication" true
    (P.memory_committed ~config ~keeper_name prepared |> get);
  let next=first@[message "New fact not yet in Memory"] in save next;boundary ~fresh:false 2 next;
  let recovered=prepare config |> some in
  check int "appended turns do not expand unpublished Memory commit" 1 (P.end_atom recovered);
  check bool "old receipt is recoverable with newly appended boundary" true
    (P.memory_committed ~config ~keeper_name recovered |> get);
  ignore (P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared:recovered ~working_state:"First fact" |> get);
  let newer=prepare config |> some in
  check int "after publication next source advances" 2 (P.end_atom newer);
  check bool "earlier receipt cannot cover new suffix" false
    (P.memory_committed ~config ~keeper_name newer |> get)
let test_baseline_partial_bootstrap () = with_source @@ fun _env config save _append boundary ->
  let prefix=[message "A";message "B";message "C";message "D"] in
  save prefix; boundary ~fresh:false 10 prefix;
  let all=prepare config |> some in
  check int "existing history is real source" 4 (List.length (P.messages all));
  let partial=P.narrow all |> some in
  check int "capacity retry uses whole atom midpoint" 2 (P.end_atom partial);
  record_prepared_memory config partial;
  let expanded=prefix@[message "E"] in save expanded;boundary ~fresh:false 11 expanded;
  let recovered=prepare config |> some in
  check int "failed publication recovers the actual narrowed source" 2 (P.end_atom recovered);
  check bool "recovered Memory is not reapplied" true
    (P.memory_committed ~config ~keeper_name recovered |> get);
  let saved=P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared:recovered ~working_state:"A and B" |> get in
  check bool "explicit captured provenance" true (saved.origin=S.Captured_checkpoint_prefix);
  check int "recovery retains its original completed anchor" 4 saved.covering_end_atom;
  let later=prepare config |> some in
  check int "remaining part of the same turn is supplied" 2 (List.length (P.messages later));
  let receipt=P.memory_range_id ~config ~keeper_name later |> get in
  check int "next read starts exactly after captured prefix" 2 receipt.start_atom;
  let ordinary=Masc.Keeper_memory_os_current.committed_durable_range
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Masc.Workspace.base_path)
    ~keeper_id:keeper_name ~receipt_scope:(Masc.Workspace.keepers_runtime_dir config) |> get in
  check bool "bootstrap does not manufacture ordinary consumer progress" true (Option.is_none ordinary)
let record_ordinary config prepared ~start_atom =
  let own=P.memory_range_id ~config ~keeper_name prepared |> get in
  let range_id={own with Masc.Keeper_memory_os_current.receipt_scope=Masc.Workspace.keepers_runtime_dir config;
    start_atom} in
  ignore (Masc.Keeper_memory_os_current.apply_disposition ~revisions:[] ~durable_range_id:range_id
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Masc.Workspace.base_path)
    ~keeper_id:keeper_name ~now:1000. ~source:{kind=Masc.Keeper_memory_os_current.Librarian;trace_id}
    ~absorbed:[] ~new_claims:[] () |> get)
let test_ordinary_witnessed_coverage () = with_source @@ fun _env config save _append boundary ->
  let prefix=[message "A";message "B"] in save prefix;boundary ~fresh:true 1 prefix;
  let full=prefix@[message "C";message "D"] in save full;boundary ~fresh:false 2 full;
  let all=P.prepare ~end_atom:4 ~config ~keeper_name ~trace_id () |> get |> some in
  record_ordinary config all ~start_atom:0;
  let prepared=prepare config |> some in
  check int "continuity selects first turn despite later ordinary receipt" 2 (P.end_atom prepared);
  check bool "serial witnessed Memory already read this prefix" true
    (P.memory_committed ~config ~keeper_name prepared |> get);
  ignore (P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared ~working_state:"A and B" |> get)
let test_ordinary_baseline_coverage () = with_source @@ fun _env config save _append boundary ->
  let baseline=[message "A";message "B"] in save baseline;boundary ~fresh:false 1 baseline;
  let full=baseline@[message "C";message "D"] in save full;boundary ~fresh:false 2 full;
  let all=P.prepare ~end_atom:4 ~config ~keeper_name ~trace_id () |> get |> some in
  record_ordinary config all ~start_atom:2;
  check bool "normal receipt never certifies unknown baseline prefix" false
    (P.memory_committed ~config ~keeper_name all |> get);
  let prefix=prepare config |> some in
  ignore (commit config prefix "A and B");
  let suffix=prepare config |> some in
  check int "next source starts after baseline" 2
    (P.memory_range_id ~config ~keeper_name suffix |> get).start_atom;
  check bool "normal serial receipt certifies already consumed suffix" true
    (P.memory_committed ~config ~keeper_name suffix |> get)
let test_historical_sources_survive_narrowing_and_recovery () =
  with_source @@ fun _env config save append _boundary ->
  let module H = Masc.Keeper_librarian_task_context in
  let module T = Masc.Keeper_turn_task_context in
  ignore (Masc.Workspace.init config ~agent_name:None);
  let goal target_value = match Goal_store.upsert_goal config ~id:"goal-history"
      ~title:"Historical goal" ~metric:"count" ~target_value () with
    | Ok (goal, _) -> goal | Error e -> fail (Goal_store.write_error_to_string e) in
  let original = goal "1" in
  Workspace_goal_index.write_goal_task_links config [original.id, ["task-a"]];
  let capture name = T.capture ~config (Ok (Some (Keeper_id.Task_id.of_string name |> get))) in
  let task_a = capture "task-a" and task_b = capture "task-b" in
  let first = List.map message ["a1";"a2"] in
  let full = first @ List.map message ["b1";"b2";"b3";"b4"] in
  let ended turn task_context history_at_start messages = append (B.Turn_ended
    {turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:turn; task_context;
     history_at_start;position=B.position_of_messages messages |> get}) in
  save full;
  ended 1 task_a B.Fresh_history first;
  let start_atom_digest = Runtime_model_input_tail_window.atom_opening_digest full 1 |> some in
  ended 2 task_b (B.Continued_history_from {start_atom=2;start_atom_digest}) full;
  let wide = P.prepare ~end_atom:6 ~config ~keeper_name ~trace_id () |> get |> some in
  ignore (goal "2");
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String keeper_name;
      "trace_id",`String trace_id;"current_task_id",`String "task-c"]) |> get in
  Masc.Keeper_meta_store.replace_snapshot config meta |> get;
  let contexts prepared = List.map (fun (scope, messages) ->
    match scope.H.attribution with
    | H.Observed {task_context;_} -> task_context, List.length messages
    | H.Unattributed -> fail "witnessed atoms lost admission context") (P.source_spans prepared) in
  check bool "default next turn uses A" true (contexts (prepare config |> some) = [task_a,2]);
  check bool "multi-turn range preserves A and B, original criterion" true
    (contexts wide = [task_a,2;task_b,4]);
  let narrow = P.narrow wide |> some in
  check bool "mid-turn cut clips B after A" true (contexts narrow = [task_a,2;task_b,1]);
  check bool "second cut remains inside A, despite B covering anchor" true
    (contexts (P.narrow narrow |> some) = [task_a,1]);
  let receipt = P.memory_range_id ~config ~keeper_name narrow |> get in
  record_prepared_memory config narrow;
  let recovered = P.prepare ~end_atom:1 ~config ~keeper_name ~trace_id () |> get |> some in
  check bool "recovery keeps exact source context" true (P.source_spans recovered = P.source_spans narrow);
  check bool "recovery keeps exact frontier" true ((P.memory_range_id ~config ~keeper_name recovered |> get) = receipt);
  check bool "committed recovery cannot shrink" true (P.narrow recovered = None);
  check bool "prefix selection cannot split exact recovery" true
    ((P.select_prefix ~end_atom:1 recovered |> get) == recovered);
  ignore (commit config recovered "Continue Task B");
  check bool "next suffix contains only remaining B" true (contexts (prepare config |> some) = [task_b,3])

let test_historical_gap_is_not_covering_task () =
  with_source @@ fun _env config save append _boundary ->
  let module H = Masc.Keeper_librarian_task_context in
  let full = List.map message ["unknown1";"unknown2";"known1";"known2"] in
  save full;
  let start_atom_digest = Runtime_model_input_tail_window.atom_opening_digest full 1 |> some in
  append (B.Turn_ended {turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:3;
    task_context=Masc.Keeper_turn_task_context.No_task;
    history_at_start=B.Continued_history_from {start_atom=2;start_atom_digest};
    position=B.position_of_messages full |> get});
  let prepared = P.prepare ~end_atom:4 ~config ~keeper_name ~trace_id () |> get |> some in
  (match P.source_spans prepared with
   | [( {H.attribution=H.Unattributed;source=H.Atom_span {start_atom=0;end_atom=2;_}}, gap);
      ({H.attribution=H.Observed _;source=H.Atom_span {start_atom=2;end_atom=4;_}}, known)] ->
     check int "missing turn text kept" 2 (List.length gap);
     check int "only witnessed suffix attributed" 2 (List.length known)
   | _ -> fail "earlier unknown atoms inherited covering turn context");
  (match P.source_spans (P.narrow prepared |> some) with
   | [({H.attribution=H.Unattributed;_}, messages)] -> check int "narrowed unknown prefix" 2 (List.length messages)
   | _ -> fail "narrowing invented known attribution")

let test_completed_turn_work_units () =
  List.iter (fun fresh -> with_source @@ fun _env config save append boundary ->
    let first = [message "A"; message "B"] in
    let second = first @ [message "C"; message "D"; message "E"] in
    let full = second @ [message "F"; message "G"] in
    save full;
    boundary ~fresh 1 first; boundary ~fresh:false 2 second;
    boundary ~fresh:false 3 full;
    List.iter (fun (endpoint, count, turn) ->
      let prepared = prepare config |> some in
      check int "next completed turn only" endpoint (P.end_atom prepared);
      check int "only newly completed messages" count (List.length (P.messages prepared));
      check bool "actual covering turn" true
        (P.turn_ref prepared = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn);
      let fitted = P.fit ~fits:(fun _ -> Ok true) prepared |> get |> some in
      check bool "large capacity never widens the work unit" true (fitted == prepared);
      let receipt = P.memory_range_id ~config ~keeper_name prepared |> get in
      check int "receipt names selected boundary" turn receipt.end_boundary_line;
      let saved = commit config prepared "Prior work remains available." in
      check int "later boundary rows cannot replace selected anchor" endpoint saved.covering_end_atom;
      check bool "snapshot retains selected turn" true (saved.end_turn_ref = P.turn_ref prepared);
      let lines = B.read ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
        ~keeper_id:keeper_name |> get in
      let restored = S.restore ~trace_id ~lines ~messages:full saved
        |> Result.map_error S.error_to_string |> get in
      check int "restore preserves all later messages" (7 - endpoint) (List.length restored.messages))
      [2, 2, 1; 5, 3, 2; 7, 2, 3];
    check bool "backlog exhausted" true (Option.is_none (prepare config));
    append (B.History_restarted {trace_id});
    boundary ~fresh:false 10 first; boundary ~fresh:false 11 full;
    let restarted = prepare config |> some in
    check int "restart selects first new-generation turn" 2 (P.end_atom restarted);
    check bool "restart discards previous state" true
      (U.member "previous_working_state" (P.prompt_json restarted) = `Null);
    let saved = commit config restarted "Restarted work." in
    check int "restart snapshot uses new-generation boundary" 5 saved.end_boundary_line;
    check int "restart does not absorb later backlog" 2 saved.covering_end_atom)
    [true; false]

let test_recovery_overrides_next_turn () = with_source @@ fun _env config save _append boundary ->
  let first = [message "A"; message "B"] in
  let second = first @ [message "C"; message "D"] in
  let full = second @ [message "E"; message "F"] in
  save full; boundary ~fresh:true 1 first; boundary ~fresh:false 2 second;
  boundary ~fresh:false 3 full;
  let pending = P.prepare ~end_atom:5 ~config ~keeper_name ~trace_id () |> get |> some in
  let receipt = P.memory_range_id ~config ~keeper_name pending |> get in
  record_prepared_memory config pending;
  let recovered = P.prepare ~end_atom:1 ~config ~keeper_name ~trace_id () |> get |> some in
  check int "pending publication keeps exact interval ahead of natural turn" 5 (P.end_atom recovered);
  check bool "pending publication keeps exact receipt" true
    ((P.memory_range_id ~config ~keeper_name recovered |> get) = receipt);
  check bool "pending publication cannot be subdivided" true (Option.is_none (P.narrow recovered));
  let saved = P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared:recovered ~working_state:"Five atoms." |> get in
  check int "recovery retains actual covering turn" 6 saved.covering_end_atom;
  check int "recovery retains exact boundary line" 3 saved.end_boundary_line;
  let next = prepare config |> some in
  check int "remaining turn endpoint" 6 (P.end_atom next);
  check int "remaining turn suffix" 1 (List.length (P.messages next))

let test_fit_splits_only_oversized_work_unit () = with_source @@ fun _env config save _append boundary ->
  let messages = List.init 8 (fun index -> message (String.make (index + 1) 'x')) in
  save messages; boundary ~fresh:true 1 messages;
  let prepared = prepare config |> some in
  (* A candidate as the pass reads it: the prior state and the exact source
     atoms of its range. *)
  let view candidate = Yojson.Safe.to_string (`List [ P.prompt_json candidate;
    `List (List.map Agent_core.Checkpoint.message_to_json (P.messages candidate)) ]) in
  let original = view prepared in
  let visited = ref [] in
  let whole = P.fit ~fits:(fun candidate ->
    visited := P.end_atom candidate :: !visited; Ok true) prepared |> get |> some in
  check bool "fitting original returned unchanged" true (whole == prepared);
  check (list int) "whole request tested before search" [8] !visited;
  let first = P.narrow prepared |> some in
  ignore (commit config first "Prior work preserved.");
  let suffix = prepare config |> some in
  let exact_size candidate = view candidate |> String.length in
  let room_for_more = P.prepare ~end_atom:7 ~config ~keeper_name ~trace_id () |> get |> some in
  let limit = exact_size room_for_more in
  let expected = P.narrow suffix |> some in
  visited := [];
  let fitted = P.fit ~fits:(fun candidate ->
      visited := !visited @ [P.end_atom candidate];
      Ok (exact_size candidate <= limit)) suffix |> get |> some in
  check int "split work unit stops below capacity even with room for another atom" 6 (P.end_atom fitted);
  check (list int) "no capacity-filling search after a fitting split" [8;6] !visited;
  check string "exact suffix and prior state preserved" (view expected) (view fitted);
  check string "frozen original unaffected" original (view prepared);
  let minimum_seen = ref false in
  check bool "no indivisible atom fits" true
    (P.fit ~fits:(fun candidate ->
       if P.end_atom candidate = 5 then minimum_seen := true; Ok false) suffix
     |> get |> Option.is_none);
  check bool "minimum remaining atom was tested" true !minimum_seen;
  check bool "predicate error propagated from search" true
    (P.fit ~fits:(fun candidate ->
       if P.end_atom candidate = 8 then Ok false else Error "measurement failed") suffix
     = Error "measurement failed")

let test_fit_keeps_exact_recovery_range () = with_source @@ fun _env config save _append boundary ->
  let messages = [message "A"; message "B"; message "C"; message "D"] in
  save messages; boundary ~fresh:true 1 messages;
  let partial = prepare config |> some |> P.narrow |> some in
  record_prepared_memory config partial;
  let recovery = prepare config |> some in
  let visited = ref [] in
  let result = P.fit ~fits:(fun candidate ->
    visited := P.end_atom candidate :: !visited; Ok false) recovery |> get in
  check bool "unfit committed interval cannot be split" true (Option.is_none result);
  check (list int) "only exact recovery interval tested" [2] !visited;
  let fitted = P.fit ~fits:(fun _ -> Ok true) recovery |> get |> some in
  check bool "fitting recovery interval returned unchanged" true
    (fitted == recovery)

let test_queue_reuses_capacity_without_gating_alternatives () =
  let open Masc in
  let module F = Exact_output_fixture in
  let module K = Masc.Keeper_librarian in
  let module Current = Masc.Keeper_memory_os_current in
  let module Codex = Runtime_codex_app_server in
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "true") @@ fun () ->
  F.with_official_client_runtimes @@ fun () ->
  with_source @@ fun env config save _append boundary ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  let base_path = config.Masc.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_bin (Filename.concat keepers_dir (keeper_name ^ ".toml")) (fun oc ->
    Printf.fprintf oc "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = %S\nsandbox_image = \"base\"\n"
      keeper_name "Preserve evidence." "docker");
  Masc.Keeper_types_profile.invalidate_keeper_profile_defaults_cache keeper_name;
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name", `String keeper_name; "trace_id", `String trace_id]) |> get in
  Masc.Keeper_meta_store.replace_snapshot config meta |> get;
  let instructions = match Masc.Keeper_meta_store.read_effective_meta_presence config keeper_name |> get with
    | Meta_present meta -> meta.instructions
    | Meta_absent | Meta_not_current _ -> fail "queue fixture lacks effective metadata" in
  let registry = Exact_lane_run_registry.create
    ~path:(Filename.concat base_path Exact_lane_run_registry.storage_filename) () in
  (match Exact_lane_run_registry.install_global registry with
   | Ok () -> () | Error Already_installed -> fail "queue fixture registry already installed");
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  ignore (F.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[]
    ~cli_slot_ids:[F.cli_secondary_runtime; F.cli_primary_runtime]
    (F.resolver_snapshot ~source:"queue-capacity" []));
  let source = List.map message [String.make 1000 'a'; String.make 1000 'b';
    String.make 1000 'c'; String.make 6000 'd'] in
  save source; boundary ~fresh:true 1 source;
  let current = Current.apply_disposition ~revisions:[] ~keepers_dir ~keeper_id:keeper_name ~now:1000.
    ~source:{kind=Current.Librarian;trace_id} ~absorbed:[] ~new_claims:[] () |> get
    |> fun (d : Current.disposition) -> d.snapshot in
  let half = prepare config |> some |> P.narrow |> some in
  let _, historical_task_contexts = List.fold_left (fun (first_message, contexts) (scope, messages) ->
    let after_message = first_message + List.length messages in
    let context : Masc.Keeper_librarian_task_context.t =
      {scope;first_message;after_message;first_tool_observation=0;after_tool_observation=0} in
    after_message, contexts @ [context]) (0, []) (P.source_spans half) in
  let input : K.input =
    {turn_ref=P.turn_ref half; historical_task_contexts; goal_context =K.No_task;
     keeper_id=Masc_test_deps.keeper_id_fixture keeper_name; keeper_instructions=instructions;
     current=Some {K.facts=current.facts};
     working_context=Masc.Keeper_librarian_context.empty;
     messages=P.messages half; tool_observations=[];counterpart_observations=[]} in
  let variables =
    Masc.Keeper_librarian_runtime.librarian_prompt_variables ~continuity:half input |> get in
  let _, prompt = Prompt_registry.resolve_and_render_prompt_template
    Prompt_names.librarian variables |> get in
  let requirement = Agent_core.Exact_output.make_output_requirement
    ~schema:Masc.Keeper_structured_output_schema.librarian_continuity_output_schema
    ~minimum_guarantee:Agent_core.Exact_output.Json_syntax in
  let chars prompt = Codex.prompt_char_count prompt |> get in
  let max_chars = Masc.Keeper_lane_cli_oneshot.prompt_with_schema ~requirement ~prompt |> chars in
  let oversized = ref 0 and final_calls = ref 0 and alternative_bytes = ref None in
  let answer = {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":"s"}|} in
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt =
    let actual_chars = chars prompt in
    if String.equal runtime_id F.cli_secondary_runtime then
      match P.read ~config ~keeper_name |> get with
      | Some saved when saved.end_atom = 3 -> alternative_bytes := Some actual_chars; Ok answer
      | _ -> Error (Masc.Fusion_official_client.Setup_failure "fixture unavailable")
    else (
      incr final_calls;
      if actual_chars > max_chars then (
        incr oversized;
        Error (Masc.Fusion_official_client.Codex_failure (Codex.Rpc_error
          {method_="turn/start";code=Some (-32602);message="fixture capacity";
           data=Some (`Assoc ["input_error_code", `String "input_too_large";
             "actual_chars", `Int actual_chars; "max_chars", `Int max_chars])})))
      else Ok answer)
  in
  Masc.Keeper_librarian_queue_refresh.For_testing.run_continuity
    ~cli_runner:runner ~base_path ~keeper_name ();
  let saved = P.read ~config ~keeper_name |> get |> some in
  check int "actual queue publishes every source atom" 4 saved.end_atom;
  check int "known final-slot bound prevents repeated oversized probes" 1 !oversized;
  check int "one refusal and two fitted chunks reach final slot" 3 !final_calls;
  check bool "commits by the other CLI slot keep the learned limit" true
    (Option.is_some
       (Masc.Keeper_librarian_queue_refresh.For_testing.last_input_capacity ~config ~keeper_name));
  check bool "no-fit source still reaches recovered alternative" true
    (match !alternative_bytes with Some size -> size > max_chars | None -> false);
  let module O = Masc.Keeper_continuity_observation in
  let observation () = O.latest_synthesis ~config ~keeper_name |> some in
  check bool "no further source is not labelled drained" true
    ((observation ()).state = O.No_source);
  let next_turn = List.init 4 (fun index ->
    message (String.make 1000 (Char.chr (Char.code 'e' + index)))) in
  let extended = source @ next_turn in
  save extended; boundary ~fresh:false 2 extended;
  let rejected_calls = ref 0 in
  let rejected ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt =
    incr rejected_calls;
    check bool "actual runtime dispatch is visibly running" true
      ((observation ()).state = O.Running);
    check bool "new drain fits the learned character ceiling before dispatch" true
      (chars prompt <= max_chars);
    Ok {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":null}|} in
  Masc.Keeper_librarian_queue_refresh.For_testing.run_continuity
    ~cli_runner:rejected ~base_path ~keeper_name ();
  check int "domain refusal advances through both declared slots" 2 !rejected_calls;
  check bool "failed generation replaces running state" true
    ((observation ()).state = O.Not_committed);
  check bool "domain refusal records only the local unchanged-width branch" true
    ((observation ()).stop_reason = Some O.No_smaller_range_evidence);
  check int "refused range keeps committed frontier" 4
    (P.read ~config ~keeper_name |> get |> some).end_atom;
  let resumed_calls = ref 0 in
  let resumed ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt =
    incr resumed_calls;
    check bool "terminal reason is cleared at real resumed dispatch" true
      ((observation ()).state = O.Running && (observation ()).stop_reason = None);
    check bool "domain refusal did not erase the next drain's measured ceiling" true
      (chars prompt <= max_chars);
    Ok answer in
  Masc.Keeper_librarian_queue_refresh.For_testing.run_continuity
    ~cli_runner:resumed ~base_path ~keeper_name ();
  check bool "resumed drain really dispatched" true (!resumed_calls > 0);
  check int "resumed drain commits the remaining completed atoms" 8
    (P.read ~config ~keeper_name |> get |> some).end_atom;
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  let canonical = match C.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id with
    | Ok snapshot -> C.exact_snapshot_messages snapshot
    | Error _ -> fail "source checkpoint disappeared" in
  check bool "prefitting and failed generation preserve the original source" true
    (List.equal Agent_core.Types.Message_value.equal extended canonical);
  let after_forget = extended @ next_turn in
  save after_forget; boundary ~fresh:false 3 after_forget;
  Masc.Keeper_librarian_queue_refresh.forget_measurement ~config ~keeper_name;
  let forgotten_calls = ref 0 in
  let forgotten ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt =
    incr forgotten_calls;
    check bool "forget removes the learned ceiling instead of retaining stale knowledge" true
      (chars prompt > max_chars);
    Ok {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":null}|} in
  Masc.Keeper_librarian_queue_refresh.For_testing.run_continuity
    ~cli_runner:forgotten ~base_path ~keeper_name ();
  check int "after forget the unfit source still reaches declared alternatives" 2 !forgotten_calls;
  check int "failed request after forget does not advance coverage" 8
    (P.read ~config ~keeper_name |> get |> some).end_atom;
  (try Eio.Cancel.sub (fun cancellation ->
     let cancelled ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ =
       check bool "cancelling runtime was running" true ((observation ()).state = O.Running);
       Eio.Cancel.cancel cancellation Exit;
       Eio.Fiber.check ();
       Ok answer in
     Masc.Keeper_librarian_queue_refresh.For_testing.run_continuity
       ~cli_runner:cancelled ~base_path ~keeper_name ())
   with Eio.Cancel.Cancelled _ -> ());
  check bool "cancellation replaces running state" true ((observation ()).state = O.Cancelled);
  O.record ~config ~keeper_name
    {prepared_at=1000.;runtime_id="fixture";input=O.Without_snapshot;request_bytes=1};
  O.forget ~config ~keeper_name;
  check bool "forget clears both observations" true
    (Option.is_none (O.latest_synthesis ~config ~keeper_name)
     && Option.is_none (O.latest ~config ~keeper_name))

(* A rewrite from atom 0 carries where a request starts without it -- here
   the end of the last completed turn, as no Librarian position is saved --
   takes it again each round, since turns keep ending while it catches up,
   and drops it once its end reaches it. A target fixed when the rewrite
   began would clear at the third turn, and the next request would start
   back there and resend the fourth. *)
let test_rewrite_from_zero_follows_its_target () = with_source @@ fun _env config save _append boundary ->
  let one = [message "first"] in
  let two = one @ [message "second"] in
  let three = two @ [message "third"] in
  let four = three @ [message "fourth"] in
  save three; boundary ~fresh:true 1 one; boundary ~fresh:false 2 two; boundary ~fresh:false 3 three;
  let first = commit config (prepare config |> some) "after the first turn" in
  check int "the rewrite starts with the first turn" 1 first.end_atom;
  check (option int) "short of the last completed turn" (Some 3) first.catch_up_end_atom;
  save four; boundary ~fresh:false 4 four;
  let second = commit config (prepare config |> some) "after the second turn" in
  check int "one more turn" 2 second.end_atom;
  check (option int) "the target follows the turn that ended meanwhile" (Some 4)
    second.catch_up_end_atom;
  let third = commit config (prepare config |> some) "after the third turn" in
  check (option int) "past where it began, still short of where requests start" (Some 4)
    third.catch_up_end_atom;
  let fourth = commit config (prepare config |> some) "after the fourth turn" in
  check int "caught up" 4 fourth.end_atom;
  check (option int) "and the target is gone" None fourth.catch_up_end_atom

(* With a Librarian position that fits the history, that position is where
   requests started, so it is the target. *)
let test_rewrite_target_is_the_librarian_position () = with_source @@ fun _env config save _append boundary ->
  let one = [message "first"] in
  let two = one @ [message "second"] in
  let three = two @ [message "third"] in
  save three; boundary ~fresh:true 1 one; boundary ~fresh:false 2 two; boundary ~fresh:false 3 three;
  let last_atom_digest =
    Runtime_model_input_tail_window.atom_opening_digest three 1 |> Option.get in
  Masc.Keeper_librarian_progress.write
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
    { position = { trace_id; end_atom = 2; last_atom_digest }; boundary_lines_seen = 2 }
  |> Result.map_error Masc.Keeper_librarian_progress.write_error_to_string |> get;
  let first = commit config (prepare config |> some) "after the first turn" in
  check (option int) "the target is the Librarian's position" (Some 2) first.catch_up_end_atom


(* A snapshot file that cannot be decoded -- here a truncated one, standing
   for any format this binary does not accept. It is derived state,
   so the next pass rebuilds it from atom 0 and the commit replaces the file;
   the rebuilt snapshot carries a catch-up target, so a request does not start
   back at its early end. Before, every pass stopped on the decode error and
   nothing ever replaced the file. *)
let test_an_undecodable_snapshot_is_rebuilt () = with_source @@ fun _env config save _append boundary ->
  let one = [message "first"] in
  let two = one @ [message "second"] in
  save two; boundary ~fresh:true 1 one; boundary ~fresh:false 2 two;
  let file = P.path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname file);
  Out_channel.with_open_bin file (fun channel -> output_string channel {|{"origin":"witn|});
  check bool "the torn file is still refused by read" true (Result.is_error (P.read ~config ~keeper_name));
  let prepared =
    match P.prepare_source ~config ~keeper_name ~trace_id () |> get with
    | P.Ready prepared -> prepared
    | P.No_source (P.Drained | P.Source_unreadable | P.Empty_range) -> fail "no source to rebuild" in
  check int "the rebuild starts at atom 0" 0 (P.start_atom prepared);
  check bool "no working state is invented" true
    (U.member "previous_working_state" (P.prompt_json prepared) = `Null);
  let rebuilt = commit config prepared "after the first turn" in
  check int "the rebuilt snapshot ends at the first turn" 1 rebuilt.end_atom;
  check (option int) "a request does not start at its early end" (Some 2) rebuilt.catch_up_end_atom;
  check bool "the commit replaced the torn file" true
    (P.read ~config ~keeper_name |> get = Some rebuilt)

(* Two passes read the same undecodable file; the second commits a valid
   snapshot first. The first pass's commit must see that the file changed
   and leave the valid snapshot alone. *)
let test_a_rebuild_does_not_overwrite_a_valid_snapshot () = with_source @@ fun _env config save _append boundary ->
  let one = [message "first"] in
  let two = one @ [message "second"] in
  save two; boundary ~fresh:true 1 one; boundary ~fresh:false 2 two;
  let file = P.path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname file);
  Out_channel.with_open_bin file (fun channel -> output_string channel {|{"origin":"witn|});
  let late = prepare config |> some in
  ignore (commit config (prepare config |> some) "the pass that finished first");
  let bytes () = In_channel.with_open_bin file In_channel.input_all in
  let valid = bytes () in
  check bool "the late rebuild is refused" true
    (Result.is_error (P.commit ~new_unread_messages:[] ~config ~keeper_name ~prepared:late ~working_state:"the late pass"));
  check string "the valid snapshot is unchanged" valid (bytes ())

(* A snapshot path that cannot be read is an I/O failure, not a decode
   failure: nothing is rebuilt over it. *)
let test_an_unreadable_snapshot_stays_an_error () = with_source @@ fun _env config save _append boundary ->
  let one = [message "first"] in
  save one; boundary ~fresh:true 1 one;
  Fs_compat.mkdir_p (P.path ~config ~keeper_name);
  check bool "an unreadable snapshot stops the pass" true
    (Result.is_error (P.prepare_source ~config ~keeper_name ~trace_id ()))

let narrowing_marks = [ 'a'; 'b'; 'c'; 'd'; 'e'; 'f'; 'g'; 'h' ]
let narrowing_atom_count = List.length narrowing_marks

(* Eight atoms leave six after the first accepted two-atom unit. This exposes
   a loop that incorrectly releases its width on the first commit. Payloads
   remain large to exercise actual request rendering; the fixture capacity is
   stated in selected source atoms, independent of template/schema overhead. *)
let narrowing_atom_chars = 16_000
let narrowing_atom_text mark = String.make narrowing_atom_chars mark

(* A Keeper whose continuity snapshot no longer fits its history prepares from
   atom 0, so one pass's source is the whole backlog. These cases pin what a
   refused pass carries to the next one and which refusals must not move it at
   all (#37793: one live Keeper walked 12756 -> 6378 -> 3189 ninety-six times
   in a day and committed nothing, because every pass started over). *)
let narrowing_fixture ?(cli_slot_ids = []) ?cli_runner ?has_waiting
    ?receipt_answer ?(body_timeouts = [])
    ?(task_context = Masc.Keeper_turn_task_context.No_task)
    ?(atoms = List.map (fun mark -> message (narrowing_atom_text mark)) narrowing_marks)
    ~slot_count ~answer f =
  let open Masc in
  let module F = Exact_output_fixture in
  let module Current = Masc.Keeper_memory_os_current in
  let with_cli_runtimes body =
    match cli_slot_ids with
    | [] -> body ()
    | _ :: _ -> F.with_official_client_runtimes body
  in
  with_cli_runtimes @@ fun () ->
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "true")
  @@ fun () ->
  with_source @@ fun env config save append _boundary ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw
  @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let base_path = config.Masc.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_bin (Filename.concat keepers_dir (keeper_name ^ ".toml")) (fun oc ->
    Printf.fprintf oc "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = %S\nsandbox_image = \"base\"\n"
      keeper_name "Preserve evidence." "docker");
  Masc.Keeper_types_profile.invalidate_keeper_profile_defaults_cache keeper_name;
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name", `String keeper_name; "trace_id", `String trace_id]) |> get in
  Masc.Keeper_meta_store.replace_snapshot config meta |> get;
  let registry = Exact_lane_run_registry.create
    ~path:(Filename.concat base_path Exact_lane_run_registry.storage_filename) () in
  (match Exact_lane_run_registry.install_global registry with
   | Ok () | Error Exact_lane_run_registry.Already_installed -> ());
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  let bodies = ref [] in
  let behavior = match receipt_answer with
    | None -> F.Reply_with (fun index body ->
        bodies := !bodies @ [String.length body]; answer index body)
    | Some answer -> F.Reply_with_receipt (fun index body ->
        bodies := !bodies @ [String.length body]; answer index body) in
  let server = F.start_server ~sw ~net:env#net ~clock:env#clock behavior in
  let slot_ids = List.init slot_count (fun index -> Printf.sprintf "narrowing-slot-%d" index) in
  ignore (F.publish_registry ~cli_slot_ids ~lane_id:"librarian_exact" ~slot_ids
    (F.resolver_snapshot ~body_timeouts ~source:"narrowing-fixture"
       (List.map (fun id -> { F.id; base_url = server.F.base_url }) slot_ids)));
  save atoms;
  append (B.Turn_ended {turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
    task_context; history_at_start=B.Fresh_history;position=B.position_of_messages atoms |> get});
  ignore (Current.apply_disposition ~revisions:[] ~keepers_dir ~keeper_id:keeper_name ~now:1000.
    ~source:{ kind = Current.Librarian; trace_id } ~absorbed:[] ~new_claims:[] () |> get);
  (* No forget_measurement between passes: that is what a server restart does,
     and the width these cases are about lives in the same memory. *)
  let pass () =
    Masc.Keeper_librarian_queue_refresh.For_testing.run_continuity ?cli_runner ?has_waiting ~base_path
      ~keeper_name () in
  let coverage () = Option.map (fun (s : S.t) -> s.end_atom) (P.read ~config ~keeper_name |> get) in
  (* Take the checkpoint away for one pass. prepare then answers with no
     source without the backlog having been read, which is the outcome the
     width must survive. *)
  let hide_source body =
    let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
    let hidden = session_dir ^ ".hidden" in
    Sys.rename session_dir hidden;
    Fun.protect ~finally:(fun () -> Sys.rename hidden session_dir) body
  in
  (* What a server restart does to the loop's memory. *)
  let restart () = Masc.Keeper_librarian_queue_refresh.forget_measurement ~config ~keeper_name in
  f ~bodies ~pass ~coverage ~hide_source ~restart ~config

let fixture_atom_capacity = 2
let accepted_answer =
  Exact_output_fixture.openai_response
    (Yojson.Safe.from_string
       {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":"s"}|})
let refused kind = Printf.sprintf {|{"error":{"message":"fixture %s","type":"%s"}}|} kind kind

let contains ~sub text =
  let n = String.length sub and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = sub || at (i + 1)) in
  at 0

(* Non-overlapping occurrences of [sub] in [text]. *)
let occurrences ~sub text =
  let n = String.length sub and m = String.length text in
  let rec from i count =
    if i + n > m then count
    else if String.sub text i n = sub then from (i + n) (count + 1)
    else from (i + 1) count in
  from 0 0

let check_each_atom_once body =
  List.iter (fun mark ->
    check int (Printf.sprintf "atom %c travels once" mark) 1
      (occurrences ~sub:(narrowing_atom_text mark) body))
    narrowing_marks

(* One completed turn, during which a counterpart spoke, on a lane of one CLI
   slot whose answers [runner] gives. *)
let with_counterpart_turn ~counterpart f =
  let open Masc in
  let module F = Exact_output_fixture in
  Masc_test_deps.with_process_env Env_config.KeeperMemoryOs.librarian_env_key (Some "true") @@ fun () ->
  F.with_official_client_runtimes @@ fun () ->
  with_source @@ fun env config save _append _boundary ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  let base_path = config.Masc.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_bin (Filename.concat keepers_dir (keeper_name ^ ".toml")) (fun oc ->
    Printf.fprintf oc "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = %S\nsandbox_image = \"base\"\n"
      keeper_name "Preserve evidence." "docker");
  Masc.Keeper_types_profile.invalidate_keeper_profile_defaults_cache keeper_name;
  let meta = Masc_test_deps.meta_of_json_fixture
    (`Assoc ["name", `String keeper_name; "trace_id", `String trace_id]) |> get in
  Masc.Keeper_meta_store.replace_snapshot config meta |> get;
  let registry = Exact_lane_run_registry.create
    ~path:(Filename.concat base_path Exact_lane_run_registry.storage_filename) () in
  (match Exact_lane_run_registry.install_global registry with
   | Ok () | Error Exact_lane_run_registry.Already_installed -> ());
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  ignore (F.publish_registry ~lane_id:"librarian_exact" ~slot_ids:[]
    ~cli_slot_ids:[F.cli_primary_runtime]
    (F.resolver_snapshot ~source:"continuity-counterpart" []));
  Keeper_chat_store.append_user_message ~base_dir:base_path ~keeper_name ~content:counterpart
    ~speaker:({ speaker_id = Some "external"; speaker_name = Some "External";
                speaker_authority = Keeper_chat_store.External } : Keeper_chat_store.speaker)
    ();
  (* The turn ends after the counterpart spoke. *)
  let turn = [message "turn-1"] in
  save turn;
  B.append ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
    {B.recorded_at = Time_compat.now () +. 60.;
     event = B.Turn_ended { task_context = Masc.Keeper_turn_task_context.No_task;turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
       history_at_start = B.Fresh_history; position = B.position_of_messages turn |> get}}
  |> Result.map_error B.append_error_to_string |> get;
  let continuity runner =
    Masc.Keeper_librarian_queue_refresh.For_testing.run_continuity
      ~cli_runner:runner ~base_path ~keeper_name () in
  f ~config ~continuity

let memory_answer = {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":"s"}|}

let durable_reads config ~commit =
  let module Consumer = Masc.Keeper_librarian_durable_consumer in
  match Consumer.consume_one ~config ~keeper_name ~commit with
  | Ok (Consumer.Progress_advanced progress) -> progress.position.end_atom
  | Ok (Consumer.Nothing_to_read | Consumer.Baseline_advanced _ | Consumer.Memory_not_committed _
       | Consumer.Official_advanced _) ->
    fail "the durable pass did not move past the turn"
  | Error error -> fail (Consumer.error_to_string error)

(* A continuity pass that saves Memory is the only pass that reads its atoms:
   the durable pass moves past them afterwards without reading them again
   (#39179). A counterpart who spoke during the turn has to reach this pass,
   or no Memory pass ever sees what they said. *)
let test_a_memory_pass_carries_the_counterparts_of_its_turn () =
  let counterpart = "counterpart-promised-the-release-notes-by-friday" in
  with_counterpart_turn ~counterpart @@ fun ~config ~continuity ->
  let prompts = ref [] in
  continuity (fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt ->
    prompts := !prompts @ [prompt];
    Ok memory_answer);
  (match !prompts with
   | [prompt] ->
     check bool "the Memory pass carries the counterpart who spoke during its turn" true
       (contains ~sub:counterpart prompt)
   | _ -> fail "expected one Memory pass");
  check (option int) "the pass saved and published the turn" (Some 1)
    (Option.map (fun (saved : S.t) -> saved.end_atom) (P.read ~config ~keeper_name |> get));
  check int "the durable pass moves past the saved turn without the model" 1
    (durable_reads config ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
       fail "the durable pass sent the saved turn again"))

(* The CLI slot reports a limit the turn fits without its counterpart and not
   with it, and the turn is one atom, so no smaller unit can leave the
   counterpart out. Both the whole-turn request and the single-message floor
   must retain that counterpart. Their CLI refusals grant no skip authority,
   so this round leaves Memory to the durable pass. The durable pass reads
   the turn with the counterpart, and the next continuity pass, now
   Context-only, publishes the turn. *)
let test_a_turn_too_large_with_its_counterparts_is_left_to_the_durable_pass () =
  let module Codex = Runtime_codex_app_server in
  let module O = Masc.Keeper_continuity_observation in
  let module Current = Masc.Keeper_memory_os_current in
  let counterpart = "counterpart-marker-" ^ String.make 4000 'x' in
  with_counterpart_turn ~counterpart @@ fun ~config ~continuity ->
  let refused_prompts = ref [] in
  continuity (fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt ->
    refused_prompts := !refused_prompts @ [prompt];
    let actual_chars = Codex.prompt_char_count prompt |> get in
    Error (Masc.Fusion_official_client.Codex_failure (Codex.Rpc_error
      {method_="turn/start"; code=Some (-32602); message="fixture capacity";
       data=Some (`Assoc ["input_error_code", `String "input_too_large";
         "actual_chars", `Int actual_chars;
         "max_chars", `Int (actual_chars - String.length counterpart)])})));
  (match !refused_prompts with
   | [whole; single] ->
     List.iter (fun prompt ->
       check int "each refusal retains the original turn exactly once" 1
         (occurrences ~sub:"turn-1" prompt);
       check int "message descent cannot omit or duplicate the counterpart" 1
         (occurrences ~sub:counterpart prompt)) [whole; single]
   | _ -> fail "expected the whole-turn refusal followed by its original single-message floor");
  check bool "no snapshot is published" true (P.read ~config ~keeper_name |> get = None);
  check bool "the turn's Memory is left to the durable pass" true
    ((O.latest_synthesis ~config ~keeper_name |> some).state = O.Not_committed);
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Masc.Workspace.base_path in
  let received = ref [] in
  check int "the durable pass reads the turn" 1
    (durable_reads config ~commit:(fun ~expected_revision:_ ~range_id ~official_range_id
       (input : Masc.Keeper_librarian.input) ->
       received := List.map (fun (o : Masc.Keeper_counterpart_observation.t) -> o.content)
           input.counterpart_observations;
       match Current.apply_disposition ~revisions:[] ?durable_range_id:range_id
               ?official_range_id ~absorbed:[] ~keepers_dir ~keeper_id:keeper_name ~now:1001.
               ~source:{kind = Current.Librarian; trace_id} ~new_claims:[] () with
       | Ok _ -> Masc.Keeper_librarian_durable_consumer.Memory_committed
       | Error detail -> fail detail));
  check bool "with the counterpart the continuity pass could not carry" true
    (List.mem counterpart !received);
  continuity (fun ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt:_ ->
    Ok {|{"working_state":"s"}|});
  check (option int) "the next continuity pass publishes the turn Context-only" (Some 1)
    (Option.map (fun (saved : S.t) -> saved.end_atom) (P.read ~config ~keeper_name |> get))

(* A continuity range whose Memory the durable pass already committed is a
   Context-only pass (#38184). It asks for the working state alone: the
   request names no Memory output field, the conversation travels once, and
   an answer of the working state alone commits the range without touching
   Memory. *)
let test_a_committed_range_asks_for_the_working_state_alone () =
  let requests = ref [] in
  narrowing_fixture ~slot_count:1
    ~answer:(fun _index body ->
      requests := !requests @ [ body ];
      ( `OK
      , Exact_output_fixture.openai_response
          (`Assoc [ "working_state", `String "Continue from the eighth atom." ]) ))
  @@ fun ~bodies:_ ~pass ~coverage ~hide_source:_ ~restart:_ ~config ->
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Masc.Workspace.base_path in
  let memory_revision () =
    Masc.Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name
    |> get
    |> Option.map (fun (s : Masc.Keeper_memory_os_current.t) -> s.revision) in
  record_memory config;
  let before = memory_revision () in
  pass ();
  check int "one request" 1 (List.length !requests);
  let body = List.hd !requests in
  check bool "the request names no Memory output field" false
    (contains ~sub:Masc.Keeper_librarian.wire_field_new_claims body);
  check_each_atom_once body;
  check (option int) "the working state alone commits the whole range"
    (Some narrowing_atom_count) (coverage ());
  check (option int) "Memory stays as the durable pass committed it" before (memory_revision ())

(* #37857: a continuity pass carries the range once, folded. Tool calls and
   results reach the request as their folded lines, which keep the tool name
   and the outcome, and never as the call arguments or the result body. Both
   passes that read a continuity range are checked: the Memory pass, and the
   Context-only pass over a range whose Memory is already committed. *)
let tool_argument_marker = "fixture-tool-argument-value"
let tool_result_marker = "fixture-tool-result-body"
let tool_name = "read_file"
let tool_atom_indices = [ 1; 2; 3 ]
let tool_atom_opening index = Printf.sprintf "tool-atom-%d-opening" index
let tool_call_id index = Printf.sprintf "call-%d" index
(* One call fails, so the folded result lines must carry both outcomes. *)
let tool_call_fails index = index = 2
let tool_atoms =
  let open Agent_core.Types in
  List.concat_map (fun index ->
    let call_id = tool_call_id index in
    [ message (tool_atom_opening index)
    ; make_message ~role:Assistant
        [ ToolUse { id = call_id; name = tool_name
                  ; input = `Assoc [ "path", `String tool_argument_marker ] } ]
    ; { (make_message ~role:Tool
           [ ToolResult { tool_use_id = call_id; content = tool_result_marker
                        ; outcome = (if tool_call_fails index
                            then Tool_failed { failure_kind = Reported_tool_error; error_class = None }
                            else Tool_succeeded)
                        ; json = None; content_blocks = None } ])
        with tool_call_id = Some call_id } ])
    tool_atom_indices

(* One assistant/tool atom cannot be cut at an atom boundary. Its Memory
   receipt already exists, but no continuity frontier exists. A body refusal
   must allow sequential inference without publishing either partial state. *)
type queue_native_descent =
  | Queue_codex_native
  | Queue_claude_native
  | Queue_json_before_native
  | Queue_native_before_domain
  | Queue_measured_before_json
  | Queue_effect_started
  | Queue_opaque_failure

let queue_native_failure ~claude ~tool_effect =
  if claude then Masc.Fusion_official_client.Claude_failure
    (Runtime_claude_code.Context_window_exceeded
      {message="fixture unmeasured native refusal";tool_effect_attempted=tool_effect;response_emitted=false})
  else Masc.Fusion_official_client.Codex_failure
    (Runtime_codex_app_server.Context_window_exceeded
      {message="fixture unmeasured native refusal";tool_effect_attempted=tool_effect})

let queue_native_succeeds = function
  | Queue_codex_native | Queue_claude_native -> true
  | Queue_json_before_native | Queue_native_before_domain | Queue_measured_before_json
  | Queue_effect_started | Queue_opaque_failure -> false

let queue_native_answers ~prompt = function
  | Queue_codex_native -> [Error (queue_native_failure ~claude:false ~tool_effect:false)]
  | Queue_claude_native -> [Error (queue_native_failure ~claude:true ~tool_effect:false)]
  | Queue_json_before_native -> [Ok "not-json";Error (queue_native_failure ~claude:false ~tool_effect:false)]
  | Queue_native_before_domain -> [Error (queue_native_failure ~claude:false ~tool_effect:false);Ok "{}"]
  | Queue_measured_before_json ->
    let actual_chars = Runtime_codex_app_server.prompt_char_count prompt |> get in
    [Error (Masc.Fusion_official_client.Codex_failure (Runtime_codex_app_server.Rpc_error
      {method_="turn/start";code=Some (-32602);message="fixture measured capacity before invalid output";
       data=Some (`Assoc ["input_error_code",`String "input_too_large";
         "actual_chars",`Int actual_chars;"max_chars",`Int (actual_chars-1)])}));Ok "not-json"]
  | Queue_effect_started -> [Error (queue_native_failure ~claude:false ~tool_effect:true)]
  | Queue_opaque_failure -> [Error (Masc.Fusion_official_client.Setup_failure "fixture opaque native failure")]

let test_volatile_message_floor ?native ~failure () =
  let module Registry = Masc.Exact_lane_run_registry in
  let requests = ref [] and before_answer = ref (fun () -> ()) in
  let atoms = List.take 2 (List.drop 1 tool_atoms) in
  let answer state = `OK, Exact_output_fixture.openai_response
      (`Assoc ["working_state", `String state]) in
  let refusal status = status,
      {|{"error":{"type":"invalid_request_error","message":"fixture refusal"}}|} in
  let runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt =
    check string "the native slot serves the real Memory-covered context pass" Exact_output_fixture.cli_primary_runtime runtime_id;
    (!before_answer) ();
    let position = List.length !requests in
    requests := !requests @ [prompt];
    if position=0 then List.hd (queue_native_answers ~prompt (Option.get native))
    else if position<=2 then Ok (Yojson.Safe.to_string (`Assoc ["working_state",
      `String (if position=1 then "remembered-call" else "remembered-call-and-result")]))
    else fail "native context descent generated after the original atom was complete" in
  narrowing_fixture ~atoms ~slot_count:(if Option.is_some native then 0 else 1)
    ~cli_slot_ids:(if Option.is_some native then [Exact_output_fixture.cli_primary_runtime] else [])
    ?cli_runner:(Option.map (fun _ -> runner) native)
    ~answer:(fun index body ->
      (!before_answer) ();
      requests := !requests @ [body];
      match index, failure with
      | 0, _ | 3, Some _ -> refusal `Request_entity_too_large
      | 1, _ | 4, Some _ -> answer "remembered-call"
      | 2, Some status -> refusal status
      | 2, None | 5, Some _ -> answer "remembered-call-and-result"
      | _ -> fail "unexpected volatile read request")
  @@ fun ~bodies:_ ~pass ~coverage ~hide_source:_ ~restart:_ ~config ->
  let module Current = Masc.Keeper_memory_os_current in
  let module Progress = Masc.Keeper_librarian_progress in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Masc.Workspace.base_path in
  record_memory config;
  let memory_before = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get in
  let prepared = prepare config |> some in
  let receipt_scope = (P.memory_range_id ~config ~keeper_name prepared |> get).receipt_scope in
  let receipt () = Current.committed_durable_range ~keepers_dir ~keeper_id:keeper_name
      ~receipt_scope |> get in
  let receipt_before = receipt () in
  let progress () = Progress.read ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper_name |> Result.map_error Progress.read_error_to_string |> get in
  let progress_before = progress () in
  before_answer := (fun () ->
    check (option int) "no partial continuity frontier during inference" None (coverage ());
    check bool "inference cannot change Memory" true
      (Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get = memory_before);
    check bool "inference cannot change the Memory receipt" true (receipt () = receipt_before);
    check bool "inference cannot move the durable cursor" true (progress () = progress_before));
  let registry = Registry.global () in
  let prior_runs = List.map (fun (run : Registry.run) -> run.run_id)
    (Registry.list_runs registry) in
  pass ();
  (match failure with
   | None -> ()
   | Some _ ->
     check (option int) "a later unread message discards partial state" None (coverage ());
     check int "the failed wake stops at that message" 3 (List.length !requests);
     pass ();
     check string "a new wake retries the identical first message without partial state"
       (List.nth !requests 1) (List.nth !requests 4));
  let expected_calls = match failure with None -> 3 | Some _ -> 6 in
  check int "one whole refusal and one request per message per wake"
    expected_calls (List.length !requests);
  let first = List.nth !requests 1 and second = List.nth !requests (expected_calls - 1) in
  let call = "[tool use omitted: id=" ^ tool_call_id 1
  and result = "[tool result omitted: id=" ^ tool_call_id 1 in
  check bool "first inference carries only the call" true (contains ~sub:call first);
  check bool "first inference excludes the unread result" false (contains ~sub:result first);
  check bool "second inference carries the tool result" true (contains ~sub:result second);
  check bool "second inference carries previous volatile state" true (contains ~sub:"remembered-call" second);
  check (option int) "only the complete atom is published" (Some 1) (coverage ());
  let snapshot = P.read ~config ~keeper_name |> get |> some in
  check string "the final state is published at the original atom boundary"
    "remembered-call-and-result" snapshot.working_state;
  check bool "successful continuity publication still leaves Memory unchanged" true
    (Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get = memory_before);
  check bool "successful continuity publication still leaves durable progress unchanged" true
    (progress () = progress_before);
  let volatile_runs = Registry.list_runs registry
    |> List.filter_map (fun (run : Registry.run) ->
      if List.mem run.run_id prior_runs then None else
      match Registry.get registry ~run_id:run.run_id with
      | Some ({status=Registry.Completed {output;_};_} as loaded)
        when U.member "volatile_inference" output = `Bool true -> Some loaded
      | Some _ | None -> None) in
  check int "every successful message has a recorded volatile outcome"
    (match failure with None -> 2 | Some _ -> 3) (List.length volatile_runs);
  List.iter (fun run ->
    let decoded = Masc.Tui_decode.decode_lane_run_detail
      (Exact_output_fixture.lane_run_detail run) |> get in
    let reading = decoded.lrd_librarian_preflight |> some in
    check bool "actual volatile run is readable as context-only" true (reading.lp_memory_scope = Masc.Tui_decode.Context_only_scope);
    check bool "actual volatile run cannot claim continuity publication" true
      (reading.lp_side_writes = [Masc.Tui_decode.Continuity_write, Masc.Tui_decode.Side_not_attempted]))
    volatile_runs

type context_hole_case =
  | Context_unknown_then_typed
  | Context_typed_then_unknown
  | Context_all_holes
  | Context_single_hole
  | Context_unknown_only
  | Context_cli_tail
  | Context_invalid_answer
  | Context_late_unknown
  | Context_rewritten_source
  | Context_appended_suffix
  | Context_prior_holes
  | Context_unreceived_only
  | Context_unreceived_413_only
  | Context_unreceived_then_typed
  | Context_typed_then_unreceived
  | Context_late_unreceived

type context_fixture_answer =
  | Context_typed_refusal
  | Context_unknown_refusal
  | Context_empty_refusal_body
  | Context_unreceived_refusal of Cohttp.Code.status_code
  | Context_invalid_json
  | Context_state of string

(* Exercise the actual Memory-covered Queue -> Runtime API walk. Context-only
   holes belong to the continuation, never the already committed Memory range.
   Two real API slots distinguish one typed witness from complete exhaustion. *)
let test_context_only_api_holes case () =
  let module Current = Masc.Keeper_memory_os_current in
  let module Unread = Masc.Keeper_librarian_unread in
  let module Progress = Masc.Keeper_librarian_progress in
  let prior = case=Context_prior_holes in
  let selected = if case=Context_single_hole then [message "single-original-message"]
    else List.take 2 (List.drop 1 tool_atoms) in
  let original = if prior then message "prior explicitly unread source" :: selected else selected in
  let typed = Context_typed_refusal and unknown = Context_unknown_refusal in
  let state = "The refused original remains explicitly unread." in
  let missing = Context_unreceived_refusal `Bad_request in
  let whole = match case with
    | Context_unreceived_only -> [missing;missing]
    | Context_unreceived_413_only ->
      [Context_unreceived_refusal `Request_entity_too_large;
       Context_unreceived_refusal `Request_entity_too_large]
    | Context_unknown_then_typed | Context_typed_then_unknown | Context_all_holes
    | Context_single_hole | Context_unknown_only | Context_cli_tail | Context_invalid_answer
    | Context_late_unknown | Context_rewritten_source | Context_appended_suffix
    | Context_prior_holes | Context_unreceived_then_typed | Context_typed_then_unreceived
    | Context_late_unreceived -> [typed;typed] in
  let decisions = match case with
    | Context_unknown_then_typed -> [unknown;typed;Context_state state]
    | Context_typed_then_unknown -> [typed;unknown;Context_state state]
    | Context_all_holes -> [typed;typed;typed;typed;Context_state state]
    | Context_single_hole -> [typed;typed;Context_state state]
    | Context_unknown_only -> [unknown;Context_empty_refusal_body]
    | Context_unreceived_only -> [missing;missing]
    | Context_unreceived_413_only ->
      [Context_unreceived_refusal `Request_entity_too_large;
       Context_unreceived_refusal `Request_entity_too_large]
    | Context_unreceived_then_typed -> [missing;typed;Context_state state]
    | Context_typed_then_unreceived -> [typed;missing;Context_state state]
    | Context_late_unreceived -> [typed;typed;missing;missing]
    | Context_cli_tail -> [typed;typed]
    | Context_invalid_answer -> [Context_invalid_json;typed]
    | Context_late_unknown -> [typed;typed;unknown;unknown]
    | Context_rewritten_source | Context_appended_suffix -> [typed;typed;Context_state state]
    | Context_prior_holes -> [typed;typed;typed;typed] in
  let plan = whole @ decisions in
  let requests = ref [] and cli_requests = ref [] in
  let module Http = Llm_provider.Http_request_observer in
  let http_events = ref [] in
  let observer = Http.create (fun event -> http_events := event :: !http_events; Ok ()) in
  let before_dispatch = ref (fun () -> ()) and before_final = ref (fun () -> ()) in
  let last_index = List.length plan-1 in
  let cli_runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt =
    check string "the declared real CLI tail is visited" Exact_output_fixture.cli_primary_runtime runtime_id;
    (!before_dispatch) ();
    cli_requests := !cli_requests @ [prompt];
    if List.length !cli_requests mod 2=1 then
      Error (queue_native_failure ~claude:false ~tool_effect:false)
    else Error (Masc.Fusion_official_client.Setup_failure "opaque context-only tail") in
  (* This is the actual configured provider-body deadline, not a test elapsed
     time assertion or a synthetic typed refusal. Both candidates use it so
     the fixture can reverse their receipt order without changing the lane. *)
  let body_timeouts = match case with
    | Context_unreceived_only | Context_unreceived_413_only
    | Context_unreceived_then_typed | Context_typed_then_unreceived | Context_late_unreceived ->
      ["narrowing-slot-0", 0.5; "narrowing-slot-1", 0.5]
    | Context_unknown_then_typed | Context_typed_then_unknown | Context_all_holes
    | Context_single_hole | Context_unknown_only | Context_cli_tail | Context_invalid_answer
    | Context_late_unknown | Context_rewritten_source | Context_appended_suffix
    | Context_prior_holes -> [] in
  narrowing_fixture ~atoms:original ~slot_count:2 ~has_waiting:(fun () -> true) ~body_timeouts
    ~cli_slot_ids:(if case=Context_cli_tail then [Exact_output_fixture.cli_primary_runtime] else [])
    ?cli_runner:(if case=Context_cli_tail then Some cli_runner else None)
    ~answer:(fun _ _ -> fail "receipt fixture must handle every context request")
    ~receipt_answer:(fun index body ->
      (!before_dispatch) ();
      let position = index mod List.length plan in
      requests := !requests @ [body];
      if position=last_index then (!before_final) ();
      match List.nth plan position with
      | Context_typed_refusal -> Exact_output_fixture.Complete_response
          (`Request_entity_too_large, refused "invalid_request_error")
      | Context_unknown_refusal -> Exact_output_fixture.Complete_response
          (`Bad_request, refused "invalid_request_error")
      | Context_empty_refusal_body -> Exact_output_fixture.Complete_response (`Bad_request, "")
      | Context_unreceived_refusal status -> Exact_output_fixture.Refusal_without_body status
      | Context_invalid_json -> Exact_output_fixture.Complete_response (`OK,
          {|{"choices":[{"index":0,"message":{"role":"assistant","content":"not JSON"},"finish_reason":"stop"}]}|})
      | Context_state working_state -> Exact_output_fixture.Complete_response
          (`OK, Exact_output_fixture.openai_response
            (`Assoc ["working_state",`String working_state])))
  @@ fun ~bodies:_ ~pass ~coverage:_ ~hide_source:_ ~restart:_ ~config ->
  let pass () =
    let previous_calls = List.length !requests in
    http_events := [];
    Http.with_observer observer pass;
    check int "the actual HTTP observer loses no receipt" 0 (Http.delivery_failure_count observer);
    let events = List.rev !http_events in
    let entered = List.filter_map (fun (event : Http.event) -> match event.phase with
      | Http.Client_entered {mode;body_bytes;body_sha256;_} ->
        check bool "the actual provider uses the synchronous body receipt path" true
          (match mode with Http.Synchronous -> true | Http.Streaming -> false);
        Some (event.call_id,body_bytes,body_sha256)
      | Http.Dispatch_entered | Http.Response_headers_received _ | Http.Client_finished _ -> None) events in
    let ids = List.map (fun (id,_,_) -> id) entered in
    check int "every physical HTTP call has its own observed identity"
      (List.length ids) (List.length (List.sort_uniq Int.compare ids));
    let current_requests = List.drop previous_calls !requests in
    check (list (pair int string)) "every observed HTTP call binds the exact body the server received"
      (List.map (fun body -> String.length body,Digestif.SHA256.(digest_string body |> to_hex)) current_requests)
      (List.map (fun (_,bytes,sha256) -> bytes,sha256) entered);
    let phases = List.map (fun (event : Http.event) -> event.call_id,
      (match event.phase with
       | Http.Client_entered _ -> "entered"
       | Http.Dispatch_entered -> "dispatched"
       | Http.Response_headers_received _ -> "headers"
       | Http.Client_finished _ -> "finished")) events in
    check (list (pair int string)) "each exact request receives its headers before client completion"
      (List.concat_map (fun id -> List.map (fun phase -> id,phase)
        ["entered";"dispatched";"headers";"finished"]) ids) phases;
    let headers = List.filter_map (fun (event : Http.event) -> match event.phase with
      | Http.Response_headers_received {status} -> Some (event.call_id,status)
      | Http.Client_entered _ | Http.Dispatch_entered | Http.Client_finished _ -> None) events in
    let expected_status = function
      | Context_typed_refusal -> 413
      | Context_unknown_refusal | Context_empty_refusal_body -> 400
      | Context_unreceived_refusal status -> Cohttp.Code.code_of_status status
      | Context_invalid_json | Context_state _ -> 200 in
    check (list (pair int int)) "every call receives its actual planned headers before the body window closes"
      (List.mapi (fun index id -> id,expected_status (List.nth plan (index mod List.length plan))) ids)
      headers;
    let finished = List.filter_map (fun (event : Http.event) -> match event.phase with
      | Http.Client_finished completion -> Some (event.call_id,
          (match completion with Http.Returned_ok -> true
           | Http.Returned_error | Http.Cancelled | Http.Raised -> false))
      | Http.Client_entered _ | Http.Dispatch_entered | Http.Response_headers_received _ -> None) events in
    check (list (pair int bool)) "refusals return HTTP receipts, never pre-header or transport timeouts"
      (List.map (fun id -> id,true) ids) finished
  in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Masc.Workspace.base_path in
  let runtime_keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  let boundaries () = B.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name |> get in
  let prior_holes = if not prior then [] else (
    let hole = Unread.for_atom ~trace_id ~history_start_boundary_line:1 ~atom:0 ~message_in_atom:0
      ~messages:original ~reasons:[Masc.Keeper_librarian_input_refusal.Input_capacity] |> get in
    let snapshot = S.capture_checkpoint_prefix ~unread_messages:[hole] ~end_atom:1
      ~catch_up_end_atom:None ~trace_id ~lines:(boundaries ()) ~messages:original
      ~working_state:"Previously saved continuation." ()
      |> Result.map_error S.error_to_string |> get in
    S.save ~path:(P.path ~config ~keeper_name) snapshot |> Result.map_error S.error_to_string |> get;
    [hole]) in
  record_memory config;
  let prepared = prepare config |> some in
  let sources = P.memory_sources prepared |> get in
  check int "the prepared manifest contains the exact selected messages" (List.length selected) (List.length sources);
  let hole source = P.unread_message prepared ~source
    ~reasons:[Masc.Keeper_librarian_input_refusal.Request_body_refused] |> get in
  let new_holes = match case with
    | Context_all_holes | Context_single_hole | Context_prior_holes -> List.map hole sources
    | Context_unknown_then_typed | Context_typed_then_unknown
    | Context_unreceived_then_typed | Context_typed_then_unreceived
    | Context_rewritten_source | Context_appended_suffix -> [hole (List.hd sources)]
    | Context_unknown_only | Context_cli_tail | Context_invalid_answer | Context_late_unknown
    | Context_unreceived_only | Context_unreceived_413_only | Context_late_unreceived -> [] in
  let expected_holes = Unread.merge prior_holes new_holes |> get in
  let memory_before = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get in
  let range = P.memory_range_id ~config ~keeper_name prepared |> get in
  let receipt () = Current.committed_durable_coverage ~keepers_dir ~keeper_id:keeper_name
      ~receipt_scope:range.receipt_scope |> get in
  let receipt_before = receipt () in
  let ledger () = Current.read_unread_messages ~keepers_dir ~keeper_id:keeper_name |> get in
  let ledger_before = ledger () in
  let progress () = Progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
    |> Result.map_error Progress.read_error_to_string |> get in
  let progress_before = progress () in
  let snapshot_before = P.read ~config ~keeper_name |> get in
  let check_memory () =
    check bool "Context-only inference and publication preserve the exact Memory snapshot" true
      (Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get=memory_before);
    check bool "Context-only cannot rewrite the existing Memory receipt" true (receipt ()=receipt_before);
    check bool "Context-only cannot create cumulative Memory unread evidence" true (ledger ()=ledger_before);
    check bool "Context-only cannot advance the durable cursor" true (progress ()=progress_before) in
  before_dispatch := (fun () ->
    check bool "neither inferred state nor a newly proven hole publishes a partial snapshot" true
      (P.read ~config ~keeper_name |> get=snapshot_before);
    check_memory ());
  let save messages =
    let session_dir=Filename.concat (Masc.Keeper_fs.session_store_path config) trace_id in
    match C.save_agent_core_classified ~session_dir ~history_retained:0 (checkpoint messages) with
    | Ok (C.Saved _) -> ()
    | Ok (C.Stale_noop _) -> fail "context source mutation fixture was stale"
    | Error detail -> fail detail in
  before_final := (fun () -> match case with
    | Context_rewritten_source ->
      let changed = List.mapi (fun index (message : Agent_core.Types.message) -> if index=List.length original-1 then
        {message with Agent_core.Types.content=List.map (function
          | Agent_core.Types.ToolResult result ->
            Agent_core.Types.ToolResult {result with content="rewritten original tool result"}
          | block -> block) message.content}
        else message) original in
      check bool "source rewrite leaves the atom-opening digest unchanged" true
        (Runtime_model_input_tail_window.atom_opening_digest changed 0=
         Runtime_model_input_tail_window.atom_opening_digest original 0);
      save changed
    | Context_appended_suffix ->
      let extended=original @ [message "later completed suffix"] in
      save extended;
      B.append ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
        {B.recorded_at=1001.;event=B.Turn_ended
          {turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:2;
           task_context=Masc.Keeper_turn_task_context.No_task;history_at_start=B.Continued_history;
           position=B.position_of_messages extended |> get}}
      |> Result.map_error B.append_error_to_string |> get
    | Context_unknown_then_typed | Context_typed_then_unknown | Context_all_holes
    | Context_single_hole | Context_unknown_only | Context_cli_tail | Context_invalid_answer
    | Context_late_unknown | Context_prior_holes | Context_unreceived_only
    | Context_unreceived_413_only | Context_unreceived_then_typed
    | Context_typed_then_unreceived | Context_late_unreceived -> ());
  pass ();
  check int "the whole request and each exhausted message visit every declared API candidate"
    (List.length plan) (List.length !requests);
  let model index=U.member "model" (Yojson.Safe.from_string (List.nth !requests index)) |> U.to_string in
  check bool "exhaustion visits two distinct real API models" true (model 0<>model 1);
  check (list string) "the exact first message visits those same two models before any skip"
    [model 0;model 1] [model 2;model 3];
  check_memory ();
  let committed = match case with
    | Context_unknown_only | Context_cli_tail | Context_invalid_answer | Context_late_unknown
    | Context_unreceived_only | Context_unreceived_413_only | Context_late_unreceived
    | Context_rewritten_source -> false
    | Context_unknown_then_typed | Context_typed_then_unknown | Context_all_holes
    | Context_unreceived_then_typed | Context_typed_then_unreceived
    | Context_single_hole | Context_appended_suffix | Context_prior_holes -> true in
  if not committed then (
    check bool "an unproven message or changed source preserves the entire original continuation" true
      (P.read ~config ~keeper_name |> get=snapshot_before);
    check bool "failed Context-only publication remains observably uncommitted" true
      ((Masc.Keeper_continuity_observation.latest_synthesis ~config ~keeper_name |> some).state=
       Masc.Keeper_continuity_observation.Not_committed);
    if case<>Context_rewritten_source then (
      pass ();
      check int "the next wake retries every original source instead of retaining a volatile hole"
        (2*List.length plan) (List.length !requests);
      check string "retry starts with the same exact first message and no partial state"
        (List.nth !requests 2) (List.nth !requests (List.length plan+2));
      check bool "a second refusal still publishes neither state nor unread records" true
        (P.read ~config ~keeper_name |> get=snapshot_before);
      check_memory ());
    if case=Context_cli_tail then check int "whole and single-message walks both really reach the CLI tail on each wake"
      4 (List.length !cli_requests))
  else (
    let saved=P.read ~config ~keeper_name |> get |> some in
    check int "publication stops at the complete original atom" (P.end_atom prepared) saved.end_atom;
    check bool "only exact exhausted API holes merge with previously saved holes" true
      (saved.unread_messages=expected_holes);
    check string "all-hole continuation preserves the prior state or uses a real empty-input answer"
      (if prior then "Previously saved continuation." else state) saved.working_state;
    let last=List.nth !requests last_index in
    if case=Context_all_holes || case=Context_single_hole then (
      List.iter (fun unread ->
        check bool "the final empty-source request carries every proven unread hash" true
          (contains ~sub:(match unread.Unread.source with
            | Unread.Atom source -> source.message_sha256
            | Unread.Official_turn source -> source.message_sha256) last)) expected_holes;
      check bool "an all-hole summary cannot pretend to read the original conversation" false
        (contains ~sub:("[tool use omitted: id=" ^ tool_call_id 1) last
         || contains ~sub:("[tool result omitted: id=" ^ tool_call_id 1) last
         || contains ~sub:"single-original-message" last));
    if case=Context_unknown_then_typed || case=Context_typed_then_unknown
        || case=Context_unreceived_then_typed || case=Context_typed_then_unreceived then (
      let messages index=U.member "messages" (Yojson.Safe.from_string (List.nth !requests index)) in
      check bool "both slots refused the identical one-message conversation" true (messages 2=messages 3);
      check bool "the next accepted message sees the exact preceding hole" true
        (contains ~sub:(Unread.message_digest (List.hd selected)) last));
    if case=Context_appended_suffix then (
      let next=prepare config |> some in
      check int "a concurrently completed suffix stays outside this publication" (P.end_atom prepared) (P.start_atom next);
      check int "the suffix remains available for the next signal" (P.end_atom prepared+1) (P.end_atom next))
    else (
      let calls=List.length !requests in
      pass ();
      check int "a quiet wake performs no request after complete accounted publication" calls (List.length !requests));
    check_memory ())

type memory_floor_case =
  | Complete_memory_floor
  | Late_memory_failure
  | Rewritten_memory_source
  | Appended_memory_suffix

(* Drive the production Queue -> Runtime CLI lane -> parsed/gated Memory
   inference path. One assistant/tool exchange is one indivisible atom,
   so a whole-request refusal must stage each exact message before publishing. *)
let test_uncommitted_memory_message_floor ?native case () =
  let module Current = Masc.Keeper_memory_os_current in
  let module Program = Masc.Keeper_memory_os_program in
  let module Progress = Masc.Keeper_librarian_progress in
  let module Unread = Masc.Keeper_librarian_unread in
  let module Queue = Masc.Keeper_librarian_queue_refresh in
  let claim = "Memory floor project Meridian waits for operator approval." in
  let source = match List.take 2 (List.drop 1 tool_atoms) with
    | [call; result] ->
      (* Leave room for the staged fact's real metadata in the next single-
         message prompt while the original atom exceeds the measured bound. *)
      [{call with Agent_core.Types.content=
          Agent_core.Types.Text (claim ^ "\n" ^ String.make 2048 'x') :: call.content}; result]
    | [] | [_] | _ :: _ :: _ -> fail "fixture must contain the assistant and its tool result" in
  check int "the two source messages form one indivisible atom" 1
    (snd (Runtime_model_input_tail_window.annotate source));
  let requests = ref [] and before_answer = ref (fun _ -> ()) in
  let fail_late = ref (case=Late_memory_failure) in
  let observed_limit = ref None in
  let stage_answer ~first = Yojson.Safe.to_string (`Assoc
    ["new_claims", (if first then `List [`Assoc
       ["claim", `String claim; "category", `String "fact";
        "board_post_id", `Null; "board_comment_id", `Null;
        "supersedes", `Null; "absorbs", `List []]] else `List []);
     "dropped", `List []; "working_contexts", `List [];
     "working_state", `String (if first then "volatile-call-read" else "complete-call-and-result")]) in
  let runner ~runtime_id ~system_prompt:_ ~output_schema ~prompt =
    let blocked = Option.fold ~none:false ~some:(fun mode -> not (queue_native_succeeds mode)) native in
    let native_answers = Option.fold ~none:[] ~some:(queue_native_answers ~prompt) native in
    let position = if blocked then List.length !requests mod List.length native_answers else List.length !requests mod 3 in
    check string "the actual CLI fallback serves every stage"
      (if blocked && position=1 then Exact_output_fixture.cli_secondary_runtime
       else Exact_output_fixture.cli_primary_runtime) runtime_id;
    check bool "each stage uses the Memory output contract" true
      (U.member "new_claims" (U.member "properties" output_schema) <> `Null);
    requests := !requests @ [prompt];
    if not blocked then (!before_answer) position;
    let actual_chars = Runtime_codex_app_server.prompt_char_count prompt |> get in
    (if Option.is_none native && position<>0 then
       check bool "each staged request fits the CLI's actual reported character bound" true
         (actual_chars <= Option.get !observed_limit));
    if blocked then List.nth native_answers position else match position,native with
    | 0,Some _ -> List.hd native_answers
    | 0,None ->
      (* This is the same measured CLI refusal boundary used by the existing
         Queue fitting fixture, rather than a native admission-only verdict. *)
      let max_chars = actual_chars-1 in
      observed_limit := Some max_chars;
      Error (Masc.Fusion_official_client.Codex_failure (Runtime_codex_app_server.Rpc_error
        {method_="turn/start";code=Some (-32602);message="fixture measured input capacity";
         data=Some (`Assoc ["input_error_code",`String "input_too_large";
           "actual_chars",`Int actual_chars;"max_chars",`Int max_chars])}))
    | 1,_ -> Ok (stage_answer ~first:true)
    | 2,_ when !fail_late -> Error (Masc.Fusion_official_client.Setup_failure
        "fixture unavailable after the first accepted Memory step")
    | 2,_ -> Ok (stage_answer ~first:false)
    | _ -> fail "unexpected message-floor phase" in
  let cli_slots = match native with
    | Some (Queue_json_before_native | Queue_native_before_domain | Queue_measured_before_json) ->
      [Exact_output_fixture.cli_primary_runtime;Exact_output_fixture.cli_secondary_runtime]
    | None | Some (Queue_codex_native | Queue_claude_native | Queue_effect_started | Queue_opaque_failure) ->
      [Exact_output_fixture.cli_primary_runtime] in
  narrowing_fixture ~atoms:source ~cli_slot_ids:cli_slots
    ~cli_runner:runner ~slot_count:0
    ~answer:(fun _ _ -> fail "a CLI-only fixture must not dispatch HTTP")
  @@ fun ~bodies:_ ~pass:_ ~coverage ~hide_source:_ ~restart:_ ~config ->
  let base_path = config.Masc.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let runtime_keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  let session_dir = Filename.concat (Masc.Keeper_fs.session_store_path config) trace_id in
  let prepared = prepare config |> some in
  check bool "the original atom has no Memory receipt" false
    (P.memory_committed ~config ~keeper_name prepared |> get);
  let expected_receipt = P.memory_range_id ~config ~keeper_name prepared |> get in
  let expected_sources = Unread.sources_for_atom_range ~trace_id
    ~history_start_boundary_line:expected_receipt.history_start_boundary_line
    ~start_atom:0 ~end_atom:1 ~messages:source |> get in
  let memory_before = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get |> some in
  let stores =
    [Current.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name;
     Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name;
     Current.publication_receipt_path ~keepers_dir ~keeper_id:keeper_name;
     Current.durable_range_receipt_path ~keepers_dir ~keeper_id:keeper_name;
     Current.unread_ledger_path ~keepers_dir ~keeper_id:keeper_name;
     Masc.Keeper_librarian_context.path ~keepers_dir ~keeper_id:keeper_name;
     Progress.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name;
     P.path ~config ~keeper_name] in
  let bytes () = List.map Fs_compat.load_file_opt stores in
  let before_steps = ref None in
  let save_source messages =
    match C.save_agent_core_classified ~session_dir ~history_retained:0 (checkpoint messages) with
    | Ok (C.Saved _) -> ()
    | Ok (C.Stale_noop _) -> fail "source mutation was not saved"
    | Error detail -> fail detail in
  before_answer := (fun position ->
    if position=1 then before_steps := Some (bytes ());
    if position<>0 then (
      check bool "no staged fact, journal, receipt, context or cursor is published" true
        (bytes () = Option.get !before_steps);
      check (option int) "no partial continuity frontier is visible" None (coverage ()));
    if position=2 then match case with
      | Rewritten_memory_source ->
        let changed = match source with
          | first :: rest -> {first with Agent_core.Types.content=
              Agent_core.Types.Text "A different completed source replaced the original." :: first.content} :: rest
          | [] -> fail "source was empty" in
        save_source changed
      | Appended_memory_suffix ->
        let extended = source @ [message "A newly completed suffix must remain unread."] in
        save_source extended;
        B.append ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
          {B.recorded_at=1001.; event=B.Turn_ended
            {turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:2;
             task_context=Masc.Keeper_turn_task_context.No_task;
             history_at_start=B.Continued_history;
             position=B.position_of_messages extended |> get}}
          |> Result.map_error B.append_error_to_string |> get
      | Complete_memory_floor | Late_memory_failure -> ());
  let pass () = Queue.For_testing.run_continuity ~cli_runner:runner
    ~has_waiting:(fun () -> true) ~base_path ~keeper_name () in
  pass ();
  let blocked = Option.fold ~none:false ~some:(fun mode -> not (queue_native_succeeds mode)) native in
  if blocked then (
    let visits_per_walk = List.length cli_slots in
    let assert_uncommitted () =
      check (option int) "a vetoed native walk publishes no continuation" None (coverage ());
      check bool "a vetoed native walk cannot publish Memory or unread authority" true
        ((Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get)=Some memory_before
         && (Current.read_unread_messages ~keepers_dir ~keeper_id:keeper_name |> get)=[]);
      check bool "a vetoed walk cannot install a measured prefit capacity for a later wake" true
        (Queue.For_testing.last_input_capacity ~config ~keeper_name=None);
      check bool "a vetoed walk cannot certify the original atom as committed" false
        (P.memory_committed ~config ~keeper_name prepared |> get) in
    check int "the first failed native walk visits each declared slot only once" visits_per_walk (List.length !requests);
    assert_uncommitted ();
    pass ();
    check int "the next wake retains the entire original input and visits the same walk" (2*visits_per_walk) (List.length !requests);
    List.iter (fun index -> check string "no cached prefit may bypass the veto on the next wake"
      (List.nth !requests index) (List.nth !requests (index+visits_per_walk))) (List.init visits_per_walk Fun.id);
    assert_uncommitted ())
  else (
  (match case with
   | Late_memory_failure ->
     check int "late opaque refusal stops after the exact second message" 3 (List.length !requests);
     check bool "late failure preserves every authoritative store byte" true
       (bytes () = Option.get !before_steps);
     check (option int) "late failure publishes no frontier or unread-hole authority" None (coverage ());
     fail_late := false;
     pass ();
     check string "a new wake restarts at the identical original first message"
       (List.nth !requests 1) (List.nth !requests 4)
   | Rewritten_memory_source ->
     check bool "a rewritten source prefix leaves every authoritative store byte unchanged" true
       (bytes () = Option.get !before_steps);
     check (option int) "a rewritten source prefix grants no coverage" None (coverage ())
   | Complete_memory_floor | Appended_memory_suffix -> ());
  let expected_calls = if case=Late_memory_failure then 6 else 3 in
  check int "one whole refusal and one real CLI inference for each message"
    expected_calls (List.length !requests);
  let first_prompt = List.nth !requests (expected_calls-2)
  and second_prompt = List.nth !requests (expected_calls-1) in
  let call_marker = "[tool use omitted: id=" ^ tool_call_id 1
  and result_marker = "[tool result omitted: id=" ^ tool_call_id 1 in
  check bool "first step carries only the assistant's call" true
    (contains ~sub:call_marker first_prompt && not (contains ~sub:result_marker first_prompt));
  check bool "second step carries only the tool result" true
    (contains ~sub:result_marker second_prompt && not (contains ~sub:call_marker second_prompt));
  check bool "second step receives the actual staged Memory claim" true (contains ~sub:claim second_prompt);
  check bool "second step receives the separate volatile continuation" true
    (contains ~sub:"volatile-call-read" second_prompt);
  List.iter (fun prompt ->
    check bool "neither tool argument nor raw tool-result payload is rendered" false
      (contains ~sub:tool_argument_marker prompt || contains ~sub:tool_result_marker prompt))
    [first_prompt;second_prompt];
  let publications = Current.read_journal_tail ~keepers_dir ~keeper_id:keeper_name ~limit:(List.length !requests+1)
    |> List.map get |> List.filter_map (function
      | Current.Journal_committed {program=Some proof;_} -> Some proof
      | Current.Journal_committed {program=None;_} | Current.Journal_failed _
      | Current.Journal_quarantined _ -> None) in
  match case, publications with
  | Rewritten_memory_source, [] -> ()
  | (Complete_memory_floor | Late_memory_failure | Appended_memory_suffix), [proof] ->
    let program = proof.Masc.Keeper_memory_os_program_types.execution.program in
    check bool "every original message coordinate and full-byte hash is accounted exactly once" true
      (program.Program.sources = expected_sources && program.unread=[]);
    (match program.stages, source, expected_sources with
     | [first; second], [call; result], [call_source; result_source] ->
       check bool "the ordered decisions partition the original atom" true
         (first.decision.sources=[call_source] && second.decision.sources=[result_source]);
       check bool "the next input uses the exact prior computed Memory" true
         (second.decision.input_current=Some first.after);
       List.iter (fun (stage, original, tools) ->
         let evidence = stage.Program.decision.input_evidence in
         check bool "proof preserves the complete original message bytes" true
           (U.member "messages" evidence=`List [Agent_core.Checkpoint.message_to_json original]);
         let variables = U.member "prompt_variables" evidence in
         check bool "the joined tool outcome is judged by the first accepted step only" true
           (U.member "turn_tool_observations" variables |> U.to_string |> Yojson.Safe.from_string = tools);
         let context = U.member "historical_task_contexts" variables |> U.to_string
           |> Yojson.Safe.from_string |> U.to_list |> List.hd in
         check int "message attribution resets to the one judged message" 0
           (U.member "first_message" context |> U.to_int);
         check int "message attribution covers exactly one message" 1
           (U.member "after_message" context |> U.to_int))
         [first,call,`List [`Assoc ["tool_name",`String tool_name;"outcome",`String "succeeded"]];
          second,result,`List []]
     | _ -> fail "the Memory publication lost its two real inference stages");
    let after = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get |> some in
    check int "the complete program publishes one Memory revision" (memory_before.revision+1) after.revision;
    check (list string) "only the accepted staged claim becomes current Memory" [claim]
      (List.map (fun (fact : Masc.Keeper_memory_os_types.fact) -> fact.claim) after.facts);
    let receipt = Current.committed_durable_range ~keepers_dir ~keeper_id:keeper_name
      ~receipt_scope:expected_receipt.receipt_scope |> get in
    check bool "one receipt certifies only the original indivisible atom" true
      (receipt=Some expected_receipt);
    let snapshot = P.read ~config ~keeper_name |> get |> some in
    check int "continuity publishes only the original atom" 1 snapshot.end_atom;
    check string "continuity publishes only the final state" "complete-call-and-result" snapshot.working_state;
    check bool "program publication does not advance the ordinary consumer cursor" true
      (Progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
       |> Result.map_error Progress.read_error_to_string |> get |> Option.is_none);
    check int "the durable consumer advances across the proved atom without another Memory call" 1
      (durable_reads config ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
        fail "the durable consumer sent an atom already covered by the real Memory program"));
    (match case with
     | Appended_memory_suffix ->
       let remaining = prepare config |> some in
       check int "a concurrent suffix remains outside the committed prefix" 1 (P.start_atom remaining);
       check int "the next source still includes the newly completed suffix" 2 (P.end_atom remaining)
     | Complete_memory_floor | Late_memory_failure | Rewritten_memory_source -> ())
  | _, _ -> fail "unexpected number of canonical Memory program publications")

(* Only a completely exhausted real API walk grants unread-hole authority.
   The Queue still judges the next exact message and publishes the original
   atom once, retaining the skipped message's full source identity. *)
let test_queue_memory_floor_retains_proven_api_holes ~all_refused () =
  let module Current = Masc.Keeper_memory_os_current in
  let module Unread = Masc.Keeper_librarian_unread in
  let module Program = Masc.Keeper_memory_os_program in
  let source = List.take 2 (List.drop 1 tool_atoms) in
  let requests = ref [] in
  let accepted_at = if all_refused then 3 else 2 in
  narrowing_fixture ~atoms:source ~slot_count:1
    ~answer:(fun index body ->
      requests := !requests @ [body];
      if index < accepted_at then
        `Request_entity_too_large, refused "invalid_request_error"
      else if index=accepted_at then
        `OK, Exact_output_fixture.openai_response
          (`Assoc ["new_claims",`List [];"dropped",`List [];"working_contexts",`List [];
                   "working_state",`String "Original refused messages remain explicitly unread."])
      else if index=accepted_at+1 then
        `OK, Exact_output_fixture.openai_response
          (`Assoc ["working_state",`String "Original refused messages remain explicitly unread."])
      else fail "unexpected API visit after the atom was accounted")
  @@ fun ~bodies:_ ~pass ~coverage ~hide_source:_ ~restart:_ ~config ->
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Masc.Workspace.base_path in
  let prepared = prepare config |> some in
  let original_receipt = P.memory_range_id ~config ~keeper_name prepared |> get in
  let sources = P.memory_sources prepared |> get in
  let hole position = Unread.for_atom ~trace_id
    ~history_start_boundary_line:original_receipt.history_start_boundary_line
    ~atom:0 ~message_in_atom:position ~messages:source
    ~reasons:[Masc.Keeper_librarian_input_refusal.Request_body_refused] |> get in
  let holes = if all_refused then [hole 0;hole 1] else [hole 0] in
  pass ();
  check int "each source is attempted before one real Memory judgment completes the atom"
    (accepted_at+1) (List.length !requests);
  check (option int) "the original complete atom is accounted" (Some 1) (coverage ());
  let expected_receipt = {original_receipt with Current.unread_messages=holes} in
  check bool "the receipt retains exactly the proven original unread message" true
    (Current.committed_durable_coverage ~keepers_dir ~keeper_id:keeper_name
       ~receipt_scope:original_receipt.receipt_scope |> get = Some expected_receipt);
  check bool "accounted coverage never claims the entire atom was read" true
    (Current.committed_durable_range ~keepers_dir ~keeper_id:keeper_name
       ~receipt_scope:original_receipt.receipt_scope |> get = None);
  check bool "the cumulative ledger keeps that same source hash and named refusal" true
    (Current.committed_unread_messages ~keepers_dir ~keeper_id:keeper_name |> get = holes);
  let snapshot = P.read ~config ~keeper_name |> get |> some in
  check bool "the working-state snapshot cannot erase the skipped source" true
    (snapshot.unread_messages=holes);
  let publications = Current.read_journal_tail ~keepers_dir ~keeper_id:keeper_name
      ~limit:(List.length !requests+1)
    |> List.map get |> List.filter_map (function
      | Current.Journal_committed {program=Some proof;_} -> Some proof
      | Current.Journal_committed {program=None;_} | Current.Journal_failed _
      | Current.Journal_quarantined _ -> None) in
  (match publications, sources, source with
   | [proof], [_call_source;result_source], [_call;result] ->
     let program = proof.Masc.Keeper_memory_os_program_types.execution.program in
     check bool "the original ordered manifest partitions into exactly accepted sources and proven holes" true
       (program.Program.sources=sources && program.unread=holes);
     (match program.stages with
      | [stage] ->
        check bool "only actually judged source messages receive a decision" true
          (stage.decision.sources=(if all_refused then [] else [result_source]));
        check bool "accepted evidence distinguishes a result read from host-only judgment" true
          (U.member "messages" stage.decision.input_evidence=
           `List (if all_refused then [] else [Agent_core.Checkpoint.message_to_json result]));
        (if all_refused then
           check bool "an all-hole program still contains an actual host-observation judgment" true
             (U.member "observations" stage.decision.input_evidence <> `List []));
        let variables = U.member "prompt_variables" stage.decision.input_evidence in
        check bool "skipping a message does not discard the joined host tool outcome" true
          (U.member "turn_tool_observations" variables |> U.to_string |> Yojson.Safe.from_string =
           `List [`Assoc ["tool_name",`String tool_name;"outcome",`String "succeeded"]]);
        check bool "the accepted step is explicitly told about the earlier unread message" true
          (contains ~sub:(Unread.message_digest (List.hd source))
             (U.member "continuity" variables |> U.to_string))
      | [] | _ :: _ :: _ -> fail "a refused message was turned into a successful Memory stage")
   | _ -> fail "missing original-boundary Memory program proof");
  (* Recover a Memory commit whose continuation needs regeneration. The
     Context-only request must carry the hole as evidence, not reread it as
     a conversation message or silently declare it processed. *)
  let memory = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get in
  Sys.remove (P.path ~config ~keeper_name);
  pass ();
  check int "recovery makes exactly one Context-only request" (accepted_at+2) (List.length !requests);
  let recovered_request = List.nth !requests (accepted_at+1) in
  check bool "recovery excludes the unread tool call from conversation" false
    (contains ~sub:("[tool use omitted: id=" ^ tool_call_id 1) recovered_request);
  check bool "recovery retains a tool result only when its source was actually read" (not all_refused)
    (contains ~sub:("[tool result omitted: id=" ^ tool_call_id 1) recovered_request);
  check bool "recovery keeps the original hole hash visible" true
    (contains ~sub:(Unread.message_digest (List.hd source)) recovered_request);
  check bool "Context-only recovery does not reapply Memory" true
    (Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name |> get = memory);
  check bool "Context-only regeneration retains exactly the same hole" true
    ((P.read ~config ~keeper_name |> get |> some).unread_messages=holes);
  check int "durable recovery advances without sending either accounted source again" 1
    (durable_reads config ~commit:(fun ~expected_revision:_ ~range_id:_ ~official_range_id:_ _ ->
      fail "durable recovery duplicated the Memory program's accounted atom"));
  check bool "advancing the consumer cannot erase unread evidence" true
    (Current.committed_unread_messages ~keepers_dir ~keeper_id:keeper_name |> get = holes)

let check_folded_tool_request body =
  check int "no tool call argument reaches the request" 0
    (occurrences ~sub:tool_argument_marker body);
  check int "no tool result body reaches the request" 0
    (occurrences ~sub:tool_result_marker body);
  List.iter (fun index ->
    check int (Printf.sprintf "user message %d travels once" index) 1
      (occurrences ~sub:(tool_atom_opening index) body))
    tool_atom_indices;
  (* The folded lines are the host's own markers (Keeper_librarian
     text_of_content): the call line names the tool, and the result line with
     the same id states the outcome. *)
  List.iter (fun index ->
    let id = tool_call_id index in
    check int (Printf.sprintf "call %s keeps its tool name" id) 1
      (occurrences ~sub:(Printf.sprintf "[tool use omitted: id=%s name=%s]" id tool_name) body);
    check int (Printf.sprintf "result %s keeps its outcome" id) 1
      (occurrences
         ~sub:(Printf.sprintf "[tool result omitted: id=%s is_error=%b]" id (tool_call_fails index))
         body))
    tool_atom_indices

let historical_request body =
  let rec strings = function
    | `String text -> [text]
    | `List values -> List.concat_map strings values
    | `Assoc values -> List.concat_map (fun (_, value) -> strings value) values
    | _ -> [] in
  let lines = strings (Yojson.Safe.from_string body)
    |> List.concat_map (String.split_on_char '\n') in
  match List.find_opt (String.starts_with ~prefix:"[{\"source\":") lines with
  | Some line -> Yojson.Safe.from_string line |> U.to_list
  | None -> fail "actual request lacks historical context binding"

let test_a_continuity_pass_carries_tool_turns_folded_once () =
  let task_context = Masc.Keeper_turn_task_context.Task
    {task_id=Keeper_id.Task_id.of_string "task-historical" |> get; goals=Ok []} in
  let run ~memory_committed ~answer =
    let requests = ref [] in
    narrowing_fixture ~task_context ~atoms:tool_atoms ~slot_count:1
      ~answer:(fun _index body ->
        requests := !requests @ [ body ];
        `OK, Exact_output_fixture.openai_response answer)
    @@ fun ~bodies:_ ~pass ~coverage ~hide_source:_ ~restart:_ ~config ->
    if memory_committed then record_memory config;
    pass ();
    check int "one request" 1 (List.length !requests);
    check_folded_tool_request (List.hd !requests);
    let context = match historical_request (List.hd !requests) with
      | [context] -> context | _ -> fail "expected one historical turn" in
    check string "both modes carry historical Task" "task-historical"
      (context |> U.member "attribution" |> U.member "task_context" |> U.member "task_id" |> U.to_string);
    check int "message offsets start at selected first message" 0
      (context |> U.member "first_message" |> U.to_int);
    check int "message offsets cover exactly sent messages" (List.length tool_atoms)
      (context |> U.member "after_message" |> U.to_int);
    check int "tool offsets match actual mode observation array"
      (if memory_committed then 0 else List.length tool_atom_indices)
      (context |> U.member "after_tool_observation" |> U.to_int);
    (* The user message and the assistant's call each open an atom; the tool
       result joins the call's atom. *)
    check (option int) "the folded range commits"
      (Some (2 * List.length tool_atom_indices)) (coverage ())
  in
  run ~memory_committed:false
    ~answer:(Yojson.Safe.from_string
               {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":"s"}|});
  run ~memory_committed:true ~answer:(`Assoc [ "working_state", `String "s" ])

let selected_source_width body =
  let context = match historical_request body with
    | [context] -> context | _ -> fail "expected one selected source span" in
  let source = U.member "source" context in
  (source |> U.member "end_atom" |> U.to_int)
  - (source |> U.member "start_atom" |> U.to_int)

let test_refused_width_carries_to_the_next_pass () =
  let requested_widths = ref [] in
  narrowing_fixture ~slot_count:1
    ~answer:(fun _index body ->
      let context = match historical_request body with
        | [context] -> context | _ -> fail "narrowed request should have one source span" in
      let source = U.member "source" context in
      let width = (source |> U.member "end_atom" |> U.to_int)
        - (source |> U.member "start_atom" |> U.to_int) in
      check int "every retry restarts selected message numbering" 0
        (context |> U.member "first_message" |> U.to_int);
      check int "every retry clips offsets to selected atoms" width
        (context |> U.member "after_message" |> U.to_int);
      check int "message-only retry has no tool offsets" 0
        (context |> U.member "after_tool_observation" |> U.to_int);
      requested_widths := !requested_widths @ [width];
      if selected_source_width body > fixture_atom_capacity
      then `Request_entity_too_large, refused "invalid_request_error"
      else `OK, accepted_answer)
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart:_ ~config ->
  let width () =
    Masc.Keeper_librarian_queue_refresh.For_testing.limited_width ~config ~keeper_name ~trace_id in
  pass ();
  check (option int) "a refused source commits nothing" None (coverage ());
  check bool "the refusal left a width" true (Option.is_some (width ()));
  check int "the refused pass sends one request and does not retry in place" 1
    (List.length !bodies);
  check bool "the first request carried the whole source" true
    (List.hd !requested_widths > fixture_atom_capacity);
  pass ();
  (* Without the carried width this pass prepares the whole source again and
     is refused again, exactly as the live keeper was ninety-six times. *)
  check int "the second pass sends one request as well" 2 (List.length !bodies);
  check bool "and it is smaller than the first" true
    (List.nth !bodies 1 < List.nth !bodies 0);
  check (option int) "still over the ceiling, so still nothing commits" None (coverage ());
  pass ();
  check (list int) "actual HTTP requests carry persisted widths 8, 4, then 2"
    [narrowing_atom_count; narrowing_atom_count / 2; fixture_atom_capacity]
    (List.take 3 !requested_widths);
  check (option int) "reading less commits, and the rest follows in the same pass"
    (Some narrowing_atom_count) (coverage ());
  check (option int) "reading the backlog to its end releases the width" None (width ());
  (* Every request after the first commit stayed at the width. A pass that
     released the width on a commit would have offered the six remaining
     atoms, which the target refuses. *)
  check bool "a commit does not release the width" true
    (List.for_all (fun width -> width <= fixture_atom_capacity)
       (List.filteri (fun index _ -> index >= 2) !requested_widths))

(* RFC-0467: after a committed round, a unit waiting on the lane ends the
   loop so its durable pass reads the turns that ended meanwhile. The next
   unit resumes continuity at the same position and width. Without a waiting
   unit the same refusals end with the whole backlog read in one pass, as in
   the case above. *)
let test_a_waiting_unit_ends_the_catch_up_after_a_commit () =
  let requested_widths = ref [] in
  narrowing_fixture ~slot_count:1
    ~answer:(fun _index body ->
      requested_widths := !requested_widths @ [selected_source_width body];
      if selected_source_width body > fixture_atom_capacity
      then `Request_entity_too_large, refused "invalid_request_error"
      else `OK, accepted_answer)
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart:_ ~config ->
  let base_path = config.Masc.Workspace.base_path in
  let pass_with_waiting_unit () =
    Masc.Keeper_librarian_queue_refresh.For_testing.run_continuity
      ~has_waiting:(fun () -> true) ~base_path ~keeper_name () in
  pass_with_waiting_unit ();
  pass_with_waiting_unit ();
  check (option int) "refused rounds commit nothing" None (coverage ());
  let refused_requests = List.length !bodies in
  pass_with_waiting_unit ();
  check int "a waiting unit stops the loop after the first committed round"
    (refused_requests + 1) (List.length !bodies);
  check (list int) "waiting-unit requests retain the same 8-to-4-to-2 protocol"
    [narrowing_atom_count; narrowing_atom_count / 2; fixture_atom_capacity]
    !requested_widths;
  (* Two refusals halve eight atoms to a width of two; the one committed
     round reads exactly that width. *)
  check (option int) "that round committed one width of the backlog" (Some 2)
    (coverage ());
  pass ();
  check (option int) "the next unit resumes and reads the rest"
    (Some narrowing_atom_count) (coverage ());
  check bool "the resumed unit keeps the narrowed width" true
    (List.for_all (fun width -> width <= fixture_atom_capacity)
       (List.filteri (fun index _ -> index >= refused_requests) !requested_widths))

let test_a_refusal_that_is_not_about_size_keeps_the_width () =
  narrowing_fixture ~slot_count:1
    ~answer:(fun _index _body -> `Too_many_requests, refused "rate_limit_error")
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart:_ ~config:_ ->
  pass ();
  pass ();
  check int "each pass sends one request" 2 (List.length !bodies);
  check bool "a quota refusal leaves the source the size it was" true
    (List.nth !bodies 0 = List.nth !bodies 1);
  check (option int) "nothing is committed" None (coverage ())

let test_an_unreadable_source_keeps_the_width () =
  narrowing_fixture ~slot_count:1
    ~answer:(fun _index body ->
      if selected_source_width body > fixture_atom_capacity
      then `Request_entity_too_large, refused "invalid_request_error"
      else `OK, accepted_answer)
  @@ fun ~bodies ~pass ~coverage ~hide_source ~restart:_ ~config:_ ->
  pass ();
  check (option int) "the first pass is refused and commits nothing" None (coverage ());
  (* prepare answers with no source both for a backlog read to its end and for
     a checkpoint it cannot read. Releasing the width on the second would send
     the pass after it back at the whole backlog, which is the loop this
     fixes. *)
  hide_source (fun () -> pass ());
  check int "a source it cannot read sends no request" 1 (List.length !bodies);
  pass ();
  check bool "the width survived the unreadable pass" true
    (List.nth !bodies 1 < List.nth !bodies 0);
  pass ();
  check (option int) "and the source is read to its end" (Some narrowing_atom_count) (coverage ())

(* RFC-librarian-lifecycle §4.3 keeps the limit in the loop's memory and
   accepts that a restart reads everything again. Pinned so that making the
   width durable is a decision someone takes, not a side effect. *)
let test_a_restart_forgets_the_width () =
  narrowing_fixture ~slot_count:1
    ~answer:(fun _index body ->
      if selected_source_width body > fixture_atom_capacity
      then `Request_entity_too_large, refused "invalid_request_error"
      else `OK, accepted_answer)
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart ~config ->
  let width () =
    Masc.Keeper_librarian_queue_refresh.For_testing.limited_width ~config ~keeper_name ~trace_id in
  pass ();
  check bool "the refusal left a width" true (Option.is_some (width ()));
  restart ();
  check (option int) "a restart forgets it" None (width ());
  pass ();
  check int "each pass sends one request" 2 (List.length !bodies);
  check bool "after a restart the pass offers the whole backlog again" true
    (List.nth !bodies 1 = List.nth !bodies 0);
  check (option int) "and is refused again" None (coverage ())

(* A continuity answer that leaves out the working state never reaches
   publication: validate_selection refuses it as Domain_output_invalid, and
   invalid output does not establish that the input exceeded capacity. *)
let answer_without_state =
  Exact_output_fixture.openai_response
    (Yojson.Safe.from_string
       {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":null}|})

let test_an_answer_without_a_working_state_keeps_width () =
  narrowing_fixture ~slot_count:1
    ~answer:(fun _index _body -> `OK, answer_without_state)
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart:_ ~config:_ ->
  pass ();
  pass ();
  check bool "an invalid domain answer preserves the request width" true
    (List.nth !bodies 1 = List.nth !bodies 0);
  check (option int) "and commits no continuity" None (coverage ())

(* The answer validated and only the snapshot failed to land. That is not the
   range's size, so the width stands. *)
let test_a_snapshot_that_fails_to_commit_keeps_the_width () =
  let break_the_commit = ref (fun () -> ()) in
  narrowing_fixture ~slot_count:1
    ~answer:(fun index _body ->
      if index = 0
      then `Request_entity_too_large, refused "invalid_request_error"
      else (!break_the_commit (); `OK, accepted_answer))
  @@ fun ~bodies:_ ~pass ~coverage:_ ~hide_source:_ ~restart:_ ~config ->
  let width () =
    Masc.Keeper_librarian_queue_refresh.For_testing.limited_width ~config ~keeper_name ~trace_id in
  (* While the model is answering, put a directory where the snapshot is about
     to be written, so the commit fails on disk after a good answer. It fails
     in the same branch a CAS the history moved under does. Coverage is not
     read afterwards: the snapshot path is no longer a file. *)
  break_the_commit := (fun () -> Fs_compat.mkdir_p (P.path ~config ~keeper_name));
  pass ();
  let refused = width () in
  check bool "the size refusal left a width" true (Option.is_some refused);
  pass ();
  check (option int) "a snapshot that failed to commit leaves it where it was" refused (width ())

let test_a_size_refusal_anywhere_in_the_walk_narrows () =
  narrowing_fixture ~slot_count:2
    ~answer:(fun index _body ->
      (* The walk meets the size refusal first and ends on a quota refusal.
         The verdict has to come from the whole walk: reading only the last
         cause answered this the other way, and answered the reverse order
         differently again. *)
      if index = 0
      then `Request_entity_too_large, refused "invalid_request_error"
      else `Too_many_requests, refused "rate_limit_error")
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart:_ ~config:_ ->
  pass ();
  check int "the walk tried both slots" 2 (List.length !bodies);
  pass ();
  check bool "a walk holding one size refusal still reads less next time" true
    (List.nth !bodies 2 < List.nth !bodies 0);
  check (option int) "a walk of refusals commits nothing" None (coverage ())

(* An invalid domain answer and a quota refusal, in either order, do not
   establish that a smaller source range would produce a valid answer. *)
let walk_of_two ~first ~second =
  narrowing_fixture ~slot_count:2
    ~answer:(fun index _body -> if index mod 2 = 0 then first () else second ())
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart:_ ~config:_ ->
  pass ();
  check int "the walk tried both slots" 2 (List.length !bodies);
  pass ();
  check bool "invalid output veto preserves width across both slot orders" true
    (List.nth !bodies 2 = List.nth !bodies 0);
  check (option int) "and nothing is committed" None (coverage ())

let quota () = `Too_many_requests, refused "rate_limit_error"

(* A CLI's reported limit is a fact about the CLI transport. Once an API slot
   commits a range, the limit no longer fits the passes that follow: the next
   request carries every unread atom, the way it did before any CLI refused.
   Before this, one CLI refusal cut every later pass to CLI size for the life
   of the process, even while the API slot took whole ranges. *)
let test_an_api_commit_releases_the_cli_limit () =
  let module F = Exact_output_fixture in
  let module Codex = Runtime_codex_app_server in
  let api_up = ref false and cli_calls = ref 0 in
  let cli_runner ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt =
    incr cli_calls;
    match !cli_calls with
    | 1 ->
      (* The whole backlog is too large for the CLI; a third of its size
         holds one or two atoms, so the rest of the backlog after one fitted
         unit is more than one fitted unit again. *)
      let actual_chars = Codex.prompt_char_count prompt |> get in
      Error (Masc.Fusion_official_client.Codex_failure (Codex.Rpc_error
        {method_="turn/start";code=Some (-32602);message="fixture capacity";
         data=Some (`Assoc ["input_error_code", `String "input_too_large";
           "actual_chars", `Int actual_chars; "max_chars", `Int (actual_chars / 3)])}))
    | 2 ->
      Ok {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":"s"}|}
    | _ ->
      Error (Masc.Fusion_official_client.Setup_failure "fixture unavailable")
  in
  narrowing_fixture ~cli_slot_ids:[ F.cli_primary_runtime ] ~cli_runner ~slot_count:1
    ~answer:(fun _index _body -> if !api_up then `OK, accepted_answer else quota ())
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart:_ ~config ->
  let capacity () =
    Masc.Keeper_librarian_queue_refresh.For_testing.last_input_capacity ~config ~keeper_name in
  pass ();
  let cli_end = match coverage () with
    | Some end_atom -> end_atom
    | None -> fail "the fitted CLI answer committed nothing" in
  check bool "the CLI committed a fitted part of the backlog" true
    (cli_end > 0 && cli_end < narrowing_atom_count);
  check bool "a CLI commit keeps the limit it answered inside" true
    (Option.is_some (capacity ()));
  let before_api = List.length !bodies in
  api_up := true;
  pass ();
  check (option int) "the API slot reads the rest of the backlog"
    (Some narrowing_atom_count) (coverage ());
  check bool "an API commit forgets the CLI limit" true (Option.is_none (capacity ()));
  let api_requests = List.filteri (fun index _ -> index >= before_api) !bodies in
  (* Still fitted to the CLI limit, the rest would take more than one request
     after the first. *)
  check int "the kept limit fits the first request, and one more reads the rest" 2
    (List.length api_requests);
  check int "the CLI is not asked again" 3 !cli_calls
let no_state () = `OK, answer_without_state

let test_a_refused_answer_then_a_quota_keeps_width () =
  walk_of_two ~first:no_state ~second:quota

let test_a_quota_then_a_refused_answer_keeps_width () =
  walk_of_two ~first:quota ~second:no_state

let test_reports_in_one_pass_keep_any_size_verdict () =
  let module R = Masc.Keeper_librarian_runtime in
  let merge = Masc.Keeper_librarian_queue_refresh.For_testing.merge_not_committed in
  let report ?(same = false) detail walk_shows_size =
    { R.detail; walk_shows_size; smaller_range_meets_same_failure = same;
      message_descent=(if walk_shows_size then R.Smaller_input_may_help else R.No_descent_evidence);
      input_capacity_evidence = R.No_input_capacity_refusal; provider_input_refusals = [] } in
  List.iter
    (fun (name, earlier, (latest : R.not_committed), expected) ->
       let merged = merge earlier latest in
       check bool name expected merged.R.walk_shows_size;
       check string (name ^ ": the latest detail is logged") latest.R.detail merged.R.detail)
    [ "one report", None, report "walk" true, true
    ; "size, then a raise", Some (report "walk" true), report "raise" false, true
    ; "a raise, then size", Some (report "raise" false), report "walk" true, true
    ; "no size in either", Some (report "walk" false), report "raise" false, false
    ];
  (* The recursive splitter's veto is evidence too: it stands across reports. *)
  let merged = merge (Some (report ~same:true "walk" true)) (report "raise" false) in
  check bool "a quota seen by the walk survives a later raise" true
    merged.R.smaller_range_meets_same_failure;
  check bool "no report saw one" false
    (merge (Some (report "walk" true)) (report "raise" false)).R.smaller_range_meets_same_failure;
  let module I = Masc.Keeper_librarian_input_refusal in
  let named causes = { (report "walk" true) with
    R.provider_input_refusals = causes } in
  let first = named [I.Request_body_refused; I.Context_overflow] in
  let second = named [I.Input_capacity; I.Request_body_refused] in
  let causes earlier latest = List.map I.to_string
    (merge (Some earlier) latest).R.provider_input_refusals in
  check (list string) "named causes survive a later report without evidence"
    ["context_overflow";"request_body_refused"] (causes first (report "raise" false));
  check (list string) "every named cause survives slot order and deduplicates"
    ["context_overflow";"input_capacity";"request_body_refused"] (causes first second);
  check (list string) "reversing reports preserves the same named causes"
    (causes first second) (causes second first)

let test_append_preserves_unread_source_records () = with_source @@ fun _env config save _append boundary ->
  let prefix = [message "Unread request";message "Read answer"] in
  save prefix;boundary ~fresh:true 1 prefix;
  let hole = Masc.Keeper_librarian_unread.for_atom ~trace_id ~history_start_boundary_line:1
    ~atom:0 ~message_in_atom:0 ~messages:prefix
    ~reasons:[Masc.Keeper_librarian_input_refusal.Context_overflow] |> get in
  let snapshot = S.capture ~unread_messages:[hole] ~trace_id
    ~lines:(B.read ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name |> get)
    ~messages:prefix ~working_state:"An exact request was unread." |> Result.map_error S.error_to_string |> get in
  S.save ~path:(P.path ~config ~keeper_name) snapshot |> Result.map_error S.error_to_string |> get;
  let messages = prefix @ [message "Later task update"] in
  save messages;boundary ~fresh:false 2 messages;
  let prepared = prepare config |> some in
  check bool "valid prior holes feed the next inference" true (P.previous_unread_messages prepared = [hole]);
  check bool "prompt never presents the prior prefix as wholly read" true
    (U.member "unread_messages" (P.prompt_json prepared) = Masc.Keeper_librarian_unread.list_to_json [hole]);
  let next = commit config prepared "The request remains unread; a later task update was read." in
  check bool "a later atom commit cannot forget previous holes" true (next.unread_messages = [hole]);
  check int "only complete atom coverage advances" 3 next.end_atom

let () = run "production continuity pair"
  ["cycle",[test_case "frozen prefix keeps publication checks" `Quick
      test_prefix_selection_keeps_frozen_source_and_publication_checks;
    test_case "append preserves exact unread records" `Quick test_append_preserves_unread_source_records;
    test_case "completed turns are work units" `Quick test_completed_turn_work_units;
    test_case "a rewrite from atom 0 follows its target" `Quick test_rewrite_from_zero_follows_its_target;
    test_case "the rewrite target is the Librarian's position" `Quick test_rewrite_target_is_the_librarian_position;
    test_case "an undecodable snapshot is rebuilt" `Quick test_an_undecodable_snapshot_is_rebuilt;
    test_case "an unreadable snapshot stays an error" `Quick test_an_unreadable_snapshot_stays_an_error;
    test_case "a rebuild does not overwrite a valid snapshot" `Quick test_a_rebuild_does_not_overwrite_a_valid_snapshot;
    test_case "historical sources survive narrowing and recovery" `Quick test_historical_sources_survive_narrowing_and_recovery;
    test_case "historical gap is not the covering Task" `Quick test_historical_gap_is_not_covering_task;
    test_case "pending receipt overrides next turn" `Quick test_recovery_overrides_next_turn;
    test_case "queue keeps capacity and alternative opportunity" `Quick test_queue_reuses_capacity_without_gating_alternatives;
    test_case "a refused width carries to the next pass" `Quick test_refused_width_carries_to_the_next_pass;
    test_case "a waiting unit ends the catch-up after a commit" `Quick
      test_a_waiting_unit_ends_the_catch_up_after_a_commit;
    test_case "a Memory pass carries the counterparts of its turn" `Quick
      test_a_memory_pass_carries_the_counterparts_of_its_turn;
    test_case "a turn too large with its counterparts is left to the durable pass" `Quick
      test_a_turn_too_large_with_its_counterparts_is_left_to_the_durable_pass;
    test_case "a committed range asks for the working state alone" `Quick
      test_a_committed_range_asks_for_the_working_state_alone;
    test_case "message floor publishes only after the complete atom" `Quick
      (test_volatile_message_floor ~failure:None);
    test_case "unknown message refusal discards partial state and retries source" `Quick
      (test_volatile_message_floor ~failure:(Some `Bad_request));
    test_case "Context-only exhausted API unknown then typed records one exact hole" `Quick
      (test_context_only_api_holes Context_unknown_then_typed);
    test_case "Context-only exhausted API typed then unknown records one exact hole" `Quick
      (test_context_only_api_holes Context_typed_then_unknown);
    test_case "Context-only all holes need a real empty-input continuation when no state exists" `Quick
      (test_context_only_api_holes Context_all_holes);
    test_case "Context-only one original message may become a proven hole" `Quick
      (test_context_only_api_holes Context_single_hole);
    test_case "Context-only unknown-only exhaustion preserves source across wakes" `Quick
      (test_context_only_api_holes Context_unknown_only);
    test_case "Context-only unread refusal bodies descend but never skip across wakes" `Quick
      (test_context_only_api_holes Context_unreceived_only);
    test_case "Context-only unread HTTP 413 bodies grant no named cause across wakes" `Quick
      (test_context_only_api_holes Context_unreceived_413_only);
    test_case "Context-only unread body then typed refusal records one exact hole" `Quick
      (test_context_only_api_holes Context_unreceived_then_typed);
    test_case "Context-only typed refusal then unread body records one exact hole" `Quick
      (test_context_only_api_holes Context_typed_then_unreceived);
    test_case "Context-only late unread refusal bodies discard the volatile hole" `Quick
      (test_context_only_api_holes Context_late_unreceived);
    test_case "Context-only API exhaustion followed by an opaque CLI tail grants no skip" `Quick
      (test_context_only_api_holes Context_cli_tail);
    test_case "Context-only invalid JSON vetoes a later typed refusal" `Quick
      (test_context_only_api_holes Context_invalid_answer);
    test_case "Context-only late unknown refusal discards a volatile proven hole" `Quick
      (test_context_only_api_holes Context_late_unknown);
    test_case "Context-only hole publication rejects a rewritten non-opening source" `Quick
      (test_context_only_api_holes Context_rewritten_source);
    test_case "Context-only hole publication allows an unconsumed completed suffix" `Quick
      (test_context_only_api_holes Context_appended_suffix);
    test_case "Context-only all new holes merge prior holes and retain the actual prior state" `Quick
      (test_context_only_api_holes Context_prior_holes);
    test_case "uncommitted Memory message floor publishes one complete program" `Quick
      (test_uncommitted_memory_message_floor Complete_memory_floor);
    test_case "native Codex capacity descends through actual uncommitted Queue Memory without holes" `Quick
      (test_uncommitted_memory_message_floor ~native:Queue_codex_native Complete_memory_floor);
    test_case "native Claude capacity descends through actual uncommitted Queue Memory without holes" `Quick
      (test_uncommitted_memory_message_floor ~native:Queue_claude_native Complete_memory_floor);
    test_case "invalid JSON before native capacity blocks Queue descent across wakes" `Quick
      (test_uncommitted_memory_message_floor ~native:Queue_json_before_native Complete_memory_floor);
    test_case "invalid domain after native capacity blocks Queue descent across wakes" `Quick
      (test_uncommitted_memory_message_floor ~native:Queue_native_before_domain Complete_memory_floor);
    test_case "measured capacity followed by invalid JSON installs no Queue cache across two wakes" `Quick
      (test_uncommitted_memory_message_floor ~native:Queue_measured_before_json Complete_memory_floor);
    test_case "native refusal after a tool effect cannot descend Queue Memory" `Quick
      (test_uncommitted_memory_message_floor ~native:Queue_effect_started Complete_memory_floor);
    test_case "opaque native failure cannot descend Queue Memory" `Quick
      (test_uncommitted_memory_message_floor ~native:Queue_opaque_failure Complete_memory_floor);
    test_case "native Codex capacity descends actual Memory-covered Queue context without changing Memory" `Quick
      (test_volatile_message_floor ~native:Queue_codex_native ~failure:None);
    test_case "native Claude capacity descends actual Memory-covered Queue context without changing Memory" `Quick
      (test_volatile_message_floor ~native:Queue_claude_native ~failure:None);
    test_case "uncommitted Memory late failure preserves all stores and retries source" `Quick
      (test_uncommitted_memory_message_floor Late_memory_failure);
    test_case "uncommitted Memory rejects a changed original source prefix" `Quick
      (test_uncommitted_memory_message_floor Rewritten_memory_source);
    test_case "uncommitted Memory accepts append while leaving the suffix unread" `Quick
      (test_uncommitted_memory_message_floor Appended_memory_suffix);
    test_case "actual API exhaustion records an exact hole and recovers without rereading it" `Quick
      (test_queue_memory_floor_retains_proven_api_holes ~all_refused:false);
    test_case "all proven API holes still judge host observations before one publication" `Quick
      (test_queue_memory_floor_retains_proven_api_holes ~all_refused:true);
    test_case "a continuity pass carries tool turns folded once" `Quick
      test_a_continuity_pass_carries_tool_turns_folded_once;
    test_case "an API commit releases the CLI limit" `Quick test_an_api_commit_releases_the_cli_limit;
    test_case "a refusal that is not about size keeps the width" `Quick test_a_refusal_that_is_not_about_size_keeps_the_width;
    test_case "a size refusal anywhere in the walk narrows" `Quick test_a_size_refusal_anywhere_in_the_walk_narrows;
    test_case "an unreadable source keeps the width" `Quick test_an_unreadable_source_keeps_the_width;
    test_case "a restart forgets the width" `Quick test_a_restart_forgets_the_width;
    test_case "an answer without a working state keeps width" `Quick
      test_an_answer_without_a_working_state_keeps_width;
    test_case "a snapshot that fails to commit keeps the width" `Quick
      test_a_snapshot_that_fails_to_commit_keeps_the_width;
    test_case "a refused answer then a quota keeps width" `Quick
      test_a_refused_answer_then_a_quota_keeps_width;
    test_case "a quota then a refused answer keeps width" `Quick
      test_a_quota_then_a_refused_answer_keeps_width;
    test_case "reports in one pass keep any size verdict" `Quick
      test_reports_in_one_pass_keep_any_size_verdict;
    test_case "normal witnessed coverage" `Quick test_ordinary_witnessed_coverage;
    test_case "split only an oversized work unit" `Quick test_fit_splits_only_oversized_work_unit;
    test_case "fit preserves exact Memory recovery" `Quick test_fit_keeps_exact_recovery_range;
    test_case "normal baseline excludes unknown prefix" `Quick test_ordinary_baseline_coverage;test_case "baseline partial bootstrap and recovery" `Quick test_baseline_partial_bootstrap;test_case "executor cancellation joins commit" `Quick test_worker_cancellation_waits_for_commit;
    test_case "Memory frontier proves publication coverage" `Quick test_memory_coverage_required;
    test_case "saved state, suffix, CAS, restart" `Quick test_append_cas_and_restart;
    test_case "failed generation keeps prior coverage" `Quick test_failed_state_keeps_old_frontier]]
