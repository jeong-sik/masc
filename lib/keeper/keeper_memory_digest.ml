module Types = Keeper_memory_os_types
module Sha256 = Agent_core_sha256

type digest =
  { keeper_id : string
  ; revision : int
  ; digest_sha256 : string
  ; fact_count : int
  ; derived_count : int
  ; rendered : string
  }

let suffix = ".memory-digest.json"
let default_max_rendered_bytes = 8_192

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

let provenance_tag (basis : Types.basis) =
  match basis with
  | Observed Transcript -> ""
  | Observed (Board { post_id; comment_id }) ->
    let pid = Board_types.Post_id.to_string post_id in
    (match comment_id with
     | None -> Printf.sprintf " [board:%s]" pid
     | Some cid ->
       Printf.sprintf " [board:%s/%s]" pid (Board_types.Comment_id.to_string cid))
  | Derived derivations ->
    let premise_count =
      List.fold_left
        (fun acc (d : Types.derivation) -> acc + List.length d.premise_ids)
        0
        derivations
    in
    let rules =
      derivations
      |> List.map (fun (d : Types.derivation) -> d.rule_id)
      |> List.sort_uniq String.compare
      |> String.concat ","
    in
    Printf.sprintf " [derived(%s) from %d premise(s)]" rules premise_count
;;

let basis_rank = function
  | Types.Derived _ -> 0
  | Types.Observed _ -> 1
;;

let canonical_sort_facts (facts : Types.fact list) =
  List.sort
    (fun (a : Types.fact) (b : Types.fact) ->
       let br = Int.compare (basis_rank a.basis) (basis_rank b.basis) in
       if br <> 0
       then br
       else
         let c =
           String.compare (Types.category_to_string a.category) (Types.category_to_string b.category)
         in
         if c <> 0 then c else String.compare (Types.memory_id a) (Types.memory_id b))
    facts
;;

let content_sha256 ~max_bytes ~keeper_id ~revision (sorted_facts : Types.fact list) =
  let ctx = Sha256.init () in
  let ctx = Sha256.feed_string ctx (Printf.sprintf "%s\nrev=%d\nmax=%d\n" keeper_id revision max_bytes) in
  let ctx =
    List.fold_left
      (fun ctx (fact : Types.fact) ->
         let line =
           Printf.sprintf "%s|%s|%s\n"
             (Types.category_to_string fact.category)
             (Types.memory_id fact)
             (Yojson.Safe.to_string (Types.basis_to_json fact.basis))
         in
         Sha256.feed_string ctx line)
      ctx
      sorted_facts
  in
  Sha256.get ctx |> Sha256.to_hex
;;

let render_bounded_lines ~header ~max_bytes (facts : Types.fact list) =
  let footer_reserve = 96 in
  let budget = max (String.length header + footer_reserve) max_bytes in
  let rec loop acc used remaining =
    match remaining with
    | [] -> List.rev acc
    | (fact : Types.fact) :: rest ->
      let line =
        Printf.sprintf "- [%s] %s%s"
          (Types.category_to_string fact.category)
          fact.claim
          (provenance_tag fact.basis)
      in
      let next_used = used + 1 + String.length line in
      let reserve_needed = if rest = [] then 0 else footer_reserve in
      if next_used + reserve_needed <= budget
      then loop (line :: acc) next_used rest
      else
        let omitted = 1 + List.length rest in
        let overflow_line =
          Printf.sprintf
            "- ... (+%d more fact(s) in this epoch; query with keeper_memory_search)"
            omitted
        in
        List.rev (overflow_line :: acc)
  in
  let lines = loop [] (String.length header) facts in
  header ^ "\n" ^ String.concat "\n" lines
;;

let compile_bounded ~max_bytes ~keeper_id ~revision ~facts =
  let sorted = canonical_sort_facts facts in
  let fact_count = List.length sorted in
  let derived_count =
    List.fold_left
      (fun acc (f : Types.fact) ->
         match f.basis with
         | Derived _ -> acc + 1
         | Observed _ -> acc)
      0
      sorted
  in
  let digest_sha256 = content_sha256 ~max_bytes ~keeper_id ~revision sorted in
  let short_hash =
    if String.length digest_sha256 >= 12 then String.sub digest_sha256 0 12 else digest_sha256
  in
  let header =
    Printf.sprintf
      "Current ordinary memory digest (epoch revision=%d; %d stored facts; %d derived; sha256=%s; frozen until next Librarian commit):"
      revision fact_count derived_count short_hash
  in
  let rendered =
    match sorted with
    | [] ->
      header
      ^ "\nNo ordinary facts are current; earlier ordinary Recall facts are historical."
    | facts -> render_bounded_lines ~header ~max_bytes facts
  in
  { keeper_id
  ; revision
  ; digest_sha256
  ; fact_count
  ; derived_count
  ; rendered
  }
;;

let compile ~keeper_id ~revision ~facts =
  compile_bounded ~max_bytes:default_max_rendered_bytes ~keeper_id ~revision ~facts
;;

let to_json (d : digest) =
  `Assoc
    [ "keeper_id", `String d.keeper_id
    ; "revision", `Int d.revision
    ; "digest_sha256", `String d.digest_sha256
    ; "fact_count", `Int d.fact_count
    ; "derived_count", `Int d.derived_count
    ; "rendered", `String d.rendered
    ]
;;

let of_json = function
  | `Assoc fields ->
    (match
       ( List.assoc_opt "keeper_id" fields
       , List.assoc_opt "revision" fields
       , List.assoc_opt "digest_sha256" fields
       , List.assoc_opt "fact_count" fields
       , List.assoc_opt "derived_count" fields
       , List.assoc_opt "rendered" fields )
     with
     | ( Some (`String keeper_id)
       , Some (`Int revision)
       , Some (`String digest_sha256)
       , Some (`Int fact_count)
       , Some (`Int derived_count)
       , Some (`String rendered) ) ->
       Some { keeper_id; revision; digest_sha256; fact_count; derived_count; rendered }
     | _ -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let load_cached_sync path =
  match Fs_compat.load_regular_file_opt path with
  | Ok (Some bytes) ->
    (match Yojson.Safe.from_string bytes with
     | exception Yojson.Json_error _ -> None
     | json -> of_json json)
  | Ok None | Error _ -> None
;;

let save_cached_sync path (d : digest) =
  match Fs_compat.mkdir_p (Filename.dirname path) with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception (_ : exn) -> ()
  | () ->
    let bytes = Yojson.Safe.to_string (to_json d) ^ "\n" in
    ignore (Fs_compat.save_file_atomic_strict path bytes : (unit, string) result)
;;

let load_or_compile ~keepers_dir ~keeper_id ~revision ~facts =
  let max_bytes = default_max_rendered_bytes in
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  let sorted = canonical_sort_facts facts in
  let expected_sha = content_sha256 ~max_bytes ~keeper_id ~revision sorted in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    match load_cached_sync path with
    | Some cached
      when String.equal cached.keeper_id keeper_id
           && Int.equal cached.revision revision
           && String.equal cached.digest_sha256 expected_sha -> cached
    | Some _ | None ->
      let fresh = compile_bounded ~max_bytes ~keeper_id ~revision ~facts in
      save_cached_sync path fresh;
      fresh)
;;

let render_for_snapshot ~keepers_dir ~keeper_id ~revision ~facts =
  (load_or_compile ~keepers_dir ~keeper_id ~revision ~facts).rendered
;;

type cached_meta =
  { present : bool
  ; revision : int option
  ; digest_sha256 : string option
  ; bytes : int
  ; fact_count : int
  ; derived_count : int
  }

let read_cached_meta ~keepers_dir ~keeper_id =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    match load_cached_sync path with
    | None ->
      { present = false
      ; revision = None
      ; digest_sha256 = None
      ; bytes = 0
      ; fact_count = 0
      ; derived_count = 0
      }
    | Some cached ->
      { present = true
      ; revision = Some cached.revision
      ; digest_sha256 = Some cached.digest_sha256
      ; bytes = String.length cached.rendered
      ; fact_count = cached.fact_count
      ; derived_count = cached.derived_count
      })
;;
