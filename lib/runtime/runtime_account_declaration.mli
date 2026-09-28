(** Declaring one more sign-in of an official client runtime.toml already
    declares.

    A second Codex, Claude Code or Antigravity account is one more provider
    shaped like an existing one: the same protocol, command and binding
    tables, and a different login store. This module copies that provider
    from a chosen base and appends the copy to the file's text. Lines already
    in the text are not touched, so comments and layout stay as they were.
    Nothing here reads or writes a file, and nothing signs in. *)

type t
(** A runtime.toml text together with its parsed tables. *)

type client =
  | Claude_code
  | Codex
  | Antigravity

type base =
  { id : string
  ; display_name : string
      (** The name the loader shows: [display-name], else [provider-name],
          else the id. *)
  ; client : client
  }

type declared =
  { text : string  (** The whole text with the new provider appended. *)
  ; location : string  (** The login store written, after [~/] expansion. *)
  }

type error =
  | Unparsable of string  (** The text is not TOML. *)
  | Unknown_base of string  (** No official-client provider has this id. *)
  | Nothing_to_bind of string
      (** The base binds no model, so the copy could not run a turn. *)
  | Id_taken of string
      (** A provider or a top-level table already uses this name, or the
          name is one {!Runtime_toml.reserved_provider_ids} keeps for
          another reader. *)
  | Invalid_location of string
  | Location_taken of
      { location : string
      ; provider : string
      }
      (** Another provider of the same client already signs in there,
          spelled the same or differently. *)
  | Unsupported_layout of string
      (** The file is written so that an appended provider would not read
          back as declared. The editor is the way to add it. *)
  | Rejected of Runtime_toml.parse_error list
      (** The loader refuses the text with the new provider in it. *)

val error_message : error -> string

val parse : string -> (t, error) result

val bases : t -> base list
(** The official-client providers, in file order. HTTP providers are left
    out: they are endpoints with keys, not signed-in clients. Muse is also left
    out because this account-copy form does not support its sign-in flow. *)

val suggest_id : t -> base -> string
(** [<base>_<n>] for the smallest [n] from 2 up that no provider or
    top-level table uses. The base itself is the first account. *)

val location_label : client -> string
(** What [declare]'s [location] means for this client, in the words the
    runtime.toml key uses. *)

val expand_home : ?home_dir:string -> string -> string
(** A leading [~/] against [home_dir], the expansion {!declare} applies to
    [location]. Anything else, or no [home_dir], is returned as it is. *)

val declare :
  ?home_dir:string ->
  inherited_home:(client -> string option) ->
  t -> base:base -> id:string -> location:string ->
  (declared, error) result
(** The text with provider [id] appended: the base's provider table with a new
    [display-name] and login store, and a copy of every binding table the base
    declares. Copied values keep their exact value. [location] is the login
    store:

    - Claude Code and Codex: [account-home], the directory given as
      [CLAUDE_CONFIG_DIR] or [CODEX_HOME] at sign-in.
    - Antigravity: the OAuth file [masc runtime-antigravity-account] reports,
      written as [credentials] of type [file].

    A leading [~/] is expanded against [home_dir] when it is given.
    [inherited_home] is the home a Claude Code or Codex provider without
    [account-home] runs on; a location equal to it is refused like any other
    login already in use, since the copy would share that login and its
    quota. Two locations are one login when they reach one directory on this
    machine: the parts that exist are resolved by the filesystem ([..],
    links, the letter case of a case-insensitive disk), and a part that does
    not exist yet is compared as written. A part the filesystem refuses to
    read is [Invalid_location]. The written location is kept as it is. The
    result reads back with the login store in place and has passed
    {!Runtime_toml.parse_string}. The server's own preview still decides
    whether it can be saved. *)
