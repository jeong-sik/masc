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

    Usage:
    {[
      (* Register a prompt *)
      let entry = {
        id = "code-review-v2";
        template = "Review this code: {{source_code}}";
        version = "2.0";
        variables = ["source_code"];
        metrics = None;
        created_at = Unix.gettimeofday ();
        deprecated = false;
      } in
      Prompt_registry.register entry;

      (* Look up by ID *)
      let prompt = Prompt_registry.get ~id:"code-review-v2" () in

      (* Render with variables *)
      let rendered = Prompt_registry.render ~id:"code-review-v2"
        ~vars:[("source_code", "let x = 1")] () in
    ]}
*)

(** {1 Types} *)

module Types = Prompt_registry_types

type prompt_metrics = Types.prompt_metrics = {
  usage_count: int;      (** Number of times this prompt has been used *)
  avg_score: float;      (** Average quality score (0.0 - 1.0) *)
  last_used: float;      (** Unix timestamp of last usage *)
}

let prompt_metrics_to_yojson = Types.prompt_metrics_to_yojson
let prompt_metrics_of_yojson = Types.prompt_metrics_of_yojson

type prompt_entry = Types.prompt_entry = {
  id: string;                     (** Unique identifier *)
  template: string;               (** Prompt template with {{var}} placeholders *)
  version: string;                (** Semantic version string *)
  variables: string list;         (** Extracted variable names from template *)
  metrics: prompt_metrics option; (** Optional usage metrics *)
  created_at: float;              (** Unix timestamp of creation *)
  deprecated: bool;               (** Whether this prompt is deprecated *)
}

let prompt_entry_to_yojson = Types.prompt_entry_to_yojson
let prompt_entry_of_yojson = Types.prompt_entry_of_yojson

type registry_stats = Types.registry_stats = {
  total_prompts: int;
  active_prompts: int;
  deprecated_prompts: int;
  most_used: string option;
  avg_usage: float;
}

type prompt_meta = Types.prompt_meta = {
  description: string;
  category: string;
  required_file: bool;
  template_variables: string list;
}

type prompt_resolution = Types.prompt_resolution = {
  effective: string;
  source: string;
  file_value: string option;
  override_value: string option;
  default_value: string option;
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
  let lines = String.split_on_char '\n' content in
  match lines with
  | first :: rest when String.trim first = "---" ->
      let rec collect_meta acc = function
        | [] -> (List.rev acc, "")
        | line :: remaining when String.trim line = "---" ->
            (List.rev acc, String.concat "\n" remaining)
        | line :: remaining ->
            let pair =
              match String.index_opt line ':' with
              | Some i ->
                  let key = String.trim (String.sub line 0 i) in
                  let value = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
                  Some (key, value)
              | None -> None
            in
            collect_meta (match pair with Some p -> p :: acc | None -> acc) remaining
      in
      collect_meta [] rest
  | _ -> ([], content)

let markdown_body content =
  let _metadata, body = parse_frontmatter content in
  body

(** Parse a bracketed list value like [a, b, c] into string list. *)
let parse_list_value s =
  let s = String.trim s in
  if String.length s >= 2 && s.[0] = '[' && s.[String.length s - 1] = ']' then
    let inner = String.sub s 1 (String.length s - 2) in
    String.split_on_char ',' inner
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  else []

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

(** Make a storage key from id and version *)
let make_key ~id ~version = Printf.sprintf "%s@%s" id version

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
   byte-identical to before (None). Tests that need true prompt absence
   pin an explicit empty dir (see [with_task_create_prompt_missing] in
   test_keeper_prompt_external.ml), which this never overrides. *)
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

(** {1 Registration and Lookup} *)

(** Register a prompt entry in the registry.
    Automatically extracts variables if not provided. *)
(** {1 Template Rendering} *)

let render_template ?template_variables ~template ~vars () : (string, string) result =
  try
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
  with e ->
    Error (Printf.sprintf "Render error: %s" (Printexc.to_string e))

(** {1 Utility Functions} *)

let clear () : unit =
  with_override_mutation_lock (fun () ->
   with_mutex (fun () ->
    let persisted_dir = !prompts_dir in
    Hashtbl.clear registry;
    Hashtbl.clear version_index;
    Hashtbl.clear override_tbl;
    Hashtbl.clear meta_tbl;
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

let default_prompt_value_unlocked key =
  let storage_key = make_key ~id:key ~version:"default" in
  match Hashtbl.find_opt registry storage_key with
  | Some entry -> Some entry.template
  | None -> None

(* Pure assembly of a [resolved] record from pre-captured values.
   Invariant: [file_value] must already be read by the caller — this
   function never touches the filesystem, so it is safe to call from
   inside a [with_mutex] block without the contention cost of disk
   I/O under the lock (the original sin that [resolve_prompt] at the
   bottom of this file was explicitly refactored to avoid, see #3335). *)
let build_resolved_from_snapshot
    ~key ~override_value ~default_value ~file_value =
  let file_path = prompt_markdown_path key in
  let source, effective =
    match override_value with
    | Some value -> ("override", value)
    | None -> (
        match file_value with
        | Some value -> ("file", value)
        | None -> (
            match default_value with
            | Some value -> ("default", value)
            | None -> ("missing", "")))
  in
  {
    effective;
    source;
    file_value;
    override_value;
    default_value;
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
  snap_default_value : string option;
}

(* Resolve a single prompt by doing the filesystem read OUTSIDE the
   mutex.  Intended for batch [list_prompts]/[validate_prompt_templates]
   call sites that previously held [with_mutex] across [read_file_if_exists]. *)
let resolved_of_snapshot (s : prompt_snapshot) =
  let file_path = prompt_markdown_path s.snap_key in
  let file_value = Option.bind file_path read_file_if_exists in
  build_resolved_from_snapshot
    ~key:s.snap_key
    ~override_value:s.snap_override_value
    ~default_value:s.snap_default_value
    ~file_value

(* [expected = []] means the prompt is never rendered through
   {!render}/{!render_prompt_template} — it is spliced raw via
   [get_prompt] (e.g. [keeper_constitution]) or otherwise has no
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
      ("description", `String meta.description);
      ("current", `String resolved.effective);
      ( "default",
        ((match resolved.file_value with Some _ as v -> v | None -> resolved.default_value)
         |> fun v -> match v with Some s -> `String s | None -> `Null) );
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
    ?(required_file = false) ?(template_variables = []) () =
  with_mutex (fun () ->
      Hashtbl.replace meta_tbl key
        {
          description;
          category;
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
                let meta_pairs, _body = parse_frontmatter content in
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
                    let template_variables =
                      match List.assoc_opt "template_variables" meta_pairs with
                      | Some v -> parse_list_value v
                      | None -> []
                    in
                    register_prompt_unlocked ~key ~description ~category
                      ~required_file:true ~template_variables ()
              with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                Log.Misc.error
                  "load_prompts_from_directory: failed to read %s: %s"
                  file (Printexc.to_string exn)
            end
          end
        ) files
      end)

(** Register a hardcoded prompt with its default value.
    This also registers it in the versioned template system as a fallback. *)
let resolve_prompt key =
  let file_path = prompt_markdown_path key in
  let file_value = Option.bind file_path read_file_if_exists in
  with_mutex (fun () ->
    let override_value =
      Hashtbl.find_opt override_tbl key
      |> Option.map (fun (entry : Prompt_override_persistence.entry) ->
             entry.value)
    in
    let default_value = default_prompt_value_unlocked key in
    let source, effective =
      match override_value with
      | Some value -> ("override", value)
      | None -> (
          match file_value with
          | Some value -> ("file", value)
          | None -> (
              match default_value with
              | Some value -> ("default", value)
              | None -> ("missing", "")))
    in
    {
      effective; source; file_value; override_value; default_value;
      file_path; file_exists = Option.is_some file_value;
      has_override = Option.is_some override_value;
    })

(** Get a prompt value. Resolution: override > file > registered default *)
let get_prompt key = (resolve_prompt key).effective

let render_prompt_template key vars =
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
    render_template
      ~template_variables:effective_variables
      ~template:resolved.effective ~vars ()

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
  let file_value =
    Option.bind (prompt_markdown_path key) read_file_if_exists
  in
  if not (is_valid_prompt_key key) then Error "Invalid prompt key"
  else if trimmed = "" then Error "Prompt cannot be empty"
  else if String.length trimmed > 10000 then Error "Prompt too long (max 10000 chars)"
  else
    with_mutex (fun () ->
        match Hashtbl.find_opt meta_tbl key with
        | None -> Error "Unknown prompt key"
        | Some meta -> (
            let contract_body =
              match file_value with
              | Some body -> Some body
              | None -> default_prompt_value_unlocked key
            in
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

(** Clear override, reverting to file or default *)
let clear_prompt_override key =
  with_override_mutation_lock (fun () ->
      with_mutex (fun () -> Hashtbl.remove override_tbl key))

(** Get source of current value *)
let prompt_source key = (resolve_prompt key).source

let validate_required_prompt_files () =
  with_mutex (fun () ->
      Hashtbl.fold
        (fun key meta acc ->
          if not meta.required_file then acc
          else
            match prompt_markdown_path key with
            | Some path when Sys.file_exists path && not (Sys.is_directory path) -> acc
            | Some path -> (key, path) :: acc
            | None -> (key, "<invalid-key>") :: acc)
        meta_tbl [] |> List.sort compare)

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
            snap_default_value = default_prompt_value_unlocked key;
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

    1. Snapshot (key, meta, override, default) under [with_mutex].
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
            snap_default_value = default_prompt_value_unlocked key;
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

let set_override_persisted ~base_path key value =
  with_override_mutation_lock (fun () ->
      match validated_override key value with
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
let restore_failure_observer : (unit -> unit) ref = ref (fun () -> ())

let set_restore_failure_observer observer =
  restore_failure_observer := observer

let record_override_restore_failure () =
  !restore_failure_observer ()

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
                "prompt override restore: rejected persistence file, falling back to file/default values: %s"
                reason
          | Some key ->
              Log.Misc.error
                "prompt override restore: rejected %s, falling back to file/default value: %s"
                key reason)
        failures)
