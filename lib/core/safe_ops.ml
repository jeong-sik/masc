(** Safe Operations Module

    Provides safe wrappers for common operations that may fail,
    with proper error handling and logging instead of silent suppression.

    Design principles:
    - Never silently swallow exceptions
    - Always provide context for errors
    - Use Result types for recoverable errors
    - Log unexpected failures for debugging
*)

(** Run [f ()], re-raising [Eio.Cancel.Cancelled] with its original backtrace
    and returning [default] for any other exception. *)
let protect ~default f =
  try f ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    let bt = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace e bt
  | _ -> default

(** Execute a function, logging exceptions and returning None on failure *)
let try_with_log context f =
  try Some (f ())
  with
  | Eio.Cancel.Cancelled _ as e ->
    let bt = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace e bt
  | e ->
    Log.Misc.error "%s failed: %s" context (Printexc.to_string e);
    None

(** Execute with default value on failure *)
let try_with_default ~default context f =
  match try_with_log context f with
  | Some v -> v
  | None -> default

(** Cancel-aware Result wrapper.
    Re-raises [Eio.Cancel.Cancelled] with backtrace; captures other
    exceptions as [Error exn]. *)
let try_catch f =
  try Ok (f ())
  with
  | Eio.Cancel.Cancelled _ as e ->
    let bt = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace e bt
  | exn -> Error exn

(** Cancel-aware exception handler.
    Re-raises [Eio.Cancel.Cancelled] with backtrace; delegates other
    exceptions to [handler]. *)
let handle f handler =
  try f ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    let bt = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace e bt
  | exn -> handler exn

(** Parse JSON with detailed error reporting *)
let parse_json_safe ~context str : (Yojson.Safe.t, string) result =
  try Ok (Yojson.Safe.from_string str)
  with Yojson.Json_error msg ->
    let preview = String_util.utf8_safe ~max_bytes:53 ~suffix:"..." str |> String_util.to_string in
    Error (Printf.sprintf "[%s] JSON parse error: %s (input: %s)" context msg preview)

(** Read file contents with error handling.
    Uses Eio-native I/O via Fs_compat when available (after set_fs),
    falls back to blocking I/O in non-Eio contexts. *)
let read_file_safe path : (string, string) result =
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "File not found: %s" path)
  else
    try Ok (Fs_compat.load_file path)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Error (Printf.sprintf "Failed to read %s: %s" path (Printexc.to_string e))

(** Safe integer parsing *)
let int_of_string_safe str = int_of_string_opt str

(** Integer parsing with default *)
let int_of_string_with_default ~default str =
  match int_of_string_safe str with
  | Some v -> v
  | None -> default

(** Safe float parsing *)
let float_of_string_safe str =
  try Some (float_of_string str)
  with Failure _ -> None

(** Float parsing with default *)
let float_of_string_with_default ~default str =
  match float_of_string_safe str with
  | Some v -> v
  | None -> default

(** Read JSON file safely *)
let read_json_file_safe path : (Yojson.Safe.t, string) result =
  match read_file_safe path with
  | Error e -> Error e
  | Ok content -> parse_json_safe ~context:path content

(** Read JSON file safely, logging errors instead of silently discarding them.
    Returns [Some json] on success, [None] on failure with a warning log.
    Use this as a drop-in replacement for [read_json_file_safe |> Error _ -> None]. *)
let read_json_file_logged ~label path : Yojson.Safe.t option =
  match read_json_file_safe path with
  | Ok json -> Some json
  | Error msg ->
    Log.Misc.warn "[%s] failed to read JSON from %s: %s" label path msg;
    None

let persistence_read_drop_reason_list_dir_error = "list_dir_error"
let persistence_read_drop_reason_entry_load_error = "entry_load_error"
let persistence_read_drop_reason_invalid_payload = "invalid_payload"

let report_persistence_read_drop ~on_drop ~surface ~reason ~path ~detail =
  Log.Misc.warn "[%s] persistence read drop (%s) path=%s: %s"
    surface reason path detail;
  on_drop ()

let result_to_option_logged ~on_drop ~surface ~reason ~path = function
  | Ok value -> Some value
  | Error detail ->
    report_persistence_read_drop ~on_drop ~surface ~reason ~path ~detail;
    None

(** Read JSON file via Eio-native I/O (Fs_compat).
    Drop-in replacement for [Yojson.Safe.from_file] in Eio fiber contexts.
    Falls back to blocking I/O when Eio fs is not set. *)
let read_json_eio (path : string) : Yojson.Safe.t =
  let content = Fs_compat.load_file path in
  Yojson.Safe.from_string content

(** List files in directory safely *)
let list_dir_safe path : (string list, string) result =
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "Directory not found: %s" path)
  else if not (Sys.is_directory path) then
    Error (Printf.sprintf "Not a directory: %s" path)
  else
    try Ok (Sys.readdir path |> Array.to_list)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Error (Printf.sprintf "Failed to list %s: %s" path (Printexc.to_string e))

(** Remove file with logging on failure (for cleanup operations) *)
let remove_file_logged ?(context = "cleanup") path =
  try Sys.remove path
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Log.Misc.error "[%s] Failed to remove %s: %s" context path (Printexc.to_string e)

(** Close channel with logging on failure *)
let close_in_logged ic =
  try close_in ic
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Log.Misc.error "Failed to close input channel: %s" (Printexc.to_string e)

(** Get environment variable with logging when invalid *)
let get_env_int_logged name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some v ->
    match int_of_string_safe v with
    | Some n -> n
    | None ->
      Log.Misc.warn "Invalid int for %s=%s, using default %d" name v default;
      default

let get_env_float_logged name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some v ->
    match float_of_string_safe v with
    | Some n -> n
    | None ->
      Log.Misc.warn "Invalid float for %s=%s, using default %f" name v default;
      default

(** {2 JSON Value Extraction Helpers}

    Safe extraction from Yojson.Safe.t values with proper error handling.
    Safe extraction from Yojson.Safe.t values without exception handling.
*)

(** Safe member access: returns [`Null] for non-[`Assoc] inputs
    instead of raising [Type_error]. *)
let safe_member key = function
  | `Assoc l ->
    (match List.assoc_opt key l with
     | Some v -> v
     | None -> `Null)
  | _ -> `Null

let json_string ?(default = "") key json =
  match safe_member key json with
  | `String s -> s
  | _ -> default

(* Small LLMs (including some keepers under the local cascade) routinely
   stringify numeric tool-call arguments: max_results:"0.0", offset:"100.0",
   timeout_sec:"0.0". The JSON schema says "number" but the wire form is a
   string. Prior to 2026-04-18 these fell through to [default] (0), which
   silently produced empty search results or zero-length reads — keepers
   then retried with the same payload and gave up (tool_metrics evidence
   on 2026-04-17/18 showed this in masc_code_read: offset:"100.0",
   limit:"0.0"). Accept numeric strings with strict parsing and fall back
   to [default] only when the string does not parse as a number. Missing
   keys still fall through to [default] — no behaviour change there. *)
let parse_numeric_string s =
  let trimmed = String.trim s in
  if trimmed = "" then None
  else match int_of_string_opt trimmed with
    | Some _ as v -> v
    | None -> (
        match float_of_string_opt trimmed with
        | Some f -> Some (int_of_float f)
        | None -> None)

let parse_float_string s =
  let trimmed = String.trim s in
  if trimmed = "" then None
  else float_of_string_opt trimmed

let parse_bool_string s =
  match String.lowercase_ascii (String.trim s) with
  | "true" | "1" | "yes" | "on" -> Some true
  | "false" | "0" | "no" | "off" | "" -> Some false
  | _ -> None

let json_int ?(default = 0) key json =
  match safe_member key json with
  | `Int i -> i
  | `Float f -> int_of_float f
  | `String s -> Option.value ~default (parse_numeric_string s)
  | _ -> default

let json_float ?(default = 0.0) key json =
  match safe_member key json with
  | `Float f -> f
  | `Int i -> float_of_int i
  | `String s -> Option.value ~default (parse_float_string s)
  | _ -> default

let json_bool ?(default = false) key json =
  match safe_member key json with
  | `Bool b -> b
  | `String s -> Option.value ~default (parse_bool_string s)
  | _ -> default

let json_string_list key json =
  match safe_member key json with
  | `List l ->
      List.filter_map (fun v -> match v with `String s -> Some s | _ -> None) l
  | _ -> []

let json_string_opt key json =
  match safe_member key json with
  | `String s -> Some s
  | _ -> None

(* String-coercing *_opt variants mirror json_int/json_float/json_bool:
   accept stringified numerics/bools from small-LLM callers. Missing key
   or non-parseable value → None (no silent default substitution). *)
let json_int_opt key json =
  match safe_member key json with
  | `Int i -> Some i
  | `Float f -> Some (int_of_float f)
  | `String s -> parse_numeric_string s
  | _ -> None

let json_float_opt key json =
  match safe_member key json with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | `String s -> parse_float_string s
  | _ -> None

let json_bool_opt key json =
  match safe_member key json with
  | `Bool b -> Some b
  | `String s -> parse_bool_string s
  | _ -> None

let json_list key json =
  match safe_member key json with
  | `List l -> l
  | _ -> []

let json_list_opt key json =
  match safe_member key json with
  | `List l -> Some l
  | _ -> None

let json_assoc key json =
  match safe_member key json with
  | `Assoc a -> a
  | _ -> []

let json_member_opt key json =
  match safe_member key json with
  | `Null -> None
  | v -> Some v

(** {1 Tail-recursive list helpers} *)

(** Tail-recursive replacement for [Stdlib.List.concat_map].
    [Stdlib.List.concat_map f l] is implemented as [concat (map f l)] —
    neither [map] nor [concat] is tail-recursive, so a list of N elements
    where [f] returns M-element sub-lists uses O(N + N*M) stack frames.
    This version uses [fold_left] + [rev_append] — constant stack. *)
let concat_map_safe (f : 'a -> 'b list) (l : 'a list) : 'b list =
  List.rev (List.fold_left (fun acc x -> List.rev_append (f x) acc) [] l)

(** Tail-recursive replacement for [Stdlib.List.map].
    [Stdlib.List.map] builds the result on the stack — O(N) frames.
    For lists that may exceed ~10K elements, use this instead. *)
let map_safe (f : 'a -> 'b) (l : 'a list) : 'b list =
  List.rev (List.rev_map f l)

(** {1 Safe Process Execution} *)

(* Intentionally empty: process execution lives in Process_eio (argv-only). *)
