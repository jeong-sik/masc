(** Text → token count estimation (CJK-aware, tokenizer-free).

    Recovered verbatim from the retired
    [Agent_sdk.Llm_provider.Text_estimate] (oas 902c45d2,
    lib/llm_provider/text_estimate.ml); OAS 0.212.0 dropped the module
    with the rest of its implicit sizing surface, so MASC owns the
    approximation now. Callers previously reached it through
    [Agent_sdk.Context_reducer.estimate_char_tokens]. *)

val estimate_char_tokens : string -> int
(** ASCII ≈ 4 chars/token; multi-byte (CJK, emoji, …) ≈ 2/3 token/char.
    O(n), no allocation. Returns [>= 1]; the empty string returns [1] so
    downstream divisions never see zero. *)
