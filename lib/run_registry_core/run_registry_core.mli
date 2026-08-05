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

  val complete
    :  t
    -> id:string
    -> completion:Payload.completion
    -> [ `Completed | `Unknown ]

  val list_entries : t -> entry list
  val get : t -> id:string -> entry option
end
