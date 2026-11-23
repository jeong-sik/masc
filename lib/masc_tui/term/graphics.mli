(** Pure terminal graphics protocol encoder for Kitty APC and iTerm2 OSC 1337.

    The Kitty graphics protocol carries image bytes to the terminal inside APC
    escapes ([ESC _ G ... ESC \\]) and asks it to place them at the cursor.
    Terminals that implement it (Ghostty, Kitty, WezTerm) draw the picture;
    terminals that do not ignore the escapes entirely, which is why the
    capability is queried rather than assumed.

    Pure byte-producing module: every function returns bytes for the caller to
    write or parses bytes the caller collected. Zero terminal or filesystem
    I/O. *)

type placement = {
  columns : int;
  rows : int;
      (** The cell box an iTerm2 placement fits inside (with
          [preserveAspectRatio=1]). Kitty placements take [rows] alone when
          preserving aspect ratio, or both [cols] and [rows] when cropping. *)
}

val fit_rows :
  cell_pixels:(int * int) option ->
  image_pixels:(int * int) option ->
  columns:int ->
  rows:int ->
  int
(** Aspect-preserving rows that fit both terminal dimensions. Without measured
    pixel geometry, retains [max 1 rows] rather than inventing cell shape. *)

(** Distinct Kitty image slots owned by this process. *)
type image =
  | Graphics_query  (** {!query}'s one-pixel probe, received but never drawn *)
  | Msx_screen  (** MSX spectator screen *)
  | Mascot  (** MASC candle on [/about] *)
  | Keeper_portrait  (** Keeper portrait at the head of its detail *)
  | About_keeper_1
  | About_keeper_2
  | About_keeper_3
  | About_keeper_4
  | Evidence_image_1
  | Evidence_image_2
  | Evidence_image_3
  | Evidence_image_4
  | Image_inspection  (** Full-screen zoom/pan image inspector *)
  | Memory_diagram  (** Memory transition SVG / formation graph diagram *)

val all_of_image : image list
(** Exhaustive list of every {!image} slot constructor. *)

val image_id : image -> int
(** Unique Kitty [i=] identifier per {!image} slot, so placing or deleting one
    surface never clobbers another. *)

val resource_image_id : int -> int
(** Zero-based document occurrence in the resource image ID namespace
    ([0x10000 + index]), disjoint from every {!image} slot. *)

val evidence_images : image list
(** The four ordered {!image} slots reserved for operator verification evidence. *)

val query : string
(** Minimal 1x1 PNG Kitty capability query ([a=q,f=100]) under
    {!Graphics_query}'s image ID ([i=31]). *)

type query_reply =
  | Supported
  | Refused of string
      (** Terminal speaks the protocol and explicitly declined the query. *)

val equal_query_reply : query_reply -> query_reply -> bool

val parse_query_reply : string -> query_reply option
(** Parse one Kitty APC reply body (between [ESC _ G] and [ESC \\]). Returns
    [None] when the body is not an answer to {!query}. *)

val payload_media_type : string
(** Canonical media type expected by {!place} and {!replace_png}: ["image/png"]
    ([f=100]). *)

val replace_rgb :
  image_id:int ->
  placement_id:int ->
  data:string ->
  pixel_width:int ->
  pixel_height:int ->
  rows:int ->
  string
(** Transmit raw 24-bit RGB pixels ([f=24]) under a stable image/placement ID,
    chunked at 4096 base64 bytes with [q=2]. Returns [""] when [data] is empty
    or its length disagrees with [pixel_width * pixel_height * 3]. *)

val replace_rgba :
  image_id:int ->
  placement_id:int ->
  data:string ->
  pixel_width:int ->
  pixel_height:int ->
  rows:int ->
  string
(** Transmit straight-alpha 32-bit RGBA pixels encoded losslessly as PNG
    ([f=100], without Kitty transport compression [o=z]) under a stable
    image/placement ID. Returns [""] when [data] is empty or its length
    disagrees with [pixel_width * pixel_height * 4]. *)

val put : image_id:int -> placement_id:int -> rows:int -> string
(** Place pixels already retained by the terminal under [image_id] ([a=p])
    without re-transmitting bytes. *)

(** Vertical source-pixel slice for scrolled full-width PNG placements. *)
type crop = {
  top_px : int;
  height_px : int;
}

val replace_png :
  image_id:int ->
  placement_id:int ->
  data:string ->
  rows:int ->
  cols:int ->
  crop:crop option ->
  string
(** Transmit PNG bytes ([f=100]) under a stable image/placement ID over [cols]
    by [rows] cells with optional vertical source-pixel [crop]. Returns [""]
    when [data] is empty. *)

val put_png :
  image_id:int ->
  placement_id:int ->
  rows:int ->
  cols:int ->
  crop:crop option ->
  string
(** Re-place or re-crop already transmitted PNG pixels without re-sending bytes. *)

(** Explicit 2D source-pixel crop and cell target for zoom/pan inspection. *)
type viewport_window = {
  x : int;
  y : int;
  width : int;
  height : int;
  columns : int;
  rows : int;
}

val place_viewport :
  ?image_id:int -> ?placement_id:int -> data:string -> viewport_window -> string
(** Transmit PNG bytes with explicit [x/y/w/h] source-pixel crop and [c/r] cell
    geometry (defaults to {!Image_inspection}, placement [1]). *)

val put_viewport :
  ?image_id:int -> ?placement_id:int -> viewport_window -> string
(** Re-crop an already transmitted viewport image without re-sending bytes. *)

val place : data:string -> rows:int -> string
(** Chunked, silent ([q=2]) PNG transmit-and-display at the cursor ([f=100,a=T]).
    Returns [""] when [data] is empty. *)

val place_slot :
  image:image -> placement_id:int -> data:string -> rows:int -> string
(** Chunked, silent ([q=2]), cursor-preserving ([C=1]) aspect-preserving PNG
    transmit-and-display bound to a dedicated {!image} slot ID ([i=...]) so
    {!delete_image} cleanly removes the placement without ghost pixels. Returns
    [""] when [data] is empty. *)

val delete_placement : image_id:int -> placement_id:int -> string
(** Delete one placement while retaining the stored image pixels ([d=i]). *)

val delete_image : image_id:int -> string
(** Delete all placements of [image_id] and free its stored pixels ([d=I]). *)

val delete_all : string
(** Delete every Kitty image placed by this process ([a=d]). *)

type graphics_protocol =
  | Kitty_protocol
  | ITerm2_protocol
  | Unsupported_protocol

val equal_graphics_protocol : graphics_protocol -> graphics_protocol -> bool

val protocol_of_probe :
  graphics:Probe.graphics_reply option ->
  term_program:string option ->
  graphics_protocol
(** Derive the active graphics transport from observed startup {!Probe} output
    and [TERM_PROGRAM] fallback. Explicit Kitty refusal falls back cleanly. *)

val iterm2_place : data:string -> placement -> string
(** Inline image placement using iTerm2 OSC 1337 with [preserveAspectRatio=1].
    Returns [""] when [data] is empty. *)

val tmux_wrapped : string -> string
(** Wrap terminal escape bytes in a tmux DCS passthrough envelope, doubling
    every internal [ESC] byte. *)

type image_region = {
  top : int;
  left : int;
  width_cells : float;
  height_cells : float;
}

val image_point :
  image_region -> row:int -> column:int -> (float * float) option
(** Map the center of a reported terminal cell to a normalized [(0..1, 0..1)]
    image coordinate, returning [None] outside the measured image region. *)
