(** Voice setup wizard probes/saves, per-keeper voice assignment, voice
    config/setup loading, and local CoreAudio input resolution. *)

val voice_probe_kept_back
  :  ko:bool
  -> Masc_tui_types.workspace_refusal
  -> string

val launch_voice_wizard_probe
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> request:int
  -> string
  -> unit

val voice_setup_revision : Yojson.Safe.t -> string option

val launch_voice_wizard_reread
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> request:int
  -> unit

val voice_wizard_probe_sentence : string

val voice_wizard_probe_lines : Yojson.Safe.t -> string list

val launch_voice_wizard_save
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_voice_wizard_session.voice_wizard_session
  -> unit

val voice_setup_first_tts_endpoint
  :  Masc_tui_types.state
  -> (string * string option) option

val voice_agent_voice_rows : Yojson.Safe.t -> (string * string) list

val launch_voice_agent_voices
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> kind:string
  -> api_key_env:string option
  -> unit

val launch_voice_agent_voice_save
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> Masc_tui_types.voice_agent_session
  -> unit

val resolved_audio_input_device
  :  pick:string option
  -> for_display:bool
  -> string option

val launch_voice_config_load
  :  Masc_tui_types.state
  -> mailbox:Masc_tui_transport.Workspace_admission.mailbox
  -> unit
