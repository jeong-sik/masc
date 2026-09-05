(** Assemble a [masc keeper-create] invocation into the declaration
    [POST /api/v1/keepers/<name>/up] carries, and read what came back.

    Pure on both ends. The command itself is the transport, the credential and
    the exit code; none of those is here, so the flag surface can be asserted
    without a server. *)

type booleans =
  { autoboot : bool option
  ; proactive : bool option
  }
(** Tri-state, one field per boolean flag pair. [None] leaves the key out of
    the declaration, which is what keeps a create from writing a decision the
    operator never named:
    [Keeper_turn_up_config_persistence.full_fields] writes whatever the meta
    holds, so a two-valued flag would settle [autoboot_enabled] by default. *)

type flags =
  { name : string
  ; instructions : string
  ; sandbox_profile : string
  ; network_mode : string option
  ; remote_endpoint : string option
  ; mention_targets : string list
  ; skills : string list option
  ; max_context_override : int option
  ; booleans : booleans
  }
(** One invocation's flags, before any of them is judged.

    [name], [instructions] and [sandbox_profile] are plain strings because
    cmdliner cannot mark a flag required on a term that also accepts [--edit];
    the emptiness of each is decided in {!declaration_of_flags} instead.

    [skills] separates the two selections a repeatable flag cannot: [None] is
    [--skill] never passed, which leaves the keeper's selection unchanged, and
    [Some []] is [--no-skills], which selects none. *)

val network_mode_behaviours : (string * string) list
(** Each network mode's spelling and what a keeper in it can reach, one
    sentence per mode in the typed owner's order, for the refusal messages
    and the manpage. Built from
    {!Keeper_types_profile_sandbox.all_network_modes} by a match exhaustive on
    the variant, so a mode the owner gains has no sentence until one is
    written, and the compiler says so. *)

val declaration_of_flags : flags -> (Yojson.Safe.t, string) result
(** The [keeper_up] declaration these flags describe, or the one sentence the
    operator has to act on.

    Refuses a missing [network_mode]. On a create that field decides whether
    the guest reaches the network at all and the server's default is [none],
    so an omission here is how a keeper whose work is web search is made
    unable to do it. The spelling is not judged: a value this command does not
    recognise is the parser's rejection to give, and a second copy of the
    mapping is how the tool descriptor and
    [Masc.Keeper_turn_up_args.known_turn_up_args] drifted apart. The same
    holds for [sandbox_profile], which is refused only when it is blank.

    Every key it emits is in [Masc.Keeper_turn_up_args.known_turn_up_args]. A
    key outside that set is rejected by the server as an unknown argument, so
    the two are asserted against each other in the test suite rather than kept
    in step by hand. *)

val form_stem : string
(** The text [--edit] opens, which is [Masc.Keeper_turn_up_args.creation_stem]
    unchanged — the same form the TUI's create opens, so a field the parser
    starts requiring reaches both surfaces at once. Restating it here is what
    left the TUI form two fields wide across the whole time [sandbox_profile]
    was required. *)

val form_input_refusal : stdin_is_tty:bool -> editor:string option -> string option
(** Why [--edit] cannot run, or [None] when it can.

    Two reasons, both settled before a child process is spawned or a socket is
    opened: no terminal (a pipe, a CI step, a subagent) and no [$EDITOR] or
    [$VISUAL]. Each message names the flags that carry the same declaration
    without an editor, so the answer to a refusal is in the refusal. *)

val declaration_of_form : string -> (Yojson.Safe.t * string, string) result
(** The edited form's declaration and the [name] it declares, which is needed
    separately because it addresses the route.

    Rejects text that is not a JSON object, an object with no non-blank
    [name] string, and an object with no non-blank [network_mode] string. The
    two required keys are the two the flag path requires, so [--edit] cannot
    reach a state the flags refuse: the form judged only [name], and deleting
    the stem's empty [network_mode] line sent the key absent and took the
    profile default of [none] — the incident this command exists to stop.

    The [network_mode] {e spelling} is not judged here, only its presence.
    Nothing else is judged either: this is not a second copy of
    [Masc.Keeper_turn_up_args.parse]. *)

type outcome =
  | Created of
      { name : string
      ; sandbox_profile : string
      ; network_mode : string
      }
  | Reconfigured of { name : string }
  | Revision_conflict
  | Unauthorized of string
  | Refused of string
  | Unreachable of string

val outcome_of_response : status:int -> body:string -> outcome
(** Classify one [/up] response. [Unreachable] is never produced here — it is
    the transport's own failure, which the command constructs.

    [Created] reads the isolation the create envelope names. Only the create
    branch answers with those two fields: it returns
    [Keeper_turn_up_create.create_response_json], while the update branch
    returns [Keeper_meta_json.meta_to_json], which carries neither because
    both are TOML-owned. A 2xx without them is therefore [Reconfigured] — a
    keeper of that name already existed and the declaration was applied to it
    — and not a create whose isolation went unread.

    [Revision_conflict] is the retryable rejection, matched on the [code] the
    server's [detail] carries, against
    [Masc.Keeper_turn_up_update.config_revision_conflict_code]. An exported
    constant, not the sentence around it. [Unauthorized] is 401 or 403.
    Everything else is [Refused] carrying the server's own message verbatim:
    this command does not re-classify server prose. *)

val render : outcome -> string * int
(** What to print and the exit code, produced together so they cannot
    disagree. A non-zero code means the text belongs on stderr; the caller
    routes it.

    [Refused] exits 1 whether or not anything was written. The server reports
    a keeper that was created and then failed to launch its lane as a
    sentence, and reading that sentence is how a string classifier starts, so
    this command does not claim to know which happened. The message says the
    declaration may have been written, and says that re-running the same
    command applies it to the keeper of that name rather than making a second
    one. Only the refusals this module raises before a request — the ones
    {!declaration_of_flags}, {!form_input_refusal} and {!declaration_of_form}
    return — can say that nothing was created. *)
