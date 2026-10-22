open Alcotest
module E = Masc.Keeper_chat_events
module Journal = Masc.Keeper_chat_event_log
module Live = Masc_tui_keeper_chat_live
module Log = Masc_tui_keeper_chat_log
module Transcript = Masc_tui_keeper_chat_transcript
module Media = Masc_tui_chat_media
module Projection = Server_keeper_chat_agui_projection

let media ?(generation=4) ?(scope=0) ?(index=0) ?(mime="image/png") reference : E.generated_media =
  {index; media_type=mime; source_type=Agent_core.Types.Base64; media_ref=reference;
   response={response_generation=generation; response_scope=scope}}

let wire event =
  let _, projected = Projection.project ~timestamp:12. ~redact_text:Fun.id Projection.initial event in
  match projected with
  | None -> fail "generated output did not reach the transport"
  | Some event -> Ag_ui.event_to_sse ~id:6 event

let test_wire_journal_and_chunked_replay () =
  let original = media ~generation:8 ~scope:3 ~index:2 "/api/v1/media/original" in
  let event = E.Agent_core_media_delta original in
  let journal = match Journal.keeper_chat_event_of_json (Journal.keeper_chat_event_to_json event) with
    | Error detail -> fail detail | Ok event -> Log.delta_of_journaled event in
  check bool "journal retains exact producer output" true (journal=Some (Live.Media original));
  let decoder = Live.create () in
  let received = wire event |> String.to_seq |> Seq.map (fun c -> Live.feed decoder (String.make 1 c))
    |> List.of_seq |> List.concat in
  check bool "byte-split transport retains original ownership, sequence and reference" true
    (List.map (fun (x : Live.observed_delta) -> x.seq,x.delta) received = [Some 6,Live.Media original]);
  let log = Log.create ~keeper_name:"image" ~request_id:"original" ~started_at:1. in
  check bool "first delivery persists in operation log" true (Log.add log ~seq:(Some 6) (Live.Media original));
  check bool "replay cannot add the same sequence again" false (Log.add log ~seq:(Some 6) (Live.Media original))

let test_malformed_media_has_no_ownership () =
  let original = E.generated_media_to_json (media "/api/v1/media/original") in
  let fields = Yojson.Safe.Util.to_assoc original in
  let replace key value = `Assoc ((key,value)::List.remove_assoc key fields) in
  let malformed =
    [ `Assoc (List.remove_assoc "response" fields)
    ; replace "response" `Null
    ; replace "response" (`Assoc ["content_generation",`Int 4])
    ; replace "response" (`Assoc ["content_generation",`Int 4;"stream_scope",`Int (-1)])
    ; `Assoc (("response",E.response_identity_to_json {response_generation=4;response_scope=0})::fields)
    ; `Assoc (("extra",`Bool true)::fields)
    ; replace "index" (`Int (-1)); replace "index" (`Float 0.)
    ; replace "source_type" (`String "unknown"); replace "media_ref" (`String " ") ] in
  List.iter (fun value ->
    check bool "shared decoder rejects invalid ownership" true (Result.is_error (E.generated_media_of_json value));
    check bool "strict stream validates the same shape" true
      (Result.is_error (Masc_tui_keeper_chat_projection.validate_custom_value ~name:"KEEPER_MEDIA_DELTA" value));
    let payload = `Assoc ["type",`String "CUSTOM";"name",`String "KEEPER_MEDIA_DELTA";"value",value] in
    let deltas = Live.feed (Live.create ()) ("data: " ^ Yojson.Safe.to_string payload ^ "\n\n") in
    check bool "malformed wire never becomes usable media" true
      (List.for_all (fun (x : Live.observed_delta) -> match x.delta with Live.Undecodable _ -> true | _ -> false) deltas
       && deltas <> [])) malformed

let current_media transcript = Transcript.trail transcript |> List.filter_map (function
  | Transcript.Trail_media media -> Some media | _ -> None)

let test_response_and_attempt_authority () =
  let transcript = Transcript.create ~keeper_name:"image" ~request_id:"original" ~started_at:1. in
  let apply delta = Transcript.apply ~now:2. transcript delta in
  let first = media "/api/v1/media/one" in
  apply (Live.Media first); apply (Live.Media first);
  check bool "same response block is retained once" true (current_media transcript=[first]);
  apply (Live.Stream_model_stopped (Some first.response));
  apply (Live.Media (media ~index:1 "/api/v1/media/closed"));
  let second = media ~scope:1 "/api/v1/media/two" in
  apply (Live.Media second);
  apply (Live.Media (media ~index:2 "/api/v1/media/stale"));
  check bool "closed and older responses cannot append" true (current_media transcript=[first;second]);
  check string "media metadata never becomes authored reply text" "" (Transcript.text transcript);
  apply (Live.Runtime_attempt_started {runtime_id=Some "next";attempt_index=Some 1});
  apply (Live.Media second);
  check bool "superseded response cannot borrow new attempt" true (current_media transcript=[]);
  check bool "previous attempt still retains original media evidence" true
    (List.exists (function Transcript.Trail_superseded {items;_} ->
       List.exists (function Transcript.Trail_media m -> m=first | _ -> false) items | _ -> false)
       (Transcript.trail transcript));
  let next = media ~generation:5 "/api/v1/media/next" in
  apply (Live.Media next); apply Live.Run_finished;
  apply (Live.Media (media ~generation:6 "/api/v1/media/terminal"));
  check bool "terminal operation rejects a new owner too" true (current_media transcript=[next])

let test_persisted_occurrence_coverage_and_playback () =
  let original = media "/api/v1/media/image" in
  let block = Media.of_generated original in
  let other = Media.Image {src="/api/v1/media/other";cap=None} in
  let blocks = [block;block;other] in
  let kept, previews, remaining = Media.without_drawn_generated ~covered:[original] blocks (Media.images blocks) in
  check bool "one observed block consumes one durable occurrence" true (kept=[block;other] && remaining=[]);
  check bool "image actions preserve uncovered occurrences" true (previews=Media.images kept);
  let more, _, _ = Media.without_drawn_generated ~covered:remaining [block] (Media.images [block]) in
  check bool "coverage cannot be reused on a subsequent row" true (more=[block]);
  let audio = media ~mime:"audio/wav" "/api/v1/media/audio" |> Media.of_generated in
  check bool "generated audio uses peer playback authority" true
    (match Media.newest_playable [audio] with
     | Some {source=`Server_path reference;_} -> reference="/api/v1/media/audio"
     | _ -> false)

let test_generated_midi_live_and_reload_playback () =
  let raw = "MThd\000\000\000\006\000\000\000\001\001\224"
    ^ "MTrk\000\000\000\016\000\192\032\000\144\060\064"
    ^ "\131\096\128\060\000\000\255\047\000" in
  let base_dir = Filename.temp_dir "generated_midi_" "" in
  List.iter (fun mime ->
    let accum = Keeper_stream_media_accum.create () in
    Keeper_stream_media_accum.on_event accum
      (Agent_core.Types.ContentBlockDelta {index=0; delta=MediaDelta
        {media_type=mime;source_type=Base64;data=Base64.encode_string raw}});
    Keeper_stream_media_accum.on_event accum (Agent_core.Types.ContentBlockStop {index=0});
    let blocks = Keeper_stream_media_accum.to_chat_blocks ~base_dir accum in
    let reference = match blocks with
      | [Masc.Keeper_chat_blocks.Attach {src=Some reference;mime_type=Some observed;_}]
          when String.equal mime observed -> reference
      | _ -> fail "generated MIDI lost its retained attachment source/type" in
    let original = media ~mime reference in
    let streamed = Live.feed (Live.create ()) (wire (E.Agent_core_media_delta original)) in
    let live = match streamed with
      | [{Live.delta=Live.Media observed;_}] -> Media.of_generated observed
      | _ -> fail "generated MIDI did not reach the live consumer" in
    let reloaded = Media.of_json (Masc.Keeper_chat_blocks.blocks_to_yojson blocks) in
    check bool "live and reload retain exactly the same MIDI source" true (reloaded=[live]);
    List.iter (fun values -> match Media.newest_playable values with
      | Some {kind=`Midi;source=`Server_path path;_} ->
          check string "MIDI playback reads the original peer source" reference path
      | _ -> fail "retained generated MIDI was skipped or routed to an audio player")
      [[live];reloaded];
    let token = Filename.basename reference in
    match Masc.Keeper_chat_media_store.file_path_of_token ~base_dir ~token with
    | None -> fail "generated MIDI source disappeared from the store"
    | Some path ->
        check string "served MIDI type stays canonical" "audio/midi"
          (Masc.Keeper_chat_media_store.content_type_of_path path);
        check string "stored MIDI keeps all original bytes" raw
          (In_channel.with_open_bin path In_channel.input_all))
    ["audio/midi";"audio/x-midi"]

let () = run "Generated media response ownership" ["transport",[
  test_case "wire journal and duplicate replay" `Quick test_wire_journal_and_chunked_replay;
  test_case "malformed media cannot acquire ownership" `Quick test_malformed_media_has_no_ownership];
  "operation",[test_case "response attempt and terminal ownership" `Quick test_response_and_attempt_authority;
  test_case "generated MIDI live and reload playback" `Quick test_generated_midi_live_and_reload_playback;
  test_case "durable occurrence coverage and peer playback" `Quick test_persisted_occurrence_coverage_and_playback]]
