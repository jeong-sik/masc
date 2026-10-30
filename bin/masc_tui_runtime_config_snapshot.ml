type rows = (string * string) list list

type t = {
  reading : Masc_tui_runtime_config_view.reading;
  rows : rows;
  models : (Masc_tui_model_runtime_table.row list, string) result;
}

let source_rows ~path source =
  Masc_tui_code_lexer.rows_of_source
    ~language:(Masc_tui_code_lexer.language_of_path path) source
  |> List.map (List.map (fun (text, kind) ->
       Masc.Tui_terminal_text.sanitize_terminal_text text, kind))

let of_reading (reading : Masc_tui_runtime_config_view.reading) =
  let rows = source_rows ~path:reading.path reading.source_text in
  let models = Result.bind reading.model_bindings (fun projection ->
    Result.bind reading.account_groups (fun account_groups ->
      Masc_tui_model_runtime_table.of_projection ~account_groups projection)) in
  {reading; rows; models}

let rows_for_source ~path ~source_text snapshot =
  if String.equal path snapshot.reading.path
     && String.equal source_text snapshot.reading.source_text
  then Some snapshot.rows else None
