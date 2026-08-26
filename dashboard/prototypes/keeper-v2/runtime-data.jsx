/* MASC v2 — Runtime config model, lifted 1:1 from config/runtime.toml +
   lib/runtime/runtime_schema.mli (Provider × Model × Binding). A runtime id is
   a binding key "provider.model" (Runtime_schema.binding_key). Routing lanes
   ([runtime].default/librarian/cross_verifier/media_failover) and keeper
   assignments ([runtime.assignments]) reference those ids. Consumed by the
   Runtime editor (runtime-editor.jsx) and the per-keeper capability readout. */

// thinking-control-format → label (Runtime_schema.thinking_control_format)
const RT_TCF = {
  none: '없음',
  reasoning_effort: 'reasoning-effort',
  thinking_object: 'thinking-object',
  chat_template_token: 'chat-template-token',
  chat_template_kwargs: 'chat-template-kwargs',
};

// [providers.*]
const RT_PROVIDERS = [
  { id: 'ollama_cloud', display_name: 'Ollama Cloud', protocol: 'openai-compatible-http', api_format: 'Chat_completions_api', endpoint: 'https://ollama.com/v1', credential: { type: 'env', key: 'OLLAMA_CLOUD_API_KEY' }, caps: { mcpTools: true, toolEvents: true, mcpHeaders: true } },
  { id: 'deepseek', display_name: 'DeepSeek API', protocol: 'openai-compatible-http', api_format: 'Chat_completions_api', endpoint: 'https://api.deepseek.com', credential: { type: 'env', key: 'DEEPSEEK_API_KEY' }, caps: { mcpTools: true, toolEvents: true, mcpHeaders: true } },
  { id: 'glm-coding', display_name: 'GLM Coding Plan', protocol: 'openai-compatible-http', api_format: 'Chat_completions_api', endpoint: 'https://api.z.ai/api/coding/paas/v4', credential: { type: 'env', key: 'ZAI_API_KEY_SB' }, caps: { mcpTools: true, toolEvents: true, mcpHeaders: true } },
  { id: 'ollama', display_name: 'Local Ollama', protocol: 'ollama-http', api_format: 'Ollama_api', endpoint: 'http://localhost:11434', credential: null, caps: { mcpTools: false, toolEvents: false, mcpHeaders: false } },
];

// [models.*] — curated to the bound set + a couple of catalog spares.
// caps: { maxOut, toolChoice, extThinking, reasoningBudget, tcf, json, structured, image, multimodal, topK, seed }
const RT_MODELS = [
  { id: 'deepseek-v4-pro', api_name: 'deepseek-v4-pro', max_context: 1000000, tools: true, thinking: true, preserve: false, streaming: true, caps: { maxOut: 384000, toolChoice: true, extThinking: true, reasoningBudget: true, tcf: 'reasoning_effort', json: true, structured: true, image: false, multimodal: false } },
  { id: 'deepseek-v4-flash', api_name: 'deepseek-v4-flash', max_context: 1048576, tools: true, thinking: true, preserve: false, streaming: true, caps: { maxOut: 384000, toolChoice: false, extThinking: true, reasoningBudget: true, tcf: 'reasoning_effort', json: false, structured: false, image: false, multimodal: false } },
  { id: 'glm-4-7-coding', api_name: 'glm-4.7', max_context: 200000, tools: true, thinking: true, preserve: true, streaming: true, caps: { maxOut: 128000, toolChoice: false, extThinking: true, reasoningBudget: false, tcf: 'reasoning_effort', json: true, structured: false, image: false, multimodal: false } },
  { id: 'glm-5-turbo', api_name: 'GLM-5-Turbo', max_context: 203000, tools: true, thinking: true, preserve: true, streaming: true, caps: { maxOut: 131072, toolChoice: false, extThinking: true, reasoningBudget: false, tcf: 'reasoning_effort', json: true, structured: false, image: false, multimodal: false } },
  { id: 'minimax-m3', api_name: 'minimax-m3', max_context: 524288, tools: true, thinking: true, preserve: false, streaming: true, caps: { maxOut: 131072, toolChoice: false, extThinking: true, reasoningBudget: true, tcf: 'reasoning_effort', json: true, structured: true, image: true, multimodal: true } },
  { id: 'kimi-k2-6', api_name: 'kimi-k2.6', max_context: 262144, tools: true, thinking: true, preserve: false, streaming: true, caps: { maxOut: 32768, toolChoice: false, extThinking: true, reasoningBudget: true, tcf: 'reasoning_effort', json: true, structured: true, image: true, multimodal: true } },
  { id: 'gemma4-26b-a4b-qat', api_name: 'hf.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL', max_context: 262144, tools: true, thinking: true, preserve: false, streaming: true, caps: { maxOut: null, toolChoice: false, extThinking: true, reasoningBudget: false, tcf: 'chat_template_token', json: false, structured: false, image: true, multimodal: true, topK: true, seed: true } },
  { id: 'ollama-cloud-glm-5-2', api_name: 'glm-5.2', max_context: 1000000, tools: true, thinking: true, preserve: false, streaming: true, caps: { maxOut: null, toolChoice: false, extThinking: true, reasoningBudget: true, tcf: 'reasoning_effort', json: false, structured: false, image: false, multimodal: false } },
  { id: 'ollama-cloud-gpt-oss-120b', api_name: 'gpt-oss:120b', max_context: 131072, tools: true, thinking: true, preserve: false, streaming: true, caps: { maxOut: null, toolChoice: false, extThinking: true, reasoningBudget: true, tcf: 'reasoning_effort', json: false, structured: false, image: false, multimodal: false } },
  { id: 'ollama-cloud-qwen3-5-397b', api_name: 'qwen3.5:397b', max_context: 262144, tools: true, thinking: true, preserve: false, streaming: true, caps: { maxOut: null, toolChoice: false, extThinking: true, reasoningBudget: true, tcf: 'reasoning_effort', json: false, structured: false, image: true, multimodal: true } },
];

// [<provider>.<model>] binding tables → runtime ids. is_default ← [runtime].default
const RT_BINDINGS = [
  { provider_id: 'ollama_cloud', model_id: 'deepseek-v4-flash', is_default: true, max_concurrent: null, num_ctx: null, price_in: 0.14, price_out: 0.28 },
  { provider_id: 'deepseek', model_id: 'deepseek-v4-pro', is_default: false, max_concurrent: null, num_ctx: null, price_in: 0.435, price_out: 0.87 },
  { provider_id: 'deepseek', model_id: 'deepseek-v4-flash', is_default: false, max_concurrent: null, num_ctx: null, price_in: 0.14, price_out: 0.28 },
  { provider_id: 'glm-coding', model_id: 'glm-4-7-coding', is_default: false, max_concurrent: null, num_ctx: null, price_in: 0.6, price_out: 2.2 },
  { provider_id: 'glm-coding', model_id: 'glm-5-turbo', is_default: false, max_concurrent: null, num_ctx: null, price_in: 1.2, price_out: 4.0 },
  { provider_id: 'ollama_cloud', model_id: 'minimax-m3', is_default: false, max_concurrent: null, num_ctx: null, price_in: null, price_out: null },
  { provider_id: 'ollama_cloud', model_id: 'kimi-k2-6', is_default: false, max_concurrent: null, num_ctx: null, price_in: null, price_out: null },
  { provider_id: 'ollama', model_id: 'gemma4-26b-a4b-qat', is_default: false, max_concurrent: 1, num_ctx: 262144, price_in: 0, price_out: 0 },
  { provider_id: 'ollama_cloud', model_id: 'ollama-cloud-glm-5-2', is_default: false, max_concurrent: null, num_ctx: null, price_in: null, price_out: null },
  { provider_id: 'ollama_cloud', model_id: 'ollama-cloud-gpt-oss-120b', is_default: false, max_concurrent: null, num_ctx: null, price_in: null, price_out: null },
];

// [runtime] routing lanes
const RT_ROUTING = {
  default: 'ollama_cloud.deepseek-v4-flash',
  librarian: 'ollama_cloud.minimax-m3',      // memory-os 라이브러리안 — JSON mode 필요
  cross_verifier: 'deepseek.deepseek-v4-pro', // 반-합리화 평가자 — JSON mode 필요
  media_failover: [],
};

// fictional → real runtime id (used by the one-time migration of keeper data)
const RT_LEGACY_MAP = {
  'agent-core·seoul-1': 'ollama_cloud.deepseek-v4-flash',
  'agent-core·tokyo-2': 'deepseek.deepseek-v4-pro',
  'local·docker': 'ollama.gemma4-26b-a4b-qat',
};

// ── helpers ──────────────────────────────────────────────────────────
function rtBindingKey(b) { return b.provider_id + '.' + b.model_id; }
function rtRuntimeIds() { return RT_BINDINGS.map(rtBindingKey); }
function rtBindingOf(id) { return RT_BINDINGS.find(b => rtBindingKey(b) === id) || null; }
function rtModelOf(modelId) { return RT_MODELS.find(m => m.id === modelId) || null; }
function rtProviderOf(pid) { return RT_PROVIDERS.find(p => p.id === pid) || null; }
// capability bundle for a runtime id (binding → model caps + provider)
function rtCaps(id) {
  const b = rtBindingOf(id); if (!b) return null;
  const m = rtModelOf(b.model_id); if (!m) return null;
  const p = rtProviderOf(b.provider_id);
  return {
    runtimeId: id, provider: p, model: m, binding: b, caps: m.caps,
    multimodal: !!(m.caps.multimodal || m.caps.image),
    json: !!m.caps.json,
    effortMode: m.caps.tcf,                 // 'reasoning_effort' | 'thinking_object' | ...
    effortAdjustable: m.caps.tcf === 'reasoning_effort' || !!m.caps.reasoningBudget,
    maxContext: m.max_context,
  };
}
function rtIsJsonCapable(id) { const c = rtCaps(id); return !!(c && c.json); }

Object.assign(window, {
  RT_TCF, RT_PROVIDERS, RT_MODELS, RT_BINDINGS, RT_ROUTING, RT_LEGACY_MAP,
  rtBindingKey, rtRuntimeIds, rtBindingOf, rtModelOf, rtProviderOf, rtCaps, rtIsJsonCapable,
});
