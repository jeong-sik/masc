(** Caller-owned observation of native HTTP POST calls. No URL, headers,
    credentials, request content or response content crosses this interface.
    A call identity belongs to the observer captured when that call entered;
    nested observers and inherited concurrent fibers cannot rebind it.

    Body size/hash describe the bytes submitted to the HTTP client, not bytes
    acknowledged by a peer. Dispatch entry, response headers and client return
    are distinct facts. A successful client return is not a provider/parser or
    business-success verdict. Callbacks run synchronously and must stay bounded.
    Unbound calls do no body hashing or recording. No observation changes
    admission or retry policy. *)

type mode = Synchronous | Streaming
type completion = Returned_ok | Returned_error | Cancelled | Raised
type tool_inventory =
  | No_tools_member
  | Tools_member of { wire_entries : int; json_bytes : int; json_sha256 : string }
  | Tools_unavailable
(** The exact request's [tools] member, compactly re-encoded by Yojson while
    preserving object and array order. [wire_entries] counts top-level entries,
    not functions nested inside a provider entry. No schema content is exposed.
    Absent, observed empty and unavailable are distinct facts. *)

type request_member =
  { name : string
  ; wire_bytes : int
  ; value_json_bytes : int
  ; value_json_sha256 : string
  }
(** One top-level JSON member in original order. [wire_bytes] includes the
    encoded key, colon and value; it excludes the object's braces and commas.
    Values and their text are never exposed. Duplicate member names retain
    their separate occurrences. *)

type request_components =
  | Json_object_members of { members : request_member list; framing_bytes : int }
  | Components_unavailable
(** Exact decomposition is available only when compact re-encoding reproduces
    the submitted body byte-for-byte. Member [wire_bytes] plus [framing_bytes]
    account for that body's full byte count. This is structural attribution,
    not token usage or proof that an unchanged member can be omitted. *)

type request_metadata =
  { tool_inventory : tool_inventory
  ; components : request_components
  }

type phase =
  | Client_entered of
      { mode : mode; body_bytes : int; body_sha256 : string
      ; tool_inventory : tool_inventory option
      ; request_components : request_components option }
  | Dispatch_entered
  | Response_headers_received of { status : int }
  | Client_finished of completion

type event = { call_id : int; phase : phase }
type t
type call

val create : (event -> (unit, unit) result) -> t
val with_observer : t -> (unit -> 'a) -> 'a
val with_request_metadata :
  body:string -> metadata:(unit -> request_metadata) -> (unit -> 'a) -> 'a
(** Bind serializer-owned metadata only to this exact body digest. The lazy
    producer is not evaluated without an observer. An ordinary producer
    exception records unavailable metadata without changing the HTTP result;
    reserved exceptions propagate. Unrelated nested HTTP bodies cannot inherit
    this request's metadata. [None] in a client event means unobserved. *)
val capture : ('input -> 'a) -> ('input -> 'a)
(** Capture the current observer in a closure before an actor/executor handoff.
    Invoking it rebinds that owner on the receiving fiber. Ordinary child
    fibers inherit bindings, but an already running actor does not. When no
    observer is bound, return the original closure without adding a binding. *)
val delivery_failure_count : t -> int
(** Rejected callbacks and ordinary callback exceptions are counted and do not
    rewrite a client result. Reserved exceptions, including cancellation, escape.
    A consumer with missing events must retain unknown aggregate metrics. *)

val with_call :
  mode:mode -> body:string -> (call option -> ('a, 'error) result) -> ('a, 'error) result
val dispatch_entered : call option -> unit
val response_headers_received : call option -> status:int -> unit
