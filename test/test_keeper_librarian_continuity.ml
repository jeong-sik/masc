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
  check int "first completed prefix supplied" 1 (U.member "completed_conversation" input |> U.to_list |> List.length);
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
  check int "only new complete suffix fed to model" 1
    (U.member "completed_conversation" input |> U.to_list |> List.length);
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
  let restarted=prepare config |> some |> P.prompt_json in
  check bool "restart does not carry old state into new generation" true (U.member "previous_working_state" restarted=`Null);
  check int "restart supplies full completed prefix" 2 (U.member "completed_conversation" restarted |> U.to_list |> List.length)
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
  check int "partial cut is independent of real completed anchor" 5 saved.covering_end_atom;
  let later=prepare config |> some in
  check int "remaining source is still supplied" 3 (List.length (P.messages later));
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
  let prepared=prepare config |> some in
  record_ordinary config prepared ~start_atom:0;
  check bool "serial witnessed Memory already read this prefix" true
    (P.memory_committed ~config ~keeper_name prepared |> get);
  ignore (P.commit ~config ~keeper_name ~prepared ~working_state:"A and B" |> get)
let test_ordinary_baseline_coverage () = with_source @@ fun _env config save _append boundary ->
  let baseline=[message "A";message "B"] in save baseline;boundary ~fresh:false 1 baseline;
  let full=baseline@[message "C";message "D"] in save full;boundary ~fresh:false 2 full;
  let all=prepare config |> some in
  record_ordinary config all ~start_atom:2;
  check bool "normal receipt never certifies unknown baseline prefix" false
    (P.memory_committed ~config ~keeper_name all |> get);
  let prefix=P.narrow all |> some in
  ignore (commit config prefix "A and B");
  let suffix=prepare config |> some in
  check int "next source starts after baseline" 2
    (P.memory_range_id ~config ~keeper_name suffix |> get).start_atom;
  check bool "normal serial receipt certifies already consumed suffix" true
    (P.memory_committed ~config ~keeper_name suffix |> get)
let test_fit_largest_request_prefix () = with_source @@ fun _env config save _append boundary ->
  let messages = List.init 8 (fun index -> message (String.make (index + 1) 'x')) in
  save messages; boundary ~fresh:true 1 messages;
  let prepared = prepare config |> some in
  let original = P.prompt_json prepared |> Yojson.Safe.to_string in
  let visited = ref [] in
  let whole = P.fit ~fits:(fun candidate ->
    visited := P.end_atom candidate :: !visited; Ok true) prepared |> get |> some in
  check bool "fitting original returned unchanged" true (whole == prepared);
  check (list int) "whole request tested before search" [8] !visited;
  let first = P.narrow prepared |> some in
  ignore (commit config first "Prior work preserved.");
  let suffix = prepare config |> some in
  let exact_size candidate = P.prompt_json candidate |> Yojson.Safe.to_string |> String.length in
  let expected = P.prepare ~end_atom:7 ~config ~keeper_name ~trace_id () |> get |> some in
  let limit = exact_size expected in
  let fitted = P.fit ~fits:(fun candidate -> Ok (exact_size candidate <= limit)) suffix
    |> get |> some in
  check int "largest fitting whole-atom endpoint" 7 (P.end_atom fitted);
  check string "exact suffix and prior state preserved" (P.prompt_json expected |> Yojson.Safe.to_string)
    (P.prompt_json fitted |> Yojson.Safe.to_string);
  check string "frozen original unaffected" original (P.prompt_json prepared |> Yojson.Safe.to_string);
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
     working_context=Masc.Keeper_librarian_context_io.capture ~base_path ~keepers_dir ~keeper_name;
     messages=P.messages half; tool_observations=[];counterpart_observations=[]} in
  let variables = ("continuity", Yojson.Safe.to_string (P.prompt_json half)) ::
    List.remove_assoc "continuity" (K.prompt_variables input) in
  let _, prompt = Prompt_registry.resolve_and_render_prompt_template
    Prompt_names.librarian variables |> get in
  let requirement = Agent_core.Exact_output.make_output_requirement
    ~schema:Masc.Keeper_structured_output_schema.librarian_current_output_schema
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
  check bool "no-fit source still reaches recovered alternative" true
    (match !alternative_bytes with Some size -> size > max_chars | None -> false)

let () = run "production continuity pair"
  ["cycle",[test_case "queue keeps capacity and alternative opportunity" `Quick test_queue_reuses_capacity_without_gating_alternatives;
    test_case "normal witnessed coverage" `Quick test_ordinary_witnessed_coverage;
    test_case "largest request-fitting prefix" `Quick test_fit_largest_request_prefix;
    test_case "fit preserves exact Memory recovery" `Quick test_fit_keeps_exact_recovery_range;
    test_case "normal baseline excludes unknown prefix" `Quick test_ordinary_baseline_coverage;test_case "baseline partial bootstrap and recovery" `Quick test_baseline_partial_bootstrap;test_case "executor cancellation joins commit" `Quick test_worker_cancellation_waits_for_commit;
    test_case "Memory frontier proves publication coverage" `Quick test_memory_coverage_required;
    test_case "saved state, suffix, CAS, restart" `Quick test_append_cas_and_restart;
    test_case "failed generation keeps prior coverage" `Quick test_failed_state_keeps_old_frontier]]
