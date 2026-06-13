(** SSE broadcast helper for keeper chat persistence events.

    Mirrors [Keeper_registry_broadcast]: a pure side-effect wrapper
    around [Sse.broadcast] with a failure counter + WARN log. *)

let chat_appended ~keeper_name ~source =
  try
    (* Field is named [connector], not [source]: the dashboard SSE
       vocabulary already reserves [source] for the journal origin
       (JournalSource), and the chat JSONL's own [source] column is a
       different boundary. *)
    let json =
      `Assoc
        [ ("type", `String "keeper_chat_appended");
          ("name", `String keeper_name);
          ("connector", `String source);
          ("ts_unix", `Float (Time_compat.now ()));
        ]
    in
    Sse.broadcast json
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
