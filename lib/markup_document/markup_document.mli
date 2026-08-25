(** Standards-parsed HTML/XML document tree shared by web surfaces. *)

type t =
  | Text of string
  | Element of {
      namespace : string;
      name : string;
      attributes : (string * string) list;
      children : t list;
    }

val parse_html : string -> t list
(** Parse an HTML5 document or fragment with Markup.ml error recovery. *)

val text_content : t -> string
val attribute : string -> t -> string option
val elements_named : string -> t list -> t list
val first_element_named : string -> t list -> t option
val html_space_tokens : string -> string list
(** Split an HTML token-list attribute on the five ASCII whitespace bytes. *)
