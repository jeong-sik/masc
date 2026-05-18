(** Phase 2a low-trust operator recommendations.

   Surfaces a dashboard nudge when [trust_score] indicates a provider
   is dragging the cascade.  Observation only — the user runs the
   suggested config edit themselves.  Phase 2b is what would make these
   self-applying, and it is gated by [MASC_CASCADE_TRUST_PERSIST]. *)

module Health = Cascade_health_tracker

type recommendation_action =
  | Reduce_weight (* unreliable but partially working *)
  | Disable (* effectively dead *)
  | Investigate (* high-volume same-fingerprint failures — config bug *)

let recommendation_action_to_string = function
  | Reduce_weight -> "reduce_weight"
  | Disable -> "disable"
  | Investigate -> "investigate"
;;

type recommendation =
  { rec_provider_key : string
  ; rec_trust_score : float
  ; rec_same_fingerprint_count : int
  ; rec_events_in_window : int
  ; rec_top_fingerprint : string option
  ; rec_action : recommendation_action
  ; rec_rationale : string
  }

let top_failure_fingerprint (info : Health.provider_info) =
  match info.top_fingerprints with
  | [] -> None
  | (fingerprint, count) :: _ -> Some (fingerprint, count)
;;

let recommendation_rationale ~provider_key ~trust_score ~events ~top_count action =
  match action with
  | Investigate when top_count >= 5 ->
    Printf.sprintf
      "Provider %s has repeated the same failure fingerprint %d times; inspect \
       config/auth before changing weights."
      provider_key
      top_count
  | Investigate ->
    Printf.sprintf
      "Provider %s has very low trust %.2f across %d recent events; inspect quota/auth \
       before disabling it."
      provider_key
      trust_score
      events
  | Disable ->
    Printf.sprintf
      "Provider %s trust %.2f is below 0.10 after %d recent events; disable until \
       recovery is confirmed."
      provider_key
      trust_score
      events
  | Reduce_weight ->
    Printf.sprintf
      "Provider %s trust %.2f is below 0.30; reduce its routing weight while monitoring \
       recovery."
      provider_key
      trust_score
;;

(* Classifier — see RFC-0009 §"Phase 2a".

   The provider_info record no longer stores a raw [trust_score], so this
   derives it from the live tracker snapshot using [Cascade_trust.trust_score].
   Recommendations stay observation-only: this module never mutates config. *)
let classify_recommendation (info : Health.provider_info) : recommendation option =
  if info.events_in_window <= 0
  then None
  else (
    let trust_score = Cascade_trust.trust_score info in
    let top_fingerprint, same_fingerprint_count =
      match top_failure_fingerprint info with
      | Some (fingerprint, count) -> Some fingerprint, count
      | None -> None, 0
    in
    (* Reviewer #13194: [same_fingerprint_count] is accumulated across the
       provider's lifetime via [provider_info.top_fingerprints], not the
       rolling [events_in_window].  A busy provider that once accumulated
       5+ identical failures would otherwise gate [Investigate] forever
       even when the recent window is healthy.  Couple the gate with a
       rolling-window floor (the recent window must have seen at least
       as many events as the fingerprint count we are reacting to) AND
       a low trust-score check (so a healthy window overrides the
       lifetime artifact).  The two extra conditions keep the
       recommendation responsive to the live signal without losing
       the stuck-fingerprint detection it was built for. *)
    let stuck_fingerprint =
      same_fingerprint_count >= 5 && info.events_in_window >= 5 && trust_score < 0.50
    in
    let action =
      if stuck_fingerprint
      then Some Investigate
      else if trust_score < 0.10 && info.events_in_window >= 30
      then Some Investigate
      else if trust_score < 0.10
      then Some Disable
      else if trust_score < 0.30
      then Some Reduce_weight
      else None
    in
    match action with
    | None -> None
    | Some rec_action ->
      Some
        { rec_provider_key = info.provider_key
        ; rec_trust_score = trust_score
        ; rec_same_fingerprint_count = same_fingerprint_count
        ; rec_events_in_window = info.events_in_window
        ; rec_top_fingerprint = top_fingerprint
        ; rec_action
        ; rec_rationale =
            recommendation_rationale
              ~provider_key:info.provider_key
              ~trust_score
              ~events:info.events_in_window
              ~top_count:same_fingerprint_count
              rec_action
        })
;;

let low_trust_recommendations (infos : Health.provider_info list) : recommendation list =
  List.filter_map classify_recommendation infos
  |> List.sort (fun a b -> Float.compare a.rec_trust_score b.rec_trust_score)
;;

let recommendation_to_json (r : recommendation) : Yojson.Safe.t =
  `Assoc
    [ "provider_key", `String r.rec_provider_key
    ; "trust_score", `Float r.rec_trust_score
    ; "same_fingerprint_count", `Int r.rec_same_fingerprint_count
    ; "events_in_window", `Int r.rec_events_in_window
    ; ( "top_fingerprint"
      , match r.rec_top_fingerprint with
        | Some fp -> `String fp
        | None -> `Null )
    ; "action", `String (recommendation_action_to_string r.rec_action)
    ; "rationale", `String r.rec_rationale
    ]
;;

let recommendations_json () : Yojson.Safe.t =
  let infos = Health.all_providers Health.global in
  `List (List.map recommendation_to_json (low_trust_recommendations infos))
;;
