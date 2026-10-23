import test from 'node:test';
import assert from 'node:assert/strict';
import {createPersonalSessionStorage} from '../accounts/personal-session.js';
const key='sb-test-auth-token',choice='coltrain-remember-device';
const token=(id='a',refresh='refresh-a')=>JSON.stringify({user:{id},access_token:'access-'+id,refresh_token:refresh});
const memory=()=>{const map=new Map();return {getItem:k=>map.get(k)??null,setItem:(k,v)=>map.set(k,v),removeItem:k=>map.delete(k)};};
const fixture=()=>{const local=memory(),session=memory();return {local,session,store:createPersonalSessionStorage({local,session,authKey:key})};};
test('sessions stay tab-only unless personal persistence is explicitly chosen',()=>{
 const {local,session,store}=fixture();store.setItem(key,token());assert.equal(local.getItem(key),null);assert.equal(session.getItem(key),token());
 assert.equal(createPersonalSessionStorage({local,session:memory(),authKey:key}).getItem(key),null);
 local.setItem('coltrain-device-mode','personal');assert(store.setRemember(true));assert.equal(local.getItem(key),token());
 const reopened=createPersonalSessionStorage({local,session:memory(),authKey:key});assert.equal(reopened.getItem(key),token());
 reopened.setItem(key,token('a','rotated-refresh'));assert.equal(store.getItem(key),token('a','rotated-refresh'));
});
test('turning remember off preserves current session and clears all persistent auth keys',()=>{
 const {local,session,store}=fixture();local.setItem('coltrain-device-mode','personal');store.setItem(key,token());store.setRemember(true);
 store.setItem(key+'-code-verifier','pkce-test');store.setItem(key+'-user','cached-user');
 local.setItem('coltrain-device-mode','shared');assert(store.setRemember(false));assert.equal(store.getItem(key),token());assert.equal(session.getItem(key),token());
 for(const k of [key,key+'-code-verifier',key+'-user',choice])assert.equal(local.getItem(k),null);
 assert.equal(createPersonalSessionStorage({local,session:memory(),authKey:key}).getItem(key),null);
});
test('sign-out clears stored token/refresh credentials and personal consent',()=>{
 const {local,session,store}=fixture();local.setItem('coltrain-device-mode','personal');store.setRemember(true);store.setItem(key,token());store.clear();
 assert.equal(local.getItem(key),null);assert.equal(local.getItem(choice),null);assert.equal(session.getItem(key),null);assert.equal(store.isRemembered(),false);
});
test('unavailable persistent storage falls back safely to current-session sign-in',()=>{
 const local={getItem:()=>{throw Error('blocked')},setItem:()=>{throw Error('quota')},removeItem:()=>{}};
 const store=createPersonalSessionStorage({session:memory(),local,authKey:key});assert.equal(store.setRemember(true),false);assert(store.failed());store.setItem(key,token());assert.equal(store.getItem(key),token());
 const f=fixture();f.local.setItem('coltrain-device-mode','personal');f.store.setRemember(true);f.local.setItem=()=>{throw Error('quota')};f.store.setItem(key,token());assert.equal(f.store.getItem(key),token());assert(f.store.failed());assert.equal(f.local.getItem(choice),null);
});
test('different tab accounts never adopt or overwrite another identity on refresh',()=>{
 const local=memory(),one=memory(),two=memory();local.setItem('coltrain-device-mode','personal');
 const a=createPersonalSessionStorage({session:one,local,authKey:key}),b=createPersonalSessionStorage({session:two,local,authKey:key});
 a.setItem(key,token('a'));a.setRemember(true);b.setItem(key,token('b'));b.setRemember(true);
 assert.equal(a.getItem(key),token('a'));a.setItem(key,token('a','a-next'));assert.equal(local.getItem(key),token('b'));
 a.clear();assert.equal(local.getItem(key),token('b'));assert.equal(b.getItem(key),token('b'));
});

test('remembered PKCE callbacks can read their verifier after reopening before a session exists',()=>{
 const {local,store}=fixture();local.setItem('coltrain-device-mode','personal');store.setRemember(true);store.setItem(key+'-code-verifier','callback-verifier');
 const reopened=createPersonalSessionStorage({session:memory(),local,authKey:key});assert.equal(reopened.getItem(key+'-code-verifier'),'callback-verifier');assert.equal(reopened.getItem(key),null);
});
