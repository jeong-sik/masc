(** Tests for Board_attachment_meta — RFC-0037 PR-1.

    Pure-data round-trip + meta_json embedding.  No I/O. *)

open Alcotest
open Masc
module BAM = Board_attachment_meta

(* Initialize crypto RNG once — required by Random_id.prefixed via
   Mirage_crypto_rng. Same pattern as test_board_karma_ledger,
   test_board_moderation, test_board_curation, etc. *)
let () = Mirage_crypto_rng_unix.use_default ()

let sample_attachment ?(kind = BAM.Image) ?(width = Some 1920)
    ?(height = Some 1080) ?(name = "diagram.png") () : BAM.t =
  {
    id = BAM.Id.generate ();
    kind;
    origin_url = "https://example.com/upload/diagram.png";
    origin_name = name;
    origin_size_bytes = 524288;
    mime_type = "image/png";
    width;
    height;
    created_at = 1714989600.0;
  }

let attachment_eq (a : BAM.t) (b : BAM.t) : bool =
  BAM.Id.equal a.id b.id
  && a.kind = b.kind
  && String.equal a.origin_url b.origin_url
  && String.equal a.origin_name b.origin_name
  && a.origin_size_bytes = b.origin_size_bytes
  && String.equal a.mime_type b.mime_type
  && a.width = b.width
  && a.height = b.height
  && Float.equal a.created_at b.created_at

let attachment_pp fmt (t : BAM.t) =
  Format.fprintf fmt
    "{id=%s; kind=%s; origin_url=%s; origin_size_bytes=%d}"
    (BAM.Id.to_string t.id)
    (BAM.kind_to_string t.kind)
    t.origin_url
    t.origin_size_bytes

let attachment_testable = testable attachment_pp attachment_eq

(* --- Id discipline --- *)

let test_id_generate_prefix () =
  let id = BAM.Id.generate () in
  let s = BAM.Id.to_string id in
  check bool "generated id has 'a-' prefix" true
    (String.length s > 2 && String.sub s 0 2 = "a-")

let test_id_of_string_valid () =
  match BAM.Id.of_string "a-abcdef0123" with
  | Ok _ -> ()
  | Error _ -> fail "valid id rejected"

let test_id_of_string_rejects_path_traversal () =
  match BAM.Id.of_string "../etc/passwd" with
  | Ok _ -> fail "path traversal accepted"
  | Error _ -> ()

let test_id_of_string_rejects_slash () =
  match BAM.Id.of_string "a/b" with
  | Ok _ -> fail "slash accepted"
  | Error _ -> ()

let test_id_of_string_rejects_too_long () =
  let s = String.make 65 'x' in
  match BAM.Id.of_string s with
  | Ok _ -> fail "65-char id accepted"
  | Error _ -> ()

let test_id_of_string_rejects_empty () =
  match BAM.Id.of_string "" with
  | Ok _ -> fail "empty id accepted"
  | Error _ -> ()

(* --- Kind round-trip --- *)

let test_kind_round_trip () =
  let all = [BAM.Image; BAM.Video; BAM.Youtube; BAM.External_link] in
  List.iter (fun k ->
    let s = BAM.kind_to_string k in
    match BAM.kind_of_string s with
    | Ok k' when k = k' -> ()
    | Ok _ -> failf "kind drift: %s" s
    | Error _ -> failf "rejected own output: %s" s
  ) all

let test_kind_unknown () =
  match BAM.kind_of_string "audio" with
  | Ok _ -> fail "unknown kind accepted"
  | Error _ -> ()

(* --- to_yojson / of_yojson round-trip --- *)

let test_yojson_round_trip_image () =
  let a = sample_attachment () in
  let json = BAM.to_yojson a in
  match BAM.of_yojson json with
  | Ok a' -> check attachment_testable "round-trip image" a a'
  | Error e -> failf "round-trip failed: %s" (BAM.error_to_string e)

let test_yojson_round_trip_each_kind () =
  List.iter (fun kind ->
    let a = sample_attachment ~kind () in
    let json = BAM.to_yojson a in
    match BAM.of_yojson json with
    | Ok a' -> check attachment_testable
                 (Printf.sprintf "round-trip %s" (BAM.kind_to_string kind)) a a'
    | Error e -> failf "round-trip %s failed: %s"
                   (BAM.kind_to_string kind) (BAM.error_to_string e)
  ) [BAM.Image; BAM.Video; BAM.Youtube; BAM.External_link]

let test_yojson_optional_dimensions_absent () =
  let a = sample_attachment ~width:None ~height:None () in
  let json = BAM.to_yojson a in
  match BAM.of_yojson json with
  | Ok a' ->
    check (option int) "width None" None a'.width;
    check (option int) "height None" None a'.height
  | Error e -> failf "round-trip None dims: %s" (BAM.error_to_string e)

let test_yojson_rejects_unknown_shape () =
  let bogus : Yojson.Safe.t = `Int 42 in
  match BAM.of_yojson bogus with
  | Ok _ -> fail "non-object accepted"
  | Error _ -> ()

let test_yojson_rejects_missing_field () =
  let json : Yojson.Safe.t = `Assoc [("id", `String "a-x")] in
  match BAM.of_yojson json with
  | Ok _ -> fail "missing-field accepted"
  | Error _ -> ()

let test_yojson_rejects_invalid_id () =
  let a = sample_attachment () in
  let json = BAM.to_yojson a in
  let json' = match json with
    | `Assoc kvs ->
      `Assoc (List.map (fun (k, v) ->
        if k = "id" then (k, `String "../oops") else (k, v)
      ) kvs)
    | _ -> json
  in
  match BAM.of_yojson json' with
  | Ok _ -> fail "invalid id accepted"
  | Error _ -> ()

let test_yojson_rejects_invalid_kind () =
  let a = sample_attachment () in
  let json = BAM.to_yojson a in
  let json' = match json with
    | `Assoc kvs ->
      `Assoc (List.map (fun (k, v) ->
        if k = "kind" then (k, `String "audio") else (k, v)
      ) kvs)
    | _ -> json
  in
  match BAM.of_yojson json' with
  | Ok _ -> fail "invalid kind accepted"
  | Error _ -> ()

(* --- meta_json embedding --- *)

let test_meta_attach_from_none () =
  let a = sample_attachment () in
  let meta = BAM.attach_to_post_meta ~existing:None [a] in
  match meta with
  | `Assoc kvs ->
    check int "single key" 1 (List.length kvs);
    check string "key name" BAM.meta_json_key (fst (List.hd kvs))
  | _ -> fail "attach returned non-object"

let test_meta_preserves_other_keys () =
  let existing : Yojson.Safe.t = `Assoc [
    ("foo", `String "bar");
    ("count", `Int 7);
  ] in
  let a = sample_attachment () in
  let meta = BAM.attach_to_post_meta ~existing:(Some existing) [a] in
  match meta with
  | `Assoc kvs ->
    let has key = List.mem_assoc key kvs in
    check bool "foo preserved" true (has "foo");
    check bool "count preserved" true (has "count");
    check bool "attachments added" true (has BAM.meta_json_key)
  | _ -> fail "attach returned non-object"

let test_meta_overwrites_attachments_slot () =
  let existing : Yojson.Safe.t = `Assoc [
    (BAM.meta_json_key, `List [`String "old garbage"]);
    ("other", `String "kept");
  ] in
  let a = sample_attachment () in
  let meta = BAM.attach_to_post_meta ~existing:(Some existing) [a] in
  let parsed = BAM.attachments_of_post_meta (Some meta) in
  check int "slot replaced, not appended" 1 (List.length parsed);
  match meta with
  | `Assoc kvs ->
    check bool "other key preserved" true (List.mem_assoc "other" kvs)
  | _ -> fail "attach returned non-object"

let test_meta_round_trip_multiple () =
  let attachments = [
    sample_attachment ~kind:BAM.Image ~name:"a.png" ();
    sample_attachment ~kind:BAM.Video ~name:"b.mp4" ();
    sample_attachment ~kind:BAM.Youtube ~name:"c.url"
      ~width:None ~height:None ();
  ] in
  let meta = BAM.attach_to_post_meta ~existing:None attachments in
  let parsed = BAM.attachments_of_post_meta (Some meta) in
  check int "count preserved" (List.length attachments) (List.length parsed);
  List.iter2 (fun original recovered ->
    check attachment_testable "round-trip preserves attachment"
      original recovered
  ) attachments parsed

let test_meta_total_on_none () =
  check int "None => []" 0 (List.length (BAM.attachments_of_post_meta None))

let test_meta_total_on_non_object () =
  let bogus : Yojson.Safe.t = `String "not an object" in
  check int "non-object => []"
    0 (List.length (BAM.attachments_of_post_meta (Some bogus)));
  let result = BAM.attachments_of_post_meta_result (Some bogus) in
  check int "non-object reports one error" 1 (List.length result.BAM.errors);
  match result.BAM.errors with
  | [ BAM.Meta_not_object { received = "string" } ] -> ()
  | _ -> fail "non-object attachment meta error not surfaced"

let test_meta_total_on_missing_key () =
  let no_attachments : Yojson.Safe.t = `Assoc [("foo", `String "bar")] in
  check int "missing key => []"
    0 (List.length (BAM.attachments_of_post_meta (Some no_attachments)))

let test_meta_reports_non_list_attachments_slot () =
  let meta : Yojson.Safe.t = `Assoc [(BAM.meta_json_key, `String "not a list")] in
  let parsed = BAM.attachments_of_post_meta (Some meta) in
  check int "non-list attachments => []" 0 (List.length parsed);
  let result = BAM.attachments_of_post_meta_result (Some meta) in
  check int "non-list reports one error" 1 (List.length result.BAM.errors);
  match result.BAM.errors with
  | [ BAM.Attachments_not_list { received = "string" } ] -> ()
  | _ -> fail "non-list attachment slot error not surfaced"

let test_meta_drops_invalid_items () =
  let valid = sample_attachment () in
  let meta : Yojson.Safe.t = `Assoc [
    (BAM.meta_json_key, `List [
      BAM.to_yojson valid;
      `String "garbage";
      `Assoc [("id", `String "a-x")];  (* missing fields *)
    ]);
  ] in
  let parsed = BAM.attachments_of_post_meta (Some meta) in
  check int "invalid items dropped, valid kept" 1 (List.length parsed);
  let result = BAM.attachments_of_post_meta_result (Some meta) in
  check int "result keeps valid attachment" 1 (List.length result.BAM.attachments);
  check int "result reports invalid items" 2 (List.length result.BAM.errors);
  match result.BAM.errors with
  | [ BAM.Attachment_decode_error { index = 1; _ };
      BAM.Attachment_decode_error { index = 2; _ } ] -> ()
  | _ -> fail "invalid attachment item errors not surfaced with item indexes"

(* --- registration --- *)

let () =
  run "Board_attachment_meta" [
    "id discipline", [
      test_case "generate has 'a-' prefix" `Quick test_id_generate_prefix;
      test_case "valid id accepted" `Quick test_id_of_string_valid;
      test_case "rejects path traversal" `Quick
        test_id_of_string_rejects_path_traversal;
      test_case "rejects slash" `Quick test_id_of_string_rejects_slash;
      test_case "rejects > 64 chars" `Quick
        test_id_of_string_rejects_too_long;
      test_case "rejects empty" `Quick test_id_of_string_rejects_empty;
    ];
    "kind", [
      test_case "round-trip all kinds" `Quick test_kind_round_trip;
      test_case "rejects unknown kind" `Quick test_kind_unknown;
    ];
    "yojson", [
      test_case "round-trip image" `Quick test_yojson_round_trip_image;
      test_case "round-trip every kind" `Quick test_yojson_round_trip_each_kind;
      test_case "optional width/height absent" `Quick
        test_yojson_optional_dimensions_absent;
      test_case "rejects unknown JSON shape" `Quick
        test_yojson_rejects_unknown_shape;
      test_case "rejects missing field" `Quick
        test_yojson_rejects_missing_field;
      test_case "rejects invalid id payload" `Quick
        test_yojson_rejects_invalid_id;
      test_case "rejects invalid kind payload" `Quick
        test_yojson_rejects_invalid_kind;
    ];
    "meta_json embedding", [
      test_case "attach from None existing" `Quick test_meta_attach_from_none;
      test_case "preserves other keys" `Quick test_meta_preserves_other_keys;
      test_case "overwrites attachments slot" `Quick
        test_meta_overwrites_attachments_slot;
      test_case "round-trip multiple" `Quick test_meta_round_trip_multiple;
      test_case "total on None" `Quick test_meta_total_on_none;
      test_case "total on non-object" `Quick test_meta_total_on_non_object;
      test_case "total on missing key" `Quick test_meta_total_on_missing_key;
      test_case "reports non-list attachments slot" `Quick
        test_meta_reports_non_list_attachments_slot;
      test_case "drops invalid items" `Quick test_meta_drops_invalid_items;
    ];
  ]
