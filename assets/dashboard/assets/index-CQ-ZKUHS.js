var yo=Object.defineProperty;var bo=(t,e,n)=>e in t?yo(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Dt=(t,e,n)=>bo(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var Cn,I,Ja,Va,wt,ra,Ya,Qa,Xa,Hs,us,ds,ke={},Za=[],xo=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Nn=Array.isArray;function lt(t,e){for(var n in e)t[n]=e[n];return t}function Ks(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function ti(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Cn.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return Qe(t,r,s,a,null)}function Qe(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++Ja,__i:-1,__u:0};return a==null&&I.vnode!=null&&I.vnode(i),i}function Ie(t){return t.children}function ne(t,e){this.props=t,this.context=e}function qt(t,e){if(e==null)return t.__?qt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?qt(t):null}function ei(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return ei(t)}}function la(t){(!t.__d&&(t.__d=!0)&&wt.push(t)&&!sn.__r++||ra!=I.debounceRendering)&&((ra=I.debounceRendering)||Ya)(sn)}function sn(){for(var t,e,n,s,a,i,r,l=1;wt.length;)wt.length>l&&wt.sort(Qa),t=wt.shift(),l=wt.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=lt({},s)).__v=s.__v+1,I.vnode&&I.vnode(n),Bs(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??qt(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,ai(i,n,r),s.__e=s.__=null,n.__e!=a&&ei(n)));sn.__r=0}function ni(t,e,n,s,a,i,r,l,d,u,v){var c,p,m,g,x,C,T,N=s&&s.__k||Za,O=e.length;for(d=ko(n,e,N,d,O),c=0;c<O;c++)(m=n.__k[c])!=null&&(p=m.__i==-1?ke:N[m.__i]||ke,m.__i=c,C=Bs(t,m,p,a,i,r,l,d,u,v),g=m.__e,m.ref&&p.ref!=m.ref&&(p.ref&&qs(p.ref,null,m),v.push(m.ref,m.__c||g,m)),x==null&&g!=null&&(x=g),(T=!!(4&m.__u))||p.__k===m.__k?d=si(m,d,t,T):typeof m.type=="function"&&C!==void 0?d=C:g&&(d=g.nextSibling),m.__u&=-7);return n.__e=x,d}function ko(t,e,n,s,a){var i,r,l,d,u,v=n.length,c=v,p=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=Qe(null,r,null,null,null):Nn(r)?r=t.__k[i]=Qe(Ie,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=Qe(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+p,r.__=t,r.__b=t.__b+1,l=null,(u=r.__i=wo(r,n,d,c))!=-1&&(c--,(l=n[u])&&(l.__u|=2)),l==null||l.__v==null?(u==-1&&(a>v?p--:a<v&&p++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?p--:u==d+1?p++:(u>d?p--:p++,r.__u|=4))):t.__k[i]=null;if(c)for(i=0;i<v;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=qt(l)),oi(l,l));return s}function si(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=si(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=qt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function wo(t,e,n,s){var a,i,r,l=t.key,d=t.type,u=e[n],v=u!=null&&(2&u.__u)==0;if(u===null&&l==null||v&&l==u.key&&d==u.type)return n;if(s>(v?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((u=e[r=a>=0?a--:i++])!=null&&(2&u.__u)==0&&l==u.key&&d==u.type)return r}return-1}function ca(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||xo.test(e)?n:n+"px"}function Fe(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||ca(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||ca(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Xa,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=Hs,t.addEventListener(e,i?ds:us,i)):t.removeEventListener(e,i?ds:us,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function ua(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Hs++;else if(e.t<n.u)return;return n(I.event?I.event(e):e)}}}function Bs(t,e,n,s,a,i,r,l,d,u){var v,c,p,m,g,x,C,T,N,O,H,D,Y,xt,kt,Q,rt,L=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[l=e.__e=n.__e]),(v=I.__b)&&v(e);t:if(typeof L=="function")try{if(T=e.props,N="prototype"in L&&L.prototype.render,O=(v=L.contextType)&&s[v.__c],H=v?O?O.props.value:v.__:s,n.__c?C=(c=e.__c=n.__c).__=c.__E:(N?e.__c=c=new L(T,H):(e.__c=c=new ne(T,H),c.constructor=L,c.render=Ao),O&&O.sub(c),c.state||(c.state={}),c.__n=s,p=c.__d=!0,c.__h=[],c._sb=[]),N&&c.__s==null&&(c.__s=c.state),N&&L.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=lt({},c.__s)),lt(c.__s,L.getDerivedStateFromProps(T,c.__s))),m=c.props,g=c.state,c.__v=e,p)N&&L.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),N&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(N&&L.getDerivedStateFromProps==null&&T!==m&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(T,H),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(T,c.__s,H)===!1){for(e.__v!=n.__v&&(c.props=T,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(z){z&&(z.__=e)}),D=0;D<c._sb.length;D++)c.__h.push(c._sb[D]);c._sb=[],c.__h.length&&r.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(T,c.__s,H),N&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(m,g,x)})}if(c.context=H,c.props=T,c.__P=t,c.__e=!1,Y=I.__r,xt=0,N){for(c.state=c.__s,c.__d=!1,Y&&Y(e),v=c.render(c.props,c.state,c.context),kt=0;kt<c._sb.length;kt++)c.__h.push(c._sb[kt]);c._sb=[]}else do c.__d=!1,Y&&Y(e),v=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++xt<25);c.state=c.__s,c.getChildContext!=null&&(s=lt(lt({},s),c.getChildContext())),N&&!p&&c.getSnapshotBeforeUpdate!=null&&(x=c.getSnapshotBeforeUpdate(m,g)),Q=v,v!=null&&v.type===Ie&&v.key==null&&(Q=ii(v.props.children)),l=ni(t,Nn(Q)?Q:[Q],e,n,s,a,i,r,l,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&r.push(c),C&&(c.__E=c.__=null)}catch(z){if(e.__v=null,d||i!=null)if(z.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(rt=i.length;rt--;)Ks(i[rt]);ps(e)}else e.__e=n.__e,e.__k=n.__k,z.then||ps(e);I.__e(z,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=So(n.__e,e,n,s,a,i,r,d,u);return(v=I.diffed)&&v(e),128&e.__u?void 0:l}function ps(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(ps)}function ai(t,e,n){for(var s=0;s<n.length;s++)qs(n[s],n[++s],n[++s]);I.__c&&I.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){I.__e(i,a.__v)}})}function ii(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Nn(t)?t.map(ii):lt({},t)}function So(t,e,n,s,a,i,r,l,d){var u,v,c,p,m,g,x,C=n.props||ke,T=e.props,N=e.type;if(N=="svg"?a="http://www.w3.org/2000/svg":N=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((m=i[u])&&"setAttribute"in m==!!N&&(N?m.localName==N:m.nodeType==3)){t=m,i[u]=null;break}}if(t==null){if(N==null)return document.createTextNode(T);t=document.createElementNS(a,N,T.is&&T),l&&(I.__m&&I.__m(e,i),l=!1),i=null}if(N==null)C===T||l&&t.data==T||(t.data=T);else{if(i=i&&Cn.call(t.childNodes),!l&&i!=null)for(C={},u=0;u<t.attributes.length;u++)C[(m=t.attributes[u]).name]=m.value;for(u in C)if(m=C[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=m;else if(!(u in T)){if(u=="value"&&"defaultValue"in T||u=="checked"&&"defaultChecked"in T)continue;Fe(t,u,null,m,a)}}for(u in T)m=T[u],u=="children"?p=m:u=="dangerouslySetInnerHTML"?v=m:u=="value"?g=m:u=="checked"?x=m:l&&typeof m!="function"||C[u]===m||Fe(t,u,m,C[u],a);if(v)l||c&&(v.__html==c.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(c&&(t.innerHTML=""),ni(e.type=="template"?t.content:t,Nn(p)?p:[p],e,n,s,N=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&qt(n,0),l,d),i!=null)for(u=i.length;u--;)Ks(i[u]);l||(u="value",N=="progress"&&g==null?t.removeAttribute("value"):g!=null&&(g!==t[u]||N=="progress"&&!g||N=="option"&&g!=C[u])&&Fe(t,u,g,C[u],a),u="checked",x!=null&&x!=t[u]&&Fe(t,u,x,C[u],a))}return t}function qs(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){I.__e(a,n)}}function oi(t,e,n){var s,a;if(I.unmount&&I.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||qs(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){I.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&oi(s[a],e,n||typeof t.type!="function");n||Ks(t.__e),t.__c=t.__=t.__e=void 0}function Ao(t,e,n){return this.constructor(t,n)}function Co(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),I.__&&I.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],Bs(e,t=e.__k=ti(Ie,null,[t]),a||ke,ke,e.namespaceURI,a?null:e.firstChild?Cn.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),ai(i,t,r)}Cn=Za.slice,I={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},Ja=0,Va=function(t){return t!=null&&t.constructor===void 0},ne.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=lt({},this.state),typeof t=="function"&&(t=t(lt({},n),this.props)),t&&lt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),la(this))},ne.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),la(this))},ne.prototype.render=Ie,wt=[],Ya=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Qa=function(t,e){return t.__v.__b-e.__v.__b},sn.__r=0,Xa=/(PointerCapture)$|Capture$/i,Hs=0,us=ua(!1),ds=ua(!0);var ri=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++i]]=l:r===6?s[1][e[++i]]+=l+"":r?(a=t.apply(l,ri(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},da=new Map;function No(t){var e=da.get(this);return e||(e=new Map,da.set(this,e)),(e=ri(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",l="",d=[0],u=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,r):i===3&&(p||r)?(d.push(3,p,r),i=2):i===2&&r==="..."&&p?d.push(4,p,0):i===2&&r&&!p?d.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(d.push(i,0,r,a),i=6),p&&(d.push(i,p,0,a),i=6)),r=""},v=0;v<n.length;v++){v&&(i===1&&u(),u(v));for(var c=0;c<n[v].length;c++)s=n[v][c],i===1?s==="<"?(u(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(u(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[v][c+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=No.bind(ti),we,j,Pn,pa,vs=0,li=[],F=I,va=F.__b,ma=F.__r,fa=F.diffed,_a=F.__c,ga=F.unmount,$a=F.__;function Gs(t,e){F.__h&&F.__h(j,t,vs||e),vs=0;var n=j.__H||(j.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function ze(t){return vs=1,To(di,t)}function To(t,e,n){var s=Gs(we++,2);if(s.t=t,!s.__c&&(s.__=[di(void 0,e),function(l){var d=s.__N?s.__N[0]:s.__[0],u=s.t(d,l);d!==u&&(s.__N=[u,s.__[1]],s.__c.setState({}))}],s.__c=j,!j.__f)){var a=function(l,d,u){if(!s.__c.__H)return!0;var v=s.__c.__H.__.filter(function(p){return!!p.__c});if(v.every(function(p){return!p.__N}))return!i||i.call(this,l,d,u);var c=s.__c.props!==l;return v.forEach(function(p){if(p.__N){var m=p.__[0];p.__=p.__N,p.__N=void 0,m!==p.__[0]&&(c=!0)}}),i&&i.call(this,l,d,u)||c};j.__f=!0;var i=j.shouldComponentUpdate,r=j.componentWillUpdate;j.componentWillUpdate=function(l,d,u){if(this.__e){var v=i;i=void 0,a(l,d,u),i=v}r&&r.call(this,l,d,u)},j.shouldComponentUpdate=a}return s.__N||s.__}function $t(t,e){var n=Gs(we++,3);!F.__s&&ui(n.__H,e)&&(n.__=t,n.u=e,j.__H.__h.push(n))}function ci(t,e){var n=Gs(we++,7);return ui(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Ro(){for(var t;t=li.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(Xe),t.__H.__h.forEach(ms),t.__H.__h=[]}catch(e){t.__H.__h=[],F.__e(e,t.__v)}}F.__b=function(t){j=null,va&&va(t)},F.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),$a&&$a(t,e)},F.__r=function(t){ma&&ma(t),we=0;var e=(j=t.__c).__H;e&&(Pn===j?(e.__h=[],j.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(Xe),e.__h.forEach(ms),e.__h=[],we=0)),Pn=j},F.diffed=function(t){fa&&fa(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(li.push(e)!==1&&pa===F.requestAnimationFrame||((pa=F.requestAnimationFrame)||Lo)(Ro)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Pn=j=null},F.__c=function(t,e){e.some(function(n){try{n.__h.forEach(Xe),n.__h=n.__h.filter(function(s){return!s.__||ms(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],F.__e(s,n.__v)}}),_a&&_a(t,e)},F.unmount=function(t){ga&&ga(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{Xe(s)}catch(a){e=a}}),n.__H=void 0,e&&F.__e(e,n.__v))};var ha=typeof requestAnimationFrame=="function";function Lo(t){var e,n=function(){clearTimeout(s),ha&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);ha&&(e=requestAnimationFrame(n))}function Xe(t){var e=j,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),j=e}function ms(t){var e=j;t.__c=t.__(),j=e}function ui(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function di(t,e){return typeof e=="function"?e(t):e}var Io=Symbol.for("preact-signals");function Tn(){if(_t>1)_t--;else{for(var t,e=!1;se!==void 0;){var n=se;for(se=void 0,fs++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&mi(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(fs=0,_t--,e)throw t}}function Do(t){if(_t>0)return t();_t++;try{return t()}finally{Tn()}}var R=void 0;function pi(t){var e=R;R=void 0;try{return t()}finally{R=e}}var se=void 0,_t=0,fs=0,an=0;function vi(t){if(R!==void 0){var e=t.n;if(e===void 0||e.t!==R)return e={i:0,S:t,p:R.s,n:void 0,t:R,e:void 0,x:void 0,r:e},R.s!==void 0&&(R.s.n=e),R.s=e,t.n=e,32&R.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=R.s,e.n=void 0,R.s.n=e,R.s=e),e}}function U(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}U.prototype.brand=Io;U.prototype.h=function(){return!0};U.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:pi(function(){var s;(s=e.W)==null||s.call(e)}))};U.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&pi(function(){var a;(a=e.Z)==null||a.call(e)}))}};U.prototype.subscribe=function(t){var e=this;return De(function(){var n=e.value,s=R;R=void 0;try{t(n)}finally{R=s}},{name:"sub"})};U.prototype.valueOf=function(){return this.value};U.prototype.toString=function(){return this.value+""};U.prototype.toJSON=function(){return this.value};U.prototype.peek=function(){var t=R;R=void 0;try{return this.value}finally{R=t}};Object.defineProperty(U.prototype,"value",{get:function(){var t=vi(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(fs>100)throw new Error("Cycle detected");this.v=t,this.i++,an++,_t++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Tn()}}}});function f(t,e){return new U(t,e)}function mi(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function fi(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function _i(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function Tt(t,e){U.call(this,void 0),this.x=t,this.s=void 0,this.g=an-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}Tt.prototype=new U;Tt.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===an))return!0;if(this.g=an,this.f|=1,this.i>0&&!mi(this))return this.f&=-2,!0;var t=R;try{fi(this),R=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return R=t,_i(this),this.f&=-2,!0};Tt.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}U.prototype.S.call(this,t)};Tt.prototype.U=function(t){if(this.t!==void 0&&(U.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};Tt.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(Tt.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=vi(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function W(t,e){return new Tt(t,e)}function gi(t){var e=t.u;if(t.u=void 0,typeof e=="function"){_t++;var n=R;R=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,Ws(t),s}finally{R=n,Tn()}}}function Ws(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,gi(t)}function Eo(t){if(R!==this)throw new Error("Out-of-order effect");_i(this),R=t,this.f&=-2,8&this.f&&Ws(this),Tn()}function Vt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Vt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Vt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,gi(this),fi(this),_t++;var t=R;return R=this,Eo.bind(this,t)};Vt.prototype.N=function(){2&this.f||(this.f|=2,this.o=se,se=this)};Vt.prototype.d=function(){this.f|=8,1&this.f||Ws(this)};Vt.prototype.dispose=function(){this.d()};function De(t,e){var n=new Vt(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var $i,Ue,Mo=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,hi=[];De(function(){$i=this.N})();function Yt(t,e){I[t]=e.bind(null,I[t]||function(){})}function on(t){if(Ue){var e=Ue;Ue=void 0,e()}Ue=t&&t.S()}function yi(t){var e=this,n=t.data,s=Oo(n);s.value=n;var a=ci(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=W(function(){var m=s.value.value;return m===0?0:m===!0?"":m||""}),v=W(function(){return!Array.isArray(u.value)&&!Va(u.value)}),c=De(function(){if(this.N=bi,v.value){var m=u.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=m)}}),p=e.__$u.d;return e.__$u.d=function(){c(),p.call(this)},[v,u]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}yi.displayName="ReactiveTextNode";Object.defineProperties(U.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:yi},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Yt("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof U&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});Yt("__r",function(t,e){if(t(e),e.type!==Ie){on();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return De(function(){r=this},{name:i}),r.c=a,r})(function(){var a;Mo&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),on(n)}});Yt("__e",function(t,e,n,s){on(),t(e,n,s)});Yt("diffed",function(t,e){on();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in s)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var u=i[d],v=s[d];u===void 0?(u=Po(n,d,v),i[d]=u):u.o(v,a)}for(var c in s)a[c]=s[c]}}t(e)});function Po(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(l,d){i.value=l,r=l.peek()},d:De(function(){this.N=bi;var l=i.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}Yt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});Yt("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});ne.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function Oo(t,e){return ci(function(){return f(t,e)},[])}var jo=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Fo(){Do(function(){for(var t;t=hi.shift();)$i.call(t)})}function bi(){hi.push(this)===1&&(I.requestAnimationFrame||jo)(Fo)}const zo=["overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],xi={tab:"overview",params:{},postId:null},Uo={journal:"activity",mdal:"goals"};function ya(t){return!!t&&zo.includes(t)}function ba(t){if(t)return Uo[t]??t}function _s(t){try{return decodeURIComponent(t)}catch{return t}}function gs(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Ho(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function ki(t,e){const n=ba(t[0]),s=ba(e.tab),a=ya(n)?n:ya(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=_s(t[2]):t[0]==="post"&&t[1]&&(i=_s(t[1]))),{tab:a,params:e,postId:i}}function rn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return xi;const n=_s(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=gs(a),r=Ho(s);return ki(r,i)}function Ko(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...xi,params:gs(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=gs(e.replace(/^\?/,""));return ki(s,a)}function wi(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const st=f(rn(window.location.hash));window.addEventListener("hashchange",()=>{st.value=rn(window.location.hash)});function Rn(t,e){const n={tab:t,params:{},postId:null};window.location.hash=wi(n)}function Bo(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function qo(){if(window.location.hash&&window.location.hash!=="#"){st.value=rn(window.location.hash);return}const t=Ko(window.location.pathname,window.location.search);if(t){st.value=t;const e=wi(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",st.value=rn(window.location.hash)}const $s=[{id:"overview",label:"Overview",icon:"🏠"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"council",label:"Council",icon:"🏛️"},{id:"goals",label:"Planning",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"agents",label:"Agents",icon:"🤖"},{id:"ops",label:"Ops",icon:"🎮"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function Go(){const t=st.value.tab;return o`
    <div class="main-tab-bar">
      ${$s.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Rn(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const xa="masc_dashboard_sse_session_id",Wo=1e3,Jo=15e3,ht=f(!1),Ln=f(0),Si=f(null),Gt=f([]);function Vo(){let t=sessionStorage.getItem(xa);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(xa,t)),t}const Yo=200;function X(t,e,n="system"){const s={agent:t,text:e,timestamp:Date.now(),kind:n};Gt.value=[s,...Gt.value].slice(0,Yo)}function ka(t,e){const n=(e??"").replace(/\s+/g," ").trim();if(!n)return`New ${t.toLowerCase()}`;const s=n.length>88?`${n.slice(0,85)}...`:n;return`${t}: ${s}`}let ot=null,Ht=null,hs=0;function Ai(){Ht&&(clearTimeout(Ht),Ht=null)}function Qo(){if(Ht)return;hs++;const t=Math.min(hs,5),e=Math.min(Jo,Wo*Math.pow(2,t));Ht=setTimeout(()=>{Ht=null,Ci()},e)}function Ci(){Ai(),ot&&(ot.close(),ot=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Vo());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);ot=i,i.onopen=()=>{ot===i&&(hs=0,ht.value=!0)},i.onerror=()=>{ot===i&&(ht.value=!1,i.close(),ot=null,Qo())},i.onmessage=r=>{try{const l=JSON.parse(r.data);Ln.value++,Si.value=l,Xo(l)}catch{}}}function Xo(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":X(n,"Joined","system");break;case"agent_left":X(n,"Left","system");break;case"broadcast":X(n,`${(t.message??t.content??"").slice(0,80)}`,"system");break;case"task_update":X(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks");break;case"board_post":case"masc/board_post":X(n,ka("Post",t.content??t.message),"board");break;case"board_comment":case"masc/board_comment":X(n,ka("Comment",t.content??t.message),"board");break;case"keeper_heartbeat":X(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers");break;case"keeper_handoff":X(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers");break;case"keeper_compaction":X(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers");break;case"keeper_guardrail":X(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers");break;default:X(n,e,"system")}}function Zo(){Ai(),ot&&(ot.close(),ot=null),ht.value=!1}function Ni(){return new URLSearchParams(window.location.search)}function Ti(){const t=Ni(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Ri(){return{...Ti(),"Content-Type":"application/json"}}const tr=15e3,Li=3e4,er=6e4,wa=new Set([408,425,429,500,502,503,504]);class Ee extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Dt(this,"method");Dt(this,"path");Dt(this,"status");Dt(this,"statusText");Dt(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Js(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Ee({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function nr(){var e,n;const t=Ni();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function pt(t){const e=await Js(t,{headers:Ti()},tr);if(!e.ok)throw new Ee({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function sr(t){return new Promise(e=>setTimeout(e,t))}function ar(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function ir(t){if(t instanceof Ee)return t.timeout||typeof t.status=="number"&&wa.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=ar(t.message);return e!==null&&wa.has(e)}async function Me(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!ir(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await sr(i),s+=1}}async function vt(t,e,n){const s=await Js(t,{method:"POST",headers:{...Ri(),...n??{}},body:JSON.stringify(e)},Li);if(!s.ok)throw new Ee({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function or(t,e,n,s=Li){const a=await Js(t,{method:"POST",headers:{...Ri(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Ee({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function rr(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function lr(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function B(t,e){const n=await or("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},er),s=rr(n);return lr(s)}function cr(t="compact"){return pt(`/api/v1/dashboard?mode=${t}`)}function ur(){return pt("/api/v1/operator")}function dr(t){return vt("/api/v1/operator/action",t)}function pr(t,e){return vt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function Wt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function vr(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Ii(t){if(!S(t))return null;const e=_(t.id,"").trim(),n=_(t.author,"").trim(),s=_(t.content,"").trim();if(!e||!n)return null;const a=w(t.score,0),i=w(t.votes_up,0),r=w(t.votes_down,0),l=w(t.votes,a||i-r),d=w(t.comment_count,w(t.reply_count,0)),u=(()=>{const g=t.flair;if(typeof g=="string"&&g.trim())return g.trim();if(S(g)){const C=_(g.name,"").trim();if(C)return C}return _(t.flair_name,"").trim()||void 0})(),v=_(t.created_at_iso,"").trim()||Wt(t.created_at),c=_(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Wt(t.updated_at):v),m=_(t.title,"").trim()||vr(s);return{id:e,author:n,title:m,content:s,tags:[],votes:l,vote_balance:a,comment_count:d,created_at:v,updated_at:c,flair:u,hearth_count:w(t.hearth_count,0)}}function mr(t){if(!S(t))return null;const e=_(t.id,"").trim(),n=_(t.post_id,"").trim(),s=_(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:_(t.content,""),created_at:Wt(t.created_at)}}async function fr(t,e){return Me("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit","100");const s=n.toString(),a=await pt(`/api/v1/board${s?`?${s}`:""}`);return{posts:Array.isArray(a.posts)?a.posts.map(Ii).filter(r=>r!==null):[]}})}async function _r(t){return Me("fetchBoardPost",async()=>{const e=await pt(`/api/v1/board/${t}?format=flat`),n=S(e.post)?e.post:e,s=Ii(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(mr).filter(r=>r!==null);return{...s,comments:i}})}function Di(t,e){return vt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:nr()})}function gr(t,e,n){return vt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function $r(t){const e=_(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function K(...t){for(const e of t){const n=_(e,"");if(n.trim())return n.trim()}return""}function Sa(t){const e=$r(K(t.outcome,t.result,t.result_code));if(!e)return;const n=K(t.reason,t.reason_code,t.description,t.detail),s=K(t.summary,t.summary_ko,t.summary_en,t.note),a=K(t.details,t.details_text,t.text,t.note),i=K(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=K(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=K(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(p=>{if(typeof p=="string")return p.trim();if(S(p)){const m=_(p.summary,"").trim();if(m)return m;const g=_(p.text,"").trim();if(g)return g;const x=_(p.type,"").trim();return x||_(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),u=(()=>{const c=w(t.turn,Number.NaN);if(Number.isFinite(c))return c;const p=w(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const m=w(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const g=w(t.round,Number.NaN);return Number.isFinite(g)?g:void 0})(),v=K(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:l||void 0,turn:u,phase:v||void 0}}function hr(t,e){const n=S(t.state)?t.state:{};if(_(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>S(r)?_(r.type,"")==="session.outcome":!1),i=S(n.session_outcome)?n.session_outcome:{};if(S(i)&&Object.keys(i).length>0){const r=Sa(i);if(r)return r}if(S(a))return Sa(S(a.payload)?a.payload:{})}function S(t){return typeof t=="object"&&t!==null}function _(t,e=""){return typeof t=="string"?t:e}function w(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function ft(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function ys(t,e=!1){return typeof t=="boolean"?t:e}function Zt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(S(e)){const n=_(e.name,"").trim(),s=_(e.id,"").trim(),a=_(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function yr(t){const e={};if(!S(t)&&!Array.isArray(t))return e;if(S(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=_(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!S(n))continue;const s=K(n.to,n.target,n.actor_id,n.name,n.id),a=K(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function br(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function J(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const xr=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function kr(t){const e=S(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(xr.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function wr(t,e){if(t!=="dice.rolled")return;const n=w(e.raw_d20,0),s=w(e.total,0),a=w(e.bonus,0),i=_(e.action,"roll"),r=w(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Sr(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ar(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Cr(t,e,n,s){const a=n||e||_(s.actor_id,"")||_(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=_(s.proposed_action,_(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=_(s.reply,_(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return _(s.reply,_(s.content,_(s.text,"Narration")));case"dice.rolled":{const i=_(s.action,"roll"),r=w(s.total,0),l=w(s.dc,0),d=_(s.label,""),u=a||"actor",v=l>0?` vs DC ${l}`:"",c=d?` (${d})`:"";return`${u} ${i}: ${r}${v}${c}`}case"turn.started":return`Turn ${w(s.turn,1)} started`;case"phase.changed":return`Phase: ${_(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${_(s.name,S(s.actor)?_(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${_(s.keeper_name,_(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${_(s.keeper_name,_(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${w(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${w(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||_(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||_(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${_(s.reason_code,"unknown")}`;case"memory.signal":{const i=S(s.entity_refs)?s.entity_refs:{},r=_(i.requested_tier,""),l=_(i.effective_tier,""),d=ys(i.guardrail_applied,!1),u=_(s.summary_en,_(s.summary_ko,"Memory signal"));if(!r&&!l)return u;const v=r&&l?`${r}->${l}`:l||r;return`${u} [${v}${d?" (guardrail)":""}]`}case"world.event":{if(_(s.event_type,"")==="canon.check"){const r=_(s.status,"unknown"),l=_(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return _(s.description,_(s.summary,"World event"))}case"combat.attack":return _(s.summary,_(s.result,"Attack resolved"));case"combat.defense":return _(s.summary,_(s.result,"Defense resolved"));case"session.outcome":return _(s.summary,_(s.outcome,"Session ended"));default:{const i=Sr(s);return i?`${t}: ${i}`:t}}}function Nr(t,e){const n=S(t)?t:{},s=_(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=_(n.actor_name,"").trim()||e[a]||_(S(n.payload)?n.payload.actor_name:"",""),r=S(n.payload)?n.payload:{},l=_(n.ts,_(n.timestamp,new Date().toISOString())),d=_(n.phase,_(r.phase,"")),u=_(n.category,"");return{type:s,actor:i||a||_(r.actor_name,""),actor_id:a||_(r.actor_id,""),actor_name:i,seq:n.seq,room_id:_(n.room_id,""),phase:d||void 0,category:u||Ar(s),visibility:_(n.visibility,_(r.visibility,"public")),event_id:_(n.event_id,""),content:Cr(s,a,i,r),dice_roll:wr(s,r),timestamp:l}}function Tr(t,e,n){var Q,rt;const s=_(t.room_id,"")||n||"default",a=S(t.state)?t.state:{},i=S(a.party)?a.party:{},r=S(a.actor_control)?a.actor_control:{},l=S(a.join_gate)?a.join_gate:{},d=S(a.contribution_ledger)?a.contribution_ledger:{},u=Object.entries(i).map(([L,z])=>{const $=S(z)?z:{},je=J($,"max_hp",void 0,10),aa=J($,"hp",void 0,je),ro=J($,"max_mp",void 0,0),lo=J($,"mp",void 0,0),co=J($,"level",void 0,1),uo=J($,"xp",void 0,0),po=ys($.alive,aa>0),ia=r[L],oa=typeof ia=="string"?ia:void 0,vo=br($.role,L,oa),mo=ft($.generation),fo=K($.joined_at,$.joinedAt,$.started_at,$.startedAt),_o=K($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),go=K($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),$o=K($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),ho=K($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:L,name:_($.name,L),role:vo,keeper:oa,archetype:_($.archetype,""),persona:_($.persona,""),portrait:_($.portrait,"")||void 0,background:_($.background,"")||void 0,traits:Zt($.traits),skills:Zt($.skills),stats_raw:kr($),status:po?"active":"dead",generation:mo,joined_at:fo||void 0,claimed_at:_o||void 0,last_seen:go||void 0,scene:$o||void 0,location:ho||void 0,inventory:Zt($.inventory),notes:Zt($.notes),relationships:yr($.relationships),stats:{hp:aa,max_hp:je,mp:lo,max_mp:ro,level:co,xp:uo,strength:J($,"strength","str",10),dexterity:J($,"dexterity","dex",10),constitution:J($,"constitution","con",10),intelligence:J($,"intelligence","int",10),wisdom:J($,"wisdom","wis",10),charisma:J($,"charisma","cha",10)}}}),v=u.filter(L=>L.status!=="dead"),c=hr(t,e),p={phase_open:ys(l.phase_open,!0),min_points:w(l.min_points,3),window:_(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},m=Object.entries(d).map(([L,z])=>{const $=S(z)?z:{};return{actor_id:L,score:w($.score,0),last_reason:_($.last_reason,"")||null,reasons:Zt($.reasons)}}),g=u.reduce((L,z)=>(L[z.id]=z.name,L),{}),x=e.map(L=>Nr(L,g)),C=w(a.turn,1),T=_(a.phase,"round"),N=_(a.map,""),O=S(a.world)?a.world:{},H=N||_(O.ascii_map,_(O.map,"")),D=x.filter((L,z)=>{const $=e[z];if(!S($))return!1;const je=S($.payload)?$.payload:{};return w(je.turn,-1)===C}),Y=(D.length>0?D:x).slice(-12),xt=_(a.status,"active");return{session:{id:s,room:s,status:xt==="ended"?"ended":xt==="paused"?"paused":"active",round:C,actors:v,created_at:((Q=x[0])==null?void 0:Q.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:T,events:Y,timestamp:((rt=x[x.length-1])==null?void 0:rt.timestamp)??new Date().toISOString()},map:H||void 0,join_gate:p,contribution_ledger:m,outcome:c,party:v,story_log:x,history:[]}}async function Rr(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await pt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Lr(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([pt(`/api/v1/trpg/state${e}`),Rr(t)]);return Tr(n,s,t)}function Ir(t){return vt("/api/v1/trpg/rounds/run",{room_id:t})}function Dr(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Er(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),vt("/api/v1/trpg/dice/roll",e)}function Mr(t,e){const n=Dr();return vt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Pr(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),vt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Or(t,e,n){return vt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function jr(t,e,n){const s=await B("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Fr(t){const e=await B("trpg.mid_join.request",t);return JSON.parse(e)}async function Ei(t,e){await B("masc_broadcast",{agent_name:t,message:e})}async function zr(t,e,n=1){await B("masc_add_task",{title:t,description:e,priority:n})}async function Ur(t){return B("masc_join",{agent_name:t})}async function Mi(t){await B("masc_leave",{agent_name:t})}async function Hr(t){await B("masc_heartbeat",{agent_name:t})}async function Kr(t=40){return(await B("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Br(t,e=20){return B("masc_task_history",{task_id:t,limit:e})}async function qr(){return Me("fetchDebates",async()=>{const t=await pt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!S(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:_(e.status,"open"),argument_count:w(e.argument_count,0),created_at:Wt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Gr(){return Me("fetchCouncilSessions",async()=>{const t=await pt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!S(e))return null;const n=_(e.id,"").trim(),s=_(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:_(e.initiator,"system"),votes:w(e.votes,0),quorum:w(e.quorum,0),state:_(e.state,"open"),created_at:Wt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Wr(t){const e=await B("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Jr(t){return Me("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await pt(`/api/v1/council/debates/${e}/summary`);if(!S(n))return null;const s=_(n.id,"").trim();return s?{id:s,topic:_(n.topic,""),status:_(n.status,"open"),support_count:w(n.support_count,0),oppose_count:w(n.oppose_count,0),neutral_count:w(n.neutral_count,0),total_arguments:w(n.total_arguments,0),created_at:Wt(n.created_at_iso??n.created_at),summary_text:_(n.summary_text,"")}:null})}function Vr(t){const e=_(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function Yr(t){return S(t)?{iteration:ft(t.iteration)??0,metric_before:w(t.metric_before,0),metric_after:w(t.metric_after,0),delta:w(t.delta,0),changes:_(t.changes,""),failed_attempts:_(t.failed_attempts,""),next_suggestion:_(t.next_suggestion,""),elapsed_ms:ft(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function Qr(t){if(!S(t))return null;const e=_(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(Yr).filter(s=>s!==null):[];return{loop_id:e,profile:_(t.profile,"custom"),status:Vr(t.status),current_iteration:ft(t.iteration)??ft(t.current_iteration)??0,max_iterations:ft(t.max_iterations)??0,baseline_metric:w(t.baseline_metric,0),current_metric:w(t.current_metric,w(t.baseline_metric,0)),target:_(t.target,""),stagnation_streak:ft(t.stagnation_streak)??0,stagnation_limit:ft(t.stagnation_limit)??0,elapsed_seconds:w(t.elapsed_seconds,0),history:n}}async function Xr(){try{const t=await B("masc_mdal_status",{}),e=JSON.parse(t);if(S(e)&&_(e.error,"").trim()!=="")return{state:"idle"};const n=Qr(e);return n?{state:"ready",loop:n}:{state:"error"}}catch{return{state:"error"}}}async function Zr(){try{const t=await B("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Rt=f([]),bt=f([]),Pe=f([]),Qt=f([]),Lt=f(null),ee=f(null),bs=f(new Map),Vs=f([]),Se=f("hot"),St=f(!0),Pi=f(null),ct=f(""),Ae=f([]),Ft=f(!1),tt=f(new Map),xs=f(!1),Ce=f(!1),ks=f(!1),zt=f(!1),tl=f(null),ws=f(null),Oi=f(null),ji=f(null),Fi=W(()=>Rt.value.filter(t=>t.status==="active"||t.status==="idle")),Ys=W(()=>{const t=bt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function el(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const nl=W(()=>{const t=new Map;for(const e of Qt.value)t.set(e.name,el(e));return t}),sl=12e4,al=W(()=>{const t=Date.now(),e=new Set,n=bs.value;for(const s of Qt.value){const a=n.get(s.name);a!=null&&t-a>sl&&e.add(s.name)}return e}),ln={},il=5e3;function Ss(){delete ln.compact,delete ln.full}function et(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ae(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function zi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function ol(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function rl(t){if(!et(t))return null;const e=b(t.name);return e?{name:e,status:zi(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:ae(t.traits),interests:ae(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function ll(t){if(!et(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:ol(t.status),priority:A(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function cl(t){if(!et(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",s=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:A(t.seq),from:e,content:n,timestamp:s,type:b(t.type)}}function ul(t){return Array.isArray(t)?t.map(e=>{if(!et(e))return null;const n=A(e.ts_unix);if(n==null)return null;const s=et(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?A(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function dl(t){return(Array.isArray(t)?t:et(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!et(n))return null;const s=et(n.agent)?n.agent:null,a=et(n.context)?n.context:null,i=et(n.metrics_window)?n.metrics_window:void 0,r=b(n.name);if(!r)return null;const l=A(n.context_ratio)??A(a==null?void 0:a.context_ratio),d=b(n.status)??b(s==null?void 0:s.status)??"offline",u=zi(d),v=b(n.model)??b(n.active_model)??b(n.primary_model),c=ae(n.skill_secondary),p=a?{source:b(a.source),context_ratio:A(a.context_ratio),context_tokens:A(a.context_tokens),context_max:A(a.context_max),message_count:A(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,m=s?{name:b(s.name),status:b(s.status),current_task:b(s.current_task)??null,last_seen:b(s.last_seen)}:void 0,g=ul(n.metrics_series);return{name:r,emoji:b(n.emoji),koreanName:b(n.koreanName)??b(n.korean_name),agent_name:b(n.agent_name),trace_id:b(n.trace_id),model:v,primary_model:b(n.primary_model),active_model:b(n.active_model),next_model_hint:b(n.next_model_hint)??null,status:u,last_heartbeat:b(n.last_heartbeat)??b(s==null?void 0:s.last_seen),generation:A(n.generation),turn_count:A(n.turn_count)??A(n.total_turns),context_ratio:l,context_tokens:A(n.context_tokens)??A(a==null?void 0:a.context_tokens),context_max:A(n.context_max)??A(a==null?void 0:a.context_max),context_source:b(n.context_source)??b(a==null?void 0:a.source),context:p,traits:ae(n.traits),interests:ae(n.interests),primaryValue:b(n.primaryValue)??b(n.primary_value),activityLevel:A(n.activityLevel)??A(n.activity_level),memory_recent_note:b(n.memory_recent_note)??null,conversation_tail_count:A(n.conversation_tail_count),k2k_count:A(n.k2k_count),handoff_count_total:A(n.handoff_count_total)??A(n.trace_history_count),compaction_count:A(n.compaction_count),last_compaction_saved_tokens:A(n.last_compaction_saved_tokens),skill_primary:b(n.skill_primary)??null,skill_secondary:c,skill_reason:b(n.skill_reason)??null,metrics_series:g.length>0?g:void 0,metrics_window:i,agent:m}}).filter(n=>n!==null)}async function In(t="full"){var s,a,i;const e=Date.now(),n=ln[t];if(!(n&&e-n.time<il)){xs.value=!0;try{const r=await cr(t);ln[t]={data:r,time:e},Rt.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(rl).filter(l=>l!==null),bt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(ll).filter(l=>l!==null),Pe.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(cl).filter(l=>l!==null),Qt.value=dl(r.keepers),Lt.value=et(r.status)?r.status:null,ee.value=r.perpetual??null,tl.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{xs.value=!1}}}async function ut(){Ce.value=!0;try{const t=await fr(Se.value,{excludeSystem:St.value});Vs.value=t.posts??[],ws.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Ce.value=!1}}async function dt(){var t;ks.value=!0;try{const e=ct.value||((t=Lt.value)==null?void 0:t.room)||"default";ct.value||(ct.value=e);const n=await Lr(e);Pi.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ks.value=!1}}async function ie(){Ft.value=!0;try{const t=await Zr();Ae.value=Array.isArray(t)?t:[],Oi.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Ft.value=!1}}async function oe(){const t=++Fn;zt.value=!0;try{const e=await Xr();if(t!==Fn||e.state==="error")return;if(ji.value=new Date().toISOString(),e.state==="idle"){const i=new Map(tt.value);for(const[r,l]of i.entries())l.status==="running"&&i.set(r,{...l,status:"stopped"});tt.value=i;return}const n=e.loop,s=new Map(tt.value),a=s.get(n.loop_id);s.set(n.loop_id,{...a??{},...n,history:n.history.length>0?n.history:(a==null?void 0:a.history)??[]}),tt.value=s}catch(e){console.error("MDAL fetch error:",e)}finally{t===Fn&&(zt.value=!1)}}let On=null,jn=null,Fn=0;function pl(){return Si.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(bs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),bs.value=n}if(Ss(),On||(On=setTimeout(()=>{In(),On=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(jn||(jn=setTimeout(()=>{ut(),jn=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Ss(),e.type==="mdal_started"&&e.loop_id){const n=new Map(tt.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),tt.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(tt.value),s=e.metric_before??e.metric_after??0,a=e.metric_after??s,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:s,current_metric:a,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:s,metric_after:a,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:a,history:[r,...i.history]}),tt.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(tt.value),s=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...s,current_iteration:e.iteration??s.current_iteration,current_metric:e.metric_after??s.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),tt.value=n}}})}let re=null;function vl(){re||(re=setInterval(()=>{Ss(),In()},1e4))}function ml(){re&&(clearInterval(re),re=null)}function h({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function at({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function fl(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function P({timestamp:t}){const e=fl(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function He(t){return(t??"").trim().toLowerCase()}function Et(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Aa(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Qs(t,e,n,s){const a=He(t),i=e.filter(v=>He(v.assignee)===a&&(v.status==="claimed"||v.status==="in_progress")).length,r=n.filter(v=>He(v.from)===a).sort((v,c)=>Et(c.timestamp)-Et(v.timestamp))[0],l=s.filter(v=>He(v.agent)===a).sort((v,c)=>Et(c.timestamp)-Et(v.timestamp))[0],d=r?Et(r.timestamp):0,u=l?Et(l.timestamp):0;return d===0&&u===0?{activeAssignedCount:i,lastActivityAt:null,lastActivityText:i>0?`${i} claimed tasks`:null}:d>=u&&r?{activeAssignedCount:i,lastActivityAt:r.timestamp,lastActivityText:Aa(r.content)}:{activeAssignedCount:i,lastActivityAt:l?new Date(l.timestamp).toISOString():null,lastActivityText:l?Aa(l.text):null}}const Xs=f(null);function Ui(t){Xs.value=t}function Ca(){Xs.value=null}const Pt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function _l(t){if(!t)return 0;const e=Pt.findIndex(n=>n.level===t);return e>=0?e:0}function gl({keeper:t}){const e=_l(t.autonomy_level),n=Pt[e]??Pt[0];if(!n)return null;const s=(e+1)/Pt.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Pt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Pt.map((a,i)=>o`
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
            <strong><${P} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Ze(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function $l({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Ze(t.context_tokens)}</div>
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
  `}function hl({keeper:t}){var v,c;const e=t.metrics_series??[];if(e.length<2){const p=(((v=t.context)==null?void 0:v.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((p,m)=>{const g=a+m/(i-1)*(n-2*a),x=s-a-(p.context_ratio??0)*(s-2*a);return{x:g,y:x,p}}),l=r.map(({x:p,y:m})=>`${p.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
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
    </div>`}const zn=f("");function yl({keeper:t}){var a,i,r,l;const e=zn.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${zn.value}
        onInput=${d=>{zn.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Ze(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Ze(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Ze(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function bl({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function xl({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function kl({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Na({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Un(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function wl({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Un(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Un(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Un(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Sl({keeperName:t}){const[e,n]=ze("Loading internal monologue..."),[s,a]=ze(""),[i,r]=ze([]),[l,d]=ze(!1),u=async()=>{try{const c=await B("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof c=="string"?c:JSON.stringify(c,null,2))}catch(c){n("Failed to load: "+String(c))}};$t(()=>{u()},[t]);const v=async()=>{if(!s.trim())return;d(!0);const c=s;a(""),r(p=>[...p,{role:"You",text:c}]);try{const p=await B("masc_keeper_msg",{name:t,message:c});r(m=>[...m,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),u()}catch(p){r(m=>[...m,{role:"System",text:"Error: "+String(p)}])}finally{d(!1)}};return o`
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
              onInput=${c=>a(c.currentTarget.value)} 
              onKeyDown=${c=>c.key==="Enter"&&!c.shiftKey&&v()}
              placeholder="Ping the agent..."
              disabled=${l}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${v} 
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
  `}function Al(){var e,n,s;const t=Xs.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Ca()}}
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
            <${at} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ca()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${$l} keeper=${t} />

        ${""}
        <${hl} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${h} title="Field Dictionary">
            <${yl} keeper=${t} />
          <//>

          ${""}
          <${h} title="Profile">
            <${Na} traits=${t.traits??[]} label="Traits" />
            <${Na} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${P} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${h} title="Autonomy">
                <${gl} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${h} title="TRPG Stats">
                <${bl} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${h} title="Equipment (${t.inventory.length})">
                <${xl} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${h} title="Relationships (${Object.keys(t.relationships).length})">
                <${kl} rels=${t.relationships} />
              <//>
            `:null}

          <${h} title="Runtime Signals">
            <${wl} keeper=${t} />
          <//>

          <${h} title="Memory & Context">
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
        <${Sl} keeperName=${t.name} />
      </div>
    </div>
  `:null}let Cl=0;const At=f([]);function y(t,e="success",n=4e3){const s=++Cl;At.value=[...At.value,{id:s,message:t,type:e}],setTimeout(()=>{At.value=At.value.filter(a=>a.id!==s)},n)}function Nl(t){At.value=At.value.filter(e=>e.id!==t)}function Tl(){const t=At.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Nl(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Rl="masc_dashboard_agent_name",Xt=f(null),cn=f(!1),Ne=f(""),un=f([]),Te=f([]),Kt=f(""),le=f(!1);function Hi(t){Xt.value=t,Zs()}function Ta(){Xt.value=null,Ne.value="",un.value=[],Te.value=[],Kt.value=""}function Ll(){const t=Xt.value;return t?Rt.value.find(e=>e.name===t)??null:null}function Ki(t){return t?bt.value.filter(e=>e.assignee===t):[]}async function Zs(){const t=Xt.value;if(t){cn.value=!0,Ne.value="",un.value=[],Te.value=[];try{const e=await Kr(80);un.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Ki(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await Br(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Te.value=s}catch(e){Ne.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{cn.value=!1}}}async function Ra(){var s;const t=Xt.value,e=Kt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Rl))==null?void 0:s.trim())||"dashboard";le.value=!0;try{await Ei(n,`@${t} ${e}`),Kt.value="",y(`Mention sent to ${t}`,"success"),Zs()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";y(i,"error")}finally{le.value=!1}}function Il({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${at} status=${t.status} />
    </div>
  `}function Dl({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function El(){var a,i,r,l;const t=Xt.value;if(!t)return null;const e=Ll(),n=Ki(t),s=un.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Ta()}}
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
                        <${at} status=${e.status} />
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
                    ${e.last_seen?o`<span>Last seen: <${P} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Zs()}} disabled=${cn.value}>
              ${cn.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ta}>Close</button>
          </div>
        </div>

        ${Ne.value?o`<div class="council-error">${Ne.value}</div>`:null}

        <div class="agent-detail-grid">
          <${h} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Il} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${h} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${h} title="Task History">
          ${Te.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Te.value.map(d=>o`<${Dl} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${h} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Kt.value}
              onInput=${d=>{Kt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Ra()}}
              disabled=${le.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ra()}}
              disabled=${le.value||Kt.value.trim()===""}
            >
              ${le.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Mt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Ml({agent:t}){const e=Qs(t.name,bt.value,Pe.value,Gt.value);return o`
    <div class="agent" onClick=${()=>Hi(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${at} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
      ${!t.current_task&&e.activeAssignedCount>0?o`<span class="agent-task">${e.activeAssignedCount} claimed</span>`:null}
      ${e.lastActivityText?o`
            <span class="agent-activity-meta">
              ${e.lastActivityAt?o`<${P} timestamp=${e.lastActivityAt} /> · `:null}
              ${e.lastActivityText}
            </span>
          `:null}
    </div>
  `}function Pl(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function La(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Ol({keeper:t}){var r;const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=nl.value.get(t.name),a=al.value.has(t.name),i=((r=t.agent)==null?void 0:r.current_task)??"No current task";return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>Ui(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${at} status=${t.status} />
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
              <div class="keeper-ctx-fill ${La(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${La(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${Pl(t.context_tokens)})`:null}
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
          </div>
        `:null}

        <div class="keeper-focus-row">${i}</div>

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?o`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${P} timestamp=${t.last_heartbeat} />
          </div>
        `:null}
      </div>
    </div>
  `}function Ia(){var r,l,d,u,v;const t=Lt.value,e=Rt.value,n=Qt.value,s=Ys.value,a=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(l=t==null?void 0:t.monitoring)==null?void 0:l.council;return o`
    <div class="stats-grid">
      <${Mt} label="Agents" value=${e.length} />
      <${Mt} label="Active" value=${Fi.value.length} color="#4ade80" />
      <${Mt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${Mt} label="Tasks" value=${bt.value.length} />
      <${Mt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${Mt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    ${a||i?o`
        <${h} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${Ea(a==null?void 0:a.alert_level)}`}>
                ${Da(a==null?void 0:a.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Ke(a==null?void 0:a.last_activity_age_s)}</span>
                <span>SLO: ≤ ${Ke(a==null?void 0:a.slo_target_age_s)}</span>
                <span>SLO Breach: ${a!=null&&a.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(a==null?void 0:a.new_posts_24h)??0}</span>
                <span>Unanswered: ${(a==null?void 0:a.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${Ea(i==null?void 0:i.alert_level)}`}>
                ${Da(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${Ke(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${Ke(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${h} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(c=>o`<${Ml} key=${c.name} agent=${c} />`)}
        </div>
      <//>

      <${h} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(c=>o`<${Ol} key=${c.name} keeper=${c} />`)}
        </div>
      <//>
    </div>

    ${ee.value?o`
        <${h} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${ee.value.running?"Running":"Stopped"}</span>
            ${ee.value.goal?o`<span>Goal: ${ee.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${h} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${jl(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(v=t.data_quality)!=null&&v.last_sync_at?o`<span>Data Sync: <${P} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function jl(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Ke(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function Da(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Ea(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const Oe=f(null),dn=f(!1),yt=f(null),E=f(!1),pn=f([]);let Fl=1;function M(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function G(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Bi(t){return typeof t=="boolean"?t:void 0}function zl(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ot(t,e=[]){if(Array.isArray(t))return t;if(!M(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Ul(t){return M(t)?{id:k(t.id),seq:G(t.seq),from:k(t.from)??k(t.from_agent)??"system",content:k(t.content)??"",timestamp:k(t.timestamp)??new Date().toISOString(),type:k(t.type)}:null}function Hl(t){return M(t)?{room_id:k(t.room_id),current_room:k(t.current_room)??k(t.room),project:k(t.project),cluster:k(t.cluster),paused:Bi(t.paused),pause_reason:k(t.pause_reason)??null,paused_by:k(t.paused_by)??null,paused_at:k(t.paused_at)??null}:{}}function Ma(t){if(!M(t))return;const e=Object.entries(t).map(([n,s])=>{const a=k(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Kl(t){if(!M(t))return null;const e=M(t.status)?t.status:void 0,n=M(t.summary)?t.summary:M(e==null?void 0:e.summary)?e.summary:void 0,s=M(t.session)?t.session:M(e==null?void 0:e.session)?e.session:void 0,a=k(t.session_id)??k(n==null?void 0:n.session_id)??k(s==null?void 0:s.session_id);if(!a)return null;const i=Ma(t.report_paths)??Ma(e==null?void 0:e.report_paths),r=Ot(t.recent_events,["events"]).filter(M);return{session_id:a,status:k(t.status)??k(n==null?void 0:n.status)??k(s==null?void 0:s.status),progress_pct:G(t.progress_pct)??G(n==null?void 0:n.progress_pct),elapsed_sec:G(t.elapsed_sec)??G(n==null?void 0:n.elapsed_sec),remaining_sec:G(t.remaining_sec)??G(n==null?void 0:n.remaining_sec),done_delta_total:G(t.done_delta_total)??G(n==null?void 0:n.done_delta_total),summary:n,team_health:M(t.team_health)?t.team_health:M(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:M(t.communication_metrics)?t.communication_metrics:M(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:M(t.orchestration_state)?t.orchestration_state:M(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:M(t.cascade_metrics)?t.cascade_metrics:M(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function Bl(t){if(!M(t))return null;const e=k(t.name);if(!e)return null;const n=M(t.context)?t.context:void 0;return{name:e,agent_name:k(t.agent_name),status:k(t.status),autonomy_level:k(t.autonomy_level),context_ratio:G(t.context_ratio)??G(n==null?void 0:n.context_ratio),generation:G(t.generation),active_goal_ids:zl(t.active_goal_ids),last_autonomous_action_at:k(t.last_autonomous_action_at)??null,last_turn_ago_s:G(t.last_turn_ago_s),model:k(t.model)??k(t.active_model)??k(t.primary_model)}}function ql(t){if(!M(t))return null;const e=k(t.confirm_token)??k(t.token);return e?{confirm_token:e,actor:k(t.actor),action_type:k(t.action_type),target_type:k(t.target_type),target_id:k(t.target_id)??null,delegated_tool:k(t.delegated_tool),created_at:k(t.created_at),preview:t.preview}:null}function Gl(t){const e=M(t)?t:{};return{room:Hl(e.room),sessions:Ot(e.sessions,["items","sessions"]).map(Kl).filter(n=>n!==null),keepers:Ot(e.keepers,["items","keepers"]).map(Bl).filter(n=>n!==null),recent_messages:Ot(e.recent_messages,["messages"]).map(Ul).filter(n=>n!==null),pending_confirms:Ot(e.pending_confirms,["items","confirms"]).map(ql).filter(n=>n!==null),available_actions:Ot(e.available_actions,["actions"]).filter(M).map(n=>({action_type:k(n.action_type)??"unknown",target_type:k(n.target_type)??"unknown",description:k(n.description),confirm_required:Bi(n.confirm_required)}))}}function Be(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Pa(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function vn(t){pn.value=[{...t,id:Fl++,at:new Date().toISOString()},...pn.value].slice(0,20)}function qi(t){return t.confirm_required?Be(t.preview)||"Confirmation required":Be(t.result)||Be(t.executed_action)||Be(t.delegated_tool_result)||t.status}async function Jt(){dn.value=!0,yt.value=null;try{const t=await ur();Oe.value=Gl(t)}catch(t){yt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{dn.value=!1}}async function Wl(t){E.value=!0,yt.value=null;try{const e=await dr(t);return vn({actor:t.actor,action_type:t.action_type,target_label:Pa(t),outcome:e.confirm_required?"preview":"executed",message:qi(e),delegated_tool:e.delegated_tool}),await Jt(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw yt.value=n,vn({actor:t.actor,action_type:t.action_type,target_label:Pa(t),outcome:"error",message:n}),e}finally{E.value=!1}}async function Jl(t,e){E.value=!0,yt.value=null;try{const n=await pr(t,e);return vn({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:qi(n),delegated_tool:n.delegated_tool}),await Jt(),n}catch(n){const s=n instanceof Error?n.message:"Operator confirmation failed";throw yt.value=s,vn({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:s}),n}finally{E.value=!1}}const Gi="masc_dashboard_agent_name";function Vl(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Gi))==null?void 0:s.trim())||"dashboard"}const Dn=f(Vl()),ce=f(""),As=f("Operator pause"),ue=f(""),mn=f(""),Cs=f("2"),fn=f(""),Bt=f("note"),_n=f(""),gn=f(""),$n=f(""),Ns=f("2"),Ts=f("Operator stop request"),Rs=f(""),de=f("");function Yl(t){const e=t.trim()||"dashboard";Dn.value=e,localStorage.setItem(Gi,e)}function Oa(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Ql(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}async function It(t){const e=Dn.value.trim()||"dashboard";try{const n=await Wl({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?y("Confirmation queued","warning"):y(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";return y(s,"error"),null}}async function ja(){const t=ce.value.trim();if(!t)return;await It({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(ce.value="")}async function Xl(){await It({action_type:"room_pause",target_type:"room",payload:{reason:As.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function Zl(){await It({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function tc(){const t=ue.value.trim();if(!t)return;await It({action_type:"task_inject",target_type:"room",payload:{title:t,description:mn.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Cs.value,10)||2},successMessage:"Task injection submitted"})&&(ue.value="",mn.value="")}async function ec(){var i;const t=Oe.value,e=fn.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){y("Select a team session first","warning");return}const n={turn_kind:Bt.value},s=_n.value.trim();s&&(n.message=s),Bt.value==="task"&&(n.task_title=gn.value.trim()||"Operator injected task",n.task_description=$n.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Ns.value,10)||2),await It({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(_n.value="",Bt.value==="task"&&(gn.value="",$n.value=""))}async function nc(){var n;const t=Oe.value,e=fn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){y("Select a team session first","warning");return}await It({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Ts.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function sc(){var a;const t=Oe.value,e=Rs.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=de.value.trim();if(!e){y("Select a keeper first","warning");return}if(!n)return;await It({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(de.value="")}async function ac(t){const e=Dn.value.trim()||"dashboard";try{await Jl(e,t),y("Confirmation executed","success")}catch(n){const s=n instanceof Error?n.message:"Confirmation failed";y(s,"error")}}function ic(){var d;$t(()=>{Jt()},[]);const t=Oe.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],s=(t==null?void 0:t.keepers)??[],a=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(u=>u.session_id===fn.value)??n[0]??null,l=s.find(u=>u.name===Rs.value)??s[0]??null;return o`
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
            value=${Dn.value}
            onInput=${u=>Yl(u.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Jt()}} disabled=${dn.value||E.value}>
            ${dn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${yt.value?o`
        <section class="ops-banner error">${yt.value}</section>
      `:null}

      ${a.length>0?o`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <div class="ops-confirmation-list">
            ${a.map(u=>o`
              <article key=${u.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${u.action_type??"unknown"}</strong>
                  <span>${u.target_type??"target"}${u.target_id?`:${u.target_id}`:""}</span>
                  <span>${u.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${u.preview?o`<pre class="ops-code-block">${Oa(u.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{ac(u.confirm_token)}} disabled=${E.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${u.confirm_token}</span>
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
              value=${ce.value}
              onInput=${u=>{ce.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&ja()}}
              disabled=${E.value}
            />
            <button class="control-btn" onClick=${()=>{ja()}} disabled=${E.value||ce.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${As.value}
              onInput=${u=>{As.value=u.target.value}}
              disabled=${E.value}
            />
            <button class="control-btn ghost" onClick=${()=>{Xl()}} disabled=${E.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{Zl()}} disabled=${E.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${ue.value}
            onInput=${u=>{ue.value=u.target.value}}
            disabled=${E.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${mn.value}
            onInput=${u=>{mn.value=u.target.value}}
            disabled=${E.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Cs.value}
              onChange=${u=>{Cs.value=u.target.value}}
              disabled=${E.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{tc()}} disabled=${E.value||ue.value.trim()===""}>
              Inject
            </button>
          </div>

          ${i.length>0?o`
            <div class="ops-section-head">Recent Messages</div>
            <div class="ops-feed-list">
              ${i.slice(0,6).map(u=>o`
                <article key=${u.seq??u.id??u.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${u.from}</strong>
                    <span>${u.timestamp}</span>
                  </div>
                  <div class="ops-feed-content">${u.content}</div>
                </article>
              `)}
            </div>
          `:null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
          <div class="ops-entity-list">
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(u=>{var v;return o`
              <button
                key=${u.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===u.session_id?"active":""}"
                onClick=${()=>{fn.value=u.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${u.session_id}</strong>
                  <span class="status-badge ${u.status??"idle"}">${u.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(u.progress_pct??0)}%</span>
                  <span>${u.done_delta_total??0} done</span>
                  <span>${(v=u.team_health)!=null&&v.status?String(u.team_health.status):"health n/a"}</span>
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
                <pre class="ops-code-block compact">${Oa(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Bt.value}
              onChange=${u=>{Bt.value=u.target.value}}
              disabled=${E.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{ec()}} disabled=${E.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${_n.value}
            onInput=${u=>{_n.value=u.target.value}}
            disabled=${E.value||!r}
          ></textarea>
          ${Bt.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${gn.value}
              onInput=${u=>{gn.value=u.target.value}}
              disabled=${E.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${$n.value}
              onInput=${u=>{$n.value=u.target.value}}
              disabled=${E.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Ns.value}
              onChange=${u=>{Ns.value=u.target.value}}
              disabled=${E.value||!r}
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
              value=${Ts.value}
              onInput=${u=>{Ts.value=u.target.value}}
              disabled=${E.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{nc()}} disabled=${E.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${s.length===0?o`<div class="ops-empty">No keepers available.</div>`:s.map(u=>o`
              <button
                key=${u.name}
                class="ops-entity-card ${(l==null?void 0:l.name)===u.name?"active":""}"
                onClick=${()=>{Rs.value=u.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${u.name}</strong>
                  <span class="status-badge ${u.status??"idle"}">${u.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${u.model??"model n/a"}</span>
                  <span>${typeof u.context_ratio=="number"?`${Math.round(u.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${Ql(u.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${l?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${l.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${l.autonomy_level??"n/a"}</span>
                <span>Generation: ${l.generation??0}</span>
                <span>Goals: ${((d=l.active_goal_ids)==null?void 0:d.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${de.value}
            onInput=${u=>{de.value=u.target.value}}
            disabled=${E.value||!l}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{sc()}} disabled=${E.value||!l||de.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${pn.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:pn.value.map(u=>o`
            <article key=${u.id} class="ops-log-entry ${u.outcome}">
              <div class="ops-log-head">
                <strong>${u.action_type}</strong>
                <span>${u.target_label}</span>
                <span>${u.at}</span>
              </div>
              <div class="ops-log-body">${u.message}</div>
            </article>
          `)}
        </div>
      </section>
    </section>
  `}const Ls=f([]),Is=f([]),pe=f(""),hn=f(!1),ve=f(!1),Re=f(""),yn=f(null),Z=f(null),Ds=f(!1);async function Es(){hn.value=!0,Re.value="";try{const[t,e]=await Promise.all([qr(),Gr()]);Ls.value=t,Is.value=e}catch(t){Re.value=t instanceof Error?t.message:"Failed to load council data"}finally{hn.value=!1}}async function Fa(){const t=pe.value.trim();if(t){ve.value=!0;try{const e=await Wr(t);pe.value="",y(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Es()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";y(n,"error")}finally{ve.value=!1}}}async function oc(t){yn.value=t,Ds.value=!0,Z.value=null;try{Z.value=await Jr(t)}catch(e){Re.value=e instanceof Error?e.message:"Failed to load debate status",Z.value=null}finally{Ds.value=!1}}function rc({debate:t}){const e=yn.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>oc(t.id)}
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
  `}function lc({session:t}){return o`
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
  `}function cc(){var e;const t=(e=Lt.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${P} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function uc(){var e,n;$t(()=>{Es()},[]);const t=((n=(e=Lt.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${cc} />
      <${h} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${pe.value}
            onInput=${s=>{pe.value=s.target.value}}
            onKeyDown=${s=>{s.key==="Enter"&&Fa()}}
            disabled=${ve.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Fa}
            disabled=${ve.value||pe.value.trim()===""}
          >
            ${ve.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Es} disabled=${hn.value}>
            ${hn.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Re.value?o`<div class="council-error">${Re.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${h} title="Debates" class="section">
          <div class="council-list">
            ${Ls.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:Ls.value.map(s=>o`<${rc} key=${s.id} debate=${s} />`)}
          </div>
        <//>

        <${h} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Is.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Is.value.map(s=>o`<${lc} key=${s.id} session=${s} />`)}
          </div>
        <//>
      </div>

      <${h} title=${yn.value?`Debate Detail (${yn.value})`:"Debate Detail"} class="section">
        ${Ds.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Z.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${Z.value.status}</span>
                  <span>Total arguments: ${Z.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${Z.value.support_count}</span>
                  <span>Oppose: ${Z.value.oppose_count}</span>
                  <span>Neutral: ${Z.value.neutral_count}</span>
                </div>
                ${Z.value.summary_text?o`<pre class="council-detail">${Z.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function dc({text:t}){if(!t)return null;const e=pc(t);return o`<div class="markdown-content">${e}</div>`}function pc(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Hn(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${Hn(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${Hn(i.join(`
`))}</p>`)}return n}function Hn(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Wi=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],tn=f(null),me=f([]),Nt=f(!1),Ct=f(null),fe=f("");function vc(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const mc=f(vc()),_e=f(!1);async function ta(t){Ct.value=t,tn.value=null,me.value=[],Nt.value=!0;try{const e=await _r(t);if(Ct.value!==t)return;tn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},me.value=e.comments??[]}catch{Ct.value===t&&(tn.value=null,me.value=[])}finally{Ct.value===t&&(Nt.value=!1)}}async function za(t){const e=fe.value.trim();if(e){_e.value=!0;try{await gr(t,mc.value,e),fe.value="",y("Comment posted","success"),await ta(t),ut()}catch{y("Failed to post comment","error")}finally{_e.value=!1}}}function fc(){const t=Se.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Wi.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Se.value=e.id,ut()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${St.value?"is-active":""}"
          onClick=${()=>{St.value=!St.value,ut()}}
        >
          ${St.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${ut} disabled=${Ce.value}>
          ${Ce.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Kn(){var e;const t=(e=Lt.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${P} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Ji({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function _c(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Ua(t){return t.updated_at!==t.created_at}function Bn(){var n;const t=((n=Wi.find(s=>s.id===Se.value))==null?void 0:n.label)??Se.value,e=Vs.value.length;return o`
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
        <strong>${St.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${ws.value?o`<${P} timestamp=${ws.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function gc({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Di(t.id,n),ut()}catch{y("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Bo(t.id)}>
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
              <${Ji} flair=${t.flair} />
              ${Ua(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${P} timestamp=${t.created_at} /></span>
            ${Ua(t)?o`<span>Updated <${P} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${_c(t.content)}</div>
      </div>
    </div>
  `}function $c({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${P} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function hc({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${fe.value}
        onInput=${e=>{fe.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&za(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${_e.value}
      />
      <button
        onClick=${()=>za(t)}
        disabled=${_e.value||fe.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${_e.value?"...":"Post"}
      </button>
    </div>
  `}function yc({post:t}){Ct.value!==t.id&&!Nt.value&&ta(t.id);const e=async n=>{try{await Di(t.id,n),ut()}catch{y("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Rn("board")}>← Back to Board</button>
      <${h} title=${o`${t.title} <${Ji} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${dc} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${P} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${h} title="Comments (${Nt.value?"...":me.value.length})">
        ${Nt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${$c} comments=${me.value} />`}
        <${hc} postId=${t.id} />
      <//>
    </div>
  `}function bc(){var a,i;const t=Vs.value,e=Ce.value,n=st.value.postId,s=((i=(a=Lt.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(l=>l.id===n)??(Ct.value===n?tn.value:null);return!r&&Ct.value!==n&&!Nt.value&&ta(n),r?o`
          <${Kn} />
          <${Bn} />
          <${yc} post=${r} />
        `:o`
          <div>
            <${Kn} />
            <${Bn} />
            <button class="back-btn" onClick=${()=>Rn("board")}>← Back to Board</button>
            ${Nt.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${s?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${Kn} />
    <${Bn} />
    <${fc} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${s?"No posts loaded (board feed degraded). Check board contract sync.":St.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${gc} key=${r.id} post=${r} />`)}
          </div>`}
  `}const Vi=120,Ms=f("all"),xc={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},kc={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function wc(t){if(t.kind)return t.kind;const e=t.text;return e==="New post"||e==="New comment"?"board":e.startsWith("Task:")?"tasks":e.startsWith("Heartbeat")||e.startsWith("Handoff")||e.startsWith("Compaction")||e.startsWith("Guardrail")?"keepers":"system"}function Sc(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Ac(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",kind:wc(t),actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function bn(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Ps=W(()=>{const t=Pe.value.map(Sc),e=Gt.value.map(Ac);return[...t,...e].sort((n,s)=>bn(s.timestamp)-bn(n.timestamp))}),Cc=W(()=>{const t=Ps.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Nc=W(()=>{const t=Ms.value;return(t==="all"?Ps.value:Ps.value.filter(n=>n.kind===t)).slice(0,Vi)}),Tc=W(()=>Rt.value.map(t=>({agent:t,motion:Qs(t.name,bt.value,Pe.value,Gt.value)})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:bn(e.motion.lastActivityAt??0)-bn(t.motion.lastActivityAt??0)}));function Rc(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function te({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Lc({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Rc(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${kc[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Ic(){const t=Cc.value,e=Nc.value,n=e[0],s=Tc.value;return o`
    <div class="stats-grid">
      <${te} label="Visible rows" value=${e.length} />
      <${te} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${te} label="Tracked keeper events" value=${t.keepers} color="#4ade80" />
      <${te} label="Tracked board events" value=${t.board} color="#fbbf24" />
      <${te} label="SSE events" value=${Ln.value} color="#c084fc" />
    </div>

    <${h} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(a=>o`
            <button
              class="goal-filter-btn ${Ms.value===a?"active":""}"
              onClick=${()=>{Ms.value=a}}
            >
              ${xc[a]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${ht.value?"":"pill-stale"}">
            ${ht.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${P} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${Vi} rows</span>
          <span>Journal merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for events...</div>`:e.map(a=>o`<${Lc} key=${a.id} row=${a} />`)}
      </div>
    <//>

    <${h} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(({agent:a,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${a.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${P} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Yi({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
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
  `}function Dc({agent:t}){const e=Qs(t.name,bt.value,Pe.value,Gt.value);return o`
    <button class="agent-card ${t.status}" onClick=${()=>Hi(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${Yi} ratio=${t.context_ratio} />
        <${at} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:e.activeAssignedCount>0?o`<div class="agent-task">${e.activeAssignedCount} claimed tasks</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
      ${e.lastActivityText?o`
            <div class="agent-activity-meta">
              ${e.lastActivityAt?o`<${P} timestamp=${e.lastActivityAt} /> · `:null}
              ${e.lastActivityText}
            </div>
          `:null}
    </button>
  `}function Ec(t){return typeof t.context_ratio!="number"||Number.isNaN(t.context_ratio)?"—":`${Math.round(t.context_ratio*100)}%`}function Mc(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??"No active focus"}function Pc(t){return[`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`,`Compactions ${t.compaction_count??0}`].join(" · ")}function Oc({keeper:t}){return o`
    <div class="live-agent keeper-card" onClick=${()=>Ui(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Yi} ratio=${t.context_ratio} />
        <${at} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Context</span>
            <strong class="keeper-core-value">${Ec(t)}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Generation</span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Heartbeat</span>
            <strong class="keeper-core-value">
              ${t.last_heartbeat?o`<${P} timestamp=${t.last_heartbeat} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Model</span>
            <strong class="keeper-core-value">${t.model??"—"}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Focus</span>
            <strong class="keeper-core-value keeper-core-text">${Mc(t)}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Continuity</span>
            <strong class="keeper-core-value">${Pc(t)}</strong>
          </div>
        </div>
      </div>
    </div>
  `}function jc(){const t=Rt.value,e=Qt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${Oc} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${Dc} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function qn({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${P} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Fc(){const{todo:t,inProgress:e,done:n}=Ys.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${qn} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${qn} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${qn} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function zc(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function Gn({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${zc(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${P} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function Uc(){const t=Ys.value,e=t.inProgress,n=t.todo,s=t.done,a=Fi.value,i=n.filter(l=>(l.priority??3)<=2),r=n.filter(l=>!l.assignee);return o`
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
      <${h} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(l=>o`<${Gn} key=${l.id} task=${l} />`)}
        </div>
      <//>

      <${h} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(l=>o`<${Gn} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${h} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(l=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${l.name}</div>
                    <div class="council-sub">
                      ${l.current_task?o`<span>${l.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${at} status=${l.status} />
                </div>
              `)}
        </div>
      <//>

      <${h} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(l=>o`<${Gn} key=${l.id} task=${l} />`)}
        </div>
      <//>
    </div>
  `}const xn=f("all"),kn=f("all"),Os=W(()=>{let t=Ae.value;return xn.value!=="all"&&(t=t.filter(e=>e.horizon===xn.value)),kn.value!=="all"&&(t=t.filter(e=>e.status===kn.value)),t}),Hc=W(()=>{const t={short:[],mid:[],long:[]};for(const e of Os.value){const n=t[e.horizon];n&&n.push(e)}return t}),Kc=W(()=>{const t=Array.from(tt.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Bc(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function ea(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function en(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function qc(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Ha(t){return t.toFixed(4)}function Ka(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Gc({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${en(t.horizon)}">
            ${ea(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Bc(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${P} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${at} status=${t.status} />
        <div class="goal-updated">
          <${P} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Ba({label:t,timestamp:e,source:n}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${P} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Wn({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${h} title="${ea(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${Gc} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Wc(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${xn.value===t?"active":""}"
            onClick=${()=>{xn.value=t}}
          >
            ${t==="all"?"All":ea(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${kn.value===t?"active":""}"
            onClick=${()=>{kn.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Jc(){const t=Ae.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${en("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${en("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${en("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Vc({loop:t}){const e=t.history[0];return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${at} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Ha(t.baseline_metric)}</span>
          <span>Current ${Ha(t.current_metric)}</span>
          <span class=${Ka(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Ka(t)}
          </span>
          <span>Elapsed ${qc(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function Yc(){$t(()=>{ie(),oe()},[]);const t=Hc.value,e=Kc.value,n=e.filter(a=>a.status==="running").length,s=Ae.value.filter(a=>a.status==="active").length;return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Os.value.length}</div>
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

      <${h} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>masc_mdal_status</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${ie} disabled=${Ft.value}>
              ${Ft.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${oe} disabled=${zt.value}>
              ${zt.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{ie(),oe()}}
              disabled=${Ft.value||zt.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Ba} label="Goals" timestamp=${Oi.value} source="masc_goal_list" />
          <${Ba} label="MDAL loops" timestamp=${ji.value} source="masc_mdal_status" />
        </div>
      <//>

      <${h} title="Goal Pipeline" class="section">
        <${Jc} />
        <${Wc} />
      <//>

      ${Ft.value&&Ae.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Os.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${Wn} horizon="short" items=${t.short??[]} />
              <${Wn} horizon="mid" items=${t.mid??[]} />
              <${Wn} horizon="long" items=${t.long??[]} />
            `}

      <${h} title="MDAL Loops" class="section">
        ${zt.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0?o`
                <div class="empty-state">
                  No loop snapshot is visible right now. This section only changes when the backend exposes a current MDAL loop.
                </div>
              `:o`
                <div class="planning-loop-list">
                  ${e.map(a=>o`<${Vc} key=${a.loop_id} loop=${a} />`)}
                </div>
              `}
      <//>
    </div>
  `}const jt=f(""),Jn=f("ability_check"),Vn=f("10"),Yn=f("12"),qe=f(""),Ge=f("idle"),mt=f(""),We=f("keeper-late"),Qn=f("player"),Xn=f(""),V=f("idle"),Zn=f(null),Je=f(""),ts=f(""),es=f("player"),ns=f(""),ss=f(""),as=f(""),ge=f("20"),is=f("20"),os=f(""),Ve=f("idle"),js=f(null),Qi=f("overview"),rs=f("all"),ls=f("all"),cs=f("all"),Qc=12e4,En=f(null),qa=f(Date.now());function Xc(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Zc(t,e){return e>0?Math.round(t/e*100):0}const tu={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},eu={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Ye(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function nu(t){const e=t.trim().toLowerCase();return tu[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function su(t){const e=t.trim().toLowerCase();return eu[e]??"상황에 따라 선택되는 전술 액션입니다."}function gt(t){return typeof t=="object"&&t!==null}function q(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function it(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Le(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const au=new Set(["str","dex","con","int","wis","cha"]);function iu(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!gt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const l=Number.parseFloat(i.trim());if(Number.isFinite(l)){s[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function ou(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(ge.value.trim(),10);Number.isFinite(s)&&s>n&&(ge.value=String(n))}function Fs(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function ru(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function lu(t){Qi.value=t}function Xi(t){const e=En.value;return e==null||e<=t}function cu(t){const e=En.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function wn(){En.value=null}function Zi(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function uu(t,e){Zi(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(En.value=Date.now()+Qc,y("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function nn(t){return Xi(t)?(y("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function zs(t,e,n){return Zi([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function du({hp:t,max:e}){const n=Zc(t,e),s=Xc(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function pu({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function vu({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function to({actor:t}){var d,u,v,c;const e=(d=t.archetype)==null?void 0:d.trim(),n=(u=t.persona)==null?void 0:u.trim(),s=(v=t.portrait)==null?void 0:v.trim(),a=(c=t.background)==null?void 0:c.trim(),i=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([p,m])=>Number.isFinite(m)).filter(([p])=>!au.has(p.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${p=>{const m=p.target;m&&(m.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${at} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${vu} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${du} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${pu} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Ye(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([p,m])=>o`
                <span class="trpg-custom-stat-chip">${Ye(p)} ${m}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(p=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Ye(p)}</span>
                  <span class="trpg-annot-desc">${nu(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(p=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Ye(p)}</span>
                  <span class="trpg-annot-desc">${su(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function mu({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function eo({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${ru(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Fs(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${P} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function fu({events:t}){const e="__none__",n=rs.value,s=ls.value,a=cs.value,i=Array.from(new Set(t.map(Fs).map(c=>c.trim()).filter(c=>c!==""))).sort((c,p)=>c.localeCompare(p)),r=Array.from(new Set(t.map(c=>(c.type??"").trim()).filter(c=>c!==""))).sort((c,p)=>c.localeCompare(p)),l=t.some(c=>(c.type??"").trim()===""),d=Array.from(new Set(t.map(c=>(c.phase??"").trim()).filter(c=>c!==""))).sort((c,p)=>c.localeCompare(p)),u=t.some(c=>(c.phase??"").trim()===""),v=t.filter(c=>{if(n!=="all"&&Fs(c)!==n)return!1;const p=(c.type??"").trim(),m=(c.phase??"").trim();if(s===e){if(p!=="")return!1}else if(s!=="all"&&p!==s)return!1;if(a===e){if(m!=="")return!1}else if(a!=="all"&&m!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${c=>{rs.value=c.target.value}}>
          <option value="all">all</option>
          ${i.map(c=>o`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${c=>{ls.value=c.target.value}}>
          <option value="all">all</option>
          ${l?o`<option value=${e}>(none)</option>`:null}
          ${r.map(c=>o`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${c=>{cs.value=c.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${d.map(c=>o`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{rs.value="all",ls.value="all",cs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${v.length} / 전체 ${t.length}
      </span>
    </div>
    <${eo} events=${v.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function _u({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function no({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function gu({state:t,nowMs:e}){var u;const n=ct.value||((u=t.session)==null?void 0:u.room)||"",s=Ge.value,a=t.party??[];if(!a.find(v=>v.id===jt.value)&&a.length>0){const v=a[0];v&&(jt.value=v.id)}const r=async()=>{var c,p;if(!n){y("Room ID가 비어 있습니다.","error");return}if(!nn(e))return;const v=((c=t.current_round)==null?void 0:c.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(zs("라운드 실행",n,v)){Ge.value="running";try{const m=await Ir(n);js.value=m,Ge.value="ok";const g=gt(m.summary)?m.summary:null,x=g?Le(g,"advanced",!1):!1,C=g?q(g,"progress_reason",""):"";y(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,x?"success":"warning"),dt()}catch(m){js.value=null,Ge.value="error";const g=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";y(g,"error")}finally{wn()}}},l=async()=>{var c,p;if(!n||!nn(e))return;const v=((c=t.current_round)==null?void 0:c.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(zs("턴 강제 진행",n,v))try{await Mr(n),y("턴을 다음 단계로 이동했습니다.","success"),dt()}catch{y("턴 이동에 실패했습니다.","error")}finally{wn()}},d=async()=>{if(!n||!nn(e))return;const v=jt.value.trim();if(!v){y("먼저 Actor를 선택하세요.","warning");return}const c=Number.parseInt(Vn.value,10),p=Number.parseInt(Yn.value,10);if(Number.isNaN(c)||Number.isNaN(p)){y("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(qe.value,10),g=qe.value.trim()===""||Number.isNaN(m)?void 0:m;try{await Er({roomId:n,actorId:v,action:Jn.value.trim()||"ability_check",statValue:c,dc:p,rawD20:g}),y("주사위 판정을 기록했습니다.","success"),dt()}catch{y("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${v=>{ct.value=v.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${jt.value}
            onChange=${v=>{jt.value=v.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(v=>o`<option value=${v.id}>${v.name} (${v.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Jn.value}
              onInput=${v=>{Jn.value=v.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Vn.value}
              onInput=${v=>{Vn.value=v.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Yn.value}
              onInput=${v=>{Yn.value=v.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${qe.value}
              onInput=${v=>{qe.value=v.target.value}}
              onKeyDown=${v=>{v.key==="Enter"&&d()}}
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
              disabled=${s==="running"}
            >
              ${s==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${l}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function $u({state:t}){var a;const e=ct.value||((a=t.session)==null?void 0:a.room)||"",n=Ve.value,s=async()=>{if(!e){y("Room ID가 비어 있습니다.","warning");return}const i=Je.value.trim(),r=ts.value.trim();if(!r&&!i){y("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(ge.value.trim(),10),d=Number.parseInt(is.value.trim(),10),u=Number.isFinite(d)?Math.max(1,d):20,v=Number.isFinite(l)?Math.max(0,Math.min(u,l)):u;let c={};try{c=iu(os.value)}catch(p){y(p instanceof Error?p.message:"능력치 JSON 오류","error");return}Ve.value="spawning";try{const p=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await Pr(e,{actor_id:i||void 0,name:r||void 0,role:es.value,idempotencyKey:p,portrait:ss.value.trim()||void 0,background:as.value.trim()||void 0,hp:v,max_hp:u,alive:v>0,stats:Object.keys(c).length>0?c:void 0}),g=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!g)throw new Error("생성 응답에 actor_id가 없습니다.");const x=ns.value.trim();x&&await Or(e,g,x),jt.value=g,mt.value=g,i||(Je.value=""),Ve.value="ok",y(`Actor 생성 완료: ${g}`,"success"),await dt()}catch(p){Ve.value="error",y(p instanceof Error?p.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ts.value}
            onInput=${i=>{ts.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${es.value}
            onChange=${i=>{es.value=i.target.value}}
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
            value=${ns.value}
            onInput=${i=>{ns.value=i.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${s} disabled=${n==="spawning"}>
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
              value=${Je.value}
              onInput=${i=>{Je.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${ss.value}
              onInput=${i=>{ss.value=i.target.value}}
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
              value=${ge.value}
              onInput=${i=>{ge.value=i.target.value}}
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
              value=${is.value}
              onInput=${i=>{const r=i.target.value;is.value=r,ou(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${as.value}
              onInput=${i=>{as.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${os.value}
              onInput=${i=>{os.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function hu({state:t,nowMs:e}){var p;const n=ct.value||((p=t.session)==null?void 0:p.room)||"",s=t.join_gate,a=Zn.value,i=gt(a)?a:null,r=(t.party??[]).filter(m=>m.role!=="dm"),l=mt.value.trim(),d=r.some(m=>m.id===l),u=d?l:l?"__manual__":"",v=async()=>{const m=mt.value.trim(),g=We.value.trim();if(!n||!m){y("Room/Actor가 필요합니다.","warning");return}V.value="checking";try{const x=await jr(n,m,g||void 0);Zn.value=x,V.value="ok",y("참가 가능 여부를 갱신했습니다.","success")}catch(x){V.value="error";const C=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";y(C,"error")}},c=async()=>{var T,N;const m=mt.value.trim(),g=We.value.trim(),x=Xn.value.trim();if(!n||!m||!g){y("Room/Actor/Keeper가 필요합니다.","warning");return}if(!nn(e))return;const C=((T=t.current_round)==null?void 0:T.phase)??((N=t.session)==null?void 0:N.status)??"unknown";if(zs("Mid-Join 승인 요청",n,C)){V.value="requesting";try{const O=await Fr({room_id:n,actor_id:m,keeper_name:g,role:Qn.value,...x?{name:x}:{}});Zn.value=O;const H=gt(O)?Le(O,"granted",!1):!1,D=gt(O)?q(O,"reason_code",""):"";H?y("Mid-Join이 승인되었습니다.","success"):y(`Mid-Join이 거절되었습니다${D?`: ${D}`:""}`,"warning"),V.value=H?"ok":"error",dt()}catch(O){V.value="error";const H=O instanceof Error?O.message:"Mid-Join 요청에 실패했습니다.";y(H,"error")}finally{wn()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${s!=null&&s.phase_open?"OPEN":"CLOSED"}</strong>
        ${s!=null&&s.window?o`<span style="margin-left:8px;">(${s.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(s==null?void 0:s.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${u}
            onChange=${m=>{const g=m.target.value;if(g==="__manual__"){(d||!l)&&(mt.value="");return}mt.value=g}}
          >
            <option value="">Actor 선택</option>
            ${r.map(m=>o`
              <option value=${m.id}>${m.name} (${m.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${u==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${mt.value}
                onInput=${m=>{mt.value=m.target.value}}
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
            value=${We.value}
            onInput=${m=>{We.value=m.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Qn.value}
            onChange=${m=>{Qn.value=m.target.value}}
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
            value=${Xn.value}
            onInput=${m=>{Xn.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${v} disabled=${V.value==="checking"||V.value==="requesting"}>
              ${V.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${c} disabled=${V.value==="checking"||V.value==="requesting"}>
              ${V.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Le(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${it(i,"effective_score",0)}/${it(i,"required_points",0)}</span>
            ${q(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${q(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function so({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function ao({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function io(){const t=js.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=gt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(gt).slice(-8),i=t.canon_check,r=gt(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],u=n?Le(n,"advanced",!1):!1,v=n?q(n,"progress_reason",""):"",c=n?q(n,"progress_detail",""):"",p=n?it(n,"player_successes",0):0,m=n?it(n,"player_required_successes",0):0,g=n?Le(n,"dm_success",!1):!1,x=n?it(n,"timeouts",0):0,C=n?it(n,"unavailable",0):0,T=n?it(n,"reprompts",0):0,N=n?it(n,"npc_attacks",0):0,O=n?it(n,"keeper_timeout_sec",0):0,H=n?it(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${g?"DM ok":"DM stalled"} / players ${p}/${m}
          </span>
        </div>
        ${v?o`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${c?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${O||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${H}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(D=>{const Y=q(D,"status","unknown"),xt=q(D,"actor_id","-"),kt=q(D,"role","-"),Q=q(D,"reason",""),rt=q(D,"action_type",""),L=q(D,"reply","");return o`
                <div class="trpg-round-item ${Y.includes("fallback")||Y.includes("timeout")?"failed":"active"}">
                  <span>${xt} (${kt})</span>
                  <span style="margin-left:auto; font-size:11px;">${Y}</span>
                  ${rt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${rt}</div>`:null}
                  ${Q?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Q}</div>`:null}
                  ${L?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${L.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${q(r,"status","unknown")}</strong>
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
  `}function yu({state:t,nowMs:e}){var r,l,d;const n=ct.value||((r=t.session)==null?void 0:r.room)||"",s=((l=t.current_round)==null?void 0:l.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=Xi(e),i=cu(e);return o`
    <${h} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>uu(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{wn(),y("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function bu({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>lu(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function xu({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${h} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${h} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${eo} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${h} title="맵" style="margin-top:16px;">
              <${mu} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${h} title="현재 라운드">
          <${ao} state=${t} />
        <//>

        <${h} title="기여도" style="margin-top:16px;">
          <${so} state=${t} />
        <//>

        <${h} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${to} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${h} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${no} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function ku({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${h} title=${`이벤트 타임라인 (${e.length})`}>
          <${fu} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${h} title="최근 라운드 결과">
          <${io} />
        <//>

        <${h} title="현재 라운드" style="margin-top:16px;">
          <${ao} state=${t} />
        <//>
      </div>
    </div>
  `}function wu({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${yu} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${h} title="조작 패널">
            <${gu} state=${t} nowMs=${e} />
          <//>

          <${h} title="Actor Spawn" style="margin-top:16px;">
            <${$u} state=${t} />
          <//>

          <${h} title="Mid-Join Gate" style="margin-top:16px;">
            <${hu} state=${t} nowMs=${e} />
          <//>

          <${h} title="최근 라운드 결과" style="margin-top:16px;">
            <${io} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${h} title="기여도" style="margin-top:0;">
            <${so} state=${t} />
          <//>

          <${h} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${to} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${h} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${no} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Su(){var l,d,u,v,c;const t=Pi.value,e=ks.value;if($t(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const p=window.setInterval(()=>{qa.value=Date.now()},1e3);return()=>{window.clearInterval(p)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>dt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=Qi.value,r=qa.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${ct.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((u=t.session)==null?void 0:u.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>dt()}>새로고침</button>
      </div>

      <${_u} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((v=t.session)==null?void 0:v.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((c=t.current_round)==null?void 0:c.round_number)??0}</div>
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

      <${bu} active=${i} />

      ${i==="overview"?o`<${xu} state=${t} />`:i==="timeline"?o`<${ku} state=${t} />`:o`<${wu} state=${t} nowMs=${r} />`}
    </div>
  `}const na="masc_dashboard_agent_name";function Au(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(na);return e??n??"dashboard"}const nt=f(Au()),$e=f(""),he=f(""),Sn=f(""),ye=f(!1),Ut=f(!1),be=f(!1),xe=f(!1),An=f(!1),Mn=f(!1);function sa(t){const e=t.trim();nt.value=e,e&&localStorage.setItem(na,e)}function Cu(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Us(){const t=nt.value.trim();if(t){be.value=!0;try{const e=await Ur(t),n=Cu(e);n&&sa(n),Mn.value=!0,y(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";y(n,"error")}finally{be.value=!1}}}async function Nu(){const t=nt.value.trim();if(t){xe.value=!0;try{await Mi(t),Mn.value=!1,y(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";y(n,"error")}finally{xe.value=!1}}}async function Tu(){const t=nt.value.trim();if(t)try{await Mi(t)}catch{}localStorage.removeItem(na),sa("dashboard"),Mn.value=!1,await Us()}async function Ru(){const t=nt.value.trim();if(t){An.value=!0;try{await Hr(t),y("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";y(n,"error")}finally{An.value=!1}}}async function Ga(){const t=nt.value.trim(),e=$e.value.trim();if(!(!t||!e)){ye.value=!0;try{await Ei(t,e),$e.value="",y("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";y(s,"error")}finally{ye.value=!1}}}async function Lu(){const t=he.value.trim(),e=Sn.value.trim()||"Created from dashboard";if(t){Ut.value=!0;try{await zr(t,e,1),he.value="",Sn.value="",y("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";y(s,"error")}finally{Ut.value=!1}}}function Iu(){return $t(()=>{Us()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${nt.value}
        onInput=${t=>sa(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${$e.value}
          onInput=${t=>{$e.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Ga()}}
          disabled=${ye.value}
        />
        <button
          class="control-btn"
          onClick=${Ga}
          disabled=${ye.value||$e.value.trim()===""||nt.value.trim()===""}
        >
          ${ye.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Us()}}
          disabled=${be.value||nt.value.trim()===""}
        >
          ${be.value?"Joining...":Mn.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Nu()}}
          disabled=${xe.value||nt.value.trim()===""}
        >
          ${xe.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Tu()}}
          disabled=${be.value||xe.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Ru()}}
          disabled=${An.value||nt.value.trim()===""}
        >
          ${An.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${he.value}
        onInput=${t=>{he.value=t.target.value}}
        disabled=${Ut.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${Sn.value}
        onInput=${t=>{Sn.value=t.target.value}}
        disabled=${Ut.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${Lu}
        disabled=${Ut.value||he.value.trim()===""}
      >
        ${Ut.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}const oo={overview:"Room health, keeper pressure, and top-line execution status",board:"Human and agent discussion feed with system noise filtered by default",activity:"Unified live stream for messages, task changes, board events, and keeper events",council:"Debates, quorum status, and decision flow",goals:"Goals and MDAL loops in one planning surface with freshness signals",execution:"Queue readiness and assignee coverage",tasks:"Kanban-style task distribution",agents:"Operational directory for agents and keepers",ops:"Guided operator controls for room, sessions, and keepers",trpg:"Narrative room control and state visibility"};function Du(){const t=ht.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Ln.value} events</span>
    </div>
  `}function Eu(){const t=st.value.tab,e=ht.value,n=$s.find(s=>s.id===t);return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${$s.map(s=>o`
            <button
              class="rail-tab-btn ${t===s.id?"active":""}"
              onClick=${()=>Rn(s.id)}
            >
              ${s.icon} ${s.label}
            </button>
          `)}
        </div>
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${oo[t]??"Live operational view"}</p>
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
            <strong>${Rt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Qt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${bt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Ln.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{In(),t==="ops"&&Jt(),t==="board"&&ut(),t==="trpg"&&dt(),t==="goals"&&(ie(),oe())}}
        >
          Refresh Now
        </button>
      </section>

      <${Iu} />
    </aside>
  `}function Mu(){switch(st.value.tab){case"overview":return o`<${Ia} />`;case"ops":return o`<${ic} />`;case"council":return o`<${uc} />`;case"board":return o`<${bc} />`;case"execution":return o`<${Uc} />`;case"activity":return o`<${Ic} />`;case"agents":return o`<${jc} />`;case"tasks":return o`<${Fc} />`;case"goals":return o`<${Yc} />`;case"trpg":return o`<${Su} />`;default:return o`<${Ia} />`}}function Pu(){$t(()=>{qo(),Ci(),In();const e=pl();return vl(),()=>{Zo(),e(),ml()}},[]),$t(()=>{const e=st.value.tab;e==="ops"&&Jt(),e==="board"&&ut(),e==="trpg"&&dt(),e==="goals"&&(ie(),oe())},[st.value.tab]);const t=st.value.tab;return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${oo[t]??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <${Du} />
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${Go} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${xs.value&&!ht.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Mu} />`}
        </main>
        <${Eu} />
      </div>

      <${Al} />
      <${El} />
      <${Tl} />
    </div>
  `}const Wa=document.getElementById("app");Wa&&Co(o`<${Pu} />`,Wa);
