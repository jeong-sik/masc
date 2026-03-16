(** Lodge Atmosphere — dynamic mood computation for agents.

    Provides mood signals for agent personality.
    Legacy API (get_value/get_description) preserved for backward compatibility.

    @since 2.49.0 (legacy), 3.0.0 (dynamic mood) *)

(** {1 Legacy API} *)

(** Get current atmosphere value (0.0 to 1.0, default 0.5) *)
val get_value : unit -> float

(** Get human-readable atmosphere description *)
val get_description : unit -> string

(** {1 Dynamic mood computation} *)

(** Compute mood from reaction ratio and activity level.
    [positive_ratio]: fraction of positive reactions (0.0-1.0).
    [activity_level]: recent board activity (0.0-1.0). *)
val compute_mood :
  positive_ratio:float -> activity_level:float -> Lodge_daemon.mood

(** Compute mood with default signals (time-of-day + jitter). *)
val compute_mood_default : unit -> Lodge_daemon.mood
