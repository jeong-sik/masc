(** Planning_eio - OCaml 5.x Pure Synchronous Planning Module

    Eio-native version of Planning module.
    Implements the planning-with-files pattern for structured AI collaboration:
    - task_plan.md: Main execution plan
    - notes.md: Observations, learnings, context
    - errors.md: Error tracking (PDCA Check phase)
    - deliverable.md: Final output/result

    All operations are pure synchronous - no monads, no async wrappers.
    Uses Fun.protect for resource cleanup and Unix.lockf for file locking.
*)

(** Error entry for failure tracking *)
type error_entry = {
  timestamp: string;
  error_type: string;
  message: string;
  context: string option; [@default None]
  resolved: bool;
} [@@deriving yojson]

(** Planning context for a task *)
type planning_context = {
  task_id: string;
  task_plan: string;
  notes: string list; [@default []]
  errors: error_entry list; [@default []]
  deliverable: string; [@default ""]
  created_at: string;
  updated_at: string;
} [@@deriving yojson]

(* ===== Utility Functions ===== *)

let now_iso () =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

(** Create empty planning context *)
let create_context ~task_id =
  let now = now_iso () in
  {
    task_id;
    task_plan = "";
    notes = [];
    errors = [];
    deliverable = "";
    created_at = now;
    updated_at = now;
  }

(* ===== File System Helpers ===== *)

let planning_dir (config : Coord.config) task_id =
  Filename.concat config.base_path (Printf.sprintf "planning/%s" task_id)

let ensure_dir path =
  Fs_compat.mkdir_p path

(** File read via Fs_compat (Eio-native when available, blocking fallback) *)
let read_file_content path =
  if Fs_compat.file_exists path then
    Fs_compat.load_file path
  else ""

(** File write via Fs_compat (Eio-native when available, blocking fallback) *)
let write_file_content path content =
  ensure_dir (Filename.dirname path);
  Fs_compat.save_file path content

let find_substring_from haystack ~needle ~from =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if i + needle_len > haystack_len then None
    else if String.sub haystack i needle_len = needle then Some i
    else loop (i + 1)
  in
  loop from

let normalize_placeholder value =
  match String.trim value with
  | "_No plan yet_" | "_No deliverable yet_" -> ""
  | other -> other

let extract_markdown_section content ~heading ~next_headings =
  match find_substring_from content ~needle:heading ~from:0 with
  | None -> None
  | Some heading_idx ->
      let body_start = heading_idx + String.length heading in
      let body_end =
        next_headings
        |> List.filter_map (fun marker ->
               find_substring_from content ~needle:marker ~from:body_start)
        |> List.sort compare
        |> function
        | first :: _ -> first
        | [] -> String.length content
      in
      let body =
        String.sub content body_start (body_end - body_start)
        |> String.trim
        |> normalize_placeholder
      in
      Some body

type parsed_full_context = {
  task_plan: string;
  deliverable: string option;
}

let parse_full_context_markdown content =
  let task_heading = "## Task Plan (PDCA: Plan)" in
  let notes_heading = "## Notes & Observations (PDCA: Do)" in
  let errors_heading = "## Errors & Failures (PDCA: Check)" in
  let deliverable_heading = "## Deliverable (PDCA: Act)" in
  match
    extract_markdown_section content ~heading:task_heading
      ~next_headings:[ notes_heading; errors_heading; deliverable_heading ]
  with
  | None -> None
  | Some task_plan ->
      let deliverable =
        extract_markdown_section content ~heading:deliverable_heading
          ~next_headings:[ "\n---"; "\r\n---" ]
      in
      Some { task_plan; deliverable }

(* ===== Core Operations (Pure Sync) ===== *)

(** Initialize planning context for a task *)
let init (config : Coord.config) ~task_id : (planning_context, string) result =
  try
    let dir = planning_dir config task_id in
    ensure_dir dir;
    let ctx = create_context ~task_id in
    (* Create empty files - PDCA structure *)
    write_file_content (Filename.concat dir "task_plan.md") "# Task Plan\n\n";
    write_file_content (Filename.concat dir "notes.md") "# Notes & Observations\n\n";
    write_file_content (Filename.concat dir "errors.md") "# Errors & Failures (PDCA Check)\n\n";
    write_file_content (Filename.concat dir "deliverable.md") "";
    (* Save context *)
    let json = planning_context_to_yojson ctx in
    write_file_content (Filename.concat dir "context.json") (Yojson.Safe.pretty_to_string json);
    Ok ctx
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Load planning context *)
let load (config : Coord.config) ~task_id : (planning_context, string) result =
  try
    let dir = planning_dir config task_id in
    let ctx_path = Filename.concat dir "context.json" in
    if not (Sys.file_exists ctx_path) then
      Error (Printf.sprintf "Planning context not found for task %s" task_id)
    else begin
      let content = read_file_content ctx_path in
      let json = Yojson.Safe.from_string content in
      planning_context_of_yojson json
    end
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Update task plan *)
let update_plan (config : Coord.config) ~task_id ~content : (planning_context, string) result =
  try
    let dir = planning_dir config task_id in
    match load config ~task_id with
    | Error e -> Error e
    | Ok ctx ->
        let parsed = parse_full_context_markdown content in
        let task_plan =
          match parsed with
          | Some p -> p.task_plan
          | None -> content
        in
        let deliverable =
          match parsed with
          | Some { deliverable = Some value; _ } -> value
          | _ -> ctx.deliverable
        in
        let updated = { ctx with task_plan; deliverable; updated_at = now_iso () } in
        write_file_content (Filename.concat dir "task_plan.md") task_plan;
        (match parsed with
         | Some { deliverable = Some value; _ } ->
             write_file_content (Filename.concat dir "deliverable.md") value
         | _ -> ());
        write_file_content (Filename.concat dir "context.json")
          (Yojson.Safe.pretty_to_string (planning_context_to_yojson updated));
        Ok updated
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Add note *)
let add_note (config : Coord.config) ~task_id ~note : (planning_context, string) result =
  try
    let dir = planning_dir config task_id in
    match load config ~task_id with
    | Error e -> Error e
    | Ok ctx ->
        let timestamp = now_iso () in
        let formatted_note = Printf.sprintf "## [%s]\n%s\n" timestamp note in
        let updated = { ctx with
          notes = ctx.notes @ [note];
          updated_at = now_iso ()
        } in
        (* Append to notes.md *)
        let notes_path = Filename.concat dir "notes.md" in
        let existing = read_file_content notes_path in
        write_file_content notes_path (existing ^ formatted_note ^ "\n");
        write_file_content (Filename.concat dir "context.json")
          (Yojson.Safe.pretty_to_string (planning_context_to_yojson updated));
        Ok updated
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Add error - PDCA Check phase. Auto-creates planning context if none exists. *)
let add_error (config : Coord.config) ~task_id ~error_type ~message ?context () : (planning_context, string) result =
  try
    let dir = planning_dir config task_id in
    let ctx = match load config ~task_id with
      | Ok ctx -> Ok ctx
      | Error _ ->
          (* Auto-init planning context so error_add works without prior plan_init *)
          init config ~task_id
    in
    match ctx with
    | Error e -> Error e
    | Ok ctx ->
        let timestamp = now_iso () in
        let error_entry = { timestamp; error_type; message; context; resolved = false } in
        let formatted_error = Printf.sprintf "## [%s] %s\n**Type**: %s\n%s\n%s\n---\n"
          timestamp
          (if error_type = "" then "Error" else error_type)
          error_type
          message
          (match context with Some c -> Printf.sprintf "**Context**: %s" c | None -> "")
        in
        let updated = { ctx with
          errors = ctx.errors @ [error_entry];
          updated_at = now_iso ()
        } in
        (* Append to errors.md *)
        let errors_path = Filename.concat dir "errors.md" in
        let existing = read_file_content errors_path in
        write_file_content errors_path (existing ^ formatted_error ^ "\n");
        write_file_content (Filename.concat dir "context.json")
          (Yojson.Safe.pretty_to_string (planning_context_to_yojson updated));
        Ok updated
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Mark error as resolved *)
let resolve_error (config : Coord.config) ~task_id ~index : (planning_context, string) result =
  try
    match load config ~task_id with
    | Error e -> Error e
    | Ok ctx ->
        if index < 0 || index >= List.length ctx.errors then
          Error (Printf.sprintf "Error index %d out of bounds" index)
        else begin
          let errors = List.mapi (fun i e ->
            if i = index then { e with resolved = true } else e
          ) ctx.errors in
          let updated = { ctx with errors; updated_at = now_iso () } in
          let dir = planning_dir config task_id in
          write_file_content (Filename.concat dir "context.json")
            (Yojson.Safe.pretty_to_string (planning_context_to_yojson updated));
          Ok updated
        end
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** Set deliverable. Auto-creates planning context if none exists. *)
let set_deliverable (config : Coord.config) ~task_id ~content : (planning_context, string) result =
  try
    let dir = planning_dir config task_id in
    let ctx = match load config ~task_id with
      | Ok ctx -> Ok ctx
      | Error _ ->
          (* Auto-init planning context so deliver works without prior plan_init *)
          init config ~task_id
    in
    match ctx with
    | Error e -> Error e
    | Ok ctx ->
        let updated = { ctx with deliverable = content; updated_at = now_iso () } in
        write_file_content (Filename.concat dir "deliverable.md") content;
        write_file_content (Filename.concat dir "context.json")
          (Yojson.Safe.pretty_to_string (planning_context_to_yojson updated));
        Ok updated
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(* ===== Session-level Context ===== *)

let current_task_file (config : Coord.config) =
  Filename.concat (Coord_utils.masc_dir config) "current_task"

(** Get current task_id for session *)
let get_current_task (config : Coord.config) : string option =
  let path = current_task_file config in
  if Sys.file_exists path then
    Some (String.trim (read_file_content path))
  else
    None

(** Set current task_id for session *)
let set_current_task (config : Coord.config) ~task_id : unit =
  let path = current_task_file config in
  ensure_dir (Filename.dirname path);
  write_file_content path task_id

(** Clear current task *)
let clear_current_task (config : Coord.config) : unit =
  let path = current_task_file config in
  if Sys.file_exists path then
    Sys.remove path

(** Resolve task_id - use provided or fall back to current *)
let resolve_task_id (config : Coord.config) ~task_id : (string, string) result =
  match task_id with
  | "" ->
      (match get_current_task config with
       | Some t -> Ok t
       | None -> Error "No task_id provided and no current task set. Use masc_plan_set_task first.")
  | t -> Ok t

(* ===== Display Helpers ===== *)

(** Format error entry for display *)
let format_error_entry i (e : error_entry) =
  let status = if e.resolved then "✅" else "❌" in
  let ctx_str = match e.context with Some c -> Printf.sprintf " (%s)" c | None -> "" in
  Printf.sprintf "%d. %s [%s] **%s**%s: %s" (i+1) status e.timestamp e.error_type ctx_str e.message

(** Get full context as markdown for MODEL consumption *)
let get_context_markdown ctx =
  let unresolved = List.filter (fun e -> not e.resolved) ctx.errors in
  let resolved = List.filter (fun e -> e.resolved) ctx.errors in
  Printf.sprintf {|# Planning Context: %s

## Task Plan (PDCA: Plan)
%s

## Notes & Observations (PDCA: Do)
%s

## Errors & Failures (PDCA: Check)
### Unresolved (%d)
%s

### Resolved (%d)
%s

## Deliverable (PDCA: Act)
%s

---
*Created: %s | Updated: %s*
|}
    ctx.task_id
    (if ctx.task_plan = "" then "_No plan yet_" else ctx.task_plan)
    (if ctx.notes = [] then "_No notes yet_" else String.concat "\n\n" (List.mapi (fun i n -> Printf.sprintf "%d. %s" (i+1) n) ctx.notes))
    (List.length unresolved)
    (if unresolved = [] then "_No unresolved errors_" else String.concat "\n" (List.mapi format_error_entry unresolved))
    (List.length resolved)
    (if resolved = [] then "_No resolved errors_" else String.concat "\n" (List.mapi format_error_entry resolved))
    (if ctx.deliverable = "" then "_No deliverable yet_" else ctx.deliverable)
    ctx.created_at
    ctx.updated_at
