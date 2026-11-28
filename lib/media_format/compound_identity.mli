(** Which document a Compound File holds, read from the streams directly under
    its root storage, and whether its body is encrypted. *)

type identity =
  | Word of { encrypted : bool }
      (** [WordDocument]; [fEncrypted] of the FibBase ([MS-DOC] 2.5.2). *)
  | Excel of { encrypted : bool }
      (** [Workbook] or [Book]; a FilePass record after the BOF and an
          optional WriteProtect ([MS-XLS] 2.1.7.20.2, 2.4.117). *)
  | Powerpoint of { encrypted : bool }
      (** [PowerPoint Document]; the [Current User] headerToken
          ([MS-PPT] 2.3.2) or, with the plain token, which PowerPoint 2002
          also writes to encrypted files, the length of the UserEditAtom
          that offsetToCurrentEdit names (2.3.3). *)
  | Hwp of { encrypted : bool }
      (** [FileHeader] starting [HWP Document File]; its properties set the
          password, DRM, certificate-encryption or certificate-DRM bit
          (HWP 5.0 file format, FileHeader). *)
  | Encrypted_ooxml
      (** [EncryptionInfo] and [EncryptedPackage] ([MS-OFFCRYPTO] 2.3.4).
          The inner format is unknown without the password. *)

type fault =
  | Compound of Compound_file.fault
  | No_document_stream
  | Several_document_streams of string list
  | Missing_stream of string
      (** A stream the identified format must carry is absent. *)
  | Short_stream of
      { name : string
      ; bytes : int
      }  (** A stream ends before the field the check reads. *)
  | Workbook_without_bof
  | Unknown_header_token of int
      (** [Current User] carries a token [MS-PPT] does not define. *)
  | Current_edit_past_end of { offset : int }
      (** offsetToCurrentEdit leaves fewer than 8 bytes of
          [PowerPoint Document] for the record header. *)
  | Not_a_user_edit_atom of
      { offset : int
      ; record_type : int
      ; length : int
      }
      (** The record at offsetToCurrentEdit is not a UserEditAtom of 0x1C or
          0x20 bytes. *)

val identify : string -> (identity, fault) result
