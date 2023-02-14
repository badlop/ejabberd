USE [master]
GO

-- prevent creation when already exists
IF DB_ID('ejabberd_test') IS NOT NULL
BEGIN
SET noexec on;
END

CREATE DATABASE ejabberd_test;
GO

USE ejabberd_test;
GO

CREATE LOGIN ejabberd_test WITH PASSWORD = 'ejabberd_Test1';
GO

CREATE USER ejabberd_test FOR LOGIN ejabberd_test;
GO

GRANT ALL TO ejabberd_test;
GO

GRANT CONTROL ON SCHEMA ::dbo TO ejabberd_test;
GO
