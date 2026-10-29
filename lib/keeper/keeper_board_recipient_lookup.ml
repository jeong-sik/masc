(* The Keeper whose own name or alias is [name], by the persisted settings.
   [name] is already a valid Keeper name, so the file name built from it stays
   inside the Keeper settings directory. *)
let keeper_named config name =
  match Keeper_meta_store.read_effective_meta_resolved config name with
  | Error detail -> Error detail
  | Ok (Some (keeper_name, _meta)) -> Ok (Some keeper_name)
  | Ok None ->
    (match
       Keeper_meta_store.persisted_keeper_for_mention_target
         config
         ~mention_target:name
     with
     | Error detail -> Error detail
     | Ok None -> Ok None
     | Ok (Some (keeper_name, _meta)) -> Ok (Some keeper_name))
;;

let recipient_of_keeper keeper_name =
  match Board.Agent_id.parse keeper_name with
  | Ok recipient -> Ok (Some recipient)
  | Error error ->
    Error
      (Printf.sprintf
         "Keeper %S cannot be recorded as a Board recipient: %s"
         keeper_name
         (Board.show_board_error error))
;;

let declared ~base_path candidate =
  let written = Recipient_resolution.Candidate.to_string candidate in
  match Keeper_identity.Keeper_id.of_string written with
  | None -> Ok None
  | Some id ->
    let name = Keeper_identity.Keeper_id.to_string id in
    (match Keeper_id.Keeper_name.of_string name with
     | Error _ -> Ok None
     | Ok _ ->
       (match keeper_named (Workspace.default_config base_path) name with
        | Error detail -> Error (Printf.sprintf "cannot resolve @%s: %s" written detail)
        | Ok None -> Ok None
        | Ok (Some keeper_name) -> recipient_of_keeper keeper_name))
;;

let make ~base_path = Recipient_lookup.make (declared ~base_path)
