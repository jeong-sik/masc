import re

with open('lib/oas_worker_named.ml', 'r') as f:
    ml = f.read()

old_code = '''    | (provider_cfg : Llm_provider.Provider_config.t) :: rest ->
      let is_last = rest = [] in'''

new_code = '''    | (provider_cfg : Llm_provider.Provider_config.t) :: rest ->
      match Cascade_health_tracker.check_circuit_breaker Cascade_health_tracker.global ~provider_key:provider_cfg.model_id with
      | Error msg ->
          Log.Misc.debug "cascade %s: skipping %s (circuit breaker open: %s)" cascade_name provider_cfg.model_id msg;
          try_cascade ?on_success ?resume_checkpoint ?per_provider_timeout_s rest last_err
      | Ok () ->
      let is_last = rest = [] in'''

if old_code in ml:
    ml = ml.replace(old_code, new_code)
    with open('lib/oas_worker_named.ml', 'w') as f:
        f.write(ml)
    print("Success: Replaced in oas_worker_named.ml")
else:
    print("Error: Could not find old_code in oas_worker_named.ml")
