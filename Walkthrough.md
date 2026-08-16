# Complete Project Walkthrough

Everything about this project, from the first reading of the brief to the final
push. Written to be studied before the panel, not submitted to it.

If you can explain every section below in your own words, you can answer anything
they ask.

---

## Contents

**Part 1** — [What the system does](#part-1--what-the-system-does)
**Part 2** — [The five tasks and how each is satisfied](#part-2--the-five-tasks-and-how-each-is-satisfied)
**Part 3** — [Chronological build log](#part-3--chronological-build-log)
**Part 4** — [The code, line by line](#part-4--the-code-line-by-line)
**Part 5** — [Every Azure resource and why it's configured that way](#part-5--every-azure-resource-and-why-its-configured-that-way)
**Part 6** — [Complete request flows, traced end to end](#part-6--complete-request-flows-traced-end-to-end)
**Part 7** — [Every problem hit and how it was diagnosed](#part-7--every-problem-hit-and-how-it-was-diagnosed)
**Part 8** — [Every decision and its justification](#part-8--every-decision-and-its-justification)
**Part 9** — [Things you must be able to say without hesitating](#part-9--things-you-must-be-able-to-say-without-hesitating)

---

# Part 1 — What the system does

## The one-sentence version

A cloud-native system that stores student fee records in Azure SQL, exposes them
through a secured API, and emails reminders to students whose payments are
overdue.

## The 60-second version

There are **two flows** and nothing else.

**Flow one is synchronous.** A client makes an HTTP request. It hits Azure API
Management first, which checks the caller has a valid subscription key, checks
they haven't exceeded the rate limit, and — if they're trying to modify data —
validates an Entra ID token and confirms it carries the `FeeAdmin` role. Only
then does the request reach the Azure Function, which queries or updates Azure
SQL and returns JSON.

**Flow two is asynchronous.** Once a day, a Logic App wakes up, calls the
Function App's overdue endpoint, gets back a list of students with outstanding
balances past their due date, and sends each one a personalised reminder email.

Everything else in the architecture — the gateway, the identity provider, the
telemetry, the retry policies — exists to make those two flows secure,
observable and reliable.

## Why it's built the way it is

The brief asks for six Azure services. Rather than treating that as a checklist,
the design gives each service exactly one responsibility:

| Service | Owns |
|---|---|
| Azure SQL | Durable storage and indexed retrieval |
| Azure Functions | Business logic — the fee status calculation — and data access |
| API Management | Authentication, authorisation, rate limiting, routing |
| Entra ID | Identity and role assignment |
| Logic Apps | Scheduling, iteration, email delivery |
| Application Insights | Telemetry |

No component does two jobs. That's why the whole thing can be explained in a
minute.

---

# Part 2 — The five tasks and how each is satisfied

## Task 1 — Data Storage

**What the brief asked for:** An Azure SQL Database with a `Students` table
(StudentID, Name, Course, TotalFee, PaidAmount, DueDate) and an `Administrators`
table (AdminID, Name, Role), populated with at least 20 students.

**What was built:**

`FeeManagementDB` on the server `fee-management-dhiren-2026`, General Purpose
Serverless tier with the free offer applied.

Two tables with exactly the specified columns — nothing added, nothing renamed.

One index: `IX_Students_DueDate` on `Students(DueDate)`.

25 students and 3 administrators seeded, with due dates set relative to
`GETDATE()` so the data never goes stale.

**How to demonstrate it:** run the verification query at the bottom of
`02_seed.sql`. It returns Paid 8, Overdue 9, Partially Paid 8 — proving all three
statuses exist in the data before any application code runs.

## Task 2 — Automation

**What the brief asked for:** A Logic App or Durable Function that fetches
overdue students and sends email reminders via SendGrid or Outlook.

**What was built:**

`logic-fee-reminders`, a Consumption-tier Logic App with four steps:

1. **Recurrence** — every 1 day
2. **HTTP** — GET `/api/overdue-students` with a function key
3. **Parse JSON** — applies a schema so the response becomes typed fields
4. **For each** — iterates the array, sending an email per student

Emails go via the Outlook.com connector and are personalised with each student's
name, course, total fee, amount paid, outstanding balance and due date.

**How to demonstrate it:** Logic App → Run history → click the latest run →
expand For each → shows 8 iterations. Then show the delivered emails in the
inbox.

## Task 3 — Payment Status API

**What the brief asked for:** An Azure Function that fetches fee details by
StudentID and returns "Paid", "Partially Paid" or "Overdue". Expose it through
API Management with rate limiting and API key authentication.

**What was built:**

`GET /students/{studentId}` returning the record plus a calculated
`paymentStatus`.

Exposed through `apim-fee-management-dhiren` on the Consumption tier, with:

- A **Product** (`Fee Management Product`) with "Requires subscription" enabled —
  this is what makes the subscription key mandatory
- A **rate-limit policy** at the API scope: 5 calls per 60 seconds

**How to demonstrate it:**

- Call students 1, 9 and 18 — shows all three statuses
- Call six times rapidly — the sixth returns 429 with a `Retry-After` header
- Call the URL in a browser with no key — returns 401 "Access denied due to
  missing subscription key"

## Task 4 — Secure Updates for Administrators

**What the brief asked for:** An API endpoint for admins to update fee records,
secured with Azure AD authentication and role-based access control.

**What was built:**

`PUT /students/{studentId}/fees`, protected by a `validate-jwt` policy applied to
**that operation only**.

The Entra app registration `fee-management-admin-api` defines a `FeeAdmin` app
role of type **Applications**. The policy checks three things on every request:
the token signature (against Entra's published metadata), the audience (must
match the app's ID URI), and the `roles` claim (must contain `FeeAdmin`).

**How to demonstrate it:**

- PUT with no Authorization header → 401 "Unauthorized. Admin access required."
- PUT with a valid FeeAdmin token → 200, record updated, status recalculated
- GET the record again → confirms the change persisted

## Task 5 — Scalability and Monitoring

**What the brief asked for:** Application Insights for monitoring, and retry
policies for Logic Apps.

**What was built:**

Application Insights provisioned alongside the Function App, capturing requests,
dependencies (including SQL calls), exceptions and custom traces. The Function
code logs at each significant point.

Retry policies on **both** Logic App actions — the HTTP call and the email send —
configured as exponential interval, 4 attempts, PT7S starting interval.

**How to demonstrate it:** Logic App → HTTP action → Settings → shows the retry
config. Then Application Insights → Live Metrics or Failures.

---

# Part 3 — Chronological build log

This is what actually happened, in order.

## Phase 0 — Reading the brief and scoping

The first design was over-engineered. It included a fee-update audit table,
managed identity for the SQL connection, keyset pagination on the list endpoint,
a SQL view duplicating the status calculation, a fourth "Pending" status, and a
5000-row seed.

**All of it was cut before a line of code was written.** The reasoning: the brief
doesn't ask for any of it, and each addition is one more thing to build, explain
in a 15-minute presentation, and debug under deadline pressure.

Every cut is documented in the assumptions register, so the reasoning is visible
rather than looking like something was overlooked.

**The build order was chosen to front-load risk:**

1. Database — blocks everything
2. Function code — testable locally
3. **Email connector** — the only dependency outside Azure
4. Function App deployment
5. Logic App
6. API Management
7. Entra ID

Step 3 was deliberately pulled forward.

## Phase 1 — SQL schema and seed data

Two scripts written and split deliberately:

- `01_schema.sql` — DDL, run once
- `02_seed.sql` — DML, re-runnable

The split matters because the demo mutates student 18 via the admin endpoint.
Re-running the seed resets the data without dropping the schema. This was
rehearsed before recording.

**Two data-hygiene fixes during review:**

Student 23 originally had `PaidAmount = 0` with a future due date, which reports
as "Partially Paid" — correct per the three permitted statuses, but it looks like
a bug when the row is on screen. Given a genuine partial payment instead. The
underlying edge case stayed documented.

Administrator names were changed from the recruiter's actual name to neutral
sample names.

## Phase 2 — Function code

Three endpoints written in the Python v2 programming model. Design decisions
covered in Part 4.

## Phase 3 — Local environment

The most frustrating phase, and the source of five separate failures — all
environmental, none to do with the code. Full detail in Part 7.

Once working, eight test cases ran green against the live Azure SQL database from
a local Functions host.

## Phase 4 — Email connector de-risking

A throwaway Logic App (`logic-email-test`) built with just a Recurrence trigger
and one Send email action.

**First attempt picked the Zoho Mail connector by mistake** — the brief specifies
SendGrid or Outlook. Corrected to Outlook.com.

**SendGrid was rejected deliberately:** the Azure Marketplace free tier is
deprecated and new accounts need sender verification that can take hours. Not an
acceptable dependency against a fixed deadline.

**Office 365 Outlook vs Outlook.com:** neither accepts a Gmail address as the
*sending* account. The Azure subscription is registered to Gmail, so an
Outlook.com account was used. Gmail is fine as a *recipient*.

Test email delivered. It landed in spam — normal for a new Outlook account's
first outbound message, not a fault.

**Ten minutes here removed the largest single risk in the build.**

## Phase 5 — Function App deployment

Created via the VS Code **Advanced** flow, because the basic flow hides the
Application Insights prompt.

Eleven prompts, each answered deliberately — full table in Part 5.

**Critical ordering:** the `SqlConnectionString` app setting was added *before*
deploying. Deploy first and the first invocation crashes reading a missing
environment variable.

Deployed in 21 seconds. Verified with a direct call returning Aarav Sharma.

## Phase 6 — Logic App

Built the real workflow. Two subtleties:

**The For each loop iterates the Parse JSON body, not the HTTP body.** Both appear
in the dynamic content picker and look interchangeable. Choosing the HTTP body
would iterate raw text and lose every typed field.

**The Logic App calls the Function endpoint rather than querying SQL directly.**
It has a SQL connector and could. Routing through the Function keeps the overdue
rule in exactly one place.

**First run sent 8 emails where 9 were expected.** Investigated rather than
assumed to be a bug: an earlier PUT during local testing had changed student 16's
due date to 2026-12-31, so they were no longer overdue. **The system behaved
correctly** — and it's a good demonstration that the admin endpoint has real
downstream consequences.

Retry policies added last: exponential, 4 attempts, PT7S, on both actions.

## Phase 7 — API Management

Consumption tier chosen. Developer tier costs ~$50/month and takes 40 minutes to
provision.

Function App imported directly, which wires the backend and stores the function
key as a named value automatically.

**All three operations imported as POST** — APIM can't read route metadata from
the Python v2 model. Each was corrected to the right method and URL template.

**Rate limiting hit a tier constraint.** The first policy used
`rate-limit-by-key`, which APIM rejected: *"Policy is not allowed in
'Consumption' sku."* Switched to `rate-limit`, which turns out to be the better
fit — it counts per subscription automatically.

**Key enforcement needed a Product.** Applying policies alone doesn't require a
key. The API must belong to a Product with "Requires subscription" enabled.
Verified with a 401 from a keyless browser call.

## Phase 8 — Entra ID

App registration, Application ID URI, `FeeAdmin` app role of type Applications,
client secret, admin consent, `validate-jwt` policy on the PUT operation only.

**The hardest debugging of the build was here.** A valid token with the correct
role still returned 401. Full diagnosis in Part 7 — it came down to token version
mismatch between v1.0 issuance and v2.0 metadata.

Final verification: 401 without a token, 200 with one, record updated and status
recalculated from Paid to Partially Paid.

## Phase 9 — Documentation and repository

Four documents written, an architecture diagram generated, a `.gitignore` created
and verified against a simulated repo, and the code pushed to a private GitHub
repository with a secret scan confirming no credentials were committed.

---

# Part 4 — The code, line by line

The whole application is one file, `function_app.py`, about 150 lines. Here is
every meaningful part of it and why it's written that way.

## The app declaration

```python
app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
```

`AuthLevel.FUNCTION` means every endpoint requires a function key. The Function
App cannot be called by anyone who merely knows its URL.

API Management holds that key. This makes APIM the **only** public entry point,
which is what makes the security boundary easy to reason about.

Note: `func start` ignores this locally. No key is needed in development, every
key is needed once deployed. Expect that difference.

## Configuration

```python
CONNECTION_STRING = os.environ["SqlConnectionString"]
```

Read from the environment, never hardcoded. The same code runs unchanged locally
(reading `local.settings.json`) and in Azure (reading an application setting).

Using `os.environ[...]` rather than `os.environ.get(...)` is deliberate — if the
setting is missing, the app fails loudly at startup rather than silently at the
first database call.

## The status calculation — the heart of the assignment

```python
def get_payment_status(total_fee, paid_amount, due_date):
    if paid_amount >= total_fee:
        return "Paid"
    if due_date < date.today():
        return "Overdue"
    return "Partially Paid"
```

Four lines, and the single most important function in the system.

**Why it's in the Function and not the database:** the brief specifies using
Azure Functions for fee calculations. Beyond that, both the API and the Logic App
need this status. One implementation means they cannot disagree.

**Why the order matters:** the three statuses are not mutually exclusive. A
student who has paid in full but whose due date has passed satisfies both "paid"
and "past due". Checking `Paid` first establishes precedence — a settled account
is never reported as overdue.

**Where else this rule appears:** the identical `CASE` expression is at the
bottom of `02_seed.sql`. That means the seed verification and the running
application agree by construction, not by coincidence.

## Response helpers

```python
def json_response(payload, status_code=200):
    return func.HttpResponse(
        json.dumps(payload),
        status_code=status_code,
        mimetype="application/json",
    )
```

One place that builds responses, so the content type and serialisation are
consistent across all three endpoints.

```python
def student_to_dict(row):
    return {
        "studentId": row.StudentID,
        ...
        "balance": float(row.TotalFee - row.PaidAmount),
        "paymentStatus": get_payment_status(row.TotalFee, row.PaidAmount, row.DueDate),
    }
```

One place that shapes a database row into API output. `balance` is derived here
rather than stored, so it can never drift from `TotalFee - PaidAmount`.

**A known nuance:** `float()` converts an exact `Decimal` to binary floating
point. Fine for display, but it means the JSON isn't byte-exact for money.
Production would serialise as a string or use a decimal-aware encoder. Worth
knowing if asked.

## Endpoint 1 — Get student fee

```python
@app.route(route="students/{studentId:int}", methods=["GET"])
def get_student_fee(req: func.HttpRequest) -> func.HttpResponse:
    student_id = int(req.route_params.get("studentId"))
```

The `:int` route constraint means a non-numeric ID never reaches the handler —
the runtime rejects it. Input validation at the routing layer.

```python
    conn = pyodbc.connect(CONNECTION_STRING)
    try:
        row = conn.cursor().execute(
            "SELECT StudentID, Name, Course, TotalFee, PaidAmount, DueDate "
            "FROM Students WHERE StudentID = ?",
            student_id,
        ).fetchone()
    finally:
        conn.close()
```

**Explicit `try`/`finally` rather than `with pyodbc.connect(...)`.** The pyodbc
context manager commits on exit but does *not* close the connection — a subtle
behaviour that leaks connections under load. Being explicit is both correct and
easier to defend.

**Parameterised query.** The `?` placeholder with the value passed separately.
The query text is fixed at author time; user input never becomes part of it.

```python
    if row is None:
        return json_response({"error": f"Student {student_id} not found"}, 404)
```

404 with a structured error, not a bare status code.

## Endpoint 2 — Overdue students

```python
"SELECT ... FROM Students "
"WHERE PaidAmount < TotalFee AND DueDate < CAST(GETDATE() AS DATE) "
"ORDER BY DueDate"
```

Two predicates: outstanding balance **and** past due. `CAST(GETDATE() AS DATE)`
strips the time component so the comparison is date-to-date.

`ORDER BY DueDate` means the most overdue students come first — a small thing,
but it makes the output readable and the emails sensibly ordered.

This is the query `IX_Students_DueDate` exists to serve.

## Endpoint 3 — Admin update

```python
    try:
        body = req.get_json()
    except ValueError:
        return json_response({"error": "Request body must be valid JSON"}, 400)
```

`get_json()` raises `ValueError` if the body isn't JSON or the content type is
wrong. Caught and turned into a 400 rather than an unhandled 500.

*(This is the code path that produced the 500 through APIM until the
`Content-Type` header was added — see Part 7.)*

```python
    if total_fee is None and paid_amount is None and due_date is None:
        return json_response(
            {"error": "Provide at least one of: totalFee, paidAmount, dueDate"}, 400
        )
```

An empty body is rejected with a message naming the accepted fields. Useful
errors, not just correct ones.

```python
        cursor.execute(
            "UPDATE Students "
            "SET TotalFee   = COALESCE(?, TotalFee), "
            "    PaidAmount = COALESCE(?, PaidAmount), "
            "    DueDate    = COALESCE(?, DueDate) "
            "WHERE StudentID = ?",
            total_fee, paid_amount, due_date, student_id,
        )
```

**This is the cleverest part of the codebase and worth being able to explain.**

Partial updates normally tempt you into building a dynamic `SET` clause —
concatenating column names based on which fields were supplied. That's how SQL
injection vulnerabilities get written.

`COALESCE(?, ColumnName)` returns the parameter if it isn't null, and the
existing column value if it is. So sending `{"paidAmount": 95000}` alone updates
only that column, with no string building, and every value still passed as a
bound parameter.

```python
        if cursor.rowcount == 0:
            return json_response({"error": f"Student {student_id} not found"}, 404)

        conn.commit()
```

`rowcount` checked **before** committing. If no rows matched, return 404 with
nothing written.

```python
        row = cursor.execute(
            "SELECT ... FROM Students WHERE StudentID = ?", student_id
        ).fetchone()
```

Re-select after commit and return the updated record. The caller confirms the new
state and the recalculated status in one round trip — and it makes the demo
stronger, because the status visibly changes in the response.

---

# Part 5 — Every Azure resource and why it's configured that way

All in resource group `rg-fee-management`, region **Central India**.

Everything is co-located. Cross-region calls add latency and, for some services,
egress cost.

## Azure SQL Database

| Setting | Value | Why |
|---|---|---|
| Server | `fee-management-dhiren-2026` | New server, so all assignment resources are self-contained |
| Database | `FeeManagementDB` | |
| Tier | General Purpose **Serverless** | Workload is intermittent — scales compute to zero when idle |
| Free offer | Applied | 100,000 vCore seconds, 32 GB data, 32 GB backup per month |
| Overage behaviour | **Auto-pause until next month** | Makes runaway cost structurally impossible, not merely unlikely |
| Allow Azure services | **Yes** | This is what lets the Function App connect once deployed |
| Client IP firewall rule | Added | For the Query editor and local development |

**The "Allow Azure services" toggle is the one most easily missed.** Without it
everything works locally and fails immediately after deployment, because the
Function App's outbound IP isn't in the firewall rules.

## Function App

| Prompt | Answer | Reasoning |
|---|---|---|
| Runtime stack | **Python 3.12** | Matches the local venv and the `cp312` pyodbc wheel |
| OS | **Linux** | Required for Python on Azure Functions |
| Hosting plan | **Consumption (Legacy)** | Well-documented and predictable. Flex Consumption is newer with different regional availability and deployment behaviour |
| Hostname format | **Global default (Legacy)** | Clean predictable URL. The secure option appends a random tenant-scoped string — harder to type into APIM config, awkward on screen |
| Runtime storage auth | **Secrets** | Managed identity needs an extra RBAC assignment on the storage account; misconfiguration prevents the app starting |
| Application Insights | **Create new** | Satisfies Task 5 at provisioning time and wires the connection string automatically |

**Application setting:** `SqlConnectionString`, added *before* deployment.

## API Management

| Setting | Value | Why |
|---|---|---|
| Tier | **Consumption** | Provisions in minutes, effectively free at this volume. Developer is ~$50/month and 40 minutes |
| API import | From Function App | Wires the backend and stores the function key as a named value |
| Product | `Fee Management Product` | With **Requires subscription** — this is what enforces the API key |
| Rate limit | `rate-limit calls="5" renewal-period="60"` | Applied at **All operations** scope |
| JWT validation | `validate-jwt` | Applied at **update_student_fees** scope only |

**Policy scope is the design point.** The rate limit sits at API level so it
covers everything. The JWT check sits at operation level so it covers only the
admin write. Putting the JWT check at API level would break student reads.

## Entra ID

| Setting | Value | Why |
|---|---|---|
| Account types | **Single tenant** | Multi-tenant would let other organisations authenticate — not wanted |
| Application ID URI | `api://<client-id>` | Becomes the `aud` claim the policy validates |
| App role | `FeeAdmin` | |
| Allowed member types | **Applications** | Enables client credentials flow — scriptable, no interactive sign-in |
| Client secret | 6 months | |
| Admin consent | **Granted** | This is what puts `"roles": ["FeeAdmin"]` into the token |

**Applications rather than Users is a deliberate choice.** A user-type role would
require an interactive browser sign-in, which is awkward mid-demo and adds a
failure point to a recording. Client credentials means one scripted HTTP call.

## Logic App

| Setting | Value | Why |
|---|---|---|
| Plan | **Consumption (Multi-tenant)** | Pay per execution. Standard runs on an always-on App Service plan |
| Trigger | Recurrence, 1 day | |
| Retry policy | Exponential, 4 attempts, PT7S | On **both** the HTTP and email actions |

**Why exponential rather than fixed:** transient failures — throttling, cold
starts, brief network faults — usually clear within seconds. Backing off
increasingly gives a struggling downstream service room to recover instead of
adding load.

**Why both actions:** the HTTP call can fail on a Function App cold start or a
SQL wake-up. The email action can fail on connector throttling when sending
several messages in a tight loop. Both are realistic in this architecture.

---

# Part 6 — Complete request flows, traced end to end

## Flow A — A student checks their payment status

```
1.  Client sends:
      GET https://apim-fee-management-dhiren.azure-api.net/
          fee-management-api-dhiren/students/1
      Header: Ocp-Apim-Subscription-Key: <key>

2.  APIM inbound pipeline:
      a. Product requires subscription → key checked against the subscription
         → missing or invalid = 401, request terminated
      b. rate-limit policy → is this subscription under 5 calls/60s?
         → exceeded = 429 with Retry-After, request terminated
      c. set-backend-service → route to the Function App backend
      d. Function key injected from the APIM named value

3.  Function App:
      a. Route matched: students/{studentId:int}
         → non-numeric ID would never reach the handler
      b. AuthLevel.FUNCTION → function key validated
      c. Handler get_student_fee() invoked
      d. logging.info("Fetching fee details for StudentID 1")

4.  Azure SQL:
      SELECT ... FROM Students WHERE StudentID = ?
      → clustered PK seek, O(log n)
      → 1 row returned

5.  Function App:
      a. row is not None → proceed
      b. student_to_dict(row):
           - balance = TotalFee - PaidAmount
           - paymentStatus = get_payment_status(120000, 120000, 2026-07-01)
             → paid_amount >= total_fee → "Paid"
      c. json_response(payload, 200)

6.  Telemetry:
      Application Insights records the request, the SQL dependency call,
      and the custom trace

7.  Response travels back through APIM to the client:
      200 OK
      {"studentId": 1, "name": "Aarav Sharma", ..., "paymentStatus": "Paid"}
```

## Flow B — An administrator updates a fee record

```
1.  Admin obtains a token:
      POST https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token
      Body: client_id, client_secret, scope=api://<client-id>/.default,
            grant_type=client_credentials

    Entra ID returns a JWT containing:
      aud   : api://<client-id>
      iss   : https://sts.windows.net/<tenant-id>/
      roles : ["FeeAdmin"]
      exp   : now + 60 minutes

2.  Admin sends:
      PUT .../students/18/fees
      Ocp-Apim-Subscription-Key: <key>
      Authorization: Bearer <jwt>
      Content-Type: application/json
      {"paidAmount": 95000}

3.  APIM inbound pipeline:
      a. Subscription key checked        → 401 if missing
      b. Rate limit checked              → 429 if exceeded
      c. validate-jwt:
           - signature verified against Entra's published JWKS
           - aud must equal api://<client-id>
           - roles must contain "FeeAdmin"
         → any failure = 401 "Unauthorized. Admin access required."
           and the request never reaches compute
      d. Route to backend with function key

4.  Function App — update_student_fees():
      a. req.get_json() → {"paidAmount": 95000}
         (fails with ValueError if Content-Type is absent → 400)
      b. total_fee = None, paid_amount = 95000, due_date = None
      c. Not all three None → proceed

5.  Azure SQL:
      UPDATE Students
      SET TotalFee   = COALESCE(NULL, TotalFee),      -- unchanged
          PaidAmount = COALESCE(95000, PaidAmount),   -- updated
          DueDate    = COALESCE(NULL, DueDate)        -- unchanged
      WHERE StudentID = 18

      cursor.rowcount = 1 → not 0, so no 404
      conn.commit()

      SELECT ... WHERE StudentID = 18  -- re-read the updated row

6.  Function App:
      student_to_dict(row):
        - balance = 120000 - 95000 = 25000
        - get_payment_status(120000, 95000, 2026-08-20)
            95000 >= 120000?           No
            2026-08-20 < today?        No
            → "Partially Paid"

7.  Response:
      200 OK
      {
        "message": "Fee record updated for student 18",
        "student": { ..., "balance": 25000.0,
                     "paymentStatus": "Partially Paid" }
      }
```

**The thing to notice:** the status wasn't stored anywhere. It was recalculated
from the new data on the way out.

## Flow C — The daily reminder job

```
1.  Recurrence trigger fires (daily)

2.  HTTP action:
      GET https://fee-management-api-dhiren.azurewebsites.net/
          api/overdue-students?code=<function key>

    Note: this bypasses APIM entirely. It's an internal Azure-to-Azure call
    that needs neither key management nor rate limiting — and routing machine
    traffic through APIM would consume the client rate-limit budget.

    Retry policy active: exponential, 4 attempts, PT7S
    → covers Function App cold start and SQL auto-resume delay

3.  Azure SQL:
      SELECT ... WHERE PaidAmount < TotalFee
                  AND DueDate < CAST(GETDATE() AS DATE)
                ORDER BY DueDate
      → IX_Students_DueDate range seek
      → 8 rows

4.  Parse JSON:
      Applies the schema → the array becomes typed objects with
      named, selectable fields

5.  For each (8 iterations):
      Send an email (V2) via the Outlook.com connector
      Body populated with items()['name'], items()['course'],
      items()['balance'], items()['dueDate'] etc.

      Retry policy active on this action too
      → covers connector throttling

6.  8 personalised emails delivered
```

---

# Part 7 — Every problem hit and how it was diagnosed

The diagnosis matters more than the fix. This is the section that shows you can
debug, not just follow instructions.

## Local environment

### `ModuleNotFoundError: No module named 'pyodbc'`

**Symptom:** `func start` failed on import despite `pip install` reporting
success.

**Diagnosis:** the terminal prompt during the install had no `(.venv)` prefix.
Packages went to the global Python 3.12 installation. The Functions worker looks
in `.venv/Lib/site-packages`.

**Fix:** activate the venv, reinstall, then verify:
```powershell
python -c "import pyodbc; print(pyodbc.__file__)"
```
The path must contain `.venv`.

**Lesson:** verify where a package landed, don't trust that the install succeeded.

### `Worker runtime cannot be 'None'`

**Symptom:** Core Tools couldn't determine the runtime, despite
`FUNCTIONS_WORKER_RUNTIME: "python"` being visible in `local.settings.json`.

**Diagnosis:** the file showed 5 errors in VS Code. The JSON was malformed, so
*nothing* in it was read — including the runtime setting.

**Root cause:** the password had been pasted with the connection string
template's surrounding braces `{...}` still in place. In ODBC, braces are escaping
syntax; in JSON they broke the structure.

**Fix:** remove the braces. Only `{ODBC Driver 18 for SQL Server}` keeps them.

### `ModuleNotFoundError: No module named 'azure'`

**Diagnosis:** the VS Code Run button had executed `function_app.py` as a plain
Python script.

**Fix:** Azure Functions are never run that way. `func start` boots the host,
which loads the module with the runtime available.

### `No job functions found`

**Diagnosis:** the VS Code workspace root was the parent folder, not `functions/`.

**Fix:** `host.json` must sit at the workspace root for the extension to detect
the project.

**This one caused five separate downstream failures** before it was corrected —
the venv landed in the wrong directory, `pip install -r requirements.txt` couldn't
find the file, and terminal commands ran from the wrong path.

## Azure resource creation

### "No servers found in the selected resource group"

**Diagnosis:** the simplified SQL Database create form filters the server dropdown
by the selected resource group. A brand-new resource group is empty.

**Fix:** create a new server from within the form.

### "Your subscription does not have access to create a server in the selected region"

**Diagnosis:** East US was unavailable on this subscription.

**Fix:** Central India — which also co-locates everything.

### Query editor rejected Entra sign-in

**Diagnosis:** the SQL server showed "Microsoft Entra admin: Not configured", so
the Google-federated Azure account had no identity inside the database.

**Fix:** SQL authentication with the server admin credentials.

### `renderComponentIntoRoot` error loading the Logic App designer

**Diagnosis:** a portal session alive for six-plus hours. The token had gone
stale.

**Fix:** sign out and back in. The same stale session was also why the retry
policy dropdown appeared greyed out and read-only.

## Logic App

### 8 emails instead of 9

**Diagnosis — and this one is worth telling:** the endpoint had returned 9
overdue students earlier in the day. By the time the Logic App ran, it returned 8.

The cause: during local testing, a PUT request had changed student 16's due date
to 2026-12-31. That student was no longer overdue.

**The system was correct.** The admin update took effect, the query reflected the
new state, and the loop processed exactly the qualifying students.

**Why this matters:** it proves the admin endpoint has real downstream
consequences rather than just returning a 200.

## API Management

### `Policy is not allowed in 'Consumption' sku`

**Symptom:** APIM rejected the rate-limit policy on save.

**Diagnosis:** `rate-limit-by-key` is unsupported on the Consumption tier.

**Fix:** `rate-limit`, which counts per subscription automatically — which is the
behaviour that was wanted anyway, with no counter-key expression needed.

### All operations imported as POST

**Diagnosis:** APIM can't read route metadata from the Python v2 programming
model, so it defaults to POST with the function name as the path.

**Fix:** correct each operation's method and URL template manually.

### API callable without a subscription key

**Diagnosis:** applying policies doesn't require a key. The API must belong to a
**Product** with "Requires subscription" enabled.

**Fix:** create the product, enable the setting, add the API to it. Verified with
a 401 from a keyless browser call.

### 500 with an empty body on GET

**Diagnosis:** a direct call to the Function App succeeded, which isolated the
problem to APIM's forwarding. The actual cause was that the serverless database
had auto-paused and the wake-up exceeded APIM's backend timeout.

**Fix:** transient. Warm the database before demonstrating.

### 500 on PUT

**Diagnosis:** the GET worked, so routing and auth were fine. The difference was
the request body.

**Root cause:** the APIM test console doesn't automatically set
`Content-Type: application/json`. Without it, `req.get_json()` raised, and the
error surfaced as a 500 through APIM rather than the 400 seen locally.

**Fix:** add the header explicitly.

## Entra ID

### App absent from the "My APIs" tab

**Diagnosis:** applications don't reliably list themselves there.

**Fix:** the service principal is registered under "APIs my organization uses".

### Token issued with no `roles` claim

**Diagnosis:** the app role existed but nothing had been granted it.

**Fix:** add the application permission, then **Grant admin consent**. That button
is what puts the claim in the token.

### 401 with a valid token — the hardest bug

**Symptom:** a freshly issued token, correct audience, correct role, still 401.

**Diagnosis:** decoded the token and read the claims:

```json
"iss": "https://sts.windows.net/<tenant-id>/",
"ver": "1.0"
```

That's a **v1.0** issuer. The policy pointed at the **v2.0** OpenID metadata
document, which declares a different issuer. Validation failed on issuer
mismatch — not on audience or role, both of which were correct.

**Root cause:** the client credentials flow with a `.default` scope issues v1.0
tokens by default from this app registration.

**Two possible fixes:** edit the app manifest's `accessTokenAcceptedVersion` and
re-fetch a token, or point the policy at the v1 metadata endpoint.

**Chosen:** remove `/v2.0` from the `openid-config` URL. One edit versus editing
JSON, saving, and re-acquiring a token.

**The principle:** the token version must match the discovery document used to
validate it.

**Why this is worth telling the panel:** the diagnosis came from reading the
actual token rather than guessing. That's the difference between debugging and
trial and error.

---

# Part 8 — Every decision and its justification

| Decision | Chosen | Alternative | Justification |
|---|---|---|---|
| Reminder orchestration | Logic App | Durable Function | Daily scheduled fan-out with no state. Scheduler, retry and email connector are configuration, not code. Durable Functions win when orchestration needs stateful coordination or compensation |
| Status calculation location | Function | SQL view or computed column | Brief specifies Functions for fee calculations. One implementation serves both the API and the Logic App, so they cannot diverge |
| Logic App data source | Function endpoint | SQL connector direct | Keeps the overdue rule in one place |
| Rate limit policy | `rate-limit` | `rate-limit-by-key` | Latter unsupported on Consumption. Former counts per subscription automatically |
| App role member type | Applications | Users | Enables client credentials — scriptable, no interactive sign-in |
| JWT policy scope | PUT operation only | All operations | Student reads must work with just a subscription key |
| SQL authentication | Connection string | Managed identity | Better practice, but needs contained-user setup with an opaque failure mode. Documented as production work |
| APIM tier | Consumption | Developer | Minutes vs 40 minutes, free vs ~$50/month |
| Function hosting | Consumption (classic) | Flex Consumption | Well-documented, predictable behaviour |
| Partial updates | `COALESCE` | Dynamic `SET` clause | No string concatenation, every value stays a bound parameter |
| Email provider | Outlook.com | SendGrid | SendGrid's Azure free tier is deprecated; new accounts need sender verification that can take hours |
| Seed date strategy | Relative (`DATEADD`) | Hardcoded dates | Data never goes stale; demo always has overdue records |
| Seed script design | Re-runnable (`DELETE` first) | Insert-only | Resets demo data without dropping schema |
| Index strategy | One, on `DueDate` | Multiple speculative indexes | Two query patterns, two access paths. Indexes cost writes |
| Money type | `DECIMAL(10,2)` | `FLOAT` | Exact decimal arithmetic; float introduces rounding error on currency |
| Route for overdue | `/overdue-students` | `/students/overdue` | Avoids ambiguity against the `{studentId}` parameterised route |

---

# Part 9 — Things you must be able to say without hesitating

These are the questions most likely to come, with the answer compressed to what
you'd actually say.

**"Walk me through what happens when a student checks their fee status."**

> Request hits API Management first. It checks the subscription key, checks the
> rate limit, then forwards to the Function App with a function key that only
> APIM holds. The Function queries Azure SQL by primary key, gets the row, and
> calculates the status in code — Paid if fully paid, else Overdue if past due,
> else Partially Paid. Returns JSON. Application Insights records the request and
> the SQL dependency.

**"Why calculate status in code rather than storing it?"**

> A stored status would need updating every time a payment lands or a date
> passes, and it would go stale silently. Calculating it means it's always
> correct by definition. It also means one implementation serves both the API and
> the Logic App, so they can't disagree.

**"How do you prevent SQL injection?"**

> Every statement is parameterised — no string concatenation anywhere. The update
> endpoint was the interesting case, because partial updates tempt you into
> building a dynamic SET clause. I used COALESCE on each column instead, so the
> query text is fixed at author time and every value is a bound parameter.

**"How does this scale to 5000 records?"**

> There are two query patterns. Single-student lookup is served by the clustered
> primary key — a B-tree seek. The overdue scan is served by a non-clustered index
> on DueDate, so it seeks a date range rather than scanning, then evaluates the
> balance predicate on the matching subset. Both logarithmic. I deliberately
> didn't index PaidAmount or TotalFee because no query filters on them and
> indexes cost write performance.

**"Why API Management at all? The Function App could be called directly."**

> That's exactly what it prevents. Every function uses AuthLevel.FUNCTION, so the
> Function App needs a key, and the key lives in an APIM named value. Knowing the
> URL isn't enough. That gives one public entry point where authentication,
> authorisation and rate limiting all happen, and an unauthorised request never
> reaches compute.

**"Explain the two-tier authentication."**

> Every request needs a subscription key — that's the API key requirement. The
> admin write additionally needs an Entra ID token carrying the FeeAdmin role.
> Both are enforced at the gateway. The point is that a compromised subscription
> key permits reads but cannot mutate financial data.

**"Why is the app role Applications rather than Users?"**

> It enables the client credentials flow, so a token comes from one scripted HTTP
> call rather than an interactive sign-in. That's the right shape for
> service-to-service calls and for automation. A user-type role would be correct
> if a person were signing in through a web app.

**"Why does the Logic App bypass API Management?"**

> It's an internal Azure-to-Azure call. It doesn't need the gateway's subscription
> key management, and routing machine traffic through APIM would consume the rate
> limit budget that exists for client traffic. It authenticates with a function
> key, which is the appropriate control for a service-to-service call.

**"What happens if an email fails to send?"**

> Both the HTTP call and the email action have exponential retry — four attempts
> starting at seven seconds. Exponential because transient failures like connector
> throttling usually clear within seconds, and backing off gives the downstream
> service room rather than adding load. If all four fail, the run is marked failed
> in the Logic App history. In production I'd alert on that.

**"What if two admins update the same student simultaneously?"**

> Last write wins. There's no optimistic concurrency control, which is a genuine
> limitation I've documented. The fix is a RowVersion column exposed as an ETag,
> with the client sending If-Match and the API returning 409 on conflict. I didn't
> build it because the brief doesn't ask for it, but it's the first thing I'd add
> for a real financial system.

**"Why is there no foreign key between Students and Administrators?"**

> The brief defines no join column in either table, and the real relationship is
> many-to-many — any administrator can act on any student — which needs a junction
> table the brief doesn't ask for. Entra ID is the authorisation source of truth;
> the Administrators table is the application's roster, with Role values matching
> the Entra app role names. To model it properly I'd add a fee-update history
> table holding both IDs as foreign keys, which gives you the relationship and an
> audit trail at once.

**"What was the hardest part?"**

> Token validation. My first policy pointed at the v2.0 OpenID metadata endpoint,
> but the client credentials flow with a .default scope issues v1.0 tokens —
> different issuer claim, so validation failed even though the audience and role
> were both correct. I decoded the token, saw ver 1.0 and the sts.windows.net
> issuer, and pointed the policy at the v1 metadata document. The lesson is that
> the token version has to match the discovery document you validate against.

**"What would you do differently?"**

> Managed identity for the SQL connection first, so there are no stored
> credentials at all. Then an audit table, because financial data modification
> without a record of who did it is hard to defend. Then optimistic concurrency on
> the update endpoint. Those three are ordered by risk, not effort.

**"What assumptions did you make?"**

> Three that matter. The Students schema has no email column, so reminders go to
> a single configured mailbox — I kept the specified columns rather than adding
> one, and documented it. The three permitted statuses don't cover a student who's
> paid nothing and isn't yet due, so that falls through to Partially Paid;
> production would add a Pending status. And the two tables have no defined
> relationship, so I didn't invent one.

---

## The three sentences to lead with

If you get thirty seconds before questions start:

> "It's a serverless architecture — API Management at the edge handling
> authentication, authorisation and rate limiting, Azure Functions for the fee
> logic, Azure SQL for storage, and a Logic App for the daily reminder job.
>
> The design point I'd highlight is the two-tier security model: students read
> with a subscription key, admins write with a subscription key plus an Entra ID
> token carrying a specific role, and both are enforced at the gateway so
> unauthorised requests never reach compute.
>
> I've documented a few assumptions where the specification was ambiguous — the
> main one being that the Students schema has no email column, so I kept the
> specified columns and documented the workaround rather than deviating."
