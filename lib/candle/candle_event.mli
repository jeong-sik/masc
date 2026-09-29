(** One row of [candle-ledger.jsonl] (RFC-goal-candle-ledger 3.1).

    A row is a flat JSON object: ["kind"], ["at"], then the fields of that kind.
    Reading is closed: an unknown kind, an unknown or missing or repeated field,
    a field of the wrong JSON kind and a value outside its type are all errors.
    A field with nothing to say is written as [null]; none is left out.

    The ledger records what happened. It does not compute. A kind is added by
    the change that first writes it, together with the readers that need it. *)

type body =
  | Snapshot of
      { goal_id : string
      ; request_id : string  (** The verification request that passed. *)
      ; criterion_revision : string
      ; passed_at : Candle_time.t  (** When the verifier's passing result was made. *)
      ; goal_created_at : Candle_time.t
      ; due_date : string option
            (** The Goal's due date exactly as the Goal held it, readable or
                not. The Goal's due-date reader (Goal_due) is the one place
                that says what it means, so the ledger does not interpret it. *)
      ; title : string
      ; metric : string option
      ; target_value : string option
      ; linked_task_ids : string list  (** The Tasks linked to the Goal when it passed. *)
      }

type t =
  { at : Candle_time.t
  ; body : body
  }

val kind : body -> string
(** The row's ["kind"]: [snapshot]. *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val to_line : t -> (string, string) result
(** One JSON line, without the newline. [Error] when the line would not read
    back, so an event that cannot be read never reaches an append-only file. *)

val of_line : string -> (t, string) result
