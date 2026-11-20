// NEXORA V2 transaction history API. Authenticated, read-only, ledger-backed.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status=200) =>
  new Response(JSON.stringify(body), {status, headers:{...corsHeaders,"Content-Type":"application/json"}});
const fail=(status:number,error:string)=>json({error},status);

Deno.serve(async(req)=>{
  if(req.method==="OPTIONS") return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST") return fail(405,"POST required");
  const url=Deno.env.get("SUPABASE_URL");
  const anon=Deno.env.get("SUPABASE_ANON_KEY")??Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!anon||!service) return fail(500,"Server configuration incomplete");
  const auth=req.headers.get("Authorization")??"";
  if(!auth.startsWith("Bearer ")) return fail(401,"Authentication required");
  try {
    const authRes=await fetch(url+"/auth/v1/user",{headers:{apikey:anon,Authorization:auth}});
    if(!authRes.ok) return fail(401,"Invalid or expired session");
    const user=await authRes.json();
    if(!user?.id) return fail(401,"Invalid session");
    let body:Record<string,unknown>;
    try{body=await req.json();}catch{return fail(400,"Invalid JSON");}
    const page=Number(body.page??1), pageSize=Number(body.page_size??25);
    if(!Number.isInteger(page)||page<1||page>10000) return fail(400,"Invalid page");
    if(!Number.isInteger(pageSize)||pageSize<1||pageSize>100) return fail(400,"Invalid page size");
    const type=typeof body.entry_type==="string"?body.entry_type:"";
    const allowed=["deposit_credit","withdrawal_debit","withdrawal_refund","payment_debit","payment_refund","admin_adjustment","transfer_debit","transfer_credit","opening_balance"];
    if(type&&!allowed.includes(type)) return fail(400,"Invalid transaction type");
    const from=typeof body.from==="string"?body.from:"";
    const to=typeof body.to==="string"?body.to:"";
    if(from&&!/^\d{4}-\d{2}-\d{2}$/.test(from)) return fail(400,"Invalid from date");
    if(to&&!/^\d{4}-\d{2}-\d{2}$/.test(to)) return fail(400,"Invalid to date");
    if(from&&to&&from>to) return fail(400,"Invalid date range");
    const offset=(page-1)*pageSize;
    let query="nx_wallet_ledger?user_id=eq."+encodeURIComponent(user.id)+"&select=id,asset_code,amount,entry_type,reference_type,reference_id,metadata,created_at&order=created_at.desc&limit="+pageSize+"&offset="+offset;
    if(type) query+="&entry_type=eq."+encodeURIComponent(type);
    if(from) query+="&created_at=gte."+encodeURIComponent(from+"T00:00:00Z");
    if(to) query+="&created_at=lte."+encodeURIComponent(to+"T23:59:59.999Z");
    const response=await fetch(url+"/rest/v1/"+query,{headers:{apikey:service,Authorization:"Bearer "+service}});
    if(!response.ok) return fail(503,"History unavailable");
    const rows=await response.json();
    const countHeader=response.headers.get("Content-Range")??"";
    const total=countHeader.includes("/")&&countHeader.split("/").pop()!=="*"?Number(countHeader.split("/").pop()):null;
    return json({transactions:rows,page,page_size:pageSize,total,has_more:rows.length===pageSize});
  }catch{return fail(503,"History service temporarily unavailable");}
});
