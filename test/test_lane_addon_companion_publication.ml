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
let output phase submitted=`Assoc ["operation_id",`String operation_id;"phase",`String phase;
  "fill_submitted",`Bool submitted;"website_login_verified",`Bool false]
let notice ?(kind="attention_required") ?(phase="approval_ready") ?(submitted=false) () =
  P.event ~output_schema (`Assoc ["publication_id",`String publication_id;
    "kind",`String kind;"output",output phase submitted]) |> pub_ok
let with_origin run () = Eio_main.run (fun env ->
  let root=Filename.temp_dir "companion-publication-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let config=Workspace.default_config root in
    let trace=Random_id.uuid_v7 () in
    let turn=Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:42 in
    let context=Keeper_tool_call_log_context.{empty_turn_context with agent_name=Some keeper;
      trace_id=Some trace;keeper_turn_id=Some 42;task_id=Some "task-original"} in
    let channel=Keeper_continuation_channel.dashboard ~thread_id:"original-thread" |> string_ok in
    let source=O.source ~keeper_name:keeper ~turn_ref:(Some turn) ~tool_use_id:(Some "original-login-use")
      ~trace_id:(Some trace) ~source_context:(Some context) ~channel:(Some channel) |> origin_ok in
    let destination=O.{instance_id="original-provider";package_id="onepassword";package_revision="0.1.0";
      tool="onepassword_login";declaration_id=Some "original-declaration";configuration_revision=Some "original-revision"} in
    let fs=Eio.Stdenv.fs env in
    let origin=match O.reserve ~fs ~config ~source ~destination
      ~arguments:(`Assoc ["goal",`String "PRIVATE_INPUT_MARKER"]) |> origin_ok with
      | O.Fresh r -> r | Existing _ -> fail "fixture did not create original source" in
    run fs config origin))
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
let canonical_retention fs config origin =
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
let schema_refusal _fs _config origin =
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
let durable_queue_and_consumption fs config origin =
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
  let fields=Keeper_unified_prompt.For_testing.board_event_fields observed in
  check string "prompt metadata preserves original publication" publication_id (List.assoc "publication_id" fields);
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
let unreadable_or_foreign_source fs config origin =
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
let unsafe_record fs config origin =
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
let ()=run "Original companion publication" ["publication",[
  test_case "immutable canonical retention and conflict" `Quick (with_origin canonical_retention);
  test_case "closed output schema before publication" `Quick (with_origin schema_refusal);
  test_case "durable queue, original observation and consumed-source dedup" `Quick (with_origin durable_queue_and_consumption);
  test_case "unreadable or changed source is not consumed" `Quick (with_origin unreadable_or_foreign_source);
  test_case "unsafe original record cannot authorize admission" `Quick (with_origin unsafe_record)]]
