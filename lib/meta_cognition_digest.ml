(** Meta_cognition_digest — Board digest management.

    Manages meta-cognition digest posts on the board, including
    signature-based deduplication and latest-digest lookup.

    @since God file decomposition — extracted from meta_cognition.ml *)

open Meta_cognition_types

let digest_hearth = "meta-cognition"
let digest_source = "meta_cognition_digest"

let post_digest_key post =
  match post.Board.meta_json with
  | Some (`Assoc fields) ->
    (match List.assoc_opt "source" fields, List.assoc_opt "digest_key" fields with
     | Some (`String source), Some (`String digest_key)
       when String.equal (String.lowercase_ascii (String.trim source)) digest_source ->
       Some digest_key
     | _ -> None)
  | _ -> None
;;

let latest_digest_post () =
  Board_dispatch.list_posts
    ~hearth:digest_hearth
    ~post_kind_filter:Board.Automation_post
    ~sort_by:Board_dispatch.Recent
    ~limit:20
    ()
  |> List.find_map (fun post ->
    Option.map (fun digest_key -> post, digest_key) (post_digest_key post))
;;

let latest_digest_ref ?summary () =
  match latest_digest_post () with
  | None -> None
  | Some (post, digest_key) ->
    let matches_summary =
      match summary with
      | Some current_summary ->
        String.equal
          digest_key
          (Meta_cognition_interpret.summary_signature current_summary)
      | None -> false
    in
    Some
      { post_id = Board.Post_id.to_string post.id
      ; title = post.title
      ; created_at = Server_utils.iso8601_of_unix post.created_at
      ; updated_at = Some (Server_utils.iso8601_of_unix post.updated_at)
      ; hearth = post.hearth
      ; digest_key
      ; matches_summary
      }
;;

let latest_digest_json ?summary () =
  match latest_digest_ref ?summary () with
  | None -> `Null
  | Some digest ->
    `Assoc
      [ "post_id", `String digest.post_id
      ; "title", `String digest.title
      ; "created_at", `String digest.created_at
      ; ( "updated_at"
        , match digest.updated_at with
          | Some value -> `String value
          | None -> `Null )
      ; ( "hearth"
        , match digest.hearth with
          | Some value -> `String value
          | None -> `Null )
      ; "digest_key", `String digest.digest_key
      ; "matches_summary", `Bool digest.matches_summary
      ; "provenance", `String "board"
      ]
;;
