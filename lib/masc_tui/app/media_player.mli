(** Self-contained local playback controller for TUI chat audio, MIDI, and video
    attachments.

    Uses [Unix.create_process] with [Unix.O_CLOEXEC], owns at most one active
    background audio/MIDI player process (cleanly stopping and reaping any
    previous process before starting another), and removes owned temporary files
    on natural exit, {!stop}, or {!shutdown}. *)

type os_family =
  | Os_macos
  | Os_linux

type playback_plan =
  | Audio_spawn of { executable : string; args : string list }
  | Midi_fluidsynth of { executable : string; args : string list }
  | Midi_handoff_alphatex of string
  | Video_open of { executable : string; args : string list }

type play_outcome =
  | Playing of string
  | Opened_external of string
  | Handoff_alphatex of string

type t

val create : unit -> t
(** Create a playback controller with no active process. *)

val detect_os : unit -> os_family
(** Detect host OS family ([Os_macos] on Darwin, [Os_linux] otherwise). *)

val find_soundfont :
  ?getenv:(string -> string option) ->
  ?executable_name:string ->
  ?base_path:string ->
  ?file_exists:(string -> bool) ->
  unit ->
  string option
(** Locate a SoundFont ([sonivox.sf2] or standard system [.sf2]) for
    [fluidsynth] MIDI playback. *)

val plan_playback :
  ?os:os_family ->
  ?resolve:(string -> string option) ->
  ?soundfont:string ->
  mime_type:string ->
  path:string ->
  unit ->
  (playback_plan, string) result
(** Pure playback planner mapping [(os, available tools, soundfont, mime_type,
    path)] to an explicit {!playback_plan} or a clear diagnostic. *)

val play_file :
  t ->
  ?base_path:string ->
  ?resolve:(string -> string option) ->
  ?temp_cleanup:bool ->
  mime_type:string ->
  label:string ->
  path:string ->
  unit ->
  (play_outcome, string) result
(** Stop any previous active player, then play [path] according to
    {!plan_playback}. When [temp_cleanup] is [true]:
    - on {!Playing}, [path] is removed once playback ends or {!stop}/{!shutdown} is called;
    - on {!Opened_external}, [path] is retained (bounded LRU) for the external player and removed on {!shutdown};
    - on {!Handoff_alphatex}, the caller owns [path] until the external viewer finishes. *)

val stop : t -> string option
(** Terminate and reap any active audio/MIDI player process, remove its owned
    temp file, and return its label (or [None] if nothing was playing). *)

val is_playing : t -> bool
(** [true] while a tracked audio/MIDI player process is active. *)

val shutdown : t -> unit
(** Stop and reap any active process on TUI exit. *)
