(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var xe,C,Zn,ts,nt,wn,es,ns,ss,cn,Be,qe,Ut={},as=[],sa=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,ke=Array.isArray;function Q(t,e){for(var n in e)t[n]=e[n];return t}function un(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function is(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?xe.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return ae(t,r,s,a,null)}function ae(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++Zn,__i:-1,__u:0};return a==null&&C.vnode!=null&&C.vnode(i),i}function Wt(t){return t.children}function St(t,e){this.props=t,this.context=e}function vt(t,e){if(e==null)return t.__?vt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?vt(t):null}function os(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return os(t)}}function Sn(t){(!t.__d&&(t.__d=!0)&&nt.push(t)&&!re.__r++||wn!=C.debounceRendering)&&((wn=C.debounceRendering)||es)(re)}function re(){for(var t,e,n,s,a,i,r,c=1;nt.length;)nt.length>c&&nt.sort(ns),t=nt.shift(),c=nt.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=Q({},s)).__v=s.__v+1,C.vnode&&C.vnode(n),dn(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??vt(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,cs(i,n,r),s.__e=s.__=null,n.__e!=a&&os(n)));re.__r=0}function rs(t,e,n,s,a,i,r,c,d,u,p){var l,v,_,b,D,T,S,k=s&&s.__k||as,F=e.length;for(d=aa(n,e,k,d,F),l=0;l<F;l++)(_=n.__k[l])!=null&&(v=_.__i==-1?Ut:k[_.__i]||Ut,_.__i=l,T=dn(t,_,v,a,i,r,c,d,u,p),b=_.__e,_.ref&&v.ref!=_.ref&&(v.ref&&pn(v.ref,null,_),p.push(_.ref,_.__c||b,_)),D==null&&b!=null&&(D=b),(S=!!(4&_.__u))||v.__k===_.__k?d=ls(_,d,t,S):typeof _.type=="function"&&T!==void 0?d=T:b&&(d=b.nextSibling),_.__u&=-7);return n.__e=D,d}function aa(t,e,n,s,a){var i,r,c,d,u,p=n.length,l=p,v=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=ae(null,r,null,null,null):ke(r)?r=t.__k[i]=ae(Wt,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=ae(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+v,r.__=t,r.__b=t.__b+1,c=null,(u=r.__i=ia(r,n,d,l))!=-1&&(l--,(c=n[u])&&(c.__u|=2)),c==null||c.__v==null?(u==-1&&(a>p?v--:a<p&&v++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?v--:u==d+1?v++:(u>d?v--:v++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<p;i++)(c=n[i])!=null&&(2&c.__u)==0&&(c.__e==s&&(s=vt(c)),ds(c,c));return s}function ls(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=ls(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=vt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function ia(t,e,n,s){var a,i,r,c=t.key,d=t.type,u=e[n],p=u!=null&&(2&u.__u)==0;if(u===null&&c==null||p&&c==u.key&&d==u.type)return n;if(s>(p?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((u=e[r=a>=0?a--:i++])!=null&&(2&u.__u)==0&&c==u.key&&d==u.type)return r}return-1}function Cn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||sa.test(e)?n:n+"px"}function Qt(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||Cn(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||Cn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(ss,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=cn,t.addEventListener(e,i?qe:Be,i)):t.removeEventListener(e,i?qe:Be,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Tn(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=cn++;else if(e.t<n.u)return;return n(C.event?C.event(e):e)}}}function dn(t,e,n,s,a,i,r,c,d,u){var p,l,v,_,b,D,T,S,k,F,O,A,H,xt,Y,q,L,N=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[c=e.__e=n.__e]),(p=C.__b)&&p(e);t:if(typeof N=="function")try{if(S=e.props,k="prototype"in N&&N.prototype.render,F=(p=N.contextType)&&s[p.__c],O=p?F?F.props.value:p.__:s,n.__c?T=(l=e.__c=n.__c).__=l.__E:(k?e.__c=l=new N(S,O):(e.__c=l=new St(S,O),l.constructor=N,l.render=ra),F&&F.sub(l),l.state||(l.state={}),l.__n=s,v=l.__d=!0,l.__h=[],l._sb=[]),k&&l.__s==null&&(l.__s=l.state),k&&N.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=Q({},l.__s)),Q(l.__s,N.getDerivedStateFromProps(S,l.__s))),_=l.props,b=l.state,l.__v=e,v)k&&N.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),k&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(k&&N.getDerivedStateFromProps==null&&S!==_&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(S,O),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(S,l.__s,O)===!1){for(e.__v!=n.__v&&(l.props=S,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(g){g&&(g.__=e)}),A=0;A<l._sb.length;A++)l.__h.push(l._sb[A]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(S,l.__s,O),k&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(_,b,D)})}if(l.context=O,l.props=S,l.__P=t,l.__e=!1,H=C.__r,xt=0,k){for(l.state=l.__s,l.__d=!1,H&&H(e),p=l.render(l.props,l.state,l.context),Y=0;Y<l._sb.length;Y++)l.__h.push(l._sb[Y]);l._sb=[]}else do l.__d=!1,H&&H(e),p=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++xt<25);l.state=l.__s,l.getChildContext!=null&&(s=Q(Q({},s),l.getChildContext())),k&&!v&&l.getSnapshotBeforeUpdate!=null&&(D=l.getSnapshotBeforeUpdate(_,b)),q=p,p!=null&&p.type===Wt&&p.key==null&&(q=us(p.props.children)),c=rs(t,ke(q)?q:[q],e,n,s,a,i,r,c,d,u),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),T&&(l.__E=l.__=null)}catch(g){if(e.__v=null,d||i!=null)if(g.then){for(e.__u|=d?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;i[i.indexOf(c)]=null,e.__e=c}else{for(L=i.length;L--;)un(i[L]);Ke(e)}else e.__e=n.__e,e.__k=n.__k,g.then||Ke(e);C.__e(g,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=oa(n.__e,e,n,s,a,i,r,d,u);return(p=C.diffed)&&p(e),128&e.__u?void 0:c}function Ke(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Ke)}function cs(t,e,n){for(var s=0;s<n.length;s++)pn(n[s],n[++s],n[++s]);C.__c&&C.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){C.__e(i,a.__v)}})}function us(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:ke(t)?t.map(us):Q({},t)}function oa(t,e,n,s,a,i,r,c,d){var u,p,l,v,_,b,D,T=n.props||Ut,S=e.props,k=e.type;if(k=="svg"?a="http://www.w3.org/2000/svg":k=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((_=i[u])&&"setAttribute"in _==!!k&&(k?_.localName==k:_.nodeType==3)){t=_,i[u]=null;break}}if(t==null){if(k==null)return document.createTextNode(S);t=document.createElementNS(a,k,S.is&&S),c&&(C.__m&&C.__m(e,i),c=!1),i=null}if(k==null)T===S||c&&t.data==S||(t.data=S);else{if(i=i&&xe.call(t.childNodes),!c&&i!=null)for(T={},u=0;u<t.attributes.length;u++)T[(_=t.attributes[u]).name]=_.value;for(u in T)if(_=T[u],u!="children"){if(u=="dangerouslySetInnerHTML")l=_;else if(!(u in S)){if(u=="value"&&"defaultValue"in S||u=="checked"&&"defaultChecked"in S)continue;Qt(t,u,null,_,a)}}for(u in S)_=S[u],u=="children"?v=_:u=="dangerouslySetInnerHTML"?p=_:u=="value"?b=_:u=="checked"?D=_:c&&typeof _!="function"||T[u]===_||Qt(t,u,_,T[u],a);if(p)c||l&&(p.__html==l.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(l&&(t.innerHTML=""),rs(e.type=="template"?t.content:t,ke(v)?v:[v],e,n,s,k=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&vt(n,0),c,d),i!=null)for(u=i.length;u--;)un(i[u]);c||(u="value",k=="progress"&&b==null?t.removeAttribute("value"):b!=null&&(b!==t[u]||k=="progress"&&!b||k=="option"&&b!=T[u])&&Qt(t,u,b,T[u],a),u="checked",D!=null&&D!=t[u]&&Qt(t,u,D,T[u],a))}return t}function pn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){C.__e(a,n)}}function ds(t,e,n){var s,a;if(C.unmount&&C.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||pn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){C.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&ds(s[a],e,n||typeof t.type!="function");n||un(t.__e),t.__c=t.__=t.__e=void 0}function ra(t,e,n){return this.constructor(t,n)}function la(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),C.__&&C.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],dn(e,t=e.__k=is(Wt,null,[t]),a||Ut,Ut,e.namespaceURI,a?null:e.firstChild?xe.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),cs(i,t,r)}xe=as.slice,C={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(c){t=c}throw t}},Zn=0,ts=function(t){return t!=null&&t.constructor===void 0},St.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=Q({},this.state),typeof t=="function"&&(t=t(Q({},n),this.props)),t&&Q(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Sn(this))},St.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Sn(this))},St.prototype.render=Wt,nt=[],es=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,ns=function(t,e){return t.__v.__b-e.__v.__b},re.__r=0,ss=/(PointerCapture)$|Capture$/i,cn=0,Be=Tn(!1),qe=Tn(!0);var ps=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],c=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=c:r===4?s[1]=Object.assign(s[1]||{},c):r===5?(s[1]=s[1]||{})[e[++i]]=c:r===6?s[1][e[++i]]+=c+"":r?(a=t.apply(c,ps(t,c,n,["",null])),s.push(a),c[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(c)}return s},An=new Map;function ca(t){var e=An.get(this);return e||(e=new Map,An.set(this,e)),(e=ps(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",c="",d=[0],u=function(v){i===1&&(v||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,v,r):i===3&&(v||r)?(d.push(3,v,r),i=2):i===2&&r==="..."&&v?d.push(4,v,0):i===2&&r&&!v?d.push(5,0,!0,r):i>=5&&((r||!v&&i===5)&&(d.push(i,0,r,a),i=6),v&&(d.push(i,v,0,a),i=6)),r=""},p=0;p<n.length;p++){p&&(i===1&&u(),u(p));for(var l=0;l<n[p].length;l++)s=n[p][l],i===1?s==="<"?(u(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:c?s===c?c="":r+=s:s==='"'||s==="'"?c=s:s===">"?(u(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[p][l+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=ca.bind(is),le,j,Ae,Nn,Rn=0,vs=[],R=C,Dn=R.__b,En=R.__r,Ln=R.diffed,Pn=R.__c,Mn=R.unmount,jn=R.__;function fs(t,e){R.__h&&R.__h(j,t,Rn||e),Rn=0;var n=j.__H||(j.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function ce(t,e){var n=fs(le++,3);!R.__s&&ms(n.__H,e)&&(n.__=t,n.u=e,j.__H.__h.push(n))}function _s(t,e){var n=fs(le++,7);return ms(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function ua(){for(var t;t=vs.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(ie),t.__H.__h.forEach(Je),t.__H.__h=[]}catch(e){t.__H.__h=[],R.__e(e,t.__v)}}R.__b=function(t){j=null,Dn&&Dn(t)},R.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),jn&&jn(t,e)},R.__r=function(t){En&&En(t),le=0;var e=(j=t.__c).__H;e&&(Ae===j?(e.__h=[],j.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(ie),e.__h.forEach(Je),e.__h=[],le=0)),Ae=j},R.diffed=function(t){Ln&&Ln(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(vs.push(e)!==1&&Nn===R.requestAnimationFrame||((Nn=R.requestAnimationFrame)||da)(ua)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Ae=j=null},R.__c=function(t,e){e.some(function(n){try{n.__h.forEach(ie),n.__h=n.__h.filter(function(s){return!s.__||Je(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],R.__e(s,n.__v)}}),Pn&&Pn(t,e)},R.unmount=function(t){Mn&&Mn(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{ie(s)}catch(a){e=a}}),n.__H=void 0,e&&R.__e(e,n.__v))};var In=typeof requestAnimationFrame=="function";function da(t){var e,n=function(){clearTimeout(s),In&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);In&&(e=requestAnimationFrame(n))}function ie(t){var e=j,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),j=e}function Je(t){var e=j;t.__c=t.__(),j=e}function ms(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}var pa=Symbol.for("preact-signals");function we(){if(et>1)et--;else{for(var t,e=!1;Ct!==void 0;){var n=Ct;for(Ct=void 0,We++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&hs(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(We=0,et--,e)throw t}}function va(t){if(et>0)return t();et++;try{return t()}finally{we()}}var w=void 0;function $s(t){var e=w;w=void 0;try{return t()}finally{w=e}}var Ct=void 0,et=0,We=0,ue=0;function gs(t){if(w!==void 0){var e=t.n;if(e===void 0||e.t!==w)return e={i:0,S:t,p:w.s,n:void 0,t:w,e:void 0,x:void 0,r:e},w.s!==void 0&&(w.s.n=e),w.s=e,t.n=e,32&w.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=w.s,e.n=void 0,w.s.n=e,w.s=e),e}}function E(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}E.prototype.brand=pa;E.prototype.h=function(){return!0};E.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:$s(function(){var s;(s=e.W)==null||s.call(e)}))};E.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&$s(function(){var a;(a=e.Z)==null||a.call(e)}))}};E.prototype.subscribe=function(t){var e=this;return Vt(function(){var n=e.value,s=w;w=void 0;try{t(n)}finally{w=s}},{name:"sub"})};E.prototype.valueOf=function(){return this.value};E.prototype.toString=function(){return this.value+""};E.prototype.toJSON=function(){return this.value};E.prototype.peek=function(){var t=w;w=void 0;try{return this.value}finally{w=t}};Object.defineProperty(E.prototype,"value",{get:function(){var t=gs(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(We>100)throw new Error("Cycle detected");this.v=t,this.i++,ue++,et++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{we()}}}});function f(t,e){return new E(t,e)}function hs(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function ys(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function bs(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function ot(t,e){E.call(this,void 0),this.x=t,this.s=void 0,this.g=ue-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}ot.prototype=new E;ot.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ue))return!0;if(this.g=ue,this.f|=1,this.i>0&&!hs(this))return this.f&=-2,!0;var t=w;try{ys(this),w=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return w=t,bs(this),this.f&=-2,!0};ot.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}E.prototype.S.call(this,t)};ot.prototype.U=function(t){if(this.t!==void 0&&(E.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};ot.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(ot.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=gs(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function ft(t,e){return new ot(t,e)}function xs(t){var e=t.u;if(t.u=void 0,typeof e=="function"){et++;var n=w;w=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,vn(t),s}finally{w=n,we()}}}function vn(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,xs(t)}function fa(t){if(w!==this)throw new Error("Out-of-order effect");bs(this),w=t,this.f&=-2,8&this.f&&vn(this),we()}function mt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}mt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};mt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,xs(this),ys(this),et++;var t=w;return w=this,fa.bind(this,t)};mt.prototype.N=function(){2&this.f||(this.f|=2,this.o=Ct,Ct=this)};mt.prototype.d=function(){this.f|=8,1&this.f||vn(this)};mt.prototype.dispose=function(){this.d()};function Vt(t,e){var n=new mt(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var ks,Zt,_a=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,ws=[];Vt(function(){ks=this.N})();function $t(t,e){C[t]=e.bind(null,C[t]||function(){})}function de(t){if(Zt){var e=Zt;Zt=void 0,e()}Zt=t&&t.S()}function Ss(t){var e=this,n=t.data,s=$a(n);s.value=n;var a=_s(function(){for(var c=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=ft(function(){var _=s.value.value;return _===0?0:_===!0?"":_||""}),p=ft(function(){return!Array.isArray(u.value)&&!ts(u.value)}),l=Vt(function(){if(this.N=Cs,p.value){var _=u.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=_)}}),v=e.__$u.d;return e.__$u.d=function(){l(),v.call(this)},[p,u]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}Ss.displayName="ReactiveTextNode";Object.defineProperties(E.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Ss},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});$t("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof E&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});$t("__r",function(t,e){if(t(e),e.type!==Wt){de();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return Vt(function(){r=this},{name:i}),r.c=a,r})(function(){var a;_a&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),de(n)}});$t("__e",function(t,e,n,s){de(),t(e,n,s)});$t("diffed",function(t,e){de();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var c=i[r];c!==void 0&&!(r in s)&&(c.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var u=i[d],p=s[d];u===void 0?(u=ma(n,d,p),i[d]=u):u.o(p,a)}for(var l in s)a[l]=s[l]}}t(e)});function ma(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(c,d){i.value=c,r=c.peek()},d:Vt(function(){this.N=Cs;var c=i.value.value;r!==c?(r=void 0,a?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):r=void 0})}}$t("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var c=r.__$u;c&&(r.__$u=void 0,c.d())}}t(e)});$t("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});St.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function $a(t,e){return _s(function(){return f(t,e)},[])}var ga=function(t){queueMicrotask(function(){queueMicrotask(t)})};function ha(){va(function(){for(var t;t=ws.shift();)ks.call(t)})}function Cs(){ws.push(this)===1&&(C.requestAnimationFrame||ga)(ha)}const ya=["overview","board","activity","agents","tasks","journal","trpg","council"],Ts={tab:"overview",params:{},postId:null};function zn(t){return!!t&&ya.includes(t)}function Ve(t){try{return decodeURIComponent(t)}catch{return t}}function Ge(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function ba(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function As(t,e){const n=t[0],s=e.tab,a=zn(n)?n:zn(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Ve(t[2]):t[0]==="post"&&t[1]&&(i=Ve(t[1]))),{tab:a,params:e,postId:i}}function pe(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Ts;const n=Ve(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Ge(a),r=ba(s);return As(r,i)}function xa(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Ts,params:Ge(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ge(e.replace(/^\?/,""));return As(s,a)}function Ns(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const X=f(pe(window.location.hash));window.addEventListener("hashchange",()=>{X.value=pe(window.location.hash)});function Se(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Ns(n)}function ka(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function wa(){if(window.location.hash&&window.location.hash!=="#"){X.value=pe(window.location.hash);return}const t=xa(window.location.pathname,window.location.search);if(t){X.value=t;const e=Ns(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",X.value=pe(window.location.hash)}const Sa=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function Ca(){const t=X.value.tab;return o`
    <div class="main-tab-bar">
      ${Sa.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Se(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Fn="masc_dashboard_sse_session_id",Ta=1e3,Aa=15e3,_t=f(!1),fn=f(0),Rs=f(null),ve=f([]);function Na(){let t=sessionStorage.getItem(Fn);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Fn,t)),t}const Ra=200;function K(t,e){const n={agent:t,text:e,timestamp:Date.now()};ve.value=[n,...ve.value].slice(0,Ra)}let G=null,ut=null,Xe=0;function Ds(){ut&&(clearTimeout(ut),ut=null)}function Da(){if(ut)return;Xe++;const t=Math.min(Xe,5),e=Math.min(Aa,Ta*Math.pow(2,t));ut=setTimeout(()=>{ut=null,Es()},e)}function Es(){Ds(),G&&(G.close(),G=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Na());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);G=i,i.onopen=()=>{G===i&&(Xe=0,_t.value=!0)},i.onerror=()=>{G===i&&(_t.value=!1,i.close(),G=null,Da())},i.onmessage=r=>{try{const c=JSON.parse(r.data);fn.value++,Rs.value=c,Ea(c)}catch{}}}function Ea(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":K(n,"Joined");break;case"agent_left":K(n,"Left");break;case"broadcast":K(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":K(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":K(n,"New post");break;case"board_comment":K(n,"New comment");break;case"keeper_heartbeat":K(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":K(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":K(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":K(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:K(n,e)}}function La(){Ds(),G&&(G.close(),G=null),_t.value=!1}function Ls(){return new URLSearchParams(window.location.search)}function Ps(){const t=Ls(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Ms(){return{...Ps(),"Content-Type":"application/json"}}const Pa=15e3,js=3e4,Ma=6e4;async function _n(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(a)}}function ja(){var e,n;const t=Ls();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function gt(t){const e=await _n(t,{headers:Ps()},Pa);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function Gt(t,e){const n=await _n(t,{method:"POST",headers:Ms(),body:JSON.stringify(e)},js);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function Ia(t,e,n,s=js){const a=await _n(t,{method:"POST",headers:{...Ms(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function za(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Fa(t){var e,n,s,a,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function z(t,e){const n=await Ia("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Ma),s=za(n);return Fa(s)}function Is(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function Oa(t="compact"){return gt(`/api/v1/dashboard?mode=${t}`)}function Ha(){return gt("/api/v1/board")}function Ua(t){return gt(`/api/v1/board/${t}`)}function zs(t,e){return Gt("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:ja()})}function Ba(t,e,n){return Gt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function P(t){return typeof t=="object"&&t!==null}function m(t,e=""){return typeof t=="string"?t:e}function M(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Bt(t,e=!1){return typeof t=="boolean"?t:e}function Ne(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(P(e)){const n=m(e.name,"").trim(),s=m(e.id,"").trim(),a=m(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function qa(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function U(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}function Ka(t,e){if(t!=="dice.rolled")return;const n=M(e.raw_d20,0),s=M(e.total,0),a=M(e.bonus,0),i=m(e.action,"roll"),r=M(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Ja(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Wa(t,e,n){const s=e||m(n.actor_id,"");switch(t){case"turn.action.proposed":{const a=m(n.proposed_action,m(n.reply,""));return a?`${s||"actor"}: ${a}`:"Action proposed"}case"turn.action.resolved":{const a=m(n.reply,m(n.result,""));return a?`Resolved: ${a}`:"Action resolved"}case"narration.posted":return m(n.reply,m(n.content,m(n.text,"Narration")));case"dice.rolled":{const a=m(n.action,"roll"),i=M(n.total,0),r=M(n.dc,0),c=m(n.label,""),d=s||"actor",u=r>0?` vs DC ${r}`:"",p=c?` (${c})`:"";return`${d} ${a}: ${i}${u}${p}`}case"turn.started":return`Turn ${M(n.turn,1)} started`;case"phase.changed":return`Phase: ${m(n.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${m(n.name,s||"unknown")}`;case"actor.claimed":return`${m(n.keeper_name,m(n.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${m(n.keeper_name,m(n.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${M(n.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${M(n.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||m(n.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||m(n.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${m(n.reason_code,"unknown")}`;case"memory.signal":{const a=P(n.entity_refs)?n.entity_refs:{},i=m(a.requested_tier,""),r=m(a.effective_tier,""),c=Bt(a.guardrail_applied,!1),d=m(n.summary_en,m(n.summary_ko,"Memory signal"));if(!i&&!r)return d;const u=i&&r?`${i}->${r}`:r||i;return`${d} [${u}${c?" (guardrail)":""}]`}case"world.event":{if(m(n.event_type,"")==="canon.check"){const i=m(n.status,"unknown"),r=m(n.contract_id,"n/a");return`Canon ${i}: ${r}`}return m(n.description,m(n.summary,"World event"))}case"combat.attack":return m(n.summary,m(n.result,"Attack resolved"));case"combat.defense":return m(n.summary,m(n.result,"Defense resolved"));case"session.outcome":return m(n.summary,m(n.outcome,"Session ended"));default:{const a=Ja(n);return a?`${t}: ${a}`:t}}}function Va(t){const e=P(t)?t:{},n=m(e.type,"event"),s=typeof e.actor_id=="string"?e.actor_id:"",a=P(e.payload)?e.payload:{};return{type:n,actor:s||m(a.actor_id,""),content:Wa(n,s,a),dice_roll:Ka(n,a),timestamp:m(e.ts,new Date().toISOString())}}function Ga(t,e,n,s){var Y,q;const a=m(t.room_id,"")||n||"default",i=P(t.state)?t.state:{},r=P(i.party)?i.party:{},c=P(i.actor_control)?i.actor_control:{},d=P(i.join_gate)?i.join_gate:{},u=P(i.contribution_ledger)?i.contribution_ledger:{},l=Object.entries(r).map(([L,N])=>{const g=P(N)?N:{},Yt=U(g,"max_hp",void 0,10),bn=U(g,"hp",void 0,Yt),Ys=U(g,"max_mp",void 0,0),Qs=U(g,"mp",void 0,0),Zs=U(g,"level",void 0,1),ta=U(g,"xp",void 0,0),ea=Bt(g.alive,bn>0),xn=c[L],kn=typeof xn=="string"?xn:void 0,na=qa(g.role,L,kn);return{id:L,name:m(g.name,L),role:na,keeper:kn,archetype:m(g.archetype,""),persona:m(g.persona,""),traits:Ne(g.traits),skills:Ne(g.skills),status:ea?"active":"dead",stats:{hp:bn,max_hp:Yt,mp:Qs,max_mp:Ys,level:Zs,xp:ta,strength:U(g,"strength","str",10),dexterity:U(g,"dexterity","dex",10),constitution:U(g,"constitution","con",10),intelligence:U(g,"intelligence","int",10),wisdom:U(g,"wisdom","wis",10),charisma:U(g,"charisma","cha",10)}}}).filter(L=>L.status!=="dead"),v={phase_open:Bt(d.phase_open,!0),min_points:M(d.min_points,3),window:m(d.window,"round_boundary_only"),last_opened_turn:typeof d.last_opened_turn=="number"?d.last_opened_turn:null,last_closed_turn:typeof d.last_closed_turn=="number"?d.last_closed_turn:null},_=Object.entries(u).map(([L,N])=>{const g=P(N)?N:{};return{actor_id:L,score:M(g.score,0),last_reason:m(g.last_reason,"")||null,reasons:Ne(g.reasons)}}),b=e.map(Va),D=M(i.turn,1),T=m(i.phase,"round"),S=m(i.map,""),k=P(i.world)?i.world:{},F=S||m(k.ascii_map,m(k.map,"")),O=b.filter((L,N)=>{const g=e[N];if(!P(g))return!1;const Yt=P(g.payload)?g.payload:{};return M(Yt.turn,-1)===D}),A=(O.length>0?O:b).slice(-12),H=m(i.status,"active");return{session:{id:a,room:a,status:H==="ended"?"ended":H==="paused"?"paused":"active",round:D,actors:l,created_at:((Y=b[0])==null?void 0:Y.timestamp)??new Date().toISOString()},current_round:{round_number:D,phase:T,events:A,timestamp:((q=b[b.length-1])==null?void 0:q.timestamp)??new Date().toISOString()},map:F||void 0,join_gate:v,contribution_ledger:_,party:l,story_log:b,history:s??[]}}async function Xa(){try{const t=await gt("/api/v1/trpg/sessions");return(Array.isArray(t.sessions)?t.sessions:[]).map(n=>P(n)?{room_id:m(n.room_id,""),first_ts:m(n.first_ts,""),last_ts:m(n.last_ts,""),event_count:M(n.event_count,0),last_seq:M(n.last_seq,0),ended:Bt(n.ended,!1),current:Bt(n.current,!1)}:null).filter(n=>n!==null)}catch{return[]}}async function Ya(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await gt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Qa(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s,a]=await Promise.all([gt(`/api/v1/trpg/state${e}`),Ya(t),Xa()]);return Ga(n,s,t,a)}function Za(t){return Gt("/api/v1/trpg/rounds/run",{room_id:t})}function ti(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function ei(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Gt("/api/v1/trpg/dice/roll",e)}function ni(t,e){const n=ti();return Gt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function si(t,e,n){const s=await z("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function ai(t){const e=await z("trpg.mid_join.request",t);return JSON.parse(e)}async function Fs(t,e){await z("masc_broadcast",{agent_name:t,message:e})}async function ii(t,e,n=1){await z("masc_add_task",{title:t,description:e,priority:n})}async function oi(t){return z("masc_join",{agent_name:t})}async function Os(t){await z("masc_leave",{agent_name:t})}async function ri(t){await z("masc_heartbeat",{agent_name:t})}async function li(t=40){return(await z("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function ci(t,e=20){return z("masc_task_history",{task_id:t,limit:e})}async function ui(){const t=await z("masc_debates",{});return Is(t)}async function di(){const t=await z("masc_sessions",{});return Is(t)}async function pi(t){const e=await z("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function vi(t){return z("masc_debate_status",{debate_id:t})}const ht=f([]),Xt=f([]),Hs=f([]),yt=f([]),mn=f(null),wt=f(null),Ye=f(new Map),Us=f([]),On=f("hot"),Bs=f(null),dt=f(""),Qe=f(!1),Ze=f(!1),tn=f(!1),fi=ft(()=>ht.value.filter(t=>t.status==="active"||t.status==="idle")),qs=ft(()=>{const t=Xt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function _i(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const mi=ft(()=>{const t=new Map;for(const e of yt.value)t.set(e.name,_i(e));return t}),$i=12e4,gi=ft(()=>{const t=Date.now(),e=new Set,n=Ye.value;for(const s of yt.value){const a=n.get(s.name);a!=null&&t-a>$i&&e.add(s.name)}return e}),fe={},hi=5e3;function en(){delete fe.compact,delete fe.full}function J(t){return typeof t=="object"&&t!==null}function $(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function h(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Tt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ks(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function yi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function bi(t){if(!J(t))return null;const e=$(t.name);return e?{name:e,status:Ks(t.status),current_task:$(t.current_task)??null,last_seen:$(t.last_seen),emoji:$(t.emoji),koreanName:$(t.koreanName)??$(t.korean_name),model:$(t.model),traits:Tt(t.traits),interests:Tt(t.interests),activityLevel:h(t.activityLevel)??h(t.activity_level),primaryValue:$(t.primaryValue)??$(t.primary_value)}:null}function xi(t){if(!J(t))return null;const e=$(t.id),n=$(t.title);return!e||!n?null:{id:e,title:n,status:yi(t.status),priority:h(t.priority),assignee:$(t.assignee),description:$(t.description),created_at:$(t.created_at),updated_at:$(t.updated_at)}}function ki(t){if(!J(t))return null;const e=$(t.from)??$(t.from_agent)??"system",n=$(t.content)??"",s=$(t.timestamp)??new Date().toISOString();return{id:$(t.id),seq:h(t.seq),from:e,content:n,timestamp:s,type:$(t.type)}}function wi(t){return Array.isArray(t)?t.map(e=>{if(!J(e))return null;const n=h(e.ts_unix);if(n==null)return null;const s=J(e.handoff)?e.handoff:null;return{ts:n,context_ratio:h(e.context_ratio)??0,context_tokens:h(e.context_tokens)??0,context_max:h(e.context_max)??0,latency_ms:h(e.latency_ms)??0,generation:h(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:h(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:h(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?h(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Si(t){return(Array.isArray(t)?t:J(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!J(n))return null;const s=J(n.agent)?n.agent:null,a=J(n.context)?n.context:null,i=J(n.metrics_window)?n.metrics_window:void 0,r=$(n.name);if(!r)return null;const c=h(n.context_ratio)??h(a==null?void 0:a.context_ratio),d=$(n.status)??$(s==null?void 0:s.status)??"offline",u=Ks(d),p=$(n.model)??$(n.active_model)??$(n.primary_model),l=Tt(n.skill_secondary),v=a?{source:$(a.source),context_ratio:h(a.context_ratio),context_tokens:h(a.context_tokens),context_max:h(a.context_max),message_count:h(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,_=s?{name:$(s.name),status:$(s.status),current_task:$(s.current_task)??null,last_seen:$(s.last_seen)}:void 0,b=wi(n.metrics_series);return{name:r,emoji:$(n.emoji),koreanName:$(n.koreanName)??$(n.korean_name),agent_name:$(n.agent_name),trace_id:$(n.trace_id),model:p,primary_model:$(n.primary_model),active_model:$(n.active_model),next_model_hint:$(n.next_model_hint)??null,status:u,last_heartbeat:$(n.last_heartbeat)??$(s==null?void 0:s.last_seen),generation:h(n.generation),turn_count:h(n.turn_count)??h(n.total_turns),context_ratio:c,context_tokens:h(n.context_tokens)??h(a==null?void 0:a.context_tokens),context_max:h(n.context_max)??h(a==null?void 0:a.context_max),context_source:$(n.context_source)??$(a==null?void 0:a.source),context:v,traits:Tt(n.traits),interests:Tt(n.interests),primaryValue:$(n.primaryValue)??$(n.primary_value),activityLevel:h(n.activityLevel)??h(n.activity_level),memory_recent_note:$(n.memory_recent_note)??null,conversation_tail_count:h(n.conversation_tail_count),k2k_count:h(n.k2k_count),handoff_count_total:h(n.handoff_count_total)??h(n.trace_history_count),compaction_count:h(n.compaction_count),last_compaction_saved_tokens:h(n.last_compaction_saved_tokens),skill_primary:$(n.skill_primary)??null,skill_secondary:l,skill_reason:$(n.skill_reason)??null,metrics_series:b.length>0?b:void 0,metrics_window:i,agent:_}}).filter(n=>n!==null)}async function Ce(t="full"){var s,a,i;const e=Date.now(),n=fe[t];if(!(n&&e-n.time<hi)){Qe.value=!0;try{const r=await Oa(t);fe[t]={data:r,time:e},ht.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(bi).filter(c=>c!==null),Xt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(xi).filter(c=>c!==null),Hs.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(ki).filter(c=>c!==null),yt.value=Si(r.keepers),mn.value=J(r.status)?r.status:null,wt.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{Qe.value=!1}}}async function rt(){Ze.value=!0;try{const t=await Ha();Us.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{Ze.value=!1}}async function at(){var t;tn.value=!0;try{const e=dt.value||((t=mn.value)==null?void 0:t.room)||"default";dt.value||(dt.value=e);const n=await Qa(e);Bs.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{tn.value=!1}}let Re=null,De=null;function Ci(){return Rs.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Ye.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Ye.value=n}en(),Re||(Re=setTimeout(()=>{Ce(),Re=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(De||(De=setTimeout(()=>{rt(),De=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&en()}})}let At=null;function Ti(){At||(At=setInterval(()=>{en(),Ce()},1e4))}function Ai(){At&&(clearInterval(At),At=null)}function x({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Z({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Ni(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function tt({timestamp:t}){const e=Ni(t);return o`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const $n=f(null);function Js(t){$n.value=t}function Hn(){$n.value=null}function oe(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Ri({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${oe(t.context_tokens)}</div>
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
  `}function Di({keeper:t}){var p,l;const e=t.metrics_series??[];if(e.length<2){const v=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,_=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${_}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((v,_)=>{const b=a+_/(i-1)*(n-2*a),D=s-a-(v.context_ratio??0)*(s-2*a);return{x:b,y:D,p:v}}),c=r.map(({x:v,y:_})=>`${v.toFixed(1)},${_.toFixed(1)}`).join(" "),d=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>o`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:_})=>o`
          <circle cx="${v.toFixed(1)}" cy="${_.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Ee=f("");function Ei({keeper:t}){var a,i,r,c;const e=Ee.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ee.value}
        onInput=${d=>{Ee.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${oe(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${oe(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${oe(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Li({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Pi({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Mi({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Un({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Le(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function ji({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Le(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Le(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Le(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Ii(){var e,n,s;const t=$n.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Hn()}}
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
            <${Z} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Hn()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Ri} keeper=${t} />

        ${""}
        <${Di} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${x} title="Field Dictionary">
            <${Ei} keeper=${t} />
          <//>

          ${""}
          <${x} title="Profile">
            <${Un} traits=${t.traits??[]} label="Traits" />
            <${Un} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${tt} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?o`
              <${x} title="TRPG Stats">
                <${Li} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${x} title="Equipment (${t.inventory.length})">
                <${Pi} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${x} title="Relationships (${Object.keys(t.relationships).length})">
                <${Mi} rels=${t.relationships} />
              <//>
            `:null}

          <${x} title="Runtime Signals">
            <${ji} keeper=${t} />
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
      </div>
    </div>
  `:null}let zi=0;const st=f([]);function y(t,e="success",n=4e3){const s=++zi;st.value=[...st.value,{id:s,message:t,type:e}],setTimeout(()=>{st.value=st.value.filter(a=>a.id!==s)},n)}function Fi(t){st.value=st.value.filter(e=>e.id!==t)}function Oi(){const t=st.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Fi(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Hi="masc_dashboard_agent_name",bt=f(null),_e=f(!1),qt=f(""),me=f([]),Kt=f([]),pt=f(""),Nt=f(!1);function Ws(t){bt.value=t,gn()}function Bn(){bt.value=null,qt.value="",me.value=[],Kt.value=[],pt.value=""}function Ui(){const t=bt.value;return t?ht.value.find(e=>e.name===t)??null:null}function Vs(t){return t?Xt.value.filter(e=>e.assignee===t):[]}async function gn(){const t=bt.value;if(t){_e.value=!0,qt.value="",me.value=[],Kt.value=[];try{const e=await li(80);me.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Vs(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await ci(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Kt.value=s}catch(e){qt.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{_e.value=!1}}}async function qn(){var s;const t=bt.value,e=pt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Hi))==null?void 0:s.trim())||"dashboard";Nt.value=!0;try{await Fs(n,`@${t} ${e}`),pt.value="",y(`Mention sent to ${t}`,"success"),gn()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";y(i,"error")}finally{Nt.value=!1}}function Bi({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Z} status=${t.status} />
    </div>
  `}function qi({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Ki(){var a,i,r,c;const t=bt.value;if(!t)return null;const e=Ui(),n=Vs(t),s=me.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Bn()}}
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
                        <${Z} status=${e.status} />
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
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${tt} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{gn()}} disabled=${_e.value}>
              ${_e.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Bn}>Close</button>
          </div>
        </div>

        ${qt.value?o`<div class="council-error">${qt.value}</div>`:null}

        <div class="agent-detail-grid">
          <${x} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Bi} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${x} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${x} title="Task History">
          ${Kt.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Kt.value.map(d=>o`<${qi} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${x} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${pt.value}
              onInput=${d=>{pt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&qn()}}
              disabled=${Nt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{qn()}}
              disabled=${Nt.value||pt.value.trim()===""}
            >
              ${Nt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function lt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Ji({agent:t}){return o`
    <div class="agent" onClick=${()=>Ws(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${Z} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Wi(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Vi(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function Kn(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Gi({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=mi.value.get(t.name),a=gi.value.has(t.name);return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>Js(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Z} status=${t.status} />
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
              <div class="keeper-ctx-fill ${Kn(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${Kn(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${Wi(t.context_tokens)})`:null}
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
            <${tt} timestamp=${t.last_heartbeat} />
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
          <div class="keeper-note-preview">${Vi(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function Jn(){const t=mn.value,e=ht.value,n=yt.value,s=qs.value;return o`
    <div class="stats-grid">
      <${lt} label="Agents" value=${e.length} />
      <${lt} label="Active" value=${fi.value.length} color="#4ade80" />
      <${lt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${lt} label="Tasks" value=${Xt.value.length} />
      <${lt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${lt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${x} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(a=>o`<${Ji} key=${a.name} agent=${a} />`)}
        </div>
      <//>

      <${x} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(a=>o`<${Gi} key=${a.name} keeper=${a} />`)}
        </div>
      <//>
    </div>

    ${wt.value?o`
        <${x} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${wt.value.running?"Running":"Stopped"}</span>
            ${wt.value.goal?o`<span>Goal: ${wt.value.goal}</span>`:null}
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
            <span>Uptime: ${Xi(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
          </div>
        <//>
      `:null}
  `}function Xi(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const nn=f([]),sn=f([]),Rt=f(""),$e=f(!1),Dt=f(!1),ge=f(""),he=f(null),Et=f(""),an=f(!1);async function on(){$e.value=!0,ge.value="";try{const[t,e]=await Promise.all([ui(),di()]);nn.value=t,sn.value=e}catch(t){ge.value=t instanceof Error?t.message:"Failed to load council data"}finally{$e.value=!1}}async function Wn(){const t=Rt.value.trim();if(t){Dt.value=!0;try{const e=await pi(t);Rt.value="",y(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await on()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";y(n,"error")}finally{Dt.value=!1}}}async function Yi(t){he.value=t,an.value=!0,Et.value="";try{Et.value=await vi(t)}catch(e){Et.value=e instanceof Error?e.message:"Failed to load debate status"}finally{an.value=!1}}function Qi({debate:t}){const e=he.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Yi(t.id)}
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
  `}function Zi({session:t}){return o`
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
  `}function to(){return ce(()=>{on()},[]),o`
    <div>
      <${x} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Rt.value}
            onInput=${t=>{Rt.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Wn()}}
            disabled=${Dt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Wn}
            disabled=${Dt.value||Rt.value.trim()===""}
          >
            ${Dt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${on} disabled=${$e.value}>
            ${$e.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${ge.value?o`<div class="council-error">${ge.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${x} title="Debates" class="section">
          <div class="council-list">
            ${nn.value.length===0?o`<div class="empty-state">No debates yet</div>`:nn.value.map(t=>o`<${Qi} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${x} title="Voting Sessions" class="section">
          <div class="council-list">
            ${sn.value.length===0?o`<div class="empty-state">No active sessions</div>`:sn.value.map(t=>o`<${Zi} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${x} title=${he.value?`Debate Detail (${he.value})`:"Debate Detail"} class="section">
        ${an.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Et.value?o`<pre class="council-detail">${Et.value}</pre>`:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function eo({text:t}){if(!t)return null;const e=no(t);return o`<div class="markdown-content">${e}</div>`}function no(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Pe(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${Pe(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${Pe(i.join(`
`))}</p>`)}return n}function Pe(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const so=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Lt=f([]),Pt=f(!1),Mt=f(""),ao=f("dashboard-user"),jt=f(!1);async function Gs(t){Pt.value=!0,Lt.value=[];try{const e=await Ua(t);Lt.value=e.comments??[]}catch{}finally{Pt.value=!1}}async function Vn(t){const e=Mt.value.trim();if(e){jt.value=!0;try{await Ba(t,ao.value,e),Mt.value="",y("Comment posted","success"),await Gs(t),rt()}catch{y("Failed to post comment","error")}finally{jt.value=!1}}}function io(){const t=On.value;return o`
    <div class="board-controls">
      ${so.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{On.value=e.id,rt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Xs({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function oo({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await zs(t.id,n),rt()}catch{y("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>ka(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Xs} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${tt} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function ro({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${tt} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function lo({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Mt.value}
        onInput=${e=>{Mt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Vn(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${jt.value}
      />
      <button
        onClick=${()=>Vn(t)}
        disabled=${jt.value||Mt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${jt.value?"...":"Post"}
      </button>
    </div>
  `}function co({post:t}){Lt.value.length===0&&!Pt.value&&Gs(t.id);const e=async n=>{try{await zs(t.id,n),rt()}catch{y("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Se("board")}>← Back to Board</button>
      <${x} title=${o`${t.title} <${Xs} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${eo} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${tt} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${x} title="Comments (${Pt.value?"...":Lt.value.length})">
        ${Pt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${ro} comments=${Lt.value} />`}
        <${lo} postId=${t.id} />
      <//>
    </div>
  `}function uo(){const t=Us.value,e=Ze.value,n=X.value.postId;if(n){const s=t.find(a=>a.id===n);return s?o`<${co} post=${s} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>Se("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${io} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(s=>o`<${oo} key=${s.id} post=${s} />`)}
          </div>`}
  `}function po(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function vo(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function Gn(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function fo({row:t}){return o`
    <div class="message-row">
      <span class="message-agent">${t.actor}</span>
      <span class="message-source ${t.source}">${t.source}</span>
      <span class="message-text">${t.content}</span>
      <span class="message-time"><${tt} timestamp=${t.timestamp} /></span>
    </div>
  `}function _o(){const t=Hs.value.map(po),e=ve.value.map(vo),n=[...t,...e].sort((s,a)=>Gn(a.timestamp)-Gn(s.timestamp)).slice(0,80);return o`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${n.length===0?o`<div class="empty-state">No recent activity</div>`:n.map(s=>o`<${fo} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function mo({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>Ws(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${Z} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function $o({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return o`
    <div class="live-agent keeper-card" onClick=${()=>Js(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Z} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="live-agent-meta">
          ${t.generation!=null?o`<span>Gen ${t.generation}</span>`:null}
          ${t.turn_count!=null?o`<span>Turn ${t.turn_count}</span>`:null}
          ${e!=null?o`<span class=${n?`${n}-metric`:""}>Ctx ${e}%</span>`:null}
        </div>
        ${e!=null?o`<div class="ctx-bar"><div class="ctx-fill ${n}" style="width: ${e}%"></div></div>`:null}
      </div>
    </div>
  `}function go(){const t=ht.value,e=yt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${$o} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${mo} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Me({task:t}){return o`
    <div class="task-row">
      <${Z} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?o`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?o`<${tt} timestamp=${t.created_at} />`:null}
    </div>
  `}function ho(){const{todo:t,inProgress:e,done:n}=qs.value;return o`
    <div class="grid-2col">
      <${x} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?o`<div class="empty-state">No tasks in progress</div>`:e.map(s=>o`<${Me} key=${s.id} task=${s} />`)}
        </div>
      <//>

      <${x} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?o`<div class="empty-state">No pending tasks</div>`:t.map(s=>o`<${Me} key=${s.id} task=${s} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?o`
        <${x} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(s=>o`<${Me} key=${s.id} task=${s} />`)}
            ${n.length>20?o`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function yo({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function bo(){const t=ve.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${yo} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const kt=f(""),je=f("ability_check"),Ie=f("10"),ze=f("12"),te=f(""),ee=f("idle"),ne=f(""),se=f("keeper-late"),Fe=f("player"),Oe=f(""),B=f("idle"),He=f(null),rn=f(null);function xo(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function ko(t,e){return e>0?Math.round(t/e*100):0}const wo={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},So={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Ue(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Co(t){const e=t.trim().toLowerCase();return wo[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function To(t){const e=t.trim().toLowerCase();return So[e]??"상황에 따라 선택되는 전술 액션입니다."}function it(t){return typeof t=="object"&&t!==null}function I(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function V(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Jt(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}function Ao({hp:t,max:e}){const n=ko(t,e),s=xo(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function No({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Ro({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Do({actor:t}){var i,r;const e=(i=t.archetype)==null?void 0:i.trim(),n=(r=t.persona)==null?void 0:r.trim(),s=t.traits??[],a=t.skills??[];return o`
    <div class="trpg-actor">
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${Z} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Ro} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Ao} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${No} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Ue(e)}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${s.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${s.map(c=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Ue(c)}</span>
                  <span class="trpg-annot-desc">${Co(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${a.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${a.map(c=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Ue(c)}</span>
                  <span class="trpg-annot-desc">${To(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Eo({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Lo({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var s;return o`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?o`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?o`<span class="trpg-dice">[${e.dice_roll.notation}: ${(s=e.dice_roll.rolls)==null?void 0:s.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${tt} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function Xn(t,e){const n=new Date(t).getTime(),s=new Date(e).getTime();if(isNaN(n)||isNaN(s)||s<=n)return"";const a=Math.floor((s-n)/1e3);if(a<60)return`${a}s`;if(a<3600)return`${Math.floor(a/60)}m`;const i=Math.floor(a/3600),r=Math.floor(a%3600/60);return r>0?`${i}h ${r}m`:`${i}h`}function Po({state:t}){const e=t.history??[];return e.length===0?null:o`
    <div class="trpg-round-list">
      ${e.slice(0,20).map(n=>o`
        <div class="trpg-round-item ${n.current?"active":n.ended?"ended":"paused"}">
          <span title=${n.room_id}>${n.room_id.length>12?n.room_id.slice(0,12)+"...":n.room_id}</span>
          <span style="margin-left:auto; display:flex; gap:8px; font-size:11px; color:#888; align-items:center;">
            <span>${n.event_count} events</span>
            ${Xn(n.first_ts,n.last_ts)?o`<span>${Xn(n.first_ts,n.last_ts)}</span>`:null}
            <span style="color:${n.current?"#4CAF50":n.ended?"#f44336":"#ff9800"};">
              ${n.current?"active":n.ended?"ended":"paused"}
            </span>
          </span>
        </div>
      `)}
    </div>
  `}function Mo({state:t}){var d;const e=dt.value||((d=t.session)==null?void 0:d.room)||"",n=ee.value,s=t.party??[];if(!s.find(u=>u.id===kt.value)&&s.length>0){const u=s[0];u&&(kt.value=u.id)}const i=async()=>{if(!e){y("No room set","error");return}ee.value="running";try{const u=await Za(e);rn.value=u,ee.value="ok";const p=it(u.summary)?u.summary:null,l=p?Jt(p,"advanced",!1):!1,v=p?I(p,"progress_reason",""):"";y(l?"Round advanced":`Round stalled${v?`: ${v}`:""}`,l?"success":"warning"),at()}catch(u){rn.value=null,ee.value="error";const p=u instanceof Error?u.message:"Round failed";y(p,"error")}},r=async()=>{if(e)try{await ni(e),y("Turn advanced","success"),at()}catch{y("Advance failed","error")}},c=async()=>{if(!e)return;const u=kt.value.trim();if(!u){y("Select actor first","warning");return}const p=Number.parseInt(Ie.value,10),l=Number.parseInt(ze.value,10);if(Number.isNaN(p)||Number.isNaN(l)){y("Stat/DC must be numbers","warning");return}const v=Number.parseInt(te.value,10),_=te.value.trim()===""||Number.isNaN(v)?void 0:v;try{await ei({roomId:e,actorId:u,action:je.value.trim()||"ability_check",statValue:p,dc:l,rawD20:_}),y("Dice rolled","success"),at()}catch{y("Dice roll failed","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            type="text"
            value=${e}
            onInput=${u=>{dt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${kt.value}
            onChange=${u=>{kt.value=u.target.value}}
          >
            <option value="">Select actor</option>
            ${s.map(u=>o`<option value=${u.id}>${u.name} (${u.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              type="text"
              value=${je.value}
              onInput=${u=>{je.value=u.target.value}}
              placeholder="action"
            />
            <input
              type="text"
              value=${Ie.value}
              onInput=${u=>{Ie.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              type="text"
              value=${ze.value}
              onInput=${u=>{ze.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              type="text"
              value=${te.value}
              onInput=${u=>{te.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&c()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${c}>Roll</button>
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
  `}function jo({state:t}){var c;const e=dt.value||((c=t.session)==null?void 0:c.room)||"",n=t.join_gate,s=He.value,a=it(s)?s:null,i=async()=>{const d=ne.value.trim(),u=se.value.trim();if(!e||!d){y("Room/Actor is required","warning");return}B.value="checking";try{const p=await si(e,d,u||void 0);He.value=p,B.value="ok",y("Eligibility updated","success")}catch(p){B.value="error";const l=p instanceof Error?p.message:"Eligibility check failed";y(l,"error")}},r=async()=>{const d=ne.value.trim(),u=se.value.trim(),p=Oe.value.trim();if(!e||!d||!u){y("Room/Actor/Keeper is required","warning");return}B.value="requesting";try{const l=await ai({room_id:e,actor_id:d,keeper_name:u,role:Fe.value,...p?{name:p}:{}});He.value=l;const v=it(l)?Jt(l,"granted",!1):!1,_=it(l)?I(l,"reason_code",""):"";v?y("Mid-join granted","success"):y(`Mid-join rejected${_?`: ${_}`:""}`,"warning"),B.value=v?"ok":"error",at()}catch(l){B.value="error";const v=l instanceof Error?l.message:"Mid-join request failed";y(v,"error")}};return o`
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
            type="text"
            value=${ne.value}
            onInput=${d=>{ne.value=d.target.value}}
            placeholder="player-xyz"
          />
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            type="text"
            value=${se.value}
            onInput=${d=>{se.value=d.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Fe.value}
            onChange=${d=>{Fe.value=d.target.value}}
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
            value=${Oe.value}
            onInput=${d=>{Oe.value=d.target.value}}
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
            Eligible: <strong>${Jt(a,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${V(a,"effective_score",0)}/${V(a,"required_points",0)}</span>
            ${I(a,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${I(a,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Io({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function zo({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Fo(){const t=rn.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=it(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(it).slice(-8),i=t.canon_check,r=it(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(A=>typeof A=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(A=>typeof A=="string").slice(0,3):[],u=n?Jt(n,"advanced",!1):!1,p=n?I(n,"progress_reason",""):"",l=n?I(n,"progress_detail",""):"",v=n?V(n,"player_successes",0):0,_=n?V(n,"player_required_successes",0):0,b=n?Jt(n,"dm_success",!1):!1,D=n?V(n,"timeouts",0):0,T=n?V(n,"unavailable",0):0,S=n?V(n,"reprompts",0):0,k=n?V(n,"npc_attacks",0):0,F=n?V(n,"keeper_timeout_sec",0):0,O=n?V(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${b?"DM ok":"DM stalled"} / players ${v}/${_}
          </span>
        </div>
        ${p?o`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${D}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${F||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${O}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(A=>{const H=I(A,"status","unknown"),xt=I(A,"actor_id","-"),Y=I(A,"role","-"),q=I(A,"reason",""),L=I(A,"action_type",""),N=I(A,"reply","");return o`
                <div class="trpg-round-item ${H.includes("fallback")||H.includes("timeout")?"failed":"active"}">
                  <span>${xt} (${Y})</span>
                  <span style="margin-left:auto; font-size:11px;">${H}</span>
                  ${L?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${L}</div>`:null}
                  ${q?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${q}</div>`:null}
                  ${N?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${N.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${I(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(A=>o`<div>violation: ${A}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(A=>o`<div>warning: ${A}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Oo(){var a,i;const t=Bs.value;if(tn.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>at()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[];return o`
    <div>
      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((a=t.session)==null?void 0:a.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((i=t.current_round)==null?void 0:i.round_number)??0}</div>
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
      <${zo} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${x} title="Story Log (${s.length})">
            <${Lo} events=${s} />
          <//>

          ${""}
          ${t.map?o`
              <${x} title="Map" style="margin-top:16px;">
                <${Eo} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${x} title="Controls">
            <${Mo} state=${t} />
          <//>

          <${x} title="Last Round Result" style="margin-top:16px;">
            <${Fo} />
          <//>

          ${""}
          <${x} title="Mid-Join Gate" style="margin-top:16px;">
            <${jo} state=${t} />
          <//>

          ${""}
          <${x} title="Contribution" style="margin-top:16px;">
            <${Io} state=${t} />
          <//>

          ${""}
          <${x} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(r=>o`<${Do} key=${r.id??r.name} actor=${r} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${x} title="History (${t.history.length})" style="margin-top:16px;">
                <${Po} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const hn="masc_dashboard_agent_name";function Ho(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(hn);return e??n??"dashboard"}const W=f(Ho()),It=f(""),zt=f(""),ye=f(""),Ft=f(!1),ct=f(!1),Ot=f(!1),Ht=f(!1),be=f(!1),Te=f(!1);function yn(t){const e=t.trim();W.value=e,e&&localStorage.setItem(hn,e)}function Uo(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function ln(){const t=W.value.trim();if(t){Ot.value=!0;try{const e=await oi(t),n=Uo(e);n&&yn(n),Te.value=!0,y(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";y(n,"error")}finally{Ot.value=!1}}}async function Bo(){const t=W.value.trim();if(t){Ht.value=!0;try{await Os(t),Te.value=!1,y(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";y(n,"error")}finally{Ht.value=!1}}}async function qo(){const t=W.value.trim();if(t)try{await Os(t)}catch{}localStorage.removeItem(hn),yn("dashboard"),Te.value=!1,await ln()}async function Ko(){const t=W.value.trim();if(t){be.value=!0;try{await ri(t),y("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";y(n,"error")}finally{be.value=!1}}}async function Yn(){const t=W.value.trim(),e=It.value.trim();if(!(!t||!e)){Ft.value=!0;try{await Fs(t,e),It.value="",y("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";y(s,"error")}finally{Ft.value=!1}}}async function Jo(){const t=zt.value.trim(),e=ye.value.trim()||"Created from dashboard";if(t){ct.value=!0;try{await ii(t,e,1),zt.value="",ye.value="",y("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";y(s,"error")}finally{ct.value=!1}}}function Wo(){return ce(()=>{ln()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${W.value}
        onInput=${t=>yn(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${It.value}
          onInput=${t=>{It.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Yn()}}
          disabled=${Ft.value}
        />
        <button
          class="control-btn"
          onClick=${Yn}
          disabled=${Ft.value||It.value.trim()===""||W.value.trim()===""}
        >
          ${Ft.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{ln()}}
          disabled=${Ot.value||W.value.trim()===""}
        >
          ${Ot.value?"Joining...":Te.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Bo()}}
          disabled=${Ht.value||W.value.trim()===""}
        >
          ${Ht.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{qo()}}
          disabled=${Ot.value||Ht.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Ko()}}
          disabled=${be.value||W.value.trim()===""}
        >
          ${be.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${zt.value}
        onInput=${t=>{zt.value=t.target.value}}
        disabled=${ct.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${ye.value}
        onInput=${t=>{ye.value=t.target.value}}
        disabled=${ct.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${Jo}
        disabled=${ct.value||zt.value.trim()===""}
      >
        ${ct.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function Vo(){const t=_t.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${fn.value} events</span>
    </div>
  `}const Go=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function Xo(){const t=X.value.tab,e=_t.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Go.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Se(n.id)}
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
            <strong>${Xt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${fn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Ce(),t==="board"&&rt(),t==="trpg"&&at()}}
        >
          Refresh Now
        </button>
      </section>

      <${Wo} />
    </aside>
  `}function Yo(){switch(X.value.tab){case"overview":return o`<${Jn} />`;case"council":return o`<${to} />`;case"board":return o`<${uo} />`;case"activity":return o`<${_o} />`;case"agents":return o`<${go} />`;case"tasks":return o`<${ho} />`;case"journal":return o`<${bo} />`;case"trpg":return o`<${Oo} />`;default:return o`<${Jn} />`}}function Qo(){return ce(()=>{wa(),Es(),Ce();const t=Ci();return Ti(),()=>{La(),t(),Ai()}},[]),ce(()=>{const t=X.value.tab;t==="board"&&rt(),t==="trpg"&&at()},[X.value.tab]),o`
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
          <${Vo} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${Ca} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Qe.value&&!_t.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Yo} />`}
        </main>
        <${Xo} />
      </div>

      <${Ii} />
      <${Ki} />
      <${Oi} />
    </div>
  `}const Qn=document.getElementById("app");Qn&&la(o`<${Qo} />`,Qn);
