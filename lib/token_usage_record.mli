(** Token_usage_record — Parse token usage evidence from CDAL proof.

    @since CDAL eval content-based redesign *)

type t = {
  turn : int;
  input_tokens : int;
  output_tokens : int;
  cost_usd : float option;
}

(** Parse an array of token usage records from JSON. *)
val of_json_list : Yojson.Safe.t -> (t list, string) result

(** Total input + output tokens across all turns. *)
val total_tokens : t list -> int

(** Total cost across all turns (0.0 if no cost data). *)
val total_cost : t list -> float
