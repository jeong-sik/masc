(** Decode [gh auth status --json hosts] into a per-host credential verdict.

    This is an observation of a product CLI, deliberately outside exec, Gate,
    and policy (RFC-0369 §3; INV-KEEPER-008). It decodes a string: it spawns
    nothing, reads no environment, and never carries a token value.

    Two things are deliberately NOT done here.

    The exit code is not an input. With [--json] gh always exits 0 "regardless
    of any authentication issues" (its own [--help]); without [--json] a host
    whose keyring account is fine but whose active token comes from the
    environment exits 1, exactly like a host with no credential at all. Neither
    code separates "unset a variable" from "log in".

    The [error] text is not classified. gh reports the cause of a failed row in
    prose that has no contract — a 401 body, a DNS failure, a TLS error all
    arrive as one string. It is carried verbatim to the operator instead of
    being pattern-matched into a category this module would then be wrong
    about. The row's [state] is the only failure signal read. *)

type source_kind =
  | Environment_variable of string
      (** gh resolved the token from this variable. The name is kept because it
          is what an operator has to unset. *)
  | Stored_credential
      (** The system keyring, or a config file gh named by absolute path. *)
  | No_token_found
      (** gh's [default] source: it looked and found nothing for this host. *)

type row =
  { host : string
  ; state : string  (** Verbatim. gh's own vocabulary, e.g. [success], [error], [timeout]. *)
  ; active : bool  (** Whether gh would use this row for this host. *)
  ; login : string option  (** Absent on a row that never authenticated. *)
  ; token_source_label : string  (** Verbatim, recognised or not. *)
  ; source : source_kind option
      (** [None] when [token_source_label] is one this module does not
          recognise. A label gh adds later must not be assumed to be a stored
          credential: if it names a variable, that assumption hides a shadow.
          So it is not interpreted, and the host's verdict declines. *)
  ; scopes : string list option
      (** [None] when gh emitted no scopes field, which is not the same as a
          token with no scopes — a fine-grained PAT legitimately has none. *)
  ; error : string option  (** gh's failure prose, verbatim, never parsed. *)
  }

type verdict =
  | Authenticated
  | Unauthenticated
  | Shadowed
      (** This host carries both an environment-sourced row and a stored one.
          gh resolves the environment first, so [gh auth login] and
          [gh auth refresh] silently no-op; the operator's action is to unset
          the variable. Decided by the presence of the environment row within
          the host, not by [active] and not by whether either credential is
          valid — a perfectly healthy environment token over a healthy keyring
          is still a shadow. *)
  | Unknown
      (** Undecidable: an unrecognised [token_source_label], no row marked
          active, or more than one. Never a stand-in for the other three. *)

type host_status =
  { host : string
  ; verdict : verdict
  ; rows : row list
  }

type t =
  { hosts : host_status list  (** One entry per key of gh's [hosts] object. *)
  ; undecodable : string option
      (** [Some detail] when the payload was not the expected shape, in which
          case [hosts] is empty. Distinct from "gh knows no hosts", which is a
          well-formed empty object. *)
  }

val decode : string -> t
(** Total over any input. Takes gh's stdout only — the human sentence gh prints
    when no host is logged in goes to stderr, and mixing the two produces a
    payload this function reports as undecodable. *)

val verdict_to_string : verdict -> string
