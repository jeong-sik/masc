var Al=Object.defineProperty;var wl=(t,e,n)=>e in t?Al(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Te=(t,e,n)=>wl(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var Xa,K,Jo,Vo,ve,Gi,Qo,Yo,Xo,Ni,Fs,Hs,Nn={},Zo=[],Tl=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Za=Array.isArray;function Ht(t,e){for(var n in e)t[n]=e[n];return t}function Ri(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function tr(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Xa.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return ra(t,r,a,s,null)}function ra(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Jo,__i:-1,__u:0};return s==null&&K.vnode!=null&&K.vnode(i),i}function Fn(t){return t.children}function ln(t,e){this.props=t,this.context=e}function Ue(t,e){if(e==null)return t.__?Ue(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Ue(t):null}function er(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return er(t)}}function Ji(t){(!t.__d&&(t.__d=!0)&&ve.push(t)&&!$a.__r++||Gi!=K.debounceRendering)&&((Gi=K.debounceRendering)||Qo)($a)}function $a(){for(var t,e,n,a,s,i,r,u=1;ve.length;)ve.length>u&&ve.sort(Yo),t=ve.shift(),u=ve.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=Ht({},a)).__v=a.__v+1,K.vnode&&K.vnode(n),Di(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??Ue(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,sr(i,n,r),a.__e=a.__=null,n.__e!=s&&er(n)));$a.__r=0}function nr(t,e,n,a,s,i,r,u,d,p,f){var l,c,m,$,y,k,R,T=a&&a.__k||Zo,M=e.length;for(d=Cl(n,e,T,d,M),l=0;l<M;l++)(m=n.__k[l])!=null&&(c=m.__i==-1?Nn:T[m.__i]||Nn,m.__i=l,k=Di(t,m,c,s,i,r,u,d,p,f),$=m.__e,m.ref&&c.ref!=m.ref&&(c.ref&&Pi(c.ref,null,m),f.push(m.ref,m.__c||$,m)),y==null&&$!=null&&(y=$),(R=!!(4&m.__u))||c.__k===m.__k?d=ar(m,d,t,R):typeof m.type=="function"&&k!==void 0?d=k:$&&(d=$.nextSibling),m.__u&=-7);return n.__e=y,d}function Cl(t,e,n,a,s){var i,r,u,d,p,f=n.length,l=f,c=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=ra(null,r,null,null,null):Za(r)?r=t.__k[i]=ra(Fn,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=ra(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+c,r.__=t,r.__b=t.__b+1,u=null,(p=r.__i=Nl(r,n,d,l))!=-1&&(l--,(u=n[p])&&(u.__u|=2)),u==null||u.__v==null?(p==-1&&(s>f?c--:s<f&&c++),typeof r.type!="function"&&(r.__u|=4)):p!=d&&(p==d-1?c--:p==d+1?c++:(p>d?c--:c++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<f;i++)(u=n[i])!=null&&(2&u.__u)==0&&(u.__e==a&&(a=Ue(u)),or(u,u));return a}function ar(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=ar(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=Ue(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Nl(t,e,n,a){var s,i,r,u=t.key,d=t.type,p=e[n],f=p!=null&&(2&p.__u)==0;if(p===null&&u==null||f&&u==p.key&&d==p.type)return n;if(a>(f?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((p=e[r=s>=0?s--:i++])!=null&&(2&p.__u)==0&&u==p.key&&d==p.type)return r}return-1}function Vi(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Tl.test(e)?n:n+"px"}function Vn(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||Vi(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||Vi(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Xo,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Ni,t.addEventListener(e,i?Hs:Fs,i)):t.removeEventListener(e,i?Hs:Fs,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Qi(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Ni++;else if(e.t<n.u)return;return n(K.event?K.event(e):e)}}}function Di(t,e,n,a,s,i,r,u,d,p){var f,l,c,m,$,y,k,R,T,M,C,D,Z,$t,dt,tt,it,I=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[u=e.__e=n.__e]),(f=K.__b)&&f(e);t:if(typeof I=="function")try{if(R=e.props,T="prototype"in I&&I.prototype.render,M=(f=I.contextType)&&a[f.__c],C=f?M?M.props.value:f.__:a,n.__c?k=(l=e.__c=n.__c).__=l.__E:(T?e.__c=l=new I(R,C):(e.__c=l=new ln(R,C),l.constructor=I,l.render=Dl),M&&M.sub(l),l.state||(l.state={}),l.__n=a,c=l.__d=!0,l.__h=[],l._sb=[]),T&&l.__s==null&&(l.__s=l.state),T&&I.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=Ht({},l.__s)),Ht(l.__s,I.getDerivedStateFromProps(R,l.__s))),m=l.props,$=l.state,l.__v=e,c)T&&I.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),T&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(T&&I.getDerivedStateFromProps==null&&R!==m&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(R,C),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(R,l.__s,C)===!1){for(e.__v!=n.__v&&(l.props=R,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(J){J&&(J.__=e)}),D=0;D<l._sb.length;D++)l.__h.push(l._sb[D]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(R,l.__s,C),T&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(m,$,y)})}if(l.context=C,l.props=R,l.__P=t,l.__e=!1,Z=K.__r,$t=0,T){for(l.state=l.__s,l.__d=!1,Z&&Z(e),f=l.render(l.props,l.state,l.context),dt=0;dt<l._sb.length;dt++)l.__h.push(l._sb[dt]);l._sb=[]}else do l.__d=!1,Z&&Z(e),f=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++$t<25);l.state=l.__s,l.getChildContext!=null&&(a=Ht(Ht({},a),l.getChildContext())),T&&!c&&l.getSnapshotBeforeUpdate!=null&&(y=l.getSnapshotBeforeUpdate(m,$)),tt=f,f!=null&&f.type===Fn&&f.key==null&&(tt=ir(f.props.children)),u=nr(t,Za(tt)?tt:[tt],e,n,a,s,i,r,u,d,p),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),k&&(l.__E=l.__=null)}catch(J){if(e.__v=null,d||i!=null)if(J.then){for(e.__u|=d?160:128;u&&u.nodeType==8&&u.nextSibling;)u=u.nextSibling;i[i.indexOf(u)]=null,e.__e=u}else{for(it=i.length;it--;)Ri(i[it]);Ks(e)}else e.__e=n.__e,e.__k=n.__k,J.then||Ks(e);K.__e(J,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):u=e.__e=Rl(n.__e,e,n,a,s,i,r,d,p);return(f=K.diffed)&&f(e),128&e.__u?void 0:u}function Ks(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Ks)}function sr(t,e,n){for(var a=0;a<n.length;a++)Pi(n[a],n[++a],n[++a]);K.__c&&K.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){K.__e(i,s.__v)}})}function ir(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Za(t)?t.map(ir):Ht({},t)}function Rl(t,e,n,a,s,i,r,u,d){var p,f,l,c,m,$,y,k=n.props||Nn,R=e.props,T=e.type;if(T=="svg"?s="http://www.w3.org/2000/svg":T=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(p=0;p<i.length;p++)if((m=i[p])&&"setAttribute"in m==!!T&&(T?m.localName==T:m.nodeType==3)){t=m,i[p]=null;break}}if(t==null){if(T==null)return document.createTextNode(R);t=document.createElementNS(s,T,R.is&&R),u&&(K.__m&&K.__m(e,i),u=!1),i=null}if(T==null)k===R||u&&t.data==R||(t.data=R);else{if(i=i&&Xa.call(t.childNodes),!u&&i!=null)for(k={},p=0;p<t.attributes.length;p++)k[(m=t.attributes[p]).name]=m.value;for(p in k)if(m=k[p],p!="children"){if(p=="dangerouslySetInnerHTML")l=m;else if(!(p in R)){if(p=="value"&&"defaultValue"in R||p=="checked"&&"defaultChecked"in R)continue;Vn(t,p,null,m,s)}}for(p in R)m=R[p],p=="children"?c=m:p=="dangerouslySetInnerHTML"?f=m:p=="value"?$=m:p=="checked"?y=m:u&&typeof m!="function"||k[p]===m||Vn(t,p,m,k[p],s);if(f)u||l&&(f.__html==l.__html||f.__html==t.innerHTML)||(t.innerHTML=f.__html),e.__k=[];else if(l&&(t.innerHTML=""),nr(e.type=="template"?t.content:t,Za(c)?c:[c],e,n,a,T=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&Ue(n,0),u,d),i!=null)for(p=i.length;p--;)Ri(i[p]);u||(p="value",T=="progress"&&$==null?t.removeAttribute("value"):$!=null&&($!==t[p]||T=="progress"&&!$||T=="option"&&$!=k[p])&&Vn(t,p,$,k[p],s),p="checked",y!=null&&y!=t[p]&&Vn(t,p,y,k[p],s))}return t}function Pi(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){K.__e(s,n)}}function or(t,e,n){var a,s;if(K.unmount&&K.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Pi(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){K.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&or(a[s],e,n||typeof t.type!="function");n||Ri(t.__e),t.__c=t.__=t.__e=void 0}function Dl(t,e,n){return this.constructor(t,n)}function Pl(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),K.__&&K.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],Di(e,t=e.__k=tr(Fn,null,[t]),s||Nn,Nn,e.namespaceURI,s?null:e.firstChild?Xa.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),sr(i,t,r)}Xa=Zo.slice,K={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(u){t=u}throw t}},Jo=0,Vo=function(t){return t!=null&&t.constructor===void 0},ln.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=Ht({},this.state),typeof t=="function"&&(t=t(Ht({},n),this.props)),t&&Ht(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Ji(this))},ln.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Ji(this))},ln.prototype.render=Fn,ve=[],Qo=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Yo=function(t,e){return t.__v.__b-e.__v.__b},$a.__r=0,Xo=/(PointerCapture)$|Capture$/i,Ni=0,Fs=Qi(!1),Hs=Qi(!0);var rr=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],u=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=u:r===4?a[1]=Object.assign(a[1]||{},u):r===5?(a[1]=a[1]||{})[e[++i]]=u:r===6?a[1][e[++i]]+=u+"":r?(s=t.apply(u,rr(t,u,n,["",null])),a.push(s),u[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(u)}return a},Yi=new Map;function Ll(t){var e=Yi.get(this);return e||(e=new Map,Yi.set(this,e)),(e=rr(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",u="",d=[0],p=function(c){i===1&&(c||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,c,r):i===3&&(c||r)?(d.push(3,c,r),i=2):i===2&&r==="..."&&c?d.push(4,c,0):i===2&&r&&!c?d.push(5,0,!0,r):i>=5&&((r||!c&&i===5)&&(d.push(i,0,r,s),i=6),c&&(d.push(i,c,0,s),i=6)),r=""},f=0;f<n.length;f++){f&&(i===1&&p(),p(f));for(var l=0;l<n[f].length;l++)a=n[f][l],i===1?a==="<"?(p(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:u?a===u?u="":r+=a:a==='"'||a==="'"?u=a:a===">"?(p(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[f][l+1]===">")?(p(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(p(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return p(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Ll.bind(tr),Rn,Q,os,Xi,Us=0,lr=[],X=K,Zi=X.__b,to=X.__r,eo=X.diffed,no=X.__c,ao=X.unmount,so=X.__;function Li(t,e){X.__h&&X.__h(Q,t,Us||e),Us=0;var n=Q.__H||(Q.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function cr(t){return Us=1,El(pr,t)}function El(t,e,n){var a=Li(Rn++,2);if(a.t=t,!a.__c&&(a.__=[pr(void 0,e),function(u){var d=a.__N?a.__N[0]:a.__[0],p=a.t(d,u);d!==p&&(a.__N=[p,a.__[1]],a.__c.setState({}))}],a.__c=Q,!Q.__f)){var s=function(u,d,p){if(!a.__c.__H)return!0;var f=a.__c.__H.__.filter(function(c){return!!c.__c});if(f.every(function(c){return!c.__N}))return!i||i.call(this,u,d,p);var l=a.__c.props!==u;return f.forEach(function(c){if(c.__N){var m=c.__[0];c.__=c.__N,c.__N=void 0,m!==c.__[0]&&(l=!0)}}),i&&i.call(this,u,d,p)||l};Q.__f=!0;var i=Q.shouldComponentUpdate,r=Q.componentWillUpdate;Q.componentWillUpdate=function(u,d,p){if(this.__e){var f=i;i=void 0,s(u,d,p),i=f}r&&r.call(this,u,d,p)},Q.shouldComponentUpdate=s}return a.__N||a.__}function xt(t,e){var n=Li(Rn++,3);!X.__s&&dr(n.__H,e)&&(n.__=t,n.u=e,Q.__H.__h.push(n))}function ur(t,e){var n=Li(Rn++,7);return dr(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Il(){for(var t;t=lr.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(la),t.__H.__h.forEach(Bs),t.__H.__h=[]}catch(e){t.__H.__h=[],X.__e(e,t.__v)}}X.__b=function(t){Q=null,Zi&&Zi(t)},X.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),so&&so(t,e)},X.__r=function(t){to&&to(t),Rn=0;var e=(Q=t.__c).__H;e&&(os===Q?(e.__h=[],Q.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(la),e.__h.forEach(Bs),e.__h=[],Rn=0)),os=Q},X.diffed=function(t){eo&&eo(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(lr.push(e)!==1&&Xi===X.requestAnimationFrame||((Xi=X.requestAnimationFrame)||Ol)(Il)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),os=Q=null},X.__c=function(t,e){e.some(function(n){try{n.__h.forEach(la),n.__h=n.__h.filter(function(a){return!a.__||Bs(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],X.__e(a,n.__v)}}),no&&no(t,e)},X.unmount=function(t){ao&&ao(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{la(a)}catch(s){e=s}}),n.__H=void 0,e&&X.__e(e,n.__v))};var io=typeof requestAnimationFrame=="function";function Ol(t){var e,n=function(){clearTimeout(a),io&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);io&&(e=requestAnimationFrame(n))}function la(t){var e=Q,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),Q=e}function Bs(t){var e=Q;t.__c=t.__(),Q=e}function dr(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}function pr(t,e){return typeof e=="function"?e(t):e}var Ml=Symbol.for("preact-signals");function ts(){if(ae>1)ae--;else{for(var t,e=!1;cn!==void 0;){var n=cn;for(cn=void 0,Ws++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&fr(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(Ws=0,ae--,e)throw t}}function zl(t){if(ae>0)return t();ae++;try{return t()}finally{ts()}}var H=void 0;function vr(t){var e=H;H=void 0;try{return t()}finally{H=e}}var cn=void 0,ae=0,Ws=0,ya=0;function mr(t){if(H!==void 0){var e=t.n;if(e===void 0||e.t!==H)return e={i:0,S:t,p:H.s,n:void 0,t:H,e:void 0,x:void 0,r:e},H.s!==void 0&&(H.s.n=e),H.s=e,t.n=e,32&H.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=H.s,e.n=void 0,H.s.n=e,H.s=e),e}}function et(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}et.prototype.brand=Ml;et.prototype.h=function(){return!0};et.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:vr(function(){var a;(a=e.W)==null||a.call(e)}))};et.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&vr(function(){var s;(s=e.Z)==null||s.call(e)}))}};et.prototype.subscribe=function(t){var e=this;return Hn(function(){var n=e.value,a=H;H=void 0;try{t(n)}finally{H=a}},{name:"sub"})};et.prototype.valueOf=function(){return this.value};et.prototype.toString=function(){return this.value+""};et.prototype.toJSON=function(){return this.value};et.prototype.peek=function(){var t=H;H=void 0;try{return this.value}finally{H=t}};Object.defineProperty(et.prototype,"value",{get:function(){var t=mr(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Ws>100)throw new Error("Cycle detected");this.v=t,this.i++,ya++,ae++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{ts()}}}});function _(t,e){return new et(t,e)}function fr(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function _r(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function gr(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function be(t,e){et.call(this,void 0),this.x=t,this.s=void 0,this.g=ya-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}be.prototype=new et;be.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ya))return!0;if(this.g=ya,this.f|=1,this.i>0&&!fr(this))return this.f&=-2,!0;var t=H;try{_r(this),H=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return H=t,gr(this),this.f&=-2,!0};be.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}et.prototype.S.call(this,t)};be.prototype.U=function(t){if(this.t!==void 0&&(et.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};be.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(be.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=mr(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function gt(t,e){return new be(t,e)}function hr(t){var e=t.u;if(t.u=void 0,typeof e=="function"){ae++;var n=H;H=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,Ei(t),a}finally{H=n,ts()}}}function Ei(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,hr(t)}function jl(t){if(H!==this)throw new Error("Out-of-order effect");gr(this),H=t,this.f&=-2,8&this.f&&Ei(this),ts()}function Qe(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Qe.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Qe.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,hr(this),_r(this),ae++;var t=H;return H=this,jl.bind(this,t)};Qe.prototype.N=function(){2&this.f||(this.f|=2,this.o=cn,cn=this)};Qe.prototype.d=function(){this.f|=8,1&this.f||Ei(this)};Qe.prototype.dispose=function(){this.d()};function Hn(t,e){var n=new Qe(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var $r,Qn,ql=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,yr=[];Hn(function(){$r=this.N})();function Ye(t,e){K[t]=e.bind(null,K[t]||function(){})}function ba(t){if(Qn){var e=Qn;Qn=void 0,e()}Qn=t&&t.S()}function br(t){var e=this,n=t.data,a=Hl(n);a.value=n;var s=ur(function(){for(var u=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var p=gt(function(){var m=a.value.value;return m===0?0:m===!0?"":m||""}),f=gt(function(){return!Array.isArray(p.value)&&!Vo(p.value)}),l=Hn(function(){if(this.N=kr,f.value){var m=p.value;u.__v&&u.__v.__e&&u.__v.__e.nodeType===3&&(u.__v.__e.data=m)}}),c=e.__$u.d;return e.__$u.d=function(){l(),c.call(this)},[f,p]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}br.displayName="ReactiveTextNode";Object.defineProperties(et.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:br},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Ye("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof et&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});Ye("__r",function(t,e){if(t(e),e.type!==Fn){ba();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return Hn(function(){r=this},{name:i}),r.c=s,r})(function(){var s;ql&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),ba(n)}});Ye("__e",function(t,e,n,a){ba(),t(e,n,a)});Ye("diffed",function(t,e){ba();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var u=i[r];u!==void 0&&!(r in a)&&(u.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var p=i[d],f=a[d];p===void 0?(p=Fl(n,d,f),i[d]=p):p.o(f,s)}for(var l in a)s[l]=a[l]}}t(e)});function Fl(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(u,d){i.value=u,r=u.peek()},d:Hn(function(){this.N=kr;var u=i.value.value;r!==u?(r=void 0,s?t[e]=u:u!=null&&(u!==!1||e[4]==="-")?t.setAttribute(e,u):t.removeAttribute(e)):r=void 0})}}Ye("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var u=r.__$u;u&&(r.__$u=void 0,u.d())}}t(e)});Ye("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});ln.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var u in this.props)if(!(u in t))return!0;return!1};function Hl(t,e){return ur(function(){return _(t,e)},[])}var Kl=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Ul(){zl(function(){for(var t;t=yr.shift();)$r.call(t)})}function kr(){yr.push(this)===1&&(K.requestAnimationFrame||Kl)(Ul)}const Bl=["command","overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],xr={tab:"overview",params:{},postId:null},Wl={journal:"activity",mdal:"goals"};function oo(t){return!!t&&Bl.includes(t)}function ro(t){if(t)return Wl[t]??t}function Gs(t){try{return decodeURIComponent(t)}catch{return t}}function Js(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function Gl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Sr(t,e){const n=ro(t[0]),a=ro(e.tab),s=oo(n)?n:oo(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Gs(t[2]):t[0]==="post"&&t[1]&&(i=Gs(t[1]))),{tab:s,params:e,postId:i}}function ka(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return xr;const n=Gs(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const u=n.indexOf("?");u>=0&&(a=n.slice(0,u),s=n.slice(u+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Js(s),r=Gl(a);return Sr(r,i)}function Jl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...xr,params:Js(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Js(e.replace(/^\?/,""));return Sr(a,s)}function Ar(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const zt=_(ka(window.location.hash));window.addEventListener("hashchange",()=>{zt.value=ka(window.location.hash)});function Tt(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Ar(n)}function Vl(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Ql(){if(window.location.hash&&window.location.hash!=="#"){zt.value=ka(window.location.hash);return}const t=Jl(window.location.pathname,window.location.search);if(t){zt.value=t;const e=Ar(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",zt.value=ka(window.location.hash)}const lo="masc_dashboard_sse_session_id",Yl=1e3,Xl=15e3,Bt=_(!1),Kn=_(0),wr=_(null),oe=_([]);function Zl(){let t=sessionStorage.getItem(lo);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(lo,t)),t}const tc=200;function ec(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};oe.value=[s,...oe.value].slice(0,tc)}function Vs(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function co(t,e){const n=Vs(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function At(t,e,n,a,s={}){ec(t,e,n,{eventType:a,...s})}let Mt=null,je=null,Qs=0;function Tr(){je&&(clearTimeout(je),je=null)}function nc(){if(je)return;Qs++;const t=Math.min(Qs,5),e=Math.min(Xl,Yl*Math.pow(2,t));je=setTimeout(()=>{je=null,Cr()},e)}function Cr(){Tr(),Mt&&(Mt.close(),Mt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",Zl());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);Mt=i,i.onopen=()=>{Mt===i&&(Qs=0,Bt.value=!0)},i.onerror=()=>{Mt===i&&(Bt.value=!1,i.close(),Mt=null,nc())},i.onmessage=r=>{try{const u=JSON.parse(r.data);Kn.value++,wr.value=u,ac(u)}catch{}}}function ac(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":At(n,"Joined","system","agent_joined");break;case"agent_left":At(n,"Left","system","agent_left");break;case"broadcast":At(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":At(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":At(n,co("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Vs(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":At(n,co("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Vs(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":At(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":At(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":At(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":At(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:At(n,e,"system","unknown")}}function sc(){Tr(),Mt&&(Mt.close(),Mt=null),Bt.value=!1}function Nr(){return new URLSearchParams(window.location.search)}function Rr(){const t=Nr(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Dr(){return{...Rr(),"Content-Type":"application/json"}}const ic=15e3,Ii=3e4,oc=6e4,uo=new Set([408,425,429,500,502,503,504]);class Un extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Te(this,"method");Te(this,"path");Te(this,"status");Te(this,"statusText");Te(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function Oi(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Un({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function rc(){var e,n;const t=Nr();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function St(t){const e=await Oi(t,{headers:Rr()},ic);if(!e.ok)throw new Un({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function lc(t){return new Promise(e=>setTimeout(e,t))}function cc(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function uc(t){if(t instanceof Un)return t.timeout||typeof t.status=="number"&&uo.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=cc(t.message);return e!==null&&uo.has(e)}async function Xe(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!uc(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await lc(i),a+=1}}async function Ft(t,e,n,a=Ii){const s=await Oi(t,{method:"POST",headers:{...Dr(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Un({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function dc(t,e,n,a=Ii){const s=await Oi(t,{method:"POST",headers:{...Dr(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Un({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function pc(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function vc(t){var e,n,a,s,i,r,u;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((u=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:u.text)??""}async function ht(t,e){const n=await dc("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},oc),a=pc(n);return vc(a)}function mc(t="compact"){return St(`/api/v1/dashboard?mode=${t}`)}function fc(t={}){return Xe("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return St(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function _c(){return St("/api/v1/operator")}function gc(){return St("/api/v1/command-plane")}function hc(){return St("/api/v1/command-plane/help")}function $c(t,e){return Ft(t,e)}function yc(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Ii}}function Bn(t){return Ft("/api/v1/operator/action",t,void 0,yc(t))}function bc(t,e){return Ft("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const kc=new Set(["lodge-system","team-session"]);function Be(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function xc(t){return kc.has(t.trim().toLowerCase())}function Sc(t){return t.filter(e=>!xc(e.author))}function Ac(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Pr(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),a=h(t.content,"").trim();if(!e||!n)return null;const s=q(t.score,0),i=q(t.votes_up,0),r=q(t.votes_down,0),u=q(t.votes,s||i-r),d=q(t.comment_count,q(t.reply_count,0)),p=(()=>{const $=t.flair;if(typeof $=="string"&&$.trim())return $.trim();if(O($)){const k=h($.name,"").trim();if(k)return k}return h(t.flair_name,"").trim()||void 0})(),f=h(t.created_at_iso,"").trim()||Be(t.created_at),l=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Be(t.updated_at):f),m=h(t.title,"").trim()||Ac(a);return{id:e,author:n,title:m,content:a,tags:[],votes:u,vote_balance:s,comment_count:d,created_at:f,updated_at:l,flair:p,hearth_count:q(t.hearth_count,0)}}function wc(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),a=h(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:h(t.content,""),created_at:Be(t.created_at)}}async function Tc(t,e){return Xe("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await St(`/api/v1/board${a?`?${a}`:""}`),i=Array.isArray(s.posts)?s.posts.map(Pr).filter(u=>u!==null):[];return{posts:e!=null&&e.excludeSystem?Sc(i):i}})}async function Cc(t){return Xe("fetchBoardPost",async()=>{const e=await St(`/api/v1/board/${t}?format=flat`),n=O(e.post)?e.post:e,a=Pr(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(wc).filter(r=>r!==null);return{...a,comments:i}})}function Lr(t,e){return Ft("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:rc()})}function Nc(t,e,n){return Ft("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Rc(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function ot(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function po(t){const e=Rc(ot(t.outcome,t.result,t.result_code));if(!e)return;const n=ot(t.reason,t.reason_code,t.description,t.detail),a=ot(t.summary,t.summary_ko,t.summary_en,t.note),s=ot(t.details,t.details_text,t.text,t.note),i=ot(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=ot(t.winner_actor_id,t.winner_actor,t.actor_winner_id),u=ot(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(c=>{if(typeof c=="string")return c.trim();if(O(c)){const m=h(c.summary,"").trim();if(m)return m;const $=h(c.text,"").trim();if($)return $;const y=h(c.type,"").trim();return y||h(c.event_id,"").trim()}return""}).filter(c=>c.length>0):[]})(),p=(()=>{const l=q(t.turn,Number.NaN);if(Number.isFinite(l))return l;const c=q(t.turn_number,Number.NaN);if(Number.isFinite(c))return c;const m=q(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const $=q(t.round,Number.NaN);return Number.isFinite($)?$:void 0})(),f=ot(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:u||void 0,turn:p,phase:f||void 0}}function Dc(t,e){const n=O(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>O(r)?h(r.type,"")==="session.outcome":!1),i=O(n.session_outcome)?n.session_outcome:{};if(O(i)&&Object.keys(i).length>0){const r=po(i);if(r)return r}if(O(s))return po(O(s.payload)?s.payload:{})}function O(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function q(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Pc(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ys(t,e=!1){return typeof t=="boolean"?t:e}function en(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(O(e)){const n=h(e.name,"").trim(),a=h(e.id,"").trim(),s=h(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function Lc(t){const e={};if(!O(t)&&!Array.isArray(t))return e;if(O(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=h(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!O(n))continue;const a=ot(n.to,n.target,n.actor_id,n.name,n.id),s=ot(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function Ec(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function yt(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const Ic=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Oc(t){const e=O(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(Ic.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function Mc(t,e){if(t!=="dice.rolled")return;const n=q(e.raw_d20,0),a=q(e.total,0),s=q(e.bonus,0),i=h(e.action,"roll"),r=q(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function zc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function jc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function qc(t,e,n,a){const s=n||e||h(a.actor_id,"")||h(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(a.proposed_action,h(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(a.reply,h(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(a.reply,h(a.content,h(a.text,"Narration")));case"dice.rolled":{const i=h(a.action,"roll"),r=q(a.total,0),u=q(a.dc,0),d=h(a.label,""),p=s||"actor",f=u>0?` vs DC ${u}`:"",l=d?` (${d})`:"";return`${p} ${i}: ${r}${f}${l}`}case"turn.started":return`Turn ${q(a.turn,1)} started`;case"phase.changed":return`Phase: ${h(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(a.name,O(a.actor)?h(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${h(a.keeper_name,h(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${h(a.keeper_name,h(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${q(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${q(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||h(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||h(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(a.reason_code,"unknown")}`;case"memory.signal":{const i=O(a.entity_refs)?a.entity_refs:{},r=h(i.requested_tier,""),u=h(i.effective_tier,""),d=Ys(i.guardrail_applied,!1),p=h(a.summary_en,h(a.summary_ko,"Memory signal"));if(!r&&!u)return p;const f=r&&u?`${r}->${u}`:u||r;return`${p} [${f}${d?" (guardrail)":""}]`}case"world.event":{if(h(a.event_type,"")==="canon.check"){const r=h(a.status,"unknown"),u=h(a.contract_id,"n/a");return`Canon ${r}: ${u}`}return h(a.description,h(a.summary,"World event"))}case"combat.attack":return h(a.summary,h(a.result,"Attack resolved"));case"combat.defense":return h(a.summary,h(a.result,"Defense resolved"));case"session.outcome":return h(a.summary,h(a.outcome,"Session ended"));default:{const i=zc(a);return i?`${t}: ${i}`:t}}}function Fc(t,e){const n=O(t)?t:{},a=h(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[s]||h(O(n.payload)?n.payload.actor_name:"",""),r=O(n.payload)?n.payload:{},u=h(n.ts,h(n.timestamp,new Date().toISOString())),d=h(n.phase,h(r.phase,"")),p=h(n.category,"");return{type:a,actor:i||s||h(r.actor_name,""),actor_id:s||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:d||void 0,category:p||jc(a),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:qc(a,s,i,r),dice_roll:Mc(a,r),timestamp:u}}function Hc(t,e,n){var tt,it;const a=h(t.room_id,"")||n||"default",s=O(t.state)?t.state:{},i=O(s.party)?s.party:{},r=O(s.actor_control)?s.actor_control:{},u=O(s.join_gate)?s.join_gate:{},d=O(s.contribution_ledger)?s.contribution_ledger:{},p=Object.entries(i).map(([I,J])=>{const b=O(J)?J:{},Dt=yt(b,"max_hp",void 0,10),Yt=yt(b,"hp",void 0,Dt),ue=yt(b,"max_mp",void 0,0),L=yt(b,"mp",void 0,0),Pt=yt(b,"level",void 0,1),de=yt(b,"xp",void 0,0),Jn=Ys(b.alive,Yt>0),v=r[I],N=typeof v=="string"?v:void 0,F=Ec(b.role,I,N),nt=Pc(b.generation),j=ot(b.joined_at,b.joinedAt,b.started_at,b.startedAt),lt=ot(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),Y=ot(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),V=ot(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),ct=ot(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:I,name:h(b.name,I),role:F,keeper:N,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:en(b.traits),skills:en(b.skills),stats_raw:Oc(b),status:Jn?"active":"dead",generation:nt,joined_at:j||void 0,claimed_at:lt||void 0,last_seen:Y||void 0,scene:V||void 0,location:ct||void 0,inventory:en(b.inventory),notes:en(b.notes),relationships:Lc(b.relationships),stats:{hp:Yt,max_hp:Dt,mp:L,max_mp:ue,level:Pt,xp:de,strength:yt(b,"strength","str",10),dexterity:yt(b,"dexterity","dex",10),constitution:yt(b,"constitution","con",10),intelligence:yt(b,"intelligence","int",10),wisdom:yt(b,"wisdom","wis",10),charisma:yt(b,"charisma","cha",10)}}}),f=p.filter(I=>I.status!=="dead"),l=Dc(t,e),c={phase_open:Ys(u.phase_open,!0),min_points:q(u.min_points,3),window:h(u.window,"round_boundary_only"),last_opened_turn:typeof u.last_opened_turn=="number"?u.last_opened_turn:null,last_closed_turn:typeof u.last_closed_turn=="number"?u.last_closed_turn:null},m=Object.entries(d).map(([I,J])=>{const b=O(J)?J:{};return{actor_id:I,score:q(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:en(b.reasons)}}),$=p.reduce((I,J)=>(I[J.id]=J.name,I),{}),y=e.map(I=>Fc(I,$)),k=q(s.turn,1),R=h(s.phase,"round"),T=h(s.map,""),M=O(s.world)?s.world:{},C=T||h(M.ascii_map,h(M.map,"")),D=y.filter((I,J)=>{const b=e[J];if(!O(b))return!1;const Dt=O(b.payload)?b.payload:{};return q(Dt.turn,-1)===k}),Z=(D.length>0?D:y).slice(-12),$t=h(s.status,"active");return{session:{id:a,room:a,status:$t==="ended"?"ended":$t==="paused"?"paused":"active",round:k,actors:f,created_at:((tt=y[0])==null?void 0:tt.timestamp)??new Date().toISOString()},current_round:{round_number:k,phase:R,events:Z,timestamp:((it=y[y.length-1])==null?void 0:it.timestamp)??new Date().toISOString()},map:C||void 0,join_gate:c,contribution_ledger:m,outcome:l,party:f,story_log:y,history:[]}}async function Kc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await St(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Uc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([St(`/api/v1/trpg/state${e}`),Kc(t)]);return Hc(n,a,t)}function Bc(t){return Ft("/api/v1/trpg/rounds/run",{room_id:t})}function Wc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Gc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ft("/api/v1/trpg/dice/roll",e)}function Jc(t,e){const n=Wc();return Ft("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Vc(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Ft("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function Qc(t,e,n){return Ft("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Yc(t,e,n){const a=await ht("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Xc(t){const e=await ht("trpg.mid_join.request",t);return JSON.parse(e)}async function Er(t,e){await ht("masc_broadcast",{agent_name:t,message:e})}async function Zc(t,e,n=1){await ht("masc_add_task",{title:t,description:e,priority:n})}async function tu(t){return ht("masc_join",{agent_name:t})}async function Ir(t){await ht("masc_leave",{agent_name:t})}async function eu(t){await ht("masc_heartbeat",{agent_name:t})}async function nu(t=40){return(await ht("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function au(t,e=20){return ht("masc_task_history",{task_id:t,limit:e})}async function su(){return Xe("fetchDebates",async()=>{const t=await St("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:h(e.status,"open"),argument_count:q(e.argument_count,0),created_at:Be(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function iu(){return Xe("fetchCouncilSessions",async()=>{const t=await St("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:h(e.initiator,"system"),votes:q(e.votes,0),quorum:q(e.quorum,0),state:h(e.state,"open"),created_at:Be(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function ou(t){const e=await ht("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function ru(t){return Xe("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await St(`/api/v1/council/debates/${e}/summary`);if(!O(n))return null;const a=h(n.id,"").trim();return a?{id:a,topic:h(n.topic,""),status:h(n.status,"open"),support_count:q(n.support_count,0),oppose_count:q(n.oppose_count,0),neutral_count:q(n.neutral_count,0),total_arguments:q(n.total_arguments,0),created_at:Be(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function lu(t,e,n){return ht("masc_keeper_msg",{name:t,message:e})}async function cu(){try{const t=await ht("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const un=_(""),Wt=_({}),rt=_({}),Xs=_({}),Zs=_({}),ti=_({}),ei=_({}),Gt=_({});function st(t,e,n){t.value={...t.value,[e]:n}}function Vt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function B(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Ct(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ie(t){return typeof t=="boolean"?t:void 0}function ni(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function ai(t){return Array.isArray(t)?t.map(e=>B(e)).filter(e=>!!e):[]}function uu(t){var n;const e=(n=B(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function du(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function rs(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Vt(a))continue;const s=B(a.name);if(!s)continue;const i=B(a[e]);e==="summary"?n.push({name:s,summary:i}):n.push({name:s,reason:i})}return n}function pu(t){if(!Vt(t))return null;const e=B(t.name);return e?{name:e,trigger:B(t.trigger),outcome:B(t.outcome),summary:B(t.summary),reason:B(t.reason)}:null}function vu(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function mu(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Or(t,e,n){return B(t)??mu(e,n)}function Mr(t,e){return typeof t=="boolean"?t:e==="recover"}function xa(t){if(!Vt(t))return null;const e=B(t.health_state),n=B(t.next_action_path),a=B(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:B(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:ni(t.last_reply_at),last_reply_preview:B(t.last_reply_preview)??null,last_error:B(t.last_error)??null,next_eligible_at_s:Ct(t.next_eligible_at_s)??null,recoverable:Mr(t.recoverable,n),summary:Or(t.summary,e,B(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Mi(t){return Vt(t)?{hour:Ct(t.hour),checked:Ct(t.checked)??0,acted:Ct(t.acted)??0,acted_names:ai(t.acted_names),activity_report:B(t.activity_report),quiet_hours_overridden:Ie(t.quiet_hours_overridden),skipped_reason:B(t.skipped_reason),acted_rows:rs(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:rs(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:rs(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(pu).filter(e=>e!==null):[]}:null}function fu(t){return Vt(t)?{enabled:Ie(t.enabled)??!1,interval_s:Ct(t.interval_s)??0,quiet_start:Ct(t.quiet_start),quiet_end:Ct(t.quiet_end),quiet_active:Ie(t.quiet_active),use_planner:Ie(t.use_planner),delegate_llm:Ie(t.delegate_llm),agent_count:Ct(t.agent_count),agents:ai(t.agents),last_tick_ago_s:Ct(t.last_tick_ago_s)??null,last_tick_ago:B(t.last_tick_ago),total_ticks:Ct(t.total_ticks),total_checkins:Ct(t.total_checkins),last_skip_reason:B(t.last_skip_reason)??null,last_tick_result:Mi(t.last_tick_result),active_self_heartbeats:ai(t.active_self_heartbeats)}:null}function _u(t){return Vt(t)?{status:t.status,diagnostic:xa(t.diagnostic)}:null}function gu(t){return Vt(t)?{recovered:Ie(t.recovered)??!1,skipped_reason:B(t.skipped_reason)??null,before:xa(t.before),after:xa(t.after),down:t.down,up:t.up}:null}function hu(t,e){var T,M;if(!(t!=null&&t.name))return null;const n=B((T=t.agent)==null?void 0:T.status)??B(t.status)??"unknown",a=B((M=t.agent)==null?void 0:M.error)??null,s=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,u=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,p=t.proactive_cooldown_sec??0,f=t.last_proactive_ago_s??null,l=d&&f!=null?Math.max(0,p-f):null,c=r<=0||u==null?"never":u>900?"stale":"fresh",m=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,$=a??(s&&!i?"keeper keepalive is not running":null),y=n==="offline"||n==="inactive"?"offline":$?"degraded":c==="stale"?"stale":c==="never"?"idle":"healthy",k=$?vu($):e!=null&&e.quiet_active&&c!=="fresh"?"quiet_hours":s&&!i?"disabled":r<=0?"never_started":l!=null&&l>0?"min_gap":c==="fresh"||c==="stale"?"no_recent_activity":"unknown",R=y==="offline"||y==="degraded"||y==="stale"?"recover":k==="quiet_hours"?"manual_lodge_poke":k==="unknown"?"probe":"direct_message";return{health_state:y,quiet_reason:k,next_action_path:R,last_reply_status:c,last_reply_at:m,last_reply_preview:null,last_error:$,next_eligible_at_s:l!=null&&l>0?l:null,recoverable:Mr(void 0,R),summary:Or(void 0,y,k),keepalive_running:i}}function $u(t,e){if(!Vt(t))return null;const n=uu(t.role),a=B(t.content)??B(t.preview);if(!a)return null;const s=ni(t.ts_unix)??ni(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:du(n),text:a,timestamp:s,delivery:"history"}}function yu(t,e,n){const a=Vt(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((i,r)=>$u(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:xa(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function vo(t,e){const n=rt.value[t]??[];rt.value={...rt.value,[t]:[...n,e].slice(-50)}}function bu(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function ku(t,e){const a=(rt.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(i=>bu(s,i)));rt.value={...rt.value,[t]:[...e,...a].slice(-50)}}function es(t,e){Wt.value={...Wt.value,[t]:e},ku(t,e.history)}function mo(t,e){const n=Wt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};es(t,{...n,diagnostic:{...a,...e}})}async function zi(){We();try{await xe()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function ca(t){un.value=t.trim()}async function zr(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Wt.value[n])return Wt.value[n];st(Xs,n,!0),st(Gt,n,null);try{const a=await ht("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const i=yu(n,a,s);return es(n,i),i}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return st(Gt,n,s),null}finally{st(Xs,n,!1)}}async function xu(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;vo(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),st(Zs,n,!0),st(Gt,n,null);try{const i=await lu(n,a);rt.value={...rt.value,[n]:(rt.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},vo(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),mo(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await zi()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw rt.value={...rt.value,[n]:(rt.value[n]??[]).map(u=>u.id===s?{...u,delivery:"error",error:r}:u)},mo(n,{last_reply_status:"error",last_error:r}),st(Gt,n,r),i}finally{st(Zs,n,!1)}}async function Su(t,e){const n=t.trim();if(!n)return null;st(ti,n,!0),st(Gt,n,null);try{const a=await Bn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=_u(a.result),i=(s==null?void 0:s.diagnostic)??null;if(i){const r=Wt.value[n];es(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??rt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await zi(),i}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw st(Gt,n,s),a}finally{st(ti,n,!1)}}async function Au(t,e){const n=t.trim();if(!n)return null;st(ei,n,!0),st(Gt,n,null);try{const a=await Bn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=gu(a.result),i=(s==null?void 0:s.after)??null;if(i){const r=Wt.value[n];es(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??rt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await zi(),i}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw st(Gt,n,s),a}finally{st(ei,n,!1)}}const Qt=_([]),_t=_([]),ye=_([]),Nt=_([]),ke=_(null),rn=_(null),si=_(new Map),Jt=_([]),Dn=_("hot"),me=_(!0),jr=_(null),Kt=_(""),Pn=_([]),Oe=_(!1),qr=_(new Map),ii=_("unknown"),oi=_(null),ri=_(!1),Ln=_(!1),li=_(!1),Me=_(!1),wu=_(null),ci=_(null),Fr=_(null),Hr=_(null),Tu=gt(()=>Qt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Kr=gt(()=>{const t=_t.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Cu(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Ur=gt(()=>{const t=new Map;for(const e of Nt.value)t.set(e.name,Cu(e));return t}),Nu=12e4;function Ru(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof s=="number"?Date.now()-s*1e3:null}const Br=gt(()=>{const t=Date.now(),e=new Set,n=si.value;for(const a of Nt.value){const s=Ru(a,n);s!=null&&t-s>Nu&&e.add(a.name)}return e}),Sa={},Du=5e3;function We(){delete Sa.compact,delete Sa.full}function ut(t){return typeof t=="object"&&t!==null}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function dn(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Pu(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Wr(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Lu(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Eu(t){if(!ut(t))return null;const e=x(t.name);return e?{name:e,status:Wr(t.status),current_task:x(t.current_task)??null,last_seen:x(t.last_seen),emoji:x(t.emoji),koreanName:x(t.koreanName)??x(t.korean_name),model:x(t.model),traits:dn(t.traits),interests:dn(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:x(t.primaryValue)??x(t.primary_value)}:null}function Iu(t){if(!ut(t))return null;const e=x(t.id),n=x(t.title);return!e||!n?null:{id:e,title:n,status:Lu(t.status),priority:A(t.priority),assignee:x(t.assignee),description:x(t.description),created_at:x(t.created_at),updated_at:x(t.updated_at)}}function Ou(t){if(!ut(t))return null;const e=x(t.from)??x(t.from_agent)??"system",n=x(t.content)??"",a=x(t.timestamp)??new Date().toISOString();return{id:x(t.id),seq:A(t.seq),from:e,content:n,timestamp:a,type:x(t.type)}}function Mu(t){return Array.isArray(t)?t.map(e=>{if(!ut(e))return null;const n=A(e.ts_unix);if(n==null)return null;const a=ut(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?A(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function fo(t){if(!ut(t))return null;const e=x(t.health_state),n=x(t.next_action_path),a=x(t.last_reply_status);if(!e||!n||!a)return null;const s=x(t.quiet_reason)??null,i=x(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":s==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":s==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":s==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:s,next_action_path:n,last_reply_status:a,last_reply_at:Pu(t.last_reply_at)??x(t.last_reply_at)??null,last_reply_preview:x(t.last_reply_preview)??null,last_error:x(t.last_error)??null,next_eligible_at_s:A(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function zu(t,e){return(Array.isArray(t)?t:ut(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!ut(a))return null;const s=ut(a.agent)?a.agent:null,i=ut(a.context)?a.context:null,r=ut(a.metrics_window)?a.metrics_window:void 0,u=x(a.name);if(!u)return null;const d=A(a.context_ratio)??A(i==null?void 0:i.context_ratio),p=x(a.status)??x(s==null?void 0:s.status)??"offline",f=Wr(p),l=x(a.model)??x(a.active_model)??x(a.primary_model),c=dn(a.skill_secondary),m=i?{source:x(i.source),context_ratio:A(i.context_ratio),context_tokens:A(i.context_tokens),context_max:A(i.context_max),message_count:A(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,$=s?{name:x(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:x(s.error),status:x(s.status),current_task:x(s.current_task)??null,last_seen:x(s.last_seen),last_seen_ago_s:A(s.last_seen_ago_s),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,y=Mu(a.metrics_series),k={name:u,emoji:x(a.emoji),koreanName:x(a.koreanName)??x(a.korean_name),agent_name:x(a.agent_name),trace_id:x(a.trace_id),model:l,primary_model:x(a.primary_model),active_model:x(a.active_model),next_model_hint:x(a.next_model_hint)??null,status:f,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:A(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:A(a.proactive_idle_sec),proactive_cooldown_sec:A(a.proactive_cooldown_sec),last_heartbeat:x(a.last_heartbeat)??x(s==null?void 0:s.last_seen),generation:A(a.generation),turn_count:A(a.turn_count)??A(a.total_turns),keeper_age_s:A(a.keeper_age_s),last_turn_ago_s:A(a.last_turn_ago_s),last_handoff_ago_s:A(a.last_handoff_ago_s),last_compaction_ago_s:A(a.last_compaction_ago_s),last_proactive_ago_s:A(a.last_proactive_ago_s),context_ratio:d,context_tokens:A(a.context_tokens)??A(i==null?void 0:i.context_tokens),context_max:A(a.context_max)??A(i==null?void 0:i.context_max),context_source:x(a.context_source)??x(i==null?void 0:i.source),context:m,traits:dn(a.traits),interests:dn(a.interests),primaryValue:x(a.primaryValue)??x(a.primary_value),activityLevel:A(a.activityLevel)??A(a.activity_level),memory_recent_note:x(a.memory_recent_note)??null,conversation_tail_count:A(a.conversation_tail_count),k2k_count:A(a.k2k_count),handoff_count_total:A(a.handoff_count_total)??A(a.trace_history_count),compaction_count:A(a.compaction_count),last_compaction_saved_tokens:A(a.last_compaction_saved_tokens),diagnostic:fo(a.diagnostic),skill_primary:x(a.skill_primary)??null,skill_secondary:c,skill_reason:x(a.skill_reason)??null,metrics_series:y.length>0?y:void 0,metrics_window:r,agent:$};return k.diagnostic=fo(a.diagnostic)??hu(k,(e==null?void 0:e.lodge)??null),k}).filter(a=>a!==null)}function ju(t){return ut(t)?{...t,lodge:fu(t.lodge)??void 0}:null}function qu(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Fu(t){if(!ut(t))return null;const e=A(t.iteration);if(e==null)return null;const n=A(t.metric_before)??0,a=A(t.metric_after)??n;return{iteration:e,metric_before:n,metric_after:a,delta:A(t.delta)??a-n,changes:x(t.changes)??"",failed_attempts:x(t.failed_attempts)??"",next_suggestion:x(t.next_suggestion)??"",elapsed_ms:A(t.elapsed_ms)??0,cost_usd:A(t.cost_usd)??null}}function Hu(t){var i,r;if(!ut(t))return null;const e=x(t.loop_id);if(!e)return null;const n=A(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(Fu).filter(u=>u!==null):[],s=A(t.current_metric)??((i=a[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:x(t.profile)??"unknown",status:qu(t.status),current_iteration:A(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:A(t.max_iterations)??0,baseline_metric:n,current_metric:s,target:x(t.target)??"",stagnation_streak:A(t.stagnation_streak)??0,stagnation_limit:A(t.stagnation_limit)??0,elapsed_seconds:A(t.elapsed_seconds)??0,history:a}}async function xe(t="full"){var a,s,i;const e=Date.now(),n=Sa[t];if(!(n&&e-n.time<Du)){ri.value=!0;try{const r=await mc(t);Sa[t]={data:r,time:e},Qt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Eu).filter(d=>d!==null),_t.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(Iu).filter(d=>d!==null),ye.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Ou).filter(d=>d!==null);const u=ju(r.status);ke.value=u,Nt.value=zu(r.keepers,u),rn.value=r.perpetual??null,wu.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{ri.value=!1}}}async function jt(){Ln.value=!0;try{const t=await Tc(Dn.value,{excludeSystem:me.value});Jt.value=t.posts??[],ci.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Ln.value=!1}}async function Ut(){var t;li.value=!0;try{const e=Kt.value||((t=ke.value)==null?void 0:t.room)||"default";Kt.value||(Kt.value=e);const n=await Uc(e);jr.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{li.value=!1}}async function pn(){Oe.value=!0;try{const t=await cu();Pn.value=Array.isArray(t)?t:[],Fr.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Oe.value=!1}}async function qe(){Me.value=!0;try{const t=await fc(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const s=Hu(a);s&&n.set(s.loop_id,s)}qr.value=n,Hr.value=new Date().toISOString(),oi.value=null,ii.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),ii.value="error",oi.value=t instanceof Error?t.message:String(t)}finally{Me.value=!1}}let ua=null;function Ku(t){ua=t}let ls=null,cs=null,us=null,ds=null;function Uu(){us||(us=setTimeout(()=>{ua==null||ua(),us=null},500))}function Bu(){ds||(ds=setTimeout(()=>{qe(),ds=null},350))}function Wu(){return wr.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(si.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),si.value=n}We(),ls||(ls=setTimeout(()=>{xe(),ls=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(cs||(cs=setTimeout(()=>{jt(),cs=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&We(),e.type.startsWith("decision_")&&Uu(),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&Bu()}})}let vn=null;function Gu(){vn||(vn=setInterval(()=>{We(),xe()},1e4))}function Ju(){vn&&(clearInterval(vn),vn=null)}function w({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Rt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Vu(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function U({timestamp:t}){const e=Vu(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function pe(t){return(t??"").trim().toLowerCase()}function pt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function da(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Yn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function nn(t){return t.last_heartbeat??Yn(t.last_turn_ago_s)??Yn(t.last_proactive_ago_s)??Yn(t.last_handoff_ago_s)??Yn(t.last_compaction_ago_s)}function Qu(t){const e=t.title.trim();return e||da(t.content)}function Yu(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function En(t,e,n,a,s={}){var M;const i=pe(t),r=e.filter(C=>pe(C.assignee)===i&&(C.status==="claimed"||C.status==="in_progress")).length,u=n.filter(C=>pe(C.from)===i).sort((C,D)=>pt(D.timestamp)-pt(C.timestamp))[0],d=a.filter(C=>pe(C.agent)===i||pe(C.author)===i).sort((C,D)=>pt(D.timestamp)-pt(C.timestamp))[0],p=(s.boardPosts??[]).filter(C=>pe(C.author)===i).sort((C,D)=>pt(D.updated_at||D.created_at)-pt(C.updated_at||C.created_at))[0],f=(s.keepers??[]).filter(C=>pe(C.name)===i&&nn(C)!==null).sort((C,D)=>pt(nn(D)??0)-pt(nn(C)??0))[0],l=u?pt(u.timestamp):0,c=d?pt(d.timestamp):0,m=p?pt(p.updated_at||p.created_at):0,$=f?pt(nn(f)??0):0,y=s.lastSeen?pt(s.lastSeen):0,k=((M=s.currentTask)==null?void 0:M.trim())||(r>0?`${r} claimed tasks`:null);if(l===0&&c===0&&m===0&&$===0&&y===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:k};const T=[u?{timestamp:u.timestamp,ts:l,text:da(u.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:m,text:`Post: ${da(Qu(p))}`}:null,f?{timestamp:nn(f),ts:$,text:Yu(f)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:c,text:da(d.text)}:null].filter(C=>C!==null).sort((C,D)=>D.ts-C.ts)[0];return T&&T.ts>=y?{activeAssignedCount:r,lastActivityAt:T.timestamp,lastActivityText:T.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:k??"Presence heartbeat"}}let Xu=0;const fe=_([]);function S(t,e="success",n=4e3){const a=++Xu;fe.value=[...fe.value,{id:a,message:t,type:e}],setTimeout(()=>{fe.value=fe.value.filter(s=>s.id!==a)},n)}function Zu(t){fe.value=fe.value.filter(e=>e.id!==t)}function td(){const t=fe.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Zu(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}function ed(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function nd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function ad(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function _o(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Gr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function sd(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Jr(t){if(!t)return null;const e=Wt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Vr({keeper:t,showRawStatus:e=!1}){if(xt(()=>{t!=null&&t.name&&zr(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Wt.value[t.name],a=Jr(t),s=Xs.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${ed(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${nd((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?o` · ${Gr(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?o` · next eligible ${sd(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?o`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Qr({keeperName:t,placeholder:e}){const[n,a]=cr("");xt(()=>{t&&zr(t)},[t]);const s=rt.value[t]??[],i=Zs.value[t]??!1,r=Gt.value[t],u=async()=>{const d=n.trim();if(!(!t||!d)){a("");try{await xu(t,d)}catch(p){const f=p instanceof Error?p.message:`Failed to message ${t}`;S(f,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(d=>o`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${_o(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${_o(d)}`}>${ad(d)}</span>
                  ${d.timestamp?o`<span class="keeper-conversation-time">${Gr(d.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${d.text}</div>
                ${d.error?o`<div class="keeper-conversation-error">${d.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${d=>{a(d.target.value)}}
          disabled=${i||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{u()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?o`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Yr({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=Jr(e),s=ti.value[e.name]??!1,i=ei.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",u=(a==null?void 0:a.recoverable)??r==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Su(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to probe ${e.name}`;S(p,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Au(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to recover ${e.name}`;S(p,"error")})}}
        disabled=${i||!u||!t.trim()}
      >
        ${i?"Recovering...":"Recover"}
      </button>
      <button
        class=${`control-btn ghost ${r==="manual_lodge_poke"?"is-active":""}`}
        onClick=${n}
      >
        Poke Lodge
      </button>
    </div>
  `}const ji=_(null);function Aa(t){ji.value=t,ca(t.name)}function go(){ji.value=null}const De=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function id(t){if(!t)return 0;const e=De.findIndex(n=>n.level===t);return e>=0?e:0}function od({keeper:t}){const e=id(t.autonomy_level),n=De[e]??De[0];if(!n)return null;const a=(e+1)/De.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${De.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${De.map((s,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?s.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${U} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function pa(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function rd({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${pa(t.context_tokens)}</div>
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
        <div class="kpi-value">${a}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function ld({keeper:t}){var f,l;const e=t.metrics_series??[];if(e.length<2){const c=(((f=t.context)==null?void 0:f.context_ratio)??0)*100,m=c>85?"#ef4444":c>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${c.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${c.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((c,m)=>{const $=s+m/(i-1)*(n-2*s),y=a-s-(c.context_ratio??0)*(a-2*s);return{x:$,y,p:c}}),u=r.map(({x:c,y:m})=>`${c.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,p=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:c})=>c.is_handoff).map(({x:c})=>o`
          <line x1="${c.toFixed(1)}" y1="${s}" x2="${c.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${u}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${r.filter(({p:c})=>c.is_compaction).map(({x:c,y:m})=>o`
          <circle cx="${c.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const ps=_("");function cd({keeper:t}){var s,i,r,u;const e=ps.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ps.value}
        onInput=${d=>{ps.value=d.target.value}}
      />
      ${a.map(d=>o`
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${pa(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${pa(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${pa(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((u=t.context)==null?void 0:u.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function ud({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(a=>o`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${a.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${a.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function dd({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function pd({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function ho({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function vs(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function vd({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:vs(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:vs(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:vs(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Xr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function md(){try{const t=await Bn({actor:Xr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Mi(t.result);We(),await xe(),e!=null&&e.skipped_reason?S(e.skipped_reason,"warning"):S(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";S(e,"error")}}function fd({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Vr} keeper=${t} />
          <${Yr}
            actor=${Xr()}
            keeper=${t}
            onPokeLodge=${()=>{md()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Qr}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function _d(){var e,n,a;const t=ji.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&go()}}
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
            <${Rt} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>go()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${rd} keeper=${t} />

        ${""}
        <${ld} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${cd} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${ho} traits=${t.traits??[]} label="Traits" />
            <${ho} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${U} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${w} title="Autonomy">
                <${od} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${w} title="TRPG Stats">
                <${ud} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${w} title="Equipment (${t.inventory.length})">
                <${dd} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${pd} rels=${t.relationships} />
              <//>
            `:null}

          <${w} title="Runtime Signals">
            <${vd} keeper=${t} />
          <//>

          <${w} title="Memory & Context">
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
                  ${t.context_max??((a=t.context)==null?void 0:a.context_max)??"-"}
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
        <${fd} keeper=${t} />
      </div>
    </div>
  `:null}const gd="masc_dashboard_agent_name",Ze=_(null),wa=_(!1),In=_(""),Ta=_([]),On=_([]),Fe=_(""),mn=_(!1);function He(t){Ze.value=t,qi()}function $o(){Ze.value=null,In.value="",Ta.value=[],On.value=[],Fe.value=""}function hd(){const t=Ze.value;return t?Qt.value.find(e=>e.name===t)??null:null}function Zr(t){return t?_t.value.filter(e=>e.assignee===t):[]}async function qi(){const t=Ze.value;if(t){wa.value=!0,In.value="",Ta.value=[],On.value=[];try{const e=await nu(80);Ta.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Zr(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await au(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));On.value=a}catch(e){In.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{wa.value=!1}}}async function yo(){var a;const t=Ze.value,e=Fe.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(gd))==null?void 0:a.trim())||"dashboard";mn.value=!0;try{await Er(n,`@${t} ${e}`),Fe.value="",S(`Mention sent to ${t}`,"success"),qi()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";S(i,"error")}finally{mn.value=!1}}function $d({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Rt} status=${t.status} />
    </div>
  `}function yd({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function bd(){var s,i,r,u;const t=Ze.value;if(!t)return null;const e=hd(),n=Zr(t),a=Ta.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&$o()}}
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
                        <${Rt} status=${e.status} />
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
            ${(((s=e==null?void 0:e.traits)==null?void 0:s.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(d=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(u=e==null?void 0:e.interests)==null?void 0:u.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${U} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{qi()}} disabled=${wa.value}>
              ${wa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${$o}>Close</button>
          </div>
        </div>

        ${In.value?o`<div class="council-error">${In.value}</div>`:null}

        <div class="agent-detail-grid">
          <${w} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${$d} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${w} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((d,p)=>o`<div key=${p} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${w} title="Task History">
          ${On.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${On.value.map(d=>o`<${yd} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Fe.value}
              onInput=${d=>{Fe.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&yo()}}
              disabled=${mn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{yo()}}
              disabled=${mn.value||Fe.value.trim()===""}
            >
              ${mn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const ms=600*1e3,fs=1200*1e3,bo=.8;function Lt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Xt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function ko(t){return(t??"").trim().toLowerCase()}function Zt(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Pe(t){return typeof t!="number"||Number.isNaN(t)?3:t}function kd(t){const e=Pe(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function Ce(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Xn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function xo(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function So(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function xd(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function _s(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Sd(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Ad(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function wd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Td(t){return t?t.enabled?t.quiet_active?`Quiet hours ${xo(t.quiet_start)}-${xo(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${So(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${So(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function Ao(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Ne({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Cd({item:t}){return o`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?o`<span><${U} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function gs({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:i}){return o`
    <button class="monitor-row ${t}" onClick=${i}>
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e}</span>
            <span class="monitor-sub">${n}</span>
          </div>
        </div>
        <span class="monitor-pill ${t}">${t==="bad"?"Alert":t==="warn"?"Watch":"Ready"}</span>
      </div>
      <div class="monitor-meta">
        ${a.map(r=>o`<span>${r}</span>`)}
      </div>
      <div class="monitor-focus">${s}</div>
    </button>
  `}function wo(){var C,D,Z,$t,dt,tt,it,I,J,b,Dt,Yt,ue,L,Pt,de,Jn;const t=ke.value,e=Qt.value,n=_t.value,a=Nt.value,s=Kr.value,i=(C=t==null?void 0:t.monitoring)==null?void 0:C.board,r=(D=t==null?void 0:t.monitoring)==null?void 0:D.council,u=Bt.value,d=new Map(e.map(v=>[ko(v.name),v])),p=e.map(v=>{var Wi;const N=En(v.name,n,ye.value,oe.value,{currentTask:v.current_task,lastSeen:v.last_seen,boardPosts:Jt.value,keepers:a}),F=N.lastActivityAt??v.last_seen??null,nt=F?Math.max(0,Date.now()-Lt(F)):Number.POSITIVE_INFINITY,j=N.activeAssignedCount,lt=!!((Wi=v.current_task)!=null&&Wi.trim()),Y=lt||j>0;let V="ok",ct="Fresh and ready",Ae=!1,we=!1;return v.status==="offline"||v.status==="inactive"?(V=Y?"bad":"warn",ct=Y?"Load without an available owner":"Offline"):Y&&nt>fs?(V="bad",ct="Execution is stale"):j>0&&!lt?(V="warn",ct="Claimed work has no current_task",we=!0):lt&&j===0?(V="warn",ct="current_task has no claimed work",we=!0):!Y&&nt<=ms?(V="ok",ct="Dispatchable now",Ae=!0):!Y&&nt>fs?(V="warn",ct="Idle but not freshly active"):Y&&nt>ms&&(V="warn",ct="Execution is getting quiet"),{agent:v,lastSignalAt:F,activeTaskCount:j,tone:V,note:ct,focus:Zt(v.current_task)??N.lastActivityText??(Ae?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:Ae,drift:we}}).sort((v,N)=>{const F=Xt(N.tone)-Xt(v.tone);return F!==0?F:Lt(N.lastSignalAt)-Lt(v.lastSignalAt)}),f=a.map(v=>{var V;const N=Ur.value.get(v.name)??"idle",F=Br.value.has(v.name),nt=v.context_ratio??0,j=v.diagnostic??null;let lt="ok",Y="Healthy keeper";return F||v.status==="offline"||N==="handoff-imminent"||(j==null?void 0:j.health_state)==="offline"||(j==null?void 0:j.health_state)==="degraded"?(lt="bad",Y=Zt(j==null?void 0:j.summary,56)??(F?"Heartbeat stale":N==="handoff-imminent"?"Handoff imminent":(j==null?void 0:j.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((j==null?void 0:j.health_state)==="stale"||nt>=bo||N==="preparing"||N==="compacting")&&(lt="warn",Y=Zt(j==null?void 0:j.summary,56)??(nt>=bo?"High context pressure":`Lifecycle ${N}`)),{keeper:v,tone:lt,note:Y,focus:Zt(j==null?void 0:j.summary,120)??Zt((V=v.agent)==null?void 0:V.current_task)??v.skill_primary??v.last_proactive_reason??v.memory_recent_note??"No active focus",timestamp:v.last_heartbeat??null}}).sort((v,N)=>{const F=Xt(N.tone)-Xt(v.tone);return F!==0?F:Lt(N.timestamp)-Lt(v.timestamp)}),l=n.filter(v=>v.status==="todo"||v.status==="claimed"||v.status==="in_progress").map(v=>{var Ae,we;const N=v.assignee?d.get(ko(v.assignee))??null:null,F=N?En(N.name,n,ye.value,oe.value,{currentTask:N.current_task,lastSeen:N.last_seen,boardPosts:Jt.value,keepers:a}):null,nt=(F==null?void 0:F.lastActivityAt)??(N==null?void 0:N.last_seen)??null,j=nt?Math.max(0,Date.now()-Lt(nt)):Number.POSITIVE_INFINITY,lt=v.status==="claimed"||v.status==="in_progress";let Y="ok",V="Covered",ct=!1;return v.assignee?!N||N.status==="offline"||N.status==="inactive"?(Y="bad",V="Assigned owner is unavailable",ct=!0):lt&&j>fs?(Y="bad",V="Execution has lost a fresh signal"):lt&&j>ms?(Y="warn",V="Execution is drifting quiet"):v.status==="todo"&&Pe(v.priority)<=2&&!((Ae=N.current_task)!=null&&Ae.trim())&&((F==null?void 0:F.activeAssignedCount)??0)===0?(Y="ok",V="Ready for dispatch"):lt&&!((we=N.current_task)!=null&&we.trim())&&(Y="warn",V="Owner focus is not explicit"):(Y=Pe(v.priority)<=2?"bad":"warn",V=lt?"Active work has no owner":"Ready work has no owner",ct=!0),{task:v,owner:N,lastSignalAt:nt,tone:Y,note:V,focus:Zt(N==null?void 0:N.current_task)??(F==null?void 0:F.lastActivityText)??Zt(v.description)??"Needs operator attention.",ownerGap:ct}}).sort((v,N)=>{const F=Xt(N.tone)-Xt(v.tone);if(F!==0)return F;const nt=Pe(v.task.priority)-Pe(N.task.priority);return nt!==0?nt:Lt(N.lastSignalAt??N.task.updated_at??N.task.created_at)-Lt(v.lastSignalAt??v.task.updated_at??v.task.created_at)}),c=l.filter(v=>v.task.status==="todo"&&Pe(v.task.priority)<=2),m=l.filter(v=>v.ownerGap).length,$=p.filter(v=>v.dispatchable),y=p.filter(v=>v.drift||v.tone!=="ok"),k=f.filter(v=>v.tone!=="ok"),R=t!=null&&t.paused?"bad":((Z=t==null?void 0:t.data_quality)==null?void 0:Z.board_contract_ok)===!1||(($t=t==null?void 0:t.data_quality)==null?void 0:$t.council_feed_ok)===!1?"warn":u?"ok":"warn",T=[];t!=null&&t.paused&&T.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((dt=t.data_quality)==null?void 0:dt.last_sync_at)??null,action:()=>Tt("ops")}),u||T.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:()=>Tt("activity")}),Ce(i==null?void 0:i.alert_level)!=="ok"&&T.push({key:"board-monitor",tone:Ce(i==null?void 0:i.alert_level),title:"Board feed needs attention",detail:`Freshness ${_s(i==null?void 0:i.last_activity_age_s)} · ${(i==null?void 0:i.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>Tt("board")}),Ce(r==null?void 0:r.alert_level)!=="ok"&&T.push({key:"council-monitor",tone:Ce(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${_s(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>Tt("council")}),(((tt=t==null?void 0:t.data_quality)==null?void 0:tt.board_contract_ok)===!1||((it=t==null?void 0:t.data_quality)==null?void 0:it.council_feed_ok)===!1)&&T.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((I=t.data_quality)==null?void 0:I.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((J=t.data_quality)==null?void 0:J.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((b=t.data_quality)==null?void 0:b.last_sync_at)??null,action:()=>Tt("ops")});const M=[...T,...l.filter(v=>v.tone!=="ok").slice(0,3).map(v=>({key:`task-${v.task.id}`,tone:v.tone,title:v.task.title,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt??v.task.updated_at??v.task.created_at??null,action:()=>Tt("execution")})),...k.slice(0,2).map(v=>({key:`keeper-${v.keeper.name}`,tone:v.tone,title:v.keeper.name,detail:`${v.note} · ${v.focus}`,timestamp:v.timestamp,action:()=>Aa(v.keeper)})),...y.slice(0,2).map(v=>({key:`agent-${v.agent.name}`,tone:v.tone,title:v.agent.name,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt,action:()=>He(v.agent.name)}))].sort((v,N)=>{const F=Xt(N.tone)-Xt(v.tone);return F!==0?F:Lt(N.timestamp)-Lt(v.timestamp)}).slice(0,8);return o`
    <div class="stats-grid">
      <${Ne}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Xn(R)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${Ne}
        label="Urgent Queue"
        value=${c.length}
        color=${c.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${Ne}
        label="Active Work"
        value=${s.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${Ne}
        label="Dispatchable"
        value=${$.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${Ne}
        label="Keeper Pressure"
        value=${k.length}
        color=${k.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${Ne}
        label="Owner Gaps"
        value=${m}
        color=${m>0?"#fb7185":"#4ade80"}
        caption="tasks missing a live owner"
      />
    </div>

    <${w} title="Room Health" class="section">
      <div class="monitor-section-head">
        <h2 class="monitor-headline">Operational health at a glance</h2>
        <p class="monitor-subheadline">The Overview now prioritizes room state, feed freshness, and immediate intervention signals over full entity dumps.</p>
      </div>
      <div class="overview-health-grid">
        <div class="stat-card">
          <div class="stat-label">Live Feed</div>
          <div class="stat-value" style=${`color:${u?"#4ade80":"#fbbf24"}`}>${u?"Online":"Retrying"}</div>
          <div class="monitor-stat-caption">${Kn.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Xn(Ce(i==null?void 0:i.alert_level))}`}>${Ao(i==null?void 0:i.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${_s(i==null?void 0:i.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Xn(Ce(r==null?void 0:r.alert_level))}`}>${Ao(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Xn(R)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${xd((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(Dt=t==null?void 0:t.data_quality)!=null&&Dt.last_sync_at?o`Last sync <${U} timestamp=${t.data_quality.last_sync_at} />`:o`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${Td(t==null?void 0:t.lodge)}</div>
        ${(Yt=t==null?void 0:t.lodge)!=null&&Yt.last_skip_reason?o`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

    <div class="grid-2col">
      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${M.length===0?o`<div class="empty-state">No immediate intervention required</div>`:M.map(v=>o`<${Cd} key=${v.key} item=${v} />`)}
        </div>
      <//>

      <${w} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${$.length===0?o`<div class="empty-state">No fully dispatchable agents right now</div>`:$.slice(0,5).map(v=>o`
                <${gs}
                  key=${v.agent.name}
                  tone=${v.tone}
                  title=${v.agent.name}
                  subtitle=${v.note}
                  meta=${[v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No recent signal",v.agent.model??"model n/a",v.agent.koreanName??"room agent"]}
                  focus=${v.focus}
                  onClick=${()=>He(v.agent.name)}
                />
              `)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${w} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${l.length===0?o`<div class="empty-state">No active or ready tasks</div>`:l.slice(0,6).map(v=>o`
                <${gs}
                  key=${v.task.id}
                  tone=${v.tone}
                  title=${v.task.title}
                  subtitle=${`${kd(v.task.priority)} · ${v.note}`}
                  meta=${[v.task.assignee?`Owner ${v.task.assignee}`:"Unassigned",v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No live signal",v.task.updated_at?`Touched ${new Date(v.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${v.focus}
                  onClick=${()=>Tt("execution")}
                />
              `)}
        </div>
      <//>

      <${w} title="Keeper Pressure" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Long-running keepers under pressure</h2>
          <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${k.length===0?o`<div class="empty-state">No keeper pressure signals right now</div>`:k.slice(0,5).map(v=>{var N;return o`
                <${gs}
                  key=${v.keeper.name}
                  tone=${v.tone}
                  title=${v.keeper.name}
                  subtitle=${(N=v.keeper.diagnostic)!=null&&N.health_state?`${v.note} · ${v.keeper.diagnostic.health_state}`:v.note}
                  meta=${[v.timestamp?`Heartbeat ${new Date(v.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof v.keeper.context_ratio=="number"?Math.round(v.keeper.context_ratio*100):0}%`,v.keeper.model?`Model ${v.keeper.model}`:"model n/a",v.keeper.diagnostic?`${Ad(v.keeper.diagnostic.quiet_reason)} · next ${wd(v.keeper.diagnostic.next_action_path)} · reply ${v.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${v.focus}
                  onClick=${()=>Aa(v.keeper)}
                />
              `})}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${w} title="Agent Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Agents with drift or aging load</h2>
          <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
        </div>
        <div class="monitor-list">
          ${y.length===0?o`<div class="empty-state">No agent drift or stale load right now</div>`:y.slice(0,5).map(v=>o`
                <button class="monitor-row ${v.tone}" onClick=${()=>He(v.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${v.agent.name}</span>
                        ${v.agent.koreanName?o`<span class="monitor-sub">${v.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${v.note}</div>
                    </div>
                    <${Rt} status=${v.agent.status} />
                    <span class="monitor-pill ${v.tone}">${v.dispatchable?"Ready":v.drift?"Drift":"Watch"}</span>
                  </div>
                  <div class="monitor-meta">
                    ${v.lastSignalAt?o`<span>Signal <${U} timestamp=${v.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
                    <span>${v.activeTaskCount>0?`${v.activeTaskCount} active tasks`:"No active tasks"}</span>
                    ${v.agent.model?o`<span>${v.agent.model}</span>`:null}
                  </div>
                  <div class="monitor-focus">${v.focus}</div>
                </button>
              `)}
        </div>
      <//>

      <${w} title="Runtime Notes" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Secondary runtime context</h2>
          <p class="monitor-subheadline">This stays below the triage queue so operators can scan first and drill later.</p>
        </div>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${Tu.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${rn.value?`Perpetual runtime ${rn.value.running?"running":"stopped"}${rn.value.goal?` · ${Zt(rn.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(ue=t==null?void 0:t.lodge)!=null&&ue.enabled?"enabled":"disabled"} · Last tick ${((L=t==null?void 0:t.lodge)==null?void 0:L.last_tick_ago)??"never"} · Self heartbeats ${((de=(Pt=t==null?void 0:t.lodge)==null?void 0:Pt.active_self_heartbeats)==null?void 0:de.length)??0}${(Jn=t==null?void 0:t.lodge)!=null&&Jn.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${k.length} · Highest context ${Sd(Math.max(...a.map(v=>v.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>
  `}const le=_(null),Ca=_(!1),Na=_(null),ui=_(null),Ra=_(null),Fi=_("operations"),Wn=_(null),di=_(!1),Da=_(null);function z(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function g(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function E(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function To(t){return typeof t=="boolean"?t:void 0}function kt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Nd(t){if(z(t))return{policy_class:g(t.policy_class),approval_class:g(t.approval_class),tool_allowlist:kt(t.tool_allowlist),model_allowlist:kt(t.model_allowlist),requires_human_for:kt(t.requires_human_for),autonomy_level:g(t.autonomy_level),escalation_timeout_sec:E(t.escalation_timeout_sec),kill_switch:To(t.kill_switch),frozen:To(t.frozen)}}function Rd(t){if(z(t))return{headcount_cap:E(t.headcount_cap),active_operation_cap:E(t.active_operation_cap),max_cost_usd:E(t.max_cost_usd),max_tokens:E(t.max_tokens)}}function tl(t){if(!z(t))return null;const e=g(t.unit_id),n=g(t.label),a=g(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:g(t.parent_unit_id)??null,leader_id:g(t.leader_id)??null,roster:kt(t.roster),capability_profile:kt(t.capability_profile),source:g(t.source),created_at:g(t.created_at),updated_at:g(t.updated_at),policy:Nd(t.policy),budget:Rd(t.budget)}}function el(t){if(!z(t))return null;const e=tl(t.unit);return e?{unit:e,leader_status:g(t.leader_status),roster_total:E(t.roster_total),roster_live:E(t.roster_live),active_operation_count:E(t.active_operation_count),health:g(t.health),reasons:kt(t.reasons),children:Array.isArray(t.children)?t.children.map(el).filter(n=>n!==null):[]}:null}function Dd(t){if(z(t))return{total_units:E(t.total_units),company_count:E(t.company_count),platoon_count:E(t.platoon_count),squad_count:E(t.squad_count),leaf_agent_unit_count:E(t.leaf_agent_unit_count),live_agent_count:E(t.live_agent_count),managed_unit_count:E(t.managed_unit_count),active_operation_count:E(t.active_operation_count)}}function Pd(t){const e=z(t)?t:{};return{version:g(e.version),generated_at:g(e.generated_at),source:g(e.source),summary:Dd(e.summary),units:Array.isArray(e.units)?e.units.map(el).filter(n=>n!==null):[]}}function nl(t){if(!z(t))return null;const e=g(t.operation_id),n=g(t.objective),a=g(t.assigned_unit_id),s=g(t.trace_id),i=g(t.status);return!e||!n||!a||!s||!i?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:g(t.autonomy_level),policy_class:g(t.policy_class),budget_class:g(t.budget_class),detachment_session_id:g(t.detachment_session_id)??null,trace_id:s,checkpoint_ref:g(t.checkpoint_ref)??null,active_goal_ids:kt(t.active_goal_ids),note:g(t.note)??null,created_by:g(t.created_by),source:g(t.source),status:i,created_at:g(t.created_at),updated_at:g(t.updated_at)}}function Ld(t){if(!z(t))return null;const e=nl(t.operation);return e?{operation:e,assigned_unit_label:g(t.assigned_unit_label)}:null}function Ed(t){const e=z(t)?t:{},n=z(e.summary)?e.summary:void 0;return{version:g(e.version),generated_at:g(e.generated_at),summary:n?{total:E(n.total),active:E(n.active),paused:E(n.paused),managed:E(n.managed),projected:E(n.projected)}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Ld).filter(a=>a!==null):[]}}function Id(t){if(!z(t))return null;const e=g(t.detachment_id),n=g(t.operation_id),a=g(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:g(t.leader_id)??null,roster:kt(t.roster),session_id:g(t.session_id)??null,checkpoint_ref:g(t.checkpoint_ref)??null,runtime_kind:g(t.runtime_kind)??null,runtime_ref:g(t.runtime_ref)??null,source:g(t.source),status:g(t.status),last_event_at:g(t.last_event_at)??null,last_progress_at:g(t.last_progress_at)??null,heartbeat_deadline:g(t.heartbeat_deadline)??null,created_at:g(t.created_at),updated_at:g(t.updated_at)}}function Od(t){if(!z(t))return null;const e=Id(t.detachment);return e?{detachment:e,assigned_unit_label:g(t.assigned_unit_label),operation:nl(t.operation)}:null}function Md(t){const e=z(t)?t:{},n=z(e.summary)?e.summary:void 0;return{version:g(e.version),generated_at:g(e.generated_at),summary:n?{total:E(n.total),active:E(n.active),projected:E(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Od).filter(a=>a!==null):[]}}function zd(t){if(!z(t))return null;const e=g(t.decision_id),n=g(t.trace_id),a=g(t.requested_action),s=g(t.scope_type),i=g(t.scope_id);return!e||!n||!a||!s||!i?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:s,scope_id:i,operation_id:g(t.operation_id)??null,target_unit_id:g(t.target_unit_id)??null,requested_by:g(t.requested_by),status:g(t.status),reason:g(t.reason)??null,source:g(t.source),detail:t.detail,created_at:g(t.created_at),decided_at:g(t.decided_at)??null,expires_at:g(t.expires_at)??null}}function jd(t){const e=z(t)?t:{},n=z(e.summary)?e.summary:void 0;return{version:g(e.version),generated_at:g(e.generated_at),summary:n?{total:E(n.total),pending:E(n.pending),approved:E(n.approved),denied:E(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(zd).filter(a=>a!==null):[]}}function qd(t){if(!z(t))return null;const e=tl(t.unit);return e?{unit:e,roster_total:E(t.roster_total),roster_live:E(t.roster_live),headcount_cap:E(t.headcount_cap),active_operations:E(t.active_operations),active_operation_cap:E(t.active_operation_cap),utilization:E(t.utilization)}:null}function Fd(t){const e=z(t)?t:{};return{version:g(e.version),generated_at:g(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(qd).filter(n=>n!==null):[]}}function Hd(t){if(!z(t))return null;const e=g(t.alert_id);return e?{alert_id:e,severity:g(t.severity),kind:g(t.kind),scope_type:g(t.scope_type),scope_id:g(t.scope_id),title:g(t.title),detail:g(t.detail),timestamp:g(t.timestamp)}:null}function Kd(t){const e=z(t)?t:{},n=z(e.summary)?e.summary:void 0;return{version:g(e.version),generated_at:g(e.generated_at),summary:n?{total:E(n.total),bad:E(n.bad),warn:E(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Hd).filter(a=>a!==null):[]}}function Ud(t){if(!z(t))return null;const e=g(t.event_id),n=g(t.trace_id),a=g(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:g(t.operation_id)??null,unit_id:g(t.unit_id)??null,actor:g(t.actor)??null,source:g(t.source),timestamp:g(t.timestamp),detail:t.detail}}function Bd(t){const e=z(t)?t:{};return{version:g(e.version),generated_at:g(e.generated_at),events:Array.isArray(e.events)?e.events.map(Ud).filter(n=>n!==null):[]}}function Wd(t){const e=z(t)?t:{};return{version:g(e.version),generated_at:g(e.generated_at),topology:Pd(e.topology),operations:Ed(e.operations),detachments:Md(e.detachments),alerts:Kd(e.alerts),decisions:jd(e.decisions),capacity:Fd(e.capacity),traces:Bd(e.traces)}}function Gd(t){if(!z(t))return null;const e=g(t.title),n=g(t.path);return!e||!n?null:{title:e,path:n}}function Jd(t){if(!z(t))return null;const e=g(t.id),n=g(t.title),a=g(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function Vd(t){if(!z(t))return null;const e=g(t.id),n=g(t.title),a=g(t.tool),s=g(t.summary);return!e||!n||!a||!s?null:{id:e,title:n,tool:a,summary:s,success_signals:kt(t.success_signals),pitfalls:kt(t.pitfalls)}}function Qd(t){if(!z(t))return null;const e=g(t.id),n=g(t.title),a=g(t.summary),s=g(t.when_to_use);return!e||!n||!a||!s?null:{id:e,title:n,summary:a,when_to_use:s,steps:Array.isArray(t.steps)?t.steps.map(Vd).filter(i=>i!==null):[]}}function Yd(t){if(!z(t))return null;const e=g(t.id),n=g(t.title),a=g(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:kt(t.tools)}}function Xd(t){if(!z(t))return null;const e=g(t.id),n=g(t.title),a=g(t.symptom),s=g(t.why),i=g(t.fix_tool),r=g(t.fix_summary);return!e||!n||!a||!s||!i||!r?null:{id:e,title:n,symptom:a,why:s,fix_tool:i,fix_summary:r}}function Zd(t){if(!z(t))return null;const e=g(t.id),n=g(t.title),a=g(t.path_id),s=g(t.transport);return!e||!n||!a||!s?null:{id:e,title:n,path_id:a,transport:s,request:t.request,response:t.response,notes:kt(t.notes)}}function tp(t){const e=z(t)?t:{};return{version:g(e.version),generated_at:g(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Gd).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Jd).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Qd).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Yd).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Xd).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Zd).filter(n=>n!==null):[]}}function ep(t){Fi.value=t}async function Mn(){Ca.value=!0,Na.value=null;try{const t=await gc();le.value=Wd(t)}catch(t){Na.value=t instanceof Error?t.message:"Failed to load command plane snapshot"}finally{Ca.value=!1}}async function np(){di.value=!0,Da.value=null;try{const t=await hc();Wn.value=tp(t)}catch(t){Da.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{di.value=!1}}async function ce(t,e,n){ui.value=t,Ra.value=null;try{await $c(e,n),await Mn()}catch(a){throw Ra.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{ui.value=null}}function ap(t){return ce(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function sp(t){return ce(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function ip(t){return ce(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function op(t={}){return ce("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function rp(t){return ce(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function lp(t){return ce(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function cp(t,e){return ce(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function up(t,e){return ce(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}function dp(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Ge(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function pp(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function vp(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function qt(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function mp(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function at(t){return ui.value===t}function fp(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function _p(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function gp(t){return t.status==="claimed"||t.status==="in_progress"}function hp(t){const e=Wn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(s=>s.tool===t);if(a)return a}return null}function hs(t){var e;return((e=Wn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function $p(t){const e=Wn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function se(t){try{await t()}catch{}}function yp(){var i;const t=le.value,e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.decisions.summary,s=t==null?void 0:t.alerts.summary;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(e==null?void 0:e.total_units)??0}</strong><small>${(e==null?void 0:e.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(n==null?void 0:n.active)??0}</strong><small>${((i=t==null?void 0:t.detachments.summary)==null?void 0:i.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(a==null?void 0:a.pending)??0}</strong><small>${(a==null?void 0:a.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(s==null?void 0:s.bad)??0}</strong><small>${(s==null?void 0:s.warn)??0} warn</small></div>
    </div>
  `}function bp(){return o`
    <div class="command-surface-tabs">
      ${["operations","topology","alerts","trace","control"].map(e=>o`
        <button
          class="command-surface-tab ${Fi.value===e?"active":""}"
          onClick=${()=>ep(e)}
        >
          ${e}
        </button>
      `)}
    </div>
  `}function kp(){var dt,tt,it,I,J,b,Dt,Yt,ue;const t=le.value,e=ke.value,n=fp(),a=n?Qt.value.find(L=>L.name===n)??null:null,s=n?_t.value.filter(L=>L.assignee===n&&gp(L)):[],i=((dt=t==null?void 0:t.operations.summary)==null?void 0:dt.active)??0,r=((tt=t==null?void 0:t.detachments.summary)==null?void 0:tt.total)??0,u=((it=t==null?void 0:t.decisions.summary)==null?void 0:it.pending)??0,d=t==null?void 0:t.detachments.detachments.find(L=>{const Pt=L.detachment.heartbeat_deadline,de=Pt?Date.parse(Pt):Number.NaN;return L.detachment.status==="stalled"||!Number.isNaN(de)&&de<=Date.now()}),p=t==null?void 0:t.alerts.alerts.find(L=>L.severity==="bad"),f=!!(e!=null&&e.room||e!=null&&e.project),l=(a==null?void 0:a.current_task)??null,c=_p(a==null?void 0:a.last_seen),m=c!=null?c<=120:null,$=[f?{title:"Room readiness",tone:"ok",detail:`${(e==null?void 0:e.room)??(e==null?void 0:e.project)??"unknown"} · base ${(e==null?void 0:e.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},n?a?s.length===0?{title:"Task readiness",tone:"warn",detail:`${n} has no claimed task. Claim one or create one first.`,tool:_t.value.length>0?"masc_claim":"masc_add_task"}:l?m===!1?{title:"Task readiness",tone:"warn",detail:`${n} current_task=${l}, but heartbeat is stale (${c}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${n} current_task=${l}${c!=null?` · last seen ${c}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${n} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${n} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((I=t.topology.summary)==null?void 0:I.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:i===0?{title:"Operation readiness",tone:"warn",detail:`${((J=t.topology.summary)==null?void 0:J.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${i} active operation(s) across ${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},u>0?{title:"Dispatch readiness",tone:"warn",detail:`${u} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:i>0&&r===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:d||p?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${d?` · detachment ${d.detachment.detachment_id} is stalled`:""}${p?` · alert ${p.title??p.alert_id}`:""}.`,tool:u>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${r} detachment(s) visible and no strict approval backlog.`,tool:"masc_detachment_list"}],y=f?!n||!a?"masc_join":s.length===0?_t.value.length>0?"masc_claim":"masc_add_task":l?m===!1?"masc_heartbeat":!t||(((Dt=t.topology.summary)==null?void 0:Dt.managed_unit_count)??0)===0?"masc_unit_define":i===0?"masc_operation_start":u>0?"masc_policy_approve":i>0&&r===0||d||p?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",k=hp(y),T=$p(y==="masc_set_room"?["repo-root-room"]:y==="masc_plan_set_task"?["claimed-not-current"]:y==="masc_heartbeat"?["heartbeat-stale"]:y==="masc_dispatch_tick"?["no-detachments"]:y==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),M=hs("room_task_hygiene"),C=hs("cpv2_benchmark"),D=hs("supervisor_session"),Z=((Yt=Wn.value)==null?void 0:Yt.docs)??[],$t=[M,C,D].filter(L=>L!==null);return o`
    <div class="command-guide-grid">
      <section class="card command-section">
        <div class="card-title">Readiness</div>
        <div class="command-guide-readiness">
          ${$.map(L=>o`
            <article class="command-guide-card ${qt(L.tone)}">
              <div class="command-guide-head">
                <strong>${L.title}</strong>
                <span class="command-chip ${qt(L.tone)}">${L.tone}</span>
              </div>
              <p>${L.detail}</p>
              <div class="command-card-foot">Next tool: ${L.tool}</div>
            </article>
          `)}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Next Step</div>
        <article class="command-guide-card highlight">
          <div class="command-guide-head">
            <strong>${(k==null?void 0:k.title)??y}</strong>
            <span class="command-chip ok">${y}</span>
          </div>
          <p>${(k==null?void 0:k.summary)??"Use the next tool in the canonical flow to remove the current blocker."}</p>
          ${(ue=k==null?void 0:k.success_signals)!=null&&ue.length?o`<div class="command-tag-row">
                ${k.success_signals.map(L=>o`<span class="command-tag ok">${L}</span>`)}
              </div>`:null}
          ${T.length>0?o`<div class="command-guide-list">
                ${T.map(L=>o`
                  <article class="command-guide-inline">
                    <strong>${L.title}</strong>
                    <div>${L.symptom}</div>
                    <div class="command-card-sub">Fix with ${L.fix_tool}: ${L.fix_summary}</div>
                  </article>
                `)}
              </div>`:null}
        </article>
      </section>

      <section class="card command-section">
        <div class="card-title">How It Works</div>
        ${di.value?o`<div class="empty-state">Loading CPv2 runbook…</div>`:Da.value?o`<div class="empty-state error">${Da.value}</div>`:o`
                <div class="command-guide-paths">
                  ${$t.map(L=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${L.title}</strong>
                        <span class="command-chip">${L.id}</span>
                      </div>
                      <p>${L.summary}</p>
                      <div class="command-card-sub">${L.when_to_use}</div>
                      <div class="command-step-list">
                        ${L.steps.map(Pt=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Pt.tool}</span>
                            <span>${Pt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${Z.length>0?o`<div class="command-doc-links">
                      ${Z.map(L=>o`<span class="command-tag">${L.title}: ${L.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function al({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,s=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${mp(t.unit.kind)}</span>
            <span class="command-chip ${qt(t.health)}">${t.health??"ok"}</span>
            ${i!=null&&i.frozen?o`<span class="command-chip warn">frozen</span>`:null}
            ${i!=null&&i.kill_switch?o`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>Leader ${t.unit.leader_id??"unassigned"} / ${t.leader_status??"unknown"}</span>
            <span>Roster ${n}/${a}</span>
            <span>Ops ${s}</span>
            <span>Autonomy ${(i==null?void 0:i.autonomy_level)??"n/a"}</span>
          </div>
          ${t.reasons&&t.reasons.length>0?o`<div class="command-tag-row">
                ${t.reasons.map(r=>o`<span class="command-tag warn">${r}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?o`<div class="command-tree-children">
            ${t.children.map(r=>o`<${al} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function xp({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,s=`recall:${e.operation_id}`;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${qt(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${Ge(e.updated_at)}</span>
      </div>
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${at(n)} onClick=${()=>se(()=>ap(e.operation_id))}>
                ${at(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${at(s)} onClick=${()=>se(()=>ip(e.operation_id))}>
                ${at(s)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${at(a)} onClick=${()=>se(()=>sp(e.operation_id))}>
                ${at(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Sp({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${qt(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Ge(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${vp(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Ge(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${pp(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Ap({alert:t}){return o`
    <article class="command-alert ${qt(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${qt(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Ge(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function wp({event:t}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${Ge(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${dp(t.detail)}</pre>
    </article>
  `}function Tp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return o`
    <article class="command-card ${qt(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${qt(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${Ge(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${at(e)} onClick=${()=>se(()=>rp(t.decision_id))}>
                ${at(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${at(n)} onClick=${()=>se(()=>lp(t.decision_id))}>
                ${at(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Cp({row:t}){var u,d,p;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,s=!!((u=e.policy)!=null&&u.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${qt(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((p=e.policy)==null?void 0:p.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${s?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${at(n)} onClick=${()=>se(()=>cp(e.unit_id,!s))}>
          ${at(n)?"Applying…":s?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${at(a)} onClick=${()=>se(()=>up(e.unit_id,!i))}>
          ${at(a)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Np(){const t=le.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${xp} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${Sp} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Rp(){const t=le.value;return o`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${al} node=${e} />`)}`:o`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function Dp(){const t=le.value;return o`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${Ap} alert=${e} />`)}
          </div>`:o`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function Pp(){const t=le.value;return o`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${wp} event=${e} />`)}
          </div>`:o`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function Lp(){const t=le.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${Tp} decision=${e} />`)}
            </div>`:o`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${Cp} row=${e} />`)}
            </div>`:o`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function Ep(){switch(Fi.value){case"topology":return o`<${Rp} />`;case"alerts":return o`<${Dp} />`;case"trace":return o`<${Pp} />`;case"control":return o`<${Lp} />`;case"operations":default:return o`<${Np} />`}}function Ip(){return xt(()=>{Mn(),np()},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{se(()=>op())}}
            disabled=${at("dispatch:tick")}
          >
            ${at("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{Mn()}} disabled=${Ca.value}>
            ${Ca.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${Na.value?o`<div class="empty-state error">${Na.value}</div>`:null}
      ${Ra.value?o`<div class="empty-state error">${Ra.value}</div>`:null}

      <${yp} />
      <${kp} />
      <${bp} />
      <${Ep} />
    </section>
  `}const Gn=_(null),Pa=_(!1),re=_(null),W=_(!1),La=_([]);let Op=1;function G(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function P(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function mt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function sl(t){return typeof t=="boolean"?t:void 0}function Mp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Le(t,e=[]){if(Array.isArray(t))return t;if(!G(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function zp(t){return G(t)?{id:P(t.id),seq:mt(t.seq),from:P(t.from)??P(t.from_agent)??"system",content:P(t.content)??"",timestamp:P(t.timestamp)??new Date().toISOString(),type:P(t.type)}:null}function jp(t){return G(t)?{room_id:P(t.room_id),current_room:P(t.current_room)??P(t.room),project:P(t.project),cluster:P(t.cluster),paused:sl(t.paused),pause_reason:P(t.pause_reason)??null,paused_by:P(t.paused_by)??null,paused_at:P(t.paused_at)??null}:{}}function Co(t){if(!G(t))return;const e=Object.entries(t).map(([n,a])=>{const s=P(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function qp(t){if(!G(t))return null;const e=G(t.status)?t.status:void 0,n=G(t.summary)?t.summary:G(e==null?void 0:e.summary)?e.summary:void 0,a=G(t.session)?t.session:G(e==null?void 0:e.session)?e.session:void 0,s=P(t.session_id)??P(n==null?void 0:n.session_id)??P(a==null?void 0:a.session_id);if(!s)return null;const i=Co(t.report_paths)??Co(e==null?void 0:e.report_paths),r=Le(t.recent_events,["events"]).filter(G);return{session_id:s,status:P(t.status)??P(n==null?void 0:n.status)??P(a==null?void 0:a.status),progress_pct:mt(t.progress_pct)??mt(n==null?void 0:n.progress_pct),elapsed_sec:mt(t.elapsed_sec)??mt(n==null?void 0:n.elapsed_sec),remaining_sec:mt(t.remaining_sec)??mt(n==null?void 0:n.remaining_sec),done_delta_total:mt(t.done_delta_total)??mt(n==null?void 0:n.done_delta_total),summary:n,team_health:G(t.team_health)?t.team_health:G(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:G(t.communication_metrics)?t.communication_metrics:G(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:G(t.orchestration_state)?t.orchestration_state:G(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:G(t.cascade_metrics)?t.cascade_metrics:G(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:a,recent_events:r}}function Fp(t){if(!G(t))return null;const e=P(t.name);if(!e)return null;const n=G(t.context)?t.context:void 0;return{name:e,agent_name:P(t.agent_name),status:P(t.status),autonomy_level:P(t.autonomy_level),context_ratio:mt(t.context_ratio)??mt(n==null?void 0:n.context_ratio),generation:mt(t.generation),active_goal_ids:Mp(t.active_goal_ids),last_autonomous_action_at:P(t.last_autonomous_action_at)??null,last_turn_ago_s:mt(t.last_turn_ago_s),model:P(t.model)??P(t.active_model)??P(t.primary_model)}}function Hp(t){if(!G(t))return null;const e=P(t.confirm_token)??P(t.token);return e?{confirm_token:e,actor:P(t.actor),action_type:P(t.action_type),target_type:P(t.target_type),target_id:P(t.target_id)??null,delegated_tool:P(t.delegated_tool),created_at:P(t.created_at),preview:t.preview}:null}function Kp(t){const e=G(t)?t:{};return{room:jp(e.room),sessions:Le(e.sessions,["items","sessions"]).map(qp).filter(n=>n!==null),keepers:Le(e.keepers,["items","keepers"]).map(Fp).filter(n=>n!==null),recent_messages:Le(e.recent_messages,["messages"]).map(zp).filter(n=>n!==null),pending_confirms:Le(e.pending_confirms,["items","confirms"]).map(Hp).filter(n=>n!==null),available_actions:Le(e.available_actions,["actions"]).filter(G).map(n=>({action_type:P(n.action_type)??"unknown",target_type:P(n.target_type)??"unknown",description:P(n.description),confirm_required:sl(n.confirm_required)}))}}function Zn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function No(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ea(t){La.value=[{...t,id:Op++,at:new Date().toISOString()},...La.value].slice(0,20)}function il(t){return t.confirm_required?Zn(t.preview)||"Confirmation required":Zn(t.result)||Zn(t.executed_action)||Zn(t.delegated_tool_result)||t.status}async function Je(){Pa.value=!0,re.value=null;try{const t=await _c();Gn.value=Kp(t)}catch(t){re.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Pa.value=!1}}async function Up(t){W.value=!0,re.value=null;try{const e=await Bn(t);return Ea({actor:t.actor,action_type:t.action_type,target_label:No(t),outcome:e.confirm_required?"preview":"executed",message:il(e),delegated_tool:e.delegated_tool}),await Je(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw re.value=n,Ea({actor:t.actor,action_type:t.action_type,target_label:No(t),outcome:"error",message:n}),e}finally{W.value=!1}}async function Bp(t,e){W.value=!0,re.value=null;try{const n=await bc(t,e);return Ea({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:il(n),delegated_tool:n.delegated_tool}),await Je(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw re.value=a,Ea({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{W.value=!1}}const ol="masc_dashboard_agent_name";function Wp(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(ol))==null?void 0:a.trim())||"dashboard"}const ns=_(Wp()),fn=_(""),pi=_("Operator pause"),_n=_(""),Ia=_(""),vi=_("2"),Oa=_(""),Ke=_("note"),Ma=_(""),za=_(""),ja=_(""),mi=_("2"),fi=_("Operator stop request"),_i=_(""),gn=_("");function Gp(t){const e=t.trim()||"dashboard";ns.value=e,localStorage.setItem(ol,e)}function Ro(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Jp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function qa(t){return typeof t=="string"?t.trim().toLowerCase():""}function Vp(t){var a;const e=qa(t.status);if(e==="paused")return"bad";const n=qa((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Do(t){const e=qa(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function Se(t){const e=ns.value.trim()||"dashboard";try{const n=await Up({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?S("Confirmation queued","warning"):S(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return S(a,"error"),null}}async function Po(){const t=fn.value.trim();if(!t)return;await Se({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(fn.value="")}async function Qp(){await Se({action_type:"room_pause",target_type:"room",payload:{reason:pi.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function Yp(){await Se({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function Xp(){const t=_n.value.trim();if(!t)return;await Se({action_type:"task_inject",target_type:"room",payload:{title:t,description:Ia.value.trim()||"Injected from Ops tab",priority:Number.parseInt(vi.value,10)||2},successMessage:"Task injection submitted"})&&(_n.value="",Ia.value="")}async function Zp(){var i;const t=Gn.value,e=Oa.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){S("Select a team session first","warning");return}const n={turn_kind:Ke.value},a=Ma.value.trim();a&&(n.message=a),Ke.value==="task"&&(n.task_title=za.value.trim()||"Operator injected task",n.task_description=ja.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(mi.value,10)||2),await Se({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Ma.value="",Ke.value==="task"&&(za.value="",ja.value=""))}async function tv(){var n;const t=Gn.value,e=Oa.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){S("Select a team session first","warning");return}await Se({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:fi.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function ev(){var s;const t=Gn.value,e=_i.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=gn.value.trim();if(!e){S("Select a keeper first","warning");return}if(!n)return;await Se({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(gn.value="")}async function nv(t){const e=ns.value.trim()||"dashboard";try{await Bp(e,t),S("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";S(a,"error")}}function av(){var l;xt(()=>{Je()},[]);const t=Gn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Oa.value)??n[0]??null,u=a.find(c=>c.name===_i.value)??a[0]??null,d=n.filter(c=>Vp(c)!=="ok"),p=a.filter(c=>Do(c)!=="ok"),f=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:s.length,detail:s.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:s.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:d.length,detail:d.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:d.some(c=>qa(c.status)==="paused")?"bad":d.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:p.length,detail:p.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:p.some(c=>Do(c)==="bad")?"bad":p.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <div class="ops-header card">
        <div>
          <div class="card-title">Operator Control</div>
          <h2 class="ops-heading">Guided control for room, sessions, and keepers</h2>
          <p class="ops-subheading">
            Structured actions only. Destructive changes remain behind confirmation tokens.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">Actor</label>
          <input
            id="ops-actor"
            class="control-input ops-actor-input"
            type="text"
            value=${ns.value}
            onInput=${c=>Gp(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Je()}} disabled=${Pa.value||W.value}>
            ${Pa.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${re.value?o`
        <section class="ops-banner error">${re.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
        </div>
        <div class="ops-priority-grid">
          ${f.map(c=>o`
            <div key=${c.key} class="ops-priority-card ${c.tone}">
              <span class="ops-priority-label">${c.label}</span>
              <strong>${c.value}</strong>
              <div class="ops-priority-detail">${c.detail}</div>
            </div>
          `)}
        </div>
      </section>

      ${s.length>0?o`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${s.map(c=>o`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${c.action_type??"unknown"}</strong>
                  <span>${c.target_type??"target"}${c.target_id?`:${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${c.preview?o`<pre class="ops-code-block">${Ro(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{nv(c.confirm_token)}} disabled=${W.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${c.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        </section>
      `:null}

      <div class="ops-grid">
        <section class="card ops-panel">
          <div class="card-title">Room Control</div>
          <div class="ops-stat-grid">
            <div class="ops-stat">
              <span>Room</span>
              <strong>${e.current_room??e.room_id??"default"}</strong>
            </div>
            <div class="ops-stat">
              <span>Project</span>
              <strong>${e.project??"n/a"}</strong>
            </div>
            <div class="ops-stat">
              <span>Cluster</span>
              <strong>${e.cluster??"n/a"}</strong>
            </div>
            <div class="ops-stat ${e.paused?"warn":"ok"}">
              <span>Status</span>
              <strong>${e.paused?"Paused":"Running"}</strong>
            </div>
          </div>

          <label class="control-label" for="ops-broadcast">Broadcast</label>
          <div class="control-row">
            <input
              id="ops-broadcast"
              class="control-input"
              type="text"
              placeholder="@agent or room-wide operator update"
              value=${fn.value}
              onInput=${c=>{fn.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&Po()}}
              disabled=${W.value}
            />
            <button class="control-btn" onClick=${()=>{Po()}} disabled=${W.value||fn.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${pi.value}
              onInput=${c=>{pi.value=c.target.value}}
              disabled=${W.value}
            />
            <button class="control-btn ghost" onClick=${()=>{Qp()}} disabled=${W.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{Yp()}} disabled=${W.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${_n.value}
            onInput=${c=>{_n.value=c.target.value}}
            disabled=${W.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${Ia.value}
            onInput=${c=>{Ia.value=c.target.value}}
            disabled=${W.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${vi.value}
              onChange=${c=>{vi.value=c.target.value}}
              disabled=${W.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{Xp()}} disabled=${W.value||_n.value.trim()===""}>
              Inject
            </button>
          </div>

          ${i.length>0?o`
            <div class="ops-section-head">Context Tail</div>
            <div class="ops-context-note">Recent room chatter stays available for context, but command work remains the primary focus of this tab.</div>
            <div class="ops-feed-list">
              ${i.slice(0,6).map(c=>o`
                <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${c.from}</strong>
                    <span>${c.timestamp}</span>
                  </div>
                  <div class="ops-feed-content">${c.content}</div>
                </article>
              `)}
            </div>
          `:null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
          <div class="ops-entity-list">
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var m;return o`
              <button
                key=${c.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===c.session_id?"active":""}"
                onClick=${()=>{Oa.value=c.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.session_id}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(c.progress_pct??0)}%</span>
                  <span>${c.done_delta_total??0} done</span>
                  <span>${(m=c.team_health)!=null&&m.status?String(c.team_health.status):"health n/a"}</span>
                </div>
              </button>
            `})}
          </div>

          ${r?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${r.session_id}</div>
              <div class="ops-detail-meta">
                <span>Status: ${r.status??"unknown"}</span>
                <span>Elapsed: ${r.elapsed_sec??0}s</span>
                <span>Remaining: ${r.remaining_sec??0}s</span>
              </div>
              ${r.recent_events&&r.recent_events.length>0?o`
                <pre class="ops-code-block compact">${Ro(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Ke.value}
              onChange=${c=>{Ke.value=c.target.value}}
              disabled=${W.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{Zp()}} disabled=${W.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${Ma.value}
            onInput=${c=>{Ma.value=c.target.value}}
            disabled=${W.value||!r}
          ></textarea>
          ${Ke.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${za.value}
              onInput=${c=>{za.value=c.target.value}}
              disabled=${W.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${ja.value}
              onInput=${c=>{ja.value=c.target.value}}
              disabled=${W.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${mi.value}
              onChange=${c=>{mi.value=c.target.value}}
              disabled=${W.value||!r}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
          `:null}

          <div class="ops-section-head">Stop Session</div>
          <div class="control-row ops-split-row">
            <input
              class="control-input"
              type="text"
              value=${fi.value}
              onInput=${c=>{fi.value=c.target.value}}
              disabled=${W.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{tv()}} disabled=${W.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${a.length===0?o`<div class="ops-empty">No keepers available.</div>`:a.map(c=>o`
              <button
                key=${c.name}
                class="ops-entity-card ${(u==null?void 0:u.name)===c.name?"active":""}"
                onClick=${()=>{_i.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${Jp(c.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${u?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${u.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${u.autonomy_level??"n/a"}</span>
                <span>Generation: ${u.generation??0}</span>
                <span>Goals: ${((l=u.active_goal_ids)==null?void 0:l.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${gn.value}
            onInput=${c=>{gn.value=c.target.value}}
            disabled=${W.value||!u}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{ev()}} disabled=${W.value||!u||gn.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${La.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:La.value.map(c=>o`
            <article key=${c.id} class="ops-log-entry ${c.outcome}">
              <div class="ops-log-head">
                <strong>${c.action_type}</strong>
                <span>${c.target_label}</span>
                <span>${c.at}</span>
              </div>
              <div class="ops-log-body">${c.message}</div>
            </article>
          `)}
        </div>
      </section>
    </section>
  `}const gi=_([]),hi=_([]),hn=_(""),Fa=_(!1),$n=_(!1),zn=_(""),Ha=_(null),wt=_(null),$i=_(!1),_e=_(null),va=_(null);async function Ve(){Fa.value=!0,zn.value="";try{const[t,e]=await Promise.all([su(),iu()]);gi.value=t,hi.value=e,_e.value=!0,va.value=Date.now()}catch(t){zn.value=t instanceof Error?t.message:"Failed to load council data",_e.value=!1}finally{Fa.value=!1}}Ku(Ve);async function Lo(){const t=hn.value.trim();if(t){$n.value=!0;try{const e=await ou(t);hn.value="",S(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ve()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";S(n,"error")}finally{$n.value=!1}}}async function sv(t){Ha.value=t,$i.value=!0,wt.value=null;try{wt.value=await ru(t)}catch(e){zn.value=e instanceof Error?e.message:"Failed to load debate status",wt.value=null}finally{$i.value=!1}}function iv({debate:t}){const e=Ha.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>sv(t.id)}
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
  `}function ov({session:t}){return o`
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
  `}function rv(){return _e.value===null||_e.value&&!va.value?null:o`
    <div class="feed-health-banner ${_e.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${_e.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${va.value?o`<span class="feed-health-meta">Last sync: <${U} timestamp=${va.value} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function lv(){xt(()=>{Ve()},[]);const t=_e.value===!1;return o`
    <div>
      <${rv} />
      <${w} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${hn.value}
            onInput=${e=>{hn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&Lo()}}
            disabled=${$n.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Lo}
            disabled=${$n.value||hn.value.trim()===""}
          >
            ${$n.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ve} disabled=${Fa.value}>
            ${Fa.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${zn.value?o`<div class="council-error">${zn.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${w} title="Debates" class="section">
          <div class="council-list">
            ${gi.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:gi.value.map(e=>o`<${iv} key=${e.id} debate=${e} />`)}
          </div>
        <//>

        <${w} title="Voting Sessions" class="section">
          <div class="council-list">
            ${hi.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:hi.value.map(e=>o`<${ov} key=${e.id} session=${e} />`)}
          </div>
        <//>
      </div>

      <${w} title=${Ha.value?`Debate Detail (${Ha.value})`:"Debate Detail"} class="section">
        ${$i.value?o`<div class="loading-indicator">Loading debate detail...</div>`:wt.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${wt.value.status}</span>
                  <span>Total arguments: ${wt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${wt.value.support_count}</span>
                  <span>Oppose: ${wt.value.oppose_count}</span>
                  <span>Neutral: ${wt.value.neutral_count}</span>
                </div>
                ${wt.value.summary_text?o`<pre class="council-detail">${wt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function cv({text:t}){if(!t)return null;const e=uv(t);return o`<div class="markdown-content">${e}</div>`}function uv(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${u?`language-${u}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&r.push(u),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const p=e[a].replace("</think>","").trim();p&&r.push(p),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${$s(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${$s(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${$s(i.join(`
`))}</p>`)}return n}function $s(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const rl=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ma=_(null),yn=_([]),he=_(!1),ge=_(null),bn=_("");function dv(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const pv=_(dv()),kn=_(!1);async function Hi(t){ge.value=t,ma.value=null,yn.value=[],he.value=!0;try{const e=await Cc(t);if(ge.value!==t)return;ma.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},yn.value=e.comments??[]}catch{ge.value===t&&(ma.value=null,yn.value=[])}finally{ge.value===t&&(he.value=!1)}}async function Eo(t){const e=bn.value.trim();if(e){kn.value=!0;try{await Nc(t,pv.value,e),bn.value="",S("Comment posted","success"),await Hi(t),jt()}catch{S("Failed to post comment","error")}finally{kn.value=!1}}}function vv(){const t=Dn.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${rl.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Dn.value=e.id,jt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${me.value?"is-active":""}"
          onClick=${()=>{me.value=!me.value,jt()}}
        >
          ${me.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${jt} disabled=${Ln.value}>
          ${Ln.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function ys(){var e;const t=(e=ke.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${U} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function ll({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function mv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Io(t){return t.updated_at!==t.created_at}function bs(){var n;const t=((n=rl.find(a=>a.id===Dn.value))==null?void 0:n.label)??Dn.value,e=Jt.value.length;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${e}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${me.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${ci.value?o`<${U} timestamp=${ci.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function fv({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Lr(t.id,n),jt()}catch{S("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Vl(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-head">
          <div class="post-title-row">
            <div class="post-title">${t.title}</div>
            <div class="post-chip-row">
              <${ll} flair=${t.flair} />
              ${Io(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${U} timestamp=${t.created_at} /></span>
            ${Io(t)?o`<span>Updated <${U} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${mv(t.content)}</div>
      </div>
    </div>
  `}function _v({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${U} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function gv({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${bn.value}
        onInput=${e=>{bn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Eo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${kn.value}
      />
      <button
        onClick=${()=>Eo(t)}
        disabled=${kn.value||bn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${kn.value?"...":"Post"}
      </button>
    </div>
  `}function hv({post:t}){ge.value!==t.id&&!he.value&&Hi(t.id);const e=async n=>{try{await Lr(t.id,n),jt()}catch{S("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Tt("board")}>← Back to Board</button>
      <${w} title=${o`${t.title} <${ll} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${cv} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${U} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${w} title="Comments (${he.value?"...":yn.value.length})">
        ${he.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${_v} comments=${yn.value} />`}
        <${gv} postId=${t.id} />
      <//>
    </div>
  `}function $v(){var s,i;const t=Jt.value,e=Ln.value,n=zt.value.postId,a=((i=(s=ke.value)==null?void 0:s.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(u=>u.id===n)??(ge.value===n?ma.value:null);return!r&&ge.value!==n&&!he.value&&Hi(n),r?o`
          <${ys} />
          <${bs} />
          <${hv} post=${r} />
        `:o`
          <div>
            <${ys} />
            <${bs} />
            <button class="back-btn" onClick=${()=>Tt("board")}>← Back to Board</button>
            ${he.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${a?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${ys} />
    <${bs} />
    <${vv} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${a?"No posts loaded (board feed degraded). Check board contract sync.":me.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${fv} key=${r.id} post=${r} />`)}
          </div>`}
  `}function yv(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function bv(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function kv(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const cl=120,xv=12,Sv=16,Av=12,yi=_("all"),wv={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Tv={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Cv(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Nv(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:yv(t),actor:bv(t),content:kv(t),timestamp:new Date(t.timestamp).toISOString()}}function Rv(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Dv(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function ta(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function bi(t){return t.last_heartbeat??ta(t.last_turn_ago_s)??ta(t.last_proactive_ago_s)??ta(t.last_handoff_ago_s)??ta(t.last_compaction_ago_s)}function Pv(t,e){const n=bi(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Et(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const ki=gt(()=>{const t=ye.value.map(Cv),e=oe.value.map(Nv),n=[..._t.value].sort((i,r)=>Et(r.updated_at??r.created_at??0)-Et(i.updated_at??i.created_at??0)).slice(0,xv).map(Rv).filter(i=>i!==null),a=[...Jt.value].sort((i,r)=>Et(r.updated_at||r.created_at)-Et(i.updated_at||i.created_at)).slice(0,Sv).map(Dv),s=[...Nt.value].sort((i,r)=>Et(bi(r)??0)-Et(bi(i)??0)).slice(0,Av).map(Pv).filter(i=>i!==null);return[...t,...e,...n,...a,...s].sort((i,r)=>Et(r.timestamp)-Et(i.timestamp))}),Lv=gt(()=>{const t=ki.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Ev=gt(()=>{const t=yi.value;return(t==="all"?ki.value:ki.value.filter(n=>n.kind===t)).slice(0,cl)}),Iv=gt(()=>Qt.value.map(t=>({agent:t,motion:En(t.name,_t.value,ye.value,oe.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Jt.value,keepers:Nt.value})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:Et(e.motion.lastActivityAt??0)-Et(t.motion.lastActivityAt??0)}));function Ov(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function an({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Mv({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Ov(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Tv[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function zv(){const t=Lv.value,e=Ev.value,n=e[0],a=Iv.value;return o`
    <div class="stats-grid">
      <${an} label="Visible rows" value=${e.length} />
      <${an} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${an} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${an} label="Board signals" value=${t.board} color="#fbbf24" />
      <${an} label="SSE events" value=${Kn.value} color="#c084fc" />
    </div>

    <${w} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>o`
            <button
              class="goal-filter-btn ${yi.value===s?"active":""}"
              onClick=${()=>{yi.value=s}}
            >
              ${wv[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Bt.value?"":"pill-stale"}">
            ${Bt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${U} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${cl} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(s=>o`<${Mv} key=${s.id} row=${s} />`)}
      </div>
    <//>

    <${w} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(({agent:s,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${s.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${U} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function ul({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let u="mitosis-safe";return t>=.8?u="mitosis-critical":t>=.5&&(u="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${s}" cy="${s}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${u}" 
          cx="${s}" cy="${s}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${u}">${Math.round(t*100)}%</span>
    </div>
  `}const ks=600*1e3,jv=1200*1e3,Oo=.8;function ee(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Re(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function qv(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Fv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Hv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Kv(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Uv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Bv(t){var d,p;const e=En(t.name,_t.value,ye.value,oe.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Jt.value,keepers:Nt.value}),n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-ee(n)):Number.POSITIVE_INFINITY,s=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",u="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",u=n?"Offline or inactive":"No recent presence"):a>jv?(i="quiet",r="bad",u=s?"Working without a fresh signal":"No fresh agent signal"):s?(i="working",r=a>ks?"warn":"ok",u=a>ks?"Execution looks quiet for too long":"Task and live signal aligned"):a>ks?(i="quiet",r="warn",u="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",u="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((p=t.current_task)==null?void 0:p.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:u}}function Wv(t){const e=Ur.value.get(t.name)??"idle",n=Br.value.has(t.name),a=t.context_ratio??0;let s="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=Oo)&&(s="warning",i="warn",r=a>=Oo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:i,focus:Kv(t),note:r}}function sn({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Gv({item:t}){const e=t.kind==="agent"?()=>He(t.agent.name):()=>Aa(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${U} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function Jv({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>He(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ul} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Rt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${qv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${U} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${U} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Vv({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>Aa(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ul} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Rt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Fv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${U} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${Uv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Hv(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Qv(){const t=[...Qt.value].map(Bv).sort((d,p)=>{const f=Re(p.tone)-Re(d.tone);if(f!==0)return f;const l=p.activeTaskCount-d.activeTaskCount;return l!==0?l:ee(p.lastSignalAt)-ee(d.lastSignalAt)}),e=[...Nt.value].map(Wv).sort((d,p)=>{const f=Re(p.tone)-Re(d.tone);if(f!==0)return f;const l=(p.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return l!==0?l:ee(p.keeper.last_heartbeat)-ee(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline").length,a=t.filter(d=>d.state==="working").length,s=t.filter(d=>d.lastSignalAt&&Date.now()-ee(d.lastSignalAt)<=12e4).length,i=t.filter(d=>d.tone!=="ok"),r=e.filter(d=>d.tone!=="ok"),u=[...r.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...i.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,p)=>{const f=Re(p.tone)-Re(d.tone);return f!==0?f:ee(p.timestamp)-ee(d.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${sn} label="Agents online" value=${n} color="#4ade80" caption="active + idle" />
        <${sn} label="Working now" value=${a} color="#fbbf24" caption="task or claimed load" />
        <${sn} label="Fresh signals" value=${s} color="#22d3ee" caption="within last 2 minutes" />
        <${sn} label="Agent alerts" value=${i.length} color=${i.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${sn} label="Keeper alerts" value=${r.length} color=${r.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${w} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:u.map(d=>o`<${Gv} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(d=>o`<${Vv} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${w} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?o`<div class="empty-state">No agents registered</div>`:t.map(d=>o`<${Jv} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}function xs({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${U} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Yv(){const{todo:t,inProgress:e,done:n}=Kr.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${xs} key=${a.id} task=${a} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${xs} key=${a.id} task=${a} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${xs} key=${a.id} task=${a} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}const Ka=600*1e3,fa=1200*1e3;function as(t){return(t??"").trim().toLowerCase()}function It(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function $e(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function te(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function jn(t){return typeof t!="number"||Number.isNaN(t)?3:t}function dl(t){const e=jn(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function pl(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function vl(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function Xv(t){return t.updated_at??t.created_at??null}function Zv(t){const e=new Map;for(const n of t)e.set(as(n.name),En(n.name,_t.value,ye.value,oe.value,{currentTask:n.current_task,lastSeen:n.last_seen,boardPosts:Jt.value,keepers:Nt.value}));return e}function Mo(t,e,n){var k,R;const a=as(t.assignee),s=a?e.get(a)??null:null,i=s?n.get(a)??null:null,r=(i==null?void 0:i.lastActivityAt)??(s==null?void 0:s.last_seen)??null,u=r?Math.max(0,Date.now()-It(r)):Number.POSITIVE_INFINITY,d=$e(t.description),p=$e(s==null?void 0:s.current_task)??(i==null?void 0:i.lastActivityText)??null,f=t.status==="claimed"||t.status==="in_progress";let l="ok",c="Fresh owner coverage",m=p??d??t.id,$=!1,y=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?($=!0,l="bad",c="Assigned owner is offline",m="Queue item is blocked until ownership changes."):u>Ka?(l="warn",c="Owner exists but live signal is quiet",m=p??"Owner may need a nudge before pickup."):((i==null?void 0:i.activeAssignedCount)??0)>0||(k=s.current_task)!=null&&k.trim()?(l="warn",c="Owner is already carrying active work",m=p??`${(i==null?void 0:i.activeAssignedCount)??0} active tasks already assigned.`):(c="Ready and covered by a fresh operator",m=p??d??"This can be picked up immediately."):($=!0,l="bad",c="Assigned owner is not present in the room",m="Reassign or bring the owner back online."):($=!0,l=jn(t.priority)<=2?"bad":"warn",c=jn(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",m="Assign an agent before this queue item slips."):f&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?($=!0,l="bad",c="Assigned owner is offline",m=p??"Execution has no live operator right now."):u>fa?(y=!0,l="bad",c="Assigned owner has gone quiet",m=p??"Fresh operator signal is missing."):u>Ka?(y=!0,l="warn",c="Execution has been quiet for too long",m=p??"Check whether this work is blocked."):(R=s.current_task)!=null&&R.trim()?(c="Execution has fresh owner coverage",m=p??d??t.id):(l="warn",c=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",m=p??"Task state and agent focus are drifting apart."):($=!0,l="bad",c="Assigned owner is not active in the room",m="Execution is orphaned until ownership is restored."):($=!0,l="bad",c="Active work has no assignee",m="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:i,tone:l,note:c,focus:m,lastSignalAt:r,lastTouchedAt:Xv(t),ownerGap:$,quiet:y}}function tm(t,e){var c;const n=e.get(as(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-It(a)):Number.POSITIVE_INFINITY,i=!!((c=t.current_task)!=null&&c.trim()),r=n.activeAssignedCount,u=i||r>0;let d="loaded",p="ok",f="Healthy active load",l=$e(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(d="offline",p="bad",f="Agent is unavailable"):u&&s>fa?(d="quiet",p="bad",f="Working without a fresh signal"):r>0&&!i?(d="drift",p="warn",f="Claimed work exists but current_task is empty",l=`${r} active tasks need explicit focus.`):i&&r===0?(d="drift",p="warn",f="current_task has no matching claimed work",l=$e(t.current_task)??"Task metadata and operator state drifted."):!u&&s<=Ka?(d="dispatchable",p="ok",f="Fresh signal and no active load",l=n.lastActivityText??"Ready for assignment."):u?s>Ka&&(d="loaded",p="warn",f="Execution load is healthy but slightly quiet",l=$e(t.current_task)??`${r} active tasks in flight.`):(d="quiet",p=s>fa?"bad":"warn",f=s>fa?"No fresh signal while idle":"Reachable, but not freshly active",l=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:p,state:d,note:f,focus:l,lastSignalAt:a,activeTaskCount:r}}function on({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function em({item:t}){return o`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?dl(t.taskRow.task.priority):vl(t.agentRow.state)}
        </span>
        ${t.kind==="task"?o`<span>${pl(t.taskRow.task.status)}</span>`:o`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?o`<span><${U} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </div>
  `}function zo({row:t}){var e;return o`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${dl(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?o`<${Rt} status=${t.assigneeAgent.status} />`:o`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${pl(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?o`<span>Owner ${t.task.assignee}</span>`:o`<span>Unassigned</span>`}
        ${t.lastTouchedAt?o`<span>Touched <${U} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?o`<span>Signal <${U} timestamp=${t.lastSignalAt} /></span>`:o`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&$e(t.assigneeAgent.current_task)!==t.focus?o`<div class="monitor-footnote">Owner focus: ${$e(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function nm({row:t}){const{agent:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>He(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Rt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${vl(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${U} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function am(){const t=Qt.value,e=_t.value,n=new Map(t.map(l=>[as(l.name),l])),a=Zv(t),s=e.filter(l=>l.status==="claimed"||l.status==="in_progress").map(l=>Mo(l,n,a)).sort((l,c)=>{const m=te(c.tone)-te(l.tone);return m!==0?m:It(c.lastSignalAt??c.lastTouchedAt)-It(l.lastSignalAt??l.lastTouchedAt)}),i=e.filter(l=>l.status==="todo").map(l=>Mo(l,n,a)).sort((l,c)=>{const m=te(c.tone)-te(l.tone);if(m!==0)return m;const $=jn(l.task.priority)-jn(c.task.priority);return $!==0?$:It(l.lastTouchedAt)-It(c.lastTouchedAt)}),r=t.map(l=>tm(l,a)).filter(l=>l.state==="dispatchable"||l.state==="drift"||l.state==="quiet").sort((l,c)=>{if(l.state==="dispatchable"&&c.state!=="dispatchable")return-1;if(c.state==="dispatchable"&&l.state!=="dispatchable")return 1;const m=te(c.tone)-te(l.tone);return m!==0?m:It(c.lastSignalAt)-It(l.lastSignalAt)}),u=[...s.filter(l=>l.tone!=="ok").map(l=>({kind:"task",key:`active-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt??l.lastTouchedAt,taskRow:l})),...i.filter(l=>l.tone==="bad").map(l=>({kind:"task",key:`ready-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastTouchedAt,taskRow:l})),...r.filter(l=>l.state==="drift"||l.tone==="bad").map(l=>({kind:"agent",key:`agent-${l.agent.name}`,tone:l.tone,title:l.agent.name,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt,agentRow:l}))].sort((l,c)=>{const m=te(c.tone)-te(l.tone);return m!==0?m:It(c.timestamp)-It(l.timestamp)}).slice(0,8),d=r.filter(l=>l.state==="dispatchable"),p=[...s,...i].filter(l=>l.ownerGap),f=s.filter(l=>l.quiet);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${on} label="Active work" value=${s.length} color="#fbbf24" caption="claimed + in progress" />
        <${on} label="Needs intervention" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${on} label="Ownership gaps" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${on} label="Dispatchable agents" value=${d.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${on} label="Quiet execution" value=${f.length} color=${f.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No active execution risks right now</div>`:u.map(l=>o`<${em} key=${l.key} item=${l} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${i.length===0?o`<div class="empty-state">No ready tasks in the queue</div>`:i.slice(0,10).map(l=>o`<${zo} key=${l.task.id} row=${l} />`)}
          </div>
        <//>

        <${w} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?o`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(l=>o`<${nm} key=${l.agent.name} row=${l} />`)}
          </div>
        <//>
      </div>

      <${w} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?o`<div class="empty-state">No active execution tasks</div>`:s.map(l=>o`<${zo} key=${l.task.id} row=${l} />`)}
        </div>
      <//>
    </div>
  `}const Ua=_("all"),Ba=_("all"),xi=gt(()=>{let t=Pn.value;return Ua.value!=="all"&&(t=t.filter(e=>e.horizon===Ua.value)),Ba.value!=="all"&&(t=t.filter(e=>e.status===Ba.value)),t}),sm=gt(()=>{const t={short:[],mid:[],long:[]};for(const e of xi.value){const n=t[e.horizon];n&&n.push(e)}return t}),im=gt(()=>{const t=Array.from(qr.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function om(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Ki(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function _a(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function rm(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function jo(t){return t.toFixed(4)}function qo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function lm({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${_a(t.horizon)}">
            ${Ki(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${om(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${U} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Rt} status=${t.status} />
        <div class="goal-updated">
          <${U} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Fo({label:t,timestamp:e,source:n,note:a}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?o`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${U} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Ss({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${w} title="${Ki(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>o`<${lm} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function cm(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ua.value===t?"active":""}"
            onClick=${()=>{Ua.value=t}}
          >
            ${t==="all"?"All":Ki(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Ba.value===t?"active":""}"
            onClick=${()=>{Ba.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function um(){const t=Pn.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${_a("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${_a("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${_a("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function dm({loop:t}){const e=t.history[0];return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Rt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${jo(t.baseline_metric)}</span>
          <span>Current ${jo(t.current_metric)}</span>
          <span class=${qo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${qo(t)}
          </span>
          <span>Elapsed ${rm(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function pm(){xt(()=>{pn(),qe()},[]);const t=sm.value,e=im.value,n=e.filter(r=>r.status==="running").length,a=Pn.value.filter(r=>r.status==="active").length,s=ii.value,i=s==="idle"?"No loop running":s==="error"?oi.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${xi.value.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Running loops</div>
          <div class="stat-value" style="color:#fbbf24">${n}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Known loops</div>
          <div class="stat-value">${e.length}</div>
        </div>
      </div>

      <${w} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${pn} disabled=${Oe.value}>
              ${Oe.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${qe} disabled=${Me.value}>
              ${Me.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{pn(),qe()}}
              disabled=${Oe.value||Me.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Fo} label="Goals" timestamp=${Fr.value} source="masc_goal_list" />
          <${Fo}
            label="MDAL loops"
            timestamp=${Hr.value}
            source="/api/v1/mdal/loops"
            note=${i}
          />
        </div>
      <//>

      <${w} title="Goal Pipeline" class="section">
        <${um} />
        <${cm} />
      <//>

      ${Oe.value&&Pn.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:xi.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${Ss} horizon="short" items=${t.short??[]} />
              <${Ss} horizon="mid" items=${t.mid??[]} />
              <${Ss} horizon="long" items=${t.long??[]} />
            `}

      <${w} title="MDAL Loops" class="section">
        ${Me.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&s==="error"?o`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&s==="idle"?o`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?o`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:o`
                <div class="planning-loop-list">
                  ${e.map(r=>o`<${dm} key=${r.loop_id} loop=${r} />`)}
                </div>
              `}
      <//>
    </div>
  `}const Ee=_(""),As=_("ability_check"),ws=_("10"),Ts=_("12"),ea=_(""),na=_("idle"),ne=_(""),aa=_("keeper-late"),Cs=_("player"),Ns=_(""),bt=_("idle"),Rs=_(null),sa=_(""),Ds=_(""),Ps=_("player"),Ls=_(""),Es=_(""),Is=_(""),xn=_("20"),Os=_("20"),Ms=_(""),ia=_("idle"),Si=_(null),ml=_("overview"),zs=_("all"),js=_("all"),qs=_("all"),vm=12e4,ss=_(null),Ho=_(Date.now());function mm(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function fm(t,e){return e>0?Math.round(t/e*100):0}const _m={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},gm={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function oa(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function hm(t){const e=t.trim().toLowerCase();return _m[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function $m(t){const e=t.trim().toLowerCase();return gm[e]??"상황에 따라 선택되는 전술 액션입니다."}function ie(t){return typeof t=="object"&&t!==null}function vt(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Ot(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function qn(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const ym=new Set(["str","dex","con","int","wis","cha"]);function bm(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!ie(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const u=Number.parseFloat(i.trim());if(Number.isFinite(u)){a[r]=Math.max(0,Math.trunc(u));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function km(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(xn.value.trim(),10);Number.isFinite(a)&&a>n&&(xn.value=String(n))}function Ai(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function xm(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Sm(t){ml.value=t}function fl(t){const e=ss.value;return e==null||e<=t}function Am(t){const e=ss.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Wa(){ss.value=null}function _l(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function wm(t,e){_l(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ss.value=Date.now()+vm,S("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function ga(t){return fl(t)?(S("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function wi(t,e,n){return _l([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Tm({hp:t,max:e}){const n=fm(t,e),a=mm(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Cm({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Nm({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function gl({actor:t}){var d,p,f,l;const e=(d=t.archetype)==null?void 0:d.trim(),n=(p=t.persona)==null?void 0:p.trim(),a=(f=t.portrait)==null?void 0:f.trim(),s=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],u=Object.entries(t.stats_raw??{}).filter(([c,m])=>Number.isFinite(m)).filter(([c])=>!ym.has(c.toLowerCase()));return o`
    <div class="trpg-actor">
      ${a?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${c=>{const m=c.target;m&&(m.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${Rt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Nm} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Tm} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Cm} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${oa(e)}</div>`:null}
      ${s?o`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${u.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${u.map(([c,m])=>o`
                <span class="trpg-custom-stat-chip">${oa(c)} ${m}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(c=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${oa(c)}</span>
                  <span class="trpg-annot-desc">${hm(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(c=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${oa(c)}</span>
                  <span class="trpg-annot-desc">${$m(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Rm({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function hl({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${xm(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ai(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${U} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Dm({events:t}){const e="__none__",n=zs.value,a=js.value,s=qs.value,i=Array.from(new Set(t.map(Ai).map(l=>l.trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),u=t.some(l=>(l.type??"").trim()===""),d=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),p=t.some(l=>(l.phase??"").trim()===""),f=t.filter(l=>{if(n!=="all"&&Ai(l)!==n)return!1;const c=(l.type??"").trim(),m=(l.phase??"").trim();if(a===e){if(c!=="")return!1}else if(a!=="all"&&c!==a)return!1;if(s===e){if(m!=="")return!1}else if(s!=="all"&&m!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{zs.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${l=>{js.value=l.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${l=>{qs.value=l.target.value}}>
          <option value="all">all</option>
          ${p?o`<option value=${e}>(none)</option>`:null}
          ${d.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{zs.value="all",js.value="all",qs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${f.length} / 전체 ${t.length}
      </span>
    </div>
    <${hl} events=${f.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Pm({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function $l({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Lm({state:t,nowMs:e}){var p;const n=Kt.value||((p=t.session)==null?void 0:p.room)||"",a=na.value,s=t.party??[];if(!s.find(f=>f.id===Ee.value)&&s.length>0){const f=s[0];f&&(Ee.value=f.id)}const r=async()=>{var l,c;if(!n){S("Room ID가 비어 있습니다.","error");return}if(!ga(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(wi("라운드 실행",n,f)){na.value="running";try{const m=await Bc(n);Si.value=m,na.value="ok";const $=ie(m.summary)?m.summary:null,y=$?qn($,"advanced",!1):!1,k=$?vt($,"progress_reason",""):"";S(y?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${k?`: ${k}`:""}`,y?"success":"warning"),Ut()}catch(m){Si.value=null,na.value="error";const $=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";S($,"error")}finally{Wa()}}},u=async()=>{var l,c;if(!n||!ga(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(wi("턴 강제 진행",n,f))try{await Jc(n),S("턴을 다음 단계로 이동했습니다.","success"),Ut()}catch{S("턴 이동에 실패했습니다.","error")}finally{Wa()}},d=async()=>{if(!n||!ga(e))return;const f=Ee.value.trim();if(!f){S("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(ws.value,10),c=Number.parseInt(Ts.value,10);if(Number.isNaN(l)||Number.isNaN(c)){S("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(ea.value,10),$=ea.value.trim()===""||Number.isNaN(m)?void 0:m;try{await Gc({roomId:n,actorId:f,action:As.value.trim()||"ability_check",statValue:l,dc:c,rawD20:$}),S("주사위 판정을 기록했습니다.","success"),Ut()}catch{S("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${f=>{Kt.value=f.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Ee.value}
            onChange=${f=>{Ee.value=f.target.value}}
          >
            <option value="">Actor 선택</option>
            ${s.map(f=>o`<option value=${f.id}>${f.name} (${f.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${As.value}
              onInput=${f=>{As.value=f.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${ws.value}
              onInput=${f=>{ws.value=f.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ts.value}
              onInput=${f=>{Ts.value=f.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ea.value}
              onInput=${f=>{ea.value=f.target.value}}
              onKeyDown=${f=>{f.key==="Enter"&&d()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${d}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${r}
              disabled=${a==="running"}
            >
              ${a==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${u}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${a!=="idle"?o`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Em({state:t}){var s;const e=Kt.value||((s=t.session)==null?void 0:s.room)||"",n=ia.value,a=async()=>{if(!e){S("Room ID가 비어 있습니다.","warning");return}const i=sa.value.trim(),r=Ds.value.trim();if(!r&&!i){S("이름 또는 Actor ID를 입력하세요.","warning");return}const u=Number.parseInt(xn.value.trim(),10),d=Number.parseInt(Os.value.trim(),10),p=Number.isFinite(d)?Math.max(1,d):20,f=Number.isFinite(u)?Math.max(0,Math.min(p,u)):p;let l={};try{l=bm(Ms.value)}catch(c){S(c instanceof Error?c.message:"능력치 JSON 오류","error");return}ia.value="spawning";try{const c=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await Vc(e,{actor_id:i||void 0,name:r||void 0,role:Ps.value,idempotencyKey:c,portrait:Es.value.trim()||void 0,background:Is.value.trim()||void 0,hp:f,max_hp:p,alive:f>0,stats:Object.keys(l).length>0?l:void 0}),$=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!$)throw new Error("생성 응답에 actor_id가 없습니다.");const y=Ls.value.trim();y&&await Qc(e,$,y),Ee.value=$,ne.value=$,i||(sa.value=""),ia.value="ok",S(`Actor 생성 완료: ${$}`,"success"),await Ut()}catch(c){ia.value="error",S(c instanceof Error?c.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Ds.value}
            onInput=${i=>{Ds.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ps.value}
            onChange=${i=>{Ps.value=i.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Keeper (optional)</label>
          <input
            id="trpg-spawn-keeper-input"
            name="trpg-spawn-keeper-input"
            type="text"
            value=${Ls.value}
            onInput=${i=>{Ls.value=i.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${a} disabled=${n==="spawning"}>
              ${n==="spawning"?"Spawning...":"Spawn Actor"}
            </button>
          </div>
        </div>
      </div>

      <details class="trpg-control-details">
        <summary>상세 입력 (선택)</summary>
        <div class="trpg-control-grid">
          <div class="trpg-control-field">
            <label>Actor ID (optional)</label>
            <input
              id="trpg-spawn-actor-id-input"
              name="trpg-spawn-actor-id-input"
              type="text"
              value=${sa.value}
              onInput=${i=>{sa.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Es.value}
              onInput=${i=>{Es.value=i.target.value}}
              placeholder="https://.../portrait.png"
            />
          </div>
          <div class="trpg-control-field">
            <label>HP</label>
            <input
              id="trpg-spawn-hp-input"
              name="trpg-spawn-hp-input"
              type="number"
              min="0"
              value=${xn.value}
              onInput=${i=>{xn.value=i.target.value}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field">
            <label>Max HP</label>
            <input
              id="trpg-spawn-max-hp-input"
              name="trpg-spawn-max-hp-input"
              type="number"
              min="1"
              value=${Os.value}
              onInput=${i=>{const r=i.target.value;Os.value=r,km(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Is.value}
              onInput=${i=>{Is.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ms.value}
              onInput=${i=>{Ms.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Im({state:t,nowMs:e}){var c;const n=Kt.value||((c=t.session)==null?void 0:c.room)||"",a=t.join_gate,s=Rs.value,i=ie(s)?s:null,r=(t.party??[]).filter(m=>m.role!=="dm"),u=ne.value.trim(),d=r.some(m=>m.id===u),p=d?u:u?"__manual__":"",f=async()=>{const m=ne.value.trim(),$=aa.value.trim();if(!n||!m){S("Room/Actor가 필요합니다.","warning");return}bt.value="checking";try{const y=await Yc(n,m,$||void 0);Rs.value=y,bt.value="ok",S("참가 가능 여부를 갱신했습니다.","success")}catch(y){bt.value="error";const k=y instanceof Error?y.message:"참가 가능 여부 확인에 실패했습니다.";S(k,"error")}},l=async()=>{var R,T;const m=ne.value.trim(),$=aa.value.trim(),y=Ns.value.trim();if(!n||!m||!$){S("Room/Actor/Keeper가 필요합니다.","warning");return}if(!ga(e))return;const k=((R=t.current_round)==null?void 0:R.phase)??((T=t.session)==null?void 0:T.status)??"unknown";if(wi("Mid-Join 승인 요청",n,k)){bt.value="requesting";try{const M=await Xc({room_id:n,actor_id:m,keeper_name:$,role:Cs.value,...y?{name:y}:{}});Rs.value=M;const C=ie(M)?qn(M,"granted",!1):!1,D=ie(M)?vt(M,"reason_code",""):"";C?S("Mid-Join이 승인되었습니다.","success"):S(`Mid-Join이 거절되었습니다${D?`: ${D}`:""}`,"warning"),bt.value=C?"ok":"error",Ut()}catch(M){bt.value="error";const C=M instanceof Error?M.message:"Mid-Join 요청에 실패했습니다.";S(C,"error")}finally{Wa()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${a!=null&&a.phase_open?"OPEN":"CLOSED"}</strong>
        ${a!=null&&a.window?o`<span style="margin-left:8px;">(${a.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(a==null?void 0:a.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${p}
            onChange=${m=>{const $=m.target.value;if($==="__manual__"){(d||!u)&&(ne.value="");return}ne.value=$}}
          >
            <option value="">Actor 선택</option>
            ${r.map(m=>o`
              <option value=${m.id}>${m.name} (${m.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${p==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ne.value}
                onInput=${m=>{ne.value=m.target.value}}
                placeholder="player-xyz"
                style="margin-top:6px;"
              />
            `:null}
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${aa.value}
            onInput=${m=>{aa.value=m.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Cs.value}
            onChange=${m=>{Cs.value=m.target.value}}
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
            value=${Ns.value}
            onInput=${m=>{Ns.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${f} disabled=${bt.value==="checking"||bt.value==="requesting"}>
              ${bt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${l} disabled=${bt.value==="checking"||bt.value==="requesting"}>
              ${bt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${qn(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ot(i,"effective_score",0)}/${Ot(i,"required_points",0)}</span>
            ${vt(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${vt(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function yl({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function bl({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function kl(){const t=Si.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ie(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(ie).slice(-8),i=t.canon_check,r=ie(i)?i:null,u=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],p=n?qn(n,"advanced",!1):!1,f=n?vt(n,"progress_reason",""):"",l=n?vt(n,"progress_detail",""):"",c=n?Ot(n,"player_successes",0):0,m=n?Ot(n,"player_required_successes",0):0,$=n?qn(n,"dm_success",!1):!1,y=n?Ot(n,"timeouts",0):0,k=n?Ot(n,"unavailable",0):0,R=n?Ot(n,"reprompts",0):0,T=n?Ot(n,"npc_attacks",0):0,M=n?Ot(n,"keeper_timeout_sec",0):0,C=n?Ot(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${$?"DM ok":"DM stalled"} / players ${c}/${m}
          </span>
        </div>
        ${f?o`<div style="margin-top:4px; font-size:12px;">${f}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${y}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${R}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${M||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${C}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(D=>{const Z=vt(D,"status","unknown"),$t=vt(D,"actor_id","-"),dt=vt(D,"role","-"),tt=vt(D,"reason",""),it=vt(D,"action_type",""),I=vt(D,"reply","");return o`
                <div class="trpg-round-item ${Z.includes("fallback")||Z.includes("timeout")?"failed":"active"}">
                  <span>${$t} (${dt})</span>
                  <span style="margin-left:auto; font-size:11px;">${Z}</span>
                  ${it?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${it}</div>`:null}
                  ${tt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${tt}</div>`:null}
                  ${I?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${I.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${vt(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(D=>o`<div>violation: ${D}</div>`)}
                </div>`:null}
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${u.map(D=>o`<div>warning: ${D}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Om({state:t,nowMs:e}){var r,u,d;const n=Kt.value||((r=t.session)==null?void 0:r.room)||"",a=((u=t.current_round)==null?void 0:u.phase)??((d=t.session)==null?void 0:d.status)??"unknown",s=fl(e),i=Am(e);return o`
    <${w} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>wm(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Wa(),S("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Mm({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Sm(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function zm({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${w} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${w} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${hl} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${w} title="맵" style="margin-top:16px;">
              <${Rm} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${w} title="현재 라운드">
          <${bl} state=${t} />
        <//>

        <${w} title="기여도" style="margin-top:16px;">
          <${yl} state=${t} />
        <//>

        <${w} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${gl} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${$l} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function jm({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${w} title=${`이벤트 타임라인 (${e.length})`}>
          <${Dm} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${w} title="최근 라운드 결과">
          <${kl} />
        <//>

        <${w} title="현재 라운드" style="margin-top:16px;">
          <${bl} state=${t} />
        <//>
      </div>
    </div>
  `}function qm({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Om} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${w} title="조작 패널">
            <${Lm} state=${t} nowMs=${e} />
          <//>

          <${w} title="Actor Spawn" style="margin-top:16px;">
            <${Em} state=${t} />
          <//>

          <${w} title="Mid-Join Gate" style="margin-top:16px;">
            <${Im} state=${t} nowMs=${e} />
          <//>

          <${w} title="최근 라운드 결과" style="margin-top:16px;">
            <${kl} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${w} title="기여도" style="margin-top:0;">
            <${yl} state=${t} />
          <//>

          <${w} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${gl} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${$l} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Fm(){var u,d,p,f,l;const t=jr.value,e=li.value;if(xt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const c=window.setInterval(()=>{Ho.value=Date.now()},1e3);return()=>{window.clearInterval(c)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Ut()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=ml.value,r=Ho.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Kt.value||((u=t.session)==null?void 0:u.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Ut()}>새로고침</button>
      </div>

      <${Pm} outcome=${s} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((f=t.session)==null?void 0:f.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((l=t.current_round)==null?void 0:l.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${a.length}</div>
        </div>
      </div>

      <${Mm} active=${i} />

      ${i==="overview"?o`<${zm} state=${t} />`:i==="timeline"?o`<${jm} state=${t} />`:o`<${qm} state=${t} nowMs=${r} />`}
    </div>
  `}const Ui="masc_dashboard_agent_name";function Hm(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Ui);return e??n??"dashboard"}const ft=_(Hm()),Sn=_(""),An=_(""),Ga=_(""),xl=_(null),Ja=_(null),wn=_(!1),ze=_(!1),Tn=_(!1),Cn=_(!1),Va=_(!1),Qa=_(!1),is=_(!1);function Ya(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ha(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Sl(t){return!t||t.length===0?"none":t.join(", ")}function Km(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ya(t.quiet_start)}-${Ya(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ha(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${ha(t.interval_s)}.`:`Lodge ticks every ${ha(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function tn(){We();try{await xe()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Bi(t){const e=t.trim();ft.value=e,e&&localStorage.setItem(Ui,e)}function Um(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Ti(){const t=ft.value.trim();if(t){Tn.value=!0;try{const e=await tu(t),n=Um(e);n&&Bi(n),is.value=!0,await tn(),S(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";S(n,"error")}finally{Tn.value=!1}}}async function Bm(){const t=ft.value.trim();if(t){Cn.value=!0;try{await Ir(t),is.value=!1,await tn(),S(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";S(n,"error")}finally{Cn.value=!1}}}async function Wm(){const t=ft.value.trim();if(t)try{await Ir(t)}catch{}localStorage.removeItem(Ui),Bi("dashboard"),is.value=!1,await Ti()}async function Gm(){const t=ft.value.trim();if(t){Va.value=!0;try{await eu(t),await tn(),S("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";S(n,"error")}finally{Va.value=!1}}}async function Ko(){const t=ft.value.trim(),e=Sn.value.trim();if(!(!t||!e)){wn.value=!0;try{await Er(t,e),Sn.value="",await tn(),S("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";S(a,"error")}finally{wn.value=!1}}}async function Jm(){const t=An.value.trim(),e=Ga.value.trim()||"Created from dashboard";if(t){ze.value=!0;try{await Zc(t,e,1),An.value="",Ga.value="",await tn(),S("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";S(a,"error")}finally{ze.value=!1}}}async function Uo(){const t=ft.value.trim()||"dashboard";Qa.value=!0,Ja.value=null;try{const e=await Bn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=Mi(e.result);xl.value=n,await tn(),n!=null&&n.skipped_reason?S(n.skipped_reason,"warning"):S(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Ja.value=n,S(n,"error")}finally{Qa.value=!1}}function Vm({runtime:t}){var s,i;const e=xl.value??(t==null?void 0:t.last_tick_result)??null;if(Ja.value)return o`<div class="control-result-box is-error">${Ja.value}</div>`;if(!e)return o`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((i=e.passed_rows)==null?void 0:i.slice(0,3))??[];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?o`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${Sl(e.acted_names)}</div>
      ${e.skipped_reason?o`<div class="control-status-copy">${e.skipped_reason}</div>`:null}
      ${e.activity_report?o`<pre class="control-transcript-text">${e.activity_report}</pre>`:null}
      ${n.length>0?o`
            <div class="control-result-list">
              ${n.map(r=>o`<div>${r.name}: ${r.reason??"skipped"}</div>`)}
            </div>
          `:null}
      ${a.length>0?o`
            <div class="control-result-list">
              ${a.map(r=>o`<div>${r.name}: ${r.reason??"passed"}</div>`)}
            </div>
          `:null}
    </div>
  `}function Qm(t){return t.find(n=>n.name===un.value)??t[0]??null}function Ym(){var a,s;const t=Nt.value,e=((a=ke.value)==null?void 0:a.lodge)??null,n=Qm(t);return xt(()=>{Ti()},[]),xt(()=>{var r;const i=((r=t[0])==null?void 0:r.name)??"";if(!un.value&&i){ca(i);return}un.value&&!t.some(u=>u.name===un.value)&&ca(i)},[t.map(i=>i.name).join("|")]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Identity</h4>
          <p class="control-help">Broadcasts and operator actions use this agent name.</p>
        </div>

        <label class="control-label" for="dock-agent">Agent</label>
        <input
          id="dock-agent"
          class="control-input"
          type="text"
          value=${ft.value}
          onInput=${i=>Bi(i.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Ti()}}
            disabled=${Tn.value||ft.value.trim()===""}
          >
            ${Tn.value?"Joining...":is.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Bm()}}
            disabled=${Cn.value||ft.value.trim()===""}
          >
            ${Cn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Wm()}}
            disabled=${Tn.value||Cn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Gm()}}
            disabled=${Va.value||ft.value.trim()===""}
          >
            ${Va.value?"Pinging...":"Heartbeat"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Broadcast</h4>
          <p class="control-help">This is visible to the room and other agents. Use it for announcements, nudges, and @mentions, not private keeper prompts.</p>
        </div>

        <label class="control-label" for="dock-message">Broadcast</label>
        <div class="control-row">
          <input
            id="dock-message"
            class="control-input"
            type="text"
            placeholder="@agent or room-wide update"
            value=${Sn.value}
            onInput=${i=>{Sn.value=i.target.value}}
            onKeyDown=${i=>{i.key==="Enter"&&Ko()}}
            disabled=${wn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{Ko()}}
            disabled=${wn.value||Sn.value.trim()===""||ft.value.trim()===""}
          >
            ${wn.value?"Sending...":"Send"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Keeper Direct Message</h4>
          <p class="control-help">This sends a 1:1 message through <code>masc_keeper_msg</code> and keeps the actual reply thread in the dock so you can see whether the keeper answered.</p>
        </div>

        <label class="control-label" for="dock-keeper">Keeper</label>
        <select
          id="dock-keeper"
          class="control-input"
          value=${(n==null?void 0:n.name)??""}
          onInput=${i=>{ca(i.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?o`<option value="">No keepers available</option>`:t.map(i=>o`<option value=${i.name}>${i.name}</option>`)}
        </select>

        <${Vr} keeper=${n} />
        <${Yr}
          actor=${ft.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{Uo()}}
        />
        <${Qr}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${Km(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${ha(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Ya(e==null?void 0:e.quiet_start)}-${Ya(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${Sl((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?o`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{Uo()}}
            disabled=${Qa.value}
          >
            ${Qa.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${Vm} runtime=${e} />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Quick Task</h4>
          <p class="control-help">Fast backlog injection for local follow-up work.</p>
        </div>

        <input
          id="dock-task"
          class="control-input"
          type="text"
          placeholder="Task title"
          value=${An.value}
          onInput=${i=>{An.value=i.target.value}}
          disabled=${ze.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Ga.value}
          onInput=${i=>{Ga.value=i.target.value}}
          disabled=${ze.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{Jm()}}
          disabled=${ze.value||An.value.trim()===""}
        >
          ${ze.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const Bo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],Ci=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"execution",label:"Execution",icon:"🛠️",group:"observe",description:"Intervention queue for stalled work, ownership gaps, and execution drift"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"activity",label:"Activity",icon:"📊",group:"observe",description:"Unified live stream for messages, task changes, board events, and keeper events"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"council",label:"Council",icon:"🏛️",group:"coordinate",description:"Debates, quorum status, and decision flow"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals and MDAL loops in one planning surface with freshness signals"},{id:"tasks",label:"Tasks",icon:"📋",group:"coordinate",description:"Kanban-style task distribution"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],Wo="masc_dashboard_quick_actions_open";function Xm(){const t=Bt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Kn.value} events</span>
    </div>
  `}function Zm(){const t=zt.value.tab,e=Bt.value,n=Ci.find(r=>r.id===t),a=Bo.find(r=>r.id===(n==null?void 0:n.group)),[s,i]=cr(()=>{const r=localStorage.getItem(Wo);return r!=="0"});return xt(()=>{localStorage.setItem(Wo,s?"1":"0")},[s]),o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?o`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${Bo.map(r=>o`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${Ci.filter(u=>u.group===r.id).map(u=>o`
                  <button
                    class="rail-tab-btn ${t===u.id?"active":""}"
                    onClick=${()=>Tt(u.id)}
                  >
                    <span class="rail-tab-icon">${u.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${u.label}</strong>
                      <span>${u.description}</span>
                    </span>
                  </button>
                `)}
            </div>
          </div>
        `)}
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${(n==null?void 0:n.description)??"Live operational view"}</p>
        </div>
      </section>

      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Snapshot</h3>
          <span class="rail-section-chip ${e?"ok":"bad"}">${e?"Live":"Offline"}</span>
        </div>
        <div class="rail-stat-grid">
          <div class="rail-stat-card">
            <span>Agents</span>
            <strong>${Qt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${Nt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${_t.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${Kn.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${()=>{xe(),t==="command"&&Mn(),t==="ops"&&Je(),t==="board"&&jt(),t==="council"&&Ve(),t==="trpg"&&Ut(),t==="goals"&&(pn(),qe())}}
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>Tt("ops")}>
            Open Ops
          </button>
        </div>
      </section>

      <section class="rail-card fold-card">
        <div class="rail-card-head">
          <h3>Quick Actions</h3>
          <span class="rail-section-chip">${s?"Open":"Closed"}</span>
        </div>
        <button class="fold-toggle" onClick=${()=>i(r=>!r)}>
          <span>${s?"Hide inline actions":"Show inline actions"}</span>
          <span class="fold-toggle-meta">Join, broadcast, keeper DM, lodge poke</span>
        </button>
        ${s?o`<div class="rail-fold-body"><${Ym} /></div>`:o`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function tf(){switch(zt.value.tab){case"command":return o`<${Ip} />`;case"overview":return o`<${wo} />`;case"ops":return o`<${av} />`;case"council":return o`<${lv} />`;case"board":return o`<${$v} />`;case"execution":return o`<${am} />`;case"activity":return o`<${zv} />`;case"agents":return o`<${Qv} />`;case"tasks":return o`<${Yv} />`;case"goals":return o`<${pm} />`;case"trpg":return o`<${Fm} />`;default:return o`<${wo} />`}}function ef(){xt(()=>{Ql(),Cr(),xe(),jt();const n=Wu();return Gu(),()=>{sc(),n(),Ju()}},[]),xt(()=>{const n=zt.value.tab;n==="command"&&Mn(),n==="ops"&&Je(),n==="board"&&jt(),n==="council"&&Ve(),n==="trpg"&&Ut(),n==="goals"&&(pn(),qe())},[zt.value.tab]);const t=zt.value.tab,e=Ci.find(n=>n.id===t);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <${Xm} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Zm} />
        <main class="dashboard-main">
          ${ri.value&&!Bt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${tf} />`}
        </main>
      </div>

      <${_d} />
      <${bd} />
      <${td} />
    </div>
  `}const Go=document.getElementById("app");Go&&Pl(o`<${ef} />`,Go);
