open Alcotest
module Consumer = Masc_tui_child_content
module ChildRead = Masc.Keeper_child_content_read
module Native = Masc_tui_native_tasks
module NativeRead = Masc.Keeper_native_task_read
module Task = Runtime_native_tasks
module T = Masc_tui_types
module Render = Masc_tui_render_chat
module Layout = Masc_tui_message_layout

let keeper = "alpha"

(* Child fixtures mirror test_tui_child_content.ml. The store receiver doubles
   as the native-task invocation ticket; the read rejects observations whose
   origin leaves the store scope, so an origin that differs is invalid data,
   not a second ticket to join on. *)
let child_receiver : ChildRead.receiver =
  {receiver_generation="child-gen"; session_id="child-session"; client_uuid="input"}
let child_receiver_json (receiver : ChildRead.receiver) =
  `Assoc ["receiver_generation", `String receiver.receiver_generation;
    "session_id", `String receiver.session_id; "client_uuid", `String receiver.client_uuid]
let coverage = ["persistence_failure_history", `String "unavailable";
  "provider_completeness", `String "unknown"; "liveness", `String "unknown"]
let envelope schema fields = `Assoc (("schema", `String schema) :: coverage @ fields)
let receipt kind store through =
  `Assoc ["kind", `String kind; "store_id", `String store; "through_sequence", `Int through]
let inventory mode entries =
  let schema, key, kind = match mode with
    | Consumer.Poll -> "masc.child_content.hints.v1", "hints", "unchecked"
    | Consumer.Audit -> "masc.child_content.receivers.v1", "receivers", "audited" in
  let field = match mode with Consumer.Poll -> "hint" | Consumer.Audit -> "storage" in
  envelope schema ["keeper_name", `String keeper; "cleanup_failures", `List [];
    key, `List (List.map (fun (receiver, status) -> `Assoc ["receiver", child_receiver_json receiver;
      field, (match status with Ok (store, through) -> receipt kind store through
        | Error code -> `Assoc ["kind", `String "failed"; "error", `String code])]) entries)]
let observation ?(receiver=child_receiver) ?(ordinal=1) ?(channel="text") ?(known=false)
    ?(body="body") ?(model="child-model") ?(provider="same-provider-envelope")
    ?(call_id="parent") ?(envelope="original-parent-envelope") ?(call_ordinal=0) id =
  let origin = `Assoc ["keeper_name", `String keeper;
    "source", `Assoc ["kind", `String "operation"; "operation_id", `String "original-operation"];
    "attempt", `Assoc ["routing_run_id", `String "routing"; "runtime_id", `String "claude";
      "lane_attempt_index", `Int 0];
    "invocation", child_receiver_json receiver] in
  let provenance = if known then ["parent_occurrence", `Assoc ["call_id", `String call_id;
      "call_envelope_uuid", `String envelope; "call_ordinal", `Int call_ordinal]] else [] in
  let attribution = if known then `Assoc ["kind", `String "original_parent_input";
      "evidence", `Assoc ["kind", `String "explicit"]]
    else `Assoc ["kind", `String "parent_input_refused";
      "reason", `Assoc ["kind", `String "unknown_parent"]] in
  `Assoc (["schema", `String "masc.child_content.v1"; "origin", origin;
    "observation_id", `String id; "envelope_uuid", `String provider;
    "ordinal", `Int ordinal; "channel", `String channel;
    "parent_tool_use_id", `String call_id; "message_id", `String ""; "model", `String model;
    "text", `String body; "attribution", attribution] @ provenance)
let row_at seq at obs = `Assoc ["seq", `Int seq; "recorded_at", `Float at; "observation", obs]
let page ?(receiver=child_receiver) ?(cleanup=[]) store through rows =
  envelope "masc.child_content.records.v1"
    ["scope", `Assoc ["keeper_name", `String keeper; "receiver", child_receiver_json receiver];
     "records", `List rows;
     "next_cursor", `Assoc ["store_id", `String store; "after_sequence", `Int through];
     "validation", `Assoc ["kind", `String "audited"; "through_sequence", `Int through];
     "cleanup_failures", `List (List.map (fun operation -> `String operation) cleanup)]
let json value = Yojson.Safe.to_string value
let read mode previous entries serve =
  let reads = ref [] in
  let fetch path =
    let uri = Uri.of_string path in
    let endpoint = match mode with Consumer.Poll -> "/api/v1/keepers/alpha/child-content/hints"
      | Consumer.Audit -> "/api/v1/keepers/alpha/child-content/receivers" in
    if Uri.path uri = endpoint then Ok (200, json (inventory mode entries))
    else if Uri.path uri = "/api/v1/keepers/alpha/child-content/records" then begin
      reads := uri :: !reads; serve uri
    end else fail ("unexpected Child path: " ^ path) in
  match Consumer.read ~mode ~keeper_name:keeper ~fetch ~previous with
  | Ok state -> state, List.rev !reads | Error error -> fail (Consumer.error_text error)
let after uri = Uri.get_query_param uri "after_sequence"

(* Native fixtures mirror test_tui_native_tasks.ml. *)
let native_receiver : NativeRead.receiver =
  {receiver_generation="child-gen"; session_id="child-session"}
let health = `Assoc ["coverage", `String "issues_observed_in_this_process_only";
  "process_epoch", `String "process"; "historical_failure_coverage", `String "unknown";
  "issues", `List []]
let unknown = ["provider_completeness", `String "unknown";
  "historical_persistence_failures", `String "unknown"]
let native_inventory store through = `Assoc
  (["schema", `String "masc.native_tasks.receivers.v1"; "keeper_name", `String keeper;
    "observed_persistence_health", health; "cleanup_failures", `List [];
    "receivers", `List [`Assoc ["receiver_generation", `String native_receiver.receiver_generation;
      "session_id", `String native_receiver.session_id; "storage", `Assoc ["status", `String "audited";
        "store_id", `String store; "through_sequence", `Int through]]]] @ unknown)
let native_origin ?(task_id="task") ?(call="call") ?(envelope="original-parent-envelope")
    ?(run="run") () : Task.origin =
  {keeper_name=keeper; source=Task.Operation {operation_id="original-operation"};
   attempt={routing_run_id="routing"; runtime_id="claude"; lane_attempt_index=0};
   invocation={receiver_generation=native_receiver.receiver_generation;
     session_id=native_receiver.session_id; client_uuid="input"};
   native_call={session_id=native_receiver.session_id; call_id=call;
     call_envelope_uuid=envelope; call_ordinal=0};
   task_id; run_id=run}
let native_observation ?(origin=native_origin ()) ?(boundary=Task.Task_terminal_unobserved) uuid event =
  match Task.make ~origin ~uuid ~event ~boundary with
  | Ok value -> value | Error detail -> fail detail
let native_registered ?skip ?ambient ?(origin=native_origin ()) uuid =
  native_observation ~origin uuid (Task.Task_registered {subagent_type=Some "worker";
    is_backgrounded=Some true; skip_transcript=skip; ambient})
let native_page store through rows = `Assoc
  (["schema", `String "masc.native_tasks.records.v1"; "keeper_name", `String keeper;
    "receiver_generation", `String native_receiver.receiver_generation;
    "session_id", `String native_receiver.session_id;
    "observed_persistence_health", health; "cleanup_failures", `List [];
    "records", `List (List.map (fun (seq, observation) -> `Assoc
      ["seq", `Int seq; "recorded_at", `Float (float_of_int seq);
       "observation", Task.to_json observation]) rows);
    "validation", `Assoc ["kind", `String "full_committed_history"; "through_sequence", `Int through];
    "next_cursor", `Assoc ["store_id", `String store; "after_sequence", `Int through];
    "terminal_without_observation", `String "unknown"] @ unknown)
let native_load previous ~store ~through ~rows ~after =
  let record_reads = ref 0 in
  let fetch path =
    let uri = Uri.of_string path in
    match Uri.path uri with
    | "/api/v1/keepers/alpha/native-tasks/receivers" ->
        Ok (200, Yojson.Safe.to_string (native_inventory store through))
    | "/api/v1/keepers/alpha/native-tasks/records" ->
        incr record_reads;
        let query = Uri.query uri in
        check (option (list string)) "opaque generation survives query encoding"
          (Some [native_receiver.receiver_generation]) (List.assoc_opt "receiver_generation" query);
        check (option (list string)) "opaque session survives query encoding"
          (Some [native_receiver.session_id]) (List.assoc_opt "session_id" query);
        check (option (list string)) "exact previous suffix boundary"
          (Option.map (fun n -> [string_of_int n]) after) (List.assoc_opt "after_sequence" query);
        check (option (list string)) "opaque cursor incarnation survives query encoding"
          (Option.map (fun _ -> [store]) after) (List.assoc_opt "store_id" query);
        Ok (200, Yojson.Safe.to_string (native_page store through rows))
    | _ -> fail ("unexpected native read path: " ^ path) in
  match Native.read ~mode:Native.Audit ~keeper_name:keeper ~fetch ~previous with
  | Ok state -> state, !record_reads | Error error -> fail (Native.error_text error)

let project_bodies ?native child =
  let state = T.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  state.msg_child_content <- [keeper, child];
  (match native with None -> () | Some tasks -> state.msg_native_tasks <- [keeper, tasks]);
  let (projection : Render.chat_projection) =
    Render.keeper_message_projection state ~keeper_name:keeper ~chat_cols:80 in
  List.map (fun (entry : Layout.entry) -> entry.body) projection.layout_entries

let test_skip_transcript_parent_omits_child_row () =
  let origin_skip = native_origin ~task_id:"task-skip" ~call:"parent"
    ~envelope:"original-parent-envelope" ~run:"run-skip" () in
  let origin_plain = native_origin ~task_id:"task-plain" ~call:"parent-plain"
    ~envelope:"plain-envelope" ~run:"run-plain" () in
  let native, _ = native_load Native.empty ~store:"native-store" ~through:2
    ~rows:[1, native_registered ~origin:origin_skip ~skip:true "native-one";
           2, native_registered ~origin:origin_plain "native-two"]
    ~after:None in
  let child, _ = read Consumer.Poll Consumer.empty [child_receiver, Ok ("child-store", 3)]
    (fun uri ->
      check (option string) "fresh store begins without cursor" None (after uri);
      Ok (200, json (page "child-store" 3
        [row_at 1 1.0 (observation ~body:"omitted-body" ~known:true "obs-skip");
         row_at 2 2.0 (observation ~body:"plain-body" ~known:true ~call_id:"parent-plain"
           ~envelope:"plain-envelope" "obs-plain");
         row_at 3 3.0 (observation ~body:"unknown-body" "obs-unknown")]))) in
  let bodies = project_bodies ~native child in
  check bool "skip_transcript parent omits its child row" false (List.mem "omitted-body" bodies);
  check bool "unmarked parent keeps its child row" true (List.mem "plain-body" bodies);
  check bool "unattributed observation keeps its child row" true (List.mem "unknown-body" bodies)

let test_child_rows_follow_arrival_order_across_stores () =
  let receiver_b : ChildRead.receiver =
    {receiver_generation="child-gen-b"; session_id="child-session-b"; client_uuid="input-b"} in
  let child, requests = read Consumer.Poll Consumer.empty
    [child_receiver, Ok ("store-a", 2); receiver_b, Ok ("store-b", 1)] (fun uri ->
      match Uri.get_query_param uri "client_uuid" with
      | Some id when String.equal id child_receiver.client_uuid ->
          Ok (200, json (page "store-a" 2
            [row_at 1 1.0 (observation ~body:"store-a-first" "obs-a1");
             row_at 2 3.0 (observation ~body:"store-a-third" "obs-a3")]))
      | Some id when String.equal id receiver_b.client_uuid ->
          Ok (200, json (page ~receiver:receiver_b "store-b" 1
            [row_at 1 2.0 (observation ~receiver:receiver_b ~body:"store-b-second" "obs-b2")]))
      | _ -> fail "unexpected child store read") in
  check int "both stores read" 2 (List.length requests);
  let bodies = project_bodies child in
  let child_bodies = List.filter
    (fun body -> List.mem body ["store-a-first"; "store-b-second"; "store-a-third"]) bodies in
  check (list string) "rows follow arrival order, not store order"
    ["store-a-first"; "store-b-second"; "store-a-third"] child_bodies

let layout_entry body : Layout.entry =
  {delivery_state=None; style=Layout.Inbound; heading_boundary=Layout.Start_heading;
   body_presentation=Layout.Source_body; timestamp=""; timeline_bucket=None;
   speaker="CHILD"; role_label="CHILD";
   role_label_mark_cells=Layout.role_label_mark_cells ~style:Layout.Inbound ();
   diagnostics=[]; request_label=""; body; journal=[];
   markdown_source=Layout.Markdown_streaming; turn_rail=Layout.Rail_none;
   action=Layout.Action_none}

let test_redacted_child_anchor_falls_back_to_entry_head () =
  let anchor : T.child_content_anchor =
    {child_receiver={receiver_generation="gen"; session_id="sess"; client_uuid="input"};
     child_store_id="store"; child_observation_id="obs"; child_ordinal=1;
     child_channel=Runtime_claude_code.Text_content} in
  let point : T.chat_scroll_point =
    {scroll_anchor=T.Scroll_durable (T.Search_child anchor);
     body_row=0; source_position=None; rows_below=0} in
  let projection : Render.For_testing.chat_projection =
    {tagged_entries=[]; transient_anchors=[]; layout_entries=[layout_entry "redacted body"]} in
  check (option int) "surviving child anchor holds its entry head" (Some 0)
    (Render.For_testing.surviving_entry_row projection 0 point);
  check (option int) "removed observation acquires no fallback" None
    (Render.For_testing.surviving_entry_row projection 5 point)

let () = run "Child chat projection"
  ["projection",
   [test_case "skip_transcript parent omits its child row" `Quick
      test_skip_transcript_parent_omits_child_row;
    test_case "child rows follow arrival order across stores" `Quick
      test_child_rows_follow_arrival_order_across_stores];
   "scroll",
   [test_case "redacted child anchor falls back to entry head" `Quick
      test_redacted_child_anchor_falls_back_to_entry_head]]
