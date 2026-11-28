type identity =
  | Word of { encrypted : bool }
  | Excel of { encrypted : bool }
  | Powerpoint of { encrypted : bool }
  | Hwp of { encrypted : bool }
  | Encrypted_ooxml

type fault =
  | Compound of Compound_file.fault
  | No_document_stream
  | Several_document_streams of string list
  | Missing_stream of string
  | Short_stream of
      { name : string
      ; bytes : int
      }
  | Workbook_without_bof
  | Unknown_header_token of int
  | Current_edit_past_end of { offset : int }
  | Not_a_user_edit_atom of
      { offset : int
      ; record_type : int
      ; length : int
      }

let ( let* ) = Result.bind
let word_stream = "WordDocument"
let workbook_streams = [ "Workbook"; "Book" ]
let powerpoint_stream = "PowerPoint Document"
let current_user_stream = "Current User"
let hwp_header_stream = "FileHeader"
let hwp_signature = "HWP Document File"
let encryption_info_stream = "EncryptionInfo"
let encrypted_package_stream = "EncryptedPackage"

(* [MS-DOC] 2.5.2 FibBase: the flags word at 0x0A; fEncrypted is bit 8. *)
let fib_flags_offset = 0x0A
let fib_encrypted = 0x0100

(* [MS-XLS] 2.3: record types. *)
let record_bof = 0x0809
let record_write_protect = 0x0086
let record_file_pass = 0x002F

(* [MS-PPT] 2.3.2 CurrentUserAtom: an 8-byte record header, size,
   headerToken, then offsetToCurrentEdit. *)
let header_token_offset = 12
let current_edit_offset = 16
let token_plain = 0xE391C05F
let token_encrypted = 0xF3D1C4DF

(* [MS-PPT] 2.3.1 RecordHeader: version and instance, recType, recLen.
   2.3.3 UserEditAtom: recLen 0x1C, or 0x20 with encryptSessionPersistIdRef,
   which an encrypted document must have (2.3.7). *)
let record_header_bytes = 8
let record_user_edit = 0x0FF5
let user_edit_plain_length = 0x1C
let user_edit_encrypted_length = 0x20

(* HWP 5.0 FileHeader: a 32-byte signature, the version, then properties.
   Four property bits mean the body is encrypted: bit 1 password, bit 4 DRM,
   bit 8 certificate encryption, bit 10 certificate DRM (pyhwp names them
   password, drm, cert_encrypted, cert_drm). Bit 2, a distribution document,
   is not: rhwp opens one. *)
let hwp_properties_offset = 36
let hwp_encrypted_bits = 0x02 lor 0x10 lor 0x100 lor 0x400

let u16 s offset = String.get_uint16_le s offset
let u32 s offset = Int32.to_int (String.get_int32_le s offset) land 0xFFFF_FFFF
let compound result = Result.map_error (fun fault -> Compound fault) result

(* Reads the first [bytes] of [name], which the caller knows is present. *)
let prefix file name bytes =
  let* found = compound (Compound_file.stream_slice file name ~offset:0 ~max_bytes:bytes) in
  match found with
  | None -> Error (Missing_stream name)
  | Some data when String.length data < bytes ->
    Error (Short_stream { name; bytes = String.length data })
  | Some data -> Ok data
;;

let word_encrypted file =
  let* fib = prefix file word_stream (fib_flags_offset + 2) in
  Ok (u16 fib fib_flags_offset land fib_encrypted <> 0)
;;

(* The globals substream starts BOF, then an optional WriteProtect, then an
   optional FilePass. Record headers stay plain in an encrypted workbook. *)
let excel_encrypted file name =
  let* found = compound (Compound_file.stream_slice file name ~offset:0 ~max_bytes:512) in
  match found with
  | None -> Error (Missing_stream name)
  | Some data ->
    let record_at offset =
      if offset + 4 > String.length data
      then Error (Short_stream { name; bytes = String.length data })
      else Ok (u16 data offset, u16 data (offset + 2))
    in
    let* kind, bof_length = record_at 0 in
    if kind <> record_bof
    then Error Workbook_without_bof
    else (
      let second = 4 + bof_length in
      let* kind, length = record_at second in
      if kind = record_file_pass
      then Ok true
      else if kind = record_write_protect
      then (
        let* kind, _ = record_at (second + 4 + length) in
        Ok (kind = record_file_pass))
      else Ok false)
;;

(* PowerPoint 2002 writes the plain token to encrypted files too ([MS-PPT]
   appendix A <6> and <11>), so with that token the most recent
   UserEditAtom decides. *)
let current_edit_encrypted file ~offset =
  let* found =
    compound
      (Compound_file.stream_slice
         file
         powerpoint_stream
         ~offset
         ~max_bytes:record_header_bytes)
  in
  match found with
  | None -> Error (Missing_stream powerpoint_stream)
  | Some header when String.length header < record_header_bytes ->
    Error (Current_edit_past_end { offset })
  | Some header ->
    let record_type = u16 header 2 and length = u32 header 4 in
    if record_type <> record_user_edit
    then Error (Not_a_user_edit_atom { offset; record_type; length })
    else if length = user_edit_encrypted_length
    then Ok true
    else if length = user_edit_plain_length
    then Ok false
    else Error (Not_a_user_edit_atom { offset; record_type; length })
;;

let powerpoint_encrypted file =
  let* atom = prefix file current_user_stream (current_edit_offset + 4) in
  match u32 atom header_token_offset with
  | token when token = token_encrypted -> Ok true
  | token when token = token_plain ->
    current_edit_encrypted file ~offset:(u32 atom current_edit_offset)
  | token -> Error (Unknown_header_token token)
;;

type claim =
  | Word_claim
  | Excel_claim of string
  | Powerpoint_claim
  | Hwp_claim of string
  | Encrypted_ooxml_claim

let claim_stream = function
  | Word_claim -> word_stream
  | Excel_claim name -> name
  | Powerpoint_claim -> powerpoint_stream
  | Hwp_claim _ -> hwp_header_stream
  | Encrypted_ooxml_claim -> encrypted_package_stream
;;

let identify bytes =
  let* file = compound (Compound_file.read bytes) in
  let streams = List.map String.lowercase_ascii (Compound_file.root_streams file) in
  let has name = List.mem (String.lowercase_ascii name) streams in
  let* hwp_header =
    compound
      (Compound_file.stream_slice file hwp_header_stream ~offset:0 ~max_bytes:(hwp_properties_offset + 4))
  in
  let claims =
    List.filter_map
      Fun.id
      [ (if has word_stream then Some Word_claim else None)
      ; Option.map (fun name -> Excel_claim name) (List.find_opt has workbook_streams)
      ; (if has powerpoint_stream then Some Powerpoint_claim else None)
      ; (match hwp_header with
         | Some header when String.starts_with ~prefix:hwp_signature header ->
           Some (Hwp_claim header)
         | Some _ | None -> None)
      ; (if has encryption_info_stream && has encrypted_package_stream
         then Some Encrypted_ooxml_claim
         else None)
      ]
  in
  match claims with
  | [] -> Error No_document_stream
  | _ :: _ :: _ -> Error (Several_document_streams (List.map claim_stream claims))
  | [ Word_claim ] ->
    let* encrypted = word_encrypted file in
    Ok (Word { encrypted })
  | [ Excel_claim name ] ->
    let* encrypted = excel_encrypted file name in
    Ok (Excel { encrypted })
  | [ Powerpoint_claim ] ->
    let* encrypted = powerpoint_encrypted file in
    Ok (Powerpoint { encrypted })
  | [ Hwp_claim header ] ->
    if String.length header < hwp_properties_offset + 4
    then Error (Short_stream { name = hwp_header_stream; bytes = String.length header })
    else Ok (Hwp { encrypted = u32 header hwp_properties_offset land hwp_encrypted_bits <> 0 })
  | [ Encrypted_ooxml_claim ] -> Ok Encrypted_ooxml
;;
