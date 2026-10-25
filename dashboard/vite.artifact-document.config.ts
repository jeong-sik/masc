import { defineConfig } from 'vite'

export default defineConfig({
  ssr: { noExternal: true },
  build: {
    ssr: 'src/workers/artifact-document.ts', target: 'node22',
    outDir: 'dist-artifact-document', emptyOutDir: true,
    rollupOptions: { output: { entryFileNames: 'artifact-document.mjs', inlineDynamicImports: true } },
  },
})
