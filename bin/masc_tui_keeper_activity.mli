module Decode = Masc.Tui_decode

type tool_use = {
  tu_name : string;
  tu_calls : int;
}

type window = {
  aw_turns : int;
  aw_heartbeats : int;
  aw_input_tokens : int;
  aw_output_tokens : int;
  aw_cost_usd : float;
  aw_tool_calls : int;
  aw_top_tools : tool_use list;
  aw_covered : bool;
      (** Whether the rows handed in reach past [since]. The metrics window is
          bounded by row count, so a busy Keeper can fill it with less than the
          requested span. False means the totals describe the rows that were
          read, not the whole span. *)
  aw_oldest_ts : string option;
      (** Timestamp of the oldest row considered, so an uncovered window can
          state what it does reach. *)
}

val cutoff_of : now:float -> hours:int -> string
(** ISO 8601 UTC instant [hours] before [now], in the same shape metrics rows
    carry in [ts]. Row timestamps sort lexicographically in that shape, so the
    result is directly comparable against them. *)

val summarize : since:string -> Decode.log_entry list -> window
(** Fold the rows at or after [since]. Rows without a usage, cost, or tool
    field contribute nothing to that total rather than counting as zero. *)

val empty : window
