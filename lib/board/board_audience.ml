include Board_types

(* The tokenization grammar (edge trimming, whitespace splitting, [@@]
   selectors, [@] target candidates) is shared with the Keeper write
   boundary through [Board_addressing] (issue #25601).  This module owns
   only the Board identity policy: candidates are validated through
   [Agent_id.of_string], which is case-sensitive, and invalid candidates
   fail closed as [Malformed_targets]. *)

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
  match Board_addressing.parse content with
  | Board_addressing.Broadcast_all -> Broadcast_all
  | Board_addressing.Unsupported_broadcast selectors ->
    Unsupported_broadcast selectors
  | Board_addressing.No_explicit_address -> No_explicit_address
  | Board_addressing.Raw_targets candidates ->
    let targets, malformed =
      List.fold_left
        (fun (targets, malformed) candidate ->
          match Agent_id.of_string candidate with
          | Ok target -> target :: targets, malformed
          | Error _ ->
            (* Report the original [@]-prefixed token so the error message
               shows what the author typed. *)
            targets, (Board_addressing.target_prefix ^ candidate) :: malformed)
        ([], [])
        candidates
    in
    (match List.sort_uniq String.compare malformed with
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
