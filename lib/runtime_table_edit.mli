(** What the commands that write one table of runtime.toml with the line
    editor ([masc browser-lane-setup --mode bidi], [--mode ego]) share.

    The loader reads what strict TOML forbids: a header for a table that dotted
    keys or an inline table already declared loads as one table, and a strict
    reader (a script reading runtime.toml with Python's tomllib) refuses the
    file. A line editor adds a header or edits the keys under one, so it is
    only sound where the table has its own header or is not there at all, and
    nothing above it is inline. *)

type unreachable =
  | Inline_ancestor of string list
      (** A table above the one being written is spelled inline, so no header
          can be added under it. *)
  | Declared_another_way of string list
      (** The table is there, written inline or with dotted keys, which a line
          editor does not reach. *)

val unreachable_message : table_path:string list -> unreachable -> string

(** [check_editable ~table_path ~ancestors ~declared text]: [declared] is
    whether the table is there at all. A table that is there needs its own
    standard header; every table in [ancestors] must not be inline. *)
val check_editable
  :  table_path:string list
  -> ancestors:string list list
  -> declared:bool
  -> string
  -> (unit, unreachable) result

type 'e commit_error =
  | Changed_meanwhile
      (** runtime.toml is not the revision the plan was made from. Nothing was
          written. *)
  | Edit_refused of 'e
  | Not_written of string
  | Outcome_unknown of string
      (** The edit was sent to the workspace's running server, and whether it
          landed could not be told: the answer was lost and the text could
          not be read again, or changed since. *)

type observe_error =
  | Missing of string  (** No runtime.toml at this path. *)
  | Unreadable of { path : string; reason : string }

(** Where a table edit reads runtime.toml and commits it: the file itself
    ({!file_store}), or the workspace's running server, which is the one
    writer of the file while it runs (RFC-0482 §3.2). *)
type store =
  { path : string  (** The file the store reads and writes, for messages. *)
  ; observe : unit -> (Runtime.config_observation, observe_error) result
  ; commit :
      'e. revision:string -> edit:(string -> (string, 'e) result) -> (unit, 'e commit_error) result
        (** Commits [edit] of the text as it is at that moment. The revision
            the plan was made from is compared first, so a write that landed
            since is not overwritten. *)
  }

val file_store : runtime_config_path:string -> store
(** The file itself: [commit] edits it under the configuration write lock,
    through {!Runtime.edit_config_text}. *)

val revision_of_observation : Runtime.config_observation -> string
