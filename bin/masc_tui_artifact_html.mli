(** Inert, standards-parsed HTML reading. No scripts, CSS, navigation, URL
    resolution, file reads or image decoding. Original source stays caller-owned. *)
type image_source =
  | Embedded_base64 of Masc_tui_image_payload.t
  | Embedded_svg of string
  | Unavailable of string
type image = { label : string; source : image_source }
type cell = { text : string; heading : bool }
type block =
  | Paragraph of string
  | Heading of int * string
  | Preformatted of string
  | List_item of int * string
  | List_continuation of int * string
  | Table of cell list list
  | Image of image
type t = private { blocks : block list; images : image list }
val project : string -> t
(** Body reading order, with HTML whitespace/entity handling. Active/metadata
    subtrees and explicit hidden nodes are omitted. CSS layout is not evaluated.
    Declared base64 image data URIs and serialized inline SVG roots become
    image sources. SVG acquisition retains the offline renderer's validation;
    this projection does not sanitize or render SVG. *)
val images : t -> image list
