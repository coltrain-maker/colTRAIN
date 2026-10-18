import {avatarMarkup} from './avatars.js';
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function setAccountHeader({storeName='Account setup',profile,user,role}={}) {
  const header=document.querySelector('header'),context=header?.querySelector('.store');
  if(!context)return;
  header.classList.toggle('signed-in-header',Boolean(user));
  context.classList.toggle('account-identity',Boolean(user));
  const candidate=profile?.full_name||user?.user_metadata?.full_name;
  const name=typeof candidate==='string'&&candidate.trim()?candidate.trim():user?.email||'Teammate';
  context.innerHTML=user?`${avatarMarkup(name,profile?.avatar_path)}<span class="account-identity-text"><strong>${esc(storeName)}</strong><span>Signed in as ${esc(name)}${role?` · ${esc(role)}`:''}</span></span>`:esc(storeName);
}
