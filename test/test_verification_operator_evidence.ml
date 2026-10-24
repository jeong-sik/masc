(* The operator projection of submitted evidence: what an image artifact looks
   like on the wire, and that nothing else about the evidence changes. *)

module Store = Workspace_verification_store
module Operator = Workspace_verification_operator_evidence

let ceiling = Store.verification_evidence_max_bytes
let budget = Tool_shard_limits.verification_operator_preview_budget_bytes

let with_base_path f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.temp_dir "operator_evidence_test" "" in
  Fun.protect
    ~finally:(fun () ->
      Fs_compat.clear_fs ();
      Masc_test_deps.cleanup_test_workspace dir)
    (fun () -> f dir)

let png_signature = "\x89PNG\r\n\x1a\n"

(* PNG-signed bytes of an exact length. The projection does not decode the
   picture, so the signature and the length are what the fixture must get
   right. *)
let png_of_length length = png_signature ^ String.make (length - String.length png_signature) 'p'

let sha256_of data = Digestif.SHA256.(digest_string data |> to_hex)

(* A binary item as the capture path files it, so the body is read back from
   disk rather than assumed. *)
let filed_binary ~base_path ~request_id ~index ~format data =
  let body = Store.persist_binary_body ~base_path ~request_id ~index data in
  Store.Evidence_artifact_binary
    { reference = Printf.sprintf "artifact:shot-%d.%s" index format
    ; bytes = String.length data
    ; sha256 = sha256_of data
    ; format
    ; body
    }

let preview_testable =
  let pp formatter = function
    | Operator.Inline { body_base64 } ->
      Format.fprintf formatter "Inline(%d chars)" (String.length body_base64)
    | Operator.Withheld Operator.Not_image_format -> Format.pp_print_string formatter "Not_image_format"
    | Operator.Withheld Operator.Body_not_filed -> Format.pp_print_string formatter "Body_not_filed"
    | Operator.Withheld Operator.Body_unreadable -> Format.pp_print_string formatter "Body_unreadable"
    | Operator.Withheld (Operator.Body_identity_mismatch _) ->
      Format.pp_print_string formatter "Body_identity_mismatch"
    | Operator.Withheld (Operator.Over_delivery_ceiling { bytes; ceiling }) ->
      Format.fprintf formatter "Over_delivery_ceiling(%d, %d)" bytes ceiling
    | Operator.Withheld Operator.Over_response_budget ->
      Format.pp_print_string formatter "Over_response_budget"
  in
  Alcotest.testable pp ( = )

let previews_of ~base_path items =
  Operator.previews ~base_path items |> List.map (function
    | Some preview -> preview
    | None -> Alcotest.fail "a binary item carried no preview")

let test_an_image_under_the_ceiling_is_inline () =
  with_base_path (fun base_path ->
    let data = png_of_length 1000 in
    let item = filed_binary ~base_path ~request_id:"vr-a" ~index:0 ~format:"png" data in
    Alcotest.(check (list preview_testable))
      "inline with the bytes themselves"
      [ Operator.Inline { body_base64 = Base64.encode_string data } ]
      (previews_of ~base_path [ item ]))

let test_the_ceiling_is_inclusive_and_one_more_byte_is_withheld () =
  with_base_path (fun base_path ->
    let at = png_of_length ceiling in
    let over = png_of_length (ceiling + 1) in
    let items =
      [ filed_binary ~base_path ~request_id:"vr-b" ~index:0 ~format:"png" at
      ; filed_binary ~base_path ~request_id:"vr-b" ~index:1 ~format:"png" over
      ]
    in
    Alcotest.(check (list preview_testable))
      "an image of exactly the ceiling is sent, one byte more is named"
      [ Operator.Inline { body_base64 = Base64.encode_string at }
      ; Operator.Withheld (Operator.Over_delivery_ceiling { bytes = ceiling + 1; ceiling })
      ]
      (previews_of ~base_path items))

let test_a_missing_or_unfiled_body_is_named () =
  with_base_path (fun base_path ->
    let data = png_of_length 100 in
    let unfiled =
      Store.Evidence_artifact_binary
        { reference = "artifact:a.png"; bytes = 100; sha256 = sha256_of data
        ; format = "png"; body = None }
    in
    let vanished =
      Store.Evidence_artifact_binary
        { reference = "artifact:b.png"; bytes = 100; sha256 = sha256_of data
        ; format = "png"; body = Some "evidence/vr-c/9.bin" }
    in
    Alcotest.(check (list preview_testable))
      "each missing body has its own cause"
      [ Operator.Withheld Operator.Body_not_filed
      ; Operator.Withheld Operator.Body_unreadable
      ]
      (previews_of ~base_path [ unfiled; vanished ]))

let test_a_body_path_outside_the_evidence_directory_is_not_read () =
  with_base_path (fun base_path ->
    (* A real file next to the evidence directory and one at an absolute path:
       the paths that would reach them are refused, and the bytes never reach
       the response. *)
    let masc_dir = Common.masc_dir_from_base_path ~base_path in
    let data = png_of_length 100 in
    Fs_compat.mkdir_p masc_dir;
    Fs_compat.save_file (Filename.concat masc_dir "secret.bin") data;
    let outside = Filename.concat base_path "outside.bin" in
    Fs_compat.save_file outside data;
    let with_body body =
      Store.Evidence_artifact_binary
        { reference = "artifact:p.png"; bytes = 100; sha256 = sha256_of data
        ; format = "png"; body = Some body }
    in
    let refused =
      [ "evidence/../secret.bin"; "evidence/vr-e/../../secret.bin"; outside
      ; "secret.bin"; "evidence/vr-e/0.png"; "evidence//0.bin"; "evidence/vr-e/0.bin/x" ]
    in
    Alcotest.(check (list preview_testable))
      "every path that is not evidence/<request>/<n>.bin is unreadable"
      (List.map (fun _ -> Operator.Withheld Operator.Body_unreadable) refused)
      (previews_of ~base_path (List.map with_body refused)))

let test_formats_that_never_show_are_not_read () =
  with_base_path (fun base_path ->
    (* The body is never filed: a format that cannot show must be decided
       before any read, so it is [Not_image_format] and not a missing body. *)
    let pdf =
      Store.Evidence_artifact_binary
        { reference = "artifact:r.pdf"; bytes = 5; sha256 = "x"; format = "pdf"; body = None }
    in
    let bare =
      Store.Evidence_artifact_binary
        { reference = "artifact:r"; bytes = 5; sha256 = "x"; format = "unknown"; body = None }
    in
    Alcotest.(check (list preview_testable))
      "only the four image formats are candidates"
      [ Operator.Withheld Operator.Not_image_format
      ; Operator.Withheld Operator.Not_image_format
      ]
      (previews_of ~base_path [ pdf; bare ]))

let test_the_response_budget_is_spent_in_item_order_and_counts_exact_bytes () =
  with_base_path (fun base_path ->
    let images = budget / ceiling in
    let full index =
      filed_binary ~base_path ~request_id:"vr-d" ~index ~format:"png" (png_of_length ceiling)
    in
    let items = List.init (images + 1) full in
    let verdicts = previews_of ~base_path items in
    let inline = function Operator.Inline _ -> true | Operator.Withheld _ -> false in
    Alcotest.(check (list bool))
      "the budget admits exactly its images and then withholds"
      (List.init (images + 1) (fun index -> index < images))
      (List.map inline verdicts);
    Alcotest.(check preview_testable) "the first image past the budget is named"
      (Operator.Withheld Operator.Over_response_budget)
      (List.nth verdicts images))

let test_a_withheld_image_does_not_spend_the_budget () =
  with_base_path (fun base_path ->
    let images = budget / ceiling in
    let full index =
      filed_binary ~base_path ~request_id:"vr-e" ~index ~format:"png" (png_of_length ceiling)
    in
    let too_big =
      filed_binary ~base_path ~request_id:"vr-e" ~index:100 ~format:"png"
        (png_of_length (ceiling + 1))
    in
    let items = (too_big :: List.init images full) in
    let inline = function Operator.Inline _ -> true | Operator.Withheld _ -> false in
    Alcotest.(check (list bool)) "an oversize image ahead of them costs the rest nothing"
      (false :: List.init images (fun _ -> true))
      (List.map inline (previews_of ~base_path items)))

let test_other_kinds_have_no_preview_and_json_is_the_persisted_json () =
  with_base_path (fun base_path ->
    let binary =
      filed_binary ~base_path ~request_id:"vr-f" ~index:0 ~format:"png" (png_of_length 64)
    in
    let others =
      [ Store.Evidence_note "tests green"
      ; Store.Evidence_artifact
          { reference = "artifact:p.json"; content = "{}"; bytes = 2; truncated = false }
      ; Store.Evidence_invalid_reference
      ; Store.Evidence_artifact_unreadable
          { reference = "artifact:gone"; reason = Store.Evidence_missing }
      ; Store.Evidence_collaboration
          { reference = "board:p1"; content = "{}"; sha256 = sha256_of "{}" }
      ]
    in
    let items = binary :: others in
    Alcotest.(check (list bool)) "only the binary item has a preview"
      [ true; false; false; false; false; false ]
      (List.map Option.is_some (Operator.previews ~base_path items));
    let request : Store.request_header =
      { id = "vr-f"; task_id = "task-1"; worker = "w"; created_at = 1.0 }
    in
    let access = Store.Evidence_available { request; items } in
    let operator = Operator.access_to_yojson ~base_path access in
    let persisted = Store.submitted_evidence_access_to_yojson access in
    let items_of json = Yojson.Safe.Util.(json |> member "items" |> to_list) in
    let without_preview = function
      | `Assoc fields -> `Assoc (List.remove_assoc "preview" fields)
      | other -> other
    in
    Alcotest.(check (list string)) "every item is the persisted item once its preview is removed"
      (List.map Yojson.Safe.to_string (items_of persisted))
      (List.map (fun item -> Yojson.Safe.to_string (without_preview item)) (items_of operator));
    List.iter2
      (fun persisted_item operator_item ->
         match persisted_item with
         | `Assoc fields when List.assoc_opt "kind" fields <> Some (`String "artifact_binary") ->
           Alcotest.(check string) "a non-binary item is untouched"
             (Yojson.Safe.to_string persisted_item) (Yojson.Safe.to_string operator_item)
         | _ -> ())
      (items_of persisted) (items_of operator);
    Alcotest.(check string) "the request header is the persisted one"
      (Yojson.Safe.to_string Yojson.Safe.Util.(persisted |> member "request"))
      (Yojson.Safe.to_string Yojson.Safe.Util.(operator |> member "request")))

let test_an_unavailable_access_is_the_persisted_json () =
  with_base_path (fun base_path ->
    let access =
      Store.Evidence_unavailable { request_id = "vr-g"; reason = Store.Request_not_found }
    in
    Alcotest.(check string) "no items, no preview"
      (Yojson.Safe.to_string (Store.submitted_evidence_access_to_yojson access))
      (Yojson.Safe.to_string (Operator.access_to_yojson ~base_path access)))

(* The route's JSON must be what the TUI decodes: same bytes, same media type
   read from the bytes, withheld causes with their numbers. *)
let test_changed_bytes_are_withheld_and_the_tui_retains_the_identity_mismatch () =
  with_base_path (fun base_path ->
    let original = png_of_length 100 in
    let replacement = png_signature ^ String.make (100 - String.length png_signature) 'q' in
    let item = filed_binary ~base_path ~request_id:"vr-changed" ~index:0 ~format:"png" original in
    let path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "evidence/vr-changed/0.bin" in
    Fs_compat.save_file path replacement;
    let mismatch : Store.binary_body_identity_mismatch =
      { expected_bytes = 100; actual_bytes = 100
      ; expected_sha256 = sha256_of original; actual_sha256 = sha256_of replacement } in
    Alcotest.(check (list preview_testable)) "the server withholds the changed body"
      [ Operator.Withheld (Operator.Body_identity_mismatch mismatch) ]
      (previews_of ~base_path [ item ]);
    let request : Store.request_header =
      { id = "vr-changed"; task_id = "task-1"; worker = "w"; created_at = 1.0 } in
    let wire = `Assoc [ "result", `Assoc [ "evidence",
      Operator.access_to_yojson ~base_path (Store.Evidence_available { request; items = [item] }) ] ] in
    match Masc.Tui_decode.decode_verification_evidence wire with
    | Ok (Masc.Tui_decode.Evidence_items
        [ Masc.Tui_decode.Ev_binary
            { ev_b_preview = Masc.Tui_decode.Preview_withheld
                (Masc.Tui_decode.Withheld_body_identity_mismatch
                  { expected_bytes; actual_bytes; expected_sha256; actual_sha256 }); _ } ]) ->
      Alcotest.(check (pair int int)) "the decoder retains both sizes" (100, 100)
        (expected_bytes, actual_bytes);
      Alcotest.(check (pair string string)) "the decoder retains both digests"
        (mismatch.expected_sha256, mismatch.actual_sha256) (expected_sha256, actual_sha256)
    | Ok _ -> Alcotest.fail "the mismatch must remain withheld on the wire"
    | Error detail -> Alcotest.fail detail)

let test_the_tui_decodes_what_the_server_writes () =
  with_base_path (fun base_path ->
    let data = png_of_length 300 in
    let items =
      [ filed_binary ~base_path ~request_id:"vr-h" ~index:0 ~format:"png" data
      ; filed_binary ~base_path ~request_id:"vr-h" ~index:1 ~format:"png" (png_of_length (ceiling + 1))
      ; Store.Evidence_artifact_binary
          { reference = "artifact:r.pdf"; bytes = 5; sha256 = "x"; format = "pdf"; body = None }
      ]
    in
    let request : Store.request_header =
      { id = "vr-h"; task_id = "task-1"; worker = "w"; created_at = 1.0 }
    in
    let wire =
      `Assoc
        [ "result"
        , `Assoc
            [ "evidence"
            , Operator.access_to_yojson ~base_path (Store.Evidence_available { request; items }) ] ]
    in
    match Masc.Tui_decode.decode_verification_evidence wire with
    | Ok
        (Masc.Tui_decode.Evidence_items
          [ Masc.Tui_decode.Ev_binary { ev_b_preview = Masc.Tui_decode.Preview_image { ev_media; ev_data }; _ }
          ; Masc.Tui_decode.Ev_binary
              { ev_b_preview =
                  Masc.Tui_decode.Preview_withheld
                    (Masc.Tui_decode.Withheld_over_delivery_ceiling { bytes; ceiling = wire_ceiling })
              ; _ }
          ; Masc.Tui_decode.Ev_binary
              { ev_b_preview = Masc.Tui_decode.Preview_withheld Masc.Tui_decode.Withheld_not_image_format; _ }
          ]) ->
      Alcotest.(check string) "same bytes" data ev_data;
      Alcotest.(check string) "media type read from the bytes" "image/png"
        (Masc.Keeper_vision_downscale.media_type_to_string ev_media);
      Alcotest.(check int) "over-ceiling size" (ceiling + 1) bytes;
      Alcotest.(check int) "over-ceiling limit" ceiling wire_ceiling
    | Ok _ -> Alcotest.fail "the TUI decoded the items into other shapes"
    | Error detail -> Alcotest.fail detail)

let () =
  Alcotest.run "Verification operator evidence"
    [ ( "preview"
      , [ Alcotest.test_case "an image under the ceiling is inline" `Quick
            test_an_image_under_the_ceiling_is_inline
        ; Alcotest.test_case "the ceiling is inclusive" `Quick
            test_the_ceiling_is_inclusive_and_one_more_byte_is_withheld
        ; Alcotest.test_case "a missing or unfiled body is named" `Quick
            test_a_missing_or_unfiled_body_is_named
        ; Alcotest.test_case "a body path outside the evidence directory is not read" `Quick
            test_a_body_path_outside_the_evidence_directory_is_not_read
        ; Alcotest.test_case "formats that never show are not read" `Quick
            test_formats_that_never_show_are_not_read
        ; Alcotest.test_case "the budget is spent in item order on exact bytes" `Quick
            test_the_response_budget_is_spent_in_item_order_and_counts_exact_bytes
        ; Alcotest.test_case "a withheld image does not spend the budget" `Quick
            test_a_withheld_image_does_not_spend_the_budget
        ] )
    ; ( "wire"
      , [ Alcotest.test_case "other kinds and persisted json are untouched" `Quick
            test_other_kinds_have_no_preview_and_json_is_the_persisted_json
        ; Alcotest.test_case "an unavailable access is the persisted json" `Quick
            test_an_unavailable_access_is_the_persisted_json
        ; Alcotest.test_case "the TUI decodes what the server writes" `Quick
            test_the_tui_decodes_what_the_server_writes
        ; Alcotest.test_case "changed bytes are withheld through the TUI decoder" `Quick
            test_changed_bytes_are_withheld_and_the_tui_retains_the_identity_mismatch
        ] )
    ]
