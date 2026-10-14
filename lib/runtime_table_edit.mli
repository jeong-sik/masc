(** What the commands that write one table of runtime.toml with the line
    editor ([masc browser-lane-setup --mode bidi], [--mode automation]) share.

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

(** Commits the edit under the configuration write lock. The text [edit] is
    given is the one on disk at that moment: the revision the plan was made
    from is compared again first, so a write that landed since is not
    overwritten. *)
val commit
  :  runtime_config_path:string
  -> revision:string
  -> edit:(string -> (string, 'e) result)
  -> (unit, 'e commit_error) result

val revision_of_observation : Runtime.config_observation -> string
