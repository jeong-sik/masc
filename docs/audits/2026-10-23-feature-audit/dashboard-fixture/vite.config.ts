import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'
import tailwindcss from '@tailwindcss/vite'
export default defineConfig({plugins:[preact(),tailwindcss()],cacheDir:'.audit-feature-20261023/vite-cache',publicDir:false,server:{host:'127.0.0.1',port:51923,strictPort:true}})
