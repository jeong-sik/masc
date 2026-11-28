type ooxml =
  | Word
  | Spreadsheet
  | Presentation

type identity =
  | Ooxml of ooxml
  | Hwpx of { encrypted : bool }

type fault =
  | Archive_unreadable of string
  | Repeated_member_name of
      { entries : int
      ; distinct : int
      }
  | Part_too_large of
      { path : string
      ; declared_bytes : int
      }
  | Part_unreadable of
      { path : string
      ; reason : string
      }
  | Xml_unreadable of
      { path : string
      ; reason : string
      }
  | No_document_marker
  | Ooxml_and_hwpx
  | Several_main_parts of int
  | Main_part_missing of string
  | Unsupported_main_part of
      { part : string
      ; content_type : string option
      }

type part =
  | Relationships
  | Content_types
  | Mimetype
  | Manifest

let ( let* ) = Result.bind

let part_path = function
  | Relationships -> "_rels/.rels"
  | Content_types -> "[Content_Types].xml"
  | Mimetype -> "mimetype"
  | Manifest -> "META-INF/manifest.xml"
;;

(* The largest of each part in the L2 survey's ZIP samples (8 Office
   packages, 516 HWPX) was 727 B, 14.5 KB (a 40-slide deck, about 360 B a
   slide), 19 B and 4.9 KB. A MiB of repeated markup deflates to about
   2 KB, so the limit is on the declared expanded size. One upload parses at
   most 320 KiB of XML: [_rels/.rels] and one 256 KiB part. Package_xml took
   at most 0.03 s of CPU on a 256 KiB part of the costliest shapes measured
   (one start tag with 30,000 attributes, 37,000 nested elements; xmlm 1.4.0,
   M3 Max, Sys.time). *)
let part_max_bytes = function
  | Relationships -> 64 * 1024
  | Content_types -> 256 * 1024
  | Mimetype -> 1024
  | Manifest -> 256 * 1024
;;

let relationships_namespace = "http://schemas.openxmlformats.org/package/2006/relationships"
let content_types_namespace = "http://schemas.openxmlformats.org/package/2006/content-types"
let manifest_namespace = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"
let hwpx_mimetype = "application/hwp+zip"

(* The package relationship to the main part: ECMA-376 transitional and
   ISO/IEC 29500 strict spell it differently. *)
let office_document_relationship_types =
  [ "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
  ; "http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument"
  ]
;;

let main_part_kinds =
  [ "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", Word
  ; ( "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
    , Spreadsheet )
  ; ( "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
    , Presentation )
  ]
;;

let expand ~max_bytes ~path file =
  let declared = Zipc.File.decompressed_size file in
  let unreadable reason = Error (Part_unreadable { path; reason }) in
  let* bytes =
    if declared > max_bytes
    then Error (Part_too_large { path; declared_bytes = declared })
    else if Zipc.File.is_encrypted file
    then unreadable "the member is encrypted"
    else (
      (* WORKAROUND: zipc 0.2.0's inflater raises Invalid_argument instead of
         returning Error on a dynamic block with no distance codes followed
         by a length symbol (https://github.com/dbuenzli/zipc/issues/13).
         decompress 1.6.1 raises Invalid_argument on other mutated members,
         so changing inflaters does not remove the class. Root fix: a zipc
         release with https://github.com/dbuenzli/zipc/pull/14, then this
         handler goes. *)
      match Zipc.File.to_binary_string file with
      | Ok bytes -> Ok bytes
      | Error reason -> unreadable reason
      | exception Invalid_argument reason -> unreadable ("malformed Deflate data: " ^ reason))
  in
  let expanded = String.length bytes in
  if expanded = declared
  then Ok bytes
  else
    unreadable
      (Printf.sprintf "expanded to %d bytes; the central directory says %d" expanded declared)
;;

(* OPC part names compare ASCII case-insensitively (ECMA-376 Part 2 §9.1.1),
   so two members whose names differ only in case are one part written twice
   and the package is unreadable. The HWPX entries ([mimetype],
   [META-INF/manifest.xml]) follow ODF and are named exactly. *)
type naming =
  | Part_name
  | Exact_name

let find_member ~naming archive name =
  match naming with
  | Exact_name -> Ok (Zipc.find name archive)
  | Part_name ->
    let wanted = String.lowercase_ascii name in
    let matches =
      Zipc.fold
        (fun member acc ->
           if String.equal (String.lowercase_ascii (Zipc.Member.path member)) wanted
           then member :: acc
           else acc)
        archive
        []
    in
    (match matches with
     | [] -> Ok None
     | [ member ] -> Ok (Some member)
     | _ :: _ :: _ ->
       Error
         (Part_unreadable
            { path = name
            ; reason =
                Printf.sprintf
                  "%d members share this name when case is ignored"
                  (List.length matches)
            }))
;;

let read_part archive part =
  let path = part_path part in
  let naming =
    match part with
    | Relationships | Content_types -> Part_name
    | Mimetype | Manifest -> Exact_name
  in
  let* found = find_member ~naming archive path in
  match found with
  | None -> Ok None
  | Some member ->
    (match Zipc.Member.kind member with
     | Zipc.Member.Dir -> Error (Part_unreadable { path; reason = "the member is a directory" })
     | Zipc.Member.File file ->
       Result.map Option.some (expand ~max_bytes:(part_max_bytes part) ~path file))
;;

let named ~namespace ~name (element : Package_xml.element) =
  let element_namespace, local = element.name in
  String.equal element_namespace namespace && String.equal local name
;;

(* The elements below the root, after checking the root is {namespace}name. *)
let descendants ~path ~namespace ~name bytes =
  let unreadable reason = Error (Xml_unreadable { path; reason }) in
  match Package_xml.elements bytes with
  | Error reason -> unreadable reason
  | Ok [] -> unreadable "no root element"
  | Ok (root :: below) ->
    if named ~namespace ~name root
    then Ok below
    else (
      let root_namespace, root_name = root.name in
      unreadable
        (Printf.sprintf "the root is {%s}%s, not {%s}%s" root_namespace root_name namespace name))
;;

let children_named ~namespace ~name elements =
  List.filter
    (fun (element : Package_xml.element) -> element.depth = 1 && named ~namespace ~name element)
    elements
;;

type main_part_reference =
  | In_package of string
  | Outside_package of string

let main_part_references archive =
  let* relationships = read_part archive Relationships in
  match relationships with
  | None -> Ok []
  | Some bytes ->
    let path = part_path Relationships in
    let* elements =
      descendants ~path ~namespace:relationships_namespace ~name:"Relationships" bytes
    in
    let relationships =
      children_named ~namespace:relationships_namespace ~name:"Relationship" elements
    in
    let is_main element =
      match Package_xml.attribute "Type" element with
      | Some kind -> List.mem kind office_document_relationship_types
      | None -> false
    in
    List.filter is_main relationships
    |> List.fold_left
         (fun acc element ->
            let* references = acc in
            let unreadable reason = Error (Xml_unreadable { path; reason }) in
            match Package_xml.attribute "Target" element, Package_xml.attribute "TargetMode" element with
            | None, (None | Some _) -> unreadable "an officeDocument relationship has no Target"
            | Some target, (None | Some "Internal") -> Ok (In_package target :: references)
            | Some target, Some "External" -> Ok (Outside_package target :: references)
            | Some _, Some mode -> unreadable (Printf.sprintf "TargetMode is %S" mode))
         (Ok [])
;;

let lowercase_extension part =
  let segment =
    match String.rindex_opt part '/' with
    | Some slash -> String.sub part (slash + 1) (String.length part - slash - 1)
    | None -> part
  in
  match String.rindex_opt segment '.' with
  | Some dot ->
    Some (String.lowercase_ascii (String.sub segment (dot + 1) (String.length segment - dot - 1)))
  | None -> None
;;

(* An Override names one part; otherwise the Default for the part's extension
   applies (ECMA-376 Part 2 §10.1.2.2). Both comparisons ignore ASCII case. *)
let content_type_of_part ~part elements =
  let attribute = Package_xml.attribute in
  let lowercase_equal value expected = String.equal (String.lowercase_ascii value) expected in
  let part_name = String.lowercase_ascii ("/" ^ part) in
  let override =
    children_named ~namespace:content_types_namespace ~name:"Override" elements
    |> List.find_map (fun element ->
      match attribute "PartName" element with
      | Some name when lowercase_equal name part_name -> attribute "ContentType" element
      | Some _ | None -> None)
  in
  match override, lowercase_extension part with
  | Some _, _ | None, None -> override
  | None, Some extension ->
    children_named ~namespace:content_types_namespace ~name:"Default" elements
    |> List.find_map (fun element ->
      match attribute "Extension" element with
      | Some value when lowercase_equal value extension -> attribute "ContentType" element
      | Some _ | None -> None)
;;

(* A package relationship's Target is a URI reference from the package root
   (ECMA-376 Part 2 §9.3). The member name is that reference resolved with
   RFC 3986 §5.2.4: "." segments drop, ".." drops the segment before it and
   never climbs above the root. *)
let member_name_of_target target =
  let segments = String.split_on_char '/' target in
  let segments =
    match segments with
    | "" :: rest -> rest
    | _ -> segments
  in
  let up = function
    | _ :: above -> above
    | [] -> []
  in
  (* A reference that ends in a dot segment ends in "/": it names a folder,
     which no member matches. *)
  let rec resolve kept = function
    | [] -> List.rev kept
    | [ "." ] -> List.rev ("" :: kept)
    | [ ".." ] -> List.rev ("" :: up kept)
    | "." :: rest -> resolve kept rest
    | ".." :: rest -> resolve (up kept) rest
    | segment :: rest -> resolve (segment :: kept) rest
  in
  String.concat "/" (resolve [] segments)
;;

let ooxml_identity archive target =
  let* found = find_member ~naming:Part_name archive (member_name_of_target target) in
  match found with
  | None -> Error (Main_part_missing target)
  | Some member ->
    let part = Zipc.Member.path member in
    let* content_types = read_part archive Content_types in
    let* content_type =
      match content_types with
      | None -> Ok None
      | Some bytes ->
        let* elements =
          descendants
            ~path:(part_path Content_types)
            ~namespace:content_types_namespace
            ~name:"Types"
            bytes
        in
        Ok (content_type_of_part ~part elements)
    in
    let kind =
      Option.bind content_type (fun value ->
        List.assoc_opt (String.lowercase_ascii value) main_part_kinds)
    in
    (match kind with
     | Some kind -> Ok (Ooxml kind)
     | None -> Error (Unsupported_main_part { part; content_type }))
;;

(* Only a relationship into the package can name the main part. One that
   points outside is not counted, and alone it leaves the part missing. *)
let ooxml_of_references archive references =
  let inside, outside =
    List.partition_map
      (function
        | In_package target -> Either.Left target
        | Outside_package target -> Either.Right target)
      references
  in
  match inside, outside with
  | [ target ], _ -> ooxml_identity archive target
  | _ :: _ :: _, _ -> Error (Several_main_parts (List.length inside))
  | [], target :: _ -> Error (Main_part_missing target)
  | [], [] -> Error No_document_marker
;;

let hwpx_claimed archive =
  let* mimetype = read_part archive Mimetype in
  match mimetype with
  | Some value -> Ok (String.equal value hwpx_mimetype)
  | None -> Ok false
;;

let hwpx_encrypted archive =
  let* manifest = read_part archive Manifest in
  match manifest with
  | None -> Ok false
  | Some bytes ->
    let* elements =
      descendants ~path:(part_path Manifest) ~namespace:manifest_namespace ~name:"manifest" bytes
    in
    Ok (List.exists (named ~namespace:manifest_namespace ~name:"encryption-data") elements)
;;

(* zipc reads as many central directory entries as the end of central
   directory record counts, and keeps one member per name. A count above
   [Zipc.member_count] means a name was written twice, and a reader that
   takes the first copy would see another document. The search mirrors
   zipc's: the last signature in the 22-byte record plus a comment of at
   most 65535 bytes. *)
let central_directory_entries bytes =
  let record_bytes = 22 and max_comment_bytes = 65535 and signature = 0x06054b50l in
  let last = String.length bytes - record_bytes in
  let first = last - max_comment_bytes in
  let rec find start =
    if start < first || start < 0
    then None
    else if Int32.equal (String.get_int32_le bytes start) signature
    then Some (String.get_uint16_le bytes (start + 10))
    else find (start - 1)
  in
  find last
;;

let identify bytes =
  match Zipc.of_binary_string bytes with
  | Error reason -> Error (Archive_unreadable reason)
  | Ok archive ->
    let distinct = Zipc.member_count archive in
    let* () =
      match central_directory_entries bytes with
      | Some entries when entries <> distinct ->
        Error (Repeated_member_name { entries; distinct })
      | Some _ -> Ok ()
      | None -> Error (Archive_unreadable "no end of central directory record")
    in
    let* main_parts = main_part_references archive in
    let* hwpx = hwpx_claimed archive in
    (match main_parts, hwpx with
     | _ :: _, true -> Error Ooxml_and_hwpx
     | [], false -> Error No_document_marker
     | [], true ->
       let* encrypted = hwpx_encrypted archive in
       Ok (Hwpx { encrypted })
     | (_ :: _ as references), false -> ooxml_of_references archive references)
;;
