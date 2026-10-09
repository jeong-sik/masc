open Alcotest
module Native = Masc_tui_native_tasks
module Read = Masc.Keeper_native_task_read
module Task = Runtime_native_tasks
module Layout = Masc_tui_message_layout
let keeper = "alpha"
let receiver : Read.receiver = {receiver_generation="receiver /&+%";session_id="session /&+%"}
let health = `Assoc ["coverage",`String "issues_observed_in_this_process_only";
  "process_epoch",`String "process";"historical_failure_coverage",`String "unknown";"issues",`List []]
let unknown = ["provider_completeness",`String "unknown";"historical_persistence_failures",`String "unknown"]
let inventory store through = `Assoc
  (["schema",`String "masc.native_tasks.receivers.v1";"keeper_name",`String keeper;
    "observed_persistence_health",health;"cleanup_failures",`List [];
    "receivers",`List [`Assoc ["receiver_generation",`String receiver.receiver_generation;
      "session_id",`String receiver.session_id;"storage",`Assoc ["status",`String "audited";
        "store_id",`String store;"through_sequence",`Int through]]]] @ unknown)
let origin ?(task_id="task") ?(call="call") ?(run="run") () : Task.origin =
  {keeper_name=keeper;source=Task.Operation {operation_id="original-operation"};
   attempt={routing_run_id="routing";runtime_id="claude";lane_attempt_index=0};
   invocation={receiver_generation=receiver.receiver_generation;session_id=receiver.session_id;client_uuid="input"};
   native_call={session_id=receiver.session_id;call_id=call;call_envelope_uuid="envelope";call_ordinal=0};
   task_id;run_id=run}
let observation ?(origin=origin ()) ?(boundary=Task.Task_terminal_unobserved) uuid event =
  match Task.make ~origin ~uuid ~event ~boundary with
  | Ok value -> value | Error detail -> fail detail
let registered ?skip ?ambient ?(origin=origin ()) uuid =
  observation ~origin uuid (Task.Task_registered {subagent_type=Some "worker";
    is_backgrounded=Some true;skip_transcript=skip;ambient})
let page store through rows = `Assoc
  (["schema",`String "masc.native_tasks.records.v1";"keeper_name",`String keeper;
    "receiver_generation",`String receiver.receiver_generation;"session_id",`String receiver.session_id;
    "observed_persistence_health",health;"cleanup_failures",`List [];
    "records",`List (List.map (fun (seq,observation) -> `Assoc
      ["seq",`Int seq;"recorded_at",`Float (float_of_int seq);"observation",Task.to_json observation]) rows);
    "validation",`Assoc ["kind",`String "full_committed_history";"through_sequence",`Int through];
    "next_cursor",`Assoc ["store_id",`String store;"after_sequence",`Int through];
    "terminal_without_observation",`String "unknown"] @ unknown)
let load previous ~store ~through ~rows ~after =
  let record_reads=ref 0 in
  let fetch path =
    let uri=Uri.of_string path in
    match Uri.path uri with
    | "/api/v1/keepers/alpha/native-tasks/receivers" -> Ok (200,Yojson.Safe.to_string (inventory store through))
    | "/api/v1/keepers/alpha/native-tasks/records" ->
        incr record_reads;
        let query=Uri.query uri in
        check (option (list string)) "opaque generation survives query encoding"
          (Some [receiver.receiver_generation]) (List.assoc_opt "receiver_generation" query);
        check (option (list string)) "opaque session survives query encoding"
          (Some [receiver.session_id]) (List.assoc_opt "session_id" query);
        check (option (list string)) "exact previous suffix boundary" (Option.map (fun n -> [string_of_int n]) after)
          (List.assoc_opt "after_sequence" query);
        check (option (list string)) "opaque cursor incarnation survives query encoding"
          (Option.map (fun _ -> [store]) after) (List.assoc_opt "store_id" query);
        Ok (200,Yojson.Safe.to_string (page store through rows))
    | _ -> fail ("unexpected native read path: " ^ path) in
  match Native.read ~keeper_name:keeper ~fetch ~previous with
  | Ok state -> state,!record_reads | Error error -> fail (Native.error_text error)

let test_independent_suffix_and_identity () =
  let store="store /&+%" in
  let first,_=load Native.empty ~store ~through:1 ~rows:[1,registered "one"] ~after:None in
  let only=List.hd (Native.tasks first) in
  check bool "registration is no running receipt" true (only.status=None && only.terminal=None);
  let usage:Task.usage={total_tokens=9;tool_uses=2;duration_ms=(-3)} in
  let progress=observation "two" (Task.Task_progress_reported {usage;last_tool_name=Some "Read"}) in
  let second,_=load first ~store ~through:2 ~rows:[2,progress] ~after:(Some 1) in
  let only=List.hd (Native.tasks second) in
  check bool "post-root observation retains independent signed provider usage" true (only.usage=Some usage);
  let terminal=observation ~boundary:Task.Task_terminal_observed "three"
    (Task.Task_terminal_reported {outcome=Task.Task_completed_notice;reason=None;usage=None;
      skip_transcript=None;ambient=None}) in
  let third,_=load second ~store ~through:3 ~rows:[3,terminal] ~after:(Some 2) in
  let fourth,reads=load third ~store ~through:3 ~rows:[] ~after:(Some 3) in
  check int "audited unchanged boundary avoids redundant records HTTP" 0 reads;
  check bool "unchanged audited refresh preserves immutable view identity" true (fourth == third);
  check int "no duplicate task on repeated suffix" 1 (List.length (Native.tasks fourth));
  check bool "explicit terminal remains visible" true
    ((List.hd (Native.tasks fourth)).terminal=Some Task.Task_completed_notice);
  let other=registered ~origin:(origin ~call:"another-call" ()) "four" in
  let distinct,_=load fourth ~store ~through:4 ~rows:[4,other] ~after:(Some 3) in
  check int "same task ID from another native call is not merged" 2 (List.length (Native.tasks distinct));
  let replaced,_=load distinct ~store:"replacement-store" ~through:1 ~rows:[1,registered "new-store"] ~after:None in
  check int "replacement incarnation has distinct retained history" 3 (List.length (Native.tasks replaced));
  check bool "old incarnation is explicitly diagnostic history" true (Native.diagnostics replaced<>[])

let test_failure_keeps_cursor_and_scope () =
  let first,_=load Native.empty ~store:"store" ~through:1 ~rows:[1,registered "one"] ~after:None in
  (match Native.read ~keeper_name:"beta" ~previous:first
      ~fetch:(fun _ -> fail "foreign cache must refuse before HTTP") with
   | Error (Native.Invalid_response Read.Scope_mismatch) -> ()
   | _ -> fail "another Keeper was allowed to reuse this history");
  let foreign=observation ~origin:{(origin ()) with keeper_name="beta"} "two"
    (Task.Task_progress_reported {usage={total_tokens=1;tool_uses=1;duration_ms=1};last_tool_name=None}) in
  let failed,_=load first ~store:"store" ~through:2 ~rows:[2,foreign] ~after:(Some 1) in
  check int "wrong scope cannot overwrite prior observations" 1 (List.length (Native.tasks failed));
  check bool "scope refusal is retained as a typed receiver failure" true
    (match Native.errors failed with [Native.Receiver_read (_,Native.Invalid_response Read.Scope_mismatch)] -> true | _ -> false);
  let retried,_=load failed ~store:"store" ~through:2
    ~rows:[2,registered ~origin:(origin ~run:"retry-run" ()) "retry"] ~after:(Some 1) in
  check int "retry resumes unchanged cursor" 2 (List.length (Native.tasks retried));
  let disconnected=Native.failed retried (Native.Transport "disconnected") in
  check bool "transport failure retains observations" true (Native.tasks disconnected=Native.tasks retried);
  let missing_inventory = match inventory "store" 2 with
    | `Assoc fields -> `Assoc (("receivers",`List [])::List.remove_assoc "receivers" fields)
    | _ -> fail "expected inventory" in
  let absent = Native.read ~keeper_name:keeper ~previous:retried
    ~fetch:(fun _ -> Ok (200,Yojson.Safe.to_string missing_inventory)) |> Result.get_ok in
  check int "missing receiver is not task completion/deletion" 2 (List.length (Native.tasks absent));
  check bool "missing receiver retains unknown-coverage diagnostic" true (Native.diagnostics absent<>[])

let test_real_chat_projection_preserves_flags_and_terminal_safety () =
  let dangerous="task\027]0;injected\007\nnew-row" in
  let visible=registered ~origin:(origin ~task_id:dangerous ()) "visible" in
  let hidden=registered ~origin:(origin ~run:"hidden" ()) ~skip:true "hidden" in
  let ambient=registered ~origin:(origin ~run:"ambient" ()) ~ambient:true "ambient" in
  let native,_=load Native.empty ~store:"store\027[2J" ~through:3
    ~rows:[1,visible;2,hidden;3,ambient] ~after:None in
  let state=Masc_tui_types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_target_keeper_name <- Some keeper;
  state.msg_native_tasks <- [keeper,native];
  state.msg_tool_visibility <- Masc_tui_types.Tools_full;
  state.msg_history <- [{Masc_tui_types.me_keeper_name=keeper;me_role=Message_keeper;
    me_identity=Persisted_row "settled";me_turn_phase=Turn_output;me_turn_sequence=None;
    me_operation_seq=0;me_text="settled reply";me_image=Masc_tui_image_preview.No_image;
    me_memory_summary=None;me_journal=[];me_memory_pass=Layout.No_pass;me_gate=None;
    me_submitted_at=None;me_tool_block=None;me_skill_block=[];me_timestamp="";
    me_request_id="settled";me_execution_source=None;me_at=1.}];
  let entries=Masc_tui_render_chat.native_task_entries state ~keeper_name:keeper ~role_label_column:10 in
  check int "skip_transcript hides only its inline entry" 3 (List.length entries);
  check int "native observations do not fabricate root activity" 0
    (List.length (Masc_tui_types.keeper_message_activity_rows state));
  let safe text=check bool "opaque controls never reach terminal presentation" false
      (String.contains text '\027' || String.contains text '\007') in
  List.iter (fun (entry:Layout.entry) ->
    safe entry.speaker;safe entry.role_label;safe entry.body;List.iter safe entry.diagnostics;
    check bool "native observations never mint root request/clock" true
      (entry.request_label="" && entry.timeline_bucket=None)) entries;
  check string "raw task identity stays unchanged in cache" dangerous
    (List.hd (Native.tasks native)).origin.task_id;
  let projection=Masc_tui_render_chat.keeper_message_projection state ~keeper_name:keeper ~chat_cols:100 in
  check int "independent entries join nonempty settled chat layout" 4 (List.length projection.layout_entries);
  check int "one scroll placeholder per independent entry" 3 (List.length projection.transient_anchors);
  let idle=Masc_tui_render_chat.keeper_message_projection state ~keeper_name:keeper ~chat_cols:100 in
  check bool "retained task lane preserves idle physical layout cache identity" true
    (projection.layout_entries == idle.layout_entries);
  state.msg_tool_visibility <- Masc_tui_types.Tools_compact;
  let compact=Masc_tui_render_chat.keeper_message_projection state ~keeper_name:keeper ~chat_cols:100 in
  check bool "tools setting change invalidates native layout" false
    (idle.layout_entries == compact.layout_entries);
  let wide=Masc_tui_render_chat.native_task_entries state ~keeper_name:keeper ~role_label_column:10 in
  let narrow=Masc_tui_render_chat.native_task_entries state ~keeper_name:keeper ~role_label_column:8 in
  check bool "changed label width invalidates native entries" false (wide == narrow);
  let patch=observation ~origin:(origin ~task_id:dangerous ()) "patch"
    (Task.Task_patched {status=Some Task.Task_paused;is_backgrounded=None;
      end_time=None;total_paused_ms=Some (-2)}) in
  let changed,_=load native ~store:"store\027[2J" ~through:4 ~rows:[4,patch] ~after:(Some 3) in
  state.msg_native_tasks <- [keeper,changed];
  let refreshed=Masc_tui_render_chat.keeper_message_projection state ~keeper_name:keeper ~chat_cols:100 in
  check bool "changed observation invalidates native layout" false
    (compact.layout_entries == refreshed.layout_entries)

let () = run "native task TUI consumer" ["observations",[
  test_case "suffix, original identity and store incarnation" `Quick test_independent_suffix_and_identity;
  test_case "failure, cursor preservation and absent receiver" `Quick test_failure_keeps_cursor_and_scope;
  test_case "actual chat projection, flags and terminal safety" `Quick test_real_chat_projection_preserves_flags_and_terminal_safety]]
