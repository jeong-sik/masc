(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var Le,A,fs,ms,ot,On,_s,gs,$s,xn,Qe,tn,Wt={},hs=[],Ca=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,De=Array.isArray;function tt(t,e){for(var n in e)t[n]=e[n];return t}function kn(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function ys(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Le.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return de(t,r,s,a,null)}function de(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++fs,__i:-1,__u:0};return a==null&&A.vnode!=null&&A.vnode(i),i}function Zt(t){return t.children}function Rt(t,e){this.props=t,this.context=e}function ht(t,e){if(e==null)return t.__?ht(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?ht(t):null}function bs(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return bs(t)}}function Fn(t){(!t.__d&&(t.__d=!0)&&ot.push(t)&&!_e.__r++||On!=A.debounceRendering)&&((On=A.debounceRendering)||_s)(_e)}function _e(){for(var t,e,n,s,a,i,r,l=1;ot.length;)ot.length>l&&ot.sort(gs),t=ot.shift(),l=ot.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=tt({},s)).__v=s.__v+1,A.vnode&&A.vnode(n),wn(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??ht(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,ws(i,n,r),s.__e=s.__=null,n.__e!=a&&bs(n)));_e.__r=0}function xs(t,e,n,s,a,i,r,l,d,u,v){var c,p,f,b,T,R,S,k=s&&s.__k||hs,O=e.length;for(d=Aa(n,e,k,d,O),c=0;c<O;c++)(f=n.__k[c])!=null&&(p=f.__i==-1?Wt:k[f.__i]||Wt,f.__i=c,R=wn(t,f,p,a,i,r,l,d,u,v),b=f.__e,f.ref&&p.ref!=f.ref&&(p.ref&&Sn(p.ref,null,f),v.push(f.ref,f.__c||b,f)),T==null&&b!=null&&(T=b),(S=!!(4&f.__u))||p.__k===f.__k?d=ks(f,d,t,S):typeof f.type=="function"&&R!==void 0?d=R:b&&(d=b.nextSibling),f.__u&=-7);return n.__e=T,d}function Aa(t,e,n,s,a){var i,r,l,d,u,v=n.length,c=v,p=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=de(null,r,null,null,null):De(r)?r=t.__k[i]=de(Zt,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=de(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+p,r.__=t,r.__b=t.__b+1,l=null,(u=r.__i=Ta(r,n,d,c))!=-1&&(c--,(l=n[u])&&(l.__u|=2)),l==null||l.__v==null?(u==-1&&(a>v?p--:a<v&&p++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?p--:u==d+1?p++:(u>d?p--:p++,r.__u|=4))):t.__k[i]=null;if(c)for(i=0;i<v;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=ht(l)),Cs(l,l));return s}function ks(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=ks(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=ht(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Ta(t,e,n,s){var a,i,r,l=t.key,d=t.type,u=e[n],v=u!=null&&(2&u.__u)==0;if(u===null&&l==null||v&&l==u.key&&d==u.type)return n;if(s>(v?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((u=e[r=a>=0?a--:i++])!=null&&(2&u.__u)==0&&l==u.key&&d==u.type)return r}return-1}function Hn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Ca.test(e)?n:n+"px"}function ae(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||Hn(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||Hn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace($s,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=xn,t.addEventListener(e,i?tn:Qe,i)):t.removeEventListener(e,i?tn:Qe,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Un(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=xn++;else if(e.t<n.u)return;return n(A.event?A.event(e):e)}}}function wn(t,e,n,s,a,i,r,l,d,u){var v,c,p,f,b,T,R,S,k,O,K,L,G,at,it,q,Q,C=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[l=e.__e=n.__e]),(v=A.__b)&&v(e);t:if(typeof C=="function")try{if(S=e.props,k="prototype"in C&&C.prototype.render,O=(v=C.contextType)&&s[v.__c],K=v?O?O.props.value:v.__:s,n.__c?R=(c=e.__c=n.__c).__=c.__E:(k?e.__c=c=new C(S,K):(e.__c=c=new Rt(S,K),c.constructor=C,c.render=Ra),O&&O.sub(c),c.state||(c.state={}),c.__n=s,p=c.__d=!0,c.__h=[],c._sb=[]),k&&c.__s==null&&(c.__s=c.state),k&&C.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=tt({},c.__s)),tt(c.__s,C.getDerivedStateFromProps(S,c.__s))),f=c.props,b=c.state,c.__v=e,p)k&&C.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),k&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(k&&C.getDerivedStateFromProps==null&&S!==f&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(S,K),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(S,c.__s,K)===!1){for(e.__v!=n.__v&&(c.props=S,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(P){P&&(P.__=e)}),L=0;L<c._sb.length;L++)c.__h.push(c._sb[L]);c._sb=[],c.__h.length&&r.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(S,c.__s,K),k&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(f,b,T)})}if(c.context=K,c.props=S,c.__P=t,c.__e=!1,G=A.__r,at=0,k){for(c.state=c.__s,c.__d=!1,G&&G(e),v=c.render(c.props,c.state,c.context),it=0;it<c._sb.length;it++)c.__h.push(c._sb[it]);c._sb=[]}else do c.__d=!1,G&&G(e),v=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++at<25);c.state=c.__s,c.getChildContext!=null&&(s=tt(tt({},s),c.getChildContext())),k&&!p&&c.getSnapshotBeforeUpdate!=null&&(T=c.getSnapshotBeforeUpdate(f,b)),q=v,v!=null&&v.type===Zt&&v.key==null&&(q=Ss(v.props.children)),l=xs(t,De(q)?q:[q],e,n,s,a,i,r,l,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&r.push(c),R&&(c.__E=c.__=null)}catch(P){if(e.__v=null,d||i!=null)if(P.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(Q=i.length;Q--;)kn(i[Q]);en(e)}else e.__e=n.__e,e.__k=n.__k,P.then||en(e);A.__e(P,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=Na(n.__e,e,n,s,a,i,r,d,u);return(v=A.diffed)&&v(e),128&e.__u?void 0:l}function en(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(en)}function ws(t,e,n){for(var s=0;s<n.length;s++)Sn(n[s],n[++s],n[++s]);A.__c&&A.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){A.__e(i,a.__v)}})}function Ss(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:De(t)?t.map(Ss):tt({},t)}function Na(t,e,n,s,a,i,r,l,d){var u,v,c,p,f,b,T,R=n.props||Wt,S=e.props,k=e.type;if(k=="svg"?a="http://www.w3.org/2000/svg":k=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((f=i[u])&&"setAttribute"in f==!!k&&(k?f.localName==k:f.nodeType==3)){t=f,i[u]=null;break}}if(t==null){if(k==null)return document.createTextNode(S);t=document.createElementNS(a,k,S.is&&S),l&&(A.__m&&A.__m(e,i),l=!1),i=null}if(k==null)R===S||l&&t.data==S||(t.data=S);else{if(i=i&&Le.call(t.childNodes),!l&&i!=null)for(R={},u=0;u<t.attributes.length;u++)R[(f=t.attributes[u]).name]=f.value;for(u in R)if(f=R[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=f;else if(!(u in S)){if(u=="value"&&"defaultValue"in S||u=="checked"&&"defaultChecked"in S)continue;ae(t,u,null,f,a)}}for(u in S)f=S[u],u=="children"?p=f:u=="dangerouslySetInnerHTML"?v=f:u=="value"?b=f:u=="checked"?T=f:l&&typeof f!="function"||R[u]===f||ae(t,u,f,R[u],a);if(v)l||c&&(v.__html==c.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(c&&(t.innerHTML=""),xs(e.type=="template"?t.content:t,De(p)?p:[p],e,n,s,k=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&ht(n,0),l,d),i!=null)for(u=i.length;u--;)kn(i[u]);l||(u="value",k=="progress"&&b==null?t.removeAttribute("value"):b!=null&&(b!==t[u]||k=="progress"&&!b||k=="option"&&b!=R[u])&&ae(t,u,b,R[u],a),u="checked",T!=null&&T!=t[u]&&ae(t,u,T,R[u],a))}return t}function Sn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){A.__e(a,n)}}function Cs(t,e,n){var s,a;if(A.unmount&&A.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||Sn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){A.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&Cs(s[a],e,n||typeof t.type!="function");n||kn(t.__e),t.__c=t.__=t.__e=void 0}function Ra(t,e,n){return this.constructor(t,n)}function La(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),A.__&&A.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],wn(e,t=e.__k=ys(Zt,null,[t]),a||Wt,Wt,e.namespaceURI,a?null:e.firstChild?Le.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),ws(i,t,r)}Le=hs.slice,A={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},fs=0,ms=function(t){return t!=null&&t.constructor===void 0},Rt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=tt({},this.state),typeof t=="function"&&(t=t(tt({},n),this.props)),t&&tt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Fn(this))},Rt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Fn(this))},Rt.prototype.render=Zt,ot=[],_s=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,gs=function(t,e){return t.__v.__b-e.__v.__b},_e.__r=0,$s=/(PointerCapture)$|Capture$/i,xn=0,Qe=Un(!1),tn=Un(!0);var As=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++i]]=l:r===6?s[1][e[++i]]+=l+"":r?(a=t.apply(l,As(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},Bn=new Map;function Da(t){var e=Bn.get(this);return e||(e=new Map,Bn.set(this,e)),(e=As(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",l="",d=[0],u=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,p,r):i===3&&(p||r)?(d.push(3,p,r),i=2):i===2&&r==="..."&&p?d.push(4,p,0):i===2&&r&&!p?d.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(d.push(i,0,r,a),i=6),p&&(d.push(i,p,0,a),i=6)),r=""},v=0;v<n.length;v++){v&&(i===1&&u(),u(v));for(var c=0;c<n[v].length;c++)s=n[v][c],i===1?s==="<"?(u(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(u(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[v][c+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Da.bind(ys),Jt,D,ze,Kn,nn=0,Ts=[],E=A,Gn=E.__b,qn=E.__r,Wn=E.diffed,Jn=E.__c,Vn=E.unmount,Yn=E.__;function Cn(t,e){E.__h&&E.__h(D,t,nn||e),nn=0;var n=D.__H||(D.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function ie(t){return nn=1,Ea(Ls,t)}function Ea(t,e,n){var s=Cn(Jt++,2);if(s.t=t,!s.__c&&(s.__=[Ls(void 0,e),function(l){var d=s.__N?s.__N[0]:s.__[0],u=s.t(d,l);d!==u&&(s.__N=[u,s.__[1]],s.__c.setState({}))}],s.__c=D,!D.__f)){var a=function(l,d,u){if(!s.__c.__H)return!0;var v=s.__c.__H.__.filter(function(p){return!!p.__c});if(v.every(function(p){return!p.__N}))return!i||i.call(this,l,d,u);var c=s.__c.props!==l;return v.forEach(function(p){if(p.__N){var f=p.__[0];p.__=p.__N,p.__N=void 0,f!==p.__[0]&&(c=!0)}}),i&&i.call(this,l,d,u)||c};D.__f=!0;var i=D.shouldComponentUpdate,r=D.componentWillUpdate;D.componentWillUpdate=function(l,d,u){if(this.__e){var v=i;i=void 0,a(l,d,u),i=v}r&&r.call(this,l,d,u)},D.shouldComponentUpdate=a}return s.__N||s.__}function yt(t,e){var n=Cn(Jt++,3);!E.__s&&Rs(n.__H,e)&&(n.__=t,n.u=e,D.__H.__h.push(n))}function Ns(t,e){var n=Cn(Jt++,7);return Rs(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Pa(){for(var t;t=Ts.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(pe),t.__H.__h.forEach(sn),t.__H.__h=[]}catch(e){t.__H.__h=[],E.__e(e,t.__v)}}E.__b=function(t){D=null,Gn&&Gn(t)},E.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Yn&&Yn(t,e)},E.__r=function(t){qn&&qn(t),Jt=0;var e=(D=t.__c).__H;e&&(ze===D?(e.__h=[],D.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(pe),e.__h.forEach(sn),e.__h=[],Jt=0)),ze=D},E.diffed=function(t){Wn&&Wn(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(Ts.push(e)!==1&&Kn===E.requestAnimationFrame||((Kn=E.requestAnimationFrame)||Ma)(Pa)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),ze=D=null},E.__c=function(t,e){e.some(function(n){try{n.__h.forEach(pe),n.__h=n.__h.filter(function(s){return!s.__||sn(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],E.__e(s,n.__v)}}),Jn&&Jn(t,e)},E.unmount=function(t){Vn&&Vn(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{pe(s)}catch(a){e=a}}),n.__H=void 0,e&&E.__e(e,n.__v))};var Xn=typeof requestAnimationFrame=="function";function Ma(t){var e,n=function(){clearTimeout(s),Xn&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);Xn&&(e=requestAnimationFrame(n))}function pe(t){var e=D,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),D=e}function sn(t){var e=D;t.__c=t.__(),D=e}function Rs(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function Ls(t,e){return typeof e=="function"?e(t):e}var Ia=Symbol.for("preact-signals");function Ee(){if(nt>1)nt--;else{for(var t,e=!1;Lt!==void 0;){var n=Lt;for(Lt=void 0,an++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Ps(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(an=0,nt--,e)throw t}}function ja(t){if(nt>0)return t();nt++;try{return t()}finally{Ee()}}var w=void 0;function Ds(t){var e=w;w=void 0;try{return t()}finally{w=e}}var Lt=void 0,nt=0,an=0,ge=0;function Es(t){if(w!==void 0){var e=t.n;if(e===void 0||e.t!==w)return e={i:0,S:t,p:w.s,n:void 0,t:w,e:void 0,x:void 0,r:e},w.s!==void 0&&(w.s.n=e),w.s=e,t.n=e,32&w.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=w.s,e.n=void 0,w.s.n=e,w.s=e),e}}function I(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}I.prototype.brand=Ia;I.prototype.h=function(){return!0};I.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Ds(function(){var s;(s=e.W)==null||s.call(e)}))};I.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&Ds(function(){var a;(a=e.Z)==null||a.call(e)}))}};I.prototype.subscribe=function(t){var e=this;return Qt(function(){var n=e.value,s=w;w=void 0;try{t(n)}finally{w=s}},{name:"sub"})};I.prototype.valueOf=function(){return this.value};I.prototype.toString=function(){return this.value+""};I.prototype.toJSON=function(){return this.value};I.prototype.peek=function(){var t=w;w=void 0;try{return this.value}finally{w=t}};Object.defineProperty(I.prototype,"value",{get:function(){var t=Es(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(an>100)throw new Error("Cycle detected");this.v=t,this.i++,ge++,nt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Ee()}}}});function _(t,e){return new I(t,e)}function Ps(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Ms(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Is(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function ut(t,e){I.call(this,void 0),this.x=t,this.s=void 0,this.g=ge-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}ut.prototype=new I;ut.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ge))return!0;if(this.g=ge,this.f|=1,this.i>0&&!Ps(this))return this.f&=-2,!0;var t=w;try{Ms(this),w=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return w=t,Is(this),this.f&=-2,!0};ut.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}I.prototype.S.call(this,t)};ut.prototype.U=function(t){if(this.t!==void 0&&(I.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};ut.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(ut.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Es(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function st(t,e){return new ut(t,e)}function js(t){var e=t.u;if(t.u=void 0,typeof e=="function"){nt++;var n=w;w=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,An(t),s}finally{w=n,Ee()}}}function An(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,js(t)}function za(t){if(w!==this)throw new Error("Out-of-order effect");Is(this),w=t,this.f&=-2,8&this.f&&An(this),Ee()}function xt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}xt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};xt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,js(this),Ms(this),nt++;var t=w;return w=this,za.bind(this,t)};xt.prototype.N=function(){2&this.f||(this.f|=2,this.o=Lt,Lt=this)};xt.prototype.d=function(){this.f|=8,1&this.f||An(this)};xt.prototype.dispose=function(){this.d()};function Qt(t,e){var n=new xt(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var zs,oe,Oa=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Os=[];Qt(function(){zs=this.N})();function kt(t,e){A[t]=e.bind(null,A[t]||function(){})}function $e(t){if(oe){var e=oe;oe=void 0,e()}oe=t&&t.S()}function Fs(t){var e=this,n=t.data,s=Ha(n);s.value=n;var a=Ns(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=st(function(){var f=s.value.value;return f===0?0:f===!0?"":f||""}),v=st(function(){return!Array.isArray(u.value)&&!ms(u.value)}),c=Qt(function(){if(this.N=Hs,v.value){var f=u.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=f)}}),p=e.__$u.d;return e.__$u.d=function(){c(),p.call(this)},[v,u]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}Fs.displayName="ReactiveTextNode";Object.defineProperties(I.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Fs},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});kt("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof I&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});kt("__r",function(t,e){if(t(e),e.type!==Zt){$e();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return Qt(function(){r=this},{name:i}),r.c=a,r})(function(){var a;Oa&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),$e(n)}});kt("__e",function(t,e,n,s){$e(),t(e,n,s)});kt("diffed",function(t,e){$e();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in s)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var u=i[d],v=s[d];u===void 0?(u=Fa(n,d,v),i[d]=u):u.o(v,a)}for(var c in s)a[c]=s[c]}}t(e)});function Fa(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(l,d){i.value=l,r=l.peek()},d:Qt(function(){this.N=Hs;var l=i.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}kt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});kt("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});Rt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function Ha(t,e){return Ns(function(){return _(t,e)},[])}var Ua=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Ba(){ja(function(){for(var t;t=Os.shift();)zs.call(t)})}function Hs(){Os.push(this)===1&&(A.requestAnimationFrame||Ua)(Ba)}const Ka=["overview","board","activity","agents","tasks","goals","journal","trpg","council"],Us={tab:"overview",params:{},postId:null};function Zn(t){return!!t&&Ka.includes(t)}function on(t){try{return decodeURIComponent(t)}catch{return t}}function rn(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Ga(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Bs(t,e){const n=t[0],s=e.tab,a=Zn(n)?n:Zn(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=on(t[2]):t[0]==="post"&&t[1]&&(i=on(t[1]))),{tab:a,params:e,postId:i}}function he(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Us;const n=on(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=rn(a),r=Ga(s);return Bs(r,i)}function qa(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Us,params:rn(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=rn(e.replace(/^\?/,""));return Bs(s,a)}function Ks(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const Z=_(he(window.location.hash));window.addEventListener("hashchange",()=>{Z.value=he(window.location.hash)});function Pe(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Ks(n)}function Wa(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Ja(){if(window.location.hash&&window.location.hash!=="#"){Z.value=he(window.location.hash);return}const t=qa(window.location.pathname,window.location.search);if(t){Z.value=t;const e=Ks(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Z.value=he(window.location.hash)}const Va=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function Ya(){const t=Z.value.tab;return o`
    <div class="main-tab-bar">
      ${Va.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Pe(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Qn="masc_dashboard_sse_session_id",Xa=1e3,Za=15e3,bt=_(!1),Tn=_(0),Gs=_(null),ye=_([]);function Qa(){let t=sessionStorage.getItem(Qn);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Qn,t)),t}const ti=200;function W(t,e){const n={agent:t,text:e,timestamp:Date.now()};ye.value=[n,...ye.value].slice(0,ti)}let X=null,_t=null,ln=0;function qs(){_t&&(clearTimeout(_t),_t=null)}function ei(){if(_t)return;ln++;const t=Math.min(ln,5),e=Math.min(Za,Xa*Math.pow(2,t));_t=setTimeout(()=>{_t=null,Ws()},e)}function Ws(){qs(),X&&(X.close(),X=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Qa());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);X=i,i.onopen=()=>{X===i&&(ln=0,bt.value=!0)},i.onerror=()=>{X===i&&(bt.value=!1,i.close(),X=null,ei())},i.onmessage=r=>{try{const l=JSON.parse(r.data);Tn.value++,Gs.value=l,ni(l)}catch{}}}function ni(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":W(n,"Joined");break;case"agent_left":W(n,"Left");break;case"broadcast":W(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":W(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":W(n,"New post");break;case"board_comment":W(n,"New comment");break;case"keeper_heartbeat":W(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":W(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":W(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":W(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:W(n,e)}}function si(){qs(),X&&(X.close(),X=null),bt.value=!1}function Js(){return new URLSearchParams(window.location.search)}function Vs(){const t=Js(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Ys(){return{...Vs(),"Content-Type":"application/json"}}const ai=15e3,Xs=3e4,ii=6e4;async function Nn(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(a)}}function oi(){var e,n;const t=Js();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function te(t){const e=await Nn(t,{headers:Vs()},ai);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function ee(t,e){const n=await Nn(t,{method:"POST",headers:Ys(),body:JSON.stringify(e)},Xs);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function ri(t,e,n,s=Xs){const a=await Nn(t,{method:"POST",headers:{...Ys(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function li(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function ci(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function j(t,e){const n=await ri("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},ii),s=li(n);return ci(s)}function Zs(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function ui(t="compact"){return te(`/api/v1/dashboard?mode=${t}`)}function di(t){const n=new URLSearchParams().toString();return te(`/api/v1/board${n?`?${n}`:""}`)}function pi(t){return te(`/api/v1/board/${t}`)}function Qs(t,e){return ee("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:oi()})}function vi(t,e,n){return ee("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function fi(t){const e=m(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function z(...t){for(const e of t){const n=m(e,"");if(n.trim())return n.trim()}return""}function ts(t){const e=fi(z(t.outcome,t.result,t.result_code));if(!e)return;const n=z(t.reason,t.reason_code,t.description,t.detail),s=z(t.summary,t.summary_ko,t.summary_en,t.note),a=z(t.details,t.details_text,t.text,t.note),i=z(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=z(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=z(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(p=>{if(typeof p=="string")return p.trim();if(N(p)){const f=m(p.summary,"").trim();if(f)return f;const b=m(p.text,"").trim();if(b)return b;const T=m(p.type,"").trim();return T||m(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),u=(()=>{const c=M(t.turn,Number.NaN);if(Number.isFinite(c))return c;const p=M(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const f=M(t.current_turn,Number.NaN);if(Number.isFinite(f))return f;const b=M(t.round,Number.NaN);return Number.isFinite(b)?b:void 0})(),v=z(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:l||void 0,turn:u,phase:v||void 0}}function mi(t,e){const n=N(t.state)?t.state:{};if(m(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>N(r)?m(r.type,"")==="session.outcome":!1),i=N(n.session_outcome)?n.session_outcome:{};if(N(i)&&Object.keys(i).length>0){const r=ts(i);if(r)return r}if(N(a))return ts(N(a.payload)?a.payload:{})}function N(t){return typeof t=="object"&&t!==null}function m(t,e=""){return typeof t=="string"?t:e}function M(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function _i(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function cn(t,e=!1){return typeof t=="boolean"?t:e}function At(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(N(e)){const n=m(e.name,"").trim(),s=m(e.id,"").trim(),a=m(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function gi(t){const e={};if(!N(t)&&!Array.isArray(t))return e;if(N(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=m(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!N(n))continue;const s=z(n.to,n.target,n.actor_id,n.name,n.id),a=z(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function $i(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function H(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}function hi(t,e){if(t!=="dice.rolled")return;const n=M(e.raw_d20,0),s=M(e.total,0),a=M(e.bonus,0),i=m(e.action,"roll"),r=M(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function yi(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function bi(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function xi(t,e,n,s){const a=n||e||m(s.actor_id,"")||m(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=m(s.proposed_action,m(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=m(s.reply,m(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return m(s.reply,m(s.content,m(s.text,"Narration")));case"dice.rolled":{const i=m(s.action,"roll"),r=M(s.total,0),l=M(s.dc,0),d=m(s.label,""),u=a||"actor",v=l>0?` vs DC ${l}`:"",c=d?` (${d})`:"";return`${u} ${i}: ${r}${v}${c}`}case"turn.started":return`Turn ${M(s.turn,1)} started`;case"phase.changed":return`Phase: ${m(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${m(s.name,a||"unknown")}`;case"actor.claimed":return`${m(s.keeper_name,m(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${m(s.keeper_name,m(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${M(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${M(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||m(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||m(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${m(s.reason_code,"unknown")}`;case"memory.signal":{const i=N(s.entity_refs)?s.entity_refs:{},r=m(i.requested_tier,""),l=m(i.effective_tier,""),d=cn(i.guardrail_applied,!1),u=m(s.summary_en,m(s.summary_ko,"Memory signal"));if(!r&&!l)return u;const v=r&&l?`${r}->${l}`:l||r;return`${u} [${v}${d?" (guardrail)":""}]`}case"world.event":{if(m(s.event_type,"")==="canon.check"){const r=m(s.status,"unknown"),l=m(s.contract_id,"n/a");return`Canon ${r}: ${l}`}return m(s.description,m(s.summary,"World event"))}case"combat.attack":return m(s.summary,m(s.result,"Attack resolved"));case"combat.defense":return m(s.summary,m(s.result,"Defense resolved"));case"session.outcome":return m(s.summary,m(s.outcome,"Session ended"));default:{const i=yi(s);return i?`${t}: ${i}`:t}}}function ki(t,e){const n=N(t)?t:{},s=m(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=m(n.actor_name,"").trim()||e[a]||m(N(n.payload)?n.payload.actor_name:"",""),r=N(n.payload)?n.payload:{},l=m(n.ts,m(n.timestamp,new Date().toISOString())),d=m(n.phase,m(r.phase,"")),u=m(n.category,"");return{type:s,actor:i||a||m(r.actor_name,""),actor_id:a||m(r.actor_id,""),actor_name:i,seq:n.seq,room_id:m(n.room_id,""),phase:d||void 0,category:u||bi(s),visibility:m(n.visibility,m(r.visibility,"public")),event_id:m(n.event_id,""),content:xi(s,a,i,r),dice_roll:hi(s,r),timestamp:l}}function wi(t,e,n){var q,Q;const s=m(t.room_id,"")||n||"default",a=N(t.state)?t.state:{},i=N(a.party)?a.party:{},r=N(a.actor_control)?a.actor_control:{},l=N(a.join_gate)?a.join_gate:{},d=N(a.contribution_ledger)?a.contribution_ledger:{},u=Object.entries(i).map(([C,P])=>{const g=N(P)?P:{},se=H(g,"max_hp",void 0,10),In=H(g,"hp",void 0,se),fa=H(g,"max_mp",void 0,0),ma=H(g,"mp",void 0,0),_a=H(g,"level",void 0,1),ga=H(g,"xp",void 0,0),$a=cn(g.alive,In>0),jn=r[C],zn=typeof jn=="string"?jn:void 0,ha=$i(g.role,C,zn),ya=_i(g.generation),ba=z(g.joined_at,g.joinedAt,g.started_at,g.startedAt),xa=z(g.claimed_at,g.claimedAt,g.assigned_at,g.assignedAt,g.assigned_time),ka=z(g.last_seen,g.lastSeen,g.last_seen_at,g.lastSeenAt,g.last_active,g.lastActive),wa=z(g.scene,g.current_scene,g.currentScene,g.world_scene,g.scene_name,g.sceneName),Sa=z(g.location,g.current_location,g.currentLocation,g.position,g.zone,g.area);return{id:C,name:m(g.name,C),role:ha,keeper:zn,archetype:m(g.archetype,""),persona:m(g.persona,""),traits:At(g.traits),skills:At(g.skills),status:$a?"active":"dead",generation:ya,joined_at:ba||void 0,claimed_at:xa||void 0,last_seen:ka||void 0,scene:wa||void 0,location:Sa||void 0,inventory:At(g.inventory),notes:At(g.notes),relationships:gi(g.relationships),stats:{hp:In,max_hp:se,mp:ma,max_mp:fa,level:_a,xp:ga,strength:H(g,"strength","str",10),dexterity:H(g,"dexterity","dex",10),constitution:H(g,"constitution","con",10),intelligence:H(g,"intelligence","int",10),wisdom:H(g,"wisdom","wis",10),charisma:H(g,"charisma","cha",10)}}}),v=u.filter(C=>C.status!=="dead"),c=mi(t,e),p={phase_open:cn(l.phase_open,!0),min_points:M(l.min_points,3),window:m(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},f=Object.entries(d).map(([C,P])=>{const g=N(P)?P:{};return{actor_id:C,score:M(g.score,0),last_reason:m(g.last_reason,"")||null,reasons:At(g.reasons)}}),b=u.reduce((C,P)=>(C[P.id]=P.name,C),{}),T=e.map(C=>ki(C,b)),R=M(a.turn,1),S=m(a.phase,"round"),k=m(a.map,""),O=N(a.world)?a.world:{},K=k||m(O.ascii_map,m(O.map,"")),L=T.filter((C,P)=>{const g=e[P];if(!N(g))return!1;const se=N(g.payload)?g.payload:{};return M(se.turn,-1)===R}),G=(L.length>0?L:T).slice(-12),at=m(a.status,"active");return{session:{id:s,room:s,status:at==="ended"?"ended":at==="paused"?"paused":"active",round:R,actors:v,created_at:((q=T[0])==null?void 0:q.timestamp)??new Date().toISOString()},current_round:{round_number:R,phase:S,events:G,timestamp:((Q=T[T.length-1])==null?void 0:Q.timestamp)??new Date().toISOString()},map:K||void 0,join_gate:p,contribution_ledger:f,outcome:c,party:v,story_log:T,history:[]}}async function Si(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await te(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ci(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([te(`/api/v1/trpg/state${e}`),Si(t)]);return wi(n,s,t)}function Ai(t){return ee("/api/v1/trpg/rounds/run",{room_id:t})}function Ti(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Ni(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),ee("/api/v1/trpg/dice/roll",e)}function Ri(t,e){const n=Ti();return ee("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function Li(t,e,n){const s=await j("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Di(t){const e=await j("trpg.mid_join.request",t);return JSON.parse(e)}async function ta(t,e){await j("masc_broadcast",{agent_name:t,message:e})}async function Ei(t,e,n=1){await j("masc_add_task",{title:t,description:e,priority:n})}async function Pi(t){return j("masc_join",{agent_name:t})}async function ea(t){await j("masc_leave",{agent_name:t})}async function Mi(t){await j("masc_heartbeat",{agent_name:t})}async function Ii(t=40){return(await j("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function ji(t,e=20){return j("masc_task_history",{task_id:t,limit:e})}async function zi(){const t=await j("masc_debates",{});return Zs(t)}async function Oi(){const t=await j("masc_sessions",{});return Zs(t)}async function Fi(t){const e=await j("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function Hi(t){return j("masc_debate_status",{debate_id:t})}async function Ui(){try{const t=await j("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const wt=_([]),ne=_([]),na=_([]),St=_([]),Rn=_(null),Nt=_(null),un=_(new Map),sa=_([]),es=_("hot"),aa=_(null),gt=_(""),Me=_([]),Dt=_(!1),dn=_(!1),pn=_(!1),vn=_(!1),Bi=st(()=>wt.value.filter(t=>t.status==="active"||t.status==="idle")),ia=st(()=>{const t=ne.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Ki(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Gi=st(()=>{const t=new Map;for(const e of St.value)t.set(e.name,Ki(e));return t}),qi=12e4,Wi=st(()=>{const t=Date.now(),e=new Set,n=un.value;for(const s of St.value){const a=n.get(s.name);a!=null&&t-a>qi&&e.add(s.name)}return e}),be={},Ji=5e3;function fn(){delete be.compact,delete be.full}function J(t){return typeof t=="object"&&t!==null}function $(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function h(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Et(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function oa(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Vi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Yi(t){if(!J(t))return null;const e=$(t.name);return e?{name:e,status:oa(t.status),current_task:$(t.current_task)??null,last_seen:$(t.last_seen),emoji:$(t.emoji),koreanName:$(t.koreanName)??$(t.korean_name),model:$(t.model),traits:Et(t.traits),interests:Et(t.interests),activityLevel:h(t.activityLevel)??h(t.activity_level),primaryValue:$(t.primaryValue)??$(t.primary_value)}:null}function Xi(t){if(!J(t))return null;const e=$(t.id),n=$(t.title);return!e||!n?null:{id:e,title:n,status:Vi(t.status),priority:h(t.priority),assignee:$(t.assignee),description:$(t.description),created_at:$(t.created_at),updated_at:$(t.updated_at)}}function Zi(t){if(!J(t))return null;const e=$(t.from)??$(t.from_agent)??"system",n=$(t.content)??"",s=$(t.timestamp)??new Date().toISOString();return{id:$(t.id),seq:h(t.seq),from:e,content:n,timestamp:s,type:$(t.type)}}function Qi(t){return Array.isArray(t)?t.map(e=>{if(!J(e))return null;const n=h(e.ts_unix);if(n==null)return null;const s=J(e.handoff)?e.handoff:null;return{ts:n,context_ratio:h(e.context_ratio)??0,context_tokens:h(e.context_tokens)??0,context_max:h(e.context_max)??0,latency_ms:h(e.latency_ms)??0,generation:h(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:h(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:h(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?h(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function to(t){return(Array.isArray(t)?t:J(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!J(n))return null;const s=J(n.agent)?n.agent:null,a=J(n.context)?n.context:null,i=J(n.metrics_window)?n.metrics_window:void 0,r=$(n.name);if(!r)return null;const l=h(n.context_ratio)??h(a==null?void 0:a.context_ratio),d=$(n.status)??$(s==null?void 0:s.status)??"offline",u=oa(d),v=$(n.model)??$(n.active_model)??$(n.primary_model),c=Et(n.skill_secondary),p=a?{source:$(a.source),context_ratio:h(a.context_ratio),context_tokens:h(a.context_tokens),context_max:h(a.context_max),message_count:h(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,f=s?{name:$(s.name),status:$(s.status),current_task:$(s.current_task)??null,last_seen:$(s.last_seen)}:void 0,b=Qi(n.metrics_series);return{name:r,emoji:$(n.emoji),koreanName:$(n.koreanName)??$(n.korean_name),agent_name:$(n.agent_name),trace_id:$(n.trace_id),model:v,primary_model:$(n.primary_model),active_model:$(n.active_model),next_model_hint:$(n.next_model_hint)??null,status:u,last_heartbeat:$(n.last_heartbeat)??$(s==null?void 0:s.last_seen),generation:h(n.generation),turn_count:h(n.turn_count)??h(n.total_turns),context_ratio:l,context_tokens:h(n.context_tokens)??h(a==null?void 0:a.context_tokens),context_max:h(n.context_max)??h(a==null?void 0:a.context_max),context_source:$(n.context_source)??$(a==null?void 0:a.source),context:p,traits:Et(n.traits),interests:Et(n.interests),primaryValue:$(n.primaryValue)??$(n.primary_value),activityLevel:h(n.activityLevel)??h(n.activity_level),memory_recent_note:$(n.memory_recent_note)??null,conversation_tail_count:h(n.conversation_tail_count),k2k_count:h(n.k2k_count),handoff_count_total:h(n.handoff_count_total)??h(n.trace_history_count),compaction_count:h(n.compaction_count),last_compaction_saved_tokens:h(n.last_compaction_saved_tokens),skill_primary:$(n.skill_primary)??null,skill_secondary:c,skill_reason:$(n.skill_reason)??null,metrics_series:b.length>0?b:void 0,metrics_window:i,agent:f}}).filter(n=>n!==null)}async function Ie(t="full"){var s,a,i;const e=Date.now(),n=be[t];if(!(n&&e-n.time<Ji)){dn.value=!0;try{const r=await ui(t);be[t]={data:r,time:e},wt.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(Yi).filter(l=>l!==null),ne.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(Xi).filter(l=>l!==null),na.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Zi).filter(l=>l!==null),St.value=to(r.keepers),Rn.value=J(r.status)?r.status:null,Nt.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{dn.value=!1}}}async function dt(){pn.value=!0;try{const t=await di();sa.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{pn.value=!1}}async function lt(){var t;vn.value=!0;try{const e=gt.value||((t=Rn.value)==null?void 0:t.room)||"default";gt.value||(gt.value=e);const n=await Ci(e);aa.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{vn.value=!1}}async function mn(){Dt.value=!0;try{const t=await Ui();Me.value=Array.isArray(t)?t:[]}catch(t){console.error("Goals fetch error:",t)}finally{Dt.value=!1}}let Oe=null,Fe=null;function eo(){return Gs.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(un.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),un.value=n}fn(),Oe||(Oe=setTimeout(()=>{Ie(),Oe=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Fe||(Fe=setTimeout(()=>{dt(),Fe=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&fn()}})}let Pt=null;function no(){Pt||(Pt=setInterval(()=>{fn(),Ie()},1e4))}function so(){Pt&&(clearInterval(Pt),Pt=null)}function x({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function et({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function ao(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function B({timestamp:t}){const e=ao(t);return o`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const Ln=_(null);function ra(t){Ln.value=t}function ns(){Ln.value=null}const ft=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function io(t){if(!t)return 0;const e=ft.findIndex(n=>n.level===t);return e>=0?e:0}function oo({keeper:t}){const e=io(t.autonomy_level),n=ft[e]??ft[0];if(!n)return null;const s=(e+1)/ft.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${ft.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${ft.map((a,i)=>o`
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
            <strong><${B} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function ve(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function ro({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ve(t.context_tokens)}</div>
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
  `}function lo({keeper:t}){var v,c;const e=t.metrics_series??[];if(e.length<2){const p=(((v=t.context)==null?void 0:v.context_ratio)??0)*100,f=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${f}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((p,f)=>{const b=a+f/(i-1)*(n-2*a),T=s-a-(p.context_ratio??0)*(s-2*a);return{x:b,y:T,p}}),l=r.map(({x:p,y:f})=>`${p.toFixed(1)},${f.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${a}" x2="${p.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:f})=>o`
          <circle cx="${p.toFixed(1)}" cy="${f.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const He=_("");function co({keeper:t}){var a,i,r,l;const e=He.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${He.value}
        onInput=${d=>{He.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ve(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ve(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ve(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function uo({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function po({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function vo({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function ss({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ue(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function fo({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Ue(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Ue(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Ue(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function mo({keeperName:t}){const[e,n]=ie("Loading internal monologue..."),[s,a]=ie(""),[i,r]=ie([]),[l,d]=ie(!1),u=async()=>{try{const c=await j("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof c=="string"?c:JSON.stringify(c,null,2))}catch(c){n("Failed to load: "+String(c))}};yt(()=>{u()},[t]);const v=async()=>{if(!s.trim())return;d(!0);const c=s;a(""),r(p=>[...p,{role:"You",text:c}]);try{const p=await j("masc_keeper_msg",{name:t,message:c});r(f=>[...f,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),u()}catch(p){r(f=>[...f,{role:"System",text:"Error: "+String(p)}])}finally{d(!1)}};return o`
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
  `}function _o(){var e,n,s;const t=Ln.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&ns()}}
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
            <${et} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>ns()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${ro} keeper=${t} />

        ${""}
        <${lo} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${x} title="Field Dictionary">
            <${co} keeper=${t} />
          <//>

          ${""}
          <${x} title="Profile">
            <${ss} traits=${t.traits??[]} label="Traits" />
            <${ss} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${B} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${x} title="Autonomy">
                <${oo} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${x} title="TRPG Stats">
                <${uo} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${x} title="Equipment (${t.inventory.length})">
                <${po} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${x} title="Relationships (${Object.keys(t.relationships).length})">
                <${vo} rels=${t.relationships} />
              <//>
            `:null}

          <${x} title="Runtime Signals">
            <${fo} keeper=${t} />
          <//>

          <${x} title="Memory & Context">
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
        <${mo} keeperName=${t.name} />
      </div>
    </div>
  `:null}let go=0;const rt=_([]);function y(t,e="success",n=4e3){const s=++go;rt.value=[...rt.value,{id:s,message:t,type:e}],setTimeout(()=>{rt.value=rt.value.filter(a=>a.id!==s)},n)}function $o(t){rt.value=rt.value.filter(e=>e.id!==t)}function ho(){const t=rt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>$o(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const yo="masc_dashboard_agent_name",Ct=_(null),xe=_(!1),Vt=_(""),ke=_([]),Yt=_([]),$t=_(""),Mt=_(!1);function la(t){Ct.value=t,Dn()}function as(){Ct.value=null,Vt.value="",ke.value=[],Yt.value=[],$t.value=""}function bo(){const t=Ct.value;return t?wt.value.find(e=>e.name===t)??null:null}function ca(t){return t?ne.value.filter(e=>e.assignee===t):[]}async function Dn(){const t=Ct.value;if(t){xe.value=!0,Vt.value="",ke.value=[],Yt.value=[];try{const e=await Ii(80);ke.value=e.filter(a=>a.includes(t)).slice(0,20);const n=ca(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await ji(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Yt.value=s}catch(e){Vt.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{xe.value=!1}}}async function is(){var s;const t=Ct.value,e=$t.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(yo))==null?void 0:s.trim())||"dashboard";Mt.value=!0;try{await ta(n,`@${t} ${e}`),$t.value="",y(`Mention sent to ${t}`,"success"),Dn()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";y(i,"error")}finally{Mt.value=!1}}function xo({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${et} status=${t.status} />
    </div>
  `}function ko({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function wo(){var a,i,r,l;const t=Ct.value;if(!t)return null;const e=bo(),n=ca(t),s=ke.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&as()}}
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
                        <${et} status=${e.status} />
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
                    ${e.last_seen?o`<span>Last seen: <${B} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Dn()}} disabled=${xe.value}>
              ${xe.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${as}>Close</button>
          </div>
        </div>

        ${Vt.value?o`<div class="council-error">${Vt.value}</div>`:null}

        <div class="agent-detail-grid">
          <${x} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${xo} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${x} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${x} title="Task History">
          ${Yt.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Yt.value.map(d=>o`<${ko} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${x} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${$t.value}
              onInput=${d=>{$t.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&is()}}
              disabled=${Mt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{is()}}
              disabled=${Mt.value||$t.value.trim()===""}
            >
              ${Mt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function pt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function So({agent:t}){return o`
    <div class="agent" onClick=${()=>la(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${et} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Co(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Ao(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function os(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function To({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=Gi.value.get(t.name),a=Wi.value.has(t.name);return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>ra(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${et} status=${t.status} />
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
              <div class="keeper-ctx-fill ${os(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${os(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${Co(t.context_tokens)})`:null}
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
            <${B} timestamp=${t.last_heartbeat} />
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
          <div class="keeper-note-preview">${Ao(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function rs(){const t=Rn.value,e=wt.value,n=St.value,s=ia.value;return o`
    <div class="stats-grid">
      <${pt} label="Agents" value=${e.length} />
      <${pt} label="Active" value=${Bi.value.length} color="#4ade80" />
      <${pt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${pt} label="Tasks" value=${ne.value.length} />
      <${pt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${pt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${x} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(a=>o`<${So} key=${a.name} agent=${a} />`)}
        </div>
      <//>

      <${x} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(a=>o`<${To} key=${a.name} keeper=${a} />`)}
        </div>
      <//>
    </div>

    ${Nt.value?o`
        <${x} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${Nt.value.running?"Running":"Stopped"}</span>
            ${Nt.value.goal?o`<span>Goal: ${Nt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${x} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${No(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
          </div>
        <//>
      `:null}
  `}function No(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const _n=_([]),gn=_([]),It=_(""),we=_(!1),jt=_(!1),Se=_(""),Ce=_(null),zt=_(""),$n=_(!1);async function hn(){we.value=!0,Se.value="";try{const[t,e]=await Promise.all([zi(),Oi()]);_n.value=t,gn.value=e}catch(t){Se.value=t instanceof Error?t.message:"Failed to load council data"}finally{we.value=!1}}async function ls(){const t=It.value.trim();if(t){jt.value=!0;try{const e=await Fi(t);It.value="",y(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await hn()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";y(n,"error")}finally{jt.value=!1}}}async function Ro(t){Ce.value=t,$n.value=!0,zt.value="";try{zt.value=await Hi(t)}catch(e){zt.value=e instanceof Error?e.message:"Failed to load debate status"}finally{$n.value=!1}}function Lo({debate:t}){const e=Ce.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Ro(t.id)}
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
  `}function Do({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function Eo(){return yt(()=>{hn()},[]),o`
    <div>
      <${x} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${It.value}
            onInput=${t=>{It.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&ls()}}
            disabled=${jt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${ls}
            disabled=${jt.value||It.value.trim()===""}
          >
            ${jt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${hn} disabled=${we.value}>
            ${we.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Se.value?o`<div class="council-error">${Se.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${x} title="Debates" class="section">
          <div class="council-list">
            ${_n.value.length===0?o`<div class="empty-state">No debates yet</div>`:_n.value.map(t=>o`<${Lo} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${x} title="Voting Sessions" class="section">
          <div class="council-list">
            ${gn.value.length===0?o`<div class="empty-state">No active sessions</div>`:gn.value.map(t=>o`<${Do} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${x} title=${Ce.value?`Debate Detail (${Ce.value})`:"Debate Detail"} class="section">
        ${$n.value?o`<div class="loading-indicator">Loading debate detail...</div>`:zt.value?o`<pre class="council-detail">${zt.value}</pre>`:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Po({text:t}){if(!t)return null;const e=Mo(t);return o`<div class="markdown-content">${e}</div>`}function Mo(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Be(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${Be(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${Be(i.join(`
`))}</p>`)}return n}function Be(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Io=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],fe=_([]),Ot=_(!1),cs=_(null),Ft=_(""),jo=_("dashboard-user"),Ht=_(!1);async function ua(t){Ot.value=!0;try{const e=await pi(t);fe.value=e.comments??[]}catch{}finally{Ot.value=!1}}async function us(t){const e=Ft.value.trim();if(e){Ht.value=!0;try{await vi(t,jo.value,e),Ft.value="",y("Comment posted","success"),await ua(t),dt()}catch{y("Failed to post comment","error")}finally{Ht.value=!1}}}function zo(){const t=es.value;return o`
    <div class="board-controls">
      ${Io.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{es.value=e.id,dt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function da({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Oo({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Qs(t.id,n),dt()}catch{y("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Wa(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${da} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${B} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Fo({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${B} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Ho({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Ft.value}
        onInput=${e=>{Ft.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&us(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Ht.value}
      />
      <button
        onClick=${()=>us(t)}
        disabled=${Ht.value||Ft.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Ht.value?"...":"Post"}
      </button>
    </div>
  `}function Uo({post:t}){cs.value!==t.id&&!Ot.value&&(cs.value=t.id,fe.value=[],ua(t.id));const e=async n=>{try{await Qs(t.id,n),dt()}catch{y("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Pe("board")}>← Back to Board</button>
      <${x} title=${o`${t.title} <${da} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Po} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${B} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${x} title="Comments (${Ot.value?"...":fe.value.length})">
        ${Ot.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Fo} comments=${fe.value} />`}
        <${Ho} postId=${t.id} />
      <//>
    </div>
  `}function Bo(){const t=sa.value,e=pn.value,n=Z.value.postId;if(n){const s=t.find(a=>a.id===n);return s?o`<${Uo} post=${s} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>Pe("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${zo} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(s=>o`<${Oo} key=${s.id} post=${s} />`)}
          </div>`}
  `}function Ko(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Go(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function ds(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function qo({row:t}){const e=new Date(t.timestamp),n=isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1});return o`
    <div class="term-row">
      <span class="term-time">${n}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-source ${t.source}">${t.source==="message"?"msg":"evt"}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Wo(){const t=na.value.map(Ko),e=ye.value.map(Go),n=[...t,...e].sort((s,a)=>ds(a.timestamp)-ds(s.timestamp)).slice(0,100);return o`
    <div class="section">
      <h2 style="color: var(--accent); text-shadow: 0 0 10px rgba(0,240,255,0.5); margin-bottom: 16px; font-family: monospace;">> LIVE_ACTIVITY_STREAM</h2>
      <div class="terminal-feed">
        ${n.length===0?o`<div class="empty-state" style="font-family: monospace; color: var(--ok);">> Waiting for signal...</div>`:n.map(s=>o`<${qo} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function pa({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
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
  `}const Jo={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function Vo(t){return Jo[t]}function vt({metric:t}){const e=Vo(t);return o`
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
  `}function Yo({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>la(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${pa} ratio=${t.context_ratio} />
        <${et} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function Xo(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function Zo(t){var a,i,r;const e=(a=t.last_drift_reason)==null?void 0:a.trim();if(e)return e;const n=(i=t.last_proactive_reason)==null?void 0:i.trim();if(n)return n;const s=(r=t.memory_recent_note)==null?void 0:r.trim();return s||"—"}function Qo(t){var s;const e=t.k2k_count??0,n=(s=t.k2k_mentions)==null?void 0:s[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function tr(t){var s;const e=t.drift_count_total??0,n=Xo((s=t.metrics_window)==null?void 0:s.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function er({keeper:t}){var a;const e=Zo(t),n=Qo(t),s=tr(t);return o`
    <div class="live-agent keeper-card" onClick=${()=>ra(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${pa} ratio=${t.context_ratio} />
        <${et} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${vt} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?o`<${B} timestamp=${t.created_at} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${vt} metric="generation" /></span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${vt} metric="status" /></span>
            <strong class="keeper-core-value">${t.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${vt} metric="relations" /></span>
            <strong class="keeper-core-value">${n}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${vt} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${e}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${vt} metric="personality_change" /></span>
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
  `}function nr(){const t=wt.value,e=St.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${er} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${Yo} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Ke({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${B} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function sr(){const{todo:t,inProgress:e,done:n}=ia.value;return o`
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
  `}function ar({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function ir(){const t=ye.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${ar} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const Ae=_("all"),Te=_("all"),va=st(()=>{let t=Me.value;return Ae.value!=="all"&&(t=t.filter(e=>e.horizon===Ae.value)),Te.value!=="all"&&(t=t.filter(e=>e.status===Te.value)),t}),or=st(()=>{const t={short:[],mid:[],long:[]};for(const e of va.value){const n=t[e.horizon];n&&n.push(e)}return t});function rr(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function En(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function me(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function lr({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${me(t.horizon)}">
            ${En(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${rr(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${B} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${et} status=${t.status} />
        <div class="goal-updated">
          <${B} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Ge({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${x} title="${En(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${lr} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function cr(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ae.value===t?"active":""}"
            onClick=${()=>{Ae.value=t}}
          >
            ${t==="all"?"All":En(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Te.value===t?"active":""}"
            onClick=${()=>{Te.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function ur(){const t=Me.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${me("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${me("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${me("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function dr(){yt(()=>{mn()},[]);const t=or.value;return o`
    <div>
      <${x} title="Goals Overview" class="section">
        <${ur} />
        <${cr} />
        <div style="margin-top:8px;">
          <button class="control-btn ghost" onClick=${mn} disabled=${Dt.value}>
            ${Dt.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      <//>

      ${Dt.value&&Me.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:va.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
            <${Ge} horizon="short" items=${t.short??[]} />
            <${Ge} horizon="mid" items=${t.mid??[]} />
            <${Ge} horizon="long" items=${t.long??[]} />
          `}
    </div>
  `}const Tt=_(""),qe=_("ability_check"),We=_("10"),Je=_("12"),re=_(""),le=_("idle"),ce=_(""),ue=_("keeper-late"),Ve=_("player"),Ye=_(""),U=_("idle"),Xe=_(null),yn=_(null);function pr(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function vr(t,e){return e>0?Math.round(t/e*100):0}const fr={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},mr={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Ze(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function _r(t){const e=t.trim().toLowerCase();return fr[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function gr(t){const e=t.trim().toLowerCase();return mr[e]??"상황에 따라 선택되는 전술 액션입니다."}function ct(t){return typeof t=="object"&&t!==null}function F(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Y(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Xt(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}function $r({hp:t,max:e}){const n=vr(t,e),s=pr(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function hr({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function yr({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function br({actor:t}){var i,r;const e=(i=t.archetype)==null?void 0:i.trim(),n=(r=t.persona)==null?void 0:r.trim(),s=t.traits??[],a=t.skills??[];return o`
    <div class="trpg-actor">
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${et} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${yr} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${$r} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${hr} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Ze(e)}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${s.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${s.map(l=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Ze(l)}</span>
                  <span class="trpg-annot-desc">${_r(l)}</span>
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
                  <span class="trpg-annot-name">${Ze(l)}</span>
                  <span class="trpg-annot-desc">${gr(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function xr({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function kr({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var s;return o`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?o`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?o`<span class="trpg-dice">[${e.dice_roll.notation}: ${(s=e.dice_roll.rolls)==null?void 0:s.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${B} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function wr({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Sr({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Cr({state:t}){var d;const e=gt.value||((d=t.session)==null?void 0:d.room)||"",n=le.value,s=t.party??[];if(!s.find(u=>u.id===Tt.value)&&s.length>0){const u=s[0];u&&(Tt.value=u.id)}const i=async()=>{if(!e){y("No room set","error");return}le.value="running";try{const u=await Ai(e);yn.value=u,le.value="ok";const v=ct(u.summary)?u.summary:null,c=v?Xt(v,"advanced",!1):!1,p=v?F(v,"progress_reason",""):"";y(c?"Round advanced":`Round stalled${p?`: ${p}`:""}`,c?"success":"warning"),lt()}catch(u){yn.value=null,le.value="error";const v=u instanceof Error?u.message:"Round failed";y(v,"error")}},r=async()=>{if(e)try{await Ri(e),y("Turn advanced","success"),lt()}catch{y("Advance failed","error")}},l=async()=>{if(!e)return;const u=Tt.value.trim();if(!u){y("Select actor first","warning");return}const v=Number.parseInt(We.value,10),c=Number.parseInt(Je.value,10);if(Number.isNaN(v)||Number.isNaN(c)){y("Stat/DC must be numbers","warning");return}const p=Number.parseInt(re.value,10),f=re.value.trim()===""||Number.isNaN(p)?void 0:p;try{await Ni({roomId:e,actorId:u,action:qe.value.trim()||"ability_check",statValue:v,dc:c,rawD20:f}),y("Dice rolled","success"),lt()}catch{y("Dice roll failed","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${e}
            onInput=${u=>{gt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Tt.value}
            onChange=${u=>{Tt.value=u.target.value}}
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
              value=${qe.value}
              onInput=${u=>{qe.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${We.value}
              onInput=${u=>{We.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Je.value}
              onInput=${u=>{Je.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${re.value}
              onInput=${u=>{re.value=u.target.value}}
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
  `}function Ar({state:t}){var l;const e=gt.value||((l=t.session)==null?void 0:l.room)||"",n=t.join_gate,s=Xe.value,a=ct(s)?s:null,i=async()=>{const d=ce.value.trim(),u=ue.value.trim();if(!e||!d){y("Room/Actor is required","warning");return}U.value="checking";try{const v=await Li(e,d,u||void 0);Xe.value=v,U.value="ok",y("Eligibility updated","success")}catch(v){U.value="error";const c=v instanceof Error?v.message:"Eligibility check failed";y(c,"error")}},r=async()=>{const d=ce.value.trim(),u=ue.value.trim(),v=Ye.value.trim();if(!e||!d||!u){y("Room/Actor/Keeper is required","warning");return}U.value="requesting";try{const c=await Di({room_id:e,actor_id:d,keeper_name:u,role:Ve.value,...v?{name:v}:{}});Xe.value=c;const p=ct(c)?Xt(c,"granted",!1):!1,f=ct(c)?F(c,"reason_code",""):"";p?y("Mid-join granted","success"):y(`Mid-join rejected${f?`: ${f}`:""}`,"warning"),U.value=p?"ok":"error",lt()}catch(c){U.value="error";const p=c instanceof Error?c.message:"Mid-join request failed";y(p,"error")}};return o`
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
            value=${ce.value}
            onInput=${d=>{ce.value=d.target.value}}
            placeholder="player-xyz"
          />
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${ue.value}
            onInput=${d=>{ue.value=d.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ve.value}
            onChange=${d=>{Ve.value=d.target.value}}
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
            value=${Ye.value}
            onInput=${d=>{Ye.value=d.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${i} disabled=${U.value==="checking"||U.value==="requesting"}>
              ${U.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${r} disabled=${U.value==="checking"||U.value==="requesting"}>
              ${U.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${a?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Xt(a,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Y(a,"effective_score",0)}/${Y(a,"required_points",0)}</span>
            ${F(a,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${F(a,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Tr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Nr({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Rr(){const t=yn.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ct(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(ct).slice(-8),i=t.canon_check,r=ct(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(L=>typeof L=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(L=>typeof L=="string").slice(0,3):[],u=n?Xt(n,"advanced",!1):!1,v=n?F(n,"progress_reason",""):"",c=n?F(n,"progress_detail",""):"",p=n?Y(n,"player_successes",0):0,f=n?Y(n,"player_required_successes",0):0,b=n?Xt(n,"dm_success",!1):!1,T=n?Y(n,"timeouts",0):0,R=n?Y(n,"unavailable",0):0,S=n?Y(n,"reprompts",0):0,k=n?Y(n,"npc_attacks",0):0,O=n?Y(n,"keeper_timeout_sec",0):0,K=n?Y(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${b?"DM ok":"DM stalled"} / players ${p}/${f}
          </span>
        </div>
        ${v?o`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${c?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${R}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${O||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${K}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(L=>{const G=F(L,"status","unknown"),at=F(L,"actor_id","-"),it=F(L,"role","-"),q=F(L,"reason",""),Q=F(L,"action_type",""),C=F(L,"reply","");return o`
                <div class="trpg-round-item ${G.includes("fallback")||G.includes("timeout")?"failed":"active"}">
                  <span>${at} (${it})</span>
                  <span style="margin-left:auto; font-size:11px;">${G}</span>
                  ${Q?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${Q}</div>`:null}
                  ${q?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${q}</div>`:null}
                  ${C?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${C.slice(0,120)}</div>`:null}
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
                  ${d.map(L=>o`<div>violation: ${L}</div>`)}
                </div>`:null}
            ${l.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(L=>o`<div>warning: ${L}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Lr(){var i,r;const t=aa.value;if(vn.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>lt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome;return o`
    <div>
      <${wr} outcome=${a} />

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
      <${Nr} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${x} title="Story Log (${s.length})">
            <${kr} events=${s} />
          <//>

          ${""}
          ${t.map?o`
              <${x} title="Map" style="margin-top:16px;">
                <${xr} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${x} title="Controls">
            <${Cr} state=${t} />
          <//>

          <${x} title="Last Round Result" style="margin-top:16px;">
            <${Rr} />
          <//>

          ${""}
          <${x} title="Mid-Join Gate" style="margin-top:16px;">
            <${Ar} state=${t} />
          <//>

          ${""}
          <${x} title="Contribution" style="margin-top:16px;">
            <${Tr} state=${t} />
          <//>

          ${""}
          <${x} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(l=>o`<${br} key=${l.id??l.name} actor=${l} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${x} title="History (${t.history.length})" style="margin-top:16px;">
                <${Sr} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const Pn="masc_dashboard_agent_name";function Dr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Pn);return e??n??"dashboard"}const V=_(Dr()),Ut=_(""),Bt=_(""),Ne=_(""),Kt=_(!1),mt=_(!1),Gt=_(!1),qt=_(!1),Re=_(!1),je=_(!1);function Mn(t){const e=t.trim();V.value=e,e&&localStorage.setItem(Pn,e)}function Er(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function bn(){const t=V.value.trim();if(t){Gt.value=!0;try{const e=await Pi(t),n=Er(e);n&&Mn(n),je.value=!0,y(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";y(n,"error")}finally{Gt.value=!1}}}async function Pr(){const t=V.value.trim();if(t){qt.value=!0;try{await ea(t),je.value=!1,y(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";y(n,"error")}finally{qt.value=!1}}}async function Mr(){const t=V.value.trim();if(t)try{await ea(t)}catch{}localStorage.removeItem(Pn),Mn("dashboard"),je.value=!1,await bn()}async function Ir(){const t=V.value.trim();if(t){Re.value=!0;try{await Mi(t),y("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";y(n,"error")}finally{Re.value=!1}}}async function ps(){const t=V.value.trim(),e=Ut.value.trim();if(!(!t||!e)){Kt.value=!0;try{await ta(t,e),Ut.value="",y("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";y(s,"error")}finally{Kt.value=!1}}}async function jr(){const t=Bt.value.trim(),e=Ne.value.trim()||"Created from dashboard";if(t){mt.value=!0;try{await Ei(t,e,1),Bt.value="",Ne.value="",y("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";y(s,"error")}finally{mt.value=!1}}}function zr(){return yt(()=>{bn()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${V.value}
        onInput=${t=>Mn(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Ut.value}
          onInput=${t=>{Ut.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&ps()}}
          disabled=${Kt.value}
        />
        <button
          class="control-btn"
          onClick=${ps}
          disabled=${Kt.value||Ut.value.trim()===""||V.value.trim()===""}
        >
          ${Kt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{bn()}}
          disabled=${Gt.value||V.value.trim()===""}
        >
          ${Gt.value?"Joining...":je.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Pr()}}
          disabled=${qt.value||V.value.trim()===""}
        >
          ${qt.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Mr()}}
          disabled=${Gt.value||qt.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Ir()}}
          disabled=${Re.value||V.value.trim()===""}
        >
          ${Re.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Bt.value}
        onInput=${t=>{Bt.value=t.target.value}}
        disabled=${mt.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${Ne.value}
        onInput=${t=>{Ne.value=t.target.value}}
        disabled=${mt.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${jr}
        disabled=${mt.value||Bt.value.trim()===""}
      >
        ${mt.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function Or(){const t=bt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Tn.value} events</span>
    </div>
  `}const Fr=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"goals",label:"Goals"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function Hr(){const t=Z.value.tab,e=bt.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Fr.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Pe(n.id)}
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
            <strong>${wt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${St.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${ne.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Tn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Ie(),t==="board"&&dt(),t==="trpg"&&lt()}}
        >
          Refresh Now
        </button>
      </section>

      <${zr} />
    </aside>
  `}function Ur(){switch(Z.value.tab){case"overview":return o`<${rs} />`;case"council":return o`<${Eo} />`;case"board":return o`<${Bo} />`;case"activity":return o`<${Wo} />`;case"agents":return o`<${nr} />`;case"tasks":return o`<${sr} />`;case"goals":return o`<${dr} />`;case"journal":return o`<${ir} />`;case"trpg":return o`<${Lr} />`;default:return o`<${rs} />`}}function Br(){return yt(()=>{Ja(),Ws(),Ie();const t=eo();return no(),()=>{si(),t(),so()}},[]),yt(()=>{const t=Z.value.tab;t==="board"&&dt(),t==="trpg"&&lt(),t==="goals"&&mn()},[Z.value.tab]),o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">Real-time multi-agent operations console</p>
        </div>
        <div class="header-right">
          <${Or} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${Ya} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${dn.value&&!bt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Ur} />`}
        </main>
        <${Hr} />
      </div>

      <${_o} />
      <${wo} />
      <${ho} />
    </div>
  `}const vs=document.getElementById("app");vs&&La(o`<${Br} />`,vs);
