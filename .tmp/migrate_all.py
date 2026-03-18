"""Replace ALL Llm_client.X with actual module paths (Llm_types/Llm_orchestration/Llm_provider_bridge).
Handles lib/ (direct), test/ and bin/ (may need Masc_mcp. prefix).
"""
import os, re

TYPES = {
    'message', 'model_spec', 'provider', 'role', 'tool_def', 'tool_call',
    'token_usage', 'completion_request', 'completion_response',
    'Llama', 'Claude', 'OpenAI', 'Gemini', 'Glm_cloud', 'OpenRouter', 'Custom',
    'System', 'User', 'Assistant', 'Tool',
    'total_tokens', 'text_of_response', 'text_of_message',
    'string_of_provider', 'string_of_role',
    'system_msg', 'user_msg', 'assistant_msg', 'tool_msg',
    'sanitize_text_utf8', 'sanitize_message_utf8', 'sanitize_messages_utf8',
    'estimate_tokens', 'model_spec_of_string',
    'normalize_request', 'clamp_llama_max_tokens',
    'llama_default', 'claude_opus', 'claude_sonnet', 'openai_default',
    'glm_cloud', 'gemini_pro',
    'default_local_model_spec', 'default_execution_model_spec',
    'default_verifier_model_spec', 'first_available_model_spec',
    'configured_default_model_label', 'default_execution_model_labels',
    'default_verifier_model_labels', 'available_model_specs_of_strings',
    'content', 'tool_calls', 'usage', 'model_used', 'latency_ms',
    'model', 'messages', 'temperature', 'max_tokens', 'tools',
    'response_format', 'call_id', 'call_name', 'call_arguments',
    'provider', 'model_id', 'max_context', 'api_url', 'api_key_env',
    'cost_per_1k_input', 'cost_per_1k_output',
    'tool_name', 'tool_description', 'parameters',
    'input_tokens', 'output_tokens',
}

ORCHESTRATION = {
    'complete', 'cascade', 'run_prompt_cascade',
    'with_llm_permit', 'llm_semaphore_available', 'llm_permits_in_use',
    'max_concurrent_llm',
    'completion_cache_key', 'cache_key_of_request',
    'token_usage_to_json', 'token_usage_of_json',
    'tool_call_to_json', 'tool_call_of_json',
    'completion_response_to_cache_json', 'completion_response_of_cache_json',
    'filter_by_provider_health',
}

CLIENT_ONLY = {
    'to_oas_provider', 'to_oas_message', 'of_oas_message',
    'of_oas_usage', 'to_oas_usage',
}

def has_open_masc(content):
    return bool(re.search(r'^open Masc_mcp\b', content, re.MULTILINE))

def replace_in_file(filepath):
    with open(filepath) as f:
        content = f.read()
    if filepath.endswith('llm_client.ml') or filepath.endswith('llm_client.mli'):
        return False
    original = content
    is_external = '/test/' in filepath or '/bin/' in filepath
    has_open = has_open_masc(content) if is_external else True

    def replacer(m):
        sym = m.group(1)
        if sym in CLIENT_ONLY:
            return m.group(0)
        elif sym in ORCHESTRATION:
            mod = 'Llm_orchestration'
        elif sym in TYPES:
            mod = 'Llm_types'
        else:
            return m.group(0)
        if is_external and not has_open:
            return f'Masc_mcp.{mod}.{sym}'
        return f'{mod}.{sym}'

    content = re.sub(r'Llm_client\.(\w+)', replacer, content)
    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        return True
    return False

changed = 0
for d in ['lib', 'test', 'bin']:
    for root, _, files in os.walk(d):
        for f in sorted(files):
            if f.endswith('.ml') or f.endswith('.mli'):
                path = os.path.join(root, f)
                if replace_in_file(path):
                    changed += 1
                    print(f"  {path}")
print(f"\nChanged: {changed} files")
