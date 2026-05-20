let task_preview ~limit tasks =
  let n = min limit (List.length tasks) in
  let preview =
    List.filteri (fun i _ -> i < n) tasks
    |> List.map (fun (t : Masc_domain.task) ->
      Printf.sprintf
        "  - %s (p%d): %s"
        t.id
        t.priority
        (String_util.utf8_safe ~max_bytes:83 ~suffix:"…" t.title
         |> String_util.to_string))
    |> String.concat "\n"
  in
  n, preview
;;

let backlog_task_section ~config ~meta ~predicate ~title =
  try
    let backlog = Coord.read_backlog config in
    let tasks = List.filter predicate backlog.tasks in
    match tasks with
    | [] -> None
    | tasks ->
      let n, preview = task_preview ~limit:5 tasks in
      Some
        (Printf.sprintf
           "**%s (%d total, showing %d):**\n%s"
           title
           (List.length tasks)
           n
           preview)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Keeper_callback_failure.record
      ~base_dir:config.Coord.base_path
      ~meta
      ~callback:"work_discovery_nudge"
      exn;
    None
;;

let actionable_verification_request_ids ~(config : Coord.config) : string list =
  Verification.list_requests config.Coord.base_path
  |> List.filter Verification.request_is_actionable
  |> List.map (fun (req : Verification.verification_request) -> req.id)
;;

let section_for_source ~config ~(meta : Keeper_types.keeper_meta) source =
  match source with
  | "unclaimed_tasks" ->
    backlog_task_section
      ~config
      ~meta
      ~title:"Unclaimed tasks"
      ~predicate:(fun (t : Masc_domain.task) ->
        t.task_status = Masc_domain.Todo)
  | "awaiting_verification_tasks"
  | "verification_tasks" ->
    let actionable_request_ids = actionable_verification_request_ids ~config in
    backlog_task_section
      ~config
      ~meta
      ~title:"Awaiting verification tasks"
      ~predicate:(fun (t : Masc_domain.task) ->
        match t.task_status with
        | Masc_domain.AwaitingVerification { verification_id; _ } ->
          List.exists (String.equal verification_id) actionable_request_ids
        | _ -> false)
  | "stale_tasks" ->
    Some
      "**Stale task audit requested:** inspect stale/orphan task state with visible \
       task-audit tools before claiming new work."
  | "board_cleanup" ->
    Some
      "**Board cleanup requested:** inspect stale board posts and use visible board \
       cleanup or curation tools when there is safe cleanup work."
  | _ -> None
;;

let render_nudge ~interval sections =
  let active_schema_guard =
    "Use only tool schemas currently shown by the runtime. If an execution tool is \
     absent from the active schema list, do not name or call it; emit [STATE] or use \
     a visible handoff/status tool."
  in
  let unknown_tool_guard = Keeper_tool_guidance.render_unknown_tool_guard () in
  Printf.sprintf
    "## Discovered Work (auto, %ds interval)\n\n\
     %s\n\n\
     ### Use the smallest real action now\n\
     %s\n\n\
     %s\n\n\
     Do not print fenced pseudo-calls. Pick the smallest viable action and emit one \
     or more structured tool calls now."
    interval
    (String.concat "\n\n" sections)
    active_schema_guard
    unknown_tool_guard
;;

let make ~(config : Coord.config) ~get_meta () () : string option =
  let meta : Keeper_types.keeper_meta = get_meta () in
  match meta.work_discovery_enabled with
  | Some false -> None
  | _ ->
    let interval = Option.value ~default:600 meta.work_discovery_interval_sec in
    let since_last =
      Time_compat.now () -. meta.runtime.proactive_rt.last_work_discovery_ts
    in
    if since_last < float_of_int interval
    then None
    else (
      let sources = Option.value ~default:[] meta.work_discovery_sources in
      let chunks =
        List.filter_map
          (fun src -> src |> String.trim |> String.lowercase_ascii
                      |> section_for_source ~config ~meta)
          sources
      in
      let guidance_section =
        match meta.work_discovery_guidance with
        | Some g when String.trim g <> "" ->
          Some (Printf.sprintf "**Operator guidance:** %s" (String.trim g))
        | _ -> None
      in
      let sections =
        chunks
        @
        match guidance_section with
        | Some s -> [ s ]
        | None -> []
      in
      match sections with
      | [] -> None
      | _ -> Some (render_nudge ~interval sections))
;;
