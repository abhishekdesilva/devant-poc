-- POC 9: customers table for Integration 2 on Microsoft SQL Server.
-- Run once against the target database, for example with sqlcmd:
--   sqlcmd -S <host>,1433 -d <database> -U <admin login> -i db/mssql-schema.sql
-- Then run Integration 2 with DB_TYPE=mssql (DB_SETUP stays false).

IF OBJECT_ID(N'dbo.customers', N'U') IS NULL
CREATE TABLE dbo.customers (
    id         INT IDENTITY(1,1) PRIMARY KEY,
    name       NVARCHAR(100) NOT NULL,
    email      NVARCHAR(255) NOT NULL CONSTRAINT uq_customers_email UNIQUE,
    created_at VARCHAR(40)   NOT NULL
);
GO

-- Optional: a login for Integration 2 that can only read and write data.
-- Replace <password>, or create the login according to your own standards.
-- CREATE LOGIN poc9_app WITH PASSWORD = '<password>';
-- CREATE USER poc9_app FOR LOGIN poc9_app;
-- ALTER ROLE db_datareader ADD MEMBER poc9_app;
-- ALTER ROLE db_datawriter ADD MEMBER poc9_app;
-- GO
