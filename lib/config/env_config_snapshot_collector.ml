(** Effect shell for {!Env_config_snapshot_core}.

    Each collector owns exactly one environment or applied-runtime read. The
    resulting observation is handed to the pure projection core. *)

type t =
  { spec : Env_config_snapshot_core.spec
  ; collect : unit -> Env_config_snapshot_core.observation
  }

type observed =
  { spec : Env_config_snapshot_core.spec
  ; observation : Env_config_snapshot_core.observation
  }

let entry
      ?(getenv = Sys.getenv_opt)
      ?(sensitive = false)
      ~default
      env_name
      description
  =
  { spec = Env_config_snapshot_core.make_spec ~sensitive ~default env_name description
  ; collect = (fun () -> Env_config_snapshot_core.Raw_environment (getenv env_name))
  }
;;

let effective_entry ?(sensitive = false) ~default ~read env_name description =
  { spec = Env_config_snapshot_core.make_spec ~sensitive ~default env_name description
  ; collect =
      (fun () ->
        let value, source = read () in
        Env_config_snapshot_core.Applied_value { value; source })
  }
;;

(* [t] and [observed] both carry a [spec], and [observed] is declared second,
   so an unannotated [collector.spec] resolves against [observed] and the next
   field access has nowhere to go. The annotation names which record this is. *)
let collect (collector : t) : observed =
  { spec = collector.spec; observation = collector.collect () }

let project observed =
  Env_config_snapshot_core.to_json observed.spec observed.observation

let to_json collector = collector |> collect |> project

let category name collectors =
  let observed = List.map collect collectors in
  name, `List (List.map project observed)
