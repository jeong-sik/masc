(** Canonical MCP tool help content.

    The MCP schema description should stay short and discovery-oriented.
    Longer workflow/runbook guidance lives here and can be surfaced through
    dedicated help tools/resources/prompts. *)

type help_entry = {
  name : string;
  short_description : string;
  when_to_use : string;
  key_constraints : string list;
  details_markdown : string;
  doc_refs : string list;
  prompt_hints : string list;
}

let normalize_spaces text =
  text
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun chunk -> chunk <> "")
  |> String.concat " "

let trim_terminal_punctuation text =
  let rec loop value =
    let len = String.length value in
    if len = 0 then
      value
    else
      match value.[len - 1] with
      | '.' | ';' | ':' | ',' -> loop (String.sub value 0 (len - 1))
      | _ -> value
  in
  loop (String.trim text)

let first_sentence text =
  let text = normalize_spaces text in
  let len = String.length text in
  let rec loop idx =
    if idx >= len then
      text
    else
      match text.[idx] with
      | '.' | '!' | '?' -> String.sub text 0 (idx + 1)
      | _ -> loop (idx + 1)
  in
  loop 0 |> String.trim

let truncate ~max_len text =
  if String.length text <= max_len then
    text
  else
    String.sub text 0 (max 0 (max_len - 1)) ^ "…"

let help_doc_refs name =
  if String.starts_with ~prefix:"masc_team_session_" name then
    [
      "docs/TEAM-SESSION-ARCHITECTURE.md";
      "docs/SUPERVISOR-MODE.md";
    ]
  else if
    String.starts_with ~prefix:"masc_operation_" name
    || String.starts_with ~prefix:"masc_dispatch_" name
    || String.starts_with ~prefix:"masc_unit_" name
    || String.starts_with ~prefix:"masc_policy_" name
    || String.starts_with ~prefix:"masc_observe_" name
    || String.starts_with ~prefix:"masc_detachment_" name
  then
    [
      "docs/COMMAND-PLANE-RUNBOOK.md";
      "docs/BENCHMARK-RUNBOOK.md";
    ]
  else if
    String.starts_with ~prefix:"masc_keeper_" name
  then
    [ "docs/SUPERVISOR-MODE.md" ]
  else
    []

let help_prompt_hints name =
  if String.equal name "masc_tool_help" then
    [ "Use prompt 'tool_help' when the caller needs a guided explanation." ]
  else if String.starts_with ~prefix:"masc_team_session_" name then
    [ "Use prompt 'team_session_proof' for collaboration evidence." ]
  else if
    String.starts_with ~prefix:"masc_operation_" name
    || String.starts_with ~prefix:"masc_dispatch_" name
    || String.starts_with ~prefix:"masc_observe_" name
  then
    [ "Use prompt 'command_truth' for managed execution evidence." ]
  else
    []

let default_when_to_use name =
  if String.equal name "masc_tool_help" then
    "Use when you need canonical guidance for a specific MASC tool."
  else
    "Use when you need this tool's canonical action."

let constraints_from_metadata name =
  let meta = Tool_catalog.metadata name in
  let visibility_note =
    match meta.visibility with
    | Tool_catalog.Hidden -> [ "Hidden from the default tool list." ]
    | Tool_catalog.Default -> []
  in
  let lifecycle_note =
    match meta.lifecycle, meta.replacement with
    | Tool_catalog.Deprecated, Some replacement ->
        [ "Deprecated. Prefer " ^ replacement ^ "." ]
    | Tool_catalog.Deprecated, None -> [ "Deprecated." ]
    | Tool_catalog.Active, _ -> []
  in
  let implementation_note =
    match meta.implementation_status with
    | Tool_catalog.Placeholder -> [ "Placeholder implementation; not a truthful default surface." ]
    | Tool_catalog.Simulation -> [ "Simulation-backed implementation." ]
    | Tool_catalog.Adapter -> [ "Compatibility or adapter surface." ]
    | Tool_catalog.Real -> []
  in
  visibility_note @ lifecycle_note @ implementation_note

let manual_help_entry name =
  match name with
  | "keeper_tool_search" ->
      Some
        {
          name;
          short_description = "Search for additional tools by natural language query.";
          when_to_use = "Use when your core tools are insufficient for the current task and you need help identifying relevant tools by describing the capability you need.";
          key_constraints =
            [
              "Returns up to 10 matching results per query.";
            ];
          details_markdown =
            "BM25 search over the full tool universe. Returns matching tool names, descriptions, and usage guidance for discovery and selection.";
          doc_refs = [];
          prompt_hints = [];
        }
  | "masc_tool_help" ->
      Some
        {
          name;
          short_description = "Return canonical help and metadata for a specific MASC tool.";
          when_to_use = "Use when you need the concise description, lifecycle, and detailed guidance for one tool.";
          key_constraints = [];
          details_markdown =
            "Returns the canonical short description, lifecycle/visibility metadata, replacement info, and detailed help for a specific tool.";
          doc_refs = [ "docs/COMMAND-PLANE-RUNBOOK.md" ];
          prompt_hints = [ "Pair with prompt 'tool_help' when you want a ready-to-use explanation." ];
        }
  | "masc_team_session_step" ->
      Some
        {
          name;
          short_description = "Record a structured team-session turn, checkpoint, or worker spawn.";
          when_to_use = "Use when a supervisor needs to append auditable session activity without bypassing the session ledger.";
          key_constraints =
            [
              "Requires a valid session_id.";
              "Write semantics depend on turn_kind and optional spawn/task fields.";
            ];
          details_markdown =
            "This is the canonical write entrypoint for team-session activity. It records a turn, optional run-note or deliverable, and can spawn workers through the supervised session lane.";
          doc_refs =
            [
              "docs/TEAM-SESSION-ARCHITECTURE.md";
              "docs/SUPERVISOR-MODE.md";
            ];
          prompt_hints = [ "Use prompt 'team_session_proof' to read the resulting collaboration evidence." ];
        }
  | "masc_autoresearch_swarm_start" ->
      Some
        {
          name;
          short_description =
            "Start an autoresearch loop through the swarm-facing team-session surface and optional managed-operation lane.";
          when_to_use =
            "Use when you want Karpathy-style autoresearch to show up in the normal supervised swarm workflow instead of living as a standalone ecosystem loop.";
          key_constraints =
            [
              "Requires goal, metric_fn, and target_file.";
              "Needs local team-session runtime context; managed-operation launch is best-effort and may degrade to session-only with warnings.";
            ];
          details_markdown =
            "Creates the raw autoresearch loop first, then links it to a supervised team session and, when possible, a research_pipeline managed operation on the compatibility lane. Team-session status exposes a linked_autoresearch block and team-session stop stops the linked loop.";
          doc_refs =
            [
              "docs/SWARM-DELIVERY-RUNBOOK.md";
              "docs/TEAM-SESSION.md";
            ];
          prompt_hints =
            [
              "Use when you want raw masc_autoresearch_* behavior but need operator-visible session/proof surfaces.";
            ];
        }
  | "masc_repo_synthesis_swarm_start" ->
      Some
        {
          name;
          short_description =
            "Start a repo-synthesis run through the managed-operation compatibility lane, attached team session, and proof surfaces.";
          when_to_use =
            "Use when Codex/TUI needs one MCP front door for repo-scoped synthesis questions before dropping to raw command-plane or team-session tools.";
          key_constraints =
            [
              "Requires goal, question, and repo_root.";
              "Seeds planned worker roles and writes a benchmark run record, but dashboard remains read-only.";
            ];
          details_markdown =
            "Creates a managed coding_task inspect-stage operation on the repo-synthesis platoon, starts an attached team session, registers planned worker roles, stores benchmark metadata under .masc/repo-synthesis-benchmarks, and returns proof/report artifact paths plus recommended next tools. The attached team session remains the default operator-visible execution path.";
          doc_refs =
            [
              "docs/COMMAND-PLANE-RUNBOOK.md";
              "docs/BENCHMARK-RUNBOOK.md";
              "docs/SUPERVISOR-MODE.md";
            ];
          prompt_hints =
            [
              "Use when you want MCP write/control plus dashboard read/proof for repo questions.";
            ];
        }
  | "masc_operation_start" ->
      Some
        {
          name;
          short_description = "Start a managed operation on a selected unit.";
          when_to_use = "Use when you explicitly need the managed-operation compatibility lane for benchmarking or topology experiments.";
          key_constraints =
            [
              "Requires assigned_unit_id and objective.";
              "Managed operation state is later advanced through checkpoint/finalize/policy tools.";
            ];
          details_markdown =
            "Creates the managed-operation record on the experimental command-plane lane, binds it to a unit, and seeds the trace/checkpoint path used by operator and proof surfaces.";
          doc_refs =
            [
              "docs/COMMAND-PLANE-RUNBOOK.md";
              "docs/BENCHMARK-RUNBOOK.md";
            ];
          prompt_hints = [ "Use prompt 'command_truth' to inspect resulting execution evidence." ];
        }
  | "masc_tool_admin_snapshot" ->
      Some
        {
          name;
          short_description =
            "Return a unified admin snapshot covering tool inventory, auth, and command-plane policy surfaces.";
          when_to_use =
            "Use when you need one truthful view of what tools exist, what is visible, what auth/RBAC applies, and which policy surfaces are enforced versus advisory.";
          key_constraints =
            [
              "Tool catalog visibility metadata is read-only in this snapshot.";
              "Command-plane tool/model allowlists now constrain unit routing and assignment via tagged capabilities, but they do not yet hard-stop every per-tool worker invocation.";
            ];
          details_markdown =
            "Provides a namespace-scoped control snapshot: auth config and credentials, command-plane policy topology, and the full tool inventory with metadata and permission hints.";
          doc_refs =
            [
              "docs/COMMAND-PLANE-RUNBOOK.md";
              "docs/SUPERVISOR-MODE.md";
            ];
          prompt_hints =
            [
              "Use before changing auth or unit policy to confirm what is actually enforced.";
            ];
        }
  | "masc_tool_admin_update" ->
      Some
        {
          name;
          short_description =
            "Apply auth or unit-policy updates through a single admin entrypoint.";
          when_to_use =
            "Use when you need to change auth settings or update a unit policy envelope.";
          key_constraints =
            [
              "Section must be one of: auth | unit_policy.";
              "Unit tool/model allowlists now affect command-plane routing and assignment when capability tags are present; worker-runtime per-tool enforcement is still a follow-up slice.";
            ];
          details_markdown =
            "Delegates to the existing truthful write paths: Config mode updates, Auth config persistence, managed-operation unit policy updates, and keeper meta policy updates. Command-plane unit policy now feeds routing/assignment gates; deeper worker-runtime enforcement remains a separate step.";
          doc_refs =
            [
              "docs/COMMAND-PLANE-RUNBOOK.md";
              "docs/SUPERVISOR-MODE.md";
            ];
          prompt_hints =
            [
              "Run masc_tool_admin_snapshot first, then apply the smallest necessary section update.";
            ];
        }
  | _ -> None

let derived_short_description name original =
  let meta = Tool_catalog.metadata name in
  match meta.lifecycle, meta.replacement with
  | Tool_catalog.Deprecated, Some replacement ->
      "Deprecated alias for " ^ replacement ^ "."
  | Tool_catalog.Deprecated, None -> "Deprecated tool retained for compatibility."
  | _, _ ->
      let seed =
        match first_sentence original with
        | "" -> default_when_to_use name
        | sentence -> sentence
      in
      let cleaned =
        seed |> normalize_spaces |> truncate ~max_len:120
      in
      if cleaned = "" then
        "MASC tool."
      else if String.ends_with ~suffix:"." cleaned then
        cleaned
      else
        cleaned ^ "."

let derived_details name original =
  let base = normalize_spaces original in
  let extra_constraints = constraints_from_metadata name in
  if extra_constraints = [] then
    base
  else
    String.concat "\n\n"
      [
        base;
        "Constraints:\n"
        ^ String.concat "\n" (List.map (fun item -> "- " ^ item) extra_constraints);
      ]

let entry_of_schema (schema : Types.tool_schema) : help_entry =
  match manual_help_entry schema.name with
  | Some entry -> entry
  | None ->
      {
        name = schema.name;
        short_description = derived_short_description schema.name schema.description;
        when_to_use = default_when_to_use schema.name;
        key_constraints = constraints_from_metadata schema.name;
        details_markdown = derived_details schema.name schema.description;
        doc_refs = help_doc_refs schema.name;
        prompt_hints = help_prompt_hints schema.name;
      }

let find_entry (schemas : Types.tool_schema list) name =
  schemas
  |> List.find_opt (fun (schema : Types.tool_schema) -> String.equal schema.name name)
  |> Option.map entry_of_schema

let canonicalize_schema (schema : Types.tool_schema) : Types.tool_schema =
  let entry = entry_of_schema schema in
  { schema with description = entry.short_description }

let canonicalize_schemas schemas =
  List.map canonicalize_schema schemas

let entry_json (entry : help_entry) =
  let meta_fields = Tool_catalog.metadata_to_fields entry.name in
  let workflow_fields =
    match Workflow_guide.workflow_context ~tool_name:entry.name with
    | Some (before, after, mistakes) ->
        let str_list xs = `List (List.map (fun s -> `String s) xs) in
        [ ("before", str_list before);
          ("after", str_list after);
          ("common_mistakes", str_list mistakes) ]
    | None -> []
  in
  `Assoc
    ([
       ("name", `String entry.name);
       ("short_description", `String entry.short_description);
       ("when_to_use", `String entry.when_to_use);
       ("key_constraints", `List (List.map (fun value -> `String value) entry.key_constraints));
       ("details_markdown", `String entry.details_markdown);
       ("doc_refs", `List (List.map (fun value -> `String value) entry.doc_refs));
       ("prompt_hints", `List (List.map (fun value -> `String value) entry.prompt_hints));
     ]
    @ meta_fields
    @ workflow_fields)

let entry_markdown (entry : help_entry) =
  let meta = Tool_catalog.metadata entry.name in
  let lifecycle = Tool_catalog.lifecycle_to_string meta.lifecycle in
  let visibility = Tool_catalog.visibility_to_string meta.visibility in
  let header =
    [
      "# " ^ entry.name;
      "";
      entry.short_description;
      "";
      "- visibility: `" ^ visibility ^ "`";
      "- lifecycle: `" ^ lifecycle ^ "`";
    ]
  in
  let replacement_lines =
    match meta.replacement with
    | Some replacement -> [ "- replacement: `" ^ replacement ^ "`" ]
    | None -> []
  in
  let when_lines =
    [
      "";
      "## When To Use";
      "";
      entry.when_to_use;
    ]
  in
  let constraint_lines =
    if entry.key_constraints = [] then
      []
    else
      [
        "";
        "## Key Constraints";
        "";
      ]
      @ List.map (fun item -> "- " ^ item) entry.key_constraints
  in
  let detail_lines =
    [
      "";
      "## Details";
      "";
      entry.details_markdown;
    ]
  in
  let doc_lines =
    if entry.doc_refs = [] then
      []
    else
      [
        "";
        "## Docs";
        "";
      ]
      @ List.map (fun item -> "- `" ^ item ^ "`") entry.doc_refs
  in
  let prompt_lines =
    if entry.prompt_hints = [] then
      []
    else
      [
        "";
        "## Prompt Hints";
        "";
      ]
      @ List.map (fun item -> "- " ^ item) entry.prompt_hints
  in
  let workflow_lines =
    match Workflow_guide.workflow_context ~tool_name:entry.name with
    | Some (before, after, mistakes) ->
        let before_items = List.map (fun t -> "- `" ^ t ^ "`") before in
        let after_items = List.map (fun t -> "- `" ^ t ^ "`") after in
        let mistake_items = List.map (fun m -> "- " ^ m) mistakes in
        [ ""; "## Workflow Context"; "" ]
        @ (if before <> [] then [ "**Call before this tool:**" ] @ before_items else [])
        @ (if after <> [] then [ ""; "**Call after this tool:**" ] @ after_items else [])
        @ (if mistakes <> [] then [ ""; "**Common mistakes:**" ] @ mistake_items else [])
    | None -> []
  in
  String.concat "\n"
    (header @ replacement_lines @ when_lines @ constraint_lines @ detail_lines
   @ doc_lines @ prompt_lines @ workflow_lines)

let index_json (schemas : Types.tool_schema list) =
  `Assoc
    [
      ("count", `Int (List.length schemas));
      ("tools", `List (List.map (fun schema -> entry_json (entry_of_schema schema)) schemas));
    ]

let index_markdown (schemas : Types.tool_schema list) =
  let rows =
    schemas
    |> List.sort (fun (a : Types.tool_schema) (b : Types.tool_schema) ->
           String.compare a.name b.name)
    |> List.map (fun schema ->
           let entry = entry_of_schema schema in
           Printf.sprintf "- `%s` — %s" schema.name entry.short_description)
  in
  String.concat "\n"
    ([
       "# Tool Help Index";
       "";
       "Canonical help entries for MCP-exposed MASC tools.";
       "";
     ]
    @ rows)

let validate_short_description (entry : help_entry) =
  not (String.contains entry.short_description '\n')
  && String.length (String.trim entry.short_description) > 0
  && String.length entry.short_description <= 140
