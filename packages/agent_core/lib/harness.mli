(** Test harness framework for agent verification.

    Provides pluggable verification layers inspired by the Swiss Cheese
    model: multiple independent layers, each catching different failure
    modes. Compose layers via {!Swiss_cheese} for multi-layer checks.

    @stability Evolving
    @since 0.93.1 *)

(** {1 Common types} *)

(** Verdict from a harness evaluation. *)
type verdict =
  { passed : bool
  ; score : float option (** 0.0-1.0, for graded harnesses *)
  ; evidence : string list (** Machine-readable evidence strings *)
  ; detail : string option (** Human-readable explanation *)
  }

(** A single layer in a Swiss Cheese stack. *)
type 'obs layer =
  { name : string
  ; check : 'obs -> bool
  ; evidence : 'obs -> string
  }

(** Result of evaluating one layer. *)
type 'obs layer_result =
  { layer_name : string
  ; layer_passed : bool
  ; layer_evidence : string
  }

(** Combined result from all layers. *)
type 'obs swiss_verdict =
  { all_passed : bool
  ; layer_results : 'obs layer_result list
  ; coverage : float (** Fraction of layers that passed. *)
  }

(** {1 Behavioral harness} *)

module Behavioral : sig
  (** What we expect from the agent. *)
  type expectation =
    | ToolSelected of string list
    | ContainsText of string
    | All of expectation list

  (** What we observe from the agent run. *)
  type observation =
    { tools_called : string list
    ; turn_count : int
    ; final_response : string
    ; messages : Types.message list
    }

  (** Extract observation from an agent after a run. *)
  val observe : Agent.t -> (Types.api_response, Error.sdk_error) result -> observation

  (** Evaluate an observation against an expectation. *)
  val evaluate : observation -> expectation -> verdict
end

(** {1 Adversarial harness} *)

module Adversarial : sig
  (** Types of adversarial input. *)
  type adversarial_input =
    | MalformedJson of string
    | PromptInjection of string
    | ToolError of
        { tool_name : string
        ; error : string
        }
    | OversizedInput of { size : int }

  (** What we expect under adversarial conditions. *)
  type expectation =
    | GracefulError
    | NoToolExecution
    | ErrorContains of string

  type observation =
    { result : (Types.api_response, Error.sdk_error) result
    ; tools_executed : string list
    ; error_message : string option
    }

  (** Evaluate adversarial observation against expectation. *)
  val evaluate : observation -> expectation -> verdict
end

(** {1 Performance harness} *)

module Performance : sig
  type observation =
    { latencies_ms : float list
    ; total_tokens : int
    ; total_cost_usd : float
    ; turn_count : int
    }

  type expectation = { max_p95_latency_ms : float option }

  val default_expectation : expectation

  (** Calculate p95 from a list of latencies. *)
  val p95 : float list -> float

  (** Evaluate performance against thresholds. *)
  val evaluate : observation -> expectation -> verdict
end

(** {1 Regression harness (golden file)} *)

module Regression : sig
  type match_mode =
    | ExactMatch
    | StructuralMatch of (Yojson.Safe.t -> Yojson.Safe.t -> bool)
    | FuzzyMatch of { threshold : float }

  type observation =
    { output_json : Yojson.Safe.t
    ; output_text : string
    }

  (** Compare observation against a golden string value. *)
  val evaluate : mode:match_mode -> observation -> string -> verdict
end

(** {1 Swiss Cheese combinator} *)

module Swiss_cheese : sig
  (** Run all layers and produce a combined verdict. *)
  val evaluate_layers : 'obs layer list -> 'obs -> 'obs swiss_verdict

  (** Require all layers to pass. *)
  val require_all : 'obs layer list -> 'obs -> verdict

  (** Require at least [n] layers to pass. *)
  val require_n : int -> 'obs layer list -> 'obs -> verdict
end

(** {1 Composability harness} *)

module Composability : sig
  type scenario =
    | SingleAgent
    | Handoff of
        { parent : string
        ; targets : string list
        }
    | Orchestrated of { agents : string list }
    | Pipeline of { stages : string list }

  type expectation =
    | HandoffOccurred of string
    | AllAgentsCompleted
    | ContextPropagated of string

  type observation =
    { agents_involved : string list
    ; handoffs_observed : (string * string) list
    ; all_completed : bool
    ; context_keys : string list
    ; total_turns : int
    }

  (** Evaluate composability observation against expectation. *)
  val evaluate : observation -> expectation -> verdict
end

(** {1 Model grader} *)

module Model_grader : sig
  (** Configuration for LLM-based evaluation. *)
  type config =
    { prompt_template : string (** Must contain \{goal\} and \{result\} placeholders *)
    ; rubric : string (** Evaluation criteria *)
    ; weight : float (** 0.0-1.0 weight for this grader *)
    }

  (** Grade a result using an LLM via dependency-injected [complete_fn].
      Extracts a numeric score from the LLM response.
      [passed] is true when score >= 0.5 * weight. *)
  val grade
    :  complete_fn:(string -> (string, string) result)
    -> config
    -> goal:string
    -> result:string
    -> verdict
end

(** {1 JSON serialization (Swiss Verdict Schema v1)} *)

(** Serialize a verdict to JSON.
    Emits the shared verdict fields used by Swiss Verdict layer results:
    [passed], [score], [evidence], and [detail].
    Callers that need a full schema-conformant [layer_result] object must
    add [layer_name] separately. *)
val verdict_to_json : verdict -> Yojson.Safe.t

(** Serialize a swiss_verdict to JSON.
    Conforms to [docs/schemas/swiss-verdict.schema.json] (schema_version 1).
    Each [layer_result.layer_evidence] is wrapped in a single-element list
    to match the schema's [evidence: string array] shape. *)
val swiss_verdict_to_json : _ swiss_verdict -> Yojson.Safe.t
