import hashlib
import json
import subprocess
from pathlib import Path
import sys
root = Path(sys.argv[1])
revision = sys.argv[2] if len(sys.argv) > 2 else None
def read(path):
    return subprocess.check_output(['git', 'show', f'{revision}:{path}'], cwd=root, text=True) if revision else (root / path).read_text()
ml = read('lib/server/server_runtime_bootstrap.ml')
stdio = read('bin/main_stdio_eio.ml')
activation = ml.split('let activate_owner_state', 1)[1].split('let run ~sw', 1)[0]
http = ml.split('let run ~sw', 1)[1]
checks = {
    'shared_activation_finishes_recovery_before_return': 'Lane_addon_runtime.recover_sampling' in activation and activation.index('Lane_addon_runtime.recover_sampling') < activation.index('{ state'),
    'http_awaits_activation_before_state_publication': http.index('activate_owner_state') < http.index('publish_server_state state'),
    'http_awaits_activation_before_readiness': http.index('activate_owner_state') < http.index('mark_owner_state_ready'),
    'stdio_awaits_activation_before_readiness': stdio.index('Server_runtime_bootstrap.activate_owner_state') < stdio.index('Server_runtime_bootstrap.mark_owner_state_ready'),
    'stdio_readiness_precedes_protocol_loop': stdio.index('Server_runtime_bootstrap.mark_owner_state_ready') < stdio.index('Mcp_eio.run_stdio'),
    'single_startup_recovery_call': ml.count('Lane_addon_runtime.recover_sampling') == 1,
}
print(json.dumps({'kind':'source ordering check; not runtime stdio execution', 'revision':revision or 'working tree', 'checks':checks, 'sha256':{'bootstrap':hashlib.sha256(ml.encode()).hexdigest(), 'stdio':hashlib.sha256(stdio.encode()).hexdigest()}}, indent=2))
sys.exit(0 if all(checks.values()) else 1)
