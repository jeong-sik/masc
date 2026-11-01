(** Reclamation of retired keepers' Apple volumes: report first, delete on
    request.

    The claims marker ({!Keeper_sandbox_microvm}) answers which workspaces
    still want a keeper's volumes. This module turns one volume listing into
    per-keeper verdicts and, only when the caller asks, deletes the volumes
    of the keepers no evidence protects. Every unreadable answer keeps the
    volumes and is reported as its reason, so an operator sees why a keeper
    was or was not reclaimed. All effects run through the injected [run];
    [registered_keeper] answers the local-registration question so this
    module touches no filesystem. *)

(** Which of a keeper's two volumes a listed name is. *)
type volume_role =
  | Work_role
  | Build_role

(** One listed name. A name is this module's only when the remainder after
    its prefix regenerates it through {!Keeper_sandbox_microvm.work_volume_name}
    or {!build_volume_name}; anything else is foreign and never judged. *)
type listed_volume =
  | Masc_keeper_volume of
      { role : volume_role
      ; volume_name : string
      ; keeper_name : string
      }
  | Foreign_volume of string

val masc_keeper_volume_of_name : string -> listed_volume

(** Why a keeper's volumes are not reclaim candidates. [Unverified] keeps
    them too: an answer this module could not read is never read as "no
    owner". *)
type keep_reason =
  | Referenced_by_containers of string list
        (** A live or stopped guest, or a volume helper, still names this keeper. *)
  | Claimed_by_workspaces of string list
        (** The work volume's claims marker still names these base paths. *)
  | Registered_in_this_workspace
        (** This workspace still declares the keeper in its config. *)
  | Unverified of string
        (** A listing, marker read or registration question that failed. *)

type keeper_outcome =
  | Kept of keep_reason
  | Reclaim_candidate
  | Reclaimed
        (** Only after [~execute:true] and a removal whose absence check
            confirmed both volumes gone. *)
  | Reclaim_failed of string

type keeper_verdict = private
  { keeper_name : string
  ; work_volume : string option
  ; build_volume : string option
  ; outcome : keeper_outcome
  }

type report =
  { foreign_volumes : string list
        (** Listed names that are not this product's keeper volumes. *)
  ; keepers : keeper_verdict list
  }

val apple_keeper_volume_gc :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string)
  -> timeout_sec:float
  -> registered_keeper:(string -> bool)
  -> claims_image:string option
        (** The image the claims read helper runs on. [None] skips every
            marker read and keeps the unowned-and-unregistered keepers as
            [Unverified]: without a marker read there is no claim evidence
            either way. *)
  -> execute:bool
  -> (report, string) result
(** List the Apple volumes, group them by keeper, and judge each keeper:
    a container still referencing it keeps it; so do remaining claimants on
    the work volume's marker and a registration in this workspace. The rest
    are reclaim candidates, and with [~execute:true] their work and build
    volumes are deleted through
    {!Keeper_sandbox_microvm.remove_apple_keeper_volumes}, whose absence
    check decides [Reclaimed] versus [Reclaim_failed]. Without [execute] no
    volume is touched. A failed volume listing is [Error] and nothing runs. *)

val keep_reason_to_string : keep_reason -> string
val keeper_outcome_to_string : keeper_outcome -> string
