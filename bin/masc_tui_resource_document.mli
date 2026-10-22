(** The exact current Resources document. This projection reads state without
    changing retained bytes, request ownership, selection or scroll. *)
type t
val current : Masc_tui_types.state -> t option
(** [None] when no inventory entry owns the pending/error/content key. *)
val entry : t -> Masc_tui_resource_catalog.t
val text_part_count : Masc_tui_types.state -> int
(** Text parts of the current admitted reading, in original response order.
    Pending reads, refusals and withdrawn inventory have no selectable parts. *)
val copy_source : Masc_tui_types.state -> ((string * string), string) result
(** Label and exact original bytes of the selected text part. Requires a ready
    workspace and focused Resources detail; never concatenates parts, decodes
    blobs, follows URIs or sanitizes payload bytes. The caller owns clipboard
    delivery; success does not establish terminal acknowledgement. *)
val rows : cols:int -> t -> string list
(** [cols] is the actual document pane width, after Activity and optional
    Resources split. Both drawing and search use this projection.
    Each source part's CRLF is parsed before fencing, joining, Markdown and
    terminal sanitization;
    original parts and copy bytes are unchanged. Standalone CR stays escaped. *)
val search_rows : cols:int -> Masc_tui_types.state -> string list option
(** Search only the currently displayed admitted content. Metadata-only,
    loading another key, failures and withdrawn inventory return [None].
    Terminal styling is removed from copies; source contents stay immutable. *)
