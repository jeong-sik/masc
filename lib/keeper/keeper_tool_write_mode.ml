(* Issue #8490: Variant SSOT for filesystem write mode. Adding a constructor
   forces compilation in [to_string] and every dispatch AND extends
   [valid_strings]; the schema mirrors the SSOT through [Tool_shard_types]
   (cycle avoidance per #8480/#8484 pattern). Lives in its own module so
   the host and the remote write handlers read one definition without
   either depending on the other. *)
type t =
  | Overwrite
  | Append
  | Patch
  (** RFC-0006 Phase A.4: read-replace-write for the Anthropic Code
        [Edit] cognate. Caller supplies [old_string] + [new_string]
        (and optional [replace_all]) instead of [content]. *)

let to_string = function
  | Overwrite -> "overwrite"
  | Append -> "append"
  | Patch -> "patch"
;;

(* Sound partial parser: only canonical mode strings decode to a real
   variant. Missing mode is rejected before this parser; explicit empty
   strings are invalid input. *)
let of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "overwrite" -> Some Overwrite
  | "append" -> Some Append
  | "patch" -> Some Patch
  | _ -> None
;;

let all = [ Overwrite; Append; Patch ]
let valid_strings = List.map to_string all

(* [Safe_ops.json_string] maps "key absent" and "key present but not a
   string" onto the same default, and that default is the destructive mode.
   {"mode": ["append"]} therefore reached Overwrite while the merely
   misspelled {"mode": "apend"} was rejected — a type error was handled
   more permissively than a value error, in the destructive direction. Read
   the member so a non-string is rejected on the same path as a bad string.
   Absence follows that same rejection path (masc#31573): every model-facing
   translator injects mode explicitly and Gate replay reconstructs it from
   the recorded effect, so an absent mode only reaches a handler through an
   internal-name call that bypassed translation — and defaulting that to
   Overwrite turned a missing member into a whole-file write. The [Error]
   carries what was seen, for the caller's message. *)
let of_args (args : Yojson.Safe.t) =
  let member =
    match args with
    | `Assoc members -> List.assoc_opt "mode" members
    | _ -> None
  in
  match member with
  | None -> Error "(absent)"
  | Some (`String raw) ->
    (match of_string_opt raw with
     | Some mode -> Ok mode
     | None -> Error raw)
  | Some other -> Error (Yojson.Safe.to_string other)
;;

let rejection_message raw =
  Printf.sprintf
    "mode must be one of [%s], got %S."
    (String.concat ", " valid_strings)
    raw
;;
