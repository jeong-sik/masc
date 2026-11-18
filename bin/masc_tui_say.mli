(** Screen text that holds both languages (RFC tui-one-screen-grammar section
    7.1, layer 9).

    Every word the app writes on a screen is a value of this type. A screen
    moved to it hands its rows over as [t], so a literal written in one
    language does not compile there: it has no way in but {!both},
    {!per_language} or {!as_received}. The language is chosen once, where the
    frame draws the row ({!render}).

    Depends on nothing, so every renderer can use it. *)

type language =
  | Ko
  | En  (** The two languages a screen is drawn in. *)

type t
(** Text for the screen, in both languages. *)

val both : ko:string -> en:string -> t
(** Text the app wrote, in each language. *)

val per_language : (language -> string) -> t
(** Text the app wrote around a value, such as a count: the function matches
    on {!language}, and a missing branch stops the build (warning 8 is an
    error in this repository). *)

val as_received : string -> t
(** Text shown as it was received, the same in both languages: a Keeper's
    name, text a person wrote, a model ID, a path, a configuration key, a
    number a value module formatted. Never a literal: a literal is words the
    app wrote, and those go through {!both}. *)

val code : string -> t
(** A literal that reads the same in both languages because it holds no
    words: a field label in an evidence row ([bytes=], [sha256=]), a protocol
    name the reader compares with logs, a glyph, a separator. A word, or a
    wire state a reader is meant to read as one ([queued]), goes through
    {!both}. *)

val of_ko_flag : (ko:bool -> string) -> t
(** The text a function that still takes [~ko:bool] writes in each language.
    A bridge to the functions not moved yet; the last layer of section 7.1
    removes it with the flag. *)

val map : (string -> string) -> t -> t
(** The same change made to the text in each language: fitting it to a
    width, cutting it, padding it. *)

val empty : t
(** No text. *)

val ( ++ ) : t -> t -> t
(** The two texts one after the other, in the same language. *)

val concat : sep:t -> t list -> t
(** The texts in order with [sep] between them. *)

val render : language -> t -> string
(** The text in one language. Only the frame that draws a row calls this. *)
