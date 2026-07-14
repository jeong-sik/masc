type source =
  | Env
  | Toml
  | Default

type 'a field = {
  value : 'a;
  source : source;
}

type t = {
  stream_idle_timeout_sec : float option field;
  body_timeout_override_sec : float option field;
}

(** Exhaustive boundary for the labels emitted by
    {!Config_boot_overrides.source}. Unknown labels are an internal contract
    violation and must not be displayed as a fabricated default source. *)
let source_of_env_name name : source =
  match Config_boot_overrides.source name with
  | "env" -> Env
  | "boot_override" -> Toml
  | "default" -> Default
  | label ->
    raise
      (Env_config_core.Config_error
         (Printf.sprintf "unknown config source for %s: %S" name label))

let source_to_string = function
  | Env -> "env"
  | Toml -> "toml"
  | Default -> "default"

(* Per-call CLI subprocess idle timeout. Read fresh each turn rather than
   frozen at server boot — the value sits outside the keepalive budget
   contract enforced by the [t] snapshot. Range [10, 600] mirrors
   the CLI transport contract; it is independent of the opt-in HTTP stream
   idle deadline.

   SSOT: must match Env_config_keeper.KeeperKeepalive.cli_subprocess_idle_sec
   (same default 120, same range [10, 600]). *)
let cli_subprocess_idle_sec_live () =
  Float.max 10.0
    (Float.min 600.0
       (Env_config_core.get_float
          ~default:120.0
          "MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC"))

let cli_subprocess_idle_sec = cli_subprocess_idle_sec_live

(* SSOT: Env_config_keeper.KeeperKeepalive.body_timeout_sec_override
   (same env var, same clamp [10, 600]). Opt-in: unset -> None.
   OAS applies this only to non-streaming sync body reads; streaming
   liveness is progress-based. *)
let body_timeout_override_sec_live () =
  match Env_config_core.raw_value_opt "MASC_KEEPER_BODY_TIMEOUT_SEC" with
  | Some raw ->
      (match Float.of_string_opt (String.trim raw) with
       | Some v -> Some (Float.max 10.0 (Float.min 600.0 v))
       | None -> None)
  | None -> None

let freeze_from_current () =
  let source_field name value =
    { value; source = source_of_env_name name }
  in
  let stream_idle_timeout_sec =
    source_field
      "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC"
      (Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec ())
  in
  let body_timeout_override_sec =
    {
      value = body_timeout_override_sec_live ();
      source = source_of_env_name "MASC_KEEPER_BODY_TIMEOUT_SEC";
    }
  in
  {
    stream_idle_timeout_sec;
    body_timeout_override_sec;
  }

let frozen : t option Atomic.t = Atomic.make None

let init () =
  match Atomic.get frozen with
  | Some _ -> ()
  | None -> Atomic.set frozen (Some (freeze_from_current ()))

let reset_for_tests () =
  Atomic.set frozen None

let current () =
  match Atomic.get frozen with
  | Some snapshot -> snapshot
  | None -> freeze_from_current ()

let field_to_yojson value_to_yojson (field : 'a field) =
  `Assoc
    [
      ("value", value_to_yojson field.value);
      ("source", `String (source_to_string field.source));
    ]

let option_float_to_yojson = function
  | Some value -> `Float value
  | None -> `Null

let to_yojson (runtime : t) =
  `Assoc
    [
      ("stream_idle_timeout_sec", field_to_yojson option_float_to_yojson runtime.stream_idle_timeout_sec);
      ("body_timeout_override_sec", field_to_yojson option_float_to_yojson runtime.body_timeout_override_sec);
    ]

let stream_idle_timeout_sec () =
  (current ()).stream_idle_timeout_sec.value

let body_timeout_override_sec () =
  (current ()).body_timeout_override_sec.value
