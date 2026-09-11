# Typed image results through tool execution

A tool could return only text even though canonical conversation ToolResult already supports image blocks. Agent execution, durable settlement, and next-turn assembly discarded structured blocks. This prevents an evaluator from inspecting an image returned by a read tool.

The tool output now carries optional canonical content blocks. Successful execution preserves them through hooks, durable settlement/replay, context injection, and conversation assembly. Text-only producers explicitly return no blocks. Failure classification remains unchanged. Checkpoints persist the independent text summary as well as the blocks; image-only blocks must not erase that summary on reload.

The feature scenario executes a tool returning a real one-pixel PNG, restores its conversation through the checkpoint codec, and checks the next Anthropic request contains the exact PNG image data. The existing durable execution scenario now persists an image result, closes/reopens the journal, and checks the result is replayed without executing the effect again. These are transport tests, not semantic image-recognition evidence.

This slice does not expose a Goal image lookup or implement PDF rendering. OpenAI/Ollama and Gemini currently require dependent provider projection work before their image tool results constitute visual input. Goal/Task shared contained PNG lookup follows that provider work. No runtime upgrade or live acceptance is claimed here.

Validation: source parsing and whitespace checks only at authoring time. Behavioral tests require exact-head CI; no local build was run.
