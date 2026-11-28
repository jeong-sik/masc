type unknown =
  | No_document_signature
  | Zip_package of Zip_package_identity.fault
  | Compound_file of Compound_identity.fault

type detection =
  | Document of Document_format.t
  | Encrypted of Document_format.t option
  | Unknown of unknown

let pdf_signature = "%PDF-"

let of_zip_identity : Zip_package_identity.identity -> detection = function
  | Ooxml Word -> Document Docx
  | Ooxml Spreadsheet -> Document Xlsx
  | Ooxml Presentation -> Document Pptx
  | Hwpx { encrypted = false } -> Document Hwpx
  | Hwpx { encrypted = true } -> Encrypted (Some Hwpx)
;;

let of_compound_identity : Compound_identity.identity -> detection = function
  | Word { encrypted } -> if encrypted then Encrypted (Some Doc) else Document Doc
  | Excel { encrypted } -> if encrypted then Encrypted (Some Xls) else Document Xls
  | Powerpoint { encrypted } -> if encrypted then Encrypted (Some Ppt) else Document Ppt
  | Hwp { encrypted } -> if encrypted then Encrypted (Some Hwp) else Document Hwp
  | Encrypted_ooxml -> Encrypted None
;;

let detect bytes =
  if String.starts_with ~prefix:pdf_signature bytes
  then Document Pdf
  else if String.starts_with ~prefix:Compound_file.signature bytes
  then (
    match Compound_identity.identify bytes with
    | Ok identity -> of_compound_identity identity
    | Error fault -> Unknown (Compound_file fault))
  else if Zipc.string_has_magic bytes
  then (
    match Zip_package_identity.identify bytes with
    | Ok identity -> of_zip_identity identity
    | Error fault -> Unknown (Zip_package fault))
  else Unknown No_document_signature
;;
