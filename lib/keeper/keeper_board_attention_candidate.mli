(** Durable evidence for board signals that reached the reactive pipeline but
    had no deterministic keeper wake reason.

    This ledger is intentionally not a wake queue. A recorded candidate means
    "this board signal requires an LLM/Judge attention boundary before it can
    become control flow"; it does not wake a keeper and does not authorize
    substring/keyword matching as a fallback. *)

type signal_kind =
  | Post_created
  | Comment_added
  | Reaction_changed

type attention_authority =
  | Llm_judge_required

type wake_authority =
  | No_direct_wake

type candidate = {
  candidate_id : string;
  dedupe_key : string;
  keeper_name : string;
  post_id : string;
  signal_kind : signal_kind;
  author : string;
  title : string;
  content_preview : string;
  hearth : string option;
  updated_at : float option;
  recorded_at : float;
  attention_authority : attention_authority;
  wake_authority : wake_authority;
}

type record_result =
  [ `Recorded
  | `Duplicate of candidate
  | `Error of string
  ]

val signal_kind_to_string : signal_kind -> string
val signal_kind_of_string : string -> signal_kind option
val attention_authority_to_string : attention_authority -> string
val attention_authority_of_string : string -> attention_authority option
val wake_authority_to_string : wake_authority -> string
val wake_authority_of_string : string -> wake_authority option

val candidate_id_of_dedupe_key : string -> string

val of_board_signal :
  keeper_name:string ->
  recorded_at:float ->
  Board_dispatch.board_signal ->
  candidate

val candidate_to_json : candidate -> Yojson.Safe.t
val candidate_of_json : Yojson.Safe.t -> (candidate, string) result

val record : base_path:string -> candidate -> record_result

val load_candidates : base_path:string -> keeper_name:string -> candidate list
