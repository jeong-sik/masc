(** Optional Lane Add-on views and asynchronous lifecycle operations.
    Read handlers never wait for an observation worker. *)
val add_routes : sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t -> Http_server_eio.Router.t -> Http_server_eio.Router.t

val decode_body : string -> (Yojson.Safe.t, string) result
val decode_slice_query : (string * string) list -> (Yojson.Safe.t, string) result

val decode_inspect_query : (string * string) list -> (Yojson.Safe.t, string) result

(** The source kinds [GET /api/v1/lane-addons/live] can watch: the ones with a
    machine screen behind them ([msx_capture], [dos_capture]). *)
type screen_source = Lane_addon_sources.live_reader = Msx_screen | Dos_screen

(** A spectator's last mark: the change count it read and the incarnation it
    read it under. *)
type since = { count : int; incarnation : string }

val decode_live_query :
  (string * string) list -> (screen_source * since option, string) result
(** [source_kind] (required), and [since] with [incarnation] (optional, always
    together: a nonnegative decimal change count and the incarnation it was
    read under). A kind with no screen ([snapshot_file], [lane_output],
    [browser_document]), an unknown kind, an unknown or repeated parameter, a
    [since] that is not decimal digits, and [since] or [incarnation] alone are
    errors. *)

(** What a live read can say from the published mark alone. *)
type live_answer =
  | Answered of Yojson.Safe.t
      (** No machine, or a [since] that still names the current mark
          ([state] ["unchanged"]). *)
  | Needs_locked_read
      (** The mark moved, no [since] was given, or the machine is running:
          the frame has to be copied under the machine lock. *)

val dos_answer_from_publication :
  since:since option -> Dos_lane.published_state -> live_answer
(** A running DOS machine always needs a locked read, even when its last
    stable mark equals [since]. *)

val live_from_published_mark : screen_source -> since:since option -> live_answer
(** The first step of [GET /api/v1/lane-addons/live]. It reads the machine's
    published state without taking the machine lock and never suspends.
    [Running] goes to the locked read to observe the completed run. *)
