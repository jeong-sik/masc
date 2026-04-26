(** Autoresearch_codegen — LLM-based code change generation.

    Builds prompts, parses MODEL responses as a strict JSON object,
    and invokes the cascade for code generation.

    @since 2.80.0 *)

include module type of struct
  include Autoresearch_types
end

(** {1 Prompt construction (exposed for testing)} *)

val build_code_change_prompt
  :  goal:string
  -> baseline:float
  -> lower_is_better:bool
  -> history:cycle_record list
  -> insights:string list
  -> file_content:string
  -> target_file:string
  -> string

(** {1 Response parsing} *)

(** [parse_model_code_response raw] returns
    [Ok (hypothesis, modified_code)] on success, [Error reason]
    otherwise. Uses [Llm_provider.Lenient_json] for deterministic
    recovery (strip markdown fences, unwrap double-stringify,
    trailing commas, close brackets) before JSON parse. *)
val parse_model_code_response : string -> (string * string, string) result

(** {1 Entry point} *)

(** [generate_code_change ~goal ~baseline ~lower_is_better ~history
    ~insights ~target_file ~file_content] invokes the
    [autoresearch] cascade and returns [Ok (hypothesis, new_code)]
    or [Error reason]. Backs off when local runtime slots are
    saturated. *)
val generate_code_change
  :  goal:string
  -> baseline:float
  -> lower_is_better:bool
  -> history:cycle_record list
  -> insights:string list
  -> target_file:string
  -> file_content:string
  -> (string * string, string) result
