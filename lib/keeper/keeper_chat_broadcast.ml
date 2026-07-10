(** SSE broadcast helper for keeper chat persistence events.

    Mirrors [Keeper_registry_broadcast]: a pure side-effect wrapper
    around [Sse.broadcast] with a failure counter + WARN log. *)

(** Audio clip descriptor attached to a [keeper_chat_appended] event when
    the utterance was synthesized (RFC-0235 P1). [token] is the capability
    in the URL path [/api/v1/voice/audio/<token>]; the dashboard assembles
    the full URL from its own base. [message_text] doubles as the
    accessible caption/fallback. *)
type audio_clip = {
  token : string;
  audio_url : string option;
  mime : string;
  duration_sec : float option;
  message_text : string;
  device_id : string option;
  expired : bool;
}

let audio_clip_to_json (clip : audio_clip) =
  let base =
    [ ("token", `String clip.token)
    ; ("mime", `String clip.mime)
    ; ("message_text", `String (Observability_redact.redact_text clip.message_text))
    ]
  in
  let with_optional fields =
    fields
    |> fun fs ->
    (match clip.audio_url with
     | None -> fs
     | Some url -> fs @ [ ("audio_url", `String url) ])
    |> fun fs ->
    (match clip.duration_sec with
     | None -> fs
     | Some d -> fs @ [ ("duration_sec", `Float d) ])
    |> fun fs ->
    (match clip.device_id with
     | None -> fs
     | Some id -> fs @ [ ("device_id", `String id) ])
    |> fun fs ->
    if clip.expired then fs @ [ ("expired", `Bool true) ] else fs
  in
  with_optional base

let do_broadcast ~keeper_name ~source ~audio ?content () =
  try
    (* Field is named [connector], not [source]: the dashboard SSE
       vocabulary already reserves [source] for the journal origin
       (JournalSource), and the chat JSONL's own [source] column is a
       different boundary. [audio] is a separate boundary (RFC-0235): only
       present when this turn synthesized a clip, and the dashboard decodes
       it into a typed record at the SSE edge. [blocks] mirrors the
       backend parser output so the dashboard can prefer server-provided
       rich blocks over its local parser. *)
    let base_fields =
      [ ("type", `String "keeper_chat_appended");
        ("name", `String keeper_name);
        ("connector", `String source);
        ("ts_unix", `Float (Time_compat.now ()));
      ]
    in
    let fields =
      match audio with
      | None -> base_fields
      | Some clip -> base_fields @ [ ("audio", `Assoc (audio_clip_to_json clip)) ]
    in
    let blocks =
      match content with
      | None -> None
      | Some text ->
        let text = Observability_redact.redact_text text in
        let parsed = Keeper_chat_blocks.parse_text_to_blocks text in
        if parsed = [] then None else Some parsed
    in
    let fields =
      match blocks with
      | None -> fields
      | Some bs -> fields @ [ ("blocks", Keeper_chat_blocks.blocks_to_yojson bs) ]
    in
    Sse.broadcast (`Assoc fields)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ ("keeper", keeper_name); ("site", "chat_appended") ]
      ();
    Log.Keeper.warn
      "keeper_chat_broadcast: chat_appended name=%s failed: %s"
      keeper_name
      (Printexc.to_string exn)

(** Broadcast with no audio clip. [content] is optional; when supplied the
    backend parser turns it into rich chat blocks included in the SSE
    payload so the dashboard can render server-provided blocks. *)
let chat_appended ~keeper_name ~source ?content () =
  do_broadcast ~keeper_name ~source ~audio:None ?content ()

(** Broadcast with a synthesized audio clip attached (RFC-0235 P1). Used by
    a turn that owns a voice clip ([Voice_bridge_transport.make_audio_file]
    token); the dashboard decodes the [audio] field into a typed record and
    renders a play button. [content] is used to derive rich blocks for the
    event, mirroring {!chat_appended}. *)
let chat_appended_with_audio ~keeper_name ~source ~audio ?content () =
  do_broadcast ~keeper_name ~source ~audio:(Some audio) ?content ()

let queue_changed ~keeper_name ~depth () =
  try
    Sse.broadcast
      (`Assoc
        [ ("type", `String "keeper_chat_queue_changed");
          ("name", `String keeper_name);
          ("depth", `Int depth);
          ("ts_unix", `Float (Time_compat.now ()));
        ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ ("keeper", keeper_name); ("site", "queue_changed") ]
      ();
    Log.Keeper.warn
      "keeper_chat_broadcast: queue_changed name=%s failed: %s"
      keeper_name
      (Printexc.to_string exn)

