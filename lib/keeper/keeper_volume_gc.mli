(** Reclamation of retired keepers' Apple volumes: report first, then delete
    only the keepers a request names.

    The claims marker ({!Keeper_sandbox_microvm}) records participating
    workspaces, but cannot exclude unrecorded owners. This module turns one
    volume listing into per-keeper verdicts. A missing or empty claims marker
    keeps a work volume. Every unreadable answer keeps the affected volumes
    and is reported as its reason, so an operator sees why a keeper
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
        (** A listing or marker that cannot establish safe ownership. *)

type keeper_outcome =
  | Kept of keep_reason
  | Reclaim_candidate
  | Reclaimed
        (** Only for a keeper [Reclaim_named] names, after a delete-time
            confirmation that the keeper is still build-only, and an absence
            check for the listed build volume. *)
  | Reclaim_failed of string

type keeper_verdict = private
  { keeper_name : string
  ; work_volume : string option
  ; build_volume : string option
  ; outcome : keeper_outcome
  }

(** What a call does after it judges the keepers. *)
type request =
  | Report_only
  | Reclaim_named of string list
      (** Keeper names, the unit a report's verdicts carry. A keeper is
          reclaimed only when this list names it and this call judges it a
          candidate again. A candidate the list does not name stays
          [Reclaim_candidate], and a named keeper that is no longer a
          candidate carries its new verdict. *)

type report =
  { foreign_volumes : string list
        (** Listed names that are not this product's keeper volumes. *)
  ; keepers : keeper_verdict list
  ; unlisted_keepers : string list
        (** Names [Reclaim_named] gave that no listed keeper volume belongs
            to. Nothing is deleted for them. Empty for [Report_only]. *)
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
  -> request:request
  -> (report, string) result
(** List the Apple volumes, group them by keeper, and judge each keeper:
    a container still referencing it keeps it; so do remaining claimants on
    the work volume's marker and a registration in this workspace. A work
    volume with a missing or empty marker is kept as [Unverified]. Unprotected
    build-only volumes without an observed reference are reclaim candidates.
    [Report_only] touches no volume. [Reclaim_named] deletes the build volume
    of a candidate it names and of no other keeper.
    A candidate is judged from one listing, which a concurrent boot in
    another workspace can already have outrun, so before a named candidate's
    delete the build-only shape is confirmed by a fresh listing: a keeper
    whose work volume has since appeared, whose listed build volume is gone,
    or whose confirmation listing cannot be read is kept as [Unverified] and
    nothing is deleted for it. Past that confirmation the fence is the
    platform, which refuses to delete a volume a container (running or
    stopped) references, and the absence check after the delete: a volume
    that remains is [Reclaim_failed], never [Reclaimed].
    A boot that lands between the confirmation and the delete can still fail
    loudly at container creation; it cannot lose a held volume silently.
    A failed initial volume listing is [Error] and nothing runs. *)

val keep_reason_to_string : keep_reason -> string
val keeper_outcome_to_string : keeper_outcome -> string
