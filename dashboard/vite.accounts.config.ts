import { defineConfig } from 'vite'

// The console of a signed-in person on the account server: a second entry of
// this workspace, apart from the operator dashboard. It is built to be
// answered under /accounts/console with a policy that lets a browser take
// scripts and styles from the answering server alone, and before any login.
// So the build inlines nothing (no data: URL, no script or style in the page)
// and writes no source map.
export default defineConfig({
  root: 'src/accounts',
  base: '/accounts/console/',
  build: {
    // Under the bundle of the dashboard, which the build of the dashboard
    // empties first: `pnpm build` runs that build and then this one.
    outDir: '../../../assets/dashboard/accounts',
    emptyOutDir: true,
    sourcemap: false,
    assetsInlineLimit: 0,
    modulePreload: { polyfill: false },
    target: 'es2022',
  },
})
