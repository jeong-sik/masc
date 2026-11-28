type unknown =
  | No_document_signature
  | Zip_package of Zip_package_identity.fault

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

let detect bytes =
  if String.starts_with ~prefix:pdf_signature bytes
  then Document Pdf
  else if Zipc.string_has_magic bytes
  then (
    match Zip_package_identity.identify bytes with
    | Ok identity -> of_zip_identity identity
    | Error fault -> Unknown (Zip_package fault))
  else Unknown No_document_signature
;;
