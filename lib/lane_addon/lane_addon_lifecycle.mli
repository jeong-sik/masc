(** Typed facts about the container engine that holds an Add-on's worker, and
    the lifecycle state the runtime keeps for it. Pure: no I/O. *)

(** The engine a container was created on. Docker reports an engine ID; the
    Apple [container] runtime reports the application data root its API server
    stores containers under. Two engines are the same engine only when these
    are equal. *)
type engine = Docker_engine of string | Apple_app_root of string

(** Why the engine cannot say who it is. [Unreachable] is decided by the exit
    status of the identity command alone; [Identity_unreadable] means the
    command succeeded and printed something that is not an identity. Neither
    carries a meaning parsed out of an error message. *)
type engine_fault =
  | Unreachable of string
  | Identity_unreadable of string

val engine_equal : engine -> engine -> bool
val engine_to_string : engine -> string
val engine_to_json : engine -> Yojson.Safe.t
val engine_of_json : Yojson.Safe.t -> (engine, string) result
type authority =
  | Container_authority of { runtime : Lane_addon_types.runtime; engine : engine }
  | Native_admission of { installation_id : string }
(** Retained before creating a container or launching a native payload. Native
    claim paths are recomputed by the host from its store and installation key. *)
type resource =
  | Container_resource of string
  | Native_resource of { pid : int; started : string option }
val authority_to_json : authority -> Yojson.Safe.t
val authority_of_json : Yojson.Safe.t -> (authority, string) result
val resource_to_json : resource -> Yojson.Safe.t
val resource_of_json : Yojson.Safe.t -> (resource, string) result
val resource_to_string : resource -> string
val container_id : resource -> string option

(** The engine a later command reached when it was not the recorded one. *)
type observed_engine =
  | Other_engine of engine
  | Unreadable_engine of string

(** The container that holds a worker slot, as its labels name it. [instance]
    is the worker incarnation that created it and [state_owner] the persistent
    state owner it was created for; either is [None] when the label is absent. *)
type holder = {
  container_id : string;
  instance : string option;
  state_owner : string option;
}

(** Why a worker or its cleanup cannot proceed. The variant, not the text,
    decides whether the runtime retries ({!heal}); the string is for people. *)
type failure =
  | Engine_unreachable of string
  | Engine_mismatch of { recorded : engine; observed : observed_engine }
      (** The command reached an engine other than the one that holds the
          container, so its answer says nothing about that container. *)
  | Slot_foreign of holder
      (** The slot's container is not this worker's and is not a dead
          predecessor of it: another owner, or an instance still live in this
          process. It is never removed. *)
  | Slot_predecessor_unremovable of { instance_id : string; detail : string }
      (** A dead predecessor holds the slot and its removal was not confirmed. *)
  | Worker_failed of string
  | Cleanup_unconfirmed of string
  | Persistence_failed of string
  | Previous_process
      (** A non-terminal record left by an earlier server process. The
          configuration pass cleans it through its recorded engine whether or
          not a declaration still names it, and a declaration waits for that
          cleanup before it attaches again. An explicit Detach does the same on
          request and then removes the declaration; nothing waits for it. *)
  | Effect_outcome_unknown of string

(** [cause] is the failure the runtime acts on now. [first] is the failure that
    began the sequence, kept when a later attempt (usually the cleanup after a
    failed start) fails for a different reason, so that the original cause is
    never replaced by its own cleanup. *)
type failed = { cause : failure; first : failure option }

(** What a confirmed release stands on. [Never_created] requires no recorded
    execution authority and no resource. [Released] names the recorded engine
    that confirmed container absence. [Native_released] names the exact
    installation and incarnation whose admission is retired and settled.
    [Native_retained] names one whose admission settled but whose resources
    the host could not confirm released: the operator took them over. *)
type release =
  | Never_created
  | Released of { engine : engine; container_id : string option }
  | Native_released of { installation_id : string; instance_id : string }
      (** Native retirement and actual admission settlement were confirmed. *)
  | Native_retained of { installation_id : string; instance_id : string }
      (** Native retirement and admission settlement were confirmed. The
          resources the host could not confirm released stay where they are;
          the host never removes them. *)

(** [Detaching] keeps the failure that was in place when the detach began. *)
type state =
  | Attached
  | Observing
  | Failed of failed
  | Detaching of failed option
  | Detached of release

(** What a waiting failure needs before another attempt is worth making. *)
type condition =
  | Engine_reachable
  | Engine_is of engine
  | Holder_changes of holder
      (** The container that holds the slot is gone or no longer carries the
          labels it had. *)

type heal =
  | Retry  (** Another attempt can succeed without anything else changing. *)
  | Wait_until of condition
      (** Repeating the attempt would only repeat the refusal. *)

val heal : failure -> heal
(** The single place that decides retry or wait for every failure. *)

val failed : failure -> failed
val fail_again : failed -> failure -> failed
(** A later attempt failed: [cause] is replaced and the earliest different
    cause is kept as [first]. *)

val release_to_json : release -> Yojson.Safe.t
val release_of_json : Yojson.Safe.t -> (release, string) result

val failure_to_string : failure -> string
val failure_detail : failure -> string
(** The reason without the context [failure_to_string] adds, for events that
    already name their own context. *)
val failed_to_string : failed -> string
val failure_to_json : failure -> Yojson.Safe.t
val failure_of_json : Yojson.Safe.t -> (failure, string) result

val project : state -> Lane_addon_types.phase
(** The display phase of a state. It is derived and never read back. *)

val state_to_json : state -> Yojson.Safe.t
val state_of_json : Yojson.Safe.t -> (state, string) result
(** Strict: a record that does not carry the current shape is an error, so an
    older record surfaces as unreadable instead of being reinterpreted. *)
