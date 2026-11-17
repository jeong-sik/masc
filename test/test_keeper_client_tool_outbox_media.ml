open Alcotest

module Media = Masc.Keeper_client_tool_outbox_media
module P = Llm_provider.Types

let reference ?(mime = "application/octet-stream") () =
  match Tool_output.make_artifact_ref ~sha256:(String.make 64 'a') ~bytes:7
      ~preview:"opaque bytes" ~mime with
  | Ok reference -> reference
  | Error error -> fail (Tool_output.make_error_to_string error)

let normalized ?mime () =
  Tool_output.normalized_artifact_ref_to_json (reference ?mime ())

let response blocks =
  `Assoc ["success", `Bool true; "content", `String "returned data";
          "content_blocks", `List blocks]

let artifact ?(media_type = "application/pdf") ?(original = normalized ()) kind =
  `Assoc ["type", `String kind; "media_type", `String media_type; "artifact", original]

let fields = function
  | `Assoc fields -> fields
  | _ -> fail "object fixture required"

let unavailable ~kind ~media_type reason block =
  match Media.host_attachments (response [block]) with
  | [Media.Unavailable value] ->
    check int "exact slot" 0 value.slot;
    check bool "typed kind" true (value.kind = kind);
    check (option string) "declared MIME" media_type value.media_type;
    check string "closed diagnostic" (Media.unavailable_reason_to_string reason)
      (Media.unavailable_reason_to_string value.reason)
  | [Media.Readable _] -> fail "unavailable media must not become a readable reference"
  | [] | _ :: _ -> fail "one unavailable slot required"

let test_exact_producer_slots () =
  let document = artifact ~media_type:"Application/PDF; profile=Original" "document" in
  let audio = artifact ~media_type:"audio/wav" "audio" in
  let nested = `Assoc ["type", `String "tool_result"; "content", `List [document]] in
  let input = response [ `Assoc ["type", `String "text"; "text", `String "data"];
    document; artifact "image"; audio; document; nested ] in
  let before = Yojson.Safe.to_string input in
  (match Media.host_attachments input with
   | [Media.Readable first; Media.Readable second; Media.Readable third] ->
     check (list int) "opaque slots count and repeated references remain occurrences"
       [1;3;4] [first.slot;second.slot;third.slot];
     check bool "document kind is declared" true (first.kind = Media.Document);
     check bool "audio kind is declared" true (second.kind = Media.Audio);
     check string "declared MIME is not normalized or inferred"
       "Application/PDF; profile=Original" first.media_type;
     check string "binary label is separate" "application/octet-stream" first.original.mime;
     check bool "original normalized reference survives" true
       (Tool_output.normalized_artifact_ref_to_json first.original = normalized ());
     check bool "same artifact remains another occurrence" true (third.original = first.original)
   | _ -> fail "only three explicit top-level retained media slots are readable");
  check string "input JSON is unchanged" before (Yojson.Safe.to_string input)

let test_response_authority () =
  let block = artifact "document" in
  let valid = fields (response [block]) in
  List.iter (fun input ->
    check int "non-host response remains opaque" 0 (List.length (Media.host_attachments input)))
    [ `Assoc ["content_blocks", `List [block]]
    ; `Assoc (("success", `Bool true) :: valid)
    ; `Assoc (("content_blocks", `List [block]) :: valid)
    ; `Assoc (("extra", `Null) :: valid)
    ; `Assoc ["success", `String "true"; "content", `String "data";
              "content_blocks", `List [block]]
    ; `Assoc ["success", `Bool true; "content", `Null; "content_blocks", `List [block]]
    ; `Assoc ["success", `Bool true; "content", `String "data"; "content_blocks", block]
    ; `Assoc ["success", `Bool false; "content", `String "data"; "content_blocks", `Null]
    ; `Assoc ["result", `Assoc ["contentItems", `List [block]]]
    ; `List [response [block]]; `Null ];
  match Media.host_attachments
      (`Assoc ["success", `Bool false; "content", `String "tool failure";
               "content_blocks", `List [block]]) with
  | [Media.Readable _] -> ()
  | _ -> fail "returned failure may still carry an original attachment"

let test_ambiguous_kind () =
  let original = fields (artifact "document") in
  unavailable ~kind:(Some Media.Document) ~media_type:(Some "application/pdf")
    Media.Ambiguous_type (`Assoc (("type", `String "document") :: original));
  unavailable ~kind:None ~media_type:(Some "application/pdf") Media.Ambiguous_type
    (`Assoc (("type", `String "audio") :: original));
  unavailable ~kind:None ~media_type:(Some "application/pdf") Media.Ambiguous_type
    (`Assoc (("type", `String "text") :: original))

let test_exact_attachment_fields () =
  let original = fields (artifact "document") in
  List.iter (fun block ->
    unavailable ~kind:(Some Media.Document) ~media_type:(Some "application/pdf")
      Media.Malformed_attachment block)
    [ `Assoc (("extra", `Null) :: original)
    ; `Assoc (("source", `Assoc ["type", `String "url"; "data", `String "https://invalid.test/x"])
              :: original)
    ; `Assoc (("artifact", normalized ()) :: original)
    ; `Assoc (("undecodable_base64", normalized ~mime:"text/plain" ()) :: original) ];
  unavailable ~kind:(Some Media.Document) ~media_type:None Media.Malformed_attachment
    (`Assoc (("media_type", `String "audio/wav") :: original));
  unavailable ~kind:(Some Media.Document) ~media_type:None Media.Malformed_attachment
    (`Assoc ["type", `String "document"; "artifact", normalized ()])

let test_reference_authority () =
  List.iter (fun original ->
    unavailable ~kind:(Some Media.Document) ~media_type:(Some "application/pdf")
      Media.Invalid_artifact_reference (artifact ~original "document"))
    [ `Assoc ["sha256", `String (String.make 64 'a'); "bytes", `Int 7]
    ; `Assoc ["_blob", `Assoc ["sha256", `String "bad"]]
    ; `Assoc (("extra", `Null) :: fields (normalized ())) ];
  unavailable ~kind:(Some Media.Document) ~media_type:(Some "application/pdf")
    Media.Non_binary_artifact (artifact ~original:(normalized ~mime:"application/pdf" ()) "document");
  unavailable ~kind:(Some Media.Document) ~media_type:(Some "application/pdf")
    Media.Non_binary_artifact
    (artifact ~original:(normalized ~mime:Tool_output.artifact_manifest_mime ()) "document")

let wire block =
  match Agent_core.Checkpoint.wire_content_block_to_json_result ~scope:"outbox-media-fixture" block with
  | Ok json -> json
  | Error error -> fail (Agent_core.Error.to_string error)

let test_nonstored_and_undecodable () =
  List.iter (fun source ->
    unavailable ~kind:(Some Media.Document) ~media_type:(Some "application/pdf")
      Media.Reference_not_fetched (wire (P.Document {media_type="application/pdf";source})))
    [P.Url "https://invalid.test/private.pdf"; P.File_id "opaque-file-id"];
  unavailable ~kind:(Some Media.Audio) ~media_type:(Some "audio/wav")
    Media.Inline_media_not_materialized
    (wire (P.Audio {media_type="audio/wav";source=P.Base64 "not decoded by this projection"}));
  unavailable ~kind:(Some Media.Document) ~media_type:(Some "application/pdf")
    Media.Undecodable_base64
    (`Assoc ["type", `String "document"; "media_type", `String "application/pdf";
             "undecodable_base64", normalized ~mime:"text/plain" ();
             "detail", `String "private decoder detail must not be echoed"])

let test_unrelated_payload_and_carrier_unchanged () =
  let held = artifact "document" in
  let unrelated = response
      [ `Assoc ["type", `String "text"; "text", `String (Yojson.Safe.to_string held)]
      ; `Assoc ["type", `String "tool_result"; "content", `List [held]]
      ; `Assoc ["media_type", `String "application/pdf"; "artifact", normalized ()]
      ; artifact "image" ] in
  check int "no recursive data or MIME inference" 0 (List.length (Media.host_attachments unrelated));
  let receipt = `Assoc ["response", response [held]] in
  check bool "existing carrier keeps normalized original unchanged" true
    (Media.carrier_row receipt = receipt);
  let original = `Assoc ["response", response
      [wire (P.Document {media_type="application/pdf";source=P.Base64 "YQ=="})]] in
  let projected = Media.carrier_row original in
  check bool "existing carrier still omits inline bytes" false (projected = original);
  check bool "carrier projection is stable" true (Media.carrier_row projected = projected)

let () =
  run "Retained host media decoder"
    [ "authority",
      [ test_case "exact producer slots and identities" `Quick test_exact_producer_slots
      ; test_case "exact response authority and null" `Quick test_response_authority
      ; test_case "ambiguous type preserves known kind" `Quick test_ambiguous_kind
      ; test_case "extra fields and source collisions refuse reading" `Quick test_exact_attachment_fields
      ; test_case "strict normalized binary reference" `Quick test_reference_authority
      ; test_case "nonstored and undecodable media are unavailable" `Quick test_nonstored_and_undecodable
      ; test_case "unrelated data and carrier behavior stay intact" `Quick test_unrelated_payload_and_carrier_unchanged
      ] ]
