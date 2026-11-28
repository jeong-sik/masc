(** The document formats a workspace attachment may hold. *)

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

val all : t list
(** Every format, in the order an upload picker lists them. *)

val wire_mime : t -> string
(** The MIME type the server stores and sends. It is the IANA-registered type
    where one exists. HWPX uses the value its own [mimetype] entry carries
    ([application/hwp+zip]); HWP has no registered type and uses
    [application/x-hwp]. *)

val of_wire_mime : string -> t option
(** The inverse of {!wire_mime}. Only the exact values {!wire_mime} returns
    parse; anything else is [None]. *)

val extension : t -> string
(** The file extension with its leading dot. A picker uses it to show which
    files it offers. A format is never chosen from it. *)
