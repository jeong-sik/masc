(** Notify — macOS desktop notification for a keeper mention.

    Posted through terminal-notifier when it is on [PATH], otherwise through
    osascript; a host with neither posts nothing and starts no process. The
    notifier is found by scanning [PATH], not by spawning a probe, and it is
    the only process this module runs.

    The post is a projection on the keeper's masc_broadcast tool call, and a
    tool call keeps the turn's no-progress watchdog off, so the spawn is
    bounded by {!notifier_timeout_sec}: a notifier that does not return is
    stopped and logged, and the tool call completes as if the notification
    had failed, which is all that happened. *)

(** {1 Types} *)

type focus_payload = {
  target_agent : string option;
  from_agent : string option;
  task_id : string option;
}

(** {1 Send} *)

val notifier_timeout_sec : float
(** Wall-clock bound on the one notifier process, in seconds. Measured posts
    take under half a second; the bound exists for the notifier that never
    returns, such as one blocked on a permission dialog. *)

val notify_mention :
  ?target_agent:string -> from_agent:string -> message:string -> unit -> unit
(** Post "@from_agent mentioned you" with [message] as the body. Returns when
    the notifier has exited or its bound has passed; every failure is a log
    line and none reaches the caller, except Eio cancellation, which is
    re-raised. *)

(** {1 Helpers} *)

val sanitize_token : string -> string
val token_value : string option -> string
val is_truthy : string -> bool
val escape_shell : string -> string
val escape_applescript : string -> string
val render_focus_template : string -> focus_payload -> string
val agent_emoji : string -> string
val register_agent_emoji : string -> string -> unit
