include Board_types

let trim_token_edges value =
  let is_word = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '@' | '_' | '-' -> true
    | _ -> false
  in
  let length = String.length value in
  let first = ref 0 in
  let last = ref (length - 1) in
  while !first < length && not (is_word value.[!first]) do
    incr first
  done;
  while !last >= !first && not (is_word value.[!last]) do
    decr last
  done;
  if !last < !first then "" else String.sub value !first (!last - !first + 1)
;;

let normalized_tokens content =
  content
  |> String.map (function
    | '\t' | '\n' | '\r' -> ' '
    | character -> character)
  |> String.split_on_char ' '
  |> List.map trim_token_edges
  |> List.filter (fun token -> not (String.equal token ""))
;;

type explicit_address =
  | No_explicit_address
  | Explicit_targets of Agent_id.t list
  | Broadcast_all
  | Unsupported_broadcast of string list
  | Malformed_targets of string list

let compare_agent_id left right =
  String.compare (Agent_id.to_string left) (Agent_id.to_string right)
;;

let explicit_address_of_text content =
  let tokens = normalized_tokens content in
  let selectors =
    tokens
    |> List.filter_map (fun token ->
      if String.length token >= 2 && String.starts_with ~prefix:"@@" token
      then
        Some
          (String.sub token 2 (String.length token - 2)
           |> String.lowercase_ascii)
      else None)
    |> List.sort_uniq String.compare
  in
  if selectors <> [] && List.for_all (String.equal "all") selectors
  then Broadcast_all
  else if selectors <> []
  then Unsupported_broadcast selectors
  else (
    let targets, malformed =
      List.fold_left
        (fun (targets, malformed) token ->
          if Char.equal token.[0] '@'
             && not (String.starts_with ~prefix:"@@" token)
          then
            let candidate = String.sub token 1 (String.length token - 1) in
            match Agent_id.of_string candidate with
            | Ok target -> target :: targets, malformed
            | Error _ -> targets, token :: malformed
          else targets, malformed)
        ([], [])
        tokens
    in
    match List.sort_uniq String.compare malformed with
    | _ :: _ as malformed -> Malformed_targets malformed
    | [] ->
      (match List.sort_uniq compare_agent_id targets with
       | [] -> No_explicit_address
       | _ :: _ as targets -> Explicit_targets targets))
;;

let direct_targets_of_text content =
  match explicit_address_of_text content with
  | Explicit_targets targets -> targets
  | ( No_explicit_address
    | Broadcast_all
    | Unsupported_broadcast _
    | Malformed_targets _ ) -> []
;;

let address_text ~title ~content =
  String.concat
    "\n"
    (List.filter
       (fun value -> not (String.equal (String.trim value) ""))
       [ title; content ])
;;

let unsupported_broadcast_error selectors =
  Validation_error
    (Printf.sprintf
       "unsupported Board broadcast selector(s): %s"
       (String.concat ", " (List.map (Printf.sprintf "@@%s") selectors)))
;;

let malformed_targets_error targets =
  Validation_error
    (Printf.sprintf
       "invalid Board target token(s): %s"
       (String.concat ", " targets))
;;

let audience_of_address ~visibility ~unaddressed = function
  | Explicit_targets targets -> Ok (Targets targets)
  | Broadcast_all ->
    (match visibility with
     | Direct -> Error (Validation_error "Direct Board posts cannot broadcast")
     | Public | Unlisted | Internal -> Ok Broadcast)
  | Unsupported_broadcast selectors -> Error (unsupported_broadcast_error selectors)
  | Malformed_targets targets -> Error (malformed_targets_error targets)
  | No_explicit_address -> unaddressed ()
;;

let audience_for_post ~visibility ~title ~content =
  explicit_address_of_text (address_text ~title ~content)
  |> audience_of_address ~visibility ~unaddressed:(fun () ->
    match visibility with
    | Direct -> Error (Validation_error "Direct Board posts require explicit targets")
    | Public | Unlisted | Internal -> Ok Discoverable)
;;

let audience_for_comment ~content =
  match explicit_address_of_text content with
  | Explicit_targets targets -> Ok (Targets targets)
  | Broadcast_all -> Ok Broadcast
  | Unsupported_broadcast selectors -> Error (unsupported_broadcast_error selectors)
  | Malformed_targets targets -> Error (malformed_targets_error targets)
  | No_explicit_address -> Ok Thread_participants
;;

let audience_for_reaction = Thread_participants

let audience_label = function
  | Targets _ -> "targets"
  | Broadcast -> "broadcast"
  | Thread_participants -> "thread_participants"
  | Discoverable -> "discoverable"
;;
