(** Process-local MSX worker. The host owns installation lifetime and authority;
    this process owns one machine and its MCP tool implementations. *)
module S = Mcp_protocol.Mcp_types
module Server = Mcp_protocol_eio.Server
module Machine = Msx_machine_tools


let response ?(extra_content = []) result : S.tool_result =
  { content = S.TextContent {type_="text";text=Tool_result.message result;annotations=None}
      :: extra_content
  ; is_error = Some (Tool_result.is_failed result)
  ; structured_content = Some (Tool_result.data result)
  ; _meta =
      let fields = match Lane_addon_tool_result.metadata result with Some (`Assoc fields) -> fields | _ -> [] in
      let failure = match Tool_result.failure_class result with
        | None -> []
        | Some Tool_result.Workflow_rejection | Some Tool_result.Policy_rejection ->
            ["io.github.jeong-sik/masc.machine.failure", `String "rejected"]
        | Some (Tool_result.Dependency_unavailable) | Some (Tool_result.Runtime_failure)
        | Some (Tool_result.Operator_cancelled) -> ["io.github.jeong-sik/masc.machine.failure", `String "failed"] in
      Some (`Assoc (failure @ fields)) }

(* What an exception that reached this edge leaves behind for the operator: the
   exception and where it was raised. The result carries only the exception's
   text, so without this line the raise site is lost. A log call can itself
   raise (a terminal that hung up), and that must not replace the typed result
   the caller is waiting for. *)
let report_contained ~what exn backtrace =
  try
    Log.MsxLog.error "%s raised an unexpected exception: %s\n%s" what
      (Printexc.to_string exn) (Printexc.raw_backtrace_to_string backtrace)
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | _ -> ()

(* The one place an escaping exception becomes a result. This process owns the
   only machine and RAM-only state: an exception that leaves a handler ends the
   process and the machine with it, and container logs are not readable. The
   machine operations return typed results for the failures they know (a file
   that will not read, a ledger that will not write); what reaches this edge
   is a defect, reported as a runtime failure whose effect is unknown because
   the exception may follow one, and logged with its backtrace. Cancellation is
   not a failure and passes. *)
let contain ~tool_name ~start_time run =
  match run () with
  | result -> result
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      report_contained ~what:tool_name exn backtrace;
      response (Tool_result.make_err ~tool_name ~start_time
        ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Effect_outcome_unknown
        ("MSX worker raised an unexpected exception: " ^ Printexc.to_string exn))

let contain_message ~what run =
  match run () with
  | result -> result
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      report_contained ~what exn backtrace;
      Error (what ^ " raised an unexpected exception: " ^ Printexc.to_string exn)

let screen ~tool_name ~start_time ~arguments =
  match Msx_lane.capture () with
  | Error error -> response (Machine.of_lane ~tool_name ~start_time (Error error))
  | Ok (observation, frame) ->
      match Msx_worker_png.encode_frame frame with
      | Error message -> response (Tool_result.make_err ~tool_name ~start_time
          ~class_:Tool_result.Runtime_failure message)
      | Ok png -> response
          ~extra_content:[S.ImageContent {type_="image"; data=Base64.encode_string png;
            mime_type="image/png";annotations=None}]
          (Machine.of_lane ~tool_name ~start_time ~sprites:(Tool_args.get_bool arguments "sprites" false) ~extra:[
            "width", `Int frame.width; "height", `Int frame.height;
            "media_type", `String "image/png"] (Ok observation))

let invoke_unguarded ~base_path ~principal ~(tool : Msx_tool.t) ~arguments =
  let actor = match principal with
    | Lane_addon_call_context.Keeper name | Authenticated_agent name | Host_actor name -> name
    | Operator | Anonymous -> Lane_addon_call_context.actor_label principal in
  let name = Msx_tool.name tool in
  let start_time = Tool_timing.start () in
  let asks_for_pixels = match arguments with
    | `Assoc fields -> List.mem_assoc "pixel_response" fields || List.mem_assoc "known_pixels" fields
    | _ -> false in
  match tool with
  | Msx_tool.Screen -> screen ~tool_name:name ~start_time ~arguments
  | Msx_tool.Step when Tool_args.get_bool arguments "include_frame" false ->
    response (Msx_worker_frame.step ~arguments)
  | Msx_tool.Step when asks_for_pixels ->
    response (Tool_result.make_err ~tool_name:name ~start_time
      ~class_:Tool_result.Workflow_rejection ~effect_disposition:Tool_result.Proven_pre_effect
      "pixel_response and known_pixels require include_frame=true")
  | Msx_tool.(Load | Eject | Save | Restore | Export_disk | Change_disk | Meta | Checkpoint_info
             | Press | Step | Step_until_change | Peek | Ram_diff) ->
    let events = ref [] in
    let relay ~author content =
      events := `Assoc ["author", `String author; "content", `String content] :: !events in
    let result = Machine.dispatch ~relay ~base_path ~agent:actor ~tool ~arguments in
    let result = match !events with
      | [] -> result
      | events ->
          let metadata = match Lane_addon_tool_result.metadata result with Some (`Assoc fields) -> fields | _ -> [] in
          Tool_result.with_metadata (`Assoc (("io.github.jeong-sik/masc.machine.events", `List (List.rev events)) :: metadata)) result in
    response result

let invoke ~base_path ~principal ~tool ~arguments =
  contain ~tool_name:(Msx_tool.name tool) ~start_time:(Tool_timing.start ())
    (fun () -> invoke_unguarded ~base_path ~principal ~tool ~arguments)

let live_snapshot () =
  match Msx_lane.live ~since:None with
  | Msx_lane.Nothing_loaded -> `Assoc ["source_kind", `String "msx_capture"; "state", `String "no_machine"]
  | Msx_lane.Unchanged mark -> `Assoc ["source_kind", `String "msx_capture";
      "state", `String "unchanged"; "change_count", `Int mark.count; "incarnation", `String mark.incarnation]
  | Msx_lane.Changed (mark, frame) -> `Assoc ["source_kind", `String "msx_capture";
      "state", `String "changed"; "change_count", `Int mark.count; "incarnation", `String mark.incarnation;
      "frame_number", `Int frame.number; "screen", `Assoc ["format", `String "rgb8";
        "width", `Int frame.width; "height", `Int frame.height;
        "rgb_base64", `String (Base64.encode_string frame.rgb)]]

let observation history () =
  match Msx_lane.capture_with_identity () with
  | Error Msx_lane.No_machine -> Machine_input_history.clear history; Ok (`Assoc ["rows", `List [`Assoc [
      "id", `String "screen"; "lane_id", `String "msx/screen"; "kind", `String "value";
      "title", `String "MSX machine"; "observed_at", `Float (Time_compat.now ());
      "subject_id", `String "msx"; "clock", `Null; "actor", `Null;
      "fields", `Assoc ["machine_loaded", `Bool false; "machine_live", live_snapshot ()]; "evidence", `List []; "related_ids", `List []]];
      "coverage", `List []])
  | Error
      (( Msx_lane.Activity_disabled | Msx_lane.Activity_unobserved
       | Msx_lane.Invalid_request _ | Msx_lane.Effect_unknown _ | Msx_lane.Unreadable _
       | Msx_lane.Dependency_unavailable _ ) as error) ->
    Error (Msx_lane.error_to_string error)
  | Ok capture ->
      let o = capture.Msx_lane.observation in
      let inputs = Machine_input_history.publish history ~incarnation:capture.incarnation
        ~entry_count:capture.input_count ~newest_first:capture.input_ledger in
      Ok (`Assoc [
        "rows", `List [`Assoc [
          "id", `String "screen"; "lane_id", `String "msx/screen";
          "kind", `String "value"; "title", `String "MSX screen";
          "observed_at", `Float (Time_compat.now ());
          "subject_id", `String capture.incarnation;
          "clock", `Assoc ["domain", `String "msx/frame"; "value", `String (string_of_int o.frame)];
          "actor", `Null; "fields", `Assoc (("machine_loaded", `Bool true) :: ("input_history", inputs) :: ("machine_live", live_snapshot ()) :: Machine.observation_fields o);
          "evidence", `List []; "related_ids", `List []]];
        "coverage", `List [`Assoc [
          "source_id", `String "machine"; "incarnation", `String capture.incarnation;
          "cursor", `String (string_of_int capture.input_count);
          "complete", `Bool true; "detail", `Null]]])

let schemas () =
  Msx_tool.all
  |> List.map (fun tool ->
      let name = Msx_tool.name tool in
      match Embedded_config.read ("tools/" ^ name ^ ".toml") with
      | None -> invalid_arg ("missing MSX tool definition: " ^ name)
      | Some contents ->
          match Tool_definition_toml.load ~name ~contents with
          | Ok definition -> tool, definition.Tool_definition_toml.schema
          | Error message -> invalid_arg message)

let definition (schema : Masc_domain.tool_schema) =
  match S.tool_of_yojson (`Assoc ["name", `String schema.name;
      "description", `String schema.description; "inputSchema", schema.input_schema]) with
  | Ok tool -> tool | Error message -> invalid_arg message

let create ~base_path () =
  let history = Machine_input_history.create ~encode:Msx_lane.entry_json () in
  let server = Server.create ~name:"masc-msx-addon" ~version:"0.1.0" () in
  let schemas = schemas () in
  let server = List.fold_left (fun server (_tool, (schema : Masc_domain.tool_schema)) ->
    Server.add_tool (definition schema)
      (fun _context _name _arguments ->
        Ok (response (Tool_result.make_err ~tool_name:schema.name ~start_time:(Tool_timing.start ())
          ~class_:Tool_result.Policy_rejection ~effect_disposition:Tool_result.Proven_pre_effect
          "Machine calls require the host caller-context control port"))) server)
    server schemas in
  let server = Server.tool Lane_addon_call_context.tool_name
    ~description:"Invoke a declared tool with caller context from the owning host."
    ~input_schema:Lane_addon_call_context.input_schema
    (fun _context _name arguments ->
      contain_message ~what:"Machine call" (fun () ->
      match Lane_addon_call_context.of_json (Option.value ~default:`Null arguments) with
      | Error message -> Error message
      | Ok call ->
          match Option.bind (Msx_tool.of_name call.tool) (fun tool ->
              Option.map (fun schema -> tool, schema) (List.assoc_opt tool schemas)) with
          | None -> Error "Unknown exported machine tool"
          | Some (tool, (schema : Masc_domain.tool_schema)) ->
              match Tool_input_contract.check_arguments ~contract:Tool_input_contract.Host_tool ~schema:(Some schema.input_schema)
                  ~name:schema.name ~args:call.arguments with
              | Error error -> Ok (response (Tool_input_contract.rejection_result error))
              | Ok (arguments, _) -> Ok (invoke ~base_path ~principal:call.principal
                  ~tool ~arguments))) server in
  let server = Server.tool Machine_input_history.tool_name
    ~description:"Read a page of the last observed immutable input history."
    ~input_schema:Machine_input_history.input_schema
    (fun _context _name arguments ->
      contain_message ~what:"Input history read" (fun () ->
        Machine_input_history.read history ~arguments:(Option.value ~default:`Null arguments)
        |> Result.map (fun data -> {S.content=[];is_error=Some false;structured_content=Some data;_meta=None}))) server in
  Server.tool "lane_observe" ~description:"Read this worker's MSX screen without advancing the machine."
    ~input_schema:(`Assoc ["type", `String "object"; "properties", `Assoc [
      "binding", `Assoc ["type", `String "object"];
      "sources", `Assoc ["type", `String "array"]]])
    (fun _context _name _arguments ->
      contain_message ~what:"Screen observation" (fun () ->
        match Result.bind (observation history ()) Machine_observation_packet.encode with
        | Error message -> Error message
        | Ok data ->
            Ok {S.content=[S.TextContent {type_="text";text=Yojson.Safe.to_string data;annotations=None}];
                is_error=Some false;structured_content=Some data;_meta=None})) server
