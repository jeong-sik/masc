type client = Codex | Claude | Antigravity
val name : client -> string
val source_url : client -> string
val install : run:(string list -> (unit, string) result) -> client -> (unit, string) result
(** Execute only after explicit selection. Downloads the documented vendor script
    over HTTPS into a private temporary directory, runs it as the current user,
    then checks the installed executable's version. This is not account/model
    verification or an independently pinned binary publisher attestation. The
    injected terminal runner must preserve interactive input and route stdout
    away from any machine-readable receipt. *)
