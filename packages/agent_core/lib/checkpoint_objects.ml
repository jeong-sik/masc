let ( let* ) = Result.bind

(* ── Digests and the hash chain ─────────────────────────── *)

type digest = string
type chain = string

let sha256_hex ?off ?len text =
  Agent_core_sha256.to_hex (Agent_core_sha256.digest_string ?off ?len text)
;;

let is_lowercase_hex_64 text =
  String.length text = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       text
;;

let digest_of_hex text =
  if is_lowercase_hex_64 text
  then Ok text
  else Error (Printf.sprintf "not 64 lowercase hex characters: %S" text)
;;

let digest_of_bytes bytes = sha256_hex bytes
let chain_of_hex = digest_of_hex
let chain_start = sha256_hex "masc.rfc-0476.chain.v1"
let chain_step chain digest = sha256_hex (chain ^ digest)

(* The content digest names what a checkpoint holds, whatever turns its
   messages are split into: the header as the head writes it and the chain
   over every message. *)
let content_tag = "masc.rfc-0476.content.v1\n"

let content_digest_of ~header_bytes ~chain =
  sha256_hex (String.concat "" [ content_tag; header_bytes; "\n"; chain ])
;;

(* ── Head ───────────────────────────────────────────────── *)

type turn =
  { bundle : digest
  ; messages : int
  ; chain : chain
  }

(* The last turn segment, the messages the segments up to it hold and the
   chain over them. *)
type segment_ref =
  { segment : digest
  ; segment_messages : int
  ; segment_chain : chain
  }

type history =
  { segment : segment_ref option
  ; turns : turn list
  ; open_messages : digest list
  }

type segment =
  { previous : digest option
  ; segment_turns : turn list
  }

type header =
  { session_id : string
  ; turn_count : int
  ; created_at : float
  }

type header_objects =
  { system_prompt : digest
  ; tools : digest
  }

type head =
  { header : header
  ; header_json : Yojson.Safe.t
  ; header_objects : header_objects
  ; history : history
  }

(* Closed turns a head names itself; with this many, the oldest of them
   become one segment. *)
let turns_per_segment = 64

let message_count history =
  (match history.segment with
   | None -> 0
   | Some segment -> segment.segment_messages)
  + List.fold_left (fun total (turn : turn) -> total + turn.messages) 0 history.turns
  + List.length history.open_messages
;;

let head_objects head =
  [ head.header_objects.system_prompt; head.header_objects.tools ]
  @ (match head.history.segment with
     | None -> []
     | Some segment -> [ segment.segment ])
  @ List.map (fun (turn : turn) -> turn.bundle) head.history.turns
  @ head.history.open_messages
;;

let segment_objects segment =
  Option.to_list segment.previous @ List.map (fun (turn : turn) -> turn.bundle) segment.segment_turns
;;

let head_format = "masc.checkpoint.head"

(* The two header fields a head keeps as objects: large, and the same from
   one save to the next. *)
let system_prompt_field = "system_prompt"
let tools_field = "tools"
let is_object_field (name, (_ : Yojson.Safe.t)) =
  String.equal name system_prompt_field || String.equal name tools_field
;;

(* The header as a head writes it, every field but the messages and the two
   object fields, with an empty message list; and those two fields' values. *)
let split_header ~before_messages ~after_messages =
  let fields = before_messages @ after_messages in
  match List.assoc_opt system_prompt_field fields, List.assoc_opt tools_field fields with
  | Some system_prompt, Some tools ->
    let keep field = not (is_object_field field) in
    Ok
      ( `Assoc
          (List.filter keep before_messages
           @ ((Checkpoint_codec.messages_field, `List []) :: List.filter keep after_messages))
      , system_prompt
      , tools )
  | None, (Some _ | None) | Some _, None ->
    Error
      (Error.Serialization
         (JsonParseError { detail = "checkpoint header has no system_prompt or tools field" }))
;;

let header_objects_json header_objects =
  `Assoc
    [ system_prompt_field, `String header_objects.system_prompt
    ; tools_field, `String header_objects.tools
    ]
;;

let content_header_bytes ~header_json ~header_objects =
  Yojson.Safe.to_string
    (`Assoc [ "checkpoint", header_json; "header_objects", header_objects_json header_objects ])
;;

let history_chain history =
  let closed =
    match List.rev history.turns, history.segment with
    | (last : turn) :: _, (Some _ | None) -> last.chain
    | [], Some segment -> segment.segment_chain
    | [], None -> chain_start
  in
  List.fold_left chain_step closed history.open_messages
;;

let head_content_digest head =
  content_digest_of
    ~header_bytes:
      (content_header_bytes ~header_json:head.header_json ~header_objects:head.header_objects)
    ~chain:(history_chain head.history)
;;

let turn_to_json (turn : turn) =
  `Assoc
    [ "bundle", `String turn.bundle
    ; "messages", `Int turn.messages
    ; "chain", `String turn.chain
    ]
;;

let history_to_json history =
  `Assoc
    [ ( "segment"
      , match history.segment with
        | None -> `Null
        | Some segment ->
          `Assoc
            [ "segment", `String segment.segment
            ; "messages", `Int segment.segment_messages
            ; "chain", `String segment.segment_chain
            ] )
    ; "turns", `List (List.map turn_to_json history.turns)
    ; "open", `List (List.map (fun digest -> `String digest) history.open_messages)
    ]
;;

let segment_bytes segment =
  Yojson.Safe.to_string
    (`Assoc
       [ ( "previous"
         , match segment.previous with
           | None -> `Null
           | Some digest -> `String digest )
       ; "turns", `List (List.map turn_to_json segment.segment_turns)
       ])
;;

let head_json head =
  `Assoc
    [ "format", `String head_format
    ; "checkpoint", head.header_json
    ; "header_objects", header_objects_json head.header_objects
    ; "history", history_to_json head.history
    ]
;;

(* ── Message entries and the memo ───────────────────────── *)

(* What one message is written as: the bytes the checkpoint codec writes for
   it, their digest, and the message those bytes decode to. *)
type entry =
  { bytes : string
  ; digest : digest
  ; decoded : Types.message
  }

module Entries = Hashtbl.Make (struct
    type t = Types.message

    let equal = ( == )
    let hash = Types.Message_value.hash
  end)

(* The messages of the last plan or load, by position, with each one's entry
   and [chains.(i)], the chain over the first [i]. A later save whose
   messages begin with these values, physically, takes their entries and
   chain values as they are, so it hashes only what follows. *)
type last =
  { last_messages : Types.message array
  ; last_entries : entry array
  ; last_chains : chain array
  }

type memo =
  { mutable entries : entry Entries.t
  ; mutable last : last option
  }

let create_memo () = { entries = Entries.create 0; last = None }

let encoded_entry memo message =
  match Entries.find_opt memo.entries message with
  | Some entry -> Ok entry
  | None ->
    let* { Checkpoint_codec.bytes; decoded } =
      Checkpoint_codec.validated_message_encoding message
    in
    Ok { bytes; digest = digest_of_bytes bytes; decoded }
;;

(* The next memo holds each message of this save under its own identity and
   under its decoded record, which is what a save after a load passes. *)
let remember next message (entry : entry) =
  Entries.replace next message entry;
  Entries.replace next entry.decoded entry
;;

(* ── Bundles ────────────────────────────────────────────── *)

(* One line of JSON naming each message's digest and length, then each
   message's bytes on a line of its own. Compact JSON has no raw newline, so the
   file reads as JSON lines; a reader checks each slice against the header
   without encoding anything again. *)
let bundle_bytes entries =
  let header =
    `Assoc
      [ ( "messages"
        , `List
            (List.map
               (fun entry ->
                  `Assoc
                    [ "sha256", `String entry.digest
                    ; "bytes", `Int (String.length entry.bytes)
                    ])
               entries) )
      ]
  in
  String.concat "\n" (Yojson.Safe.to_string header :: List.map (fun entry -> entry.bytes) entries)
  ^ "\n"
;;

(* ── Saving ─────────────────────────────────────────────── *)

type boundary =
  | Turn_continues
  | Turn_closes

type plan =
  { objects : (digest * string) list
  ; head_bytes : string
  ; head : head
  ; content : digest
  ; decoded : Checkpoint_types.t
  }


module Digest_set = Set.Make (String)

(* How many of [messages] begin as [last] did: the same value at each
   position, or the value [last] decoded there. *)
let shared_prefix last (messages : Types.message array) =
  match last with
  | None -> 0
  | Some last ->
    let limit = min (Array.length last.last_messages) (Array.length messages) in
    let rec count index =
      if index < limit
         && (last.last_messages.(index) == messages.(index)
             || last.last_entries.(index).decoded == messages.(index))
      then count (index + 1)
      else index
    in
    count 0
;;

(* Every message's entry and the chain over each prefix: the shared prefix
   from [memo.last], the rest encoded (through [memo.entries]) and hashed. *)
let entries_and_chains memo (messages : Types.message array) =
  let length = Array.length messages in
  let shared = shared_prefix memo.last messages in
  let chains = Array.make (length + 1) chain_start in
  let entries =
    match memo.last with
    | Some last when shared > 0 ->
      Array.blit last.last_chains 0 chains 0 (shared + 1);
      Array.sub last.last_entries 0 shared
    | Some _ | None -> [||]
  in
  let rec encode rev_entries index =
    if index = length
    then Ok (Array.append entries (Array.of_list (List.rev rev_entries)))
    else
      let* entry = encoded_entry memo messages.(index) in
      chains.(index + 1) <- chain_step chains.(index) entry.digest;
      encode (entry :: rev_entries) (index + 1)
  in
  let* entries = encode [] shared in
  Ok (shared, entries, chains)
;;

(* The longest run of [previous] turns whose chain values the new messages
   reproduce at the same positions; a match there is a match of every message
   before it. A kept turn whose bundle is [absent] gets its bundle back from
   those messages, as an object to write. Answers the kept turns, those
   objects and how many messages the kept turns hold. *)
let kept_turns ~absent ~from (entries : entry array) (chains : chain array) previous_turns =
  let length = Array.length entries in
  let rec keep rev_kept rev_objects covered = function
    | [] -> List.rev rev_kept, List.rev rev_objects, covered
    | turn :: turns ->
      let through = covered + turn.messages in
      if through <= length && String.equal chains.(through) turn.chain
      then
        if Digest_set.mem turn.bundle absent
        then (
          let bytes = bundle_bytes (Array.to_list (Array.sub entries covered turn.messages)) in
          let bundle = digest_of_bytes bytes in
          keep ({ turn with bundle } :: rev_kept) ((bundle, bytes) :: rev_objects) through turns)
        else keep (turn :: rev_kept) rev_objects through turns
      else List.rev rev_kept, List.rev rev_objects, covered
  in
  keep [] [] from previous_turns
;;

let unwritten_open_objects ~previous_open entries =
  let rec collect written rev_objects = function
    | [] -> List.rev rev_objects
    | entry :: rest ->
      if Digest_set.mem entry.digest written
      then collect written rev_objects rest
      else collect (Digest_set.add entry.digest written) ((entry.digest, entry.bytes) :: rev_objects) rest
  in
  collect (Digest_set.of_list previous_open) [] entries
;;

(* After a plan of [messages]: the table holds every message under its own
   identity and its decoded record (a save after a load passes those). A
   plan that extends the last one adds what is new; any other plan builds
   the table again from its own messages. *)
let remember_plan memo ~shared (messages : Types.message array) (entries : entry array) chains =
  let extends_last =
    match memo.last with
    | Some last -> shared = Array.length last.last_messages
    | None -> false
  in
  let table = if extends_last then memo.entries else Entries.create (Array.length messages) in
  for index = (if extends_last then shared else 0) to Array.length messages - 1 do
    remember table messages.(index) entries.(index)
  done;
  memo.entries <- table;
  memo.last <- Some { last_messages = messages; last_entries = entries; last_chains = chains }
;;

let rec take n = function
  | [] -> []
  | turn :: rest -> if n = 0 then [] else turn :: take (n - 1) rest
;;

let rec drop n = function
  | [] -> []
  | _ :: rest as turns -> if n = 0 then turns else drop (n - 1) rest
;;

(* While [turns_per_segment] closed turns are left, the oldest of them become
   a segment naming the one before it. *)
let rec pack segment turns rev_objects =
  if List.length turns < turns_per_segment
  then segment, turns, List.rev rev_objects
  else (
    let packed = take turns_per_segment turns in
    let bytes =
      segment_bytes
        { previous = Option.map (fun (segment : segment_ref) -> segment.segment) segment
        ; segment_turns = packed
        }
    in
    let digest = digest_of_bytes bytes in
    let before, chain =
      match segment with
      | None -> 0, chain_start
      | Some segment -> segment.segment_messages, segment.segment_chain
    in
    let segment =
      { segment = digest
      ; segment_messages =
          List.fold_left (fun total (turn : turn) -> total + turn.messages) before packed
      ; segment_chain = List.fold_left (fun (_ : chain) (turn : turn) -> turn.chain) chain packed
      }
    in
    pack (Some segment) (drop turns_per_segment turns) ((digest, bytes) :: rev_objects))
;;

let object_of_json json =
  let bytes = Yojson.Safe.to_string json in
  digest_of_bytes bytes, bytes
;;

let plan_save memo ?previous ?(absent = []) boundary (cp : Checkpoint_types.t) =
  let* (before_messages, after_messages), decoded_header =
    Checkpoint_codec.validated_fields_around_messages cp
  in
  let* header_json, system_prompt_json, tools_json =
    split_header ~before_messages ~after_messages
  in
  let messages = Array.of_list cp.messages in
  let* shared, entries, chains = entries_and_chains memo messages in
  let absent = Digest_set.of_list absent in
  let present digest = not (Digest_set.mem digest absent) in
  let ((system_prompt, _) as system_prompt_object) = object_of_json system_prompt_json in
  let ((tools, _) as tools_object) = object_of_json tools_json in
  let header_objects = { system_prompt; tools } in
  (* A header object the previous head names, and the store holds, stays. *)
  let header_writes =
    List.filter_map
      (fun (((digest, _) as written), named) ->
         match previous with
         | Some previous when String.equal (named previous.header_objects) digest && present digest ->
           None
         | Some _ | None -> Some written)
      [ system_prompt_object, (fun objects -> objects.system_prompt)
      ; tools_object, (fun objects -> objects.tools)
      ]
  in
  let length = Array.length entries in
  (* The previous segments stay when the chain where they end is the new
     messages' there; the turns after them can stay only then. *)
  let kept_segment, from, previous_turns, previous_open =
    match previous with
    | None -> None, 0, [], []
    | Some previous ->
      let previous_open = List.filter present previous.history.open_messages in
      (match previous.history.segment with
       | None -> None, 0, previous.history.turns, previous_open
       | Some segment
         when present segment.segment
              && segment.segment_messages <= length
              && String.equal chains.(segment.segment_messages) segment.segment_chain ->
         Some segment, segment.segment_messages, previous.history.turns, previous_open
       | Some _ -> None, 0, [], previous_open)
  in
  let kept, restored, covered = kept_turns ~absent ~from entries chains previous_turns in
  let rest = Array.to_list (Array.sub entries covered (length - covered)) in
  let closed, open_messages, written =
    match boundary, rest with
    | Turn_closes, [] -> kept, [], []
    | Turn_closes, (_ :: _ as closing) ->
      let bytes = bundle_bytes closing in
      let bundle = digest_of_bytes bytes in
      ( kept @ [ { bundle; messages = List.length closing; chain = chains.(length) } ]
      , []
      , [ bundle, bytes ] )
    | Turn_continues, open_entries ->
      ( kept
      , List.map (fun entry -> entry.digest) open_entries
      , unwritten_open_objects ~previous_open open_entries )
  in
  let segment, turns, segments = pack kept_segment closed [] in
  remember_plan memo ~shared messages entries chains;
  let head =
    { header =
        { session_id = decoded_header.session_id
        ; turn_count = decoded_header.turn_count
        ; created_at = decoded_header.created_at
        }
    ; header_json
    ; header_objects
    ; history = { segment; turns; open_messages }
    }
  in
  Ok
    { objects = header_writes @ restored @ segments @ written
    ; head_bytes = Yojson.Safe.to_string (head_json head)
    ; head
    ; content =
        content_digest_of
          ~header_bytes:(content_header_bytes ~header_json ~header_objects)
          ~chain:chains.(length)
    ; decoded =
        { decoded_header with
          messages = Array.to_list (Array.map (fun (entry : entry) -> entry.decoded) entries)
        }
    }
;;

let content_digest memo (cp : Checkpoint_types.t) =
  let* (before_messages, after_messages), _decoded_header =
    Checkpoint_codec.validated_fields_around_messages cp
  in
  let* header_json, system_prompt_json, tools_json =
    split_header ~before_messages ~after_messages
  in
  let messages = Array.of_list cp.messages in
  let* (_ : int), (_ : entry array), chains = entries_and_chains memo messages in
  let header_objects =
    { system_prompt = fst (object_of_json system_prompt_json); tools = fst (object_of_json tools_json) }
  in
  Ok
    (content_digest_of
       ~header_bytes:(content_header_bytes ~header_json ~header_objects)
       ~chain:chains.(Array.length messages))
;;

(* ── Loading ────────────────────────────────────────────── *)

type load_error =
  | Head_invalid of string
  | Checkpoint_invalid of Error.t
  | Object_missing of digest
  | Object_unreadable of
      { digest : digest
      ; detail : string
      }
  | Object_digest_mismatch of
      { expected : digest
      ; actual : digest
      }
  | Bundle_invalid of
      { bundle : digest
      ; detail : string
      }
  | Turn_mismatch of
      { bundle : digest
      ; detail : string
      }
  | Message_invalid of
      { digest : digest
      ; detail : string
      }
  | Segment_invalid of
      { segment : digest
      ; detail : string
      }
  | Header_object_invalid of
      { digest : digest
      ; detail : string
      }

let load_error_to_string = function
  | Head_invalid detail -> "checkpoint head is invalid: " ^ detail
  | Checkpoint_invalid error -> "checkpoint head is invalid: " ^ Error.to_string error
  | Object_missing digest -> "checkpoint object is missing: " ^ digest
  | Object_unreadable { digest; detail } ->
    Printf.sprintf "checkpoint object %s could not be read: %s" digest detail
  | Object_digest_mismatch { expected; actual } ->
    Printf.sprintf "checkpoint object %s holds bytes with digest %s" expected actual
  | Bundle_invalid { bundle; detail } ->
    Printf.sprintf "checkpoint bundle %s is invalid: %s" bundle detail
  | Turn_mismatch { bundle; detail } ->
    Printf.sprintf "checkpoint bundle %s does not match its turn: %s" bundle detail
  | Message_invalid { digest; detail } ->
    Printf.sprintf "checkpoint message %s is invalid: %s" digest detail
  | Segment_invalid { segment; detail } ->
    Printf.sprintf "checkpoint turn segment %s is invalid: %s" segment detail
  | Header_object_invalid { digest; detail } ->
    Printf.sprintf "checkpoint header object %s is invalid: %s" digest detail
;;

(* Exactly the listed fields, each once, in any order. *)
let exact_fields ~what expected fields =
  let names = List.map fst fields in
  let sorted = List.sort String.compare names in
  if List.equal String.equal sorted (List.sort String.compare expected)
  then Ok ()
  else
    Error
      (Printf.sprintf "%s fields are [%s], expected [%s]" what (String.concat "," names)
         (String.concat "," expected))
;;

let string_field ~what fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (Printf.sprintf "%s.%s must be a string" what name)
;;

let int_field ~what fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ | None -> Error (Printf.sprintf "%s.%s must be an integer" what name)
;;

let list_field ~what fields name =
  match List.assoc_opt name fields with
  | Some (`List values) -> Ok values
  | Some _ | None -> Error (Printf.sprintf "%s.%s must be an array" what name)
;;

let map_result f values =
  let rec go rev = function
    | [] -> Ok (List.rev rev)
    | value :: rest ->
      let* mapped = f value in
      go (mapped :: rev) rest
  in
  go [] values
;;

let turn_of_json = function
  | `Assoc fields ->
    let what = "turn" in
    let* () = exact_fields ~what [ "bundle"; "messages"; "chain" ] fields in
    let* bundle = Result.bind (string_field ~what fields "bundle") digest_of_hex in
    let* messages = int_field ~what fields "messages" in
    let* chain = Result.bind (string_field ~what fields "chain") chain_of_hex in
    if messages < 1
    then Error "turn.messages must be at least 1"
    else Ok { bundle; messages; chain }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "turn must be an object"
;;

let open_of_json ~what fields =
  Result.bind
    (list_field ~what fields "open")
    (map_result (function
       | `String digest -> digest_of_hex digest
       | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
         Error (what ^ ".open holds a value that is not a digest")))
;;

let segment_ref_of_json = function
  | `Null -> Ok None
  | `Assoc fields ->
    let what = "history.segment" in
    let* () = exact_fields ~what [ "segment"; "messages"; "chain" ] fields in
    let* segment = Result.bind (string_field ~what fields "segment") digest_of_hex in
    let* segment_messages = int_field ~what fields "messages" in
    let* segment_chain = Result.bind (string_field ~what fields "chain") chain_of_hex in
    if segment_messages < turns_per_segment
    then Error "history.segment holds fewer messages than one segment has turns"
    else Ok (Some { segment; segment_messages; segment_chain })
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "history.segment must be null or an object"
;;

(* A head names fewer closed turns than a segment holds: a save packs the
   rest into segments. *)
let history_of_json = function
  | `Assoc fields ->
    let what = "history" in
    let* () = exact_fields ~what [ "segment"; "turns"; "open" ] fields in
    let* segment =
      match List.assoc_opt "segment" fields with
      | Some segment -> segment_ref_of_json segment
      | None -> Error "history.segment is missing"
    in
    let* turns = Result.bind (list_field ~what fields "turns") (map_result turn_of_json) in
    let* open_messages = open_of_json ~what fields in
    if List.length turns >= turns_per_segment
    then Error (Printf.sprintf "history.turns holds %d turns, a segment's worth or more" (List.length turns))
    else (
      (* Each part was checked as nonnegative above. Check the sum without
         overflowing before [message_count] is used to answer from the head. *)
      let add_count total count =
        if count > max_int - total
        then Error "history message count exceeds the integer range"
        else Ok (total + count)
      in
      let initial =
        match segment with
        | None -> 0
        | Some segment -> segment.segment_messages
      in
      let* closed =
        List.fold_left
          (fun sum (turn : turn) ->
             let* total = sum in
             add_count total turn.messages)
          (Ok initial) turns
      in
      let* (_ : int) = add_count closed (List.length open_messages) in
      Ok { segment; turns; open_messages })
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "history must be an object"
;;

let header_objects_of_json = function
  | `Assoc fields ->
    let what = "head.header_objects" in
    let* () = exact_fields ~what [ system_prompt_field; tools_field ] fields in
    let* system_prompt = Result.bind (string_field ~what fields system_prompt_field) digest_of_hex in
    let* tools = Result.bind (string_field ~what fields tools_field) digest_of_hex in
    Ok { system_prompt; tools }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "head.header_objects must be an object"
;;

let segment_of_string ~digest bytes =
  let invalid detail = Error (Segment_invalid { segment = digest; detail }) in
  match Yojson.Safe.from_string bytes with
  | exception Yojson.Json_error detail -> invalid ("not JSON: " ^ detail)
  | `Assoc fields ->
    let what = "segment" in
    (match
       let* () = exact_fields ~what [ "previous"; "turns" ] fields in
       let* previous =
         match List.assoc_opt "previous" fields with
         | None -> Error "segment.previous is missing"
         | Some `Null -> Ok None
         | Some (`String previous) -> Result.map Option.some (digest_of_hex previous)
         | Some (`Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) ->
           Error "segment.previous must be null or a digest"
       in
       let* segment_turns = Result.bind (list_field ~what fields "turns") (map_result turn_of_json) in
       if List.length segment_turns <> turns_per_segment
       then
         Error
           (Printf.sprintf "segment holds %d turns, not %d" (List.length segment_turns)
              turns_per_segment)
       else Ok { previous; segment_turns }
     with
     | Ok segment -> Ok segment
     | Error detail -> invalid detail)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    invalid "segment must be an object"
;;

(* The [checkpoint_version] a document names: a head's in its checkpoint
   field, any other document's at its top. It is read before the head's
   shape, so the hard cut and a later binary's head (another field, another
   format) read as their version, not as damage. *)
let named_version fields json =
  match List.mem_assoc "format" fields, List.assoc_opt "checkpoint" fields with
  | true, Some checkpoint -> Checkpoint_codec.checkpoint_json_version checkpoint
  | true, None | false, (Some _ | None) -> Checkpoint_codec.checkpoint_json_version json
;;

(* The full checkpoint header: the head's fields with the two object fields
   put back. The decoder reads fields by name. *)
let full_header_json ~header_fields ~system_prompt ~tools =
  `Assoc (header_fields @ [ system_prompt_field, system_prompt; tools_field, tools ])
;;

let head_of_fields fields =
  let invalid detail = Error (Head_invalid detail) in
  let what = "head" in
  match exact_fields ~what [ "format"; "checkpoint"; "header_objects"; "history" ] fields with
  | Error detail -> invalid detail
  | Ok () ->
    (match
       ( string_field ~what fields "format"
       , List.assoc_opt "checkpoint" fields
       , List.assoc_opt "header_objects" fields
       , List.assoc_opt "history" fields )
     with
     | Error detail, _, _, _ -> invalid detail
     | Ok format, _, _, _ when not (String.equal format head_format) ->
       invalid (Printf.sprintf "head.format is %S, expected %S" format head_format)
     | Ok _, None, _, _ | Ok _, _, None, _ | Ok _, _, _, None -> invalid "a head field is missing"
     | Ok _, Some header_json, Some objects_json, Some history_json ->
       (match header_json with
        | `Assoc header_fields when List.exists is_object_field header_fields ->
          invalid "head.checkpoint holds a field the head keeps as an object"
        | `Assoc header_fields ->
          (* The object fields' values are not here; placeholders let the
             codec check every other field. *)
          (match
             ( Checkpoint_codec.of_json
                 (full_header_json ~header_fields ~system_prompt:`Null ~tools:(`List []))
             , header_objects_of_json objects_json
             , history_of_json history_json )
           with
           | Error error, _, _ -> Error (Checkpoint_invalid error)
           | Ok _, Error detail, _ | Ok _, Ok _, Error detail -> invalid detail
           | Ok checkpoint, Ok header_objects, Ok history ->
             (match checkpoint.messages with
              | [] ->
                Ok
                  { header =
                      { session_id = checkpoint.session_id
                      ; turn_count = checkpoint.turn_count
                      ; created_at = checkpoint.created_at
                      }
                  ; header_json
                  ; header_objects
                  ; history
                  }
              | _ :: _ -> invalid "head.checkpoint.messages must be empty"))
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
          invalid "head.checkpoint must be an object"))
;;

let head_of_string text =
  let invalid detail = Error (Head_invalid detail) in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error detail -> invalid ("not JSON: " ^ detail)
  | `Assoc fields as json ->
    (match named_version fields json with
     | Ok got when got <> Checkpoint_types.checkpoint_version ->
       Error
         (Checkpoint_invalid
            (Error.Serialization
               (VersionMismatch { expected = Checkpoint_types.checkpoint_version; got })))
     | Ok _ | Error _ ->
       if List.mem_assoc "format" fields
       then head_of_fields fields
       else
         invalid
           (Printf.sprintf "document fields are [%s], not a head"
              (String.concat "," (List.map fst fields))))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    invalid "head must be an object"
;;

let read_checked ~read_object digest =
  match read_object digest with
  | Error detail -> Error (Object_unreadable { digest; detail })
  | Ok None -> Error (Object_missing digest)
  | Ok (Some bytes) ->
    let actual = digest_of_bytes bytes in
    if String.equal actual digest
    then Ok bytes
    else Error (Object_digest_mismatch { expected = digest; actual })
;;

let decode_message ~digest bytes =
  Checkpoint_codec.decode_written_bytes ~decode:Checkpoint_codec.message_of_json bytes
  |> Result.map_error (fun error -> Message_invalid { digest; detail = Error.to_string error })
;;

let bundle_header_entry = function
  | `Assoc fields ->
    let what = "bundle message" in
    let* () = exact_fields ~what [ "sha256"; "bytes" ] fields in
    let* digest = Result.bind (string_field ~what fields "sha256") digest_of_hex in
    let* length = int_field ~what fields "bytes" in
    if length < 0 then Error "bundle message bytes must not be negative" else Ok (digest, length)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "bundle message must be an object"
;;

(* The bundle's messages as entries, every slice checked against the header,
   each message decoded from its own bytes. *)
let bundle_entries ~bundle bytes =
  let invalid detail = Bundle_invalid { bundle; detail } in
  match String.index_opt bytes '\n' with
  | None -> Error (invalid "no header line")
  | Some newline ->
    let* header =
      match Yojson.Safe.from_string (String.sub bytes 0 newline) with
      | exception Yojson.Json_error detail -> Error (invalid ("header is not JSON: " ^ detail))
      | `Assoc fields ->
        Result.map_error invalid
          (let* () = exact_fields ~what:"bundle" [ "messages" ] fields in
           Result.bind (list_field ~what:"bundle" fields "messages") (map_result bundle_header_entry))
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        Error (invalid "header must be an object")
    in
    let rec slices offset rev = function
      | [] ->
        if offset = String.length bytes
        then Ok (List.rev rev)
        else Error (invalid "bytes follow the last listed message")
      | (digest, length) :: rest ->
        (* [length] comes from the bundle header. Compare against the
           remaining bytes before adding it to [offset]: a large valid JSON
           integer can otherwise overflow and make the index negative. *)
        if length >= String.length bytes - offset
        then Error (invalid "a listed message runs past the end of the bundle")
        else if not (Char.equal bytes.[offset + length] '\n')
        then Error (invalid (Printf.sprintf "the message at byte %d does not end its line" offset))
        else (
          let actual = sha256_hex ~off:offset ~len:length bytes in
          if not (String.equal actual digest)
          then Error (invalid (Printf.sprintf "message at byte %d has digest %s, header names %s" offset actual digest))
          else (
            let message_bytes = String.sub bytes offset length in
            let* decoded = decode_message ~digest message_bytes in
            slices (offset + length + 1) ({ bytes = message_bytes; digest; decoded } :: rev) rest))
    in
    slices (newline + 1) [] header
;;

let header_object ~read_object digest =
  let* bytes = read_checked ~read_object digest in
  match Yojson.Safe.from_string bytes with
  | exception Yojson.Json_error detail ->
    Error (Header_object_invalid { digest; detail = "not JSON: " ^ detail })
  | json -> Ok json
;;

let system_prompt ~read_object head =
  let digest = head.header_objects.system_prompt in
  let* json = header_object ~read_object digest in
  match json with
  | `Null -> Ok None
  | `String prompt -> Ok (Some prompt)
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error (Header_object_invalid { digest; detail = "a system prompt is a string or null" })
;;

let find_last ~read_object head find =
  let first_found = function
    | Some _ as found -> fun (_ : unit -> ('a option, load_error) result) -> Ok found
    | None -> fun next -> next ()
  in
  let rec in_open = function
    | [] -> Ok None
    | digest :: older ->
      let* bytes = read_checked ~read_object digest in
      let* message = decode_message ~digest bytes in
      first_found (find message) (fun () -> in_open older)
  in
  let rec in_turns = function
    | [] -> Ok None
    | (turn : turn) :: older ->
      let* bytes = read_checked ~read_object turn.bundle in
      let* entries = bundle_entries ~bundle:turn.bundle bytes in
      let held = List.length entries in
      if held <> turn.messages
      then
        Error
          (Turn_mismatch
             { bundle = turn.bundle
             ; detail = Printf.sprintf "it holds %d messages, the turn names %d" held turn.messages
             })
      else
        first_found
          (List.find_map (fun (entry : entry) -> find entry.decoded) (List.rev entries))
          (fun () -> in_turns older)
  in
  let rec in_segments = function
    | None -> Ok None
    | Some digest ->
      let* bytes = read_checked ~read_object digest in
      let* segment = segment_of_string ~digest bytes in
      let* found = in_turns (List.rev segment.segment_turns) in
      first_found found (fun () -> in_segments segment.previous)
  in
  let* found = in_open (List.rev head.history.open_messages) in
  first_found found (fun () ->
    let* found = in_turns (List.rev head.history.turns) in
    first_found found (fun () ->
      in_segments (Option.map (fun (segment : segment_ref) -> segment.segment) head.history.segment)))
;;

let load memo ~read_object head =
  let next = Entries.create 0 in
  let* system_prompt = header_object ~read_object head.header_objects.system_prompt in
  let* tools = header_object ~read_object head.header_objects.tools in
  (* The segments' turns, oldest first, read from the last segment back. *)
  let rec segment_turns later = function
    | None -> Ok later
    | Some digest ->
      let* bytes = read_checked ~read_object digest in
      let* segment = segment_of_string ~digest bytes in
      segment_turns (segment.segment_turns @ later) segment.previous
  in
  let* older_turns =
    segment_turns [] (Option.map (fun (segment : segment_ref) -> segment.segment) head.history.segment)
  in
  (* Each message's entry with the chain through it, newest first: the turns'
     values come from checking them against the head, the open messages'
     from stepping on. *)
  let rec load_turns chain count rev_loaded = function
    | [] -> Ok (chain, count, rev_loaded)
    | (turn : turn) :: turns ->
      let* bytes = read_checked ~read_object turn.bundle in
      let* entries = bundle_entries ~bundle:turn.bundle bytes in
      let held = List.length entries in
      if held <> turn.messages
      then
        Error
          (Turn_mismatch
             { bundle = turn.bundle
             ; detail = Printf.sprintf "it holds %d messages, the turn names %d" held turn.messages
             })
      else (
        let chain, rev_loaded =
          List.fold_left
            (fun (chain, rev_loaded) entry ->
               let chain = chain_step chain entry.digest in
               chain, (entry, chain) :: rev_loaded)
            (chain, rev_loaded) entries
        in
        if not (String.equal chain turn.chain)
        then Error (Turn_mismatch { bundle = turn.bundle; detail = "its messages give another chain" })
        else load_turns chain (count + held) rev_loaded turns)
  in
  let* chain, count, rev_loaded = load_turns chain_start 0 [] older_turns in
  let* () =
    match head.history.segment with
    | None -> Ok ()
    | Some segment ->
      if count = segment.segment_messages && String.equal chain segment.segment_chain
      then Ok ()
      else
        Error
          (Segment_invalid
             { segment = segment.segment
             ; detail = "its turns give another message count or chain than the head names"
             })
  in
  let* chain, (_ : int), rev_loaded = load_turns chain count rev_loaded head.history.turns in
  let* (_ : chain), rev_loaded =
    List.fold_left
      (fun acc digest ->
         let* chain, rev_loaded = acc in
         let* bytes = read_checked ~read_object digest in
         let* decoded = decode_message ~digest bytes in
         let chain = chain_step chain digest in
         Ok (chain, ({ bytes; digest; decoded }, chain) :: rev_loaded))
      (Ok (chain, rev_loaded))
      head.history.open_messages
  in
  let* header =
    match head.header_json with
    | `Assoc header_fields ->
      Checkpoint_codec.of_json (full_header_json ~header_fields ~system_prompt ~tools)
      |> Result.map_error (fun error -> Checkpoint_invalid error)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error (Head_invalid "head.checkpoint must be an object")
  in
  let loaded = Array.of_list (List.rev rev_loaded) in
  let entries = Array.map fst loaded in
  let chains = Array.make (Array.length loaded + 1) chain_start in
  Array.iteri (fun index ((_ : entry), chain) -> chains.(index + 1) <- chain) loaded;
  Array.iter (fun (entry : entry) -> Entries.replace next entry.decoded entry) entries;
  let messages = Array.map (fun (entry : entry) -> entry.decoded) entries in
  memo.entries <- next;
  memo.last <- Some { last_messages = messages; last_entries = entries; last_chains = chains };
  Ok { header with messages = Array.to_list messages }
;;
