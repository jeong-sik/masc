(* Reads go through the config layer, which is where this repository keeps the
   environment: [Env_config_core.raw_value_opt] also answers from the boot
   override store, so a value seeded from runtime.toml reaches these knobs the
   same way a exported variable does, and CI's env-read floor stays where it
   is. *)

let default_endpoint = "https://api.typesafe.ai/v1/systemone"
let default_model = "jev-latest"

let api_key () = Env_config_core.trim_opt (Env_config_core.raw_value_opt "TYPESAFEAI_API_KEY")

let endpoint () =
  Env_config_core.get_string ~default:default_endpoint "MASC_TYPESAFEAI_ENDPOINT"
;;

let model () = Env_config_core.get_string ~default:default_model "MASC_TYPESAFEAI_MODEL"

(* The variable turns the lane off; it cannot turn it on without a key, and a
   key alone is enough to opt in. [get_bool] reads the same spellings this
   module used to match by hand (true/1/yes/on, false/0/no/off) and warns on
   anything else instead of silently reading it as off. *)
let is_enabled () =
  Env_config_core.get_bool ~default:true "MASC_TYPESAFEAI_ENABLED"
  && Option.is_some (api_key ())
;;

(* One switch per gate. A key turns the lane on; each gate can still be
   turned off by name, so adding a gate does not switch on another one that
   nobody reviewed with it. The Board gate defaults to on, which is what the
   lane switch alone meant before the second gate existed. The absorb gate
   defaults to off: it sends the librarian's memories to the vendor, which a
   deployment that set its key for the Board gate did not choose. *)
let is_board_attention_enabled () =
  is_enabled ()
  && Env_config_core.get_bool ~default:true "MASC_TYPESAFEAI_BOARD_ATTENTION_ENABLED"
;;

let is_absorb_gate_enabled () =
  is_enabled ()
  && Env_config_core.get_bool ~default:false "MASC_TYPESAFEAI_ABSORB_GATE_ENABLED"
;;
