(** Real private publication files, durable recipient queue and canonical
    observation reads. Runtime retirement cases replace only the external worker
    with explicit barriers and use the real companion broker. No Browser or
    model turn runs. *)
open Alcotest
open Masc
module O=Lane_addon_companion_origin
module P=Lane_addon_companion_publication
module Recovery_test=Fs_compat_test_support.Publication_recovery_for_testing
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
  let initial=Unix.lstat (path origin) in
  let again=retain fs config origin (notice ()) |> pub_ok in
  check bool "same publication reconciles original record" true (again=first);
  let repeated=Unix.lstat (path origin) in
  check bool "existing publication preserves original inode" true
    (initial.st_dev=repeated.st_dev && initial.st_ino=repeated.st_ino);
  let changed=notice ~kind:"effect_submitted" ~phase:"fill_submitted" ~submitted:true () in
  check bool "same publication ID refuses changed payload" true (retain fs config origin changed=Error P.Binding_conflict);
  check string "conflict never rewrites original" bytes (read (path origin));
  check bool "original publication strictly reloads" true
    (P.find ~config ~origin_id:origin.id ~publication_id=Ok first)
let release_failure_on_existing _env fs config origin =
  let first=retain fs config origin (notice ()) |> pub_ok in
  let file=path origin in
  let bytes=read file and initial=Unix.lstat file in
  let fault=Recovery_test.lane_scope_release_fault
    ~owner:("companion-publication-" ^ origin.O.id ^ "-" ^ publication_id)
    ~exception_:(Failure "publication recovery lane release")
    |> Result.get_ok in
  let result=Recovery_test.with_lane_scope_release_fault fault (fun () ->
    retain fs config origin (notice ())) in
  check bool "existing publication cannot hide recovery lane release failure" true
    (result=Error P.Commit_unconfirmed);
  check string "release failure preserves exact publication bytes" bytes (read file);
  let current=Unix.lstat file in
  check bool "release failure preserves publication inode" true
    (initial.st_dev=current.st_dev && initial.st_ino=current.st_ino);
  check bool "healthy repeat reconciles the immutable publication" true
    ((retain fs config origin (notice ()) |> pub_ok) = first)
let live_owner_record _env fs config origin =
  retain fs config origin (notice ()) |> pub_ok |> ignore;
  let target=path origin in
  let owner="companion-publication-" ^ origin.O.id ^ "-" ^ publication_id in
  let lock_path=File_lock_eio.lock_file_path (target ^ ".publication-owner") in
  let observation=File_lock_eio.with_durable_lock_observed ~lock_path (fun () ->
    let private_root=Common.masc_dir_from_base_path ~base_path:origin.base_path in
    Eio.Path.with_open_dir Eio.Path.(fs / private_root) (fun owned_root ->
      Eio.Switch.run (fun sw ->
        let registry=Fs_compat.Publication_recovery.open_registry ~sw ~fs
          ~registry_root:owned_root |> Result.get_ok in
        let root_stat=Unix.stat private_root and parent=Unix.stat (Filename.dirname target) in
        let operation_id=Uuidm.of_string (Random_id.uuid_v7 ()) |> Option.get in
        Recovery_test.seed_prepared ~registry ~owner ~operation_id
          ~allowed_root_path:private_root ~allowed_root_device:(Int64.of_int root_stat.st_dev)
          ~allowed_root_inode:(Int64.of_int root_stat.st_ino)
          ~parent_components:["lane-addons";"companion-publications";origin.id]
          ~parent_device:(Int64.of_int parent.st_dev) ~parent_inode:(Int64.of_int parent.st_ino)
          ~target_leaf:(Filename.basename target) ~permissions:0o600 |> Result.get_ok;
        let record=List.fold_left Filename.concat private_root
          ["fs-publication-recovery";"lanes";owner;"active";Uuidm.to_string operation_id] in
        let bytes=read record and before=Unix.lstat record in
        check bool "active publication owner refuses retry before recovery readiness" true
          (retain fs config origin (notice ())=Error P.Commit_unconfirmed);
        check string "live publication Prepared record stays exact" bytes (read record);
        let after=Unix.lstat record in
        check bool "live publication Prepared record keeps its inode" true
          (before.st_dev=after.st_dev && before.st_ino=after.st_ino)))) in
  match observation with
  | File_lock_eio.Body_completed {value=();release_error=None} -> ()
  | Lock_not_acquired _ | Body_completed {release_error=Some _;_} -> fail "owner fixture lock failed"
let host_owner_loss _env fs config origin =
  let event=P.owner_lost ~publication_id |> pub_ok in
  check bool "host notice uses a fixed generic unknown output" true
    (event.kind=P.Owner_lost && event.output=`Assoc ["outcome",`String "unknown"]);
  check bool "worker capability cannot forge host owner loss" true
    (P.event ~output_schema (P.event_json event)=Error P.Invalid_event);
  check bool "host notice requires a canonical publication identity" true
    (P.owner_lost ~publication_id:"../replacement"=Error P.Invalid_event);
  let retained=retain fs config origin event |> pub_ok in
  check bool "original closed worker schema remains provenance" true
    (retained.output_schema=(Lane_addon_action.canonical output_schema |> string_ok));
  check bool "host notice strictly reloads without worker-schema coercion" true
    (P.find ~config ~origin_id:origin.id ~publication_id=Ok retained);
  deliver fs config origin event |> delivery_ok;
  let change=only config |> payload in
  check (option string) "owner loss retains the original Task" (Some "task-original") change.ao_source.task_id;
  check bool "owner loss retains its original conversation" true
    (Keeper_continuation_channel.same_route origin.source.channel change.ao_channel);
  let observed=Keeper_world_observation.pending_board_event_of_addon_operation_change
    ~base_path:config.base_path ~keeper_name:keeper ~arrived_at:0. change |> pub_ok in
  let fields=Keeper_unified_prompt.For_testing.board_event_fields {observed with preview=""} in
  check bool "resumed input carries the complete host event" true
    (Yojson.Safe.from_string (List.assoc "publication" fields)=P.event_json event);
  let file=path origin in
  let bytes=read file in
  let json=Yojson.Safe.from_string bytes in
  let changed=match json with
    | `Assoc fields -> `Assoc (List.map (fun (name,value) ->
        if name="event" then name,`Assoc ["publication_id",`String publication_id;
          "kind",`String "owner_lost";"output",`Assoc ["outcome",`String "known"]]
        else name,value) fields)
    | _ -> fail "retained host publication missing" in
  let damaged=Yojson.Safe.to_string changed ^ "\n" in
  write file damaged;
  check bool "changed host outcome is not authoritative" true
    (P.find ~config ~origin_id:origin.id ~publication_id=Error P.Corrupt);
  check bool "damaged host record cannot be silently repaired" true
    (retain fs config origin event=Error P.Corrupt);
  check string "failed reconciliation preserves damaged evidence" damaged (read file)
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
  bootstrap config ~urgency:Q.Immediate ~arrived_at:0.;
  deliver fs config origin (notice ()) |> delivery_ok;
  check bool "ordinary source is actually first in the durable urgency-stable queue" true
    (match pending config with first::_ -> first.source.payload=Q.Bootstrap | [] -> false);
  let first=intake () in
  check bool "first admitted ordinary source excludes companion notice" true
    (match selected first with [selection] -> selection.source.payload=Q.Bootstrap | []|_::_ -> false);
  check int "deferred companion remains pending" 2 (List.length (pending config));
  ack_fixture_batch config first;
  let second=intake () in
  check int "companion admits on its own later turn" 1 (List.length (selected second));
  check_route "ordinary source never strips later companion route" origin.source.channel second)
let retired_tool_result_does_not_anchor_batch env fs config origin =
  let runtime_snapshot=Runtime.For_testing.snapshot () in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot) (fun () ->
  let runtime_path=Filename.concat config.Workspace.base_path "receipt-runtime.toml" in
  write runtime_path {|[providers.codex]
protocol = "codex-app-server"
command = "/bin/false"
is-non-interactive = true
[models.codex]
api-name = "gpt-fixture"
max-context = 400000
[codex.codex]
[runtime]
default = "codex.codex"
|};
  ignore (Runtime.init_default ~config_path:runtime_path |> string_ok);
  Masc_test_deps.declare_fixture_keeper ~base_path:config.base_path
    ~sandbox_profile:(Some Keeper_types_profile.Docker) ~sandbox_image:"base" keeper;
  Keeper_types_profile.invalidate_keeper_profile_snapshots ();
  let meta=match Keeper_meta_store.read_effective_meta config keeper |> string_ok with
    | Some meta -> meta | None -> fail "declared fixture Keeper missing" in
  check bool "fixture route can consume Codex receipt bodies" true
    (Keeper_client_tool_outbox_wake.route_can_consume meta);
  let outbox=Keeper_client_tool_outbox.load ~base_path:config.base_path ~keeper_name:keeper |> string_ok in
  check (list string) "fixture has no unread receipt bodies" []
    (Keeper_client_tool_outbox.receipt_ids outbox);
  with_intake env config (fun intake ->
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
  check (option string) "hint retirement has no intake error" None
    (Option.map Keeper_heartbeat_stimulus_intake.event_queue_intake_error_to_string
       admitted.event_queue_intake_error);
  let selection=match selected admitted with
    | [selection] -> selection | [] | _::_ -> fail "original companion was not admitted after hint retirement" in
  check string "retired hint cannot select a different invocation" origin.O.id (payload selection).ao_origin_id;
  check_route "retired channel-less hint cannot erase original conversation" origin.source.channel admitted;
  check int "hint retirement keeps original publication pending before turn completion" 1
    (List.length (pending config));
  ack_fixture_batch config admitted;
  check int "only later original turn completion consumes publication" 0 (List.length (pending config))))
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
type runtime_exit_case = Missing_terminal | Known_terminal | Rejected_invocation
let runtime_worker_exit mode env fs config original =
  let module Runtime=Lane_addon_runtime in
  let module L=Lane_addon_lifecycle in
  let clock=Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock 10. (fun () -> Eio.Switch.run (fun sw ->
  Eio_context.with_test_env ~sw ~clock ~net:(Eio.Stdenv.net env)
    ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
  Runtime.For_testing.reset ();
  Fun.protect ~finally:Runtime.For_testing.reset (fun () ->
    let ended,end_worker=Eio.Promise.create () in
    let delivered,deliver_notice=Eio.Promise.create () in
    let acknowledged,acknowledge=Eio.Promise.create () in
    let socket=ref None and events=ref [] and stops=ref 0 in
    let empty=`Assoc ["type",`String "object";"properties",`Assoc [];"additionalProperties",`Bool false] in
    let tool=Mcp_protocol.Mcp_types.tool_of_yojson (`Assoc ["name",`String "owner_loss_probe";
      "inputSchema",empty;"outputSchema",output_schema]) |> string_ok in
    let backend : Runtime.For_testing.backend = {
      start=(fun ~sw:_ ~state_owner:_ ~instance_id ~installation_id ~package:_ ~binding:_
          ~on_authority ~is_live_instance:_ ~on_created ->
        let connection : Runtime.For_testing.connection = {
          resource=L.Native_resource {pid=Unix.getpid ();started=None};resolved_image=None;
          browser=None;host=None;action_schema=(fun () -> None);operator_schema=(fun () -> None);
          exported_tools=(fun () -> [tool]);companion_tools=(fun () -> [tool.name]);
          observation_effect=(fun _ -> Lane_addon_call_context.May_change);
          observe=(fun ~binding:_ ~sources:_ -> Ok Lane_addon_types.{rows=[];coverage=[]});
          act=(fun ~arguments:_ -> Error "fixture has no actions");
          call_operator=(fun ~admit:_ ~arguments:_ -> Error Lane_addon_worker_protocol.Operator_unavailable);
          await_exit=(fun () -> Eio.Promise.await ended;"fixture worker ended");
          stop=(fun () -> incr stops;ignore (Eio.Promise.try_resolve end_worker ());
            Ok (L.Native_released {installation_id;instance_id}));
          call_exported_tool=(fun ~companion ~on_result ~on_dispatch:_ ~authorize:_ ~principal:_ ~name:_ ~arguments:_ ->
            let admitted=match companion with Some value -> value | None -> fail "companion missing" in
            check bool "fake external worker receives original host admission" true (admitted.admit ());
            let path=admitted.context.socket_path in
            socket:=Some (path,Unix.lstat (Filename.dirname path),Unix.lstat path);
            (match mode with
             | Missing_terminal | Rejected_invocation -> ()
             | Known_terminal ->
                 let capability=match admitted.context.publication_id with
                   | Some id -> id | None -> fail "original publisher missing" in
                 Eio.Fiber.fork ~sw (fun () ->
                   Eio.Fiber.yield ();
                   let flow=Eio.Net.connect ~sw (Eio.Stdenv.net env) (`Unix admitted.context.socket_path) in
                   let event=notice ~kind:"terminal" ~phase:"outcome_unknown" () in
                   Eio.Flow.copy_string (Yojson.Safe.to_string (`Assoc ["publication_id",`String capability;
                     "event",P.event_json event]) ^ "\n") flow;
                   let reader=Eio.Buf_read.of_flow flow ~max_size:65537 in
                   check bool "real private broker confirms durable terminal admission" true
                     (Yojson.Safe.from_string (Eio.Buf_read.line reader)=`Assoc ["accepted",`Bool true]);
                   Eio.Flow.close flow;Eio.Promise.resolve acknowledge ()));
            let reply={(Mcp_protocol.Mcp_types.tool_result_of_text "fixture response") with
              structured_content=Some (output "approval_ready" false);
              is_error=Some (match mode with Rejected_invocation -> true | Missing_terminal | Known_terminal -> false)} in
            on_result reply;Ok reply)} in
        match on_authority (L.Native_admission {installation_id}) with
        | Error detail -> Error (L.Persistence_failed detail)
        | Ok () -> on_created connection;Ok connection);
      acquire=(fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_
        ~read_browser_document:_ ~binding:_ -> Ok (`List []));
      package_ready=(fun ~package:_ -> Ok ());condition_met=(fun ~runtime:_ _ -> false);
      sweep=(fun ~runtime:_ ~is_live_instance:_ -> Ok []);
      recover_stop=(fun ~state_owner:_ ~instance_id:_ ~authority:_ ~resource:_ ->
        Error (L.Cleanup_unconfirmed "unexpected fixture recovery"))} in
    Runtime.For_testing.with_backend backend (fun () ->
      let manifest=Filename.concat config.Workspace.base_path "owner-loss.toml" in
      write manifest {|id = "owner-loss-fixture"
revision = "1"
title = "Controlled companion worker"
runtime = "host_process"
command = ["fixture-worker"]
contributions = ["observe"]
[world.tools]
export = ["owner_loss_probe"]
invocation = "host_context"
hooks = ["validate_input", "validate_output"]
[resources]
max_reply_bytes = 65536
|};
      let dispatch operation fields=Runtime.dispatch ~caller:"fixture-operator"
        ~access:Lane_addon_sources.Operator_configuration ~config ~operation (`Assoc fields)
        |> Result.map_error Runtime.error_to_string |> string_ok in
      let attached=dispatch Runtime.Attach ["manifest_path",`String manifest;"run_id",`String "owner-loss";
        "binding",`Assoc ["sources",`List []]] in
      let id=Yojson.Safe.Util.member "instance_id" attached |> Yojson.Safe.Util.to_string in
      let inspect ()=dispatch Runtime.Inspect ["instance_id",`String id]
        |> Yojson.Safe.Util.member "instances" |> Yojson.Safe.Util.to_list |> List.hd in
      let rec await predicate=if predicate () then () else (Eio.Time.sleep clock 0.001;await predicate) in
      await (fun () -> (inspect () |> Yojson.Safe.Util.member "observation_seq" |> Yojson.Safe.Util.to_int)>0);
      let access=Lane_addon_sources.Keeper keeper in
      let reading=Runtime.tool_export_reading ~config ~access ~reserved:[] |> string_ok in
      let export=match reading.exports with [one] -> one | [] | _::_ -> fail "fixture export unavailable" in
      let turn=original.O.source.turn_ref in
      let trace=Ids.Turn_ref.trace_id turn in
      let context=Keeper_tool_call_log_context.{empty_turn_context with agent_name=Some keeper;
        trace_id=Some trace;keeper_turn_id=Some (Ids.Turn_ref.absolute_turn turn);task_id=original.source.task_id} in
      let source=O.source ~keeper_name:keeper ~turn_ref:(Some turn) ~tool_use_id:(Some "runtime-owner-loss")
        ~trace_id:(Some trace) ~source_context:(Some context) ~channel:(Some original.source.channel) |> origin_ok in
      let publish ~origin ~output_schema ~event=
        match D.deliver ~fs ~config ~origin ~output_schema ~event with
        | Error _ -> Error ()
        | Ok () -> events:=event.P.kind::!events;
            ignore (Eio.Promise.try_resolve deliver_notice ());Ok () in
      let reply=Runtime.call_exported_tool_with_authority ~companion_publish:(Some publish)
        ~continuation:(Some (Ok source)) ~on_complete:(fun () -> ()) ~on_result:(fun _ -> ())
        ~authorize:None ~principal:(Some (Lane_addon_call_context.Keeper keeper))
        ~config ~access ~reserved:[] ~export ~arguments:(`Assoc []) in
      check bool "original invocation returned its controlled worker reply" true (Result.is_ok reply);
      (match mode with Known_terminal -> Eio.Promise.await acknowledged | Missing_terminal | Rejected_invocation -> ());
      Eio.Promise.resolve end_worker ();
      (match mode with Missing_terminal -> Eio.Promise.await delivered | Known_terminal | Rejected_invocation -> ());
      await (fun () ->
        match inspect () |> Yojson.Safe.Util.member "lifecycle" |> L.state_of_json |> string_ok with
        | L.Failed _ -> true
        | L.Attached | L.Observing -> false
        | L.Detaching _ | L.Detached _ -> fail "original worker retired before operator Detach");
      let captured,directory_identity,socket_identity=match !socket with
        | Some original -> original | None -> fail "original socket not captured" in
      (* Listener refusal is observable before Detach; it does not claim that
         every Browser settlement has joined. Detach below joins the owner. *)
      await (fun () ->
        let connection=Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
        Fun.protect ~finally:(fun () -> Unix.close connection) (fun () ->
          Unix.set_nonblock connection;
          match Unix.connect connection (Unix.ADDR_UNIX captured) with
          | () -> false
          | exception Unix.Unix_error (Unix.ECONNREFUSED,_,_) -> true
          | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINPROGRESS),_,_) -> false));
      let check_retained () =
        let same expected path =
          let current=Unix.lstat path in
          current.st_dev=expected.Unix.st_dev && current.st_ino=expected.st_ino
          && current.st_kind=expected.st_kind in
        check bool "original stopped IPC pathnames stay retained" true
          (same directory_identity (Filename.dirname captured) && same socket_identity captured) in
      check_retained ();
      check int "detected exit closes IPC admission without stopping worker resource" 0 !stops;
      let expected=match mode with Missing_terminal -> [P.Owner_lost] | Known_terminal -> [P.Terminal]
        | Rejected_invocation -> [] in
      check bool "one original outcome and no false owner-loss notice" true (!events=expected);
      (match mode with
       | Rejected_invocation -> check int "rejected invocation creates no async queue source" 0 (List.length (pending config))
       | Missing_terminal | Known_terminal ->
           let change=only config |> payload in
           check (option string) "runtime notice preserves original Task" original.source.task_id change.ao_source.task_id;
           check bool "runtime notice preserves original conversation" true
             (Keeper_continuation_channel.same_route original.source.channel change.ao_channel));
      ignore (dispatch Runtime.Detach ["instance_id",`String id]);
      Runtime.For_testing.await_run_stopped ~config ~instance_id:id;
      check int "explicit Detach still owns worker resource release" 1 !stops;
      check_retained ();
      check bool "Detach reuses the same settlement without another notice" true (!events=expected))))))
let ()=run "Original companion publication" ["publication",[
  test_case "existing publication does not hide recovery release failure" `Quick
    (with_origin release_failure_on_existing);
  test_case "live publication owner protects its actual Prepared record" `Quick
    (with_origin live_owner_record);
  test_case "manual worker exit publishes owner loss without Detach" `Quick (with_origin (runtime_worker_exit Missing_terminal));
  test_case "known terminal suppresses owner loss at worker exit" `Quick (with_origin (runtime_worker_exit Known_terminal));
  test_case "rejected invocation emits no owner loss at worker exit" `Quick (with_origin (runtime_worker_exit Rejected_invocation));
  test_case "host-only owner loss retains original source and fixed outcome" `Quick (with_origin host_owner_loss);
  test_case "one original invocation and conversation per intake" `Quick (with_origin invocation_batches);
  test_case "ordinary sources defer companion routing intact" `Quick (with_origin general_source_precedes_addon);
  test_case "retired tool result hint cannot anchor companion admission" `Quick (with_origin retired_tool_result_does_not_anchor_batch);
  test_case "unreadable original does not anchor source grouping" `Quick (with_origin unreadable_source_does_not_anchor_batch);
  test_case "immutable canonical retention and conflict" `Quick (with_origin canonical_retention);
  test_case "closed output schema before publication" `Quick (with_origin schema_refusal);
  test_case "durable queue, original observation and consumed-source dedup" `Quick (with_origin durable_queue_and_consumption);
  test_case "unreadable or changed source is not consumed" `Quick (with_origin unreadable_or_foreign_source);
  test_case "unsafe original record cannot authorize admission" `Quick (with_origin unsafe_record)]]
