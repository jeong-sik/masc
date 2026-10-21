module S = Mcp_protocol.Mcp_types
module Server = Mcp_protocol_eio.Server
module Controller = Machine_controller_contract

let response ?(extra_content = []) result : S.tool_result =
  { content = S.TextContent {type_="text";text=Tool_result.message result;annotations=None} :: extra_content
  ; is_error = Some (Tool_result.is_failed result)
  ; structured_content = Some (Tool_result.data result)
  ; _meta = Lane_addon_tool_result.metadata result }

let json_response data : S.tool_result =
  { content = [S.TextContent {type_="text";text=Yojson.Safe.to_string data;annotations=None}];
    is_error=Some false;structured_content=Some data;_meta=None }

(* The one place an exception that escaped a handler stops. The MCP server
   loop does not catch handler exceptions, and the worker is the process that
   holds the machine, so an exception left to run its course ends the worker
   and the machine with it. The container's log driver is [none], so the
   exception and its backtrace ride in the result: they are the only record.

   The outcome is [Effect_outcome_unknown]: the exception says nothing about
   whether the call moved the machine. Cancellation is not a failure of the
   call and goes on unwinding. *)
let failed_by_exception ~tool_name ~start_time exn : S.tool_result =
  let backtrace = Printexc.get_backtrace () in
  let described = Printexc.to_string exn in
  let data =
    `Assoc
      (("exception", `String described)
       :: (if backtrace = "" then [] else [ ("backtrace", `String backtrace) ]))
  in
  response
    (Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time
       ~effect_disposition:Tool_result.Effect_outcome_unknown ~data
       (Printf.sprintf
          "%s raised %s inside the DOS worker. The worker is still running and the \
           machine may have moved: read masc_dos_screen before sending more input."
          tool_name described))
;;

let contained ~tool_name f =
  let start_time = Tool_timing.start () in
  match f () with
  | result -> result
  | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
  | exception exn -> Ok (failed_by_exception ~tool_name ~start_time exn)
;;

let guarded name ?description ?input_schema handler server =
  Server.tool name ?description ?input_schema
    (fun context tool_name arguments ->
      contained ~tool_name:name (fun () -> handler context tool_name arguments))
    server

let schemas () = List.map (fun tool ->
  let name = Controller.dos_tool_name tool in
  match Embedded_config.read ("tools/" ^ name ^ ".toml") with
  | None -> invalid_arg ("missing DOS tool definition: " ^ name)
  | Some contents -> match Tool_definition_toml.load ~name ~contents with
    | Ok definition -> tool, definition.Tool_definition_toml.schema
    | Error message -> invalid_arg message) Controller.all_of_dos_tool

let definition (schema : Masc_domain.tool_schema) =
  match S.tool_of_yojson (`Assoc ["name", `String schema.name;
    "description", `String schema.description; "inputSchema", schema.input_schema]) with
  | Ok tool -> tool | Error message -> invalid_arg message

let create ~base_path () =
  let history = Machine_input_history.create ~encode:Dos_lane.entry_json () in
  let events = ref [] in
  let module Machine = Dos_machine_tools.Make (struct
    let relay ~author content =
      events := `Assoc ["author", `String author; "content", `String content] :: !events
    let parse_controller value =
      Validation.Id_shape.parse value |> Result.map (fun _ -> value)
  end) in
  let mutex = Eio.Mutex.create () in
  let holder () =
    match Machine.off_domain Dos_lane.screen with
    | Ok observation -> Ok observation.Dos_lane.controller
    | Error Dos_lane.No_machine -> Ok None
    | Error
        (( Dos_lane.Activity_disabled
         | Dos_lane.Activity_unobserved
         | Dos_lane.Invalid_request _
         | Dos_lane.Unreadable _
         | Dos_lane.Held_by _
         | Dos_lane.Guest_fault _
         | Dos_lane.Unsaveable _
         | Dos_lane.Checkpoint_refused _
         | Dos_lane.Other_program _
         | Dos_lane.Would_discard_previous_autosave _ ) as error) -> Error (Dos_lane.error_to_string error) in
  let authorize ~tool (call : Lane_addon_call_context.t) =
    let need = Controller.controller_need tool in
    let controlled = match need with
      | Controller.Takes_controller | Controller.Hands_controller -> true
      | Controller.No_controller -> false in
    let ( let* ) = Result.bind in
    let* actor = match call.principal with
      | Keeper name | Authenticated_agent name | Host_actor name ->
          Validation.Id_shape.parse name |> Result.map (fun _ -> name)
      | (Operator | Anonymous) as principal ->
          if controlled || tool = Controller.Dos_save then
            Error "DOS controller calls require a verified named host principal"
          else Ok (Lane_addon_call_context.actor_label principal) in
    let* released_controller = if not controlled then Ok false else
      match call.controller with
      | None -> Error "DOS controller operations require host admission"
      | Some admission ->
          let* current = holder () in
          if current <> admission.observed_holder then Error "DOS controller changed since host admission"
          else
            let* () = match need with
              | Controller.Hands_controller ->
                  let* target = Machine.pass_target call.arguments in
                  if target = admission.handoff_target then Ok ()
                  else Error "DOS handoff target differs from host admission"
              | Controller.Takes_controller | Controller.No_controller -> Ok () in
            (match admission.observed_holder, admission.release with
             | Some departed, Some reason when not (String.equal departed actor) ->
                 (match Machine.off_domain (fun () -> Dos_lane.release_left ~holder:departed
                   ~announce:(Machine.announce ~author:actor (Machine.departure_notice departed reason))) with
                  | Ok true -> Ok true
                  | Ok false -> Error "DOS controller changed before release"
                  | Error error -> Error (Dos_lane.error_to_string error))
             | _, None -> Ok false
             | None, Some _ | Some _, Some _ -> Error "invalid DOS controller release admission") in
    Ok (actor, released_controller) in
  let invoke ~released_controller ~actor ~tool ~arguments =
    let result = Machine.dispatch ~base_path ~agent:actor ~tool ~arguments in
    let result = match result with
      | Tool_result.Failed failure when released_controller ->
          Tool_result.Failed {failure with effect_disposition=Tool_result.Proven_post_effect}
      | (Tool_result.Completed _ | Tool_result.Deferred _ | Failed _) as result -> result in
    response result in
  let screen ~arguments () =
    let tool_name = Controller.dos_tool_name Controller.Dos_screen
    and start_time = Tool_timing.start () in
    let failure code result =
      let answer = response result in
      let fields = match answer.S._meta with Some (`Assoc fields) -> fields | None | Some _ -> [] in
      {answer with S._meta = Some (`Assoc (
        ("io.github.jeong-sik/masc.machine.screenError", `String code) :: fields))} in
    match Machine.capture_png () with
    | Error (Machine.Lane Dos_lane.No_machine) ->
        failure "no_machine" (Machine.of_lane ~base_path ~tool_name ~start_time (Error Dos_lane.No_machine))
    | Error
        (Machine.Lane
           (( Dos_lane.Activity_disabled
            | Dos_lane.Activity_unobserved
            | Dos_lane.Invalid_request _
            | Dos_lane.Unreadable _
            | Dos_lane.Held_by _
            | Dos_lane.Guest_fault _
            | Dos_lane.Unsaveable _
            | Dos_lane.Checkpoint_refused _
            | Dos_lane.Other_program _
         | Dos_lane.Would_discard_previous_autosave _ ) as error)) -> failure "capture_failed" (Machine.of_lane ~base_path ~tool_name ~start_time (Error error))
    | Error (Machine.Encode message) -> failure "encode_failed" (Machine.image_capture_failed ~tool_name ~start_time message)
    | Ok {observation; width; height; png} ->
        let pad = if not (Tool_args.get_bool arguments "include_pad" false) then [] else
          let value = match observation.Dos_lane.saves_name with
            | None -> `Assoc ["kind", `String "no_machine"]
            | Some saves_name ->
                match Machine.off_domain (fun () -> Dos_pad.load ~base_path ~saves_name) with
                | Ok (Some (source, layout)) -> `Assoc ["kind", `String "ready";
                    "layout", Machine_pad_layout.to_json ~saves_name ~source layout]
                | Ok None -> `Assoc ["kind", `String "missing"; "saves_name", `String saves_name]
                | Error message -> `Assoc ["kind", `String "invalid"; "message", `String message] in
          ["pad", value] in
        response ~extra_content:[S.ImageContent {type_="image"; data=Base64.encode_string png;
          mime_type="image/png"; annotations=None}]
          (Machine.of_lane ~base_path ~tool_name ~start_time
            ~extra:(Machine.png_fields ~width ~height ~png @ [Machine.core_field] @ pad) (Ok observation)) in
  let schemas = schemas () in
  let server = Server.create ~name:"masc-dos-addon" ~version:"0.1.0" () in
  let server = List.fold_left (fun server (_tool, (schema : Masc_domain.tool_schema)) ->
    Server.add_tool (definition schema) (fun _context _name _arguments ->
      Ok (response (Tool_result.make_err ~tool_name:schema.name ~start_time:(Tool_timing.start ())
        ~class_:Tool_result.Policy_rejection ~effect_disposition:Tool_result.Proven_pre_effect
        "Machine calls require the host caller-context control port"))) server) server schemas in
  let server = guarded Controller.release_tool
    ~description:"Release only the named controller under the owning host's lifecycle authority."
    ~input_schema:Lane_addon_call_context.input_schema
    (fun _context _name arguments -> Eio.Mutex.use_ro mutex (fun () ->
      let ( let* ) = Result.bind in
      let* call = Lane_addon_call_context.of_json (Option.value ~default:`Null arguments) in
      let* () = if call.tool = Controller.release_tool && call.arguments = `Assoc [] then Ok ()
        else Error "invalid controller-release envelope" in
      let* by = match call.principal with
        | Keeper name | Authenticated_agent name | Host_actor name ->
            Validation.Id_shape.parse name |> Result.map (fun _ -> name)
        | Operator | Anonymous -> Error "controller release requires a named host principal" in
      let* holder, reason = match call.controller with
        | Some {observed_holder=Some holder;release=Some reason;handoff_target=None} -> Ok (holder,reason)
        | _ -> Error "controller release requires a named holder and departure reason" in
      events := [];
      let released = Machine.off_domain (fun () -> Dos_lane.release_left ~holder
        ~announce:(Machine.announce ~author:by (Machine.departure_notice holder reason))) in
      Machine.flush_announcements ();
      let answer = match released with
        | Ok released -> json_response (`Assoc ["released", `Bool released])
        | Error Dos_lane.No_machine -> json_response (`Assoc ["released", `Bool false])
        | Error
            (( Dos_lane.Activity_disabled
             | Dos_lane.Activity_unobserved
             | Dos_lane.Invalid_request _
             | Dos_lane.Unreadable _
             | Dos_lane.Held_by _
             | Dos_lane.Guest_fault _
             | Dos_lane.Unsaveable _
             | Dos_lane.Checkpoint_refused _
             | Dos_lane.Other_program _
         | Dos_lane.Would_discard_previous_autosave _ ) as error) -> response (Machine.reject ~tool_name:Controller.release_tool
            ~start_time:(Tool_timing.start ()) (Dos_lane.error_to_string error)) in
      Ok {answer with S._meta=Some (`Assoc ["io.github.jeong-sik/masc.machine.events",
        `List (List.rev !events)])})) server in
  let server = guarded Controller.snapshot_tool
    ~description:"Read the current controller for host credential admission."
    ~input_schema:(`Assoc ["type", `String "object"; "additionalProperties", `Bool false])
    (fun _context _name _arguments -> Eio.Mutex.use_ro mutex (fun () ->
      Result.map (fun holder -> json_response (`Assoc ["holder",
        (match holder with None -> `Null | Some name -> `String name)])) (holder ()))) server in
  let server = guarded Lane_addon_call_context.tool_name
    ~description:"Execute a machine tool with verified host identity and controller admission."
    ~input_schema:Lane_addon_call_context.input_schema
    (fun _context _name arguments -> Eio.Mutex.use_ro mutex (fun () ->
      let ( let* ) = Result.bind in
      let* call = Lane_addon_call_context.of_json (Option.value ~default:`Null arguments) in
      let* tool, schema =
        match Option.bind (Controller.dos_tool_of_name call.tool) (fun tool ->
          Option.map (fun schema -> tool, schema) (List.assoc_opt tool schemas)) with
        | Some found -> Ok found | None -> Error "Unknown exported machine tool" in
      match Tool_input_contract.check_arguments ~contract:Tool_input_contract.Host_tool ~schema:(Some schema.input_schema)
        ~name:schema.name ~args:call.arguments with
      | Error error -> Ok (response (Tool_input_contract.rejection_result error))
      | Ok (arguments, _) ->
          events := [];
          let start_time = Tool_timing.start () in
          (* An exception still leaves the lines the call queued: a load or a
             restore announces under the lane lock before anything else can
             raise, and those lines belong to a machine that did change. They
             go out with this call's events, with the failure as its answer. *)
          let answer =
            match
              match authorize ~tool call with
              | Error message -> response (Machine.reject ~tool_name:call.tool
                  ~start_time message)
              | Ok (actor, released_controller) ->
                  if tool = Controller.Dos_screen then screen ~arguments ()
                  else invoke ~released_controller ~actor ~tool ~arguments
            with
            | answer -> answer
            | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
            | exception exn -> failed_by_exception ~tool_name:call.tool ~start_time exn in
          Machine.flush_announcements ();
          let metadata = match answer.S._meta with Some (`Assoc fields) -> fields | _ -> [] in
          Ok { answer with S._meta = Some (`Assoc
            (("io.github.jeong-sik/masc.machine.events", `List (List.rev !events)) :: metadata)) })) server in
  let server = guarded Machine_input_history.tool_name
    ~description:"Read a page of the last observed immutable input history."
    ~input_schema:Machine_input_history.input_schema
    (fun _context _name arguments -> Eio.Mutex.use_ro mutex (fun () ->
      Machine_input_history.read history ~arguments:(Option.value ~default:`Null arguments)
      |> Result.map (fun data -> {S.content=[];is_error=Some false;structured_content=Some data;_meta=None}))) server in
  let live_snapshot () =
    let fields = match Machine.off_domain (fun () -> Dos_lane.live ~since:None) with
      | Dos_lane.Nothing_loaded -> ["state", `String "no_machine"]
      | Dos_lane.Unchanged mark -> ["state", `String "unchanged";
          "change_count", `Int mark.count; "incarnation", `String mark.incarnation]
      | Dos_lane.Changed (mark, frame) -> ["state", `String "changed";
          "change_count", `Int mark.count; "incarnation", `String mark.incarnation;
          "screen", `Assoc ["format", `String "rgb8"; "width", `Int frame.width;
            "height", `Int frame.height; "rgb_base64", `String (Base64.encode_string frame.rgb)]] in
    `Assoc (["source_kind", `String "dos_capture";
      "activity", Machine_action_feed.to_json_list (Dos_lane.recent_activity ())] @ fields) in
  guarded "lane_observe" ~description:"Read this worker's DOS screen without advancing the machine."
    ~input_schema:(`Assoc ["type", `String "object"; "properties", `Assoc [
      "binding", `Assoc ["type", `String "object"]; "sources", `Assoc ["type", `String "array"]]])
    (fun _context _name _arguments -> Eio.Mutex.use_ro mutex (fun () ->
      let observed = match Machine.off_domain Dos_lane.capture_with_identity with
      | Error Dos_lane.No_machine -> Machine_input_history.clear history; Ok (json_response (`Assoc ["rows", `List [`Assoc [
          "id", `String "screen"; "lane_id", `String "dos/screen"; "kind", `String "value";
          "title", `String "DOS machine"; "observed_at", `Float (Time_compat.now ());
          "subject_id", `String "dos"; "clock", `Null; "actor", `Null;
          "fields", `Assoc ["machine_loaded", `Bool false; "machine_live", live_snapshot ()]; "evidence", `List []; "related_ids", `List []]];
          "coverage", `List []]))
      | Error
          (( Dos_lane.Activity_disabled
           | Dos_lane.Activity_unobserved
           | Dos_lane.Invalid_request _
           | Dos_lane.Unreadable _
           | Dos_lane.Held_by _
           | Dos_lane.Guest_fault _
           | Dos_lane.Unsaveable _
           | Dos_lane.Checkpoint_refused _
           | Dos_lane.Other_program _
         | Dos_lane.Would_discard_previous_autosave _ ) as error) -> Error (Dos_lane.error_to_string error)
      | Ok capture ->
          let o = capture.Dos_lane.observation in
          let inputs = Machine_input_history.publish history ~incarnation:capture.incarnation
            ~entry_count:capture.input_count ~newest_first:capture.input_ledger in
          Ok (json_response (`Assoc [
            "rows", `List [`Assoc ["id", `String "screen"; "lane_id", `String "dos/screen";
              "kind", `String "value"; "title", `String "DOS screen";
              "observed_at", `Float (Time_compat.now ()); "subject_id", `String capture.incarnation;
              "clock", `Assoc ["domain", `String "dos/step"; "value", `String (string_of_int o.steps)];
              "actor", `Null; "fields", `Assoc (("machine_loaded", `Bool true) :: ("input_history", inputs) :: ("machine_live", live_snapshot ()) :: Machine.observation_fields o);
              "evidence", `List []; "related_ids", `List []]];
            "coverage", `List [`Assoc ["source_id", `String "machine";
              "incarnation", `String capture.incarnation; "cursor", `String (string_of_int capture.input_count);
              "complete", `Bool true; "detail", `Null]]])) in
      match observed with
      | Error _ as error -> error
      | Ok result ->
          let packet = Option.value ~default:`Null result.S.structured_content in
          Result.map json_response (Machine_observation_packet.encode packet))) server
