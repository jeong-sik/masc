(** Keeper_tool_alias — flat routing table for two-surface tool naming.

    RFC-0064: replaces the 3-tier classification (aliases / oas_dual_register
    / hallucinated_builtins) with a single [route] type. Each LLM-native tool
    name maps to one route record containing the internal handler name, an
    input translator, and an optional public schema.

    Two surfaces:
    - LLM native tools: Execute, Grep, Read, Edit, Write, WebSearch, WebFetch
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
  ; descriptor : Agent_tool_descriptor.t
  }

let routing_table : (string, route) Hashtbl.t =
  let t = Hashtbl.create 8 in
  List.iter
    (fun (d : Agent_tool_descriptor.t) ->
       Hashtbl.replace
         t
         d.public_name
         { internal_name = d.internal_name
         ; translate = d.translate
         ; public_schema = Some d.input_schema
         ; descriptor = d
         })
    Agent_tool_descriptor.public_descriptors;
  t
;;

(* ── Result-based telemetry ──────────────────────────────────────── *)

(** [is_known_public name] is [true] when [name] has a routing entry. *)
let is_known_public name = Hashtbl.mem routing_table name

(** Known internal handler names — the [internal_name] values that
    [routing_table] entries map onto, plus the [masc_*] surface that
    [public_masc_to_internal] resolves. Used to bound the [routed_to]
    Prometheus label so that unrecognised strings never become a new
    time series. *)
let known_internal_names_tbl : (string, unit) Hashtbl.t =
  let t = Hashtbl.create 128 in
  Hashtbl.iter
    (fun _ r ->
       List.iter
         (fun internal_name ->
            Hashtbl.replace t internal_name ();
            (* Also admit the public MCP counterpart (e.g. [masc_board_post])
               so successful MCP routes do not collapse to [tool="unknown"]
               (PR #14585 review).  Sourced from the descriptor SSOT after the
               keeper-internal catalog list was severed (#19797). *)
            match Agent_tool_descriptor.public_name_for_internal internal_name with
            | Some public -> Hashtbl.replace t public ()
            | None -> ())
         (Agent_tool_descriptor.internal_names r.descriptor))
    routing_table;
  List.iter
    (fun public_mcp -> Hashtbl.replace t public_mcp ())
    Tool_catalog_surfaces.public_mcp_surface_tools;
  t
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
    Keeper_metrics.(to_string ToolCallTotal)
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

(** [public_names ()] returns all LLM-native public names in stable order.
    Used by callers that previously used [expand_universe] to add alias names
    to allowlists — they should now add these names directly. *)
let public_names = Agent_tool_descriptor.public_names

let public_name_for_internal = Agent_tool_descriptor.public_name_for_internal

(* ── MCP surface routing (separate concern) ──────────────────────── *)

let public_masc_to_internal_tbl =
  (* Reverse (public MCP name -> internal name) map, rebuilt from the
     descriptor SSOT after the keeper-internal catalog list + replacement
     table were severed (#19797).  Each descriptor's internal names map to
     their canonical public name when one exists. *)
  let t = Hashtbl.create 16 in
  Hashtbl.iter
    (fun _ r ->
       List.iter
         (fun internal ->
            match Agent_tool_descriptor.public_name_for_internal internal with
            | Some public -> Hashtbl.replace t public internal
            | None -> ())
         (Agent_tool_descriptor.internal_names r.descriptor))
    routing_table;
  t
;;

let public_masc_to_internal name = Hashtbl.find_opt public_masc_to_internal_tbl name

let strip_mcp_masc_prefix name =
  if String.starts_with ~prefix:"mcp__masc__" name
  then String.sub name 11 (String.length name - 11)
  else name
;;

type canonical_resolution =
  | Public_mcp of
      { stripped : string
      ; internal : string
      }
  | Public_alias of { internal : string }
  | Internal of { canonical : string }
  | Unknown

let canonical_resolution name =
  let stripped = strip_mcp_masc_prefix name in
  match public_masc_to_internal stripped with
  | Some internal -> Public_mcp { stripped; internal }
  | None ->
    (match route stripped with
     | Some r -> Public_alias { internal = r.internal_name }
     | None ->
       if is_known_internal stripped then Internal { canonical = stripped } else Unknown)
;;

let canonical_internal_name name =
  match canonical_resolution name with
  | Public_mcp { internal; _ } | Public_alias { internal } -> Some internal
  | Internal { canonical } -> Some canonical
  | Unknown -> None
;;

(** [public_input_schema public_name] returns the LLM-facing JSON schema
    for a known public tool name. [None] means no tailored schema exists. *)
let public_input_schema = function
  | public -> Agent_tool_descriptor.public_input_schema public
;;

(** [translate_input ~public input] reshapes an LLM call payload from
    the descriptor-owned public schema field names to the internal
    keeper tool's expected payload.

    For unknown public names this is the identity. *)
let translate_input ~public input =
  Agent_tool_descriptor.translate_input ~public input
;;
