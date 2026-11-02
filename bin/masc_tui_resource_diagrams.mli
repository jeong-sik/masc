(** Immutable preparation of the diagrams in one retained resource response.
    The UI owns snapshots; workers receive a request and return PNG bytes. *)
type request
type claim
type image = private { png : string; key : string; width : int; height : int }
type t
type frame = {
  frame_mime_type : string option;
  frame_contents : Masc_tui_mcp.resource_content list;
  frame_width : int;
  frame_cell_pixels : int * int;
  frame_colors : (string * string) option;
}
type admission = Admit | Retire | Ignore
val create : mime_type:string option -> contents:Masc_tui_mcp.resource_content list ->
  width:int -> cell_pixels:(int * int) -> colors:(string * string) option -> t
val request : t -> request
val sources : request -> string list
val width : request -> int
val colors : request -> (string * string) option
val matches : mime_type:string option -> contents:Masc_tui_mcp.resource_content list ->
  width:int -> cell_pixels:(int * int) -> colors:(string * string) option -> t -> bool
val matches_frame : frame -> t -> bool
val admission : request -> frame:frame option -> t option -> admission
(** Check the current owner and all frame inputs before starting a physical
    renderer. A replaced owner is untouched. *)
val claim_next : t -> (string * claim * t) option
(** Claim one unfinished source. Only one source may be preparing per request. *)
val abandon : request -> source:string -> claim -> t -> t
(** Return only this exact unfinished claim to the pending state. *)
val abandon_preparing : t -> t
(** Return the current unstarted claim to pending without losing completed sources. *)
val owns_claim : request -> source:string -> claim -> t -> bool
val settle : request -> source:string -> (string, string) result -> t -> t
(** Another request cannot change this snapshot. Bytes must be an actual PNG
    with positive dimensions; a failed render stays explicit until reread. *)
val settle_claimed : request -> source:string -> claim -> (string, string) result -> t -> t
(** A completion from an earlier claim cannot settle a later retry. *)
val image : source:string -> t -> image option
val image_for_display : source:string -> t -> image option
(** Resolve a sanitized document fence through the same CRLF and terminal-text
    projection used by resource reading. The worker still receives original bytes. *)
val failure : source:string -> t -> string option
val failures : t -> string list
val progress : t -> int * int
(** Completed and total distinct sources, including explicit failures. *)
val cell_pixels : t -> int * int
val owns : Masc_tui_mcp.resource_content list -> t -> bool
