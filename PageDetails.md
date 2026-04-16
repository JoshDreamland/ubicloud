ALL callers to PageNexus.assemble will be required to provide escalation information:

* **Urgency:** Enum indicating the likelihood that this problem indicates an impending outage.  
  * **`NOTIFY`:** Just FYI. Use when adding a new alert for something that may or may not work.  
  * **`TICKET`**: This is a real problem, but it can wait until business hours.  
  * **`PAGE`**: This is a real problem, and it poses a real threat if not investigated as part of oncall.  
* **Owner:** The person responsible for this alert; generally, the author of the call to assemble().  
* **Tag (Alert Type):**   
  * On ClickHouse's side, this corresponds to a Playbook entry.  
    * Playbook entry is  used to debug this issue instead of escalating to owner.  
  * Failure to provide a playbook entry is a contract to own all tickets and pages.  
* **Blast Radius:** For `PAGE` urgency, indicates the number of customers that would be impacted.  
  * `NONE`: Customers will never see the effects of this page.  
  * `SINGLE`: This affects one customer's resource.  
    * Caveat: Ubicloud re-uses VPCs (Private Subnets) between customers, CH doesn't.  
  * `MANY`: This affects a resource shared by multiple customers (e.g. whole Location)  
  * `ALL`:  Global DNS outage or some crap  
* **Impact Timeline:** For `PAGE` urgency, indicates time to respond.  
  * `UNLIKELY`: I don't know why a `PAGE` would use this rather than `NOTIFY`.  
  * `EVENTUALLY`: Should probably be `TICKET`; ignore as a page unless it's your \#1 customer.  
  * `SOON`: Flailing is ongoing and recovery systems are not doing their jobs.  
  * `NOW`: Live services are already affected.  
* **Customer Impact:**  
  * `NONE`: The customer will not notice the effects of this problem (e.g. internal logs outage)  
  * `VISIBILITY`: Customer-facing metrics or billing outage. (Do we want this?)  
  * `DEGRADE`: A service is experiencing degradation (higher latency, packet loss)  
  * `OUTAGE`: A service is down and a customer is experiencing an outage.  
* **Service UBID:** ID for the most immediate *service* resource affected by this issue.  
  * Prefer Postgres resource to VM resource, prefer VM resource to Port resource.  
  * Open question: can we agree to *always* supply a customer-created resource ID?
