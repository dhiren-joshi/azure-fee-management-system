
-- Task 1: Data Storage - Schema
-- Fee Management System - Azure SQL Database
--
-- Run this ONCE to create the tables.
-- To reload sample data afterwards, run 02_seed.sql on its own.


DROP TABLE IF EXISTS Students;
DROP TABLE IF EXISTS Administrators;



-- Students table

CREATE TABLE Students (
    StudentID   INT             NOT NULL PRIMARY KEY,
    Name        NVARCHAR(100)   NOT NULL,
    Course      NVARCHAR(100)   NOT NULL,
    TotalFee    DECIMAL(10, 2)  NOT NULL,
    PaidAmount  DECIMAL(10, 2)  NOT NULL DEFAULT 0,
    DueDate     DATE            NOT NULL
);



-- Administrators table

CREATE TABLE Administrators (
    AdminID     INT             NOT NULL PRIMARY KEY,
    Name        NVARCHAR(100)   NOT NULL,
    Role        NVARCHAR(50)    NOT NULL
);


-- ------------------------------------------------------------
-- Index for the overdue lookup used by the Logic App.
-- The PRIMARY KEY on StudentID already covers single-student
-- lookups; this keeps the overdue scan efficient as the table
-- grows (scalability requirement).
-- ------------------------------------------------------------
CREATE INDEX IX_Students_DueDate ON Students (DueDate);
