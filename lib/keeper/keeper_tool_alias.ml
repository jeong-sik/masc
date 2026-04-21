(** Keeper_tool_alias — see .mli for contract.

    The mapping below is the single source of truth for LLM-facing tool
    surface naming. Reviewers: any change here must keep [to_public]
    total (every internal name has a defined behavior) and
    [to_internal] partial (only Anthropic-Code cognates resolve). *)

(* (public_name, internal_name).
   Keep alphabetical by public name to make diffs reviewable. *)
let aliases : (string * string) list =
  [
    "Bash", "keeper_bash";
    "Edit", "keeper_fs_edit";
    "Grep", "keeper_shell";   (* op=rg routed at dispatch layer, Phase A.4 *)
    "Read", "keeper_fs_read";
    "Write", "keeper_fs_edit"; (* create-vs-update collapsed at dispatch layer *)
  ]

(* Subset of [aliases] safe for OAS dual registration. Phase A.4
   (#8963 follow-up) added Edit/Write/Grep once their input adapters
   landed: Edit goes through the new keeper_fs_edit mode=patch path,
   Write maps cleanly to mode=overwrite, Grep synthesizes
   keeper_shell op=rg. *)
let oas_dual_register : (string * string) list =
  [
    "Bash", "keeper_bash";
    "Edit", "keeper_fs_edit";
    "Grep", "keeper_shell";
    "Read", "keeper_fs_read";
    "Write", "keeper_fs_edit";
  ]

(* Anthropic Code surface names without a keeper cognate. The disclosure
   check should not nuke a turn solely because these appeared — instead a
   teaching tool_result tells the LLM what surface to use. RFC-0006 §3.1. *)
let hallucinated_builtins =
  [ "Agent"; "Skill"; "WebSearch"; "WebFetch"; "TodoWrite"; "NotebookEdit" ]

let public_to_internal_tbl =
  let t = Hashtbl.create (List.length aliases) in
  List.iter (fun (pub, internal) -> Hashtbl.replace t pub internal) aliases;
  t

let internal_to_public_tbl =
  (* When two public names share an internal target (Edit/Write -> keeper_fs_edit)
     the first occurrence wins so [to_public] is stable. *)
  let t = Hashtbl.create (List.length aliases) in
  List.iter
    (fun (pub, internal) ->
      if not (Hashtbl.mem t internal) then Hashtbl.replace t internal pub)
    aliases;
  t

let to_internal name = Hashtbl.find_opt public_to_internal_tbl name

let to_public internal =
  match Hashtbl.find_opt internal_to_public_tbl internal with
  | Some public -> public
  | None -> internal

let canonicalize_observed names =
  List.map (fun n -> match to_internal n with Some i -> i | None -> n) names

let hallucinated_set =
  let t = Hashtbl.create (List.length hallucinated_builtins) in
  List.iter (fun n -> Hashtbl.replace t n ()) hallucinated_builtins;
  t

let is_hallucinated_builtin name = Hashtbl.mem hallucinated_set name

let all_aliases () = aliases

(* ── Phase A.2 OAS dual registration ────────────────────────────── *)

let oas_dual_register_aliases () = oas_dual_register

(* Helpers for assembling JSON tool schemas. Kept local to avoid coupling
   alias semantics with the broader Tool_shard helpers. *)
let property name typ description =
  ( name,
    `Assoc
      [ ("type", `String typ); ("description", `String description) ] )

let object_schema ?(required = []) properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun n -> `String n) required));
    ]

(* Anthropic Code "Bash" tool schema, mirrored as closely as we can while
   only exposing what keeper_bash actually supports. *)
let bash_public_schema =
  object_schema ~required:[ "command" ]
    [
      property "command" "string"
        "The shell command to execute. Single command only. No chaining \
         (&&, ||, ;), pipes (|), or redirects (>, >>). Example: 'dune \
         build', 'rg pattern lib/'.";
      property "description" "string"
        "Optional short description of what the command does. Logged for \
         observability.";
      property "timeout" "number"
        "Timeout in seconds (default 30, max 180). For \
         run_in_background=true, 0 disables the timeout.";
      property "run_in_background" "boolean"
        "Default false. When true, returns immediately with \
         background_task_id; poll output via keeper_bash_output, stop via \
         keeper_bash_kill.";
    ]

(* Anthropic Code "Read" tool schema. We do not yet support offset/limit
   in keeper_fs_read; declared here so the LLM can pass them but the
   translator drops them. *)
let read_public_schema =
  object_schema ~required:[ "file_path" ]
    [
      property "file_path" "string"
        "Absolute or playground-relative file path to read.";
      property "limit" "integer"
        "Approximate maximum bytes to return (mapped to keeper_fs_read \
         max_bytes; line-based limit is not supported).";
      property "offset" "integer"
        "Currently ignored; reads from the start. Listed for compatibility \
         with the Anthropic Read tool surface.";
    ]

(* Anthropic Code "Edit" tool schema. Patch semantics: in-place string
   replacement. Maps to keeper_fs_edit mode=patch. *)
let edit_public_schema =
  object_schema ~required:[ "file_path"; "old_string"; "new_string" ]
    [
      property "file_path" "string"
        "Absolute or playground-relative file path to edit. The file \
         must exist.";
      property "old_string" "string"
        "Exact substring to replace. Must occur exactly once in the file \
         unless replace_all=true.";
      property "new_string" "string"
        "Replacement substring. Pass an empty string to delete \
         old_string.";
      property "replace_all" "boolean"
        "Default false. When true, replaces every occurrence of \
         old_string.";
    ]

(* Anthropic Code "Write" tool schema. Maps to keeper_fs_edit
   mode=overwrite (parent dirs created automatically). *)
let write_public_schema =
  object_schema ~required:[ "file_path"; "content" ]
    [
      property "file_path" "string"
        "Absolute or playground-relative file path. Parent directories \
         are created as needed.";
      property "content" "string"
        "Full file content. Overwrites the existing file.";
    ]

(* Anthropic Code "Grep" tool schema. Synthesized as keeper_shell op=rg
   so the LLM does not need to learn keeper_shell's op enum. The
   keeper_shell rg implementation already supports type/glob filters
   used here. Anthropic-Code -i and -n flags are accepted as boolean
   conveniences but currently dropped (rg always emits line numbers). *)
let grep_public_schema =
  object_schema ~required:[ "pattern" ]
    [
      property "pattern" "string"
        "Regular expression to search for.";
      property "path" "string"
        "Directory or file to search in. Defaults to the keeper \
         playground when omitted.";
      property "glob" "string"
        "Glob filter, e.g. '*.ml' or 'lib/**/*.ml'.";
      property "type" "string"
        "Ripgrep file-type filter, e.g. 'ml', 'py'.";
      property "-i" "boolean"
        "Case insensitive. Currently accepted but not yet routed; \
         Anthropic-Code compatibility shim.";
      property "-n" "boolean"
        "Show line numbers. Always true under the hood; accepted for \
         schema parity.";
    ]

let public_input_schema = function
  | "Bash" -> Some bash_public_schema
  | "Edit" -> Some edit_public_schema
  | "Grep" -> Some grep_public_schema
  | "Read" -> Some read_public_schema
  | "Write" -> Some write_public_schema
  | _ -> None

(* Translate an LLM call payload from the public schema to the internal
   tool's expected shape. Identity for unknown aliases.

   Robust against malformed payloads: anything that isn't a JSON object
   passes through unchanged so the downstream validator can produce the
   normal structured error. *)
let translate_bash_input input =
  match input with
  | `Assoc fields ->
      let out = ref [] in
      List.iter
        (fun (k, v) ->
          match k with
          | "command" -> out := ("cmd", v) :: !out
          | "timeout" -> out := ("timeout_sec", v) :: !out
          | "description" -> ()  (* dropped; logged elsewhere *)
          | _ -> out := (k, v) :: !out)
        fields;
      `Assoc (List.rev !out)
  | _ -> input

let translate_read_input input =
  match input with
  | `Assoc fields ->
      let out = ref [] in
      List.iter
        (fun (k, v) ->
          match k with
          | "file_path" -> out := ("path", v) :: !out
          | "limit" -> out := ("max_bytes", v) :: !out
          | "offset" -> ()  (* keeper_fs_read does not support offsets *)
          | _ -> out := (k, v) :: !out)
        fields;
      `Assoc (List.rev !out)
  | _ -> input

(* Anthropic Edit { file_path, old_string, new_string, replace_all? }
   → keeper_fs_edit { path, mode=patch, old_string, new_string,
                      replace_all }. The handler reads the current
   file, replaces, and writes back. *)
let translate_edit_input input =
  match input with
  | `Assoc fields ->
      let has_content = List.exists (fun (k, _) -> k = "content") fields in
      let mode = if has_content then "overwrite" else "patch" in
      let out = ref [ ("mode", `String mode) ] in
      List.iter
        (fun (k, v) ->
          match k with
          | "file_path" -> out := ("path", v) :: !out
          | "old_string" | "new_string" | "replace_all" | "content" ->
              out := (k, v) :: !out
          | "mode" -> ()  (* ignore caller-supplied overrides *)
          | _ -> out := (k, v) :: !out)
        fields;
      `Assoc (List.rev !out)
  | _ -> input

(* Anthropic Write { file_path, content } → keeper_fs_edit
   { path, content, mode=overwrite }. *)
let translate_write_input input =
  match input with
  | `Assoc fields ->
      let out = ref [ ("mode", `String "overwrite") ] in
      List.iter
        (fun (k, v) ->
          match k with
          | "file_path" -> out := ("path", v) :: !out
          | "content" -> out := ("content", v) :: !out
          | "mode" -> ()  (* always overwrite via Write alias *)
          | _ -> out := (k, v) :: !out)
        fields;
      `Assoc (List.rev !out)
  | _ -> input

(* Anthropic Grep { pattern, path?, glob?, type?, -i?, -n? } →
   keeper_shell { op=rg, pattern, path?, glob?, type? }. The boolean
   conveniences -i/-n are dropped; keeper_shell rg always emits line
   numbers and case sensitivity is folded into the pattern itself. *)
let translate_grep_input input =
  match input with
  | `Assoc fields ->
      let out = ref [ ("op", `String "rg") ] in
      let is_case_insensitive =
        match List.assoc_opt "-i" fields with
        | Some (`Bool true) -> true
        | _ -> false
      in
      List.iter
        (fun (k, v) ->
          match k with
          | "pattern" ->
              let v' = if is_case_insensitive then
                match v with
                | `String s -> `String ("(?i)" ^ s)
                | _ -> v
              else v
              in
              out := (k, v') :: !out
          | "path" | "glob" | "type" ->
              out := (k, v) :: !out
          | "op" -> ()  (* always rg via Grep alias *)
          | "-i" | "-n" -> ()  (* shim accepted, not routed *)
          | _ -> out := (k, v) :: !out)
        fields;
      `Assoc (List.rev !out)
  | _ -> input

let translate_input ~public input =
  match public with
  | "Bash" -> translate_bash_input input
  | "Edit" -> translate_edit_input input
  | "Grep" -> translate_grep_input input
  | "Read" -> translate_read_input input
  | "Write" -> translate_write_input input
  | _ -> input

let expand_universe internal_names =
  let already = Hashtbl.create (List.length internal_names) in
  List.iter (fun n -> Hashtbl.replace already n ()) internal_names;
  let extras =
    List.filter_map
      (fun (public, internal) ->
        if Hashtbl.mem already internal && not (Hashtbl.mem already public)
        then begin
          Hashtbl.replace already public ();
          Some public
        end
        else None)
      oas_dual_register
  in
  internal_names @ extras
