module Ledger_state = Workspace_memory_ledger
module Briefing_state = Workspace_memory_briefing

let ( let* ) = Result.bind

type ledger = string
type briefing = string
type t = Ledger of ledger | Briefing of briefing

let sha256 bytes = Digestif.SHA256.(digest_string bytes |> to_hex)
let digest = function Ledger digest | Briefing digest -> digest
let kind = function Ledger _ -> "ledger" | Briefing _ -> "briefing"

(* The bytes each revision names: the ledger as [Ledger_state.save] writes it,
   the Briefing state with its keys sorted. *)
let ledger_bytes state = Yojson.Safe.to_string (Ledger_state.to_json state)
let briefing_bytes state =
  Result.map Yojson.Safe.to_string (Lane_addon_action.canonical (Briefing_state.to_json state))

let of_ledger = Ledger_state.sha256
let of_briefing state = Result.map sha256 (briefing_bytes state)
let ledger_sha256 revision = revision
let briefing_sha256 revision = revision

let to_json revision = `Assoc ["kind", `String (kind revision); "sha256", `String (digest revision)]

let of_json = function
  | `Assoc fields when List.equal String.equal (List.sort String.compare (List.map fst fields)) ["kind"; "sha256"] ->
    let* digest = match List.assoc "sha256" fields with
      | `String digest when String_util.is_lowercase_sha256_hex digest -> Ok digest
      | _ -> Error "a revision is named by 64 lowercase hex digits" in
    (match List.assoc "kind" fields with
     | `String "ledger" -> Ok (Ledger digest)
     | `String "briefing" -> Ok (Briefing digest)
     | _ -> Error "a revision kind is ledger or briefing")
  | _ -> Error "a revision is an object with exactly kind and sha256"

let path ~base_path revision =
  List.fold_left Filename.concat (Ledger_state.directory ~base_path)
    ["revisions"; kind revision; digest revision ^ ".json"]

type error =
  | Missing of t
  | Damaged of { revision : t; detail : string }
  | Unavailable of { revision : t; detail : string }
  | Unencodable of string

let error_to_string error =
  let name revision = kind revision ^ " revision " ^ digest revision in
  match error with
  | Missing revision -> name revision ^ " has no file"
  | Damaged {revision; detail} -> name revision ^ " is damaged: " ^ detail
  | Unavailable {revision; detail} -> name revision ^ " is unavailable: " ^ detail
  | Unencodable detail -> "Briefing state has no key-sorted JSON: " ^ detail

let io revision f =
  try f () with
  | Unix.Unix_error (error, fn, arg) ->
    Error (Unavailable {revision; detail = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error)})
  | Sys_error detail -> Error (Unavailable {revision; detail})
  | Eio.Io _ as exn -> Error (Unavailable {revision; detail = Printexc.to_string exn})

(* A base path that does not exist is a wrong path; writing would create it. *)
let write ~base_path revision bytes =
  io revision (fun () ->
    if not (Sys.is_directory base_path) then
      Error (Unavailable {revision; detail = base_path ^ ": workspace base is not a directory"})
    else
      Keeper_fs.save_bytes_durable_atomic (path ~base_path revision) bytes
      |> Result.map_error (fun error ->
        Unavailable {revision; detail = Keeper_fs.durable_write_error_to_string error}))

let write_ledger ~base_path state =
  let bytes = ledger_bytes state in
  let revision = sha256 bytes in
  write ~base_path (Ledger revision) bytes |> Result.map (fun () -> revision)

let write_briefing ~base_path state =
  let* bytes = briefing_bytes state |> Result.map_error (fun detail -> Unencodable detail) in
  let revision = sha256 bytes in
  write ~base_path (Briefing revision) bytes |> Result.map (fun () -> revision)

let read ~base_path revision ~decode ~revision_of =
  io revision (fun () ->
    match Fs_compat.load_file_opt (path ~base_path revision) with
    | None -> Error (Missing revision)
    | Some bytes ->
      let damaged detail = Damaged {revision; detail} in
      let actual = sha256 bytes in
      if not (String.equal actual (digest revision)) then Error (damaged ("its bytes hash to " ^ actual))
      else
        let* json = try Ok (Yojson.Safe.from_string bytes) with
          | Yojson.Json_error detail -> Error (damaged detail) in
        let* state = decode json |> Result.map_error damaged in
        let* again = revision_of state |> Result.map_error damaged in
        if String.equal again (digest revision) then Ok state
        else Error (damaged ("it decodes to a state whose revision is " ^ again)))

let read_ledger ~base_path revision =
  read ~base_path (Ledger revision) ~decode:Ledger_state.of_json
    ~revision_of:(fun state -> Ok (of_ledger state))

let read_briefing ~base_path revision =
  read ~base_path (Briefing revision) ~decode:Briefing_state.of_json ~revision_of:of_briefing
