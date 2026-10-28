module Owner = Lane_addon_tool_request_owner

open Result.Syntax

let scope = "hitl-judge-originals"
let package_id = "hitl-auto-judge"
let tool = "judge"
let installation = Owner.Manual "hitl-auto-judge-host"

let request_id_of ~approval_id ~sequence = Printf.sprintf "%s#%d" approval_id sequence

let request_id original =
  request_id_of
    ~approval_id:(Hitl_judge_original.approval_id original)
    ~sequence:(Hitl_judge_original.sequence original)
;;

let summary original =
  `Assoc
    [ "approval_id", `String (Hitl_judge_original.approval_id original)
    ; "input_hash", `String (Hitl_judge_original.input_hash original)
    ; "sequence", `Int (Hitl_judge_original.sequence original)
    ]
;;

let retain ~store original =
  Owner.retain
    ~store
    ~scope
    ~request_id:(request_id original)
    ~installation_id:(Owner.installation_id installation)
    ~package_id
    ~tool
    ~summary:(summary original)
    ~request:(Hitl_judge_original.to_json original)
  |> Result.map_error Owner.error_to_string
;;

let load ~store ~approval_id ~sequence =
  let* record =
    Owner.load ~store ~scope ~request_id:(request_id_of ~approval_id ~sequence)
    |> Result.map_error Owner.error_to_string
  in
  match record with
  | None -> Ok (None, None)
  | Some (retained : Owner.retained) ->
    let* original = Hitl_judge_original.of_json retained.request in
    let* () =
      if String.equal (request_id original) retained.request_id
      then Ok ()
      else Error "Judge original differs from the attempt its record names"
    in
    let* () =
      if Yojson.Safe.equal (summary original) retained.summary
      then Ok ()
      else Error "Judge original differs from the summary its record keeps"
    in
    let* () =
      if String.equal retained.installation_id (Owner.installation_id installation)
         && String.equal retained.package_id package_id
         && String.equal retained.tool tool
      then Ok ()
      else Error "Judge original belongs to another installation, package or tool"
    in
    Ok (Some retained, Some original)
;;
