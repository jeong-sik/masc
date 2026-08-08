(** Typed execution-cause validation and closed durable codec. *)

(** Opaque identity of the external event domain that owns a cause. The text
    form is accepted only at the construction/codec boundary; execution
    control must retain and compare the typed value instead of matching its
    diagnostic representation. *)
module External_source : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Make (Event_id : Execution_id.S) : sig
  type t =
    | Internal_event of Event_id.t
    | External_event of
        { source : External_source.t
        ; event_id : string
        }

  val validate_all : t list -> (unit, string) result
  val equal : t -> t -> bool
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, string) result
end
