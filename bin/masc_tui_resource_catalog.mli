(** Resources from two authorities. Report reads always use the existing
    token-bound admin HTTP API, never the MCP resource permission. *)
type report = private { id : string; revision : Masc.Published_artifact.revision }
type key = Mcp_uri of string | Report_revision of report
type t = Mcp of Masc_tui_mcp.resource | Report of report
type listing = { entries : t list; notes : string list }
type reading =
  { parts : Masc_tui_mcp.resource_content list
  ; revisions : report list
  }
type scope = All_resources | Published_reports | Markdown_reports | Html_reports
type layout = Full_width | Side_by_side
type presentation = Document | Source
type day = { year : int; month : int; day : int }
val local_day : float -> day
val on_day : day -> t -> bool
val select : scope:scope -> day:day option -> t list -> t list
(** Preserve source order and typed identities. Date filtering includes only
    reports whose publication instant falls on the selected local day. *)
val scope_label : scope -> string
val next_scope : scope -> scope

type direction = Older | Newer
type read_request = { key : key; owner : unit ref }

val key : t -> key
val equal_key : key -> key -> bool
val owns_key : t -> key -> bool
(** Whether this inventory entry owns a read. A listed report owns its fixed
    revisions; an MCP resource owns only its exact URI. *)
val entry_for_key : t list -> key -> t option
val adjacent_revision : direction -> current:report -> report list -> report option
val mcp_reading : Masc_tui_mcp.resource_content list -> reading
val metadata : t -> Masc_tui_mcp.resource
val display_name : t -> string
val origin : t -> string
val report_path : report -> string
val reports_of_json : Yojson.Safe.t -> (t list * string list, string) result
val report_contents : report -> Yojson.Safe.t ->
  (reading, string) result
val combine :
  (Masc_tui_mcp.resource list * Masc_tui_mcp.resources_walk_stop, string) result ->
  (t list * string list, string) result -> (listing, string) result
