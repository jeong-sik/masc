(* The stream readings as the one line these cases compare. The transcript
   reports them as values. Which reading survives a scope change is what the
   cases check, and one line per reading keeps each case to one comparison. *)
let stream_tokens_text ~keeper_name transcript =
  match Masc_tui_keeper_chat_transcript.stream_usage ~keeper_name transcript with
  | None -> None
  | Some usage ->
    let counter label value = Option.map (Printf.sprintf "%s %d" label) value in
    (match
       List.filter_map Fun.id
         [ counter "in" usage.Masc_tui_keeper_chat_live.input_tokens
         ; counter "out" usage.Masc_tui_keeper_chat_live.output_tokens
         ; counter "cache read" usage.Masc_tui_keeper_chat_live.cache_read_input_tokens
         ; counter "cache write" usage.Masc_tui_keeper_chat_live.cache_creation_input_tokens
         ]
     with
     | [] -> None
     | counters -> Some ("tokens: " ^ String.concat " \xc2\xb7 " counters))

let stream_details_text ~keeper_name transcript =
  match
    List.filter_map Fun.id
      [ stream_tokens_text ~keeper_name transcript
      ; Option.map
          (fun reason -> "stopped: " ^ reason)
          (Masc_tui_keeper_chat_transcript.stream_stop_reason ~keeper_name transcript)
      ]
  with
  | [] -> None
  | parts -> Some (String.concat " \xc2\xb7 " parts)

let runtime_identity_text ~keeper_name ~configured_runtime transcript =
  let identity =
    Masc_tui_keeper_chat_transcript.runtime_identity ~keeper_name ~configured_runtime
      transcript
  in
  let configured = "configured: " ^ identity.Masc_tui_keeper_chat_transcript.configured in
  match identity.Masc_tui_keeper_chat_transcript.observed with
  | Some (Masc_tui_keeper_chat_transcript.Turn_runtime runtime) ->
    "turn: " ^ runtime ^ " \xc2\xb7 " ^ configured
  | Some (Masc_tui_keeper_chat_transcript.Stream_model model) ->
    "model: " ^ model ^ " \xc2\xb7 " ^ configured
  | None -> configured
