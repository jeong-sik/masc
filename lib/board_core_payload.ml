(** Board_core_payload — State block extraction and post payload normalization.

    Handles [STATE]...[/STATE] block parsing from post bodies,
    title derivation, and content normalization before persistence.

    @since God file decomposition — extracted from board_core.ml *)

let state_start_marker = "[STATE]"
let state_end_marker = "[/STATE]"

(* Hoisted to module level to avoid per-call recompilation *)
let start_re = Re.str state_start_marker |> Re.compile
let end_re = Re.str state_end_marker |> Re.compile

let extract_state_block (text : string) : string option * string =
  match Re.exec_opt start_re text with
  | None -> None, String.trim text
  | Some g ->
    let start_idx = Re.Group.start g 0 in
    let block_body_start = start_idx + String.length state_start_marker in
    let end_idx =
      match Re.exec_opt ~pos:block_body_start end_re text with
      | Some g2 -> Re.Group.start g2 0
      | None -> String.length text
    in
    let block_end = min (String.length text) (end_idx + String.length state_end_marker) in
    let state_block = String.sub text start_idx (block_end - start_idx) |> String.trim in
    let before = if start_idx = 0 then "" else String.sub text 0 start_idx in
    let after =
      if block_end >= String.length text
      then ""
      else String.sub text block_end (String.length text - block_end)
    in
    Some state_block, String.trim (before ^ after)
;;

let meta_state_block (meta_json : Yojson.Safe.t option) =
  match meta_json with
  | Some (`Assoc fields) ->
    (match List.assoc_opt "state_block" fields with
     | Some (`String value) ->
       let value = String.trim value in
       if value = "" then None else Some value
     | _ -> None)
  | _ -> None
;;

let merge_meta_json ?state_block (meta_json : Yojson.Safe.t option) : Yojson.Safe.t option
  =
  let fields =
    match meta_json with
    | Some (`Assoc assoc) -> assoc
    | _ -> []
  in
  let fields =
    match state_block with
    | Some block when block <> "" && not (List.mem_assoc "state_block" fields) ->
      ("state_block", `String block) :: fields
    | _ -> fields
  in
  match fields with
  | [] -> None
  | _ -> Some (`Assoc fields)
;;

let derive_post_title (body : string) =
  let first_line =
    body
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.find_opt (fun line -> line <> "")
    |> Option.value ~default:"Untitled post"
  in
  (* UTF-8-safe truncation: byte-based String.sub used to split multi-byte
     characters, producing invalid UTF-8 lines in board_posts.jsonl
     (Issue #7690). utf8_safe returns a variant so future callers can
     observe/meter truncation events; here we just materialize. *)
  String_util.utf8_safe ~max_bytes:80 ~suffix:"..." first_line |> String_util.to_string
;;

let normalize_post_payload ~content ?title ?body ~post_kind ?meta_json () =
  let raw_body = Option.value body ~default:content in
  let extracted_state, stripped_body = extract_state_block raw_body in
  let normalized_body = String.trim stripped_body in
  let normalized_title =
    match title with
    | Some value when String.trim value <> "" -> String.trim value
    | _ -> derive_post_title normalized_body
  in
  let merged_meta = merge_meta_json ?state_block:extracted_state meta_json in
  normalized_title, normalized_body, post_kind, merged_meta
;;
