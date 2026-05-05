(* See keeper_admission_router.mli for documentation. *)

module KAP = Keeper_admission_policy
module KPTB = Keeper_provider_token_bucket

type surface_reason =
  | Min_tier_unsatisfiable
  | All_candidates_throttled

type drift_record = {
  preferred_provider : string;
  actual_provider : string;
  tier : KAP.tier;
  reason : string;
}

type decision =
  | Dispatch of {
      candidate : KAP.candidate;
      drift : drift_record;
    }
  | Wait
  | Surface of surface_reason

type bucket_lookup = string -> KPTB.t option

let classify_reason ~preferred ~actual ~tier =
  if String.equal preferred actual then "preferred"
  else
    match (tier : KAP.tier) with
    | KAP.Preferred -> "secondary_preferred"
    | KAP.Acceptable -> "fallback"
    | KAP.Survival -> "survival_recovery"

(* Walk the above-floor candidate list once.  For each candidate ask
   the [buckets] lookup; if a bucket is present, try to acquire one
   token.  First success returns Dispatch.

   The [count_above_floor] tally is used after the walk to disambiguate
   Surface (no above-floor candidates exist at all) from Wait
   (above-floor candidates exist but are all currently throttled).
   This is the I2 vs I5 boundary: I2 (work-conserving) lets Wait
   happen when supply is temporarily zero; Surface only fires when
   supply is structurally absent. *)
let schedule ~policy ~buckets =
  let preferred = KAP.top_provider policy in
  let above_floor = KAP.candidates_above_min_tier policy in
  let rec walk count = function
    | [] ->
        if count = 0 then Surface Min_tier_unsatisfiable
        else Surface All_candidates_throttled
    | (c : KAP.candidate) :: rest -> (
        match buckets c.provider with
        | None ->
            (* Bucket not configured for this provider.  Skip without
               counting toward "above-floor supply" — a missing
               bucket is misconfiguration, not throttling. *)
            walk count rest
        | Some bucket ->
            if KPTB.try_acquire bucket then
              let drift =
                {
                  preferred_provider = preferred;
                  actual_provider = c.provider;
                  tier = c.tier;
                  reason =
                    classify_reason ~preferred ~actual:c.provider ~tier:c.tier;
                }
              in
              Dispatch { candidate = c; drift }
            else
              (* Bucket exists but refused.  This counts as supply that
                 is currently throttled — the right answer when nothing
                 succeeds is Wait, not Surface. *)
              walk (count + 1) rest)
  in
  match above_floor with
  | [] -> Surface Min_tier_unsatisfiable
  | _ ->
      (match walk 0 above_floor with
       | Surface All_candidates_throttled -> Wait
       | other -> other)
