"""
Fee Management System - Azure Functions (Python v2 programming model)

Three HTTP endpoints:
  GET  /api/students/{studentId}        Task 3 - fee details + payment status
  GET  /api/overdue-students            Task 2 - list consumed by the Logic App
  PUT  /api/students/{studentId}/fees   Task 4 - admin update, secured at APIM

All endpoints use AuthLevel.FUNCTION, so the Function App can only be
called with a function key. API Management holds that key and is the
only public entry point.
"""

import os
import json
import logging
from datetime import date

import azure.functions as func
import pyodbc

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

# Set in the Function App's Application Settings - never hardcoded.
CONNECTION_STRING = os.environ["SqlConnectionString"]


# ---------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------

def get_payment_status(total_fee, paid_amount, due_date):
    """
    The fee calculation the brief asks for. Returns exactly one of the
    three required values. Order matters: a fully paid student is never
    overdue, so 'Paid' is checked first.
    """
    if paid_amount >= total_fee:
        return "Paid"
    if due_date < date.today():
        return "Overdue"
    return "Partially Paid"


def json_response(payload, status_code=200):
    return func.HttpResponse(
        json.dumps(payload),
        status_code=status_code,
        mimetype="application/json",
    )


def student_to_dict(row):
    return {
        "studentId": row.StudentID,
        "name": row.Name,
        "course": row.Course,
        "totalFee": float(row.TotalFee),
        "paidAmount": float(row.PaidAmount),
        "balance": float(row.TotalFee - row.PaidAmount),
        "dueDate": row.DueDate.isoformat(),
        "paymentStatus": get_payment_status(row.TotalFee, row.PaidAmount, row.DueDate),
    }


# ---------------------------------------------------------------
# Task 3: Payment status for a single student
# ---------------------------------------------------------------

@app.route(route="students/{studentId:int}", methods=["GET"])
def get_student_fee(req: func.HttpRequest) -> func.HttpResponse:
    student_id = int(req.route_params.get("studentId"))
    logging.info("Fetching fee details for StudentID %s", student_id)

    conn = pyodbc.connect(CONNECTION_STRING)
    try:
        row = conn.cursor().execute(
            "SELECT StudentID, Name, Course, TotalFee, PaidAmount, DueDate "
            "FROM Students WHERE StudentID = ?",
            student_id,
        ).fetchone()
    finally:
        conn.close()

    if row is None:
        return json_response({"error": f"Student {student_id} not found"}, 404)

    return json_response(student_to_dict(row))


# ---------------------------------------------------------------
# Task 2: Overdue students, called by the Logic App
# ---------------------------------------------------------------

@app.route(route="overdue-students", methods=["GET"])
def get_overdue_students(req: func.HttpRequest) -> func.HttpResponse:
    logging.info("Fetching overdue students")

    conn = pyodbc.connect(CONNECTION_STRING)
    try:
        rows = conn.cursor().execute(
            "SELECT StudentID, Name, Course, TotalFee, PaidAmount, DueDate "
            "FROM Students "
            "WHERE PaidAmount < TotalFee AND DueDate < CAST(GETDATE() AS DATE) "
            "ORDER BY DueDate"
        ).fetchall()
    finally:
        conn.close()

    logging.info("Found %s overdue students", len(rows))
    return json_response([student_to_dict(row) for row in rows])


# ---------------------------------------------------------------
# Task 4: Admin update of a fee record
# API Management validates the Entra ID token and the FeeAdmin app
# role before a request ever reaches this function.
# ---------------------------------------------------------------

@app.route(route="students/{studentId:int}/fees", methods=["PUT"])
def update_student_fees(req: func.HttpRequest) -> func.HttpResponse:
    student_id = int(req.route_params.get("studentId"))

    try:
        body = req.get_json()
    except ValueError:
        return json_response({"error": "Request body must be valid JSON"}, 400)

    total_fee = body.get("totalFee")
    paid_amount = body.get("paidAmount")
    due_date = body.get("dueDate")

    if total_fee is None and paid_amount is None and due_date is None:
        return json_response(
            {"error": "Provide at least one of: totalFee, paidAmount, dueDate"}, 400
        )

    logging.info("Admin update requested for StudentID %s", student_id)

    conn = pyodbc.connect(CONNECTION_STRING)
    try:
        cursor = conn.cursor()
        # COALESCE keeps the existing value for any field not supplied,
        # so there is no dynamic SQL to build. Values are parameterised.
        cursor.execute(
            "UPDATE Students "
            "SET TotalFee   = COALESCE(?, TotalFee), "
            "    PaidAmount = COALESCE(?, PaidAmount), "
            "    DueDate    = COALESCE(?, DueDate) "
            "WHERE StudentID = ?",
            total_fee, paid_amount, due_date, student_id,
        )

        if cursor.rowcount == 0:
            return json_response({"error": f"Student {student_id} not found"}, 404)

        conn.commit()

        row = cursor.execute(
            "SELECT StudentID, Name, Course, TotalFee, PaidAmount, DueDate "
            "FROM Students WHERE StudentID = ?",
            student_id,
        ).fetchone()
    finally:
        conn.close()

    logging.info("Fee record updated for StudentID %s", student_id)
    return json_response({
        "message": f"Fee record updated for student {student_id}",
        "student": student_to_dict(row),
    })
