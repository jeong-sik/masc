(** Optional Lane Add-on views and asynchronous lifecycle operations.
    Read handlers never wait for an observation worker. *)
val add_routes : sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t -> Http_server_eio.Router.t -> Http_server_eio.Router.t

val decode_body : string -> (Yojson.Safe.t, string) result
val decode_slice_query : (string * string) list -> (Yojson.Safe.t, string) result

val decode_inspect_query : (string * string) list -> (Yojson.Safe.t, string) result

(** The source kinds [GET /api/v1/lane-addons/live] can watch: the ones with a
    machine screen behind them ([msx_capture], [dos_capture]). *)
type screen_source = Msx_screen | Dos_screen

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

