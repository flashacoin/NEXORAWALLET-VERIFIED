// NEXORA V2 deposit verification preview.
// This endpoint is intentionally verification-only: it does not credit balances.
// Admin authentication and server configuration are required. Fail closed on every mismatch.
const cors={ "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization,apikey,content-type", "Access-Control-Allow-Methods":"POST,OPTIONS" };
const json=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{...cors,"Content-Type":"application/json"}});
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 if(req.method!=="POST")return json({error:"POST required"},405);
 const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY")??Deno.env.get("SUPABASE_PUBLISHABLE_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),admins=(Deno.env.get("NEXORA_ADMIN_USER_IDS")??"").split(",").map(x=>x.trim()).filter(Boolean);
 const gridKey=Deno.env.get("TRONGRID_API_KEY"),depositAddress=Deno.env.get("NEXORA_DEPOSIT_ADDRESS"),usdtContract=Deno.env.get("NEXORA_USDT_CONTRACT"),minConfirmations=Number(Deno.env.get("NEXORA_DEPOSIT_CONFIRMATIONS")??"");
 if(!url||!anon||!service||!admins.length||!gridKey||!depositAddress||!usdtContract||!Number.isInteger(minConfirmations)||minConfirmations<1)return json({error:"Deposit verification is not configured"},503);
 const auth=req.headers.get("Authorization")??"";if(!auth.startsWith("Bearer "))return json({error:"Authentication required"},401);
 const authRes=await fetch(url+"/auth/v1/user",{headers:{apikey:anon,Authorization:auth}});if(!authRes.ok)return json({error:"Invalid session"},401);
 const user=await authRes.json();if(!admins.includes(user?.id))return json({error:"Admin permission required"},403);
 let body:{tx_hash?:string};try{body=await req.json()}catch{return json({error:"Invalid JSON"},400)}
 const hash=typeof body.tx_hash==="string"?body.tx_hash.trim():"";if(!/^[a-f0-9]{64}$/i.test(hash))return json({error:"Invalid transaction hash"},400);
 try{
  const response=await fetch("https://api.trongrid.io/v1/transactions/"+hash,{headers:{"TRON-PRO-API-KEY":gridKey}});
  if(!response.ok)return json({error:"TRON provider lookup failed"},502);
  const tx=await response.json();
  // Provider transaction API result formats can vary. Return evidence for manual inspection only,
  // and never interpret a user-supplied hash or incomplete provider response as a verified deposit.
  const infoRes=await fetch("https://api.trongrid.io/v1/transactions/"+hash+"/events",{headers:{"TRON-PRO-API-KEY":gridKey}});
  if(!infoRes.ok)return json({error:"Provider event lookup failed"},502);
  const events=await infoRes.json();
  return json({verification_status:"manual_review_required",tx_hash:hash,provider_transaction:tx,provider_events:events,expected_recipient:depositAddress,expected_contract:usdtContract,minimum_confirmations:minConfirmations,warning:"Evidence fetched only. No transaction confirmation threshold, token contract, recipient, amount or ledger credit has been verified by this preview endpoint."});
 }catch{return json({error:"TRON provider unavailable"},503)}
});
