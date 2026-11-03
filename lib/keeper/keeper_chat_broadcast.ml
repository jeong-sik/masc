(** SSE broadcast helper for keeper chat persistence events.

    Mirrors [Keeper_registry_broadcast]: a pure side-effect wrapper
    around [Sse.broadcast] with a failure counter + WARN log. *)

let audio_clip_to_json (clip : Keeper_chat_types.audio_clip) =
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

let chat_appended ~keeper_name ?connector ?audio () =
  try
    (* Field is named [connector], not [source]: the dashboard SSE
       vocabulary already reserves [source] for the journal origin
       (JournalSource), and the chat JSONL's own [source] column is a
       different boundary. [audio] is a separate boundary (RFC-0235): only
       present when the row carries a synthesized clip, and the dashboard
       decodes it into a typed record at the SSE edge. *)
    let fields =
      [ ("type", `String "keeper_chat_appended");
        ("name", `String keeper_name);
        ("ts_unix", `Float (Time_compat.now ()));
      ]
    in
    let fields =
      match connector with
      | None -> fields
      | Some connector -> fields @ [ ("connector", `String connector) ]
    in
    let fields =
      match audio with
      | None -> fields
      | Some clip -> fields @ [ ("audio", `Assoc (audio_clip_to_json clip)) ]
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


let operation_event_to_json ~keeper_name ~operation_id ~seq ~event =
  let seq_fields =
    match seq with
    | None -> []
    | Some seq -> [ "seq", `Int seq ]
  in
  `Assoc
    ([ "type", `String "keeper_chat_operation_event"
     ; "name", `String keeper_name
     ; "operation_id", `String operation_id
     ; "ag_ui_event", Ag_ui.event_to_json event
     ; "ts_unix", `Float (Time_compat.now ())
     ]
     @ seq_fields)
;;

let operation_event ~base_path ~keeper_name ~operation_id ~seq ~event =
  try
    Sse.broadcast_to
      (Sse.Runtime_observers (Sse.runtime_authority_exn ~base_path))
      (operation_event_to_json ~keeper_name ~operation_id ~seq ~event)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name; "site", "chat_operation_event" ]
      ();
    Log.Keeper.warn
      "keeper_chat_broadcast: operation_event name=%s operation_id=%s failed: %s"
      keeper_name
      operation_id
      (Printexc.to_string exn)
;;
