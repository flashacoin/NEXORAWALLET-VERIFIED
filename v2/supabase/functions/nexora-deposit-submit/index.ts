// NEXORA V2 deposit submission. This only creates a pending record; no wallet credit.
const corsHeaders = { "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, apikey, content-type", "Access-Control-Allow-Methods":"POST, OPTIONS" };
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...corsHeaders,"Content-Type":"application/json"}});
Deno.serve(async(req)=>{
 if(req.method==="OPTIONS") return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST") return json({error:"POST required"},405);
 const url=Deno.env.get("SUPABASE_URL"), anon=Deno.env.get("SUPABASE_ANON_KEY")??Deno.env.get("SUPABASE_PUBLISHABLE_KEY"), service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!url||!anon||!service) return json({error:"Server configuration incomplete"},500);
 const authHeader=req.headers.get("Authorization")??"";
 if(!authHeader.startsWith("Bearer ")) return json({error:"Sign in required"},401);
 let auth:Response;
 try{auth=await fetch(url+"/auth/v1/user",{headers:{apikey:anon,Authorization:authHeader}})}catch{return json({error:"Authentication service unavailable"},503)}
 if(!auth.ok) return json({error:"Invalid or expired session"},401);
 const user=await auth.json(); if(!user?.id) return json({error:"Invalid user"},401);
 let body:any; try{body=await req.json()}catch{return json({error:"Invalid JSON"},400)}
 const amount=Number(body?.amount), network=body?.network_code??"TRON-TRC20", hash=typeof body?.tx_hash==="string"?body.tx_hash.trim():"";
 if(!Number.isFinite(amount)||amount<=0||amount!==Math.round(amount*1e6)/1e6) return json({error:"Amount must be positive with up to 6 USDT decimals"},400);
 if(network!=="TRON-TRC20") return json({error:"Unsupported network"},400);
 if(!/^[A-Fa-f0-9]{64}$/.test(hash)) return json({error:"Invalid transaction hash format"},400);
 const headers={apikey:service,Authorization:"Bearer "+service,"Content-Type":"application/json"};
 let response:Response;
 try{response=await fetch(url+"/rest/v1/rpc/nx_submit_deposit",{method:"POST",headers,body:JSON.stringify({p_user_id:user.id,p_amount:amount,p_network_code:network,p_tx_hash:hash})})}catch{return json({error:"Deposit service unavailable"},503)}
 const data=await response.json().catch(()=>null);
 if(!response.ok) return json({error:typeof data==="string"?data:(data?.message??"Deposit submission failed")},409);
 return json({success:true,submission_id:data,status:"submitted",notice:"Submitted for verification. Your wallet has not been credited."});
});
