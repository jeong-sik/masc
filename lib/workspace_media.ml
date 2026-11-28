let exists ~base_path sha256 =
  let store = Attachment_store.create ~base_path in
  match Attachment_store.get_meta_by_sha256 store ~sha256 with
  | Ok (Some _) -> Ok true
  | Ok None ->
    Ok
      (Option.is_some
         (Keeper_chat_media_store.file_path_of_token ~base_dir:base_path ~token:sha256))
  | Error error -> Error (Attachment_store.get_error_to_string error)
;;

let known_missing ~base_path sha256s =
  List.filter
    (fun sha256 ->
       match exists ~base_path sha256 with
       | Ok false -> true
       | Ok true | Error _ -> false)
    sha256s
;;
