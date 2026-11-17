module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Approval = Lane_addon_request_approval
module Fingerprint = Keeper_approval_request_fingerprint

type reference =
  { request : Fingerprint.exact_request
  ; approval_id : string option
  }
type t = reference list

let read ~base_path =
  let store = Lane_addon_store.create
      ~root:(Lane_addon_store.directory
        ~masc_dir:(Config_dir_resolver.masc_root ~base_path)) in
  Eio_guard.run_in_systhread ~label:"approval-original-readers" (fun () ->
    Owner.fold_all_records ~store ~init:[] ~f:(fun found record ->
      let captured = match Progress.approval (Owner.Record.progress record) with
        | None -> None
        | Some (Progress.Intent_pending intent) -> Some (intent, None)
        | Some (Progress.Waiting_for_approval (intent, waiting)) ->
          Some (intent, Some waiting)
      in
      match captured with
      | None -> Ok found
      | Some (intent, waiting) ->
        let request = Approval.request intent in
        if not (String.equal (Approval.original_request_id intent)
                  (Owner.Record.request_id record)
                && String.equal (Approval.original_request_digest intent)
                  (Owner.Record.request_digest record)
                && String.equal (Fingerprint.base_path request) base_path)
        then Error (Owner.Invalid_request
          "approval intent differs from its original record or workspace")
        else match waiting with
          | Some waiting when not (Approval.wait_matches_intent intent waiting) ->
            Error (Owner.Invalid_request "approval wait differs from its original intent")
          | Some waiting ->
            Ok ({ request; approval_id = Some (Approval.approval_id waiting) } :: found)
          | None -> Ok ({ request; approval_id = None } :: found))
    |> Result.map_error Owner.error_to_string)

let protects references ~approval_id ~matches =
  List.exists (fun reference ->
    (match reference.approval_id with
     | Some id -> String.equal id approval_id
     | None -> false)
    || matches reference.request) references
