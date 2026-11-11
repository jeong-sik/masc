(** What the server's storage cleanup last did for each Keeper.

    The cleanup loop keeps this value in memory and publishes it on the
    dashboard tools envelope. Nothing here is stored. A restarted server
    starts from [empty] and its first pass fills the rows again. The durable
    record stays the server log, and for the guest build step the audit log.

    Design: [docs/rfc/RFC-storage-cleanup-steps-come-from-one-list-and-leave-a-result.md]. *)

type builds =
  { cleaned : int  (** Guest [_build] directories cleaned. *)
  ; failed : int  (** Guest [_build] directories whose clean failed. *)
  }

type workspace =
  { removed : int  (** Workspace entries removed. *)
  ; skipped : int  (** Entries judged and left in place. *)
  ; failed : int  (** Entries whose removal failed. *)
  ; freed_kib : int
  (** Free space on the endpoint after the sweep minus before it. Other
      writers move it too, so it can be negative. *)
  ; available_kib : int  (** Free space on the endpoint after the sweep. *)
  }

(** How one step ended for one Keeper. *)
type 'report outcome =
  | Reclaimed of 'report
  (** The payload ran to its end. A run that removed nothing is still this,
      and so is a run that could not remove some of what it judged: the
      report counts those. *)
  | Deferred of string
  (** The Keeper was busy, so nothing was sent. The text is the Owner's
      reason. *)
  | Not_running
  (** There was no running guest to attach to. Nothing was sent. *)
  | Failed of string
  (** Anything else, in the step's own words. No code branches on the text. *)

(** One step's result for one Keeper. Each step carries its own report. *)
type attempt =
  | Guest_builds of builds outcome
  | Remote_workspace of workspace outcome

val step : attempt -> Keeper_cleanup_step.t

type row =
  { keeper : string
  ; attempt : attempt  (** The latest attempt of this step for this Keeper. *)
  ; finished_at : float  (** When that attempt ended. *)
  ; reclaimed_at : float option
  (** When this step last ended [Reclaimed] for this Keeper, the latest
      attempt included. It is kept as long as the row is: a pass that does
      not choose the step drops the row and this time with it. *)
  }

(** Why a pass chose no step for a Keeper. *)
type exclusion =
  | Without_meta  (** No meta is stored for it yet. *)
  | Unreadable of string
  (** Its declaration could not be read. The text says why. *)
  | No_step  (** Nothing in the step list cleans its sandbox. *)
  | Switched_off  (** Every step that applies to it is switched off. *)

(** What one pass did with one Keeper. *)
type disposition =
  | Excluded of exclusion
  | Scheduled of Keeper_cleanup_step.t list  (** Its steps were started. *)
  | Still_running of Keeper_cleanup_step.t list
  (** Its steps were chosen, and its earlier attempt had not returned. *)

(** One Owner a pass looked at. *)
type owner =
  | Unnamed
  (** The Owner holds no meta yet, so it has no name. Counted in
      [without_meta]. *)
  | Named of string * disposition

type step_pass =
  { step : Keeper_cleanup_step.t
  ; enabled : bool  (** The step's switch when the pass started. *)
  ; selected : int  (** Keepers the pass chose this step for. *)
  }

type unreadable =
  { keeper : string
  ; reason : string
  }

(** The latest pass over the Keepers. Every Keeper it looked at is counted
    once: [owners] is the sum of [without_meta], [no_step], [switched_off],
    [scheduled] and the lengths of [unreadable] and [still_running]. *)
type pass =
  { started_at : float
  ; interval_sec : float  (** The pass interval in force when it started. *)
  ; owners : int  (** Keepers the pass looked at. *)
  ; without_meta : int
  ; unreadable : unreadable list
  ; no_step : int
  ; switched_off : int
  ; scheduled : int  (** Keepers whose steps it started. *)
  ; still_running : string list
  (** Keepers left alone because their earlier attempt had not returned. *)
  ; steps : step_pass list  (** One per step, in the order of the step list. *)
  }

type t =
  { pass : pass option  (** [None] until the first pass after a start. *)
  ; rows : row list  (** One row per Keeper and step, in no promised order. *)
  }

val empty : t

val conclude_pass :
  started_at:float ->
  interval_sec:float ->
  enabled:(Keeper_cleanup_step.t -> bool) ->
  owner list ->
  pass * (t -> t)
(** The summary of a pass that looked at these Owners, and the change that
    records it. Both come from the one list. The change keeps only the rows
    of a Keeper and step the pass chose: the rows of a Keeper that left,
    whose profile changed, or whose step was switched off are dropped. An
    attempt that was still running when its row was dropped writes the row
    again when it ends, and the next pass applies the same rule to it. *)

val record_attempt : keeper:string -> finished_at:float -> attempt -> t -> t
(** Replaces the row of the same Keeper and step. [reclaimed_at] becomes
    [finished_at] for a [Reclaimed] attempt and keeps its earlier value
    otherwise. *)

val envelope_field : string
(** The dashboard tools envelope field that carries this value. *)

val to_json : t -> Yojson.Safe.t
