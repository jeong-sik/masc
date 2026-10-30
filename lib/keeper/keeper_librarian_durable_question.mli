(** The host form of a durable Memory question. An original freezes the parse
    time, the policy, both prompt resolutions and the output schema of its
    [durable_preparation] and names the prompt it sent by digest. The input and
    the substitutions repeat other facts of the original, so a restored original
    renders them again from its own input and checks the digest. *)
type frozen = {
  parsing_now : float;
  policy : Keeper_librarian_runtime.durable_policy;
  rule_prompt : Prompt_registry.prompt_resolution;
  prompt : Prompt_registry.prompt_resolution;
  rendered_prompt_sha256 : string;
  output_schema : Yojson.Safe.t;
}
val to_json : Keeper_librarian_runtime.durable_preparation -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (frozen, string) result
(** Field-exact decoder; the parse time must be finite. It restores nothing:
    the caller renders the question again from its own input. *)
val rendered_matches : frozen -> Keeper_librarian_runtime.durable_preparation -> (unit, string) result
(** The prompt rendered from the restored preparation is the one the host was sent. *)
val request : request_id:string -> Keeper_librarian_runtime.durable_preparation ->
  (Lane_addon_exact.request, string) result
(** The Exact output request of the durable tool: the rendered prompt as one
    user message, under the output schema. *)
