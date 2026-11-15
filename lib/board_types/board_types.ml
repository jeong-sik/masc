(** Board - MASC Internal Board (Mastodon-style federation ready)

    Zero-tolerance implementation:
    - ID validation (no path traversal)
    - TTL optional (0 = permanent, default)
    - Explicit persistence errors
    - Cryptographic IDs (no prediction)
    - Atomic writes (no corruption)
    - Automatic sweeper (no manual cleanup)

    Eio Best Practices:
    - Switch.on_release for cleanup (not Fun.protect)
    - Structured concurrency

    @since 0.5.0 - Replaces social.ml with hardened implementation
*)

(** {1 Error Types - No Silent Failures} *)

type board_error =
  | Invalid_id of string
  | Post_not_found of string
  | Comment_not_found of string
  | Io_error of string
  | Validation_error of string
  | Already_voted of string
  | Already_exists of string
  | Unauthorized of string
    (** Actor attempted an owner-gated mutation (e.g. editing a post they
        do not own). Distinct from [Validation_error] so callers can map it
        to a 403-class rejection rather than a generic input error. *)
  | Recipient_lookup_failed of string
    (** The declared-recipient lookup could not answer for a name in the
        text: a Keeper's settings could not be read, or two Keepers claim one
        alias. The write is refused and nothing is stored. *)
  [@@deriving show]

(* Complete-source reads distinguish unavailable data from absent rows. *)
type board_read_error =
  | Read_invalid_id of string
  | Read_post_not_found of string
  | Read_comment_not_found of string
  | Read_source_unavailable of board_error
  [@@deriving show]

let board_error_of_read_error = function
  | Read_invalid_id detail -> Invalid_id detail
  | Read_post_not_found post_id -> Post_not_found post_id
  | Read_comment_not_found comment_id -> Comment_not_found comment_id
  | Read_source_unavailable _ -> Io_error "Board data is unavailable."

(** {1 Safe ID Module - Parse Don't Validate} *)

(* Shared regex for alphanumeric ID validation (Post_id, Board_id, Sub_board_id).
   Single [Re.compile] DFA build instead of 3 identical copies. [Comment_id]
   is stricter: it accepts only the shape its own [generate] mints. *)
let alphanumeric_id_re = Re.Pcre.re {|^[a-zA-Z0-9_-]+$|} |> Re.compile

module Post_id : sig
  type t
  val of_string : string -> (t, board_error) result
  val of_string_for_read : string -> (t, board_read_error) result
  val to_string : t -> string
  val generate : unit -> t
  val json_schema_pattern : string
end = struct
  type t = string

  (* Only alphanumeric, dash, underscore. Max [max_len] chars. The length
     bound is one constant so [of_string] and [json_schema_pattern] cannot
     drift: a schema that advertised a different bound would reject an id the
     parser accepts, which is the mismatch this pattern exists to prevent. *)
  let valid_pattern = alphanumeric_id_re
  let max_len = 64

  let json_schema_pattern = Printf.sprintf "^[a-zA-Z0-9_-]{1,%d}$" max_len

  let parse s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= max_len && Re.execp valid_pattern s then Ok s
    else Error (Printf.sprintf "Invalid post_id: %s" s)

  let of_string s = Result.map_error (fun detail -> Invalid_id detail) (parse s)
  let of_string_for_read s = Result.map_error (fun detail -> Read_invalid_id detail) (parse s)

  let to_string t = t

  let generate () = Random_id.prefixed ~prefix:"p-" ~bytes:16
end

module Comment_id : sig
  type t
  val of_string : string -> (t, board_error) result
  val of_string_for_read : string -> (t, board_read_error) result
  val to_string : t -> string
  val generate : unit -> t
  val accepted_format : string
  val json_schema_pattern : string
end = struct
  type t = string

  (* [generate] is the only minter, so the parser accepts exactly what it
     mints: the ["c-"] prefix followed by [2 * random_bytes] lowercase hex
     characters. A keeper that invents a comment id (["c-placeholder"],
     ["BUILDER_A_DONE"]: 109 of the 134 masc_board_comment_vote calls in
     August 2026, #29457) is refused here with the accepted shape instead of
     reaching the store as a lookup that can only miss. *)
  let prefix = "c-"
  let random_bytes = 16
  let hex_length = 2 * random_bytes
  let accepted_format = Printf.sprintf "%s<%d lowercase hex>" prefix hex_length
  let json_schema_pattern = Printf.sprintf "^%s[0-9a-f]{%d}$" prefix hex_length
  let valid_pattern = Re.Pcre.re json_schema_pattern |> Re.compile

  let parse s =
    let s = String.trim s in
    if Re.execp valid_pattern s then Ok s
    else
      Error
        (Printf.sprintf
           "Invalid comment_id %S; expected %s, the id masc_board_post_get \
            and masc_board_comment return"
           s accepted_format)

  let of_string s = Result.map_error (fun detail -> Invalid_id detail) (parse s)
  let of_string_for_read s = Result.map_error (fun detail -> Read_invalid_id detail) (parse s)

  let to_string t = t

  let generate () = Random_id.prefixed ~prefix ~bytes:random_bytes
end

module Deletion_id : sig
  type t
  val of_string : string -> (t, board_error) result
  val to_string : t -> string
  val generate : unit -> t
end = struct
  type t = string
  let prefix = "d-"
  let random_bytes = 16
  let length = String.length prefix + (2 * random_bytes)
  let pattern = Re.Pcre.re (Printf.sprintf "^%s[0-9a-f]{%d}$" prefix (2 * random_bytes)) |> Re.compile
  let of_string text =
    if String.length text = length && Re.execp pattern text then Ok text
    else Error (Invalid_id "Invalid Board deletion decision ID.")
  let to_string id = id
  let generate () = Random_id.prefixed ~prefix ~bytes:random_bytes
end

module Agent_id : sig
  type t
  val parse : string -> (t, board_error) result
  val of_string : string -> (t, board_error) result
  val to_string : t -> string
end = struct
  type t = string

  (* SSOT: [Validation.Id_shape] owns the agent id shape. This module carried
     its own copy and drifted twice -- #8625 raised the length cap by hand to
     match, #8633 re-widened the pattern by hand to match -- each time catching
     up after the fact. It now delegates, so the two cannot disagree again, and
     board inherits the path-separator and traversal checks it never had. *)
  let from_shape = function
    | Ok id -> Ok (Validation.Id_shape.to_string id)
    | Error reason -> Error (Validation_error (Printf.sprintf "Invalid agent_id: %s" reason))

  let parse s =
    Validation.Id_shape.parse (String.trim s) |> from_shape

  let of_string s =
    Validation.Id_shape.validate (String.trim s) |> from_shape

  let to_string t = t
end

(** {1 Types with Mandatory TTL} *)

type visibility =
  | Public      (* Visible to federation *)
  | Unlisted    (* Not in feeds, but accessible *)
  | Internal    (* This MASC instance only *)
  | Direct      (* Mentioned agents only *)

type audience =
  | Targets of Agent_id.t list
  | Broadcast
  | Thread_participants
  | Discoverable
(** Closed routing authority for Board mutations. [Targets] contains exact
    typed Board identities, not Keeper identities; MASC may project those
    identities into Keeper lanes without making Board depend on Keeper. *)

type post_kind =
  | Human_post [@tla.symbol "human_post"]
  | Automation_post [@tla.symbol "automation_post"]
  | System_post [@tla.symbol "system_post"]
[@@deriving tla]

(* RFC-0233 §7: typed provenance of a board post — which keeper turn produced
   it and through which channel. Replaces the fusion [meta_json] [run_id]
   smuggle with a first-class field that a real index can key on (no
   meta_json substring scan, RFC §7.6 guard #2).

   [source] is the channel's [Surface_ref.lane_label] string, NOT a typed
   [Surface_ref.t]: Surface_ref lives in the [masc] umbrella, which depends on
   [masc_board], so referencing the typed variant here would form a cycle.

   [turn_ref] and [fusion_run_id] are distinct (RFC §7.6 guard #5): turn_ref is
   the turn-level join key, fusion_run_id correlates a fusion deliberation run.
   All sub-fields optional; an all-[None] origin is represented as [origin = None]. *)
type post_origin = {
  turn_ref: Ids.Turn_ref.t option;
  source: string option;
  fusion_run_id: string option;
  fusion_producer: string option;
}

(* RFC-0233 §7: constructor for a keeper-authored post's origin. A keeper post
   is the output of a specific keeper turn, so [turn_ref] is the turn-level join
   key and [source] names the producing channel (e.g. "keeper_speech",
   "keeper_alert"). [fusion_run_id] is always [None] here: fusion's
   server-root-switch fork has its own constructor at the fusion sink. [turn_ref]
   stays optional so callers that cannot reach a mint-once-safe turn reference
   still set [source] (origin present, turn_ref absent) rather than fabricating
   one. *)
let keeper_authored_origin ?turn_ref ~source () : post_origin =
  { turn_ref; source = Some source; fusion_run_id = None; fusion_producer = None }

type post_close_state = {
  closed_by: Agent_id.t;
  closed_at: float;
  successor_id: Post_id.t option;
  summary: string option;
}

type post = {
  id: Post_id.t;
  author: Agent_id.t;
  title: string;
  body: string;
  post_kind: post_kind;
  meta_json: Yojson.Safe.t option;
  visibility: visibility;
  audience: audience option; (* None means no recorded audience; never infer it on read. *)
  created_at: float;
  content_updated_at: float; (* Last title, body or author change. *)
  updated_at: float;   (* Last activity: vote, comment, edit *)
  expires_at: float;   (* 0.0 is permanent; the sweeper removes only a positive time already past. *)
  votes_up: int;
  votes_down: int;
  reply_count: int;
  pinned: bool;              (* Operator-curated pin (owner-gated): floats the post to the top of its category *)
  hearth: string option;     (* Topic category within the Board *)
  thread_id: string option;  (* Linked Conversation thread *)
  origin: post_origin option; (* RFC-0233 §7: originating turn / channel provenance *)
  closed: post_close_state option; (* None = open; absent key on read = open *)
}

type comment = {
  id: Comment_id.t;
  post_id: Post_id.t;
  parent_id: Comment_id.t option;
  author: Agent_id.t;
  content: string;
  audience: audience option; (* None means no recorded audience; never infer it on read. *)
  created_at: float;
  expires_at: float;   (* MANDATORY *)
  votes_up: int;
  votes_down: int;
}

type source_completeness =
  | Source_complete
  | Source_incomplete of board_error

type comments_observation = {
  comments : comment list;
  completeness : source_completeness;
}

type post_creation = {
  post: post;
  audience: audience;
  unresolved: string list;
}

type comment_creation = {
  comment: comment;
  audience: audience;
  unresolved: string list;
}

type reaction_target_type =
  | Reaction_post
  | Reaction_comment

type reaction = {
  target_type: reaction_target_type;
  target_id: string;
  user_id: Agent_id.t;
  emoji: string;
  created_at: float;
}

type reaction_summary = {
  emoji: string;
  count: int;
  reacted: bool;
  recent_user_ids: string list;
}

type reaction_toggle_result = {
  post_id : Post_id.t;
  target_type: reaction_target_type;
  target_id: string;
  user_id: string;
  emoji: string;
  reacted: bool;
  summary: reaction_summary list;
}

(** {1 SubBoard — Named spaces within the board} *)

module Sub_board_id : sig
  type t
  val of_string : string -> (t, board_error) result
  val to_string : t -> string
  val generate : unit -> t
end = struct
  type t = string

  let valid_pattern = alphanumeric_id_re

  let of_string s =
    let s = String.trim s in
    let len = String.length s in
    if len >= 1 && len <= 64 && Re.execp valid_pattern s then Ok s
    else Error (Invalid_id (Printf.sprintf "Invalid sub_board_id: %s" s))

  let to_string t = t

  let generate () = Random_id.prefixed ~prefix:"sb-" ~bytes:16
end

type sub_board_access =
  | Open
  | Members_only
  | Owner_only
[@@deriving enumerate]

type sub_board = {
  id: Sub_board_id.t;
  slug: string;
  name: string;
  description: string;
  owner: Agent_id.t;
  members: Agent_id.t list;
  access: sub_board_access;
  created_at: float;
  post_count: int;
}

(** {1 Read pagination and sweeper defaults} *)

module Limits = struct
  let env_int name default = Env_config_core.get_int ~default name

  (* The default read is the newest comments, not the oldest: a reader that
     does not know a thread yet wants its tail, and the body travels with it.
     A caller that wants the head names comment_offset=0. *)
  let default_comment_page_limit = 20
  let max_comment_page_limit = 100
  let default_ttl_hours = 0    (* 0 = permanent (no expiry) *)
  let sweeper_interval_sec = env_int "MASC_BOARD_SWEEPER_INTERVAL_SEC" 10
  let sweeper_batch_size = env_int "MASC_BOARD_SWEEPER_BATCH_SIZE" 100
  (* task-1758/#39356 scope extension: once a thread holds this many
     comments, the next one is refused at the write boundary so a hot
     thread becomes a chain of successor posts instead of one endless row.
     Override with MASC_BOARD_COMMENT_COUNT_CAP. *)
  let comment_count_cap = env_int "MASC_BOARD_COMMENT_COUNT_CAP" 100

  (** [comment_count_cap]'s fail-open meaning is deliberate: a non-positive
      value switches the growth limit off. But silence would make that look
      like a typo that silently did nothing, so the loader records one WARN
      that names the variable and the value read (issuecomment-5858752752). *)
  let cap_warning_message ~cap () =
    if cap > 0 then None
    else
      Some
        (Printf.sprintf
           "MASC_BOARD_COMMENT_COUNT_CAP is %d; the comment cap is OFF"
           cap)
end

module Comment_page = struct
  type start =
    | From_offset of int
    | Latest
    | After_comment of Comment_id.t

  type request =
    { start : start
    ; limit : int
    }

  type argument =
    | Comment_offset
    | Comment_limit
    | Comment_tail
    | After_comment_id

  type request_error =
    | Arguments_not_an_object
    | Not_an_integer of
        { argument : argument
        ; given : string
        }
    | Integer_out_of_range of
        { argument : argument
        ; literal : string
        }
    | Not_a_string of
        { argument : argument
        ; given : string
        }
    | Not_a_comment_id of string
    | Negative_offset of int
    | Limit_out_of_bounds of int
    | Tail_out_of_bounds of int
    | Conflicting_arguments of
        { given : argument
        ; conflicts_with : argument
        }

  let argument_name = function
    | Comment_offset -> "comment_offset"
    | Comment_limit -> "comment_limit"
    | Comment_tail -> "comment_tail"
    | After_comment_id -> "after_comment_id"
  ;;

  let integer_argument (fields : (string * Yojson.Safe.t) list) argument =
    match List.assoc_opt (argument_name argument) fields with
    | None -> Ok None
    | Some (`Int value) -> Ok (Some value)
    | Some (`Intlit literal) -> Error (Integer_out_of_range { argument; literal })
    (* A JSON number with no fractional part is an integer, which is the rule
       the tool-call validator applies before a call reaches a handler
       (Agent_core.Tool_input_validation's integer type check). Refusing 50.0
       here rejected a call the schema had already accepted. The two cannot
       share one function: the validator ships in the agent_core package,
       which takes no MASC library. *)
    | Some (`Float value)
      when Float.is_finite value
           && Float.is_integer value
           && value >= Float.of_int Int.min_int
           && value < Float.of_int Int.max_int -> Ok (Some (int_of_float value))
    | Some (`Float value) when Float.is_finite value && Float.is_integer value ->
      Error (Integer_out_of_range { argument; literal = Printf.sprintf "%.0f" value })
    | Some ((`Null | `Bool _ | `Float _ | `String _ | `Assoc _ | `List _) as value) ->
      Error (Not_an_integer { argument; given = Json_util.kind_name value })
  ;;

  (* The id is parsed here, where the call arrives, so a read never looks up
     an id the store could not have minted. *)
  let comment_id_argument (fields : (string * Yojson.Safe.t) list) =
    match List.assoc_opt (argument_name After_comment_id) fields with
    | None -> Ok None
    | Some (`String raw) ->
      (match Comment_id.of_string raw with
       | Ok comment_id -> Ok (Some comment_id)
       | Error _ -> Error (Not_a_comment_id raw))
    | Some ((`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) as value)
      ->
      Error (Not_a_string { argument = After_comment_id; given = Json_util.kind_name value })
  ;;

  let bounded_limit = function
    | None -> Ok Limits.default_comment_page_limit
    | Some limit when limit < 1 || limit > Limits.max_comment_page_limit ->
      Error (Limit_out_of_bounds limit)
    | Some limit -> Ok limit
  ;;

  let conflict given conflicts_with = Error (Conflicting_arguments { given; conflicts_with })

  (* Each of comment_offset, comment_tail and after_comment_id says where the
     page starts, so two of them in one call name two pages. The call is
     refused rather than one of them winning: a winner the caller did not
     pick reads a page it did not ask for. comment_tail is also the page's
     size, so comment_limit beside it is a second size. With none of them the
     read starts at the newest comment: a caller that does not know the
     thread yet wants its tail, and comment_offset=0 is how it asks for the
     head. *)
  let request_of_args (args : Yojson.Safe.t) =
    match args with
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error Arguments_not_an_object
    | `Assoc fields ->
      let open Result.Syntax in
      let* offset = integer_argument fields Comment_offset in
      let* limit = integer_argument fields Comment_limit in
      let* tail = integer_argument fields Comment_tail in
      let* after = comment_id_argument fields in
      (match tail, after, offset, limit with
       | Some _, Some _, _, _ -> conflict Comment_tail After_comment_id
       | Some _, None, Some _, _ -> conflict Comment_tail Comment_offset
       | Some _, None, None, Some _ -> conflict Comment_tail Comment_limit
       | Some count, None, None, None ->
         (* 0 asks for the post body with no comments: the [Latest] page is
            then empty and the body still travels (task-1820 D2 rows). *)
         if count < 0 || count > Limits.max_comment_page_limit
         then Error (Tail_out_of_bounds count)
         else Ok { start = Latest; limit = count }
       | None, Some _, Some _, _ -> conflict After_comment_id Comment_offset
       | None, Some comment_id, None, limit ->
         let* limit = bounded_limit limit in
         Ok { start = After_comment comment_id; limit }
       | None, None, Some offset, _ when offset < 0 -> Error (Negative_offset offset)
       | None, None, Some offset, limit ->
         let* limit = bounded_limit limit in
         Ok { start = From_offset offset; limit }
       | None, None, None, limit ->
         let* limit = bounded_limit limit in
         Ok { start = Latest; limit })
  ;;

  let request_error_to_string = function
    | Arguments_not_an_object -> "the arguments must be a JSON object"
    | Not_an_integer { argument; given } ->
      Printf.sprintf "%s must be an integer (got %s)" (argument_name argument) given
    | Integer_out_of_range { argument; literal } ->
      Printf.sprintf
        "%s must be an integer this server can hold (got %s)"
        (argument_name argument)
        literal
    | Not_a_string { argument; given } ->
      Printf.sprintf "%s must be a string (got %s)" (argument_name argument) given
    | Not_a_comment_id raw ->
      Printf.sprintf
        "after_comment_id %S is not a comment id; expected %s, the id a thread \
         page prints beside each comment"
        raw
        Comment_id.accepted_format
    | Negative_offset offset ->
      Printf.sprintf "comment_offset must be 0 or greater (got %d)" offset
    | Limit_out_of_bounds limit ->
      Printf.sprintf
        "comment_limit must be between 1 and %d (got %d)"
        Limits.max_comment_page_limit
        limit
    | Tail_out_of_bounds count ->
      Printf.sprintf
        "comment_tail must be between 0 and %d (got %d)"
        Limits.max_comment_page_limit
        count
    | Conflicting_arguments { given; conflicts_with } ->
      Printf.sprintf
        "%s cannot be sent with %s: %s"
        (argument_name given)
        (argument_name conflicts_with)
        (match conflicts_with with
         | Comment_limit -> "comment_tail is already the number of comments to read."
         | Comment_offset | Comment_tail | After_comment_id ->
           "each one says where the page starts. Send only one of them.")
  ;;

  type 'a page =
    { offset : int
    ; items : 'a list
    ; total : int
    ; next_offset : int option
    }

  type 'a t =
    | Page of 'a page
    | Offset_out_of_range of
        { requested : int
        ; total : int
        }
    | Comment_not_found of
        { comment_id : Comment_id.t
        ; total : int
        }

  let accept_every_page (_ : 'a page) = true

  let select ?(fits = accept_every_page) ~comment_id_of (request : request) items =
    let total = List.length items in
    let page_of ~first ~count =
      let taken = List.filteri (fun index _ -> index >= first && index < first + count) items in
      let reached = first + List.length taken in
      { offset = first
      ; items = taken
      ; total
      ; next_offset = (if reached < total then Some reached else None)
      }
    in
    (* A page never stops before its first item, so one item is always taken
       and the search starts above it. The rest is a halving search for the
       longest page [fits] accepts: rendering a candidate costs as much as the
       page is large, and extending one item at a time rendered it once per
       comment. *)
    let longest_count ~most page_of_count =
      let rec longest_fitting low high best =
        if low > high
        then best
        else (
          let midpoint = low + ((high - low) / 2) in
          if fits (page_of_count midpoint)
          then longest_fitting (midpoint + 1) high midpoint
          else longest_fitting low (midpoint - 1) best)
      in
      match most with
      | 0 -> 0
      | 1 -> 1
      | _ -> longest_fitting 2 most 1
    in
    let forward first =
      let count =
        longest_count
          ~most:(min request.limit (total - first))
          (fun count -> page_of ~first ~count)
      in
      Page (page_of ~first ~count)
    in
    let is_wanted wanted item =
      match comment_id_of item with
      | Some id -> String.equal id (Comment_id.to_string wanted)
      | None -> false
    in
    match request.start with
    (* [total] is the end of the thread: an empty page that names the
       thread's size. Only an offset past it names nothing. *)
    | From_offset offset when offset > total ->
      Offset_out_of_range { requested = offset; total }
    | From_offset offset -> forward offset
    (* The anchor's own position is resolved on this read, so a sweep that
       moved it still starts the page right after it. The newest comment
       anchors an empty end page, which is how a reader learns nothing new
       arrived. *)
    | After_comment wanted ->
      (match List.find_index (is_wanted wanted) items with
       | Some index -> forward (index + 1)
       | None -> Comment_not_found { comment_id = wanted; total })
    (* The page ends at the thread's end and grows backwards, so a page the
       budget cuts keeps the newest comments and names where it starts. *)
    | Latest ->
      let count =
        longest_count
          ~most:(min request.limit total)
          (fun count -> page_of ~first:(total - count) ~count)
      in
      Page (page_of ~first:(total - count) ~count)
  ;;

  module Position = struct
    type t =
      { offset : int
      ; returned : int
      ; total : int
      ; next_offset : int option
      }

    let of_page (page : 'a page) =
      { offset = page.offset
      ; returned = List.length page.items
      ; total = page.total
      ; next_offset = page.next_offset
      }
    ;;

    let to_yojson position =
      `Assoc
        [ "offset", `Int position.offset
        ; "returned", `Int position.returned
        ; "total", `Int position.total
        ; "has_more", `Bool (Option.is_some position.next_offset)
        ; ( "next_offset"
          , match position.next_offset with
            | Some next -> `Int next
            | None -> `Null )
        ]
    ;;

    let int_field fields name =
      match List.assoc_opt name fields with
      | Some (`Int value) -> Some value
      | Some (`Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _)
      | None -> None
    ;;

    let of_yojson (json : Yojson.Safe.t) =
      match json with
      | `Assoc fields ->
        (match int_field fields "offset", int_field fields "returned", int_field fields "total" with
         | Some offset, Some returned, Some total ->
           (match List.assoc_opt "next_offset" fields with
            | Some (`Int next) -> Some { offset; returned; total; next_offset = Some next }
            | Some `Null | None -> Some { offset; returned; total; next_offset = None }
            | Some (`Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) -> None)
         | (None | Some _), _, _ -> None)
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
    ;;

    let line position =
      match position.returned with
      | 0 ->
        (match position.total with
         | 0 -> "[no comments]"
         | total ->
           Printf.sprintf
             "[no comments from offset %d: the thread has %d now.]"
             position.offset
             total)
      | returned ->
        let following =
          match position.next_offset with
          | Some next -> Printf.sprintf " Read the rest with comment_offset=%d." next
          | None -> " No comments after this page."
        in
        (* The newest page has no forward cursor, but it may have older
           comments. Name a non-overlapping page immediately before this
           one; repeating the hint walks to offset zero without rereading
           the newest slice. A budget-shortened page uses its actual size. *)
        let preceding =
          if position.offset = 0
          then ""
          else
            let count = min position.offset returned in
            Printf.sprintf
              " Read earlier with comment_offset=%d and comment_limit=%d."
              (position.offset - count)
              count
        in
        Printf.sprintf
          "[comments %d-%d of %d.%s%s]"
          position.offset
          (position.offset + returned - 1)
          position.total
          following
          preceding
    ;;

    let metadata_key = "masc.comment_page"
    let to_metadata position = `Assoc [ metadata_key, to_yojson position ]

    let of_metadata (metadata : Yojson.Safe.t option) =
      match metadata with
      | Some (`Assoc fields) ->
        (match List.assoc_opt metadata_key fields with
         | Some json -> of_yojson json
         | None -> None)
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
      | None -> None
    ;;
  end
end

(** {1 Vote Direction} *)

type vote_direction = Up | Down

(** {1 Incremental Hot-Post Index} *)

type hot_post_key =
  { net_vote : int
  ; created_at : float
  ; post_id : string
  }

let hot_post_key_of_post (p : post) : hot_post_key =
  { net_vote = p.votes_up - p.votes_down
  ; created_at = p.created_at
  ; post_id = Post_id.to_string p.id
  }
;;

let compare_hot_post_key (a : hot_post_key) (b : hot_post_key) : int =
  let cmp = Int.compare b.net_vote a.net_vote in
  if cmp <> 0
  then cmp
  else (
    let cmp = Float.compare b.created_at a.created_at in
    if cmp <> 0 then cmp else String.compare a.post_id b.post_id)
;;

module Hot_post_set = Set.Make (struct
    type t = hot_post_key

    let compare = compare_hot_post_key
  end)

type recent_post_key =
  { recent_created_at : float
  ; recent_post_id : string
  }

let recent_post_key_of_post (p : post) : recent_post_key =
  { recent_created_at = p.created_at
  ; recent_post_id = Post_id.to_string p.id
  }
;;

let compare_recent_post_key (a : recent_post_key) (b : recent_post_key) : int =
  let cmp = Float.compare b.recent_created_at a.recent_created_at in
  if cmp <> 0 then cmp else String.compare a.recent_post_id b.recent_post_id
;;

module Recent_post_set = Set.Make (struct
    type t = recent_post_key

    let compare = compare_recent_post_key
  end)

(** {1 In-Memory Store} *)

type flusher_msg =
  | Flush
  | Sweep

type posts_source_observation = {
  source_path : string;
  snapshot : Fs_compat.private_jsonl_snapshot;
  workspace_observation : Board_workspace_binding.observation;
}

type posts_source_history =
  | No_observation
  | Posts_observed of posts_source_observation

type posts_row_error =
  | Invalid_posts_json of { line : int; detail : string }
  | Invalid_posts_row of { line : int }

type posts_source_file = Posts_file

type posts_source_stage =
  | Read_posts | Decode_posts | Encode_posts
  | Write_posts | Project_posts | Report_source

type posts_source_diagnostic =
  | File_diagnostic of {
      file : posts_source_file;
      error : Fs_compat.private_jsonl_transaction_error;
    }
  | Workspace_diagnostic of Board_workspace_binding.rejection
  | Posts_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Raised_diagnostic of {
      stage : posts_source_stage;
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }
(** One chronological trace for the current operation. Transaction entries
    retain their original primary/cleanup order; prior operations are not replayed. *)

type posts_source_failure =
  | Posts_not_observed
  | Posts_rows_rejected of posts_row_error list
  | Posts_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Posts_missing
  | Posts_source_binding_mismatch
  | Posts_policy_source_is_posts_source
  | Posts_snapshot_stale
  | Posts_workspace_binding_refused of Board_workspace_binding.rejection
  | Posts_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type posts_unsettled_write_kind =
  | Append_write
  | Rewrite_write

type posts_unsettled_write = {
  expected : posts_source_observation;
  kind : posts_unsettled_write_kind;
  intended_bytes : string;
}

type posts_source_state =
  | Posts_unobserved
  | Posts_readable of {
      observation : posts_source_observation;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_refused of {
      last_observed : posts_source_history;
      failure : posts_source_failure;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_unsettled of {
      last_observed : posts_source_history;
      failure : posts_source_failure;
      pending : posts_unsettled_write;
      diagnostics : posts_source_diagnostic list;
    }

type posts_write_outcome =
  | Posts_written of { diagnostics : posts_source_diagnostic list }
  | Posts_not_written of {
      failure : posts_source_failure;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_write_unknown of {
      failure : posts_source_failure;
      diagnostics : posts_source_diagnostic list;
    }

type posts_source_read =
  | Posts_complete of {
      observation : posts_source_observation;
      posts : post list;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_partial of {
      observation : posts_source_observation;
      posts : post list;
      errors : posts_row_error list;
      diagnostics : posts_source_diagnostic list;
    }
  | Posts_unavailable of {
      failure : posts_source_failure;
      diagnostics : posts_source_diagnostic list;
    }

type posts_source_io = {
  posts : Fs_compat.private_jsonl_transaction_io_for_testing option;
}
(** Immutable real-transaction seam for the posts file. None selects
    production IO. *)

type comments_source_observation = {
  source_path : string;
  snapshot : Fs_compat.private_jsonl_snapshot;
  workspace_observation : Board_workspace_binding.observation;
}

type comments_source_history =
  | No_comments_observation
  | Comments_observed of comments_source_observation
  | Comments_present_without_snapshot
(** A validated nonauthoritative read can prove Present without granting an
    exact snapshot for mutation. This still prevents later Missing from being
    treated as an uninitialized source. *)

type comments_row_error =
  | Invalid_comments_json of { line : int; detail : string }
  | Invalid_comments_row of { line : int }

type comments_source_stage =
  | Read_comments | Decode_comments | Encode_comments
  | Write_comments | Project_comments | Report_comments

type comments_source_diagnostic =
  | Comments_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Comments_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Comments_workspace_diagnostic of Board_workspace_binding.rejection
  | Comments_display_diagnostic of Fs_compat.Private_jsonl_unique_fold.error
  | Comments_display_cleanup_diagnostic of Fs_compat.private_jsonl_operation_failure
  | Comments_raised_diagnostic of {
      stage : comments_source_stage;
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }

type comments_source_failure =
  | Comments_not_observed
  | Comments_rows_rejected of comments_row_error list
  | Comments_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Comments_missing
  | Comments_source_binding_mismatch
  | Comments_snapshot_stale
  | Comments_publication_pending
  | Comments_reload_required
  | Comments_workspace_refused of Board_workspace_binding.rejection
  | Comments_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type comments_write_kind = Comments_append | Comments_rewrite

type comments_unsettled_write = {
  expected : comments_source_observation;
  kind : comments_write_kind;
  intended_bytes : string;
}

type comments_recovery_receipt = {
  interrupted : comments_unsettled_write;
  prior_failure : comments_source_failure;
  fence : comments_source_observation;
  diagnostics : comments_source_diagnostic list;
}
(** Explicit storage recovery superseded an interrupted attempt. This is not
    a verdict that the original operation was written or not written. *)

type comments_publication = {
  observation : comments_source_observation;
  diagnostics : comments_source_diagnostic list;
}
(** The actual successful append receipt, retained before model publication.
    Only its owning store may acknowledge it after a normal publication or
    after recording the exact appended row's rejected-publication cleanup. *)

type comments_source_state =
  | Comments_unobserved
  | Comments_readable of comments_publication
  | Comments_publishing of comments_publication
  | Comments_recovered of comments_recovery_receipt
  (** Completed recovery, retained before finishing can raise. Repeated settle
      returns this same receipt without IO or replaying historical exceptions;
      acknowledge it explicitly before a full model reload. *)
  | Comments_refused of {
      last_observed : comments_source_history;
      failure : comments_source_failure;
      diagnostics : comments_source_diagnostic list;
    }
  | Comments_unsettled of {
      pending : comments_unsettled_write;
      failure : comments_source_failure;
      diagnostics : comments_source_diagnostic list;
    }
(** [No_comments_observation] means this store has never observed this source.
    A first observed Missing source is legitimate empty input;
    losing a source this store observed Present is refused. This lifetime
    evidence does not prove absence across different processes. *)

type sub_boards_source_observation = {
  policy_path : string;
  policy_snapshot : Fs_compat.private_jsonl_snapshot;
  policy_workspace : Board_workspace_binding.observation;
}

type sub_boards_source_history =
  | No_policy_observation
  | Policy_observed of sub_boards_source_observation
  | Policy_present_without_snapshot

type sub_boards_row_error =
  | Invalid_policy_json of { line : int; detail : string }
  | Invalid_policy_row of { line : int }

type sub_boards_source_diagnostic =
  | Policy_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Policy_workspace_diagnostic of Board_workspace_binding.rejection
  | Policy_raised_diagnostic of {
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }

type sub_boards_source_failure =
  | Policy_not_observed
  | Policy_rows_rejected of sub_boards_row_error list
  | Policy_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Policy_missing
  | Policy_binding_mismatch
  | Policy_publication_pending
  | Policy_workspace_refused of Board_workspace_binding.rejection
  | Policy_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type sub_boards_write_kind = Policy_append | Policy_rewrite

type sub_boards_pending_write = {
  policy_before : sub_boards_source_observation;
  policy_kind : sub_boards_write_kind;
  policy_intended_bytes : string;
}

type sub_boards_publication = {
  policy_after : sub_boards_source_observation;
  policy_cleanup : sub_boards_source_diagnostic list;
}

type sub_boards_source_state =
  | Policy_unobserved
  | Policy_readable of sub_boards_source_observation
  | Policy_publishing of sub_boards_publication
  | Policy_refused of {
      policy_history : sub_boards_source_history;
      policy_failure : sub_boards_source_failure;
      policy_diagnostics : sub_boards_source_diagnostic list;
    }
  | Policy_unsettled of {
      policy_pending : sub_boards_pending_write;
      policy_failure : sub_boards_source_failure;
      policy_diagnostics : sub_boards_source_diagnostic list;
    }
(** Policy authority belongs to persist_mutex. Unknown writes and interrupted
    model publication remain fail-stop for this store, with the exact pending
    bytes or known-success receipt retained. Only a fresh store can reload
    them. This is not multi-source crash recovery; see #26378. *)

type reactions_source_observation = {
  reaction_path : string;
  reaction_snapshot : Fs_compat.private_jsonl_snapshot;
  reaction_workspace : Board_workspace_binding.observation;
}

type reactions_source_history =
  | No_reactions_observation
  | Reactions_observed of reactions_source_observation
  | Reactions_present_without_snapshot

type reactions_row_error =
  | Invalid_reaction_json of { line : int; detail : string }
  | Invalid_reaction_row of { line : int }

type reactions_source_diagnostic =
  | Reaction_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Reaction_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Reaction_workspace_diagnostic of Board_workspace_binding.rejection
  | Reaction_raised_diagnostic of {
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }
  | Reaction_projection_diagnostic of board_error

type reactions_source_failure =
  | Reactions_not_observed
  | Reactions_rows_rejected of reactions_row_error list
  | Reactions_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Reactions_missing
  | Reactions_binding_mismatch
  | Reactions_publication_pending
  | Reactions_workspace_refused of Board_workspace_binding.rejection
  | Reactions_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type reactions_pending_write = {
  reaction_before : reactions_source_observation;
  reaction_intended_bytes : string;
}

type reactions_publication = {
  reaction_after : reactions_source_observation;
  reaction_cleanup : reactions_source_diagnostic list;
}

type reactions_source_state =
  | Reactions_unobserved
  | Reactions_readable of reactions_source_observation
  | Reactions_publishing of reactions_publication
  | Reactions_refused of {
      reaction_history : reactions_source_history;
      reaction_failure : reactions_source_failure;
      reaction_diagnostics : reactions_source_diagnostic list;
    }
  | Reactions_unsettled of {
      reaction_pending : reactions_pending_write;
      reaction_failure : reactions_source_failure;
      reaction_diagnostics : reactions_source_diagnostic list;
    }
(** Reaction authority belongs to persist_mutex. Known file success remains owned
    until model publication is acknowledged. Unknown writes and unfinished
    publication require a fresh store; an ordinary reload cannot clear them. *)


type deletion_outcome =
  | Durable_deletion
  | Deletion_decision_pending of string
  | Deletion_persistence_pending of string
(** Decision_pending does not establish model application. Persistence_pending
    does; neither authorizes replay or claims durable completion. *)

type sub_board_deletion_authorization =
  | Operator_sub_board_deletion
  | Owner_sub_board_deletion of Agent_id.t
(** Authority supplied by the calling boundary, never decoded from a marker. *)

type deletion_operation =
  | Delete_post of {
      deleted_post : Post_id.t;
      deleted_comments : Comment_id.t list;
    }
  | Delete_sub_board of {
      deleted_sub_board : Sub_board_id.t;
      deleted_slug : string;
      unlinked_posts : Post_id.t list;
    }

type deletion_plan = {
  decision_id : Deletion_id.t;
  operation : deletion_operation;
}
(** Fixed original identities. Recovery never expands the selected children or
    posts by looking up a slug again. Later boards and posts remain outside it. *)

type deletion_observation = {
  decision_path : string;
  decision_snapshot : Fs_compat.private_jsonl_snapshot;
  decision_workspace : Board_workspace_binding.observation;
}

type deletion_diagnostic =
  | Deletion_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Deletion_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Deletion_workspace_diagnostic of Board_workspace_binding.rejection
  | Deletion_raised_diagnostic of {
      exception_ : exn; backtrace : Printexc.raw_backtrace;
    }

type deletion_failure =
  | Deletion_invalid_decision of string
  | Deletion_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Deletion_workspace_refused of Board_workspace_binding.rejection
  | Deletion_marker_missing
  | Deletion_binding_mismatch
  | Deletion_projection_rejected of board_error
  | Deletion_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type deletion_receipt = {
  decision : deletion_plan;
  decision_after : deletion_observation;
  decision_cleanup : deletion_diagnostic list;
}
(** Known durable marker publication, retained before any model change. *)

type deletion_progress =
  | Decision_recorded
  | Model_applied
  | Sources_uncertain
  | Sources_written
(** Sources_uncertain retains an unknown source effect and requires fresh-store
    recovery. Same-store reload and ordinary flush do not replay that effect.
    Sources_written means all sources selected by the recorded operation have
    known durable receipts: four for a post, Posts and Policy for a sub-board. *)

type deletion_work = {
  decision_receipt : deletion_receipt;
  deletion_progress : deletion_progress;
  deletion_last_failure : deletion_failure option;
  deletion_diagnostics : deletion_diagnostic list;
}

type deletion_attempt =
  | Recording_decision of deletion_plan
  | Retiring_decision of deletion_receipt

type deletion_state =
  | Deletion_unobserved
  | Deletion_readable of {
      observation : deletion_observation;
      plan : deletion_plan option;
      diagnostics : deletion_diagnostic list;
    }
  | Deletion_pending of deletion_work
  | Deletion_unsettled of {
      before : deletion_observation;
      attempt : deletion_attempt;
      intended_bytes : string;
      failure : deletion_failure;
      diagnostics : deletion_diagnostic list;
    }
  | Deletion_refused of {
      last_observed : deletion_observation option;
      failure : deletion_failure;
      diagnostics : deletion_diagnostic list;
    }
  | Deletion_projection_failed of {
      receipt : deletion_receipt;
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }
(** Sole deletion owner under persist_mutex. Ordinary flush/reload cannot settle
    an unknown record/retirement or an exceptional model publication. A fresh
    initializer durably fences an observed decision before applying its fixed
    IDs to fresh complete models. All selected known writes precede retirement. *)

type votes_source_observation = {
  vote_path : string;
  vote_snapshot : Fs_compat.private_jsonl_snapshot;
  vote_workspace : Board_workspace_binding.observation;
}

type votes_source_history =
  | No_votes_observation
  | Votes_observed of votes_source_observation
  | Votes_present_without_snapshot

type votes_row_error =
  | Invalid_vote_json of { line : int; detail : string }
  | Invalid_vote_row of { line : int }

type votes_source_diagnostic =
  | Vote_file_diagnostic of Fs_compat.private_jsonl_transaction_error
  | Vote_guard_diagnostic of Fs_compat.private_jsonl_guard_failure
  | Vote_workspace_diagnostic of Board_workspace_binding.rejection
  | Vote_raised_diagnostic of {
      exception_ : exn;
      backtrace : Printexc.raw_backtrace;
    }
  | Vote_projection_diagnostic of board_error

type votes_source_failure =
  | Votes_not_observed
  | Votes_rows_rejected of votes_row_error list
  | Votes_transaction_failed of Fs_compat.private_jsonl_transaction_error
  | Votes_missing
  | Votes_binding_mismatch
  | Votes_publication_pending
  | Votes_workspace_refused of Board_workspace_binding.rejection
  | Votes_raised of { exception_ : exn; backtrace : Printexc.raw_backtrace }

type votes_write_kind = Vote_append | Vote_rewrite

type votes_pending_write = {
  vote_before : votes_source_observation;
  vote_kind : votes_write_kind;
  vote_intended_bytes : string;
}

type votes_publication = {
  vote_after : votes_source_observation;
  vote_cleanup : votes_source_diagnostic list;
}

type votes_source_state =
  | Votes_unobserved
  | Votes_readable of votes_source_observation
  | Votes_publishing of votes_publication
  | Votes_refused of {
      vote_history : votes_source_history;
      vote_failure : votes_source_failure;
      vote_diagnostics : votes_source_diagnostic list;
    }
  | Votes_unsettled of {
      vote_pending : votes_pending_write;
      vote_failure : votes_source_failure;
      vote_diagnostics : votes_source_diagnostic list;
    }
(** Vote authority belongs to persist_mutex. Known file success remains owned
    until model publication is acknowledged. Unknown writes and unfinished
    publication require a fresh store; an ordinary reload cannot clear them. *)

type store = {
  (** Canonical posts observation/refusal/uncertainty, owned by persist_mutex.
      Successful loads and writes advance it; dirty cards need not equal its bytes. *)
  mutable posts_source : posts_source_state;
  posts_source_io : posts_source_io;
  (** Source authority is owned by persist_mutex. *)
  mutable comments_source : comments_source_state;
  comments_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  mutable sub_boards_source : sub_boards_source_state;
  sub_boards_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  (** Vote-file observation and unfinished effects are owned by persist_mutex. *)
  mutable votes_source : votes_source_state;
  votes_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  (** None selects production vote-file IO. *)
  mutable reactions_source : reactions_source_state;
  reactions_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  deletion_source_io : Fs_compat.private_jsonl_transaction_io_for_testing option;
  mutable workspace_binding: Board_workspace_binding.t;
  posts: (string, post) Hashtbl.t;
  comments: (string, comment) Hashtbl.t;
  (* #10086: value carries [(direction, cast_ts)] so
     [rewrite_vote_log] persists the original vote timestamp on
     every flush instead of overwriting it with the wall clock.
     The float is Unix seconds at which the vote was first cast,
     or the flip time on a direction change. *)
  vote_log: (string, vote_direction * float) Hashtbl.t;
  post_count: int ref;
  mutable last_sweep: float;
  mutex: Eio.Mutex.t;
  persist_mutex: Eio.Mutex.t;
  origin_create_mutex: Eio.Mutex.t;
  (* Phase 2 caches *)
  mutable karma_cache: ((string * int) list * (string * (string * int) list) list) option;       (** None = stale *)
  mutable hot_post_index: Hot_post_set.t;                 (** Incremental immutable Hot index *)
  mutable recent_post_index: Recent_post_set.t;           (** Incremental immutable Recent index *)
  comments_by_post: (string, string list) Hashtbl.t;      (** post_id -> comment_id list *)
  reactions: (string, reaction) Hashtbl.t;                 (** unique target/user/emoji reactions *)
  mutable dirty_posts: bool;                               (** Deferred flush flag *)
  mutable dirty_comments: bool;                            (** Deferred flush flag *)
  mutable deletion_state: deletion_state;
  dirty_post_ids: (string, unit) Hashtbl.t;                 (** Deferred post snapshots *)
  dirty_comment_ids: (string, unit) Hashtbl.t;              (** Deferred comment snapshots *)
  post_rows: (string, post * string) Hashtbl.t;             (** See .mli *)
  comment_rows: (string, comment * string) Hashtbl.t;       (** See .mli *)
  mutable last_flush: float;
  flusher_inbox: flusher_msg Eio.Stream.t;                               (** Last deferred flush time *)
  sub_boards: (string, sub_board) Hashtbl.t;               (** sub_board_id -> sub_board *)
  sub_boards_by_slug: (string, string) Hashtbl.t;          (** slug -> sub_board_id *)
  (* RFC-0233 §7 guard #2: real secondary indexes for origin lookup, mirroring
     [sub_boards_by_slug]. Maintained on create and rebuilt on load (derive-on-
     load, no separately-persisted SSOT). Never a meta_json substring scan. *)
  posts_by_turn_ref: (string, string) Hashtbl.t;           (** Turn_ref.to_string -> post_id *)
  posts_by_run_id: (string, string) Hashtbl.t;             (** fusion_run_id -> post_id *)
}
