(** Generational Metrics - Evidence for successor improvement *)

(** {1 Types} *)

type task_record = {
  generation: int;
  task_id: string;
  completed: bool;
  duration_ms: int;
  error_count: int;
  input_tokens: int;
  output_tokens: int;
  timestamp: float;
}

type handoff_record = {
  from_generation: int;
  to_generation: int;
  dna_size: int;
  context_ratio: float;
  timestamp: float;
}

type generation_summary = {
  generation: int;
  total_tasks: int;
  completed_tasks: int;
  total_errors: int;
  avg_duration_ms: float;
  total_input_tokens: int;
  total_output_tokens: int;
  knowledge_retention: float option;
}

type generation_comparison = {
  gen_a: int;
  gen_b: int;
  completion_delta: float;
  error_delta: float;
  duration_delta: float;
  token_delta: float;
  retention_b: float option;
  verdict: string;
}

(** {1 Recording} *)

val record_task : 
  generation:int -> 
  task_id:string -> 
  completed:bool -> 
  duration_ms:int -> 
  error_count:int ->
  input_tokens:int ->
  output_tokens:int ->
  task_record

val record_handoff :
  from_generation:int ->
  to_generation:int ->
  dna_size:int ->
  context_ratio:float ->
  handoff_record

val record_retention_test :
  generation:int ->
  question:string ->
  expected:string ->
  actual:string ->
  confidence:float ->
  unit

(** {1 Analysis} *)

val summarize_generation : int -> generation_summary option
val compare_generations : int -> int -> generation_comparison option
val format_comparison : generation_comparison -> string

(** {1 Utilities} *)

val reset : unit -> unit
val to_json : unit -> Yojson.Safe.t
