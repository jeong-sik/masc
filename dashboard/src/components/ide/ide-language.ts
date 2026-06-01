/**
 * Shared LSP/IDE language constants.
 *
 * `DEFAULT_LANGUAGE_ID` was duplicated byte-for-byte in
 * ide-lsp-client.ts (textDocument/didOpen fallback when path-based
 * detection misses) and ide-data-workspace-store.ts (initial value for
 * the code document store + workspace-file response fallback).
 * Both branches use the LSP "plain text" identifier `'text'`; a drift
 * here would silently change the fallback language between the
 * workspace store's optimistic open and the client's actual didOpen.
 *
 * Keep this module dependency-free so it can grow into the natural
 * owner for LSP-related constants (file-extension → language id maps,
 * encoding defaults) without forming cycles with the LSP client.
 */
export const DEFAULT_LANGUAGE_ID = 'text' as const
