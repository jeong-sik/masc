(** The declaration a person's Keeper is created with (RFC
    a-persons-keeper-runs-on-the-engine, S2 / stack A3-2).

    A person's Keeper is a record of the authorization log plus one
    [keepers/<engine_name>.toml] file: the log names the owner, the engine
    name and the Runtime, and the declaration is what the engine reads when it
    starts the Keeper. The multi-account boot refuses a definition the log does
    not name ({!Server_accounts.no_keeper_definition}), so the two are written
    in that order: the log first, the declaration second.

    {b What this module decides, and what it does not.} It renders the bytes of
    that declaration and writes them when a caller asks
    ({!commit}). Who asks, in which order the log and the declaration are
    written, and how a Keeper whose declaration is missing is repaired belong to
    the caller. Keeping the shape here means the values are reviewed once, and a
    test can hand the rendered bytes to the real loader
    ({!Keeper_types_profile_toml.inspect_keeper_toml_content}) instead of
    trusting a hand-copied fixture.

    {b The values.}
    - [activation_mode = "on_demand"]: the person's Keeper runs when the person
      writes to it. It does not start by itself: the autonomous mode is a later
      step of the RFC (§3.5, S3), and a Keeper that starts on its own before
      that step exists would start turns nobody asked for.
    - [tools.masc_enabled = false]: a person's Keeper runs without tools
      (RFC §2, "사람의 Keeper 는 도구 없이 돈다"). The value is written out
      rather than left to a default, because it is the guarantee A3-1 made
      enforceable and a reader of the file should see it.
    - [sandbox_profile], [sandbox_image], [network_mode]: the shipped default
      declaration of a fresh install ([config/keepers-default/imp.toml]) uses
      the same three. The RFC does not read what a tool-less Keeper needs here
      (§4, "sandbox"), so this follows the shipped default rather than
      inventing a value. Changing it changes where a person's Keeper runs, and
      that is a decision, not a detail. *)

(** The instructions of a person's Keeper.

    Fixed text: the declaration is written before anything of the person's
    first conversation exists, so there is nothing to interpolate. A turn reads
    it as the Keeper's own instructions, not as the system prompt of the
    client. *)
val instructions : string

(** The complete declaration, ready to be validated and written at
    [keepers/<engine_name>.toml].

    The bytes name no [keeper.name]: the loader derives the name from the file
    name and refuses a key that disagrees with it. *)
val content : unit -> string

(** {b Writing it.} The Keeper is created by a request that knows only its
    [base_path], not a [Workspace.config]: the multi-account server builds no
    workspace state. This is therefore a second, narrow entry point beside
    [Keeper_turn_up_config_persistence.commit_declaration] rather than a
    caller that dresses a [base_path] up as a [Workspace.config].

    {b Order and repair.} The authorization log is written first and this
    declaration second, because a boot refuses a definition the log does not
    name ([Server_accounts.no_keeper_definition]) and a log record without a
    declaration only means the Keeper does not run. A retry of the same request
    must therefore converge: identical bytes already on disk are
    {!Already_present}, not an error and not a rewrite. *)

(** What a write did. *)
type outcome =
  | Created
  (** Nothing was there and the declaration was written. *)
  | Already_present
  (** The same bytes were already on disk; nothing was written. This is the
      answer a retry of a creation request gets, so two calls with the same
      input return the same outcome. *)
  | Replaced
  (** Different bytes were on disk and [~replace:true] asked for them to go. *)

(** Why a write did not happen. *)
type error =
  | Name_not_a_file_component of string
  (** The engine name is not a single path component, so it could name a file
      outside the [keepers] directory. *)
  | Path_unreadable of { path : string; reason : string }
  | Path_escapes_base_path of { path : string; base_path : string }
  (** The resolved path is not under [base_path]: a symlinked [keepers]
      directory, for instance. *)
  | Declaration_refused of { path : string; reason : string }
  (** The bytes are not a declaration the engine would load, or they name
      another Keeper. Nothing is written: a file the loader refuses would stop
      the next boot. *)
  | Read_failed of { path : string; reason : string }
  (** The declaration that is there now could not be read, so whether this is a
      retry or a different declaration is unknown. *)
  | Different_declaration_present of { path : string; sha256 : string }
  (** A different declaration is already there and [~replace] was not given.
      Overwriting a Keeper's instructions is a decision, not a retry. *)
  | Write_failed of { path : string; reason : string }
  | Read_back_mismatch of
      { path : string; expected_sha256 : string; observed_sha256 : string }
  (** The write returned but the bytes on disk are not the bytes asked for. *)

(** The path a declaration of [engine_name] is written to:
    [base_path/keepers/<engine_name>.toml]. *)
val path_for : base_path:string -> engine_name:string -> (string, error) result

(** Write the declaration of [engine_name].

    The content is validated with the loader the engine uses before anything is
    written, then committed through
    [Keeper_turn_up_config_persistence.commit_declaration_at_base_path]: the
    same manifest-then-Runtime locks, the same before-image journal and the
    same atomic replacement a Keeper configuration write already has, and the
    bytes are read back afterwards.

    The revision is read first and handed to the commit as its expected
    revision, so a write that lost a race with another writer is refused rather
    than merged. *)
val commit :
  base_path:string ->
  engine_name:string ->
  content:string ->
  replace:bool ->
  (outcome, error) result

(** One line for a log or an answer body. *)
val error_message : error -> string
