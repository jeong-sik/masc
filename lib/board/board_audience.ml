include Board_types

(* The tokenization grammar (edge trimming, whitespace splitting, [@@]
   selectors, [@] target candidates) is shared with the Keeper write
   boundary through [Board_addressing] (issue #25601).  This module owns the
   Board audience policy.  A name written after [@] is only a candidate; it
   becomes a target when the [Recipient_lookup] installed at server start
   declares it, and it is prose otherwise (RFC-at-name-resolves-to-declared-
   recipient). *)

type explicit_address =
  | No_explicit_address
  | Explicit_targets of Agent_id.t list
  | Broadcast_all
  | Unsupported_broadcast of string list

let compare_agent_id left right =
  String.compare (Agent_id.to_string left) (Agent_id.to_string right)
;;

(* What the text asks for, and the candidates the lookup did not declare.

   A token an [Agent_id] could never be is prose, not a mention that went
   wrong: [Recipient_resolution.Candidate.of_string] keeps ASCII letters,
   digits, [_] and [-] and drops the rest, so "@internals/libs/errors/x.",
   "@types/node" and a bare "@" are neither targets nor failed addresses.

   A candidate nobody declares is prose as well, and it comes back in the
   second component so the author can see the name did not reach anyone: the
   "check" in "@check" is a dune alias, "@alcie" is a misspelling of "@alice".
   Neither rejects the post.  A lookup that cannot answer does refuse it,
   because storing "no recipient" for a name that may be declared would lose
   the address for good. *)
let address_of_text ~lookup content =
  match Board_addressing.parse content with
  | Board_addressing.Broadcast_all -> Ok (Broadcast_all, [])
  | Board_addressing.Unsupported_broadcast selectors ->
    (* A bare [@@] parses as the empty selector. Empty is prose by the same
       argument; a named one is an author who meant to broadcast and named a
       selector that does not exist, which is worth refusing. *)
    (match List.filter (fun selector -> not (String.equal selector "")) selectors with
     | [] -> Ok (No_explicit_address, [])
     | named -> Ok (Unsupported_broadcast named, []))
  | Board_addressing.No_explicit_address -> Ok (No_explicit_address, [])
  | Board_addressing.Raw_targets raw ->
    let candidates = List.filter_map Recipient_resolution.Candidate.of_string raw in
    (match Recipient_lookup.resolve lookup candidates with
     | Error detail -> Error (Recipient_lookup_failed detail)
     | Ok { Recipient_lookup.recipients; unresolved } ->
       (match List.sort_uniq compare_agent_id recipients with
        | [] -> Ok (No_explicit_address, unresolved)
        | _ :: _ as recipients -> Ok (Explicit_targets recipients, unresolved)))
;;

(* The Keeper side reads the text again for its explicit-mention flag
   (RFC section 3.4); it asks for names the way an author wrote them and does
   not decide who receives the post. *)
let direct_targets_of_text content =
  match Board_addressing.parse content with
  | Board_addressing.Raw_targets candidates ->
    candidates
    |> List.filter_map (fun candidate ->
      match Agent_id.parse candidate with
      | Ok target -> Some target
      | Error _ -> None)
    |> List.sort_uniq compare_agent_id
  | Board_addressing.(Broadcast_all | Unsupported_broadcast _ | No_explicit_address) -> []
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

let audience_of_address ~visibility ~unaddressed = function
  | Explicit_targets targets -> Ok (Targets targets)
  | Broadcast_all ->
    (match visibility with
     | Direct -> Error (Validation_error "Direct Board posts cannot broadcast")
     | Public | Unlisted | Internal -> Ok Broadcast)
  | Unsupported_broadcast selectors -> Error (unsupported_broadcast_error selectors)
  | No_explicit_address -> unaddressed ()
;;

(* An unaddressed post's audience follows its visibility. Public and
   Internal posts start a conversation any keeper may discover. Unlisted
   means "not in feeds, but accessible" (Board_types), and a keeper's feed
   is its attention collector: an unaddressed Unlisted post is thread
   activity, reaching a keeper only by explicit address or by joining its
   thread, and no keeper pays an attention judgment for it. The runtime
   writes verification requests, verdict receipts, and fusion results this
   way. A rejection reaches the producer as a typed stimulus and a fusion
   result reaches its requester as [Fusion_completed]; an approval wakes
   nobody — the task leaves the backlog as Done, and the producer's current
   task was already cleared when it submitted. A stalled review stays
   Internal because the Board is its only path to the producer. *)
let audience_for_post ~lookup ~post_kind ~visibility ~title ~content =
  (* A system post is written by platform code, which decides who it reaches
     from its visibility. Its text carries evidence such as evaluator and
     commit messages, so reading an address out of it would let that text
     wake a keeper or reject the post. It also never asks the lookup: a
     Keeper whose settings cannot be read must not stop a system post. *)
  let address =
    match post_kind with
    | System_post -> Ok (No_explicit_address, [])
    | Human_post | Automation_post ->
      address_of_text ~lookup (address_text ~title ~content)
  in
  Result.bind address (fun (address, unresolved) ->
    audience_of_address ~visibility address ~unaddressed:(fun () ->
      match visibility with
      | Direct ->
        (* The refusal is the only answer this write gives, so it carries the
           names that were written and not declared. *)
        Error
          (Validation_error
             (match unresolved with
              | [] -> "Direct Board posts require explicit targets"
              | _ :: _ ->
                Printf.sprintf
                  "Direct Board posts require a declared target, and no Keeper declares %s"
                  (String.concat ", " (List.map (Printf.sprintf "@%s") unresolved))))
      | Unlisted -> Ok Thread_participants
      | Public | Internal -> Ok Discoverable)
    |> Result.map (fun audience -> audience, unresolved))
;;

let audience_for_comment ~lookup ~content =
  Result.bind (address_of_text ~lookup content) (fun (address, unresolved) ->
    (match address with
     | Explicit_targets targets -> Ok (Targets targets)
     | Broadcast_all -> Ok Broadcast
     | Unsupported_broadcast selectors -> Error (unsupported_broadcast_error selectors)
     | No_explicit_address -> Ok Thread_participants)
    |> Result.map (fun audience -> audience, unresolved))
;;

let audience_for_reaction = Thread_participants
let audience_for_vote = Thread_participants

let audience_label = function
  | Targets _ -> "targets"
  | Broadcast -> "broadcast"
  | Thread_participants -> "thread_participants"
  | Discoverable -> "discoverable"
;;

let to_yojson = function
  | Targets targets ->
    `Assoc [ "kind", `String "targets"
           ; "targets", `List (List.map (fun id -> `String (Agent_id.to_string id)) targets) ]
  | Broadcast -> `Assoc [ "kind", `String "broadcast" ]
  | Thread_participants -> `Assoc [ "kind", `String "thread_participants" ]
  | Discoverable -> `Assoc [ "kind", `String "discoverable" ]
;;

let of_yojson = function
  | `Assoc fields ->
    (match List.sort (fun (a, _) (b, _) -> String.compare a b) fields with
     | [ "kind", `String "targets"; "targets", `List (_ :: _ as values) ] ->
       let rec parse acc = function
         | [] -> Some (Targets (List.sort_uniq compare_agent_id acc))
         | `String value :: rest ->
           (match Agent_id.of_string value with
            | Ok id -> parse (id :: acc) rest
            | Error _ -> None)
         | _ -> None
       in
       parse [] values
     | [ "kind", `String "broadcast" ] -> Some Broadcast
     | [ "kind", `String "thread_participants" ] -> Some Thread_participants
     | [ "kind", `String "discoverable" ] -> Some Discoverable
     | _ -> None)
  | _ -> None
;;
