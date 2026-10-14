(** The lane token: the secret the browser host sends and the server compares,
    kept in [<base-path>/.masc/browser-lane/token]. The host, the server and
    the installer all read it through {!of_text}, so a token one of them
    would refuse is refused by every one of them. *)

type t

type refusal =
  | Too_short  (** Fewer than {!minimum_length} characters after trimming. *)
  | Not_printable
      (** A character other than a visible ASCII one (codes 33 to 126), such
          as a space inside the token, a control character or a non-ASCII
          one. *)

val minimum_length : int

val of_text : string -> (t, refusal) result
(** The token a file's text holds: the text without the whitespace around it,
    when what is left is at least {!minimum_length} visible ASCII characters. *)

val to_string : t -> string
val equal : t -> t -> bool

val refusal_message : refusal -> string
(** One clause naming what is wrong with the text, without the text. *)
