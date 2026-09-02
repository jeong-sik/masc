include Board_types

(* The tokenization grammar (edge trimming, whitespace splitting, [@@]
   selectors, [@] target candidates) is shared with the Keeper write
   boundary through [Board_addressing] (issue #25601).  This module owns
   only the Board identity policy: candidates are validated through
   [Agent_id.of_string], which is case-sensitive, and a candidate it rejects is
   read as prose rather than as a failed address. *)

type explicit_address =
  | No_explicit_address
  | Explicit_targets of Agent_id.t list
  | Broadcast_all
  | Unsupported_broadcast of string list

let compare_agent_id left right =
  String.compare (Agent_id.to_string left) (Agent_id.to_string right)
;;

(* A token an [Agent_id] could never be is prose, not a mention that went
   wrong. [Agent_id.of_string] checks shape only -- 1..64 of [a-zA-Z0-9._-]
   with one optional colon -- so every candidate it rejects fails on a
   character or a length no keeper name can have. Treating those as malformed
   addresses rejected the whole post, and the live log shows what was being
   rejected: a bare "@" five times, "@@" three times, and
   "@internals/libs/errors/asyncErrorHandler." once. Prose, an npm scope, a
   path. None was an attempt to address anyone.

   The case this used to protect is not the case it caught. A plausible
   misspelling -- "@alcie" for "@alice" -- passes the shape check, becomes a
   target, and matches no keeper on the read side, where each keeper filters a
   post's mentions against its own ids. That mention is lost silently today and
   still is after this change; catching it needs the keeper registry at the
   write boundary, which this does not add. What this removes is a rejection
   that fired only where there was nothing to protect. *)
let explicit_address_of_text content =
  match Board_addressing.parse content with
  | Board_addressing.Broadcast_all -> Broadcast_all
  | Board_addressing.Unsupported_broadcast selectors ->
    (* A bare [@@] parses as the empty selector. Empty is prose by the same
       argument; a named one is an author who meant to broadcast and named a
       selector that does not exist, which is worth refusing. *)
    (match List.filter (fun selector -> not (String.equal selector "")) selectors with
     | [] -> No_explicit_address
     | named -> Unsupported_broadcast named)
  | Board_addressing.No_explicit_address -> No_explicit_address
  | Board_addressing.Raw_targets candidates ->
    let targets =
      List.filter_map
        (fun candidate ->
           match Agent_id.of_string candidate with
           | Ok target -> Some target
           | Error _ -> None)
        candidates
    in
    (match List.sort_uniq compare_agent_id targets with
     | [] -> No_explicit_address
     | _ :: _ as targets -> Explicit_targets targets)
;;

let direct_targets_of_text content =
  match explicit_address_of_text content with
  | Explicit_targets targets -> targets
  | (No_explicit_address | Broadcast_all | Unsupported_broadcast _) -> []
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

(* An unaddressed post's audience depends on who wrote it. A person or a
   keeper (Human_post, Automation_post) starts a conversation anyone may
   discover. A System_post is a receipt the runtime writes about work that
   already has an owner — a verification verdict, a fusion result — and the
   owner is woken by its own typed stimulus, not by reading the Board. So a
   receipt is thread activity: whoever joins its thread hears it, and nobody
   is invited by discovery. Measured 2026-09-01: verifier_exact and system
   receipts produced 429 of 1,784 per-keeper attention judgments in 24 h,
   303 of them not_relevant. *)
let audience_for_post ~visibility ~post_kind ~title ~content =
  explicit_address_of_text (address_text ~title ~content)
  |> audience_of_address ~visibility ~unaddressed:(fun () ->
    match visibility, post_kind with
    | Direct, (Human_post | Automation_post | System_post) ->
      Error (Validation_error "Direct Board posts require explicit targets")
    | (Public | Unlisted | Internal), (Human_post | Automation_post) ->
      Ok Discoverable
    | (Public | Unlisted | Internal), System_post -> Ok Thread_participants)
;;

let audience_for_comment ~content =
  match explicit_address_of_text content with
  | Explicit_targets targets -> Ok (Targets targets)
  | Broadcast_all -> Ok Broadcast
  | Unsupported_broadcast selectors -> Error (unsupported_broadcast_error selectors)
  | No_explicit_address -> Ok Thread_participants
;;

let audience_for_reaction = Thread_participants
let audience_for_vote = Thread_participants

let audience_label = function
  | Targets _ -> "targets"
  | Broadcast -> "broadcast"
  | Thread_participants -> "thread_participants"
  | Discoverable -> "discoverable"
;;
