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
        "docs/KEEPER-USER-MANUAL.md";
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

(* Authored help lives in the tool's own [config/tools/<name>.toml] [help]
   table (RFC prompts-and-tool-definitions-outside-ocaml §2.2; the in-code
   table this replaces was the last hand-written copy). The embedded tree is
   the source: definitions are validated at boot, so a file that fails to
   load here has already refused the boot — the defensive [Error] arm below
   only means "no authored help", never a silent half-entry. *)
let toml_help_table =
  lazy
    (let table = Hashtbl.create 32 in
     List.iter
       (fun rel ->
          if
            String.starts_with ~prefix:"tools/" rel
            && String.equal (Filename.dirname rel) "tools"
            && Filename.check_suffix rel ".toml"
          then (
            let name = Filename.remove_extension (Filename.basename rel) in
            match Embedded_config.read rel with
            | None -> ()
            | Some contents ->
              (match Tool_definition_toml.load ~name ~contents with
               | Ok { Tool_definition_toml.help = Some help; _ } ->
                 Hashtbl.replace table name help
               | Ok { Tool_definition_toml.help = None; _ } | Error _ -> ())))
       Embedded_config.file_list;
     table)

let toml_help name = Hashtbl.find_opt (Lazy.force toml_help_table) name

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

let entry_of_schema (schema : Masc_domain.tool_schema) : help_entry =
  match toml_help schema.name with
  | Some (help : Tool_definition_toml.help) ->
      (* An authored [help] table is the whole entry, the way the retired
         in-code table was: absent prose fields fall back to the schema
         derivation, absent lists stay empty rather than picking up derived
         constraint notes, so an authored entry renders exactly as written. *)
      let meta = Tool_catalog.metadata schema.name in
      {
        name = schema.name;
        short_description =
          (match help.short_description with
           | Some text -> text
           | None ->
               derived_short_description_with_meta meta schema.name
                 schema.description);
        when_to_use =
          (match help.when_to_use with
           | Some text -> text
           | None -> default_when_to_use schema.name);
        key_constraints = help.key_constraints;
        details_markdown =
          (match help.details_markdown with
           | Some text -> text
           | None -> derived_details_with_meta meta schema.description);
        doc_refs = help.doc_refs;
        prompt_hints = help.prompt_hints;
        examples = help.examples;
        alternatives = help.alternatives;
      }
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

