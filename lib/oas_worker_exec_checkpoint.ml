(** Oas_worker_exec_checkpoint — Lifecycle, checkpoint, and idle-detail helpers.

    Keeps side-effecting run helpers separate from the main build/resume/run
    orchestration in {!Oas_worker_exec}. *)

let publish_lifecycle _bus ~name ~event ~detail ?error ?session_id ?status () =
  match Masc_event_bus.get () with
  | None -> ()
  | Some mb ->
      let optional_string_field key = function
        | Some value when String.trim value <> "" -> [ (key, `String value) ]
        | _ -> []
      in
      Oas_bus_instrument.publish mb
        (Oas.Event_bus.mk_event
           (Custom
              ( Printf.sprintf "masc.oas_worker.%s" event,
                `Assoc
                  ([
                     ("agent", `String name);
                     ("detail", `String detail);
                     ("timestamp", `Float (Time_compat.now ()));
                   ]
                   @ optional_string_field "error" error
                   @ optional_string_field "session_id" session_id
                   @ optional_string_field "status" status) )))

let persist_checkpoint ~dir ~session_id (ckpt : Oas.Checkpoint.t)
    : (unit, string) result =
  let path = Filename.concat dir (session_id ^ ".json") in
  try
    Fs_compat.mkdir_p dir;
    Result.map_error
      (fun err ->
         Printf.sprintf "checkpoint persist failed for %s: %s" session_id err)
      (Fs_compat.save_file_atomic path (Oas.Checkpoint.to_string ckpt))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error (Printf.sprintf "checkpoint persist failed for %s: %s"
             session_id (Printexc.to_string exn))

let build_checkpoint ~session_id ?checkpoint_sidecar (agent : Oas.Agent.t) =
  match checkpoint_sidecar with
  | None -> Oas.Agent.checkpoint ~session_id agent
  | Some json ->
      Oas.Agent_checkpoint.build_checkpoint
        ~session_id ~working_context:json
        ~state:(Oas.Agent.state agent)
        ~tools:(Oas.Agent.tools agent)
        ~context:(Oas.Agent.context agent)
        ~mcp_clients:(Oas.Agent.options agent).mcp_clients
        ()

let partial_response_of_stop
    ~(session_id : string)
    ~(model_id : string)
    ~(text : string)
  : Oas.Types.api_response =
  {
    id = session_id;
    model = model_id;
    stop_reason = Oas.Types.EndTurn;
    content = [ Oas.Types.Text text ];
    usage = None;
    telemetry = None;
  }

(** Enrich an [Oas.Error.to_string] detail with the name of the most
    recently called tool when the error is an "Idle detected" failure.
    For all other error strings the input is returned unchanged.

    Exposed at module level so it can be unit-tested independently of
    the network-bound [run] function. *)
let enrich_idle_detail (detail : string) (messages : Oas.Types.message list) : string =
  if String.starts_with ~prefix:"Idle detected" detail then
    let last_tool =
      let rec find = function
        | [] -> None
        | (m : Oas.Types.message) :: rest ->
            let later = find rest in
            if Option.is_some later then
              later
            else if m.role = Oas.Types.Assistant then
              List.find_map
                (function
                  | Oas.Types.ToolUse { name; _ } -> Some name
                  | _ -> None)
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
