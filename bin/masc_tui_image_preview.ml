(** See {!Masc_tui_image_preview} (.mli) for the contract. *)

type preview =
  | Named_path of string
  | Staged of Masc_tui_keeper_chat_projection.attachment
  | No_image

let choose_preview ~named ~staged =
  match named with
  | Some path -> Named_path path
  | None -> (
    match List.rev staged with
    | newest :: _ -> Staged newest
    | [] -> No_image)
;;
