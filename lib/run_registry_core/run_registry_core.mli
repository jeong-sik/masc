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
end

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
    -> [ `Completed | `Unknown ]

  val list_entries : t -> entry list
  val get : t -> id:string -> entry option
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
