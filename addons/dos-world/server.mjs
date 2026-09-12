import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { DosWorld, actionSchema, observeSchema } from './world.mjs';

// Reserve stdout exclusively for the SDK transport, including during WASM load.
console.log = console.error.bind(console);
const world = new DosWorld();
const server = new Server({ name: 'masc-dos-world', version: '0.1.0' }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [
  { name: 'lane_observe', description: 'Read the owned DOS machine’s latest verified file and screen capture.',
    inputSchema: observeSchema, annotations: { readOnlyHint: true, destructiveHint: false,
      idempotentHint: true, openWorldHint: false } },
  { name: 'lane_act', description: 'Send N to this DOS machine and confirm the guest counter and rendered bar changed.',
    inputSchema: actionSchema, annotations: { readOnlyHint: false, destructiveHint: false,
      idempotentHint: true, openWorldHint: false } }
] }));
server.setRequestHandler(CallToolRequestSchema, async request => {
  try {
    let output;
    switch (request.params.name) {
      case 'lane_observe': output = await world.observe(request.params.arguments); break;
      case 'lane_act': output = await world.act(request.params.arguments); break;
      default: throw new Error('Unknown tool');
    }
    // Avoid duplicating base64 image bytes in the textual MCP projection.
    return { content: [], structuredContent: output, isError: false };
  } catch (error) {
    return { content: [{ type: 'text', text: error.message }], isError: true };
  }
});
const transport = new StdioServerTransport();
process.stdin.once('end', () => { void world.close().finally(() => server.close()); });
process.once('SIGTERM', () => { void world.close().finally(() => server.close()); });
await server.connect(transport);
