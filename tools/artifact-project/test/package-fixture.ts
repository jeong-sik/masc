import type { ProjectRequest } from '../src/project.ts'
export const pixel = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aFEkAAAAASUVORK5CYII=', 'base64')
export function viteProject(): ProjectRequest {
  const source: Record<string, string | Buffer> = {
    'package.json': JSON.stringify({ name: 'vite-artifact-fixture', private: true, type: 'module', scripts: {
      prebuild: 'node prebuild.cjs', build: 'vite build', postbuild: 'node postbuild.cjs',
    }, dependencies: { react: '19.3.1', 'react-dom': '19.3.1', clsx: '2.1.1' }, devDependencies: { vite: '8.3.5', '@vitejs/plugin-react': '6.1.2' } }),
    'prebuild.cjs': 'require("fs").writeFileSync("before.txt","prebuild reached")',
    'postbuild.cjs': 'require("fs").copyFileSync("before.txt","dist/lifecycle.txt")',
    'vite.config.mjs': `import{defineConfig}from'vite';import react from'@vitejs/plugin-react';import{resolve}from'node:path';
      export default defineConfig({plugins:[react(),{name:'fixture-label',resolveId(id){if(id==='virtual:build-label')return '\\0label'},load(id){if(id==='\\0label')return 'export default "설정 적용됨"'}}],
        resolve:{alias:{'@':resolve(import.meta.dirname,'src')}},build:{assetsInlineLimit:0,rolldownOptions:{input:{main:resolve(import.meta.dirname,'index.html'),extra:resolve(import.meta.dirname,'nested/index.html')}}}});`,
    'index.html': '<!doctype html><html lang="ko"><head><title>Vite 빌드 앱</title></head><body><div id="root"></div><img id="public" src="/logo.svg"><script type="module" src="/src/main.tsx"></script></body></html>',
    'nested/index.html': '<!doctype html><html><body><p>두 번째 페이지 😀</p></body></html>',
    'src/main.tsx': `import{useState}from'react';import{createRoot}from'react-dom/client';import{flushSync}from'react-dom';import clsx from'clsx';import label from'virtual:build-label';import title from'@/title';import './style.css';import picture from'./pixel.png';
      function App(){const[n,setN]=useState(0);const[msg,setMsg]=useState(label);return <button id="counter" className={clsx('counter',n>0&&'changed')} onClick={async()=>{const lazy=await import('./lazy');flushSync(()=>{setN(n+1);setMsg(lazy.message)})}}><img src={picture}/>{title} {n} {msg} 😀</button>}
      flushSync(()=>createRoot(document.getElementById('root')!).render(<App/>));`,
    'src/title.ts': 'export default "함께 만든 앱";',
    'src/lazy.ts': 'export const message:string="분할 모듈 실행";',
    'src/style.css': '.counter{color:#174b68;background-image:url(./pixel.png)}',
    'src/pixel.png': pixel,
    'public/logo.svg': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4"><path fill="blue" d="M0 0h4v4H0z"/></svg>',
    'public/data.json': '{"message":"런타임 데이터"}',
  }
  return { schema: 'masc.artifact_project.v1', build: { kind: 'package_script', script: 'build', output_directory: 'dist', entry_html: 'index.html' }, install_scripts: false,
    files: Object.entries(source).map(([path, content]) => ({ path, content_base64: Buffer.from(content).toString('base64') })) }
}
