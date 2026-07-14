(** Runtime_oas_checkpoint — Lifecycle, checkpoint, and idle-detail helpers.

    Keeps side-effecting run helpers separate from the main build/resume/run
    orchestration in {!Runtime_agent}. *)

let missing_masc_bus_warned = Atomic.make false

let publish_lifecycle ~name ~event ~detail ?error ?session_id ?status
    ?(attrs = []) () =
  match Masc_event_bus.get () with
  | None ->
      if Atomic.compare_and_set missing_masc_bus_warned false true then
        Log.Misc.warn
          "runtime lifecycle event was not published: MASC event bus is not initialized"
  | Some mb ->
      let optional_string_field key = function
        | Some value when String.trim value <> "" -> [ (key, `String value) ]
        | _ -> []
      in
      Agent_sdk.Event_bus.publish mb
        (Agent_sdk.Event_bus.mk_event
           (Custom
              ( Printf.sprintf "masc.oas_worker.%s" event
              , `Assoc
                  ([ ("agent", `String name)
                   ; ("detail", `String detail)
                   ; ("timestamp", `Float (Time_compat.now ()))
                   ]
                   @ optional_string_field "error" error
                   @ optional_string_field "session_id" session_id
                   @ optional_string_field "status" status
                   @ attrs) )))

let build_checkpoint ~session_id ?checkpoint_sidecar (agent : Agent_sdk.Agent.t) =
  match checkpoint_sidecar with
  | None -> Agent_sdk.Agent.checkpoint ~session_id agent
  | Some json ->
      Agent_sdk.Agent_checkpoint.build_checkpoint
        ~session_id ~working_context:json
        ~state:(Agent_sdk.Agent.state agent)
        ~tools:(Agent_sdk.Agent.tools agent)
        ~context:(Agent_sdk.Agent.context agent)
        ~mcp_clients:(Agent_sdk.Agent.options agent).mcp_clients
        ()

let partial_response_of_stop
    ~(session_id : string)
    ~(text : string)
  : Agent_sdk.Types.api_response =
  (* RFC-0132 PR-2: api_response model surface = external boundary; redact via SSOT. *)
  {
    id = session_id;
    model = Boundary_redaction.to_string Boundary_redaction.runtime_model_label;
    stop_reason = Agent_sdk.Types.EndTurn;
    content = [ Agent_sdk.Types.Text text ];
    usage = None;
    telemetry = None;
  }
