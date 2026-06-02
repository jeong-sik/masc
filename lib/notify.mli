(** Notify — macOS native notification bridge.

    terminal-notifier with osascript fallback. Sends native macOS notifications
    for MASC events with per-agent emoji.

    @since 0.1.0 *)

(** {1 Types} *)

type event =
  | Mention of { from_agent : string; target_agent : string option; message : string }
  | Interrupt of { agent : string; action : string }
  | PortalMessage of { from_agent : string; target_agent : string option; message : string }
  | TaskCompleted of { agent : string; task_id : string }
  | Custom of { title : string; subtitle : string; message : string }

type focus_payload = {
  target_agent : string option;
  from_agent : string option;
  task_id : string option;
}

(** {1 Core Send} *)

val send_notification :
  ?sound:bool -> ?focus_cmd:string ->
  title:string -> subtitle:string -> message:string -> unit -> unit

val notify : event -> unit

(** {1 Convenience} *)

val notify_mention :
  ?target_agent:string -> from_agent:string -> message:string -> unit -> unit
val notify_portal :
  ?target_agent:string -> from_agent:string -> message:string -> unit -> unit
val notify_task_done : agent:string -> task_id:string -> unit

(** {1 Helpers} *)

val sanitize_token : string -> string
val token_value : string option -> string
val is_truthy : string -> bool
val escape_shell : string -> string
val escape_applescript : string -> string
val render_focus_template : string -> focus_payload -> string
val agent_emoji : string -> string
val register_agent_emoji : string -> string -> unit
