(* The judgement of a builtin Skill package as a table: every authority,
   receipt state and installed tree, with no filesystem. *)

open Alcotest
module Judgement = Builtin_skill_judgement
module Revision = Builtin_skill_revision

let release = Revision.bundled_entries [ "SKILL.md", "instruction"; "references/guide.md", "guide" ]
let release_revision = Revision.revision release
let owner_only_file_mode = 0o600

type tree = No_tree | Release_tree | Release_files_other_modes | Different_tree
type receipt = No_receipt | Receipt_matches | Receipt_stale

let entries = function
  | No_tree -> None
  | Release_tree -> Some release
  | Release_files_other_modes ->
    Some (List.map (fun (entry : Revision.entry) ->
      match entry.kind with
      | Revision.File -> { entry with mode = owner_only_file_mode }
      | Revision.Directory -> entry) release)
  | Different_tree ->
    Some (Revision.bundled_entries [ "SKILL.md", "operator instruction"; "references/guide.md", "guide" ])

let tree_name = function
  | No_tree -> "no tree"
  | Release_tree -> "release tree"
  | Release_files_other_modes -> "release files, other modes"
  | Different_tree -> "different tree"

let receipt_content receipt tree =
  match receipt, entries tree with
  | No_receipt, (Some _ | None) -> None
  | Receipt_matches, Some installed -> Some (Revision.recorded (Revision.revision installed))
  | Receipt_matches, None -> Some (Revision.recorded release_revision)
  | Receipt_stale, (Some _ | None) -> Some (Revision.recorded "a tree that is gone")

let receipt_name = function
  | No_receipt -> "no receipt"
  | Receipt_matches -> "receipt matches"
  | Receipt_stale -> "receipt stale"

let authority_name = function Judgement.Startup -> "start" | Judgement.Installer -> "installer"

(* Expected shapes. The revision a step carries is checked separately. *)
type expected =
  | Publish
  | Up_to_date
  | Record
  | Record_with_release_permissions
  | Permissions_pending
  | Exchange
  | Replace_pending
  | Keep_modified
  | Keep_untracked_different

let expected_name = function
  | Publish -> "publish"
  | Up_to_date -> "up to date"
  | Record -> "record"
  | Record_with_release_permissions -> "record with release permissions"
  | Permissions_pending -> "permissions pending"
  | Exchange -> "exchange"
  | Replace_pending -> "replace pending"
  | Keep_modified -> "keep modified"
  | Keep_untracked_different -> "keep untracked different"

(* The shape of a step and the installed revision it names, if any. *)
let observed = function
  | Judgement.Publish -> Ok (Publish, None)
  | Judgement.Settled Judgement.Up_to_date -> Ok (Up_to_date, None)
  | Judgement.Record { revision } -> Ok (Record, Some revision)
  | Judgement.Record_with_release_permissions { revision; entries = _ } ->
    Ok (Record_with_release_permissions, Some revision)
  | Judgement.Settled (Judgement.Permissions_pending { revision }) -> Ok (Permissions_pending, Some revision)
  | Judgement.Exchange { revision } -> Ok (Exchange, Some revision)
  | Judgement.Settled (Judgement.Replace_pending { revision }) -> Ok (Replace_pending, Some revision)
  | Judgement.Settled (Judgement.Keep_modified { revision }) -> Ok (Keep_modified, Some revision)
  | Judgement.Settled (Judgement.Keep_untracked_different { revision }) ->
    Ok (Keep_untracked_different, Some revision)
  | Judgement.Settled
      ( Judgement.Install_missing | Judgement.Adopt_identical
      | Judgement.Adopt_with_release_permissions | Judgement.Replace_recorded _
      | Judgement.Keep_uninspectable _ ) ->
    Error "a verdict only the caller produces"

let bundled_table =
  let both expected tree receipt =
    [ Judgement.Startup, receipt, tree, expected; Judgement.Installer, receipt, tree, expected ] in
  let split ~start ~installer tree receipt =
    [ Judgement.Startup, receipt, tree, start; Judgement.Installer, receipt, tree, installer ] in
  List.concat
    [ both Publish No_tree No_receipt
    ; both Publish No_tree Receipt_matches
    ; both Publish No_tree Receipt_stale
    ; both Record Release_tree No_receipt
    ; both Up_to_date Release_tree Receipt_matches
    ; both Record Release_tree Receipt_stale
    ; split ~start:Permissions_pending ~installer:Record_with_release_permissions
        Release_files_other_modes No_receipt
    ; split ~start:Replace_pending ~installer:Exchange Release_files_other_modes Receipt_matches
    ; both Keep_modified Release_files_other_modes Receipt_stale
    ; both Keep_untracked_different Different_tree No_receipt
    ; split ~start:Replace_pending ~installer:Exchange Different_tree Receipt_matches
    ; both Keep_modified Different_tree Receipt_stale ]

let test_bundled_table () =
  check int "every authority, receipt and tree" 24 (List.length bundled_table);
  List.iter (fun (authority, receipt, tree, expected) ->
    let label = String.concat ", " [ authority_name authority; receipt_name receipt; tree_name tree ] in
    let step =
      Judgement.bundled_step authority ~receipt:(receipt_content receipt tree) ~installed:(entries tree)
        ~bundled_revision:release_revision in
    match observed step, entries tree with
    | Error reason, (Some _ | None) -> fail (label ^ ": " ^ reason)
    | Ok (shape, named), installed ->
      check string label (expected_name expected) (expected_name shape);
      check (option string) (label ^ ": names the installed revision")
        (Option.map Revision.revision (match named with Some _ -> installed | None -> None)) named)
    bundled_table

type retired_expected = Remove_receipt | Retire_receipt_pending | Move_aside | Retire_tree_pending | Keep_retired_modified

let retired_name = function
  | Remove_receipt -> "remove receipt"
  | Retire_receipt_pending -> "retire pending, receipt only"
  | Move_aside -> "move aside"
  | Retire_tree_pending -> "retire pending, tree"
  | Keep_retired_modified -> "keep retired modified"

let retired_observed = function
  | Judgement.Remove_receipt -> Ok Remove_receipt
  | Judgement.Settled_retired (Judgement.Retire_pending { revision = None }) -> Ok Retire_receipt_pending
  | Judgement.Move_aside { revision = _ } -> Ok Move_aside
  | Judgement.Settled_retired (Judgement.Retire_pending { revision = Some _ }) -> Ok Retire_tree_pending
  | Judgement.Settled_retired (Judgement.Keep_retired_modified { revision = _ }) -> Ok Keep_retired_modified
  | Judgement.Settled_retired (Judgement.Retire_recorded _ | Judgement.Keep_retired_uninspectable _) ->
    Error "a verdict only the caller produces"

let retired_table =
  [ Judgement.Startup, Receipt_matches, No_tree, Retire_receipt_pending
  ; Judgement.Installer, Receipt_matches, No_tree, Remove_receipt
  ; Judgement.Startup, Receipt_matches, Different_tree, Retire_tree_pending
  ; Judgement.Installer, Receipt_matches, Different_tree, Move_aside
  ; Judgement.Startup, Receipt_stale, Different_tree, Keep_retired_modified
  ; Judgement.Installer, Receipt_stale, Different_tree, Keep_retired_modified ]

let test_retired_table () =
  List.iter (fun (authority, receipt, tree, expected) ->
    let label = String.concat ", " [ authority_name authority; receipt_name receipt; tree_name tree ] in
    match receipt_content receipt tree with
    | None -> fail (label ^ ": a retired package always has a receipt")
    | Some receipt ->
      match retired_observed (Judgement.retired_step authority ~receipt ~installed:(entries tree)) with
      | Ok shape -> check string label (retired_name expected) (retired_name shape)
      | Error reason -> fail (label ^ ": " ^ reason))
    retired_table

let () =
  run "Builtin Skill judgement"
    [ "table", [ test_case "shipped package" `Quick test_bundled_table
               ; test_case "package no longer shipped" `Quick test_retired_table ] ]
