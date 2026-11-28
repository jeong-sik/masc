type t =
  | Pdf
  | Hwp
  | Hwpx
  | Doc
  | Docx
  | Xls
  | Xlsx
  | Ppt
  | Pptx
[@@deriving enumerate]

let wire_mime = function
  | Pdf -> "application/pdf"
  | Hwp -> "application/x-hwp"
  | Hwpx -> "application/hwp+zip"
  | Doc -> "application/msword"
  | Docx -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  | Xls -> "application/vnd.ms-excel"
  | Xlsx -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  | Ppt -> "application/vnd.ms-powerpoint"
  | Pptx -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
;;

let of_wire_mime mime = List.find_opt (fun format -> String.equal (wire_mime format) mime) all

let extension = function
  | Pdf -> ".pdf"
  | Hwp -> ".hwp"
  | Hwpx -> ".hwpx"
  | Doc -> ".doc"
  | Docx -> ".docx"
  | Xls -> ".xls"
  | Xlsx -> ".xlsx"
  | Ppt -> ".ppt"
  | Pptx -> ".pptx"
;;
