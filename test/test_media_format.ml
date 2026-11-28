(* Media_format: the document format comes from the package structure, never
   from a file name. The Office parts under fixtures/media_format are the
   [_rels/.rels] and [[Content_Types].xml] LibreOffice 26.8 wrote for
   synthetic documents; the archives around them are built here with zipc. *)

open Alcotest
module D = Document_format
module M = Media_format
module Z = Zip_package_identity

let fixture name =
  In_channel.with_open_bin ("fixtures/media_format/" ^ name) In_channel.input_all
;;

let ok_or_fail = function
  | Ok value -> value
  | Error message -> Alcotest.fail message
;;

type compression =
  | Stored
  | Deflated

let zip ?first members =
  let add archive (path, compression, data) =
    let file =
      ok_or_fail
        (match compression with
         | Stored -> Zipc.File.stored_of_binary_string data
         | Deflated -> Zipc.File.deflate_of_binary_string data)
    in
    Zipc.add (ok_or_fail (Zipc.Member.make ~path (Zipc.Member.File file))) archive
  in
  ok_or_fail (Zipc.to_binary_string ?first (List.fold_left add Zipc.empty members))
;;

let replace ~sub ~by s =
  let n = String.length sub in
  let rec find i =
    if i + n > String.length s
    then Alcotest.failf "%S is not in the fixture" sub
    else if String.equal (String.sub s i n) sub
    then i
    else find (i + 1)
  in
  let i = find 0 in
  String.sub s 0 i ^ by ^ String.sub s (i + n) (String.length s - i - n)
;;

let replace_every ~sub ~by s =
  let pieces = ref [] and start = ref 0 and i = ref 0 in
  let n = String.length sub in
  while !i + n <= String.length s do
    if String.equal (String.sub s !i n) sub
    then (
      pieces := by :: String.sub s !start (!i - !start) :: !pieces;
      i := !i + n;
      start := !i)
    else incr i
  done;
  String.concat "" (List.rev (String.sub s !start (String.length s - !start) :: !pieces))
;;

let fault_to_string : Z.fault -> string = function
  | Archive_unreadable _ -> "archive_unreadable"
  | Repeated_member_name { entries; distinct } ->
    Printf.sprintf "repeated_member_name %d %d" entries distinct
  | Part_too_large { path; declared_bytes } ->
    Printf.sprintf "part_too_large %s %d" path declared_bytes
  | Part_unreadable { path; reason = _ } -> "part_unreadable " ^ path
  | Xml_unreadable { path; reason = _ } -> "xml_unreadable " ^ path
  | No_document_marker -> "no_document_marker"
  | Ooxml_and_hwpx -> "ooxml_and_hwpx"
  | Several_main_parts n -> Printf.sprintf "several_main_parts %d" n
  | Main_part_missing target -> "main_part_missing " ^ target
  | Unsupported_main_part { part; content_type } ->
    Printf.sprintf "unsupported_main_part %s %s" part (Option.value ~default:"-" content_type)
;;

let describe = function
  | M.Document format -> "document " ^ D.extension format
  | M.Encrypted (Some format) -> "encrypted " ^ D.extension format
  | M.Encrypted None -> "encrypted ?"
  | M.Unknown No_document_signature -> "no_document_signature"
  | M.Unknown (Zip_package fault) -> fault_to_string fault
  | M.Unknown (Compound_file _) -> "compound_file"
;;

let expect expected bytes = check string expected expected (describe (M.detect bytes))

(* Office Open XML *)

let word_main = "word/document.xml"
let transitional = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
let strict = "http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument"
let word_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
let rels_namespace = "http://schemas.openxmlformats.org/package/2006/relationships"
let types_namespace = "http://schemas.openxmlformats.org/package/2006/content-types"

let office ?(rels_compression = Deflated) ?rels ?types ?(main = Some word_main) prefix =
  let rels = Option.value rels ~default:(fixture (prefix ^ "-rels.xml")) in
  let types = Option.value types ~default:(Some (fixture (prefix ^ "-content-types.xml"))) in
  zip
    (List.concat
       [ (match types with
          | Some types -> [ "[Content_Types].xml", Deflated, types ]
          | None -> [])
       ; [ "_rels/.rels", rels_compression, rels ]
       ; (match main with
          | Some main -> [ main, Deflated, "<placeholder/>" ]
          | None -> [])
       ])
;;

let docx_rels () = fixture "docx-rels.xml"
let docx_types () = fixture "docx-content-types.xml"

let test_office_formats () =
  expect "document .docx" (office "docx");
  expect "document .xlsx" (office ~main:(Some "xl/workbook.xml") "xlsx");
  expect "document .pptx" (office ~main:(Some "ppt/presentation.xml") "pptx")
;;

let test_target_spellings () =
  let target by = replace ~sub:{|Target="word/document.xml"|} ~by (docx_rels ()) in
  expect "document .docx" (office ~rels:(target {|Target="/word/document.xml"|}) "docx");
  expect "document .docx" (office ~rels:(target {|Target="Word/Document.xml"|}) "docx");
  (* RFC 3986 dot segments, from the package root. *)
  expect "document .docx" (office ~rels:(target {|Target="./word/document.xml"|}) "docx");
  expect
    "document .docx"
    (office ~rels:(target {|Target="word/../word/./document.xml"|}) "docx");
  expect "document .docx" (office ~rels:(target {|Target="../word/document.xml"|}) "docx");
  expect
    "main_part_missing word/document.xml/."
    (office ~rels:(target {|Target="word/document.xml/."|}) "docx");
  expect
    "document .docx"
    (office ~rels:(replace ~sub:transitional ~by:strict (docx_rels ())) "docx")
;;

let test_default_content_type () =
  let types =
    Printf.sprintf
      {|<Types xmlns="%s"><Default Extension="XML" ContentType="%s"/></Types>|}
      types_namespace
      word_type
  in
  expect "document .docx" (office ~types:(Some types) "docx")
;;

let test_main_types_outside_the_set () =
  let with_type by = Some (replace ~sub:word_type ~by (docx_types ())) in
  let macro = "application/vnd.ms-word.document.macroEnabled.main+xml" in
  let template = "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml" in
  expect
    ("unsupported_main_part word/document.xml " ^ macro)
    (office ~types:(with_type macro) "docx");
  expect
    ("unsupported_main_part word/document.xml " ^ template)
    (office ~types:(with_type template) "docx");
  expect "unsupported_main_part word/document.xml -" (office ~types:None "docx")
;;

let test_main_part_references () =
  let rels = docx_rels () in
  let second =
    Printf.sprintf {|<Relationship Id="rId9" Type="%s" Target="word/other.xml"/>|} transitional
  in
  expect
    "several_main_parts 2"
    (office ~rels:(replace ~sub:"</Relationships>" ~by:(second ^ "</Relationships>") rels) "docx");
  let outside =
    Printf.sprintf
      {|<Relationship Id="rId9" Type="%s" Target="https://example.com/a.docx" TargetMode="External"/>|}
      transitional
  in
  expect
    "document .docx"
    (office ~rels:(replace ~sub:"</Relationships>" ~by:(outside ^ "</Relationships>") rels) "docx");
  expect "main_part_missing word/document.xml" (office ~main:None "docx");
  expect
    "main_part_missing word/document.xml"
    (office
       ~rels:
         (replace
            ~sub:{|Target="word/document.xml"|}
            ~by:{|Target="word/document.xml" TargetMode="External"|}
            rels)
       "docx");
  expect
    "xml_unreadable _rels/.rels"
    (office ~rels:(replace ~sub:{|Target="word/document.xml"|} ~by:"" rels) "docx")
;;

let test_unreadable_relationships () =
  expect "xml_unreadable _rels/.rels" (office ~rels:"<Relationships" "docx");
  expect
    "xml_unreadable _rels/.rels"
    (office ~rels:(replace ~sub:rels_namespace ~by:"urn:other" (docx_rels ())) "docx");
  let over part = Z.part_max_bytes part + 1 in
  expect
    (Printf.sprintf "part_too_large _rels/.rels %d" (over Relationships))
    (office ~rels:(String.make (over Relationships) ' ') "docx");
  expect
    (Printf.sprintf "part_too_large [Content_Types].xml %d" (over Content_types))
    (office ~types:(Some (String.make (over Content_types) ' ')) "docx")
;;

(* zipc keeps one member per name, so the archive is written with a stand-in
   of the same length and renamed in its bytes afterwards. *)
let test_repeated_member_name () =
  let stand_in = "[Content_Types].xmQ" in
  let archive =
    zip
      [ "[Content_Types].xml", Deflated, docx_types ()
      ; "_rels/.rels", Deflated, docx_rels ()
      ; word_main, Deflated, "<placeholder/>"
      ; stand_in, Deflated, fixture "xlsx-content-types.xml"
      ]
  in
  expect "repeated_member_name 4 3" (replace_every ~sub:stand_in ~by:"[Content_Types].xml" archive)
;;

let le16 s i = Char.code s.[i] lor (Char.code s.[i + 1] lsl 8)
let le32 s i = le16 s i lor (le16 s (i + 2) lsl 16)

(* The central directory file header of [path] (APPNOTE 4.3.12): signature
   PK\001\002, name length at 28, name at 46. *)
let central_entry archive path =
  let rec find i =
    if i + 46 > String.length archive
    then Alcotest.failf "no central directory entry for %s" path
    else if String.equal (String.sub archive i 4) "PK\001\002"
            && String.equal (String.sub archive (i + 46) (le16 archive (i + 28))) path
    then i
    else find (i + 1)
  in
  find 0
;;

let patch archive offset replacement =
  let b = Bytes.of_string archive in
  Bytes.blit_string replacement 0 b offset (String.length replacement);
  Bytes.to_string b
;;

let test_damaged_parts () =
  let archive = office ~rels_compression:Stored "docx" in
  let data = String.length archive / 2 in
  expect "archive_unreadable" (String.sub archive 0 data);
  let flipped = replace ~sub:"officeDocument/2006" ~by:"officeDocument/2007" archive in
  expect "part_unreadable _rels/.rels" flipped;
  let entry = central_entry archive "_rels/.rels" in
  let one_byte_short = le32 archive (entry + 24) - 1 in
  let size = String.init 4 (fun k -> Char.chr ((one_byte_short lsr (8 * k)) land 0xff)) in
  expect "part_unreadable _rels/.rels" (patch archive (entry + 24) size);
  let directory_mode = 0o40755 in
  let mode = String.init 2 (fun k -> Char.chr ((directory_mode lsr (8 * k)) land 0xff)) in
  expect "part_unreadable _rels/.rels" (patch archive (entry + 40) mode)
;;

(* zipc 0.2.0 raises Invalid_argument on this Deflate data: a dynamic block
   whose distance code lengths are all zero, then a length symbol. The
   archive holds only [_rels/.rels]; a review generator wrote it. *)
let test_malformed_deflate () =
  expect "part_unreadable _rels/.rels" (fixture "deflate-without-distance-codes.zip");
  let archive = office "docx" in
  let crc = central_entry archive "_rels/.rels" + 16 in
  let flipped = le32 archive crc lxor 1 in
  let value = String.init 4 (fun k -> Char.chr ((flipped lsr (8 * k)) land 0xff)) in
  expect "part_unreadable _rels/.rels" (patch archive crc value)
;;

let test_part_names_ignore_case () =
  let types = docx_types () and rels = docx_rels () in
  expect
    "document .docx"
    (zip
       [ "[content_types].XML", Deflated, types
       ; "_RELS/.rels", Deflated, rels
       ; "Word/Document.xml", Deflated, "<placeholder/>"
       ]);
  expect
    "part_unreadable _rels/.rels"
    (zip
       [ "[Content_Types].xml", Deflated, types
       ; "_rels/.rels", Deflated, rels
       ; "_RELS/.RELS", Deflated, rels
       ; word_main, Deflated, "<placeholder/>"
       ])
;;

(* HWPX *)

let manifest_namespace = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"

let manifest body =
  Printf.sprintf
    {|<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><odf:manifest xmlns:odf="%s">%s</odf:manifest>|}
    manifest_namespace
    body
;;

let encrypted_entry =
  {|<odf:file-entry full-path="Contents/section0.xml" media-type="application/xml" size="1024"><odf:encryption-data checksum-type="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0#sha256-1k" checksum="AAAA"><odf:algorithm algorithm-name="http://www.w3.org/2001/04/xmlenc#aes256-cbc" initialisation-vector="AAAA"/></odf:encryption-data></odf:file-entry>|}
;;

let hwpx ?first ?(mimetype = "application/hwp+zip") ?(compression = Stored) ?manifest extra =
  zip
    ?first
    (List.concat
       [ [ "mimetype", compression, mimetype
         ; "version.xml", Deflated, "<version/>"
         ; "Contents/content.hpf", Deflated, "<package/>"
         ; "Contents/header.xml", Deflated, "<head/>"
         ; "Contents/section0.xml", Deflated, "<sec/>"
         ]
       ; (match manifest with
          | Some body -> [ "META-INF/manifest.xml", Deflated, body ]
          | None -> [])
       ; extra
       ])
;;

let test_hwpx_marker () =
  expect "document .hwpx" (hwpx []);
  (* 61 of the 521 ZIP .hwpx samples in the rhwp repository (1a76570e83)
     keep [mimetype] deflated or behind another member. *)
  expect
    "document .hwpx"
    (hwpx ~first:"Contents/header.xml" ~compression:Deflated []);
  expect "no_document_marker" (hwpx ~mimetype:"application/hwp+zip\n" []);
  expect "no_document_marker" (hwpx ~mimetype:"application/epub+zip" []);
  expect "no_document_marker" (zip [ "readme.txt", Deflated, "plain" ]);
  let over = Z.part_max_bytes Mimetype + 1 in
  expect
    (Printf.sprintf "part_too_large mimetype %d" over)
    (hwpx ~mimetype:(String.make over 'a') []);
  expect
    "ooxml_and_hwpx"
    (hwpx [ "_rels/.rels", Deflated, docx_rels (); word_main, Deflated, "<w/>" ])
;;

let test_hwpx_encryption () =
  expect "encrypted .hwpx" (hwpx ~manifest:(manifest encrypted_entry) []);
  let over = Z.part_max_bytes Manifest + 1 in
  expect
    (Printf.sprintf "part_too_large META-INF/manifest.xml %d" over)
    (hwpx ~manifest:(String.make over ' ') []);
  expect "document .hwpx" (hwpx ~manifest:(manifest "") []);
  expect
    "document .hwpx"
    (hwpx
       ~manifest:
         (manifest {|<odf:file-entry full-path="Contents/section0.xml" media-type="application/xml"/>|})
       []);
  let foreign =
    {|<odf:file-entry full-path="a.xml"><x:encryption-data xmlns:x="urn:other"/></odf:file-entry>|}
  in
  expect "document .hwpx" (hwpx ~manifest:(manifest foreign) []);
  expect "xml_unreadable META-INF/manifest.xml" (hwpx ~manifest:"<odf:manifest" [])
;;

(* Package XML *)

let utf16le ascii =
  "\xff\xfe" ^ String.concat "" (List.init (String.length ascii) (fun i -> String.make 1 ascii.[i] ^ "\x00"))
;;

let test_package_xml () =
  let rels = docx_rels () in
  expect
    "document .docx"
    (office ~rels:(utf16le (replace ~sub:{|encoding="UTF-8"|} ~by:{|encoding="UTF-16"|} rels)) "docx");
  expect
    "xml_unreadable _rels/.rels"
    (office ~rels:(replace ~sub:{|Id="rId1"|} ~by:{|Id="rId1" Id="rId2"|} rels) "docx");
  expect
    "xml_unreadable [Content_Types].xml"
    (office
       ~types:(Some (replace ~sub:"<Types" ~by:"<!DOCTYPE Types []><Types" (docx_types ())))
       "docx");
  expect "document .docx" (office ~rels:(rels ^ "<!-- end -->\n") "docx");
  expect "xml_unreadable _rels/.rels" (office ~rels:(rels ^ "<Relationships/>") "docx")
;;

(* The two shapes that fill the largest part with the most markup: one start
   tag with as many attributes as fit, and elements nested as deep as fit.
   markup 1.0.3 compares each attribute with every one before it, so the
   first shape costs it time quadratic in the attribute count. *)
let test_package_xml_cost () =
  let room = Z.part_max_bytes Manifest - String.length (manifest "") - 64 in
  let attributes = Buffer.create room in
  let rec add i =
    let next = Printf.sprintf " a%d=\"\"" i in
    if Buffer.length attributes + String.length next < room
    then (
      Buffer.add_string attributes next;
      add (i + 1))
  in
  add 0;
  let wide = Printf.sprintf "<odf:file-entry%s/>" (Buffer.contents attributes) in
  let levels = room / String.length "<odf:x></odf:x>" in
  let repeat piece = String.concat "" (List.init levels (fun _ -> piece)) in
  let deep = repeat "<odf:x>" ^ repeat "</odf:x>" in
  List.iter
    (fun (shape, body) ->
       let archive = hwpx ~manifest:(manifest body) [] in
       let started = Sys.time () in
       expect "document .hwpx" archive;
       let seconds = Sys.time () -. started in
       if seconds > 1.0 then Alcotest.failf "%s took %.2f s of CPU" shape seconds)
    [ "one start tag", wide; "deep nesting", deep ]
;;

(* Signatures and wire names *)

let test_signatures () =
  expect "document .pdf" "%PDF-1.7\n%\xe2\xe3\xcf\xd3\n";
  expect "no_document_signature" "";
  expect "no_document_signature" "PDF-1.7";
  expect "no_document_signature" "hello"
;;

let test_wire_mime () =
  List.iter
    (fun format ->
       check
         (option string)
         (D.extension format)
         (Some (D.extension format))
         (Option.map D.extension (D.of_wire_mime (D.wire_mime format))))
    D.all;
  let mimes = List.map D.wire_mime D.all in
  check int "distinct wire MIME types" (List.length mimes) (List.length (List.sort_uniq compare mimes));
  check bool "octet-stream" true (Option.is_none (D.of_wire_mime "application/octet-stream"));
  check bool "exact spelling only" true (Option.is_none (D.of_wire_mime "Application/PDF"))
;;

(* Every byte string gets an answer. Flipping or cutting bytes of real
   packages never raises; the seed is fixed so a failure reproduces. *)
let test_mutations_always_answer () =
  let state = Random.State.make [| 20261128 |] in
  let mutate seed =
    let b = Bytes.of_string seed in
    for _ = 1 to 1 + Random.State.int state 6 do
      Bytes.set b (Random.State.int state (Bytes.length b)) (Char.chr (Random.State.int state 256))
    done;
    let s = Bytes.to_string b in
    if Random.State.int state 20 = 0 then String.sub s 0 (Random.State.int state (String.length s)) else s
  in
  List.iter
    (fun (name, seed) ->
       for _ = 1 to 2000 do
         let input = mutate seed in
         match M.detect input with
         | M.Document _ | M.Encrypted _ | M.Unknown _ -> ()
         | exception e -> Alcotest.failf "%s mutation raised %s" name (Printexc.to_string e)
       done)
    [ "docx", office "docx"
    ; "stored docx", office ~rels_compression:Stored "docx"
    ; "hwpx", hwpx ~manifest:(manifest "") []
    ; "encrypted hwpx", hwpx ~manifest:(manifest encrypted_entry) []
    ; "malformed deflate", fixture "deflate-without-distance-codes.zip"
    ]
;;

let () =
  run
    "media_format"
    [ ( "office open xml"
      , [ test_case "the three formats" `Quick test_office_formats
        ; test_case "target spellings" `Quick test_target_spellings
        ; test_case "default content type" `Quick test_default_content_type
        ; test_case "main types outside the set" `Quick test_main_types_outside_the_set
        ; test_case "main part references" `Quick test_main_part_references
        ; test_case "unreadable relationships" `Quick test_unreadable_relationships
        ; test_case "damaged parts" `Quick test_damaged_parts
        ; test_case "malformed deflate" `Quick test_malformed_deflate
        ; test_case "part names ignore case" `Quick test_part_names_ignore_case
        ; test_case "repeated member name" `Quick test_repeated_member_name
        ; test_case "package XML" `Quick test_package_xml
        ; test_case "package XML cost" `Quick test_package_xml_cost
        ] )
    ; ( "hwpx"
      , [ test_case "mimetype marker" `Quick test_hwpx_marker
        ; test_case "manifest encryption" `Quick test_hwpx_encryption
        ] )
    ; ( "signatures"
      , [ test_case "pdf and unknown" `Quick test_signatures
        ; test_case "wire MIME" `Quick test_wire_mime
        ; test_case "mutations always answer" `Quick test_mutations_always_answer
        ] )
    ]
;;
