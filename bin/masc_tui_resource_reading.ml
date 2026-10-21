type t = {
  entry : Masc_tui_resource_catalog.t;
  contents : Masc_tui_mcp.resource_content list option;
  error : string option;
  requested : bool;
  image_cursor : int;
  text_cursor : int;
  revisions : Masc_tui_resource_catalog.report list;
  presentation : Masc_tui_resource_catalog.presentation;
  metadata_expanded : bool;
  confirmation : Masc_tui_artifact_checks.status option;
}
let create ~entry ~contents ~error ~requested ~image_cursor ~text_cursor
    ~revisions ~presentation ~metadata_expanded ~confirmation =
  {entry;contents;error;requested;image_cursor;text_cursor;revisions;presentation;
   metadata_expanded;confirmation}
let searchable reading = match reading.contents, reading.error with
  | Some _, None -> true
  | (Some _ | None), (Some _ | None) -> false

type search_position =
  | Cursor of int
  | Landed of { index : int; cols : int; query : string; reading : t }
let first = Cursor 0
let cursor = function Cursor index | Landed {index;_} -> index
let record_landing ~cols ~query ~index reading = Landed {index;cols;query;reading}
let same_reading a b =
  a.entry=b.entry && Option.equal (==) a.contents b.contents
  && a.error=b.error && a.requested=b.requested
  && a.image_cursor=b.image_cursor && a.text_cursor=b.text_cursor
  && a.revisions=b.revisions && a.presentation=b.presentation
  && a.metadata_expanded=b.metadata_expanded && a.confirmation=b.confirmation
let landing ~cols ~query reading = function
  | Landed original when original.cols=cols && original.query=query
      && query<>"" && same_reading original.reading reading -> Some original.index
  | Cursor _ | Landed _ -> None
