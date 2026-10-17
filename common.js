const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtTime = s => s ? new Date(s).toLocaleString('en-IN',{dateStyle:'medium',timeStyle:'short'}) : '—';
const readPlayer = () => { try{return JSON.parse(sessionStorage.getItem('arcade_player')||'null')}catch{return null} };
const readAdmin = () => sessionStorage.getItem('arcade_admin') || '';
function savePlayer(p){sessionStorage.setItem('arcade_player',JSON.stringify(p))}
function logout(){sessionStorage.removeItem('arcade_player');location.href='index.html'}
function notify(msg,type='info'){const box=$('notice');if(!box)return;box.textContent=msg;box.className='notice '+type;box.hidden=false}
async function rpc(fn,args={}){
 if(!SUPABASE_URL || SUPABASE_URL.includes('YOUR-PROJECT') || !SUPABASE_KEY || SUPABASE_KEY.includes('YOUR_')) throw new Error('Configure config.js with your Supabase Project URL and publishable/anon key.');
 let res; try{res=await fetch(SUPABASE_URL+'/rest/v1/rpc/'+fn,{method:'POST',headers:{'Content-Type':'application/json',apikey:SUPABASE_KEY,Authorization:'Bearer '+SUPABASE_KEY},body:JSON.stringify(args)})}catch{throw new Error('Cannot reach Supabase. Check your internet connection.')}
 const body=await res.json().catch(()=>null);if(!res.ok)throw new Error(body?.message||body?.details||body?.hint||`Supabase error ${res.status}`);return body;
}
function requirePlayer(){const p=readPlayer();if(!p){location.href='index.html';return null}return p}
function nav(active=''){return `<header class="topbar"><a class="brand" href="index.html"><span class="brand-icon">✦</span> SKILL ARCADE</a><nav><a class="${active==='home'?'active':''}" href="index.html">Home</a><a class="${active==='games'?'active':''}" href="games.html">Games</a><a class="${active==='history'?'active':''}" href="history.html">History</a><a href="admin.html">Admin</a></nav><button class="btn btn-quiet btn-small" onclick="logout()">Log out</button></header>`}
function shell(content,active=''){document.body.innerHTML=nav(active)+`<main class="page">${content}<div id="notice" class="notice" hidden></div></main><footer>SKILL ARCADE · School event credit system</footer>`}
