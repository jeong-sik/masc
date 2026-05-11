(** Keeper_tool_alias — flat routing table for two-surface tool naming.

    RFC-0064: replaces the 3-tier classification (aliases / oas_dual_register
    / hallucinated_builtins) with a single [route] type. Each LLM-native tool
    name maps to one route record containing the internal handler name, an
    input translator, and an optional public schema.

    Two surfaces:
    - LLM native tools: Bash, Read, Edit, Write, Grep, WebSearch, WebFetch
    - MCP tools: masc_* (handled separately via Tool_catalog_surfaces)

    Internal [keeper_*] names are implementation details of the routing layer,
    not a public surface. A tool call for a name we don't handle is a routing
    miss — captured by result-based telemetry, not by upfront classification.

    @since 2.187.0 — RFC-0064 two-surface model *)

(* ── Route type ──────────────────────────────────────────────────── *)

type route =
  { internal_name : string
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; public_schema : Yojson.Safe.t option
  }

let routing_table : (string, route) Hashtbl.t =
  let t = Hashtbl.create 8 in
  (* Kept alphabetical by public name for reviewability. *)
  let entries =
    [ "Bash", { internal_name = "keeper_bash"; translate = Fun.id; public_schema = None }
    ; ( "Edit"
      , { internal_name = "keeper_fs_edit"; translate = Fun.id; public_schema = None } )
    ; "Grep", { internal_name = "keeper_shell"; translate = Fun.id; public_schema = None }
    ; ( "Read"
      , { internal_name = "keeper_fs_read"; translate = Fun.id; public_schema = None } )
    ; ( "WebFetch"
      , { internal_name = "masc_web_fetch"; translate = Fun.id; public_schema = None } )
    ; ( "WebSearch"
      , { internal_name = "masc_web_search"; translate = Fun.id; public_schema = None } )
    ; ( "Write"
      , { internal_name = "keeper_fs_edit"; translate = Fun.id; public_schema = None } )
    ]
  in
  List.iter (fun (pub, r) -> Hashtbl.replace t pub r) entries;
  t
;;

(* Schema and translator registration happens after the per-tool helpers
   below are defined. See [register_schemas_and_translators] at the end. *)

(* ── Result-based telemetry ──────────────────────────────────────── *)

(** [is_known_public name] is [true] when [name] has a routing entry. *)
let is_known_public name = Hashtbl.mem routing_table name

(** Known internal handler names — the [internal_name] values that
    [routing_table] entries map onto, plus the [masc_*] surface that
    [public_masc_to_internal] resolves. Used to bound the [routed_to]
    Prometheus label so that unrecognised strings never become a new
    time series. *)
let known_internal_names_tbl : (string, unit) Hashtbl.t =
  let t = Hashtbl.create 64 in
  Hashtbl.iter (fun _ r -> Hashtbl.replace t r.internal_name ()) routing_table;
  List.iter (fun n -> Hashtbl.replace t n ()) Tool_catalog_surfaces.keeper_internal_tools;
  t
;;

let register_known_internal name =
  if name <> "" then Hashtbl.replace known_internal_names_tbl name ()
;;

let is_known_internal name = Hashtbl.mem known_internal_names_tbl name

(** Bound a label value to a closed set so hallucinated / unbounded
    names never inflate Prometheus cardinality. *)
let safe_tool_label name =
  if is_known_public name
  then name
  else if is_known_internal name
  then name
  else "unknown"
;;

let safe_routed_to_label name =
  if name = "none" then name else if is_known_internal name then name else "unknown"
;;

let record_route_outcome ~tool ~routed_to ~result =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_tool_call_total
    ~labels:
      [ "tool", safe_tool_label tool
      ; "routed_to", safe_routed_to_label routed_to
      ; "result", result
      ]
    ()
;;

(** [route public_name] returns routing info for a known LLM-native tool.
    [None] means the name is not in our surface — a routing miss. *)
let route name =
  match Hashtbl.find_opt routing_table name with
  | Some r -> Some r
  | None -> None
;;

(** [route_or_miss name] returns the route if found, or records a routing
    miss via result-based telemetry and returns [None].

    Used by direct OAS-edge dispatch where a [None] result short-circuits
    the call. General canonicalisation (which also has to handle MCP
    prefixes and pass-through of already-internal names) goes through
    [Keeper_tool_disclosure.canonical_tool_name], which emits its own
    per-branch telemetry — see that module for the wider path. *)
let route_or_miss name =
  match route name with
  | Some r ->
    record_route_outcome ~tool:name ~routed_to:r.internal_name ~result:"ok";
    Some r
  | None ->
    record_route_outcome ~tool:name ~routed_to:"none" ~result:"miss";
    None
;;

(** [public_names ()] returns all LLM-native public names in stable order.
    Used by callers that previously used [expand_universe] to add alias names
    to allowlists — they should now add these names directly. *)
let public_names () = [ "Bash"; "Edit"; "Grep"; "Read"; "WebFetch"; "WebSearch"; "Write" ]

(* ── MCP surface routing (separate concern) ──────────────────────── *)

let public_masc_to_internal_tbl =
  let t = Hashtbl.create 16 in
  List.iter
    (fun internal ->
       match Tool_catalog_surfaces.keeper_internal_replacement internal with
       | Some public -> Hashtbl.replace t public internal
       | None -> ())
    Tool_catalog_surfaces.keeper_internal_tools;
  t
;;

let public_masc_to_internal name = Hashtbl.find_opt public_masc_to_internal_tbl name

let strip_mcp_masc_prefix name =
  if String.starts_with ~prefix:"mcp__masc__" name
  then String.sub name 11 (String.length name - 11)
  else name
;;

(* ── Schema helpers (local) ──────────────────────────────────────── *)

let property name typ description =
  name, `Assoc [ "type", `String typ; "description", `String description ]
;;

let object_schema ?(required = []) properties =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun n -> `String n) required)
    ]
;;

(* ── Public input schemas ─────────────────────────────────────────── *)

let bash_public_schema =
  object_schema
    ~required:[ "command" ]
    [ property
        "command"
        "string"
        "The shell command to execute. Single command only. No chaining (&&, ||, ;), \
         pipes (|), or redirects (>, >>). Example: 'dune build', 'rg pattern lib/'."
    ; property
        "description"
        "string"
        "Optional short description of what the command does. Logged for observability."
    ; property
        "timeout"
        "number"
        "Timeout in seconds (default 30, max 180). For run_in_background=true, 0 \
         disables the timeout."
    ; property
        "run_in_background"
        "boolean"
        "Default false. When true, returns immediately with background_task_id; poll \
         output via keeper_bash_output, stop via keeper_bash_kill."
    ]
;;

let read_public_schema =
  object_schema
    ~required:[ "file_path" ]
    [ property "file_path" "string" "Absolute or playground-relative file path to read."
    ; property
        "limit"
        "integer"
        "Approximate maximum bytes to return (mapped to keeper_fs_read max_bytes; \
         line-based limit is not supported)."
    ; property
        "offset"
        "integer"
        "Currently ignored; reads from the start. Listed for compatibility with the \
         Anthropic Read tool surface."
    ]
;;

let edit_public_schema =
  object_schema
    ~required:[ "file_path"; "old_string"; "new_string" ]
    [ property
        "file_path"
        "string"
        "Absolute or playground-relative file path to edit. The file must exist."
    ; property
        "old_string"
        "string"
        "Exact substring to replace. Must occur exactly once in the file unless \
         replace_all=true."
    ; property
        "new_string"
        "string"
        "Replacement substring. Pass an empty string to delete old_string."
    ; property
        "replace_all"
        "boolean"
        "Default false. When true, replaces every occurrence of old_string."
    ]
;;

let write_public_schema =
  object_schema
    ~required:[ "file_path"; "content" ]
    [ property
        "file_path"
        "string"
        "Absolute or playground-relative file path. Parent directories are created as \
         needed."
    ; property "content" "string" "Full file content. Overwrites the existing file."
    ]
;;

let grep_public_schema =
  object_schema
    ~required:[ "pattern" ]
    [ property "pattern" "string" "Regular expression to search for."
    ; property
        "path"
        "string"
        "Directory or file to search in. Defaults to the keeper playground when omitted."
    ; property "glob" "string" "Glob filter, e.g. '*.ml' or 'lib/**/*.ml'."
    ; property "type" "string" "Ripgrep file-type filter, e.g. 'ml', 'py'."
    ; property
        "-i"
        "boolean"
        "Case insensitive. Currently accepted but not yet routed; Anthropic-Code \
         compatibility shim."
    ; property
        "-n"
        "boolean"
        "Show line numbers. Always true under the hood; accepted for schema parity."
    ]
;;

let web_fetch_public_schema =
  object_schema
    ~required:[ "url" ]
    [ property "url" "string" "URL to fetch (http or https only)."
    ; property "timeout" "integer" "Request timeout in seconds (default 15, max 60)."
    ]
;;

let web_search_public_schema =
  object_schema
    ~required:[ "query" ]
    [ property "query" "string" "Search query text for current public web information."
    ; property
        "limit"
        "integer"
        "Maximum number of results to return (default 5, max 10)."
    ]
;;

(** [public_input_schema public_name] returns the LLM-facing JSON schema
    for a known public tool name. [None] means no tailored schema exists. *)
let public_input_schema = function
  | "Bash" -> Some bash_public_schema
  | "Edit" -> Some edit_public_schema
  | "Grep" -> Some grep_public_schema
  | "Read" -> Some read_public_schema
  | "WebFetch" -> Some web_fetch_public_schema
  | "WebSearch" -> Some web_search_public_schema
  | "Write" -> Some write_public_schema
  | _ -> None
;;

(* ── Input translators ────────────────────────────────────────────── *)

let translate_bash_input input =
  match input with
  | `Assoc fields ->
    let out = ref [] in
    List.iter
      (fun (k, v) ->
         match k with
         | "command" -> out := ("cmd", v) :: !out
         | "timeout" -> out := ("timeout_sec", v) :: !out
         | "description" -> () (* dropped; logged elsewhere *)
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

let translate_read_input input =
  match input with
  | `Assoc fields ->
    let out = ref [] in
    List.iter
      (fun (k, v) ->
         match k with
         | "file_path" -> out := ("path", v) :: !out
         | "limit" -> out := ("max_bytes", v) :: !out
         | "offset" -> () (* keeper_fs_read does not support offsets *)
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

let translate_edit_input input =
  match input with
  | `Assoc fields ->
    let has_content = List.exists (fun (k, _) -> k = "content") fields in
    let mode = if has_content then "overwrite" else "patch" in
    let out = ref [ "mode", `String mode ] in
    List.iter
      (fun (k, v) ->
         match k with
         | "file_path" -> out := ("path", v) :: !out
         | "old_string" | "new_string" | "replace_all" | "content" ->
           out := (k, v) :: !out
         | "mode" -> () (* ignore caller-supplied overrides *)
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

let translate_write_input input =
  match input with
  | `Assoc fields ->
    let out = ref [ "mode", `String "overwrite" ] in
    List.iter
      (fun (k, v) ->
         match k with
         | "file_path" -> out := ("path", v) :: !out
         | "content" -> out := ("content", v) :: !out
         | "mode" -> () (* always overwrite via Write alias *)
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

let translate_grep_input input =
  match input with
  | `Assoc fields ->
    let out = ref [ "op", `String "rg" ] in
    let is_case_insensitive =
      match List.assoc_opt "-i" fields with
      | Some (`Bool true) -> true
      | _ -> false
    in
    List.iter
      (fun (k, v) ->
         match k with
         | "pattern" ->
           let v' =
             if is_case_insensitive
             then (
               match v with
               | `String s -> `String ("(?i)" ^ s)
               | _ -> v)
             else v
           in
           out := (k, v') :: !out
         | "path" | "glob" | "type" -> out := (k, v) :: !out
         | "op" -> () (* always rg via Grep alias *)
         | "-i" | "-n" -> () (* shim accepted, not routed *)
         | _ -> out := (k, v) :: !out)
      fields;
    `Assoc (List.rev !out)
  | _ -> input
;;

(** [translate_input ~public input] reshapes an LLM call payload from
    the public schema (Anthropic Code field names) to the internal
    keeper tool's expected payload.

    For unknown public names this is the identity. *)
let translate_input ~public input =
  match public with
  | "Bash" -> translate_bash_input input
  | "Edit" -> translate_edit_input input
  | "Grep" -> translate_grep_input input
  | "Read" -> translate_read_input input
  | "WebFetch" -> input
  | "WebSearch" -> input
  | "Write" -> translate_write_input input
  | _ -> input
;;

(* ── Deferred registration (schemas + translators into routing table) ── *)

(* The routing table is created with [Fun.id] translators and [None] schemas
   because the per-tool helpers above are not yet in scope at table creation
   time. This [register] call patches in the real values. *)

let () =
  List.iter
    (fun (pub, schema, translator) ->
       match Hashtbl.find_opt routing_table pub with
       | Some r ->
         Hashtbl.replace
           routing_table
           pub
           { r with translate = translator; public_schema = Some schema }
       | None -> ())
    [ "Bash", bash_public_schema, translate_bash_input
    ; "Edit", edit_public_schema, translate_edit_input
    ; "Grep", grep_public_schema, translate_grep_input
    ; "Read", read_public_schema, translate_read_input
    ; ("WebFetch", web_fetch_public_schema, fun x -> x)
    ; ("WebSearch", web_search_public_schema, fun x -> x)
    ; "Write", write_public_schema, translate_write_input
    ]
;;
