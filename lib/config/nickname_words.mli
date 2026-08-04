(** Shared adjective/animal word lists for MASC agent nicknames — the single
    source of truth for both the generator ([Nickname]) and the auth-side
    classifier ([Auth_nickname]). Keeping one copy prevents the two paths from
    drifting. *)

val adjectives : string array
val animals : string array

val array_contains : string array -> string -> bool
(** [array_contains arr value] scans [arr] left to right and returns [true] at
    the first element that is [String.equal] to [value], [false] when no
    element matches. *)

val is_hex4 : string -> bool
(** [is_hex4 value] returns [true] when [value] has length 4 and every
    character is ['0'..'9'] or ['a'..'f']. That is the shape of the suffix
    [Nickname.generate_unique] appends. Uppercase hex returns [false]. *)
