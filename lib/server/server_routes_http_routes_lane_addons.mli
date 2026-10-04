(** Optional Lane Add-on views and asynchronous lifecycle operations.
    Read handlers never wait for an observation worker. *)
val add_routes : sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t -> Http_server_eio.Router.t -> Http_server_eio.Router.t

val decode_body : string -> (Yojson.Safe.t, string) result
val decode_slice_query : (string * string) list -> (Yojson.Safe.t, string) result

val decode_inspect_query : (string * string) list -> (Yojson.Safe.t, string) result

val broadcast_principal_for_standing :
  Server_auth.request_credential_standing -> string -> (string, string) result
(** A Broadcast journal identity comes only from an authenticated credential's
    canonical actor, never a caller-supplied header or a bearer fingerprint. *)

(** A spectator's last mark: the change count it read and the incarnation it
    read it under. *)
type since = { count : int; incarnation : string }

val decode_live_query :
  (string * string) list -> (Machine_lane.t * since option, string) result
(** [source_kind] (required), read as the machine whose screen it captures
    ([msx_capture], [dos_capture]), and [since] with [incarnation] (optional, always
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

type screen_publication = since Machine_live_publication.t
val answer_from_publication :
  Machine_lane.t -> since:since option -> screen_publication -> live_answer
(** Both machine kinds use the same rule: [Running] always needs a locked read,
    even when its last published mark equals [since]. *)

val live_from_published_mark : Machine_lane.t -> since:since option -> live_answer
(** The first step of [GET /api/v1/lane-addons/live]. It reads the machine's
    published state without taking the machine lock and never suspends.
    [Running] goes to the locked read to observe the completed run. *)

val query_fields : Httpun.Request.t -> (string * string) list
(** Preserve repeated query values so both transports reject duplicates. *)

val package_catalog_payload : Mcp_server.server_state -> (string * string) list ->
  (Yojson.Safe.t, string) result
val package_preview_payload : Mcp_server.server_state -> (string * string) list ->
  (Yojson.Safe.t, string) result
(** Shared H1/H2 payloads. The transport applies its read-auth gate before
    calling these filesystem readers. *)
