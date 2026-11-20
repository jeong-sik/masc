module Tui_decode = Masc.Tui_decode

type context_summary =
  | Context_measured of {
      ratio : float;
      tokens : int;
      maximum : int;
      observed_at : string;
      turn_ref : string;
    }
  | Context_partial of {
      tokens : int;
      observed_at : string;
      turn_ref : string;
    }
  | Context_unavailable of string

type context_pressure =
  | Quiet
  | Pressure
  | Danger

val percentage_tenths_full : int
(** A whole in tenths of one percent: [1000]. A bar of {!percentage_tenths}
    against it is full at the whole. *)

val percentage_tenths : float -> int
(** A ratio projected to tenths of one percent, using the rounding visible in
    the Keeper detail row. For example, [0.4999] becomes [500] ([50.0%]). *)

val context_pressure : float -> context_pressure
(** The pressure band for the rounded percentage shown to the operator. *)

val log_kind_label : Tui_decode.log_kind -> string
val log_channel_label : Tui_decode.log_channel -> string
val usage_label : input:int option -> output:int option -> string
val latency_label : int option -> string

val log_entry_rows : width:int -> time:string -> Tui_decode.log_entry -> string list
(** Full observed facts, wrapped in display cells. Entries retain their own
    field order; callers order entries newest first before slicing rows. *)
val context_summary : Tui_decode.context_observation -> context_summary
val context_facts :
  ?pressure_tone:(context_pressure -> 'reading Masc_tui_chat_facts.tone) ->
  ko:bool ->
  inspect_key:string ->
  Tui_decode.context_observation ->
  'reading Masc_tui_chat_facts.t list
(** The context reading as facts of the chat's Keeper status block: the share,
    the token counts behind it, and the key that opens the breakdown.
    [pressure_tone] lets a styled surface colour the measured share by its
    {!context_pressure} band; omitting it keeps {!Masc_tui_chat_facts.Amount}.
    [inspect_key] is the name of that key, spelled by the key table; this
    layout cannot see the table, so the caller hands it over. *)
