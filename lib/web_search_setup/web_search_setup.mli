(** Web_search_setup — write the [\[web_search\]] section of runtime.toml.

    Every change goes through {!Runtime.edit_config_text}, so the read, the edit
    and the commit happen inside one config write lock, and through
    {!Toml_line_editor}, so comments and unrelated tables survive byte-for-byte.
    Built the way {!Voice_setup} is, for the same reason: a writer that
    regenerated the section would delete the notes an operator keeps above a
    setting they measured.

    One thing a changed line loses is its own trailing comment: the line editor
    replaces a string, integer or float line whole and keeps a trailing comment
    only for a boolean. Comments on other lines and above the section stay.

    Writes no secret. A provider's API key is read from the environment of the
    process that starts the server
    ({!Web_search_provider.credential_env_names}); runtime.toml is committed, so
    it has no key for one. What this module writes is where to search and in
    what order. *)

type key =
  | Searxng_url
  | Provider
  | Provider_order
  | Fallbacks
  | Timeout_sec
  | Cache_ttl_sec
[@@deriving enumerate]
(* [all_of_key] is generated, so a key added here is in it. *)

val key_name : key -> string
(** The key as runtime.toml spells it inside [\[web_search\]]. The registry
    ({!Keeper_runtime_setting_registry}) owns the names; a test holds this
    list to it. *)

val toml_key : key -> string
(** The dotted key the registry names the setting by, [web_search.provider]
    for {!Provider}. *)

type providers = Web_search_provider.t * Web_search_provider.t list
(** A provider list that is never empty: the first element and the rest. An
    empty [provider_order] is read as "not configured" and falls back to the
    default order, which is the opposite of what writing one asks for, so the
    type has no such value. Repeats are dropped, keeping the first. *)

type change =
  | Set_searxng_url of string
      (** An http or https URL with a host and no userinfo credentials, refused
          as {!Section_invalid} otherwise. The loader does not look at the
          scheme, and the reader refuses any other on every search, so a typo
          written here would be a provider that reads as configured and fails
          each call. *)
  | Set_provider of Web_search_provider.t
      (** The provider tried first. The others follow. *)
  | Set_provider_order of providers
      (** The whole order. When set, the chain is exactly this list. A provider
          named here without a credential fails on every call, except SearXNG,
          which falls back to its default address: the default order filters by
          credential, a configured one does not
          ({!Web_search_provider.needs_credential_to_call}). *)
  | Set_fallbacks of providers
  | Set_timeout_sec of int
  | Set_cache_ttl_sec of float
  | Unset of key
      (** Remove the key, so the reader's default applies again. *)

val change_key : change -> key
(** The key a change sets or removes. *)

val display_searxng_url : string -> string
(** [display_searxng_url url] returns [url] with any authority userinfo
    ([user:password@] or [user@]) replaced by [[REDACTED]@], so printing a
    hand-edited [runtime.toml] or a refusal message never echoes embedded
    credentials (#43143). *)

type settings =
  { searxng_url : string option
  ; provider : string option
  ; provider_order : string option
  ; fallbacks : string option
  ; timeout_sec : int option
  ; cache_ttl_sec : float option
  }
(** What runtime.toml's [\[web_search\]] table holds now. Strings are as
    written: an alias, or a label this binary does not know, is shown and not
    normalized. A key written with the wrong type reads as absent here and
    appears in the [problems] of {!observation}. *)

type observation =
  { revision : string
        (** Hand back as [expected_revision] to {!apply}. *)
  ; settings : settings
  ; problems : string list
        (** One sentence per [web_search.*] key the loader already refuses in
            the file as it is, with the key and what it wanted. Empty when the
            section loads. *)
  }

type error =
  | Configuration_unavailable of string
      (** runtime.toml could not be read, or is not valid TOML. *)
  | Configuration_changed
      (** Someone else wrote runtime.toml between {!observe} and {!apply}.
          Nothing was written. Re-observe and decide again. *)
  | Conflicting_changes of key
      (** Two changes address one key, so which one is meant is not decided
          here. Nothing was written. *)
  | Section_invalid of string
      (** The text after the change does not parse, or its [web_search.*] keys
          do not load. The message is the loader's sentence. Not written. A key
          that was already wrong in the file is reported here too, on any
          change, because the commit would leave it wrong.

          Nothing reads these keys until the server starts, so a section that
          does not load stays quiet until the next restart refuses it. A writer
          that committed text it had not read back would reproduce that. *)
  | Table_not_reachable
      (** [web_search] is written as an inline table or as dotted keys at the
          top of the file. A line editor would open a [\[web_search\]] header
          beside it, which TOML 1.0 forbids. Not written. *)
  | Not_read_back of key
      (** The edit was made and the loader still does not read the requested
          value at this key: the line editor and the loader disagree about
          where it is. Not written. *)
  | Configuration_rejected of string
      (** The commit was refused. The whole file is validated on every commit,
          so an unrelated section that is already broken refuses a web-search
          edit too; the message says which. *)

val error_message : error -> string

val observe : runtime_config_path:string -> (observation, error) result
(** The current runtime.toml revision and the [\[web_search\]] settings, from
    one read so a caller cannot join a revision to a different observation. *)

val apply
  :  runtime_config_path:string
  -> expected_revision:string
  -> change list
  -> (string, error) result
(** Apply every change in order, in one commit under the config write lock.
    [Ok] carries the revision this commit produced, taken from the commit
    itself.

    All of them or none, and at most one change per {!key}. Each value is read
    back through the loader before anything is written. *)
