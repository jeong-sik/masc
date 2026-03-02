(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var De,N,ys,bs,lt,Kn,xs,ks,ws,An,en,nn,Jt={},Ss=[],Da=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Pe=Array.isArray;function nt(t,e){for(var n in e)t[n]=e[n];return t}function Tn(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Cs(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?De.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return fe(t,r,s,a,null)}function fe(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++ys,__i:-1,__u:0};return a==null&&N.vnode!=null&&N.vnode(i),i}function ee(t){return t.children}function Pt(t,e){this.props=t,this.context=e}function bt(t,e){if(e==null)return t.__?bt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?bt(t):null}function As(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return As(t)}}function Gn(t){(!t.__d&&(t.__d=!0)&&lt.push(t)&&!$e.__r++||Kn!=N.debounceRendering)&&((Kn=N.debounceRendering)||xs)($e)}function $e(){for(var t,e,n,s,a,i,r,l=1;lt.length;)lt.length>l&&lt.sort(ks),t=lt.shift(),l=lt.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=nt({},s)).__v=s.__v+1,N.vnode&&N.vnode(n),Nn(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??bt(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,Rs(i,n,r),s.__e=s.__=null,n.__e!=a&&As(n)));$e.__r=0}function Ts(t,e,n,s,a,i,r,l,d,u,f){var c,p,m,h,R,L,A,S=s&&s.__k||Ss,z=e.length;for(d=Pa(n,e,S,d,z),c=0;c<z;c++)(m=n.__k[c])!=null&&(p=m.__i==-1?Jt:S[m.__i]||Jt,m.__i=c,L=Nn(t,m,p,a,i,r,l,d,u,f),h=m.__e,m.ref&&p.ref!=m.ref&&(p.ref&&Rn(p.ref,null,m),f.push(m.ref,m.__c||h,m)),R==null&&h!=null&&(R=h),(A=!!(4&m.__u))||p.__k===m.__k?d=Ns(m,d,t,A):typeof m.type=="function"&&L!==void 0?d=L:h&&(d=h.nextSibling),m.__u&=-7);return n.__e=R,d}function Pa(t,e,n,s,a){var i,r,l,d,u,f=n.length,c=f,p=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=fe(null,r,null,null,null):Pe(r)?r=t.__k[i]=fe(ee,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=fe(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+p,r.__=t,r.__b=t.__b+1,l=null,(u=r.__i=Ea(r,n,d,c))!=-1&&(c--,(l=n[u])&&(l.__u|=2)),l==null||l.__v==null?(u==-1&&(a>f?p--:a<f&&p++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?p--:u==d+1?p++:(u>d?p--:p++,r.__u|=4))):t.__k[i]=null;if(c)for(i=0;i<f;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=bt(l)),Ds(l,l));return s}function Ns(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=Ns(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=bt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Ea(t,e,n,s){var a,i,r,l=t.key,d=t.type,u=e[n],f=u!=null&&(2&u.__u)==0;if(u===null&&l==null||f&&l==u.key&&d==u.type)return n;if(s>(f?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((u=e[r=a>=0?a--:i++])!=null&&(2&u.__u)==0&&l==u.key&&d==u.type)return r}return-1}function Wn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Da.test(e)?n:n+"px"}function oe(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||Wn(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||Wn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(ws,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=An,t.addEventListener(e,i?nn:en,i)):t.removeEventListener(e,i?nn:en,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Vn(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=An++;else if(e.t<n.u)return;return n(N.event?N.event(e):e)}}}function Nn(t,e,n,s,a,i,r,l,d,u){var f,c,p,m,h,R,L,A,S,z,q,D,K,ot,rt,G,et,T=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[l=e.__e=n.__e]),(f=N.__b)&&f(e);t:if(typeof T=="function")try{if(A=e.props,S="prototype"in T&&T.prototype.render,z=(f=T.contextType)&&s[f.__c],q=f?z?z.props.value:f.__:s,n.__c?L=(c=e.__c=n.__c).__=c.__E:(S?e.__c=c=new T(A,q):(e.__c=c=new Pt(A,q),c.constructor=T,c.render=ja),z&&z.sub(c),c.state||(c.state={}),c.__n=s,p=c.__d=!0,c.__h=[],c._sb=[]),S&&c.__s==null&&(c.__s=c.state),S&&T.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=nt({},c.__s)),nt(c.__s,T.getDerivedStateFromProps(A,c.__s))),m=c.props,h=c.state,c.__v=e,p)S&&T.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),S&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(S&&T.getDerivedStateFromProps==null&&A!==m&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(A,q),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(A,c.__s,q)===!1){for(e.__v!=n.__v&&(c.props=A,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(I){I&&(I.__=e)}),D=0;D<c._sb.length;D++)c.__h.push(c._sb[D]);c._sb=[],c.__h.length&&r.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(A,c.__s,q),S&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(m,h,R)})}if(c.context=q,c.props=A,c.__P=t,c.__e=!1,K=N.__r,ot=0,S){for(c.state=c.__s,c.__d=!1,K&&K(e),f=c.render(c.props,c.state,c.context),rt=0;rt<c._sb.length;rt++)c.__h.push(c._sb[rt]);c._sb=[]}else do c.__d=!1,K&&K(e),f=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++ot<25);c.state=c.__s,c.getChildContext!=null&&(s=nt(nt({},s),c.getChildContext())),S&&!p&&c.getSnapshotBeforeUpdate!=null&&(R=c.getSnapshotBeforeUpdate(m,h)),G=f,f!=null&&f.type===ee&&f.key==null&&(G=Ls(f.props.children)),l=Ts(t,Pe(G)?G:[G],e,n,s,a,i,r,l,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&r.push(c),L&&(c.__E=c.__=null)}catch(I){if(e.__v=null,d||i!=null)if(I.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(et=i.length;et--;)Tn(i[et]);sn(e)}else e.__e=n.__e,e.__k=n.__k,I.then||sn(e);N.__e(I,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=Ia(n.__e,e,n,s,a,i,r,d,u);return(f=N.diffed)&&f(e),128&e.__u?void 0:l}function sn(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(sn)}function Rs(t,e,n){for(var s=0;s<n.length;s++)Rn(n[s],n[++s],n[++s]);N.__c&&N.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){N.__e(i,a.__v)}})}function Ls(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Pe(t)?t.map(Ls):nt({},t)}function Ia(t,e,n,s,a,i,r,l,d){var u,f,c,p,m,h,R,L=n.props||Jt,A=e.props,S=e.type;if(S=="svg"?a="http://www.w3.org/2000/svg":S=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((m=i[u])&&"setAttribute"in m==!!S&&(S?m.localName==S:m.nodeType==3)){t=m,i[u]=null;break}}if(t==null){if(S==null)return document.createTextNode(A);t=document.createElementNS(a,S,A.is&&A),l&&(N.__m&&N.__m(e,i),l=!1),i=null}if(S==null)L===A||l&&t.data==A||(t.data=A);else{if(i=i&&De.call(t.childNodes),!l&&i!=null)for(L={},u=0;u<t.attributes.length;u++)L[(m=t.attributes[u]).name]=m.value;for(u in L)if(m=L[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=m;else if(!(u in A)){if(u=="value"&&"defaultValue"in A||u=="checked"&&"defaultChecked"in A)continue;oe(t,u,null,m,a)}}for(u in A)m=A[u],u=="children"?p=m:u=="dangerouslySetInnerHTML"?f=m:u=="value"?h=m:u=="checked"?R=m:l&&typeof m!="function"||L[u]===m||oe(t,u,m,L[u],a);if(f)l||c&&(f.__html==c.__html||f.__html==t.innerHTML)||(t.innerHTML=f.__html),e.__k=[];else if(c&&(t.innerHTML=""),Ts(e.type=="template"?t.content:t,Pe(p)?p:[p],e,n,s,S=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&bt(n,0),l,d),i!=null)for(u=i.length;u--;)Tn(i[u]);l||(u="value",S=="progress"&&h==null?t.removeAttribute("value"):h!=null&&(h!==t[u]||S=="progress"&&!h||S=="option"&&h!=L[u])&&oe(t,u,h,L[u],a),u="checked",R!=null&&R!=t[u]&&oe(t,u,R,L[u],a))}return t}function Rn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){N.__e(a,n)}}function Ds(t,e,n){var s,a;if(N.unmount&&N.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||Rn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){N.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&Ds(s[a],e,n||typeof t.type!="function");n||Tn(t.__e),t.__c=t.__=t.__e=void 0}function ja(t,e,n){return this.constructor(t,n)}function Oa(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),N.__&&N.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],Nn(e,t=e.__k=Cs(ee,null,[t]),a||Jt,Jt,e.namespaceURI,a?null:e.firstChild?De.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),Rs(i,t,r)}De=Ss.slice,N={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},ys=0,bs=function(t){return t!=null&&t.constructor===void 0},Pt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=nt({},this.state),typeof t=="function"&&(t=t(nt({},n),this.props)),t&&nt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Gn(this))},Pt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Gn(this))},Pt.prototype.render=ee,lt=[],xs=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,ks=function(t,e){return t.__v.__b-e.__v.__b},$e.__r=0,ws=/(PointerCapture)$|Capture$/i,An=0,en=Vn(!1),nn=Vn(!0);var Ps=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++i]]=l:r===6?s[1][e[++i]]+=l+"":r?(a=t.apply(l,Ps(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},Jn=new Map;function Ma(t){var e=Jn.get(this);return e||(e=new Map,Jn.set(this,e)),(e=Ps(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",l="",d=[0],u=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,r):i===3&&(p||r)?(d.push(3,p,r),i=2):i===2&&r==="..."&&p?d.push(4,p,0):i===2&&r&&!p?d.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(d.push(i,0,r,a),i=6),p&&(d.push(i,p,0,a),i=6)),r=""},f=0;f<n.length;f++){f&&(i===1&&u(),u(f));for(var c=0;c<n[f].length;c++)s=n[f][c],i===1?s==="<"?(u(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(u(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[f][c+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Ma.bind(Cs),Yt,P,ze,Yn,an=0,Es=[],E=N,Qn=E.__b,Xn=E.__r,Zn=E.diffed,ts=E.__c,es=E.unmount,ns=E.__;function Ln(t,e){E.__h&&E.__h(P,t,an||e),an=0;var n=P.__H||(P.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function re(t){return an=1,za(Os,t)}function za(t,e,n){var s=Ln(Yt++,2);if(s.t=t,!s.__c&&(s.__=[Os(void 0,e),function(l){var d=s.__N?s.__N[0]:s.__[0],u=s.t(d,l);d!==u&&(s.__N=[u,s.__[1]],s.__c.setState({}))}],s.__c=P,!P.__f)){var a=function(l,d,u){if(!s.__c.__H)return!0;var f=s.__c.__H.__.filter(function(p){return!!p.__c});if(f.every(function(p){return!p.__N}))return!i||i.call(this,l,d,u);var c=s.__c.props!==l;return f.forEach(function(p){if(p.__N){var m=p.__[0];p.__=p.__N,p.__N=void 0,m!==p.__[0]&&(c=!0)}}),i&&i.call(this,l,d,u)||c};P.__f=!0;var i=P.shouldComponentUpdate,r=P.componentWillUpdate;P.componentWillUpdate=function(l,d,u){if(this.__e){var f=i;i=void 0,a(l,d,u),i=f}r&&r.call(this,l,d,u)},P.shouldComponentUpdate=a}return s.__N||s.__}function xt(t,e){var n=Ln(Yt++,3);!E.__s&&js(n.__H,e)&&(n.__=t,n.u=e,P.__H.__h.push(n))}function Is(t,e){var n=Ln(Yt++,7);return js(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Fa(){for(var t;t=Es.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(me),t.__H.__h.forEach(on),t.__H.__h=[]}catch(e){t.__H.__h=[],E.__e(e,t.__v)}}E.__b=function(t){P=null,Qn&&Qn(t)},E.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),ns&&ns(t,e)},E.__r=function(t){Xn&&Xn(t),Yt=0;var e=(P=t.__c).__H;e&&(ze===P?(e.__h=[],P.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(me),e.__h.forEach(on),e.__h=[],Yt=0)),ze=P},E.diffed=function(t){Zn&&Zn(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(Es.push(e)!==1&&Yn===E.requestAnimationFrame||((Yn=E.requestAnimationFrame)||Ha)(Fa)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),ze=P=null},E.__c=function(t,e){e.some(function(n){try{n.__h.forEach(me),n.__h=n.__h.filter(function(s){return!s.__||on(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],E.__e(s,n.__v)}}),ts&&ts(t,e)},E.unmount=function(t){es&&es(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{me(s)}catch(a){e=a}}),n.__H=void 0,e&&E.__e(e,n.__v))};var ss=typeof requestAnimationFrame=="function";function Ha(t){var e,n=function(){clearTimeout(s),ss&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);ss&&(e=requestAnimationFrame(n))}function me(t){var e=P,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),P=e}function on(t){var e=P;t.__c=t.__(),P=e}function js(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function Os(t,e){return typeof e=="function"?e(t):e}var Ua=Symbol.for("preact-signals");function Ee(){if(st>1)st--;else{for(var t,e=!1;Et!==void 0;){var n=Et;for(Et=void 0,rn++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Fs(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(rn=0,st--,e)throw t}}function Ba(t){if(st>0)return t();st++;try{return t()}finally{Ee()}}var C=void 0;function Ms(t){var e=C;C=void 0;try{return t()}finally{C=e}}var Et=void 0,st=0,rn=0,he=0;function zs(t){if(C!==void 0){var e=t.n;if(e===void 0||e.t!==C)return e={i:0,S:t,p:C.s,n:void 0,t:C,e:void 0,x:void 0,r:e},C.s!==void 0&&(C.s.n=e),C.s=e,t.n=e,32&C.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=C.s,e.n=void 0,C.s.n=e,C.s=e),e}}function j(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}j.prototype.brand=Ua;j.prototype.h=function(){return!0};j.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Ms(function(){var s;(s=e.W)==null||s.call(e)}))};j.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&Ms(function(){var a;(a=e.Z)==null||a.call(e)}))}};j.prototype.subscribe=function(t){var e=this;return ne(function(){var n=e.value,s=C;C=void 0;try{t(n)}finally{C=s}},{name:"sub"})};j.prototype.valueOf=function(){return this.value};j.prototype.toString=function(){return this.value+""};j.prototype.toJSON=function(){return this.value};j.prototype.peek=function(){var t=C;C=void 0;try{return this.value}finally{C=t}};Object.defineProperty(j.prototype,"value",{get:function(){var t=zs(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(rn>100)throw new Error("Cycle detected");this.v=t,this.i++,he++,st++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Ee()}}}});function _(t,e){return new j(t,e)}function Fs(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Hs(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Us(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function pt(t,e){j.call(this,void 0),this.x=t,this.s=void 0,this.g=he-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}pt.prototype=new j;pt.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===he))return!0;if(this.g=he,this.f|=1,this.i>0&&!Fs(this))return this.f&=-2,!0;var t=C;try{Hs(this),C=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return C=t,Us(this),this.f&=-2,!0};pt.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}j.prototype.S.call(this,t)};pt.prototype.U=function(t){if(this.t!==void 0&&(j.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};pt.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(pt.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=zs(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function at(t,e){return new pt(t,e)}function Bs(t){var e=t.u;if(t.u=void 0,typeof e=="function"){st++;var n=C;C=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,Dn(t),s}finally{C=n,Ee()}}}function Dn(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Bs(t)}function qa(t){if(C!==this)throw new Error("Out-of-order effect");Us(this),C=t,this.f&=-2,8&this.f&&Dn(this),Ee()}function St(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}St.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};St.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Bs(this),Hs(this),st++;var t=C;return C=this,qa.bind(this,t)};St.prototype.N=function(){2&this.f||(this.f|=2,this.o=Et,Et=this)};St.prototype.d=function(){this.f|=8,1&this.f||Dn(this)};St.prototype.dispose=function(){this.d()};function ne(t,e){var n=new St(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var qs,le,Ka=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Ks=[];ne(function(){qs=this.N})();function Ct(t,e){N[t]=e.bind(null,N[t]||function(){})}function ye(t){if(le){var e=le;le=void 0,e()}le=t&&t.S()}function Gs(t){var e=this,n=t.data,s=Wa(n);s.value=n;var a=Is(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=at(function(){var m=s.value.value;return m===0?0:m===!0?"":m||""}),f=at(function(){return!Array.isArray(u.value)&&!bs(u.value)}),c=ne(function(){if(this.N=Ws,f.value){var m=u.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=m)}}),p=e.__$u.d;return e.__$u.d=function(){c(),p.call(this)},[f,u]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}Gs.displayName="ReactiveTextNode";Object.defineProperties(j.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Gs},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Ct("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof j&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});Ct("__r",function(t,e){if(t(e),e.type!==ee){ye();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return ne(function(){r=this},{name:i}),r.c=a,r})(function(){var a;Ka&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),ye(n)}});Ct("__e",function(t,e,n,s){ye(),t(e,n,s)});Ct("diffed",function(t,e){ye();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in s)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var u=i[d],f=s[d];u===void 0?(u=Ga(n,d,f),i[d]=u):u.o(f,a)}for(var c in s)a[c]=s[c]}}t(e)});function Ga(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(l,d){i.value=l,r=l.peek()},d:ne(function(){this.N=Ws;var l=i.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}Ct("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});Ct("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});Pt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function Wa(t,e){return Is(function(){return _(t,e)},[])}var Va=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Ja(){Ba(function(){for(var t;t=Ks.shift();)qs.call(t)})}function Ws(){Ks.push(this)===1&&(N.requestAnimationFrame||Va)(Ja)}const Ya=["overview","execution","board","activity","agents","tasks","goals","journal","trpg","council"],Vs={tab:"overview",params:{},postId:null};function as(t){return!!t&&Ya.includes(t)}function ln(t){try{return decodeURIComponent(t)}catch{return t}}function cn(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Qa(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Js(t,e){const n=t[0],s=e.tab,a=as(n)?n:as(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=ln(t[2]):t[0]==="post"&&t[1]&&(i=ln(t[1]))),{tab:a,params:e,postId:i}}function be(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Vs;const n=ln(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=cn(a),r=Qa(s);return Js(r,i)}function Xa(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Vs,params:cn(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=cn(e.replace(/^\?/,""));return Js(s,a)}function Ys(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const Z=_(be(window.location.hash));window.addEventListener("hashchange",()=>{Z.value=be(window.location.hash)});function Ie(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Ys(n)}function Za(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function ti(){if(window.location.hash&&window.location.hash!=="#"){Z.value=be(window.location.hash);return}const t=Xa(window.location.pathname,window.location.search);if(t){Z.value=t;const e=Ys(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Z.value=be(window.location.hash)}const ei=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Decisions",icon:"🏛️"},{id:"board",label:"Discussions",icon:"💬"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"activity",label:"Activity",icon:"📊"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function ni(){const t=Z.value.tab;return o`
    <div class="main-tab-bar">
      ${ei.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Ie(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const is="masc_dashboard_sse_session_id",si=1e3,ai=15e3,kt=_(!1),Pn=_(0),Qs=_(null),xe=_([]);function ii(){let t=sessionStorage.getItem(is);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(is,t)),t}const oi=200;function W(t,e){const n={agent:t,text:e,timestamp:Date.now()};xe.value=[n,...xe.value].slice(0,oi)}let X=null,$t=null,un=0;function Xs(){$t&&(clearTimeout($t),$t=null)}function ri(){if($t)return;un++;const t=Math.min(un,5),e=Math.min(ai,si*Math.pow(2,t));$t=setTimeout(()=>{$t=null,Zs()},e)}function Zs(){Xs(),X&&(X.close(),X=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",ii());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);X=i,i.onopen=()=>{X===i&&(un=0,kt.value=!0)},i.onerror=()=>{X===i&&(kt.value=!1,i.close(),X=null,ri())},i.onmessage=r=>{try{const l=JSON.parse(r.data);Pn.value++,Qs.value=l,li(l)}catch{}}}function li(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":W(n,"Joined");break;case"agent_left":W(n,"Left");break;case"broadcast":W(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":W(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":W(n,"New post");break;case"board_comment":W(n,"New comment");break;case"keeper_heartbeat":W(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":W(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":W(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":W(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:W(n,e)}}function ci(){Xs(),X&&(X.close(),X=null),kt.value=!1}function ta(){return new URLSearchParams(window.location.search)}function ea(){const t=ta(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function na(){return{...ea(),"Content-Type":"application/json"}}const ui=15e3,sa=3e4,di=6e4;async function En(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(a)}}function pi(){var e,n;const t=ta();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function it(t){const e=await En(t,{headers:ea()},ui);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function se(t,e){const n=await En(t,{method:"POST",headers:na(),body:JSON.stringify(e)},sa);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function vi(t,e,n,s=sa){const a=await En(t,{method:"POST",headers:{...na(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function fi(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function mi(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function H(t,e){const n=await vi("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},di),s=fi(n);return mi(s)}function _i(t="compact"){return it(`/api/v1/dashboard?mode=${t}`)}function wt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function gi(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function aa(t){if(!k(t))return null;const e=v(t.id,"").trim(),n=v(t.author,"").trim(),s=v(t.content,"").trim();if(!e||!n)return null;const a=w(t.score,0),i=w(t.votes_up,0),r=w(t.votes_down,0),l=w(t.votes,a||i-r),d=w(t.comment_count,w(t.reply_count,0)),u=(()=>{const h=t.flair;if(typeof h=="string"&&h.trim())return h.trim();if(k(h)){const L=v(h.name,"").trim();if(L)return L}return v(t.flair_name,"").trim()||void 0})(),f=v(t.created_at_iso,"").trim()||wt(t.created_at),c=v(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?wt(t.updated_at):f),m=v(t.title,"").trim()||gi(s);return{id:e,author:n,title:m,content:s,tags:[],votes:l,vote_balance:a,comment_count:d,created_at:f,updated_at:c,flair:u,hearth_count:w(t.hearth_count,0)}}function $i(t){if(!k(t))return null;const e=v(t.id,"").trim(),n=v(t.post_id,"").trim(),s=v(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:v(t.content,""),created_at:wt(t.created_at)}}async function hi(t){const e=new URLSearchParams;t&&e.set("sort_by",t),e.set("limit","100");const n=e.toString(),s=await it(`/api/v1/board${n?`?${n}`:""}`);return{posts:Array.isArray(s.posts)?s.posts.map(aa).filter(i=>i!==null):[]}}async function yi(t){const e=await it(`/api/v1/board/${t}?format=flat`),n=k(e.post)?e.post:e,s=aa(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map($i).filter(r=>r!==null);return{...s,comments:i}}function ia(t,e){return se("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:pi()})}function bi(t,e,n){return se("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function xi(t){const e=v(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function O(...t){for(const e of t){const n=v(e,"");if(n.trim())return n.trim()}return""}function os(t){const e=xi(O(t.outcome,t.result,t.result_code));if(!e)return;const n=O(t.reason,t.reason_code,t.description,t.detail),s=O(t.summary,t.summary_ko,t.summary_en,t.note),a=O(t.details,t.details_text,t.text,t.note),i=O(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=O(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=O(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(p=>{if(typeof p=="string")return p.trim();if(k(p)){const m=v(p.summary,"").trim();if(m)return m;const h=v(p.text,"").trim();if(h)return h;const R=v(p.type,"").trim();return R||v(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),u=(()=>{const c=w(t.turn,Number.NaN);if(Number.isFinite(c))return c;const p=w(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const m=w(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const h=w(t.round,Number.NaN);return Number.isFinite(h)?h:void 0})(),f=O(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:l||void 0,turn:u,phase:f||void 0}}function ki(t,e){const n=k(t.state)?t.state:{};if(v(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>k(r)?v(r.type,"")==="session.outcome":!1),i=k(n.session_outcome)?n.session_outcome:{};if(k(i)&&Object.keys(i).length>0){const r=os(i);if(r)return r}if(k(a))return os(k(a.payload)?a.payload:{})}function k(t){return typeof t=="object"&&t!==null}function v(t,e=""){return typeof t=="string"?t:e}function w(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function wi(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function dn(t,e=!1){return typeof t=="boolean"?t:e}function Rt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(k(e)){const n=v(e.name,"").trim(),s=v(e.id,"").trim(),a=v(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Si(t){const e={};if(!k(t)&&!Array.isArray(t))return e;if(k(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=v(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!k(n))continue;const s=O(n.to,n.target,n.actor_id,n.name,n.id),a=O(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Ci(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function U(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}function Ai(t,e){if(t!=="dice.rolled")return;const n=w(e.raw_d20,0),s=w(e.total,0),a=w(e.bonus,0),i=v(e.action,"roll"),r=w(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Ti(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ni(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Ri(t,e,n,s){const a=n||e||v(s.actor_id,"")||v(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=v(s.proposed_action,v(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=v(s.reply,v(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return v(s.reply,v(s.content,v(s.text,"Narration")));case"dice.rolled":{const i=v(s.action,"roll"),r=w(s.total,0),l=w(s.dc,0),d=v(s.label,""),u=a||"actor",f=l>0?` vs DC ${l}`:"",c=d?` (${d})`:"";return`${u} ${i}: ${r}${f}${c}`}case"turn.started":return`Turn ${w(s.turn,1)} started`;case"phase.changed":return`Phase: ${v(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${v(s.name,a||"unknown")}`;case"actor.claimed":return`${v(s.keeper_name,v(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${v(s.keeper_name,v(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${w(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${w(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||v(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||v(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${v(s.reason_code,"unknown")}`;case"memory.signal":{const i=k(s.entity_refs)?s.entity_refs:{},r=v(i.requested_tier,""),l=v(i.effective_tier,""),d=dn(i.guardrail_applied,!1),u=v(s.summary_en,v(s.summary_ko,"Memory signal"));if(!r&&!l)return u;const f=r&&l?`${r}->${l}`:l||r;return`${u} [${f}${d?" (guardrail)":""}]`}case"world.event":{if(v(s.event_type,"")==="canon.check"){const r=v(s.status,"unknown"),l=v(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return v(s.description,v(s.summary,"World event"))}case"combat.attack":return v(s.summary,v(s.result,"Attack resolved"));case"combat.defense":return v(s.summary,v(s.result,"Defense resolved"));case"session.outcome":return v(s.summary,v(s.outcome,"Session ended"));default:{const i=Ti(s);return i?`${t}: ${i}`:t}}}function Li(t,e){const n=k(t)?t:{},s=v(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=v(n.actor_name,"").trim()||e[a]||v(k(n.payload)?n.payload.actor_name:"",""),r=k(n.payload)?n.payload:{},l=v(n.ts,v(n.timestamp,new Date().toISOString())),d=v(n.phase,v(r.phase,"")),u=v(n.category,"");return{type:s,actor:i||a||v(r.actor_name,""),actor_id:a||v(r.actor_id,""),actor_name:i,seq:n.seq,room_id:v(n.room_id,""),phase:d||void 0,category:u||Ni(s),visibility:v(n.visibility,v(r.visibility,"public")),event_id:v(n.event_id,""),content:Ri(s,a,i,r),dice_roll:Ai(s,r),timestamp:l}}function Di(t,e,n){var G,et;const s=v(t.room_id,"")||n||"default",a=k(t.state)?t.state:{},i=k(a.party)?a.party:{},r=k(a.actor_control)?a.actor_control:{},l=k(a.join_gate)?a.join_gate:{},d=k(a.contribution_ledger)?a.contribution_ledger:{},u=Object.entries(i).map(([T,I])=>{const g=k(I)?I:{},ie=U(g,"max_hp",void 0,10),Un=U(g,"hp",void 0,ie),ya=U(g,"max_mp",void 0,0),ba=U(g,"mp",void 0,0),xa=U(g,"level",void 0,1),ka=U(g,"xp",void 0,0),wa=dn(g.alive,Un>0),Bn=r[T],qn=typeof Bn=="string"?Bn:void 0,Sa=Ci(g.role,T,qn),Ca=wi(g.generation),Aa=O(g.joined_at,g.joinedAt,g.started_at,g.startedAt),Ta=O(g.claimed_at,g.claimedAt,g.assigned_at,g.assignedAt,g.assigned_time),Na=O(g.last_seen,g.lastSeen,g.last_seen_at,g.lastSeenAt,g.last_active,g.lastActive),Ra=O(g.scene,g.current_scene,g.currentScene,g.world_scene,g.scene_name,g.sceneName),La=O(g.location,g.current_location,g.currentLocation,g.position,g.zone,g.area);return{id:T,name:v(g.name,T),role:Sa,keeper:qn,archetype:v(g.archetype,""),persona:v(g.persona,""),traits:Rt(g.traits),skills:Rt(g.skills),status:wa?"active":"dead",generation:Ca,joined_at:Aa||void 0,claimed_at:Ta||void 0,last_seen:Na||void 0,scene:Ra||void 0,location:La||void 0,inventory:Rt(g.inventory),notes:Rt(g.notes),relationships:Si(g.relationships),stats:{hp:Un,max_hp:ie,mp:ba,max_mp:ya,level:xa,xp:ka,strength:U(g,"strength","str",10),dexterity:U(g,"dexterity","dex",10),constitution:U(g,"constitution","con",10),intelligence:U(g,"intelligence","int",10),wisdom:U(g,"wisdom","wis",10),charisma:U(g,"charisma","cha",10)}}}),f=u.filter(T=>T.status!=="dead"),c=ki(t,e),p={phase_open:dn(l.phase_open,!0),min_points:w(l.min_points,3),window:v(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},m=Object.entries(d).map(([T,I])=>{const g=k(I)?I:{};return{actor_id:T,score:w(g.score,0),last_reason:v(g.last_reason,"")||null,reasons:Rt(g.reasons)}}),h=u.reduce((T,I)=>(T[I.id]=I.name,T),{}),R=e.map(T=>Li(T,h)),L=w(a.turn,1),A=v(a.phase,"round"),S=v(a.map,""),z=k(a.world)?a.world:{},q=S||v(z.ascii_map,v(z.map,"")),D=R.filter((T,I)=>{const g=e[I];if(!k(g))return!1;const ie=k(g.payload)?g.payload:{};return w(ie.turn,-1)===L}),K=(D.length>0?D:R).slice(-12),ot=v(a.status,"active");return{session:{id:s,room:s,status:ot==="ended"?"ended":ot==="paused"?"paused":"active",round:L,actors:f,created_at:((G=R[0])==null?void 0:G.timestamp)??new Date().toISOString()},current_round:{round_number:L,phase:A,events:K,timestamp:((et=R[R.length-1])==null?void 0:et.timestamp)??new Date().toISOString()},map:q||void 0,join_gate:p,contribution_ledger:m,outcome:c,party:f,story_log:R,history:[]}}async function Pi(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await it(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ei(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([it(`/api/v1/trpg/state${e}`),Pi(t)]);return Di(n,s,t)}function Ii(t){return se("/api/v1/trpg/rounds/run",{room_id:t})}function ji(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Oi(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),se("/api/v1/trpg/dice/roll",e)}function Mi(t,e){const n=ji();return se("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function zi(t,e,n){const s=await H("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Fi(t){const e=await H("trpg.mid_join.request",t);return JSON.parse(e)}async function oa(t,e){await H("masc_broadcast",{agent_name:t,message:e})}async function Hi(t,e,n=1){await H("masc_add_task",{title:t,description:e,priority:n})}async function Ui(t){return H("masc_join",{agent_name:t})}async function ra(t){await H("masc_leave",{agent_name:t})}async function Bi(t){await H("masc_heartbeat",{agent_name:t})}async function qi(t=40){return(await H("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Ki(t,e=20){return H("masc_task_history",{task_id:t,limit:e})}async function Gi(){const t=await it("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!k(e))return null;const n=v(e.id,"").trim(),s=v(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:v(e.status,"open"),argument_count:w(e.argument_count,0),created_at:wt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]}async function Wi(){const t=await it("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!k(e))return null;const n=v(e.id,"").trim(),s=v(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:v(e.initiator,"system"),votes:w(e.votes,0),quorum:w(e.quorum,0),state:v(e.state,"open"),created_at:wt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]}async function Vi(t){const e=await H("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Ji(t){const e=encodeURIComponent(t),n=await it(`/api/v1/council/debates/${e}/summary`);if(!k(n))return null;const s=v(n.id,"").trim();return s?{id:s,topic:v(n.topic,""),status:v(n.status,"open"),support_count:w(n.support_count,0),oppose_count:w(n.oppose_count,0),neutral_count:w(n.neutral_count,0),total_arguments:w(n.total_arguments,0),created_at:wt(n.created_at_iso??n.created_at),summary_text:v(n.summary_text,"")}:null}async function Yi(){try{const t=await H("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const At=_([]),ae=_([]),la=_([]),Tt=_([]),In=_(null),Dt=_(null),pn=_(new Map),ca=_([]),vn=_("hot"),ua=_(null),ht=_(""),je=_([]),It=_(!1),fn=_(!1),mn=_(!1),_n=_(!1),da=at(()=>At.value.filter(t=>t.status==="active"||t.status==="idle")),jn=at(()=>{const t=ae.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Qi(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Xi=at(()=>{const t=new Map;for(const e of Tt.value)t.set(e.name,Qi(e));return t}),Zi=12e4,to=at(()=>{const t=Date.now(),e=new Set,n=pn.value;for(const s of Tt.value){const a=n.get(s.name);a!=null&&t-a>Zi&&e.add(s.name)}return e}),ke={},eo=5e3;function gn(){delete ke.compact,delete ke.full}function J(t){return typeof t=="object"&&t!==null}function $(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function b(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function jt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function pa(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function no(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function so(t){if(!J(t))return null;const e=$(t.name);return e?{name:e,status:pa(t.status),current_task:$(t.current_task)??null,last_seen:$(t.last_seen),emoji:$(t.emoji),koreanName:$(t.koreanName)??$(t.korean_name),model:$(t.model),traits:jt(t.traits),interests:jt(t.interests),activityLevel:b(t.activityLevel)??b(t.activity_level),primaryValue:$(t.primaryValue)??$(t.primary_value)}:null}function ao(t){if(!J(t))return null;const e=$(t.id),n=$(t.title);return!e||!n?null:{id:e,title:n,status:no(t.status),priority:b(t.priority),assignee:$(t.assignee),description:$(t.description),created_at:$(t.created_at),updated_at:$(t.updated_at)}}function io(t){if(!J(t))return null;const e=$(t.from)??$(t.from_agent)??"system",n=$(t.content)??"",s=$(t.timestamp)??new Date().toISOString();return{id:$(t.id),seq:b(t.seq),from:e,content:n,timestamp:s,type:$(t.type)}}function oo(t){return Array.isArray(t)?t.map(e=>{if(!J(e))return null;const n=b(e.ts_unix);if(n==null)return null;const s=J(e.handoff)?e.handoff:null;return{ts:n,context_ratio:b(e.context_ratio)??0,context_tokens:b(e.context_tokens)??0,context_max:b(e.context_max)??0,latency_ms:b(e.latency_ms)??0,generation:b(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:b(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:b(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?b(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function ro(t){return(Array.isArray(t)?t:J(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!J(n))return null;const s=J(n.agent)?n.agent:null,a=J(n.context)?n.context:null,i=J(n.metrics_window)?n.metrics_window:void 0,r=$(n.name);if(!r)return null;const l=b(n.context_ratio)??b(a==null?void 0:a.context_ratio),d=$(n.status)??$(s==null?void 0:s.status)??"offline",u=pa(d),f=$(n.model)??$(n.active_model)??$(n.primary_model),c=jt(n.skill_secondary),p=a?{source:$(a.source),context_ratio:b(a.context_ratio),context_tokens:b(a.context_tokens),context_max:b(a.context_max),message_count:b(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,m=s?{name:$(s.name),status:$(s.status),current_task:$(s.current_task)??null,last_seen:$(s.last_seen)}:void 0,h=oo(n.metrics_series);return{name:r,emoji:$(n.emoji),koreanName:$(n.koreanName)??$(n.korean_name),agent_name:$(n.agent_name),trace_id:$(n.trace_id),model:f,primary_model:$(n.primary_model),active_model:$(n.active_model),next_model_hint:$(n.next_model_hint)??null,status:u,last_heartbeat:$(n.last_heartbeat)??$(s==null?void 0:s.last_seen),generation:b(n.generation),turn_count:b(n.turn_count)??b(n.total_turns),context_ratio:l,context_tokens:b(n.context_tokens)??b(a==null?void 0:a.context_tokens),context_max:b(n.context_max)??b(a==null?void 0:a.context_max),context_source:$(n.context_source)??$(a==null?void 0:a.source),context:p,traits:jt(n.traits),interests:jt(n.interests),primaryValue:$(n.primaryValue)??$(n.primary_value),activityLevel:b(n.activityLevel)??b(n.activity_level),memory_recent_note:$(n.memory_recent_note)??null,conversation_tail_count:b(n.conversation_tail_count),k2k_count:b(n.k2k_count),handoff_count_total:b(n.handoff_count_total)??b(n.trace_history_count),compaction_count:b(n.compaction_count),last_compaction_saved_tokens:b(n.last_compaction_saved_tokens),skill_primary:$(n.skill_primary)??null,skill_secondary:c,skill_reason:$(n.skill_reason)??null,metrics_series:h.length>0?h:void 0,metrics_window:i,agent:m}}).filter(n=>n!==null)}async function Oe(t="full"){var s,a,i;const e=Date.now(),n=ke[t];if(!(n&&e-n.time<eo)){fn.value=!0;try{const r=await _i(t);ke[t]={data:r,time:e},At.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(so).filter(l=>l!==null),ae.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(ao).filter(l=>l!==null),la.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(io).filter(l=>l!==null),Tt.value=ro(r.keepers),In.value=J(r.status)?r.status:null,Dt.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{fn.value=!1}}}async function vt(){mn.value=!0;try{const t=await hi(vn.value);ca.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{mn.value=!1}}async function ut(){var t;_n.value=!0;try{const e=ht.value||((t=In.value)==null?void 0:t.room)||"default";ht.value||(ht.value=e);const n=await Ei(e);ua.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{_n.value=!1}}async function $n(){It.value=!0;try{const t=await Yi();je.value=Array.isArray(t)?t:[]}catch(t){console.error("Goals fetch error:",t)}finally{It.value=!1}}let Fe=null,He=null;function lo(){return Qs.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(pn.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),pn.value=n}gn(),Fe||(Fe=setTimeout(()=>{Oe(),Fe=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(He||(He=setTimeout(()=>{vt(),He=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&gn()}})}let Ot=null;function co(){Ot||(Ot=setInterval(()=>{gn(),Oe()},1e4))}function uo(){Ot&&(clearInterval(Ot),Ot=null)}function y({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function tt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function po(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function M({timestamp:t}){const e=po(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}const On=_(null);function va(t){On.value=t}function rs(){On.value=null}const _t=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function vo(t){if(!t)return 0;const e=_t.findIndex(n=>n.level===t);return e>=0?e:0}function fo({keeper:t}){const e=vo(t.autonomy_level),n=_t[e]??_t[0];if(!n)return null;const s=(e+1)/_t.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${_t.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${_t.map((a,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${M} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function _e(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function mo({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${_e(t.context_tokens)}</div>
        <div class="kpi-label">Tokens</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.handoff_count_total??"—"}</div>
        <div class="kpi-label">Handoffs</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.compaction_count??"—"}</div>
        <div class="kpi-label">Compactions</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${s}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function _o({keeper:t}){var f,c;const e=t.metrics_series??[];if(e.length<2){const p=(((f=t.context)==null?void 0:f.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((p,m)=>{const h=a+m/(i-1)*(n-2*a),R=s-a-(p.context_ratio??0)*(s-2*a);return{x:h,y:R,p}}),l=r.map(({x:p,y:m})=>`${p.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${a}" x2="${p.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:m})=>o`
          <circle cx="${p.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Ue=_("");function go({keeper:t}){var a,i,r,l;const e=Ue.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ue.value}
        onInput=${d=>{Ue.value=d.target.value}}
      />
      ${s.map(d=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
        </div>
      `)}
      ${t.trace_id?o`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?o`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?o`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${_e(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${_e(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${_e(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function $o({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
    <div>
      <div style="display: flex; gap: 12px; margin-bottom: 10px;">
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">HP ${t.hp}/${t.max_hp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${e}%; height:100%; background:${e>50?"#4ade80":e>25?"#fbbf24":"#ef4444"}; border-radius:3px;" />
          </div>
        </div>
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">MP ${t.mp}/${t.max_mp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${n}%; height:100%; background:#818cf8; border-radius:3px;" />
          </div>
        </div>
      </div>
      <div style="display:grid; grid-template-columns: repeat(3,1fr); gap:6px;">
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>o`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${s.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${s.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function ho({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function yo({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function ls({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Be(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function bo({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Be(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Be(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Be(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function xo({keeperName:t}){const[e,n]=re("Loading internal monologue..."),[s,a]=re(""),[i,r]=re([]),[l,d]=re(!1),u=async()=>{try{const c=await H("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof c=="string"?c:JSON.stringify(c,null,2))}catch(c){n("Failed to load: "+String(c))}};xt(()=>{u()},[t]);const f=async()=>{if(!s.trim())return;d(!0);const c=s;a(""),r(p=>[...p,{role:"You",text:c}]);try{const p=await H("masc_keeper_msg",{name:t,message:c});r(m=>[...m,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),u()}catch(p){r(m=>[...m,{role:"System",text:"Error: "+String(p)}])}finally{d(!1)}};return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Inner Monologue</h3>
      
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <!-- Chat Area -->
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <div style="background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 12px; height: 300px; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem;">
            ${i.length===0?o`<div style="color: var(--text-muted); font-style: italic;">No direct messages yet.</div>`:null}
            ${i.map(c=>o`
              <div style="padding: 8px; border-radius: 8px; background: ${c.role==="You"?"rgba(0, 240, 255, 0.1)":"rgba(255, 255, 255, 0.05)"}; border-left: 2px solid ${c.role==="You"?"var(--accent-cyan)":"var(--text-muted)"};">
                <strong style="color: ${c.role==="You"?"var(--accent-cyan)":"var(--text-primary)"}; display: block; margin-bottom: 4px;">${c.role}</strong>
                <span style="white-space: pre-wrap;">${c.text}</span>
              </div>
            `)}
          </div>
          <div style="display: flex; gap: 8px;">
            <input 
              type="text" 
              value=${s} 
              onInput=${c=>a(c.target.value)} 
              onKeyDown=${c=>c.key==="Enter"&&!c.shiftKey&&f()}
              placeholder="Ping the agent..."
              disabled=${l}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${f} 
              disabled=${l||!s.trim()}
              style="background: var(--accent-cyan); color: #000; border: none; border-radius: 8px; padding: 8px 16px; font-weight: bold; cursor: pointer; opacity: ${l?.5:1};"
            >
              ${l?"Sending...":"Send"}
            </button>
          </div>
        </div>

        <!-- Monologue / Status Area -->
        <div style="background: #050810; border: 1px solid var(--card-border); border-radius: 12px; padding: 12px; height: 345px; overflow-y: auto; font-family: monospace; font-size: 0.75rem; color: var(--ok); white-space: pre-wrap; box-shadow: inset 0 0 15px rgba(0,0,0,0.8);">
          ${e}
        </div>
        
      </div>
    </div>
  `}function ko(){var e,n,s;const t=On.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&rs()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?o`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${tt} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>rs()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${mo} keeper=${t} />

        ${""}
        <${_o} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${y} title="Field Dictionary">
            <${go} keeper=${t} />
          <//>

          ${""}
          <${y} title="Profile">
            <${ls} traits=${t.traits??[]} label="Traits" />
            <${ls} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${M} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${y} title="Autonomy">
                <${fo} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${y} title="TRPG Stats">
                <${$o} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${y} title="Equipment (${t.inventory.length})">
                <${ho} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${y} title="Relationships (${Object.keys(t.relationships).length})">
                <${yo} rels=${t.relationships} />
              <//>
            `:null}

          <${y} title="Runtime Signals">
            <${bo} keeper=${t} />
          <//>

          <${y} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context source</span>
                <strong>${t.context_source??((e=t.context)==null?void 0:e.source)??"-"}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Context tokens</span>
                <strong>
                  ${t.context_tokens??((n=t.context)==null?void 0:n.context_tokens)??"-"}
                  /
                  ${t.context_max??((s=t.context)==null?void 0:s.context_max)??"-"}
                </strong>
              </div>
              ${t.memory_recent_note?o`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:o`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${xo} keeperName=${t.name} />
      </div>
    </div>
  `:null}let wo=0;const ct=_([]);function x(t,e="success",n=4e3){const s=++wo;ct.value=[...ct.value,{id:s,message:t,type:e}],setTimeout(()=>{ct.value=ct.value.filter(a=>a.id!==s)},n)}function So(t){ct.value=ct.value.filter(e=>e.id!==t)}function Co(){const t=ct.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>So(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Ao="masc_dashboard_agent_name",Nt=_(null),we=_(!1),Qt=_(""),Se=_([]),Xt=_([]),yt=_(""),Mt=_(!1);function fa(t){Nt.value=t,Mn()}function cs(){Nt.value=null,Qt.value="",Se.value=[],Xt.value=[],yt.value=""}function To(){const t=Nt.value;return t?At.value.find(e=>e.name===t)??null:null}function ma(t){return t?ae.value.filter(e=>e.assignee===t):[]}async function Mn(){const t=Nt.value;if(t){we.value=!0,Qt.value="",Se.value=[],Xt.value=[];try{const e=await qi(80);Se.value=e.filter(a=>a.includes(t)).slice(0,20);const n=ma(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await Ki(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Xt.value=s}catch(e){Qt.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{we.value=!1}}}async function us(){var s;const t=Nt.value,e=yt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Ao))==null?void 0:s.trim())||"dashboard";Mt.value=!0;try{await oa(n,`@${t} ${e}`),yt.value="",x(`Mention sent to ${t}`,"success"),Mn()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";x(i,"error")}finally{Mt.value=!1}}function No({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${tt} status=${t.status} />
    </div>
  `}function Ro({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Lo(){var a,i,r,l;const t=Nt.value;if(!t)return null;const e=To(),n=ma(t),s=Se.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&cs()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?o`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?o`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?o`
                        <${tt} status=${e.status} />
                        ${e.model?o`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?o`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:o`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?o`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((a=e==null?void 0:e.traits)==null?void 0:a.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(d=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${M} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Mn()}} disabled=${we.value}>
              ${we.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${cs}>Close</button>
          </div>
        </div>

        ${Qt.value?o`<div class="council-error">${Qt.value}</div>`:null}

        <div class="agent-detail-grid">
          <${y} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${No} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${y} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${y} title="Task History">
          ${Xt.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Xt.value.map(d=>o`<${Ro} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${y} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${yt.value}
              onInput=${d=>{yt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&us()}}
              disabled=${Mt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{us()}}
              disabled=${Mt.value||yt.value.trim()===""}
            >
              ${Mt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function ft({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Do({agent:t}){return o`
    <div class="agent" onClick=${()=>fa(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${tt} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Po(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Eo(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function ds(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Io({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=Xi.value.get(t.name),a=to.value.has(t.name);return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>va(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${tt} status=${t.status} />
          ${s?o`<span class="pill pill-lifecycle pill-lifecycle-${s}">${s}</span>`:null}
          ${a?o`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?o`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?o`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${ds(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${ds(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${Po(t.context_tokens)})`:null}
            </span>
          </div>
        `:null}

        <!-- Row 3: Operational metrics -->
        ${t.generation!=null?o`
          <div class="keeper-metrics-row">
            <span>Gen ${t.generation}</span>
            <span>T${t.turn_count??0}</span>
            ${(t.handoff_count_total??0)>0?o`<span class="keeper-metric-hl">↻${t.handoff_count_total}</span>`:null}
            ${(t.compaction_count??0)>0?o`<span class="keeper-metric-compact">◆${t.compaction_count}</span>`:null}
            ${(t.k2k_count??0)>0?o`<span>K2K:${t.k2k_count}</span>`:null}
            ${(t.conversation_tail_count??0)>0?o`<span>💬${t.conversation_tail_count}</span>`:null}
          </div>
        `:null}

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?o`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${M} timestamp=${t.last_heartbeat} />
          </div>
        `:null}

        <!-- Row 5: Trait chips -->
        ${t.traits&&t.traits.length>0?o`
          <div class="keeper-trait-row">
            ${t.traits.slice(0,3).map(i=>o`<span class="keeper-trait-chip">${i}</span>`)}
            ${t.traits.length>3?o`<span class="keeper-trait-more">+${t.traits.length-3}</span>`:null}
          </div>
        `:null}

        <!-- Row 6: Memory note preview -->
        ${t.memory_recent_note?o`
          <div class="keeper-note-preview">${Eo(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function ps(){var r,l,d,u,f;const t=In.value,e=At.value,n=Tt.value,s=jn.value,a=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(l=t==null?void 0:t.monitoring)==null?void 0:l.council;return o`
    <div class="stats-grid">
      <${ft} label="Agents" value=${e.length} />
      <${ft} label="Active" value=${da.value.length} color="#4ade80" />
      <${ft} label="Keepers" value=${n.length} color="#22d3ee" />
      <${ft} label="Tasks" value=${ae.value.length} />
      <${ft} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${ft} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    ${a||i?o`
        <${y} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${fs(a==null?void 0:a.alert_level)}`}>
                ${vs(a==null?void 0:a.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${ce(a==null?void 0:a.last_activity_age_s)}</span>
                <span>SLO: ≤ ${ce(a==null?void 0:a.slo_target_age_s)}</span>
                <span>SLO Breach: ${a!=null&&a.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(a==null?void 0:a.new_posts_24h)??0}</span>
                <span>Unanswered: ${(a==null?void 0:a.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${fs(i==null?void 0:i.alert_level)}`}>
                ${vs(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${ce(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${ce(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${y} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(c=>o`<${Do} key=${c.name} agent=${c} />`)}
        </div>
      <//>

      <${y} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(c=>o`<${Io} key=${c.name} keeper=${c} />`)}
        </div>
      <//>
    </div>

    ${Dt.value?o`
        <${y} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${Dt.value.running?"Running":"Stopped"}</span>
            ${Dt.value.goal?o`<span>Goal: ${Dt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${y} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${jo(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(f=t.data_quality)!=null&&f.last_sync_at?o`<span>Data Sync: <${M} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function jo(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function ce(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function vs(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function fs(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const hn=_([]),yn=_([]),zt=_(""),Ce=_(!1),Ft=_(!1),Zt=_(""),Ae=_(null),V=_(null),bn=_(!1);async function xn(){Ce.value=!0,Zt.value="";try{const[t,e]=await Promise.all([Gi(),Wi()]);hn.value=t,yn.value=e}catch(t){Zt.value=t instanceof Error?t.message:"Failed to load council data"}finally{Ce.value=!1}}async function ms(){const t=zt.value.trim();if(t){Ft.value=!0;try{const e=await Vi(t);zt.value="",x(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await xn()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";x(n,"error")}finally{Ft.value=!1}}}async function Oo(t){Ae.value=t,bn.value=!0,V.value=null;try{V.value=await Ji(t)}catch(e){Zt.value=e instanceof Error?e.message:"Failed to load debate status",V.value=null}finally{bn.value=!1}}function Mo({debate:t}){const e=Ae.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Oo(t.id)}
    >
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Args: ${t.argument_count}</span>
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function zo({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.state?o`<span>State: ${t.state}</span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function Fo(){return xt(()=>{xn()},[]),o`
    <div>
      <${y} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${zt.value}
            onInput=${t=>{zt.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&ms()}}
            disabled=${Ft.value}
          />
          <button
            class="control-btn secondary"
            onClick=${ms}
            disabled=${Ft.value||zt.value.trim()===""}
          >
            ${Ft.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${xn} disabled=${Ce.value}>
            ${Ce.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Zt.value?o`<div class="council-error">${Zt.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${y} title="Debates" class="section">
          <div class="council-list">
            ${hn.value.length===0?o`<div class="empty-state">No debates yet</div>`:hn.value.map(t=>o`<${Mo} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${y} title="Voting Sessions" class="section">
          <div class="council-list">
            ${yn.value.length===0?o`<div class="empty-state">No active sessions</div>`:yn.value.map(t=>o`<${zo} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${y} title=${Ae.value?`Debate Detail (${Ae.value})`:"Debate Detail"} class="section">
        ${bn.value?o`<div class="loading-indicator">Loading debate detail...</div>`:V.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${V.value.status}</span>
                  <span>Total arguments: ${V.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${V.value.support_count}</span>
                  <span>Oppose: ${V.value.oppose_count}</span>
                  <span>Neutral: ${V.value.neutral_count}</span>
                </div>
                ${V.value.summary_text?o`<pre class="council-detail">${V.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Ho({text:t}){if(!t)return null;const e=Uo(t);return o`<div class="markdown-content">${e}</div>`}function Uo(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${qe(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${qe(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${qe(i.join(`
`))}</p>`)}return n}function qe(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Bo=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],kn=_([]),Ht=_(!1),wn=_(null),Ut=_(""),qo=_("dashboard-user"),Bt=_(!1);async function _a(t){wn.value=t,Ht.value=!0;try{const e=await yi(t);if(wn.value!==t)return;kn.value=e.comments??[]}catch{}finally{Ht.value=!1}}async function _s(t){const e=Ut.value.trim();if(e){Bt.value=!0;try{await bi(t,qo.value,e),Ut.value="",x("Comment posted","success"),await _a(t),vt()}catch{x("Failed to post comment","error")}finally{Bt.value=!1}}}function Ko(){const t=vn.value;return o`
    <div class="board-controls">
      ${Bo.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{vn.value=e.id,vt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function ga({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Go({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await ia(t.id,n),vt()}catch{x("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Za(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${ga} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${M} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Wo({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${M} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Vo({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Ut.value}
        onInput=${e=>{Ut.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&_s(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Bt.value}
      />
      <button
        onClick=${()=>_s(t)}
        disabled=${Bt.value||Ut.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Bt.value?"...":"Post"}
      </button>
    </div>
  `}function Jo({post:t}){wn.value!==t.id&&!Ht.value&&_a(t.id);const e=async n=>{try{await ia(t.id,n),vt()}catch{x("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Ie("board")}>← Back to Board</button>
      <${y} title=${o`${t.title} <${ga} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Ho} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${M} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${y} title="Comments (${Ht.value?"...":kn.value.length})">
        ${Ht.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Wo} comments=${kn.value} />`}
        <${Vo} postId=${t.id} />
      <//>
    </div>
  `}function Yo(){const t=ca.value,e=mn.value,n=Z.value.postId;if(n){const s=t.find(a=>a.id===n);return s?o`<${Jo} post=${s} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>Ie("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${Ko} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(s=>o`<${Go} key=${s.id} post=${s} />`)}
          </div>`}
  `}function Qo(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Xo(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function gs(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function Zo({row:t}){const e=new Date(t.timestamp),n=isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1});return o`
    <div class="term-row">
      <span class="term-time">${n}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-source ${t.source}">${t.source==="message"?"msg":"evt"}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function tr(){const t=la.value.map(Qo),e=xe.value.map(Xo),n=[...t,...e].sort((s,a)=>gs(a.timestamp)-gs(s.timestamp)).slice(0,100);return o`
    <div class="section">
      <h2 style="color: var(--accent); text-shadow: 0 0 10px rgba(0,240,255,0.5); margin-bottom: 16px; font-family: monospace;">> LIVE_ACTIVITY_STREAM</h2>
      <div class="terminal-feed">
        ${n.length===0?o`<div class="empty-state" style="font-family: monospace; color: var(--ok);">> Waiting for signal...</div>`:n.map(s=>o`<${Zo} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function $a({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${l}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${l}">${Math.round(t*100)}%</span>
    </div>
  `}const er={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function nr(t){return er[t]}function mt({metric:t}){const e=nr(t);return o`
    <span
      class="metric-tip"
      tabindex="0"
      role="button"
      aria-label="${e.label} 설명"
      title="${e.description} (source: ${e.sourcePath})"
    >
      i
      <span class="metric-tip-pop" role="tooltip">
        <strong>${e.label}</strong>
        <span>${e.description}</span>
        ${e.formula?o`<span><code>formula:</code> ${e.formula}</span>`:null}
        <span><code>source:</code> ${e.sourcePath}</span>
        ${e.interpretation?o`<span>${e.interpretation}</span>`:null}
      </span>
    </span>
  `}function sr({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>fa(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${$a} ratio=${t.context_ratio} />
        <${tt} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function ar(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function ir(t){var a,i,r;const e=(a=t.last_drift_reason)==null?void 0:a.trim();if(e)return e;const n=(i=t.last_proactive_reason)==null?void 0:i.trim();if(n)return n;const s=(r=t.memory_recent_note)==null?void 0:r.trim();return s||"—"}function or(t){var s;const e=t.k2k_count??0,n=(s=t.k2k_mentions)==null?void 0:s[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function rr(t){var s;const e=t.drift_count_total??0,n=ar((s=t.metrics_window)==null?void 0:s.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function lr({keeper:t}){var a;const e=ir(t),n=or(t),s=rr(t);return o`
    <div class="live-agent keeper-card" onClick=${()=>va(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${$a} ratio=${t.context_ratio} />
        <${tt} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${mt} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?o`<${M} timestamp=${t.created_at} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${mt} metric="generation" /></span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${mt} metric="status" /></span>
            <strong class="keeper-core-value">${t.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${mt} metric="relations" /></span>
            <strong class="keeper-core-value">${n}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${mt} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${e}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${mt} metric="personality_change" /></span>
            <strong class="keeper-core-value">${s}</strong>
          </div>
        </div>

        <!-- Inner Information Section -->
        <div class="keeper-inner-info">
          ${(a=t.agent)!=null&&a.current_task?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Task</span>
              <span class="keeper-value">${t.agent.current_task}</span>
            </div>
          `:null}
          ${t.will?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Will (의지)</span>
              <span class="keeper-value">${t.will}</span>
            </div>
          `:null}
          ${t.needs?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Needs (니즈)</span>
              <span class="keeper-value">${t.needs}</span>
            </div>
          `:null}
          ${t.desires?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Desires (욕구)</span>
              <span class="keeper-value">${t.desires}</span>
            </div>
          `:null}
          ${t.memory_recent_note?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Memory Note</span>
              <span class="keeper-value memory-note">"${t.memory_recent_note}"</span>
            </div>
          `:null}
        </div>
      </div>
    </div>
  `}function cr(){const t=At.value,e=Tt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${lr} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${sr} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Ke({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${M} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function ur(){const{todo:t,inProgress:e,done:n}=jn.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${Ke} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${Ke} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${Ke} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function dr(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function Ge({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${dr(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${M} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function pr(){const t=jn.value,e=t.inProgress,n=t.todo,s=t.done,a=da.value,i=n.filter(l=>(l.priority??3)<=2),r=n.filter(l=>!l.assignee);return o`
    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">In Progress</div>
        <div class="stat-value" style="color:#fbbf24">${e.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Ready Queue</div>
        <div class="stat-value">${n.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Urgent Ready</div>
        <div class="stat-value" style="color:#fb7185">${i.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Done (Visible)</div>
        <div class="stat-value" style="color:#4ade80">${s.length}</div>
      </div>
    </div>

    <div class="council-grid">
      <${y} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(l=>o`<${Ge} key=${l.id} task=${l} />`)}
        </div>
      <//>

      <${y} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(l=>o`<${Ge} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${y} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(l=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${l.name}</div>
                    <div class="council-sub">
                      ${l.current_task?o`<span>${l.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${tt} status=${l.status} />
                </div>
              `)}
        </div>
      <//>

      <${y} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(l=>o`<${Ge} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>
  `}function vr({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function fr(){const t=xe.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${vr} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const Te=_("all"),Ne=_("all"),ha=at(()=>{let t=je.value;return Te.value!=="all"&&(t=t.filter(e=>e.horizon===Te.value)),Ne.value!=="all"&&(t=t.filter(e=>e.status===Ne.value)),t}),mr=at(()=>{const t={short:[],mid:[],long:[]};for(const e of ha.value){const n=t[e.horizon];n&&n.push(e)}return t});function _r(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function zn(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ge(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function gr({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ge(t.horizon)}">
            ${zn(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${_r(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${M} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${tt} status=${t.status} />
        <div class="goal-updated">
          <${M} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function We({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${y} title="${zn(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${gr} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function $r(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Te.value===t?"active":""}"
            onClick=${()=>{Te.value=t}}
          >
            ${t==="all"?"All":zn(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Ne.value===t?"active":""}"
            onClick=${()=>{Ne.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function hr(){const t=je.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${t.length}</div>
        <div class="goal-summary-label">Total</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${e}</div>
        <div class="goal-summary-label">Active</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${n}</div>
        <div class="goal-summary-label">Completed</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ge("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ge("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ge("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function yr(){xt(()=>{$n()},[]);const t=mr.value;return o`
    <div>
      <${y} title="Goals Overview" class="section">
        <${hr} />
        <${$r} />
        <div style="margin-top:8px;">
          <button class="control-btn ghost" onClick=${$n} disabled=${It.value}>
            ${It.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      <//>

      ${It.value&&je.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:ha.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
            <${We} horizon="short" items=${t.short??[]} />
            <${We} horizon="mid" items=${t.mid??[]} />
            <${We} horizon="long" items=${t.long??[]} />
          `}
    </div>
  `}const Lt=_(""),Ve=_("ability_check"),Je=_("10"),Ye=_("12"),ue=_(""),de=_("idle"),pe=_(""),ve=_("keeper-late"),Qe=_("player"),Xe=_(""),B=_("idle"),Ze=_(null),Sn=_(null);function br(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function xr(t,e){return e>0?Math.round(t/e*100):0}const kr={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},wr={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function tn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Sr(t){const e=t.trim().toLowerCase();return kr[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Cr(t){const e=t.trim().toLowerCase();return wr[e]??"상황에 따라 선택되는 전술 액션입니다."}function dt(t){return typeof t=="object"&&t!==null}function F(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Q(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function te(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}function Ar({hp:t,max:e}){const n=xr(t,e),s=br(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Tr({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Nr({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Rr({actor:t}){var i,r;const e=(i=t.archetype)==null?void 0:i.trim(),n=(r=t.persona)==null?void 0:r.trim(),s=t.traits??[],a=t.skills??[];return o`
    <div class="trpg-actor">
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${tt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Nr} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Ar} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Tr} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${tn(e)}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${s.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${s.map(l=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${tn(l)}</span>
                  <span class="trpg-annot-desc">${Sr(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${a.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${a.map(l=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${tn(l)}</span>
                  <span class="trpg-annot-desc">${Cr(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Lr({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Dr({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var s;return o`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?o`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?o`<span class="trpg-dice">[${e.dice_roll.notation}: ${(s=e.dice_roll.rolls)==null?void 0:s.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${M} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function Pr({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Er({state:t}){const e=t.history??[];return e.length===0?null:o`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>o`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Ir({state:t}){var d;const e=ht.value||((d=t.session)==null?void 0:d.room)||"",n=de.value,s=t.party??[];if(!s.find(u=>u.id===Lt.value)&&s.length>0){const u=s[0];u&&(Lt.value=u.id)}const i=async()=>{if(!e){x("No room set","error");return}de.value="running";try{const u=await Ii(e);Sn.value=u,de.value="ok";const f=dt(u.summary)?u.summary:null,c=f?te(f,"advanced",!1):!1,p=f?F(f,"progress_reason",""):"";x(c?"Round advanced":`Round stalled${p?`: ${p}`:""}`,c?"success":"warning"),ut()}catch(u){Sn.value=null,de.value="error";const f=u instanceof Error?u.message:"Round failed";x(f,"error")}},r=async()=>{if(e)try{await Mi(e),x("Turn advanced","success"),ut()}catch{x("Advance failed","error")}},l=async()=>{if(!e)return;const u=Lt.value.trim();if(!u){x("Select actor first","warning");return}const f=Number.parseInt(Je.value,10),c=Number.parseInt(Ye.value,10);if(Number.isNaN(f)||Number.isNaN(c)){x("Stat/DC must be numbers","warning");return}const p=Number.parseInt(ue.value,10),m=ue.value.trim()===""||Number.isNaN(p)?void 0:p;try{await Oi({roomId:e,actorId:u,action:Ve.value.trim()||"ability_check",statValue:f,dc:c,rawD20:m}),x("Dice rolled","success"),ut()}catch{x("Dice roll failed","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${e}
            onInput=${u=>{ht.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Lt.value}
            onChange=${u=>{Lt.value=u.target.value}}
          >
            <option value="">Select actor</option>
            ${s.map(u=>o`<option value=${u.id}>${u.name} (${u.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Ve.value}
              onInput=${u=>{Ve.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Je.value}
              onInput=${u=>{Je.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ye.value}
              onInput=${u=>{Ye.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ue.value}
              onInput=${u=>{ue.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&l()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${l}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${i}
              disabled=${n==="running"}
            >
              ${n==="running"?"Running...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${r}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${n!=="idle"?o`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function jr({state:t}){var l;const e=ht.value||((l=t.session)==null?void 0:l.room)||"",n=t.join_gate,s=Ze.value,a=dt(s)?s:null,i=async()=>{const d=pe.value.trim(),u=ve.value.trim();if(!e||!d){x("Room/Actor is required","warning");return}B.value="checking";try{const f=await zi(e,d,u||void 0);Ze.value=f,B.value="ok",x("Eligibility updated","success")}catch(f){B.value="error";const c=f instanceof Error?f.message:"Eligibility check failed";x(c,"error")}},r=async()=>{const d=pe.value.trim(),u=ve.value.trim(),f=Xe.value.trim();if(!e||!d||!u){x("Room/Actor/Keeper is required","warning");return}B.value="requesting";try{const c=await Fi({room_id:e,actor_id:d,keeper_name:u,role:Qe.value,...f?{name:f}:{}});Ze.value=c;const p=dt(c)?te(c,"granted",!1):!1,m=dt(c)?F(c,"reason_code",""):"";p?x("Mid-join granted","success"):x(`Mid-join rejected${m?`: ${m}`:""}`,"warning"),B.value=p?"ok":"error",ut()}catch(c){B.value="error";const p=c instanceof Error?c.message:"Mid-join request failed";x(p,"error")}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${n!=null&&n.phase_open?"OPEN":"CLOSED"}</strong>
        ${n!=null&&n.window?o`<span style="margin-left:8px;">(${n.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(n==null?void 0:n.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <input
            id="trpg-join-actor-input"
            name="trpg-join-actor-input"
            type="text"
            value=${pe.value}
            onInput=${d=>{pe.value=d.target.value}}
            placeholder="player-xyz"
          />
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${ve.value}
            onInput=${d=>{ve.value=d.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Qe.value}
            onChange=${d=>{Qe.value=d.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Name (optional)</label>
          <input
            id="trpg-join-name-input"
            name="trpg-join-name-input"
            type="text"
            value=${Xe.value}
            onInput=${d=>{Xe.value=d.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${i} disabled=${B.value==="checking"||B.value==="requesting"}>
              ${B.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${r} disabled=${B.value==="checking"||B.value==="requesting"}>
              ${B.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${a?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${te(a,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Q(a,"effective_score",0)}/${Q(a,"required_points",0)}</span>
            ${F(a,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${F(a,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Or({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Mr({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function zr(){const t=Sn.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=dt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(dt).slice(-8),i=t.canon_check,r=dt(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],u=n?te(n,"advanced",!1):!1,f=n?F(n,"progress_reason",""):"",c=n?F(n,"progress_detail",""):"",p=n?Q(n,"player_successes",0):0,m=n?Q(n,"player_required_successes",0):0,h=n?te(n,"dm_success",!1):!1,R=n?Q(n,"timeouts",0):0,L=n?Q(n,"unavailable",0):0,A=n?Q(n,"reprompts",0):0,S=n?Q(n,"npc_attacks",0):0,z=n?Q(n,"keeper_timeout_sec",0):0,q=n?Q(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${h?"DM ok":"DM stalled"} / players ${p}/${m}
          </span>
        </div>
        ${f?o`<div style="margin-top:4px; font-size:12px;">${f}</div>`:null}
        ${c?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${R}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${L}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${z||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${q}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(D=>{const K=F(D,"status","unknown"),ot=F(D,"actor_id","-"),rt=F(D,"role","-"),G=F(D,"reason",""),et=F(D,"action_type",""),T=F(D,"reply","");return o`
                <div class="trpg-round-item ${K.includes("fallback")||K.includes("timeout")?"failed":"active"}">
                  <span>${ot} (${rt})</span>
                  <span style="margin-left:auto; font-size:11px;">${K}</span>
                  ${et?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${et}</div>`:null}
                  ${G?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${G}</div>`:null}
                  ${T?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${T.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${F(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(D=>o`<div>violation: ${D}</div>`)}
                </div>`:null}
            ${l.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(D=>o`<div>warning: ${D}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Fr(){var i,r;const t=ua.value;if(_n.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>ut()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome;return o`
    <div>
      <${Pr} outcome=${a} />

      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((i=t.session)==null?void 0:i.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((r=t.current_round)==null?void 0:r.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${s.length}</div>
        </div>
      </div>

      ${""}
      <${Mr} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${y} title="Story Log (${s.length})">
            <${Dr} events=${s} />
          <//>

          ${""}
          ${t.map?o`
              <${y} title="Map" style="margin-top:16px;">
                <${Lr} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${y} title="Controls">
            <${Ir} state=${t} />
          <//>

          <${y} title="Last Round Result" style="margin-top:16px;">
            <${zr} />
          <//>

          ${""}
          <${y} title="Mid-Join Gate" style="margin-top:16px;">
            <${jr} state=${t} />
          <//>

          ${""}
          <${y} title="Contribution" style="margin-top:16px;">
            <${Or} state=${t} />
          <//>

          ${""}
          <${y} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(l=>o`<${Rr} key=${l.id??l.name} actor=${l} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${y} title="History (${t.history.length})" style="margin-top:16px;">
                <${Er} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const Fn="masc_dashboard_agent_name";function Hr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Fn);return e??n??"dashboard"}const Y=_(Hr()),qt=_(""),Kt=_(""),Re=_(""),Gt=_(!1),gt=_(!1),Wt=_(!1),Vt=_(!1),Le=_(!1),Me=_(!1);function Hn(t){const e=t.trim();Y.value=e,e&&localStorage.setItem(Fn,e)}function Ur(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Cn(){const t=Y.value.trim();if(t){Wt.value=!0;try{const e=await Ui(t),n=Ur(e);n&&Hn(n),Me.value=!0,x(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";x(n,"error")}finally{Wt.value=!1}}}async function Br(){const t=Y.value.trim();if(t){Vt.value=!0;try{await ra(t),Me.value=!1,x(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";x(n,"error")}finally{Vt.value=!1}}}async function qr(){const t=Y.value.trim();if(t)try{await ra(t)}catch{}localStorage.removeItem(Fn),Hn("dashboard"),Me.value=!1,await Cn()}async function Kr(){const t=Y.value.trim();if(t){Le.value=!0;try{await Bi(t),x("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";x(n,"error")}finally{Le.value=!1}}}async function $s(){const t=Y.value.trim(),e=qt.value.trim();if(!(!t||!e)){Gt.value=!0;try{await oa(t,e),qt.value="",x("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";x(s,"error")}finally{Gt.value=!1}}}async function Gr(){const t=Kt.value.trim(),e=Re.value.trim()||"Created from dashboard";if(t){gt.value=!0;try{await Hi(t,e,1),Kt.value="",Re.value="",x("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";x(s,"error")}finally{gt.value=!1}}}function Wr(){return xt(()=>{Cn()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${Y.value}
        onInput=${t=>Hn(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${qt.value}
          onInput=${t=>{qt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&$s()}}
          disabled=${Gt.value}
        />
        <button
          class="control-btn"
          onClick=${$s}
          disabled=${Gt.value||qt.value.trim()===""||Y.value.trim()===""}
        >
          ${Gt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Cn()}}
          disabled=${Wt.value||Y.value.trim()===""}
        >
          ${Wt.value?"Joining...":Me.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Br()}}
          disabled=${Vt.value||Y.value.trim()===""}
        >
          ${Vt.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{qr()}}
          disabled=${Wt.value||Vt.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Kr()}}
          disabled=${Le.value||Y.value.trim()===""}
        >
          ${Le.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Kt.value}
        onInput=${t=>{Kt.value=t.target.value}}
        disabled=${gt.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${Re.value}
        onInput=${t=>{Re.value=t.target.value}}
        disabled=${gt.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${Gr}
        disabled=${gt.value||Kt.value.trim()===""}
      >
        ${gt.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function Vr(){const t=kt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Pn.value} events</span>
    </div>
  `}const Jr=[{id:"overview",label:"Overview"},{id:"council",label:"Decisions"},{id:"board",label:"Discussions"},{id:"execution",label:"Execution"},{id:"activity",label:"Activity"},{id:"goals",label:"Goals"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function Yr(){const t=Z.value.tab,e=kt.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Jr.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Ie(n.id)}
            >
              ${n.label}
            </button>
          `)}
        </div>
        <div class="rail-links">
          <a class="rail-link" href="/dashboard/lodge">Legacy Lodge</a>
          <a class="rail-link" href="/dashboard/credits">Legacy Credits</a>
        </div>
      </section>

      <section class="rail-card">
        <h3>Live Snapshot</h3>
        <div class="rail-stats">
          <div class="rail-stat-row">
            <span>Connection</span>
            <strong>${e?"Online":"Offline"}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Agents</span>
            <strong>${At.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Tt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${ae.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Pn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Oe(),t==="board"&&vt(),t==="trpg"&&ut()}}
        >
          Refresh Now
        </button>
      </section>

      <${Wr} />
    </aside>
  `}function Qr(){switch(Z.value.tab){case"overview":return o`<${ps} />`;case"council":return o`<${Fo} />`;case"board":return o`<${Yo} />`;case"execution":return o`<${pr} />`;case"activity":return o`<${tr} />`;case"agents":return o`<${cr} />`;case"tasks":return o`<${ur} />`;case"goals":return o`<${yr} />`;case"journal":return o`<${fr} />`;case"trpg":return o`<${Fr} />`;default:return o`<${ps} />`}}function Xr(){return xt(()=>{ti(),Zs(),Oe();const t=lo();return co(),()=>{ci(),t(),uo()}},[]),xt(()=>{const t=Z.value.tab;t==="board"&&vt(),t==="trpg"&&ut(),t==="goals"&&$n()},[Z.value.tab]),o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">Decision and execution operations console</p>
        </div>
        <div class="header-right">
          <${Vr} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${ni} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${fn.value&&!kt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Qr} />`}
        </main>
        <${Yr} />
      </div>

      <${ko} />
      <${Lo} />
      <${Co} />
    </div>
  `}const hs=document.getElementById("app");hs&&Oa(o`<${Xr} />`,hs);
