(** Pure decoder for the [/api/v1/keeper-efficiency] month view.

    The wire shape is ["masc.keeper-efficiency/v1"]; anything else, a
    missing field, or a negative count is a decode error rather than a
    defaulted value. No network, clock, or UI dependency.

    @since 0.67.0 — task-2944 *)

type keeper_month = {
  keeper : string;
  turns : int;
  input_tokens : int;
  output_tokens : int;
  cost_usd : float;
  calls : int;
  failed : int;
  deferred : int;
  tool_ms : float;
}

type fleet = {
  turns_total : int;
  calls_per_turn : float;
  tool_s_per_turn : float;
  output_tokens_per_turn : float;
  input_tokens_per_turn : float;
  cost_usd_per_turn : float;
}

type month_view = {
  month : string;
  generated_at : float;
  days_covered : int;
  keepers : keeper_month list;
  fleet : fleet;
}

type decode_error =
  | Not_an_object
  | Unexpected_schema of string
  | Missing_field of string
  | Invalid_field of { field : string; detail : string }
  | Malformed_json of { line_number : int option; detail : string }

val decode_error_to_string : decode_error -> string

val of_json : Yojson.Safe.t -> (month_view, decode_error) result
(** Decode one response body. [turns]-style counts and token sums must be
    non-negative integers; [month] must be a non-empty [YYYY-MM] string. *)

val keeper_row : month_view -> keeper:string -> keeper_month option
(** The one keeper's month row, if this month has one. *)
