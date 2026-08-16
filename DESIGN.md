# Design Document

Formal design of the Azure Fee Management System: the data model, API contract,
security model, request flows, and the reasoning behind each choice.

This sits alongside two other documents. The README describes what the system is
and how to deploy it. IMPLEMENTATION.md records how it was built and what went
wrong along the way. This document states the design itself, maps every
requirement in the brief to where it is satisfied, and prepares the answers to
the questions the design invites.

---

## Contents

1. [Design goals and constraints](#1-design-goals-and-constraints)
2. [System overview](#2-system-overview)
3. [Data model](#3-data-model)
4. [API contract](#4-api-contract)
5. [Security model](#5-security-model)
6. [Request flows](#6-request-flows)
7. [Non-functional design](#7-non-functional-design)
8. [Alternatives considered](#8-alternatives-considered)
9. [Requirements traceability](#9-requirements-traceability)
10. [Known limitations](#10-known-limitations)
11. [Anticipated questions](#11-anticipated-questions)

---

## 1. Design goals and constraints

### Goals

| Goal | How it shapes the design |
|---|---|
| Satisfy every requirement in the brief | Each requirement traced to a component in §9 |
| Keep the system explainable in 15 minutes | Three endpoints, two tables, one workflow — no component exists that cannot be justified in one sentence |
| No secrets in source | Configuration read from environment; connection strings and keys live in app settings and APIM named values |
| Correct security boundaries | The backend is unreachable except through the gateway |
| Cost-controlled | Every service on a serverless or consumption tier; the database configured to pause rather than bill on overage |

### Constraints

**The schema is fixed.** The brief specifies the exact columns of both tables.
Where those columns are insufficient — there is no email address for reminders —
the gap is documented rather than resolved by deviating from the specification.

**Three status values only.** The brief permits "Paid", "Partially Paid" and
"Overdue". A fourth would be cleaner but would break a stated contract.

**Time.** The build ran to a fixed deadline. This ruled out designs whose failure
modes were hard to diagnose under time pressure — managed identity for SQL being
the main example.

### Explicit non-goals

Scope deliberately excluded, each of which was designed and then removed:

- A fee-update audit table
- Managed identity for the SQL and storage connections
- Pagination on the list endpoint
- A SQL view duplicating the status calculation
- A fourth "Pending" status
- A 5000-row seed

None is asked for by the brief. Each would add surface area to explain and to
maintain. All are recorded in §10 and in the README's assumptions.

---

## 2. System overview

The system contains exactly two flows.

**Synchronous.** A client calls the API. API Management authenticates the
request, applies rate limiting, and — for the admin operation — validates an
Entra ID token and its role claim. It then forwards to the Function App, which
reads or writes Azure SQL and returns JSON.

**Asynchronous.** A Logic App runs daily, calls the overdue endpoint on the
Function App, and sends a personalised reminder email for each overdue student.

Everything else — the gateway, the identity provider, the telemetry, the retry
configuration — is the non-functional layer wrapped around those two flows.

### Component responsibilities

| Component | Responsibility | Explicitly not responsible for |
|---|---|---|
| API Management | Authentication, authorisation, rate limiting, routing | Business logic, data access |
| Function App | Fee status calculation, data access, request validation | Authentication (handled at the edge) |
| Azure SQL | Durable storage, referential integrity, indexed retrieval | Business rules — no triggers, no computed status |
| Logic App | Scheduling, iteration, email delivery, retry | Determining who is overdue — it asks the API |
| Entra ID | Token issuance, role assignment | Anything at request time; APIM validates offline against published metadata |
| Application Insights | Request, dependency and exception telemetry | Alerting (not configured in this build) |

The line worth defending: **the Logic App does not know the overdue rule.** It
could query SQL directly via the SQL connector. Routing through the Function
endpoint means the status rule exists in exactly one place, so the API and the
reminder job can never disagree about whether a student is overdue.

---

## 3. Data model

### Entities

```
Students                          Administrators
─────────────────────────         ─────────────────────
StudentID   INT      PK           AdminID   INT      PK
Name        NVARCHAR(100)         Name      NVARCHAR(100)
Course      NVARCHAR(100)         Role      NVARCHAR(50)
TotalFee    DECIMAL(10,2)
PaidAmount  DECIMAL(10,2)
DueDate     DATE

Index: IX_Students_DueDate (DueDate)
```

### There is no relationship between the tables

This is deliberate and worth stating plainly, because it looks like an omission.

Neither table carries a column referencing the other, and the brief defines none.
The real-world relationship is many-to-many — any administrator may act on any
student record — which cannot be expressed without a junction table the brief
does not ask for.

The tables are related *behaviourally*, not relationally: administrators act on
student records through the API. Authorisation for that action is enforced by
Entra ID, not by a database constraint.

The `Administrators` table records the roster. Its `Role` values (`FeeAdmin`,
`Viewer`) deliberately match the Entra app role names, so the application's own
record of who may do what aligns with the identity provider's.

Modelling this properly would mean a `FeeUpdateHistory` table holding both
`AdminID` and `StudentID` as foreign keys, plus old and new values and a
timestamp. That gives the correct relationship *and* an audit trail. It is
recorded as production work in §10.

### Type rationale

| Choice | Reasoning |
|---|---|
| `DECIMAL(10,2)` for money | Exact decimal arithmetic. `FLOAT` introduces rounding error on currency, which is indefensible in a financial system |
| `NVARCHAR` over `VARCHAR` | Unicode support for names |
| `DATE` over `DATETIME` for `DueDate` | A fee deadline has no meaningful time component. Comparing dates without a time avoids off-by-one errors at midnight |
| `NOT NULL DEFAULT 0` on `PaidAmount` | A new student has paid nothing. `NULL` would make `PaidAmount >= TotalFee` evaluate to unknown rather than false, silently breaking the status rule |
| `NOT NULL` throughout | No business case exists for a student without a course or a due date |

### Access paths

The system performs exactly two queries. Each has a matching access path.

| Query | Predicate | Access path | Complexity |
|---|---|---|---|
| Single student | `WHERE StudentID = ?` | Clustered PK seek | O(log n) |
| Overdue scan | `WHERE PaidAmount < TotalFee AND DueDate < today` | `IX_Students_DueDate` range seek, then residual predicate | O(log n + m) |

No index was added on `PaidAmount` or `TotalFee`. Indexes cost storage and slow
writes; adding them for queries the system does not perform would be
speculative.

This is the concrete answer to the brief's 5000-record requirement: two query
patterns, two access paths, neither degrading linearly with table size.

---

## 4. API contract

Base URL: `https://{apim-instance}.azure-api.net/{api-suffix}`

All requests require the header `Ocp-Apim-Subscription-Key`.

### GET /students/{studentId}

Fee details and calculated payment status for one student. Serves both the
student-facing view and the admin query described in the brief's functional
requirements — the same read operation with different callers.

**Response 200**

```json
{
  "studentId": 1,
  "name": "Aarav Sharma",
  "course": "Computer Engineering",
  "totalFee": 120000.0,
  "paidAmount": 120000.0,
  "balance": 0.0,
  "dueDate": "2026-07-01",
  "paymentStatus": "Paid"
}
```

`balance` is returned as a derived convenience field so callers do not need to
compute it.

**Errors:** 404 if the student does not exist.

### GET /overdue-students

Array of students with an outstanding balance whose due date has passed.
Consumed by the Logic App.

**Errors:** none specific — returns an empty array when nothing is overdue.

### PUT /students/{studentId}/fees

Updates a fee record. Requires an Entra ID bearer token carrying the `FeeAdmin`
role in addition to the subscription key, and `Content-Type: application/json`.

**Request**

```json
{ "paidAmount": 95000 }
```

Any combination of `totalFee`, `paidAmount` and `dueDate` may be supplied.
Omitted fields retain their existing values.

**Response 200** — returns the updated record, so the caller can confirm the new
state and the recalculated status in a single round trip.

**Errors:** 400 if the body is not valid JSON or contains none of the three
updatable fields; 401 without a valid admin token; 404 if the student does not
exist.

### Status calculation

The rule, in evaluation order:

```
PaidAmount >= TotalFee          →  "Paid"
DueDate < today                 →  "Overdue"
otherwise                       →  "Partially Paid"
```

**Order is the design decision.** The three statuses are not mutually exclusive —
a student who has paid in full but whose due date has passed satisfies two of
them. Checking `Paid` first establishes precedence: a settled account is never
reported as overdue.

The rule lives in one Python function. The identical expression appears in the
seed verification query, so SQL and application agree by construction.

---

## 5. Security model

### Layered enforcement

```
Request
   │
   ├─ Layer 1: Subscription key       (all operations)
   │           Rejected → 401
   │
   ├─ Layer 2: Rate limit             (all operations)
   │           Exceeded → 429
   │
   ├─ Layer 3: JWT + role claim       (PUT only)
   │           Invalid → 401
   │
   └─ Layer 4: Function key           (APIM → backend)
               Absent → 401
```

Layers 1–3 execute at the API Management edge. An unauthorised request never
reaches compute.

Layer 4 means the Function App is unreachable directly. Knowing its URL is not
sufficient — `AuthLevel.FUNCTION` on every endpoint requires a key that only
APIM holds.

### The two tiers

The brief asks for API keys (Task 3) and Entra ID with RBAC (Task 4). These are
not alternatives; they are layered.

| Caller | Subscription key | Entra token with FeeAdmin |
|---|---|---|
| Student — read own status | Required | — |
| Logic App — read overdue list | Required | — |
| Admin — update fee record | Required | Required |

The distinction matters: a compromised subscription key permits reads but cannot
mutate financial data. Writing requires an identity that Entra ID has explicitly
granted the `FeeAdmin` role.

### Token validation

APIM validates offline against Entra's published OpenID metadata — it does not
call Entra per request. Three things are checked:

1. **Signature** — against keys from the metadata document
2. **Audience** — must equal the application's ID URI
3. **Role claim** — `roles` must contain `FeeAdmin`

The app role is of type **Applications**, not Users. This enables the client
credentials flow: a token is obtained with one scripted HTTP call rather than an
interactive browser sign-in. That is both scriptable for automation and
demonstrable without a login flow mid-presentation.

### Injection resistance

Every SQL statement is parameterised. The update endpoint uses `COALESCE` on each
column rather than building a dynamic `SET` clause, so partial updates require no
string concatenation:

```sql
SET TotalFee   = COALESCE(?, TotalFee),
    PaidAmount = COALESCE(?, PaidAmount),
    DueDate    = COALESCE(?, DueDate)
```

The query text is fixed at author time. User input never becomes part of it.

### Secrets handling

| Secret | Where it lives |
|---|---|
| SQL connection string | Function App application setting, read via `os.environ` |
| Function key | APIM named value, injected on backend calls |
| APIM subscription key | Held by the client |
| Entra client secret | Held by the calling application |

Nothing is hardcoded. `local.settings.json` is local-only and excluded from
source control; the repository contains only a placeholder template.

---

## 6. Request flows

### Student checks payment status

```
Student → APIM
              validate subscription key
              check rate limit (5/min)
       → Function App  (+ function key)
              query Students by StudentID
       → Azure SQL
              clustered PK seek
       ← row
              calculate status: Paid | Overdue | Partially Paid
       ← JSON 200
              emit telemetry → Application Insights
```

### Administrator updates a fee record

```
Admin → Entra ID
              POST /oauth2/v2.0/token (client credentials)
        ← JWT with roles: ["FeeAdmin"]

Admin → APIM   (subscription key + Authorization: Bearer …)
              validate subscription key
              check rate limit
              validate-jwt:  signature, audience, roles claim
       → Function App  (+ function key)
              parse and validate body
              UPDATE with COALESCE, parameterised
       → Azure SQL
              commit
              re-select updated row
       ← row
              recalculate status
       ← JSON 200 with updated record
```

Any failure at the APIM layer terminates the flow before reaching compute.

### Daily reminder job

```
Logic App  (recurrence: 1 day)
       → Function App   GET /overdue-students  (+ function key)
              retry: exponential, 4 attempts, PT7S
       → Azure SQL
              IX_Students_DueDate range seek
       ← rows
       ← JSON array
              Parse JSON → typed fields
              For each:
                  Send an email (V2)
                  retry: exponential, 4 attempts, PT7S
       → Outlook
```

The Logic App calls the Function App directly with a function key rather than
routing through APIM. This is deliberate: it is an internal Azure-to-Azure call
that needs neither the gateway's key management nor its rate limiting, and
routing machine traffic through APIM would consume the rate limit budget
intended for clients.

---

## 7. Non-functional design

### Scalability

| Dimension | Design | Limit |
|---|---|---|
| Data volume | Two indexed access paths, both O(log n) | Comfortably beyond the 5000-record requirement |
| Request concurrency | Function App on Consumption scales out per-request | Bounded by plan limits |
| Database compute | Serverless, auto-scales within configured vCore range | Free tier vCore-second allowance |
| Batch size | Logic App For-each iterates the overdue set | Would need pagination and batching at large scale |

**The honest constraint:** the overdue endpoint returns an unbounded array. At
5000 students with a high overdue proportion this becomes impractical, and the
For-each loop would need batching. Pagination is recorded as production work.

### Reliability

| Failure mode | Mitigation |
|---|---|
| Function App cold start | Exponential retry on the Logic App's HTTP action |
| Database auto-resume delay | Same retry policy; the connection timeout is 30s |
| Email connector throttling | Exponential retry on the email action |
| Transient SQL fault | Retry at the workflow level |
| Malformed request | Validated before reaching the database; 400 returned |

Retry is exponential rather than fixed because transient failures usually clear
within seconds. Backing off increasingly gives a struggling downstream service
room to recover instead of adding load.

### Observability

Application Insights captures requests, dependencies (including SQL calls),
exceptions and custom traces. The Function code logs at each significant point —
student lookups, overdue counts, successful updates.

Logic App run history provides per-iteration status for the reminder job, which
is inspectable without leaving the portal.

**Not configured:** alert rules. Production would alert on failure rate, response
time and dependency failures, routed to an on-call channel.

### Cost

Every service is serverless or consumption-tier. The database's free-offer
overage behaviour is set to pause rather than bill, which makes runaway cost
structurally impossible rather than merely unlikely.

---

## 8. Alternatives considered

| Decision | Chosen | Alternative | Why |
|---|---|---|---|
| Reminder orchestration | Logic App | Durable Function | Daily scheduled fan-out with no state. Retry policy and scheduling are configuration, not code; run history is inspectable. A Durable Function wins when orchestration needs stateful coordination or compensation logic |
| Status calculation location | Function | SQL computed column or view | The brief specifies using Functions for fee calculations. One implementation serves both the API and the Logic App, so they cannot diverge |
| Logic App data source | Function endpoint | SQL connector direct | Keeps the overdue rule in one place. Direct SQL would duplicate the business rule in the workflow |
| Rate limit policy | `rate-limit` | `rate-limit-by-key` | `rate-limit-by-key` is unsupported on the Consumption tier. `rate-limit` counts per subscription automatically, which is the desired behaviour anyway |
| App role member type | Applications | Users | Enables client credentials flow — scriptable, no interactive sign-in |
| SQL authentication | Connection string | Managed identity | Managed identity is better practice but needs an additional contained-user setup whose failure mode is opaque. Recorded as production work |
| APIM tier | Consumption | Developer | Consumption provisions in minutes and costs nothing at this volume. Developer costs ~$50/month and takes 40 minutes |
| Function hosting | Consumption (classic) | Flex Consumption | Classic is well-documented with predictable behaviour. Flex is newer with different regional availability |
| Partial update mechanism | `COALESCE` | Dynamic `SET` clause | No string concatenation, so every value stays a bound parameter |

---

## 9. Requirements traceability

Every requirement in the brief, mapped to where it is satisfied.

### Functional requirements

| Requirement | Satisfied by | Evidence |
|---|---|---|
| Students view fee details and payment status via API | `GET /students/{studentId}` | Returns record with calculated status |
| Students receive automated reminders for pending dues | Logic App daily recurrence → Outlook connector | Run history; delivered emails |
| Admins query student fee details | Same GET endpoint | Serves both audiences |
| Admins update fee records securely | `PUT /students/{studentId}/fees` behind `validate-jwt` | 401 without token, 200 with |

### Technical requirements

| Requirement | Satisfied by |
|---|---|
| Azure SQL Database for structured fee records | `FeeManagementDB`, two tables per specification |
| Automation via Logic Apps or Durable Functions | Logic App `logic-fee-reminders` |
| Azure Functions for fee calculations and API logic | `get_payment_status()` and three HTTP endpoints |
| API Management to securely expose APIs | Consumption-tier instance, product with required subscription |
| Azure AD authentication and RBAC | App registration, `FeeAdmin` app role, `validate-jwt` policy |
| Handle at least 5000 records efficiently | Clustered PK + `IX_Students_DueDate`; both access paths O(log n) |

### Task requirements

| Task | Requirement | Satisfied by |
|---|---|---|
| 1 | Students table with six specified columns | `sql/01_schema.sql` |
| 1 | Administrators table with three specified columns | `sql/01_schema.sql` |
| 1 | Sample data for at least 20 students | `sql/02_seed.sql` — 25 students, 3 administrators |
| 2 | Fetch overdue students | `GET /overdue-students` |
| 2 | Send reminders via SendGrid or Outlook | Outlook.com connector inside For-each |
| 3 | Fetch fee details by StudentID | `GET /students/{studentId}` |
| 3 | Return Paid / Partially Paid / Overdue | `get_payment_status()` |
| 3 | Rate limiting | `rate-limit calls="5" renewal-period="60"` at API scope |
| 3 | Authentication via API keys | Product with **Requires subscription** enabled |
| 4 | Endpoint for admins to update fee records | `PUT /students/{studentId}/fees` |
| 4 | Secured with Azure AD + RBAC | `validate-jwt` with `FeeAdmin` role claim, PUT scope only |
| 5 | Application Insights for monitoring | Provisioned with the Function App; structured logging in code |
| 5 | Retry policies for Logic Apps | Exponential, count 4, interval PT7S on both actions |

### Deliverables

| Deliverable | Provided |
|---|---|
| Code — Functions, Logic Apps, DB setup scripts | `functions/`, `sql/`, `policies/` |
| Documentation — architecture diagram | `architecture-diagram.png` |
| Documentation — step-by-step deployment guide | README §Deployment guide |
| Demo — 5–10 minute recording | Recorded walkthrough |

---

## 10. Known limitations

Stated plainly, with the production remedy for each.

**No concurrency control.** Two administrators updating the same student
simultaneously produces last-write-wins. There is no optimistic concurrency
check. Production would add a `RowVersion` column and an `ETag`-based
`If-Match` header, returning 409 on conflict.

**No audit trail.** The system records the current state of a fee record but not
who changed it, when, or from what. For financial data this is a real gap.
Remedy: the `FeeUpdateHistory` table described in §3.

**No email address in the schema.** Reminders route to a single configured
mailbox because the specified `Students` columns include no contact field.
Remedy: add an `Email` column and bind the connector's recipient to it.

**Unbounded list response.** `GET /overdue-students` returns every matching
record. Remedy: keyset pagination, with the Logic App batching its iteration.

**Three status values cannot express every case.** A student who has paid nothing
and is not yet due falls through to "Partially Paid". Remedy: a fourth "Pending"
status.

**Connection opened per invocation.** Acceptable at this volume, wasteful under
load. Remedy: module-scope connection reuse with proper lifecycle handling.

**Credentials rather than managed identity.** Both the SQL connection and the
runtime storage connection use secrets. Remedy: system-assigned managed identity
for both.

**No alerting.** Telemetry is collected but nothing watches it. Remedy: alert
rules on failure rate, latency and dependency failures.

---

## 11. Anticipated questions

Prepared answers to the questions this design invites.

**Why a Logic App rather than a Durable Function?**

The reminder job is a daily scheduled fan-out with no state to coordinate. Logic
Apps give the scheduler, the retry policy and the email connector as
configuration rather than code, and the run history is inspectable without
adding logging. I would choose a Durable Function if the orchestration needed
stateful coordination across steps, compensation on failure, or fan-out with
result aggregation — none of which apply here.

**Why is the status calculated in the Function rather than in SQL?**

The brief specifies using Azure Functions for fee calculations. Beyond that, the
Logic App and the API both need the status, and keeping the rule in one Python
function means they cannot disagree. If it lived in a view and the API also
computed it, the two could drift.

**Why is there no foreign key between Students and Administrators?**

The brief defines no join column in either table, and the real relationship is
many-to-many — any administrator can act on any student — which needs a junction
table the brief doesn't ask for. Entra ID is the authorisation source of truth;
the Administrators table is the application's roster, with Role values matching
the Entra app role names. To model it properly I'd add a fee-update history table
holding both IDs as foreign keys, which gives you the relationship and the audit
trail at once.

**How does this handle 5000 records efficiently?**

There are two query patterns. Single-student lookup is served by the clustered
primary key — a B-tree seek. The overdue scan is served by a non-clustered index
on DueDate, so it seeks a date range rather than scanning the table, then
evaluates the balance predicate on the matching subset. Both are logarithmic. I
deliberately didn't index PaidAmount or TotalFee, because no query filters on
them and indexes cost write performance.

**How do you prevent SQL injection?**

Every statement is parameterised — no string concatenation anywhere. The update
endpoint was the interesting case, because partial updates normally tempt you
into building a dynamic SET clause. I used COALESCE on each column instead, so
the query text is fixed at author time and every value is a bound parameter.

**What happens if the email send fails?**

Both the HTTP call and the email action have an exponential retry policy — four
attempts starting at seven seconds. Exponential rather than fixed because
transient failures like connector throttling or a cold start usually clear within
seconds, and backing off gives the downstream service room rather than adding
load. If all four attempts fail, the Logic App run is marked failed and appears
in the run history. In production I'd add an alert on that.

**What if two admins update the same student at the same time?**

Last write wins. There's no optimistic concurrency control, which is a genuine
limitation I've documented. The fix is a RowVersion column exposed as an ETag,
with the client sending If-Match and the API returning 409 on conflict. I didn't
build it because the brief doesn't ask for it and it would have added surface
area, but it's the first thing I'd add for a real deployment of a financial
system.

**Why is the backend protected by a function key when APIM already authenticates?**

Defence in depth. APIM handles authentication and authorisation at the edge, but
if the Function App's URL leaked, the AuthLevel.FUNCTION requirement means it's
still unreachable — the key lives in an APIM named value. It also means there's
exactly one public entry point, which makes the security boundary easy to reason
about.

**Why does the Logic App bypass API Management?**

It's an internal Azure-to-Azure call. It doesn't need the gateway's subscription
key management, and routing machine traffic through APIM would consume the rate
limit budget that exists for client traffic. It authenticates with a function
key, which is the appropriate control for a service-to-service call.

**Why Consumption tiers throughout?**

The workload is intermittent — some API calls and one daily batch. Consumption
scales to zero and bills per execution, which fits the shape of the traffic.
Provisioned capacity would reserve compute that sits idle. The trade-off is cold
starts, which I've mitigated on the automated path with retry policies and would
mitigate in production with a Premium plan and pre-warmed instances if latency
mattered.

**What was hardest, or what went wrong?**

The token validation. My first policy pointed at the v2.0 OpenID metadata
endpoint, but the client credentials flow with a .default scope issues v1.0
tokens — different issuer claim, so validation failed even though the audience
and role were both correct. I decoded the token, saw ver 1.0 and the
sts.windows.net issuer, and pointed the policy at the v1 metadata document. The
lesson is that the token version has to match the discovery document you validate
against, and reading the actual token beats guessing.

**What would you do differently with more time?**

Managed identity for the SQL connection first, so there are no stored
credentials. Then the audit table, because financial data modification without a
record of who did it is hard to defend. Then optimistic concurrency on the update
endpoint. Those three are ordered by risk, not by effort.
