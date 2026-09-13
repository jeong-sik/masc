module Store = Workspace_verification_store

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
  let Board_dispatch.Jsonl store = Board_dispatch.backend () in
  match store.Board.workspace_masc_dir with
  | Some workspace when String.equal workspace
      (Fs_compat.realpath_lenient (Workspace.masc_dir config)) -> Ok ()
  | Some _ | None ->
    Error (Access_denied "review workspace does not own the active Board store")

let require_visible authority (post : Board.post) =
  match post.visibility, authority with
  | (Board.Public | Board.Unlisted | Board.Internal), _ -> Ok ()
  | Board.Direct, Task_producer producer
    when String.equal producer (Board.Agent_id.to_string post.author) -> Ok ()
  | Board.Direct, (Task_producer _ | Goal_workspace) ->
    Error (Access_denied
      "Direct discussion is outside this review authority; immutable target readership is not available")

(* The canonical Board and Fusion handlers trim the id before an exact lookup;
   an id this reader keeps untrimmed would miss the same source they find. *)
let required_id args field =
  match Option.map String.trim (Json_util.get_string args field) with
  | Some value when value <> "" -> Ok value
  | Some _ | None -> Error (Invalid_request (field ^ " is required for an exact source lookup"))

let optional_integer args field ~default =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | None -> Ok default
     | Some (`Int value) -> Ok value
     | Some _ -> Error (Invalid_request (field ^ " must be an integer when provided")))
  | _ -> Error (Invalid_request "source lookup arguments must be an object")

(* The same wire budget used by the verifier's bridge. Pages carry exact
   JSON text, not an excerpt; the digest pins every cursor to one observation. *)
let page_source ~args source =
  let bytes = Yojson.Safe.to_string source in
  let total = String.length bytes in
  let digest = Digestif.SHA256.(digest_string bytes |> to_hex) in
  let budget = Tool_bridge.default_externalize_threshold_bytes in
  let* cursor = match args with
    | `Assoc fields ->
      (match List.assoc_opt "cursor" fields with
       | None -> Ok None
       | Some (`Assoc fields) when List.length fields = 2 ->
         (match List.assoc_opt "source_sha256" fields, List.assoc_opt "byte_offset" fields with
          | Some (`String expected), Some (`Int offset) ->
            if not (String.equal expected digest) then
              Error (Source_unavailable "source changed between pages; restart the exact source read")
            else if offset > 0 && offset < total
              && String_util.utf8_char_boundary bytes offset = offset then Ok (Some offset)
            else Error (Invalid_request "invalid source cursor")
          | _ -> Error (Invalid_request "invalid source cursor"))
       | Some _ -> Error (Invalid_request "invalid source cursor"))
    | _ -> Error (Invalid_request "source lookup arguments must be an object") in
  match cursor with
  | None when total <= budget -> Ok source
  | None | Some _ ->
    let offset = match cursor with None -> 0 | Some offset -> offset in
    let page ending =
      let next = if ending = total then `Null else `Assoc
        ["source_sha256", `String digest; "byte_offset", `Int ending] in
      `Assoc ["representation", `String "source_json_page";
        "source_sha256", `String digest; "total_bytes", `Int total;
        "byte_offset", `Int offset; "content", `String (String.sub bytes offset (ending - offset));
        "next_cursor", next] in
    let rec fit low high =
      if low >= high then low else
        let mid = low + ((high - low + 1) / 2) in
        let ending = String_util.utf8_char_boundary bytes mid in
        if String.length (Yojson.Safe.to_string (page ending)) <= budget
        then fit mid high else fit low (mid - 1) in
    let ending = String_util.utf8_char_boundary bytes (fit offset (min total (offset + budget))) in
    if ending <= offset then Error (Source_unavailable "source page envelope exceeds the bridge budget")
    else Ok (page ending)

let board_error = function
  | Board.Post_not_found _ -> Source_unavailable "referenced Board post was not found; no deletion or expiry is inferred"
  | (Board.Invalid_id _ | Board.Validation_error _) as error ->
    Invalid_request (Board_tool.board_error_to_string error)
  | Board.Unauthorized _ as error -> Access_denied (Board_tool.board_error_to_string error)
  | Board.Io_error _ as error -> Storage_failed (Board_tool.board_error_to_string error)
  | (Board.Comment_not_found _ | Board.Already_exists _ | Board.Already_voted _) as error ->
    Source_unavailable (Board_tool.board_error_to_string error)

let capture_board ~config ~authority ~post_id =
  let* () = require_workspace config in
  let* () = Board_dispatch.require_persisted_sources_readable () |> Result.map_error board_error in
  let* post, comments = Board_dispatch.get_post_and_comments ~post_id ()
    |> Result.map_error board_error in
  let* () = require_visible authority post in
  Ok (`Assoc ["source", `String "board"; "post", Board.post_to_yojson post;
    "comments", `List (List.map Board.comment_to_yojson comments)])

let fusion_error = function
  | Fusion_decision.Rejected detail -> Source_unavailable detail
  | Fusion_decision.Storage_failure detail -> Storage_failed detail

let capture_fusion ~config ~authority ~run_id =
  let* () = require_workspace config in
  let* () = Board_dispatch.require_persisted_sources_readable () |> Result.map_error board_error in
  let* post = Fusion_decision.source_in_workspace ~run_id |> Result.map_error fusion_error in
  let* producer = match post.Board.origin with
    | Some {fusion_run_id=Some actual; fusion_producer=Some producer; _}
      when actual = run_id && String.trim producer <> "" -> Ok producer
    | _ -> Error (Source_unavailable "Fusion source has no immutable producer identity") in
  let* () = match authority with
    | Task_producer expected when expected = producer -> Ok ()
    | Task_producer _ -> Error (Access_denied "Fusion source belongs to another producer")
    | Goal_workspace -> require_visible authority post in
  let* decisions = Fusion_decision.read ~config ~run_id |> Result.map_error fusion_error in
  Ok (`Assoc
    [ "source", `String "fusion"
    ; "run_id", `String run_id
    ; "evidence_sha256", `String (Fusion_decision.evidence_sha256 post)
    ; "post", Board.post_to_yojson post
    ; "keeper_decisions", `List decisions ])


(* Captured once before the request commit; never capture on verifier read. *)
let capture ~config ~authority ~references = protect (fun () ->
  List.fold_left (fun result reference ->
    let* items = result in
    let* source = match Store.collaboration_reference reference with
      | Some (Store.Board_source, post_id) -> capture_board ~config ~authority ~post_id
      | Some (Store.Fusion_source, run_id) -> capture_fusion ~config ~authority ~run_id
      | None -> Error (Invalid_request "expected board:<post-id> or fusion:<run-id>") in
    let content = Yojson.Safe.to_string source in
    let sha256 = Digestif.SHA256.(digest_string content |> to_hex) in
    Ok (items @ [Store.Evidence_collaboration {reference; content; sha256}]))
    (Ok []) (List.sort_uniq String.compare references))

let submitted_source ~submitted_evidence reference =
  let matches = List.filter_map (function
    | Store.Evidence_collaboration item when item.reference = reference ->
        Some (Store.Evidence_collaboration item)
    | _ -> None) submitted_evidence in
  match matches with
  | [item] ->
      (* Reuse the persistence decoder for hash and shape validation. *)
      let* item = Store.submitted_evidence_item_of_yojson
        (Store.submitted_evidence_item_to_yojson item)
        |> Result.map_error (fun detail -> Storage_failed detail) in
      (match item with
       | Store.Evidence_collaboration {content; _} -> Ok (Yojson.Safe.from_string content)
       | _ -> Error (Storage_failed "invalid submitted collaboration kind"))
  | [] -> Error (Access_denied "source was not captured in this verification submission")
  | _ -> Error (Storage_failed "duplicate submitted collaboration identity")

let read_board ~submitted_evidence ~args = protect (fun () ->
  let* post_id = required_id args "post_id" in
  let* offset = optional_integer args "comment_offset" ~default:0 in
  let* limit = optional_integer args "comment_limit" ~default:Board.Limits.default_comment_page_limit in
  let* () = if offset < 0 || limit < 1 || limit > Board.Limits.max_comment_page_limit then
    Error (Invalid_request "comment pagination is outside the Board descriptor contract") else Ok () in
  let* source = submitted_source ~submitted_evidence ("board:" ^ post_id) in
  match source with
  | `Assoc ["source", `String "board"; "post", post; "comments", `List comments] ->
      let* () = match Board.post_of_yojson post with
        | Some decoded when Board.Post_id.to_string decoded.id = post_id -> Ok ()
        | _ -> Error (Storage_failed "submitted Board identity does not match reference") in
      let total = List.length comments in
      let offset = min offset total in
      let selected = List.filteri (fun index _ -> index >= offset && index - offset < limit) comments in
      let next = offset + List.length selected in
      page_source ~args (`Assoc ["source", `String "board"; "post", post;
        "comments", `List selected; "pagination", `Assoc ["offset", `Int offset;
          "returned", `Int (List.length selected); "total", `Int total;
          "has_more", `Bool (next < total); "next_offset", (if next < total then `Int next else `Null)]])
  | _ -> Error (Storage_failed "invalid submitted Board snapshot"))

let read_fusion ~submitted_evidence ~args = protect (fun () ->
  let* run_id = required_id args "run_id" in
  let* source = submitted_source ~submitted_evidence ("fusion:" ^ run_id) in
  match source with
  | `Assoc fields when List.assoc_opt "source" fields = Some (`String "fusion")
      && List.assoc_opt "run_id" fields = Some (`String run_id) -> page_source ~args source
  | _ -> Error (Storage_failed "invalid submitted Fusion snapshot"))
