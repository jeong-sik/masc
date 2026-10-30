(** Shared adjective/animal word lists for MASC agent nicknames — the single
    source of truth for both the generator ([Nickname]) and the auth-side
    classifier ([Auth_nickname]). Keeping one copy prevents the two paths from
    drifting. *)

val adjectives : string array
val animals : string array
