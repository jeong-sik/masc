(** Run one declared [cli_slots] lane slot as an official-client one-shot.

    RFC cli-runtimes-as-lane-slots: an exact-output lane may declare
    official-client runtime ids that it walks after every catalog (HTTP) slot
    is exhausted. This module is the per-slot executor for that walk. It
    mirrors the HTTP contract deliberately:

    - the prompt carries the lane schema in the exact Agent Core sentence
      ({!Agent_core.Exact_output.schema_instruction_text}), so the model gets
      the same words on both transports;
    - the answer is parsed with a strict [Yojson.Safe.from_string] — no fence
      stripping, no repair — because that is precisely what Agent Core does to
      a [Json_syntax_only] HTTP body. An unparseable answer is the CLI's
      [Invalid_json_output] and the walk advances, exactly like an HTTP slot.

    Domain validation stays with the lane consumer, as it does on the HTTP
    path. *)

type failure =
  | Not_an_official_client of { runtime_id : string }
      (** The id resolved to nothing this module may run. Declaration-time
          admission does not check this ([cli_slots] are carried verbatim);
          the walk reports it per slot and advances. *)
  | Execution_failed of
      { runtime_id : string
      ; detail : string
      }
      (** The client failed to produce an answer: admission, spawn, timeout,
          bridge, or an empty response. *)
  | Invalid_json_output of
      { runtime_id : string
      ; detail : string
      }
      (** The client answered, but the text is not one JSON value. *)

val failure_to_string : failure -> string

type runner =
  runtime_id:string
  -> system_prompt:string
  -> output_schema:Yojson.Safe.t
  -> prompt:string
  -> (string, string) result
(** The effectful edge, injectable for tests. The default wraps
    {!Fusion_official_client.run_panelist}.

    [output_schema] is the caller's own domain schema, handed to the CLI's
    schema flag so the client validates its answer instead of only being asked
    for the shape in prose. Codex ignores it: its app-server [turn/start] has
    no field for a schema. *)

val run
  :  ?runner:runner
  -> base_dir:string
  -> runtime_id:string
  -> system_prompt:string
  -> requirement:Agent_core.Exact_output.output_requirement
  -> prompt:string
  -> unit
  -> (Yojson.Safe.t, failure) result
(** Execute [prompt] (suffixed with the lane schema instruction) once on
    [runtime_id] and parse the answer as a single JSON value. *)

val walk
  :  ?runner:runner
  -> base_dir:string
  -> cli_slots:string list
  -> system_prompt:string
  -> requirement:Agent_core.Exact_output.output_requirement
  -> prompt:string
  -> unit
  -> (string * Yojson.Safe.t, failure list) result
(** Walk [cli_slots] in declaration order and return the first slot whose
    answer parses, as [(runtime_id, value)]. [Error failures] carries every
    slot's failure in walk order when all of them failed; an empty
    [cli_slots] is [Error []] — the caller distinguishes "nothing declared"
    from "declared and exhausted" by the list it passed in. *)
