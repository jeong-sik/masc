import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath } from 'node:url'
const root = fileURLToPath(new URL('.', import.meta.url))
const dashboard = fileURLToPath(new URL('../../', import.meta.url))
export default defineConfig({
  root, base: '/',
  cacheDir: fileURLToPath(new URL('../../../artifacts/dashboard/board-reactions-source/vite-cache/', import.meta.url)),
  plugins: [preact(), tailwindcss()],
  resolve: { alias: { '@masc-dashboard': `${dashboard}src` }, dedupe: ['preact', 'htm', '@preact/signals'] },
  server: { host: '127.0.0.1', port: 0, strictPort: true, fs: { allow: [root, dashboard] } },
})
