(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const r of a)if(r.type==="childList")for(const o of r.addedNodes)o.tagName==="LINK"&&o.rel==="modulepreload"&&s(o)}).observe(document,{childList:!0,subtree:!0});function n(a){const r={};return a.integrity&&(r.integrity=a.integrity),a.referrerPolicy&&(r.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?r.credentials="include":a.crossOrigin==="anonymous"?r.credentials="omit":r.credentials="same-origin",r}function s(a){if(a.ep)return;a.ep=!0;const r=n(a);fetch(a.href,r)}})();var Ne,C,fs,ms,rt,jn,_s,gs,$s,bn,Ze,Qe,Jt={},hs=[],xa=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Re=Array.isArray;function tt(t,e){for(var n in e)t[n]=e[n];return t}function kn(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function ys(t,e,n){var s,a,r,o={};for(r in e)r=="key"?s=e[r]:r=="ref"?a=e[r]:o[r]=e[r];if(arguments.length>2&&(o.children=arguments.length>3?Ne.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(r in t.defaultProps)o[r]===void 0&&(o[r]=t.defaultProps[r]);return de(t,o,s,a,null)}function de(t,e,n,s,a){var r={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++fs,__i:-1,__u:0};return a==null&&C.vnode!=null&&C.vnode(r),r}function Yt(t){return t.children}function Nt(t,e){this.props=t,this.context=e}function ht(t,e){if(e==null)return t.__?ht(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?ht(t):null}function bs(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return bs(t)}}function On(t){(!t.__d&&(t.__d=!0)&&rt.push(t)&&!fe.__r++||jn!=C.debounceRendering)&&((jn=C.debounceRendering)||_s)(fe)}function fe(){for(var t,e,n,s,a,r,o,c=1;rt.length;)rt.length>c&&rt.sort(gs),t=rt.shift(),c=rt.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,r=[],o=[],e.__P&&((n=tt({},s)).__v=s.__v+1,C.vnode&&C.vnode(n),xn(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,r,a??ht(s),!!(32&s.__u),o),n.__v=s.__v,n.__.__k[n.__i]=n,ws(r,n,o),s.__e=s.__=null,n.__e!=a&&bs(n)));fe.__r=0}function ks(t,e,n,s,a,r,o,c,u,l,p){var d,v,f,$,A,N,x,b=s&&s.__k||hs,j=e.length;for(u=wa(n,e,b,u,j),d=0;d<j;d++)(f=n.__k[d])!=null&&(v=f.__i==-1?Jt:b[f.__i]||Jt,f.__i=d,N=xn(t,f,v,a,r,o,c,u,l,p),$=f.__e,f.ref&&v.ref!=f.ref&&(v.ref&&wn(v.ref,null,f),p.push(f.ref,f.__c||$,f)),A==null&&$!=null&&(A=$),(x=!!(4&f.__u))||v.__k===f.__k?u=xs(f,u,t,x):typeof f.type=="function"&&N!==void 0?u=N:$&&(u=$.nextSibling),f.__u&=-7);return n.__e=A,u}function wa(t,e,n,s,a){var r,o,c,u,l,p=n.length,d=p,v=0;for(t.__k=new Array(a),r=0;r<a;r++)(o=e[r])!=null&&typeof o!="boolean"&&typeof o!="function"?(typeof o=="string"||typeof o=="number"||typeof o=="bigint"||o.constructor==String?o=t.__k[r]=de(null,o,null,null,null):Re(o)?o=t.__k[r]=de(Yt,{children:o},null,null,null):o.constructor===void 0&&o.__b>0?o=t.__k[r]=de(o.type,o.props,o.key,o.ref?o.ref:null,o.__v):t.__k[r]=o,u=r+v,o.__=t,o.__b=t.__b+1,c=null,(l=o.__i=Sa(o,n,u,d))!=-1&&(d--,(c=n[l])&&(c.__u|=2)),c==null||c.__v==null?(l==-1&&(a>p?v--:a<p&&v++),typeof o.type!="function"&&(o.__u|=4)):l!=u&&(l==u-1?v--:l==u+1?v++:(l>u?v--:v++,o.__u|=4))):t.__k[r]=null;if(d)for(r=0;r<p;r++)(c=n[r])!=null&&(2&c.__u)==0&&(c.__e==s&&(s=ht(c)),Cs(c,c));return s}function xs(t,e,n,s){var a,r;if(typeof t.type=="function"){for(a=t.__k,r=0;a&&r<a.length;r++)a[r]&&(a[r].__=t,e=xs(a[r],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=ht(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Sa(t,e,n,s){var a,r,o,c=t.key,u=t.type,l=e[n],p=l!=null&&(2&l.__u)==0;if(l===null&&c==null||p&&c==l.key&&u==l.type)return n;if(s>(p?1:0)){for(a=n-1,r=n+1;a>=0||r<e.length;)if((l=e[o=a>=0?a--:r++])!=null&&(2&l.__u)==0&&c==l.key&&u==l.type)return o}return-1}function Fn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||xa.test(e)?n:n+"px"}function se(t,e,n,s,a){var r,o;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||Fn(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||Fn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")r=e!=(e=e.replace($s,"$1")),o=e.toLowerCase(),e=o in t||e=="onFocusOut"||e=="onFocusIn"?o.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+r]=n,n?s?n.u=s.u:(n.u=bn,t.addEventListener(e,r?Qe:Ze,r)):t.removeEventListener(e,r?Qe:Ze,r);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function zn(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=bn++;else if(e.t<n.u)return;return n(C.event?C.event(e):e)}}}function xn(t,e,n,s,a,r,o,c,u,l){var p,d,v,f,$,A,N,x,b,j,B,R,K,at,it,q,Q,S=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(u=!!(32&n.__u),r=[c=e.__e=n.__e]),(p=C.__b)&&p(e);t:if(typeof S=="function")try{if(x=e.props,b="prototype"in S&&S.prototype.render,j=(p=S.contextType)&&s[p.__c],B=p?j?j.props.value:p.__:s,n.__c?N=(d=e.__c=n.__c).__=d.__E:(b?e.__c=d=new S(x,B):(e.__c=d=new Nt(x,B),d.constructor=S,d.render=Ta),j&&j.sub(d),d.state||(d.state={}),d.__n=s,v=d.__d=!0,d.__h=[],d._sb=[]),b&&d.__s==null&&(d.__s=d.state),b&&S.getDerivedStateFromProps!=null&&(d.__s==d.state&&(d.__s=tt({},d.__s)),tt(d.__s,S.getDerivedStateFromProps(x,d.__s))),f=d.props,$=d.state,d.__v=e,v)b&&S.getDerivedStateFromProps==null&&d.componentWillMount!=null&&d.componentWillMount(),b&&d.componentDidMount!=null&&d.__h.push(d.componentDidMount);else{if(b&&S.getDerivedStateFromProps==null&&x!==f&&d.componentWillReceiveProps!=null&&d.componentWillReceiveProps(x,B),e.__v==n.__v||!d.__e&&d.shouldComponentUpdate!=null&&d.shouldComponentUpdate(x,d.__s,B)===!1){for(e.__v!=n.__v&&(d.props=x,d.state=d.__s,d.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(L){L&&(L.__=e)}),R=0;R<d._sb.length;R++)d.__h.push(d._sb[R]);d._sb=[],d.__h.length&&o.push(d);break t}d.componentWillUpdate!=null&&d.componentWillUpdate(x,d.__s,B),b&&d.componentDidUpdate!=null&&d.__h.push(function(){d.componentDidUpdate(f,$,A)})}if(d.context=B,d.props=x,d.__P=t,d.__e=!1,K=C.__r,at=0,b){for(d.state=d.__s,d.__d=!1,K&&K(e),p=d.render(d.props,d.state,d.context),it=0;it<d._sb.length;it++)d.__h.push(d._sb[it]);d._sb=[]}else do d.__d=!1,K&&K(e),p=d.render(d.props,d.state,d.context),d.state=d.__s;while(d.__d&&++at<25);d.state=d.__s,d.getChildContext!=null&&(s=tt(tt({},s),d.getChildContext())),b&&!v&&d.getSnapshotBeforeUpdate!=null&&(A=d.getSnapshotBeforeUpdate(f,$)),q=p,p!=null&&p.type===Yt&&p.key==null&&(q=Ss(p.props.children)),c=ks(t,Re(q)?q:[q],e,n,s,a,r,o,c,u,l),d.base=e.__e,e.__u&=-161,d.__h.length&&o.push(d),N&&(d.__E=d.__=null)}catch(L){if(e.__v=null,u||r!=null)if(L.then){for(e.__u|=u?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;r[r.indexOf(c)]=null,e.__e=c}else{for(Q=r.length;Q--;)kn(r[Q]);tn(e)}else e.__e=n.__e,e.__k=n.__k,L.then||tn(e);C.__e(L,e,n)}else r==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=Ca(n.__e,e,n,s,a,r,o,u,l);return(p=C.diffed)&&p(e),128&e.__u?void 0:c}function tn(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(tn)}function ws(t,e,n){for(var s=0;s<n.length;s++)wn(n[s],n[++s],n[++s]);C.__c&&C.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(r){r.call(a)})}catch(r){C.__e(r,a.__v)}})}function Ss(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Re(t)?t.map(Ss):tt({},t)}function Ca(t,e,n,s,a,r,o,c,u){var l,p,d,v,f,$,A,N=n.props||Jt,x=e.props,b=e.type;if(b=="svg"?a="http://www.w3.org/2000/svg":b=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),r!=null){for(l=0;l<r.length;l++)if((f=r[l])&&"setAttribute"in f==!!b&&(b?f.localName==b:f.nodeType==3)){t=f,r[l]=null;break}}if(t==null){if(b==null)return document.createTextNode(x);t=document.createElementNS(a,b,x.is&&x),c&&(C.__m&&C.__m(e,r),c=!1),r=null}if(b==null)N===x||c&&t.data==x||(t.data=x);else{if(r=r&&Ne.call(t.childNodes),!c&&r!=null)for(N={},l=0;l<t.attributes.length;l++)N[(f=t.attributes[l]).name]=f.value;for(l in N)if(f=N[l],l!="children"){if(l=="dangerouslySetInnerHTML")d=f;else if(!(l in x)){if(l=="value"&&"defaultValue"in x||l=="checked"&&"defaultChecked"in x)continue;se(t,l,null,f,a)}}for(l in x)f=x[l],l=="children"?v=f:l=="dangerouslySetInnerHTML"?p=f:l=="value"?$=f:l=="checked"?A=f:c&&typeof f!="function"||N[l]===f||se(t,l,f,N[l],a);if(p)c||d&&(p.__html==d.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(d&&(t.innerHTML=""),ks(e.type=="template"?t.content:t,Re(v)?v:[v],e,n,s,b=="foreignObject"?"http://www.w3.org/1999/xhtml":a,r,o,r?r[0]:n.__k&&ht(n,0),c,u),r!=null)for(l=r.length;l--;)kn(r[l]);c||(l="value",b=="progress"&&$==null?t.removeAttribute("value"):$!=null&&($!==t[l]||b=="progress"&&!$||b=="option"&&$!=N[l])&&se(t,l,$,N[l],a),l="checked",A!=null&&A!=t[l]&&se(t,l,A,N[l],a))}return t}function wn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){C.__e(a,n)}}function Cs(t,e,n){var s,a;if(C.unmount&&C.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||wn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(r){C.__e(r,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&Cs(s[a],e,n||typeof t.type!="function");n||kn(t.__e),t.__c=t.__=t.__e=void 0}function Ta(t,e,n){return this.constructor(t,n)}function Aa(t,e,n){var s,a,r,o;e==document&&(e=document.documentElement),C.__&&C.__(t,e),a=(s=!1)?null:e.__k,r=[],o=[],xn(e,t=e.__k=ys(Yt,null,[t]),a||Jt,Jt,e.namespaceURI,a?null:e.firstChild?Ne.call(e.childNodes):null,r,a?a.__e:e.firstChild,s,o),ws(r,t,o)}Ne=hs.slice,C={__e:function(t,e,n,s){for(var a,r,o;e=e.__;)if((a=e.__c)&&!a.__)try{if((r=a.constructor)&&r.getDerivedStateFromError!=null&&(a.setState(r.getDerivedStateFromError(t)),o=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),o=a.__d),o)return a.__E=a}catch(c){t=c}throw t}},fs=0,ms=function(t){return t!=null&&t.constructor===void 0},Nt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=tt({},this.state),typeof t=="function"&&(t=t(tt({},n),this.props)),t&&tt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),On(this))},Nt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),On(this))},Nt.prototype.render=Yt,rt=[],_s=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,gs=function(t,e){return t.__v.__b-e.__v.__b},fe.__r=0,$s=/(PointerCapture)$|Capture$/i,bn=0,Ze=zn(!1),Qe=zn(!0);var Ts=function(t,e,n,s){var a;e[0]=0;for(var r=1;r<e.length;r++){var o=e[r++],c=e[r]?(e[0]|=o?1:2,n[e[r++]]):e[++r];o===3?s[0]=c:o===4?s[1]=Object.assign(s[1]||{},c):o===5?(s[1]=s[1]||{})[e[++r]]=c:o===6?s[1][e[++r]]+=c+"":o?(a=t.apply(c,Ts(t,c,n,["",null])),s.push(a),c[0]?e[0]|=2:(e[r-2]=0,e[r]=a)):s.push(c)}return s},Hn=new Map;function Na(t){var e=Hn.get(this);return e||(e=new Map,Hn.set(this,e)),(e=Ts(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,r=1,o="",c="",u=[0],l=function(v){r===1&&(v||(o=o.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?u.push(0,v,o):r===3&&(v||o)?(u.push(3,v,o),r=2):r===2&&o==="..."&&v?u.push(4,v,0):r===2&&o&&!v?u.push(5,0,!0,o):r>=5&&((o||!v&&r===5)&&(u.push(r,0,o,a),r=6),v&&(u.push(r,v,0,a),r=6)),o=""},p=0;p<n.length;p++){p&&(r===1&&l(),l(p));for(var d=0;d<n[p].length;d++)s=n[p][d],r===1?s==="<"?(l(),u=[u],r=3):o+=s:r===4?o==="--"&&s===">"?(r=1,o=""):o=s+o[0]:c?s===c?c="":o+=s:s==='"'||s==="'"?c=s:s===">"?(l(),r=1):r&&(s==="="?(r=5,a=o,o=""):s==="/"&&(r<5||n[p][d+1]===">")?(l(),r===3&&(u=u[0]),r=u,(u=u[0]).push(2,0,r),r=0):s===" "||s==="	"||s===`
`||s==="\r"?(l(),r=2):o+=s),r===3&&o==="!--"&&(r=4,u=u[0])}return l(),u})(t)),e),arguments,[])).length>1?e:e[0]}var i=Na.bind(ys),me,M,Me,Un,Bn=0,As=[],E=C,Kn=E.__b,qn=E.__r,Wn=E.diffed,Jn=E.__c,Vn=E.unmount,Gn=E.__;function Ns(t,e){E.__h&&E.__h(M,t,Bn||e),Bn=0;var n=M.__H||(M.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function _e(t,e){var n=Ns(me++,3);!E.__s&&Ds(n.__H,e)&&(n.__=t,n.u=e,M.__H.__h.push(n))}function Rs(t,e){var n=Ns(me++,7);return Ds(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Ra(){for(var t;t=As.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(pe),t.__H.__h.forEach(en),t.__H.__h=[]}catch(e){t.__H.__h=[],E.__e(e,t.__v)}}E.__b=function(t){M=null,Kn&&Kn(t)},E.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Gn&&Gn(t,e)},E.__r=function(t){qn&&qn(t),me=0;var e=(M=t.__c).__H;e&&(Me===M?(e.__h=[],M.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(pe),e.__h.forEach(en),e.__h=[],me=0)),Me=M},E.diffed=function(t){Wn&&Wn(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(As.push(e)!==1&&Un===E.requestAnimationFrame||((Un=E.requestAnimationFrame)||Da)(Ra)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Me=M=null},E.__c=function(t,e){e.some(function(n){try{n.__h.forEach(pe),n.__h=n.__h.filter(function(s){return!s.__||en(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],E.__e(s,n.__v)}}),Jn&&Jn(t,e)},E.unmount=function(t){Vn&&Vn(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{pe(s)}catch(a){e=a}}),n.__H=void 0,e&&E.__e(e,n.__v))};var Xn=typeof requestAnimationFrame=="function";function Da(t){var e,n=function(){clearTimeout(s),Xn&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);Xn&&(e=requestAnimationFrame(n))}function pe(t){var e=M,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),M=e}function en(t){var e=M;t.__c=t.__(),M=e}function Ds(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}var Ea=Symbol.for("preact-signals");function De(){if(nt>1)nt--;else{for(var t,e=!1;Rt!==void 0;){var n=Rt;for(Rt=void 0,nn++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Ps(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(nn=0,nt--,e)throw t}}function La(t){if(nt>0)return t();nt++;try{return t()}finally{De()}}var k=void 0;function Es(t){var e=k;k=void 0;try{return t()}finally{k=e}}var Rt=void 0,nt=0,nn=0,ge=0;function Ls(t){if(k!==void 0){var e=t.n;if(e===void 0||e.t!==k)return e={i:0,S:t,p:k.s,n:void 0,t:k,e:void 0,x:void 0,r:e},k.s!==void 0&&(k.s.n=e),k.s=e,t.n=e,32&k.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=k.s,e.n=void 0,k.s.n=e,k.s=e),e}}function I(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}I.prototype.brand=Ea;I.prototype.h=function(){return!0};I.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Es(function(){var s;(s=e.W)==null||s.call(e)}))};I.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&Es(function(){var a;(a=e.Z)==null||a.call(e)}))}};I.prototype.subscribe=function(t){var e=this;return Zt(function(){var n=e.value,s=k;k=void 0;try{t(n)}finally{k=s}},{name:"sub"})};I.prototype.valueOf=function(){return this.value};I.prototype.toString=function(){return this.value+""};I.prototype.toJSON=function(){return this.value};I.prototype.peek=function(){var t=k;k=void 0;try{return this.value}finally{k=t}};Object.defineProperty(I.prototype,"value",{get:function(){var t=Ls(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(nn>100)throw new Error("Cycle detected");this.v=t,this.i++,ge++,nt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{De()}}}});function _(t,e){return new I(t,e)}function Ps(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Is(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Ms(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function ut(t,e){I.call(this,void 0),this.x=t,this.s=void 0,this.g=ge-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}ut.prototype=new I;ut.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ge))return!0;if(this.g=ge,this.f|=1,this.i>0&&!Ps(this))return this.f&=-2,!0;var t=k;try{Is(this),k=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return k=t,Ms(this),this.f&=-2,!0};ut.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}I.prototype.S.call(this,t)};ut.prototype.U=function(t){if(this.t!==void 0&&(I.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};ut.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(ut.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Ls(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function yt(t,e){return new ut(t,e)}function js(t){var e=t.u;if(t.u=void 0,typeof e=="function"){nt++;var n=k;k=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,Sn(t),s}finally{k=n,De()}}}function Sn(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,js(t)}function Pa(t){if(k!==this)throw new Error("Out-of-order effect");Ms(this),k=t,this.f&=-2,8&this.f&&Sn(this),De()}function kt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}kt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};kt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,js(this),Is(this),nt++;var t=k;return k=this,Pa.bind(this,t)};kt.prototype.N=function(){2&this.f||(this.f|=2,this.o=Rt,Rt=this)};kt.prototype.d=function(){this.f|=8,1&this.f||Sn(this)};kt.prototype.dispose=function(){this.d()};function Zt(t,e){var n=new kt(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var Os,ae,Ia=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Fs=[];Zt(function(){Os=this.N})();function xt(t,e){C[t]=e.bind(null,C[t]||function(){})}function $e(t){if(ae){var e=ae;ae=void 0,e()}ae=t&&t.S()}function zs(t){var e=this,n=t.data,s=ja(n);s.value=n;var a=Rs(function(){for(var c=e,u=e.__v;u=u.__;)if(u.__c){u.__c.__$f|=4;break}var l=yt(function(){var f=s.value.value;return f===0?0:f===!0?"":f||""}),p=yt(function(){return!Array.isArray(l.value)&&!ms(l.value)}),d=Zt(function(){if(this.N=Hs,p.value){var f=l.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=f)}}),v=e.__$u.d;return e.__$u.d=function(){d(),v.call(this)},[p,l]},[]),r=a[0],o=a[1];return r.value?o.peek():o.value}zs.displayName="ReactiveTextNode";Object.defineProperties(I.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:zs},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});xt("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var r=s[a];r instanceof I&&(n||(e.__np=n={}),n[a]=r,s[a]=r.peek())}}t(e)});xt("__r",function(t,e){if(t(e),e.type!==Yt){$e();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,r){var o;return Zt(function(){o=this},{name:r}),o.c=a,o})(function(){var a;Ia&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),$e(n)}});xt("__e",function(t,e,n,s){$e(),t(e,n,s)});xt("diffed",function(t,e){$e();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var r=n.U;if(r)for(var o in r){var c=r[o];c!==void 0&&!(o in s)&&(c.d(),r[o]=void 0)}else r={},n.U=r;for(var u in s){var l=r[u],p=s[u];l===void 0?(l=Ma(n,u,p),r[u]=l):l.o(p,a)}for(var d in s)a[d]=s[d]}}t(e)});function Ma(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,r=_(n),o=n.peek();return{o:function(c,u){r.value=c,o=c.peek()},d:Zt(function(){this.N=Hs;var c=r.value.value;o!==c?(o=void 0,a?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):o=void 0})}}xt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var r=s[a];r&&r.d()}}}e.__np=void 0}else{var o=e.__c;if(o){var c=o.__$u;c&&(o.__$u=void 0,c.d())}}t(e)});xt("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});Nt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var r=2&this.__$f;if(!(s||r||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var o in t)if(o!=="__source"&&t[o]!==this.props[o])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function ja(t,e){return Rs(function(){return _(t,e)},[])}var Oa=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Fa(){La(function(){for(var t;t=Fs.shift();)Os.call(t)})}function Hs(){Fs.push(this)===1&&(C.requestAnimationFrame||Oa)(Fa)}const za=["overview","board","activity","agents","tasks","journal","trpg","council"],Us={tab:"overview",params:{},postId:null};function Yn(t){return!!t&&za.includes(t)}function sn(t){try{return decodeURIComponent(t)}catch{return t}}function an(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Ha(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Bs(t,e){const n=t[0],s=e.tab,a=Yn(n)?n:Yn(s)?s:"overview";let r=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?r=sn(t[2]):t[0]==="post"&&t[1]&&(r=sn(t[1]))),{tab:a,params:e,postId:r}}function he(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Us;const n=sn(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const r=an(a),o=Ha(s);return Bs(o,r)}function Ua(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Us,params:an(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=an(e.replace(/^\?/,""));return Bs(s,a)}function Ks(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const Z=_(he(window.location.hash));window.addEventListener("hashchange",()=>{Z.value=he(window.location.hash)});function Ee(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Ks(n)}function Ba(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Ka(){if(window.location.hash&&window.location.hash!=="#"){Z.value=he(window.location.hash);return}const t=Ua(window.location.pathname,window.location.search);if(t){Z.value=t;const e=Ks(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Z.value=he(window.location.hash)}const qa=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function Wa(){const t=Z.value.tab;return i`
    <div class="main-tab-bar">
      ${qa.map(e=>i`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Ee(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Zn="masc_dashboard_sse_session_id",Ja=1e3,Va=15e3,bt=_(!1),Cn=_(0),qs=_(null),ye=_([]);function Ga(){let t=sessionStorage.getItem(Zn);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Zn,t)),t}const Xa=200;function W(t,e){const n={agent:t,text:e,timestamp:Date.now()};ye.value=[n,...ye.value].slice(0,Xa)}let X=null,_t=null,rn=0;function Ws(){_t&&(clearTimeout(_t),_t=null)}function Ya(){if(_t)return;rn++;const t=Math.min(rn,5),e=Math.min(Va,Ja*Math.pow(2,t));_t=setTimeout(()=>{_t=null,Js()},e)}function Js(){Ws(),X&&(X.close(),X=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Ga());const a=e.toString()?`/sse?${e.toString()}`:"/sse",r=new EventSource(a);X=r,r.onopen=()=>{X===r&&(rn=0,bt.value=!0)},r.onerror=()=>{X===r&&(bt.value=!1,r.close(),X=null,Ya())},r.onmessage=o=>{try{const c=JSON.parse(o.data);Cn.value++,qs.value=c,Za(c)}catch{}}}function Za(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":W(n,"Joined");break;case"agent_left":W(n,"Left");break;case"broadcast":W(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":W(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":W(n,"New post");break;case"board_comment":W(n,"New comment");break;case"keeper_heartbeat":W(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":W(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":W(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":W(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:W(n,e)}}function Qa(){Ws(),X&&(X.close(),X=null),bt.value=!1}function Vs(){return new URLSearchParams(window.location.search)}function Gs(){const t=Vs(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Xs(){return{...Gs(),"Content-Type":"application/json"}}const ti=15e3,Ys=3e4,ei=6e4;async function Tn(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(r){if(r instanceof Error&&r.name==="AbortError"){const o=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${o} ${t}: timeout after ${n}ms`)}throw r}finally{clearTimeout(a)}}function ni(){var e,n;const t=Vs();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Qt(t){const e=await Tn(t,{headers:Gs()},ti);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function te(t,e){const n=await Tn(t,{method:"POST",headers:Xs(),body:JSON.stringify(e)},Ys);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function si(t,e,n,s=Ys){const a=await Tn(t,{method:"POST",headers:{...Xs(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function ai(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function ii(t){var e,n,s,a,r,o,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(u)}return((c=(o=(r=t.result)==null?void 0:r.content)==null?void 0:o[0])==null?void 0:c.text)??""}async function F(t,e){const n=await si("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},ei),s=ai(n);return ii(s)}function Zs(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function ri(t="compact"){return Qt(`/api/v1/dashboard?mode=${t}`)}function oi(t){const n=new URLSearchParams().toString();return Qt(`/api/v1/board${n?`?${n}`:""}`)}function li(t){return Qt(`/api/v1/board/${t}`)}function Qs(t,e){return te("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:ni()})}function ci(t,e,n){return te("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function ui(t){const e=m(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function et(...t){for(const e of t){const n=m(e,"");if(n.trim())return n.trim()}return""}function Qn(t){const e=ui(et(t.outcome,t.result,t.result_code));if(!e)return;const n=et(t.reason,t.reason_code,t.description,t.detail),s=et(t.summary,t.summary_ko,t.summary_en,t.note),a=et(t.details,t.details_text,t.text,t.note),r=et(t.winner,t.winner_name,t.actor_winner,t.winner_actor),o=et(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=et(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const d=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof d=="string"?[d]:Array.isArray(d)?d.map(v=>{if(typeof v=="string")return v.trim();if(D(v)){const f=m(v.summary,"").trim();if(f)return f;const $=m(v.text,"").trim();if($)return $;const A=m(v.type,"").trim();return A||m(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),l=(()=>{const d=P(t.turn,Number.NaN);if(Number.isFinite(d))return d;const v=P(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const f=P(t.current_turn,Number.NaN);if(Number.isFinite(f))return f;const $=P(t.round,Number.NaN);return Number.isFinite($)?$:void 0})(),p=et(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:r||void 0,winner_actor_id:o||void 0,evidence:u.length>0?u:void 0,raw_reason:c||void 0,turn:l,phase:p||void 0}}function di(t,e){const n=D(t.state)?t.state:{};if(m(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(o=>D(o)?m(o.type,"")==="session.outcome":!1),r=D(n.session_outcome)?n.session_outcome:{};if(D(r)&&Object.keys(r).length>0){const o=Qn(r);if(o)return o}if(D(a))return Qn(D(a.payload)?a.payload:{})}function D(t){return typeof t=="object"&&t!==null}function m(t,e=""){return typeof t=="string"?t:e}function P(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function on(t,e=!1){return typeof t=="boolean"?t:e}function je(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(D(e)){const n=m(e.name,"").trim(),s=m(e.id,"").trim(),a=m(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function pi(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function z(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const r=t[n];if(typeof r=="number"&&Number.isFinite(r))return r}return s}function vi(t,e){if(t!=="dice.rolled")return;const n=P(e.raw_d20,0),s=P(e.total,0),a=P(e.bonus,0),r=m(e.action,"roll"),o=P(e.dc,0);return{notation:o>0?`${r} (DC ${o})`:r,rolls:n>0?[n]:[],total:s,modifier:a}}function fi(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function mi(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function _i(t,e,n,s){const a=n||e||m(s.actor_id,"")||m(s.actor_name,"");switch(t){case"turn.action.proposed":{const r=m(s.proposed_action,m(s.reply,""));return r?`${a||"actor"}: ${r}`:"Action proposed"}case"turn.action.resolved":{const r=m(s.reply,m(s.result,""));return r?`Resolved: ${r}`:"Action resolved"}case"narration.posted":return m(s.reply,m(s.content,m(s.text,"Narration")));case"dice.rolled":{const r=m(s.action,"roll"),o=P(s.total,0),c=P(s.dc,0),u=m(s.label,""),l=a||"actor",p=c>0?` vs DC ${c}`:"",d=u?` (${u})`:"";return`${l} ${r}: ${o}${p}${d}`}case"turn.started":return`Turn ${P(s.turn,1)} started`;case"phase.changed":return`Phase: ${m(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${m(s.name,a||"unknown")}`;case"actor.claimed":return`${m(s.keeper_name,m(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${m(s.keeper_name,m(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${P(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${P(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||m(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||m(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${m(s.reason_code,"unknown")}`;case"memory.signal":{const r=D(s.entity_refs)?s.entity_refs:{},o=m(r.requested_tier,""),c=m(r.effective_tier,""),u=on(r.guardrail_applied,!1),l=m(s.summary_en,m(s.summary_ko,"Memory signal"));if(!o&&!c)return l;const p=o&&c?`${o}->${c}`:c||o;return`${l} [${p}${u?" (guardrail)":""}]`}case"world.event":{if(m(s.event_type,"")==="canon.check"){const o=m(s.status,"unknown"),c=m(s.contract_id,"n/a");return`Canon ${o}: ${c}`}return m(s.description,m(s.summary,"World event"))}case"combat.attack":return m(s.summary,m(s.result,"Attack resolved"));case"combat.defense":return m(s.summary,m(s.result,"Defense resolved"));case"session.outcome":return m(s.summary,m(s.outcome,"Session ended"));default:{const r=fi(s);return r?`${t}: ${r}`:t}}}function gi(t,e){const n=D(t)?t:{},s=m(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",r=m(n.actor_name,"").trim()||e[a]||m(D(n.payload)?n.payload.actor_name:"",""),o=D(n.payload)?n.payload:{},c=m(n.ts,m(n.timestamp,new Date().toISOString())),u=m(n.phase,m(o.phase,"")),l=m(n.category,"");return{type:s,actor:r||a||m(o.actor_name,""),actor_id:a||m(o.actor_id,""),actor_name:r,seq:n.seq,room_id:m(n.room_id,""),phase:u||void 0,category:l||mi(s),visibility:m(n.visibility,m(o.visibility,"public")),event_id:m(n.event_id,""),content:_i(s,a,r,o),dice_roll:vi(s,o),timestamp:c}}function $i(t,e,n){var q,Q;const s=m(t.room_id,"")||n||"default",a=D(t.state)?t.state:{},r=D(a.party)?a.party:{},o=D(a.actor_control)?a.actor_control:{},c=D(a.join_gate)?a.join_gate:{},u=D(a.contribution_ledger)?a.contribution_ledger:{},l=Object.entries(r).map(([S,L])=>{const T=D(L)?L:{},ne=z(T,"max_hp",void 0,10),Pn=z(T,"hp",void 0,ne),ga=z(T,"max_mp",void 0,0),$a=z(T,"mp",void 0,0),ha=z(T,"level",void 0,1),ya=z(T,"xp",void 0,0),ba=on(T.alive,Pn>0),In=o[S],Mn=typeof In=="string"?In:void 0,ka=pi(T.role,S,Mn);return{id:S,name:m(T.name,S),role:ka,keeper:Mn,archetype:m(T.archetype,""),persona:m(T.persona,""),traits:je(T.traits),skills:je(T.skills),status:ba?"active":"dead",stats:{hp:Pn,max_hp:ne,mp:$a,max_mp:ga,level:ha,xp:ya,strength:z(T,"strength","str",10),dexterity:z(T,"dexterity","dex",10),constitution:z(T,"constitution","con",10),intelligence:z(T,"intelligence","int",10),wisdom:z(T,"wisdom","wis",10),charisma:z(T,"charisma","cha",10)}}}),p=l.filter(S=>S.status!=="dead"),d=di(t,e),v={phase_open:on(c.phase_open,!0),min_points:P(c.min_points,3),window:m(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},f=Object.entries(u).map(([S,L])=>{const T=D(L)?L:{};return{actor_id:S,score:P(T.score,0),last_reason:m(T.last_reason,"")||null,reasons:je(T.reasons)}}),$=l.reduce((S,L)=>(S[L.id]=L.name,S),{}),A=e.map(S=>gi(S,$)),N=P(a.turn,1),x=m(a.phase,"round"),b=m(a.map,""),j=D(a.world)?a.world:{},B=b||m(j.ascii_map,m(j.map,"")),R=A.filter((S,L)=>{const T=e[L];if(!D(T))return!1;const ne=D(T.payload)?T.payload:{};return P(ne.turn,-1)===N}),K=(R.length>0?R:A).slice(-12),at=m(a.status,"active");return{session:{id:s,room:s,status:at==="ended"?"ended":at==="paused"?"paused":"active",round:N,actors:p,created_at:((q=A[0])==null?void 0:q.timestamp)??new Date().toISOString()},current_round:{round_number:N,phase:x,events:K,timestamp:((Q=A[A.length-1])==null?void 0:Q.timestamp)??new Date().toISOString()},map:B||void 0,join_gate:v,contribution_ledger:f,outcome:d,party:p,story_log:A,history:[]}}async function hi(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Qt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function yi(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([Qt(`/api/v1/trpg/state${e}`),hi(t)]);return $i(n,s,t)}function bi(t){return te("/api/v1/trpg/rounds/run",{room_id:t})}function ki(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function xi(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),te("/api/v1/trpg/dice/roll",e)}function wi(t,e){const n=ki();return te("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function Si(t,e,n){const s=await F("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Ci(t){const e=await F("trpg.mid_join.request",t);return JSON.parse(e)}async function ta(t,e){await F("masc_broadcast",{agent_name:t,message:e})}async function Ti(t,e,n=1){await F("masc_add_task",{title:t,description:e,priority:n})}async function Ai(t){return F("masc_join",{agent_name:t})}async function ea(t){await F("masc_leave",{agent_name:t})}async function Ni(t){await F("masc_heartbeat",{agent_name:t})}async function Ri(t=40){return(await F("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Di(t,e=20){return F("masc_task_history",{task_id:t,limit:e})}async function Ei(){const t=await F("masc_debates",{});return Zs(t)}async function Li(){const t=await F("masc_sessions",{});return Zs(t)}async function Pi(t){const e=await F("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function Ii(t){return F("masc_debate_status",{debate_id:t})}const wt=_([]),ee=_([]),na=_([]),St=_([]),An=_(null),Tt=_(null),ln=_(new Map),sa=_([]),ts=_("hot"),Nn=_(null),gt=_(""),cn=_(!1),un=_(!1),dn=_(!1),Mi=yt(()=>wt.value.filter(t=>t.status==="active"||t.status==="idle")),aa=yt(()=>{const t=ee.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function ji(t){var a;const e=t.metrics_series;if(!e||e.length===0){const r=((a=t.status)==null?void 0:a.toLowerCase())??"";return r==="offline"||r==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Oi=yt(()=>{const t=new Map;for(const e of St.value)t.set(e.name,ji(e));return t}),Fi=12e4,zi=yt(()=>{const t=Date.now(),e=new Set,n=ln.value;for(const s of St.value){const a=n.get(s.name);a!=null&&t-a>Fi&&e.add(s.name)}return e}),be={},Hi=5e3;function pn(){delete be.compact,delete be.full}function J(t){return typeof t=="object"&&t!==null}function g(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function y(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Dt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function ia(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Ui(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Bi(t){if(!J(t))return null;const e=g(t.name);return e?{name:e,status:ia(t.status),current_task:g(t.current_task)??null,last_seen:g(t.last_seen),emoji:g(t.emoji),koreanName:g(t.koreanName)??g(t.korean_name),model:g(t.model),traits:Dt(t.traits),interests:Dt(t.interests),activityLevel:y(t.activityLevel)??y(t.activity_level),primaryValue:g(t.primaryValue)??g(t.primary_value)}:null}function Ki(t){if(!J(t))return null;const e=g(t.id),n=g(t.title);return!e||!n?null:{id:e,title:n,status:Ui(t.status),priority:y(t.priority),assignee:g(t.assignee),description:g(t.description),created_at:g(t.created_at),updated_at:g(t.updated_at)}}function qi(t){if(!J(t))return null;const e=g(t.from)??g(t.from_agent)??"system",n=g(t.content)??"",s=g(t.timestamp)??new Date().toISOString();return{id:g(t.id),seq:y(t.seq),from:e,content:n,timestamp:s,type:g(t.type)}}function Wi(t){return Array.isArray(t)?t.map(e=>{if(!J(e))return null;const n=y(e.ts_unix);if(n==null)return null;const s=J(e.handoff)?e.handoff:null;return{ts:n,context_ratio:y(e.context_ratio)??0,context_tokens:y(e.context_tokens)??0,context_max:y(e.context_max)??0,latency_ms:y(e.latency_ms)??0,generation:y(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:y(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:y(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?y(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ji(t){return(Array.isArray(t)?t:J(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!J(n))return null;const s=J(n.agent)?n.agent:null,a=J(n.context)?n.context:null,r=J(n.metrics_window)?n.metrics_window:void 0,o=g(n.name);if(!o)return null;const c=y(n.context_ratio)??y(a==null?void 0:a.context_ratio),u=g(n.status)??g(s==null?void 0:s.status)??"offline",l=ia(u),p=g(n.model)??g(n.active_model)??g(n.primary_model),d=Dt(n.skill_secondary),v=a?{source:g(a.source),context_ratio:y(a.context_ratio),context_tokens:y(a.context_tokens),context_max:y(a.context_max),message_count:y(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,f=s?{name:g(s.name),status:g(s.status),current_task:g(s.current_task)??null,last_seen:g(s.last_seen)}:void 0,$=Wi(n.metrics_series);return{name:o,emoji:g(n.emoji),koreanName:g(n.koreanName)??g(n.korean_name),agent_name:g(n.agent_name),trace_id:g(n.trace_id),model:p,primary_model:g(n.primary_model),active_model:g(n.active_model),next_model_hint:g(n.next_model_hint)??null,status:l,last_heartbeat:g(n.last_heartbeat)??g(s==null?void 0:s.last_seen),generation:y(n.generation),turn_count:y(n.turn_count)??y(n.total_turns),context_ratio:c,context_tokens:y(n.context_tokens)??y(a==null?void 0:a.context_tokens),context_max:y(n.context_max)??y(a==null?void 0:a.context_max),context_source:g(n.context_source)??g(a==null?void 0:a.source),context:v,traits:Dt(n.traits),interests:Dt(n.interests),primaryValue:g(n.primaryValue)??g(n.primary_value),activityLevel:y(n.activityLevel)??y(n.activity_level),memory_recent_note:g(n.memory_recent_note)??null,conversation_tail_count:y(n.conversation_tail_count),k2k_count:y(n.k2k_count),handoff_count_total:y(n.handoff_count_total)??y(n.trace_history_count),compaction_count:y(n.compaction_count),last_compaction_saved_tokens:y(n.last_compaction_saved_tokens),skill_primary:g(n.skill_primary)??null,skill_secondary:d,skill_reason:g(n.skill_reason)??null,metrics_series:$.length>0?$:void 0,metrics_window:r,agent:f}}).filter(n=>n!==null)}async function Le(t="full"){var s,a,r;const e=Date.now(),n=be[t];if(!(n&&e-n.time<Hi)){cn.value=!0;try{const o=await ri(t);be[t]={data:o,time:e},wt.value=(Array.isArray((s=o.agents)==null?void 0:s.agents)?o.agents.agents:[]).map(Bi).filter(c=>c!==null),ee.value=(Array.isArray((a=o.tasks)==null?void 0:a.tasks)?o.tasks.tasks:[]).map(Ki).filter(c=>c!==null),na.value=(Array.isArray((r=o.messages)==null?void 0:r.messages)?o.messages.messages:[]).map(qi).filter(c=>c!==null),St.value=Ji(o.keepers),An.value=J(o.status)?o.status:null,Tt.value=o.perpetual??null}catch(o){console.error("Dashboard fetch error:",o)}finally{cn.value=!1}}}async function dt(){un.value=!0;try{const t=await oi();sa.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{un.value=!1}}async function lt(){var t;dn.value=!0;try{const e=gt.value||((t=An.value)==null?void 0:t.room)||"default";gt.value||(gt.value=e);const n=await yi(e);Nn.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{dn.value=!1}}let Oe=null,Fe=null;function Vi(){return qs.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(ln.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),ln.value=n}pn(),Oe||(Oe=setTimeout(()=>{Le(),Oe=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Fe||(Fe=setTimeout(()=>{dt(),Fe=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&pn()}})}let Et=null;function Gi(){Et||(Et=setInterval(()=>{pn(),Le()},1e4))}function Xi(){Et&&(clearInterval(Et),Et=null)}function w({title:t,class:e,children:n}){return i`
    <div class="card ${e??""}">
      ${t?i`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function st({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Yi(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const r=Math.floor(a/60);return r<24?`${r}h ago`:`${Math.floor(r/24)}d ago`}function U({timestamp:t}){const e=Yi(t);return i`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const Rn=_(null);function ra(t){Rn.value=t}function es(){Rn.value=null}function ve(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Zi({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(r=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${r.label}</div>
          <div class="keeper-kpi-value">${r.value}</div>
          ${r.hint?i`<div class="keeper-kpi-hint">${r.hint}</div>`:null}
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
  `}function Qi({keeper:t}){var p,d;const e=t.metrics_series??[];if(e.length<2){const v=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,f=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${f}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,r=e.length,o=e.map((v,f)=>{const $=a+f/(r-1)*(n-2*a),A=s-a-(v.context_ratio??0)*(s-2*a);return{x:$,y:A,p:v}}),c=o.map(({x:v,y:f})=>`${v.toFixed(1)},${f.toFixed(1)}`).join(" "),u=(((d=e[e.length-1])==null?void 0:d.context_ratio)??0)*100,l=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${o.filter(({p:v})=>v.is_handoff).map(({x:v})=>i`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${l}" stroke-width="1.5"/>
        ${o.filter(({p:v})=>v.is_compaction).map(({x:v,y:f})=>i`
          <circle cx="${v.toFixed(1)}" cy="${f.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const ze=_("");function tr({keeper:t}){var a,r,o,c;const e=ze.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((r=t.interests)==null?void 0:r.join(", "))||"-"}],s=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ze.value}
        onInput=${u=>{ze.value=u.target.value}}
      />
      ${s.map(u=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ve(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ve(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ve(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((o=t.context)==null?void 0:o.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function er({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function nr({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function sr({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function ns({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function He(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function ar({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:He(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:He(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:He(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function ir(){var e,n,s;const t=Rn.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&es()}}
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
            <${st} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>es()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Zi} keeper=${t} />

        ${""}
        <${Qi} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${tr} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${ns} traits=${t.traits??[]} label="Traits" />
            <${ns} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${U} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?i`
              <${w} title="TRPG Stats">
                <${er} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${w} title="Equipment (${t.inventory.length})">
                <${nr} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${sr} rels=${t.relationships} />
              <//>
            `:null}

          <${w} title="Runtime Signals">
            <${ar} keeper=${t} />
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
  `:null}let rr=0;const ot=_([]);function h(t,e="success",n=4e3){const s=++rr;ot.value=[...ot.value,{id:s,message:t,type:e}],setTimeout(()=>{ot.value=ot.value.filter(a=>a.id!==s)},n)}function or(t){ot.value=ot.value.filter(e=>e.id!==t)}function lr(){const t=ot.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>or(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const cr="masc_dashboard_agent_name",Ct=_(null),ke=_(!1),Vt=_(""),xe=_([]),Gt=_([]),$t=_(""),Lt=_(!1);function oa(t){Ct.value=t,Dn()}function ss(){Ct.value=null,Vt.value="",xe.value=[],Gt.value=[],$t.value=""}function ur(){const t=Ct.value;return t?wt.value.find(e=>e.name===t)??null:null}function la(t){return t?ee.value.filter(e=>e.assignee===t):[]}async function Dn(){const t=Ct.value;if(t){ke.value=!0,Vt.value="",xe.value=[],Gt.value=[];try{const e=await Ri(80);xe.value=e.filter(a=>a.includes(t)).slice(0,20);const n=la(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const r=await Di(a.id,25);return{taskId:a.id,text:r.trim()}}catch(r){const o=r instanceof Error?r.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${o}`}}}));Gt.value=s}catch(e){Vt.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{ke.value=!1}}}async function as(){var s;const t=Ct.value,e=$t.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(cr))==null?void 0:s.trim())||"dashboard";Lt.value=!0;try{await ta(n,`@${t} ${e}`),$t.value="",h(`Mention sent to ${t}`,"success"),Dn()}catch(a){const r=a instanceof Error?a.message:"Failed to send mention";h(r,"error")}finally{Lt.value=!1}}function dr({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${st} status=${t.status} />
    </div>
  `}function pr({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function vr(){var a,r,o,c;const t=Ct.value;if(!t)return null;const e=ur(),n=la(t),s=xe.value;return i`
    <div
      class="agent-detail-overlay"
      onClick=${u=>{u.target.classList.contains("agent-detail-overlay")&&ss()}}
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
                        <${st} status=${e.status} />
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
                ${(r=e==null?void 0:e.traits)==null?void 0:r.map(u=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            ${(((o=e==null?void 0:e.interests)==null?void 0:o.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(u=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${U} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Dn()}} disabled=${ke.value}>
              ${ke.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${ss}>Close</button>
          </div>
        </div>

        ${Vt.value?i`<div class="council-error">${Vt.value}</div>`:null}

        <div class="agent-detail-grid">
          <${w} title="Assigned Tasks">
            ${n.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${n.map(u=>i`<${dr} key=${u.id} task=${u} />`)}</div>`}
          <//>

          <${w} title="Recent Activity">
            ${s.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${s.map((u,l)=>i`<div key=${l} class="agent-activity-line">${u}</div>`)}</div>`}
          <//>
        </div>

        <${w} title="Task History">
          ${Gt.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Gt.value.map(u=>i`<${pr} key=${u.taskId} row=${u} />`)}</div>`}
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${$t.value}
              onInput=${u=>{$t.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&as()}}
              disabled=${Lt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{as()}}
              disabled=${Lt.value||$t.value.trim()===""}
            >
              ${Lt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function pt({label:t,value:e,color:n}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function fr({agent:t}){return i`
    <div class="agent" onClick=${()=>oa(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${st} status=${t.status} />
      ${t.current_task?i`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function mr(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function _r(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function is(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function gr({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=Oi.value.get(t.name),a=zi.value.has(t.name);return i`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>ra(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${st} status=${t.status} />
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
              <div class="keeper-ctx-fill ${is(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${is(e)}">
              ${n}%
              ${t.context_tokens!=null?i` (${mr(t.context_tokens)})`:null}
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
            <${U} timestamp=${t.last_heartbeat} />
          </div>
        `:null}

        <!-- Row 5: Trait chips -->
        ${t.traits&&t.traits.length>0?i`
          <div class="keeper-trait-row">
            ${t.traits.slice(0,3).map(r=>i`<span class="keeper-trait-chip">${r}</span>`)}
            ${t.traits.length>3?i`<span class="keeper-trait-more">+${t.traits.length-3}</span>`:null}
          </div>
        `:null}

        <!-- Row 6: Memory note preview -->
        ${t.memory_recent_note?i`
          <div class="keeper-note-preview">${_r(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function rs(){const t=An.value,e=wt.value,n=St.value,s=aa.value;return i`
    <div class="stats-grid">
      <${pt} label="Agents" value=${e.length} />
      <${pt} label="Active" value=${Mi.value.length} color="#4ade80" />
      <${pt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${pt} label="Tasks" value=${ee.value.length} />
      <${pt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${pt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${w} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?i`<div class="empty-state">No agents connected</div>`:e.map(a=>i`<${fr} key=${a.name} agent=${a} />`)}
        </div>
      <//>

      <${w} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?i`<div class="empty-state">No keepers active</div>`:n.map(a=>i`<${gr} key=${a.name} keeper=${a} />`)}
        </div>
      <//>
    </div>

    ${Tt.value?i`
        <${w} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${Tt.value.running?"Running":"Stopped"}</span>
            ${Tt.value.goal?i`<span>Goal: ${Tt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?i`
        <${w} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?i`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?i`<span>Project: ${t.project}</span>`:null}
            ${t.version?i`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${$r(t.uptime_seconds??0)}</span>
            ${t.paused?i`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?i`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?i`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
          </div>
        <//>
      `:null}
  `}function $r(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const vn=_([]),fn=_([]),Pt=_(""),we=_(!1),It=_(!1),Se=_(""),Ce=_(null),Mt=_(""),mn=_(!1);async function _n(){we.value=!0,Se.value="";try{const[t,e]=await Promise.all([Ei(),Li()]);vn.value=t,fn.value=e}catch(t){Se.value=t instanceof Error?t.message:"Failed to load council data"}finally{we.value=!1}}async function os(){const t=Pt.value.trim();if(t){It.value=!0;try{const e=await Pi(t);Pt.value="",h(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await _n()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";h(n,"error")}finally{It.value=!1}}}async function hr(t){Ce.value=t,mn.value=!0,Mt.value="";try{Mt.value=await Ii(t)}catch(e){Mt.value=e instanceof Error?e.message:"Failed to load debate status"}finally{mn.value=!1}}function yr({debate:t}){const e=Ce.value===t.id;return i`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>hr(t.id)}
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
  `}function br({session:t}){return i`
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
  `}function kr(){return _e(()=>{_n()},[]),i`
    <div>
      <${w} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Pt.value}
            onInput=${t=>{Pt.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&os()}}
            disabled=${It.value}
          />
          <button
            class="control-btn secondary"
            onClick=${os}
            disabled=${It.value||Pt.value.trim()===""}
          >
            ${It.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${_n} disabled=${we.value}>
            ${we.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Se.value?i`<div class="council-error">${Se.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${w} title="Debates" class="section">
          <div class="council-list">
            ${vn.value.length===0?i`<div class="empty-state">No debates yet</div>`:vn.value.map(t=>i`<${yr} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${w} title="Voting Sessions" class="section">
          <div class="council-list">
            ${fn.value.length===0?i`<div class="empty-state">No active sessions</div>`:fn.value.map(t=>i`<${br} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${w} title=${Ce.value?`Debate Detail (${Ce.value})`:"Debate Detail"} class="section">
        ${mn.value?i`<div class="loading-indicator">Loading debate detail...</div>`:Mt.value?i`<pre class="council-detail">${Mt.value}</pre>`:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function xr({text:t}){if(!t)return null;const e=wr(t);return i`<div class="markdown-content">${e}</div>`}function wr(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const o=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(o.length).trim(),u=[];for(s++;s<e.length&&!e[s].startsWith(o);)u.push(e[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${u.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const o=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&o.push(c),s++;s<e.length&&!e[s].includes("</think>");)o.push(e[s]),s++;if(s<e.length){const l=e[s].replace("</think>","").trim();l&&o.push(l),s++}const u=o.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ue(u)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const o=[];for(;s<e.length&&e[s].startsWith("> ");)o.push(e[s].slice(2)),s++;n.push(i`<blockquote>${Ue(o.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const r=[];for(;s<e.length;){const o=e[s];if(o.trim()===""||/^(`{3,}|~{3,})/.test(o)||o.startsWith("> ")||o.trim().startsWith("<think>"))break;r.push(o),s++}r.length>0&&n.push(i`<p>${Ue(r.join(`
`))}</p>`)}return n}function Ue(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const r=a[1].slice(1,-1);e.push(i`<code>${r}</code>`)}else if(a[2]){const r=a[2].slice(2,-2);e.push(i`<strong>${r}</strong>`)}else if(a[3]){const r=a[3].slice(1,-1);e.push(i`<em>${r}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Sr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],jt=_([]),Ot=_(!1),Ft=_(""),Cr=_("dashboard-user"),zt=_(!1);async function ca(t){Ot.value=!0,jt.value=[];try{const e=await li(t);jt.value=e.comments??[]}catch{}finally{Ot.value=!1}}async function ls(t){const e=Ft.value.trim();if(e){zt.value=!0;try{await ci(t,Cr.value,e),Ft.value="",h("Comment posted","success"),await ca(t),dt()}catch{h("Failed to post comment","error")}finally{zt.value=!1}}}function Tr(){const t=ts.value;return i`
    <div class="board-controls">
      ${Sr.map(e=>i`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{ts.value=e.id,dt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function ua({flair:t}){return t?i`<span class="post-flair ${t}">${t}</span>`:null}function Ar({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Qs(t.id,n),dt()}catch{h("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>Ba(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${ua} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${U} timestamp=${t.created_at} />
          ${t.comment_count>0?i`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Nr({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${U} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Rr({postId:t}){return i`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Ft.value}
        onInput=${e=>{Ft.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ls(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${zt.value}
      />
      <button
        onClick=${()=>ls(t)}
        disabled=${zt.value||Ft.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${zt.value?"...":"Post"}
      </button>
    </div>
  `}function Dr({post:t}){jt.value.length===0&&!Ot.value&&ca(t.id);const e=async n=>{try{await Qs(t.id,n),dt()}catch{h("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>Ee("board")}>← Back to Board</button>
      <${w} title=${i`${t.title} <${ua} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${xr} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${U} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${w} title="Comments (${Ot.value?"...":jt.value.length})">
        ${Ot.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${Nr} comments=${jt.value} />`}
        <${Rr} postId=${t.id} />
      <//>
    </div>
  `}function Er(){const t=sa.value,e=un.value,n=Z.value.postId;if(n){const s=t.find(a=>a.id===n);return s?i`<${Dr} post=${s} />`:i`
          <div>
            <button class="back-btn" onClick=${()=>Ee("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return i`
    <${Tr} />
    ${e?i`<div class="loading-indicator">Loading board...</div>`:t.length===0?i`<div class="empty-state">No posts yet</div>`:i`<div class="board-post-list">
            ${t.map(s=>i`<${Ar} key=${s.id} post=${s} />`)}
          </div>`}
  `}function Lr(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Pr(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function cs(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function Ir({row:t}){const e=new Date(t.timestamp),n=isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1});return i`
    <div class="term-row">
      <span class="term-time">${n}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-source ${t.source}">${t.source==="message"?"msg":"evt"}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Mr(){const t=na.value.map(Lr),e=ye.value.map(Pr),n=[...t,...e].sort((s,a)=>cs(a.timestamp)-cs(s.timestamp)).slice(0,100);return i`
    <div class="section">
      <h2 style="color: var(--accent); text-shadow: 0 0 10px rgba(0,240,255,0.5); margin-bottom: 16px; font-family: monospace;">> LIVE_ACTIVITY_STREAM</h2>
      <div class="terminal-feed">
        ${n.length===0?i`<div class="empty-state" style="font-family: monospace; color: var(--ok);">> Waiting for signal...</div>`:n.map(s=>i`<${Ir} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function da({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,r=2*Math.PI*s,o=r*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),i`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${r}" 
          stroke-dashoffset="${o}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}const jr={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function Or(t){return jr[t]}function vt({metric:t}){const e=Or(t);return i`
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
        ${e.formula?i`<span><code>formula:</code> ${e.formula}</span>`:null}
        <span><code>source:</code> ${e.sourcePath}</span>
        ${e.interpretation?i`<span>${e.interpretation}</span>`:null}
      </span>
    </span>
  `}function Fr({agent:t}){return i`
    <button class="agent-card ${t.status}" onClick=${()=>oa(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?i`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${da} ratio=${t.context_ratio} />
        <${st} status=${t.status} />
      </div>
      ${t.current_task?i`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?i`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function zr(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function Hr(t){var a,r,o;const e=(a=t.last_drift_reason)==null?void 0:a.trim();if(e)return e;const n=(r=t.last_proactive_reason)==null?void 0:r.trim();if(n)return n;const s=(o=t.memory_recent_note)==null?void 0:o.trim();return s||"—"}function Ur(t){var s;const e=t.k2k_count??0,n=(s=t.k2k_mentions)==null?void 0:s[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function Br(t){var s;const e=t.drift_count_total??0,n=zr((s=t.metrics_window)==null?void 0:s.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function Kr({keeper:t}){const e=Hr(t),n=Ur(t),s=Br(t);return i`
    <div class="live-agent keeper-card" onClick=${()=>ra(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${da} ratio=${t.context_ratio} />
        <${st} status=${t.status} />
          ${t.model?i`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?i`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${vt} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?i`<${U} timestamp=${t.created_at} />`:"—"}
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
      </div>
    </div>
  `}function qr(){const t=wt.value,e=St.value;return i`
    <div>
      ${e.length>0?i`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>i`<${Kr} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?i`<div class="empty-state">No agents registered</div>`:i`
            <div class="agent-grid">
              ${t.map(n=>i`<${Fr} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Be({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return i`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?i`<${U} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Wr(){const{todo:t,inProgress:e,done:n}=aa.value;return i`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>i`<${Be} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>i`<${Be} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>i`<${Be} key=${s.id} task=${s} />`)}
        ${n.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function Jr({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return i`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function Vr(){const t=ye.value;return i`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?i`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>i`<${Jr} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const ft=_(""),Pe=_(""),ie=_(""),Ke=_("all"),re=_(!1),qe=_("ability_check"),We=_("10"),Je=_("12"),oe=_(""),le=_("idle"),ce=_(""),ue=_("keeper-late"),Ve=_("player"),Ge=_(""),H=_("idle"),Xe=_(null),gn=_(null);function Gr(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Xr(t,e){return e>0?Math.round(t/e*100):0}const Yr={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Zr={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Ht(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function pa(t){const e=t.trim().toLowerCase();return Yr[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function va(t){const e=t.trim().toLowerCase();return Zr[e]??"상황에 따라 선택되는 전술 액션입니다."}function ct(t){return typeof t=="object"&&t!==null}function At(t){return typeof t=="string"?t.trim():""}function Y(t){const e=t.trim();return e&&(/[A-Z]/.test(e)&&!e.includes(" ")?e.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():e.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())}function us(t){return t.trim().toLowerCase().replace(/[\s_-]+/g," ").replace(/\s+/g," ")}function Qr(t){const e=new Set,n=[];for(const s of t){const a=s.trim();if(!a)continue;const r=a.toLowerCase();e.has(r)||(e.add(r),n.push(a))}return n}function O(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function G(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function Xt(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}function fa(t,e){const n=e.trim();if(n)return t.find(s=>s.id===n)}function $n(t,e){const n=(t.actor_id??"").trim();if(n)return n;const s=(t.actor??"").trim(),a=(t.actor_name??s??"").trim();if(!a)return"";const r=e.find(p=>p.name===a);if(r)return r.id;const o=a.toLowerCase(),c=e.find(p=>p.name.toLowerCase()===o);if(c)return c.id;const u=e.find(p=>p.name.replace(/[\s_-]+/g,"").toLowerCase()===a.replace(/[\s_-]+/g,"").toLowerCase());if(u)return u.id;const l=e.find(p=>us(p.name).includes(us(a)));return(l==null?void 0:l.id)??""}function Ye(t){const e=t.type.trim().toLowerCase();return e?t.category?t.category.trim().toLowerCase():e.includes("dice.")?"dice":e.includes("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function hn(t){const e=t.trim();e&&(Pe.value=e)}function ds(){Pe.value=""}function to(t,e){if(e){if(e.winner_actor_id){const n=fa(t,e.winner_actor_id);return n?n.name:e.winner_actor_id}if(e.winner)return e.winner}}function eo(t,e){const s=((t==null?void 0:t.evidence)??[]).map(o=>At(o)).map(o=>{if(!o)return"";const c=(e.story_log??[]).find(u=>u.event_id===o||At(u.content).toLowerCase().includes(o.toLowerCase()));return c?`${c.timestamp,""}${At(c.content)}`:o}).filter(Boolean),a=(e.story_log??[]).filter(o=>o.type==="session.outcome").map(o=>At(o.content)).filter(Boolean),r=[t!=null&&t.raw_reason?`raw_reason: ${Y(t==null?void 0:t.raw_reason)}`:"",t!=null&&t.details?`details: ${Y(t==null?void 0:t.details)}`:"",t!=null&&t.summary?`summary: ${Y(t==null?void 0:t.summary)}`:""];return Qr([...s,...a,...r])}function ma({hp:t,max:e}){const n=Xr(t,e),s=Gr(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function _a({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function no({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function so({actor:t}){var o,c;const e=(o=t.archetype)==null?void 0:o.trim(),n=(c=t.persona)==null?void 0:c.trim(),s=t.traits??[],a=t.skills??[],r=t.id===Pe.value;return i`
    <div
      class="trpg-actor trpg-actor-clickable ${r?"trpg-actor-selected":""}"
      role="button"
      tabindex="0"
      onClick=${()=>{hn(t.id)}}
      onKeyDown=${u=>{(u.key==="Enter"||u.key===" ")&&(u.preventDefault(),hn(t.id))}}
    >
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${st} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${no} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${ma} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${_a} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${Ht(e)}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${s.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${s.map(u=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Ht(u)}</span>
                  <span class="trpg-annot-desc">${pa(u)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${a.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${a.map(u=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Ht(u)}</span>
                  <span class="trpg-annot-desc">${va(u)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function ao(){const t=Nn.value;if(!t)return null;const e=fa(t.party??[],Pe.value);if(!e)return null;const n=t.story_log??[],s=t.party??[],a=n.filter(l=>$n(l,s)===e.id).slice(-9),r=a.filter(l=>l.type==="actor.claimed"||l.type==="actor.released"||l.type==="actor.spawned"),o=a.filter(l=>l.type==="turn.action.proposed"||l.type==="turn.action.resolved"||l.type==="narration.posted").slice(-4),c=(t.contribution_ledger??[]).find(l=>l.actor_id===e.id),u=e.role?e.role.toUpperCase():"Unknown";return i`
    <div
      class="trpg-actor-overlay"
      onClick=${l=>{l.target.classList.contains("trpg-actor-overlay")&&ds()}}
    >
      <div class="trpg-actor-detail">
        <div class="trpg-actor-detail-header">
          <div>
            <div class="trpg-actor-name trpg-actor-detail-name">${e.name}</div>
            <div class="trpg-actor-detail-meta">
              <span class="trpg-detail-kv"><strong>ID</strong> ${e.id}</span>
              <span class="trpg-detail-kv"><strong>Role</strong> ${u}</span>
              <span class="trpg-detail-kv"><strong>Status</strong> ${e.status}</span>
              <span class="trpg-detail-kv"><strong>Keeper</strong> ${e.keeper||"unassigned"}</span>
              ${c?i`<span>contribution: ${c.score}</span>`:null}
            </div>
            ${e.persona?i`<div class="trpg-actor-persona">${e.persona}</div>`:null}
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
            <button
              class="control-btn secondary"
              onClick=${()=>{ft.value=e.id,h("Actor selected for controls","success")}}
            >
              Set as action actor
            </button>
            <button class="control-btn ghost" onClick=${ds}>Close</button>
          </div>
        </div>

        ${e.stats?i`
          <div style="margin-top:8px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#9ca3af; margin-bottom:8px;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${ma} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${_a} stats=${e.stats} />
          </div>
        `:null}

        ${r.length>0?i`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Keeper history</summary>
              <div>
                <div class="trpg-story">
                  ${r.map(l=>i`
                    <div class="trpg-event">
                      <div class="trpg-event-main">
                        <span class="trpg-event-text">${At(l.content)}</span>
                      </div>
                      <div class="trpg-event-meta-row">
                        <span class="trpg-event-ts">
                          <${U} timestamp=${l.timestamp} />
                        </span>
                      </div>
                    </div>
                  `)}
                </div>
              </div>
            </details>
          `:null}

        ${c?i`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Contribution</summary>
              <div>
                <div class="trpg-detail-kv-group">
                  <span class="trpg-detail-kv"><strong>Score</strong> ${c.score}</span>
                  ${c.last_reason?i`<span class="trpg-detail-kv"><strong>Last reason</strong> ${c.last_reason}</span>`:null}
                </div>
                ${(c.reasons??[]).length>0?i`
                    <details class="trpg-detail-section" style="margin-top:6px;">
                      <summary class="trpg-detail-summary">Contribution reasons</summary>
                      <div class="trpg-annot-list">
                        ${(c.reasons??[]).map(l=>i`
                          <span class="trpg-annot-chip">
                            <span class="trpg-annot-name">Reason</span>
                            <span class="trpg-annot-desc">${l}</span>
                          </span>
                        `)}
                      </div>
                    </details>
                  `:null}
              </div>
            </details>
          `:null}

        ${o.length>0?i`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Recent dialog/actions</summary>
              <div>
                <div class="trpg-story">
                  ${o.map(l=>i`
                    <div class="trpg-event">
                      <div class="trpg-event-main">
                        <strong>${l.actor_name||l.actor||"System"}</strong>
                        <span class="trpg-event-text">${l.content??""}</span>
                      </div>
                      <div class="trpg-event-meta-row">
                        <span class="trpg-event-ts">
                          <${U} timestamp=${l.timestamp} />
                        </span>
                      </div>
                    </div>
                  `)}
                </div>
              </div>
            </details>
          `:null}

        ${(e.traits??[]).length>0?i`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Traits</summary>
              <div>
                <div class="trpg-annot-list">
                  ${(e.traits??[]).map(l=>i`
                    <span class="trpg-annot-chip trait">
                      <span class="trpg-annot-name">${Ht(l)}</span>
                      <span class="trpg-annot-desc">${pa(l)}</span>
                    </span>
                  `)}
                </div>
              </div>
            </details>
          `:null}

        ${(e.skills??[]).length>0?i`
            <details class="trpg-detail-section">
              <summary class="trpg-detail-summary">Skills</summary>
              <div>
                <div class="trpg-annot-list">
                  ${(e.skills??[]).map(l=>i`
                    <span class="trpg-annot-chip skill">
                      <span class="trpg-annot-name">${Ht(l)}</span>
                      <span class="trpg-annot-desc">${va(l)}</span>
                    </span>
                  `)}
                </div>
              </div>
            </details>
          `:null}

        <details class="trpg-detail-section" open>
          <summary class="trpg-detail-summary">Recent events (${a.length})</summary>
          <div>
            ${a.length===0?i`<div class="empty-state" style="font-size:12px">No recent events</div>`:i`
                <div class="trpg-story">
                  ${a.map(l=>i`
                    <div class="trpg-event">
                      <div class="trpg-event-main">
                        <strong>${l.actor_name||l.actor||"System"}</strong>
                        ${" "}
                        <span class="trpg-event-text">${l.content??""}</span>
                      </div>
                      <div class="trpg-event-meta-row">
                        <span class="trpg-event-ts">
                          <${U} timestamp=${l.timestamp} />
                        </span>
                      </div>
                    </div>
                  `)}
                </div>
              `}
          </div>
        </details>
      </div>
    </div>
  `}function io({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function ro({events:t,parties:e}){const n=ie.value,s=Ke.value,a=Array.from(new Set(t.map(u=>Ye(u)).filter(Boolean))).sort();if(!(t.length>0))return i`<div class="empty-state" style="font-size:13px">No story events yet</div>`;const c=t.filter(u=>{const l=Ye(u),p=$n(u,e);return!(n&&p!==n||s!=="all"&&l!==s)}).slice(-40);return i`
    <div>
      <div class="trpg-story-toolbar">
        <div class="trpg-story-filter">
          <label for="trpg-story-actor-filter">Actor</label>
          <select
            id="trpg-story-actor-filter"
            value=${n}
            onChange=${u=>{ie.value=u.target.value}}
          >
            <option value="">All actors</option>
            ${e.map(u=>i`<option value=${u.id}>${u.name}</option>`)}
          </select>
        </div>
        <div class="trpg-story-filter">
          <label for="trpg-story-category-filter">Category</label>
          <select
            id="trpg-story-category-filter"
            value=${s}
            onChange=${u=>{Ke.value=u.target.value}}
          >
            <option value="all">All</option>
            ${a.map(u=>i`<option value=${u}>${u}</option>`)}
          </select>
        </div>
        <button
          class="control-btn ghost"
          onClick=${()=>{ie.value="",Ke.value="all"}}
        >
          Reset filter
        </button>
        <button
          class="control-btn secondary"
          onClick=${()=>{re.value=!re.value}}
          title="Show/hide debug metadata"
        >
          Debug log: ${re.value?"ON":"OFF"}
        </button>
      </div>

      ${c.length===0?i`<div class="empty-state" style="font-size:13px">No events match current filters.</div>`:i`
          <div class="trpg-story">
            ${c.map((u,l)=>{var $;const p=Ye(u),d=$n(u,e),v=u.actor_name||u.actor||d||"System",f=d===n&&n;return i`
                  <div key=${l} class="trpg-event ${u.type??""}">
                    <div class="trpg-event-main">
                    ${d?i`
                        <button
                          class="trpg-event-actor ${f?"active":""}"
                          onClick=${()=>{ie.value=d,hn(d)}}
                        >
                          ${v}
                        </button>
                      `:i`<strong>${v}</strong>`}
                    ${" "}
                    ${u.dice_roll?i`<span class="trpg-dice">[${u.dice_roll.notation}: ${($=u.dice_roll.rolls)==null?void 0:$.join(",")} = ${u.dice_roll.total}${u.dice_roll.modifier?` +${u.dice_roll.modifier}`:""}]</span>${" "}`:null}
                    <span class="trpg-event-text">${u.content??""}</span>
                  </div>
                  ${re.value?i`
                      <div class="trpg-event-meta-row">
                        <span class="trpg-event-meta">[${p}]</span>
                        <span class="trpg-event-ts">
                          <${U} timestamp=${u.timestamp} />
                        </span>
                      </div>
                    `:null}
                </div>
              `})}
          </div>
        `}
    </div>
  `}function oo({outcome:t,state:e}){if(!t)return null;const n=e.party??[],s=to(n,t),a=eo(t,e),r=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",o=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",c=[s?`승자: ${s}`:null,t.reason?`원인: ${Y(t.reason)}`:null,t.phase?`페이즈: ${Y(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div class="trpg-session-outcome">
      <div class="trpg-outcome-title">Session Outcome</div>
      <div class="trpg-outcome-status" style=${`color:${o};`}>${r}</div>
      ${t!=null&&t.summary?i`<div class="trpg-outcome-summary">${Y(t==null?void 0:t.summary)}</div>`:null}
      ${c?i`<div class="trpg-outcome-meta">${c}</div>`:null}
      ${t!=null&&t.summary||t!=null&&t.details||t!=null&&t.raw_reason||t.reason?i`
          <div class="trpg-outcome-body">
            ${t!=null&&t.summary?i`<p><strong>요약:</strong> ${Y(t==null?void 0:t.summary)}</p>`:null}
            ${t!=null&&t.details?i`<p><strong>세부:</strong> ${Y(t==null?void 0:t.details)}</p>`:null}
            ${t!=null&&t.raw_reason?i`<p><strong>원인 근거:</strong> ${Y(t==null?void 0:t.raw_reason)}</p>`:null}
            ${t.reason?i`<p><strong>원인 코드:</strong> ${Y(t.reason)}</p>`:null}
          </div>
        `:null}
      ${a.length>0?i`
          <div class="trpg-outcome-evidence">
            <div class="trpg-annot-title">근거 이벤트</div>
            ${a.map(u=>i`<div class="trpg-outcome-evidence-item">${u}</div>`)}
          </div>
        `:null}
    </div>
  `}function lo({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function co({state:t}){var u;const e=gt.value||((u=t.session)==null?void 0:u.room)||"",n=le.value,s=t.party??[];if(!s.find(l=>l.id===ft.value)&&s.length>0){const l=s[0];l&&(ft.value=l.id)}const r=async()=>{if(!e){h("No room set","error");return}le.value="running";try{const l=await bi(e);gn.value=l,le.value="ok";const p=ct(l.summary)?l.summary:null,d=p?Xt(p,"advanced",!1):!1,v=p?O(p,"progress_reason",""):"";h(d?"Round advanced":`Round stalled${v?`: ${v}`:""}`,d?"success":"warning"),lt()}catch(l){gn.value=null,le.value="error";const p=l instanceof Error?l.message:"Round failed";h(p,"error")}},o=async()=>{if(e)try{await wi(e),h("Turn advanced","success"),lt()}catch{h("Advance failed","error")}},c=async()=>{if(!e)return;const l=ft.value.trim();if(!l){h("Select actor first","warning");return}const p=Number.parseInt(We.value,10),d=Number.parseInt(Je.value,10);if(Number.isNaN(p)||Number.isNaN(d)){h("Stat/DC must be numbers","warning");return}const v=Number.parseInt(oe.value,10),f=oe.value.trim()===""||Number.isNaN(v)?void 0:v;try{await xi({roomId:e,actorId:l,action:qe.value.trim()||"ability_check",statValue:p,dc:d,rawD20:f}),h("Dice rolled","success"),lt()}catch{h("Dice roll failed","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${e}
            onInput=${l=>{gt.value=l.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${ft.value}
            onChange=${l=>{ft.value=l.target.value}}
          >
            <option value="">Select actor</option>
            ${s.map(l=>i`<option value=${l.id}>${l.name} (${l.id})</option>`)}
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
              onInput=${l=>{qe.value=l.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${We.value}
              onInput=${l=>{We.value=l.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Je.value}
              onInput=${l=>{Je.value=l.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${oe.value}
              onInput=${l=>{oe.value=l.target.value}}
              onKeyDown=${l=>{l.key==="Enter"&&c()}}
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
              onClick=${r}
              disabled=${n==="running"}
            >
              ${n==="running"?"Running...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${o}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${n!=="idle"?i`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function uo({state:t}){var c;const e=gt.value||((c=t.session)==null?void 0:c.room)||"",n=t.join_gate,s=Xe.value,a=ct(s)?s:null,r=async()=>{const u=ce.value.trim(),l=ue.value.trim();if(!e||!u){h("Room/Actor is required","warning");return}H.value="checking";try{const p=await Si(e,u,l||void 0);Xe.value=p,H.value="ok",h("Eligibility updated","success")}catch(p){H.value="error";const d=p instanceof Error?p.message:"Eligibility check failed";h(d,"error")}},o=async()=>{const u=ce.value.trim(),l=ue.value.trim(),p=Ge.value.trim();if(!e||!u||!l){h("Room/Actor/Keeper is required","warning");return}H.value="requesting";try{const d=await Ci({room_id:e,actor_id:u,keeper_name:l,role:Ve.value,...p?{name:p}:{}});Xe.value=d;const v=ct(d)?Xt(d,"granted",!1):!1,f=ct(d)?O(d,"reason_code",""):"";v?h("Mid-join granted","success"):h(`Mid-join rejected${f?`: ${f}`:""}`,"warning"),H.value=v?"ok":"error",lt()}catch(d){H.value="error";const v=d instanceof Error?d.message:"Mid-join request failed";h(v,"error")}};return i`
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
            id="trpg-join-actor-input"
            name="trpg-join-actor-input"
            type="text"
            value=${ce.value}
            onInput=${u=>{ce.value=u.target.value}}
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
            onInput=${u=>{ue.value=u.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ve.value}
            onChange=${u=>{Ve.value=u.target.value}}
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
            value=${Ge.value}
            onInput=${u=>{Ge.value=u.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${r} disabled=${H.value==="checking"||H.value==="requesting"}>
              ${H.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${o} disabled=${H.value==="checking"||H.value==="requesting"}>
              ${H.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${a?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Xt(a,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${G(a,"effective_score",0)}/${G(a,"required_points",0)}</span>
            ${O(a,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${O(a,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function po({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function vo({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function fo(){const t=gn.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ct(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(ct).slice(-8),r=t.canon_check,o=ct(r)?r:null,c=o&&Array.isArray(o.warnings)?o.warnings.filter(R=>typeof R=="string").slice(0,3):[],u=o&&Array.isArray(o.violations)?o.violations.filter(R=>typeof R=="string").slice(0,3):[],l=n?Xt(n,"advanced",!1):!1,p=n?O(n,"progress_reason",""):"",d=n?O(n,"progress_detail",""):"",v=n?G(n,"player_successes",0):0,f=n?G(n,"player_required_successes",0):0,$=n?Xt(n,"dm_success",!1):!1,A=n?G(n,"timeouts",0):0,N=n?G(n,"unavailable",0):0,x=n?G(n,"reprompts",0):0,b=n?G(n,"npc_attacks",0):0,j=n?G(n,"keeper_timeout_sec",0):0,B=n?G(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${l?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${l?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${$?"DM ok":"DM stalled"} / players ${v}/${f}
          </span>
        </div>
        ${p?i`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${d?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${d}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${j||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${B}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(R=>{const K=O(R,"status","unknown"),at=O(R,"actor_id","-"),it=O(R,"role","-"),q=O(R,"reason",""),Q=O(R,"action_type",""),S=O(R,"reply","");return i`
                <div class="trpg-round-item ${K.includes("fallback")||K.includes("timeout")?"failed":"active"}">
                  <span>${at} (${it})</span>
                  <span style="margin-left:auto; font-size:11px;">${K}</span>
                  ${Q?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${Q}</div>`:null}
                  ${q?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${q}</div>`:null}
                  ${S?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${S.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${o?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${O(o,"status","unknown")}</strong>
            </div>
            ${u.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(R=>i`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(R=>i`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function mo(){var r,o;const t=Nn.value;if(dn.value&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>lt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome;return i`
    <div>
      <${oo} outcome=${a} state=${t} />

      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((r=t.session)==null?void 0:r.status)??"Active"}</div>
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
      <${vo} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          <${ao} />

          ${""}
          <${w} title="Story Log (${s.length})">
            <${ro} events=${s} parties=${n} />
          <//>

          ${""}
          ${t.map?i`
              <${w} title="Map" style="margin-top:16px;">
                <${io} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${w} title="Controls">
            <${co} state=${t} />
          <//>

          <${w} title="Last Round Result" style="margin-top:16px;">
            <${fo} />
          <//>

          ${""}
          <${w} title="Mid-Join Gate" style="margin-top:16px;">
            <${uo} state=${t} />
          <//>

          ${""}
          <${w} title="Contribution" style="margin-top:16px;">
            <${po} state=${t} />
          <//>

          ${""}
          <${w} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(c=>i`<${so} key=${c.id??c.name} actor=${c} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?i`
              <${w} title="History (${t.history.length})" style="margin-top:16px;">
                <${lo} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const En="masc_dashboard_agent_name";function _o(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(En);return e??n??"dashboard"}const V=_(_o()),Ut=_(""),Bt=_(""),Te=_(""),Kt=_(!1),mt=_(!1),qt=_(!1),Wt=_(!1),Ae=_(!1),Ie=_(!1);function Ln(t){const e=t.trim();V.value=e,e&&localStorage.setItem(En,e)}function go(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function yn(){const t=V.value.trim();if(t){qt.value=!0;try{const e=await Ai(t),n=go(e);n&&Ln(n),Ie.value=!0,h(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";h(n,"error")}finally{qt.value=!1}}}async function $o(){const t=V.value.trim();if(t){Wt.value=!0;try{await ea(t),Ie.value=!1,h(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";h(n,"error")}finally{Wt.value=!1}}}async function ho(){const t=V.value.trim();if(t)try{await ea(t)}catch{}localStorage.removeItem(En),Ln("dashboard"),Ie.value=!1,await yn()}async function yo(){const t=V.value.trim();if(t){Ae.value=!0;try{await Ni(t),h("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";h(n,"error")}finally{Ae.value=!1}}}async function ps(){const t=V.value.trim(),e=Ut.value.trim();if(!(!t||!e)){Kt.value=!0;try{await ta(t,e),Ut.value="",h("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";h(s,"error")}finally{Kt.value=!1}}}async function bo(){const t=Bt.value.trim(),e=Te.value.trim()||"Created from dashboard";if(t){mt.value=!0;try{await Ti(t,e,1),Bt.value="",Te.value="",h("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";h(s,"error")}finally{mt.value=!1}}}function ko(){return _e(()=>{yn()},[]),i`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${V.value}
        onInput=${t=>Ln(t.target.value)}
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
          onClick=${()=>{yn()}}
          disabled=${qt.value||V.value.trim()===""}
        >
          ${qt.value?"Joining...":Ie.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{$o()}}
          disabled=${Wt.value||V.value.trim()===""}
        >
          ${Wt.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{ho()}}
          disabled=${qt.value||Wt.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{yo()}}
          disabled=${Ae.value||V.value.trim()===""}
        >
          ${Ae.value?"Pinging...":"Heartbeat"}
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
        value=${Te.value}
        onInput=${t=>{Te.value=t.target.value}}
        disabled=${mt.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${bo}
        disabled=${mt.value||Bt.value.trim()===""}
      >
        ${mt.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function xo(){const t=bt.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Cn.value} events</span>
    </div>
  `}const wo=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function So(){const t=Z.value.tab,e=bt.value;return i`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${wo.map(n=>i`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Ee(n.id)}
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
            <strong>${ee.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Cn.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Le(),t==="board"&&dt(),t==="trpg"&&lt()}}
        >
          Refresh Now
        </button>
      </section>

      <${ko} />
    </aside>
  `}function Co(){switch(Z.value.tab){case"overview":return i`<${rs} />`;case"council":return i`<${kr} />`;case"board":return i`<${Er} />`;case"activity":return i`<${Mr} />`;case"agents":return i`<${qr} />`;case"tasks":return i`<${Wr} />`;case"journal":return i`<${Vr} />`;case"trpg":return i`<${mo} />`;default:return i`<${rs} />`}}function To(){return _e(()=>{Ka(),Js(),Le();const t=Vi();return Gi(),()=>{Qa(),t(),Xi()}},[]),_e(()=>{const t=Z.value.tab;t==="board"&&dt(),t==="trpg"&&lt()},[Z.value.tab]),i`
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
          <${xo} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${Wa} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${cn.value&&!bt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${Co} />`}
        </main>
        <${So} />
      </div>

      <${ir} />
      <${vr} />
      <${lr} />
    </div>
  `}const vs=document.getElementById("app");vs&&Aa(i`<${To} />`,vs);
