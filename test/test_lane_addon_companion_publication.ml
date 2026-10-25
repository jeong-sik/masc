(** Real private publication files, durable recipient queue and canonical
    observation reads. No private worker transport, Browser or Keeper turn runs. *)
open Alcotest
open Masc
module O=Lane_addon_companion_origin
module P=Lane_addon_companion_publication
module D=Keeper_addon_publication
module Q=Keeper_event_queue
module R=Keeper_registry_event_queue
let origin_ok=function Ok x -> x | Error e -> fail (O.error_to_string e)
let pub_ok=function Ok x -> x | Error e -> fail (P.error_to_string e)
let delivery_ok=function Ok x -> x | Error e -> fail (D.error_to_string e)
let string_ok=function Ok x -> x | Error e -> fail e
let keeper="publication-owner"
let publication_id="0b000000-0000-4000-8000-000000000031"
let operation_id="0b000000-0000-4000-8000-000000000032"
let output_schema=`Assoc ["type",`String "object";"additionalProperties",`Bool false;
  "required",`List (List.map (fun s -> `String s) ["operation_id";"phase";"fill_submitted";"website_login_verified"]);
  "properties",`Assoc ["operation_id",`Assoc ["type",`String "string"];
    "phase",`Assoc ["type",`String "string";"enum",`List (List.map (fun s -> `String s)
      ["approval_ready";"fill_submitted";"outcome_unknown"])];
    "fill_submitted",`Assoc ["type",`String "boolean"];
    "website_login_verified",`Assoc ["type",`String "boolean";"enum",`List [`Bool false]]]]
let output ?(operation=operation_id) phase submitted=`Assoc ["operation_id",`String operation;"phase",`String phase;
  "fill_submitted",`Bool submitted;"website_login_verified",`Bool false]
let notice ?(id=publication_id) ?(operation=operation_id) ?(kind="attention_required") ?(phase="approval_ready") ?(submitted=false) () =
  P.event ~output_schema (`Assoc ["publication_id",`String id;
    "kind",`String kind;"output",output ~operation phase submitted]) |> pub_ok
let with_origin run () = Eio_main.run (fun env ->
  let root=Filename.temp_dir "companion-publication-" "" |> Unix.realpath in
  let fs=Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Fun.protect ~finally:(fun () ->
    Keeper_registry.For_testing.unregister ~base_path:root keeper;
    Fs_compat.clear_fs ();
    Fs_compat.remove_tree root) (fun () ->
    let config=Workspace.default_config root in
    ignore (Workspace.init config ~agent_name:(Some "fixture-operator"));
    let meta=Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name",`String keeper;"activation_mode",`String "manual"]) |> string_ok in
    ignore (Keeper_meta_store.replace_snapshot config meta |> string_ok);
    ignore (Keeper_registry.register_offline ~base_path:root keeper meta);
    let trace=Random_id.uuid_v7 () in
    let turn=Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:42 in
    let context=Keeper_tool_call_log_context.{empty_turn_context with agent_name=Some keeper;
      trace_id=Some trace;keeper_turn_id=Some 42;task_id=Some "task-original"} in
    let channel=Keeper_continuation_channel.dashboard ~thread_id:"original-thread" |> string_ok in
    let source=O.source ~keeper_name:keeper ~turn_ref:(Some turn) ~tool_use_id:(Some "original-login-use")
      ~trace_id:(Some trace) ~source_context:(Some context) ~channel:(Some channel) |> origin_ok in
    let destination=O.{instance_id="original-provider";package_id="onepassword";package_revision="0.1.0";
      tool="onepassword_login";declaration_id=Some "original-declaration";configuration_revision=Some "original-revision"} in
    let origin=match O.reserve ~fs ~config ~source ~destination
      ~arguments:(`Assoc ["goal",`String "PRIVATE_INPUT_MARKER"]) |> origin_ok with
      | O.Fresh r -> r | Existing _ -> fail "fixture did not create original source" in
    run env fs config origin))
let path origin = Filename.concat (Filename.concat (Filename.concat (Filename.concat
  (Common.masc_dir_from_base_path ~base_path:origin.O.base_path) "lane-addons")
  "companion-publications") origin.id) (publication_id ^ ".json")
let read path=In_channel.with_open_bin path In_channel.input_all
let write path bytes=Out_channel.with_open_bin path (fun out -> output_string out bytes)
let retain fs config origin event=P.retain ~fs ~config ~origin ~output_schema ~event
let deliver fs config origin event=D.deliver ~fs ~config ~origin ~output_schema ~event
let pending config=R.pending_selections_result ~base_path:config.Workspace.base_path keeper |> string_ok
let only config=match pending config with [s] -> s | [] | _::_ -> fail "expected one original queue source"
let payload (selection:Keeper_event_queue_state.pending_selection)=match selection.source.Q.payload with
  | Q.Addon_operation_changed change -> change
  | Board_signal _ | Board_attention _ | Bootstrap | Fusion_completed _ | Schedule_due _
  | Connector_attention _ | Hitl_resolved _ | Ask_answered _ | Completion_authority_rejected _
  | Task_outcome _ | Task_cancelled _ | Workspace_message _ | Delegate_completed _
  | Composition_completed _ | Tool_result_ready _ | Owned_job_completed _ -> fail "another source was queued"
let canonical_retention _env fs config origin =
  let first=retain fs config origin (notice ()) |> pub_ok in
  check bool "origin index returns exact immutable source" true (O.find ~config ~id:origin.id=Ok (Some origin));
  let bytes=read (path origin) in
  let again=retain fs config origin (notice ()) |> pub_ok in
  check bool "same publication reconciles original record" true (again=first);
  let changed=notice ~kind:"effect_submitted" ~phase:"fill_submitted" ~submitted:true () in
  check bool "same publication ID refuses changed payload" true (retain fs config origin changed=Error P.Binding_conflict);
  check string "conflict never rewrites original" bytes (read (path origin));
  check bool "original publication strictly reloads" true
    (P.find ~config ~origin_id:origin.id ~publication_id=Ok first)
let schema_refusal _env _fs _config origin =
  let raw=P.event_json (notice ()) in
  let fields=match raw with `Assoc fields -> fields | _ -> fail "event object missing" in
  let bad=`Assoc (("raw_text",`String "PRIVATE_PAYLOAD_MARKER")::fields) in
  check bool "raw worker prose is not a public envelope" true (P.event ~output_schema bad=Error P.Invalid_event);
  let private_output=match output "approval_ready" false with
    | `Assoc fields -> `Assoc (("credential",`String "PRIVATE_PAYLOAD_MARKER")::fields)
    | _ -> fail "output object missing" in
  check bool "unknown private field fails original closed schema" true
    (P.event ~output_schema (`Assoc (("output",private_output)::List.remove_assoc "output" fields))=Error P.Schema_rejected);
  let open_schema=match output_schema with `Assoc fields -> `Assoc (List.remove_assoc "additionalProperties" fields)
    | _ -> fail "schema missing" in
  check bool "open output schema refuses" true (P.event ~output_schema:open_schema raw=Error P.Schema_rejected);
  check bool "validation creates no publication directory" false (Sys.file_exists (Filename.dirname (path origin)))
let durable_queue_and_consumption _env fs config origin =
  let event=notice () in
  deliver fs config origin event |> delivery_ok;
  let selection=only config in
  let change=payload selection in
  check (option string) "original Task survives" (Some "task-original") change.ao_source.task_id;
  check bool "original conversation survives" true
    (Keeper_continuation_channel.same_route origin.source.channel change.ao_channel);
  check bool "queue wire roundtrips exact source" true
    (Q.stimulus_of_yojson (Q.stimulus_to_yojson selection.source)=Ok selection.source);
  let observed=Keeper_world_observation.pending_board_event_of_addon_operation_change
    ~base_path:config.base_path ~keeper_name:keeper ~arrived_at:selection.source.arrived_at change |> pub_ok in
  let preview=Yojson.Safe.from_string observed.preview in
  check bool "observation contains only committed public event" true
    (Yojson.Safe.Util.member "publication" preview=P.event_json event);
  let fields=Keeper_unified_prompt.For_testing.board_event_fields {observed with preview=""} in
  check string "prompt metadata preserves original publication" publication_id (List.assoc "publication_id" fields);
  check bool "full public state survives ordinary preview shortening" true
    (Yojson.Safe.from_string (List.assoc "publication" fields)=P.event_json event);
  check bool "prompt source is the canonical original" true
    (Yojson.Safe.from_string (List.assoc "source" fields)=Keeper_owned_job_identity.source_to_json change.ao_source);
  Keeper_reaction_ledger.record_event_queue_stimulus ~base_path:config.base_path ~keeper_name:keeper selection.source;
  let delivered ()=match Keeper_reaction_ledger.event_queue_delivery_seen_for_source_strict_result
      ~not_before:0. ~base_path:config.base_path ~keeper_name:keeper ~post_id:selection.source.post_id
      ~stimulus_kind:Keeper_reaction_ledger.Addon_operation_changed with
    | Ok seen -> seen
    | Error error -> fail (Keeper_reaction_ledger.strict_delivery_evidence_error_to_string error) in
  check bool "recorded stimulus alone is not delivery evidence" false (delivered ());
  ignore (Keeper_reaction_ledger.summary_for_keeper ~base_path:config.base_path ~keeper_name:keeper
    ~limit:(List.length (pending config)));
  check bool "raw original input was never copied into public observation" true
    (not (List.mem "PRIVATE_INPUT_MARKER" (String.split_on_char '"' observed.preview)));
  let bytes=read (path origin) in
  deliver fs config origin event |> delivery_ok;
  check int "lost producer ACK does not duplicate pending source" 1 (List.length (pending config));
  (match R.terminalize_pending_turn_completed_result ~base_path:config.base_path keeper
      ~applied_at:(Unix.gettimeofday ()) ~selection with
   | Ok (R.Turn_source_acked _) -> ()
   | Ok R.Turn_selection_withdrawn -> fail "original source was withdrawn"
   | Error detail -> fail detail);
  check bool "terminal receipt proves exact source delivery" true (delivered ());
  deliver fs config origin event |> delivery_ok;
  check int "consumed source does not reappear after producer ACK loss" 0 (List.length (pending config));
  check string "queue admission and consumption preserve publication bytes" bytes (read (path origin))
let unreadable_or_foreign_source _env fs config origin =
  let event=notice () in
  deliver fs config origin event |> delivery_ok;
  let selection=only config in
  let change=payload selection in
  let bytes=read (path origin) in
  write (path origin) "{";
  check bool "corrupt publication is not an empty consumed result" true
    (Keeper_world_observation.pending_board_event_of_addon_operation_change
      ~base_path:config.base_path ~keeper_name:keeper ~arrived_at:selection.source.arrived_at change=Error P.Corrupt);
  check bool "corrupt retry refuses without repair" true (retain fs config origin event=Error P.Corrupt);
  check string "corrupt bytes are retained" "{" (read (path origin));
  check int "canonical read failure leaves source durable" 1 (List.length (pending config));
  write (path origin) bytes;
  let forged={change with ao_source={change.ao_source with task_id=Some "later-task"}} in
  check bool "later Task cannot borrow original output" true
    (Keeper_world_observation.pending_board_event_of_addon_operation_change
      ~base_path:config.base_path ~keeper_name:keeper ~arrived_at:selection.source.arrived_at forged=Error P.Binding_conflict);
  check bool "another Keeper cannot consume original output" true
    (Keeper_world_observation.pending_board_event_of_addon_operation_change
      ~base_path:config.base_path ~keeper_name:"other-keeper" ~arrived_at:selection.source.arrived_at change=Error P.Binding_conflict)
let unsafe_record _env fs config origin =
  retain fs config origin (notice ()) |> pub_ok |> ignore;
  Unix.chmod (path origin) 0o644;
  check bool "unsafe retained record refuses admission" true
    (deliver fs config origin (notice ())=Error (D.Publication_failed P.Unavailable));
  check int "unsafe permissions are not repaired" 0o644 ((Unix.lstat (path origin)).Unix.st_perm land 0o777);
  check int "unsafe publication created no queue source" 0 (List.length (pending config));
  Unix.chmod (path origin) 0o600;
  let linked=Filename.concat origin.base_path "linked" in
  Unix.link (path origin) linked;
  check bool "hard linked record refuses read" true
    (P.find ~config ~origin_id:origin.id ~publication_id=Error P.Unavailable)
let another_origin fs config original =
  let trace=Random_id.uuid_v7 () in
  let turn=Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:43 in
  let context=Keeper_tool_call_log_context.{empty_turn_context with agent_name=Some keeper;
    trace_id=Some trace;keeper_turn_id=Some 43;task_id=Some "task-other"} in
  let channel=Keeper_continuation_channel.dashboard ~thread_id:"other-thread" |> string_ok in
  let source=O.source ~keeper_name:keeper ~turn_ref:(Some turn) ~tool_use_id:(Some "other-login-use")
    ~trace_id:(Some trace) ~source_context:(Some context) ~channel:(Some channel) |> origin_ok in
  match O.reserve ~fs ~config ~source ~destination:original.O.destination
      ~arguments:(`Assoc ["goal",`String "other original task"]) |> origin_ok with
  | O.Fresh origin -> origin | Existing _ -> fail "other invocation was not fresh"
let with_intake env config run = Eio.Switch.run (fun sw ->
  let meta=match Keeper_meta_store.read_meta config keeper |> string_ok with
    | Some meta -> meta | None -> fail "canonical fixture Keeper missing" in
  let ctx : _ Keeper_types_profile.context = {config;agent_name="publication-intake-fixture";
    sw;clock=Eio.Stdenv.clock env;proc_mgr=None;net=None;
    publication_recovery_provider=Masc_test_deps.non_runtime_publication_recovery_provider} in
  run (fun () -> Keeper_heartbeat_stimulus_intake.heartbeat_event_intake ~ctx
    ~meta_after_triage:meta ~pending_board_events:[]))
let selected intake=Keeper_heartbeat_source_batch.selections
  intake.Keeper_heartbeat_stimulus_intake.source_batch
let routed intake=Keeper_heartbeat_source_batch.for_turn ~reactive:true intake.Keeper_heartbeat_stimulus_intake.source_batch
  |> Keeper_heartbeat_source_batch.wake |> Keeper_unified_turn.continuation_channel_of_wake
let check_route label channel intake=check bool label true
  (match routed intake with Some actual -> Keeper_continuation_channel.same_route actual channel | None -> false)
let ack_fixture_batch config intake=
  (* Simulated completed-turn receipts exercise durable deferral only; no model
     or actual Keeper turn is executed by these controlled intake fixtures. *)
  List.iter (fun selection -> match R.terminalize_pending_turn_completed_result
      ~base_path:config.Workspace.base_path keeper ~applied_at:(Unix.gettimeofday ()) ~selection with
    | Ok (R.Turn_source_acked _) -> ()
    | Ok R.Turn_selection_withdrawn -> fail "fixture source unexpectedly withdrawn"
    | Error detail -> fail detail) (selected intake)
let bootstrap config ~urgency ~arrived_at =
  R.enqueue_durable_result ~base_path:config.Workspace.base_path keeper
    Q.{post_id="independent-bootstrap";urgency;arrived_at;payload=Bootstrap} |> string_ok
let invocation_batches env fs config origin = with_intake env config (fun intake ->
  let other=another_origin fs config origin in
  deliver fs config origin (notice ()) |> delivery_ok;
  deliver fs config other (notice ~operation:"0b000000-0000-4000-8000-000000000035" ()) |> delivery_ok;
  deliver fs config origin (notice ~id:"0b000000-0000-4000-8000-000000000033"
    ~kind:"effect_submitted" ~phase:"fill_submitted" ~submitted:true ()) |> delivery_ok;
  bootstrap config ~urgency:Q.Low ~arrived_at:0.;
  let first=intake () in
  check int "same original invocation shares one intake" 2 (List.length (selected first));
  List.iter (fun selection -> let change=payload selection in
    check string "only original invocation selected" origin.O.id change.ao_origin_id;
    check (option string) "original task is retained" (Some "task-original") change.ao_source.task_id) (selected first);
  check_route "other task and general event cannot erase original route" origin.source.channel first;
  check int "unselected sources remain durable before any completion" 4 (List.length (pending config));
  ack_fixture_batch config first;
  check int "simulated completion ACKs only its exact source group" 2 (List.length (pending config));
  let second=intake () in
  check int "other invocation gets its own intake" 1 (List.length (selected second));
  check_route "other invocation retains its own conversation" other.source.channel second;
  ack_fixture_batch config second;
  let third=intake () in
  check bool "general source remains for its own turn" true
    (match selected third with [selection] -> selection.source.payload=Q.Bootstrap | []|_::_ -> false);
  check bool "general source does not borrow a conversation" true (routed third=None))
let general_source_precedes_addon env fs config origin = with_intake env config (fun intake ->
  deliver fs config origin (notice ()) |> delivery_ok;
  bootstrap config ~urgency:Q.Immediate ~arrived_at:0.;
  let first=intake () in
  check bool "first admitted ordinary source excludes companion notice" true
    (match selected first with [selection] -> selection.source.payload=Q.Bootstrap | []|_::_ -> false);
  check int "deferred companion remains pending" 2 (List.length (pending config));
  ack_fixture_batch config first;
  let second=intake () in
  check int "companion admits on its own later turn" 1 (List.length (selected second));
  check_route "ordinary source never strips later companion route" origin.source.channel second)
let retired_tool_result_does_not_anchor_batch env fs config origin = with_intake env config (fun intake ->
  (* An inactive receipt hint is synthetic; the real queue/intake retires it
     without acknowledging any Codex result or the companion publication. *)
  let receipt_id=String.make 64 'a' in
  R.enqueue_durable_result ~base_path:config.Workspace.base_path keeper
    Q.{post_id="keeper-tool-result:" ^ receipt_id;urgency=Immediate;arrived_at=0.;
       payload=Tool_result_ready receipt_id} |> string_ok;
  deliver fs config origin (notice ()) |> delivery_ok;
  check bool "inactive tool result hint is first in the durable queue" true
    (match pending config with
     | first::_ -> first.source.payload=Q.Tool_result_ready receipt_id
     | [] -> false);
  let admitted=intake () in
  let selection=match selected admitted with
    | [selection] -> selection | [] | _::_ -> fail "original companion was not admitted after hint retirement" in
  check string "retired hint cannot select a different invocation" origin.O.id (payload selection).ao_origin_id;
  check_route "retired channel-less hint cannot erase original conversation" origin.source.channel admitted;
  check int "hint retirement keeps original publication pending before turn completion" 1
    (List.length (pending config));
  ack_fixture_batch config admitted;
  check int "only later original turn completion consumes publication" 0 (List.length (pending config)))
let unreadable_source_does_not_anchor_batch env fs config origin = with_intake env config (fun intake ->
  let other=another_origin fs config origin in
  deliver fs config origin (notice ()) |> delivery_ok;
  deliver fs config other (notice ~operation:"0b000000-0000-4000-8000-000000000035" ()) |> delivery_ok;
  write (path origin) "{";
  let admitted=intake () in
  check int "unreadable first invocation does not starve readable source" 1 (List.length (selected admitted));
  check_route "readable independent source keeps its conversation" other.source.channel admitted;
  check bool "unreadable canonical source remains explicit" true
    (match admitted.event_queue_intake_error with
     | Some (Keeper_heartbeat_stimulus_intake.Addon_result_unavailable (_,P.Corrupt)) -> true
     | Some _|None -> false);
  check int "failed original is retained alongside admitted source" 2 (List.length (pending config));
  ack_fixture_batch config admitted;
  check int "completion cannot consume unreadable original source" 1 (List.length (pending config));
  check string "failed source is not silently repaired" "{" (read (path origin)))
let ()=run "Original companion publication" ["publication",[
  test_case "one original invocation and conversation per intake" `Quick (with_origin invocation_batches);
  test_case "ordinary sources defer companion routing intact" `Quick (with_origin general_source_precedes_addon);
  test_case "retired tool result hint cannot anchor companion admission" `Quick (with_origin retired_tool_result_does_not_anchor_batch);
  test_case "unreadable original does not anchor source grouping" `Quick (with_origin unreadable_source_does_not_anchor_batch);
  test_case "immutable canonical retention and conflict" `Quick (with_origin canonical_retention);
  test_case "closed output schema before publication" `Quick (with_origin schema_refusal);
  test_case "durable queue, original observation and consumed-source dedup" `Quick (with_origin durable_queue_and_consumption);
  test_case "unreadable or changed source is not consumed" `Quick (with_origin unreadable_or_foreign_source);
  test_case "unsafe original record cannot authorize admission" `Quick (with_origin unsafe_record)]]
