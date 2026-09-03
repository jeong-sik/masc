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

val handle :
  base_path:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Total request boundary for every caller, including direct in-process uses
    that do not traverse [Tool_input_validation]. The dispatch pre-hook rejects
    the same declared bounds earlier, but never replaces this parser's ownership
    of the handler input contract. *)

module For_testing : sig
  val request_of_json : Yojson.Safe.t -> (request, invalid_request) result
  val page : request -> string -> (page, string) result
  val page_to_json : page -> Yojson.Safe.t
end
