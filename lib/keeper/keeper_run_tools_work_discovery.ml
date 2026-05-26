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
  | "open_prs" ->
    let repos_text =
      match Repo_store.load_all ~base_path:config.base_path with
      | Ok [] ->
        "jeong-sik/masc-mcp"
      | Ok repos ->
        let slugs =
          List.filter_map (fun (r : Repo_manager_types.repository) ->
            match String.split_on_char '/' r.name with
            | [ _owner; _name ] -> Some r.name
            | _ ->
              (* Try extracting owner/name from URL *)
              match String.split_on_char '/' r.url with
              | parts ->
                let len = List.length parts in
                if len >= 2 then
                  let rec nth = function
                    | [], _ -> None
                    | x :: _, 0 -> Some x
                    | _ :: xs, n -> nth (xs, n - 1)
                  in
                  (match nth (parts, len - 2), nth (parts, len - 1) with
                   | Some o, Some n ->
                     let n = String.map (fun c -> if c = '.' then '_' else c) n in
                     Some (o ^ "/" ^ n)
                   | _ -> Some r.name)
                else Some r.name)
            repos
        in
        (match slugs with [] -> "jeong-sik/masc-mcp" | _ -> String.concat ", " slugs)
      | Error _ -> "jeong-sik/masc-mcp"
    in
    Some
      (Printf.sprintf
         "**Open PR inspection:** legacy review wrappers are retired.\n\
          Step 1: Call `keeper_pr_list` with `repo=\"%s\"`.\n\
          Step 2: Read the response JSON. Extract PR numbers from the `pr_number` field \
          ONLY.\n\
          Step 3: Pick ONE open PR from the list. Call `keeper_pr_status`.\n\
          Step 4: If you find an actionable issue, post the finding to the board or \
          claim a task and use the normal sandboxed code path.\n\
          VIOLATIONS (each causes tool error and turn waste):\n\
          - Calling hidden implementation tool names.\n\
          - Using a PR number from your training data, memory, or any source other than \
          the `keeper_pr_list` response (those PRs are almost certainly merged/closed).\n\
          - Using raw `gh` CLI as a credential check instead of fixing sandbox/config.\n\
          Skip PRs already approved. One concrete finding per cycle is more valuable \
          than skimming many."
         repos_text)
  | _ -> None
;;

let render_nudge ~interval ~(pr_review_sections : string list) ~(other_sections : string list)
  =
  let active_schema_guard =
    "Use only tool schemas currently shown by the runtime. If an execution tool is \
     absent from the active schema list, do not name or call it; emit [STATE] or use \
     a visible handoff/status tool."
  in
  let unknown_tool_guard = Keeper_tool_guidance.render_unknown_tool_guard () in
  let pr_review_header =
    match pr_review_sections with
    | [] -> ""
    | _ :: _ ->
      let body = String.concat "\n\n" pr_review_sections in
      Printf.sprintf
        "## Discovered Work (auto, %ds interval) — PRIORITY ORDER\n\n\
         ### BEFORE any other work: inspect one open PR\n\
         %s\n\n\
         You MUST complete at least one PR inspection step (keeper_pr_list → \
         keeper_pr_status) BEFORE touching tasks, board posts, or verification items. \
         Hidden implementation tool names are not valid.\n\n"
        interval
        body
  in
  let other_header =
    match other_sections with
    | [] -> ""
    | _ :: _ ->
      Printf.sprintf
        "### After PR inspection: other discovered work\n\
         %s\n\n"
        (String.concat "\n\n" other_sections)
  in
  Printf.sprintf
    "%s\
     %s\
     ### Use the smallest real action now\n\
     %s\n\n\
     %s\n\n\
     Do not print fenced pseudo-calls. Pick the smallest viable action and emit one \
     or more structured tool calls now."
    pr_review_header
    other_header
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
      let pr_review_sections, other_sections =
        List.partition
          (fun s ->
             String.length s > 0
             && String.sub s 0
                  (min (String.length s) 19)
                  (* Starts with the "**Open PR inspection:**" prefix *)
                  |> String.starts_with ~prefix:"**Open PR inspection:**")
          chunks
      in
      let other_sections =
        other_sections
        @
        match guidance_section with
        | Some s -> [ s ]
        | None -> []
      in
      match pr_review_sections @ other_sections with
      | [] -> None
      | _ -> Some (render_nudge ~interval ~pr_review_sections ~other_sections))
;;
