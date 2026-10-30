(** Removing an official-client account runtime.toml declares, together with
    what routes to it.

    An account is one provider {!Runtime_account_declaration.bases} lists: a
    Claude Code, Codex or Antigravity sign-in. Removing it deletes the
    provider's table and its binding tables, and takes its runtimes out of
    everything that routes to them:

    - [runtime.lanes.<id>] candidates and [runtime.exact_output_lanes.<id>]
      slots and cli slots;
    - [runtime].media_failover;
    - [runtime.assignments]: a keeper assigned one of its runtimes loses the
      assignment and routes to the default.

    Nothing is removed when [runtime].default is one of its runtimes, or when a
    lane would be left with no candidate or an exact-output lane with no slot:
    each has no replacement this module could choose.

    The text is edited line by line, so comments and every other table stay as
    they were. A table or key the line editor cannot reach -- a lane written as
    an inline table, a provider declared with dotted keys -- is refused rather
    than guessed at: the result is parsed again, and it must differ from the
    original only by what {!removed.changes} lists. Nothing here reads or
    writes a file, and the login store the account signed in at stays on
    disk. *)

type change =
  | Table of string  (** A table removed, by the path its header names. *)
  | Lane_candidate of
      { lane : string
      ; runtime : string
      }
  | Exact_lane_slot of
      { lane : string
      ; runtime : string
      }  (** From [slots] or [cli_slots]. *)
  | Vision_runtime of string  (** Left [runtime].media_failover. *)
  | Assignment of
      { keeper : string
      ; runtime : string
      }  (** The keeper now routes to the default. *)

type removed =
  { text : string  (** The whole text without the account. *)
  ; changes : change list  (** In file order within each kind. *)
  ; login_store : string option
      (** [account-home], or the Antigravity OAuth file, as the loader reads
          it. [None] for a Claude Code or Codex provider on the home it
          inherits. *)
  }

type error =
  | Unparsable of string
  | Unknown_account of string  (** No official-client provider has this id. *)
  | Default_runtime of string  (** [runtime].default is this runtime. *)
  | Lane_emptied of string  (** This lane routes only to the account. *)
  | Exact_lane_emptied of string
  | Unsupported_layout of string
      (** The account or something routing to it is written where the line
          editor cannot remove it. The editor is the way to remove it. *)
  | Rejected of Runtime_toml.parse_error list
      (** The loader refuses the text without the account. *)

val error_message : error -> string

val remove : string -> id:string -> (removed, error) result
(** [remove text ~id] removes account [id] from [text]. *)
