(** Bilingual UI copy with compile-time language separation.

    Screens and widgets hold [Say.t] values and resolve them with the active
    [lang] at render time, preventing English/Korean string leaks across modes. *)

type lang =
  | Lang_ko
  | Lang_en

type t = {
  ko : string;
  en : string;
}

val make : ko:string -> en:string -> t
val literal : string -> t
val resolve : lang -> t -> string
val map : (string -> string) -> t -> t
val concat : sep:string -> t list -> t

val lang_code : lang -> string
val lang_of_code : string -> lang option
(** Strict parser: returns [None] for any unknown language code. *)

val equal_lang : lang -> lang -> bool
val equal : t -> t -> bool
