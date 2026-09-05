(** Byte-identity pins for the voice tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_shard_types.voice_tools] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    Nothing here derives a value from an owner module, so the whole list
    moves in one step.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. *)

open Alcotest

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* name, description, input_schema (keys sorted) *)
let expected =
    [ {|keeper_voice_speak|}, {|Speak a short utterance via the voice bridge.

Blocks until local playback finishes: status='spoken' with played_seconds means the user has already heard it — do NOT repeat or rephrase the same content. Duplicate identical messages within 30s return status='dedup_skipped' without playing. TTS or playback failures are returned as errors (ok=false), not silent successes. Concurrent calls are serialized by a global lock.|}, {|{"properties":{"audio_device":{"description":"Optional target output device id/name for the dashboard/client","type":"string"},"message":{"description":"Text to speak","type":"string"},"priority":{"description":"Optional priority hint for the TTS endpoint","type":"integer"},"provider":{"description":"Optional voice provider override","type":"string"}},"required":["message"],"type":"object"}|}
    ; {|keeper_voice_listen|}, {|Record user speech via microphone and transcribe to text.

Starts recording, waits for speech, stops on silence (2s), then returns transcribed text.|}, {|{"properties":{"language_code":{"description":"ISO language hint, e.g. ko, en","type":"string"},"timeout_seconds":{"description":"Max recording duration in seconds (default 15)","type":"number"}},"type":"object"}|}
    ; {|keeper_voice_agent|}, {|Get your own voice capability and configuration.

Reports assigned voice, available voices, active voice session state, available conversation modes, and voice_loop guidance. Without MASC_VOICE_REALTIME_WS_URL, operator audio is transcribed to normal keeper text turns and keeper output uses keeper_voice_speak/dashboard audio clips. No network required.|}, {|{"properties":{},"type":"object"}|}
    ; {|keeper_voice_sessions|}, {|List active voice sessions from the voice bridge.|}, {|{"properties":{},"type":"object"}|}
    ; {|keeper_voice_session_start|}, {|Start a voice session for this keeper.

Defaults to turn_based batch STT/TTS. conversation_mode=realtime_bridge is accepted only when MASC_VOICE_REALTIME_WS_URL points at a configured realtime audio bridge; otherwise the tool fails closed instead of pretending a duplex stream exists.|}, {|{"properties":{"conversation_mode":{"description":"Optional mode. realtime_bridge requires MASC_VOICE_REALTIME_WS_URL.","enum":["turn_based","realtime_bridge"],"type":"string"},"session_name":{"description":"Optional session name","type":"string"}},"type":"object"}|}
    ; {|keeper_voice_session_end|}, {|End the active voice session for this keeper and release bridge resources.|}, {|{"properties":{},"type":"object"}|}
    ]
;;

let published = Tool_shard_types.voice_tools

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_shard_types.voice_tools")
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (find name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_shard_types.voice_tools in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "voice_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ]
;;
