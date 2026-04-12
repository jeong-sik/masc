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
let extract_variables template =
  let regex = Re.Pcre.re {|\{\{([^}]+)\}\}|} |> Re.compile in
  let vars = Re.all regex template
    |> List.map (fun g -> Re.Group.get g 1)
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

(** {1 Persistence} *)

(** File-based persistence directory *)
let prompts_dir = store.prompts_dir

(** Markdown prompt source directory for operator-managed prompt text. *)
let markdown_dir = store.markdown_dir

(** Make a storage key from id and version *)
let make_key ~id ~version = Printf.sprintf "%s@%s" id version

(** Initialize the registry with optional file persistence *)
let init ?persist_dir () =
  prompts_dir := persist_dir;
  match persist_dir with
  | Some dir ->
      (* Load existing prompts from directory *)
      if Sys.file_exists dir && Sys.is_directory dir then begin
        let files = Sys.readdir dir in
        Array.iter (fun file ->
          if Filename.check_suffix file ".json" then begin
            let path = Filename.concat dir file in
            try
              let content = In_channel.with_open_text path In_channel.input_all in
              let json = Yojson.Safe.from_string content in
              match prompt_entry_of_yojson json with
              | Ok entry ->
                  let key = make_key ~id:entry.id ~version:entry.version in
                  Hashtbl.replace registry key entry;
                  (* Update version index *)
                  let versions = match Hashtbl.find_opt version_index entry.id with
                    | Some vs -> if List.mem entry.version vs then vs else entry.version :: vs
                    | None -> [entry.version]
                  in
                  Hashtbl.replace version_index entry.id versions
              | Error msg ->
                Log.Misc.error "Failed to parse %s: %s" file msg
            with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
              Log.Misc.error "Failed to parse %s: %s" file (Printexc.to_string exn)
          end
        ) files
      end
  | None -> ()

let set_markdown_dir dir =
  markdown_dir := Some dir

let get_markdown_dir () = !markdown_dir

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
    Option.map (fun dir -> Filename.concat dir (key ^ ".md")) !markdown_dir

(** Read a markdown file, stripping YAML frontmatter if present.
    Returns only the body after the closing [---] delimiter. *)
let read_file_if_exists path =
  if Sys.file_exists path && not (Sys.is_directory path) then
    let content = In_channel.with_open_text path In_channel.input_all in
    let _meta, body = parse_frontmatter content in
    Some body
  else None

(** {1 Registration and Lookup} *)

(** Register a prompt entry in the registry.
    Automatically extracts variables if not provided. *)
let register (entry : prompt_entry) : unit =
  with_mutex (fun () ->
    (* Auto-extract variables if empty *)
    let entry =
      if entry.variables = [] then
        { entry with variables = extract_variables entry.template }
      else entry
    in
    let key = make_key ~id:entry.id ~version:entry.version in
    Hashtbl.replace registry key entry;

    (* Update version index *)
    let versions = match Hashtbl.find_opt version_index entry.id with
      | Some vs -> if List.mem entry.version vs then vs else entry.version :: vs
      | None -> [entry.version]
    in
    Hashtbl.replace version_index entry.id versions;

    (* Persist to file if enabled *)
    match !prompts_dir with
    | Some dir ->
        Fs_compat.mkdir_p dir;
        let filename = Printf.sprintf "%s_%s.json" entry.id entry.version in
        let path = Filename.concat dir filename in
        let json = prompt_entry_to_yojson entry in
        Out_channel.with_open_text path (fun oc ->
          Out_channel.output_string oc (Yojson.Safe.pretty_to_string json)
        )
    | None -> ()
  )

(** Get a prompt entry by ID and optional version.
    If version is not specified, returns the latest non-deprecated version. *)
let get ~id ?version () : prompt_entry option =
  with_mutex (fun () ->
    match version with
    | Some v ->
        let key = make_key ~id ~version:v in
        Hashtbl.find_opt registry key
    | None ->
        (* Find latest non-deprecated version *)
        match Hashtbl.find_opt version_index id with
        | None -> None
        | Some versions ->
            (* Sort versions descending and find first non-deprecated *)
            let sorted = List.sort (fun a b -> String.compare b a) versions in
            List.find_map (fun v ->
              let key = make_key ~id ~version:v in
              match Hashtbl.find_opt registry key with
              | Some entry when not entry.deprecated -> Some entry
              | _ -> None
            ) sorted
  )

(** Get all versions of a prompt by ID *)
let get_versions ~id () : prompt_entry list =
  with_mutex (fun () ->
    match Hashtbl.find_opt version_index id with
    | None -> []
    | Some versions ->
        List.filter_map (fun v ->
          let key = make_key ~id ~version:v in
          Hashtbl.find_opt registry key
        ) versions
  )

(** List all registered prompt entries *)
let list_all () : prompt_entry list =
  with_mutex (fun () ->
    Hashtbl.fold (fun _ entry acc -> entry :: acc) registry []
  )

(** List all prompt IDs (unique, without versions) *)
let list_ids () : string list =
  with_mutex (fun () ->
    Hashtbl.fold (fun id _ acc -> id :: acc) version_index []
  )

(** Check if a prompt exists *)
let exists ~id ?version () : bool =
  with_mutex (fun () ->
    match version with
    | Some v ->
        let key = make_key ~id ~version:v in
        Hashtbl.mem registry key
    | None ->
        Hashtbl.mem version_index id
  )

(** Unregister a prompt entry *)
let unregister ~id ?version () : bool =
  with_mutex (fun () ->
    match version with
    | Some v ->
        let key = make_key ~id ~version:v in
        if Hashtbl.mem registry key then begin
          Hashtbl.remove registry key;
          (* Update version index *)
          (match Hashtbl.find_opt version_index id with
           | Some vs ->
               let new_vs = List.filter (fun ver -> ver <> v) vs in
               if new_vs = [] then Hashtbl.remove version_index id
               else Hashtbl.replace version_index id new_vs
           | None -> ());
          (* Remove file if persistence enabled *)
          (match !prompts_dir with
           | Some dir ->
               let filename = Printf.sprintf "%s_%s.json" id v in
               let path = Filename.concat dir filename in
               if Sys.file_exists path then Sys.remove path
           | None -> ());
          true
        end else false
    | None ->
        (* Remove all versions *)
        match Hashtbl.find_opt version_index id with
        | None -> false
        | Some versions ->
            List.iter (fun v ->
              let key = make_key ~id ~version:v in
              Hashtbl.remove registry key;
              (match !prompts_dir with
               | Some dir ->
                   let filename = Printf.sprintf "%s_%s.json" id v in
                   let path = Filename.concat dir filename in
                   if Sys.file_exists path then Sys.remove path
               | None -> ())
            ) versions;
            Hashtbl.remove version_index id;
            true
  )

(** Mark a prompt as deprecated *)
let deprecate ~id ~version () : bool =
  with_mutex (fun () ->
    let key = make_key ~id ~version in
    match Hashtbl.find_opt registry key with
    | Some entry ->
        let updated = { entry with deprecated = true } in
        Hashtbl.replace registry key updated;
        true
    | None -> false
  )

(** {1 Metrics} *)

(** Update usage metrics after a prompt is used *)
let update_metrics ~id ~version ~score () : unit =
  with_mutex (fun () ->
    let key = make_key ~id ~version in
    match Hashtbl.find_opt registry key with
    | Some entry ->
        let now = Unix.gettimeofday () in
        let new_metrics = match entry.metrics with
          | None ->
              { usage_count = 1; avg_score = score; last_used = now }
          | Some m ->
              let new_count = m.usage_count + 1 in
              let new_avg = (m.avg_score *. float_of_int m.usage_count +. score)
                            /. float_of_int new_count in
              { usage_count = new_count; avg_score = new_avg; last_used = now }
        in
        let updated = { entry with metrics = Some new_metrics } in
        Hashtbl.replace registry key updated;
        (* Persist updated metrics if enabled *)
        (match !prompts_dir with
         | Some dir ->
             let filename = Printf.sprintf "%s_%s.json" id version in
             let path = Filename.concat dir filename in
             let json = prompt_entry_to_yojson updated in
             Out_channel.with_open_text path (fun oc ->
               Out_channel.output_string oc (Yojson.Safe.pretty_to_string json)
             )
         | None -> ())
    | None -> ()
  )

(** {1 Template Rendering} *)

(** Render a prompt template with the given variables *)
let render_template ~template ~vars () : (string, string) result =
  try
    let result = ref template in
    List.iter (fun (name, value) ->
      let pattern = Printf.sprintf "{{%s}}" name in
      result := Re.replace_string (Re.str pattern |> Re.compile) ~by:value !result
    ) vars;
    (* Check for unresolved variables anywhere in the result *)
    let regex = Re.Pcre.re {|\{\{[^}]+\}\}|} |> Re.compile in
    let has_unresolved = Re.execp regex !result in
    if has_unresolved then
      Error "Unresolved variables in template"
    else
      Ok !result
  with e ->
    Error (Printf.sprintf "Render error: %s" (Printexc.to_string e))

(** Render a registered prompt by ID with the given variables *)
let render ~id ?version ~vars () : (string, string) result =
  match get ~id ?version () with
  | None -> Error (Printf.sprintf "Prompt '%s' not found" id)
  | Some entry -> render_template ~template:entry.template ~vars ()

(** {1 Statistics} *)

(** Get registry statistics *)
let stats () : registry_stats =
  with_mutex (fun () ->
    let all_entries = Hashtbl.fold (fun _ entry acc -> entry :: acc) registry [] in
    let total = List.length all_entries in
    let active = List.length (List.filter (fun e -> not e.deprecated) all_entries) in
    let deprecated = total - active in

    let most_used =
      List.fold_left (fun acc entry ->
        match entry.metrics with
        | None -> acc
        | Some m ->
            match acc with
            | None -> Some (entry.id, m.usage_count)
            | Some (_, count) when m.usage_count > count -> Some (entry.id, m.usage_count)
            | _ -> acc
      ) None all_entries
      |> Option.map fst
    in

    let total_usage =
      List.fold_left (fun acc entry ->
        match entry.metrics with
        | None -> acc
        | Some m -> acc + m.usage_count
      ) 0 all_entries
    in
    let avg_usage = if total > 0 then float_of_int total_usage /. float_of_int total else 0.0 in

    { total_prompts = total;
      active_prompts = active;
      deprecated_prompts = deprecated;
      most_used;
      avg_usage }
  )

(** {1 Utility Functions} *)

(** Clear all registered prompts *)
let clear () : unit =
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
    | _ -> ()
  )

(** Count of registered prompts (all versions) *)
let count () : int =
  with_mutex (fun () -> Hashtbl.length registry)

(** Count of unique prompt IDs *)
let count_unique () : int =
  with_mutex (fun () -> Hashtbl.length version_index)

(** Export registry to JSON *)
let to_json () : Yojson.Safe.t =
  with_mutex (fun () ->
    let entries = Hashtbl.fold (fun _ entry acc ->
      prompt_entry_to_yojson entry :: acc
    ) registry [] in
    `List entries
  )

(** Import registry from JSON *)
let of_json (json : Yojson.Safe.t) : (int, string) result =
  try
    let open Yojson.Safe.Util in
    let entries = to_list json in
    let count = ref 0 in
    List.iter (fun entry_json ->
      match prompt_entry_of_yojson entry_json with
      | Ok entry ->
          register entry;
          incr count
      | Error e -> Log.Misc.debug "prompt entry parse skipped: %s" e
    ) entries;
    Ok !count
  with e ->
    Error (Printexc.to_string e)

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

let unexpected_template_variables meta template =
  let expected = meta.template_variables in
  if expected = [] then []
  else
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
        match resolved.file_value with
        | Some value -> `String value
        | None -> (
            match resolved.default_value with
            | Some value -> `String value
            | None -> `Null) );
      ("effective", `String resolved.effective);
      ( "file_value",
        match resolved.file_value with
        | Some value -> `String value
        | None -> `Null );
      ( "override_value",
        match resolved.override_value with
        | Some value -> `String value
        | None -> `Null );
      ( "file_path",
        match resolved.file_path with
        | Some value -> `String value
        | None -> `Null );
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

let register_prompt ~key ~description ?(category = "general")
    ?(required_file = false) ?(template_variables = []) () =
  with_mutex (fun () ->
      Hashtbl.replace meta_tbl key
        {
          description;
          category;
          required_file;
          template_variables = List.sort_uniq String.compare template_variables;
        })

(** Auto-discover and register prompts from markdown files with frontmatter.
    Scans [dir] for [*.md] files. Files with YAML frontmatter get metadata
    from frontmatter; files without frontmatter are skipped (require explicit
    registration via [register_prompt]).

    Frontmatter format:
    {[
      ---
      description: keeper continuity rules
      category: keeper
      template_variables: [keeper_name, goal, triggers]
      ---
    ]}

    The key is derived from the filename: [keeper.constitution.md] -> [keeper.constitution]. *)
let load_prompts_from_directory dir =
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
                let category =
                  Option.value ~default:"general"
                    (List.assoc_opt "category" meta_pairs)
                in
                let template_variables =
                  match List.assoc_opt "template_variables" meta_pairs with
                  | Some v -> parse_list_value v
                  | None -> []
                in
                register_prompt ~key ~description ~category ~required_file:true
                  ~template_variables ()
          with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Log.Misc.error "load_prompts_from_directory: failed to read %s: %s"
              file (Printexc.to_string exn)
        end
      end
    ) files
  end

(** Register a hardcoded prompt with its default value.
    This also registers it in the versioned template system as a fallback. *)
let register_default ~key ~default ~description ?(category="general") () =
  with_mutex (fun () ->
    Hashtbl.replace meta_tbl key
      {
        description;
        category;
        required_file = false;
        template_variables = [];
      };
    let entry = {
      id = key;
      template = default;
      version = "default";
      variables = [];
      metrics = None;
      created_at = Unix.gettimeofday ();
      deprecated = false;
    } in
    let storage_key = make_key ~id:key ~version:"default" in
    Hashtbl.replace registry storage_key entry;
    let versions = match Hashtbl.find_opt version_index key with
      | Some vs -> if List.mem "default" vs then vs else "default" :: vs
      | None -> ["default"]
    in
      Hashtbl.replace version_index key versions
  )

(** Resolve a prompt with file I/O performed outside the mutex.
    Reads the markdown file first, then acquires the mutex for
    hashtbl lookups only. Prevents Eio.Mutex contention when
    file I/O blocks a fiber (#3335). *)
let resolve_prompt key =
  let file_path = prompt_markdown_path key in
  let file_value = Option.bind file_path read_file_if_exists in
  with_mutex (fun () ->
    let override_value = Hashtbl.find_opt override_tbl key in
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
  let template = get_prompt key in
  if String.trim template = "" then
    Error (Printf.sprintf "Prompt '%s' is missing" key)
  else
    render_template ~template ~vars ()

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
let apply_override_validated key value =
  let trimmed = String.trim value in
  if not (is_valid_prompt_key key) then Error "Invalid prompt key"
  else if trimmed = "" then Error "Prompt cannot be empty"
  else if String.length trimmed > 10000 then Error "Prompt too long (max 10000 chars)"
  else
    with_mutex (fun () ->
        match Hashtbl.find_opt meta_tbl key with
        | None -> Error "Unknown prompt key"
        | Some meta ->
            let unexpected = unexpected_template_variables meta trimmed in
            if unexpected <> [] then
              Error
                (Printf.sprintf "Unknown template variables: %s"
                   (String.concat ", " unexpected))
            else begin
              Hashtbl.replace override_tbl key trimmed;
              Ok ()
            end)

(** Set an override for a prompt *)
let set_override key value = apply_override_validated key value

(** Clear override, reverting to file or default *)
let clear_prompt_override key =
  with_mutex (fun () -> Hashtbl.remove override_tbl key)

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
            snap_override_value = Hashtbl.find_opt override_tbl key;
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
            snap_override_value = Hashtbl.find_opt override_tbl key;
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
let persist_overrides base_path =
  let masc_dir = Filename.concat base_path ".masc" in
  Fs_compat.mkdir_p masc_dir;
  let path = Filename.concat masc_dir "prompt_overrides.json" in
  let json = with_mutex (fun () ->
    Hashtbl.fold (fun key value acc ->
      (key, `String value) :: acc
    ) override_tbl []
  ) in
  let content = Yojson.Safe.pretty_to_string (`Assoc json) in
  Out_channel.with_open_text path (fun oc ->
    Out_channel.output_string oc content)

(** Restore overrides from JSON file, applying the same validation as
    [set_override] so that stale or manually-edited entries are rejected. *)
let restore_overrides base_path =
  let path = Filename.concat (Filename.concat base_path ".masc") "prompt_overrides.json" in
  if Sys.file_exists path then begin
    try
      let content = In_channel.with_open_text path In_channel.input_all in
      let json = Yojson.Safe.from_string content in
      match json with
      | `Assoc pairs ->
        List.iter (fun (key, value) ->
          match value with
          | `String s -> (
              match apply_override_validated key s with
              | Ok () -> ()
              | Error reason ->
                  Log.Misc.warn "prompt override restore: skipping %s: %s"
                    key reason)
          | _ -> ()
        ) pairs
      | _ -> ()
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Misc.warn "prompt override restore failed: %s" (Printexc.to_string exn)
  end
