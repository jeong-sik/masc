(* Which names a Keeper answers to is decided where the Board routes a post to a
   Keeper ([Keeper_lane_mentions.effective_target_ids]): its [mention_targets]
   when it has any, else its own name.  The lookup asks the same function, so a
   name it declares is a name the router delivers on.  The broadcast path asks
   [answers] before it takes a Keeper's own name, so it reaches a Keeper the
   router delivers that name to. *)
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

(* The settings are read from disk. Creating a missing directory can raise
   [Sys_error] with Eio or [Unix.Unix_error] in the Unix fallback. Both are
   failed lookups; cancellation and other exceptions still propagate. *)
let reading read =
  match read () with
  | result -> result
  | exception Sys_error detail -> Error detail
  | exception Unix.Unix_error (error, operation, _) ->
    Error (Printf.sprintf "%s: %s" operation (Unix.error_message error))
;;

(* [all_metas] is every Keeper's settings, read the first time a name needs
   them and then kept for the rest of the write. *)
let declared ~config ~all_names ~all_metas candidate =
  let written = Recipient_resolution.Candidate.to_string candidate in
  match Keeper_identity.Keeper_id.of_string written with
  | None -> Ok None
  | Some id ->
    let name = Keeper_identity.Keeper_id.to_string id in
    let failed detail =
      Error (Printf.sprintf "cannot resolve @%s: %s" written detail)
    in
    let find_alias () =
      match Lazy.force all_metas with
      | Error detail -> failed detail
      | Ok metas ->
        (match Keeper_meta_store.keeper_for_mention_target_in metas ~mention_target:name with
         | Error detail -> failed detail
         | Ok None -> Ok None
         | Ok (Some _) -> recipient id)
    in
    (* Only an own-name lookup uses [name] as a path. An alias need not obey
       Keeper filename restrictions, so still scan aliases if this is invalid. *)
    (match Keeper_id.Keeper_name.of_string name with
     | Error _ -> find_alias ()
     | Ok _ ->
       (* A case-insensitive filesystem may open [Alice.json] for [alice].
          Check the actual directory spelling as well as the payload before
          granting the own-name shortcut. The names listing does not read any
          unrelated Keeper's settings. *)
       let find ~direct =
         match Lazy.force all_names with
         | Error detail -> failed detail
         | Ok names ->
           let canonical_owner_answers =
             match direct with
             | Some meta ->
               String.equal name meta.Keeper_meta_contract.name
               && List.exists (String.equal name) names
               && answers meta id
             | None -> false
           in
           (* A Keeper name is lowercase ([Keeper_id.Keeper_name]), so the
              folded name is the only spelling a Keeper's own file can have. *)
           if canonical_owner_answers then recipient id else find_alias ()
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
        | Ok (Keeper_meta_store.Meta_present meta) -> find ~direct:(Some meta)
        | Ok Keeper_meta_store.Meta_absent -> find ~direct:None))
;;

let make ~config =
  Recipient_lookup.make_per_write (fun () ->
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
