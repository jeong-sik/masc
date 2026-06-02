(* Alcotest suite for [Masc_mcp.Tool_error].
   RFC-0148 §5 acceptance: 7 variant + exn-preservation case. *)

module TE = Masc_mcp.Tool_error

let test_kind_all_variants () =
  Alcotest.(check string) "Not_found tag"
    "not_found" (TE.kind (TE.Not_found { what = "x" }));
  Alcotest.(check string) "Permission_denied tag"
    "permission_denied" (TE.kind (TE.Permission_denied { path = "x" }));
  Alcotest.(check string) "Invalid_input tag"
    "invalid_input" (TE.kind (TE.Invalid_input { detail = "x" }));
  Alcotest.(check string) "Resource_exhausted tag"
    "resource_exhausted"
    (TE.kind (TE.Resource_exhausted { resource = "fd"; detail = "open" }));
  Alcotest.(check string) "Timeout tag"
    "timeout"
    (TE.kind (TE.Timeout { stage = "slot_wait"; elapsed_sec = 1.5 }));
  Alcotest.(check string) "Cancelled tag"
    "cancelled" (TE.kind (TE.Cancelled { reason = "parent_fiber" }));
  Alcotest.(check string) "Internal_error tag"
    "internal_error"
    (TE.kind (TE.Internal_error { detail = "x"; exn = None }))

let test_to_json_includes_record_fields () =
  let s = Yojson.Safe.to_string
    (TE.to_json (TE.Not_found { what = "lib/foo.ml" }))
  in
  Alcotest.(check bool) "JSON has kind=not_found" true
    (Astring.String.is_infix ~affix:{|"kind":"not_found"|} s);
  Alcotest.(check bool) "JSON has what field" true
    (Astring.String.is_infix ~affix:{|"what":"lib/foo.ml"|} s)

let test_to_json_omits_internal_exn () =
  (* The exn object must never reach the wire. *)
  let raw =
    try failwith "boom" with e -> e
  in
  let s = Yojson.Safe.to_string
    (TE.to_json (TE.Internal_error { detail = "wrapped"; exn = Some raw }))
  in
  Alcotest.(check bool) "JSON omits exn" false
    (Astring.String.is_infix ~affix:"exn" s);
  Alcotest.(check bool) "JSON has detail" true
    (Astring.String.is_infix ~affix:{|"detail":"wrapped"|} s)

let test_of_exn_sys_error () =
  match TE.of_exn (Sys_error "no such file") with
  | TE.Internal_error { detail; exn = Some _ } ->
      Alcotest.(check string) "detail matches" "no such file" detail
  | _ -> Alcotest.fail "expected Internal_error with Some exn"

let test_of_exn_unix_emfile () =
  match TE.of_exn (Unix.Unix_error (Unix.EMFILE, "open", "")) with
  | TE.Resource_exhausted { resource; detail } ->
      Alcotest.(check string) "resource is fd" "fd" resource;
      Alcotest.(check string) "detail is op" "open" detail
  | _ -> Alcotest.fail "expected Resource_exhausted on EMFILE"

let test_of_exn_unix_enoent () =
  match TE.of_exn (Unix.Unix_error (Unix.ENOENT, "stat", "/missing/path")) with
  | TE.Not_found { what } ->
      Alcotest.(check string) "what is path" "/missing/path" what
  | _ -> Alcotest.fail "expected Not_found on ENOENT"

let test_to_string_single_line () =
  (* Logs must stay grep-friendly: one line per error. *)
  let cases = [
    TE.Not_found { what = "x" };
    TE.Permission_denied { path = "x" };
    TE.Invalid_input { detail = "x" };
    TE.Resource_exhausted { resource = "fd"; detail = "open" };
    TE.Timeout { stage = "spawn"; elapsed_sec = 0.0 };
    TE.Cancelled { reason = "x" };
    TE.Internal_error { detail = "x"; exn = None };
  ] in
  List.iter (fun t ->
    let s = TE.to_string t in
    Alcotest.(check bool) (Printf.sprintf "no newline in [%s]" (TE.kind t))
      false (String.contains s '\n')
  ) cases

let () =
  Alcotest.run "tool_error" [
    "kind", [
      Alcotest.test_case "all variants" `Quick test_kind_all_variants;
    ];
    "to_json", [
      Alcotest.test_case "includes record fields" `Quick
        test_to_json_includes_record_fields;
      Alcotest.test_case "omits Internal_error.exn from wire" `Quick
        test_to_json_omits_internal_exn;
    ];
    "of_exn", [
      Alcotest.test_case "Sys_error maps to Internal_error" `Quick
        test_of_exn_sys_error;
      Alcotest.test_case "Unix EMFILE maps to Resource_exhausted/fd" `Quick
        test_of_exn_unix_emfile;
      Alcotest.test_case "Unix ENOENT maps to Not_found" `Quick
        test_of_exn_unix_enoent;
    ];
    "to_string", [
      Alcotest.test_case "all variants single-line" `Quick
        test_to_string_single_line;
    ];
  ]
