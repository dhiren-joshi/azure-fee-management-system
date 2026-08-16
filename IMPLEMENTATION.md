# Implementation Record

A step-by-step account of how the Fee Management System was built, including the
decisions taken at each point, the problems encountered, and how they were
resolved.

This document exists separately from the README because the README describes
*what* the system is and how to deploy it, while this describes *how it was
built* and *why each choice was made*. Where a problem was hit and fixed, both
the symptom and the root cause are recorded.

---

## Contents

1. [Planning and scoping](#1-planning-and-scoping)
2. [Task 1 — Data storage](#2-task-1--data-storage)
3. [Local development environment](#3-local-development-environment)
4. [Tasks 3 and 4 — Function implementation](#4-tasks-3-and-4--function-implementation)
5. [De-risking the email dependency](#5-de-risking-the-email-dependency)
6. [Deployment to Azure](#6-deployment-to-azure)
7. [Task 2 — Logic App automation](#7-task-2--logic-app-automation)
8. [Task 3 — API Management](#8-task-3--api-management)
9. [Task 4 — Entra ID and RBAC](#9-task-4--entra-id-and-rbac)
10. [Task 5 — Monitoring and retries](#10-task-5--monitoring-and-retries)
11. [Problems encountered and resolutions](#11-problems-encountered-and-resolutions)
12. [Assumptions register](#12-assumptions-register)
13. [Operational notes](#13-operational-notes)
14. [What would change in production](#14-what-would-change-in-production)

---

## 1. Planning and scoping

### Reading the brief

The assignment specifies five tasks and three deliverables. Read strictly, the
system needs:

- Two database tables with exactly the columns listed
- Three API endpoints (one for status, one for the reminder job, one for admin
  updates)
- One scheduled workflow
- One API gateway with keys and rate limiting
- One identity provider integration
- Monitoring and retry configuration

Everything beyond that is scope the brief does not ask for.

### Scope discipline

An initial design included a fee-update audit table, managed identity for the
SQL connection, keyset pagination on the list endpoint, a SQL view for status
calculation, a fourth "Pending" status, and a 5000-row seed.

All of it was removed before implementation. Reasoning: each addition is one
more thing to build, one more thing to explain in a 15-minute presentation, and
one more surface for something to break the night before submission. The brief
does not ask for any of them.

The removals are recorded in the README's design decisions and assumptions
sections, so the reasoning is visible rather than looking like an oversight.

### Ordering the work

The build order was chosen to put the riskiest dependency first:

1. Database — blocks everything downstream
2. Function code — testable locally before any cloud deployment
3. **Email connector test** — the only dependency outside Azure
4. Function App deployment
5. Logic App
6. API Management
7. Entra ID

Step 3 was deliberately pulled forward and run as a throwaway Logic App before
anything was built on top of it. Every other component is Azure-to-Azure and
predictable; the email connector needs an external mailbox and an OAuth consent
that could have failed for reasons outside the subscription. Discovering that at
the end would have been far more expensive than discovering it early.

---

## 2. Task 1 — Data storage

### Resource creation

A new SQL logical server `fee-management-dhiren-2026` was created in Central
India, with `FeeManagementDB` on it.

**Tier chosen:** General Purpose Serverless, with the free offer applied
(100,000 vCore seconds, 32 GB data, 32 GB backup per month).

**Why serverless:** the workload is intermittent — a handful of API calls and one
daily batch. Serverless scales compute to zero when idle and bills per vCore
second. Provisioned compute would reserve capacity that sits unused.

**Free offer overage behaviour:** set to *Auto-pause the database until next
month*. This guarantees the build cannot incur charges even if something loops
unexpectedly.

### Networking

Two settings on the server's Networking page:

| Setting | Value | Why |
|---|---|---|
| Allow Azure services and resources to access this server | Yes | Permits the Function App to connect once deployed |
| Client IP firewall rule | Added | Permits the Query editor and local development |

The first is the one most easily missed. Without it, everything works locally and
then fails immediately after deployment, because the Function App's outbound IP
is not in the firewall rules.

### Schema

Two tables, with exactly the columns the brief specifies and nothing else.

```sql
CREATE TABLE Students (
    StudentID   INT             NOT NULL PRIMARY KEY,
    Name        NVARCHAR(100)   NOT NULL,
    Course      NVARCHAR(100)   NOT NULL,
    TotalFee    DECIMAL(10, 2)  NOT NULL,
    PaidAmount  DECIMAL(10, 2)  NOT NULL DEFAULT 0,
    DueDate     DATE            NOT NULL
);

CREATE TABLE Administrators (
    AdminID     INT             NOT NULL PRIMARY KEY,
    Name        NVARCHAR(100)   NOT NULL,
    Role        NVARCHAR(50)    NOT NULL
);
```

**Type choices and their reasoning:**

- `DECIMAL(10,2)` for money, not `FLOAT`. Floating point introduces rounding
  error on currency; `DECIMAL` stores exact values. `(10,2)` allows up to
  99,999,999.99.
- `NVARCHAR` not `VARCHAR`. Unicode support for names.
- `DATE` not `DATETIME` for `DueDate`. There is no meaningful time-of-day
  component to a fee deadline, and comparing dates without a time component
  avoids off-by-one errors at midnight boundaries.
- `NOT NULL DEFAULT 0` on `PaidAmount`. A new student has paid nothing. `NULL`
  would break the `PaidAmount >= TotalFee` comparison, since `NULL` comparisons
  evaluate to unknown rather than false.
- `NOT NULL` on every column. There is no business case for a student without a
  course or a due date.

### Indexing

```sql
CREATE INDEX IX_Students_DueDate ON Students (DueDate);
```

The system has exactly two query patterns:

1. **Single-student lookup by ID** — served by the clustered primary key on
   `StudentID`. Already a B-tree seek, O(log n).
2. **Overdue scan by date** — `WHERE PaidAmount < TotalFee AND DueDate < today`.
   Without an index this is a full table scan. With the `DueDate` index, SQL
   Server can seek to the date range and evaluate the balance predicate only on
   the matching subset.

This is the concrete answer to the brief's requirement that the system "handle at
least 5000 student records efficiently". Two query patterns, two access paths,
both logarithmic rather than linear.

No index was added on `PaidAmount` or `TotalFee`. Indexes are not free — they
cost storage and slow writes. Adding them speculatively for queries the system
does not perform would be cargo-cult optimisation.

### Seed data

25 students and 3 administrators. The brief asks for at least 20.

**Due dates are relative, not hardcoded:**

```sql
CAST(DATEADD(day, -45, GETDATE()) AS DATE)
```

Using `DATEADD` against `GETDATE()` means the seed data always contains overdue
records regardless of when it is loaded. Hardcoded dates would go stale and the
demo would eventually show zero overdue students.

**Distribution is deliberate:**

| Students | Condition | Resulting status |
|---|---|---|
| 1–8 | `PaidAmount = TotalFee` | Paid |
| 9–17 | `PaidAmount < TotalFee`, date passed | Overdue |
| 18–25 | `PaidAmount < TotalFee`, date upcoming | Partially Paid |

All three statuses are represented, which means the API demo can show each one
without hunting for a suitable record.

**The seed script is re-runnable.** It begins with `DELETE FROM Students` and
`DELETE FROM Administrators`. During the demo, the admin PUT endpoint mutates
student 18; re-running the seed resets the data to a known state without
dropping and recreating the schema. This was rehearsed before recording.

**A verification query terminates the script:**

```sql
SELECT
    CASE
        WHEN PaidAmount >= TotalFee            THEN 'Paid'
        WHEN DueDate < CAST(GETDATE() AS DATE) THEN 'Overdue'
        ELSE 'Partially Paid'
    END AS PaymentStatus,
    COUNT(*) AS StudentCount
FROM Students
GROUP BY ...
```

This returned `Paid 8, Overdue 9, Partially Paid 8`, confirming the seed loaded
correctly and all three statuses exist before any application code was written.

### Data hygiene

One seed record was adjusted during review. Student 23 originally had
`PaidAmount = 0` with a future due date, which the status rule reports as
"Partially Paid" — technically correct given only three statuses are permitted,
but it reads as a bug when the row is visible on screen. The record was given a
genuine partial payment. The underlying edge case is documented in the
assumptions register rather than hidden.

Administrator names were also changed from placeholder values to neutral sample
names, since the seed data is visible in the submission.

---

## 3. Local development environment

### Toolchain

| Component | Version | Purpose |
|---|---|---|
| Python | 3.12 | Function runtime |
| Azure Functions Core Tools | 4.12.1 | Local host (`func start`) |
| ODBC Driver 18 for SQL Server | 64-bit | What `pyodbc` binds to |
| pyodbc | 5.3.0 (cp312 wheel) | Python DB-API driver |
| azure-functions | 1.25.0 | Programming model |

Python 3.12 was chosen deliberately over newer releases. The Azure Functions
Python worker supports specific versions, and the `pyodbc` wheel is built per
Python minor version (`cp312`). Matching the local version to the deployed
runtime removes a class of "works locally, fails in Azure" problems.

### Project structure

```
Fee_Management_Assignment/
├── functions/          <- VS Code workspace root
│   ├── .venv/
│   ├── function_app.py
│   ├── host.json
│   ├── local.settings.json
│   └── requirements.txt
└── sql/
```

**The workspace root must be `functions/`, not the parent.** The Azure Functions
extension looks for `host.json` at the workspace root; opening the parent folder
means the extension does not detect the project, `func start` finds nothing to
run, and terminal commands execute in the wrong directory. This caused several
failures during setup before it was corrected.

**The virtual environment must be named `.venv` and live inside `functions/`.**
That is the path the extension looks for when selecting an interpreter.

### Configuration

`local.settings.json` holds the SQL connection string. The file is local-only and
excluded from source control. The same key, `SqlConnectionString`, is set as an
application setting on the deployed Function App.

The code reads it via `os.environ["SqlConnectionString"]` — never hardcoded, and
the same code runs unchanged in both environments.

---

## 4. Tasks 3 and 4 — Function implementation

### Endpoint design

Three endpoints, which is the minimum that satisfies the brief:

| Route | Method | Task | Consumer |
|---|---|---|---|
| `/students/{studentId}` | GET | 3 | Students and admins |
| `/overdue-students` | GET | 2 | Logic App |
| `/students/{studentId}/fees` | PUT | 4 | Admins only |

The brief's functional requirements list "students view fee details", "admins
query student fee details", and "admins update fee records". The first two are
the same read operation with different callers, so one endpoint serves both
rather than duplicating logic behind two routes.

**Route naming note:** `/overdue-students` was chosen as a top-level route rather
than `/students/overdue`. The latter is more RESTful but risks ambiguity against
the `{studentId}` parameterised route. Avoiding that ambiguity was worth the
slightly less elegant path — a routing conflict discovered at 2am is expensive.

### The status calculation

```python
def get_payment_status(total_fee, paid_amount, due_date):
    if paid_amount >= total_fee:
        return "Paid"
    if due_date < date.today():
        return "Overdue"
    return "Partially Paid"
```

Four lines, and the core of the whole assignment.

**Where it lives:** in the Function, not the database. The brief states "use
Azure Functions for fee calculations and API logic", so this placement follows
the specification. It also means one implementation serves both the API and the
Logic App, so they cannot disagree about a student's status.

**Why the order matters:** the three statuses are not mutually exclusive. A
student who has paid in full but whose due date has passed satisfies both "paid"
and "past due". Checking `Paid` first establishes precedence — a fully settled
account is never reported as overdue.

The identical `CASE` expression appears in the seed verification query, which
means the SQL and Python agree by construction.

### Database access pattern

```python
conn = pyodbc.connect(CONNECTION_STRING)
try:
    ...
finally:
    conn.close()
```

Explicit `try`/`finally` rather than `with pyodbc.connect(...)`. The pyodbc
context manager commits on exit but does **not** close the connection — a subtle
behaviour that leaks connections under load. Being explicit is both correct and
easier to explain.

### The update endpoint

```sql
UPDATE Students
SET TotalFee   = COALESCE(?, TotalFee),
    PaidAmount = COALESCE(?, PaidAmount),
    DueDate    = COALESCE(?, DueDate)
WHERE StudentID = ?
```

`COALESCE` handles partial updates without building a dynamic `SET` clause. An
admin can send `{"paidAmount": 95000}` alone and the other two columns keep their
existing values.

**Security consequence:** because there is no string concatenation, every value
is passed as a bound parameter. This is the answer to "how do you handle SQL
injection" — the query text is fixed at author time and user input never becomes
part of it.

**Response design:** the endpoint returns the updated record, not just a success
message. This lets a caller confirm the new state in one round trip, and it makes
the demo stronger — the status visibly recalculates in the response.

### Authorisation level

All three functions use `AuthLevel.FUNCTION`:

```python
app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
```

The Function App cannot be called without a function key. API Management holds
that key, which makes APIM the only public entry point. Knowing the Function
App's URL is not sufficient to call it.

Note that `func start` ignores the auth level entirely — local development needs
no key, deployed calls do. This difference is expected and caused confusion
during the first deployment test.

### Error handling

| Condition | Response |
|---|---|
| Student not found | 404 with a message naming the ID |
| Body is not valid JSON | 400 |
| No updatable fields supplied | 400 naming the accepted fields |
| Success | 200 with the record |

Structured JSON errors rather than bare status codes, so a caller can act on the
response programmatically.

### Local verification

Eight test cases were run via a `.http` file before any cloud deployment:

| Request | Expected | Result |
|---|---|---|
| GET student 1 | Paid | Pass |
| GET student 9 | Overdue | Pass |
| GET student 18 | Partially Paid | Pass |
| GET student 999 | 404 | Pass |
| GET overdue-students | 9 records | Pass |
| PUT student 18, paidAmount 120000 | Status flips to Paid | Pass |
| PUT student 16, dueDate only | Other fields unchanged | Pass |
| PUT with empty body | 400 | Pass |

The seventh case is the one that proves `COALESCE` works: only the due date was
supplied, and `totalFee` and `paidAmount` retained their previous values.

---

## 5. De-risking the email dependency

Before building the real Logic App, a throwaway one (`logic-email-test`) was
created with only a Recurrence trigger and a single Send email action.

**Rationale:** the email connector is the only component of the system that
depends on something outside the Azure subscription. It needs an external
mailbox and an OAuth consent flow. Everything else is Azure-to-Azure and
behaves predictably. If the connector was going to fail, it needed to fail
early — not at the end, with the deadline approaching.

**Connector choice:** the brief permits SendGrid or Outlook.

SendGrid was rejected. The Azure Marketplace free tier has been deprecated, and
new SendGrid accounts require sender verification that can take hours to clear.
That is an unacceptable dependency with a fixed deadline.

Outlook was chosen. Two connector variants exist:

- **Office 365 Outlook** — requires a work or school Microsoft 365 account
- **Outlook.com** — accepts a personal Hotmail, Outlook or Live address

Neither accepts a Gmail address as the *sending* account. The Azure subscription
is registered to a Gmail address, so an Outlook.com account was used for the
connector. Gmail remains fine as a *recipient*.

**Result:** the test email delivered successfully. It landed in the Gmail spam
folder, which is expected behaviour for a newly created Outlook account's first
outbound message and does not indicate a fault. Marking it "not spam" once
resolves subsequent delivery.

Ten minutes spent here removed the largest single risk in the build.

---

## 6. Deployment to Azure

### Function App configuration

Created via the VS Code Azure extension using the **Advanced** flow, which
exposes prompts the basic flow hides.

| Prompt | Choice | Reasoning |
|---|---|---|
| Runtime stack | Python 3.12 | Matches local venv and the `cp312` pyodbc wheel |
| OS | Linux | Required for Python on Azure Functions |
| Hosting plan | **Consumption (Legacy)** | Well-documented, predictable. Flex Consumption is newer with different regional availability and deployment behaviour |
| Hostname format | **Global default (Legacy)** | Produces a clean predictable URL. The secure option appends a random tenant-scoped string, which is harder to type into APIM config and awkward on screen during a demo |
| Runtime storage auth | Secrets | Managed identity requires an additional RBAC role assignment on the storage account; a misconfiguration there prevents the app starting |
| Application Insights | **Create new** | Satisfies Task 5's monitoring requirement at provisioning time |
| Region | Central India | Co-located with the SQL database — lower latency, no cross-region egress |

The Application Insights prompt is the reason the Advanced flow was used. Saying
yes here wires the connection string into app settings automatically. Skipping it
means creating the resource separately and configuring instrumentation manually.

### Order of operations

The `SqlConnectionString` application setting was added **before** deploying the
code. Deploying first means the first invocation crashes reading an environment
variable that does not exist, which produces a confusing 500 and wastes a
deployment cycle diagnosing it.

### Verification

The deployed endpoint was called directly with its function key and returned the
expected record, confirming the full chain: Function App → Azure SQL → JSON
response.

---

## 7. Task 2 — Logic App automation

### Design choice: Logic App over Durable Function

The brief permits either.

**Logic App was chosen** because the workflow is a daily scheduled fan-out with
no complex state:

- The recurrence scheduler is configuration, not code
- The retry policy is a first-class setting on every action — which Task 5
  explicitly requires
- The email connector handles OAuth to the mailbox
- Run history is visually inspectable, which is valuable in a demo
- No code to maintain or deploy

**When a Durable Function would be better:** if the orchestration required
stateful coordination across steps, compensation logic on failure, or fan-out
with result aggregation. None of those apply here.

Being able to name the condition under which the other choice wins is more
useful than asserting one is universally better.

### Workflow structure

```
Recurrence (1 day)
    ↓
HTTP GET /api/overdue-students?code=<function key>
    ↓
Parse JSON (schema derived from a sample payload)
    ↓
For each (over Parse JSON body)
    └─ Send an email (V2)
```

**Why Parse JSON is present:** without it, the HTTP response is an untyped
string. Parse JSON applies a schema, which exposes `name`, `course`, `totalFee`,
`paidAmount`, `balance` and `dueDate` as selectable dynamic content inside the
loop. Without it, every field would need a hand-written expression.

**A subtle point in the For each configuration:** the loop iterates over the
**Parse JSON** body, not the **HTTP** body. Both appear in the dynamic content
picker and look interchangeable. Selecting the HTTP body would iterate raw text
and lose all the typed fields. This is easy to get wrong and hard to diagnose
afterwards.

**Why the Logic App calls the Function rather than querying SQL directly:** the
Logic App has a SQL connector and could query the database itself. Routing
through the Function endpoint instead keeps all data access and all status logic
in one layer. If the overdue rule ever changed, it changes in exactly one place.

### Email content

Each message is personalised with the student's name, course, total fee, amount
paid, outstanding balance and due date — all bound from the parsed JSON.

### Verification and an instructive result

The first run sent **8 emails**, where the endpoint had previously returned 9
overdue students.

This was investigated rather than assumed to be a bug. The cause: during local
testing, a PUT request had changed student 16's due date to 2026-12-31. That
student was therefore no longer overdue at the time the Logic App ran.

**The system behaved correctly.** The admin update took effect, the query
reflected the new state, and the loop processed exactly the students who
qualified. This is a useful demonstration that the admin endpoint has real
downstream consequences rather than just returning a 200.

---

## 8. Task 3 — API Management

### Tier selection

**Consumption tier.** The alternatives:

| Tier | Cost | Provisioning time |
|---|---|---|
| Consumption | Effectively free at this volume | 3–5 minutes |
| Developer | ~$50/month | 30–45 minutes |
| Basic and above | $150+/month | 30–45 minutes |

Consumption supports everything the brief requires: subscription keys, rate
limiting, and `validate-jwt`. It is serverless and bills per call.

### Import and correction

The Function App was imported directly, which creates the backend wiring and
stores the function key as a named value automatically.

**All three operations imported as POST.** APIM cannot read route metadata from
the Python v2 programming model, so it defaults every function to POST with the
function name as the path. Each operation was corrected:

| Operation | Method | URL template |
|---|---|---|
| `get_student_fee` | GET | `/students/{studentId}` |
| `get_overdue_students` | GET | `/overdue-students` |
| `update_student_fees` | PUT | `/students/{studentId}/fees` |

### Rate limiting

```xml
<rate-limit calls="5" renewal-period="60" />
```

Applied at the **All operations** scope, so it covers all three endpoints from
one place rather than being repeated three times.

**A tier-specific constraint was hit here.** The initial policy used
`rate-limit-by-key` with a counter-key expression. APIM rejected it:

```
Error in element 'rate-limit-by-key': Policy is not allowed in 'Consumption' sku
```

On the Consumption tier the supported policy is `rate-limit`, not
`rate-limit-by-key`. This turns out to be the better fit anyway — `rate-limit`
counts per subscription automatically, so each API key gets its own budget rather
than all callers sharing one global counter. No counter-key expression needed.

**Limit chosen:** 5 calls per minute. Deliberately low so that the 429 response
is easy to demonstrate on camera. A production limit would be far higher.

### Subscription key enforcement

Creating the API and applying policies does **not** by itself require a key. The
API must belong to a **Product** with **Requires subscription** enabled.

A product named `Fee Management Product` was created with:
- Published: yes
- Requires subscription: yes
- The Fee Management API added to it

**Note on the create form:** the APIs field on the product creation dialog did
not accept a selection. The reliable path is to create the product first, then
add the API from the product's own APIs page afterwards.

### Verification

| Test | Result |
|---|---|
| Call with no subscription key | 401 — "Access denied due to missing subscription key" |
| Call with key | 200 with the student record |
| Six rapid calls | 429 — "Rate limit is exceeded. Try again in 20 seconds." with a `Retry-After` header |

The 429 fired on the fourth request in one test rather than the sixth, because
earlier requests within the same 60-second window counted toward the limit. The
counter tracks all requests regardless of outcome — expected behaviour.

---

## 9. Task 4 — Entra ID and RBAC

### App registration

An application `fee-management-admin-api` was registered as **single tenant**.
Multi-tenant would allow other organisations to authenticate against the API,
which is not wanted and would be an odd choice to defend.

The Application ID URI was set to the default `api://<client-id>`. This value
becomes the `aud` (audience) claim in issued tokens and is what the APIM policy
validates against.

### The app role

```
Display name:         FeeAdmin
Value:                FeeAdmin
Allowed member types: Applications
```

**Allowed member types is the important choice here.** Options are Users,
Applications, or both.

**Applications** was chosen because it enables the client credentials flow — a
token can be obtained with a single scripted HTTP call and pasted into a test
console. A Users-type role would require an interactive browser sign-in, which is
awkward to perform mid-demo and adds a failure point to a recorded walkthrough.

### Granting the role

This step is easy to miss and produces a confusing failure if skipped: the app
role exists, but nothing has been granted it, so a valid token is issued
carrying no `roles` claim at all.

The grant path: **API permissions → Add a permission → select the app →
Application permissions → FeeAdmin → Add permissions → Grant admin consent**.

**A navigation note:** the application did not appear under the **My APIs** tab.
It was found under **APIs my organization uses**. The service principal is
registered there even when My APIs comes up empty.

The **Grant admin consent** button is the step that actually puts
`"roles": ["FeeAdmin"]` into the token.

### The validate-jwt policy

Applied to the `update_student_fees` operation **only**:

```xml
<validate-jwt header-name="Authorization"
              failed-validation-httpcode="401"
              failed-validation-error-message="Unauthorized. Admin access required.">
    <openid-config url="https://login.microsoftonline.com/{tenant-id}/.well-known/openid-configuration" />
    <audiences>
        <audience>api://{client-id}</audience>
    </audiences>
    <required-claims>
        <claim name="roles" match="any">
            <value>FeeAdmin</value>
        </claim>
    </required-claims>
</validate-jwt>
```

**Scoping matters.** Applying this at the All operations level would break the
two GET endpoints for students, who should need only a subscription key. Policy
scope in APIM is hierarchical, and putting the right policy at the right level is
the whole point of the two-tier model.

The result is a layered security model:

| Caller | Subscription key | Entra token with FeeAdmin |
|---|---|---|
| Student — read status | Required | Not required |
| Logic App — read overdue | Required | Not required |
| Admin — update fees | Required | Required |

Both checks happen at the APIM edge. An unauthorised request never reaches the
Function App.

### The token version problem

The first authenticated request returned 401 despite the token being valid and
carrying the correct role.

**Diagnosis:** decoding the token showed:

```json
"iss": "https://sts.windows.net/{tenant-id}/",
"ver": "1.0"
```

That is a **v1.0** issuer. The policy pointed at the **v2.0** OpenID metadata
document, which declares a different issuer value. Validation failed on issuer
mismatch — not on the audience or the role, both of which were correct.

**Cause:** the client credentials flow with a `.default` scope issues v1.0
tokens by default from this app registration.

**Two possible fixes:**

1. Edit the app manifest's `accessTokenAcceptedVersion` to force v2 tokens, then
   re-fetch a token
2. Point the policy at the v1 metadata endpoint by removing `/v2.0` from the URL

Option 2 was chosen — a single-character-class edit in one place, versus editing
JSON in the manifest, saving, and re-acquiring a token. Both are correct; the
principle is that the token version must match the discovery document used to
validate it.

### Verification

| Test | Result |
|---|---|
| PUT with no Authorization header | 401 — "Unauthorized. Admin access required." |
| PUT with an expired token | 401 |
| PUT with a valid FeeAdmin token | 200, record updated, status recalculated |

The final successful call updated student 18's `paidAmount` to 95,000, and the
response showed `balance` recalculated to 25,000 and `paymentStatus` changed from
"Paid" to "Partially Paid" — demonstrating authentication, authorisation, and the
fee calculation in a single response.

---

## 10. Task 5 — Monitoring and retries

### Application Insights

Created during Function App provisioning, which automatically sets
`APPLICATIONINSIGHTS_CONNECTION_STRING` in the app settings. No manual
instrumentation was required.

The Function code emits structured log entries at each significant point:

```python
logging.info("Fetching fee details for StudentID %s", student_id)
logging.info("Found %s overdue students", len(rows))
logging.info("Fee record updated for StudentID %s", student_id)
```

Application Insights captures requests, dependencies (including SQL calls),
exceptions and traces. It was used during the build to diagnose a failing
request, which is a more honest demonstration of its value than simply showing
that it exists.

`host.json` enables sampling with requests excluded, so request telemetry is
never sampled away while high-volume traces are.

### Retry policies

Applied to both actions in the Logic App:

| Setting | Value |
|---|---|
| Type | Exponential Interval |
| Count | 4 |
| Interval | PT7S |

**Why exponential rather than fixed:** transient failures — throttling, cold
starts, brief network faults — usually resolve within seconds. Exponential
backoff spaces retries increasingly far apart, giving the downstream service room
to recover rather than adding load to something already struggling.

**Why both actions:**

- The **HTTP** action can fail on a Function App cold start or a SQL wake-up
  exceeding the timeout. Both are transient and both are realistic in this
  serverless architecture.
- The **email** action can fail on connector throttling, which is a genuine risk
  when sending multiple messages in a tight loop.

---

## 11. Problems encountered and resolutions

Recorded because the diagnosis in each case is more instructive than the fix.

### Local environment

| Symptom | Root cause | Resolution |
|---|---|---|
| `ModuleNotFoundError: No module named 'pyodbc'` on `func start` | `pip install` ran without the venv activated, so packages installed globally. The Functions worker looks in `.venv/Lib/site-packages` | Activate the venv, reinstall, verify with `python -c "import pyodbc; print(pyodbc.__file__)"` — the path must contain `.venv` |
| `Worker runtime cannot be 'None'` | `local.settings.json` was malformed, so `FUNCTIONS_WORKER_RUNTIME` was never read despite being present in the file | The password had been pasted with the template's surrounding braces `{...}` intact, breaking the JSON. Braces are ODBC escaping syntax, not part of the value |
| `ModuleNotFoundError: No module named 'azure'` | The VS Code Run button executed `function_app.py` as a plain Python script | Azure Functions are never run that way. `func start` boots the host, which loads the module |
| `No job functions found` | The workspace root was the parent folder, not `functions/` | `host.json` must be at the workspace root for the extension to detect the project |
| Venv created in the wrong directory | Terminal was in the parent folder when `python -m venv` ran | `cd` into `functions/` first; verify with `dir` before creating |

### Azure resources

| Symptom | Root cause | Resolution |
|---|---|---|
| "No servers found in the selected resource group" | The simplified SQL create form filters servers by resource group | Either create a new server, or switch the resource group to match the existing server's |
| "Your subscription does not have access to create a server in the selected region" | East US unavailable on this subscription | Central India was used throughout, which also co-locates all resources |
| Query editor rejected Entra sign-in | No Microsoft Entra admin was configured on the SQL server | Use SQL authentication with the server admin credentials |
| `renderComponentIntoRoot` error loading the Logic App designer | Stale portal session token after several hours | Sign out and back in, or use a fresh browser session |
| Logic App retry policy dropdown greyed out | Same stale session | Resolved after re-authenticating |

### API Management

| Symptom | Root cause | Resolution |
|---|---|---|
| `Policy is not allowed in 'Consumption' sku` | `rate-limit-by-key` is unsupported on the Consumption tier | Use `rate-limit`, which counts per subscription automatically |
| All operations imported as POST | APIM cannot read route metadata from the Python v2 model | Correct method and URL template on each operation manually |
| API callable without a key | The API was not attached to a product requiring a subscription | Create a product with "Requires subscription" enabled and add the API to it |
| 500 with an empty body on GET | The serverless SQL database had auto-paused; the wake-up exceeded the backend timeout | Transient. Warm the database with a direct call before demonstrating |
| 500 on PUT | The APIM test console does not automatically set `Content-Type: application/json`, so `req.get_json()` failed | Add the header explicitly |
| 401 on PUT with a seemingly valid token | Token had expired — tokens are valid for 60 minutes | Re-acquire before testing |
| 401 on PUT with a fresh valid token | Issuer mismatch: v1.0 token validated against v2.0 metadata | Remove `/v2.0` from the `openid-config` URL |

### Entra ID

| Symptom | Root cause | Resolution |
|---|---|---|
| App absent from the "My APIs" tab | Applications do not always list themselves there | Use the "APIs my organization uses" tab |
| Token issued without a `roles` claim | The app role existed but had not been granted | Add the application permission, then click **Grant admin consent** |

---

## 12. Assumptions register

Each assumption records a genuine gap or ambiguity in the brief, the decision
taken, and what a production implementation would do differently.

### A1 — No email address in the schema

**Gap:** Task 2 requires sending email reminders. Task 1 specifies the `Students`
table as `(StudentID, Name, Course, TotalFee, PaidAmount, DueDate)`. There is no
contact column, so there is nobody to send to.

**Decision:** keep the six specified columns exactly as written. Reminders are
sent to a single configured mailbox, personalised with each student's details.

**Rationale:** the brief specifies the schema explicitly. Adding a column would
deviate from a stated requirement in order to satisfy another. Documenting the
conflict is more honest than silently resolving it.

**Production:** add an `Email NVARCHAR(255)` column to `Students` and bind the
connector's recipient field to it.

### A2 — The three statuses do not cover every case

**Gap:** Task 3 specifies returning "Paid", "Partially Paid" or "Overdue". A
student who has paid nothing and whose due date has not yet passed fits none of
them — they are not paid, not partially paid, and not overdue.

**Decision:** return "Partially Paid" as the fall-through case, and document it.

**Rationale:** the brief permits exactly three values. Introducing a fourth would
break a stated contract.

**Production:** add a distinct "Pending" status. The precedence chain becomes
Paid → Overdue → Partially Paid → Pending.

**Note:** the seed data was adjusted so no record exhibits this case on screen,
while the underlying ambiguity remains documented here.

### A3 — No relationship between the two tables

**Gap:** Task 1 specifies `Students` and `Administrators` but defines no foreign
key, and neither table contains a column referencing the other.

**Decision:** create both tables exactly as specified, with no relationship.

**Rationale:** the real relationship is many-to-many — any administrator may act
on any student record — which cannot be expressed without a third table the brief
does not ask for. Entra ID is the authorisation source of truth; the
`Administrators` table records the roster, with `Role` values matching the Entra
app role names.

**Production:** add a `FeeUpdateHistory` table holding `AdminID`, `StudentID`,
old and new values, and a timestamp. This models the relationship correctly and
provides an audit trail.

### A4 — Runtime storage authentication

**Gap:** the Function App must authenticate to its own runtime storage account.

**Decision:** connection-string authentication.

**Rationale:** managed identity requires an additional RBAC role assignment on
the storage account. A misconfiguration there prevents the Function App starting,
with an unhelpful error message.

**Production:** system-assigned managed identity for both the runtime storage
account and the SQL connection, eliminating stored credentials entirely. For SQL
this means `CREATE USER [app-name] FROM EXTERNAL PROVIDER` and granting the
appropriate role.

### A5 — Scalability is demonstrated by design, not by volume

**Gap:** the brief requires the system to "handle at least 5000 student records
efficiently" but also specifies seeding "at least 20 students".

**Decision:** seed 25 records, and address scalability through the access paths.

**Rationale:** the two requirements pull in different directions. Efficiency at
5000 records is a property of the indexing and query design, not of how many rows
happen to be loaded. The system has two query patterns; both are served by an
index and neither degrades linearly with table size.

**Production:** add pagination to the overdue endpoint, since returning an
unbounded array becomes impractical at scale, and reuse the database connection
at module scope rather than opening one per invocation.

---

## 13. Operational notes

Behaviours specific to the serverless tiers used here, recorded because they
affect how the system is demonstrated.

**Serverless SQL auto-pauses when idle.** The first request after a quiet period
takes 20–60 seconds while the database resumes. This can appear as a timeout or a
500 through APIM. Before any demonstration, issue one warm-up request.

**Function App cold start.** Consumption plan instances are deallocated after
roughly 20 minutes idle. The first invocation after that includes container
startup time.

**Function keys are per-function.** The key for `get_student_fee` does not
authorise `get_overdue_students`. Host keys authorise all functions in the app.
Using the wrong one produces a 401 that looks like an authentication bug.

**Entra tokens expire after 60 minutes.** Re-acquire before demonstrating.

**The APIM test console does not set `Content-Type`.** Any operation with a
request body needs the header added explicitly.

**Client-side IP addresses change.** The SQL firewall rule is pinned to a
specific IP. If local development stops working after a router restart, re-add
the current address.

---

## 14. What would change in production

Ordered by importance rather than effort.

**Managed identity everywhere.** No connection strings, no client secrets. The
Function App authenticates to SQL and to storage with its system-assigned
identity. This removes the entire class of leaked-credential risk.

**Audit trail.** A `FeeUpdateHistory` table capturing which administrator changed
which record, from what value to what value, and when. Financial data
modification without an audit trail is difficult to defend.

**Email address on the student record**, resolving assumption A1.

**Pagination on the overdue endpoint.** Returning an unbounded array does not
scale, and the Logic App's For-each loop would need batching alongside it.

**Connection reuse.** Opening a connection per invocation is acceptable at this
volume but wasteful. A module-scope connection with proper lifecycle handling
would reduce latency under load.

**A fourth payment status**, resolving assumption A2.

**Key Vault** for any remaining secrets, with the Function App reading them via
Key Vault references rather than plain app settings.

**Staging slots** for the Function App, so deployments can be validated before
taking production traffic.

**Alert rules** on Application Insights — failure rate, response time, and
dependency failures — routed to an on-call channel rather than relying on someone
opening the portal.
