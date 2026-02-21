(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var ye,C,Yn,Qn,st,kn,Zn,ts,es,ln,He,Ue,Ht={},ns=[],ea=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,be=Array.isArray;function Q(t,e){for(var n in e)t[n]=e[n];return t}function cn(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function ss(t,e,n){var s,a,o,r={};for(o in e)o=="key"?s=e[o]:o=="ref"?a=e[o]:r[o]=e[o];if(arguments.length>2&&(r.children=arguments.length>3?ye.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(o in t.defaultProps)r[o]===void 0&&(r[o]=t.defaultProps[o]);return ne(t,r,s,a,null)}function ne(t,e,n,s,a){var o={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++Yn,__i:-1,__u:0};return a==null&&C.vnode!=null&&C.vnode(o),o}function qt(t){return t.children}function wt(t,e){this.props=t,this.context=e}function ft(t,e){if(e==null)return t.__?ft(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?ft(t):null}function as(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return as(t)}}function wn(t){(!t.__d&&(t.__d=!0)&&st.push(t)&&!ie.__r++||kn!=C.debounceRendering)&&((kn=C.debounceRendering)||Zn)(ie)}function ie(){for(var t,e,n,s,a,o,r,l=1;st.length;)st.length>l&&st.sort(ts),t=st.shift(),l=st.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,o=[],r=[],e.__P&&((n=Q({},s)).__v=s.__v+1,C.vnode&&C.vnode(n),un(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,o,a??ft(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,rs(o,n,r),s.__e=s.__=null,n.__e!=a&&as(n)));ie.__r=0}function is(t,e,n,s,a,o,r,l,d,u,p){var c,v,f,S,D,A,x,k=s&&s.__k||ns,j=e.length;for(d=na(n,e,k,d,j),c=0;c<j;c++)(f=n.__k[c])!=null&&(v=f.__i==-1?Ht:k[f.__i]||Ht,f.__i=c,A=un(t,f,v,a,o,r,l,d,u,p),S=f.__e,f.ref&&v.ref!=f.ref&&(v.ref&&dn(v.ref,null,f),p.push(f.ref,f.__c||S,f)),D==null&&S!=null&&(D=S),(x=!!(4&f.__u))||v.__k===f.__k?d=os(f,d,t,x):typeof f.type=="function"&&A!==void 0?d=A:S&&(d=S.nextSibling),f.__u&=-7);return n.__e=D,d}function na(t,e,n,s,a){var o,r,l,d,u,p=n.length,c=p,v=0;for(t.__k=new Array(a),o=0;o<a;o++)(r=e[o])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[o]=ne(null,r,null,null,null):be(r)?r=t.__k[o]=ne(qt,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[o]=ne(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[o]=r,d=o+v,r.__=t,r.__b=t.__b+1,l=null,(u=r.__i=sa(r,n,d,c))!=-1&&(c--,(l=n[u])&&(l.__u|=2)),l==null||l.__v==null?(u==-1&&(a>p?v--:a<p&&v++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?v--:u==d+1?v++:(u>d?v--:v++,r.__u|=4))):t.__k[o]=null;if(c)for(o=0;o<p;o++)(l=n[o])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=ft(l)),cs(l,l));return s}function os(t,e,n,s){var a,o;if(typeof t.type=="function"){for(a=t.__k,o=0;a&&o<a.length;o++)a[o]&&(a[o].__=t,e=os(a[o],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=ft(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function sa(t,e,n,s){var a,o,r,l=t.key,d=t.type,u=e[n],p=u!=null&&(2&u.__u)==0;if(u===null&&l==null||p&&l==u.key&&d==u.type)return n;if(s>(p?1:0)){for(a=n-1,o=n+1;a>=0||o<e.length;)if((u=e[r=a>=0?a--:o++])!=null&&(2&u.__u)==0&&l==u.key&&d==u.type)return r}return-1}function Sn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||ea.test(e)?n:n+"px"}function Xt(t,e,n,s,a){var o,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||Sn(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||Sn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")o=e!=(e=e.replace(es,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+o]=n,n?s?n.u=s.u:(n.u=ln,t.addEventListener(e,o?Ue:He,o)):t.removeEventListener(e,o?Ue:He,o);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Cn(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=ln++;else if(e.t<n.u)return;return n(C.event?C.event(e):e)}}}function un(t,e,n,s,a,o,r,l,d,u){var p,c,v,f,S,D,A,x,k,j,U,T,W,nt,Y,R,L,g=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),o=[l=e.__e=n.__e]),(p=C.__b)&&p(e);t:if(typeof g=="function")try{if(x=e.props,k="prototype"in g&&g.prototype.render,j=(p=g.contextType)&&s[p.__c],U=p?j?j.props.value:p.__:s,n.__c?A=(c=e.__c=n.__c).__=c.__E:(k?e.__c=c=new g(x,U):(e.__c=c=new wt(x,U),c.constructor=g,c.render=ia),j&&j.sub(c),c.state||(c.state={}),c.__n=s,v=c.__d=!0,c.__h=[],c._sb=[]),k&&c.__s==null&&(c.__s=c.state),k&&g.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=Q({},c.__s)),Q(c.__s,g.getDerivedStateFromProps(x,c.__s))),f=c.props,S=c.state,c.__v=e,v)k&&g.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),k&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(k&&g.getDerivedStateFromProps==null&&x!==f&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(x,U),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(x,c.__s,U)===!1){for(e.__v!=n.__v&&(c.props=x,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(B){B&&(B.__=e)}),T=0;T<c._sb.length;T++)c.__h.push(c._sb[T]);c._sb=[],c.__h.length&&r.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(x,c.__s,U),k&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(f,S,D)})}if(c.context=U,c.props=x,c.__P=t,c.__e=!1,W=C.__r,nt=0,k){for(c.state=c.__s,c.__d=!1,W&&W(e),p=c.render(c.props,c.state,c.context),Y=0;Y<c._sb.length;Y++)c.__h.push(c._sb[Y]);c._sb=[]}else do c.__d=!1,W&&W(e),p=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++nt<25);c.state=c.__s,c.getChildContext!=null&&(s=Q(Q({},s),c.getChildContext())),k&&!v&&c.getSnapshotBeforeUpdate!=null&&(D=c.getSnapshotBeforeUpdate(f,S)),R=p,p!=null&&p.type===qt&&p.key==null&&(R=ls(p.props.children)),l=is(t,be(R)?R:[R],e,n,s,a,o,r,l,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&r.push(c),A&&(c.__E=c.__=null)}catch(B){if(e.__v=null,d||o!=null)if(B.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;o[o.indexOf(l)]=null,e.__e=l}else{for(L=o.length;L--;)cn(o[L]);Be(e)}else e.__e=n.__e,e.__k=n.__k,B.then||Be(e);C.__e(B,e,n)}else o==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=aa(n.__e,e,n,s,a,o,r,d,u);return(p=C.diffed)&&p(e),128&e.__u?void 0:l}function Be(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Be)}function rs(t,e,n){for(var s=0;s<n.length;s++)dn(n[s],n[++s],n[++s]);C.__c&&C.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(o){o.call(a)})}catch(o){C.__e(o,a.__v)}})}function ls(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:be(t)?t.map(ls):Q({},t)}function aa(t,e,n,s,a,o,r,l,d){var u,p,c,v,f,S,D,A=n.props||Ht,x=e.props,k=e.type;if(k=="svg"?a="http://www.w3.org/2000/svg":k=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),o!=null){for(u=0;u<o.length;u++)if((f=o[u])&&"setAttribute"in f==!!k&&(k?f.localName==k:f.nodeType==3)){t=f,o[u]=null;break}}if(t==null){if(k==null)return document.createTextNode(x);t=document.createElementNS(a,k,x.is&&x),l&&(C.__m&&C.__m(e,o),l=!1),o=null}if(k==null)A===x||l&&t.data==x||(t.data=x);else{if(o=o&&ye.call(t.childNodes),!l&&o!=null)for(A={},u=0;u<t.attributes.length;u++)A[(f=t.attributes[u]).name]=f.value;for(u in A)if(f=A[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=f;else if(!(u in x)){if(u=="value"&&"defaultValue"in x||u=="checked"&&"defaultChecked"in x)continue;Xt(t,u,null,f,a)}}for(u in x)f=x[u],u=="children"?v=f:u=="dangerouslySetInnerHTML"?p=f:u=="value"?S=f:u=="checked"?D=f:l&&typeof f!="function"||A[u]===f||Xt(t,u,f,A[u],a);if(p)l||c&&(p.__html==c.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(c&&(t.innerHTML=""),is(e.type=="template"?t.content:t,be(v)?v:[v],e,n,s,k=="foreignObject"?"http://www.w3.org/1999/xhtml":a,o,r,o?o[0]:n.__k&&ft(n,0),l,d),o!=null)for(u=o.length;u--;)cn(o[u]);l||(u="value",k=="progress"&&S==null?t.removeAttribute("value"):S!=null&&(S!==t[u]||k=="progress"&&!S||k=="option"&&S!=A[u])&&Xt(t,u,S,A[u],a),u="checked",D!=null&&D!=t[u]&&Xt(t,u,D,A[u],a))}return t}function dn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){C.__e(a,n)}}function cs(t,e,n){var s,a;if(C.unmount&&C.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||dn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(o){C.__e(o,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&cs(s[a],e,n||typeof t.type!="function");n||cn(t.__e),t.__c=t.__=t.__e=void 0}function ia(t,e,n){return this.constructor(t,n)}function oa(t,e,n){var s,a,o,r;e==document&&(e=document.documentElement),C.__&&C.__(t,e),a=(s=!1)?null:e.__k,o=[],r=[],un(e,t=e.__k=ss(qt,null,[t]),a||Ht,Ht,e.namespaceURI,a?null:e.firstChild?ye.call(e.childNodes):null,o,a?a.__e:e.firstChild,s,r),rs(o,t,r)}ye=ns.slice,C={__e:function(t,e,n,s){for(var a,o,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((o=a.constructor)&&o.getDerivedStateFromError!=null&&(a.setState(o.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},Yn=0,Qn=function(t){return t!=null&&t.constructor===void 0},wt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=Q({},this.state),typeof t=="function"&&(t=t(Q({},n),this.props)),t&&Q(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),wn(this))},wt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),wn(this))},wt.prototype.render=qt,st=[],Zn=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,ts=function(t,e){return t.__v.__b-e.__v.__b},ie.__r=0,es=/(PointerCapture)$|Capture$/i,ln=0,He=Cn(!1),Ue=Cn(!0);var us=function(t,e,n,s){var a;e[0]=0;for(var o=1;o<e.length;o++){var r=e[o++],l=e[o]?(e[0]|=r?1:2,n[e[o++]]):e[++o];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++o]]=l:r===6?s[1][e[++o]]+=l+"":r?(a=t.apply(l,us(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[o-2]=0,e[o]=a)):s.push(l)}return s},Tn=new Map;function ra(t){var e=Tn.get(this);return e||(e=new Map,Tn.set(this,e)),(e=us(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,o=1,r="",l="",d=[0],u=function(v){o===1&&(v||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,v,r):o===3&&(v||r)?(d.push(3,v,r),o=2):o===2&&r==="..."&&v?d.push(4,v,0):o===2&&r&&!v?d.push(5,0,!0,r):o>=5&&((r||!v&&o===5)&&(d.push(o,0,r,a),o=6),v&&(d.push(o,v,0,a),o=6)),r=""},p=0;p<n.length;p++){p&&(o===1&&u(),u(p));for(var c=0;c<n[p].length;c++)s=n[p][c],o===1?s==="<"?(u(),d=[d],o=3):r+=s:o===4?r==="--"&&s===">"?(o=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(u(),o=1):o&&(s==="="?(o=5,a=r,r=""):s==="/"&&(o<5||n[p][c+1]===">")?(u(),o===3&&(d=d[0]),o=d,(d=d[0]).push(2,0,o),o=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),o=2):r+=s),o===3&&r==="!--"&&(o=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var i=ra.bind(ss),oe,M,Ce,An,Nn=0,ds=[],N=C,Rn=N.__b,Dn=N.__r,En=N.diffed,Ln=N.__c,Pn=N.unmount,Mn=N.__;function ps(t,e){N.__h&&N.__h(M,t,Nn||e),Nn=0;var n=M.__H||(M.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function re(t,e){var n=ps(oe++,3);!N.__s&&fs(n.__H,e)&&(n.__=t,n.u=e,M.__H.__h.push(n))}function vs(t,e){var n=ps(oe++,7);return fs(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function la(){for(var t;t=ds.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(se),t.__H.__h.forEach(Ke),t.__H.__h=[]}catch(e){t.__H.__h=[],N.__e(e,t.__v)}}N.__b=function(t){M=null,Rn&&Rn(t)},N.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Mn&&Mn(t,e)},N.__r=function(t){Dn&&Dn(t),oe=0;var e=(M=t.__c).__H;e&&(Ce===M?(e.__h=[],M.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(se),e.__h.forEach(Ke),e.__h=[],oe=0)),Ce=M},N.diffed=function(t){En&&En(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(ds.push(e)!==1&&An===N.requestAnimationFrame||((An=N.requestAnimationFrame)||ca)(la)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Ce=M=null},N.__c=function(t,e){e.some(function(n){try{n.__h.forEach(se),n.__h=n.__h.filter(function(s){return!s.__||Ke(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],N.__e(s,n.__v)}}),Ln&&Ln(t,e)},N.unmount=function(t){Pn&&Pn(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{se(s)}catch(a){e=a}}),n.__H=void 0,e&&N.__e(e,n.__v))};var jn=typeof requestAnimationFrame=="function";function ca(t){var e,n=function(){clearTimeout(s),jn&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);jn&&(e=requestAnimationFrame(n))}function se(t){var e=M,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),M=e}function Ke(t){var e=M;t.__c=t.__(),M=e}function fs(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}var ua=Symbol.for("preact-signals");function xe(){if(et>1)et--;else{for(var t,e=!1;St!==void 0;){var n=St;for(St=void 0,qe++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&$s(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(qe=0,et--,e)throw t}}function da(t){if(et>0)return t();et++;try{return t()}finally{xe()}}var w=void 0;function _s(t){var e=w;w=void 0;try{return t()}finally{w=e}}var St=void 0,et=0,qe=0,le=0;function ms(t){if(w!==void 0){var e=t.n;if(e===void 0||e.t!==w)return e={i:0,S:t,p:w.s,n:void 0,t:w,e:void 0,x:void 0,r:e},w.s!==void 0&&(w.s.n=e),w.s=e,t.n=e,32&w.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=w.s,e.n=void 0,w.s.n=e,w.s=e),e}}function E(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}E.prototype.brand=ua;E.prototype.h=function(){return!0};E.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:_s(function(){var s;(s=e.W)==null||s.call(e)}))};E.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&_s(function(){var a;(a=e.Z)==null||a.call(e)}))}};E.prototype.subscribe=function(t){var e=this;return Jt(function(){var n=e.value,s=w;w=void 0;try{t(n)}finally{w=s}},{name:"sub"})};E.prototype.valueOf=function(){return this.value};E.prototype.toString=function(){return this.value+""};E.prototype.toJSON=function(){return this.value};E.prototype.peek=function(){var t=w;w=void 0;try{return this.value}finally{w=t}};Object.defineProperty(E.prototype,"value",{get:function(){var t=ms(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(qe>100)throw new Error("Cycle detected");this.v=t,this.i++,le++,et++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{xe()}}}});function _(t,e){return new E(t,e)}function $s(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function gs(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function hs(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function rt(t,e){E.call(this,void 0),this.x=t,this.s=void 0,this.g=le-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}rt.prototype=new E;rt.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===le))return!0;if(this.g=le,this.f|=1,this.i>0&&!$s(this))return this.f&=-2,!0;var t=w;try{gs(this),w=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return w=t,hs(this),this.f&=-2,!0};rt.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}E.prototype.S.call(this,t)};rt.prototype.U=function(t){if(this.t!==void 0&&(E.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};rt.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(rt.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=ms(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function _t(t,e){return new rt(t,e)}function ys(t){var e=t.u;if(t.u=void 0,typeof e=="function"){et++;var n=w;w=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,pn(t),s}finally{w=n,xe()}}}function pn(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,ys(t)}function pa(t){if(w!==this)throw new Error("Out-of-order effect");hs(this),w=t,this.f&=-2,8&this.f&&pn(this),xe()}function $t(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}$t.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};$t.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,ys(this),gs(this),et++;var t=w;return w=this,pa.bind(this,t)};$t.prototype.N=function(){2&this.f||(this.f|=2,this.o=St,St=this)};$t.prototype.d=function(){this.f|=8,1&this.f||pn(this)};$t.prototype.dispose=function(){this.d()};function Jt(t,e){var n=new $t(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var bs,Yt,va=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,xs=[];Jt(function(){bs=this.N})();function gt(t,e){C[t]=e.bind(null,C[t]||function(){})}function ce(t){if(Yt){var e=Yt;Yt=void 0,e()}Yt=t&&t.S()}function ks(t){var e=this,n=t.data,s=_a(n);s.value=n;var a=vs(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=_t(function(){var f=s.value.value;return f===0?0:f===!0?"":f||""}),p=_t(function(){return!Array.isArray(u.value)&&!Qn(u.value)}),c=Jt(function(){if(this.N=ws,p.value){var f=u.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=f)}}),v=e.__$u.d;return e.__$u.d=function(){c(),v.call(this)},[p,u]},[]),o=a[0],r=a[1];return o.value?r.peek():r.value}ks.displayName="ReactiveTextNode";Object.defineProperties(E.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:ks},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});gt("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var o=s[a];o instanceof E&&(n||(e.__np=n={}),n[a]=o,s[a]=o.peek())}}t(e)});gt("__r",function(t,e){if(t(e),e.type!==qt){ce();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,o){var r;return Jt(function(){r=this},{name:o}),r.c=a,r})(function(){var a;va&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),ce(n)}});gt("__e",function(t,e,n,s){ce(),t(e,n,s)});gt("diffed",function(t,e){ce();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var o=n.U;if(o)for(var r in o){var l=o[r];l!==void 0&&!(r in s)&&(l.d(),o[r]=void 0)}else o={},n.U=o;for(var d in s){var u=o[d],p=s[d];u===void 0?(u=fa(n,d,p),o[d]=u):u.o(p,a)}for(var c in s)a[c]=s[c]}}t(e)});function fa(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,o=_(n),r=n.peek();return{o:function(l,d){o.value=l,r=l.peek()},d:Jt(function(){this.N=ws;var l=o.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}gt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var o=s[a];o&&o.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});gt("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});wt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var o=2&this.__$f;if(!(s||o||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function _a(t,e){return vs(function(){return _(t,e)},[])}var ma=function(t){queueMicrotask(function(){queueMicrotask(t)})};function $a(){da(function(){for(var t;t=xs.shift();)bs.call(t)})}function ws(){xs.push(this)===1&&(C.requestAnimationFrame||ma)($a)}const ga=["overview","board","activity","agents","tasks","journal","trpg","council"],Ss={tab:"overview",params:{},postId:null};function In(t){return!!t&&ga.includes(t)}function Je(t){try{return decodeURIComponent(t)}catch{return t}}function We(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function ha(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Cs(t,e){const n=t[0],s=e.tab,a=In(n)?n:In(s)?s:"overview";let o=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=Je(t[2]):t[0]==="post"&&t[1]&&(o=Je(t[1]))),{tab:a,params:e,postId:o}}function ue(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Ss;const n=Je(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=We(a),r=ha(s);return Cs(r,o)}function ya(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Ss,params:We(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=We(e.replace(/^\?/,""));return Cs(s,a)}function Ts(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const X=_(ue(window.location.hash));window.addEventListener("hashchange",()=>{X.value=ue(window.location.hash)});function ke(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Ts(n)}function ba(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function xa(){if(window.location.hash&&window.location.hash!=="#"){X.value=ue(window.location.hash);return}const t=ya(window.location.pathname,window.location.search);if(t){X.value=t;const e=Ts(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",X.value=ue(window.location.hash)}const ka=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function wa(){const t=X.value.tab;return i`
    <div class="main-tab-bar">
      ${ka.map(e=>i`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>ke(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const zn="masc_dashboard_sse_session_id",Sa=1e3,Ca=15e3,mt=_(!1),vn=_(0),As=_(null),de=_([]);function Ta(){let t=sessionStorage.getItem(zn);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(zn,t)),t}const Aa=200;function K(t,e){const n={agent:t,text:e,timestamp:Date.now()};de.value=[n,...de.value].slice(0,Aa)}let G=null,dt=null,Ve=0;function Ns(){dt&&(clearTimeout(dt),dt=null)}function Na(){if(dt)return;Ve++;const t=Math.min(Ve,5),e=Math.min(Ca,Sa*Math.pow(2,t));dt=setTimeout(()=>{dt=null,Rs()},e)}function Rs(){Ns(),G&&(G.close(),G=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Ta());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);G=o,o.onopen=()=>{G===o&&(Ve=0,mt.value=!0)},o.onerror=()=>{G===o&&(mt.value=!1,o.close(),G=null,Na())},o.onmessage=r=>{try{const l=JSON.parse(r.data);vn.value++,As.value=l,Ra(l)}catch{}}}function Ra(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":K(n,"Joined");break;case"agent_left":K(n,"Left");break;case"broadcast":K(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":K(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":K(n,"New post");break;case"board_comment":K(n,"New comment");break;case"keeper_heartbeat":K(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":K(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":K(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":K(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:K(n,e)}}function Da(){Ns(),G&&(G.close(),G=null),mt.value=!1}function Ds(){return new URLSearchParams(window.location.search)}function Es(){const t=Ds(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Ls(){return{...Es(),"Content-Type":"application/json"}}const Ea=15e3,Ps=3e4,La=6e4;async function fn(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw o}finally{clearTimeout(a)}}function Pa(){var e,n;const t=Ds();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Wt(t){const e=await fn(t,{headers:Es()},Ea);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function Vt(t,e){const n=await fn(t,{method:"POST",headers:Ls(),body:JSON.stringify(e)},Ps);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function Ma(t,e,n,s=Ps){const a=await fn(t,{method:"POST",headers:{...Ls(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function ja(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Ia(t){var e,n,s,a,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function F(t,e){const n=await Ma("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},La),s=ja(n);return Ia(s)}function Ms(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function za(t="compact"){return Wt(`/api/v1/dashboard?mode=${t}`)}function Fa(){return Wt("/api/v1/board")}function Oa(t){return Wt(`/api/v1/board/${t}`)}function js(t,e){return Vt("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:Pa()})}function Ha(t,e,n){return Vt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function P(t){return typeof t=="object"&&t!==null}function m(t,e=""){return typeof t=="string"?t:e}function z(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Ge(t,e=!1){return typeof t=="boolean"?t:e}function Te(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(P(e)){const n=m(e.name,"").trim(),s=m(e.id,"").trim(),a=m(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Ua(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function O(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}function Ba(t,e){if(t!=="dice.rolled")return;const n=z(e.raw_d20,0),s=z(e.total,0),a=z(e.bonus,0),o=m(e.action,"roll"),r=z(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function Ka(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function qa(t,e,n){const s=e||m(n.actor_id,"");switch(t){case"turn.action.proposed":{const a=m(n.proposed_action,m(n.reply,""));return a?`${s||"actor"}: ${a}`:"Action proposed"}case"turn.action.resolved":{const a=m(n.reply,m(n.result,""));return a?`Resolved: ${a}`:"Action resolved"}case"narration.posted":return m(n.reply,m(n.content,m(n.text,"Narration")));case"dice.rolled":{const a=m(n.action,"roll"),o=z(n.total,0),r=z(n.dc,0),l=m(n.label,""),d=s||"actor",u=r>0?` vs DC ${r}`:"",p=l?` (${l})`:"";return`${d} ${a}: ${o}${u}${p}`}case"turn.started":return`Turn ${z(n.turn,1)} started`;case"phase.changed":return`Phase: ${m(n.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${m(n.name,s||"unknown")}`;case"actor.claimed":return`${m(n.keeper_name,m(n.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${m(n.keeper_name,m(n.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${z(n.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${z(n.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||m(n.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||m(n.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${m(n.reason_code,"unknown")}`;case"memory.signal":{const a=P(n.entity_refs)?n.entity_refs:{},o=m(a.requested_tier,""),r=m(a.effective_tier,""),l=Ge(a.guardrail_applied,!1),d=m(n.summary_en,m(n.summary_ko,"Memory signal"));if(!o&&!r)return d;const u=o&&r?`${o}->${r}`:r||o;return`${d} [${u}${l?" (guardrail)":""}]`}case"world.event":{if(m(n.event_type,"")==="canon.check"){const o=m(n.status,"unknown"),r=m(n.contract_id,"n/a");return`Canon ${o}: ${r}`}return m(n.description,m(n.summary,"World event"))}case"combat.attack":return m(n.summary,m(n.result,"Attack resolved"));case"combat.defense":return m(n.summary,m(n.result,"Defense resolved"));case"session.outcome":return m(n.summary,m(n.outcome,"Session ended"));default:{const a=Ka(n);return a?`${t}: ${a}`:t}}}function Ja(t){const e=P(t)?t:{},n=m(e.type,"event"),s=typeof e.actor_id=="string"?e.actor_id:"",a=P(e.payload)?e.payload:{};return{type:n,actor:s||m(a.actor_id,""),content:qa(n,s,a),dice_roll:Ba(n,a),timestamp:m(e.ts,new Date().toISOString())}}function Wa(t,e,n){var nt,Y;const s=m(t.room_id,"")||n||"default",a=P(t.state)?t.state:{},o=P(a.party)?a.party:{},r=P(a.actor_control)?a.actor_control:{},l=P(a.join_gate)?a.join_gate:{},d=P(a.contribution_ledger)?a.contribution_ledger:{},p=Object.entries(o).map(([R,L])=>{const g=P(L)?L:{},B=O(g,"max_hp",void 0,10),yn=O(g,"hp",void 0,B),Gs=O(g,"max_mp",void 0,0),Xs=O(g,"mp",void 0,0),Ys=O(g,"level",void 0,1),Qs=O(g,"xp",void 0,0),Zs=Ge(g.alive,yn>0),bn=r[R],xn=typeof bn=="string"?bn:void 0,ta=Ua(g.role,R,xn);return{id:R,name:m(g.name,R),role:ta,keeper:xn,archetype:m(g.archetype,""),persona:m(g.persona,""),traits:Te(g.traits),skills:Te(g.skills),status:Zs?"active":"dead",stats:{hp:yn,max_hp:B,mp:Xs,max_mp:Gs,level:Ys,xp:Qs,strength:O(g,"strength","str",10),dexterity:O(g,"dexterity","dex",10),constitution:O(g,"constitution","con",10),intelligence:O(g,"intelligence","int",10),wisdom:O(g,"wisdom","wis",10),charisma:O(g,"charisma","cha",10)}}}).filter(R=>R.status!=="dead"),c={phase_open:Ge(l.phase_open,!0),min_points:z(l.min_points,3),window:m(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},v=Object.entries(d).map(([R,L])=>{const g=P(L)?L:{};return{actor_id:R,score:z(g.score,0),last_reason:m(g.last_reason,"")||null,reasons:Te(g.reasons)}}),f=e.map(Ja),S=z(a.turn,1),D=m(a.phase,"round"),A=m(a.map,""),x=P(a.world)?a.world:{},k=A||m(x.ascii_map,m(x.map,"")),j=f.filter((R,L)=>{const g=e[L];if(!P(g))return!1;const B=P(g.payload)?g.payload:{};return z(B.turn,-1)===S}),U=(j.length>0?j:f).slice(-12),T=m(a.status,"active");return{session:{id:s,room:s,status:T==="ended"?"ended":T==="paused"?"paused":"active",round:S,actors:p,created_at:((nt=f[0])==null?void 0:nt.timestamp)??new Date().toISOString()},current_round:{round_number:S,phase:D,events:U,timestamp:((Y=f[f.length-1])==null?void 0:Y.timestamp)??new Date().toISOString()},map:k||void 0,join_gate:c,contribution_ledger:v,party:p,story_log:f,history:[]}}async function Va(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Wt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ga(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([Wt(`/api/v1/trpg/state${e}`),Va(t)]);return Wa(n,s,t)}function Xa(t){return Vt("/api/v1/trpg/rounds/run",{room_id:t})}function Ya(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Qa(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Vt("/api/v1/trpg/dice/roll",e)}function Za(t,e){const n=Ya();return Vt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function ti(t,e,n){const s=await F("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function ei(t){const e=await F("trpg.mid_join.request",t);return JSON.parse(e)}async function Is(t,e){await F("masc_broadcast",{agent_name:t,message:e})}async function ni(t,e,n=1){await F("masc_add_task",{title:t,description:e,priority:n})}async function si(t){return F("masc_join",{agent_name:t})}async function zs(t){await F("masc_leave",{agent_name:t})}async function ai(t){await F("masc_heartbeat",{agent_name:t})}async function ii(t=40){return(await F("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function oi(t,e=20){return F("masc_task_history",{task_id:t,limit:e})}async function ri(){const t=await F("masc_debates",{});return Ms(t)}async function li(){const t=await F("masc_sessions",{});return Ms(t)}async function ci(t){const e=await F("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function ui(t){return F("masc_debate_status",{debate_id:t})}const ht=_([]),Gt=_([]),Fs=_([]),yt=_([]),_n=_(null),kt=_(null),Xe=_(new Map),Os=_([]),Fn=_("hot"),Hs=_(null),pt=_(""),Ye=_(!1),Qe=_(!1),Ze=_(!1),di=_t(()=>ht.value.filter(t=>t.status==="active"||t.status==="idle")),Us=_t(()=>{const t=Gt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function pi(t){var a;const e=t.metrics_series;if(!e||e.length===0){const o=((a=t.status)==null?void 0:a.toLowerCase())??"";return o==="offline"||o==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const vi=_t(()=>{const t=new Map;for(const e of yt.value)t.set(e.name,pi(e));return t}),fi=12e4,_i=_t(()=>{const t=Date.now(),e=new Set,n=Xe.value;for(const s of yt.value){const a=n.get(s.name);a!=null&&t-a>fi&&e.add(s.name)}return e}),pe={},mi=5e3;function tn(){delete pe.compact,delete pe.full}function q(t){return typeof t=="object"&&t!==null}function $(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function h(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ct(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Bs(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function $i(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function gi(t){if(!q(t))return null;const e=$(t.name);return e?{name:e,status:Bs(t.status),current_task:$(t.current_task)??null,last_seen:$(t.last_seen),emoji:$(t.emoji),koreanName:$(t.koreanName)??$(t.korean_name),model:$(t.model),traits:Ct(t.traits),interests:Ct(t.interests),activityLevel:h(t.activityLevel)??h(t.activity_level),primaryValue:$(t.primaryValue)??$(t.primary_value)}:null}function hi(t){if(!q(t))return null;const e=$(t.id),n=$(t.title);return!e||!n?null:{id:e,title:n,status:$i(t.status),priority:h(t.priority),assignee:$(t.assignee),description:$(t.description),created_at:$(t.created_at),updated_at:$(t.updated_at)}}function yi(t){if(!q(t))return null;const e=$(t.from)??$(t.from_agent)??"system",n=$(t.content)??"",s=$(t.timestamp)??new Date().toISOString();return{id:$(t.id),seq:h(t.seq),from:e,content:n,timestamp:s,type:$(t.type)}}function bi(t){return Array.isArray(t)?t.map(e=>{if(!q(e))return null;const n=h(e.ts_unix);if(n==null)return null;const s=q(e.handoff)?e.handoff:null;return{ts:n,context_ratio:h(e.context_ratio)??0,context_tokens:h(e.context_tokens)??0,context_max:h(e.context_max)??0,latency_ms:h(e.latency_ms)??0,generation:h(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:h(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:h(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?h(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function xi(t){return(Array.isArray(t)?t:q(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!q(n))return null;const s=q(n.agent)?n.agent:null,a=q(n.context)?n.context:null,o=q(n.metrics_window)?n.metrics_window:void 0,r=$(n.name);if(!r)return null;const l=h(n.context_ratio)??h(a==null?void 0:a.context_ratio),d=$(n.status)??$(s==null?void 0:s.status)??"offline",u=Bs(d),p=$(n.model)??$(n.active_model)??$(n.primary_model),c=Ct(n.skill_secondary),v=a?{source:$(a.source),context_ratio:h(a.context_ratio),context_tokens:h(a.context_tokens),context_max:h(a.context_max),message_count:h(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,f=s?{name:$(s.name),status:$(s.status),current_task:$(s.current_task)??null,last_seen:$(s.last_seen)}:void 0,S=bi(n.metrics_series);return{name:r,emoji:$(n.emoji),koreanName:$(n.koreanName)??$(n.korean_name),agent_name:$(n.agent_name),trace_id:$(n.trace_id),model:p,primary_model:$(n.primary_model),active_model:$(n.active_model),next_model_hint:$(n.next_model_hint)??null,status:u,last_heartbeat:$(n.last_heartbeat)??$(s==null?void 0:s.last_seen),generation:h(n.generation),turn_count:h(n.turn_count)??h(n.total_turns),context_ratio:l,context_tokens:h(n.context_tokens)??h(a==null?void 0:a.context_tokens),context_max:h(n.context_max)??h(a==null?void 0:a.context_max),context_source:$(n.context_source)??$(a==null?void 0:a.source),context:v,traits:Ct(n.traits),interests:Ct(n.interests),primaryValue:$(n.primaryValue)??$(n.primary_value),activityLevel:h(n.activityLevel)??h(n.activity_level),memory_recent_note:$(n.memory_recent_note)??null,conversation_tail_count:h(n.conversation_tail_count),k2k_count:h(n.k2k_count),handoff_count_total:h(n.handoff_count_total)??h(n.trace_history_count),compaction_count:h(n.compaction_count),last_compaction_saved_tokens:h(n.last_compaction_saved_tokens),skill_primary:$(n.skill_primary)??null,skill_secondary:c,skill_reason:$(n.skill_reason)??null,metrics_series:S.length>0?S:void 0,metrics_window:o,agent:f}}).filter(n=>n!==null)}async function we(t="full"){var s,a,o;const e=Date.now(),n=pe[t];if(!(n&&e-n.time<mi)){Ye.value=!0;try{const r=await za(t);pe[t]={data:r,time:e},ht.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(gi).filter(l=>l!==null),Gt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(hi).filter(l=>l!==null),Fs.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(yi).filter(l=>l!==null),yt.value=xi(r.keepers),_n.value=q(r.status)?r.status:null,kt.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{Ye.value=!1}}}async function lt(){Qe.value=!0;try{const t=await Fa();Os.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{Qe.value=!1}}async function it(){var t;Ze.value=!0;try{const e=pt.value||((t=_n.value)==null?void 0:t.room)||"default";pt.value||(pt.value=e);const n=await Ga(e);Hs.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ze.value=!1}}let Ae=null,Ne=null;function ki(){return As.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Xe.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Xe.value=n}tn(),Ae||(Ae=setTimeout(()=>{we(),Ae=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Ne||(Ne=setTimeout(()=>{lt(),Ne=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&tn()}})}let Tt=null;function wi(){Tt||(Tt=setInterval(()=>{tn(),we()},1e4))}function Si(){Tt&&(clearInterval(Tt),Tt=null)}function b({title:t,class:e,children:n}){return i`
    <div class="card ${e??""}">
      ${t?i`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Z({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Ci(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function tt({timestamp:t}){const e=Ci(t);return i`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const mn=_(null);function Ks(t){mn.value=t}function On(){mn.value=null}function ae(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Ti({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ae(t.context_tokens)}</div>
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
  `}function Ai({keeper:t}){var p,c;const e=t.metrics_series??[];if(e.length<2){const v=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,f=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${f}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,r=e.map((v,f)=>{const S=a+f/(o-1)*(n-2*a),D=s-a-(v.context_ratio??0)*(s-2*a);return{x:S,y:D,p:v}}),l=r.map(({x:v,y:f})=>`${v.toFixed(1)},${f.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>i`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:f})=>i`
          <circle cx="${v.toFixed(1)}" cy="${f.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Re=_("");function Ni({keeper:t}){var a,o,r,l;const e=Re.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Re.value}
        onInput=${d=>{Re.value=d.target.value}}
      />
      ${s.map(d=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
        </div>
      `)}
      ${t.trace_id?i`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?i`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?i`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ae(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ae(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ae(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Ri({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>i`
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
  `}function Di({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Ei({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Hn({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function De(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Li({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:De(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:De(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:De(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Pi(){var e,n,s;const t=mn.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&On()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?i`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${Z} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>On()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Ti} keeper=${t} />

        ${""}
        <${Ai} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${b} title="Field Dictionary">
            <${Ni} keeper=${t} />
          <//>

          ${""}
          <${b} title="Profile">
            <${Hn} traits=${t.traits??[]} label="Traits" />
            <${Hn} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${tt} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?i`
              <${b} title="TRPG Stats">
                <${Ri} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${b} title="Equipment (${t.inventory.length})">
                <${Di} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${b} title="Relationships (${Object.keys(t.relationships).length})">
                <${Ei} rels=${t.relationships} />
              <//>
            `:null}

          <${b} title="Runtime Signals">
            <${Li} keeper=${t} />
          <//>

          <${b} title="Memory & Context">
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
              ${t.memory_recent_note?i`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:i`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
      </div>
    </div>
  `:null}let Mi=0;const at=_([]);function y(t,e="success",n=4e3){const s=++Mi;at.value=[...at.value,{id:s,message:t,type:e}],setTimeout(()=>{at.value=at.value.filter(a=>a.id!==s)},n)}function ji(t){at.value=at.value.filter(e=>e.id!==t)}function Ii(){const t=at.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>ji(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const zi="masc_dashboard_agent_name",bt=_(null),ve=_(!1),Ut=_(""),fe=_([]),Bt=_([]),vt=_(""),At=_(!1);function qs(t){bt.value=t,$n()}function Un(){bt.value=null,Ut.value="",fe.value=[],Bt.value=[],vt.value=""}function Fi(){const t=bt.value;return t?ht.value.find(e=>e.name===t)??null:null}function Js(t){return t?Gt.value.filter(e=>e.assignee===t):[]}async function $n(){const t=bt.value;if(t){ve.value=!0,Ut.value="",fe.value=[],Bt.value=[];try{const e=await ii(80);fe.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Js(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await oi(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Bt.value=s}catch(e){Ut.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{ve.value=!1}}}async function Bn(){var s;const t=bt.value,e=vt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(zi))==null?void 0:s.trim())||"dashboard";At.value=!0;try{await Is(n,`@${t} ${e}`),vt.value="",y(`Mention sent to ${t}`,"success"),$n()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";y(o,"error")}finally{At.value=!1}}function Oi({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Z} status=${t.status} />
    </div>
  `}function Hi({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Ui(){var a,o,r,l;const t=bt.value;if(!t)return null;const e=Fi(),n=Js(t),s=fe.value;return i`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Un()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?i`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?i`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?i`
                        <${Z} status=${e.status} />
                        ${e.model?i`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?i`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:i`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?i`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((a=e==null?void 0:e.traits)==null?void 0:a.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(o=e==null?void 0:e.traits)==null?void 0:o.map(d=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(d=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${tt} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{$n()}} disabled=${ve.value}>
              ${ve.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Un}>Close</button>
          </div>
        </div>

        ${Ut.value?i`<div class="council-error">${Ut.value}</div>`:null}

        <div class="agent-detail-grid">
          <${b} title="Assigned Tasks">
            ${n.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${n.map(d=>i`<${Oi} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${b} title="Recent Activity">
            ${s.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${s.map((d,u)=>i`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${b} title="Task History">
          ${Bt.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Bt.value.map(d=>i`<${Hi} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${b} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${vt.value}
              onInput=${d=>{vt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Bn()}}
              disabled=${At.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Bn()}}
              disabled=${At.value||vt.value.trim()===""}
            >
              ${At.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function ct({label:t,value:e,color:n}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Bi({agent:t}){return i`
    <div class="agent" onClick=${()=>qs(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${Z} status=${t.status} />
      ${t.current_task?i`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Ki(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function qi(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function Kn(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Ji({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=vi.value.get(t.name),a=_i.value.has(t.name);return i`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>Ks(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Z} status=${t.status} />
          ${s?i`<span class="pill pill-lifecycle pill-lifecycle-${s}">${s}</span>`:null}
          ${a?i`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?i`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?i`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?i`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${Kn(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${Kn(e)}">
              ${n}%
              ${t.context_tokens!=null?i` (${Ki(t.context_tokens)})`:null}
            </span>
          </div>
        `:null}

        <!-- Row 3: Operational metrics -->
        ${t.generation!=null?i`
          <div class="keeper-metrics-row">
            <span>Gen ${t.generation}</span>
            <span>T${t.turn_count??0}</span>
            ${(t.handoff_count_total??0)>0?i`<span class="keeper-metric-hl">↻${t.handoff_count_total}</span>`:null}
            ${(t.compaction_count??0)>0?i`<span class="keeper-metric-compact">◆${t.compaction_count}</span>`:null}
            ${(t.k2k_count??0)>0?i`<span>K2K:${t.k2k_count}</span>`:null}
            ${(t.conversation_tail_count??0)>0?i`<span>💬${t.conversation_tail_count}</span>`:null}
          </div>
        `:null}

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?i`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${tt} timestamp=${t.last_heartbeat} />
          </div>
        `:null}

        <!-- Row 5: Trait chips -->
        ${t.traits&&t.traits.length>0?i`
          <div class="keeper-trait-row">
            ${t.traits.slice(0,3).map(o=>i`<span class="keeper-trait-chip">${o}</span>`)}
            ${t.traits.length>3?i`<span class="keeper-trait-more">+${t.traits.length-3}</span>`:null}
          </div>
        `:null}

        <!-- Row 6: Memory note preview -->
        ${t.memory_recent_note?i`
          <div class="keeper-note-preview">${qi(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function qn(){const t=_n.value,e=ht.value,n=yt.value,s=Us.value;return i`
    <div class="stats-grid">
      <${ct} label="Agents" value=${e.length} />
      <${ct} label="Active" value=${di.value.length} color="#4ade80" />
      <${ct} label="Keepers" value=${n.length} color="#22d3ee" />
      <${ct} label="Tasks" value=${Gt.value.length} />
      <${ct} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${ct} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${b} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?i`<div class="empty-state">No agents connected</div>`:e.map(a=>i`<${Bi} key=${a.name} agent=${a} />`)}
        </div>
      <//>

      <${b} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?i`<div class="empty-state">No keepers active</div>`:n.map(a=>i`<${Ji} key=${a.name} keeper=${a} />`)}
        </div>
      <//>
    </div>

    ${kt.value?i`
        <${b} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${kt.value.running?"Running":"Stopped"}</span>
            ${kt.value.goal?i`<span>Goal: ${kt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?i`
        <${b} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?i`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?i`<span>Project: ${t.project}</span>`:null}
            ${t.version?i`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${Wi(t.uptime_seconds??0)}</span>
            ${t.paused?i`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?i`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?i`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
          </div>
        <//>
      `:null}
  `}function Wi(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const en=_([]),nn=_([]),Nt=_(""),_e=_(!1),Rt=_(!1),me=_(""),$e=_(null),Dt=_(""),sn=_(!1);async function an(){_e.value=!0,me.value="";try{const[t,e]=await Promise.all([ri(),li()]);en.value=t,nn.value=e}catch(t){me.value=t instanceof Error?t.message:"Failed to load council data"}finally{_e.value=!1}}async function Jn(){const t=Nt.value.trim();if(t){Rt.value=!0;try{const e=await ci(t);Nt.value="",y(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await an()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";y(n,"error")}finally{Rt.value=!1}}}async function Vi(t){$e.value=t,sn.value=!0,Dt.value="";try{Dt.value=await ui(t)}catch(e){Dt.value=e instanceof Error?e.message:"Failed to load debate status"}finally{sn.value=!1}}function Gi({debate:t}){const e=$e.value===t.id;return i`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Vi(t.id)}
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
  `}function Xi({session:t}){return i`
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
  `}function Yi(){return re(()=>{an()},[]),i`
    <div>
      <${b} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Nt.value}
            onInput=${t=>{Nt.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Jn()}}
            disabled=${Rt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Jn}
            disabled=${Rt.value||Nt.value.trim()===""}
          >
            ${Rt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${an} disabled=${_e.value}>
            ${_e.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${me.value?i`<div class="council-error">${me.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${b} title="Debates" class="section">
          <div class="council-list">
            ${en.value.length===0?i`<div class="empty-state">No debates yet</div>`:en.value.map(t=>i`<${Gi} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${b} title="Voting Sessions" class="section">
          <div class="council-list">
            ${nn.value.length===0?i`<div class="empty-state">No active sessions</div>`:nn.value.map(t=>i`<${Xi} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${b} title=${$e.value?`Debate Detail (${$e.value})`:"Debate Detail"} class="section">
        ${sn.value?i`<div class="loading-indicator">Loading debate detail...</div>`:Dt.value?i`<pre class="council-detail">${Dt.value}</pre>`:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Qi({text:t}){if(!t)return null;const e=Zi(t);return i`<div class="markdown-content">${e}</div>`}function Zi(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(i`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ee(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(i`<blockquote>${Ee(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),s++}o.length>0&&n.push(i`<p>${Ee(o.join(`
`))}</p>`)}return n}function Ee(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const to=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Et=_([]),Lt=_(!1),Pt=_(""),eo=_("dashboard-user"),Mt=_(!1);async function Ws(t){Lt.value=!0,Et.value=[];try{const e=await Oa(t);Et.value=e.comments??[]}catch{}finally{Lt.value=!1}}async function Wn(t){const e=Pt.value.trim();if(e){Mt.value=!0;try{await Ha(t,eo.value,e),Pt.value="",y("Comment posted","success"),await Ws(t),lt()}catch{y("Failed to post comment","error")}finally{Mt.value=!1}}}function no(){const t=Fn.value;return i`
    <div class="board-controls">
      ${to.map(e=>i`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{Fn.value=e.id,lt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Vs({flair:t}){return t?i`<span class="post-flair ${t}">${t}</span>`:null}function so({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await js(t.id,n),lt()}catch{y("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>ba(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Vs} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${tt} timestamp=${t.created_at} />
          ${t.comment_count>0?i`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function ao({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${tt} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function io({postId:t}){return i`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Pt.value}
        onInput=${e=>{Pt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Wn(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Mt.value}
      />
      <button
        onClick=${()=>Wn(t)}
        disabled=${Mt.value||Pt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Mt.value?"...":"Post"}
      </button>
    </div>
  `}function oo({post:t}){Et.value.length===0&&!Lt.value&&Ws(t.id);const e=async n=>{try{await js(t.id,n),lt()}catch{y("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>ke("board")}>← Back to Board</button>
      <${b} title=${i`${t.title} <${Vs} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Qi} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${tt} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${b} title="Comments (${Lt.value?"...":Et.value.length})">
        ${Lt.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${ao} comments=${Et.value} />`}
        <${io} postId=${t.id} />
      <//>
    </div>
  `}function ro(){const t=Os.value,e=Qe.value,n=X.value.postId;if(n){const s=t.find(a=>a.id===n);return s?i`<${oo} post=${s} />`:i`
          <div>
            <button class="back-btn" onClick=${()=>ke("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return i`
    <${no} />
    ${e?i`<div class="loading-indicator">Loading board...</div>`:t.length===0?i`<div class="empty-state">No posts yet</div>`:i`<div class="board-post-list">
            ${t.map(s=>i`<${so} key=${s.id} post=${s} />`)}
          </div>`}
  `}function lo(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function co(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function Vn(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function uo({row:t}){return i`
    <div class="message-row">
      <span class="message-agent">${t.actor}</span>
      <span class="message-source ${t.source}">${t.source}</span>
      <span class="message-text">${t.content}</span>
      <span class="message-time"><${tt} timestamp=${t.timestamp} /></span>
    </div>
  `}function po(){const t=Fs.value.map(lo),e=de.value.map(co),n=[...t,...e].sort((s,a)=>Vn(a.timestamp)-Vn(s.timestamp)).slice(0,80);return i`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${n.length===0?i`<div class="empty-state">No recent activity</div>`:n.map(s=>i`<${uo} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function vo({agent:t}){return i`
    <button class="agent-card ${t.status}" onClick=${()=>qs(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?i`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${Z} status=${t.status} />
      </div>
      ${t.current_task?i`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?i`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function fo({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return i`
    <div class="live-agent keeper-card" onClick=${()=>Ks(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Z} status=${t.status} />
          ${t.model?i`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?i`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="live-agent-meta">
          ${t.generation!=null?i`<span>Gen ${t.generation}</span>`:null}
          ${t.turn_count!=null?i`<span>Turn ${t.turn_count}</span>`:null}
          ${e!=null?i`<span class=${n?`${n}-metric`:""}>Ctx ${e}%</span>`:null}
        </div>
        ${e!=null?i`<div class="ctx-bar"><div class="ctx-fill ${n}" style="width: ${e}%"></div></div>`:null}
      </div>
    </div>
  `}function _o(){const t=ht.value,e=yt.value;return i`
    <div>
      ${e.length>0?i`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>i`<${fo} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?i`<div class="empty-state">No agents registered</div>`:i`
            <div class="agent-grid">
              ${t.map(n=>i`<${vo} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Le({task:t}){return i`
    <div class="task-row">
      <${Z} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?i`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?i`<${tt} timestamp=${t.created_at} />`:null}
    </div>
  `}function mo(){const{todo:t,inProgress:e,done:n}=Us.value;return i`
    <div class="grid-2col">
      <${b} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?i`<div class="empty-state">No tasks in progress</div>`:e.map(s=>i`<${Le} key=${s.id} task=${s} />`)}
        </div>
      <//>

      <${b} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?i`<div class="empty-state">No pending tasks</div>`:t.map(s=>i`<${Le} key=${s.id} task=${s} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?i`
        <${b} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(s=>i`<${Le} key=${s.id} task=${s} />`)}
            ${n.length>20?i`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function $o({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return i`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function go(){const t=de.value;return i`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?i`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>i`<${$o} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const xt=_(""),Pe=_("ability_check"),Me=_("10"),je=_("12"),Qt=_(""),Zt=_("idle"),te=_(""),ee=_("keeper-late"),Ie=_("player"),ze=_(""),H=_("idle"),Fe=_(null),on=_(null);function ho(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function yo(t,e){return e>0?Math.round(t/e*100):0}const bo={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},xo={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Oe(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function ko(t){const e=t.trim().toLowerCase();return bo[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function wo(t){const e=t.trim().toLowerCase();return xo[e]??"상황에 따라 선택되는 전술 액션입니다."}function ot(t){return typeof t=="object"&&t!==null}function I(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function V(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Kt(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}function So({hp:t,max:e}){const n=yo(t,e),s=ho(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Co({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function To({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Ao({actor:t}){var o,r;const e=(o=t.archetype)==null?void 0:o.trim(),n=(r=t.persona)==null?void 0:r.trim(),s=t.traits??[],a=t.skills??[];return i`
    <div class="trpg-actor">
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${Z} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${To} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${So} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Co} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${Oe(e)}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${s.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${s.map(l=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Oe(l)}</span>
                  <span class="trpg-annot-desc">${ko(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${a.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${a.map(l=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Oe(l)}</span>
                  <span class="trpg-annot-desc">${wo(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function No({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function Ro({events:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No story events yet</div>`:i`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var s;return i`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?i`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?i`<span class="trpg-dice">[${e.dice_roll.notation}: ${(s=e.dice_roll.rolls)==null?void 0:s.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${tt} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function Do({state:t}){const e=t.history??[];return e.length===0?null:i`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>i`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Eo({state:t}){var d;const e=pt.value||((d=t.session)==null?void 0:d.room)||"",n=Zt.value,s=t.party??[];if(!s.find(u=>u.id===xt.value)&&s.length>0){const u=s[0];u&&(xt.value=u.id)}const o=async()=>{if(!e){y("No room set","error");return}Zt.value="running";try{const u=await Xa(e);on.value=u,Zt.value="ok";const p=ot(u.summary)?u.summary:null,c=p?Kt(p,"advanced",!1):!1,v=p?I(p,"progress_reason",""):"";y(c?"Round advanced":`Round stalled${v?`: ${v}`:""}`,c?"success":"warning"),it()}catch(u){on.value=null,Zt.value="error";const p=u instanceof Error?u.message:"Round failed";y(p,"error")}},r=async()=>{if(e)try{await Za(e),y("Turn advanced","success"),it()}catch{y("Advance failed","error")}},l=async()=>{if(!e)return;const u=xt.value.trim();if(!u){y("Select actor first","warning");return}const p=Number.parseInt(Me.value,10),c=Number.parseInt(je.value,10);if(Number.isNaN(p)||Number.isNaN(c)){y("Stat/DC must be numbers","warning");return}const v=Number.parseInt(Qt.value,10),f=Qt.value.trim()===""||Number.isNaN(v)?void 0:v;try{await Qa({roomId:e,actorId:u,action:Pe.value.trim()||"ability_check",statValue:p,dc:c,rawD20:f}),y("Dice rolled","success"),it()}catch{y("Dice roll failed","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            type="text"
            value=${e}
            onInput=${u=>{pt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${xt.value}
            onChange=${u=>{xt.value=u.target.value}}
          >
            <option value="">Select actor</option>
            ${s.map(u=>i`<option value=${u.id}>${u.name} (${u.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              type="text"
              value=${Pe.value}
              onInput=${u=>{Pe.value=u.target.value}}
              placeholder="action"
            />
            <input
              type="text"
              value=${Me.value}
              onInput=${u=>{Me.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              type="text"
              value=${je.value}
              onInput=${u=>{je.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              type="text"
              value=${Qt.value}
              onInput=${u=>{Qt.value=u.target.value}}
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
              onClick=${o}
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

      ${n!=="idle"?i`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function Lo({state:t}){var l;const e=pt.value||((l=t.session)==null?void 0:l.room)||"",n=t.join_gate,s=Fe.value,a=ot(s)?s:null,o=async()=>{const d=te.value.trim(),u=ee.value.trim();if(!e||!d){y("Room/Actor is required","warning");return}H.value="checking";try{const p=await ti(e,d,u||void 0);Fe.value=p,H.value="ok",y("Eligibility updated","success")}catch(p){H.value="error";const c=p instanceof Error?p.message:"Eligibility check failed";y(c,"error")}},r=async()=>{const d=te.value.trim(),u=ee.value.trim(),p=ze.value.trim();if(!e||!d||!u){y("Room/Actor/Keeper is required","warning");return}H.value="requesting";try{const c=await ei({room_id:e,actor_id:d,keeper_name:u,role:Ie.value,...p?{name:p}:{}});Fe.value=c;const v=ot(c)?Kt(c,"granted",!1):!1,f=ot(c)?I(c,"reason_code",""):"";v?y("Mid-join granted","success"):y(`Mid-join rejected${f?`: ${f}`:""}`,"warning"),H.value=v?"ok":"error",it()}catch(c){H.value="error";const v=c instanceof Error?c.message:"Mid-join request failed";y(v,"error")}};return i`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${n!=null&&n.phase_open?"OPEN":"CLOSED"}</strong>
        ${n!=null&&n.window?i`<span style="margin-left:8px;">(${n.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(n==null?void 0:n.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <input
            type="text"
            value=${te.value}
            onInput=${d=>{te.value=d.target.value}}
            placeholder="player-xyz"
          />
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            type="text"
            value=${ee.value}
            onInput=${d=>{ee.value=d.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ie.value}
            onChange=${d=>{Ie.value=d.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Name (optional)</label>
          <input
            type="text"
            value=${ze.value}
            onInput=${d=>{ze.value=d.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${o} disabled=${H.value==="checking"||H.value==="requesting"}>
              ${H.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${r} disabled=${H.value==="checking"||H.value==="requesting"}>
              ${H.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${a?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Kt(a,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${V(a,"effective_score",0)}/${V(a,"required_points",0)}</span>
            ${I(a,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${I(a,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Po({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Mo({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function jo(){const t=on.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ot(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(ot).slice(-8),o=t.canon_check,r=ot(o)?o:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(T=>typeof T=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(T=>typeof T=="string").slice(0,3):[],u=n?Kt(n,"advanced",!1):!1,p=n?I(n,"progress_reason",""):"",c=n?I(n,"progress_detail",""):"",v=n?V(n,"player_successes",0):0,f=n?V(n,"player_required_successes",0):0,S=n?Kt(n,"dm_success",!1):!1,D=n?V(n,"timeouts",0):0,A=n?V(n,"unavailable",0):0,x=n?V(n,"reprompts",0):0,k=n?V(n,"npc_attacks",0):0,j=n?V(n,"keeper_timeout_sec",0):0,U=n?V(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${S?"DM ok":"DM stalled"} / players ${v}/${f}
          </span>
        </div>
        ${p?i`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${c?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${D}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${j||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${U}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(T=>{const W=I(T,"status","unknown"),nt=I(T,"actor_id","-"),Y=I(T,"role","-"),R=I(T,"reason",""),L=I(T,"action_type",""),g=I(T,"reply","");return i`
                <div class="trpg-round-item ${W.includes("fallback")||W.includes("timeout")?"failed":"active"}">
                  <span>${nt} (${Y})</span>
                  <span style="margin-left:auto; font-size:11px;">${W}</span>
                  ${L?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${L}</div>`:null}
                  ${R?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${R}</div>`:null}
                  ${g?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${g.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${I(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(T=>i`<div>violation: ${T}</div>`)}
                </div>`:null}
            ${l.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(T=>i`<div>warning: ${T}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Io(){var a,o;const t=Hs.value;if(Ze.value&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>it()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[];return i`
    <div>
      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((a=t.session)==null?void 0:a.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((o=t.current_round)==null?void 0:o.round_number)??0}</div>
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
      <${Mo} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${b} title="Story Log (${s.length})">
            <${Ro} events=${s} />
          <//>

          ${""}
          ${t.map?i`
              <${b} title="Map" style="margin-top:16px;">
                <${No} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${b} title="Controls">
            <${Eo} state=${t} />
          <//>

          <${b} title="Last Round Result" style="margin-top:16px;">
            <${jo} />
          <//>

          ${""}
          <${b} title="Mid-Join Gate" style="margin-top:16px;">
            <${Lo} state=${t} />
          <//>

          ${""}
          <${b} title="Contribution" style="margin-top:16px;">
            <${Po} state=${t} />
          <//>

          ${""}
          <${b} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(r=>i`<${Ao} key=${r.id??r.name} actor=${r} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?i`
              <${b} title="History (${t.history.length})" style="margin-top:16px;">
                <${Do} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const gn="masc_dashboard_agent_name";function zo(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(gn);return e??n??"dashboard"}const J=_(zo()),jt=_(""),It=_(""),ge=_(""),zt=_(!1),ut=_(!1),Ft=_(!1),Ot=_(!1),he=_(!1),Se=_(!1);function hn(t){const e=t.trim();J.value=e,e&&localStorage.setItem(gn,e)}function Fo(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function rn(){const t=J.value.trim();if(t){Ft.value=!0;try{const e=await si(t),n=Fo(e);n&&hn(n),Se.value=!0,y(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";y(n,"error")}finally{Ft.value=!1}}}async function Oo(){const t=J.value.trim();if(t){Ot.value=!0;try{await zs(t),Se.value=!1,y(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";y(n,"error")}finally{Ot.value=!1}}}async function Ho(){const t=J.value.trim();if(t)try{await zs(t)}catch{}localStorage.removeItem(gn),hn("dashboard"),Se.value=!1,await rn()}async function Uo(){const t=J.value.trim();if(t){he.value=!0;try{await ai(t),y("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";y(n,"error")}finally{he.value=!1}}}async function Gn(){const t=J.value.trim(),e=jt.value.trim();if(!(!t||!e)){zt.value=!0;try{await Is(t,e),jt.value="",y("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";y(s,"error")}finally{zt.value=!1}}}async function Bo(){const t=It.value.trim(),e=ge.value.trim()||"Created from dashboard";if(t){ut.value=!0;try{await ni(t,e,1),It.value="",ge.value="",y("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";y(s,"error")}finally{ut.value=!1}}}function Ko(){return re(()=>{rn()},[]),i`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${J.value}
        onInput=${t=>hn(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${jt.value}
          onInput=${t=>{jt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Gn()}}
          disabled=${zt.value}
        />
        <button
          class="control-btn"
          onClick=${Gn}
          disabled=${zt.value||jt.value.trim()===""||J.value.trim()===""}
        >
          ${zt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{rn()}}
          disabled=${Ft.value||J.value.trim()===""}
        >
          ${Ft.value?"Joining...":Se.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Oo()}}
          disabled=${Ot.value||J.value.trim()===""}
        >
          ${Ot.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Ho()}}
          disabled=${Ft.value||Ot.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Uo()}}
          disabled=${he.value||J.value.trim()===""}
        >
          ${he.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${It.value}
        onInput=${t=>{It.value=t.target.value}}
        disabled=${ut.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${ge.value}
        onInput=${t=>{ge.value=t.target.value}}
        disabled=${ut.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${Bo}
        disabled=${ut.value||It.value.trim()===""}
      >
        ${ut.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function qo(){const t=mt.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${vn.value} events</span>
    </div>
  `}const Jo=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function Wo(){const t=X.value.tab,e=mt.value;return i`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Jo.map(n=>i`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>ke(n.id)}
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
            <strong>${ht.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${yt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${Gt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${vn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{we(),t==="board"&&lt(),t==="trpg"&&it()}}
        >
          Refresh Now
        </button>
      </section>

      <${Ko} />
    </aside>
  `}function Vo(){switch(X.value.tab){case"overview":return i`<${qn} />`;case"council":return i`<${Yi} />`;case"board":return i`<${ro} />`;case"activity":return i`<${po} />`;case"agents":return i`<${_o} />`;case"tasks":return i`<${mo} />`;case"journal":return i`<${go} />`;case"trpg":return i`<${Io} />`;default:return i`<${qn} />`}}function Go(){return re(()=>{xa(),Rs(),we();const t=ki();return wi(),()=>{Da(),t(),Si()}},[]),re(()=>{const t=X.value.tab;t==="board"&&lt(),t==="trpg"&&it()},[X.value.tab]),i`
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
          <${qo} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${wa} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Ye.value&&!mt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${Vo} />`}
        </main>
        <${Wo} />
      </div>

      <${Pi} />
      <${Ui} />
      <${Ii} />
    </div>
  `}const Xn=document.getElementById("app");Xn&&oa(i`<${Go} />`,Xn);
