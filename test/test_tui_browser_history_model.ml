module History = Masc_tui_types.Browser_history
let expect message value = if not value then failwith message
let ok = function Ok value -> value | Error detail -> failwith detail
let () =
  let waiting = History.create "reader" in
  expect "navigation during list load does not supersede the pending list"
    (History.move 1 waiting=None);
  let artifact = Tool_output.make_artifact_ref ~sha256:(String.make 64 'a')
      ~bytes:2 ~mime:Masc.Browser_observation.mime ~preview:"" |> Result.map_error Tool_output.make_error_to_string |> ok in
  let entry : History.entry = {at=1.;execution_id="exec-observation";artifact} in
  let selected = History.select 0 [entry;{entry with execution_id="exec-older"}] waiting in
  expect "newer bound does not start another fetch" (History.move (-1) selected=None);
  let older = match History.move 1 selected with Some value -> value | None -> failwith "older observation missing" in
  expect "moving observation selects a distinct receipt"
    (Option.map (fun (entry : History.entry) -> entry.execution_id) (History.selected older)=Some "exec-older");
  expect "previous content cannot survive selection change" (History.observation older=None);
  expect "different artifact identity is rejected"
    (Result.is_error (History.decode_artifact artifact (`Assoc ["sha256",`String (String.make 64 'b');"bytes",`Int 2;"content",`String "{}"])));
  let row refs = `Assoc ["ts",`Float 1.;"keeper",`String "reader";"tool",`String "BrowserRead";
    "input",`Assoc [];"success",`Bool false;"execution_id",`String "exec-observation";
    "artifact_refs",refs] in
  let snapshot refs = Masc.Tui_decode.decode_keeper_calls_snapshot ~requested_keeper:"reader"
    (`Assoc ["keeper",`String "reader";"count",`Int 1;"health",`String "ok";"entries",`List [row refs]]) in
  let receipt = snapshot (`List [Tool_output.normalized_artifact_ref_to_json artifact]) |> ok in
  expect "schema-rejected node still exposes its retained observation"
    (List.length (History.entries receipt)=1);
  expect "malformed artifact must not quietly disappear from history"
    (Result.is_error (snapshot (`List [`Assoc []])));
  print_endline "Browser history model: PASS"
