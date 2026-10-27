-- POC 6 schema, seed data, and a least-privilege application login.
-- Run as an admin (sa locally). Safe to re-run.
-- The application password is passed in by sqlcmd: -v APP_PASSWORD="..."

IF DB_ID('pocdb') IS NULL
    CREATE DATABASE pocdb;
GO

USE pocdb;
GO

IF OBJECT_ID('dbo.customers') IS NULL
CREATE TABLE dbo.customers (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    name        NVARCHAR(200) NOT NULL,
    email       NVARCHAR(320) NOT NULL CONSTRAINT uq_customers_email UNIQUE,
    phone       NVARCHAR(50)  NULL,
    created_at  DATETIME2(3)  NOT NULL CONSTRAINT df_customers_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NOT NULL CONSTRAINT df_customers_updated DEFAULT SYSUTCDATETIME()
);
GO

-- No foreign key to customers, so the audit trail survives deletes.
IF OBJECT_ID('dbo.audit_log') IS NULL
CREATE TABLE dbo.audit_log (
    id           BIGINT IDENTITY(1,1) PRIMARY KEY,
    action       VARCHAR(10)  NOT NULL,
    customer_id  INT          NOT NULL,
    at           DATETIME2(3) NOT NULL CONSTRAINT df_audit_at DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM dbo.customers)
INSERT INTO dbo.customers (name, email, phone) VALUES
    (N'Ada Lovelace',  N'ada@example.com',   N'+1-201-555-0101'),
    (N'Alan Turing',   N'alan@example.com',  N'+1-201-555-0102'),
    (N'Grace Hopper',  N'grace@example.com', NULL);
GO

-- Application login: read/write on data only, no DDL, no admin rights.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'poc_app')
    CREATE LOGIN poc_app WITH PASSWORD = '$(APP_PASSWORD)', CHECK_POLICY = ON;
GO

USE pocdb;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'poc_app')
BEGIN
    CREATE USER poc_app FOR LOGIN poc_app;
    ALTER ROLE db_datareader ADD MEMBER poc_app;
    ALTER ROLE db_datawriter ADD MEMBER poc_app;
END
GO
