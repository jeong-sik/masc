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
   context=Agent_core.Context.create_sync ();mcp_sessions=[];working_context=None}
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
    append (B.Turn_ended {turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:number;
      history_at_start=(if fresh then B.Fresh_history else B.Continued_history);
      position=B.position_of_messages messages |> get}) in
  f env config save append boundary
let prepare config = P.prepare ~config ~keeper_name ~trace_id () |> get
let record_prepared_memory config prepared =
  let range_id = P.memory_range_id ~config ~keeper_name prepared |> get in
  ignore (Masc.Keeper_memory_os_current.apply_disposition ~durable_range_id:range_id
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Masc.Workspace.base_path)
    ~keeper_id:keeper_name ~now:1000. ~source:{kind=Masc.Keeper_memory_os_current.Librarian;trace_id}
    ~absorbed:[] ~new_claims:[] () |> get)
let record_memory config = record_prepared_memory config (prepare config |> some)
let commit config prepared text =
  record_prepared_memory config prepared;
  P.commit ~config ~keeper_name ~prepared ~working_state:text |> get
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
    (Result.is_error (P.commit ~config ~keeper_name ~prepared ~working_state:"old"));
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
    (Result.is_error (P.commit ~config ~keeper_name ~prepared ~working_state:" "));
  check bool "failure publishes no frontier" true (P.read ~config ~keeper_name |> get |> Option.is_none);
  let old=commit config prepared "Unresolved request remains." in
  let full=prefix@[message "Another unresolved request"] in save full;boundary ~fresh:false 2 full;
  let next=prepare config |> some in
  check bool "failure cannot replace previous valid frontier" true
    (Result.is_error (P.commit ~config ~keeper_name ~prepared:next ~working_state:""));
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
            P.commit ~config ~keeper_name ~prepared ~working_state:"Pending request remains.")
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
    (Result.is_error (P.commit ~config ~keeper_name ~prepared ~working_state:"First fact"));
  record_memory config;
  check bool "exact saved Memory permits publication" true
    (P.memory_committed ~config ~keeper_name prepared |> get);
  let next=first@[message "New fact not yet in Memory"] in save next;boundary ~fresh:false 2 next;
  let recovered=prepare config |> some in
  check int "appended turns do not expand unpublished Memory commit" 1 (P.end_atom recovered);
  check bool "old receipt is recoverable with newly appended boundary" true
    (P.memory_committed ~config ~keeper_name recovered |> get);
  ignore (P.commit ~config ~keeper_name ~prepared:recovered ~working_state:"First fact" |> get);
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
  let saved=P.commit ~config ~keeper_name ~prepared:recovered ~working_state:"A and B" |> get in
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
  ignore (Masc.Keeper_memory_os_current.apply_disposition ~durable_range_id:range_id
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
  ignore (P.commit ~config ~keeper_name ~prepared ~working_state:"A and B" |> get)
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
    (P.memory_range_id ~config ~keeper_name recovered |> get = receipt);
  check bool "pending publication cannot be subdivided" true (Option.is_none (P.narrow recovered));
  let saved = P.commit ~config ~keeper_name ~prepared:recovered ~working_state:"Five atoms." |> get in
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
    Printf.fprintf oc "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = %S\n"
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
  let current = Current.apply_disposition ~keepers_dir ~keeper_id:keeper_name ~now:1000.
    ~source:{kind=Current.Librarian;trace_id} ~absorbed:[] ~new_claims:[] () |> get in
  let half = prepare config |> some |> P.narrow |> some in
  let input : K.input =
    {turn_ref=P.turn_ref half; goal_context=K.No_task; keeper_instructions=instructions;
     current=Some {K.facts=current.facts};
     working_context=Masc.Keeper_librarian_context.empty;
     messages=P.messages half; tool_observations=[];counterpart_observations=[]} in
  let variables = ("continuity", Yojson.Safe.to_string (P.prompt_json half)) ::
    List.remove_assoc "continuity" (K.prompt_variables input) in
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
      | _ -> Error (Masc.Fusion_official_client.Setup_failure (Provider_error "fixture unavailable"))
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
  check int "refused range keeps committed frontier" 4
    (P.read ~config ~keeper_name |> get |> some).end_atom;
  let resumed_calls = ref 0 in
  let resumed ~runtime_id:_ ~system_prompt:_ ~output_schema:_ ~prompt =
    incr resumed_calls;
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


let narrowing_marks = [ 'a'; 'b'; 'c'; 'd'; 'e'; 'f'; 'g'; 'h' ]
let narrowing_atom_count = List.length narrowing_marks

(* The rendered prompt carries each atom once, as conversation_history, on top
   of a template of about 17 kB, so a unit of n atoms sends roughly
   n * narrowing_atom_chars + 17 kB. With 16,000 characters an atom and the
   ceiling below at 65,000, four atoms (64 kB + template) land over the
   ceiling and two (32 kB + template) under it for any template between 1 kB
   and 33 kB, so the template size cannot decide either comparison. Eight
   atoms rather than four so that six remain after the first committed unit:
   a pass that released the width on a commit would offer those six and be
   refused, which four atoms could not have shown. *)
let narrowing_atom_chars = 16_000
let narrowing_atom_text mark = String.make narrowing_atom_chars mark

(* A Keeper whose continuity snapshot no longer fits its history prepares from
   atom 0, so one pass's source is the whole backlog. These cases pin what a
   refused pass carries to the next one and which refusals must not move it at
   all (#37793: one live Keeper walked 12756 -> 6378 -> 3189 ninety-six times
   in a day and committed nothing, because every pass started over). *)
let narrowing_fixture ?(cli_slot_ids = []) ?cli_runner
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
  with_source @@ fun env config save _append boundary ->
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw
  @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let base_path = config.Masc.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  Out_channel.with_open_bin (Filename.concat keepers_dir (keeper_name ^ ".toml")) (fun oc ->
    Printf.fprintf oc "[keeper]\nname = %S\ninstructions = %S\nsandbox_profile = %S\n"
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
  let server = F.start_server ~sw ~net:env#net ~clock:env#clock
    (F.Reply_with (fun index body ->
       bodies := !bodies @ [String.length body];
       answer index body)) in
  let slot_ids = List.init slot_count (fun index -> Printf.sprintf "narrowing-slot-%d" index) in
  ignore (F.publish_registry ~cli_slot_ids ~lane_id:"librarian_exact" ~slot_ids
    (F.resolver_snapshot ~source:"narrowing-fixture"
       (List.map (fun id -> { F.id; base_url = server.F.base_url }) slot_ids)));
  save atoms;
  boundary ~fresh:true 1 atoms;
  ignore (Current.apply_disposition ~keepers_dir ~keeper_id:keeper_name ~now:1000.
    ~source:{ kind = Current.Librarian; trace_id } ~absorbed:[] ~new_claims:[] () |> get);
  (* No forget_measurement between passes: that is what a server restart does,
     and the width these cases are about lives in the same memory. *)
  let pass () =
    Masc.Keeper_librarian_queue_refresh.For_testing.run_continuity ?cli_runner ~base_path
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

let narrowing_ceiling = 65_000
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
let tool_atoms =
  let open Agent_core.Types in
  List.concat_map (fun index ->
    let call_id = Printf.sprintf "call-%d" index in
    [ message (tool_atom_opening index)
    ; make_message ~role:Assistant
        [ ToolUse { id = call_id; name = tool_name
                  ; input = `Assoc [ "path", `String tool_argument_marker ] } ]
    ; { (make_message ~role:Tool
           [ ToolResult { tool_use_id = call_id; content = tool_result_marker
                        ; outcome = Tool_succeeded; json = None; content_blocks = None } ])
        with tool_call_id = Some call_id } ])
    tool_atom_indices

let check_folded_tool_request body =
  check int "no tool call argument reaches the request" 0
    (occurrences ~sub:tool_argument_marker body);
  check int "no tool result body reaches the request" 0
    (occurrences ~sub:tool_result_marker body);
  List.iter (fun index ->
    check int (Printf.sprintf "user message %d travels once" index) 1
      (occurrences ~sub:(tool_atom_opening index) body))
    tool_atom_indices;
  check int "each call's tool name survives in its folded line"
    (List.length tool_atom_indices)
    (occurrences ~sub:("name=" ^ tool_name) body)

let test_a_continuity_pass_carries_tool_turns_folded_once () =
  let run ~memory_committed ~answer =
    let requests = ref [] in
    narrowing_fixture ~atoms:tool_atoms ~slot_count:1
      ~answer:(fun _index body ->
        requests := !requests @ [ body ];
        `OK, Exact_output_fixture.openai_response answer)
    @@ fun ~bodies:_ ~pass ~coverage ~hide_source:_ ~restart:_ ~config ->
    if memory_committed then record_memory config;
    pass ();
    check int "one request" 1 (List.length !requests);
    check_folded_tool_request (List.hd !requests);
    (* The user message and the assistant's call each open an atom; the tool
       result joins the call's atom. *)
    check (option int) "the folded range commits"
      (Some (2 * List.length tool_atom_indices)) (coverage ())
  in
  run ~memory_committed:false
    ~answer:(Yojson.Safe.from_string
               {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":"s"}|});
  run ~memory_committed:true ~answer:(`Assoc [ "working_state", `String "s" ])

let test_refused_width_carries_to_the_next_pass () =
  narrowing_fixture ~slot_count:1
    ~answer:(fun _index body ->
      if String.length body > narrowing_ceiling
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
    (List.hd !bodies > narrowing_ceiling);
  pass ();
  (* Without the carried width this pass prepares the whole source again and
     is refused again, exactly as the live keeper was ninety-six times. *)
  check int "the second pass sends one request as well" 2 (List.length !bodies);
  check bool "and it is smaller than the first" true
    (List.nth !bodies 1 < List.nth !bodies 0);
  check (option int) "still over the ceiling, so still nothing commits" None (coverage ());
  pass ();
  check bool "the third pass sends a request the target accepts" true
    (List.nth !bodies 2 <= narrowing_ceiling);
  check (option int) "reading less commits, and the rest follows in the same pass"
    (Some narrowing_atom_count) (coverage ());
  check (option int) "reading the backlog to its end releases the width" None (width ());
  (* Every request after the first commit stayed at the width. A pass that
     released the width on a commit would have offered the six remaining
     atoms, which the target refuses. *)
  check bool "a commit does not release the width" true
    (List.for_all (fun size -> size <= narrowing_ceiling)
       (List.filteri (fun index _ -> index >= 2) !bodies))

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
      if String.length body > narrowing_ceiling
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
      if String.length body > narrowing_ceiling
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
   RFC-librarian-lifecycle §4.3 counts a refused output among the failures
   reading less answers. *)
let answer_without_state =
  Exact_output_fixture.openai_response
    (Yojson.Safe.from_string
       {|{"new_claims":[],"dropped":[],"working_contexts":[],"working_state":null}|})

let test_an_answer_without_a_working_state_reads_less () =
  narrowing_fixture ~slot_count:1
    ~answer:(fun _index _body -> `OK, answer_without_state)
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart:_ ~config:_ ->
  pass ();
  pass ();
  check bool "an answer without a working state reads less next time" true
    (List.nth !bodies 1 < List.nth !bodies 0);
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

(* An answer the validator refused and a quota refusal, in either order. The
   refused answer is size evidence wherever the walk met it, so both orders
   read less. *)
let walk_of_two ~first ~second =
  narrowing_fixture ~slot_count:2
    ~answer:(fun index _body -> if index mod 2 = 0 then first () else second ())
  @@ fun ~bodies ~pass ~coverage ~hide_source:_ ~restart:_ ~config:_ ->
  pass ();
  check int "the walk tried both slots" 2 (List.length !bodies);
  pass ();
  check bool "the next pass reads less" true (List.nth !bodies 2 < List.nth !bodies 0);
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
      Error (Masc.Fusion_official_client.Setup_failure (Provider_error "fixture unavailable"))
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

let test_a_refused_answer_then_a_quota_reads_less () =
  walk_of_two ~first:no_state ~second:quota

let test_a_quota_then_a_refused_answer_reads_less () =
  walk_of_two ~first:quota ~second:no_state

let test_reports_in_one_pass_keep_any_size_verdict () =
  let module R = Masc.Keeper_librarian_runtime in
  let merge = Masc.Keeper_librarian_queue_refresh.For_testing.merge_not_committed in
  let report detail walk_shows_size = { R.detail; walk_shows_size } in
  List.iter
    (fun (name, earlier, (latest : R.not_committed), expected) ->
       let merged = merge earlier latest in
       check bool name expected merged.R.walk_shows_size;
       check string (name ^ ": the latest detail is logged") latest.R.detail merged.R.detail)
    [ "one report", None, report "walk" true, true
    ; "size, then a raise", Some (report "walk" true), report "raise" false, true
    ; "a raise, then size", Some (report "raise" false), report "walk" true, true
    ; "no size in either", Some (report "walk" false), report "raise" false, false
    ]

let () = run "production continuity pair"
  ["cycle",[test_case "completed turns are work units" `Quick test_completed_turn_work_units;
    test_case "a rewrite from atom 0 follows its target" `Quick test_rewrite_from_zero_follows_its_target;
    test_case "the rewrite target is the Librarian's position" `Quick test_rewrite_target_is_the_librarian_position;
    test_case "pending receipt overrides next turn" `Quick test_recovery_overrides_next_turn;
    test_case "queue keeps capacity and alternative opportunity" `Quick test_queue_reuses_capacity_without_gating_alternatives;
    test_case "a refused width carries to the next pass" `Quick test_refused_width_carries_to_the_next_pass;
    test_case "a committed range asks for the working state alone" `Quick
      test_a_committed_range_asks_for_the_working_state_alone;
    test_case "a continuity pass carries tool turns folded once" `Quick
      test_a_continuity_pass_carries_tool_turns_folded_once;
    test_case "an API commit releases the CLI limit" `Quick test_an_api_commit_releases_the_cli_limit;
    test_case "a refusal that is not about size keeps the width" `Quick test_a_refusal_that_is_not_about_size_keeps_the_width;
    test_case "a size refusal anywhere in the walk narrows" `Quick test_a_size_refusal_anywhere_in_the_walk_narrows;
    test_case "an unreadable source keeps the width" `Quick test_an_unreadable_source_keeps_the_width;
    test_case "a restart forgets the width" `Quick test_a_restart_forgets_the_width;
    test_case "an answer without a working state reads less" `Quick
      test_an_answer_without_a_working_state_reads_less;
    test_case "a snapshot that fails to commit keeps the width" `Quick
      test_a_snapshot_that_fails_to_commit_keeps_the_width;
    test_case "a refused answer then a quota reads less" `Quick
      test_a_refused_answer_then_a_quota_reads_less;
    test_case "a quota then a refused answer reads less" `Quick
      test_a_quota_then_a_refused_answer_reads_less;
    test_case "reports in one pass keep any size verdict" `Quick
      test_reports_in_one_pass_keep_any_size_verdict;
    test_case "normal witnessed coverage" `Quick test_ordinary_witnessed_coverage;
    test_case "split only an oversized work unit" `Quick test_fit_splits_only_oversized_work_unit;
    test_case "fit preserves exact Memory recovery" `Quick test_fit_keeps_exact_recovery_range;
    test_case "normal baseline excludes unknown prefix" `Quick test_ordinary_baseline_coverage;test_case "baseline partial bootstrap and recovery" `Quick test_baseline_partial_bootstrap;test_case "executor cancellation joins commit" `Quick test_worker_cancellation_waits_for_commit;
    test_case "Memory frontier proves publication coverage" `Quick test_memory_coverage_required;
    test_case "saved state, suffix, CAS, restart" `Quick test_append_cas_and_restart;
    test_case "failed generation keeps prior coverage" `Quick test_failed_state_keeps_old_frontier]]
