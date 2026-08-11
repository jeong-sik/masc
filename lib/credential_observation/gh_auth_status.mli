(** Parse [gh auth status] output into a typed credential verdict.

    This module is an observation of a product CLI, deliberately outside exec,
    Gate, and policy (RFC-0369 §3; INV-KEEPER-008). It reads text only: it
    spawns nothing, reads no environment, and never carries a token value.

    The exit code is not an input. Measured against gh 2.87.3, it cannot
    separate the cases this module exists to separate: a host whose keyring
    account is fine but whose active token comes from the environment exits 1,
    exactly like a host with no credential at all. The verdict comes from the
    per-entry source labels instead. *)

type token_source =
  | Keyring  (** gh printed [(keyring)]. *)
  | Environment of string
      (** gh printed the environment variable it read, e.g. [(GH_TOKEN)] or
          [(GITHUB_TOKEN)]. The name is kept because it is what an operator has
          to unset. *)
  | Config_default  (** gh printed [(default)] — the on-disk config entry. *)

type outcome =
  | Logged_in  (** gh marked the entry [✓]. *)
  | Login_failed  (** gh marked the entry [X]. *)

type entry =
  { outcome : outcome
  ; host : string
  ; account : string option
      (** [None] for an environment token, which gh reports as
          "using token" with no account. *)
  ; source_label : string
      (** The label gh printed, verbatim, recognised or not. *)
  ; source : token_source option
      (** The interpretation of [source_label], or [None] when this parser does
          not recognise it. A label gh adds later must not be assumed to be a
          stored credential: if it names a variable, treating it as stored
          would hide a shadow. So an unrecognised label is not interpreted at
          all, and the verdict declines rather than guessing. *)
  ; active : bool option  (** [None] when gh printed no "Active account" line. *)
  ; scopes : string list option
      (** [None] when gh printed no scopes line, which is not the same as a
          token with an empty scope set. *)
  }

type verdict =
  | Authenticated  (** At least one entry is logged in and none shadows it. *)
  | Unauthenticated  (** Parsed, and no entry is logged in. *)
  | Shadowed
      (** The host carries both an environment-sourced entry and a
          non-environment one. gh resolves the environment token first, so
          [gh auth login] and [gh auth refresh] silently no-op and the
          operator's next action is to unset the variable, not to log in.

          Decided by the presence of the environment row, not by gh's "Active
          account" line and not by whether either credential is still valid.
          All three measured shapes agree — an invalid variable over a valid
          keyring, an invalid variable over an invalid config entry, and a
          perfectly valid variable over a valid keyring are all shadowed. *)
  | Unknown
      (** The output matched neither the "not logged into any host" sentence
          nor any entry line, or an entry carries a source label this parser
          does not recognise. Never a stand-in for an authenticated or
          unauthenticated verdict: an unreadable credential surface is
          reported as unreadable. *)

type t =
  { entries : entry list
  ; verdict : verdict
  }

val parse : string -> t
(** Total over any input. Unrecognised text yields [{ entries = []; verdict =
    Unknown }] rather than a default. *)

val verdict_to_string : verdict -> string
