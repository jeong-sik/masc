"""Shared runtime.toml fixtures for setup tests (test_setup_cli, test_install_runtime_setup)."""
import json

# Claude Code rejects a declared window under its autocompact floor
# (runtime_claude_code.ml: autocompact_window_floor_tokens = 100_000), so a
# claude-code fixture declares at least the floor. The floor is restated here
# on purpose: when the OCaml constant moves, these fixtures and the
# window-floor assertions in both test files change in the same commit. The
# floor rejection itself is pinned OCaml-side by
# test/test_runtime_claude_code_config.ml (#54355); these fixtures only keep
# the declared windows above that floor.
CLAUDE_CODE_WINDOW_FLOOR = 100000

# A protocol without a floor keeps the window the fixtures always declared.
PROBE_FALLBACK_WINDOW = 32768


def probe_fixture_toml(protocol, command, account_home):
    # codex-app-server keeps its 32768 window: that protocol has no floor.
    window = CLAUDE_CODE_WINDOW_FLOOR if protocol == 'claude-code' else PROBE_FALLBACK_WINDOW
    return (
        '[runtime]\ndefault = "probe_fixture.probe_fixture"\n'
        '[providers.probe_fixture]\n'
        'display-name = "Probe fixture"\n'
        f'protocol = {json.dumps(protocol)}\n'
        f'command = {json.dumps(str(command))}\n'
        f'account-home = {json.dumps(str(account_home))}\n'
        'is-non-interactive = true\n'
        '[models.probe_fixture]\napi-name = "fixture-model"\n'
        f'max-context = {window}\ntools-support = true\nstreaming = true\n'
        '[probe_fixture.probe_fixture]\n')


def official_fixture_toml(command, account_home):
    return (
        '[runtime]\ndefault = "official_fixture.official_fixture"\n'
        '[providers.official_fixture]\n'
        'display-name = "Official fixture"\n'
        'protocol = "claude-code"\n'
        f'command = {json.dumps(str(command))}\n'
        f'account-home = {json.dumps(str(account_home))}\n'
        'is-non-interactive = true\n'
        '[models.official_fixture]\napi-name = "fixture-model"\n'
        f'max-context = {CLAUDE_CODE_WINDOW_FLOOR}\ntools-support = true\nstreaming = true\n'
        '[official_fixture.official_fixture]\n')
