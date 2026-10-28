module Ledger_state = Workspace_memory_ledger
module Briefing_state = Workspace_memory_briefing

open Result.Syntax

type ledger = string
type briefing = string
type t = Ledger of ledger | Briefing of briefing

let sha256 bytes = Agent_core_sha256.(digest_string bytes |> to_hex)
let digest = function Ledger digest | Briefing digest -> digest
let kind = function Ledger _ -> "ledger" | Briefing _ -> "briefing"

(* The bytes each revision names: the ledger as [Ledger_state.save] writes it,
   the Briefing state with its keys sorted. Briefing JSON holds only strings,
   null, lists and objects, so sorting is all its canonical form needs. *)
let ledger_bytes state = Yojson.Safe.to_string (Ledger_state.to_json state)
let briefing_bytes state = Yojson.Safe.to_string (Yojson.Safe.sort (Briefing_state.to_json state))

let of_ledger = Ledger_state.sha256
let of_briefing state = sha256 (briefing_bytes state)
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

let name revision = kind revision ^ " revision " ^ digest revision

type write_error = { revision : t; detail : string }

let write_error_to_string {revision; detail} = name revision ^ " could not be written: " ^ detail

type read_error =
  | Missing of t
  | Damaged of { revision : t; detail : string }
  | Unreadable of { revision : t; detail : string }

let read_error_to_string = function
  | Missing revision -> name revision ^ " has no file"
  | Damaged {revision; detail} -> name revision ^ " is damaged: " ^ detail
  | Unreadable {revision; detail} -> name revision ^ " could not be read: " ^ detail

(* The base is the ownership root: the write refuses a base that is missing or
   not a directory and a symbolic link below it, and checks the directory
   chain again on every call. The writer returns every failure but
   cancellation as an error. *)
let write ~base_path revision bytes =
  Keeper_fs.save_bytes_durable_atomic ~ownership_root:base_path (path ~base_path revision) bytes
  |> Result.map_error (fun error -> {revision; detail = Keeper_fs.durable_write_error_to_string error})

type stored_ledger = { revision : ledger; workspace : string * int * int }
let stored_ledger_revision stored = stored.revision
let stored_ledger_workspace stored = stored.workspace

let write_ledger ~base_path state =
  let bytes = ledger_bytes state in
  let revision = sha256 bytes in
  let observed = Fs_compat.with_owned_inventory_root base_path (fun root ->
    let stat = Fs_compat.owned_inventory_root_stat root in
    let workspace = Fs_compat.owned_inventory_root_path root, stat.Unix.st_dev, stat.Unix.st_ino in
    Ok (workspace, write ~base_path (Ledger revision) bytes)) in
  let* workspace, written = observed |> Result.map_error (fun error ->
    {revision=Ledger revision; detail=Fs_compat.owned_regular_file_read_error_to_string error}) in
  let* () = written in
  Ok {revision; workspace}

let write_briefing ~base_path state =
  let bytes = briefing_bytes state in
  let revision = sha256 bytes in
  write ~base_path (Briefing revision) bytes |> Result.map (fun () -> revision)

(* Read under the same ownership root as the write, so a symbolic link or a
   directory where the file belongs is refused rather than followed. *)
let read ~base_path revision ~decode ~revision_of =
  let damaged detail = Damaged {revision; detail} in
  match Fs_compat.load_owned_regular_file ~ownership_root:base_path (path ~base_path revision) with
  | Error error -> Error (Unreadable {revision; detail = Fs_compat.owned_regular_file_read_error_to_string error})
  | Ok None -> Error (Missing revision)
  | Ok (Some bytes) ->
    let actual = sha256 bytes in
    if not (String.equal actual (digest revision)) then Error (damaged ("its bytes hash to " ^ actual))
    else
      let* json = try Ok (Yojson.Safe.from_string bytes) with
        | Yojson.Json_error detail -> Error (damaged detail) in
      let* state = decode json |> Result.map_error damaged in
      let again = revision_of state in
      if String.equal again (digest revision) then Ok state
      else Error (damaged ("it decodes to a state whose revision is " ^ again))

let read_ledger ~base_path revision =
  read ~base_path (Ledger revision) ~decode:Ledger_state.of_json ~revision_of:of_ledger

let read_briefing ~base_path revision =
  read ~base_path (Briefing revision) ~decode:Briefing_state.of_json ~revision_of:of_briefing
