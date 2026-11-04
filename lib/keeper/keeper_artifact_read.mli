(** Explicit, bounded model read for content-addressed Tool results.

    A sha256 is the content identifier used by the HTTP endpoint. The handler
    introduces no second ownership or run-scope Gate; HTTP authorization
    remains the server boundary. It returns one typed JSON page and never
    restores the full artifact into model history. *)

val default_max_bytes : int
(** How many source bytes one page carries when the caller does not ask. The
    returned slice may be smaller when JSON escaping or base64 expansion would
    exceed the budget.

    Equal to {!maximum_max_bytes}: paging exists for artifacts larger than one
    page, so the useful default is the largest page. *)

val maximum_max_bytes : int
(** The largest page a caller may ask for: {!Common.max_tool_result_wire_bytes},
    the narrower of the two lane ceilings.

    A page returned above it would be spilled to a file the Keeper cannot open,
    which is the failure this bound exists to prevent. It does not follow the
    executing lane the way a tool result does — the schema is advertised before
    the turn resolves a runtime, so a bound that varied could not be declared. *)
val minimum_max_bytes : int
val minimum_offset : int

type request =
  { sha256 : string
  ; offset : int
  ; max_bytes : int
  }

(** Why an integer-typed request field could not be read. [Yojson.Safe]
    represents an integer literal that exceeds the native [int] range as
    [`Intlit]; that case is rejected under its own name instead of being
    swept into a wildcard. *)
type invalid_integer_field =
  | Not_an_integer of { kind : string }
  | Literal_out_of_int_range of { literal : string }
  | Literal_not_a_json_integer of { literal : string }
  | Below_minimum of
      { value : int
      ; minimum : int
      }
  | Above_maximum of
      { value : int
      ; maximum : int
      }

(** Which request field was rejected, and why. A caller whose [sha256] was
    correct is never told to fix [sha256]. *)
type invalid_request =
  | Not_an_object of { kind : string }
  | Sha256_missing
  | Sha256_not_a_string of { kind : string }
  | Sha256_malformed of Tool_output.invalid_sha256
  | Offset_invalid of invalid_integer_field
  | Max_bytes_invalid of invalid_integer_field
  | Contains_not_a_string of { kind : string }
  | Contains_empty
  | Contains_too_long of
      { bytes : int
      ; maximum : int
      }
  | Ignore_case_not_a_boolean of { kind : string }
  | Max_matches_invalid of invalid_integer_field
  | Search_field_without_contains of { field : string }
      (** [ignore_case] or [max_matches] without [contains]. *)
  | Max_bytes_with_contains
      (** [max_bytes] is the page size; a search returns lines. *)

val invalid_request_to_string : invalid_request -> string
(** Renders one rejection into the [message] field of the
    [{"ok":false,"error":"invalid_artifact_read","message":…}] envelope. *)

type page_encoding =
  | Utf_8
  | Base64

type page =
  { sha256 : string
  ; offset : int
  ; next_offset : int
  ; total_bytes : int
  ; eof : bool
  ; encoding : page_encoding
  ; content : string
  }

val page_to_json : page -> Yojson.Safe.t

(** A request that carries [contains]: where does this text occur in the
    artifact. Answered by {!Keeper_artifact_search}; the response has the page
    fields, with [content] holding one ["<byte offset>\t<line>"] per hit, plus
    [match_count] and, when some lines were too long to search,
    [skipped_lines]. [next_offset] is where to continue and [eof] says whether
    the scan reached the end. *)
type search =
  { sha256 : string
  ; offset : int
  ; needle : string
  ; ignore_case : bool
  ; max_matches : int
  }

type operation =
  | Read_page of request
  | Search_text of search

val page :
  ?envelope:(Yojson.Safe.t -> Yojson.Safe.t) -> request -> string ->
  (page, string) result
(** Page an already-read body under the existing wire budget, including the
    caller's enclosing JSON metadata. A non-EOF page must consume at least
    one source byte. Bounds are validated for direct callers too. *)

val handle :
  base_path:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Total request boundary for every caller, including direct in-process uses
    that do not traverse [Tool_input_validation]. The dispatch pre-hook rejects
    the same declared bounds earlier, but never replaces this parser's ownership
    of the handler input contract. *)

val handle_with_page :
  base_path:string -> args:Yojson.Safe.t -> Keeper_tool_execution.t * page option
(** The same handler plus its successful page observation. None means no page
    was produced. A produced page is not evidence of provider delivery or
    semantic understanding; callers must keep those observations separate. *)

module For_testing : sig
  val request_of_json : Yojson.Safe.t -> (request, invalid_request) result
  val operation_of_json : Yojson.Safe.t -> (operation, invalid_request) result
  val page : request -> string -> (page, string) result
  val page_to_json : page -> Yojson.Safe.t

  val search_page :
    search -> Keeper_artifact_search.outcome -> (Yojson.Safe.t, string) result
  (** The search response for a scan outcome, with hits dropped from the end
      until it fits the wire ceiling. *)
end
