(** Unit tests for Evidence_ref — typed provenance parser *)

let () =
  let module ER = Evidence_ref in

  (* --- backward compat: old "artifact:path" parses as Depend_on_implicit --- *)
  let t01 = ER.parse "artifact:lib/server/foo.ml" in
  assert (t01 = Some (ER.Artifact { path = "lib/server/foo.ml"; relation = ER.Depend_on_implicit; context = None }));

  let t02 = ER.parse "artifact:artifacts/proof.json" in
  assert (t02 = Some (ER.Artifact { path = "artifacts/proof.json"; relation = ER.Depend_on_implicit; context = None }));

  (* --- note: prefix --- *)
  let t03 = ER.parse "note:task completed successfully" in
  assert (t03 = Some (ER.Note "task completed successfully"));

  let t04 = ER.parse "note:" in
  assert (t04 = Some (ER.Note ""));

  (* --- new form: artifact:path:relation --- *)
  let t05 = ER.parse "artifact:lib/foo.ml:depend-on:task-211" in
  assert (match t05 with
    | Some (ER.Artifact { path = "lib/foo.ml"; relation = ER.Depend_on "task-211"; context = None }) -> true
    | _ -> false);

  let t06 = ER.parse "artifact:test.ml:tests:keeper_error_classify" in
  assert (match t06 with
    | Some (ER.Artifact { path = "test.ml"; relation = ER.Tests "keeper_error_classify"; context = None }) -> true
    | _ -> false);

  let t07 = ER.parse "artifact:README.md:documents:api" in
  assert (match t07 with
    | Some (ER.Artifact { path = "README.md"; relation = ER.Documents "api"; context = None }) -> true
    | _ -> false);

  (* --- new form: artifact:path:relation:context --- *)
  let t08 = ER.parse "artifact:lib/foo.ml:depend-on:task-211-grandchild" in
  (match t08 with
   | Some (ER.Artifact { path; relation = ER.Depend_on rel; context = Some ctx }) ->
     assert (path = "lib/foo.ml");
     assert (rel = "task-211");
     assert (ctx = "grandchild")
   | _ -> assert false);

  (* --- round-trip: parse → to_string → parse --- *)
  let raw = "artifact:lib/bar.ml:implements:task-100:feature-x" in
  let t09 = ER.parse raw in
  let serialized = Option.map ER.to_string t09 in
  let t10 = Option.bind serialized ER.parse in
  assert (t09 = t10);

  (* --- empty/blank → None --- *)
  assert (ER.parse "" = None);
  assert (ER.parse "   " = None);

  (* --- unknown prefix → None (fail-open) --- *)
  assert (ER.parse "trace:abc-123" = None);
  assert (ER.parse "PR#28181" = None);

  (* --- path with multiple colons treated as path continuation --- *)
  let t11 = ER.parse "artifact:a/b/c:d/e/f" in
  (* "a/b/c:d/e:f" — last segment "f" is too short for relation, treat as path *)
  (match t11 with
   | Some (ER.Artifact { path; relation = ER.Depend_on_implicit; context = None }) ->
     (* entire thing treated as path when suffix looks like continuation *)
     assert (path <> "")
   | _ -> assert false);

  (* --- parse_list: separates typed and unrecognized --- *)
  let raws = [
    "artifact:lib/foo.ml";
    "note:see board post";
    "trace:opsd-1";
    "artifact:test.ml:tests:bar";
    "PR#123";
    "";
  ] in
  let typed, unrecognized = ER.parse_list raws in
  assert (List.length typed = 3);
  assert (List.length unrecognized = 3);
  assert (List.mem "trace:opsd-1" unrecognized);
  assert (List.mem "PR#123" unrecognized);
  assert (List.mem "" unrecognized);

  (* --- has_explicit_relation --- *)
  assert (ER.has_explicit_relation (ER.Note "hello") = false);
  assert (ER.has_explicit_relation (ER.Artifact { path = "a"; relation = ER.Depend_on_implicit; context = None }) = false);
  assert (ER.has_explicit_relation (ER.Artifact { path = "a"; relation = ER.Tests "b"; context = None }) = true);

  Printf.printf "evidence_ref tests: all passed\n%!"
