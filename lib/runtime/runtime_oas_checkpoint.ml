(** Runtime_oas_checkpoint — Lifecycle, checkpoint, and idle-detail helpers.

    Keeps side-effecting run helpers separate from the main build/resume/run
    orchestration in {!Runtime_agent}. *)

let publish_lifecycle _bus ~name ~event ~detail ?error ?session_id ?status
    ?(attrs = []) () =
  match Masc_event_bus.get () with
  | None -> ()
  | Some _mb ->
      let optional_string_field key = function
        | Some value when String.trim value <> "" -> [ (key, `String value) ]
        | _ -> []
      in
      ignore
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

let persist_checkpoint ~dir ~session_id (ckpt : Agent_sdk.Checkpoint.t)
    : (unit, string) result =
  let path = Filename.concat dir (session_id ^ ".json") in
  try
    Fs_compat.mkdir_p dir;
    Result.map_error
      (fun err ->
         Printf.sprintf "checkpoint persist failed for %s: %s" session_id err)
      (Fs_compat.save_file_atomic path (Agent_sdk.Checkpoint.to_string ckpt))
  with
  (* CancelledNeverAbsorbed (KeeperOASAdvanced.tla): re-raise [Cancelled]
     before the catch-all so a cancelled checkpoint fiber propagates the
     cancel to its parent switch instead of returning a normal [Error]
     result.  Absorbing it would create the spec's "zombie" — the parent
     believes the child completed cleanly while the cancel signal is lost.
     Regression guard: test/test_oas_checkpoint_cancelled_never_absorbed.ml *)
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error (Printf.sprintf "checkpoint persist failed for %s: %s"
             session_id (Printexc.to_string exn))

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

(** Enrich an [Agent_sdk.Error.to_string] detail with the name of the most
    recently called tool when the error is an "Idle detected" failure.
    For all other error strings the input is returned unchanged.

    Exposed at module level so it can be unit-tested independently of
    the network-bound [run] function. *)
let enrich_idle_detail (detail : string) (messages : Agent_sdk.Types.message list) : string =
  if String.starts_with ~prefix:"Idle detected" detail then
    let last_tool =
      let rec find = function
        | [] -> None
        | (m : Agent_sdk.Types.message) :: rest ->
            let later = find rest in
            if Option.is_some later then
              later
            else if m.role = Agent_sdk.Types.Assistant then
              List.find_map
                (fun block ->
                  Agent_sdk.Canonical_tool.tool_call_of_block block
                  |> Option.map (fun call -> call.Agent_sdk.Canonical_tool.name))
                m.content
            else
              None
      in
      find messages
    in
    match last_tool with
    | Some name -> Printf.sprintf "%s (tool: %s)" detail name
    | None -> detail
  else
    detail
