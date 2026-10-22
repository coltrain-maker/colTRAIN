// Record the employee's first entry before trying email, so provider outages cannot lose the in-app alert.
export async function confirmEmployeeLogin(client){
 try{
  const recorded=await client.rpc('record_employee_first_login',{});
  if(recorded.error)return;
  // The authenticated worker can drain only this employee's event or this manager's own queued alerts.
  await client.functions.invoke('employee-login',{body:{}});
 }catch{/* A login must remain usable during provider/network failures. The durable queue retries on later entry. */}
}
