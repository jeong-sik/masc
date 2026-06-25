(** Db_op — typed classification of a SQL command string handed to a database
    CLI ([psql -c], [mysql -e], ...).  Mirrors {!Git_op}: syntactic only (it
    never connects to or executes against a database), and SQL tokens outside
    comments/string literals decide the tier.

    [Destructive] verbs are the trust-independent catastrophic-floor members for
    database mutations — the typed replacement for the legacy
    [config/destructive_ops.toml] [sql_destructive] substring patterns
    (RFC eliminate-substring-destructive-classifier §3-A, §6). The classifier is
    intentionally MORE complete than the substring catalogue: it floors
    destructive [DROP <object>], [TRUNCATE], [DELETE], and [COPY ... PROGRAM]
    token phrases even when they appear after a leading [WITH], not only the
    [drop table]/[drop database]/[truncate table]/[delete from] string forms the
    catalogue listed. Quoted strings, quoted identifiers, and SQL comments are
    skipped so ordinary read queries containing those words as text are not
    floored. *)

type read_verb =
  [ `Select | `Show | `Explain | `With | `Values | `Table ]

type mutating_verb =
  [ `Insert | `Update | `Create | `Alter | `Grant | `Revoke | `Comment
  | `Set | `Begin | `Commit | `Rollback | `Copy | `Vacuum | `Analyze
  | `Other ]

type destructive_verb =
  [ `Drop | `Truncate | `Delete | `Copy_program ]

type t =
  | Read of read_verb
  | Mutating of mutating_verb
  | Destructive of destructive_verb

val of_command : string -> (t, [ `Empty | `Unknown_verb of string ]) result
(** [of_command sql] classifies [sql] case-insensitively, after skipping SQL
    comments and quoted literals/identifiers for destructive phrase detection.
    If any [;]-separated statement contains a destructive token phrase the
    result is [Destructive] (the strictest statement wins). Otherwise the
    leading keyword decides the read/mutating tier. [`Empty] for blank input;
    [`Unknown_verb v] when the first statement's leading token is not a
    recognized SQL keyword. Syntactic only. *)

val is_destructive : t -> bool
(** [true] iff the classification is [Destructive _]. *)

val pp : Format.formatter -> t -> unit
