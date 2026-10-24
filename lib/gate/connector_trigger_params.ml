(** Canonical connector trigger-policy parameters.

    Gateway admission and connector observations use these same typed handles.
    The runtime override registry lives below the root masc library, so a
    disconnected connector does not need an upward dependency or a mirrored
    last-known policy. Configured defaults are installed by gateway bootstrap
    before transport credential checks; overrides keep their persisted keys. *)

(** Register a parameter whose values carry names.  [to_string] / [of_string]
    are the owning module's own spelling, so the wire form, the runtime.toml
    form and the picker label are one vocabulary rather than three.

    [choices] is what a picker may offer.  A domain that is only partly closed
    lists its closed names there and still accepts the rest through
    [of_string]: the picker walks the common values and the parameterized form
    is typed. *)
let register_enum ~key ~default ~to_string ~of_string ~choices ~description () =
  Runtime_params.register
    ~key
    ~default
    (* [of_string] is the judge.  A value that does not survive the round trip
       is not one this param holds, whatever handed it over. *)
    ~validate:(fun v ->
      match of_string (to_string v) with
      | Ok (_ : 'a) -> Ok ()
      | Error detail -> Error (Printf.sprintf "%s: %s" key detail))
    ~serialize:(fun v -> `String (to_string v))
    ~deserialize:(fun json ->
      match json with
      | `String raw -> of_string raw
      | other ->
          Error
            (Printf.sprintf
               "deserialize_enum: expected JSON string, got %s"
               (Json_util.kind_name other)))
    ~meta:{ description; value_type = "enum";
            min_value = None; max_value = None; choices }
    ()

(* ── connector trigger surface ───────────────────────────────── *)

(* What a connector's gateway resolved from runtime.toml at startup. The
   param default reads this rather than walking the config file itself,
   because [Runtime_params.get] calls the default thunk on
   every read and a policy check happens per inbound message: resolution is a
   file read, and it belongs to boot.

   A gateway that never starts (no bot token) leaves the hardcoded baseline
   here.  The gateways therefore install this before checking their token, so
   the params surface reports the configured policy even for a connector that
   is switched off — otherwise the screen would say [mention_or_thread] while
   runtime.toml said something else. *)
let discord_configured =
  ref (Discord_gateway_state.Mention_or_thread : Discord_gateway_state.trigger_policy)

let slack_configured =
  ref (Slack_gateway_state.Mention_or_thread : Slack_gateway_state.trigger_policy)

let set_discord_configured policy =
  discord_configured := policy

let set_slack_configured policy =
  slack_configured := policy

(* [user_only:<id>] is left out of [choices] on purpose: it carries an id, so
   it is not a value a picker can offer.  Both parsers still accept it, and the
   operator types that form. *)
let trigger_policy_choices = [ "mention_only"; "mention_or_thread"; "all" ]

let trigger_policy_description =
  "봇이 언제 응답하는가 — mention_only: 멘션된 글만. mention_or_thread: \
   멘션 또는 스레드 안의 모든 글. all: 사람이 쓴 모든 글. \
   user_only:<id> 로 한 사람만 받을 수도 있다"

(** Which Discord messages start a turn. *)
let discord =
  register_enum
    ~key:"discord.trigger_policy"
    ~default:(fun () -> !discord_configured)
    ~to_string:Discord_gateway_state.trigger_policy_to_string
    ~of_string:Discord_gateway_state.parse_trigger_policy
    ~choices:trigger_policy_choices
    ~description:trigger_policy_description
    ()

(** Which Slack messages start a turn. *)
let slack =
  register_enum
    ~key:"slack.trigger_policy"
    ~default:(fun () -> !slack_configured)
    ~to_string:Slack_gateway_state.trigger_policy_to_string
    ~of_string:Slack_gateway_state.parse_trigger_policy
    ~choices:trigger_policy_choices
    ~description:trigger_policy_description
    ()

