(** Which document format a byte string holds.

    The format comes from the bytes' structure, never from a file name: a DOCX
    named [report.doc] is a DOCX. *)

type unknown =
  | No_document_signature
      (** The bytes start with none of [%PDF-], a ZIP signature and the
          Compound File signature. *)
  | Zip_package of Zip_package_identity.fault
  | Compound_file of Compound_identity.fault

type detection =
  | Document of Document_format.t
  | Encrypted of Document_format.t option
      (** A password-protected document. [None] when the format cannot be
          told without the password. *)
  | Unknown of unknown

val detect : string -> detection
(** [detect bytes] reads the whole attachment. A ZIP keeps its member list at
    the end of the file, so a prefix is not enough. *)
