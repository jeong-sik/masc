import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'
import { rhwpNoticesPlugin } from '../../dev/rhwp-notices-plugin'

export default defineConfig({
  root: fileURLToPath(new URL('../office-roundtrip/', import.meta.url)),
  base: '/dashboard/',
  plugins: [preact(), rhwpNoticesPlugin()],
  build: {
    outDir: fileURLToPath(new URL('../../../artifacts/hwp-import/browser-build/', import.meta.url)),
    emptyOutDir: false,
  },
})
