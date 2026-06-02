(* Tier W1 — Autonomous_executor tests. *)

module E = Autonomous.Autonomous_executor
module A = Multimodal.Artifact
module W = Multimodal.Workspace

let check_bool label b =
  if not b then failwith (Printf.sprintf "%s: false" label)

let check_int label expected actual =
  if expected <> actual then
    failwith
      (Printf.sprintf "%s: expected %d, got %d" label expected actual)

(* ── classify_tool ──────────────────────────────────────────── *)

let test_classify_code () =
  check_bool "code_write → Tag_code"
    (E.classify_tool "code_write" = Some A.Tag_code)

let test_classify_image () =
  check_bool "image_generate → Tag_image"
    (E.classify_tool "image_generate" = Some A.Tag_image)

let test_classify_audio () =
  check_bool "audio_synth → Tag_audio"
    (E.classify_tool "audio_synth" = Some A.Tag_audio)

let test_classify_doc () =
  check_bool "doc_compose → Tag_doc"
    (E.classify_tool "doc_compose" = Some A.Tag_doc)

let test_classify_unknown () =
  check_bool "shell_exec → None"
    (E.classify_tool "shell_exec" = None);
  check_bool "no_underscore → None"
    (E.classify_tool "ping" = None)

(* ── translate ──────────────────────────────────────────────── *)

let test_translate_code () =
  let tc : E.tool_call =
    { name = "code_write"; args = `Assoc [ ("path", `String "x.ml") ] }
  in
  match E.translate tc ~now:1.0 ~created_by:"executor" with
  | None -> failwith "expected Some artifact"
  | Some (A.Any art) ->
      check_bool "kind tag = Tag_code"
        (A.kind_to_tag art.kind = A.Tag_code)

let test_translate_unknown_returns_none () =
  let tc : E.tool_call =
    { name = "shell_exec"; args = `Assoc [] }
  in
  check_bool "shell_exec → None"
    (E.translate tc ~now:1.0 ~created_by:"executor" = None)

let test_translate_metadata_carries_tool_name () =
  let tc : E.tool_call =
    { name = "image_generate"; args = `Assoc [] }
  in
  match E.translate tc ~now:2.0 ~created_by:"executor" with
  | Some (A.Any art) -> (
      match art.metadata with
      | `Assoc kv ->
          check_bool "tool_name field present"
            (List.mem_assoc "tool_name" kv);
          let tn = List.assoc "tool_name" kv in
          check_bool "tool_name = image_generate"
            (tn = `String "image_generate")
      | _ -> failwith "metadata not object")
  | None -> failwith "expected Some"

(* ── accumulate ─────────────────────────────────────────────── *)

let test_accumulate_mixed () =
  let calls : E.tool_call list =
    [
      { name = "code_write"; args = `Null };
      { name = "shell_exec"; args = `Null };
      { name = "image_generate"; args = `Null };
      { name = "audio_synth"; args = `Null };
      { name = "doc_compose"; args = `Null };
      { name = "ping"; args = `Null };
    ]
  in
  let ws0 = W.empty in
  let ws, arts =
    E.accumulate ws0 calls ~now:1.0 ~created_by:"executor"
  in
  check_int "4 multimodal artifacts produced" 4 (List.length arts);
  check_int "workspace size = 4" 4 (W.size ws)

let test_accumulate_empty () =
  let ws0 = W.empty in
  let ws, arts = E.accumulate ws0 [] ~now:1.0 ~created_by:"executor" in
  check_int "empty list → 0 artifacts" 0 (List.length arts);
  check_int "workspace empty" 0 (W.size ws)

let test_accumulate_only_unknown () =
  let calls : E.tool_call list =
    [
      { name = "shell_exec"; args = `Null };
      { name = "ping"; args = `Null };
    ]
  in
  let ws, arts =
    E.accumulate W.empty calls ~now:1.0 ~created_by:"executor"
  in
  check_int "no multimodal calls → 0 artifacts" 0
    (List.length arts);
  check_int "workspace empty" 0 (W.size ws)

(* ── Driver ─────────────────────────────────────────────────── *)

let () =
  let cases =
    [
      ("classify_code", test_classify_code);
      ("classify_image", test_classify_image);
      ("classify_audio", test_classify_audio);
      ("classify_doc", test_classify_doc);
      ("classify_unknown", test_classify_unknown);
      ("translate_code", test_translate_code);
      ( "translate_unknown_returns_none",
        test_translate_unknown_returns_none );
      ( "translate_metadata_carries_tool_name",
        test_translate_metadata_carries_tool_name );
      ("accumulate_mixed", test_accumulate_mixed);
      ("accumulate_empty", test_accumulate_empty);
      ("accumulate_only_unknown", test_accumulate_only_unknown);
    ]
  in
  List.iter
    (fun (name, f) ->
      try f ()
      with e ->
        Printf.printf "FAIL %s: %s\n" name (Printexc.to_string e);
        exit 1)
    cases;
  Printf.printf "test_autonomous_executor: %d cases OK\n"
    (List.length cases)
