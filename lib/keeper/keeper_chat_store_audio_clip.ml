open Keeper_chat_types

(* RFC-0235 P3: the history endpoint can tell the dashboard that a clip
   has been reaped by checking the same audio directory the synthesis side
   writes to. This keeps the TTL reaper simple while avoiding a broken
   native player on reload. *)
let audio_clip_exists ~base_dir token =
  (* Which container the clip is in is the endpoint's, not this reader's, so
     the token is resolved against every format rather than against MP3 --
     a say clip is WAVE, and looking only for MP3 reports every one of them
     as reaped. *)
  Voice_bridge_core.find_clip
    ~dir:
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "audio")
    ~token
  |> Option.is_some

(* How a file the synthesis side just wrote is announced on a chat line.

   Both halves come out of the one path: the token builds the URL the
   dashboard fetches, and the extension says what the bytes are. They used to
   be taken separately -- the token chopped off by hand, the type the literal
   "audio/mpeg" -- so every [say] reply, which is WAVE and is what a fresh mac
   has, was announced as MP3. The dashboard reads the container off the clip
   response rather than off this field, which is why nothing looked broken;
   the field is still what is persisted here and emitted on SSE, so a reader
   that has only the payload had only the wrong answer.

   It lives here, next to {!audio_clip_exists}, because this is the module
   that owns the clip record: a caller that builds one field at a time is
   where the two halves came apart. *)
let audio_clip_of_synthesized_file ~audio_file ~message_text ~device_id =
  match Voice_bridge_core.clip_of_path audio_file with
  | None ->
    (* A file under a name masc does not serve would be announced at a URL the
       clip route answers 404 for: it resolves a token by trying each known
       extension. The line is still recorded, without audio. *)
    Voice_bridge_core.log_error
      (Printf.sprintf
         "voice: synthesized %s is not a clip masc can serve; the reply is \
          recorded without audio"
         (Filename.basename audio_file));
    None
  | Some (token, format) ->
    Some
      { token
      ; audio_url = Some (Masc_network_defaults.voice_audio_path token)
      ; mime = Voice_bridge_core.clip_content_type format
      ; duration_sec = Voice_bridge_core.audio_duration_seconds ~audio_file
      ; message_text
      ; device_id
      ; expired = false
      }

let valid_audio_token token =
  Re.execp (Re.compile (Re.Pcre.re "^[A-Za-z0-9_-]+$")) token

let resolve_audio_expiry ~base_dir audio =
  match audio with
  | None -> None
  | Some a ->
      let expired =
        if not (valid_audio_token a.token) then true
        else
          match base_dir with
          | None -> a.expired
          | Some base_dir ->
              a.expired
              || not (audio_clip_exists ~base_dir a.token)
      in
      Some { a with expired }
