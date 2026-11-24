open Masc_tui_core
open Masc_tui_protocol
module Journal = Wire_chat_journal

(* Keeper_chat_response_ownership over the wire's owner type: the same three
   fields and the same two rules, [admit] and [retire_attempt]. *)
type ownership = {
  admitted : Journal.response_owner option;
  closed : Journal.response_owner option;
  unobserved_scope : int option;
}

let fresh_ownership = { admitted = None; closed = None; unobserved_scope = None }

let owner_order (a : Journal.response_owner) (b : Journal.response_owner) =
  match Int.compare a.content_generation b.content_generation with
  | 0 -> Int.compare a.stream_scope b.stream_scope
  | order -> order

type admission =
  | Append of ownership
  | Drop  (** The bytes of a superseded response. *)

let admit ownership = function
  | Journal.Unobserved_scope scope -> (
      match scope with
      | Some _ -> Append { ownership with unobserved_scope = scope }
      | None -> Append ownership)
  | Journal.Observed_response owner ->
      let closed_out =
        match ownership.closed with
        | Some closed -> owner_order owner closed <= 0
        | None -> false
      in
      let precedes_current =
        match ownership.admitted with
        | Some current ->
            owner_order owner current < 0
            || Int.equal owner.content_generation current.content_generation
               && (match ownership.unobserved_scope with
                  | Some scope -> owner.stream_scope < scope
                  | None -> false)
        | None -> false
      in
      if closed_out || precedes_current then Drop
      else
        Append { ownership with admitted = Some owner; unobserved_scope = None }

let retire_attempt ownership =
  let closed =
    match ownership.admitted with
    | Some owner -> (
        match ownership.closed with
        | Some closed when owner_order closed owner >= 0 -> Some closed
        | Some _ | None -> Some owner)
    | None -> ownership.closed
  in
  { admitted = None; closed; unobserved_scope = None }

type reading =
  | Reading of Journal.from
  | Ended

type t = {
  text : string;
  ownership : ownership;
  reading : reading;
}

let start =
  { text = ""; ownership = fresh_ownership; reading = Reading Journal.From_start }

let no_journal = { text = ""; ownership = fresh_ownership; reading = Ended }

let apply_page (page : Journal.page) t =
  match t.reading with
  | Ended -> t
  | Reading _ ->
      (* [pieces] is the run's text so far, newest first, joined once. *)
      let finish ~pieces ~ownership reading =
        { text = String.concat "" (List.rev pieces); ownership; reading }
      in
      let rec fold ~pieces ~ownership = function
        | [] ->
            finish ~pieces ~ownership
              (match page.next with
              | Some cursor -> Reading (Journal.After cursor)
              | None -> Ended)
        | (event : Journal.event) :: rest -> (
            match event with
            | Journal.Run_started -> fold ~pieces:[] ~ownership:fresh_ownership rest
            | Journal.Runtime_attempt_started ->
                fold ~pieces:[] ~ownership:(retire_attempt ownership) rest
            | Journal.Text_delta { text; owner } -> (
                match admit ownership owner with
                | Append ownership -> fold ~pieces:(text :: pieces) ~ownership rest
                | Drop -> fold ~pieces ~ownership rest)
            | Journal.Run_finished | Journal.Event_error ->
                finish ~pieces ~ownership Ended
            | Journal.Other -> fold ~pieces ~ownership rest)
      in
      fold ~pieces:[ t.text ] ~ownership:t.ownership page.events

let next_page t =
  match t.reading with
  | Reading from -> Some from
  | Ended -> None

let pending_page = function
  | Observed.Value { data; _ } -> next_page data
  | Observed.Loading _ | Observed.Absent | Observed.Unreported
  | Observed.Failed _ ->
      Some Journal.From_start

let text t =
  match t.reading with
  | Reading _ -> None
  | Ended -> if String.equal t.text "" then None else Some t.text
