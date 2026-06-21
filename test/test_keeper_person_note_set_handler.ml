(* RFC-0229 — keeper_person_note_set handler contract.

   In-process tool dispatch does not validate schema "required" fields (#21875),
   so the handler must self-enforce them. The schema declares [note] required,
   yet the handler previously read it via [Safe_ops.json_string ~default:""],
   which collapsed field-absent (LLM omission) and field-present-empty
   (deliberate RFC-0229 §3.1 tombstone) to the same "". A keeper that omitted
   [note] therefore silently cleared an existing note and got ok:true.

   These tests pin the corrected contract: an omitted [note] is rejected and
   leaves an existing note intact, while an explicit empty string still clears
   (the deliberate tombstone). *)

open Masc

module N = Keeper_person_notes
module H = Keeper_tool_in_process_runtime

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let with_base_dir f =
  let base_dir = temp_base_path "keeper-person-note-handler" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () -> f base_dir)

let keeper_name = "person-note-handler-keeper"

let make_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String keeper_name);
          ("agent_name", `String "person-note-handler-agent");
          ("trace_id", `String "trace-person-note");
          ("runtime_id", `String "ollama_cloud.deepseek-v4-flash");
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta_of_json_fixture failed: " ^ err)

let note_for store_dir speaker_id =
  List.assoc_opt speaker_id (N.notes ~base_dir:store_dir ~keeper_name)

let result_has_error json_str =
  match Yojson.Safe.from_string json_str with
  | `Assoc fields -> List.mem_assoc "error" fields
  | _ -> false

let result_field_bool json_str key =
  match Yojson.Safe.from_string json_str with
  | `Assoc fields -> (
      match List.assoc_opt key fields with Some (`Bool b) -> Some b | _ -> None)
  | _ -> None

(* The regression: omitting note must not clear an existing note. *)
let test_omitted_note_rejected_and_preserves () =
  with_base_dir (fun base_dir ->
      let config = Workspace.default_config base_dir in
      let meta = make_meta () in
      let store_dir = config.Workspace.base_path in
      N.set_note ~base_dir:store_dir ~keeper_name ~speaker_id:"111"
        ~note:"existing impression" ();
      let result =
        H.handle_person_note_set ~config ~meta
          ~args:(`Assoc [ ("speaker_id", `String "111") ])
      in
      Alcotest.(check bool)
        "omitted note returns an error" true (result_has_error result);
      Alcotest.(check (option string))
        "existing note preserved on omission" (Some "existing impression")
        (note_for store_dir "111"))

(* Deliberate tombstone (RFC-0229 §3.1): an explicit empty string clears. *)
let test_explicit_empty_note_clears () =
  with_base_dir (fun base_dir ->
      let config = Workspace.default_config base_dir in
      let meta = make_meta () in
      let store_dir = config.Workspace.base_path in
      N.set_note ~base_dir:store_dir ~keeper_name ~speaker_id:"222"
        ~note:"to be erased" ();
      let result =
        H.handle_person_note_set ~config ~meta
          ~args:
            (`Assoc [ ("speaker_id", `String "222"); ("note", `String "") ])
      in
      Alcotest.(check (option bool))
        "explicit empty note reports cleared" (Some true)
        (result_field_bool result "cleared");
      Alcotest.(check (option string))
        "explicit empty note tombstones" None (note_for store_dir "222"))

let test_note_value_set () =
  with_base_dir (fun base_dir ->
      let config = Workspace.default_config base_dir in
      let meta = make_meta () in
      let store_dir = config.Workspace.base_path in
      let result =
        H.handle_person_note_set ~config ~meta
          ~args:
            (`Assoc
              [
                ("speaker_id", `String "333");
                ("note", `String "store owner");
              ])
      in
      Alcotest.(check (option bool))
        "note value reports not-cleared" (Some false)
        (result_field_bool result "cleared");
      Alcotest.(check (option string))
        "note value stored" (Some "store owner") (note_for store_dir "333"))

let () =
  Alcotest.run "keeper_person_note_set_handler"
    [
      ( "required-note",
        [
          Alcotest.test_case "omitted note rejected, existing preserved" `Quick
            test_omitted_note_rejected_and_preserves;
          Alcotest.test_case "explicit empty note clears (tombstone)" `Quick
            test_explicit_empty_note_clears;
          Alcotest.test_case "note value is stored" `Quick test_note_value_set;
        ] );
    ]
