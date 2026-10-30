(* Which names a Keeper answers to is decided where the Board routes a post to a
   Keeper ([Keeper_lane_mentions.effective_target_ids]): its [mention_targets]
   when it has any, else its own name.  The lookup asks the same function, so a
   name it declares is a name the router delivers on.  The broadcast path
   resolves a Keeper's own name before its aliases whatever [mention_targets]
   says; the Board does not. *)
let answers (meta : Keeper_meta_contract.keeper_meta) id =
  List.exists
    (Keeper_identity.Keeper_id.equal id)
    (Keeper_lane_mentions.effective_target_ids
       ~keeper_name:meta.name
       ~mention_targets:meta.mention_targets)
;;

let recipient id =
  let name = Keeper_identity.Keeper_id.to_string id in
  match Board.Agent_id.parse name with
  | Ok recipient -> Ok (Some recipient)
  | Error error ->
    Error
      (Printf.sprintf
         "@%s cannot be recorded as a Board recipient: %s"
         name
         (Board.show_board_error error))
;;

(* The settings are read from disk.  Listing the Keepers makes the directory
   when it is missing, and that raises [Sys_error] when it cannot be made.  A
   read that raises is a failed lookup, so the write ends with an error the
   author gets instead of an exception. *)
let reading read =
  match read () with
  | result -> result
  | exception Sys_error detail -> Error detail
;;

(* Keeper names retain their spelling in metadata filenames. On a
   case-sensitive filesystem the folded name may miss an existing Keeper, so
   check the other persisted spellings of that same identity before the alias
   scan. Only these Keepers' settings are read: an unrelated broken setting
   must not prevent a healthy Keeper's own name from being addressed. Read all
   matching spellings before accepting, so a later unreadable one is reported.
   A file whose payload name differs from its filename can claim an alias, but
   does not acquire own-name priority merely from that filename. *)
let alternate_own_name_answers ~config ~id ~folded_name names =
  let rec find answered = function
    | [] -> Ok answered
    | name :: rest ->
      let matches =
        match Keeper_identity.Keeper_id.of_string name with
        | Some other -> Keeper_identity.Keeper_id.equal id other
        | None -> false
      in
      if not matches || String.equal name folded_name
      then find answered rest
      else
        (match reading (fun () -> Keeper_meta_store.read_effective_meta_presence config name) with
         | Error _ as error -> error
         | Ok (Keeper_meta_store.Meta_not_current detail) ->
           Error
             (Printf.sprintf "Keeper %s has settings this build cannot read: %s" name detail)
         | Ok (Keeper_meta_store.Meta_present meta) ->
           let owns_name = String.equal name meta.name in
           find (answered || (owns_name && answers meta id)) rest
         | Ok Keeper_meta_store.Meta_absent -> find answered rest)
  in
  find false names
;;

(* [all_metas] is every Keeper's settings, read the first time a name needs
   them and then kept for the rest of the write. *)
let declared ~config ~all_names ~all_metas candidate =
  let written = Recipient_resolution.Candidate.to_string candidate in
  match Keeper_identity.Keeper_id.of_string written with
  | None -> Ok None
  | Some id ->
    let name = Keeper_identity.Keeper_id.to_string id in
    (* [name] must be a valid Keeper name before any file name is built from
       it, so a long or odd name never reaches the file system. *)
    (match Keeper_id.Keeper_name.of_string name with
     | Error _ -> Ok None
     | Ok _ ->
       let failed detail =
         Error (Printf.sprintf "cannot resolve @%s: %s" written detail)
       in
       (* A file this build cannot read is not "no such Keeper": taking it for
          one would turn the address into prose without a word to the author. *)
       (match
          reading (fun () -> Keeper_meta_store.read_effective_meta_presence config name)
        with
        | Error detail -> failed detail
        | Ok (Keeper_meta_store.Meta_not_current detail) ->
          failed
            (Printf.sprintf "Keeper %s has settings this build cannot read: %s" name detail)
        | Ok (Keeper_meta_store.Meta_present meta) when answers meta id -> recipient id
        | Ok (Keeper_meta_store.Meta_present _ | Keeper_meta_store.Meta_absent) ->
          (match Lazy.force all_names with
           | Error detail -> failed detail
           | Ok names ->
             (match alternate_own_name_answers ~config ~id ~folded_name:name names with
              | Error detail -> failed detail
              | Ok true -> recipient id
              | Ok false ->
                (match Lazy.force all_metas with
                 | Error detail -> failed detail
                 | Ok metas ->
                   (match
                      Keeper_meta_store.keeper_for_mention_target_in
                        metas
                        ~mention_target:name
                    with
                    | Error detail -> failed detail
                    | Ok None -> Ok None
                    | Ok (Some _) -> recipient id))))))
;;

let make ~base_path =
  Recipient_lookup.make_per_write (fun () ->
    let config = Workspace.default_config base_path in
    let all_names = lazy (reading (fun () -> Keeper_meta_store.persisted_keeper_names_result config)) in
    let all_metas =
      lazy
        (reading (fun () ->
           Keeper_meta_store.persisted_effective_metas
             ~on_undecodable:Keeper_meta_store.Fail_on_undecodable_meta
             config))
    in
    declared ~config ~all_names ~all_metas)
;;
