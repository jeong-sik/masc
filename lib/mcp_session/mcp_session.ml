(** MCP HTTP Session ID management.
    Session IDs are restricted to URL-, header-, and cookie-safe ASCII tokens
    within the MCP Spec 2025-03-26 visible ASCII subset (0x21-0x7E), bounded
    to prevent header/cookie attribute injection and oversized header echoing. *)

let max_length = 128

let is_allowed_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | ':' | '-' -> true
  | _ -> false

(** Validate session ID: non-empty, <= 128 chars, strictly [A-Za-z0-9._:-]. *)
let is_valid id =
  let len = String.length id in
  len > 0 && len <= max_length && String.for_all is_allowed_char id

(** Generate cryptographically random session ID (128 bits of entropy). *)
let generate () = Random_id.prefixed ~prefix:"mcp_" ~bytes:16

(** Get or generate a valid session ID from optional header value *)
let get_or_generate = function
  | Some id when is_valid id -> id
  | Some _ -> generate ()  (* Invalid session ID format, generate new *)
  | None -> generate ()
