(** Keeper_tool_alias — flat routing table for two-surface tool naming.

    RFC-0064: replaces the 3-tier classification with a single [route]
    type. Each LLM-native tool name maps to one route record containing
    the internal handler name, an input translator, and an optional
    public schema.

    Two surfaces:
    - LLM native tools (Bash, Read, Edit, Write, Grep, WebSearch, WebFetch)
    - MCP tools (masc_*, handled via Tool_catalog_surfaces)

    Internal [keeper_*] names are implementation details of the routing
    layer, not a public surface. A tool call for a name not in the routing
    table is a routing miss — outcome-based telemetry captures this.

    @since 2.187.0 — RFC-0064 two-surface model *)

(** {1 Route type} *)

type route =
  { internal_name : string
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; public_schema : Yojson.Safe.t option
  }

(** [route public_name] returns routing info for a known LLM-native tool.
    [None] means the name is not in our surface — a routing miss. *)
val route : string -> route option

(** [route_or_miss name] is like [route] but records result-based telemetry:
    - [ok] with [routed_to = internal_name] when the name resolves
    - [miss] with [routed_to = "none"] when the name is unknown *)
val route_or_miss : string -> route option

(** [is_known_public name] is [true] when [name] has a routing entry.
    Replaces the old [canonicalize_observed] check for known names. *)
val is_known_public : string -> bool

(** [public_names ()] returns all LLM-native public names in stable order.
    Replaces [expand_universe] — callers should add these names directly
    to allowlists at construction time. *)
val public_names : unit -> string list

(** {1 Result-based telemetry} *)

(** [record_route_outcome ~tool ~routed_to ~result] increments the
    [masc_keeper_tool_call_total] counter with the given labels.
    [result] is ["ok"] for a successful route or ["miss"] for an unknown name. *)
val record_route_outcome : tool:string -> routed_to:string -> result:string -> unit

(** {1 MCP surface routing (separate concern)} *)

(** [public_masc_to_internal name] resolves an MCP-prefixed public name
    (e.g. [masc_board_get]) to its internal keeper name, via the
    [Tool_catalog_surfaces.keeper_internal_replacement] table. *)
val public_masc_to_internal : string -> string option

(** [strip_mcp_masc_prefix name] removes the ["mcp__masc__"] prefix if
    present. *)
val strip_mcp_masc_prefix : string -> string

(** {1 Public schemas} *)

(** [public_input_schema public_name] returns the LLM-facing JSON schema
    for a known public tool name. [None] means no tailored schema exists —
    callers should fall back to the internal tool's schema. *)
val public_input_schema : string -> Yojson.Safe.t option

(** {1 Input translation} *)

(** [translate_input ~public input] reshapes an LLM call payload from
    the public schema (Anthropic Code field names) to the internal
    keeper tool's expected payload.

    For unknown public names this is the identity. *)
val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t
