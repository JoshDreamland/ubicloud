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
* **Customer Actionable:** Boolean (default: false). True when the customer can or should take action to resolve this issue (e.g. increase quota, free disk space). When true, the routing layer should consider notifying the customer in addition to or instead of paging ops.
* **Oncall Mitigable:** Boolean (default: false). True when a generic oncaller (SRE) can mitigate the issue without escalating to the dev who wrote the alert. When true, the playbook entry should be sufficient to resolve. When both booleans are false, the alert implicitly requires developer escalation.

## Routing truth table (Postgres alerts)

| Alert | customer_actionable | oncall_mitigable | Rationale |
|---|---|---|---|
| Non-primary disk full | true | false | Customer's standby is bloating; customer should investigate. |
| Auto-scale max size | true | true | Primary disk full, no auto-scale options left. Customer can request quota increase; oncall can intervene manually. |
| Auto-scale quota insufficient | true | true | Primary disk full, quota blocks auto-scale. Same as above. |
| Auto-scale canceled by user | true | false | Customer canceled auto-scale; this is informational. |
| Archival backlog high | false | true | WAL archival falling behind; oncall can investigate the server. |
| Missing backup | false | true | Backup schedule missed; oncall can trigger manually or investigate. |
| Root disk full (primary) | false | true | Root disk issue on primary; oncall can clean up or recycle. |
| Backup init failed 3x | false | false | Restore from backup failing; likely a bug or infra issue, needs dev. |
| Upgrade failed | false | false | Version upgrade script failed; needs dev investigation. |
| Metrics backlog high | false | false | Internal metrics pipeline backed up; needs dev. |
| I/O throttle stale | false | false | Cgroup I/O throttle file not updating; needs dev investigation. |
| Root disk full (standby) | false | false | Non-critical, but not customer-actionable or oncall-mitigable. |
