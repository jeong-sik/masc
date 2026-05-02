import re

with open('lib/cascade/cascade_health_tracker.ml', 'r') as f:
    ml = f.read()

old_summary = '''      let successes = List.length
          (List.filter (fun e -> e.outcome = Success) recent) in
      let in_cd = state.cooldown_until > now in
      Printf.sprintf "%s: %d/%d ok (%.0f%%) consec_fail=%d cooldown=%b"
        provider_key successes total
        (if total > 0 then 100.0 *. float_of_int successes /. float_of_int total else 100.0)
        state.consecutive_failures in_cd)'''

new_summary = '''      let successes = List.length
          (List.filter (fun e -> e.outcome = Success) recent) in
      let st = Circuit_breaker.get_status t.breaker ~agent_id:provider_key in
      let in_cd = (st.state_name = "open") in
      Printf.sprintf "%s: %d/%d ok (%.0f%%) consec_fail=%d cooldown=%b"
        provider_key successes total
        (if total > 0 then 100.0 *. float_of_int successes /. float_of_int total else 100.0)
        st.recent_failures in_cd)'''

if old_summary in ml:
    ml = ml.replace(old_summary, new_summary)
    print("Replaced summary")

old_info = '''  consecutive_failures = state.consecutive_failures;
  in_cooldown = state.cooldown_until > now;
  cooldown_expires_at = (if state.cooldown_until > now then Some state.cooldown_until else None);'''

new_info = '''  consecutive_failures = (Circuit_breaker.get_status t.breaker ~agent_id:provider_key).recent_failures;
  in_cooldown = ((Circuit_breaker.get_status t.breaker ~agent_id:provider_key).state_name = "open");
  cooldown_expires_at = (Circuit_breaker.get_status t.breaker ~agent_id:provider_key).open_until;'''

if old_info in ml:
    ml = ml.replace(old_info, new_info)
    print("Replaced info")

with open('lib/cascade/cascade_health_tracker.ml', 'w') as f:
    f.write(ml)

with open('lib/oas_worker_named.ml', 'r') as f:
    ml2 = f.read()

old_try = '''try_cascade ?on_success ?resume_checkpoint ?per_provider_timeout_s rest last_err'''
new_try = '''try_cascade ~on_success ?resume_checkpoint ?per_provider_timeout_s rest last_err'''

if old_try in ml2:
    ml2 = ml2.replace(old_try, new_try)
    print("Replaced try_cascade")

with open('lib/oas_worker_named.ml', 'w') as f:
    f.write(ml2)
