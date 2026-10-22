(** Actual Curator worker restarts joined to the common host Exact HTTP flow.
    Providers are loopback fixtures; production Curator scheduling is not started. *)
open Alcotest
open Masc
module Capture = Workspace_memory_execution_capture
module Binding = Server_workspace_memory_addon_validation
module Exact = Lane_addon_exact
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request
module Briefing = Workspace_memory_briefing
module Hooks = Lane_addon_tool_hooks
module F = Exact_output_fixture
module Consumer = Server_workspace_memory_addon
module Json = Yojson.Safe.Util
let get = function Ok value -> value | Error detail -> fail detail
let owned value = get (Result.map_error Owner.error_to_string value)
let member = Json.member
let () = Mirage_crypto_rng_unix.use_default ()

type domain = Classification | Briefing
let resolution effective : Prompt_registry.prompt_resolution =
  {effective;source=Prompt_registry.Override;file_value=None;override_value=Some effective;
   file_path=None;file_exists=false;has_override=true}
let capture ~base_path domain =
  let workspace=get (Capture.observe_workspace ~base_path) in
  let destination : Capture.destination = {
    installation_id=Owner.installation_id (Owner.Configuration "curator");
    package_id=Binding.package_id;tool=Binding.tool;
    source_revision="actual-contract-fixture";configuration_revision="original-selection"} in
  let request_id=Capture.Request_id.fresh () in
  match domain with
  | Classification ->
    let claim="An original source-bound interpretation" in
    let fact : Ledger.pending_fact = {
      fact=Ledger.Ordinary {keeper_id="writer";claim_sha256=Store.digest claim};claim} in
    let prompt=resolution "Classify this original batch: {{workspace_memory_changes}}" in
    let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_curator
      prompt ["workspace_memory_changes",Yojson.Safe.to_string input] in
    let batch=match Request.prepare ~neighbor_limit:0 ~render ~ledger:Ledger.empty ~current:[fact] ~pending:[fact]
      |> Result.map_error Request.error_to_string |> get with
      | Some batch -> batch | None -> fail "expected an original classification batch" in
    let capture=get (Capture.classification ~request_id ~workspace ~destination ~prompt ~ledger:Ledger.empty ~batch) in
    let good=`Assoc ["decisions",`List [`Assoc ["fact_id",`String (Request.fact_id fact.fact);
      "kind",`String "create_claim";"value",`String "An original host-validated claim"]]] in
    capture,good,`Assoc ["decisions",`List []]
  | Briefing ->
    let sources=List.map (fun id -> {Briefing.id;kind=Briefing.Claim;text="Original source " ^ id}) ["a";"b"] in
    let prompt=resolution "Summarize the original pass: {{workspace_memory_briefing}}" in
    let render input=Prompt_registry.render_resolved_prompt_template Prompt_names.workspace_memory_briefing
      prompt ["workspace_memory_briefing",Yojson.Safe.to_string input] in
    let full=match get (Briefing.prepare ~sources ~contract:(Briefing.contract ~template:prompt.effective)
      ~render Briefing.empty) with
      | Briefing.Prepared batch -> batch
      | Briefing.Unchanged | Briefing.Cleanup _ -> fail "expected an original briefing pass" in
    let batch=match get (Briefing.narrow ~render full) with
      | Some batch -> batch | None -> fail "expected an original whole-source prefix" in
    get (Capture.briefing ~request_id ~workspace ~destination ~prompt ~batch),
      `Assoc ["briefing",`String "Only the original selected source was summarized"],
      `Assoc ["briefing",`String " "]

let call name arguments = `Assoc ["method",`String "tools/call";
  "params",`Assoc ["name",`String name;"arguments",arguments]]
let admitted arguments = call "lane_call" (`Assoc ["tool",`String Binding.tool;
  "arguments",arguments;"caller",`Assoc ["kind",`String "operator"]])

let scenario domain () =
  let base_path=Filename.temp_dir "curator-addon-contract-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path) (fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some (Filename.concat base_path "config")) (fun () ->
  F.with_official_client_runtimes (fun () ->
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let net=Eio.Stdenv.net env and clock=Eio.Stdenv.clock env in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Masc_test_deps.init_eio_clock env;
    Process_eio.init ~cwd_default:(Eio.Stdenv.cwd env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock;
    Fun.protect ~finally:(fun () -> Process_eio.reset_for_testing ();Fs_compat.clear_fs ()) (fun () ->
    Eio_context.with_test_env ~sw ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
      let package=Lane_addon_manifest.load ~path:"../addons/workspace-curator/lane.toml"
        |> Result.map_error Lane_addon_manifest.error_to_string |> get in
      let worker_state=Filename.concat base_path "worker-state" in Unix.mkdir worker_state 0o700;
      let rpc operation =
        let messages=[`Assoc ["method",`String "initialize";"params",`Assoc []];operation] in
        let input=List.mapi (fun index operation ->
          Yojson.Safe.to_string (`Assoc (["jsonrpc",`String "2.0";"id",`Int (index+1)] @ Json.to_assoc operation)))
          messages |> String.concat "\n" in
        let status,stdout,stderr=Process_eio.run_argv_with_stdin_and_status_split ~stdin_content:(input ^ "\n")
          ["python3";Filename.concat package.directory "server.py";"--state";worker_state] in
        (match status with
         | Unix.WEXITED 0 -> ()
         | Unix.WEXITED code -> failf "worker exited %d: %s" code stderr
         | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> failf "worker signal %d" signal);
        check string "worker protocol has no stderr diagnostics" "" stderr;
        match String.split_on_char '\n' stdout |> List.filter (fun line -> line<>"") |> List.map Yojson.Safe.from_string with
        | [_;reply] -> member "result" reply
        | _ -> fail "initialization and original worker request each need one reply" in
      let tool=rpc (`Assoc ["method",`String "tools/list"]) |> member "tools" |> Json.to_list
        |> List.map (fun json -> Mcp_protocol.Mcp_types.tool_of_yojson json |> get)
        |> List.find (fun (tool : Mcp_protocol.Mcp_types.tool) -> tool.name=Binding.tool) in
      let hooks=Hooks.prepare ~hooks:package.tool_hooks tool |> get in
      let invoke arguments =
        ignore (get (Hooks.before_call hooks arguments));
        let reply=rpc (admitted arguments) |> Mcp_protocol.Mcp_types.tool_result_of_yojson |> get in
        ignore (get (Hooks.after_call hooks reply));
        check bool "actual worker accepted the admitted caller" false (reply.is_error=Some true);
        match reply.structured_content with Some body -> body | None -> fail "missing structured original worker state" in
      let original,good,bad=capture ~base_path domain in
      let store=Store.create ~root:(Filename.concat base_path "host-store") in
      let original_id=Capture.Request_id.to_string (Capture.request_id original) in
      let destination=Capture.destination original in
      owned (Owner.retain ~store ~scope:Capture.scope ~request_id:original_id
        ~installation_id:destination.installation_id ~package_id:destination.package_id ~tool:destination.tool
        ~request:(Capture.to_json original));
      let reopened=Store.create ~root:(Store.root store) in
      let retained=match owned (Owner.load ~store:reopened ~scope:Capture.scope ~request_id:original_id) with
        | Some value -> value | None -> fail "original host capture must precede the worker RPC" in
      let original=get (Capture.restore ~workspace:(get (Capture.observe_workspace ~base_path)) retained) in
      let exact=get (Binding.request original) in
      let read=`Assoc ["kind",`String "read";"request_id",`String original_id] in
      check bool "original worker absence is observed before admission" true
        (member "state" (invoke read)=`String "absent");
      let call_worker ~arguments =
        ignore (get (Hooks.before_call hooks arguments));
        let reply=rpc (admitted arguments) |> Mcp_protocol.Mcp_types.tool_result_of_yojson |> get in
        ignore (get (Hooks.after_call hooks reply)); Ok reply in
      let consume call=Consumer.For_testing.resume ~store:(Store.create ~root:(Store.root store))
        ~base_path ~request_id:original_id ~call |> Result.map_error Consumer.error_to_string |> get in
      (match consume call_worker with
       | Consumer.Awaiting (Consumer.Worker_pending,_) -> ()
       | _ -> fail "production consumer must retain and submit the original to the actual worker");
      let listed=rpc (call "lane_host_requests" (`Assoc [])) |> member "structuredContent" |> member "requests" |> Json.to_list in
      let restored=match listed with [json] -> get (Exact.request_of_json json)
        | _ -> fail "exactly the original host request must survive worker restart" in
      check string "worker preserves the complete host request identity and bytes"
        (Exact.digest exact) (Exact.digest restored);
      let output=List.find (fun (output : Lane_addon_types.exact_output) -> output.name=restored.output) package.exact_outputs in
      check bool "actual package baseline equals the original domain contract" true
        (get (Lane_addon_action.canonical output.schema)=get (Lane_addon_action.canonical (Capture.output_schema original)));
      ignore (get (Exact.schema_for_request ~output restored));
      let wrong=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response bad)) in
      let right=F.start_server ~sw ~net ~clock (F.Reply (F.openai_response good)) in
      ignore (F.publish_registry ~lane_id:("curator/" ^ restored.output)
        ~slot_ids:["incomplete";"original-complete"]
        (F.resolver_snapshot ~source:base_path [{F.id="incomplete";base_url=wrong.base_url};
          {F.id="original-complete";base_url=right.base_url}]) : Runtime_exact_output_registry.t);
      let run store=get (Exact.run ~store ~declaration_id:"curator" ~package
        ~runner:(Server_lane_addon_exact.runner ~base_path)
        ~validate_request:(Server_lane_addon_exact.validate_request ~base_path) restored) in
      let final=match run reopened with
        | Exact.Final (Exact.Call_final (Exact.Answered {slot="original-complete";_}) as final) -> final
        | Exact.Final _ | Exact.Not_final _ -> fail "original semantic rejection must reach the next HTTP candidate" in
      let result=Exact.final_to_json final in
      let deliver ()=rpc (call "lane_host_result" (`Assoc ["request_id",`String original_id;"result",result]))
        |> member "structuredContent" in
      check bool "actual restarted worker acknowledges the original terminal" true (deliver ()=`Assoc ["accepted",`Bool true]);
      let finished=invoke read in
      check bool "terminal survives another process restart" true (member "state" finished=`String "finished");
      let returned=get (Exact.final_of_json ~schema:(Capture.output_schema original) (member "result" finished)) in
      (match returned with
       | Exact.Call_final (Exact.Answered {output;_}) ->
         (match get (Capture.validate_output original (Exact.checked_json output)) with
          | Capture.Classification_commit ledger ->
            check int "full original classification is an expected host commit" 1 (List.length (Ledger.dispositions ledger))
          | Capture.Briefing_commit partial ->
            (match Capture.work original with
             | Capture.Classification _ -> fail "domain kind changed"
             | Capture.Briefing batch ->
               check int "original remaining source survives the worker round trip" 1 (Briefing.remaining_count batch));
            let sources=List.map (fun id -> {Briefing.id;kind=Briefing.Claim;text="Original source " ^ id}) ["a";"b"] in
            (match Briefing.observe ~sources ~contract:(Briefing.contract
              ~template:"Summarize the original pass: {{workspace_memory_briefing}}") partial with
             | Briefing.Missing -> ()
             | Briefing.Current _ | Briefing.Stale _ -> fail "a partial original pass must not publish"))
       | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
       | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> fail "original answered terminal changed");
      check bool "duplicate delivery is acknowledged without replacing terminal" true (deliver ()=`Assoc ["accepted",`Bool true]);
      (match consume call_worker with
       | Consumer.Judgment {expected=Capture.Classification_commit _;_} when domain=Classification -> ()
       | Consumer.Judgment {expected=Capture.Briefing_commit _;_} when domain=Briefing -> ()
       | _ -> fail "consumer must retain the fully validated original domain judgment");
      (match consume (fun ~arguments:_ -> fail "retained judgment must need no live worker") with
       | Consumer.Judgment _ -> () | _ -> fail "retained original judgment was not restored");
      ignore (run (Store.create ~root:(Store.root store)) : Exact.attempt);
      check int "semantic rejection ran only once" 1 (F.post_count wrong);
      check int "retained host answer never dispatches again" 1 (F.post_count right);
      let listed=rpc (call "lane_host_requests" (`Assoc [])) |> member "structuredContent" |> member "requests" in
      check bool "finished original request is never relisted" true (listed=`List []);
      let current=match owned (Owner.load ~store:(Store.create ~root:(Store.root store))
        ~scope:Capture.scope ~request_id:original_id) with
        | Some current -> current | None -> fail "original owner disappeared after worker completion" in
      check bool "production consumer retained judgment without committing the domain" true
        (match Lane_addon_request_progress.phase current.progress with
         | Lane_addon_request_progress.Judged _ -> true
         | Lane_addon_request_progress.Captured | Admission_wait _ | Dispatch_pending _ | Committing _
         | Commit_unknown _ | Finished _ | Conflicted _ | Rejected _ -> false)
    ))))))))

let with_original_consumer f =
  let base_path=Filename.temp_dir "curator-original-admission-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    Eio_main.run (fun _ ->
      let original,good,bad=capture ~base_path Classification in
      let request_id=Capture.Request_id.to_string (Capture.request_id original) in
      let store=Store.create ~root:(Filename.concat base_path "host-store") in
      let destination=Capture.destination original in
      owned (Owner.retain ~store ~scope:Capture.scope ~request_id
        ~installation_id:destination.installation_id ~package_id:destination.package_id ~tool:destination.tool
        ~request:(Capture.to_json original));
      let resume call=Consumer.For_testing.resume ~store:(Store.create ~root:(Store.root store))
        ~base_path ~request_id ~call in
      let reply state fields=Ok { (Mcp_protocol.Mcp_types.tool_result_of_text "original worker state") with
        structured_content=Some (`Assoc (["request_id",`String request_id;"state",`String state] @ fields)) } in
      let rec files path=let stat=Unix.lstat path in match stat.Unix.st_kind with
        | Unix.S_DIR -> Sys.readdir path |> Array.to_list |> List.sort String.compare
          |> List.concat_map (fun name -> files (Filename.concat path name))
        | Unix.S_REG -> [path,stat.st_dev,stat.st_ino,stat.st_size,stat.st_mtime,
            In_channel.with_open_bin path In_channel.input_all]
        | Unix.(S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK) -> fail "unexpected original fixture store entry" in
      let journal_snapshot ()=files (Store.root store) in
      f ~resume ~reply ~request_id ~good ~bad ~journal_snapshot))

let test_capacity_retries_original_but_lost_admission_never_submits_again () =
  with_original_consumer (fun ~resume ~reply ~request_id ~good ~bad ~journal_snapshot:_ ->
    let submitted=ref [] and reads=ref 0 in
    let call ~arguments =
      match member "kind" arguments with
      | `String "read" -> incr reads;reply "absent" []
      | `String "submit" ->
        submitted:=member "request" arguments :: !submitted;
        if List.length !submitted=1 then reply "capacity_wait" []
        else Error (Consumer.Uncertain "original admission reply was lost")
      | _ -> fail "unexpected worker command" in
    let accepted value=get (Result.map_error Consumer.error_to_string value) in
    (match accepted (resume call) with
     | Consumer.Awaiting (Consumer.Capacity,_) -> () | _ -> fail "explicit pre-admission capacity must wait");
    (match accepted (resume call) with
     | Consumer.Awaiting (Consumer.Worker_unknown,_) -> () | _ -> fail "lost admission must remain uncertain");
    (match accepted (resume call) with
     | Consumer.Awaiting (Consumer.Missing_after_dispatch,_) -> () | _ -> fail "absence cannot clear dispatch uncertainty");
    check int "uncertain and absent restart never sends a third admission" 2 (List.length !submitted);
    check int "every restart read the original before considering admission" 3 !reads;
    (match !submitted with
     | [second;first] ->
       check bool "capacity admission keeps the full original input" true (first=second);
       check string "capacity admission keeps the same original ID" request_id (member "request_id" second |> Json.to_string)
     | _ -> fail "expected exactly two admission attempts");
    let final output=`Assoc ["status",`String "answered";"slot",`String "original";"output",output] in
    let returned output ~arguments:_=reply "finished" ["result",final output] in
    check bool "schema-valid but domain-invalid late answer cannot become a judgment" true
      (Result.is_error (resume (returned bad)));
    (match accepted (resume (returned good)) with
     | Consumer.Judgment _ -> () | _ -> fail "late original complete answer must remain consumable");
    (match accepted (resume (fun ~arguments:_ -> fail "retained judgment replay reached the worker")) with
     | Consumer.Judgment _ -> () | _ -> fail "same host judgment must survive a fresh handle"))

let test_terminal_unknown_survives_host_restart_without_worker_or_replacement () =
  with_original_consumer (fun ~resume ~reply ~request_id:_ ~good:_ ~bad:_ ~journal_snapshot:_ ->
    let call ~arguments=match member "kind" arguments with
      | `String "read" -> reply "absent" []
      | `String "submit" -> reply "finished" ["result",`Assoc ["status",`String "outcome_unknown"]]
      | _ -> fail "unexpected worker command" in
    let accepted value=get (Result.map_error Consumer.error_to_string value) in
    let assert_unknown=function
      | Consumer.Terminal (Exact.Outcome_unknown,_) -> ()
      | _ -> fail "terminal uncertainty cannot become capacity or a fresh request" in
    assert_unknown (accepted (resume call));
    assert_unknown (accepted (resume (fun ~arguments:_ -> fail "terminal unknown was dispatched again"))))

let test_original_output_limit_is_retained_without_worker_replay_or_a_judgment () =
  with_original_consumer (fun ~resume ~reply ~request_id:_ ~good:_ ~bad:_ ~journal_snapshot ->
    let terminal=`Assoc ["status",`String "output_limit_reached";"detail",`String "original provider limit"] in
    let call ~arguments=match member "kind" arguments with
      | `String "read" -> reply "absent" []
      | `String "submit" -> reply "finished" ["result",terminal]
      | _ -> fail "unexpected original worker command" in
    let verify result=match result |> Result.map_error Consumer.error_to_string |> get with
      | Consumer.Terminal (Exact.Call_final (Exact.Output_limit_reached _),record) ->
        (match Lane_addon_request_progress.phase record.progress with
         | Lane_addon_request_progress.Rejected {stage=Execution;evidence} ->
           check bool "typed original terminal is retained as execution refusal" true (Yojson.Safe.equal evidence terminal)
         | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
         | Finished _ | Conflicted _ | Rejected {stage=Before_dispatch;_} -> fail "a limit cannot become a domain judgment")
      | Consumer.Terminal _ | Consumer.Awaiting _ | Consumer.Judgment _ | Consumer.Commit_pending _ | Consumer.Settled _ ->
        fail "the original provider output limit changed meaning" in
    verify (resume call);
    let original_files=journal_snapshot () in
    verify (resume (fun ~arguments:_ -> fail "a terminal original must not reach the worker again"));
    check bool "restoring the terminal does not add a new journal fact" true (original_files=journal_snapshot ()))

let test_repeated_observation_retains_original_history_without_another_fact () =
  with_original_consumer (fun ~resume ~reply ~request_id:_ ~good:_ ~bad:_ ~journal_snapshot ->
    let first ~arguments=match member "kind" arguments with
      | `String "read" -> reply "absent" []
      | `String "submit" -> reply "pending" []
      | _ -> fail "unexpected admission command" in
    let observation call=match resume call |> Result.map_error Consumer.error_to_string |> get with
      | Consumer.Awaiting (_,record) -> Lane_addon_request_progress.to_json record.progress
      | Consumer.Judgment _ | Consumer.Terminal _ | Consumer.Commit_pending _ | Consumer.Settled _ ->
        fail "expected an original execution observation" in
    let initial=observation first in
    let initial_files=journal_snapshot () in
    let pending ~arguments:_=reply "pending" [] in
    List.iter (fun () -> check bool "unchanged pending does not append another fact" true
      (Yojson.Safe.equal initial (observation pending));
      check bool "equal pending preserves actual journal file identity and bytes" true
        (initial_files=journal_snapshot ())) [();();()];
    let unknown detail ~arguments:_=Error (Consumer.Uncertain detail) in
    let lost=observation (unknown "original transport lost") in
    let lost_files=journal_snapshot () in
    check bool "changed observation is retained" false (Yojson.Safe.equal initial lost);
    List.iter (fun () -> check bool "equal uncertainty retains its first evidence" true
      (Yojson.Safe.equal lost (observation (unknown "original transport lost")));
      check bool "equal uncertainty preserves actual journal file identity and bytes" true
        (lost_files=journal_snapshot ())) [();();()];
    let changed=observation (unknown "another transport failure") in
    check bool "changed uncertainty evidence is not discarded" false (Yojson.Safe.equal lost changed);
    let absent=observation (fun ~arguments:_ -> reply "absent" []) in
    let absent_files=journal_snapshot () in
    check bool "authoritative absence is a distinct fact" false (Yojson.Safe.equal absent changed);
    check bool "repeated absence preserves the original dispatch uncertainty" true
      (Yojson.Safe.equal absent (observation (fun ~arguments:_ -> reply "absent" [])));
    check bool "equal absence preserves actual journal file identity and bytes" true
      (absent_files=journal_snapshot ());
    check bool "return to pending after uncertainty is another fact" false
      (Yojson.Safe.equal absent (observation pending)))

let () = run "Workspace Curator actual worker and common Exact contract" ["original requests",[
  test_case "classification survives worker restart and full semantic HTTP acceptance" `Quick (scenario Classification);
  test_case "briefing retains its original partial pass across worker and host reads" `Quick (scenario Briefing);
  test_case "only explicit capacity retries original admission; late result survives uncertainty" `Quick
    test_capacity_retries_original_but_lost_admission_never_submits_again;
  test_case "terminal unknown survives host restart without worker or replacement" `Quick
    test_terminal_unknown_survives_host_restart_without_worker_or_replacement;
  test_case "original output limit survives without worker replay or a domain judgment" `Quick
    test_original_output_limit_is_retained_without_worker_replay_or_a_judgment;
  test_case "equal pending unknown and absent observations do not grow original history" `Quick
    test_repeated_observation_retains_original_history_without_another_fact]]
