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
  shared : bool option;
  share_uncertain : bool;
  recovery_preview : string option;
  public_url : (string, string) result option;
  diagrams : Masc_tui_resource_diagrams.t option;
}
let create ~entry ~contents ~error ~requested ~image_cursor ~text_cursor
    ~revisions ~presentation ~metadata_expanded ~confirmation ~shared ~share_uncertain ~recovery_preview ~public_url ~diagrams =
  {entry;contents;error;requested;image_cursor;text_cursor;revisions;presentation;
   metadata_expanded;confirmation;shared;share_uncertain;recovery_preview;public_url;diagrams}
let searchable reading = match reading.contents, reading.error with
  | Some _, None -> true
  | (Some _ | None), (Some _ | None) -> false

type search_position =
  | Cursor of int
  | Landed of { index : int; cols : int; query : string; reading : t }
let first = Cursor 0
let cursor = function Cursor index | Landed {index;_} -> index
let record_landing ~cols ~query ~index reading = Landed {index;cols;query;reading}
(* Name and compare every field: future display inputs must also invalidate
   search landings and prepared document layouts. *)
let[@warning "+9+27"] same_reading
    { entry; contents; error; requested; image_cursor; text_cursor; revisions;
      presentation; metadata_expanded; confirmation; shared; share_uncertain;
      recovery_preview; public_url; diagrams } b =
  entry=b.entry && Option.equal (==) contents b.contents
  && error=b.error && requested=b.requested
  && image_cursor=b.image_cursor && text_cursor=b.text_cursor
  && revisions=b.revisions && presentation=b.presentation
  && metadata_expanded=b.metadata_expanded && confirmation=b.confirmation
  && shared=b.shared && share_uncertain=b.share_uncertain
  && recovery_preview=b.recovery_preview && public_url=b.public_url
  && Option.equal (==) diagrams b.diagrams

let landing ~cols ~query reading = function
  | Landed original when original.cols=cols && original.query=query
      && query<>"" && same_reading original.reading reading -> Some original.index
  | Cursor _ | Landed _ -> None
