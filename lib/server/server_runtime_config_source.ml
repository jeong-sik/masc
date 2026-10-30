type syntax_inputs = Shared_input | Reader_specific_inputs

type t = {
  source_text : string;
  syntax_inputs : syntax_inputs;
  keeper : (Keeper_toml_loader.toml_doc, string) result;
  runtime : (Runtime_schema.config, Runtime_toml.parse_error list) result;
}

let prepare source_text =
  let keeper_source = Keeper_toml_loader.normalize_source source_text in
  let syntax = Otoml.Parser.from_string_result keeper_source in
  let keeper = Result.bind syntax Keeper_toml_loader.of_otoml in
  let syntax_inputs, runtime =
    if String.equal keeper_source source_text then
      Shared_input,
      (match syntax with
       | Ok document -> Runtime_toml.parse_toml document
       | Error message -> Error [{Runtime_toml.path="<parse>"; message}])
    else Reader_specific_inputs, Runtime_toml.parse_string source_text in
  {source_text; syntax_inputs; keeper; runtime}
