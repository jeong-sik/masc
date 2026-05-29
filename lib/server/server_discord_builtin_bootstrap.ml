(* RFC-0203 Phase 2 — boot wiring for the in-process Discord gateway. *)

let inbound_kind_of_event
  : Discord_gateway_client.gateway_event
    -> Discord_dual_run_stats.inbound_kind
  = function
  | Ready _ -> Ready
  | Message_create _ -> Message_create
  | Reaction_add _ -> Reaction_add
  | Ignored _ -> Ignored

let on_event ev =
  Discord_dual_run_stats.record_inbound
    ~path:Discord_dual_run_stats.Builtin
    (inbound_kind_of_event ev)

let start_if_enabled ~sw ~env =
  if not (Discord_builtin_config.builtin_enabled ()) then ()
  else
    match Discord_builtin_config.bot_token () with
    | None ->
      Log.Server.warn
        "RFC-0203: MASC_DISCORD_BUILTIN is on but DISCORD_BOT_TOKEN \
         is unset; in-process Discord gateway not started"
    | Some token ->
      let policy = Discord_builtin_config.trigger_policy () in
      let intents = Discord_builtin_config.intents in
      Log.Server.info
        "RFC-0203 dual-run: starting in-process Discord gateway \
         (intents=%d, policy=%s)"
        (Discord_gateway_client.intents_bitmask intents)
        (match policy with
         | Mention_only -> "mention_only"
         | User_only id -> "user_only:" ^ id
         | All -> "all");
      (* Fork into the server-wide switch. The gateway's [run] blocks
         until the switch is cancelled; on graceful shutdown that
         cancellation propagates through Discord_gateway_client's
         per-session [Switch] in connect/close, which is already
         wired to handle Eio.Cancel.Cancelled cleanly. *)
      Eio.Fiber.fork ~sw (fun () ->
        try
          Discord_gateway_client.run
            ~sw
            ~env
            ~token
            ~intents
            ~trigger_policy:policy
            ~on_event
            ()
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Server.error
            "RFC-0203: in-process Discord gateway crashed: %s"
            (Printexc.to_string exn))
