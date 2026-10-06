(* Muse Code subscription usage on the operator surface and the quota rest.
   See the [.mli]. *)

module Usage_window = Runtime_provider_usage_window

type origin =
  | Usage_changed
  | Usage_read

let source = function
  | Usage_changed -> Usage_window.Muse_usage_changed
  | Usage_read -> Usage_window.Muse_usage_read
;;

let method_name = function
  | Usage_changed -> "usage/changed"
  | Usage_read -> "usage/read"
;;

(* Spending either window refuses model calls: the host answers a turn on a
   spent account with HTTP 429 "Subscription quota exhausted. Your usage
   window resets at ...". *)
let window ~kind ~used_percent ~resets_at_ms : Usage_window.window =
  { limit_id = None
  ; kind
  ; role = Usage_window.Gates_model_calls
  ; utilization = Usage_window.Percent used_percent
  ; resets_at = Some (resets_at_ms / 1000)
  }
;;

let report origin (usage : Runtime_muse_msp.subscription_usage) =
  let rolling = usage.window in
  let weekly = usage.weekly in
  match Usage_window.window_kind_of_minutes rolling.window_duration_mins with
  | Usage_window.Seven_day ->
    Error
      (Usage_window.Duplicate_window
         { path = method_name origin; limit_id = None; kind = Usage_window.Seven_day })
  | (Usage_window.Five_hour | Usage_window.Duration_minutes _ | Usage_window.Provider_label _)
    as rolling_kind ->
    Ok
      { Usage_window.source = source origin
      ; windows =
          [ window
              ~kind:rolling_kind
              ~used_percent:rolling.used_percent
              ~resets_at_ms:rolling.resets_at_ms
          ; window
              ~kind:Usage_window.Seven_day
              ~used_percent:weekly.weekly_used_percent
              ~resets_at_ms:weekly.weekly_resets_at_ms
          ]
      }
;;

let observe ~scope origin usage =
  (match report origin usage with
   | Ok report -> Usage_window.record ~scope ~observed_at:(Time_compat.now ()) report
   | Error error ->
     Log.Runtime_agent.warn
       "Muse Code %s usage windows not recorded for %s: %s"
       (method_name origin)
       (Runtime_quota_window.scope_to_string scope)
       (Usage_window.decode_error_to_string error));
  Option.iter
    (fun reset_ms ->
       Runtime_quota_window.note_exhausted ~scope ~resets_at:(float_of_int reset_ms /. 1000.))
    (Runtime_muse_msp.exhausted_subscription_reset_ms usage)
;;
