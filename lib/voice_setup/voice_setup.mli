(** Voice_setup — write the [\[voice\]] section of runtime.toml.

    Every change goes through {!Runtime.edit_config_text}, so the read, the edit
    and the commit happen inside one config write lock, and through
    {!Toml_line_editor}, so comments and unrelated tables survive byte-for-byte.
    A live runtime.toml carries an operator's measured notes above the whisper
    endpoint -- the transcription latency, which field makes the Authorization
    header absent, how much memory the server holds resident -- and a writer
    that regenerated the section would delete the reason the settings are what
    they are.

    Deliberately not built on {!Runtime_setup_batch}: that stages a pair of
    files behind a [runtime-default-set] child process and verifies an LLM
    runtime answers a tool round trip. None of that describes a voice
    endpoint, and a voice write has no business rewriting [\[runtime\]]. *)

type section =
  | Tts
  | Stt
      (** Which endpoint list a change addresses.

          [voice.session] is not offered. It is spelled as an inline
          [endpoints = \[\]] rather than an array-of-tables, so the two
          spellings would collide, and nothing configures a realtime session
          yet. *)

type change =
  | Put_endpoint of section * Voice_config.endpoint
      (** Add the endpoint, or update the one already carrying its [id].
          Fields left [None] in the record are removed from an existing entry:
          moving an endpoint from a hosted provider to a local one has to drop
          [api_key_env], which would otherwise send an Authorization header the
          local server never asked for. *)
  | Remove_endpoint of section * string
  | Set_default_model of section * string
      (** Required once a section exists, and never blank: every endpoint in
          the section is asked for this model by name. *)
  | Set_tts_default_voice of string
  | Set_send_on_stop of bool
      (** [\[voice.stt\]].send_on_stop: whether ending a capture also sends
          what was heard, instead of leaving it in the draft. Here rather than
          in a TUI-only key because this is the section a configuring surface
          writes, and the setting could otherwise only be turned on by editing
          runtime.toml by hand. *)
  | Set_agent_voice of string * string option
      (** [(agent_id, voice)] in [\[voice.tts.agent_voices\]]. [None] drops the
          mapping, so the agent falls back to [tts.default_voice]. *)

type error =
  | Configuration_unavailable of string
      (** runtime.toml could not be read. *)
  | Configuration_changed
      (** Someone else wrote runtime.toml between {!observe} and this call.
          Nothing was written. Re-observe and decide again against what is
          there now. *)
  | Voice_section_invalid of string
      (** The edited text does not load as a voice configuration, so it was
          not written. The message is the loader's own sentence, naming the
          key and what it wanted.

          This is the check that matters. Voice is read by no one at boot: the
          first speak or transcribe after a change is what refuses, and a
          broken section once went unnoticed for six days. A writer that
          committed text it had not read back would reproduce that exactly. *)
  | Configuration_rejected of string
      (** The commit was refused. The whole file is validated on every commit,
          so an unrelated section that is already broken refuses a voice-only
          edit too; the message says which. *)

  | Endpoint_path_unusable of string
      (** The endpoint list cannot be written where it would have to go. An
          empty list is spelled as a key today, [endpoints = []], and an
          array-of-tables cannot sit beside a key of the same path. Nothing was
          written; the message says which shape is in the way.

          Not reachable through {!Tts} or {!Stt} as things stand: both refuse an
          empty endpoint list outright, so a file spelling one as a key does not
          load as a voice configuration and {!observe} refuses it first. It is
          here because the writer underneath can refuse, and swallowing that
          would be the silent failure this module exists to avoid. *)

val error_message : error -> string

val observe
  :  runtime_config_path:string
  -> (string * Voice_config.t option, error) result
(** The current source revision and the voice configuration that revision
    carries, from one observation so a caller cannot join a revision to a
    different read. Hand the revision back as [expected_revision].

    [Ok (revision, None)] means runtime.toml has no [\[voice\]] section yet. *)

val preview
  :  runtime_config_path:string
  -> expected_revision:string
  -> change list
  -> (string, error) result
(** The runtime.toml text these changes would commit, without committing it,
    for showing an operator what is about to change.

    Validated the way {!apply} validates, so an [Ok] preview is a preview of
    something that can be written. It reads outside the write lock, so the
    revision may move before {!apply} runs -- which is why apply checks it
    again, under the lock. *)

val apply
  :  runtime_config_path:string
  -> expected_revision:string
  -> change list
  -> (unit, error) result
(** Apply every change in order, in one commit under the config write lock.

    All of them or none. Changes are taken as a list rather than one call each
    because they depend on one another: a first endpoint and the
    [default_model] its section requires have to land together, and applying
    them one at a time would refuse the first half and leave the file in a
    state the loader rejects. *)

type voice_placement =
  | On_the_section (** no TTS section yet: the voice becomes the workspace default *)
  | On_the_endpoint (** a section exists and its voice belongs to another provider *)

val voice_placement : section_exists:bool -> voice_placement
(** Where a voice chosen for a local (command-run) endpoint is written.

    There are two places because a voice name is provider-shaped: [say] takes a
    label like ["Yuna"], ElevenLabs a 20-character id. One workspace default
    cannot serve both, so an endpoint carries its own when it has to.

    But an endpoint voice outranks [voice.tts.agent_voices]
    ({!Voice_config.voice_for_agent_at_endpoint}), so one written where it is
    not needed makes every per-keeper voice inert. Measured on a fresh
    workspace 2026-09-13: with it, a keeper mapped to Eddy spoke in Yuna
    (85,908 bytes); without it, Eddy (119,044 bytes), while an unmapped keeper
    still got Yuna.

    So a fresh workspace gets the section default and per-keeper voices layer
    over it, which is the order a reader expects. Only a workspace that already
    has a section — whose voice is some other provider's — puts one on the
    endpoint, and accepts that the mappings do not reach that endpoint. *)
