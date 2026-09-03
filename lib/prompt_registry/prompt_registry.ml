(** Prompt Registry - Versioned template storage and management

    This module provides a registry for storing and managing prompt templates
    with versioning, variable extraction, and usage metrics tracking.

    Features:
    - In-memory storage using Hashtbl (fast lookup)
    - Optional file-based persistence (JSON files in prompts directory)
    - Thread-safe operations via Mutex
    - Automatic variable extraction from {{var}} syntax
    - Usage metrics tracking (count, avg score, last used)
    - Version support for A/B testing and rollbacks

    Prompts enter the registry from markdown files, not from code: point
    [set_markdown_dir] at the directory and call [load_prompts_from_directory],
    which parses each [*.md] frontmatter and registers it. The in-code
    registration API ([register] / [get] / [render] and the rest of the mutable
    entry surface) was removed once nothing called it; do not reintroduce it to
    add a prompt — add the markdown file instead.

    Usage:
    {[
      Prompt_registry.set_markdown_dir "prompts";
      Prompt_registry.load_prompts_from_directory "prompts";

      (* Effective text for a key, override > file *)
      let prompt = Prompt_registry.get_prompt "code-review-v2" in

      (* Every source's contribution, side by side *)
      let resolution = Prompt_registry.resolve_prompt "code-review-v2" in
      ignore prompt;
      ignore resolution
    ]}
*)

(** {1 Types} *)

module Types = Prompt_registry_types

type prompt_entry = Types.prompt_entry = {
  id: string;                     (** Unique identifier *)
  template: string;               (** Prompt template with {{var}} placeholders *)
  version: string;                (** Semantic version string *)
  variables: string list;         (** Extracted variable names from template *)
  created_at: float;              (** Unix timestamp of creation *)
}

type prompt_meta = Types.prompt_meta = {
  description: string;
  category: string;
  operator_surface: Types.operator_surface;
  required_file: bool;
  template_variables: string list;
}

type prompt_resolution = Types.prompt_resolution = {
  effective: string;
  source: string;
  file_value: string option;
  override_value: string option;
  file_path: string option;
  file_exists: bool;
  has_override: bool;
}

type persisted_mutation_error =
  | Validation_error of string
  | Persistence_error of string

(** {1 Frontmatter Parsing} *)

(** Parse YAML-style frontmatter from a markdown file.
    Expects: --- \n key: value \n --- \n body
    Returns (assoc list of key-value pairs, body after frontmatter).
    If no frontmatter found, returns ([], full content). *)
let parse_frontmatter content =
  let parsed = Frontmatter.parse content in
  parsed.Frontmatter.fields, parsed.Frontmatter.body
;;

let markdown_body content =
  let _metadata, body = parse_frontmatter content in
  body

(** Parse a list value like [a, b, c] into string list. Reads through
    {!Frontmatter.list_field}, which also accepts the unbracketed [a, b, c]
    the other frontmatter readers used to allow; every asset in the tree
    writes the bracketed form, so nothing already on disk changes meaning. *)
let parse_list_value s =
  Frontmatter.list_field { Frontmatter.fields = [ ("v", s) ]; body = "" } "v"

(** {1 Variable Extraction} *)

(** Extract variable names from a template string.
    Matches {{variable_name}} patterns. *)
let template_variable_regex = Re.Pcre.re {|\{\{([^}]+)\}\}|} |> Re.compile

let extract_variables template =
  let vars = Re.all template_variable_regex template
    |> List.map (fun g -> Re.Group.get g 1 |> String.trim)
    |> List.filter (fun name -> name <> "")
  in
  (* Remove duplicates and sort alphabetically *)
  List.sort_uniq String.compare vars

(** {1 In-memory Registry Storage} *)

let store = Prompt_registry_store.default ()
let registry = store.registry
let version_index = store.version_index
let override_tbl = store.override_tbl
let meta_tbl = store.meta_tbl

let with_mutex f = Prompt_registry_store.with_lock store f

let with_override_mutation_lock f =
  Prompt_registry_store.with_override_mutation_lock store f

(** {1 Persistence} *)

(** File-based persistence directory *)
let prompts_dir = store.prompts_dir

(** Markdown prompt source directory for operator-managed prompt text. *)
let markdown_dir = store.markdown_dir

let set_markdown_dir dir =
  with_override_mutation_lock (fun () ->
      with_mutex (fun () -> markdown_dir := Some dir))

(* Dune-context fallback for the markdown dir (quick-suite unmasking
   #24377, 'Prompt ... is missing' class). Production always pins the dir
   through [Prompt_defaults.bootstrap_runtime], and an explicit
   [set_markdown_dir] always wins. Test executables, however, run inside
   dune's sandbox where the cwd has no [config/prompts]; every executable
   that forgot the per-test pin resolved prompts to "missing" only in CI.
   DUNE_SOURCEROOT is set by dune for every build/exec/runtest and absent
   in production processes, so this is a deterministic, environment-scoped
   branch — not a permissive default: outside dune the behaviour is
   byte-identical to before (None). Tests that need true prompt absence pin an
   explicit empty dir, which this never overrides. *)
let dune_sourceroot_markdown_dir =
  lazy
    (match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | None -> None
    | Some root ->
        let dir = Filename.concat (Filename.concat root "config") "prompts" in
        if Sys.file_exists dir && Sys.is_directory dir then Some dir else None)

let effective_markdown_dir () =
  match !markdown_dir with
  | Some _ as pinned -> pinned
  | None -> Lazy.force dune_sourceroot_markdown_dir

let get_markdown_dir () = effective_markdown_dir ()

let is_valid_prompt_key key =
  key <> ""
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       key

let prompt_markdown_path key =
  if not (is_valid_prompt_key key) then None
  else
    Option.map
      (fun dir -> Filename.concat dir (key ^ ".md"))
      (effective_markdown_dir ())

(** Read a markdown file, stripping YAML frontmatter if present.
    Returns only the body after the closing [---] delimiter. *)
let read_file_if_exists path =
  if Sys.file_exists path && not (Sys.is_directory path) then
    let content = In_channel.with_open_text path In_channel.input_all in
    Some (markdown_body content)
  else None

(* ── Fragment-group slots (#32780, #32814) ─────────────────────────────

   A group file carries several short fragments as [### marker]
   paragraphs. A marker is a lower-case key segment ([is_slot_marker]),
   so a markdown heading with spaces, braces or a capital inside a
   paragraph stays prose — optionally followed by the slot's variables:
   [### standing.current (vars: target, behind, ahead)]. A
   slot registers under [<group-key>.<marker>], so every consumer and
   name constant keeps its old key; the registry, not the callers, knows
   the file was merged. Prose before the first marker is the group's own
   body and registers under the group key when there is any.

   Paragraphs are gathered in file order. The first cut walked the lines
   backwards, handed every slot the paragraph above it and dropped the
   last one (#32814). *)

let fragment_tbl : (string, string * string) Hashtbl.t = Hashtbl.create 16
(** [slot key → (group key, marker)] — filled by the directory loader. *)

(* A marker is a lower-case key segment: [a-z0-9._-]+. Lower-case only,
   so a one-word prose heading such as [### Summary] stays prose; every
   marker in the tree is lower-case already. *)
let is_slot_marker marker =
  marker <> ""
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true | _ -> false)
       marker

(* Marker line shapes: "### name" or "### name (vars: a, b)", where
   [name] obeys [is_slot_marker]. [None] for every other line, including
   a markdown heading that is prose. *)
(* A slot is a fragment of the prompt its group assembles, so that is the
   default. A slot an operator tunes on its own says so by ending its marker
   line with [\[primary\]] — the surface has to be per slot, because folding
   files by reader put operator-facing prompts and assembly fragments in the
   same file. *)
let strip_primary_suffix rest =
  let suffix = "[primary]" in
  if String.ends_with ~suffix rest then
    (String.trim (String.sub rest 0 (String.length rest - String.length suffix)), true)
  else (rest, false)
;;

let parse_slot_header line =
  if String.length line > 4 && String.sub line 0 4 = "### " then (
    let rest, primary =
      strip_primary_suffix (String.trim (String.sub line 4 (String.length line - 4)))
    in
    let marker, vars =
      match String.index_opt rest '(' with
      | Some open_paren when
          String.length rest >= open_paren + 8
          && String.sub rest (open_paren + 1) 6 = "vars: "
          && String.ends_with ~suffix:")" rest ->
        ( String.trim (String.sub rest 0 open_paren)
        , Some
            (String.sub rest (open_paren + 7) (String.length rest - open_paren - 8)) )
      | _ -> (rest, None)
    in
    if is_slot_marker marker then Some (marker, vars, primary) else None)
  else None

type body_split = {
  preamble : string;  (** trimmed prose before the first marker *)
  slots : (string * string option * bool * string) list;
      (** (marker, declared vars, operator-facing, paragraph) in file order *)
}

(* Body → preamble and slots, walking the lines in file order. A
   paragraph runs from its marker line to the next marker line. *)
let split_body body : body_split =
  let close lines = String.trim (String.concat "\n" (List.rev lines)) in
  let close_pending pending paragraph slots =
    match pending with
    | None -> slots
    | Some (marker, vars, primary) ->
      (marker, vars, primary, close paragraph) :: slots
  in
  let rec gather ~preamble ~slots ~pending ~paragraph = function
    | [] ->
      { preamble = close preamble
      ; slots = List.rev (close_pending pending paragraph slots) }
    | line :: rest -> (
      match parse_slot_header line with
      | Some header ->
        gather ~preamble ~slots:(close_pending pending paragraph slots)
          ~pending:(Some header) ~paragraph:[] rest
      | None -> (
        match pending with
        | Some _ ->
          gather ~preamble ~slots ~pending ~paragraph:(line :: paragraph) rest
        | None ->
          gather ~preamble:(line :: preamble) ~slots ~pending ~paragraph rest))
  in
  gather ~preamble:[] ~slots:[] ~pending:None ~paragraph:[]
    (String.split_on_char '\n' body)

let slot_paragraph body marker =
  (split_body body).slots
  |> List.find_opt (fun (m, _, _, _) -> String.equal m marker)
  |> Option.map (fun (_, _, _, paragraph) -> paragraph)

(* The file a key resolves against: its own file, or its group's file. *)
let prompt_source_path key =
  match Hashtbl.find_opt fragment_tbl key with
  | Some (group_key, _marker) -> prompt_markdown_path group_key
  | None -> prompt_markdown_path key

(* The file value for a key: one slot paragraph for a slot key; for any
   other key its file's body — the preamble alone when the file carries
   slots, so a group key never returns its slots' text. *)
let file_value_of_key key =
  match Hashtbl.find_opt fragment_tbl key with
  | Some (group_key, marker) -> (
    match Option.bind (prompt_markdown_path group_key) read_file_if_exists with
    | Some body -> slot_paragraph body marker
    | None -> None)
  | None ->
    Option.bind (prompt_markdown_path key) read_file_if_exists
    |> Option.map (fun body ->
           let split = split_body body in
           if split.slots = [] then body else split.preamble)

(** {1 Registration and Lookup} *)

(** Register a prompt entry in the registry.
    Automatically extracts variables if not provided. *)
(** {1 Template Rendering} *)

(* Total by construction: [template_variable_regex] wraps group 1 in every
   match, so [Re.Group.get] cannot raise here, and the list operations are
   pure. The previous blanket [try] could only fold asynchronous exceptions
   into a stringly error. *)
let render_template ?template_variables ~template ~vars () : (string, string) result =
  let vars = List.map (fun (name, value) -> (String.trim name, value)) vars in
  let missing =
    let effective_variables = extract_variables template in
    let declared_variables =
      match template_variables with
      | Some variables ->
          variables
          |> List.map String.trim
          |> List.filter (fun name -> name <> "")
      | None -> []
    in
    List.sort_uniq String.compare
      (effective_variables @ declared_variables)
    |> List.filter (fun name -> not (List.mem_assoc name vars))
  in
  if missing <> [] then
    Error
      (Printf.sprintf "Unresolved variables in template: %s"
         (String.concat ", " missing))
  else
    Ok
      (Re.replace template_variable_regex template ~f:(fun group ->
           let name = Re.Group.get group 1 |> String.trim in
           match List.assoc_opt name vars with
           | Some value -> value
           | None -> Re.Group.get group 0))

(** {1 Utility Functions} *)

let clear () : unit =
  with_override_mutation_lock (fun () ->
   with_mutex (fun () ->
    let persisted_dir = !prompts_dir in
    Hashtbl.clear registry;
    Hashtbl.clear version_index;
    Hashtbl.clear override_tbl;
    Hashtbl.clear meta_tbl;
    Hashtbl.clear fragment_tbl;
    prompts_dir := None;
    markdown_dir := None;
    (* Clear files if persistence enabled *)
    match persisted_dir with
    | Some dir when Sys.file_exists dir && Sys.is_directory dir ->
        let files = Sys.readdir dir in
        Array.iter (fun file ->
          if Filename.check_suffix file ".json" then
            Sys.remove (Filename.concat dir file)
        ) files
    | None | Some _ -> ()
  ))

(** {1 Simple Override API for Hardcoded Prompts} *)

(* Pure assembly of a [resolved] record from pre-captured values.
   Invariant: [file_value] must already be read by the caller — this
   function never touches the filesystem, so it is safe to call from
   inside a [with_mutex] block without the contention cost of disk
   I/O under the lock (the original sin that [resolve_prompt] at the
   bottom of this file was explicitly refactored to avoid, see #3335). *)
let build_resolved_from_snapshot ~key ~override_value ~file_value =
  let file_path = prompt_source_path key in
  let source, effective =
    match override_value with
    | Some value -> ("override", value)
    | None -> (
        match file_value with
        | Some value -> ("file", value)
        | None -> ("missing", ""))
  in
  {
    effective;
    source;
    file_value;
    override_value;
    file_path;
    file_exists = Option.is_some file_value;
    has_override = Option.is_some override_value;
  }

(* Aggregate snapshot for batch listing APIs.  [list_prompts] and
   [validate_prompt_templates] gather these under [with_mutex] and
   then resolve (with disk reads) outside the lock. *)
type prompt_snapshot = {
  snap_key : string;
  snap_meta : prompt_meta;
  snap_override_value : string option;
}

(* Resolve a single prompt by doing the filesystem read OUTSIDE the
   mutex.  Intended for batch [list_prompts]/[validate_prompt_templates]
   call sites that previously held [with_mutex] across [read_file_if_exists]. *)
let resolved_of_snapshot (s : prompt_snapshot) =
  let file_value = file_value_of_key s.snap_key in
  build_resolved_from_snapshot
    ~key:s.snap_key
    ~override_value:s.snap_override_value
    ~file_value

(* [expected = []] means the prompt is never rendered through
   {!render}/{!render_prompt_template} — it is spliced raw via
   [get_prompt] (e.g. [Keeper_prompt.system_prompt_body]) or otherwise has no
   substitution points.  [List.mem variable []] is always [false], so
   omitting an [expected = []] special case already treats every
   [{{ident}}] found in [template] as unexpected for those prompts,
   which is correct: nothing downstream will ever fill the
   placeholder in, and a literal [{{...}}] (or a legacy instruction
   gated behind one — masc#23929) would leak into the live prompt
   unrendered. A prior version of this function short-circuited to
   [[]] for [expected = []], which silently accepted any override
   content for such prompts, including stale placeholder syntax. *)
let unexpected_template_variables meta template =
  let expected = meta.template_variables in
  extract_variables template
  |> List.filter (fun variable -> not (List.mem variable expected))

(* Variant that takes a pre-computed [resolved] record.  Used by the
   batch listing paths that read files outside the mutex. *)
let prompt_item_json_of_resolved key (meta : prompt_meta) resolved =
  `Assoc
    [
      ("key", `String key);
      ("category", `String meta.category);
      ( "operator_surface",
        `String (Types.operator_surface_to_string meta.operator_surface) );
      ("description", `String meta.description);
      ("current", `String resolved.effective);
      ("effective", `String resolved.effective);
      ( "file_value", Json_util.string_opt_to_json resolved.file_value );
      ( "override_value", Json_util.string_opt_to_json resolved.override_value );
      ( "file_path", Json_util.string_opt_to_json resolved.file_path );
      ("file_exists", `Bool resolved.file_exists);
      ("source", `String resolved.source);
      ("has_override", `Bool resolved.has_override);
      ("char_count", `Int (String.length resolved.effective));
      ("required_file", `Bool meta.required_file);
      ( "template_variables",
        `List (List.map (fun value -> `String value) meta.template_variables) );
    ]

let compare_prompt_items a b =
  let get_key = function
    | `Assoc fields -> (
        match List.assoc_opt "key" fields with
        | Some (`String value) -> value
        | _ -> "")
    | _ -> ""
  in
  String.compare (get_key a) (get_key b)

let register_prompt_unlocked ~key ~description ?(category = "general")
    ?(operator_surface = Types.Primary) ?(required_file = false)
    ?(template_variables = []) () =
  with_mutex (fun () ->
      Hashtbl.replace meta_tbl key
        {
          description;
          category;
          operator_surface;
          required_file;
          template_variables = List.sort_uniq String.compare template_variables;
        })

let load_prompts_from_directory dir =
  with_override_mutation_lock (fun () ->
      if Sys.file_exists dir && Sys.is_directory dir then begin
        let files = Sys.readdir dir in
        Array.iter (fun file ->
          if Filename.check_suffix file ".md" then begin
            let key = Filename.remove_extension file in
            if is_valid_prompt_key key then begin
              let path = Filename.concat dir file in
              try
                let content = In_channel.with_open_text path In_channel.input_all in
                let meta_pairs, body = parse_frontmatter content in
                match List.assoc_opt "description" meta_pairs with
                | None -> ()  (* no frontmatter or no description — skip *)
                | Some description ->
                    (* DET-OK: [category] is optional frontmatter with the
                       documented schema default [general]; the default does
                       not depend on time, environment, or iteration order. *)
                    let category =
                      match List.assoc_opt "category" meta_pairs with
                      | Some category -> category
                      | None -> "general"
                    in
                    let operator_surface =
                      match List.assoc_opt "operator_surface" meta_pairs with
                      | None -> Types.Primary
                      | Some value ->
                          (match Types.operator_surface_of_string value with
                           | Some surface -> surface
                           | None ->
                               Log.Misc.warn
                                 "prompt %s has unknown operator_surface=%S; keeping it visible as primary"
                                 key value;
                               Types.Primary)
                    in
                    let template_variables =
                      match List.assoc_opt "template_variables" meta_pairs with
                      | Some v -> parse_list_value v
                      | None -> []
                    in
                    (* A group file registers each [### marker] paragraph
                       as <key>.<marker>, carrying the group's frontmatter
                       surface (the TUI prompt list hides fragments by
                       default, so a merged operator-facing prompt keeps
                       its primary surface) and the variables declared on
                       the marker line. The prose before the
                       first marker is the group's own body and registers
                       under the group key when there is any; a file
                       without markers registers whole. *)
                    let split = split_body body in
                    (* [slot_paragraph] returns the first paragraph of a
                       marker, so a repeated marker is logged and its later
                       paragraph ignored — the registered variables and the
                       text then come from the same paragraph. A marker with
                       no paragraph is logged and not registered. *)
                    let (_ : string list) =
                      List.fold_left
                        (fun seen (marker, slot_vars, primary, paragraph) ->
                          if List.mem marker seen then begin
                            Log.Misc.error
                              "prompt %s declares slot %s twice; the first paragraph stands and the later one is ignored"
                              key marker;
                            seen
                          end
                          else if String.equal paragraph "" then begin
                            Log.Misc.error
                              "prompt %s slot %s has no paragraph; it is not registered"
                              key marker;
                            marker :: seen
                          end
                          else begin
                            let slot_key = key ^ "." ^ marker in
                            let template_variables =
                              match slot_vars with
                              | None -> []
                              | Some declared ->
                                parse_list_value ("[" ^ declared ^ "]")
                            in
                            Hashtbl.replace fragment_tbl slot_key (key, marker);
                            register_prompt_unlocked ~key:slot_key ~description
                              ~category
                              ~operator_surface:
                                (if primary then Types.Primary else Types.Fragment)
                              ~required_file:true ~template_variables ();
                            marker :: seen
                          end)
                        [] split.slots
                    in
                    if split.slots = [] || split.preamble <> "" then
                      register_prompt_unlocked ~key ~description ~category
                        ~operator_surface
                        ~required_file:true ~template_variables ()
              with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                Log.Misc.error
                  "load_prompts_from_directory: failed to read %s: %s"
                  file (Printexc.to_string exn)
            end
          end
        ) files
      end)

(** Resolve a prompt. Resolution: override > file > missing. *)
let resolve_prompt key =
  let file_path = prompt_source_path key in
  let file_value = file_value_of_key key in
  with_mutex (fun () ->
    let override_value =
      Hashtbl.find_opt override_tbl key
      |> Option.map (fun (entry : Prompt_override_persistence.entry) ->
             entry.value)
    in
    let source, effective =
      match override_value with
      | Some value -> ("override", value)
      | None -> (
          match file_value with
          | Some value -> ("file", value)
          | None -> ("missing", ""))
    in
    {
      effective; source; file_value; override_value;
      file_path; file_exists = Option.is_some file_value;
      has_override = Option.is_some override_value;
    })

(** Get a prompt value. Resolution: override > file > missing *)
let get_prompt key = (resolve_prompt key).effective

let resolve_and_render_prompt_template key vars =
  let resolved = resolve_prompt key in
  if String.trim resolved.effective = "" then
    Error (Printf.sprintf "Prompt '%s' is missing" key)
  else
    let effective_variables = extract_variables resolved.effective in
    let metadata_variables =
      with_mutex (fun () ->
          match Hashtbl.find_opt meta_tbl key with
          | None -> None
          | Some meta -> (
              match meta.template_variables with
              | [] -> None
              | variables -> Some variables))
    in
    (match metadata_variables with
     | None -> ()
     | Some variables ->
         let metadata_variables =
           variables
           |> List.map String.trim
           |> List.filter (fun name -> name <> "")
           |> List.sort_uniq String.compare
         in
         if metadata_variables <> effective_variables then
           Log.Misc.warn
             "Prompt '%s' metadata template_variables drift from effective template: metadata=[%s] effective=[%s]"
             key (String.concat ", " metadata_variables)
             (String.concat ", " effective_variables));
    Result.map
      (fun rendered -> resolved, rendered)
      (render_template
         ~template_variables:effective_variables
         ~template:resolved.effective ~vars ())

let render_prompt_template key vars =
  Result.map snd (resolve_and_render_prompt_template key vars)

(** Validate and apply a single override entry (shared logic for
    [set_override] and [restore_overrides]).  Caller must NOT hold [mu].
    Returns [Ok ()] on success or [Error msg] describing why the entry
    was rejected.

    Validation and the override write happen inside a single
    [with_mutex] block so the [meta_tbl] snapshot we validated
    against is still in effect when we install the override.  A
    prior version split the two into separate mutex transactions —
    a concurrent [unregister] or [register_prompt] landing between
    them could invalidate the validation decision (e.g. overwrite a
    key's metadata with a different [template_variables] set after
    we validated but before we wrote the override). *)
let validated_override ?expected_contract_revision key value =
  let trimmed = String.trim value in
  let file_value = file_value_of_key key in
  if not (is_valid_prompt_key key) then Error "Invalid prompt key"
  else if trimmed = "" then Error "Prompt cannot be empty"
  else if String.length trimmed > 10000 then Error "Prompt too long (max 10000 chars)"
  else
    with_mutex (fun () ->
        match Hashtbl.find_opt meta_tbl key with
        | None -> Error "Unknown prompt key"
        | Some meta -> (
            let contract_body = file_value in
            match contract_body with
            | None -> Error "Prompt contract body is missing"
            | Some body ->
                let current_contract_revision =
                  Prompt_override_persistence.contract_revision ~body
                    ~template_variables:meta.template_variables
                in
                (match expected_contract_revision with
                 | Some persisted_revision
                   when not
                          (String.equal persisted_revision
                             current_contract_revision) ->
                     Error
                       (Printf.sprintf
                          "Prompt contract revision mismatch (persisted=%s, current=%s)"
                          persisted_revision current_contract_revision)
                 | None | Some _ ->
                     let unexpected =
                       unexpected_template_variables meta trimmed
                     in
                     if unexpected <> [] then
                       Error
                         (Printf.sprintf "Unknown template variables: %s"
                            (String.concat ", " unexpected))
                     else
                       Ok
                         Prompt_override_persistence.
                           {
                             key;
                             value = trimmed;
                             contract_revision = current_contract_revision;
                           })))

(** Set an override for a prompt *)
let set_override key value =
  with_override_mutation_lock (fun () ->
      match validated_override key value with
      | Error _ as error -> error
      | Ok entry ->
          with_mutex (fun () -> Hashtbl.replace override_tbl key entry);
          Ok ())

(** Clear override, reverting to file *)
let clear_prompt_override key =
  with_override_mutation_lock (fun () ->
      with_mutex (fun () -> Hashtbl.remove override_tbl key))

(** Get source of current value *)
let prompt_source key = (resolve_prompt key).source

(* [validate_prompt_templates] was doing [read_file_if_exists] inside
   the [with_mutex] fold via [resolve_prompt_unlocked], holding the
   registry mutex across every markdown file read.  Two-phase:
   snapshot under the mutex, then read files + build resolved records
   outside.  Same refactor pattern as [list_prompts] below. *)
let validate_prompt_templates () =
  let snapshots =
    with_mutex (fun () ->
      Hashtbl.fold
        (fun key meta acc ->
          { snap_key = key;
            snap_meta = meta;
            snap_override_value =
              Hashtbl.find_opt override_tbl key
              |> Option.map
                   (fun (entry : Prompt_override_persistence.entry) ->
                     entry.value);
          } :: acc)
        meta_tbl [])
  in
  List.fold_left
    (fun acc s ->
      let resolved = resolved_of_snapshot s in
      let issues =
        match resolved with
        | { effective = ""; source = "missing"; _ } -> []
        | resolved ->
            unexpected_template_variables s.snap_meta resolved.effective
            |> List.map (fun variable -> (s.snap_key, variable))
      in
      issues @ acc)
    [] snapshots
  |> List.sort compare

(** List all registered prompts with metadata, for API/dashboard.

    Previously held [with_mutex] across every [read_file_if_exists]
    call (once per registered prompt), blocking all other prompt
    registry operations for the full disk scan.  Now:

    1. Snapshot (key, meta, override) under [with_mutex].
    2. Release the lock.
    3. For each snapshot, read the markdown file and build the
       [resolved] record outside the lock.
    4. Sort and return.

    Concurrent callers no longer serialize on disk I/O; the only lock
    hold is the in-memory Hashtbl fold. *)
let list_prompts () =
  let snapshots =
    with_mutex (fun () ->
      Hashtbl.fold
        (fun key meta acc ->
          { snap_key = key;
            snap_meta = meta;
            snap_override_value =
              Hashtbl.find_opt override_tbl key
              |> Option.map
                   (fun (entry : Prompt_override_persistence.entry) ->
                     entry.value);
          } :: acc)
        meta_tbl [])
  in
  snapshots
  |> List.map (fun s ->
    let resolved = resolved_of_snapshot s in
    prompt_item_json_of_resolved s.snap_key s.snap_meta resolved)
  |> List.sort compare_prompt_items

(** JSON export of all prompts for API *)
let prompts_json () =
  `Assoc [
    ("prompts", `List (list_prompts ()));
  ]

(** Persist overrides to JSON file *)
let save_override_entries base_path entries =
  let masc_dir = Workspace_utils.masc_dir_from_base_path ~base_path in
  try
    Fs_compat.mkdir_p masc_dir;
    let path = Filename.concat masc_dir "prompt_overrides.json" in
    Prompt_override_persistence.save ~path entries
    |> Result.map_error Prompt_override_persistence.error_to_string
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | Sys_error message -> Error message
  | Unix.Unix_error (error, operation, argument) ->
      Error
        (Printf.sprintf "%s(%s): %s" operation argument
           (Unix.error_message error))

let override_entries () =
  with_mutex (fun () ->
      Hashtbl.fold (fun _ entry acc -> entry :: acc) override_tbl [])

let replace_override_entries entries =
  with_mutex (fun () ->
      Hashtbl.clear override_tbl;
      List.iter
        (fun (entry : Prompt_override_persistence.entry) ->
          Hashtbl.replace override_tbl entry.key entry)
        entries)

let upsert_override_entry
    (entry : Prompt_override_persistence.entry) entries =
  entry
  :: List.filter
       (fun (current : Prompt_override_persistence.entry) ->
         not (String.equal current.key entry.key))
       entries

let persist_overrides base_path =
  with_override_mutation_lock (fun () ->
      save_override_entries base_path (override_entries ()))

let set_override_persisted ?expected_contract_revision ~base_path key value =
  with_override_mutation_lock (fun () ->
      match validated_override ?expected_contract_revision key value with
      | Error message -> Error (Validation_error message)
      | Ok entry ->
          let candidate = upsert_override_entry entry (override_entries ()) in
          (match save_override_entries base_path candidate with
           | Error message -> Error (Persistence_error message)
           | Ok () ->
               replace_override_entries candidate;
               Ok ()))

let clear_prompt_override_persisted ~base_path key =
  with_override_mutation_lock (fun () ->
      let candidate =
        override_entries ()
        |> List.filter
             (fun (entry : Prompt_override_persistence.entry) ->
               not (String.equal entry.key key))
      in
      match save_override_entries base_path candidate with
      | Error _ as error -> error
      | Ok () ->
          replace_override_entries candidate;
          Ok ())

(** Restore overrides from JSON file, applying the same validation as
    [set_override] so that stale or manually-edited entries are rejected. *)
let restore_failure_observer = Atomic.make (fun () -> ())

let set_restore_failure_observer observer =
  Atomic.set restore_failure_observer observer

let record_override_restore_failure () =
  (Atomic.get restore_failure_observer) ()

let restore_overrides base_path =
  let path =
    Filename.concat
      (Workspace_utils.masc_dir_from_base_path ~base_path)
      "prompt_overrides.json"
  in
  with_override_mutation_lock (fun () ->
      let candidate, failures =
        if not (Sys.file_exists path) then ([], [])
        else
          match Prompt_override_persistence.load ~path with
          | Error error ->
              ( [],
                [
                  ( None,
                    Prompt_override_persistence.error_to_string error );
                ] )
          | Ok entries ->
              List.fold_left
                (fun (accepted, rejected)
                     (entry : Prompt_override_persistence.entry) ->
                  match
                    validated_override
                      ~expected_contract_revision:entry.contract_revision
                      entry.key entry.value
                  with
                  | Ok validated -> (validated :: accepted, rejected)
                  | Error reason ->
                      (accepted, (Some entry.key, reason) :: rejected))
                ([], []) entries
      in
      (* Commit the fully validated candidate before invoking observers.  A
         faulty observer must not leave a pre-existing stale override live. *)
      replace_override_entries candidate;
      List.iter
        (fun (key, reason) ->
          record_override_restore_failure ();
          match key with
          | None ->
              Log.Misc.error
                "prompt override restore: rejected persistence file, falling back to file values: %s"
                reason
          | Some key ->
              Log.Misc.error
                "prompt override restore: rejected %s, falling back to file value: %s"
                key reason)
        failures)
