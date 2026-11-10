(* HIGH-RISK-UNREVIEWED: this module turns the accounts of an installation off.
   After it, a boot keeps the records of the accounts read-only, and nothing in
   this build turns them on again. *)

(** [Off] (design 10.5, plan F3a-2): the host-local operation that turns the
    accounts of an installation off. It writes one record, a
    {!Authz_mode_event} of the event [Off] for the workspace of the bootstrap,
    by the local operator, through the zone, so the external store answers it
    as it answers every record ({!Authz_zone.commit}).

    After it, a boot whose config does not ask for [Multi_account] starts a
    single user that keeps the records of the accounts read-only (design 5.1,
    row 4). A config that asks for [Multi_account] is a reactivation, which
    this build refuses (row 9). The config is not written: it is a request of
    the operator (design 5.1).

    {b When it writes.} The log made [Multi_account] and the external store
    matches it. The config and the auth settings do not matter: an operator
    who took [account_mode] out first meets a boot that refuses (row 3), and
    turns the accounts off from there. A store that does not match would leave
    a boot that refuses after the Off (row 10), so nothing is written over it.

    It knows the files and nothing about the process around them. The caller
    holds the BasePath lease, so no server and no other writer runs on the base
    path, and calls it from an Eio fiber, because the zone is an
    [Eio.Mutex]. *)

type error =
  | Never_activated  (** The log holds no mode event. Nothing was written. *)
  | Already_off  (** The last mode event is [Off]. Nothing was written. *)
  | Log_unreadable of string  (** The log cannot be read. Nothing was written. *)
  | Store_absent
      (** The log made [Multi_account] and the external store holds no answer:
          its install record or its file is gone. Nothing was written. *)
  | Store_mismatch of Authz_high_water.reason * Authz_high_water.reason list
      (** The external store does not match the log. Nothing was written. *)
  | Store_unreadable of string
      (** The install record or the external store cannot be read. Nothing
          was written. *)
  | Zone_not_opened of Authz_zone.open_error  (** Nothing was written. *)
  | Mode_moved of Authz_mode_state.t
      (** The zone opened on a log that is no longer in [Multi_account], although
          the read before it found one. Nothing was written. *)
  | Body_not_built of Authz_body.error
      (** {!Authz_body} refused the body. Nothing was written. *)
  | Commit_failed of Authz_zone.error  (** As {!Authz_zone.commit} says. *)

val error_to_string : error -> string

(** Writes the [Off] of the installation of [base_path], whose install record
    [config_dir] holds, and returns its workspace. [now_ms] is the wall clock
    in milliseconds. *)
val turn_off
  :  base_path:string
  -> config_dir:string option
  -> now_ms:(unit -> int)
  -> (Authz_types.Workspace_id.t, error) result
