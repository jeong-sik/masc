(** Db_op — typed classification of a SQL command string handed to a database
    CLI ([psql -c], [mysql -e], ...).  Mirrors {!Git_op}: syntactic only (it
    never connects to or executes against a database), and the leading verb of
    each statement decides the tier.

    [Destructive] verbs are the trust-independent catastrophic-floor members for
    database mutations — the typed replacement for the legacy
    [config/destructive_ops.toml] [sql_destructive] substring patterns
    (RFC eliminate-substring-destructive-classifier §3-A, §6). The classifier is
    intentionally MORE complete than the substring catalogue: it floors every
    [DROP]/[TRUNCATE]/[DELETE] statement, not only the [drop table]/[drop
    database]/[truncate table]/[delete from] string forms the catalogue listed.

    {2 Known limitation}

    Classification is by the leading keyword of each [;]-separated statement.
    A destructive operation nested inside a leading non-destructive statement —
    e.g. a CTE [WITH t AS (...) DELETE FROM ...] — is NOT detected (the leading
    verb is [WITH]). The substring catalogue's flat match would have caught it.
    This is an accepted narrowing: it is an uncommon keeper shape, and the
    principled fix (a full SQL statement parser) is out of scope here. Recorded
    in the RFC §8 tradeoffs. *)

type read_verb =
  [ `Select | `Show | `Explain | `With | `Values | `Table ]

type mutating_verb =
  [ `Insert | `Update | `Create | `Alter | `Grant | `Revoke | `Comment
  | `Set | `Begin | `Commit | `Rollback | `Copy | `Vacuum | `Analyze
  | `Other ]

type destructive_verb =
  [ `Drop | `Truncate | `Delete ]

type t =
  | Read of read_verb
  | Mutating of mutating_verb
  | Destructive of destructive_verb

val of_command : string -> (t, [ `Empty | `Unknown_verb of string ]) result
(** [of_command sql] classifies [sql] by the leading keyword of its statements,
    case-insensitively, after skipping leading whitespace and [--]/[/* */]
    comments. If any [;]-separated statement leads with a destructive verb the
    result is [Destructive] (the strictest statement wins). [`Empty] for blank
    input; [`Unknown_verb v] when the first statement's leading token is not a
    recognized SQL keyword. Syntactic only. *)

val is_destructive : t -> bool
(** [true] iff the classification is [Destructive _]. *)

val pp : Format.formatter -> t -> unit
