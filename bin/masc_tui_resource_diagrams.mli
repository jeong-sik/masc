(** Immutable preparation of the diagrams in one retained resource response.
    The UI owns snapshots; workers receive a request and return PNG bytes. *)
type request
type image = private { png : string; key : string; width : int; height : int }
type t
val create : mime_type:string option -> contents:Masc_tui_mcp.resource_content list ->
  width:int -> cell_pixels:(int * int) -> colors:(string * string) option -> t
val request : t -> request
val sources : request -> string list
val width : request -> int
val colors : request -> (string * string) option
val matches : mime_type:string option -> contents:Masc_tui_mcp.resource_content list ->
  width:int -> cell_pixels:(int * int) -> colors:(string * string) option -> t -> bool
val settle : request -> source:string -> (string, string) result -> t -> t
(** Another request cannot change this snapshot. Bytes must be an actual PNG
    with positive dimensions; a failed render stays explicit until reread. *)
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
