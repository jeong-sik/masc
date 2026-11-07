(** The audio clip of a chat row.

    [audio_clip_exists] says whether the clip of a token is still on disk,
    whatever its container. [audio_clip_of_synthesized_file] builds the clip
    record of a file that the synthesis side wrote: the token, the URL and the
    content type come from the one path. A file that masc does not serve gives
    [None], so the line is recorded without audio. [valid_audio_token] says
    whether a token has only the characters of a clip name, and
    [resolve_audio_expiry] sets [expired] on a clip whose token is not valid or
    whose file is gone.
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types

val audio_clip_of_synthesized_file :
  audio_file:string ->
  message_text:string ->
  device_id:string option ->
  audio_clip option

val resolve_audio_expiry :
  base_dir:string option ->
  audio_clip option -> audio_clip option
