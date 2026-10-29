(** Pure voice catalogue layer — ids, aliases, parsing and validation of
    endpoint catalogues. Extracted from Voice_bridge (E09 Phase 1, task-2526):
    no transport, no SDK calls, no files — only catalogue logic.

    Design: reports/e09-voice-addon-boundary-design-20261023.md
    Phase report: reports/e09-phase1-catalogue-split-20261023.md *)

let spoke_detail ~bytes ~voice =
  Printf.sprintf
    "%d bytes of audio in %s"
    bytes
    (if String.trim voice = "" then "the system voice" else "\"" ^ voice ^ "\"")
;;

(* What an endpoint reached over HTTP answered. A body carrying no [text]
   string is not a silent microphone -- it is an answer this code does not
   read -- and the probe reports the empty transcript as having heard nothing.
   Kept apart here so that the one distinction the probe exists to draw is not
   erased by a body it did not understand. *)
let transcript_of_stt_json json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "text" fields with
     | Some (`String transcript) -> Ok transcript
     | Some _ -> Error "the endpoint answered with a text field that is not a string"
     | None -> Error "the endpoint answered without a text field")
  | _ -> Error "the endpoint answered with something that is not an object"
;;

(* One voice as an endpoint names it. The id is what a configuration stores;
   the name and the language are what let a person pick it. Aliases are the
   other selections that reach it: espeak-ng's -v answers to the VoiceName
   and Language columns and to the parenthesised aliases its --voices prints
   after the file, and a voice chosen by one of those is chosen, not
   mistaken. Empty for the kinds that publish none. *)
type catalogue_voice =
  { voice_id : string
  ; voice_name : string option
  ; voice_language : string option
  ; voice_aliases : string list
  }

let catalogue_voice_json voice =
  `Assoc
    ([ "id", `String voice.voice_id ]
     @ (match voice.voice_name with
        | Some name -> [ "name", `String name ]
        | None -> [])
     @ (match voice.voice_language with
        | Some language -> [ "language", `String language ]
        | None -> [])
     @
     match voice.voice_aliases with
     | [] -> []
     | aliases -> [ "aliases", `List (List.map (fun a -> `String a) aliases) ])
;;

(* Parsing what say answers to -v ?, measured 2026-09-12 on macOS 26: 184 lines
   shaped

     Yuna                     ko_KR    # 안녕하세요. 제 이름은 유나입니다.
     Eddy (...)               ko_KR    # ...
     Majed                    ar_001   # ...

   The columns are space-padded, not tabs. The locale is not always two letters
   and two letters -- ar_001 is in that list -- so it is taken as the last field
   before the hash rather than matched by shape.

   Everything before the locale is the id, parentheses included: say adds them
   to names that exist in several languages, and passing the bare name then
   picks a different language without saying so. *)
let say_catalogue_of_output output =
  String.split_on_char '\n' output
  |> List.filter_map (fun line ->
       match String.index_opt line '#' with
       | None -> None
       | Some hash ->
         let head = String.trim (String.sub line 0 hash) in
         let fields = String.split_on_char ' ' head |> List.filter (fun p -> p <> "") in
         (match List.rev fields with
          | locale :: (_ :: _ as name_reversed) ->
            let name = String.concat " " (List.rev name_reversed) in
            Some
              { voice_id = name; voice_name = Some name; voice_language = Some locale; voice_aliases = [] }
          (* A line carrying a hash and nothing else names no voice. Dropped
             rather than offered: a row that cannot be chosen is worse than a
             shorter list. *)
          | [ _ ] | [] -> None))
;;

(* The aliases an espeak-ng --voices row carries after the file column,
   shaped [(en 3)] or glued [(zh-cmn 5)(zh 5)]. Each group is an alias and the
   priority espeak-ng resolves it with; only the alias selects a voice, so
   only the alias is kept. A group is an alias when its inside is at least
   two tokens ending in digits: voice names carry parentheses too --
   [English_(America)] -- but never a space inside them, so they cannot
   qualify. *)
let espeak_aliases_of_line line =
  let groups =
    let len = String.length line in
    let rec scan acc i =
      if i >= len
      then List.rev acc
      else (
        match String.index_from_opt line i '(' with
        | None -> List.rev acc
        | Some open_at ->
          (match String.index_from_opt line (open_at + 1) ')' with
           | None -> List.rev acc
           | Some close_at ->
             let inside = String.sub line (open_at + 1) (close_at - open_at - 1) in
             scan (inside :: acc) (close_at + 1)))
    in
    scan [] 0
  in
  let is_priority token =
    String.length token > 0
    && String.for_all
         (fun c -> c >= '0' && c <= '9')
         token
  in
  List.filter_map
    (fun inside ->
      match String.split_on_char ' ' inside |> List.filter (fun p -> p <> "") with
      | alias :: _ :: _ as tokens ->
        (match List.rev tokens with
         | last :: _ when is_priority last -> Some alias
         | _ -> None)
      | _ -> None)
    groups
;;

(* Parsing what espeak-ng answers to --voices, measured 2026-10-07 with
   espeak-ng 1.52.0: a header line then one row per voice shaped

     Pty Language       Age/Gender VoiceName          File                 Other Languages
      5  af              --/M      Afrikaans          gmw/af
      2  en-us           --/M      English_(America)  gmw/en-US            (en 3)
      5  cmn             --/M      Chinese_(Mandarin,_latin_as_English) sit/cmn  (zh-cmn 5)(zh 5)

   Columns are whitespace-separated. The voice name is the fourth token and
   the language the second; -v answers to both and to the aliases after the
   file, so all three are kept. A row with fewer than four tokens names
   nothing and is dropped rather than offered.

   The VoiceName column shows spaces as underscores, but -v wants the name
   with its spaces back: -v English_(America) fails while -v "English
   (America)" speaks. Swept 2026-10-07 across all 141 voices -- every
   space-restored name spoke, while 46 underscore forms failed and none spoke
   only with underscores -- so the id stored is the restored name. Stored
   verbatim, the wizard would offer rows that fail when chosen. *)
let espeak_spoken_name printed =
  String.map (fun c -> if Char.equal c '_' then ' ' else c) printed
;;

let espeak_catalogue_of_output output =
  let lines = String.split_on_char '\n' output in
  let rows =
    match lines with
    | [] -> []
    | _header :: rest -> rest
  in
  List.filter_map
    (fun line ->
      match String.split_on_char ' ' (String.trim line) |> List.filter (fun p -> p <> "") with
      (* The header names its own columns; if it ever reaches the rows it
         must not parse as a voice called VoiceName. *)
      | "Pty" :: _ -> None
      | _pty :: language :: _age_gender :: printed_name :: _ ->
        let voice_name = espeak_spoken_name printed_name in
        Some
          { voice_id = voice_name
          ; voice_name = Some voice_name
          ; voice_language = Some language
          ; voice_aliases = espeak_aliases_of_line line
          }
      | _ -> None)
    rows
;;

type say_voice =
  | Say_has_it
  | Say_lacks_it of { installed : int }

let say_voice_in_catalogue voices ~voice =
  let wanted = String.lowercase_ascii (String.trim voice) in
  if
    List.exists
      (fun (listed : catalogue_voice) ->
        String.equal (String.lowercase_ascii listed.voice_id) wanted)
      voices
  then Say_has_it
  else Say_lacks_it { installed = List.length voices }
;;

(* A blank voice asks for no name, and say then uses its own; there is nothing
   to look up. The catalogue itself is fetched by the caller's [~lister] so
   this layer stays free of transport. *)
let check_say_voice ~lister endpoint ~voice =
  let voice = String.trim voice in
  if String.equal voice ""
  then Ok ()
  else (
    match lister endpoint with
    | Error message ->
      Error
        (Printf.sprintf "the voices say has could not be listed to check \"%s\": %s"
           voice message)
    | Ok voices ->
      (match say_voice_in_catalogue voices ~voice with
       | Say_has_it -> Ok ()
       | Say_lacks_it { installed } ->
         Error
           (Printf.sprintf
              "say has no voice named \"%s\", and would speak in another one without \
               failing; masc voice-local-setup --list-voices prints the %d it has"
              voice installed)))
;;

(* Whether espeak-ng answers to this selection. Its -v accepts the voice name
   with its spaces, the Language column, the parenthesised aliases, and any of
   these followed by a "+<variant>" suffix (or "+<variant>" alone for the
   default voice; upstream docs/voices.md and voices.c ExtractVoiceVariantName).
   A bare "en" speaks English through the (en 2) alias, and "zh" reaches
   Mandarin through (zh 5) -- so a selection matching any of the three,
   ignoring ASCII case, is installed. The case-folding is measured, not
   assumed: -v korean, -v KOREAN, -v "english (america)" and -v EN all spoke
   on 2026-10-07 with 1.52.0.

   The catalogue lists base voices, not every base+variant combination. When
   a variant suffix is present, validation splits at '+' and checks that the
   base voice is installed (or empty, defaulting) and the variant suffix is
   non-empty; the synthesis probe or speak invocation then lets espeak-ng
   load the variant itself.

   Unlike say, espeak-ng refuses an unknown voice itself: measured the same
   day, -v NoSuchVoiceXYZ exited 1 with "Error: The specified espeak-ng voice
   does not exist." and wrote no file. This check still runs first so the
   refusal names the voice that was asked for and points at the list it can
   be picked from, rather than surfacing only as a failed clip. *)
let espeak_base_voice_in_catalogue voices ~base_voice =
  let wanted = String.lowercase_ascii (String.trim base_voice) in
  let matches listed = String.equal (String.lowercase_ascii listed) wanted in
  List.exists
    (fun (listed : catalogue_voice) ->
      matches listed.voice_id
      || Option.value ~default:false (Option.map matches listed.voice_language)
      || List.exists matches listed.voice_aliases)
    voices
;;

let espeak_voice_in_catalogue voices ~voice =
  let voice = String.trim voice in
  match String.index_opt voice '+' with
  | None -> espeak_base_voice_in_catalogue voices ~base_voice:voice
  | Some idx ->
    let base = String.sub voice 0 idx |> String.trim in
    let variant = String.sub voice (idx + 1) (String.length voice - idx - 1) |> String.trim in
    let variant_parts = String.split_on_char '+' variant in
    let valid_variants =
      variant_parts <> []
      && List.for_all (fun v -> String.length (String.trim v) > 0) variant_parts
    in
    if not valid_variants
    then false
    else if String.equal base ""
    then true
    else espeak_base_voice_in_catalogue voices ~base_voice:base
;;

let check_espeak_voice ~lister endpoint ~voice =
  let voice = String.trim voice in
  if String.equal voice ""
  then Ok ()
  else (
    match lister endpoint with
    | Error message ->
      Error
        (Printf.sprintf "the voices espeak-ng has could not be listed to check \"%s\": %s"
           voice message)
    | Ok voices ->
      if espeak_voice_in_catalogue voices ~voice
      then Ok ()
      else
        Error
          (Printf.sprintf
             "espeak-ng has no voice named \"%s\"; espeak-ng --voices prints the %d it has"
             voice (List.length voices)))
;;

(* Dispatched by what the endpoint runs: the say check matches names
   only, the espeak-ng check matches names, language tags and aliases. *)
let check_command_voice ~lister endpoint ~voice =
  let adapter = Voice_runtime_overlay.adapter_for_endpoint endpoint in
  match adapter.transport with
  | Voice_runtime_overlay.Macos_say -> check_say_voice ~lister endpoint ~voice
  | Voice_runtime_overlay.Espeak_ng -> check_espeak_voice ~lister endpoint ~voice
  | Voice_runtime_overlay.Openai_compat
  | Voice_runtime_overlay.Elevenlabs_direct
  | Voice_runtime_overlay.Voice_mcp
  | Voice_runtime_overlay.Whisper_cli ->
    (* Reached only for kinds the speak path never sends down the command
       branch; refusing keeps a miswired kind loud instead of unvoiced. *)
    Error
      (Printf.sprintf "voice config endpoint %s is not a command speaker"
         endpoint.Voice_config.id)
;;

(* The container each kind writes. say encodes WAVE and cannot encode MP3
   at all; everything reached over a wire answers MP3, which is what the
   OpenAI-compatible /audio/speech and ElevenLabs both default to and what
   the MCP bridge relays. Whisper_cli never speaks -- the branch that names
   it refuses before a file is opened -- so its answer is never written.
   espeak-ng writes WAVE through -w like say does. *)

(* How an endpoint transcribes, if it does. Written as a type rather than read
   off the kind at each site: the two command kinds reached main while the STT
   probe still matched on three, and a kind added to
   {!Voice_config.endpoint_kind} now stops this function compiling until it has
   an answer here. *)
type transcriber =
  | Over_http
  | By_command
  | Does_not_transcribe

let transcriber_of_kind = function
  | Voice_config.Openai_compat | Voice_config.Elevenlabs_direct -> Over_http
  | Voice_config.Whisper_cli -> By_command
  (* Three of these speak. None listens: [macos_say] is the say command,
     [espeak_ng] is the espeak-ng command, and voice_mcp carries a tool call,
     not audio. *)
  | Voice_config.Voice_mcp | Voice_config.Macos_say | Voice_config.Espeak_ng ->
    Does_not_transcribe
