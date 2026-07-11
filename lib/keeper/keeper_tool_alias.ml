(** Keeper_tool_alias — flat routing table for two-surface tool naming.

    RFC-0064: replaces the 3-tier classification (aliases / oas_dual_register
    / hallucinated_builtins) with a single [route] type. Each LLM-native tool
    name maps to one route record containing the internal handler name, an
    input translator, and an optional public schema.

    Two descriptor-backed surfaces:
    - LLM native-style tools: Execute, Grep/Search, Read, Edit, Write,
      WebSearch, WebFetch
    - MCP tools: names with the masc_ prefix

    Internal [keeper_*] names are implementation details of the routing layer,
    not a public surface. A tool call for a name we don't handle is a routing
    miss — captured by result-based telemetry, not by upfront classification.

    @since 2.187.0 — RFC-0064 two-surface model *)

(* ── Route type ──────────────────────────────────────────────────── *)

type route =
  { internal_name : string
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; public_schema : Yojson.Safe.t option
  ; descriptor : Keeper_tool_descriptor.t
  }

let routing_table : (string, route) Hashtbl.t =
  let t = Hashtbl.create 8 in
  List.iter
    (fun (d : Keeper_tool_descriptor.t) ->
       List.iter
         (fun public_name ->
            Hashtbl.replace
              t
              public_name
              { internal_name = d.internal_name
              ; translate = d.translate
              ; public_schema = Some d.input_schema
              ; descriptor = d
              })
         (Keeper_tool_descriptor.public_names_of_descriptor d))
    Keeper_tool_descriptor.public_descriptors;
  t
;;

(* ── Result-based telemetry ──────────────────────────────────────── *)

(** [is_known_public name] is [true] when [name] has a routing entry. *)
let is_known_public name = Hashtbl.mem routing_table name

let is_masc_mcp_descriptor = Keeper_tool_descriptor.is_masc_internal_route

let add_internal_names t (d : Keeper_tool_descriptor.t) =
  List.iter
    (fun internal_name -> Hashtbl.replace t internal_name ())
    (Keeper_tool_descriptor.internal_names d)
;;

(** Known internal handler names for LLM-native public descriptors. *)
let known_internal_names_tbl : (string, unit) Hashtbl.t =
  let t = Hashtbl.create 128 in
  List.iter (add_internal_names t) Keeper_tool_descriptor.public_descriptors;
  t
;;

(** Descriptor-backed runtime names used for telemetry labels and runtime
    canonicalisation. Kept separate from [is_known_internal] so policy
    resolution provenance still reaches [Descriptor_registry] for workspace
    descriptors. *)
let known_runtime_names_tbl : (string, unit) Hashtbl.t =
  let t = Hashtbl.create 128 in
  List.iter (add_internal_names t) Keeper_tool_descriptor.public_descriptors;
  List.iter
    (fun d -> if is_masc_mcp_descriptor d then add_internal_names t d)
    (Keeper_tool_descriptor.all_descriptors ());
  List.iter
    (fun public_mcp -> Hashtbl.replace t public_mcp ())
    Keeper_tool_name.public_mcp_non_descriptor_names;
  t
;;

let is_known_internal name = Hashtbl.mem known_internal_names_tbl name

let is_known_runtime_name name = Hashtbl.mem known_runtime_names_tbl name

(** Bound a label value to a closed set so hallucinated / unbounded
    names never inflate Otel_metric_store cardinality. *)
let safe_tool_label name =
  if is_known_public name
  then name
  else if is_known_runtime_name name
  then name
  else "unknown"
;;

let safe_routed_to_label name =
  if name = "none" then name else if is_known_runtime_name name then name else "unknown"
;;

let record_route_outcome ~tool ~routed_to ~result =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ToolCallTotal)
    ~labels:
      [ "tool", safe_tool_label tool
      ; "routed_to", safe_routed_to_label routed_to
      ; "result", result
      ; "tool_type", Tool_telemetry.tool_type_of_name tool
      ]
    ();
  (* Instruction monitoring: track per-tool invocation completeness.
     result="ok" means parameters were accepted by the runtime surface;
     other results (miss/error) indicate the call did not complete normally. *)
  Otel_metric_store.inc_counter
    (Keeper_metrics.to_string ToolCallParamCompleteness)
    ~labels:
      [ ("tool", safe_tool_label tool)
      ; ("status", if String.equal result "ok" then "complete" else "incomplete")
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

(** [public_names ()] returns all LLM-native public names in stable order.
    Used by callers that previously used [expand_universe] to add alias names
    to allowlists — they should now add these names directly. *)
let public_names = Keeper_tool_descriptor.public_names

let public_name_for_internal = Keeper_tool_descriptor.public_name_for_internal

(* ── MCP prefix normalisation ────────────────────────────────────── *)

let strip_mcp_masc_prefix name =
  if String.starts_with ~prefix:"mcp__masc__" name
  then String.sub name 11 (String.length name - 11)
  else name
;;

type canonical_resolution =
  | Public_alias of { internal : string }
  | Internal of { canonical : string }
  | Unknown

let canonical_resolution name =
  let stripped = strip_mcp_masc_prefix name in
  match route stripped with
  | Some r -> Public_alias { internal = r.internal_name }
  | None ->
    if is_known_runtime_name stripped then Internal { canonical = stripped } else Unknown
;;

let canonical_internal_name name =
  match canonical_resolution name with
  | Public_alias { internal } -> Some internal
  | Internal { canonical } -> Some canonical
  | Unknown -> None
;;

(** [public_input_schema public_name] returns the LLM-facing JSON schema
    for a known public tool name. [None] means no tailored schema exists. *)
let public_input_schema = function
  | public -> Keeper_tool_descriptor.public_input_schema public
;;

(** [translate_input ~public input] reshapes an LLM call payload from
    the descriptor-owned public schema field names to the internal
    keeper tool's expected payload.

    For unknown public names this is the identity. *)
let translate_input ~public input =
  Keeper_tool_descriptor.translate_input ~public input
;;
