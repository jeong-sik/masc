(** Unified input-token budget and output-token reservation envelope.

    The declared context window minus the wire codec's output-token
    reservation defines the single input-token limit {!type:t} shared by
    Agent Core pre-flight admission and MASC turn/forecast window signals. *)

(** Maximum input tokens permitted on one request under a provider config
    ([max_context_tokens - reserved_output_tokens]). Strictly positive and
    constructible only inside {!Input_budget}. *)
type t = private int [@@deriving show, eq]

val to_int : t -> int

(** Breakdown of the resolved input budget alongside its raw window and output
    reservation. *)
type budget =
  { max_context_tokens : int
  ; reserved_output_tokens : int
  ; max_input_tokens : t
  }
[@@deriving show, eq]

type context_fit =
  { input_tokens : int
  ; reserved_output_tokens : int
  ; max_context_tokens : int
  }
[@@deriving show, eq]

type error =
  | Missing_context_window of { model_id : string }
  | Non_positive_context_window of
      { model_id : string
      ; max_context_tokens : int
      }
  | Missing_required_output_reservation of { model_id : string }
  | Output_reservation_exceeds_window of
      { model_id : string
      ; max_context_tokens : int
      ; reserved_output_tokens : int
      }
[@@deriving show, eq]

val error_to_string : error -> string

type receipt_fit_error =
  | Receipt_budget_error of error
  | Receipt_context_exceeded of context_fit
[@@deriving show, eq]

(** Resolve the validated capability row for [config] without emitting warnings.
    Falls back to the typed provider default row when the catalog has no entry. *)
val capabilities_of_config : Provider_config.t -> Capabilities.capabilities

(** Resolve the typed output-token ceiling and its provenance for [config].
    [None] when neither capability overrides, model catalog, nor provider
    defaults declare [max_output_tokens]. *)
val output_token_ceiling : Provider_config.t -> Types.output_token_ceiling option

(** Wire output-token envelope implied by [config]'s selected HTTP codec. *)
val output_token_envelope : Provider_config.t -> Types.output_token_envelope

(** Pure optional-envelope receipt resolution shared by request serializers and
    {!of_provider_config}. Performs no logging or metrics side effects. *)
val optional_output_token_receipt
  :  envelope:Types.output_token_envelope
  -> Provider_config.t
  -> Types.output_token_receipt

(** Single authoritative output-token receipt resolver for a config and wire
    envelope (defaults to {!output_token_envelope} [config]).

    - [Anthropic_messages_max_tokens]: required on the wire; falls back to the
      model catalog or declared capability override ceiling and fails closed
      with {!Types.Required_output_token_ceiling_missing} when none exists.
    - All other envelopes: optional on the wire; omits when [max_tokens] is
      [None], clamps to ceiling when above it. *)
val resolve_output_token_receipt
  :  ?envelope:Types.output_token_envelope
  -> Provider_config.t
  -> (Types.output_token_receipt, Types.required_output_token_error) result

(** Resolve the validated positive context-token limit from [config.max_context]
    or the resolved model capability row. *)
val resolve_context_limit : Provider_config.t -> (int, error) result

(** Derive the full budget breakdown from [config].
    Optional envelopes that omit [max_tokens] reserve [0] output tokens;
    required Anthropic envelopes reserve their effective value or fail closed
    with [Missing_required_output_reservation]. Fails closed with
    [Output_reservation_exceeds_window] when
    [reserved_output_tokens >= max_context_tokens]. *)
val resolve : Provider_config.t -> (budget, error) result

(** Derive {!type:t} directly from [config]. Same semantics as {!resolve}. *)
val of_provider_config : Provider_config.t -> (t, error) result

(** Whether [input_tokens] fits within [0 .. (t :> int)]. *)
val admits : t -> input_tokens:int -> bool

(** Pre-flight admission check over a frozen {!Types.output_token_receipt} and
    a validated context window, sharing the exact reservation rules with
    {!resolve}. When [reserved_output_tokens >= max_context_tokens] or
    [input_tokens < 0] or
    [input_tokens + reserved_output_tokens > max_context_tokens], returns
    [Error (Receipt_context_exceeded _)]. *)
val admit_receipt
  :  ?model_id:string
  -> max_context_tokens:int
  -> input_tokens:int
  -> Types.output_token_receipt
  -> (context_fit, receipt_fit_error) result
