(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var xe,C,es,ns,nt,Cn,ss,as,is,dn,Ke,qe,Ut={},os=[],oa=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,we=Array.isArray;function Q(t,e){for(var n in e)t[n]=e[n];return t}function pn(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function rs(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?xe.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return ie(t,r,s,a,null)}function ie(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++es,__i:-1,__u:0};return a==null&&C.vnode!=null&&C.vnode(i),i}function Jt(t){return t.children}function St(t,e){this.props=t,this.context=e}function ft(t,e){if(e==null)return t.__?ft(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?ft(t):null}function ls(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return ls(t)}}function Tn(t){(!t.__d&&(t.__d=!0)&&nt.push(t)&&!le.__r++||Cn!=C.debounceRendering)&&((Cn=C.debounceRendering)||ss)(le)}function le(){for(var t,e,n,s,a,i,r,l=1;nt.length;)nt.length>l&&nt.sort(as),t=nt.shift(),l=nt.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=Q({},s)).__v=s.__v+1,C.vnode&&C.vnode(n),vn(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??ft(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,ds(i,n,r),s.__e=s.__=null,n.__e!=a&&ls(n)));le.__r=0}function cs(t,e,n,s,a,i,r,l,d,u,p){var c,v,_,b,P,T,w,k=s&&s.__k||os,z=e.length;for(d=ra(n,e,k,d,z),c=0;c<z;c++)(_=n.__k[c])!=null&&(v=_.__i==-1?Ut:k[_.__i]||Ut,_.__i=c,T=vn(t,_,v,a,i,r,l,d,u,p),b=_.__e,_.ref&&v.ref!=_.ref&&(v.ref&&fn(v.ref,null,_),p.push(_.ref,_.__c||b,_)),P==null&&b!=null&&(P=b),(w=!!(4&_.__u))||v.__k===_.__k?d=us(_,d,t,w):typeof _.type=="function"&&T!==void 0?d=T:b&&(d=b.nextSibling),_.__u&=-7);return n.__e=P,d}function ra(t,e,n,s,a){var i,r,l,d,u,p=n.length,c=p,v=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=ie(null,r,null,null,null):we(r)?r=t.__k[i]=ie(Jt,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=ie(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+v,r.__=t,r.__b=t.__b+1,l=null,(u=r.__i=la(r,n,d,c))!=-1&&(c--,(l=n[u])&&(l.__u|=2)),l==null||l.__v==null?(u==-1&&(a>p?v--:a<p&&v++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?v--:u==d+1?v++:(u>d?v--:v++,r.__u|=4))):t.__k[i]=null;if(c)for(i=0;i<p;i++)(l=n[i])!=null&&(2&l.__u)==0&&(l.__e==s&&(s=ft(l)),vs(l,l));return s}function us(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=us(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=ft(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function la(t,e,n,s){var a,i,r,l=t.key,d=t.type,u=e[n],p=u!=null&&(2&u.__u)==0;if(u===null&&l==null||p&&l==u.key&&d==u.type)return n;if(s>(p?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((u=e[r=a>=0?a--:i++])!=null&&(2&u.__u)==0&&l==u.key&&d==u.type)return r}return-1}function An(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||oa.test(e)?n:n+"px"}function Zt(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||An(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||An(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(is,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=dn,t.addEventListener(e,i?qe:Ke,i)):t.removeEventListener(e,i?qe:Ke,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Nn(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=dn++;else if(e.t<n.u)return;return n(C.event?C.event(e):e)}}}function vn(t,e,n,s,a,i,r,l,d,u){var p,c,v,_,b,P,T,w,k,z,F,A,H,kt,Z,K,M,N=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[l=e.__e=n.__e]),(p=C.__b)&&p(e);t:if(typeof N=="function")try{if(w=e.props,k="prototype"in N&&N.prototype.render,z=(p=N.contextType)&&s[p.__c],F=p?z?z.props.value:p.__:s,n.__c?T=(c=e.__c=n.__c).__=c.__E:(k?e.__c=c=new N(w,F):(e.__c=c=new St(w,F),c.constructor=N,c.render=ua),z&&z.sub(c),c.state||(c.state={}),c.__n=s,v=c.__d=!0,c.__h=[],c._sb=[]),k&&c.__s==null&&(c.__s=c.state),k&&N.getDerivedStateFromProps!=null&&(c.__s==c.state&&(c.__s=Q({},c.__s)),Q(c.__s,N.getDerivedStateFromProps(w,c.__s))),_=c.props,b=c.state,c.__v=e,v)k&&N.getDerivedStateFromProps==null&&c.componentWillMount!=null&&c.componentWillMount(),k&&c.componentDidMount!=null&&c.__h.push(c.componentDidMount);else{if(k&&N.getDerivedStateFromProps==null&&w!==_&&c.componentWillReceiveProps!=null&&c.componentWillReceiveProps(w,F),e.__v==n.__v||!c.__e&&c.shouldComponentUpdate!=null&&c.shouldComponentUpdate(w,c.__s,F)===!1){for(e.__v!=n.__v&&(c.props=w,c.state=c.__s,c.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(g){g&&(g.__=e)}),A=0;A<c._sb.length;A++)c.__h.push(c._sb[A]);c._sb=[],c.__h.length&&r.push(c);break t}c.componentWillUpdate!=null&&c.componentWillUpdate(w,c.__s,F),k&&c.componentDidUpdate!=null&&c.__h.push(function(){c.componentDidUpdate(_,b,P)})}if(c.context=F,c.props=w,c.__P=t,c.__e=!1,H=C.__r,kt=0,k){for(c.state=c.__s,c.__d=!1,H&&H(e),p=c.render(c.props,c.state,c.context),Z=0;Z<c._sb.length;Z++)c.__h.push(c._sb[Z]);c._sb=[]}else do c.__d=!1,H&&H(e),p=c.render(c.props,c.state,c.context),c.state=c.__s;while(c.__d&&++kt<25);c.state=c.__s,c.getChildContext!=null&&(s=Q(Q({},s),c.getChildContext())),k&&!v&&c.getSnapshotBeforeUpdate!=null&&(P=c.getSnapshotBeforeUpdate(_,b)),K=p,p!=null&&p.type===Jt&&p.key==null&&(K=ps(p.props.children)),l=cs(t,we(K)?K:[K],e,n,s,a,i,r,l,d,u),c.base=e.__e,e.__u&=-161,c.__h.length&&r.push(c),T&&(c.__E=c.__=null)}catch(g){if(e.__v=null,d||i!=null)if(g.then){for(e.__u|=d?160:128;l&&l.nodeType==8&&l.nextSibling;)l=l.nextSibling;i[i.indexOf(l)]=null,e.__e=l}else{for(M=i.length;M--;)pn(i[M]);Je(e)}else e.__e=n.__e,e.__k=n.__k,g.then||Je(e);C.__e(g,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):l=e.__e=ca(n.__e,e,n,s,a,i,r,d,u);return(p=C.diffed)&&p(e),128&e.__u?void 0:l}function Je(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Je)}function ds(t,e,n){for(var s=0;s<n.length;s++)fn(n[s],n[++s],n[++s]);C.__c&&C.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){C.__e(i,a.__v)}})}function ps(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:we(t)?t.map(ps):Q({},t)}function ca(t,e,n,s,a,i,r,l,d){var u,p,c,v,_,b,P,T=n.props||Ut,w=e.props,k=e.type;if(k=="svg"?a="http://www.w3.org/2000/svg":k=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((_=i[u])&&"setAttribute"in _==!!k&&(k?_.localName==k:_.nodeType==3)){t=_,i[u]=null;break}}if(t==null){if(k==null)return document.createTextNode(w);t=document.createElementNS(a,k,w.is&&w),l&&(C.__m&&C.__m(e,i),l=!1),i=null}if(k==null)T===w||l&&t.data==w||(t.data=w);else{if(i=i&&xe.call(t.childNodes),!l&&i!=null)for(T={},u=0;u<t.attributes.length;u++)T[(_=t.attributes[u]).name]=_.value;for(u in T)if(_=T[u],u!="children"){if(u=="dangerouslySetInnerHTML")c=_;else if(!(u in w)){if(u=="value"&&"defaultValue"in w||u=="checked"&&"defaultChecked"in w)continue;Zt(t,u,null,_,a)}}for(u in w)_=w[u],u=="children"?v=_:u=="dangerouslySetInnerHTML"?p=_:u=="value"?b=_:u=="checked"?P=_:l&&typeof _!="function"||T[u]===_||Zt(t,u,_,T[u],a);if(p)l||c&&(p.__html==c.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(c&&(t.innerHTML=""),cs(e.type=="template"?t.content:t,we(v)?v:[v],e,n,s,k=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&ft(n,0),l,d),i!=null)for(u=i.length;u--;)pn(i[u]);l||(u="value",k=="progress"&&b==null?t.removeAttribute("value"):b!=null&&(b!==t[u]||k=="progress"&&!b||k=="option"&&b!=T[u])&&Zt(t,u,b,T[u],a),u="checked",P!=null&&P!=t[u]&&Zt(t,u,P,T[u],a))}return t}function fn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){C.__e(a,n)}}function vs(t,e,n){var s,a;if(C.unmount&&C.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||fn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){C.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&vs(s[a],e,n||typeof t.type!="function");n||pn(t.__e),t.__c=t.__=t.__e=void 0}function ua(t,e,n){return this.constructor(t,n)}function da(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),C.__&&C.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],vn(e,t=e.__k=rs(Jt,null,[t]),a||Ut,Ut,e.namespaceURI,a?null:e.firstChild?xe.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),ds(i,t,r)}xe=os.slice,C={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(l){t=l}throw t}},es=0,ns=function(t){return t!=null&&t.constructor===void 0},St.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=Q({},this.state),typeof t=="function"&&(t=t(Q({},n),this.props)),t&&Q(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Tn(this))},St.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Tn(this))},St.prototype.render=Jt,nt=[],ss=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,as=function(t,e){return t.__v.__b-e.__v.__b},le.__r=0,is=/(PointerCapture)$|Capture$/i,dn=0,Ke=Nn(!1),qe=Nn(!0);var fs=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],l=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=l:r===4?s[1]=Object.assign(s[1]||{},l):r===5?(s[1]=s[1]||{})[e[++i]]=l:r===6?s[1][e[++i]]+=l+"":r?(a=t.apply(l,fs(t,l,n,["",null])),s.push(a),l[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(l)}return s},Rn=new Map;function pa(t){var e=Rn.get(this);return e||(e=new Map,Rn.set(this,e)),(e=fs(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",l="",d=[0],u=function(v){i===1&&(v||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,v,r):i===3&&(v||r)?(d.push(3,v,r),i=2):i===2&&r==="..."&&v?d.push(4,v,0):i===2&&r&&!v?d.push(5,0,!0,r):i>=5&&((r||!v&&i===5)&&(d.push(i,0,r,a),i=6),v&&(d.push(i,v,0,a),i=6)),r=""},p=0;p<n.length;p++){p&&(i===1&&u(),u(p));for(var c=0;c<n[p].length;c++)s=n[p][c],i===1?s==="<"?(u(),d=[d],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:l?s===l?l="":r+=s:s==='"'||s==="'"?l=s:s===">"?(u(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[p][c+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(u(),i=2):r+=s),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=pa.bind(rs),ce,j,Ne,Dn,Pn=0,_s=[],R=C,En=R.__b,Ln=R.__r,Mn=R.diffed,jn=R.__c,In=R.unmount,On=R.__;function ms(t,e){R.__h&&R.__h(j,t,Pn||e),Pn=0;var n=j.__H||(j.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function ue(t,e){var n=ms(ce++,3);!R.__s&&gs(n.__H,e)&&(n.__=t,n.u=e,j.__H.__h.push(n))}function $s(t,e){var n=ms(ce++,7);return gs(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function va(){for(var t;t=_s.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(oe),t.__H.__h.forEach(We),t.__H.__h=[]}catch(e){t.__H.__h=[],R.__e(e,t.__v)}}R.__b=function(t){j=null,En&&En(t)},R.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),On&&On(t,e)},R.__r=function(t){Ln&&Ln(t),ce=0;var e=(j=t.__c).__H;e&&(Ne===j?(e.__h=[],j.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(oe),e.__h.forEach(We),e.__h=[],ce=0)),Ne=j},R.diffed=function(t){Mn&&Mn(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(_s.push(e)!==1&&Dn===R.requestAnimationFrame||((Dn=R.requestAnimationFrame)||fa)(va)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Ne=j=null},R.__c=function(t,e){e.some(function(n){try{n.__h.forEach(oe),n.__h=n.__h.filter(function(s){return!s.__||We(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],R.__e(s,n.__v)}}),jn&&jn(t,e)},R.unmount=function(t){In&&In(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{oe(s)}catch(a){e=a}}),n.__H=void 0,e&&R.__e(e,n.__v))};var zn=typeof requestAnimationFrame=="function";function fa(t){var e,n=function(){clearTimeout(s),zn&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);zn&&(e=requestAnimationFrame(n))}function oe(t){var e=j,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),j=e}function We(t){var e=j;t.__c=t.__(),j=e}function gs(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}var _a=Symbol.for("preact-signals");function Se(){if(tt>1)tt--;else{for(var t,e=!1;Ct!==void 0;){var n=Ct;for(Ct=void 0,Ge++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&bs(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(Ge=0,tt--,e)throw t}}function ma(t){if(tt>0)return t();tt++;try{return t()}finally{Se()}}var x=void 0;function hs(t){var e=x;x=void 0;try{return t()}finally{x=e}}var Ct=void 0,tt=0,Ge=0,de=0;function ys(t){if(x!==void 0){var e=t.n;if(e===void 0||e.t!==x)return e={i:0,S:t,p:x.s,n:void 0,t:x,e:void 0,x:void 0,r:e},x.s!==void 0&&(x.s.n=e),x.s=e,t.n=e,32&x.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=x.s,e.n=void 0,x.s.n=e,x.s=e),e}}function L(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}L.prototype.brand=_a;L.prototype.h=function(){return!0};L.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:hs(function(){var s;(s=e.W)==null||s.call(e)}))};L.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&hs(function(){var a;(a=e.Z)==null||a.call(e)}))}};L.prototype.subscribe=function(t){var e=this;return Wt(function(){var n=e.value,s=x;x=void 0;try{t(n)}finally{x=s}},{name:"sub"})};L.prototype.valueOf=function(){return this.value};L.prototype.toString=function(){return this.value+""};L.prototype.toJSON=function(){return this.value};L.prototype.peek=function(){var t=x;x=void 0;try{return this.value}finally{x=t}};Object.defineProperty(L.prototype,"value",{get:function(){var t=ys(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Ge>100)throw new Error("Cycle detected");this.v=t,this.i++,de++,tt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Se()}}}});function f(t,e){return new L(t,e)}function bs(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function ks(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function xs(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function ot(t,e){L.call(this,void 0),this.x=t,this.s=void 0,this.g=de-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}ot.prototype=new L;ot.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===de))return!0;if(this.g=de,this.f|=1,this.i>0&&!bs(this))return this.f&=-2,!0;var t=x;try{ks(this),x=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return x=t,xs(this),this.f&=-2,!0};ot.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}L.prototype.S.call(this,t)};ot.prototype.U=function(t){if(this.t!==void 0&&(L.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};ot.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(ot.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=ys(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function _t(t,e){return new ot(t,e)}function ws(t){var e=t.u;if(t.u=void 0,typeof e=="function"){tt++;var n=x;x=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,_n(t),s}finally{x=n,Se()}}}function _n(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,ws(t)}function $a(t){if(x!==this)throw new Error("Out-of-order effect");xs(this),x=t,this.f&=-2,8&this.f&&_n(this),Se()}function $t(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}$t.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};$t.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,ws(this),ks(this),tt++;var t=x;return x=this,$a.bind(this,t)};$t.prototype.N=function(){2&this.f||(this.f|=2,this.o=Ct,Ct=this)};$t.prototype.d=function(){this.f|=8,1&this.f||_n(this)};$t.prototype.dispose=function(){this.d()};function Wt(t,e){var n=new $t(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var Ss,Qt,ga=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Cs=[];Wt(function(){Ss=this.N})();function gt(t,e){C[t]=e.bind(null,C[t]||function(){})}function pe(t){if(Qt){var e=Qt;Qt=void 0,e()}Qt=t&&t.S()}function Ts(t){var e=this,n=t.data,s=ya(n);s.value=n;var a=$s(function(){for(var l=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=_t(function(){var _=s.value.value;return _===0?0:_===!0?"":_||""}),p=_t(function(){return!Array.isArray(u.value)&&!ns(u.value)}),c=Wt(function(){if(this.N=As,p.value){var _=u.value;l.__v&&l.__v.__e&&l.__v.__e.nodeType===3&&(l.__v.__e.data=_)}}),v=e.__$u.d;return e.__$u.d=function(){c(),v.call(this)},[p,u]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}Ts.displayName="ReactiveTextNode";Object.defineProperties(L.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Ts},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});gt("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof L&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});gt("__r",function(t,e){if(t(e),e.type!==Jt){pe();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return Wt(function(){r=this},{name:i}),r.c=a,r})(function(){var a;ga&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),pe(n)}});gt("__e",function(t,e,n,s){pe(),t(e,n,s)});gt("diffed",function(t,e){pe();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var l=i[r];l!==void 0&&!(r in s)&&(l.d(),i[r]=void 0)}else i={},n.U=i;for(var d in s){var u=i[d],p=s[d];u===void 0?(u=ha(n,d,p),i[d]=u):u.o(p,a)}for(var c in s)a[c]=s[c]}}t(e)});function ha(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(l,d){i.value=l,r=l.peek()},d:Wt(function(){this.N=As;var l=i.value.value;r!==l?(r=void 0,a?t[e]=l:l!=null&&(l!==!1||e[4]==="-")?t.setAttribute(e,l):t.removeAttribute(e)):r=void 0})}}gt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var l=r.__$u;l&&(r.__$u=void 0,l.d())}}t(e)});gt("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});St.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var l in this.props)if(!(l in t))return!0;return!1};function ya(t,e){return $s(function(){return f(t,e)},[])}var ba=function(t){queueMicrotask(function(){queueMicrotask(t)})};function ka(){ma(function(){for(var t;t=Cs.shift();)Ss.call(t)})}function As(){Cs.push(this)===1&&(C.requestAnimationFrame||ba)(ka)}const xa=["overview","board","activity","agents","tasks","journal","trpg","council"],Ns={tab:"overview",params:{},postId:null};function Fn(t){return!!t&&xa.includes(t)}function Ve(t){try{return decodeURIComponent(t)}catch{return t}}function Xe(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function wa(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Rs(t,e){const n=t[0],s=e.tab,a=Fn(n)?n:Fn(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Ve(t[2]):t[0]==="post"&&t[1]&&(i=Ve(t[1]))),{tab:a,params:e,postId:i}}function ve(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Ns;const n=Ve(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const l=n.indexOf("?");l>=0&&(s=n.slice(0,l),a=n.slice(l+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Xe(a),r=wa(s);return Rs(r,i)}function Sa(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Ns,params:Xe(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Xe(e.replace(/^\?/,""));return Rs(s,a)}function Ds(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const X=f(ve(window.location.hash));window.addEventListener("hashchange",()=>{X.value=ve(window.location.hash)});function Ce(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Ds(n)}function Ca(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Ta(){if(window.location.hash&&window.location.hash!=="#"){X.value=ve(window.location.hash);return}const t=Sa(window.location.pathname,window.location.search);if(t){X.value=t;const e=Ds(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",X.value=ve(window.location.hash)}const Aa=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function Na(){const t=X.value.tab;return o`
    <div class="main-tab-bar">
      ${Aa.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Ce(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Hn="masc_dashboard_sse_session_id",Ra=1e3,Da=15e3,mt=f(!1),mn=f(0),Ps=f(null),fe=f([]);function Pa(){let t=sessionStorage.getItem(Hn);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Hn,t)),t}const Ea=200;function q(t,e){const n={agent:t,text:e,timestamp:Date.now()};fe.value=[n,...fe.value].slice(0,Ea)}let V=null,dt=null,Ye=0;function Es(){dt&&(clearTimeout(dt),dt=null)}function La(){if(dt)return;Ye++;const t=Math.min(Ye,5),e=Math.min(Da,Ra*Math.pow(2,t));dt=setTimeout(()=>{dt=null,Ls()},e)}function Ls(){Es(),V&&(V.close(),V=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Pa());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);V=i,i.onopen=()=>{V===i&&(Ye=0,mt.value=!0)},i.onerror=()=>{V===i&&(mt.value=!1,i.close(),V=null,La())},i.onmessage=r=>{try{const l=JSON.parse(r.data);mn.value++,Ps.value=l,Ma(l)}catch{}}}function Ma(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":q(n,"Joined");break;case"agent_left":q(n,"Left");break;case"broadcast":q(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":q(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":q(n,"New post");break;case"board_comment":q(n,"New comment");break;case"keeper_heartbeat":q(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":q(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":q(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":q(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:q(n,e)}}function ja(){Es(),V&&(V.close(),V=null),mt.value=!1}function Ms(){return new URLSearchParams(window.location.search)}function js(){const t=Ms(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Is(){return{...js(),"Content-Type":"application/json"}}const Ia=15e3,Os=3e4,Oa=6e4;async function $n(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(a)}}function za(){var e,n;const t=Ms();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Gt(t){const e=await $n(t,{headers:js()},Ia);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function Vt(t,e){const n=await $n(t,{method:"POST",headers:Is(),body:JSON.stringify(e)},Os);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function Fa(t,e,n,s=Os){const a=await $n(t,{method:"POST",headers:{...Is(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function Ha(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Ua(t){var e,n,s,a,i,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((l=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function O(t,e){const n=await Fa("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Oa),s=Ha(n);return Ua(s)}function zs(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function Ba(t="compact"){return Gt(`/api/v1/dashboard?mode=${t}`)}function Ka(t){const n=new URLSearchParams().toString();return Gt(`/api/v1/board${n?`?${n}`:""}`)}function qa(t){return Gt(`/api/v1/board/${t}`)}function Fs(t,e){return Vt("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:za()})}function Ja(t,e,n){return Vt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Wa(t){const e=m(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function te(...t){for(const e of t){const n=m(e,"");if(n.trim())return n.trim()}return""}function Un(t){const e=Wa(te(t.outcome,t.result,t.result_code));if(!e)return;const n=te(t.reason,t.reason_code,t.description,t.detail),s=te(t.summary,t.summary_ko,t.summary_en,t.note),a=(()=>{const r=E(t.turn,Number.NaN);if(Number.isFinite(r))return r;const l=E(t.turn_number,Number.NaN);if(Number.isFinite(l))return l;const d=E(t.current_turn,Number.NaN);if(Number.isFinite(d))return d;const u=E(t.round,Number.NaN);return Number.isFinite(u)?u:void 0})(),i=te(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,turn:a,phase:i||void 0}}function Ga(t,e){const n=D(t.state)?t.state:{};if(m(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>D(r)?m(r.type,"")==="session.outcome":!1),i=D(n.session_outcome)?n.session_outcome:{};if(D(i)&&Object.keys(i).length>0){const r=Un(i);if(r)return r}if(D(a))return Un(D(a.payload)?a.payload:{})}function D(t){return typeof t=="object"&&t!==null}function m(t,e=""){return typeof t=="string"?t:e}function E(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Ze(t,e=!1){return typeof t=="boolean"?t:e}function Re(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(D(e)){const n=m(e.name,"").trim(),s=m(e.id,"").trim(),a=m(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Va(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function U(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}function Xa(t,e){if(t!=="dice.rolled")return;const n=E(e.raw_d20,0),s=E(e.total,0),a=E(e.bonus,0),i=m(e.action,"roll"),r=E(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Ya(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Za(t,e,n){const s=e||m(n.actor_id,"");switch(t){case"turn.action.proposed":{const a=m(n.proposed_action,m(n.reply,""));return a?`${s||"actor"}: ${a}`:"Action proposed"}case"turn.action.resolved":{const a=m(n.reply,m(n.result,""));return a?`Resolved: ${a}`:"Action resolved"}case"narration.posted":return m(n.reply,m(n.content,m(n.text,"Narration")));case"dice.rolled":{const a=m(n.action,"roll"),i=E(n.total,0),r=E(n.dc,0),l=m(n.label,""),d=s||"actor",u=r>0?` vs DC ${r}`:"",p=l?` (${l})`:"";return`${d} ${a}: ${i}${u}${p}`}case"turn.started":return`Turn ${E(n.turn,1)} started`;case"phase.changed":return`Phase: ${m(n.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${m(n.name,s||"unknown")}`;case"actor.claimed":return`${m(n.keeper_name,m(n.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${m(n.keeper_name,m(n.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${E(n.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${E(n.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||m(n.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||m(n.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${m(n.reason_code,"unknown")}`;case"memory.signal":{const a=D(n.entity_refs)?n.entity_refs:{},i=m(a.requested_tier,""),r=m(a.effective_tier,""),l=Ze(a.guardrail_applied,!1),d=m(n.summary_en,m(n.summary_ko,"Memory signal"));if(!i&&!r)return d;const u=i&&r?`${i}->${r}`:r||i;return`${d} [${u}${l?" (guardrail)":""}]`}case"world.event":{if(m(n.event_type,"")==="canon.check"){const i=m(n.status,"unknown"),r=m(n.contract_id,"n/a");return`Canon ${i}: ${r}`}return m(n.description,m(n.summary,"World event"))}case"combat.attack":return m(n.summary,m(n.result,"Attack resolved"));case"combat.defense":return m(n.summary,m(n.result,"Defense resolved"));case"session.outcome":return m(n.summary,m(n.outcome,"Session ended"));default:{const a=Ya(n);return a?`${t}: ${a}`:t}}}function Qa(t){const e=D(t)?t:{},n=m(e.type,"event"),s=typeof e.actor_id=="string"?e.actor_id:"",a=D(e.payload)?e.payload:{};return{type:n,actor:s||m(a.actor_id,""),content:Za(n,s,a),dice_roll:Xa(n,a),timestamp:m(e.ts,new Date().toISOString())}}function ti(t,e,n){var Z,K;const s=m(t.room_id,"")||n||"default",a=D(t.state)?t.state:{},i=D(a.party)?a.party:{},r=D(a.actor_control)?a.actor_control:{},l=D(a.join_gate)?a.join_gate:{},d=D(a.contribution_ledger)?a.contribution_ledger:{},p=Object.entries(i).map(([M,N])=>{const g=D(N)?N:{},Yt=U(g,"max_hp",void 0,10),xn=U(g,"hp",void 0,Yt),ta=U(g,"max_mp",void 0,0),ea=U(g,"mp",void 0,0),na=U(g,"level",void 0,1),sa=U(g,"xp",void 0,0),aa=Ze(g.alive,xn>0),wn=r[M],Sn=typeof wn=="string"?wn:void 0,ia=Va(g.role,M,Sn);return{id:M,name:m(g.name,M),role:ia,keeper:Sn,archetype:m(g.archetype,""),persona:m(g.persona,""),traits:Re(g.traits),skills:Re(g.skills),status:aa?"active":"dead",stats:{hp:xn,max_hp:Yt,mp:ea,max_mp:ta,level:na,xp:sa,strength:U(g,"strength","str",10),dexterity:U(g,"dexterity","dex",10),constitution:U(g,"constitution","con",10),intelligence:U(g,"intelligence","int",10),wisdom:U(g,"wisdom","wis",10),charisma:U(g,"charisma","cha",10)}}}).filter(M=>M.status!=="dead"),c=Ga(t,e),v={phase_open:Ze(l.phase_open,!0),min_points:E(l.min_points,3),window:m(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},_=Object.entries(d).map(([M,N])=>{const g=D(N)?N:{};return{actor_id:M,score:E(g.score,0),last_reason:m(g.last_reason,"")||null,reasons:Re(g.reasons)}}),b=e.map(Qa),P=E(a.turn,1),T=m(a.phase,"round"),w=m(a.map,""),k=D(a.world)?a.world:{},z=w||m(k.ascii_map,m(k.map,"")),F=b.filter((M,N)=>{const g=e[N];if(!D(g))return!1;const Yt=D(g.payload)?g.payload:{};return E(Yt.turn,-1)===P}),A=(F.length>0?F:b).slice(-12),H=m(a.status,"active");return{session:{id:s,room:s,status:H==="ended"?"ended":H==="paused"?"paused":"active",round:P,actors:p,created_at:((Z=b[0])==null?void 0:Z.timestamp)??new Date().toISOString()},current_round:{round_number:P,phase:T,events:A,timestamp:((K=b[b.length-1])==null?void 0:K.timestamp)??new Date().toISOString()},map:z||void 0,join_gate:v,contribution_ledger:_,outcome:c,party:p,story_log:b,history:[]}}async function ei(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Gt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function ni(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([Gt(`/api/v1/trpg/state${e}`),ei(t)]);return ti(n,s,t)}function si(t){return Vt("/api/v1/trpg/rounds/run",{room_id:t})}function ai(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function ii(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Vt("/api/v1/trpg/dice/roll",e)}function oi(t,e){const n=ai();return Vt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function ri(t,e,n){const s=await O("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function li(t){const e=await O("trpg.mid_join.request",t);return JSON.parse(e)}async function Hs(t,e){await O("masc_broadcast",{agent_name:t,message:e})}async function ci(t,e,n=1){await O("masc_add_task",{title:t,description:e,priority:n})}async function ui(t){return O("masc_join",{agent_name:t})}async function Us(t){await O("masc_leave",{agent_name:t})}async function di(t){await O("masc_heartbeat",{agent_name:t})}async function pi(t=40){return(await O("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function vi(t,e=20){return O("masc_task_history",{task_id:t,limit:e})}async function fi(){const t=await O("masc_debates",{});return zs(t)}async function _i(){const t=await O("masc_sessions",{});return zs(t)}async function mi(t){const e=await O("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function $i(t){return O("masc_debate_status",{debate_id:t})}const ht=f([]),Xt=f([]),Bs=f([]),yt=f([]),gn=f(null),wt=f(null),Qe=f(new Map),Ks=f([]),Bn=f("hot"),qs=f(null),pt=f(""),tn=f(!1),en=f(!1),nn=f(!1),gi=_t(()=>ht.value.filter(t=>t.status==="active"||t.status==="idle")),Js=_t(()=>{const t=Xt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function hi(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const yi=_t(()=>{const t=new Map;for(const e of yt.value)t.set(e.name,hi(e));return t}),bi=12e4,ki=_t(()=>{const t=Date.now(),e=new Set,n=Qe.value;for(const s of yt.value){const a=n.get(s.name);a!=null&&t-a>bi&&e.add(s.name)}return e}),_e={},xi=5e3;function sn(){delete _e.compact,delete _e.full}function J(t){return typeof t=="object"&&t!==null}function $(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function h(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Tt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ws(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function wi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Si(t){if(!J(t))return null;const e=$(t.name);return e?{name:e,status:Ws(t.status),current_task:$(t.current_task)??null,last_seen:$(t.last_seen),emoji:$(t.emoji),koreanName:$(t.koreanName)??$(t.korean_name),model:$(t.model),traits:Tt(t.traits),interests:Tt(t.interests),activityLevel:h(t.activityLevel)??h(t.activity_level),primaryValue:$(t.primaryValue)??$(t.primary_value)}:null}function Ci(t){if(!J(t))return null;const e=$(t.id),n=$(t.title);return!e||!n?null:{id:e,title:n,status:wi(t.status),priority:h(t.priority),assignee:$(t.assignee),description:$(t.description),created_at:$(t.created_at),updated_at:$(t.updated_at)}}function Ti(t){if(!J(t))return null;const e=$(t.from)??$(t.from_agent)??"system",n=$(t.content)??"",s=$(t.timestamp)??new Date().toISOString();return{id:$(t.id),seq:h(t.seq),from:e,content:n,timestamp:s,type:$(t.type)}}function Ai(t){return Array.isArray(t)?t.map(e=>{if(!J(e))return null;const n=h(e.ts_unix);if(n==null)return null;const s=J(e.handoff)?e.handoff:null;return{ts:n,context_ratio:h(e.context_ratio)??0,context_tokens:h(e.context_tokens)??0,context_max:h(e.context_max)??0,latency_ms:h(e.latency_ms)??0,generation:h(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:h(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:h(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?h(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ni(t){return(Array.isArray(t)?t:J(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!J(n))return null;const s=J(n.agent)?n.agent:null,a=J(n.context)?n.context:null,i=J(n.metrics_window)?n.metrics_window:void 0,r=$(n.name);if(!r)return null;const l=h(n.context_ratio)??h(a==null?void 0:a.context_ratio),d=$(n.status)??$(s==null?void 0:s.status)??"offline",u=Ws(d),p=$(n.model)??$(n.active_model)??$(n.primary_model),c=Tt(n.skill_secondary),v=a?{source:$(a.source),context_ratio:h(a.context_ratio),context_tokens:h(a.context_tokens),context_max:h(a.context_max),message_count:h(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,_=s?{name:$(s.name),status:$(s.status),current_task:$(s.current_task)??null,last_seen:$(s.last_seen)}:void 0,b=Ai(n.metrics_series);return{name:r,emoji:$(n.emoji),koreanName:$(n.koreanName)??$(n.korean_name),agent_name:$(n.agent_name),trace_id:$(n.trace_id),model:p,primary_model:$(n.primary_model),active_model:$(n.active_model),next_model_hint:$(n.next_model_hint)??null,status:u,last_heartbeat:$(n.last_heartbeat)??$(s==null?void 0:s.last_seen),generation:h(n.generation),turn_count:h(n.turn_count)??h(n.total_turns),context_ratio:l,context_tokens:h(n.context_tokens)??h(a==null?void 0:a.context_tokens),context_max:h(n.context_max)??h(a==null?void 0:a.context_max),context_source:$(n.context_source)??$(a==null?void 0:a.source),context:v,traits:Tt(n.traits),interests:Tt(n.interests),primaryValue:$(n.primaryValue)??$(n.primary_value),activityLevel:h(n.activityLevel)??h(n.activity_level),memory_recent_note:$(n.memory_recent_note)??null,conversation_tail_count:h(n.conversation_tail_count),k2k_count:h(n.k2k_count),handoff_count_total:h(n.handoff_count_total)??h(n.trace_history_count),compaction_count:h(n.compaction_count),last_compaction_saved_tokens:h(n.last_compaction_saved_tokens),skill_primary:$(n.skill_primary)??null,skill_secondary:c,skill_reason:$(n.skill_reason)??null,metrics_series:b.length>0?b:void 0,metrics_window:i,agent:_}}).filter(n=>n!==null)}async function Te(t="full"){var s,a,i;const e=Date.now(),n=_e[t];if(!(n&&e-n.time<xi)){tn.value=!0;try{const r=await Ba(t);_e[t]={data:r,time:e},ht.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(Si).filter(l=>l!==null),Xt.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(Ci).filter(l=>l!==null),Bs.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Ti).filter(l=>l!==null),yt.value=Ni(r.keepers),gn.value=J(r.status)?r.status:null,wt.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{tn.value=!1}}}async function rt(){en.value=!0;try{const t=await Ka();Ks.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{en.value=!1}}async function at(){var t;nn.value=!0;try{const e=pt.value||((t=gn.value)==null?void 0:t.room)||"default";pt.value||(pt.value=e);const n=await ni(e);qs.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{nn.value=!1}}let De=null,Pe=null;function Ri(){return Ps.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Qe.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Qe.value=n}sn(),De||(De=setTimeout(()=>{Te(),De=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Pe||(Pe=setTimeout(()=>{rt(),Pe=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&sn()}})}let At=null;function Di(){At||(At=setInterval(()=>{sn(),Te()},1e4))}function Pi(){At&&(clearInterval(At),At=null)}function S({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function et({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Ei(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function Y({timestamp:t}){const e=Ei(t);return o`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const hn=f(null);function Gs(t){hn.value=t}function Kn(){hn.value=null}function re(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Li({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${re(t.context_tokens)}</div>
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
  `}function Mi({keeper:t}){var p,c;const e=t.metrics_series??[];if(e.length<2){const v=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,_=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${_}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((v,_)=>{const b=a+_/(i-1)*(n-2*a),P=s-a-(v.context_ratio??0)*(s-2*a);return{x:b,y:P,p:v}}),l=r.map(({x:v,y:_})=>`${v.toFixed(1)},${_.toFixed(1)}`).join(" "),d=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,u=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>o`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:_})=>o`
          <circle cx="${v.toFixed(1)}" cy="${_.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Ee=f("");function ji({keeper:t}){var a,i,r,l;const e=Ee.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${re(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${re(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${re(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Ii({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Oi({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function zi({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function qn({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Le(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Fi({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Le(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Le(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Le(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Hi(){var e,n,s;const t=hn.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Kn()}}
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
            onClick=${()=>Kn()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Li} keeper=${t} />

        ${""}
        <${Mi} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${S} title="Field Dictionary">
            <${ji} keeper=${t} />
          <//>

          ${""}
          <${S} title="Profile">
            <${qn} traits=${t.traits??[]} label="Traits" />
            <${qn} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${Y} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?o`
              <${S} title="TRPG Stats">
                <${Ii} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${S} title="Equipment (${t.inventory.length})">
                <${Oi} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${S} title="Relationships (${Object.keys(t.relationships).length})">
                <${zi} rels=${t.relationships} />
              <//>
            `:null}

          <${S} title="Runtime Signals">
            <${Fi} keeper=${t} />
          <//>

          <${S} title="Memory & Context">
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
  `:null}let Ui=0;const st=f([]);function y(t,e="success",n=4e3){const s=++Ui;st.value=[...st.value,{id:s,message:t,type:e}],setTimeout(()=>{st.value=st.value.filter(a=>a.id!==s)},n)}function Bi(t){st.value=st.value.filter(e=>e.id!==t)}function Ki(){const t=st.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Bi(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const qi="masc_dashboard_agent_name",bt=f(null),me=f(!1),Bt=f(""),$e=f([]),Kt=f([]),vt=f(""),Nt=f(!1);function Vs(t){bt.value=t,yn()}function Jn(){bt.value=null,Bt.value="",$e.value=[],Kt.value=[],vt.value=""}function Ji(){const t=bt.value;return t?ht.value.find(e=>e.name===t)??null:null}function Xs(t){return t?Xt.value.filter(e=>e.assignee===t):[]}async function yn(){const t=bt.value;if(t){me.value=!0,Bt.value="",$e.value=[],Kt.value=[];try{const e=await pi(80);$e.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Xs(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await vi(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));Kt.value=s}catch(e){Bt.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{me.value=!1}}}async function Wn(){var s;const t=bt.value,e=vt.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(qi))==null?void 0:s.trim())||"dashboard";Nt.value=!0;try{await Hs(n,`@${t} ${e}`),vt.value="",y(`Mention sent to ${t}`,"success"),yn()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";y(i,"error")}finally{Nt.value=!1}}function Wi({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${et} status=${t.status} />
    </div>
  `}function Gi({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Vi(){var a,i,r,l;const t=bt.value;if(!t)return null;const e=Ji(),n=Xs(t),s=$e.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Jn()}}
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
                    ${e.last_seen?o`<span>Last seen: <${Y} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{yn()}} disabled=${me.value}>
              ${me.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Jn}>Close</button>
          </div>
        </div>

        ${Bt.value?o`<div class="council-error">${Bt.value}</div>`:null}

        <div class="agent-detail-grid">
          <${S} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Wi} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${S} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((d,u)=>o`<div key=${u} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${S} title="Task History">
          ${Kt.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Kt.value.map(d=>o`<${Gi} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${S} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${vt.value}
              onInput=${d=>{vt.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Wn()}}
              disabled=${Nt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Wn()}}
              disabled=${Nt.value||vt.value.trim()===""}
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
  `}function Xi({agent:t}){return o`
    <div class="agent" onClick=${()=>Vs(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${et} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Yi(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Zi(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function Gn(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Qi({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=yi.value.get(t.name),a=ki.value.has(t.name);return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>Gs(t)} style="cursor: pointer">
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
              <div class="keeper-ctx-fill ${Gn(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${Gn(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${Yi(t.context_tokens)})`:null}
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
            <${Y} timestamp=${t.last_heartbeat} />
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
          <div class="keeper-note-preview">${Zi(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function Vn(){const t=gn.value,e=ht.value,n=yt.value,s=Js.value;return o`
    <div class="stats-grid">
      <${lt} label="Agents" value=${e.length} />
      <${lt} label="Active" value=${gi.value.length} color="#4ade80" />
      <${lt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${lt} label="Tasks" value=${Xt.value.length} />
      <${lt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${lt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${S} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(a=>o`<${Xi} key=${a.name} agent=${a} />`)}
        </div>
      <//>

      <${S} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(a=>o`<${Qi} key=${a.name} keeper=${a} />`)}
        </div>
      <//>
    </div>

    ${wt.value?o`
        <${S} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${wt.value.running?"Running":"Stopped"}</span>
            ${wt.value.goal?o`<span>Goal: ${wt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${S} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${to(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
          </div>
        <//>
      `:null}
  `}function to(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const an=f([]),on=f([]),Rt=f(""),ge=f(!1),Dt=f(!1),he=f(""),ye=f(null),Pt=f(""),rn=f(!1);async function ln(){ge.value=!0,he.value="";try{const[t,e]=await Promise.all([fi(),_i()]);an.value=t,on.value=e}catch(t){he.value=t instanceof Error?t.message:"Failed to load council data"}finally{ge.value=!1}}async function Xn(){const t=Rt.value.trim();if(t){Dt.value=!0;try{const e=await mi(t);Rt.value="",y(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await ln()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";y(n,"error")}finally{Dt.value=!1}}}async function eo(t){ye.value=t,rn.value=!0,Pt.value="";try{Pt.value=await $i(t)}catch(e){Pt.value=e instanceof Error?e.message:"Failed to load debate status"}finally{rn.value=!1}}function no({debate:t}){const e=ye.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>eo(t.id)}
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
  `}function so({session:t}){return o`
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
  `}function ao(){return ue(()=>{ln()},[]),o`
    <div>
      <${S} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Rt.value}
            onInput=${t=>{Rt.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Xn()}}
            disabled=${Dt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Xn}
            disabled=${Dt.value||Rt.value.trim()===""}
          >
            ${Dt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${ln} disabled=${ge.value}>
            ${ge.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${he.value?o`<div class="council-error">${he.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${S} title="Debates" class="section">
          <div class="council-list">
            ${an.value.length===0?o`<div class="empty-state">No debates yet</div>`:an.value.map(t=>o`<${no} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${S} title="Voting Sessions" class="section">
          <div class="council-list">
            ${on.value.length===0?o`<div class="empty-state">No active sessions</div>`:on.value.map(t=>o`<${so} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${S} title=${ye.value?`Debate Detail (${ye.value})`:"Debate Detail"} class="section">
        ${rn.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Pt.value?o`<pre class="council-detail">${Pt.value}</pre>`:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function io({text:t}){if(!t)return null;const e=oo(t);return o`<div class="markdown-content">${e}</div>`}function oo(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],l=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${l?`language-${l}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],l=a.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const u=e[s].replace("</think>","").trim();u&&r.push(u),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Me(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${Me(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${Me(i.join(`
`))}</p>`)}return n}function Me(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const ro=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Et=f([]),Lt=f(!1),Mt=f(""),lo=f("dashboard-user"),jt=f(!1);async function Ys(t){Lt.value=!0,Et.value=[];try{const e=await qa(t);Et.value=e.comments??[]}catch{}finally{Lt.value=!1}}async function Yn(t){const e=Mt.value.trim();if(e){jt.value=!0;try{await Ja(t,lo.value,e),Mt.value="",y("Comment posted","success"),await Ys(t),rt()}catch{y("Failed to post comment","error")}finally{jt.value=!1}}}function co(){const t=Bn.value;return o`
    <div class="board-controls">
      ${ro.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{Bn.value=e.id,rt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Zs({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function uo({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Fs(t.id,n),rt()}catch{y("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Ca(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Zs} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${Y} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function po({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${Y} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function vo({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Mt.value}
        onInput=${e=>{Mt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Yn(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${jt.value}
      />
      <button
        onClick=${()=>Yn(t)}
        disabled=${jt.value||Mt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${jt.value?"...":"Post"}
      </button>
    </div>
  `}function fo({post:t}){Et.value.length===0&&!Lt.value&&Ys(t.id);const e=async n=>{try{await Fs(t.id,n),rt()}catch{y("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Ce("board")}>← Back to Board</button>
      <${S} title=${o`${t.title} <${Zs} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${io} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${Y} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${S} title="Comments (${Lt.value?"...":Et.value.length})">
        ${Lt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${po} comments=${Et.value} />`}
        <${vo} postId=${t.id} />
      <//>
    </div>
  `}function _o(){const t=Ks.value,e=en.value,n=X.value.postId;if(n){const s=t.find(a=>a.id===n);return s?o`<${fo} post=${s} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>Ce("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${co} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(s=>o`<${uo} key=${s.id} post=${s} />`)}
          </div>`}
  `}function mo(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function $o(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function Zn(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function go({row:t}){return o`
    <div class="message-row">
      <span class="message-agent">${t.actor}</span>
      <span class="message-source ${t.source}">${t.source}</span>
      <span class="message-text">${t.content}</span>
      <span class="message-time"><${Y} timestamp=${t.timestamp} /></span>
    </div>
  `}function ho(){const t=Bs.value.map(mo),e=fe.value.map($o),n=[...t,...e].sort((s,a)=>Zn(a.timestamp)-Zn(s.timestamp)).slice(0,80);return o`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${n.length===0?o`<div class="empty-state">No recent activity</div>`:n.map(s=>o`<${go} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function Qs({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),o`
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
  `}const yo={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function bo(t){return yo[t]}function ct({metric:t}){const e=bo(t);return o`
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
  `}function ko({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>Vs(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${Qs} ratio=${t.context_ratio} />
        <${et} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function xo(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function wo(t){var a,i,r;const e=(a=t.last_drift_reason)==null?void 0:a.trim();if(e)return e;const n=(i=t.last_proactive_reason)==null?void 0:i.trim();if(n)return n;const s=(r=t.memory_recent_note)==null?void 0:r.trim();return s||"—"}function So(t){var s;const e=t.k2k_count??0,n=(s=t.k2k_mentions)==null?void 0:s[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function Co(t){var s;const e=t.drift_count_total??0,n=xo((s=t.metrics_window)==null?void 0:s.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function To({keeper:t}){const e=wo(t),n=So(t),s=Co(t);return o`
    <div class="live-agent keeper-card" onClick=${()=>Gs(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Qs} ratio=${t.context_ratio} />
        <${et} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${ct} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?o`<${Y} timestamp=${t.created_at} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${ct} metric="generation" /></span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${ct} metric="status" /></span>
            <strong class="keeper-core-value">${t.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${ct} metric="relations" /></span>
            <strong class="keeper-core-value">${n}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${ct} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${e}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${ct} metric="personality_change" /></span>
            <strong class="keeper-core-value">${s}</strong>
          </div>
        </div>
      </div>
    </div>
  `}function Ao(){const t=ht.value,e=yt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${To} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${ko} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function je({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${Y} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function No(){const{todo:t,inProgress:e,done:n}=Js.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${je} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${je} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${je} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function Ro({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function Do(){const t=fe.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${Ro} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const xt=f(""),Ie=f("ability_check"),Oe=f("10"),ze=f("12"),ee=f(""),ne=f("idle"),se=f(""),ae=f("keeper-late"),Fe=f("player"),He=f(""),B=f("idle"),Ue=f(null),cn=f(null);function Po(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Eo(t,e){return e>0?Math.round(t/e*100):0}const Lo={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Mo={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Be(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function jo(t){const e=t.trim().toLowerCase();return Lo[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Io(t){const e=t.trim().toLowerCase();return Mo[e]??"상황에 따라 선택되는 전술 액션입니다."}function it(t){return typeof t=="object"&&t!==null}function I(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function G(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function qt(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}function Oo({hp:t,max:e}){const n=Eo(t,e),s=Po(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function zo({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Fo({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Ho({actor:t}){var i,r;const e=(i=t.archetype)==null?void 0:i.trim(),n=(r=t.persona)==null?void 0:r.trim(),s=t.traits??[],a=t.skills??[];return o`
    <div class="trpg-actor">
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${et} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Fo} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Oo} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${zo} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Be(e)}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${s.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${s.map(l=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Be(l)}</span>
                  <span class="trpg-annot-desc">${jo(l)}</span>
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
                  <span class="trpg-annot-name">${Be(l)}</span>
                  <span class="trpg-annot-desc">${Io(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Uo({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Bo({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var s;return o`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?o`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?o`<span class="trpg-dice">[${e.dice_roll.notation}: ${(s=e.dice_roll.rolls)==null?void 0:s.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${Y} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function Ko({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function qo({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Jo({state:t}){var d;const e=pt.value||((d=t.session)==null?void 0:d.room)||"",n=ne.value,s=t.party??[];if(!s.find(u=>u.id===xt.value)&&s.length>0){const u=s[0];u&&(xt.value=u.id)}const i=async()=>{if(!e){y("No room set","error");return}ne.value="running";try{const u=await si(e);cn.value=u,ne.value="ok";const p=it(u.summary)?u.summary:null,c=p?qt(p,"advanced",!1):!1,v=p?I(p,"progress_reason",""):"";y(c?"Round advanced":`Round stalled${v?`: ${v}`:""}`,c?"success":"warning"),at()}catch(u){cn.value=null,ne.value="error";const p=u instanceof Error?u.message:"Round failed";y(p,"error")}},r=async()=>{if(e)try{await oi(e),y("Turn advanced","success"),at()}catch{y("Advance failed","error")}},l=async()=>{if(!e)return;const u=xt.value.trim();if(!u){y("Select actor first","warning");return}const p=Number.parseInt(Oe.value,10),c=Number.parseInt(ze.value,10);if(Number.isNaN(p)||Number.isNaN(c)){y("Stat/DC must be numbers","warning");return}const v=Number.parseInt(ee.value,10),_=ee.value.trim()===""||Number.isNaN(v)?void 0:v;try{await ii({roomId:e,actorId:u,action:Ie.value.trim()||"ability_check",statValue:p,dc:c,rawD20:_}),y("Dice rolled","success"),at()}catch{y("Dice roll failed","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
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
              value=${Ie.value}
              onInput=${u=>{Ie.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Oe.value}
              onInput=${u=>{Oe.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ze.value}
              onInput=${u=>{ze.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ee.value}
              onInput=${u=>{ee.value=u.target.value}}
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
  `}function Wo({state:t}){var l;const e=pt.value||((l=t.session)==null?void 0:l.room)||"",n=t.join_gate,s=Ue.value,a=it(s)?s:null,i=async()=>{const d=se.value.trim(),u=ae.value.trim();if(!e||!d){y("Room/Actor is required","warning");return}B.value="checking";try{const p=await ri(e,d,u||void 0);Ue.value=p,B.value="ok",y("Eligibility updated","success")}catch(p){B.value="error";const c=p instanceof Error?p.message:"Eligibility check failed";y(c,"error")}},r=async()=>{const d=se.value.trim(),u=ae.value.trim(),p=He.value.trim();if(!e||!d||!u){y("Room/Actor/Keeper is required","warning");return}B.value="requesting";try{const c=await li({room_id:e,actor_id:d,keeper_name:u,role:Fe.value,...p?{name:p}:{}});Ue.value=c;const v=it(c)?qt(c,"granted",!1):!1,_=it(c)?I(c,"reason_code",""):"";v?y("Mid-join granted","success"):y(`Mid-join rejected${_?`: ${_}`:""}`,"warning"),B.value=v?"ok":"error",at()}catch(c){B.value="error";const v=c instanceof Error?c.message:"Mid-join request failed";y(v,"error")}};return o`
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
            value=${se.value}
            onInput=${d=>{se.value=d.target.value}}
            placeholder="player-xyz"
          />
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${ae.value}
            onInput=${d=>{ae.value=d.target.value}}
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
            id="trpg-join-name-input"
            name="trpg-join-name-input"
            type="text"
            value=${He.value}
            onInput=${d=>{He.value=d.target.value}}
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
            Eligible: <strong>${qt(a,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${G(a,"effective_score",0)}/${G(a,"required_points",0)}</span>
            ${I(a,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${I(a,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Go({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Vo({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Xo(){const t=cn.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=it(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(it).slice(-8),i=t.canon_check,r=it(i)?i:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(A=>typeof A=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(A=>typeof A=="string").slice(0,3):[],u=n?qt(n,"advanced",!1):!1,p=n?I(n,"progress_reason",""):"",c=n?I(n,"progress_detail",""):"",v=n?G(n,"player_successes",0):0,_=n?G(n,"player_required_successes",0):0,b=n?qt(n,"dm_success",!1):!1,P=n?G(n,"timeouts",0):0,T=n?G(n,"unavailable",0):0,w=n?G(n,"reprompts",0):0,k=n?G(n,"npc_attacks",0):0,z=n?G(n,"keeper_timeout_sec",0):0,F=n?G(n,"roll_audit_count",0):0;return o`
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
        ${c?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${P}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${z||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${F}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(A=>{const H=I(A,"status","unknown"),kt=I(A,"actor_id","-"),Z=I(A,"role","-"),K=I(A,"reason",""),M=I(A,"action_type",""),N=I(A,"reply","");return o`
                <div class="trpg-round-item ${H.includes("fallback")||H.includes("timeout")?"failed":"active"}">
                  <span>${kt} (${Z})</span>
                  <span style="margin-left:auto; font-size:11px;">${H}</span>
                  ${M?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${M}</div>`:null}
                  ${K?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${K}</div>`:null}
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
            ${l.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(A=>o`<div>warning: ${A}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Yo(){var i,r;const t=qs.value;if(nn.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>at()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome;return o`
    <div>
      <${Ko} outcome=${a} />

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
      <${Vo} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${S} title="Story Log (${s.length})">
            <${Bo} events=${s} />
          <//>

          ${""}
          ${t.map?o`
              <${S} title="Map" style="margin-top:16px;">
                <${Uo} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${S} title="Controls">
            <${Jo} state=${t} />
          <//>

          <${S} title="Last Round Result" style="margin-top:16px;">
            <${Xo} />
          <//>

          ${""}
          <${S} title="Mid-Join Gate" style="margin-top:16px;">
            <${Wo} state=${t} />
          <//>

          ${""}
          <${S} title="Contribution" style="margin-top:16px;">
            <${Go} state=${t} />
          <//>

          ${""}
          <${S} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(l=>o`<${Ho} key=${l.id??l.name} actor=${l} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${S} title="History (${t.history.length})" style="margin-top:16px;">
                <${qo} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const bn="masc_dashboard_agent_name";function Zo(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(bn);return e??n??"dashboard"}const W=f(Zo()),It=f(""),Ot=f(""),be=f(""),zt=f(!1),ut=f(!1),Ft=f(!1),Ht=f(!1),ke=f(!1),Ae=f(!1);function kn(t){const e=t.trim();W.value=e,e&&localStorage.setItem(bn,e)}function Qo(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function un(){const t=W.value.trim();if(t){Ft.value=!0;try{const e=await ui(t),n=Qo(e);n&&kn(n),Ae.value=!0,y(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";y(n,"error")}finally{Ft.value=!1}}}async function tr(){const t=W.value.trim();if(t){Ht.value=!0;try{await Us(t),Ae.value=!1,y(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";y(n,"error")}finally{Ht.value=!1}}}async function er(){const t=W.value.trim();if(t)try{await Us(t)}catch{}localStorage.removeItem(bn),kn("dashboard"),Ae.value=!1,await un()}async function nr(){const t=W.value.trim();if(t){ke.value=!0;try{await di(t),y("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";y(n,"error")}finally{ke.value=!1}}}async function Qn(){const t=W.value.trim(),e=It.value.trim();if(!(!t||!e)){zt.value=!0;try{await Hs(t,e),It.value="",y("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";y(s,"error")}finally{zt.value=!1}}}async function sr(){const t=Ot.value.trim(),e=be.value.trim()||"Created from dashboard";if(t){ut.value=!0;try{await ci(t,e,1),Ot.value="",be.value="",y("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";y(s,"error")}finally{ut.value=!1}}}function ar(){return ue(()=>{un()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${W.value}
        onInput=${t=>kn(t.target.value)}
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
          onKeyDown=${t=>{t.key==="Enter"&&Qn()}}
          disabled=${zt.value}
        />
        <button
          class="control-btn"
          onClick=${Qn}
          disabled=${zt.value||It.value.trim()===""||W.value.trim()===""}
        >
          ${zt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{un()}}
          disabled=${Ft.value||W.value.trim()===""}
        >
          ${Ft.value?"Joining...":Ae.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{tr()}}
          disabled=${Ht.value||W.value.trim()===""}
        >
          ${Ht.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{er()}}
          disabled=${Ft.value||Ht.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{nr()}}
          disabled=${ke.value||W.value.trim()===""}
        >
          ${ke.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Ot.value}
        onInput=${t=>{Ot.value=t.target.value}}
        disabled=${ut.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${be.value}
        onInput=${t=>{be.value=t.target.value}}
        disabled=${ut.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${sr}
        disabled=${ut.value||Ot.value.trim()===""}
      >
        ${ut.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function ir(){const t=mt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${mn.value} events</span>
    </div>
  `}const or=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function rr(){const t=X.value.tab,e=mt.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${or.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Ce(n.id)}
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
            <strong>${mn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Te(),t==="board"&&rt(),t==="trpg"&&at()}}
        >
          Refresh Now
        </button>
      </section>

      <${ar} />
    </aside>
  `}function lr(){switch(X.value.tab){case"overview":return o`<${Vn} />`;case"council":return o`<${ao} />`;case"board":return o`<${_o} />`;case"activity":return o`<${ho} />`;case"agents":return o`<${Ao} />`;case"tasks":return o`<${No} />`;case"journal":return o`<${Do} />`;case"trpg":return o`<${Yo} />`;default:return o`<${Vn} />`}}function cr(){return ue(()=>{Ta(),Ls(),Te();const t=Ri();return Di(),()=>{ja(),t(),Pi()}},[]),ue(()=>{const t=X.value.tab;t==="board"&&rt(),t==="trpg"&&at()},[X.value.tab]),o`
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
          <${ir} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${Na} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${tn.value&&!mt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${lr} />`}
        </main>
        <${rr} />
      </div>

      <${Hi} />
      <${Vi} />
      <${Ki} />
    </div>
  `}const ts=document.getElementById("app");ts&&da(o`<${cr} />`,ts);
