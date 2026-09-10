(** JSON projection of every enabled declared binding, including runtimes whose
    credential or executable is unavailable. Credential values and file paths
    are never projected. Undeclared context limits stay null. *)
val to_json : Runtime_schema.config -> Yojson.Safe.t

val binding_for_provider
  :  Runtime_schema.config
  -> Runtime_schema.provider
  -> (Runtime_schema.binding, string) result
(** The binding the install wizard offers for this provider: its declared
    [wizard-default], the only enabled binding when there is exactly one, or
    the one [runtime].default already names. Anything else is a real choice
    the wizard will not guess. The installer and the seed-config guard read
    the same rule from here. *)
