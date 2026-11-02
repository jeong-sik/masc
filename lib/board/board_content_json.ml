(** Pure current persisted Board post, comment and audience codecs. *)

open Board_core_classify

type diagnostic =
  | Invalid_post_kind of { post_id : string }
  | Invalid_agent_id of { raw : string }

type 'a decoded = {
  value : 'a option;
  diagnostics : diagnostic list;
}

let quiet value = { value; diagnostics = [] }

let agent_id raw =
  match Agent_id.parse raw with
  | Ok id -> quiet (Some id)
  | Error _ -> { value = None; diagnostics = [ Invalid_agent_id { raw } ] }
;;

let compare_agent_id left right =
  String.compare (Agent_id.to_string left) (Agent_id.to_string right)
;;

let audience_to_yojson = function
  | Targets targets ->
    `Assoc [ "kind", `String "targets"
           ; "targets", `List (List.map (fun id -> `String (Agent_id.to_string id)) targets) ]
  | Broadcast -> `Assoc [ "kind", `String "broadcast" ]
  | Thread_participants -> `Assoc [ "kind", `String "thread_participants" ]
  | Discoverable -> `Assoc [ "kind", `String "discoverable" ]
;;

(* RFC-0233 §7: encode the typed origin as its own top-level [origin] key
   (sibling of [meta], NOT nested under it) so the index key needs no
   meta_json substring scan (RFC §7.6 guard #2). Each sub-field is emitted
   only when present; turn_ref serializes via [Ids.Turn_ref.to_yojson] (a flat
   "trace#turn" string), matching the chat-row wire form. *)
let post_origin_to_yojson (o : post_origin) : Yojson.Safe.t =
  `Assoc
    ((match o.turn_ref with
      | Some tr -> [ "turn_ref", Ids.Turn_ref.to_yojson tr ]
      | None -> [])
     @ (match o.source with
        | Some s -> [ "source", `String s ]
        | None -> [])
     @
     (match o.fusion_run_id with
      | Some r -> [ "fusion_run_id", `String r ]
      | None -> [])
     @ (match o.fusion_producer with
        | Some producer -> ["fusion_producer", `String producer]
        | None -> []))
;;

(* Only emitted when the post is closed; the same shape is decoded back by
   [post_close_state_of_yojson]. Absence of the ["closed"] key on read
   means open, which lets every post minted before this field existed
   round-trip unchanged. *)
let post_close_state_to_yojson (c : post_close_state) : Yojson.Safe.t =
  `Assoc
    ([ "closed_by", `String (Agent_id.to_string c.closed_by)
     ; "closed_at", `Float c.closed_at
     ]
     @ (match c.successor_id with
        | Some id -> [ "successor_id", `String (Post_id.to_string id) ]
        | None -> [])
     @ (match c.summary with
        | Some s -> [ "summary", `String s ]
        | None -> []))
;;

let post_to_yojson (p : post) : Yojson.Safe.t =
  `Assoc
    ([ "id", `String (Post_id.to_string p.id)
     ; "author", `String (Agent_id.to_string p.author)
     ; "title", `String p.title
     ; "body", `String p.body
     ; "post_kind", `String (post_kind_to_string p.post_kind)
     ; "visibility", `String (visibility_to_string p.visibility)
     ; "created_at", `Float p.created_at
     ; "content_updated_at", `Float p.content_updated_at
     ; "updated_at", `Float p.updated_at
     ; "expires_at", `Float p.expires_at
     ; "votes_up", `Int p.votes_up
     ; "votes_down", `Int p.votes_down
     ; "reply_count", `Int p.reply_count
     ; "pinned", `Bool p.pinned
     ]
     @ (match p.audience with
        | Some audience -> [ "audience", audience_to_yojson audience ]
        | None -> [])
     @ (match p.hearth with
        | Some h -> [ "hearth", `String h ]
        | None -> [])
     @ (match p.thread_id with
        | Some t -> [ "thread_id", `String t ]
        | None -> [])
     @ (match p.origin with
        | Some o -> [ "origin", post_origin_to_yojson o ]
        | None -> [])
     @ (match p.closed with
        | Some c -> [ "closed", post_close_state_to_yojson c ]
        | None -> [])
     @ (match post_classification_reason p with
        | Some reason -> [ "classification_reason", `String reason ]
        | None -> [])
     @
     match p.meta_json with
     | Some meta -> [ "meta", meta ]
     | None -> [])
;;

let comment_to_yojson (c : comment) : Yojson.Safe.t =
  `Assoc
    ([ "id", `String (Comment_id.to_string c.id)
     ; "post_id", `String (Post_id.to_string c.post_id)
     ; ( "parent_id"
       , Json_util.string_opt_to_json (Option.map Comment_id.to_string c.parent_id) )
     ; "author", `String (Agent_id.to_string c.author)
     ; "content", `String c.content
     ; "created_at", `Float c.created_at
     ; "expires_at", `Float c.expires_at
     ; "votes_up", `Int c.votes_up
     ; "votes_down", `Int c.votes_down
     ]
     @
     match c.audience with
     | Some audience -> [ "audience", audience_to_yojson audience ]
     | None -> [])
;;

let audience_of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (a, _) (b, _) -> String.compare a b) fields with
     | [ "kind", `String "targets"; "targets", `List (_ :: _ as values) ] ->
       let rec parse acc = function
         | [] -> quiet (Some (Targets (List.sort_uniq compare_agent_id acc)))
         | `String raw :: rest ->
           let parsed = agent_id raw in
           (match parsed.value with
            | Some id -> parse (id :: acc) rest
            | None -> { value = None; diagnostics = parsed.diagnostics })
         | _ -> quiet None
       in
       parse [] values
     | [ "kind", `String "broadcast" ] -> quiet (Some Broadcast)
     | [ "kind", `String "thread_participants" ] -> quiet (Some Thread_participants)
     | [ "kind", `String "discoverable" ] -> quiet (Some Discoverable)
     | _ -> quiet None)
  | _ -> quiet None
;;

let has_exact_field_set ~allowed fields =
  let rec loop seen = function
    | [] -> true
    | (name, _) :: rest ->
      if List.mem name seen || not (List.mem name allowed)
      then false
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let post_field_names =
  [ "id"
  ; "author"
  ; "title"
  ; "body"
  ; "post_kind"
  ; "visibility"
  ; "audience"
  ; "created_at"
  ; "content_updated_at"
  ; "updated_at"
  ; "expires_at"
  ; "votes_up"
  ; "votes_down"
  ; "reply_count"
  ; "pinned"
  ; "hearth"
  ; "thread_id"
  ; "origin"
  ; "closed"
  ; "classification_reason"
  ; "meta"
  ]
;;

let comment_field_names =
  [ "id"
  ; "post_id"
  ; "parent_id"
  ; "author"
  ; "content"
  ; "audience"
  ; "created_at"
  ; "expires_at"
  ; "votes_up"
  ; "votes_down"
  ]
;;

let required_string fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | None | Some _ -> None
;;

let required_float fields key =
  match List.assoc_opt key fields with
  | Some (`Float value) -> Some value
  | None | Some _ -> None
;;

let required_expiry fields =
  match required_float fields "expires_at" with
  | Some value when Float.is_finite value && Float.compare value 0.0 >= 0 -> Some value
  | Some _ | None -> None
;;

let required_int fields key =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Some value
  | None | Some _ -> None
;;

let required_bool fields key =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> Some value
  | None | Some _ -> None
;;

let optional_string fields key =
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error ()
;;

let optional_meta fields =
  match List.assoc_opt "meta" fields with
  | None -> Ok None
  | Some (`Assoc _ as meta) -> Ok (Some meta)
  | Some _ -> Error ()
;;

(* RFC-0233 §7: an emitted origin is a current typed value, not a repairable
   hint. Absent [origin] remains valid; a present malformed object rejects its
   row at the caller. *)
let post_origin_of_yojson (json : Yojson.Safe.t) : post_origin decoded =
  match json with
  | `Assoc fields when has_exact_field_set
      ~allowed:["turn_ref";"source";"fusion_run_id";"fusion_producer"] fields ->
    let turn_ref =
      match List.assoc_opt "turn_ref" fields with
      | None -> Ok None
      | Some (`String raw) ->
        (match Ids.Turn_ref.of_string raw with
         | Some turn_ref -> Ok (Some turn_ref)
         | None -> Error ())
      | Some _ -> Error ()
    in
    let source = optional_string fields "source" in
    let fusion_run_id = optional_string fields "fusion_run_id" in
    let fusion_producer = optional_string fields "fusion_producer" in
    (match turn_ref, source, fusion_run_id, fusion_producer with
     | Ok turn_ref, Ok source, Ok fusion_run_id, Ok fusion_producer ->
       if Option.is_none turn_ref
          && Option.is_none source
          && Option.is_none fusion_run_id
       then quiet None
       else (match fusion_run_id, fusion_producer with
         | None, None -> quiet (Some {turn_ref; source; fusion_run_id; fusion_producer})
         | Some _, Some producer ->
           let parsed = agent_id producer in
           { value = Option.map (fun producer_id ->
               { turn_ref; source; fusion_run_id
               ; fusion_producer = Some (Agent_id.to_string producer_id) }) parsed.value
           ; diagnostics = parsed.diagnostics
           }
         | _ -> quiet None)
     | Error (), _, _, _ | _, Error (), _, _ | _, _, Error (), _ | _, _, _, Error () -> quiet None)
  | _ -> quiet None
;;

let optional_origin fields =
  match List.assoc_opt "origin" fields with
  | None -> Ok None, []
  | Some json ->
    let decoded = post_origin_of_yojson json in
    let value = match decoded.value with
      | Some origin -> Ok (Some origin)
      | None -> Error () in
    value, decoded.diagnostics
;;

(* A malformed present close state rejects its row; absence alone means open. *)
let post_close_state_of_yojson (json : Yojson.Safe.t) : post_close_state decoded =
  match json with
  | `Assoc fields
    when has_exact_field_set
           ~allowed:[ "closed_by"; "closed_at"; "successor_id"; "summary" ]
           fields ->
    let successor_id =
      match List.assoc_opt "successor_id" fields with
      | None -> Ok None
      | Some (`String raw) ->
        (match Post_id.of_string raw with
         | Ok id -> Ok (Some id)
         | Error _ -> Error ())
      | Some _ -> Error ()
    in
    let summary = optional_string fields "summary" in
    (match
       ( required_string fields "closed_by"
       , required_float fields "closed_at"
       , successor_id
       , summary )
     with
     | Some closed_by_str, Some closed_at, Ok successor_id, Ok summary
       when Float.is_finite closed_at ->
       let parsed = agent_id closed_by_str in
       { value = Option.map
           (fun closed_by -> { closed_by; closed_at; successor_id; summary })
           parsed.value
       ; diagnostics = parsed.diagnostics
       }
     | (Some _ | None), (Some _ | None), (Ok _ | Error _), (Ok _ | Error _) ->
       quiet None)
  | _ -> quiet None
;;

let optional_closed fields =
  match List.assoc_opt "closed" fields with
  | None -> Ok None, []
  | Some json ->
    let decoded = post_close_state_of_yojson json in
    let value = match decoded.value with
      | Some closed -> Ok (Some closed)
      | None -> Error () in
    value, decoded.diagnostics
;;

let optional_audience fields =
  match List.assoc_opt "audience" fields with
  | None -> Ok None, []
  | Some json ->
    let decoded = audience_of_yojson json in
    let value = match decoded.value with
      | Some audience -> Ok (Some audience)
      | None -> Error () in
    value, decoded.diagnostics
;;

let post_of_yojson (json : Yojson.Safe.t) : post decoded =
  match json with
  | `Assoc fields
    when has_exact_field_set ~allowed:post_field_names fields ->
    let audience, audience_diagnostics = optional_audience fields in
    let closed, closed_diagnostics = optional_closed fields in
    let origin, origin_diagnostics = optional_origin fields in
    let nested_diagnostics = audience_diagnostics @ closed_diagnostics @ origin_diagnostics in
    (match
       ( required_string fields "id"
       , required_string fields "author"
       , required_string fields "title"
       , required_string fields "body"
       , required_string fields "post_kind"
       , required_string fields "visibility"
       , required_float fields "created_at"
       , required_float fields "content_updated_at"
       , required_float fields "updated_at"
       , required_expiry fields
       , required_int fields "votes_up"
       , required_int fields "votes_down"
       , required_int fields "reply_count"
       , required_bool fields "pinned"
       , optional_string fields "hearth"
       , optional_string fields "thread_id"
       , optional_string fields "classification_reason"
       , optional_meta fields
       , origin
       , closed
       , audience )
     with
     | ( Some id_str
       , Some author_str
       , Some title
       , Some body
       , Some post_kind_raw
       , Some vis_str
       , Some created_at
       , Some content_updated_at
       , Some updated_at
       , Some expires_at
       , Some votes_up
       , Some votes_down
       , Some reply_count
       , Some pinned
       , Ok hearth
       , Ok thread_id
       , Ok classification_reason
       , Ok meta_json
       , Ok origin
       , Ok closed
       , Ok audience ) when Float.is_finite content_updated_at ->
    let post_kind_opt =
      post_kind_of_string post_kind_raw
    in
    let kind_diagnostics =
      if Option.is_none post_kind_opt then [ Invalid_post_kind { post_id = id_str } ]
      else []
    in
    let author = agent_id author_str in
    let value = match
       ( Post_id.of_string id_str
       , author.value
       , visibility_of_string vis_str
       , post_kind_opt )
     with
     | Ok id, Some author, Some visibility, Some post_kind ->
        let post =
          { id
          ; author
          ; title
          ; body
          ; post_kind
          ; meta_json
          ; visibility
          ; audience
          ; created_at
          ; content_updated_at
          ; updated_at
          ; expires_at
          ; votes_up
          ; votes_down
          ; reply_count
          ; pinned
          ; hearth
          ; thread_id
          ; origin
          ; closed
          }
        in
        if Option.equal
             String.equal
             classification_reason
             (post_classification_reason post)
        then Some post
        else None
     | (Ok _ | Error _), (Some _ | None), (Some _ | None), (Some _ | None) -> None
    in
    { value
    ; diagnostics = nested_diagnostics @ kind_diagnostics @ author.diagnostics
    }
     | ( (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _) ) -> { value = None; diagnostics = nested_diagnostics })
  | `Assoc _ | _ -> quiet None
;;

let comment_of_yojson (json : Yojson.Safe.t) : comment decoded =
  match json with
  | `Assoc fields
    when has_exact_field_set ~allowed:comment_field_names fields ->
    let audience, audience_diagnostics = optional_audience fields in
    let parent_id =
      match List.assoc_opt "parent_id" fields with
      | Some `Null -> Ok None
      | Some (`String raw) ->
        (match Comment_id.of_string raw with
         | Ok parent_id -> Ok (Some parent_id)
         | Error _ -> Error ())
      | None | Some _ -> Error ()
    in
    (match
       ( required_string fields "id"
       , required_string fields "post_id"
       , required_string fields "author"
       , required_string fields "content"
       , required_float fields "created_at"
       , required_expiry fields
       , required_int fields "votes_up"
       , required_int fields "votes_down"
       , parent_id
       , audience )
     with
     | ( Some id_str
       , Some post_id_str
       , Some author_str
       , Some content
       , Some created_at
       , Some expires_at
       , Some votes_up
       , Some votes_down
       , Ok parent_id
       , Ok audience ) ->
       let author = agent_id author_str in
       let value = match
          ( Comment_id.of_string id_str
          , Post_id.of_string post_id_str
          , author.value )
        with
        | Ok id, Ok post_id, Some author ->
          Some
            { id
            ; post_id
            ; parent_id
            ; author
            ; content
            ; audience
            ; created_at
            ; expires_at
            ; votes_up
            ; votes_down
            }
          | (Ok _ | Error _), (Ok _ | Error _), (Some _ | None) -> None
       in
       { value; diagnostics = audience_diagnostics @ author.diagnostics }
     | ( (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Some _ | None)
       , (Ok _ | Error _)
       , (Ok _ | Error _) ) -> { value = None; diagnostics = audience_diagnostics })
  | _ -> quiet None
;;
