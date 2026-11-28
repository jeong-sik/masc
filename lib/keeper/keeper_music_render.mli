(** [keeper_music_render]: an alphaTex score made into files a Keeper can send.

    The host's [masc-alphatex] renders the notation to PNG, the score to a
    Standard MIDI File, and the score to WAV audio with alphaTab's built-in
    soundfont. Each file becomes the Keeper's ephemeral attachment, and the
    result names them by [attachment_id]. *)

type output =
  | Score  (** PNG of the whole score: staff and tab, as the score declares. *)
  | Midi  (** Standard MIDI File, format 0. *)
  | Audio  (** WAV, 44.1 kHz stereo 16-bit. *)

val all_outputs : output list
(** Every output, in the order a result lists them. *)

val output_name : output -> string
(** ["score" | "midi" | "audio"], as the tool's [outputs] argument spells it. *)

val executable_name : string
(** ["masc-alphatex"], looked up on the server's [PATH]. *)

val source_max_bytes : int
(** The largest [source] accepted, in bytes. *)

type request = private
  { source : string
  ; outputs : output list
        (** Non-empty, without repeats, in {!Score}, {!Midi}, {!Audio} order. *)
  }

val request_of_args : Yojson.Safe.t -> (request, string) result
(** Read [{"source": ..., "outputs": [...]}]. [source] must be non-blank and
    at most {!source_max_bytes}. [outputs] defaults to score and midi; an
    empty list, an unknown name, a repeat or a non-string is an error. *)

val handle :
  base_path:string ->
  keeper_name:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Render [args] and store each output as [keeper_name]'s ephemeral
    attachment. Every requested output is stored, or the call fails:
    - bad arguments are [Policy_rejection];
    - [masc-alphatex] absent from [PATH] is [Dependency_unavailable];
    - alphaTex that does not parse is [Policy_rejection], with alphaTab's
      diagnostics;
    - any other render or storage failure is [Runtime_failure]. *)

module For_testing : sig
  val run :
    executable:string ->
    base_path:string ->
    keeper_name:string ->
    request ->
    Keeper_tool_execution.t
  (** {!handle} after its arguments are read and [masc-alphatex] is found,
      with [executable] in its place. *)
end
