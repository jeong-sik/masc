module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

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
  examples : string list;
      (* RFC-0195 P0 — Anthropic MCP guidance: examples > longer descriptions
         for parameter accuracy. Empty list means "no curated example yet". *)
  alternatives : string list;
      (* RFC-0195 P0 — typed list of sibling tool names the LLM may try when
         this one rejects or is unavailable. Empty list means "terminal —
         this is the only path". RFC-0194 §2 instantiation. *)
}

let normalize_spaces text =
  text
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun chunk -> not (String.equal chunk ""))
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
  String_util.utf8_safe ~max_bytes:((max 0 (max_len - 1)) + 3) ~suffix:"…" text |> String_util.to_string

(* RFC-0089 §4-1 G1: tool family typed classifier.

   Closed sum over live tool name prefixes.  Adding a new family
   requires extending [tool_family] AND every [match] — the
   compiler refuses partial coverage.

   The only string classifier is [classify_tool_family] — the
   boundary parser from tool name to typed family.  After this
   point every consumer uses the variant directly. *)
type tool_family =
  | Policy
  | Observe

let tool_family_prefix = function
  | Policy -> "masc_policy_"
  | Observe -> "masc_observe_"

let all_tool_families =
  [ Policy; Observe ]

(* The single boundary parser.  Internal callers receive
   [tool_family option] and dispatch via exhaustive [match];
   no other site in this module compares a tool-name prefix. *)
let classify_tool_family name =
  List.find_opt
    (fun family -> String.starts_with ~prefix:(tool_family_prefix family) name)
    all_tool_families

let help_doc_refs name =
  match classify_tool_family name with
  | Some Policy
  | Some Observe ->
      [
        "docs/COMMAND-PLANE-RUNBOOK.md";
        "docs/BENCHMARK-RUNBOOK.md";
      ]
  | None -> []

let help_prompt_hints name =
  if String.equal name "masc_tool_help" then
    [ "Use prompt 'tool_help' when the caller needs a guided explanation." ]
  else
    []

let default_when_to_use name =
  if String.equal name "masc_tool_help" then
    "Use when you need canonical guidance for a specific MASC tool."
  else
    "Use when you need this tool's canonical action."

(* Internal: same body as [constraints_from_metadata] but operates on a
   pre-fetched [Tool_catalog.metadata] value to avoid re-doing the
   catalog lookup when [entry_of_schema] already has it in scope. *)
let constraints_from_meta (meta : Tool_catalog.metadata) =
  let visibility_note =
    match meta.visibility with
    | Tool_catalog.Hidden -> [ "Hidden from the default tool list." ]
    | Tool_catalog.Default -> []
  in
  let implementation_note =
    match meta.implementation_status with
    | Tool_catalog.Placeholder -> [ "Placeholder implementation; not a truthful default surface." ]
    | Tool_catalog.Simulation -> [ "Simulation-backed implementation." ]
    | Tool_catalog.Adapter -> [ "Compatibility or adapter surface." ]
    | Tool_catalog.Real -> []
  in
  visibility_note @ implementation_note

let constraints_from_metadata name =
  constraints_from_meta (Tool_catalog.metadata name)

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
          examples = [ "query='find a tool that edits files in place'" ];
          alternatives = [];
          (* masc_tool_help would be a natural sibling here but
             its schema lives on a different surface from this
             registry. Keeping alternatives empty preserves the
             "no dangling references" invariant pinned in
             test_alternatives_never_dangling. *)
        }
  | "masc_tool_help" ->
      Some
        {
          name;
          short_description = "Return canonical help and metadata for a specific MASC tool.";
          when_to_use = "Use when you need the concise description, visibility, and detailed guidance for one tool.";
          key_constraints = [];
          details_markdown =
            "Returns the canonical short description, visibility metadata, and detailed help for a specific tool.";
          doc_refs = [ "docs/COMMAND-PLANE-RUNBOOK.md" ];
          prompt_hints = [ "Pair with prompt 'tool_help' when you want a ready-to-use explanation." ];
          examples = [ "name='keeper_task_done'"; "name='masc_plan_set_task'" ];
          alternatives = [];
        }
  | "keeper_task_done" ->
      Some
        {
          name;
          short_description =
            "Mark your owned task done with a result summary and evidence_refs.";
          when_to_use =
            "Use when the current keeper has finished an owned task and can cite concrete evidence_refs.";
          key_constraints =
            [
              "Caller must own the task unless using a force tool.";
              "evidence_refs must include at least one locally validated base-path artifact, local git commit, or .masc trace/turn/receipt artifact when marking work done.";
            ];
          details_markdown =
            "Completes the task directly. For PR-bearing work, include the PR URL or artifact reference in evidence_refs instead of using a separate verification-evidence wrapper.";
          doc_refs = [];
          prompt_hints = [ "Prefer this over retired task verification wrapper tools." ];
          examples =
            [
              "task_id='task-123' result='Implemented the task; checks passed.' evidence_refs=['https://github.com/org/repo/pull/42']";
            ];
          alternatives = [];
        }
  | "keeper_memory_write" ->
      Some
        {
          name;
          short_description = "Persist a structured keeper memory entry.";
          when_to_use =
            "Use when an explicit decision, open question, goal, or progress note should be searchable on later turns.";
          key_constraints =
            [
              "kind must be one of the callable keeper memory kinds.";
              "Do not use for transient scratch notes.";
            ];
          details_markdown =
            "Writes a bounded structured memory note. The long_term kind is reserved for tool-result emission and is not accepted here.";
          doc_refs = [];
          prompt_hints = [];
          examples =
            [
              "kind='decision' title='verification wrapper retired' content='Use keeper_task_done evidence_refs; do not call separate submit evidence wrappers.'";
            ];
          alternatives = [];
        }
  | "keeper_tasks_list" ->
      Some
        {
          name;
          short_description = "List MASC backlog tasks visible to this keeper.";
          when_to_use =
            "Use before claiming work, checking awaiting verification items, or diagnosing current task state.";
          key_constraints =
            [
              "include_done defaults to false.";
              "Use status to narrow the list when inspecting a specific lifecycle state.";
            ];
          details_markdown =
            "Returns task_id, title, status, assignee, and priority for backlog tasks visible to the keeper.";
          doc_refs = [];
          prompt_hints = [];
          examples = [ "status='todo' include_done=false limit=20" ];
          alternatives = [];
        }
  | "masc_plan_set_task" ->
      Some
        {
          name;
          short_description = "Set or update the plan-of-record for a claimed task.";
          when_to_use =
            "Use after masc_claim to record the high-level plan (1-5 bullet outline) before doing significant work. Future-you and reviewers read this to understand intent without rerunning your reasoning.";
          key_constraints =
            [
              "Caller must own a claim on the target task_id.";
              "Plan body should be short prose, not a runbook — it is a commitment, not a script.";
            ];
          details_markdown =
            "Replaces any prior plan on the task; history is preserved in the audit log.";
          doc_refs = [];
          prompt_hints = [];
          examples =
            [
              "task_id='task-123' plan='1) Extend tool_help_registry record  2) Backfill 6 manual entries  3) Add regression tests.'";
            ];
          alternatives = [];
        }
  | _ -> None

let derived_short_description_with_meta (_meta : Tool_catalog.metadata) name original =
  let seed =
    match first_sentence original with
    | "" -> default_when_to_use name
    | sentence -> sentence
  in
  let cleaned =
    seed |> normalize_spaces |> truncate ~max_len:120
  in
  if String.equal cleaned "" then
    "MASC tool."
  else if String.ends_with ~suffix:"." cleaned then
    cleaned
  else
    cleaned ^ "."

let derived_short_description name original =
  derived_short_description_with_meta (Tool_catalog.metadata name) name original

let derived_details_with_meta (meta : Tool_catalog.metadata) original =
  let base = normalize_spaces original in
  let extra_constraints = constraints_from_meta meta in
  if extra_constraints = [] then
    base
  else
    String.concat "\n\n"
      [
        base;
        "Constraints:\n"
        ^ String.concat "\n" (List.map (fun item -> "- " ^ item) extra_constraints);
      ]

let derived_details name original =
  derived_details_with_meta (Tool_catalog.metadata name) original

let entry_of_schema (schema : Masc_domain.tool_schema) : help_entry =
  match manual_help_entry schema.name with
  | Some entry -> entry
  | None ->
      (* Fetch catalog metadata once and thread it through every helper
         that would otherwise re-query Tool_catalog.metadata.  Without
         this, each non-manual entry triggered 3 lookups via
         derived_short_description, constraints_from_metadata, and
         derived_details — the pre-hoist call graph this comment
         documented.  Today derived_details_with_meta calls
         constraints_from_meta directly on the cached meta, so the
         second lookup inside derived_details is gone; the threading
         pattern below avoids the remaining two by passing [meta]
         explicitly. *)
      let meta = Tool_catalog.metadata schema.name in
      {
        name = schema.name;
        short_description = derived_short_description_with_meta meta schema.name schema.description;
        when_to_use = default_when_to_use schema.name;
        key_constraints = constraints_from_meta meta;
        details_markdown = derived_details_with_meta meta schema.description;
        doc_refs = help_doc_refs schema.name;
        prompt_hints = help_prompt_hints schema.name;
        examples = [];
        alternatives = [];
      }

let find_entry (schemas : Masc_domain.tool_schema list) name =
  schemas
  |> List.find_opt (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
  |> Option.map entry_of_schema

let canonicalize_schema (schema : Masc_domain.tool_schema) : Masc_domain.tool_schema =
  let entry = entry_of_schema schema in
  { schema with description = entry.short_description }

let canonicalize_schemas schemas =
  List.map canonicalize_schema schemas

let entry_json (entry : help_entry) =
  let meta_fields = Tool_catalog.metadata_to_fields entry.name in
  let workflow_fields = [] in
  (* RFC-0195 P0 — empty lists omitted so the JSON wire shape stays
     identical for tools with no curated examples/alternatives. *)
  let optional_string_list_field key values =
    if values = [] then []
    else [ (key, `List (List.map (fun v -> `String v) values)) ]
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
    @ optional_string_list_field "examples" entry.examples
    @ optional_string_list_field "alternatives" entry.alternatives
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
  let when_lines =
    [
      "";
      "## When To Use";
      "";
      entry.when_to_use;
    ]
  in
  let constraint_lines =
    if Stdlib.List.length entry.key_constraints = 0 then
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
    if Stdlib.List.length entry.doc_refs = 0 then
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
    if Stdlib.List.length entry.prompt_hints = 0 then
      []
    else
      [
        "";
        "## Prompt Hints";
        "";
      ]
      @ List.map (fun item -> "- " ^ item) entry.prompt_hints
  in
  let example_lines =
    if Stdlib.List.length entry.examples = 0 then
      []
    else
      [
        "";
        "## Examples";
        "";
      ]
      @ List.map (fun item -> "- `" ^ item ^ "`") entry.examples
  in
  let alternative_lines =
    if Stdlib.List.length entry.alternatives = 0 then
      []
    else
      [
        "";
        "## Alternatives";
        "";
      ]
      @ List.map (fun item -> "- `" ^ item ^ "`") entry.alternatives
  in
  let workflow_lines = [] in
  String.concat "\n"
    (header @ when_lines @ constraint_lines @ detail_lines
   @ doc_lines @ prompt_lines @ example_lines @ alternative_lines
   @ workflow_lines)

let index_json (schemas : Masc_domain.tool_schema list) =
  `Assoc
    [
      ("count", `Int (List.length schemas));
      ("tools", `List (List.map (fun schema -> entry_json (entry_of_schema schema)) schemas));
    ]

let index_markdown (schemas : Masc_domain.tool_schema list) =
  let rows =
    schemas
    |> List.sort (fun (a : Masc_domain.tool_schema) (b : Masc_domain.tool_schema) ->
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
