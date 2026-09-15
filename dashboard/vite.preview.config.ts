import { defineConfig, mergeConfig } from 'vite'
import dashboardConfig from './vite.config'

// CI preview only: release builds continue to use vite.config.ts.
export default defineConfig(async env => mergeConfig(
  typeof dashboardConfig === 'function' ? await dashboardConfig(env) : dashboardConfig,
  { build: { rollupOptions: { input: {
    dashboard: 'index.html',
    editSnapshots: 'dev-fixtures/chat-edit-snapshots.html',
  } } } },
))
