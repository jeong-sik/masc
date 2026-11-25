open Keeper_memory_os_types
module Effects = Librarian_effects
module Ids = Set_util.StringSet

type write =
  | Remember of
      { claim : string
      ; category : category
      ; basis : basis
      }
  | Supersede of
      { old : string
      ; claim : string
      ; category : category
      ; basis : basis
      }
  | Retract of
      { id : string
      ; reason : string
      }

type refusal =
  | Unknown_fact
  | Supersedes_itself
  | Blank_claim
  | Blank_trace
  | Malformed_derivation
  | Premises_missing of string list

type t =
  | Writes of
      { facts : fact list
      ; effects : Effects.t
      }
  | Already_held
  | Already_done
  | Already_absent
  | Refused of refusal

let refusal_kind = function
  | Unknown_fact -> "unknown_fact"
  | Supersedes_itself -> "supersedes_itself"
  | Blank_claim -> "blank_claim"
  | Blank_trace -> "blank_trace"
  | Malformed_derivation -> "malformed_derivation"
  | Premises_missing _ -> "premises_missing"
;;

let held id facts = List.find_opt (fun fact -> String.equal (memory_id fact) id) facts

let held_ordinary id facts =
  match held id facts with
  | Some fact when is_ordinary fact -> Some fact
  | Some _ | None -> None
;;

let remember_personal ~claim ~category (source : Keeper_external_attention.item) =
  match Keeper_external_attention.original_message_scope source, source.external_message with
  | Some scope, Some message ->
    Option.map (fun observation -> Remember { claim; category; basis = Observed (Personal observation) })
      (personal_observation ~scope ~message_ids:[ message.message_id ])
  | _ -> None
;;

(* The fact a write states. The snapshot codec does not write a blank claim,
   so one is refused before it reaches a commit. *)
let stated ~at ~trace_id ~claim ~category basis =
  let origin : origin = { kind = Authored; trace_id } in
  if String.equal (String.trim claim) ""
  then Error Blank_claim
  else (
    match basis with
    | Observed observation ->
      let fact : fact = observed ~claim ~category ~now:at ~origin in
      Ok { fact with basis = Observed observation }
    | Derived derivations ->
      (match derived ~claim ~category ~now:at ~origin ~derivations with
       | Ok fact -> Ok fact
       | Error (_ : string) -> Error Malformed_derivation))
;;

(* Same category and basis, as the snapshot writes them. *)
let says_the_same (left : fact) (right : fact) =
  String.equal (category_to_string left.category) (category_to_string right.category)
  && Yojson.Safe.equal (basis_to_json left.basis) (basis_to_json right.basis)
;;

(* [removed] leave and [added] arrive, then support is checked. [states] is
   the id of the claim the write states, which has to be held afterwards. *)
let settle ~at ~facts ~states ~removed ~added ~touched =
  let removed_ids =
    List.fold_left
      (fun ids ((fact : fact), (_ : Effects.removal)) -> Ids.add (memory_id fact) ids)
      Ids.empty
      removed
  in
  let kept = List.filter (fun fact -> not (Ids.mem (memory_id fact) removed_ids)) facts in
  let (_ : fact list), unsupported =
    Keeper_memory_os_support_core.maintain_supported_facts (kept @ added)
  in
  let lost_statement =
    match states with
    | None -> None
    | Some id ->
      List.find_opt
        (fun (lost : Keeper_memory_os_current_types.support_invalidation) ->
           String.equal (memory_id lost.fact) id)
        unsupported
  in
  match lost_statement with
  | Some lost -> Refused (Premises_missing lost.missing_premise_ids)
  | None ->
    let effects : Effects.t =
      { added
      ; touched
      ; removed =
          removed
          @ List.map
              (fun (lost : Keeper_memory_os_current_types.support_invalidation) ->
                 lost.fact, Effects.Support_lost { missing = lost.missing_premise_ids })
              unsupported
      ; not_applied = []
      ; sources = []
      ; promotions = []
      }
    in
    Writes { facts = Effects.apply ~at facts effects; effects }
;;

let plan_write ~by ~at ~trace_id facts write =
  match write with
  | Retract { id; reason } ->
    (match held_ordinary id facts with
     | None -> Already_absent
     | Some fact ->
       settle ~at ~facts ~states:None
         ~removed:[ fact, Effects.Retracted { by; reason } ]
         ~added:[] ~touched:[])
  | Remember { claim; category; basis } ->
    (match stated ~at ~trace_id ~claim ~category basis with
     | Error refusal -> Refused refusal
     | Ok fact ->
       let id = memory_id fact in
       (match held id facts with
        | None -> settle ~at ~facts ~states:(Some id) ~removed:[] ~added:[ fact ] ~touched:[]
        | Some existing ->
          if says_the_same existing fact
          then settle ~at ~facts ~states:(Some id) ~removed:[] ~added:[] ~touched:[ id ]
          else if not (is_ordinary fact) && existing.category = fact.category
          then settle ~at ~facts ~states:(Some id) ~removed:[] ~added:[ fact ] ~touched:[]
          else Already_held))
  | Supersede { old; claim; category; basis } ->
    (match stated ~at ~trace_id ~claim ~category basis with
     | Error refusal -> Refused refusal
     | Ok fact when not (is_ordinary fact) -> Refused Unknown_fact
     | Ok fact ->
       let id = memory_id fact in
       if String.equal id old
       then Refused Supersedes_itself
       else (
         match held_ordinary old facts, held_ordinary id facts with
         | None, None -> Refused Unknown_fact
         | None, Some (_ : fact) -> Already_done
         | Some superseded, None ->
           (* The claim says what [superseded] said, corrected, so Memory has
              known it since that fact was first seen. *)
           let fact =
             { fact with first_seen = Float.min (superseded : fact).first_seen at }
           in
           settle ~at ~facts ~states:(Some id)
             ~removed:[ superseded, Effects.Superseded_by id ]
             ~added:[ fact ] ~touched:[]
         | Some superseded, Some (_ : fact) ->
           settle ~at ~facts ~states:(Some id)
             ~removed:[ superseded, Effects.Superseded_by id ]
             ~added:[] ~touched:[ id ]))
;;

(* The snapshot names the trace of the write that made it, and its reader
   refuses a snapshot that names none. *)
let plan ~by ~at ~trace_id facts write =
  if String.equal (String.trim trace_id) ""
  then Refused Blank_trace
  else plan_write ~by ~at ~trace_id facts write
;;
