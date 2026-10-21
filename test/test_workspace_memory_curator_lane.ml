(** Actual public owner, configured Runtime, MCP protocol, persistent Python
    worker and common Exact HTTP runner. Container resource launch/cleanup is
    substituted; this does not prove Docker or installed browser/UI behavior. *)
open Alcotest
open Masc
module Curator = Server_workspace_memory_curator
module Consumer = Server_workspace_memory_addon
module Capture = Workspace_memory_execution_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Store = Lane_addon_store
module Ledger = Workspace_memory_ledger
module Briefing = Workspace_memory_briefing
module Request = Workspace_memory_request
module Context = Workspace_memory_context
module Runtime = Lane_addon_runtime
module Protocol = Lane_addon_worker_protocol
module Current = Keeper_memory_os_current
module Types = Keeper_memory_os_types
module F = Exact_output_fixture
let get = function Ok value -> value | Error detail -> fail detail
let owned value=get (Result.map_error Owner.error_to_string value)
let consumed value=get (Result.map_error Consumer.error_to_string value)
let member=Yojson.Safe.Util.member
let json=testable Yojson.Safe.pp Yojson.Safe.equal
let ()=Mirage_crypto_rng_unix.use_default ()
let write path bytes=Fs_compat.mkdir_p (Filename.dirname path);Out_channel.with_open_bin path (fun c -> output_string c bytes)
let protocol_error = function
  | Protocol.Invalid_contract s | Protocol.Protocol_failed s | Protocol.Invalid_observation s -> s
  | Host_refusal (Lane_addon_call_context.Rejected s | Unavailable s | Activity_disabled s | Activity_unobserved s) -> s
  | Stopped -> "worker protocol stopped"
let invocation_error = function
  | Protocol.Host_refusal refusal -> Lane_addon_call_context.Host_refusal refusal
  | (Protocol.Invalid_contract _ | Protocol_failed _ | Invalid_observation _ | Stopped) as e ->
    Lane_addon_call_context.Transport_error (protocol_error e)
let commit_facts base_path claims =
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let keeper_id="writer" and now=1_700_000_000. in
  let expected_revision=match get (Current.read_for_keepers_dir ~keepers_dir ~keeper_id) with
    | None -> None | Some current -> Some current.revision in
  let facts=List.map (fun claim -> Types.observed ~claim ~category:Types.Fact ~now
    ~origin:{kind=Types.Authored;trace_id="actual-curator-owner-fixture"}) claims in
  Current.replace ~keepers_dir ~keeper_id ~expected_revision ~now
    ~source:{kind=Current.Librarian;trace_id="actual-curator-owner-fixture"} ~facts () |> get |> ignore
let records store=owned (Owner.discover ~store ~scope:Capture.scope)
let captures base_path store=records store |> List.map (fun record ->
  let capture=get (Capture.restore ~workspace:(get (Capture.observe_workspace ~base_path))
    ~load:(fun ~request_id -> Owner.load ~store ~scope:Capture.scope ~request_id |> Result.map_error Owner.error_to_string) record) in
  record,capture)
let await clock condition=Eio.Time.with_timeout_exn clock F.fixture_wait_seconds (fun () ->
  let rec loop ()=if condition () then () else (Eio.Fiber.yield ();loop ()) in loop ())
let reconcile_until_export clock ~config =
  await clock (fun () ->
    ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> get);
    (Runtime.tool_export_snapshot ~config ~access:Lane_addon_sources.Operator_configuration ~reserved:[]).exports<>[])
let is_finished record=match Progress.phase record.Owner.progress with
  | Progress.Finished _ -> true
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false
let ready_summary base_path=
  let ledger=get (Ledger.load ~base_path) in
  let state=get (Briefing.load ~directory:(Ledger.directory ~base_path)) in
  not (Briefing.needs_refresh ~sources:(Ledger.briefing_sources ledger)
    ~contract:(Briefing.contract ~template:(Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing).effective) state)
let settle_all clock base_path store count=await clock (fun () ->
  List.length (Ledger.dispositions (get (Ledger.load ~base_path)))=count && ready_summary base_path
  && Curator.For_testing.is_idle ~base_path && List.for_all is_finished (records store))
let publish_routes base_path urls =
  let slots=List.mapi (fun i url -> {F.id="candidate-" ^ string_of_int i;base_url=url}) urls in
  let lanes=List.map (fun output ->
    let owner=match Runtime_schema.exact_lane_owner_of_key ("curator/" ^ output) with
      | Some owner -> owner | None -> fail "invalid actual Addon output key" in
    {Runtime_schema.owner;enabled=true;slot_ids=List.map (fun (s:F.target_fixture) -> s.id) slots;
      cli_slot_ids=[];max_output_tokens=Some F.fixture_max_output_tokens;thinking=None}) ["classification";"briefing"] in
  Runtime_exact_output_registry.publish ~lanes (F.resolver_snapshot ~source:base_path slots)
  |> Result.map_error Runtime_exact_output_registry.publication_error_to_string |> get |> ignore
let backend env base_path delivery : Runtime.For_testing.backend = {
  start=(fun ~sw ~state_owner ~instance_id ~installation_id:_ ~package ~binding:_ ~on_authority ~is_live_instance:_ ~on_created ->
    let state_owner=match state_owner with Some owner -> owner | None -> fail "persistent worker has no state owner" in
    let state=Filename.concat base_path ("worker-state-" ^ Store.digest (Lane_addon_worker_state.identity state_owner)) in
    Fs_compat.mkdir_p state;
    let contract=Protocol.contract_of_package package |> Result.map_error protocol_error |> get in
    let protocol=Protocol.create ~instance_id ~contract () in
    get (on_authority (Lane_addon_lifecycle.Container_authority
      {runtime=Lane_addon_types.Docker;engine=Lane_addon_lifecycle.Docker_engine "fixture-resource-launch"}));
    let client=Agent_core.Mcp.connect ~sw ~mgr:(Eio.Stdenv.process_mgr env) ~command:"python3"
      ~args:[Filename.concat package.directory "server.py";"--state";state]
      ~max_response_bytes:contract.max_reply_bytes () |> Result.map_error Agent_core.Error.to_string |> get in
    Protocol.initialize protocol client |> Result.map_error protocol_error |> get;
    let connection : Runtime.For_testing.connection = {
      browser=None;resource=Lane_addon_lifecycle.Container_resource instance_id;
      resolved_image=Some (Lane_addon_engine.image_of_inspect Lane_addon_types.Docker ("sha256:" ^ String.make 64 'a') |> get);
      observe=(fun ~binding ~sources -> Protocol.observe protocol ~binding ~sources |> Result.map_error protocol_error);
      exported_tools=(fun () -> Protocol.exported_tools protocol);
      call_exported_tool=(fun ~on_result ~authorize ~principal ~name ~arguments ->
        Protocol.call_exported_tool ~on_result ?authorize ~principal protocol ~name ~arguments
        |> Result.map_error invocation_error);
      action_schema=(fun () -> Protocol.action_schema protocol);
      act=(fun ~arguments -> Protocol.act protocol ~arguments |> Result.map_error protocol_error);
      stop=(fun () -> Protocol.close protocol;Ok (Lane_addon_lifecycle.Released
        {engine=Lane_addon_lifecycle.Docker_engine "fixture-resource-launch";container_id=Some instance_id}));
      host=Some {await_change=None;
        list_requests=(fun () -> Protocol.host_requests protocol |> Result.map_error protocol_error);
        deliver=(fun ~arguments -> if !delivery then Error "controlled reply loss before worker delivery"
          else Protocol.host_result protocol ~arguments |> Result.map_error protocol_error)}} in
    on_created connection;Ok connection);
  package_ready=(fun ~package:_ -> Ok ());
  acquire=(fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
  recover_stop=(fun ~state_owner:_ ~instance_id:_ ~authority ~resource -> match authority,resource with
    | Lane_addon_lifecycle.Container_authority {engine;_},Some (Lane_addon_lifecycle.Container_resource id) ->
      Ok (Lane_addon_lifecycle.Released {engine;container_id=Some id})
    | Lane_addon_lifecycle.Container_authority {engine;_},None ->
      Ok (Lane_addon_lifecycle.Released {engine;container_id=None})
    | Lane_addon_lifecycle.Container_authority _,Some (Lane_addon_lifecycle.Native_resource _)
    | Lane_addon_lifecycle.Native_admission _,(None|Some _) ->
      Error (Lane_addon_lifecycle.Cleanup_unconfirmed "fixture owns container lifecycle only"));
  condition_met=(fun ~runtime:_ _ -> true);sweep=(fun ~runtime:_ ~is_live_instance:_ -> Ok []) }
let save_source config source source_text =
  let access=Lane_addon_sources.Operator_configuration in
  let document=Runtime.read_declaration ~access ~config (`Assoc ["source_path",`String source])
    |> Result.map_error (fun e -> e.Lane_addon_declaration.message) |> get in
  Runtime.save_declaration ~access ~config (`Assoc ["mode",`String "save";
    "file_name",`String (Filename.basename source);"expected_source_revision",member "source_revision" document;
    "source_text",`String source_text]) |> Result.map_error (fun e -> e.Lane_addon_declaration.message) |> get |> ignore
let capture_classification config =
  let base_path=config.Workspace.base_path in
  let context=get (Context.collect ~base_path) and ledger=get (Ledger.load ~base_path) in
  let change=Ledger.reconcile ledger (Context.keepers context) in
  let prompt=Prompt_registry.resolve_prompt Prompt_names.workspace_memory_curator in
  let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_curator
    prompt ["workspace_memory_changes",Yojson.Safe.to_string input] in
  let batch=match Request.prepare ~neighbor_limit:0 ~render ~ledger:change.ledger
    ~current:change.current_facts ~pending:change.new_facts |> Result.map_error Request.error_to_string |> get with
    | Some batch -> batch | None -> fail "fixture requires pending classification" in
  Consumer.capture_classification ~config ~prompt ~ledger:change.ledger ~batch |> consumed
let original_record store capture =
  match owned (Owner.load ~store ~scope:Capture.scope ~request_id:(Capture.Request_id.to_string (Capture.request_id capture))) with
  | Some record -> record | None -> fail "public capture did not retain its original"
let advance store record event=match Owner.advance ~store ~expected:record ~event
    |> Result.map_error Owner.update_error_to_string |> get with
  | Owner.Stored record -> record | Already_stored _ | Unconfirmed _ -> fail "fixture needs a freshly recorded original fact"
let seed_size_refusal store capture =
  let record=advance store (original_record store capture) Progress.Dispatch_intended in
  advance store record (Progress.Refused {stage=Progress.Execution;
    evidence=Lane_addon_exact.final_to_json (Lane_addon_exact.Call_final (Input_refused Input_capacity))})
type provider_mode = Answer | Refuse_fact of string
let with_fixture ?(off=false) ?(routes=true) ?(start_owner=true) ?(invalid_first=false)
    ?(claims=["An original production source"]) f =
  let base_path=Filename.temp_dir "curator-production-owner-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path ".masc/config")) (fun () ->
  F.with_official_client_runtimes (fun () -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);Masc_test_deps.init_eio_clock env;
    Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
    Fun.protect ~finally:(fun () -> Process_eio.reset_for_testing ();Fs_compat.clear_fs ()) (fun () ->
    Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
      Runtime.For_testing.reset ();
      Prompt_registry.set_markdown_dir "../config/prompts";Prompt_defaults.init ();
      Prompt_registry.clear_prompt_override Prompt_names.workspace_memory_curator;
      Prompt_registry.clear_prompt_override Prompt_names.workspace_memory_briefing;
      let config=Workspace.default_config base_path in
      let store=Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
      let package=Lane_addon_manifest.load ~path:"../addons/workspace-curator/lane.toml"
        |> Result.map_error Lane_addon_manifest.error_to_string |> get in
      let source=Filename.concat (Runtime.configuration_directory config) "curator.toml" in
      let declaration enabled=Printf.sprintf "id=\"curator\"\nenabled=%b\nrun_id=\"curator-owner\"\nmanifest_path=%s\n[binding]\nsources=[]\n"
        enabled (Yojson.Safe.to_string (`String (Filename.concat package.directory "lane.toml"))) in
      write source (declaration (not off));
      let mode=ref Answer and delivery=ref false in
      let original_for body=
        let messages=Yojson.Safe.from_string body |> member "messages" |> Yojson.Safe.Util.to_list in
        let matches=List.filter (fun (record,capture) ->
          (match Progress.phase record.Owner.progress with Progress.Dispatch_pending _ -> true
           | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
           | Rejected _ | Subdividing _ | Subdivided _ -> false)
          && List.exists (fun msg -> member "content" msg=`String (Capture.rendered_prompt capture)) messages)
          (captures base_path store) in
        match matches with [(_,capture)] -> capture | [] | _::_::_ -> fail "provider has no unique original request" in
      let response bad _index body=
        let original=original_for body in
        let output=match Capture.work original with
          | Capture.Classification {batch;_} ->
            let refuse=bad || match !mode with Answer -> false | Refuse_fact claim ->
              List.exists (fun (fact:Ledger.pending_fact) -> fact.claim=claim) batch.selected in
            `Assoc ["decisions",`List (if refuse then [] else List.map (fun (fact:Ledger.pending_fact) ->
              `Assoc ["fact_id",`String (Request.fact_id fact.fact);"kind",`String "create_claim";"value",`String fact.claim]) batch.selected)]
          | Capture.Briefing _ -> `Assoc ["briefing",`String (if bad then " " else "The original selected workspace evidence was synthesized.")] in
        `OK,F.openai_response output in
      let server=F.start_server ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) (F.Reply_with (response false)) in
      let urls=if invalid_first then
        let bad=F.start_server ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) (F.Reply_with (response true)) in
        [bad.base_url;server.base_url] else [server.base_url] in
      ignore (Runtime_exact_output_registry.publish ~lanes:[] (F.resolver_snapshot ~source:base_path [])
        |> Result.map_error Runtime_exact_output_registry.publication_error_to_string |> get);
      if routes then publish_routes base_path urls;
      commit_facts base_path claims;
      Runtime.register_exact_runner ~validate_request:(Server_lane_addon_exact.validate_request ~base_path)
        (Server_lane_addon_exact.runner ~base_path);
      Runtime.For_testing.with_backend (backend env base_path delivery) (fun () ->
        ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> get);
        if start_owner then Curator.start ~sw ~config;
        f ~sw ~clock:(Eio.Stdenv.clock env) ~base_path ~config ~store ~source ~declaration ~server ~urls ~mode ~delivery;
        Curator.For_testing.stop ~base_path;
        write source (declaration false);
        ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> get))))))))))
let test_actual_production_pipeline ()=with_fixture ~invalid_first:true (fun ~sw ~clock ~base_path ~config ~store ~source:_ ~declaration:_ ~server ~urls:_ ~mode:_ ~delivery:_ ->
  Curator.start ~sw ~config;
  settle_all clock base_path store 1;
  check int "one classification and one Briefing original" 2 (List.length (records store));
  check int "each domain reaches the admitted good HTTP candidate" 2 (F.post_count server);
  let snapshots=records store |> List.map (fun record -> record.Owner.request_id,Progress.to_json record.progress) in
  ignore (Curator.request ~base_path);await clock (fun () -> Curator.For_testing.is_idle ~base_path);
  check int "unchanged wake does not replay HTTP" 2 (F.post_count server);
  check (list (pair string json)) "original terminal and observer intents stay immutable" snapshots
    (records store |> List.map (fun record -> record.Owner.request_id,Progress.to_json record.progress)))
let test_off_then_actual_metadata_on ()=with_fixture ~off:true (fun ~sw:_ ~clock ~base_path ~config ~store ~source ~declaration ~server ~urls:_ ~mode:_ ~delivery:_ ->
  await clock (fun () -> Curator.For_testing.is_idle ~base_path);
  check int "Off creates no original request" 0 (List.length (records store));
  check int "Off calls no provider" 0 (F.post_count server);
  save_source config source (declaration true);
  ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> get);
  settle_all clock base_path store 1)
let test_original_waits_for_actual_route_publication ()=with_fixture ~routes:false (fun ~sw:_ ~clock ~base_path ~config:_ ~store ~source:_ ~declaration:_ ~server ~urls ~mode:_ ~delivery:_ ->
  await clock (fun () -> List.length (records store)=1 && Curator.For_testing.is_idle ~base_path);
  let original=(List.hd (records store)).Owner.request_id in
  check int "unconfigured route does not call a provider" 0 (F.post_count server);
  publish_routes base_path urls;
  settle_all clock base_path store 1;
  check bool "publication resumes the same retained original" true
    (List.exists (fun record -> record.Owner.request_id=original && is_finished record) (records store)))
let test_refused_identity_does_not_remint_on_unrelated_fact ()=
  let blocked="A permanently refused original source" in
  with_fixture ~start_owner:false ~claims:[blocked] (fun ~sw ~clock ~base_path ~config ~store ~source:_ ~declaration:_ ~server ~urls:_ ~mode ~delivery:_ ->
    mode:=Refuse_fact blocked;Curator.start ~sw ~config;
    await clock (fun () -> Curator.For_testing.is_idle ~base_path && match records store with
      | [record] -> (match Progress.phase record.Owner.progress with
        | Progress.Rejected _ -> true
        | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
        | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> false)
      | [] | _::_::_ -> false);
    let original=(List.hd (records store)).Owner.request_id and calls=F.post_count server in
    ignore (Curator.request ~base_path);await clock (fun () -> Curator.For_testing.is_idle ~base_path);
    check int "unchanged refusal is not a new model request" calls (F.post_count server);
    commit_facts base_path [blocked;"A separate current source"];
    await clock (fun () -> List.length (Ledger.dispositions (get (Ledger.load ~base_path)))=1 && ready_summary base_path
      && Curator.For_testing.is_idle ~base_path);
    check bool "original refusal remains with its original ID" true
      (List.exists (fun record -> record.Owner.request_id=original) (records store));
    check int "unrelated source does not remint the refused source" (calls+2) (F.post_count server))
let test_complete_discovery_blocks_malformed_original ()=with_fixture ~start_owner:false (fun ~sw ~clock ~base_path ~config ~store ~source:_ ~declaration:_ ~server ~urls:_ ~mode:_ ~delivery:_ ->
  let request_id=Capture.Request_id.fresh () |> Capture.Request_id.to_string in
  owned (Owner.retain ~store ~scope:Capture.scope ~request_id
    ~installation_id:(Owner.installation_id (Owner.Configuration "curator")) ~package_id:Capture.package_id ~tool:Capture.tool
    ~request:(`Assoc ["malformed",`Bool true]));
  Curator.start ~sw ~config;await clock (fun () -> Curator.For_testing.is_idle ~base_path);
  check int "invalid original inventory grants no replacement root" 1 (List.length (records store));
  check int "invalid original inventory dispatches no HTTP" 0 (F.post_count server))
let test_new_child_requires_fresh_configured_admission ()=
  with_fixture ~start_owner:false ~claims:["Size-refused source a";"Size-refused source b"]
    (fun ~sw:_ ~clock ~base_path:_ ~config ~store ~source ~declaration ~server ~urls:_ ~mode:_ ~delivery:_ ->
    await clock (fun () -> (Runtime.tool_export_snapshot ~config ~access:Lane_addon_sources.Operator_configuration ~reserved:[]).exports<>[]);
    let capture=capture_classification config in
    let parent=seed_size_refusal store capture in
    save_source config source (declaration false);
    check bool "saved Off before reconcile rejects new successor intention" true
      (Result.is_error (Consumer.narrow ~config ~request_id:parent.request_id));
    check int "Off rejection mints no child" 1 (List.length (records store));
    check json "Off does not alter the original refusal" (Progress.to_json parent.progress)
      (Progress.to_json (original_record store capture).progress);
    save_source config source (declaration true ^ "\n# same worker inputs with different source bytes\n");
    let child=match Consumer.narrow ~config ~request_id:parent.request_id |> consumed with
      | Consumer.Successor_ready {child;_} -> child
      | Indivisible _ | Successor_waiting _ -> fail "same semantic configuration did not admit the original child" in
    let restored=List.assoc child.request_id (List.map (fun (record,capture) -> record.Owner.request_id,capture)
      (captures config.Workspace.base_path store)) in
    check string "child preserves original raw source provenance" (Capture.destination capture).source_revision
      (Capture.destination restored).source_revision;
    check int "admission publishes journals without HTTP" 0 (F.post_count server))
let test_new_child_rejects_changed_worker_inputs ()=
  with_fixture ~start_owner:false ~claims:["Original configuration source a";"Original configuration source b"]
    (fun ~sw:_ ~clock ~base_path:_ ~config ~store ~source ~declaration:_ ~server ~urls:_ ~mode:_ ~delivery:_ ->
    await clock (fun () -> (Runtime.tool_export_snapshot ~config ~access:Lane_addon_sources.Operator_configuration ~reserved:[]).exports<>[]);
    let capture=capture_classification config in
    let parent=seed_size_refusal store capture in
    let configured=Lane_addon_config.load_file ~path:source |> get in
    save_source config source (Printf.sprintf "id=\"curator\"\nenabled=true\nrun_id=\"changed-original-inputs\"\nmanifest_path=%s\n[binding]\nsources=[]\n"
      (Yojson.Safe.to_string (`String configured.manifest_path)));
    reconcile_until_export clock ~config;
    check bool "a replacement worker does not grant an original new child" true
      (Result.is_error (Consumer.narrow ~config ~request_id:parent.request_id));
    check int "changed configured input mints no child" 1 (List.length (records store));
    check json "original refusal and capture remain intact" (Progress.to_json parent.progress)
      (Progress.to_json (original_record store capture).progress);
    check int "rejected successor never dispatches HTTP" 0 (F.post_count server))
let test_existing_intent_recovers_locally_off_then_runs_on ()=
  with_fixture ~start_owner:false ~claims:["Interrupted original source a";"Interrupted original source b"]
    (fun ~sw ~clock ~base_path ~config ~store ~source ~declaration ~server ~urls:_ ~mode:_ ~delivery:_ ->
    await clock (fun () -> (Runtime.tool_export_snapshot ~config ~access:Lane_addon_sources.Operator_configuration ~reserved:[]).exports<>[]);
    let capture=capture_classification config in
    let parent=seed_size_refusal store capture in
    let final=Lane_addon_exact.Call_final (Input_refused Input_capacity) in
    let child=match Capture.narrow ~request_id:(Capture.Request_id.fresh ()) ~final capture |> get with
      | Some child -> child | None -> fail "fixture needs a whole-prefix child" in
    let intent : Progress.successor = {request_id=Capture.Request_id.to_string (Capture.request_id child);
      request=get (Lane_addon_action.canonical (Capture.to_json child))} in
    ignore (advance store parent (Progress.Successor_intended intent));
    save_source config source (declaration false);
    ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> get);
    let recovered=Consumer.discover ~config |> consumed in
    check bool "Off completes only the original already retained intention" true
      (List.exists (fun (original:Consumer.original) -> original.record.request_id=intent.request_id) recovered);
    Curator.start ~sw ~config;
    await clock (fun () -> Curator.For_testing.is_idle ~base_path);
    check int "Off recovery starts no provider" 0 (F.post_count server);
    save_source config source (declaration true);
    ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> get);
    await clock (fun () -> List.length (Ledger.dispositions (get (Ledger.load ~base_path)))=2
      && ready_summary base_path && Curator.For_testing.is_idle ~base_path);
    check bool "original child ID completes after actual reattachment" true
      (List.exists (fun record -> record.Owner.request_id=intent.request_id && is_finished record) (records store)))
let test_accepted_host_terminal_commits_off_without_worker ()=
  with_fixture ~start_owner:false (fun ~sw ~clock ~base_path ~config ~store ~source ~declaration ~server ~urls:_ ~mode:_ ~delivery ->
    await clock (fun () -> (Runtime.tool_export_snapshot ~config ~access:Lane_addon_sources.Operator_configuration ~reserved:[]).exports<>[]);
    delivery:=true;
    let capture=capture_classification config in
    let request_id=Capture.Request_id.to_string (Capture.request_id capture) in
    ignore (Consumer.resume ~config ~request_id |> consumed);
    let request=Server_workspace_memory_addon_validation.request capture |> get in
    await clock (fun () -> match Lane_addon_exact.observe_retained ~store ~declaration_id:"curator"
        ~schema:(Capture.output_schema capture) request |> get with
      | Lane_addon_exact.Retained_terminal _ -> true | Retained_absent | Retained_open -> false);
    check int "original provider answered before the lost delivery" 1 (F.post_count server);
    save_source config source (declaration false);
    ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> get);
    Curator.start ~sw ~config;
    await clock (fun () -> is_finished (original_record store capture) && Curator.For_testing.is_idle ~base_path);
    check int "accepted host result commits locally while Off" 1 (List.length (Ledger.dispositions (get (Ledger.load ~base_path))));
    check int "Off local commit never dispatches another provider" 1 (F.post_count server);
    delivery:=false;save_source config source (declaration true);
    ignore (Runtime.reconcile_configuration ~config ~directory:(Runtime.configuration_directory config) |> get);
    settle_all clock base_path store 1;
    check int "reattach only synthesizes the pending Briefing" 2 (F.post_count server))
let test_finished_identity_readded_after_observed_removal ()=
  let claim="A completed source that is removed and later restored" in
  with_fixture ~claims:[claim]
    (fun ~sw:_ ~clock ~base_path ~config:_ ~store ~source:_ ~declaration:_ ~server ~urls:_ ~mode:_ ~delivery:_ ->
    settle_all clock base_path store 1;
    let classifications ()=captures base_path store |> List.filter_map (fun (record,capture) ->
      match Capture.work capture with
      | Capture.Classification {batch;_} -> Some (record,batch.selected)
      | Capture.Briefing _ -> None) in
    let original,selected=match classifications () with
      | [original] -> original
      | [] | _::_::_ -> fail "expected one completed original classification" in
    check bool "original classification finished before removal" true (is_finished original);
    let progress=Progress.to_json original.Owner.progress and calls=F.post_count server in
    commit_facts base_path [];
    await clock (fun () -> Ledger.dispositions (get (Ledger.load ~base_path))=[]
      && Curator.For_testing.is_idle ~base_path);
    check int "observed source removal does not request a new model answer" calls (F.post_count server);
    commit_facts base_path [claim];
    settle_all clock base_path store 1;
    let replacement=match List.filter (fun (record,_) -> record.Owner.request_id<>original.request_id)
        (classifications ()) with
      | [replacement] -> replacement
      | [] | _::_::_ -> fail "re-added pending source did not receive one distinct original" in
    let fresh,fresh_selected=replacement in
    check bool "same restored fact identity reaches the actual production owner" true
      (List.map (fun (fact:Ledger.pending_fact) -> fact.fact) fresh_selected
       = List.map (fun (fact:Ledger.pending_fact) -> fact.fact) selected);
    check bool "new original reaches a confirmed domain commit" true (is_finished fresh);
    let retained=match List.find_opt (fun record -> record.Owner.request_id=original.request_id) (records store) with
      | Some retained -> retained | None -> fail "completed original was removed" in
    check json "completed original progress stays unchanged" progress (Progress.to_json retained.progress);
    check json "completed original capture stays unchanged" original.request retained.request;
    check int "only new classification and synthesis call the provider" (calls+2) (F.post_count server))
let test_successor_frontier_ignores_an_old_semantic_destination ()=
  let old_claims=["Old configured selection a";"Old configured selection b"]
  and current_claims=["Current configured selection a";"Current configured selection b"] in
  with_fixture ~start_owner:false ~claims:old_claims
    (fun ~sw ~clock ~base_path ~config ~store ~source ~declaration:_ ~server ~urls:_ ~mode:_ ~delivery:_ ->
    let exports_ready ()=(Runtime.tool_export_snapshot ~config
      ~access:Lane_addon_sources.Operator_configuration ~reserved:[]).exports<>[] in
    await clock exports_ready;
    let old_capture=capture_classification config in
    let old=seed_size_refusal store old_capture in
    let configured=Lane_addon_config.load_file ~path:source |> get in
    save_source config source (Printf.sprintf "id=\"curator\"\nenabled=true\nrun_id=\"current-successor-frontier\"\nmanifest_path=%s\n[binding]\nsources=[]\n"
      (Yojson.Safe.to_string (`String configured.manifest_path)));
    reconcile_until_export clock ~config;
    check bool "the old refusal cannot admit a child on replacement inputs" true
      (Result.is_error (Consumer.narrow ~config ~request_id:old.request_id));
    commit_facts base_path (old_claims @ current_claims);
    let context=get (Context.collect ~base_path) and ledger=get (Ledger.load ~base_path) in
    let change=Ledger.reconcile ledger (Context.keepers context) in
    let pending=List.filter (fun (fact:Ledger.pending_fact) -> List.mem fact.claim current_claims) change.new_facts in
    let prompt=Prompt_registry.resolve_prompt Prompt_names.workspace_memory_curator in
    let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_curator
      prompt ["workspace_memory_changes",Yojson.Safe.to_string input] in
    let batch=match Request.prepare ~neighbor_limit:0 ~render ~ledger:change.ledger ~current:change.current_facts ~pending
        |> Result.map_error Request.error_to_string |> get with
      | Some batch -> batch | None -> fail "expected disjoint current pending work" in
    let current_capture=Consumer.capture_classification ~config ~prompt ~ledger:change.ledger ~batch |> consumed in
    let current=seed_size_refusal store current_capture in
    check bool "retained candidates carry different actual semantic revisions" true
      ((Capture.destination old_capture).configuration_revision<>(Capture.destination current_capture).configuration_revision);
    check bool "the old destination is not a current continuation" false
      (Consumer.successor_is_current ~config ~capture:old_capture |> consumed);
    check bool "the matching current domain has one continuation" true
      (Consumer.successor_is_current ~config ~capture:current_capture |> consumed);
    Curator.start ~sw ~config;
    await clock (fun () -> List.length (Ledger.dispositions (get (Ledger.load ~base_path)))=2
      && ready_summary base_path && Curator.For_testing.is_idle ~base_path);
    let retained_old=original_record store old_capture in
    (match Progress.phase retained_old.progress with
     | Progress.Rejected refusal -> check json "old original size refusal is preserved"
         (Lane_addon_exact.final_to_json (Lane_addon_exact.Call_final (Input_refused Input_capacity))) refusal.evidence
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> fail "old configuration acquired a successor");
    check json "old immutable capture is never replaced" old.request retained_old.request;
    let retained_current=original_record store current_capture in
    let child_id=match Progress.phase retained_current.progress with
      | Progress.Subdivided (_,intent) -> intent.request_id
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Rejected _ | Subdividing _ -> fail "current original never acquired its unique successor" in
    check bool "the actual owner completes the current original's child" true
      (List.exists (fun record -> record.Owner.request_id=child_id && is_finished record) (records store));
    let old_facts=match Capture.work old_capture with
      | Capture.Classification {batch;_} -> List.map (fun (pending:Ledger.pending_fact) -> pending.fact) batch.selected
      | Capture.Briefing _ -> fail "old original is not classification" in
    check bool "old selected facts are not reminted with the unrelated current work" true
      (List.for_all (fun (fact,_) -> not (List.mem fact old_facts)) (Ledger.dispositions (get (Ledger.load ~base_path))));
    check bool "the current continuation used the actual common provider" true (F.post_count server>0))
let ()=run "Actual Addon-backed production Curator owner" ["owner",[
  test_case "public owner uses real worker, semantic candidates and original terminal" `Quick test_actual_production_pipeline;
  test_case "actual Addon On wakes sources parked while Off" `Quick test_off_then_actual_metadata_on;
  test_case "actual output publication resumes the same original request" `Quick test_original_waits_for_actual_route_publication;
  test_case "unrelated source never remints a refused original" `Quick test_refused_identity_does_not_remint_on_unrelated_fact;
  test_case "finished source can return as new pending work after actual removal" `Quick test_finished_identity_readded_after_observed_removal;
  test_case "only the current semantic destination supplies a size successor" `Quick test_successor_frontier_ignores_an_old_semantic_destination;
  test_case "complete malformed original inventory blocks replacement" `Quick test_complete_discovery_blocks_malformed_original;
  test_case "new child requires fresh Off and semantic configuration authority" `Quick test_new_child_requires_fresh_configured_admission;
  test_case "new child rejects changed canonical worker inputs" `Quick test_new_child_rejects_changed_worker_inputs;
  test_case "existing successor intent recovers locally Off and completes after On" `Quick test_existing_intent_recovers_locally_off_then_runs_on;
  test_case "accepted retained host terminal commits Off without another provider" `Quick test_accepted_host_terminal_commits_off_without_worker]]
