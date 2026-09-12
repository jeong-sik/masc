(** Voice_wizard — the steps of setting up one voice endpoint, without any I/O.

    A wizard is a sequence of questions whose shape depends on the answers
    already given, plus the rule that decides when enough has been answered.
    Both live here, so the TUI and a later dashboard ask the same questions in
    the same order and refuse the same incomplete drafts. Neither this module
    nor anything it returns reads a file, opens a socket, or looks at the clock.

    What it produces is a {!Voice_setup.change} list, which is what actually
    reaches runtime.toml. It does not decide whether an endpoint works: that is
    what the endpoint probes answer ([masc voice-verify]), measured
    against the endpoint itself. A wizard that judged an address by looking at it would
    be guessing. *)

type provider =
  | Elevenlabs
  | Openai_compatible
  | Mcp_tool
  | Macos_say
  | Whisper_cli

val provider_label : provider -> string
val provider_of_label : string -> provider option

val providers_for : Voice_setup.section -> provider list

(** The wire name of the kind this provider becomes, for a caller that has to
    name a kind over HTTP without restating the mapping. *)
val provider_kind_label : provider -> string
(** Which providers can serve this section. [Mcp_tool] is offered for speech out
    and not for speech in: that kind synthesizes through a tool call and has no
    transcribe path. *)

type draft =
  { section : Voice_setup.section
  ; provider : provider
  ; endpoint_id : string
  ; address : string
      (** [base_url] for an HTTP provider, [mcp_url] for {!Mcp_tool}. Blank is
          allowed for {!Elevenlabs}, which then resolves to
          {!Voice_config.default_elevenlabs_base_url}. *)
  ; credential_variable : string
      (** Name of the environment variable holding the key, never the key. A
          wizard that took the secret itself would put it in runtime.toml,
          which is committed. *)
  ; model : string
  ; voice : string  (** [tts.default_voice]. Unused for speech in. *)
  ; timeout_seconds : float option
  }

val blank : section:Voice_setup.section -> provider:provider -> draft
(** A draft with the defaults that provider implies and nothing else filled in.
    [Elevenlabs] arrives with its credential variable and address already set to
    the usual ones, because they are the same on every workstation; nothing
    else is guessed. *)

val suggested_addresses : Voice_setup.section -> (string * string) list
(** [(what it is, address)] starting points for a local server, to save typing.

    Not a list of supported products, and not a claim that anything is running:
    the wizard cannot tell what is listening on a port, and the probe is what
    decides. A starting point that is wrong costs one edit. *)

type gap =
  | Endpoint_id_is_blank
  | Address_is_blank
  | Credential_variable_is_blank
  | Model_is_blank
  | Voice_is_blank

val gap_message : gap -> string

val gaps : draft -> gap list
(** What this draft still needs, in the order the steps ask for it. Empty
    exactly when {!changes} answers [Ok].

    Which fields are required depends on the provider: an OpenAI-compatible
    endpoint needs an address and can go without a credential (omitting it is
    what keeps the Authorization header off a local server that never asked for
    one), while ElevenLabs needs the credential and can go without an address. *)

val changes : draft -> (Voice_setup.change list, gap list) result
(** The changes this draft describes, or what it is still missing.

    The section's [default_model] is set alongside the endpoint rather than
    after it: a section that exists must name one, so an endpoint written on its
    own would leave a file the loader refuses. *)

type step =
  | Section
  | Provider
  | Name
  | Address
  | Credential
  | Model
  | Voice
  | Review

val steps : draft -> step list
(** The questions this draft has to answer, in order. Depends on the provider
    and the section: ElevenLabs is not asked for an address, an MCP tool is not
    asked for a credential, and speech in is not asked for a voice. *)

val step_prompt : step -> string
(** One line asking for that step, in the second person. *)

val step_gap : step -> gap option
(** The gap a step fills, when it fills one. [Review] fills none. *)

val save_request
  :  draft
  -> revision:string
  -> (Yojson.Safe.t, gap list) result
(** The body for [POST /api/v1/voice/setup]: the revision this draft was written
    against, and the changes it describes.

    The wire shape is the server's to read -- it parses back into the closed sum
    type before it means anything. Producing it here keeps one spelling of it on
    the sending side: a TUI and a dashboard that each wrote their own would
    drift, and the drift would show only as a request the server refuses. *)

val with_section : draft -> Voice_setup.section -> draft
(** Move a draft to the other side. The provider is re-picked when the current
    one does not serve the new side -- an MCP tool speaks and does not listen --
    and everything but the endpoint's name is reset with it, since the rest is
    provider vocabulary. *)
