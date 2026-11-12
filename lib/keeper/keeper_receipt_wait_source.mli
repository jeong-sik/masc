(** The schedule a receipt wait can name instead of a background run.

    A wait names an id. A background run's id is a [Keeper_msg_async] request
    id. A schedule's id is its [schedule_id], the one [masc_schedule_create]
    returns. An edit and a settled run watch keep it. Its receipt is the one a
    Keeper wake of delivery [receipt] writes ({!Keeper_schedule_receipt}). This
    module reads the schedule row under such an id. The row is the only record
    of the schedule: the wait keeps none. *)

type schedule_row =
  | Row_waiting
      (** A wake of this Keeper that delivers a receipt and has not ended. *)
  | Row_ended
      (** The same, ended: delivered, failed, cancelled or expired. It may or
          may not have written its receipt. *)
  | Row_delivers_to_queue
      (** A wake of this Keeper whose delivery is [queue]. It never writes a
          receipt. *)
  | No_row
      (** No wake of this Keeper has this schedule id. *)

val find_schedule :
  base_path:string ->
  keeper_name:string ->
  string ->
  (schedule_row, string) result
(** [Error] when the schedule store cannot be read or the row's payload does
    not decode. *)
