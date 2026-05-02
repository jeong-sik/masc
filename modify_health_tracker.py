import re

with open('lib/cascade/cascade_health_tracker.mli', 'r') as f:
    mli = f.read()

if 'val check_circuit_breaker' not in mli:
    mli += "\nval check_circuit_breaker : t -> provider_key:string -> (unit, string) result\n(** Check if the provider circuit breaker allows a request. *)\n"

with open('lib/cascade/cascade_health_tracker.mli', 'w') as f:
    f.write(mli)

with open('lib/cascade/cascade_health_tracker.ml', 'r') as f:
    ml = f.read()

# 1. Update type provider_state
ml = re.sub(r'mutable consecutive_failures: int;\s*mutable cooldown_until: float;', '', ml)

# 2. Update type t
ml = re.sub(r'type t = \{\n  providers: \(string, provider_state\) Hashtbl.t;\n  mu: Stdlib.Mutex.t;\n\}',
            'type t = {\n  providers: (string, provider_state) Hashtbl.t;\n  breaker: Circuit_breaker.t;\n  mu: Stdlib.Mutex.t;\n}', ml)

# 3. Update get_or_create_state
ml = re.sub(r'consecutive_failures = 0;\s*cooldown_until = 0.0;', '', ml)

# 4. Update create
ml = re.sub(r'providers = Hashtbl.create 8;\n  mu = Stdlib.Mutex.create \(\);\n\}',
            'providers = Hashtbl.create 8;\n  breaker = Circuit_breaker.create ~failure_threshold:cooldown_threshold ~failure_window:window_sec ~cooldown:cooldown_sec ();\n  mu = Stdlib.Mutex.create ();\n}', ml)

# 5. Update is_in_cooldown
old_is_in_cooldown = '''let is_in_cooldown t ~provider_key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.providers provider_key with
    | None -> false
    | Some state ->
      let now = Unix.gettimeofday () in
      if state.cooldown_until > now then true
      else begin
        (* Expired cooldown — clear it *)
        if state.cooldown_until > 0.0 then
          state.cooldown_until <- 0.0;
        false
      end)'''
new_is_in_cooldown = '''let is_in_cooldown t ~provider_key =
  let st = Circuit_breaker.get_status t.breaker ~agent_id:provider_key in
  if st.state_name = "open" then
    match st.open_until with
    | Some u -> u > Unix.gettimeofday ()
    | None -> true
  else false

let check_circuit_breaker t ~provider_key =
  Circuit_breaker.check t.breaker ~agent_id:provider_key
'''
ml = ml.replace(old_is_in_cooldown, new_is_in_cooldown)

# 6. Update provider_summary
ml = re.sub(r'let in_cd = state\.cooldown_until > now in\n\s*Printf\.sprintf "%s: %d/%d ok \(%\.0f%%\) consec_fail=%d cooldown=%b"\n\s*provider_key successes total\n\s*\(if total > 0 then 100\.0 \*\. float_of_int successes \/\. float_of_int total else 100\.0\)\n\s*state\.consecutive_failures in_cd',
            '''let st = Circuit_breaker.get_status t.breaker ~agent_id:provider_key in
      let in_cd = (st.state_name = "open") in
      Printf.sprintf "%s: %d/%d ok (%.0f%%) consec_fail=%d cooldown=%b"
        provider_key successes total
        (if total > 0 then 100.0 *. float_of_int successes /. float_of_int total else 100.0)
        st.recent_failures in_cd''', ml)

# 7. Update provider_info
ml = re.sub(r'consecutive_failures = state.consecutive_failures;\n\s*in_cooldown = state.cooldown_until > now;\n\s*cooldown_expires_at = \(if state.cooldown_until > now then Some state.cooldown_until else None\);',
            '''consecutive_failures = (Circuit_breaker.get_status t.breaker ~agent_id:provider_key).recent_failures;
      in_cooldown = ((Circuit_breaker.get_status t.breaker ~agent_id:provider_key).state_name = "open");
      cooldown_expires_at = (Circuit_breaker.get_status t.breaker ~agent_id:provider_key).open_until;''', ml)

with open('lib/cascade/cascade_health_tracker.ml', 'w') as f:
    f.write(ml)
