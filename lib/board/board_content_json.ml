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

(* Encode the typed origin as its own top-level [origin] key
   (sibling of [meta], NOT nested under it) so the index key needs no
   meta_json substring scan. Each sub-field is emitted
   only when present; turn_ref serializes via [Ids.Turn_ref.to_yojson] (a flat
   "trace#turn" string), matching the chat-row wire form. *)
let post_origin_to_yojson (o : post_origin) : Yojson.Safe.t =
  let fields =
    match o.fusion_producer with
    | Some producer -> [ "fusion_producer", `String producer ]
    | None -> []
  in
  let fields =
    match o.fusion_run_id with
    | Some r -> ("fusion_run_id", `String r) :: fields
    | None -> fields
  in
  let fields =
    match o.source with
    | Some s -> ("source", `String s) :: fields
    | None -> fields
  in
  let fields =
    match o.turn_ref with
    | Some tr -> ("turn_ref", Ids.Turn_ref.to_yojson tr) :: fields
    | None -> fields
  in
  `Assoc fields
;;

(* Only emitted when the post is closed; the same shape is decoded back by
   [post_close_state_of_yojson]. Absence of the ["closed"] key on read
   means open, which lets every post minted before this field existed
   round-trip unchanged. *)
let post_close_state_to_yojson (c : post_close_state) : Yojson.Safe.t =
  let tail =
    match c.summary with
    | Some s -> [ "summary", `String s ]
    | None -> []
  in
  let tail =
    match c.successor_id with
    | Some id -> ("successor_id", `String (Post_id.to_string id)) :: tail
    | None -> tail
  in
  `Assoc
    (("closed_by", `String (Agent_id.to_string c.closed_by))
     :: ("closed_at", `Float c.closed_at)
     :: tail)
;;

let post_to_yojson (p : post) : Yojson.Safe.t =
  let tail =
    match p.meta_json with
    | Some meta -> [ "meta", meta ]
    | None -> []
  in
  let tail =
    match p.attachment_ids with
    | [] -> tail
    | ids -> ("attachment_ids", `List (List.map (fun id -> `String id) ids)) :: tail
  in
  let tail =
    match post_classification_reason p with
    | Some reason -> ("classification_reason", `String reason) :: tail
    | None -> tail
  in
  let tail =
    match p.closed with
    | Some c -> ("closed", post_close_state_to_yojson c) :: tail
    | None -> tail
  in
  let tail =
    match p.origin with
    | Some o -> ("origin", post_origin_to_yojson o) :: tail
    | None -> tail
  in
  let tail =
    match p.thread_id with
    | Some t -> ("thread_id", `String t) :: tail
    | None -> tail
  in
  let tail =
    match p.hearth with
    | Some h -> ("hearth", `String h) :: tail
    | None -> tail
  in
  let tail =
    match p.audience with
    | Some audience -> ("audience", audience_to_yojson audience) :: tail
    | None -> tail
  in
  `Assoc
    (("id", `String (Post_id.to_string p.id))
     :: ("author", `String (Agent_id.to_string p.author))
     :: ("title", `String p.title)
     :: ("body", `String p.body)
     :: ("post_kind", `String (post_kind_to_string p.post_kind))
     :: ("visibility", `String (visibility_to_string p.visibility))
     :: ("created_at", `Float p.created_at)
     :: ("content_updated_at", `Float p.content_updated_at)
     :: ("updated_at", `Float p.updated_at)
     :: ("expires_at", `Float p.expires_at)
     :: ("votes_up", `Int p.votes_up)
     :: ("votes_down", `Int p.votes_down)
     :: ("reply_count", `Int p.reply_count)
     :: ("pinned", `Bool p.pinned)
     :: tail)
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
     @ (match c.attachment_ids with
        | [] -> []
        | ids -> [ "attachment_ids", `List (List.map (fun id -> `String id) ids) ])
     @
     match c.audience with
     | Some audience -> [ "audience", audience_to_yojson audience ]
     | None -> [])
;;

let audience_of_yojson = function
  | `Assoc [ "kind", `String "broadcast" ] -> quiet (Some Broadcast)
  | `Assoc [ "kind", `String "thread_participants" ] -> quiet (Some Thread_participants)
  | `Assoc [ "kind", `String "discoverable" ] -> quiet (Some Discoverable)
  | `Assoc
      ( [ "kind", `String "targets"; "targets", `List (_ :: _ as values) ]
      | [ "targets", `List (_ :: _ as values); "kind", `String "targets" ] ) ->
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
  | _ -> quiet None
;;

let required_string = function
  | Some (`String value) -> Some value
  | None | Some _ -> None
;;

let required_float = function
  | Some (`Float value) -> Some value
  | None | Some _ -> None
;;

let required_expiry slot =
  match required_float slot with
  | Some value when Float.is_finite value && Float.compare value 0.0 >= 0 -> Some value
  | Some _ | None -> None
;;

let required_int = function
  | Some (`Int value) -> Some value
  | None | Some _ -> None
;;

let required_bool = function
  | Some (`Bool value) -> Some value
  | None | Some _ -> None
;;

let optional_string = function
  | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error ()
;;

let optional_meta = function
  | None -> Ok None
  | Some (`Assoc _ as meta) -> Ok (Some meta)
  | Some _ -> Error ()
;;

let optional_attachment_ids = function
  | None -> Ok []
  | Some (`List items) ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String raw :: rest ->
        let trimmed = String.trim raw in
        if String.equal trimmed "" then Error ()
        else loop (trimmed :: acc) rest
      | _ :: _ -> Error ()
    in
    loop [] items
  | Some _ -> Error ()
;;

type raw_origin_fields =
  { mutable o_turn_ref : Yojson.Safe.t option
  ; mutable o_source : Yojson.Safe.t option
  ; mutable o_fusion_run_id : Yojson.Safe.t option
  ; mutable o_fusion_producer : Yojson.Safe.t option
  }

let extract_origin_fields fields =
  let s =
    { o_turn_ref = None
    ; o_source = None
    ; o_fusion_run_id = None
    ; o_fusion_producer = None
    }
  in
  let rec fill = function
    | [] -> Some s
    | (name, value) :: rest ->
      (match name with
       | "turn_ref" ->
         (match s.o_turn_ref with
          | Some _ -> None
          | None ->
            s.o_turn_ref <- Some value;
            fill rest)
       | "source" ->
         (match s.o_source with
          | Some _ -> None
          | None ->
            s.o_source <- Some value;
            fill rest)
       | "fusion_run_id" ->
         (match s.o_fusion_run_id with
          | Some _ -> None
          | None ->
            s.o_fusion_run_id <- Some value;
            fill rest)
       | "fusion_producer" ->
         (match s.o_fusion_producer with
          | Some _ -> None
          | None ->
            s.o_fusion_producer <- Some value;
            fill rest)
       | _ -> None)
  in
  fill fields
;;

(* An emitted origin is a current typed value, not a repairable
   hint. Absent [origin] remains valid; a present malformed object rejects its
   row at the caller. *)
let post_origin_of_yojson (json : Yojson.Safe.t) : post_origin decoded =
  match json with
  | `Assoc fields ->
    (match extract_origin_fields fields with
     | None -> quiet None
     | Some s ->
       let turn_ref =
         match s.o_turn_ref with
         | None -> Ok None
         | Some (`String raw) ->
           (match Ids.Turn_ref.of_string raw with
            | Some turn_ref -> Ok (Some turn_ref)
            | None -> Error ())
         | Some _ -> Error ()
       in
       let source = optional_string s.o_source in
       let fusion_run_id = optional_string s.o_fusion_run_id in
       let fusion_producer = optional_string s.o_fusion_producer in
       (match turn_ref, source, fusion_run_id, fusion_producer with
        | Ok turn_ref, Ok source, Ok fusion_run_id, Ok fusion_producer ->
          if Option.is_none turn_ref
             && Option.is_none source
             && Option.is_none fusion_run_id
          then quiet None
          else (match fusion_run_id, fusion_producer with
            | None, None -> quiet (Some { turn_ref; source; fusion_run_id; fusion_producer })
            | Some _, Some producer ->
              let parsed = agent_id producer in
              { value = Option.map (fun producer_id ->
                  { turn_ref; source; fusion_run_id
                  ; fusion_producer = Some (Agent_id.to_string producer_id) }) parsed.value
              ; diagnostics = parsed.diagnostics
              }
            | Some _, None | None, Some _ -> quiet None)
        | Error (), _, _, _ | _, Error (), _, _ | _, _, Error (), _ | _, _, _, Error () ->
          quiet None))
  | _ -> quiet None
;;

let optional_origin = function
  | None -> Ok None, []
  | Some json ->
    let decoded = post_origin_of_yojson json in
    let value = match decoded.value with
      | Some origin -> Ok (Some origin)
      | None -> Error () in
    value, decoded.diagnostics
;;

type raw_close_fields =
  { mutable cl_closed_by : Yojson.Safe.t option
  ; mutable cl_closed_at : Yojson.Safe.t option
  ; mutable cl_successor_id : Yojson.Safe.t option
  ; mutable cl_summary : Yojson.Safe.t option
  }

let extract_close_fields fields =
  let s =
    { cl_closed_by = None
    ; cl_closed_at = None
    ; cl_successor_id = None
    ; cl_summary = None
    }
  in
  let rec fill = function
    | [] -> Some s
    | (name, value) :: rest ->
      (match name with
       | "closed_by" ->
         (match s.cl_closed_by with
          | Some _ -> None
          | None ->
            s.cl_closed_by <- Some value;
            fill rest)
       | "closed_at" ->
         (match s.cl_closed_at with
          | Some _ -> None
          | None ->
            s.cl_closed_at <- Some value;
            fill rest)
       | "successor_id" ->
         (match s.cl_successor_id with
          | Some _ -> None
          | None ->
            s.cl_successor_id <- Some value;
            fill rest)
       | "summary" ->
         (match s.cl_summary with
          | Some _ -> None
          | None ->
            s.cl_summary <- Some value;
            fill rest)
       | _ -> None)
  in
  fill fields
;;

(* A malformed present close state rejects its row; absence alone means open. *)
let post_close_state_of_yojson (json : Yojson.Safe.t) : post_close_state decoded =
  match json with
  | `Assoc fields ->
    (match extract_close_fields fields with
     | None -> quiet None
     | Some s ->
       let successor_id =
         match s.cl_successor_id with
         | None -> Ok None
         | Some (`String raw) ->
           (match Post_id.of_string raw with
            | Ok id -> Ok (Some id)
            | Error _ -> Error ())
         | Some _ -> Error ()
       in
       let summary = optional_string s.cl_summary in
       (match
          ( required_string s.cl_closed_by
          , required_float s.cl_closed_at
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
          quiet None))
  | _ -> quiet None
;;

let optional_closed = function
  | None -> Ok None, []
  | Some json ->
    let decoded = post_close_state_of_yojson json in
    let value = match decoded.value with
      | Some closed -> Ok (Some closed)
      | None -> Error () in
    value, decoded.diagnostics
;;

let optional_audience = function
  | None -> Ok None, []
  | Some json ->
    let decoded = audience_of_yojson json in
    let value = match decoded.value with
      | Some audience -> Ok (Some audience)
      | None -> Error () in
    value, decoded.diagnostics
;;

type raw_post_fields =
  { mutable p_id : Yojson.Safe.t option
  ; mutable p_author : Yojson.Safe.t option
  ; mutable p_title : Yojson.Safe.t option
  ; mutable p_body : Yojson.Safe.t option
  ; mutable p_post_kind : Yojson.Safe.t option
  ; mutable p_visibility : Yojson.Safe.t option
  ; mutable p_audience : Yojson.Safe.t option
  ; mutable p_created_at : Yojson.Safe.t option
  ; mutable p_content_updated_at : Yojson.Safe.t option
  ; mutable p_updated_at : Yojson.Safe.t option
  ; mutable p_expires_at : Yojson.Safe.t option
  ; mutable p_votes_up : Yojson.Safe.t option
  ; mutable p_votes_down : Yojson.Safe.t option
  ; mutable p_reply_count : Yojson.Safe.t option
  ; mutable p_pinned : Yojson.Safe.t option
  ; mutable p_hearth : Yojson.Safe.t option
  ; mutable p_thread_id : Yojson.Safe.t option
  ; mutable p_origin : Yojson.Safe.t option
  ; mutable p_closed : Yojson.Safe.t option
  ; mutable p_classification_reason : Yojson.Safe.t option
  ; mutable p_meta : Yojson.Safe.t option
  ; mutable p_attachment_ids : Yojson.Safe.t option
  }

let extract_post_fields fields =
  let s =
    { p_id = None
    ; p_author = None
    ; p_title = None
    ; p_body = None
    ; p_post_kind = None
    ; p_visibility = None
    ; p_audience = None
    ; p_created_at = None
    ; p_content_updated_at = None
    ; p_updated_at = None
    ; p_expires_at = None
    ; p_votes_up = None
    ; p_votes_down = None
    ; p_reply_count = None
    ; p_pinned = None
    ; p_hearth = None
    ; p_thread_id = None
    ; p_origin = None
    ; p_closed = None
    ; p_classification_reason = None
    ; p_meta = None
    ; p_attachment_ids = None
    }
  in
  let rec fill = function
    | [] -> Some s
    | (name, value) :: rest ->
      (match name with
       | "id" ->
         (match s.p_id with
          | Some _ -> None
          | None ->
            s.p_id <- Some value;
            fill rest)
       | "author" ->
         (match s.p_author with
          | Some _ -> None
          | None ->
            s.p_author <- Some value;
            fill rest)
       | "title" ->
         (match s.p_title with
          | Some _ -> None
          | None ->
            s.p_title <- Some value;
            fill rest)
       | "body" ->
         (match s.p_body with
          | Some _ -> None
          | None ->
            s.p_body <- Some value;
            fill rest)
       | "post_kind" ->
         (match s.p_post_kind with
          | Some _ -> None
          | None ->
            s.p_post_kind <- Some value;
            fill rest)
       | "visibility" ->
         (match s.p_visibility with
          | Some _ -> None
          | None ->
            s.p_visibility <- Some value;
            fill rest)
       | "audience" ->
         (match s.p_audience with
          | Some _ -> None
          | None ->
            s.p_audience <- Some value;
            fill rest)
       | "created_at" ->
         (match s.p_created_at with
          | Some _ -> None
          | None ->
            s.p_created_at <- Some value;
            fill rest)
       | "content_updated_at" ->
         (match s.p_content_updated_at with
          | Some _ -> None
          | None ->
            s.p_content_updated_at <- Some value;
            fill rest)
       | "updated_at" ->
         (match s.p_updated_at with
          | Some _ -> None
          | None ->
            s.p_updated_at <- Some value;
            fill rest)
       | "expires_at" ->
         (match s.p_expires_at with
          | Some _ -> None
          | None ->
            s.p_expires_at <- Some value;
            fill rest)
       | "votes_up" ->
         (match s.p_votes_up with
          | Some _ -> None
          | None ->
            s.p_votes_up <- Some value;
            fill rest)
       | "votes_down" ->
         (match s.p_votes_down with
          | Some _ -> None
          | None ->
            s.p_votes_down <- Some value;
            fill rest)
       | "reply_count" ->
         (match s.p_reply_count with
          | Some _ -> None
          | None ->
            s.p_reply_count <- Some value;
            fill rest)
       | "pinned" ->
         (match s.p_pinned with
          | Some _ -> None
          | None ->
            s.p_pinned <- Some value;
            fill rest)
       | "hearth" ->
         (match s.p_hearth with
          | Some _ -> None
          | None ->
            s.p_hearth <- Some value;
            fill rest)
       | "thread_id" ->
         (match s.p_thread_id with
          | Some _ -> None
          | None ->
            s.p_thread_id <- Some value;
            fill rest)
       | "origin" ->
         (match s.p_origin with
          | Some _ -> None
          | None ->
            s.p_origin <- Some value;
            fill rest)
       | "closed" ->
         (match s.p_closed with
          | Some _ -> None
          | None ->
            s.p_closed <- Some value;
            fill rest)
       | "classification_reason" ->
         (match s.p_classification_reason with
          | Some _ -> None
          | None ->
            s.p_classification_reason <- Some value;
            fill rest)
       | "meta" ->
         (match s.p_meta with
          | Some _ -> None
          | None ->
            s.p_meta <- Some value;
            fill rest)
       | "attachment_ids" ->
         (match s.p_attachment_ids with
          | Some _ -> None
          | None ->
            s.p_attachment_ids <- Some value;
            fill rest)
       | _ -> None)
  in
  fill fields
;;

let post_of_yojson (json : Yojson.Safe.t) : post decoded =
  match json with
  | `Assoc fields ->
    (match extract_post_fields fields with
     | None -> quiet None
     | Some s ->
       let audience, audience_diagnostics = optional_audience s.p_audience in
       let closed, closed_diagnostics = optional_closed s.p_closed in
       let origin, origin_diagnostics = optional_origin s.p_origin in
       let nested_diagnostics =
         audience_diagnostics @ closed_diagnostics @ origin_diagnostics
       in
       (match
          ( required_string s.p_id
          , required_string s.p_author
          , required_string s.p_title
          , required_string s.p_body
          , required_string s.p_post_kind
          , required_string s.p_visibility
          , required_float s.p_created_at
          , required_float s.p_content_updated_at
          , required_float s.p_updated_at
          , required_expiry s.p_expires_at
          , required_int s.p_votes_up
          , required_int s.p_votes_down
          , required_int s.p_reply_count
          , required_bool s.p_pinned
          , optional_string s.p_hearth
          , optional_string s.p_thread_id
          , optional_string s.p_classification_reason
          , optional_meta s.p_meta
          , origin
          , closed
          , audience
          , optional_attachment_ids s.p_attachment_ids )
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
          , Ok audience
          , Ok attachment_ids ) when Float.is_finite content_updated_at ->
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
                ; attachment_ids
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
          , (Ok _ | Error _)
          , (Ok _ | Error _) ) -> { value = None; diagnostics = nested_diagnostics }))
  | _ -> quiet None
;;

type raw_comment_fields =
  { mutable cm_id : Yojson.Safe.t option
  ; mutable cm_post_id : Yojson.Safe.t option
  ; mutable cm_parent_id : Yojson.Safe.t option
  ; mutable cm_author : Yojson.Safe.t option
  ; mutable cm_content : Yojson.Safe.t option
  ; mutable cm_audience : Yojson.Safe.t option
  ; mutable cm_created_at : Yojson.Safe.t option
  ; mutable cm_expires_at : Yojson.Safe.t option
  ; mutable cm_votes_up : Yojson.Safe.t option
  ; mutable cm_votes_down : Yojson.Safe.t option
  ; mutable cm_attachment_ids : Yojson.Safe.t option
  }

let extract_comment_fields fields =
  let s =
    { cm_id = None
    ; cm_post_id = None
    ; cm_parent_id = None
    ; cm_author = None
    ; cm_content = None
    ; cm_audience = None
    ; cm_created_at = None
    ; cm_expires_at = None
    ; cm_votes_up = None
    ; cm_votes_down = None
    ; cm_attachment_ids = None
    }
  in
  let rec fill = function
    | [] -> Some s
    | (name, value) :: rest ->
      (match name with
       | "id" ->
         (match s.cm_id with
          | Some _ -> None
          | None ->
            s.cm_id <- Some value;
            fill rest)
       | "post_id" ->
         (match s.cm_post_id with
          | Some _ -> None
          | None ->
            s.cm_post_id <- Some value;
            fill rest)
       | "parent_id" ->
         (match s.cm_parent_id with
          | Some _ -> None
          | None ->
            s.cm_parent_id <- Some value;
            fill rest)
       | "author" ->
         (match s.cm_author with
          | Some _ -> None
          | None ->
            s.cm_author <- Some value;
            fill rest)
       | "content" ->
         (match s.cm_content with
          | Some _ -> None
          | None ->
            s.cm_content <- Some value;
            fill rest)
       | "audience" ->
         (match s.cm_audience with
          | Some _ -> None
          | None ->
            s.cm_audience <- Some value;
            fill rest)
       | "created_at" ->
         (match s.cm_created_at with
          | Some _ -> None
          | None ->
            s.cm_created_at <- Some value;
            fill rest)
       | "expires_at" ->
         (match s.cm_expires_at with
          | Some _ -> None
          | None ->
            s.cm_expires_at <- Some value;
            fill rest)
       | "votes_up" ->
         (match s.cm_votes_up with
          | Some _ -> None
          | None ->
            s.cm_votes_up <- Some value;
            fill rest)
       | "votes_down" ->
         (match s.cm_votes_down with
          | Some _ -> None
          | None ->
            s.cm_votes_down <- Some value;
            fill rest)
       | "attachment_ids" ->
         (match s.cm_attachment_ids with
          | Some _ -> None
          | None ->
            s.cm_attachment_ids <- Some value;
            fill rest)
       | _ -> None)
  in
  fill fields
;;

let comment_of_yojson (json : Yojson.Safe.t) : comment decoded =
  match json with
  | `Assoc fields ->
    (match extract_comment_fields fields with
     | None -> quiet None
     | Some s ->
       let audience, audience_diagnostics = optional_audience s.cm_audience in
       let parent_id =
         match s.cm_parent_id with
         | Some `Null -> Ok None
         | Some (`String raw) ->
           (match Comment_id.of_string raw with
            | Ok parent_id -> Ok (Some parent_id)
            | Error _ -> Error ())
         | None | Some _ -> Error ()
       in
       (match
          ( required_string s.cm_id
          , required_string s.cm_post_id
          , required_string s.cm_author
          , required_string s.cm_content
          , required_float s.cm_created_at
          , required_expiry s.cm_expires_at
          , required_int s.cm_votes_up
          , required_int s.cm_votes_down
          , parent_id
          , audience
          , optional_attachment_ids s.cm_attachment_ids )
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
          , Ok audience
          , Ok attachment_ids ) ->
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
               ; attachment_ids
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
          , (Ok _ | Error _)
          , (Ok _ | Error _) ) -> { value = None; diagnostics = audience_diagnostics }))
  | _ -> quiet None
;;
