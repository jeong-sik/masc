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

type history =
  { turns : turn list
  ; open_messages : digest list
  }

type head =
  { checkpoint : Checkpoint_types.t
  ; history : history
  }

let message_count history =
  List.fold_left (fun total turn -> total + turn.messages) 0 history.turns
  + List.length history.open_messages
;;

let head_format = "masc.checkpoint.head"

let header_json ~before_messages ~after_messages =
  `Assoc (before_messages @ ((Checkpoint_codec.messages_field, `List []) :: after_messages))
;;

let history_chain history =
  let closed =
    match List.rev history.turns with
    | [] -> chain_start
    | last :: _ -> last.chain
  in
  List.fold_left chain_step closed history.open_messages
;;

let head_content_digest head =
  let before_messages, after_messages =
    Checkpoint_codec.checkpoint_fields_around_messages head.checkpoint
  in
  content_digest_of
    ~header_bytes:(Yojson.Safe.to_string (header_json ~before_messages ~after_messages))
    ~chain:(history_chain head.history)
;;

let turn_to_json turn =
  `Assoc
    [ "bundle", `String turn.bundle
    ; "messages", `Int turn.messages
    ; "chain", `String turn.chain
    ]
;;

let history_to_json history =
  `Assoc
    [ "turns", `List (List.map turn_to_json history.turns)
    ; "open", `List (List.map (fun digest -> `String digest) history.open_messages)
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

type memo = { mutable entries : entry Entries.t }

let create_memo () = { entries = Entries.create 0 }

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

let head_json ~header history =
  `Assoc
    [ "format", `String head_format
    ; "checkpoint", header
    ; "history", history_to_json history
    ]
;;

(* [n] entries from [entries] with the chain stepped over them, or [None] when
   fewer remain. *)
let advance chain entries n =
  let rec go chain entries n =
    if n = 0
    then Some (chain, entries)
    else (
      match entries with
      | [] -> None
      | entry :: rest -> go (chain_step chain entry.digest) rest (n - 1))
  in
  go chain entries n
;;

(* The longest run of [previous] turns whose chain values the new messages
   reproduce at the same positions; a match there is a match of every message
   before it. *)
let kept_turns entries previous_turns =
  let rec keep rev_kept chain entries = function
    | [] -> List.rev rev_kept, chain, entries
    | turn :: turns ->
      (match advance chain entries turn.messages with
       | Some (chain', rest) when String.equal chain' turn.chain ->
         keep (turn :: rev_kept) chain' rest turns
       | Some _ | None -> List.rev rev_kept, chain, entries)
  in
  keep [] chain_start entries previous_turns
;;

module Digest_set = Set.Make (String)

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

let plan_save memo ?previous boundary (cp : Checkpoint_types.t) =
  let* (before_messages, after_messages), decoded_header =
    Checkpoint_codec.validated_fields_around_messages cp
  in
  let next = Entries.create (List.length cp.messages) in
  let rec encode rev_entries = function
    | [] -> Ok (List.rev rev_entries)
    | message :: rest ->
      let* entry = encoded_entry memo message in
      remember next message entry;
      encode (entry :: rev_entries) rest
  in
  let* entries = encode [] cp.messages in
  let previous_turns, previous_open =
    match previous with
    | None -> [], []
    | Some previous -> previous.turns, previous.open_messages
  in
  let kept, chain, rest = kept_turns entries previous_turns in
  let history, objects =
    match boundary, rest with
    | Turn_closes, [] -> { turns = kept; open_messages = [] }, []
    | Turn_closes, (_ :: _ as closing) ->
      let bytes = bundle_bytes closing in
      let bundle = digest_of_bytes bytes in
      let chain = List.fold_left (fun chain entry -> chain_step chain entry.digest) chain closing in
      ( { turns = kept @ [ { bundle; messages = List.length closing; chain } ]
        ; open_messages = []
        }
      , [ bundle, bytes ] )
    | Turn_continues, open_entries ->
      ( { turns = kept; open_messages = List.map (fun entry -> entry.digest) open_entries }
      , unwritten_open_objects ~previous_open open_entries )
  in
  memo.entries <- next;
  let header = header_json ~before_messages ~after_messages in
  Ok
    { objects
    ; head_bytes = Yojson.Safe.to_string (head_json ~header history)
    ; head = { checkpoint = decoded_header; history }
    ; content =
        content_digest_of
          ~header_bytes:(Yojson.Safe.to_string header)
          ~chain:(List.fold_left (fun chain (entry : entry) -> chain_step chain entry.digest) chain_start entries)
    ; decoded =
        { decoded_header with messages = List.map (fun (entry : entry) -> entry.decoded) entries }
    }
;;

let content_digest memo (cp : Checkpoint_types.t) =
  let* (before_messages, after_messages), _decoded_header =
    Checkpoint_codec.validated_fields_around_messages cp
  in
  let rec chain_over chain = function
    | [] -> Ok chain
    | message :: rest ->
      let* entry = encoded_entry memo message in
      chain_over (chain_step chain entry.digest) rest
  in
  let* chain = chain_over chain_start cp.messages in
  Ok
    (content_digest_of
       ~header_bytes:(Yojson.Safe.to_string (header_json ~before_messages ~after_messages))
       ~chain)
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

let history_of_json = function
  | `Assoc fields ->
    let what = "history" in
    let* () = exact_fields ~what [ "turns"; "open" ] fields in
    let* turns = Result.bind (list_field ~what fields "turns") (map_result turn_of_json) in
    let* open_messages =
      Result.bind
        (list_field ~what fields "open")
        (map_result (function
           | `String digest -> digest_of_hex digest
           | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
             Error "history.open holds a value that is not a digest"))
    in
    Ok { turns; open_messages }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "history must be an object"
;;

(* A document without [format] is not a head. One that names an earlier or
   later [checkpoint_version] is reported as that version, so a reader can
   tell the hard cut apart from damage. *)
let not_a_head fields json =
  match Checkpoint_codec.checkpoint_json_version json with
  | Ok got when got <> Checkpoint_types.checkpoint_version ->
    Error
      (Checkpoint_invalid
         (Error.Serialization
            (VersionMismatch { expected = Checkpoint_types.checkpoint_version; got })))
  | Ok _ | Error _ ->
    Error
      (Head_invalid
         (Printf.sprintf "document fields are [%s], not a head"
            (String.concat "," (List.map fst fields))))
;;

let head_of_string text =
  let invalid detail = Error (Head_invalid detail) in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error detail -> invalid ("not JSON: " ^ detail)
  | `Assoc fields as json when not (List.mem_assoc "format" fields) -> not_a_head fields json
  | `Assoc fields ->
    let what = "head" in
    (match exact_fields ~what [ "format"; "checkpoint"; "history" ] fields with
     | Error detail -> invalid detail
     | Ok () ->
       (match string_field ~what fields "format" with
        | Error detail -> invalid detail
        | Ok format when not (String.equal format head_format) ->
          invalid (Printf.sprintf "head.format is %S, expected %S" format head_format)
        | Ok _ ->
          (match List.assoc_opt "checkpoint" fields, List.assoc_opt "history" fields with
           | None, _ -> invalid "head.checkpoint is missing"
           | _, None -> invalid "head.history is missing"
           | Some checkpoint_json, Some history_json ->
             (match Checkpoint_codec.of_json checkpoint_json, history_of_json history_json with
              | Error error, _ -> Error (Checkpoint_invalid error)
              | Ok _, Error detail -> invalid detail
              | Ok checkpoint, Ok history ->
                (match checkpoint.messages with
                 | [] -> Ok { checkpoint; history }
                 | _ :: _ -> invalid "head.checkpoint.messages must be empty")))))
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
        if offset + length >= String.length bytes
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

let load memo ~read_object head =
  let next = Entries.create 0 in
  let rec load_turns chain rev_entries = function
    | [] -> Ok rev_entries
    | turn :: turns ->
      let* bytes = read_checked ~read_object turn.bundle in
      let* entries = bundle_entries ~bundle:turn.bundle bytes in
      let count = List.length entries in
      if count <> turn.messages
      then
        Error
          (Turn_mismatch
             { bundle = turn.bundle
             ; detail = Printf.sprintf "it holds %d messages, the turn names %d" count turn.messages
             })
      else (
        let chain = List.fold_left (fun chain entry -> chain_step chain entry.digest) chain entries in
        if not (String.equal chain turn.chain)
        then Error (Turn_mismatch { bundle = turn.bundle; detail = "its messages give another chain" })
        else load_turns chain (List.rev_append entries rev_entries) turns)
  in
  let* rev_entries = load_turns chain_start [] head.history.turns in
  let* rev_entries =
    List.fold_left
      (fun acc digest ->
         let* rev_entries = acc in
         let* bytes = read_checked ~read_object digest in
         let* decoded = decode_message ~digest bytes in
         Ok ({ bytes; digest; decoded } :: rev_entries))
      (Ok rev_entries)
      head.history.open_messages
  in
  let entries = List.rev rev_entries in
  List.iter (fun (entry : entry) -> Entries.replace next entry.decoded entry) entries;
  memo.entries <- next;
  Ok { head.checkpoint with messages = List.map (fun (entry : entry) -> entry.decoded) entries }
;;
