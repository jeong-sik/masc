(* See .mli for high-level shape. *)

module Gw = Discord_gateway_client
module State = Channel_gate_discord_state

(* Intents requested at IDENTIFY time. Same set as RFC-0203 §Modules
   and the previous sidecar configuration. *)
let default_intents : Gw.intent list =
  [ Gw.Guilds
  ; Gw.Guild_messages
  ; Gw.Message_content
  ; Gw.Guild_message_reactions
  ; Gw.Direct_messages
  ; Gw.Direct_message_reactions
  ]

(* ---------------------------------------------------------------- *)
(* Env-driven config                                                *)
(* ---------------------------------------------------------------- *)

let trimmed_env name =
  match Sys.getenv_opt name with
  | None -> None
  | Some raw ->
    let t = String.trim raw in
    if String.equal t "" then None else Some t

let bot_token_opt () = trimmed_env "DISCORD_BOT_TOKEN"

(* Trigger policy parser. Closed match — adding a new variant breaks
   compile at every call site rather than silently falling through. *)
let parse_trigger_policy raw : Gw.trigger_policy =
  let s = String.trim raw in
  if String.equal s "" then Gw.Mention_only
  else
    match s with
    | "mention_only" -> Gw.Mention_only
    | "all" -> Gw.All
    | other ->
      let prefix = "user_only:" in
      let plen = String.length prefix in
      if String.length other > plen
         && String.equal (String.sub other 0 plen) prefix
      then
        let id = String.trim (String.sub other plen (String.length other - plen)) in
        if String.equal id "" then Gw.Mention_only else Gw.User_only id
      else Gw.Mention_only

let resolved_trigger_policy () =
  match trimmed_env "MASC_DISCORD_TRIGGER_POLICY" with
  | None -> Gw.Mention_only
  | Some raw -> parse_trigger_policy raw

(* ---------------------------------------------------------------- *)
(* Inbound delivery                                                 *)
(* ---------------------------------------------------------------- *)

let handle_message_create ~dispatch
      ~(channel_id : string) ~(message_id : string)
      ~(author_id : string) ~(author_name : string option)
      ~(content : string) =
  match State.keeper_for_channel ~channel_id with
  | None ->
    (* No binding for this channel — drop quietly. The bot may be in
       channels it isn't bound to (e.g. server-wide guild messages). *)
    ()
  | Some keeper_name ->
    let msg : Channel_gate.inbound_message =
      { channel = State.channel
      ; channel_user_id = author_id
      ; channel_user_name = Option.value author_name ~default:author_id
        (* Display name ([global_name] else [username], RFC-0223 P1);
           the snowflake stands in only for malformed payloads missing
           both, keeping the gate's required field non-empty. *)
      ; channel_workspace_id = channel_id
      ; keeper_name
      ; content
      ; idempotency_key = Printf.sprintf "discord-msg-%s" message_id
      ; metadata = []
      }
    in
    (match Channel_gate.handle_inbound ~dispatch msg with
     | Error gate_err ->
       Log.Server.warn "discord inbound -> keeper failed (channel=%s keeper=%s): %s"
         channel_id keeper_name
         (Channel_gate.gate_error_to_string gate_err)
     | Ok out ->
       if String.equal out.content "" then ()
       else
         (match State.send_message ~channel_id ~content:out.content with
          | Ok _ -> ()
          | Error e ->
            Log.Server.error "discord send_message failed (channel=%s): %s"
              channel_id
              (Format.asprintf "%a" State.pp_send_error e)))

let on_event ~dispatch (ev : Gw.gateway_event) =
  match ev with
  | Gw.Ready { bot_user_id; _ } ->
    Log.Server.info "Discord gateway READY (bot_user_id=%s)" bot_user_id
  | Gw.Message_create
      { channel_id; message_id; author_id; author_name; content;
        mentions_bot = _ } ->
    (* mentions_bot is already enforced by the trigger policy at the
       gateway-state layer; nothing extra to check here. *)
    handle_message_create ~dispatch ~channel_id ~message_id ~author_id
      ~author_name ~content
  | Gw.Reaction_add _ ->
    (* The previous Python sidecar used a configurable emoji
       trigger to drain pending messages. That feature is dropped in
       the in-process gateway; re-add as a follow-up if needed. *)
    ()
  | Gw.Ignored _ ->
    ()

(* ---------------------------------------------------------------- *)
(* Start                                                            *)
(* ---------------------------------------------------------------- *)

let start ~sw ~env ~clock ~state =
  match bot_token_opt () with
  | None ->
    Log.Server.warn
      "RFC-0203: DISCORD_BOT_TOKEN is unset; in-process Discord gateway not started"
  | Some token ->
    let policy = resolved_trigger_policy () in
    let dispatch =
      Gate_keeper_backend.dispatch
        ~sw ~clock
        ~proc_mgr:state.Mcp_server.proc_mgr
        ~net:state.Mcp_server.net
        ~config:state.Mcp_server.workspace_config
    in
    let policy_label =
      match policy with
      | Gw.Mention_only -> "mention_only"
      | Gw.All -> "all"
      | Gw.User_only _ -> "user_only:<id>"
    in
    Log.Server.info
      "RFC-0203: starting in-process Discord gateway (policy=%s, intents=%d)"
      policy_label
      (Gw.intents_bitmask default_intents);
    Eio.Fiber.fork ~sw (fun () ->
      try
        Gw.run
          ~sw ~env ~token
          ~intents:default_intents
          ~trigger_policy:policy
          ~on_event:(on_event ~dispatch)
          ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Server.error
          "RFC-0203: in-process Discord gateway crashed: %s"
          (Printexc.to_string exn))
