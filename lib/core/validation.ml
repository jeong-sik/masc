(** MASC Input Validation - Security Module

    Prevents path injection and invalid input attacks:
    - Validates agent_id format (alphanumeric, dash, underscore only)
    - Validates task_id format (safe characters only)
    - Returns Result types for safe error handling

    Security basis:
    - OWASP Path Traversal Prevention
    - Input validation best practices

    MAGI Recommendation: All validation rejections are logged at WARN level
    for security monitoring and debugging.
*)

(** MAGI: Validation rejection counters for observability *)
let rejection_count = Atomic.make 0
let last_rejection_time = ref 0.0

(** Get validation statistics *)
let get_rejection_stats () =
  (Atomic.get rejection_count, !last_rejection_time)

(** Reset validation statistics *)
let reset_rejection_stats () =
  Atomic.set rejection_count 0;
  last_rejection_time := 0.0

(** Internal: Log validation rejection at WARN level *)
let log_rejection ~validator ~input ~reason =
  Atomic.incr rejection_count;
  last_rejection_time := Time_compat.now ();
  (* Truncate input for log safety *)
  let safe_input = String_util.utf8_safe ~max_bytes:35 ~suffix:"..." input |> String_util.to_string in
  Log.Misc.warn "%s rejected input '%s': %s"
    validator safe_input reason

(** Agent ID validation *)
module Agent_id : sig
  type t
  val validate : string -> (t, string) result
  val to_string : t -> string
  val of_string_unsafe : string -> t  (* For internal use only *)
end = struct
  type t = string

  (* Allow alphanumeric, dash, underscore, with optional single colon for namespacing
     e.g. keeper:keeper-test-98295-0. Bare colons, multiple colons, or leading colons
     are rejected. *)
  let valid_pattern = Re.Pcre.re {|^[a-zA-Z0-9_-]+(:[a-zA-Z0-9_-]+)?$|} |> Re.compile

  let validate s =
    let reject reason =
      log_rejection ~validator:"Agent_id" ~input:s ~reason;
      Error reason
    in
    if String.length s = 0 then
      reject "agent_id cannot be empty"
    else if String.length s > 64 then
      reject (Printf.sprintf "agent_id too long: %d chars (max 64)" (String.length s))
    else if String.contains s '/' || String.contains s '\\' then
      reject "agent_id cannot contain path separators"
    else if String.contains s '.' && String.length s >= 2 && String.sub s 0 2 = ".." then
      reject "agent_id cannot contain path traversal"
    else if not (Re.execp valid_pattern s) then
      reject (Printf.sprintf "agent_id contains invalid characters: %s (only a-z, A-Z, 0-9, _, -, : allowed)" s)
    else
      Ok s

  let to_string t = t
  let of_string_unsafe s = s
end

(** Task ID validation *)
module Task_id : sig
  type t
  val validate : string -> (t, string) result
  val to_string : t -> string
  val of_string_unsafe : string -> t  (* For internal use only *)
end = struct
  type t = string

  (* Allow alphanumeric, dash, underscore, colon (for namespacing) *)
  let valid_pattern = Re.Pcre.re {|^[a-zA-Z0-9_:-]+$|} |> Re.compile

  let validate s =
    let reject reason =
      log_rejection ~validator:"Task_id" ~input:s ~reason;
      Error reason
    in
    if String.length s = 0 then
      reject "task_id cannot be empty"
    else if String.length s > 128 then
      reject (Printf.sprintf "task_id too long: %d chars (max 128)" (String.length s))
    else if String.contains s '/' || String.contains s '\\' then
      reject "task_id cannot contain path separators"
    else if String.contains s '.' && String.length s >= 2 && String.sub s 0 2 = ".." then
      reject "task_id cannot contain path traversal"
    else if not (Re.execp valid_pattern s) then
      reject (Printf.sprintf "task_id contains invalid characters: %s (only a-z, A-Z, 0-9, _, -, : allowed)" s)
    else
      Ok s

  let to_string t = t
  let of_string_unsafe s = s
end

(** File path validation (for user-provided paths) *)
module Safe_path : sig
  val validate_relative : string -> (string, string) result
  val sanitize_filename : string -> string
end = struct
  let validate_relative path =
    let reject reason =
      log_rejection ~validator:"Safe_path" ~input:path ~reason;
      Error reason
    in
    if String.length path = 0 then
      reject "path cannot be empty"
    else if path.[0] = '/' then
      reject "absolute paths not allowed"
    else if String.length path >= 2 && String.sub path 0 2 = ".." then
      reject "path traversal not allowed"
    else if Re.execp (Re.Pcre.re {|\.\./|} |> Re.compile) path then
      reject "path traversal not allowed"
    else
      Ok path

  let sanitize_filename name =
    (* Remove any path separators and dangerous characters *)
    name
    |> Re.replace_string (Re.Pcre.re {|[/\\]|} |> Re.compile) ~by:"_"
    |> Re.replace_string (Re.Pcre.re {|\.\.|} |> Re.compile) ~by:"_"
    |> Re.replace_string (Re.Pcre.re {|[^a-zA-Z0-9_.\-]|} |> Re.compile) ~by:"_"
end

(** Numeric validation *)
module Safe_float : sig
  val validate : float -> name:string -> float
  val clamp : float -> min:float -> max:float -> float
end = struct
  let validate f ~name =
    if Float.is_nan f then begin
      Log.Misc.warn "NaN detected for %s, using 0.0" name;
      0.0
    end else if Float.is_infinite f then begin
      Log.Misc.warn "Inf detected for %s, using 0.0" name;
      0.0
    end else
      f

  let clamp f ~min ~max =
    if f < min then min
    else if f > max then max
    else f
end
