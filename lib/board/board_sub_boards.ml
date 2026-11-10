(** Sub-board policy and CRUD for one store. See the interface for the
    same-store persistence boundary and retained snapshot-error behavior. *)

open Board_core_persist
open Result.Syntax

let sub_board_to_yojson = Board_sub_board_json.sub_board_to_yojson
let parse_sub_board_members = Board_sub_board_json.parse_sub_board_members
let sub_board_of_yojson = Board_sub_board_json.sub_board_of_yojson

let reload_sub_boards store =
  with_persist_lock store (fun () ->
    let outcome = Board_sub_boards_source.read store in
    let outcome = try
      with_lock store (fun () ->
        (match outcome with
         | Board_sub_boards_source.Complete { rows; _ }
         | Partial { rows; _ } ->
           Hashtbl.clear store.sub_boards;
           Hashtbl.clear store.sub_boards_by_slug;
           List.iter (fun (sb : sub_board) ->
             let id = Sub_board_id.to_string sb.id in
             Hashtbl.replace store.sub_boards id sb;
             Hashtbl.replace store.sub_boards_by_slug sb.slug id) rows
         | Unavailable _ -> ());
        Board_sub_boards_source.publish_read store outcome);
      outcome
    with exception_ ->
      Board_sub_boards_source.fail_read store outcome exception_ (Printexc.get_raw_backtrace ()) in
    match Board_sub_boards_source.finish_read outcome with
    | Ok count -> Ok count
    | Error error -> Error (Board_paths.sub_boards_path store, Failure (show_board_error error)))

type snapshot_change =
  | Replace_sub_board of sub_board
  | Remove_sub_board of Sub_board_id.t

let changed_sub_boards_jsonl_unlocked store change =
  let buf = Buffer.create 1024 in
  Hashtbl.iter
    (fun id (sb : sub_board) ->
       let row = match change with
         | Replace_sub_board updated ->
           Some (if String.equal id (Sub_board_id.to_string updated.id) then updated else sb)
         | Remove_sub_board removed ->
           if String.equal id (Sub_board_id.to_string removed) then None else Some sb
       in
       Option.iter (fun row ->
         Buffer.add_string buf (Yojson.Safe.to_string (sub_board_to_yojson row));
         Buffer.add_char buf '\n') row)
    store.sub_boards;
  Buffer.contents buf
;;

let publish_policy store outcome publish =
  let result = match outcome with
    | Board_sub_boards_source.Written { publication; _ } ->
      let value = try publish () with exception_ ->
        Board_sub_boards_source.fail_publication store publication exception_
          (Printexc.get_raw_backtrace ()) in
      Board_sub_boards_source.acknowledge_publication store publication
      |> Result.map (fun () -> value)
    | Not_written _ | Unknown _ -> Error (Io_error "Board data is unavailable.") in
  let result = Board_sub_boards_source.finish_write outcome result in
  (match result with
   | Ok _ -> ()
   | Error error -> record_persist_error ~where:"sub_board_policy" (show_board_error error));
  result
;;

let valid_slug_pattern = Re.Pcre.re {|^[a-z0-9][a-z0-9_-]*$|} |> Re.compile

let create_sub_board
      store
      ~slug
      ~name
      ~description
      ~owner
      ?(members = [])
      ?(access = Open)
      ()
  : (sub_board, board_error) Result.t
  =
  let slug = String.lowercase_ascii (String.trim slug) in
  if
    String.length slug < 1
    || String.length slug > 64
    || not (Re.execp valid_slug_pattern slug)
  then
    Error
      (Validation_error
         (Printf.sprintf
            "Invalid sub-board slug %S: must be 1-64 lowercase alphanumeric/-/_"
            slug))
  else (
    match Agent_id.of_string owner with
    | Error e -> Error e
    | Ok owner_id ->
      (match parse_sub_board_members ~owner:owner_id members with
       | Error e -> Error e
       | Ok members ->
         with_persist_lock store (fun () ->
           let* () = Board_sub_boards_source.require_readable store in
           let* sb = with_lock store (fun () ->
             if Hashtbl.mem store.sub_boards_by_slug slug then
               Error (Already_exists (Printf.sprintf "Sub-board slug %S already exists" slug))
             else Ok {
               id = Sub_board_id.generate ();
               slug; name = String.trim name; description = String.trim description;
               owner = owner_id; members; access; created_at = Time_compat.now (); post_count = 0 }) in
           let outcome = Board_sub_boards_source.append store sb in
           publish_policy store outcome (fun () ->
             with_lock store (fun () ->
               Hashtbl.replace store.sub_boards (Sub_board_id.to_string sb.id) sb;
               Hashtbl.replace store.sub_boards_by_slug slug (Sub_board_id.to_string sb.id);
               sb)))))
;;


let update_sub_board
      store
      ~sub_board_id
      ?name
      ?description
      ?members
      ?access
      ()
  : (sub_board, board_error) Result.t
  =
  with_persist_lock store (fun () ->
    let* () = Board_sub_boards_source.require_readable store in
    let result =
      with_lock store (fun () ->
        let sb_opt =
          match Hashtbl.find_opt store.sub_boards sub_board_id with
          | Some sb -> Some sb
          | None ->
            (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
             | Some id -> Hashtbl.find_opt store.sub_boards id
             | None -> None)
        in
        match sb_opt with
        | None ->
          Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id))
        | Some sb ->
          let members_result =
            match members with
            | None -> Ok sb.members
            | Some raw -> parse_sub_board_members ~owner:sb.owner raw
          in
          (match members_result with
           | Error _ as error -> error
           | Ok members ->
             let updated =
               { sb with
                 (* DET-OK: omitted text fields preserve existing typed values. *)
                 name = Option.value ~default:sb.name (Option.map String.trim name)
               ; description =
                   Option.value
                     ~default:sb.description
                     (Option.map String.trim description)
               ; members
               (* DET-OK: omitted access keeps the existing typed policy. *)
               ; access = Option.value ~default:sb.access access
               }
             in
             Ok (updated, changed_sub_boards_jsonl_unlocked store
               (Replace_sub_board updated))))
    in
    match result with
    | Error _ as error -> error
    | Ok (updated, content) ->
      let outcome = Board_sub_boards_source.rewrite store content in
      publish_policy store outcome (fun () ->
      with_lock store (fun () ->
        Hashtbl.replace store.sub_boards (Sub_board_id.to_string updated.id) updated;
        updated)))
;;

let get_sub_board store ~sub_board_id : (sub_board, board_error) Result.t =
  with_persist_lock store (fun () ->
  let* () = Board_sub_boards_source.require_readable store in
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sub_boards sub_board_id with
    | Some sb -> Ok (sub_board_with_post_count_unlocked store sb)
    | None ->
      (* fallback: try slug *)
      (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
       | Some id ->
         (match Hashtbl.find_opt store.sub_boards id with
          | Some sb -> Ok (sub_board_with_post_count_unlocked store sb)
          | None ->
            Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id)))
       | None ->
         Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id)))))
;;

let list_sub_boards store : sub_board list =
  with_lock store (fun () ->
    let counts = sub_board_post_counts_unlocked store in
    Hashtbl.fold
      (fun _ sb acc -> sub_board_with_post_count counts sb :: acc)
      store.sub_boards
      []
    |> List.sort (fun (a : sub_board) (b : sub_board) ->
      compare a.created_at b.created_at))
;;

let read_sub_boards store =
  with_persist_lock store (fun () ->
    let* () = Board_sub_boards_source.require_readable store in
    Ok (list_sub_boards store))
;;

let delete_sub_board store ~sub_board_id : (unit, board_error) Result.t =
  with_persist_lock store (fun () ->
    let* () = Board_sub_boards_source.require_readable store in
    let snapshot =
      with_lock store (fun () ->
      let resolved_opt =
        match Hashtbl.find_opt store.sub_boards sub_board_id with
        | Some sb -> Some sb
        | None ->
          (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
           | None -> None
           | Some id ->
             (match Hashtbl.find_opt store.sub_boards id with
              | Some sb -> Some sb
              | None -> None))
      in
      match resolved_opt with
      | None ->
        Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id))
      | Some sb ->
        Ok (sb, changed_sub_boards_jsonl_unlocked store (Remove_sub_board sb.id)))
    in
    match snapshot with
    | Error _ as e -> e
    | Ok (sb, content) ->
      let outcome = Board_sub_boards_source.rewrite store content in
      publish_policy store outcome (fun () ->
      with_lock store (fun () ->
        Hashtbl.remove store.sub_boards (Sub_board_id.to_string sb.id);
        Hashtbl.remove store.sub_boards_by_slug sb.slug;
        (* Orphan policy: clear hearth on posts that belonged to this sub-board *)
        Hashtbl.iter
          (fun _ (post : post) ->
             match post.hearth with
             | Some h when String.equal h sb.slug ->
               let updated = { post with hearth = None } in
               Hashtbl.replace store.posts (Post_id.to_string post.id) updated;
               store.dirty_posts <- true;
               Hashtbl.replace store.dirty_post_ids (Post_id.to_string post.id) ()
             | _ -> ())
          store.posts;
        invalidate_post_caches store;
        ())))
;;
