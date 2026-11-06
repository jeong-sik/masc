(** Email text as an official client wrote it. One value serves both the
    account email a setup surface shows and the account an Antigravity login
    names ({!Runtime_antigravity_oauth_credential}), so the two cannot read
    the same bytes differently. *)

type t = private string

val max_bytes : int
(** 254, the longest forward path RFC 5321 section 4.5.3.1.3 admits. *)

val of_string : string -> t option
(** Valid UTF-8 of 1 to [max_bytes] bytes with no ASCII space or control
    byte. Anything else is not email text. The bytes are kept as written: no
    trimming and no case folding. *)

val to_string : t -> string
