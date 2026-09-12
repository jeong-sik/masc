type authority = Task_producer of string | Goal_workspace

type error =
  | Invalid_request of string
  | Access_denied of string
  | Source_unavailable of string
  | Storage_failed of string

let error_to_string error =
  let code, detail = match error with
    | Invalid_request detail -> "verification_source_invalid_request", detail
    | Access_denied detail -> "verification_source_access_denied", detail
    | Source_unavailable detail -> "verification_source_unavailable", detail
    | Storage_failed detail -> "verification_source_storage_failed", detail in
  Yojson.Safe.to_string (`Assoc ["code", `String code; "detail", `String detail])

let ( let* ) = Result.bind

let protect f =
  try f () with
  | (Sys_error _ | Unix.Unix_error _ | Eio.Io _ | Yojson.Json_error _) as error ->
    Error (Storage_failed (Printexc.to_string error))

(* Board is the process's active workspace store. Do not join it to task/Goal
   state belonging to another config, nor expose its directory as a file root. *)
let require_workspace config =
  if String.equal
       (Fs_compat.realpath_lenient (Filename.dirname (Board.persist_path ())))
       (Fs_compat.realpath_lenient (Workspace.masc_dir config))
  then Ok ()
  else Error (Access_denied "review workspace does not own the active Board store")

let require_visible authority (post : Board.post) =
  match post.visibility, authority with
  | (Board.Public | Board.Unlisted | Board.Internal), _ -> Ok ()
  | Board.Direct, Task_producer producer
    when String.equal producer (Board.Agent_id.to_string post.author) -> Ok ()
  | Board.Direct, (Task_producer _ | Goal_workspace) ->
    Error (Access_denied
      "Direct discussion is outside this review authority; immutable target readership is not available")

let required_id args field =
  match Json_util.get_string args field with
  | Some value when String.trim value <> "" -> Ok value
  | Some _ | None -> Error (Invalid_request (field ^ " is required for an exact source lookup"))

let optional_integer args field ~default =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | None -> Ok default
     | Some (`Int value) -> Ok value
     | Some _ -> Error (Invalid_request (field ^ " must be an integer when provided")))
  | _ -> Error (Invalid_request "source lookup arguments must be an object")

let board_error = function
  | Board.Post_not_found _ -> Source_unavailable "referenced Board post was not found; no deletion or expiry is inferred"
  | (Board.Invalid_id _ | Board.Validation_error _) as error ->
    Invalid_request (Board_tool.board_error_to_string error)
  | Board.Unauthorized _ as error -> Access_denied (Board_tool.board_error_to_string error)
  | Board.Io_error _ as error -> Storage_failed (Board_tool.board_error_to_string error)
  | (Board.Comment_not_found _ | Board.Already_exists _ | Board.Already_voted _) as error ->
    Source_unavailable (Board_tool.board_error_to_string error)

let read_board ~config ~authority ~args = protect (fun () ->
  let* () = require_workspace config in
  let* post_id = required_id args "post_id" in
  let* offset = optional_integer args "comment_offset" ~default:0 in
  let* limit = optional_integer args "comment_limit"
      ~default:Board.Limits.default_comment_page_limit in
  let* () =
    if offset < 0 || limit < 1 || limit > Board.Limits.max_comment_page_limit then
      Error (Invalid_request "comment pagination is outside the Board descriptor contract")
    else Ok () in
  let* post, comments = Board_dispatch.get_post_and_comments ~post_id ()
    |> Result.map_error board_error in
  let* () = require_visible authority post in
    let total = List.length comments in
    let offset = min offset total in
    let selected = List.filteri (fun index _ -> index >= offset && index - offset < limit) comments in
    let next = offset + List.length selected in
    Ok (`Assoc
      [ "source", `String "board"
      ; "post", Board.post_to_yojson post
      ; "comments", `List (List.map Board.comment_to_yojson selected)
      ; "pagination", `Assoc
          [ "offset", `Int offset; "returned", `Int (List.length selected)
          ; "total", `Int total; "has_more", `Bool (next < total)
          ; "next_offset", (if next < total then `Int next else `Null) ] ]))

let fusion_error = function
  | Fusion_decision.Rejected detail -> Source_unavailable detail
  | Fusion_decision.Storage_failure detail -> Storage_failed detail

let read_fusion ~config ~authority ~args = protect (fun () ->
  let* () = require_workspace config in
  let* run_id = required_id args "run_id" in
  let* post = Fusion_decision.source_in_workspace ~run_id |> Result.map_error fusion_error in
  let* () = require_visible authority post in
  let* () = match authority with
    | Goal_workspace -> Ok ()
    | Task_producer producer ->
      if String.equal producer (Board.Agent_id.to_string post.author) then Ok ()
      else Error (Access_denied "Fusion source belongs to another producer") in
  (* Preserve the existing owner check for Task reads; a Goal reads shared
     workspace advice under its own authority, without inventing a Keeper. *)
  let* decisions = match authority with
    | Task_producer producer ->
      Fusion_decision.read_for_keeper ~config ~keeper:producer ~run_id
      |> Result.map_error fusion_error
    | Goal_workspace ->
      Fusion_decision.read ~config ~run_id |> Result.map_error fusion_error in
  Ok (`Assoc
    [ "source", `String "fusion"
    ; "run_id", `String run_id
    ; "evidence_sha256", `String (Fusion_decision.evidence_sha256 post)
    ; "post", Board.post_to_yojson post
    ; "keeper_decisions", `List decisions ]))
