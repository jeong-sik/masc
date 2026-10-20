(** Resources from two authorities. Report reads always use the existing
    token-bound admin HTTP API, never the MCP resource permission. *)
type report = private { id : string; revision : Masc.Published_artifact.revision }
type key = Mcp_uri of string | Report_revision of report
type t = Mcp of Masc_tui_mcp.resource | Report of report
type listing = { entries : t list; notes : string list }

val key : t -> key
val equal_key : key -> key -> bool
val metadata : t -> Masc_tui_mcp.resource
val display_name : t -> string
val origin : t -> string
val report_path : report -> string
val reports_of_json : Yojson.Safe.t -> (t list * string list, string) result
val report_contents : report -> Yojson.Safe.t ->
  (Masc_tui_mcp.resource_content list, string) result
val combine :
  (Masc_tui_mcp.resource list * Masc_tui_mcp.resources_walk_stop, string) result ->
  (t list * string list, string) result -> (listing, string) result
