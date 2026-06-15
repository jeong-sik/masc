(** Keeper_tool_alias — flat routing table for two-surface tool naming.

    RFC-0064: replaces the 3-tier classification with a single [route]
    type. Each LLM-native tool name maps to one route record containing
    the internal handler name, an input translator, and an optional
    public schema.

    Two descriptor-backed surfaces:
    - LLM native-style tools (Execute, Grep/Search, Read, Edit, Write,
      WebSearch, WebFetch)
    - MCP tools (names with the masc_ prefix)

    Internal [keeper_*] names are implementation details of the routing
    layer, not a public surface. A tool call for a name not in the routing
    table is a routing miss — outcome-based telemetry captures this.

    @since 2.187.0 — RFC-0064 two-surface model *)

(** {1 Route type} *)

type route =
  { internal_name : string
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; public_schema : Yojson.Safe.t option
  ; descriptor : Keeper_tool_descriptor.t
  }

(** [route public_name] returns routing info for a known LLM-native tool.
    [None] means the name is not in our surface — a routing miss. *)
val route : string -> route option

(** [is_known_internal name] is [true] when [name] is a recognised LLM-native
    descriptor internal handler name. Policy resolution uses this narrow source;
    runtime telemetry has a wider private descriptor-backed label set. *)
val is_known_internal : string -> bool

(** [public_names ()] returns all LLM-native public names in stable order.
    Replaces [expand_universe] — callers should add these names directly
    to allowlists at construction time. *)
val public_names : unit -> string list

(** [public_name_for_internal internal_name] returns the preferred
    LLM-native public name for an internal routed tool, when one exists.
    The result follows [public_names] order, so ambiguous internals such
    as [tool_edit_file] pick a stable primary public surface. *)
val public_name_for_internal : string -> string option

(** {1 Result-based telemetry} *)

(** [record_route_outcome ~tool ~routed_to ~result] increments the
    [masc_keeper_tool_call_total] counter with the given labels.

    Cardinality is bounded: [tool] / [routed_to] are normalised to
    ["unknown"] when the supplied value is neither a known public name
    nor a known internal handler. Raw unrecognised strings never become
    new label values, so hallucinated tool names cannot inflate the
    Otel_metric_store time series.

    [result] is ["ok"] for a successful route or ["miss"] for an unknown name. *)
val record_route_outcome : tool:string -> routed_to:string -> result:string -> unit

(** {1 MCP prefix normalisation} *)

(** [strip_mcp_masc_prefix name] removes the ["mcp__masc__"] prefix if
    present. *)
val strip_mcp_masc_prefix : string -> string

(** Pure canonical routing result for set-logic and routing callers that need
    the same alias interpretation without emitting telemetry. *)
type canonical_resolution =
  | Public_alias of { internal : string }
  | Internal of { canonical : string }
  | Unknown

(** [canonical_resolution name] applies MCP-prefix stripping, descriptor-backed
    public alias routing, and known-internal detection. *)
val canonical_resolution : string -> canonical_resolution

(** [canonical_internal_name name] returns the internal keeper/MASC tool name
    used for pure set-logic comparisons after applying the same descriptor
    public alias and MCP-prefix routing rules used by runtime dispatch. [None]
    means the name is not a recognised public or internal tool. *)
val canonical_internal_name : string -> string option

(** {1 Public schemas} *)

(** [public_input_schema public_name] returns the LLM-facing JSON schema
    for a known public tool name. [None] means no tailored schema exists —
    callers should fall back to the internal tool's schema. *)
val public_input_schema : string -> Yojson.Safe.t option

(** {1 Input translation} *)

(** [translate_input ~public input] reshapes an LLM call payload from
    the descriptor-owned public schema field names to the internal
    keeper tool's expected payload.

    For unknown public names this is the identity. *)
val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t
