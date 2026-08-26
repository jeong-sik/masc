(* A file's type mark for the Code tree, by extension. See the .ml for why the
   kind is a closed set and the glyph is plain unicode. *)

type kind =
  | Code
  | Data
  | Prose
  | Script
  | Web
  | Media
  | Plain

(* The kind for a file name, read from its lowercased extension. A name with no
   extension, or a leading-dot dotfile with nothing after it, is [Plain]. *)
val kind_of_name : string -> kind

(* A one-column plain-unicode glyph for a kind (no Nerd Font private-use
   codepoints, so any monospace terminal draws it). *)
val glyph : kind -> string
