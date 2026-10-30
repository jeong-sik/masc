import original from "/tmp/masc-goal-outcomes-20261024/dashboard/vite.config.ts";
import {defineConfig,mergeConfig} from "/tmp/masc-goal-outcomes-20261024/dashboard/node_modules/vite/dist/node/index.js";
const target="http://127.0.0.1:62470";
export default defineConfig(env=>{
 const base=typeof original === "function"?original(env):original;
 return mergeConfig(base,{server:{proxy:{"/mcp":{target,changeOrigin:true,configure(proxy){
  proxy.on("proxyReq",(outgoing,incoming)=>{
   let same=false;
   try{const origin=new URL(incoming.headers.origin??"");same=(origin.protocol==="http:"||origin.protocol==="https:")&&origin.host===incoming.headers.host;}catch{}
   if(!same){outgoing.destroy();return;}
   outgoing.setHeader("origin",new URL(target).origin);
  });
 }}}}});
});
