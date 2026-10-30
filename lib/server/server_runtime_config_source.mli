(** Same frozen source, with each reader's syntax input and semantic policy.
    Runtime interpretation retains its existing environment-dependent home
    expansion; callers must not treat preparation as an effect-free CPU job. *)
type syntax_inputs = Shared_input | Reader_specific_inputs

type t = private {
  source_text : string;
  syntax_inputs : syntax_inputs;
  keeper : (Keeper_toml_loader.toml_doc, string) result;
  runtime : (Runtime_schema.config, Runtime_toml.parse_error list) result;
}

val prepare : string -> t
(** Parse syntax once when Keeper-normalized input equals original Runtime
    input. Otherwise parse their distinct exact inputs independently. Both
    semantic results and original revision-bearing source bytes are retained. *)
