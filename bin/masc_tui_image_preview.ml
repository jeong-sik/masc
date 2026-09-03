(** See {!Masc_tui_image_preview} (.mli) for the contract. *)

type order =
  | Named_is_newer
  | Staged_is_newer
  | Unordered

type preview =
  | Named_path of string
  | Staged of Masc_tui_keeper_chat_projection.attachment
  | No_image

let choose_preview ~named ~staged ~order =
  let newest_staged =
    match List.rev staged with
    | newest :: _ -> Some newest
    | [] -> None
  in
  match named, newest_staged with
  | None, None -> No_image
  | Some path, None -> Named_path path
  | None, Some attachment -> Staged attachment
  | Some path, Some attachment -> (
    match order with
    | Staged_is_newer -> Staged attachment
    | Named_is_newer | Unordered -> Named_path path)
;;
