(** What masc does with a Muse Code subscription usage the host states.

    The host states the account's rolling window and weekly window, each as
    a used percentage with its reset time, in [usage/changed] while a session
    runs and in the answer to [usage/read]. Every place masc hears one (a
    Keeper turn, a Fusion panelist, setup verification, a read after a failed
    turn) goes through {!observe}, so the windows reach the operator surface
    and a spent window rests the account by the same rule everywhere. *)

type origin =
  | Usage_changed  (** [usage/changed], pushed while a session runs. *)
  | Usage_read  (** The answer to [usage/read]. *)

val report :
  origin ->
  Runtime_muse_msp.subscription_usage ->
  ( Runtime_provider_usage_window.report
    , Runtime_provider_usage_window.decode_error )
    result
(** Both windows under {!Runtime_provider_usage_window.Muse_subscription_usage}
    whichever [origin] stated them, as {!Runtime_provider_usage_window.Percent}
    with no [limit_id], each {!Runtime_provider_usage_window.Gates_model_calls} and
    its reset in epoch seconds. The rolling window's kind follows its stated
    length ({!Runtime_provider_usage_window.window_kind_of_minutes}); the
    weekly window is {!Runtime_provider_usage_window.Seven_day}. A rolling
    window that is itself seven days long would share the weekly window's row
    and is refused with {!Runtime_provider_usage_window.Duplicate_window}. *)

val observe :
  scope:Runtime_quota_window.scope ->
  origin ->
  Runtime_muse_msp.subscription_usage ->
  unit
(** When a window is spent, rest [scope] until it resets
    ({!Runtime_quota_window.note_exhausted}); then record the windows
    ({!Runtime_provider_usage_window.record}, stamped with the time masc
    heard them). The rest comes first so a cancelled record cannot skip it. A
    usage {!report} refuses is logged and not recorded; the rest still
    applies. *)
