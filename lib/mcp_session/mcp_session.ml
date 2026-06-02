(** MCP HTTP Session ID management
    MCP Spec 2025-03-26: Session IDs must be visible ASCII (0x21-0x7E) *)

(* Issue #8520: Variant SSOT for masc_mcp_session tool action.  Adding
   a constructor forces compilation in [action_to_string] AND extends
   [valid_action_strings]; the schema in [tool_schemas_inline_infra.ml]
   mirrors the SSOT (cycle-aware, sync test) and the dispatcher in
   [tool_inline_dispatch.ml] consumes the Variant via
   [action_of_string_opt]. The previous code had two independent
   string lists (schema enum + match arms) with no compile-time
   linkage. *)
type action =
  | Get
  | Create
  | List
  | Cleanup
  | Remove

let action_to_string = function
  | Get -> "get"
  | Create -> "create"
  | List -> "list"
  | Cleanup -> "cleanup"
  | Remove -> "remove"

let action_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "get" -> Some Get
  | "create" -> Some Create
  | "list" -> Some List
  | "cleanup" -> Some Cleanup
  | "remove" -> Some Remove
  | _ -> None

let all_actions = [ Get; Create; List; Cleanup; Remove ]

let valid_action_strings = List.map action_to_string all_actions

(* Fiber-safe random state for session ID generation *)
let session_rng = Random.State.make_self_init ()

(** Base62 character set for compact, ASCII-safe IDs *)
let base62_chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

(** Encode integer to base62 string *)
let encode_base62 n =
  let rec aux acc n =
    if n = 0 then acc
    else aux (base62_chars.[n mod 62] :: acc) (n / 62)
  in
  if n = 0 then "0"
  else
    let chars = aux [] n |> Array.of_list in
    String.init (Array.length chars) (fun i -> chars.(i))

(** Validate session ID per MCP spec: visible ASCII only (0x21-0x7E) *)
let is_valid id =
  String.length id > 0 &&
  String.for_all (fun c ->
    let code = Char.code c in
    code >= 0x21 && code <= 0x7E
  ) id

(** Generate unique session ID (MCP spec format: visible ASCII 0x21-0x7E) *)
let generate () =
  let timestamp = int_of_float (Time_compat.now () *. 1000.0) in
  let pid = Unix.getpid () in
  let random = Random.State.int session_rng 1000000 in
  Printf.sprintf "mcp_%s_%s_%s"
    (encode_base62 timestamp)
    (encode_base62 pid)
    (encode_base62 random)

(** Get or generate a valid session ID from optional header value *)
let get_or_generate = function
  | Some id when is_valid id -> id
  | Some _ -> generate ()  (* Invalid session ID format, generate new *)
  | None -> generate ()
