(** Manual, real-model paired evaluation for #37853. This executable never
    builds itself, changes a live Keeper, or treats a fixture as a model answer. *)
open Masc
module T = Agent_core.Types
module Http = Llm_provider.Http_request_observer
module Wire = Llm_provider.Request_wire_observer
let ( let* ) = Result.bind
let sha text = Digestif.SHA256.(to_hex (digest_string text))
let encode value = Yojson.Safe.pretty_to_string value ^ "\n"

type arm = Verbatim | Projected
type task = Question | Comparison | Reuse
let arm_name = function Verbatim -> "verbatim" | Projected -> "projected"
let task_name = function Question -> "question" | Comparison -> "comparison" | Reuse -> "nested_request_reuse"

(* Preserve array order and scalar types, but JSON object field order is not
   part of the operational request's semantic equality. Duplicate keys remain
   distinct, so a submission cannot pass by shadowing an earlier value. *)
let rec canonical : Yojson.Safe.t -> Yojson.Safe.t = function
  | `Assoc fields -> `Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b)
      (List.map (fun (name, value) -> name, canonical value) fields))
  | `List values -> `List (List.map canonical values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value -> value
let equal_json left right = canonical left = canonical right

let save path value =
  Keeper_fs.save_bytes_durable_atomic path (encode value)
  |> Result.map_error Keeper_fs.durable_write_error_to_string

let message_json message =
  let payload = Keeper_provider_input_snapshot.message_payload message in
  Yojson.Safe.from_string payload.payload_bytes
let messages_json messages = `List (List.map message_json messages)
let history_digest messages = sha (Yojson.Safe.to_string (messages_json messages))

type corpus =
  { messages : T.message list
  ; alpha : Yojson.Safe.t
  ; beta : Yojson.Safe.t
  ; alpha_request : Yojson.Safe.t
  ; expected_comparison : Yojson.Safe.t
  }

let corpus () =
  let fresh = Uuidm.v4_gen (Random.State.make_self_init ()) in
  let token () = Uuidm.to_string (fresh ()) in
  let operation_token = token () in
  let request target = `Assoc
    ["argv", `List [`String "inspect"; `String (token ())];
     "target", `String target; "operation_token", `String operation_token] in
  let alpha_request = request (token ()) in
  let beta_request = match alpha_request with
    | `Assoc fields -> `Assoc (List.map (fun (key, value) ->
        key, if key = "target" then `String (token ()) else value) fields)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      invalid_arg "locally constructed request is an object" in
  (* One real reader page cannot expose the operational request. Padding is
     derived from that reader's API boundary, not a runtime budget/gate. *)
  let envelope label request = `Assoc
    ["label", `String label;
     "notes", `String (String.make (Keeper_artifact_read.maximum_max_bytes + 1) 'x');
     "request", request] in
  let alpha = envelope "alpha" alpha_request and beta = envelope "beta" beta_request in
  let exchange id input =
    [T.make_message ~role:T.Assistant [T.ToolUse {id; name="record_request"; input}];
     T.make_message ~role:T.Tool ~tool_call_id:id
       [T.ToolResult {tool_use_id=id; content="Recorded."; outcome=T.Tool_succeeded;
                      json=None; content_blocks=None}]] in
  { messages = T.make_message ~role:T.User [T.Text "Earlier context, already read by the Librarian."]
      :: (exchange "history-alpha" alpha @ exchange "history-beta" beta)
  ; alpha; beta; alpha_request
  ; expected_comparison = `Assoc ["same_argv", `Bool true; "same_target", `Bool false;
                                   "same_operation_token", `Bool true]
  }

let question = function
  | Question -> "For history-alpha, recover the exact nested request object (argv, target, operation_token). Submit that object as answer using submit_answer, then finish."
  | Comparison -> "Compare the nested request objects of history-alpha and history-beta. Submit answer with exactly three booleans: same_argv, same_target, same_operation_token. Compare field values, not the surrounding envelopes or content hashes. Then finish."
  | Reuse -> "Repeat history-alpha's operational request exactly by calling record_request with its nested request object. Omit the historical label and notes. This is a recording tool; no command executes. Then finish."

let system_prompt =
  "Use the supplied history as the source of truth. Historical arguments may be content-addressed JSON references. Use the offered artifact reader to retrieve any needed bytes, including later pages. Do not invent missing fields. Submit once after gathering the evidence. Tool receipts do not grade your answer."

let expected data = function
  | Question -> `Assoc ["answer", data.alpha_request]
  | Comparison -> `Assoc ["answer", data.expected_comparison]
  | Reuse -> `Assoc ["request", data.alpha_request]

let object_schema fields = `Assoc
  ["type", `String "object"; "properties", `Assoc fields;
   "required", `List (List.map (fun (name,_) -> `String name) fields);
   "additionalProperties", `Bool false]
let request_schema = object_schema
  ["argv", `Assoc ["type",`String "array";"items",`Assoc ["type",`String "string"]];
   "target", `Assoc ["type",`String "string"];
   "operation_token", `Assoc ["type",`String "string"]]
let answer_schema = function
  | Question | Reuse -> request_schema
  | Comparison -> object_schema (List.map (fun name -> name,`Assoc ["type",`String "boolean"])
      ["same_argv";"same_target";"same_operation_token"])

let http_event_json (event : Http.event) =
  let phase, detail = match event.phase with
    | Http.Client_entered {mode; body_bytes; body_sha256; tool_inventory=_; request_components} ->
      let components = match request_components with
        | None -> `Null
        | Some Http.Components_unavailable -> `Assoc ["available", `Bool false]
        | Some (Http.Json_object_members {members; framing_bytes}) -> `Assoc
            ["available", `Bool true; "framing_bytes", `Int framing_bytes;
             "members", `List (List.map (fun (member : Http.request_member) -> `Assoc
               ["name", `String member.name; "wire_bytes", `Int member.wire_bytes;
                "value_json_bytes", `Int member.value_json_bytes;
                "value_json_sha256", `String member.value_json_sha256]) members)] in
      "client_entered", ["mode", `String (match mode with Http.Synchronous -> "synchronous" | Streaming -> "streaming");
                         "body_bytes", `Int body_bytes; "body_sha256", `String body_sha256;
                         "components", components]
    | Http.Dispatch_entered -> "dispatch_entered", []
    | Http.Response_headers_received {status} -> "response_headers_received", ["status", `Int status]
    | Http.Client_finished completion -> "client_finished", ["completion", `String
        (match completion with Http.Returned_ok -> "returned_ok" | Returned_error -> "returned_error"
         | Cancelled -> "cancelled" | Raised -> "raised")] in
  `Assoc (["call_id", `Int event.call_id; "phase", `String phase] @ detail)

let prepare_history ~base_path ~trace_id data =
  let* position = Keeper_turn_boundaries.position_of_messages data.messages in
  let record : Keeper_turn_boundaries.record =
    {recorded_at=Time_compat.now (); event=Keeper_turn_boundaries.Turn_ended
       {task_context=Keeper_turn_task_context.No_task;
        turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
        history_at_start=Keeper_turn_boundaries.Fresh_history; position}} in
  let keepers_dir = Workspace.keepers_runtime_dir (Workspace.default_config base_path) in
  let* () = Keeper_turn_boundaries.append ~keepers_dir ~keeper_id:"argument-quality" record
    |> Result.map_error Keeper_turn_boundaries.append_error_to_string in
  match Runtime_model_input_tail_window.atom_opening_digest data.messages 0 with
  | None -> Error "synthetic source has no opening atom"
  | Some last_atom_digest ->
    Keeper_librarian_progress.write ~keepers_dir ~keeper_id:"argument-quality"
      {position={trace_id;end_atom=1;last_atom_digest};boundary_lines_seen=1}
    |> Result.map_error Keeper_librarian_progress.write_error_to_string

type observation =
  { arm : arm
  ; task : task
  ; request_inputs : T.message list list
  ; wire_inputs : T.message list list
  ; tool_schemas : Yojson.Safe.t list
  ; wire : Wire.observation list
  ; http : Http.event list
  ; observer_failures : int
  ; submissions : Yojson.Safe.t list
  ; submission_read_counts : int list
  ; submission_wire_counts : int list
  ; reads : (Yojson.Safe.t * Keeper_artifact_read.page option * int * string) list
  ; result : (Keeper_turn_driver.named_run_result, Agent_core.Error.t) result
  ; source_unchanged : bool
  ; checkpoint_prefix_checks : (string * bool) list
  }

let run_arm ~sw ~net ~root ~runtime_id ~data ~task arm =
  let base_path = Filename.concat root (task_name task ^ "-" ^ arm_name arm) in
  let* () = try Unix.mkdir base_path 0o700; Ok ()
    with Unix.Unix_error (error, operation, _) -> Error (operation ^ ": " ^ Unix.error_message error) in
  let trace_id = "paired-argument-quality" in
  let* () = prepare_history ~base_path ~trace_id data in
  let source_path = Filename.concat base_path "original-history.json" in
  let source = messages_json data.messages in
  let* () = save source_path source in
  let submissions = ref [] and reads = ref [] and inputs = ref [] and wire = ref [] and http = ref [] in
  let wire_inputs = ref [] in
  let submission_read_counts = ref [] in
  let submission_wire_counts = ref [] in
  let checkpoint_prefix_checks = ref [] in
  let checkpoint_sink (snapshot : Agent_core.Agent.checkpoint_snapshot) =
    let path = Filename.concat base_path
      (Printf.sprintf "checkpoint-%d.json" (List.length !checkpoint_prefix_checks)) in
    let* json = Agent_core.Checkpoint.to_json_result snapshot.checkpoint
      |> Result.map_error Agent_core.Error.to_string in
    let* () = save path json in
    let* stored = Eio_unix.run_in_systhread (fun () ->
      try Ok (Yojson.Safe.from_string (In_channel.with_open_bin path In_channel.input_all))
      with Sys_error detail | Yojson.Json_error detail -> Error detail) in
    let* restored = Agent_core.Checkpoint.of_json stored
      |> Result.map_error Agent_core.Error.to_string in
    let prefix = List.take (List.length data.messages) restored.messages in
    checkpoint_prefix_checks := (path, List.equal T.Message_value.equal data.messages prefix)
      :: !checkpoint_prefix_checks;
    Ok () in
  let receipt = Ok {T.content="Recorded.";content_blocks=None;_meta=None} in
  let recorder ~name ~parameter ~value_schema ~description ~grade =
    let* schema = T.tool_schema_of_input_schema ~name ~description
      ~input_schema:(object_schema [parameter,value_schema]) () in
    Ok (Agent_core.Tool.of_schema
      ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
      schema (Agent_core.Tool.ignoring_execution_env (fun input ->
        if grade then (
          submissions := input :: !submissions;
          submission_read_counts := List.length !reads :: !submission_read_counts;
          submission_wire_counts := List.length !wire :: !submission_wire_counts);
        receipt))) in
  let* record_request = recorder ~name:"record_request" ~parameter:"request" ~value_schema:request_schema
    ~description:"Record a request object without executing commands or changing external state."
    ~grade:(match task with Reuse -> true | Question | Comparison -> false) in
  let* submit_answer = recorder ~name:"submit_answer" ~parameter:"answer" ~value_schema:(answer_schema task)
    ~description:"Record your answer object. This tool gives no correctness feedback."
    ~grade:(match task with Question | Comparison -> true | Reuse -> false) in
  let schema = Keeper_runtime_schemas_toml.artifact_read in
  let reader = Tool_bridge.agent_core_tool_of_masc_with_execution_env ~base_path
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name:schema.name ~description:schema.description ~input_schema:schema.input_schema
    (fun _ args ->
      let execution, page = Keeper_artifact_read.handle_with_page ~base_path ~args in
      let result = match execution.disposition with
      | Tool_result.Completed () -> Tool_result.make_ok ~tool_name:schema.name
          ~start_time:(Tool_timing.start ()) ?data:execution.data ()
      | Tool_result.Failed class_ -> Tool_result.make_err ~tool_name:schema.name ~class_
          ~start_time:(Tool_timing.start ()) execution.raw_output
      | Tool_result.Deferred () -> Tool_result.make_err ~tool_name:schema.name
          ~class_:Tool_result.Runtime_failure ~start_time:(Tool_timing.start ()) "Unexpected deferred artifact read" in
      reads := (args, page, List.length !wire, Tool_result.message result) :: !reads;
      result) in
  let tools = [record_request;submit_answer;reader] in
  let observer = Http.create (fun event -> http := event :: !http; Ok ()) in
  let argument_demotion_seed = match arm with Verbatim -> None | Projected -> Some data.messages in
  let result = Http.with_observer observer (fun () ->
    Keeper_turn_driver.run_named ~raw_trace:None ~walk_owner:Keeper_turn_driver.One_shot_walk
      ~runtime_id ~keeper_name:"argument-quality" ~base_path ~session_id:trace_id
      ~input_policy:Keeper_input_policy.Small ?argument_demotion_seed
      ~system_prompt ~goal:(question task) ~initial_messages:data.messages
      ~tools ~agent_core_tools:tools ~checkpoint_sink ~sw ~net
      ~model_input_projection:(fun messages -> inputs := messages :: !inputs; Ok messages)
      ~on_request_wire_observation:(fun ~runtime_id:_ ~body_bytes:_ ~serialized ->
        Option.iter (fun observation ->
          wire := observation :: !wire;
          wire_inputs := (match !inputs with [] -> [] | latest::_ -> latest) :: !wire_inputs) serialized) ()) in
  let* stored_source = try Ok (In_channel.with_open_bin source_path In_channel.input_all)
    with Sys_error detail -> Error detail in
  let tool_schemas = List.map (fun tool ->
    Yojson.Safe.from_string (Keeper_provider_input_snapshot.tool_schema_payload tool).payload_bytes) tools in
  Ok {arm;task;request_inputs=List.rev !inputs;wire_inputs=List.rev !wire_inputs;
      tool_schemas;wire=List.rev !wire;http=List.rev !http;
      observer_failures=Http.delivery_failure_count observer;
      submissions=List.rev !submissions;reads=List.rev !reads;result;
      submission_read_counts=List.rev !submission_read_counts;
      submission_wire_counts=List.rev !submission_wire_counts;
      source_unchanged=stored_source=encode source && history_digest data.messages=sha (Yojson.Safe.to_string source);
      checkpoint_prefix_checks=List.rev !checkpoint_prefix_checks}

let page_json = function
  | None -> `Null
  | Some (page : Keeper_artifact_read.page) -> `Assoc
      ["sha256", `String page.sha256; "offset", `Int page.offset; "next_offset", `Int page.next_offset;
       "total_bytes", `Int page.total_bytes; "eof", `Bool page.eof;
       "encoding", `String (match page.encoding with Keeper_artifact_read.Utf_8 -> "utf8" | Base64 -> "base64");
       "content", `String page.content]

let result_json = function
  | Error error -> `Assoc ["ok", `Bool false; "error", `String (Agent_core.Error.to_string error)]
  | Ok (named : Keeper_turn_driver.named_run_result) -> `Assoc
      ["ok", `Bool true; "selected_runtime", `String named.selected_runtime_id;
       "lane_attempt", `Int named.lane_attempt_index;
       "response",
       (* [Execution_provider_response_snapshot] is private to agent_core; serialize
          the same api_response fields through the public provider codecs. *)
       (let r = named.run_result.response in
        `Assoc
          [ "id", `String r.Agent_core.Llm_provider.Types.id
          ; "model", `String r.model
          ; "stop_reason",
            `String (Agent_core.Llm_provider.Types.stop_reason_to_string r.stop_reason)
          ; "content",
            `List (List.map Agent_core.Llm_provider.Api_common.content_block_to_json r.content) ])]

let observation_json (observed : observation) = `Assoc
  ["arm", `String (arm_name observed.arm); "task", `String (task_name observed.task);
   "canonical_inputs", `List (List.map messages_json observed.request_inputs);
   "canonical_inputs_at_each_wire_observation", `List (List.map messages_json observed.wire_inputs);
   "tool_schemas", `List observed.tool_schemas;
   "canonical_capture_scope", `String "after transmitted-history dialect replay projection and bounded range/demotion; before final unread normalization and backend merge/prefix verification/serialization";
   "wire", `List (List.map Wire.observation_to_yojson observed.wire);
   "http", `List (List.map http_event_json observed.http);
   "observer_failures", `Int observed.observer_failures;
   "submissions", `List observed.submissions;
   "reader_calls_before_each_submission", `List (List.map (fun count -> `Int count) observed.submission_read_counts);
   "prepared_request_count_at_each_submission", `List (List.map (fun count -> `Int count) observed.submission_wire_counts);
   "artifact_reads", `List (List.map (fun (args, page, round, result_content) ->
     `Assoc ["args",args;"page",page_json page;"prepared_request_count",`Int round;
             "handler_result_content",`String result_content]) observed.reads);
   "source_unchanged", `Bool observed.source_unchanged;
   "persisted_checkpoint_prefix_checks", `List (List.map (fun (path, unchanged) ->
     `Assoc ["path", `String path;"original_prefix_unchanged", `Bool unchanged]) observed.checkpoint_prefix_checks);
   "result", result_json observed.result]

let historical_inputs messages = List.concat_map (fun (message : T.message) ->
  List.filter_map (function
    | T.ToolUse {id;input;_} -> Some (id,input)
    | T.Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolResult _ | Image _ | Document _ | Audio _ -> None)
    message.content) messages

let first_inputs observed = match observed.wire_inputs with
  | [] -> [] | first :: _ -> historical_inputs first

let first_request_pair_equal_except_arguments data baseline projected =
  let restore messages = List.map (fun (message : T.message) ->
    {message with content=List.map (function
       | T.ToolUse ({id;_} as call) ->
         let input = match id with
           | "history-alpha" -> data.alpha | "history-beta" -> data.beta | _ -> call.input in
         T.ToolUse {call with input}
       | (T.Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolResult _ | Image _ | Document _ | Audio _) as block -> block)
      message.content}) messages in
  match baseline.wire_inputs, projected.wire_inputs with
  | before :: _, after :: _ ->
    List.equal T.Message_value.equal (restore before) (restore after)
    && baseline.tool_schemas=projected.tool_schemas
  | [], _ | _, [] -> false

let hidden_request_read data observed =
  let contains_result result_content messages =
    List.exists (fun (message : T.message) -> List.exists (function
      | T.ToolResult {content;_} -> content=result_content
      | T.Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _ | Image _ | Document _ | Audio _ -> false)
      message.content) messages in
  let reads_before_submission = match observed.submission_read_counts,observed.submission_wire_counts with
    | [count],[submission_round] -> List.take count observed.reads
        |> List.filter (fun (_,_,read_round,result_content) -> read_round<submission_round
             && List.exists (contains_result result_content)
               (List.take (submission_round-read_round) (List.drop read_round observed.wire_inputs)))
    | ([] | _::_::_),_ | _,([] | _::_::_) -> [] in
  let originals = match observed.task with
    | Question | Reuse -> [data.alpha,data.alpha_request]
    | Comparison ->
      let beta_request = Yojson.Safe.Util.member "request" data.beta in
      [data.alpha,data.alpha_request;data.beta,beta_request] in
  List.for_all (fun (original, request) ->
    let bytes = Yojson.Safe.to_string original and request_bytes = Yojson.Safe.to_string request in
    let required_start = String.length bytes - String.length request_bytes - 1 in
    let required_end = String.length bytes - 1 in
    let spans = List.filter_map (fun (_, page, _, _) -> match page with
      | Some (page : Keeper_artifact_read.page) when page.sha256=sha bytes -> Some (page.offset,page.next_offset)
      | Some _ | None -> None) reads_before_submission |> List.sort Stdlib.compare in
    let covered = List.fold_left (fun cursor (start, stop) ->
      if start<=cursor then max cursor stop else cursor) required_start spans in
    covered>=required_end) originals

let valid_projection data baseline projected =
  let sources = ["history-alpha",data.alpha;"history-beta",data.beta] in
  List.for_all (fun (id, original) ->
    match List.assoc_opt id (first_inputs baseline), List.assoc_opt id (first_inputs projected) with
    | Some before, Some after when equal_json before original ->
      (match Tool_output.normalized_artifact_ref_of_json after with
       | Tool_output.Decoded_normalized_artifact_ref reference ->
         reference.sha256=sha (Yojson.Safe.to_string original)
         && reference.bytes=String.length (Yojson.Safe.to_string original)
         (* The real producer must expose only a strict prefix ending in the
            notes, before any hidden operational field. *)
         && String.length reference.preview < String.length (Yojson.Safe.to_string original)
         && String.starts_with ~prefix:reference.preview (Yojson.Safe.to_string original)
         && not (String_util.contains_substring reference.preview "\"request\"")
       | Tool_output.Not_normalized_artifact_ref | Invalid_normalized_artifact_ref _ -> false)
    | None, _ | _, None | Some _, Some _ -> false) sources

let successful_submission data observed =
  match observed.result, observed.submissions with
  | Ok _, [submission] -> equal_json submission (expected data observed.task)
  | Error _, _ | Ok _, ([] | _ :: _ :: _) -> false

let wire_identities observed = List.map (fun (wire : Wire.observation) ->
  wire.provider,wire.model,wire.http_codec) observed.wire |> List.sort_uniq Stdlib.compare

let paired_report data baseline projected =
  let same_runtime = match baseline.result,projected.result,wire_identities baseline,wire_identities projected with
    | Ok before,Ok after,[left],[right] ->
      left=right && before.selected_runtime_id=after.selected_runtime_id
      && before.run_result.response.model=after.run_result.response.model
      && before.lane_attempt_index=0 && after.lane_attempt_index=0
    | (Error _,_,_,_ | _,Error _,_,_ | _,_,[],_ | _,_,_,[]
      | _,_,_::_::_,_ | _,_,_,_::_::_) -> false in
  let projection = valid_projection data baseline projected in
  let same_inputs = first_request_pair_equal_except_arguments data baseline projected in
  let retrieval = hidden_request_read data projected in
  let durable observed = observed.checkpoint_prefix_checks<>[]
    && List.for_all snd observed.checkpoint_prefix_checks in
  let complete_wire observed =
    let entered = List.filter_map (fun (event : Http.event) -> match event.phase with
      | Http.Client_entered {body_sha256;body_bytes;_} -> Some (event.call_id,body_sha256,body_bytes)
      | Dispatch_entered | Response_headers_received _ | Client_finished _ -> None) observed.http in
    let rec join wires calls = match wires,calls with
      | [],[] -> true
      | [],_::_ | _::_,[] -> false
      | (wire : Wire.observation)::rest,(call_id,digest,bytes)::remaining ->
        if digest<>wire.body_sha256 || bytes<>wire.body_bytes then false else
        let has predicate = List.exists (fun (event : Http.event) -> event.call_id=call_id && predicate event.phase) observed.http in
        has (function Http.Dispatch_entered -> true | Client_entered _ | Response_headers_received _ | Client_finished _ -> false)
        && has (function Http.Response_headers_received {status} -> status>=200 && status<300
                         | Client_entered _ | Dispatch_entered | Client_finished _ -> false)
        && has (function Http.Client_finished Http.Returned_ok -> true
                         | Client_finished (Returned_error | Cancelled | Raised)
                         | Client_entered _ | Dispatch_entered | Response_headers_received _ -> false)
        && join rest remaining in
    observed.wire<>[] && observed.observer_failures=0 && join observed.wire entered in
  let baseline_pass = successful_submission data baseline and projected_pass = successful_submission data projected in
  let measured = same_runtime && projection && same_inputs
    && durable baseline && durable projected && baseline.source_unchanged && projected.source_unchanged
    && complete_wire baseline && complete_wire projected in
  let classification = if not measured then "inconclusive"
    else match baseline_pass, projected_pass, retrieval with
      | true,true,true -> "retained" | true,false,_ -> "regression"
      | false,true,true -> "improved" | false,false,_ -> "both_failed"
      | (true | false),true,false -> "correct_without_retrieval_evidence" in
  let first_bytes observed = match observed.wire with [] -> `Null | first :: _ -> `Int first.body_bytes in
  let total_bytes observed = List.fold_left (fun sum (wire : Wire.observation) -> sum+wire.body_bytes) 0 observed.wire in
  let submitted_bytes observed = List.fold_left (fun sum (event : Http.event) -> match event.phase with
    | Http.Client_entered {body_bytes;_} -> sum+body_bytes
    | Dispatch_entered | Response_headers_received _ | Client_finished _ -> sum) 0 observed.http in
  `Assoc ["task", `String (task_name baseline.task); "classification", `String classification;
          "same_observed_provider_model_codec", `Bool same_runtime; "actual_projection", `Bool projection;
          "same_first_canonical_inputs_except_arguments_and_same_tools", `Bool same_inputs;
          "projected_hidden_request_region_read", `Bool retrieval;
          "verbatim_durable_original_prefix_preserved", `Bool (durable baseline);
          "projected_durable_original_prefix_preserved", `Bool (durable projected);
          "baseline_correct", `Bool baseline_pass; "projected_correct", `Bool projected_pass;
          "verbatim_first_request_bytes", first_bytes baseline; "projected_first_request_bytes", first_bytes projected;
          "verbatim_total_serialized_bytes", `Int (total_bytes baseline);
          "projected_total_serialized_bytes", `Int (total_bytes projected);
          "verbatim_total_http_client_submitted_bytes", `Int (submitted_bytes baseline);
          "projected_total_http_client_submitted_bytes", `Int (submitted_bytes projected);
          "verbatim_requests", `Int (List.length baseline.wire); "projected_requests", `Int (List.length projected.wire)]

let main () =
  let config = ref "" and runtime = ref "" and output = ref "" in
  Arg.parse ["--runtime-config", Arg.Set_string config, "Explicit runtime TOML";
             "--runtime-id", Arg.Set_string runtime, "One explicitly selected runtime binding";
             "--output-dir", Arg.Set_string output, "New private output directory"]
    (fun argument -> raise (Arg.Bad ("Unexpected argument: " ^ argument)))
    "keeper_argument_quality_cli --runtime-config FILE --runtime-id ID --output-dir NEW_DIR";
  let* () = if List.exists (fun value -> String.trim !value="") [config;runtime;output]
    then Error "all three options are required" else Ok () in
  let config_path = Config_dir_resolver.absolute_path !config and root = Config_dir_resolver.absolute_path !output in
  let* config_bytes = try Ok (In_channel.with_open_bin config_path In_channel.input_all)
    with Sys_error detail -> Error detail in
  let* () = try Unix.mkdir root 0o700; Ok ()
    with Unix.Unix_error (error, operation, _) -> Error (operation ^ ": " ^ Unix.error_message error) in
  let (_ : string option) = Server_runtime_bootstrap.configure_agent_core_model_catalog_env () in
  let* () = Runtime.init_default_strict ~config_path in
  let* () = match Runtime.get_runtime_by_id !runtime with
    | None -> Error "runtime-id must name an active concrete binding, not a lane or an implicit default"
    | Some runtime -> match runtime.Runtime_instance.execution with
      | Runtime_execution.Agent_core _ -> Ok ()
      | Codex_app_server _ | Antigravity_cli _ | Claude_code _ | Muse_serve _ ->
        Error "this paired runner measures the AgentCore projection; official-client evaluation remains a separate required scope" in
  let data = corpus () in
  let* () = save (Filename.concat root "corpus.json") (`Assoc
    ["provenance", `String "synthetic"; "history",messages_json data.messages;
     "history_sha256", `String (history_digest data.messages);
     "oracle", `List (List.map (fun task -> `Assoc ["task", `String (task_name task);"expected",expected data task])
                        [Question;Comparison;Reuse])]) in
  let build_identity = Build_identity.to_yojson (Build_identity.current ()) in
  let pairs = ref [] in
  let report () = `Assoc
    ["schema", `String "masc.completed-argument-quality.v1"; "provenance", `String "synthetic";
     "build_identity", build_identity; "runtime_id", `String !runtime;
     "runtime_config_sha256", `String (sha config_bytes); "system_prompt", `String system_prompt;
     "scope", `String "AgentCore real model, Small in both arms; nested operational request reuse, not full envelope reuse; no official-client or fleet claim";
     "issue_acceptance", `String "not_established";
     "pairs", `List (List.rev !pairs)] in
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Time_compat.set_clock env#clock;
    Eio_context.set_env env; Eio_context.set_switch sw; Eio_context.set_net env#net;
    Eio_context.set_clock env#clock; Eio_context.set_mono_clock env#mono_clock; Fs_compat.set_fs env#fs;
    Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
      let rec loop = function
        | [] -> Ok ()
        | task :: rest ->
          let* baseline = run_arm ~sw ~net:env#net ~root ~runtime_id:!runtime ~data ~task Verbatim in
          let* () = save (Filename.concat root (task_name task ^ "-verbatim.json")) (observation_json baseline) in
          let* projected = run_arm ~sw ~net:env#net ~root ~runtime_id:!runtime ~data ~task Projected in
          let* () = save (Filename.concat root (task_name task ^ "-projected.json")) (observation_json projected) in
          pairs := paired_report data baseline projected :: !pairs;
          let* () = save (Filename.concat root "report.json") (report ()) in
          loop rest in
      loop [Question;Comparison;Reuse])))

let () = match main () with Ok () -> () | Error detail -> prerr_endline detail; exit 1
