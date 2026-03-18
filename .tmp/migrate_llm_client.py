"""Replace Llm_client.X references with their actual module paths.

Llm_client re-exports Llm_types and Llm_orchestration via `include`.
This script replaces all `Llm_client.X` with the correct origin module.
"""
import os
import re

# Symbols from Llm_types
TYPES_SYMBOLS = {
    # Types
    'message', 'model_spec', 'provider', 'role', 'tool_def', 'tool_call',
    'token_usage', 'completion_request', 'completion_response',
    # Type constructors (variants)
    'Llama', 'Claude', 'OpenAI', 'Gemini', 'Glm_cloud', 'OpenRouter', 'Custom',
    'System', 'User', 'Assistant', 'Tool',
    # Functions
    'total_tokens', 'text_of_response', 'text_of_message',
    'string_of_provider', 'string_of_role',
    'system_msg', 'user_msg', 'assistant_msg', 'tool_msg',
    'sanitize_text_utf8', 'sanitize_message_utf8', 'sanitize_messages_utf8',
    'estimate_tokens', 'model_spec_of_string',
    'normalize_request', 'clamp_llama_max_tokens',
    # Model specs
    'llama_default', 'claude_opus', 'claude_sonnet', 'openai_default',
    'glm_cloud', 'gemini_pro',
    'default_local_model_spec', 'default_execution_model_spec',
    'default_verifier_model_spec', 'first_available_model_spec',
    'configured_default_model_label', 'default_execution_model_labels',
    'default_verifier_model_labels', 'available_model_specs_of_strings',
    # Record fields (used as Llm_client.field_name in pattern matches)
    'content', 'tool_calls', 'usage', 'model_used', 'latency_ms',
    'model', 'messages', 'temperature', 'max_tokens', 'tools',
    'response_format', 'call_id', 'call_name', 'call_arguments',
    'provider', 'model_id', 'max_context', 'api_url', 'api_key_env',
    'cost_per_1k_input', 'cost_per_1k_output',
    'tool_name', 'tool_description', 'parameters',
    'input_tokens', 'output_tokens',
}

# Symbols from Llm_orchestration
ORCHESTRATION_SYMBOLS = {
    'complete', 'cascade', 'run_prompt_cascade',
    'with_llm_permit', 'llm_semaphore_available', 'llm_permits_in_use',
    'max_concurrent_llm',
    'completion_cache_key', 'cache_key_of_request',
    'token_usage_to_json', 'token_usage_of_json',
    'tool_call_to_json', 'tool_call_of_json',
    'completion_response_to_cache_json', 'completion_response_of_cache_json',
    'filter_by_provider_health',
}

# Symbols from Llm_client itself (not re-exported)
CLIENT_SYMBOLS = {
    'to_oas_provider', 'to_oas_message', 'of_oas_message',
    'of_oas_usage', 'to_oas_usage',
}

def replace_in_file(filepath):
    with open(filepath) as f:
        content = f.read()

    original = content

    # Skip llm_client.ml itself
    if filepath.endswith('llm_client.ml'):
        return False

    def replacer(m):
        full = m.group(0)
        sym = m.group(1)
        if sym in CLIENT_SYMBOLS:
            return full  # Keep as Llm_client.X
        elif sym in ORCHESTRATION_SYMBOLS:
            return f'Llm_orchestration.{sym}'
        elif sym in TYPES_SYMBOLS:
            return f'Llm_types.{sym}'
        else:
            # Unknown symbol - keep as is, print warning
            print(f"  WARNING: unknown symbol Llm_client.{sym} in {filepath}")
            return full

    content = re.sub(r'Llm_client\.(\w+)', replacer, content)

    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        return True
    return False

def main():
    changed = 0
    lib_dir = 'lib'
    for root, dirs, files in os.walk(lib_dir):
        for f in sorted(files):
            if f.endswith('.ml') or f.endswith('.mli'):
                path = os.path.join(root, f)
                if replace_in_file(path):
                    changed += 1
                    count = 0
                    with open(path) as fh:
                        for line in fh:
                            count += line.count('Llm_types.') + line.count('Llm_orchestration.')
                    print(f"  {path}: updated")

    # Also check test/ and bin/
    for d in ['test', 'bin']:
        if os.path.isdir(d):
            for root, dirs, files in os.walk(d):
                for f in sorted(files):
                    if f.endswith('.ml') or f.endswith('.mli'):
                        path = os.path.join(root, f)
                        if replace_in_file(path):
                            changed += 1
                            print(f"  {path}: updated")

    print(f"\nTotal files changed: {changed}")

if __name__ == '__main__':
    main()
