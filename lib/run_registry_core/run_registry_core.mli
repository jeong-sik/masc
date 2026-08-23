(** Shared current-state engine for bounded, append-only observation registries. *)

module Json : sig
  val object_fields
    :  Yojson.Safe.t
    -> ((string * Yojson.Safe.t) list, string) result

  val exact_fields
    :  required:string list
    -> ?optional:string list
    -> (string * Yojson.Safe.t) list
    -> (unit, string) result

  val string_field
    :  string
    -> (string * Yojson.Safe.t) list
    -> (string, string) result

  val float_field
    :  string
    -> (string * Yojson.Safe.t) list
    -> (float, string) result

  val optional_string_field
    :  string
    -> (string * Yojson.Safe.t) list
    -> (string option, string) result
end

module type Payload = sig
  type registration
  type completion

  val name : string
  val registration_to_yojson : registration -> Yojson.Safe.t
  val registration_of_yojson : Yojson.Safe.t -> (registration, string) result
  val completion_to_yojson : completion -> Yojson.Safe.t
  val completion_of_yojson : Yojson.Safe.t -> (completion, string) result
  val running_noun : string
  val restart_reason : string
  val completed_retention : [ `All | `Latest of int ]
end

type persistence_state =
  | Not_persisted
  | Durability_unknown

type persistence_failure =
  { detail : string
  ; state : persistence_state
  }

type cut_report =
  { lines_read : int
  ; malformed_lines : int
  ; retained_entries : int
  ; rewritten : bool
  }
(** What a deployment-time store cut read and what it kept. *)

module Make (Payload : Payload) : sig
  type status =
    | Running
    | Completed of Payload.completion

  type entry =
    { id : string
    ; started_at : float
    ; registration : Payload.registration
    ; status : status
    }

  type t

  val max_completed_retained : int
  val create : ?path:string -> unit -> t
  val replay : string -> t

  val register
    :  t
    -> id:string
    -> started_at:float
    -> registration:Payload.registration
    -> unit
(** Registry mutations and their JSONL events are serialized per [t], so a
    concurrent completion cannot overtake its registration on disk. *)

  val complete
    :  t
    -> id:string
    -> completion:Payload.completion
    -> [ `Completed | `Persistence_failed of persistence_failure | `Unknown ]
  (** Completion persistence is an observation-plane mutation. A durable
      append failure is returned explicitly with whether rollback established
      that it was not persisted or durability remains unknown. The in-memory
      entry remains [Running], so the caller chooses how to expose that failed
      observation without claiming a replayable completion. *)

  val list_entries : t -> entry list
  val get : t -> id:string -> entry option
  val cut_replay_log : execute:bool -> string -> cut_report
  (** Rewrites [path] from the rows the current decoders accept, dropping the
      rows they refuse. A hard-cut field leaves rows that can never decode
      again; [replay] declines to compact while any of them is on disk, so
      without this the store keeps them and its retention bound stops
      applying. [execute:false] measures and reports without writing. A file
      whose last line is unterminated is never rewritten — [rewritten] is
      [false] and the report still carries the counts. *)
end

(** Single-owner lifecycle for a process-wide registry. The first installation
    replaces the inert pre-boot registry; every later installation is rejected
    without changing the active registry. *)
module Global (Registry : sig
    type t

    val initial : t
  end) : sig
  type t = Registry.t
  type install_error = Already_installed

  val current : unit -> t
  val install : t -> (unit, install_error) result
end
