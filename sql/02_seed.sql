-- ============================================================
-- Task 1: Data Storage - Sample Data
-- Fee Management System - Azure SQL Database
--
-- Safe to run repeatedly. Clears both tables first, so this
-- also resets the demo data after testing the admin update
-- endpoint.
--
-- Due dates are relative to today, so the data always contains
-- overdue records whenever it is loaded.
--   Students 1-8   : fully paid            -> "Paid"
--   Students 9-17  : unpaid, date passed   -> "Overdue"
--   Students 18-25 : unpaid, date upcoming -> "Partially Paid"
-- ============================================================

DELETE FROM Students;
DELETE FROM Administrators;


INSERT INTO Students (StudentID, Name, Course, TotalFee, PaidAmount, DueDate) VALUES
(1,  'Aarav Sharma',     'Computer Engineering',   120000.00, 120000.00, CAST(DATEADD(day, -45, GETDATE()) AS DATE)),
(2,  'Diya Patel',       'Information Technology', 110000.00, 110000.00, CAST(DATEADD(day, -30, GETDATE()) AS DATE)),
(3,  'Rohan Mehta',      'Mechanical Engineering', 100000.00, 100000.00, CAST(DATEADD(day, -20, GETDATE()) AS DATE)),
(4,  'Ananya Iyer',      'Data Science',           135000.00, 135000.00, CAST(DATEADD(day, -15, GETDATE()) AS DATE)),
(5,  'Kabir Nair',       'Computer Engineering',   120000.00, 120000.00, CAST(DATEADD(day,  10, GETDATE()) AS DATE)),
(6,  'Ishita Desai',     'Electronics',             95000.00,  95000.00, CAST(DATEADD(day,  18, GETDATE()) AS DATE)),
(7,  'Vivaan Joshi',     'Civil Engineering',       90000.00,  90000.00, CAST(DATEADD(day,  25, GETDATE()) AS DATE)),
(8,  'Meera Kulkarni',   'Data Science',           135000.00, 135000.00, CAST(DATEADD(day,  30, GETDATE()) AS DATE)),

(9,  'Arjun Reddy',      'Computer Engineering',   120000.00,  40000.00, CAST(DATEADD(day, -60, GETDATE()) AS DATE)),
(10, 'Saanvi Rao',       'Information Technology', 110000.00,      0.00, CAST(DATEADD(day, -50, GETDATE()) AS DATE)),
(11, 'Aditya Verma',     'Mechanical Engineering', 100000.00,  25000.00, CAST(DATEADD(day, -40, GETDATE()) AS DATE)),
(12, 'Nisha Pillai',     'Electronics',             95000.00,  60000.00, CAST(DATEADD(day, -35, GETDATE()) AS DATE)),
(13, 'Rahul Gupta',      'Civil Engineering',       90000.00,      0.00, CAST(DATEADD(day, -28, GETDATE()) AS DATE)),
(14, 'Tanvi Bhosale',    'Data Science',           135000.00,  75000.00, CAST(DATEADD(day, -21, GETDATE()) AS DATE)),
(15, 'Karan Malhotra',   'Computer Engineering',   120000.00, 100000.00, CAST(DATEADD(day, -14, GETDATE()) AS DATE)),
(16, 'Priya Menon',      'Information Technology', 110000.00,  30000.00, CAST(DATEADD(day,  -7, GETDATE()) AS DATE)),
(17, 'Siddharth Rane',   'Electronics',             95000.00,  45000.00, CAST(DATEADD(day,  -3, GETDATE()) AS DATE)),

(18, 'Neha Chavan',      'Computer Engineering',   120000.00,  60000.00, CAST(DATEADD(day,   5, GETDATE()) AS DATE)),
(19, 'Aryan Kapoor',     'Mechanical Engineering', 100000.00,  50000.00, CAST(DATEADD(day,  12, GETDATE()) AS DATE)),
(20, 'Riya Deshmukh',    'Data Science',           135000.00,  90000.00, CAST(DATEADD(day,  20, GETDATE()) AS DATE)),
(21, 'Manav Singh',      'Civil Engineering',       90000.00,  20000.00, CAST(DATEADD(day,  27, GETDATE()) AS DATE)),
(22, 'Sneha Kadam',      'Information Technology', 110000.00,  55000.00, CAST(DATEADD(day,  35, GETDATE()) AS DATE)),
(23, 'Yash Agarwal',     'Electronics',             95000.00,  15000.00, CAST(DATEADD(day,  42, GETDATE()) AS DATE)),
(24, 'Pooja Shetty',     'Computer Engineering',   120000.00,  80000.00, CAST(DATEADD(day,  50, GETDATE()) AS DATE)),
(25, 'Devansh Bhat',     'Data Science',           135000.00,  35000.00, CAST(DATEADD(day,  60, GETDATE()) AS DATE));


INSERT INTO Administrators (AdminID, Name, Role) VALUES
(1, 'Sunita Kale',   'FeeAdmin'),
(2, 'Rajesh Naik',   'FeeAdmin'),
(3, 'Farah Qureshi', 'Viewer');


-- ------------------------------------------------------------
-- Verification: confirms all three statuses are present.
-- Applies the same rule as the Azure Function.
-- ------------------------------------------------------------
SELECT
    CASE
        WHEN PaidAmount >= TotalFee            THEN 'Paid'
        WHEN DueDate < CAST(GETDATE() AS DATE) THEN 'Overdue'
        ELSE 'Partially Paid'
    END AS PaymentStatus,
    COUNT(*) AS StudentCount
FROM Students
GROUP BY
    CASE
        WHEN PaidAmount >= TotalFee            THEN 'Paid'
        WHEN DueDate < CAST(GETDATE() AS DATE) THEN 'Overdue'
        ELSE 'Partially Paid'
    END;
