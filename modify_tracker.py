import re

with open('lib/cascade/cascade_health_tracker.mli', 'r') as f:
    mli = f.read()

# Add check_circuit_breaker
if 'val check_circuit_breaker' not in mli:
    mli += "\nval check_circuit_breaker : t -> provider_key:string -> (unit, string) result\n(** Check if the provider circuit breaker allows a request. *)\n"

with open('lib/cascade/cascade_health_tracker.mli', 'w') as f:
    f.write(mli)

with open('lib/cascade/cascade_health_tracker.ml', 'r') as f:
    ml = f.read()

# 1. Update type provider_state
ml = re.sub(r'mutable consecutive_failures: int;\n\s*mutable cooldown_until: float;', '', ml)

# 2. Update type t
ml = re.sub(r'type t = {\n  providers: \(string, provider_state\) Hashtbl.t;\n  mu: Stdlib.Mutex.t;\n}', 'type t = {\n  providers: (string, provider_state) Hashtbl.t;\n  breaker: Circuit_breaker.t;\n  mu: Stdlib.Mutex.t;\n}', ml)

# 3. Update get_or_create_state
ml = re.sub(r'consecutive_failures = 0;\n\s*cooldown_until = 0.0;', '', ml)

# 4. Update create
ml = re.sub(r'providers = Hashtbl.create 8;\n  mu = Stdlib.Mutex.create \(\);\n}', 'providers = Hashtbl.create 8;\n  breaker = Circuit_breaker.create ~failure_threshold:cooldown_threshold ~failure_window:window_sec ~cooldown:cooldown_sec ();\n  mu = Stdlib.Mutex.create ();\n}', ml)

# 5. Update record function (using replacement that matches exactly what we need)
# We will replace the entire match outcome with... with a new version
# This might be tricky. Let's do it carefully.
