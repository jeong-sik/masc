(** Trpg internal utilities.
    Slim copies of functions from the main library to avoid circular dependency.
    Keep in sync with: Safe_ops, Room_utils, Log. *)

(* ================================================================ *)
(* JSON helpers (from Safe_ops)                                     *)
(* ================================================================ *)

let read_json_eio (path : string) : Yojson.Safe.t =
  let content = Fs_compat.load_file path in
  Yojson.Safe.from_string content

let read_json_file_safe path : (Yojson.Safe.t, string) result =
  try
    let content = Fs_compat.load_file path in
    Ok (Yojson.Safe.from_string content)
  with exn -> Error (Printexc.to_string exn)

let json_string_opt key json =
  let open Yojson.Safe.Util in
  try
    match json |> member key with
    | `Null -> None
    | j -> Some (to_string j)
  with _ -> None

let json_int_opt key json =
  let open Yojson.Safe.Util in
  try
    match json |> member key with
    | `Null -> None
    | j -> Some (to_int j)
  with _ -> None

let json_bool_opt key json =
  let open Yojson.Safe.Util in
  try
    match json |> member key with
    | `Null -> None
    | j -> Some (to_bool j)
  with _ -> None

(* ================================================================ *)
(* Filesystem (from Room_utils / Fs_compat)                         *)
(* ================================================================ *)

let mkdir_p path = Fs_compat.mkdir_p path

(* ================================================================ *)
(* Logging (from Log.Trpg)                                          *)
(* ================================================================ *)

let log_info fmt = Printf.ksprintf (fun s -> Printf.eprintf "[trpg] INFO: %s\n%!" s) fmt
let log_warn fmt = Printf.ksprintf (fun s -> Printf.eprintf "[trpg] WARN: %s\n%!" s) fmt
let log_error fmt = Printf.ksprintf (fun s -> Printf.eprintf "[trpg] ERROR: %s\n%!" s) fmt
