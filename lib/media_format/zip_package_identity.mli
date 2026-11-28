(** Which document a ZIP package holds, read from its package structure.

    It expands four parts at most. Office Open XML is read from [_rels/.rels]
    and [[Content_Types].xml]. HWPX is read from [mimetype] and
    [META-INF/manifest.xml]. Member order and compression do not matter: the
    archive's central directory names every member. Office Open XML part
    names ignore ASCII case; the HWPX entries are named exactly. The XML
    parts are read by {!Package_xml}. *)

(** The four members detection expands. *)
type part =
  | Relationships  (** [_rels/.rels] *)
  | Content_types  (** [[Content_Types].xml] *)
  | Mimetype  (** [mimetype] *)
  | Manifest  (** [META-INF/manifest.xml] *)

val part_path : part -> string

val part_max_bytes : part -> int
(** 64 KiB, 256 KiB, 1 KiB and 256 KiB. A part whose central directory size
    is larger is not expanded, and the package is reported as
    {!Part_too_large}. The limits bound how many bytes one upload makes the
    server expand and parse. *)

type ooxml =
  | Word
  | Spreadsheet
  | Presentation

type identity =
  | Ooxml of ooxml
  | Hwpx of { encrypted : bool }
      (** [encrypted] is true when [META-INF/manifest.xml] carries an ODF
          [encryption-data] element. The manifest stays plain text in a
          password-protected HWPX. *)

type fault =
  | Archive_unreadable of string  (** [Zipc.of_binary_string] refused it. *)
  | Repeated_member_name of
      { entries : int
      ; distinct : int
      }
      (** The central directory has [entries] entries but [distinct] names:
          one name is written more than once, so two readers could take
          different copies. *)
  | Part_too_large of
      { path : string
      ; declared_bytes : int
      }
  | Part_unreadable of
      { path : string
      ; reason : string
      }
      (** Encrypted member, unsupported compression, malformed Deflate data,
          bad CRC or size, or two members whose names differ only in ASCII
          case where Office Open XML part names ignore it. *)
  | Xml_unreadable of
      { path : string
      ; reason : string
      }
      (** {!Package_xml.elements} refused the part, or its root is not the
          element the part must have. *)
  | No_document_marker
      (** Neither an Office Open XML package relationship nor an HWPX
          [mimetype] entry is present. EPUB, ODF and plain archives end here. *)
  | Ooxml_and_hwpx
      (** Both markers are present, so the package claims two formats. *)
  | Several_main_parts of int
      (** More than one [officeDocument] package relationship points into the
          package. One with [TargetMode="External"] is not counted. *)
  | Main_part_missing of string
      (** The [officeDocument] relationship names a part the archive does not
          hold, or every such relationship points outside the package. The
          Target is resolved from the package root, with ["."] and [".."]
          segments removed as RFC 3986 §5.2.4 does. *)
  | Unsupported_main_part of
      { part : string
      ; content_type : string option
      }
      (** The main part's content type is outside the three formats: a
          template, a slide show, a macro-enabled document, or no type. *)

val identify : string -> (identity, fault) result
(** [identify bytes] reads [bytes] as a whole ZIP archive. *)
