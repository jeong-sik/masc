(** The Info tab's month of Keeper efficiency.

    One read of [GET /api/v1/keeper-efficiency?month=YYYY-MM] answers every
    Keeper of the month, so the reading is keyed by the month: the Info tab of
    any Keeper shows that Keeper's row of the same answer, beside the fleet's
    per-turn figures. *)

type month_view = Masc.Tui_decode_keeper_efficiency.month_view

(** The month a read asks for: {!Keeper_efficiency.month_of_unix_time} of
    [now], the same UTC month the route answers when none is asked. *)
val month_of : now:float -> string

val path : month:string -> string

(** 120 s. The first read of a month aggregates the month's ledgers on the
    server: 41.7 s on 2026-11-06 for six days and 33 Keepers. Later reads
    answer from the server's cache in about 0.1 s. The default 10 s request
    limit would fail every first read. *)
val timeout_sec : float

val decode : Yojson.Safe.t -> (month_view, string) result

type tone =
  | Plain
  | Dim
  | Bad

(** The Info tab's lines for one Keeper, from the month last asked for. *)
val lines :
  ko:bool -> (string, month_view) Masc_tui_fetched.t -> keeper_name:string -> (tone * string) list
