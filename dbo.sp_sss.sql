
/* test

exec sp_sss @String = 'Name'
, @OnlyCurrentDB = 0
*/

USE master
GO
IF  EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.sp_sss') AND type in (N'P', N'PC'))
	DROP PROCEDURE dbo.sp_sss
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE dbo.sp_sss
( @String NVarchar(130) -- string to search for
, @Dbs NVarchar(4000) = NULL -- databases to search, comma seperated, wild cards supported
, @IncludeSystem Bit = 0 -- include system databases (master, model, etc)
, @UseWildPrefix Bit = 1
, @UseWildSuffix Bit = 1
, @Tables Bit = 1
, @Views Bit = 1
, @Jobs Bit = 1 -- SQL Agent Jobs
, @debug Varchar(255) = ''
) AS
/*
 Sql String Search
 Find a string used in a object in a database
 Author: ric vander ark
*/
BEGIN
SET NOCOUNT ON
--#region Declare
DECLARE @pk int
, @pkmax int
, @cmd nvarchar(3000)
, @dbname sysname
, @SearchString nvarchar(130)
, @Where nvarchar(1024)
, @Where2 nvarchar(1024)
, @Where3 nvarchar(1024)
, @state int
, @state_desc varchar(1000)
, @SQLAgentJobsCount int
, @p1 Int, @p2 Int
, @Name NVarchar(MAX)
, @HasWild bit

DECLARE @db TABLE
( pk int IDENTITY NOT NULL PRIMARY KEY
, name sysname NOT NULL
, id int NOT NULL
, state int NOT NULL
, state_desc varchar(1000) NOT NULL
)

DECLARE @errors TABLE
( pk int IDENTITY NOT NULL PRIMARY KEY
, code int NOT NULL
, message varchar(2000)   NOT NULL
)

DECLARE @tDbs Table
( pk int IDENTITY PRIMARY KEY
, Name NVarchar(MAX)  NULL
, HasWild bit  NOT NULL DEFAULT 0
)

CREATE TABLE dbo.#tType
( pk Int IDENTITY PRIMARY KEY CLUSTERED
, DB NVarchar(128) NULL
, DataTypeSchema sysname NOT NULL
, DataType sysname NOT NULL
, UDDTSchema sysname  NULL
, UDDT sysname  NULL
, system_type_id TinyInt NOT NULL
, user_type_id Int NOT NULL
, SizeMult Numeric(2, 1) NULL
, schema_id Int NOT NULL
, principal_id Int NULL
, max_length Smallint NOT NULL
, precision TinyInt NOT NULL
, scale TinyInt NOT NULL
, collation_name sysname NULL
, is_nullable Bit NULL
, is_user_defined Bit NOT NULL
, is_assembly_type Bit NOT NULL
, default_object_id Int NOT NULL
, rule_object_id Int NOT NULL
, is_table_type Bit NOT NULL
)

CREATE TABLE #list
( pk int IDENTITY
, DB sysname
, SchemaName sysname
, ObjectName nvarchar(128)
, Object_id int
, ObjectType varchar(100)
, ObjectSchema_id int
, [Column] nvarchar(128)
, column_id int
, DataTypeSchema nvarchar(128)
, DataType nvarchar(128)
, UDDTSchema nvarchar(128)
, UDDT nvarchar(128)
, Length int
, precision tinyint
, scale tinyint
, StorageLength int
, is_nullable bit
, collation_name nvarchar(128)
, is_identity bit
)

CREATE TABLE #listSQLAgentJobs
( pk int IDENTITY
, DB sysname
, JobName nvarchar(128)
, job_id varchar(128)
, ObjectType varchar(100)
, Description nvarchar(512)
, JobEnabled bit
, start_step_id int
, owner_sid varbinary(86)
, owner nvarchar(128)
, step_id int -- ID of the step in the job.
, step_name nvarchar(128) -- Name of the job step.
, subsystem nvarchar(40) -- Name of the subsystem used by SQL Server Agent to execute the job step.
, command nvarchar(max) -- Command to be executed by subsystem.
, database_name nvarchar(128) -- Name of the database in which command is executed if subsystem is TSQL.
, database_user_name nvarchar(128) -- Name of the database user whose account will be used when executing the step.
, output_file_name nvarchar(200) -- NAME of the file in which the step's output is saved when subsystem is TSQL, PowerShell, or CmdExec.

, notify_email_operator_id int -- E-mail name of the operator to notify.
, EmailOpName nvarchar(128)
, EmailOpEmailAddress nvarchar(100)
, EmailOpPagerAddress nvarchar(100)
, EmailOpNetSendAddress nvarchar(100)

, notify_netsend_operator_id int -- ID of the computer or user used when sending network messages.
, netsendOpName nvarchar(128)
, netsendOpEmailAddress nvarchar(100)
, netsendOpPagerAddress nvarchar(100)
, netsendOpNetSendAddress nvarchar(100)

, notify_page_operator_id int -- ID of the computer or user used when sending a page.
, pageOpName nvarchar(128)
, pageOpEmailAddress nvarchar(100)
, pageOpPagerAddress nvarchar(100)
, pageOpNetSendAddress nvarchar(100)

)

--#endregion Declare


SELECT @debug = CASE WHEN ISNULL(@debug, '') IN ('n','no','false','f','0') THEN '' ELSE @debug END
, @pk = 0
, @SQLAgentJobsCount  = 0
, @Dbs = CASE WHEN LEN(@Dbs) = 0 THEN NULL ELSE @Dbs END


IF(@Dbs IS NOT NULL)
BEGIN
	SELECT @p1 = 1 -- start location
	, @p2 = 1

	WHILE @p1 > 0
	BEGIN
		SELECT @p2 = CHARINDEX(',', @Dbs, @p1)
		IF(@p2 > 1)
		BEGIN
			INSERT @tDbs(Name) VALUES ( RTRIM(LTRIM(SUBSTRING(@Dbs, @p1, @p2 - @p1))) )
			SELECT @p1 = @p2 + 1
		END
		ELSE
		BEGIN
			INSERT @tDbs(Name) VALUES ( RTRIM(LTRIM(SUBSTRING(@Dbs, @p1, LEN(@DBs)))) )
		BREAK
		END
	END

	UPDATE @tDbs
	SET Name = REPLACE(REPLACE(Name, '*', '%'), '?', '_')

	UPDATE @tDbs
	SET HasWild = 1
	WHERE CHARINDEX('%', Name) > 0 -- Any string of zero or more characters.
	OR CHARINDEX('_', Name) > 0 -- Any single character.
	OR -- Any single character within the specified range (simplified, the pattern is really [] or [^])
	( CHARINDEX('[', Name) > 0  AND  CHARINDEX(']', Name, CHARINDEX('[', Name) + 1) > 0 )

	SELECT @pk = MIN(pk), @pkMax = MAX(pk) FROM @tDbs

WHILE @pk <= @pkMax
BEGIN
	SELECT @Name = Name
	, @HasWild = HasWild
	FROM @tDbs
	WHERE pk = @pk
	-- RAISERROR('%d) ', 10, 1, @pk) WITH NOWAIT

	IF (@HasWild = 1)
	BEGIN
		INSERT @tDbs(Name)

		SELECT name
		FROM master.sys.databases d
		WHERE name LIKE @Name
		AND (@IncludeSystem = 1 OR (@IncludeSystem = 0 AND d.name NOT IN ('master', 'tempdb', 'model', 'msdb')))
		END

		SELECT @pk = @pk + 1
	END

	INSERT @db(name, id, state, state_desc)
	SELECT DISTINCT d.name, database_id, state, state_desc
	FROM master.sys.databases d
	JOIN @tDbs db ON db.Name = d.name
	WHERE db.HasWild = 0
	ORDER BY d.name
END
ELSE
BEGIN
	INSERT @db(name, id, state, state_desc)
	SELECT name, database_id, state, state_desc
	FROM master.sys.databases d
	WHERE (@IncludeSystem = 1 OR (@IncludeSystem = 0 AND d.name NOT IN ('master', 'tempdb', 'model', 'msdb')))
	ORDER BY d.name
END

SELECT @pk = MIN(pk), @pkmax = MAX(pk) FROM @db

IF(@debug <> '')
BEGIN
	SELECT @cmd =  CAST(DB_ID() AS varchar(11)) + ', ' + DB_NAME()
	RAISERROR('Current DB_ID() = %s', 10,1, @cmd) WITH NOWAIT

	IF( CHARINDEX('Verbose', @debug) > 0)
	BEGIN
		SELECT '@db' AS '@db', * FROM @db
	END
END

SELECT @SearchString = CASE WHEN @UseWildPrefix = 1 AND RIGHT(@String,1) <> '%' THEN '%' ELSE '' END
 + @String
+ CASE WHEN @UseWildSuffix = 1 AND RIGHT(@String,1) <> '%' THEN '%' ELSE '' END

--SELECT @String , @SearchString
--RETURN



IF(@Jobs = 1)
BEGIN
	--#region jobs

	INSERT #listSQLAgentJobs
	( DB
	, JobName
	, job_id
	, ObjectType
	, Description
	, JobEnabled
	, start_step_id
	, owner_sid
	, owner
	, step_id
	, step_name
	, subsystem
	, command
	, database_name
	, database_user_name
	, output_file_name
	, notify_email_operator_id
	, EmailOpName
	, EmailOpEmailAddress
	, EmailOpPagerAddress
	, EmailOpNetSendAddress
	, notify_netsend_operator_id
	, netsendOpName
	, netsendOpEmailAddress
	, netsendOpPagerAddress
	, netsendOpNetSendAddress
	, notify_page_operator_id
	, pageOpName
	, pageOpEmailAddress
	, pageOpPagerAddress
	, pageOpNetSendAddress
	)

	SELECT
	'msdb' AS DB
	, j.name
	, CAST(j.job_id AS varchar(128))
	, 'SQL Agent Job' AS ObjectType
	, j.description
	, j.enabled
	, j.start_step_id

	, j.owner_sid
	, SUSER_SNAME(j.owner_sid)

	, js.step_id
	, js.step_name -- Name of the job step.
	, js.subsystem  -- Name of the subsystem used by SQL Server Agent to execute the job step.
	, js.command  -- Command to be executed by subsystem.
	, js.database_name -- Name of the database in which command is executed if subsystem is TSQL.
	, js.database_user_name  -- Name of the database user whose account will be used when executing the step.
	, js.output_file_name

	, j.notify_email_operator_id
	, email_op.name AS EmailOpName
	, email_op.email_address AS EmailOpEmailAddress
	, email_op.pager_address AS EmailOpPagerAddress
	, email_op.netsend_address AS EmailOpNetSendAddress

	, j.notify_netsend_operator_id
	, netsend_op.name AS netsendOpName
	, netsend_op.email_address AS netsendOpEmailAddress
	, netsend_op.pager_address AS netsendOpPagerAddress
	, netsend_op.netsend_address AS netsendOpNetSendAddress

	, j.notify_page_operator_id
	, page_op.name AS pageOpName
	, page_op.email_address AS pageOpEmailAddress
	, page_op.pager_address AS pageOpPagerAddress
	, page_op.netsend_address AS pageOpNetSendAddress
	FROM msdb.dbo.sysjobs j WITH (NOLOCK)
	JOIN msdb.dbo.sysjobsteps js WITH (NOLOCK) ON js.job_id = j.job_id
	JOIN master.dbo.sysservers s WITH (NOLOCK) ON s.srvid = j.originating_server_id
	LEFT JOIN msdb.dbo.sysoperators email_op WITH (NOLOCK) ON email_op.id = j.notify_email_operator_id
	LEFT JOIN msdb.dbo.sysoperators netsend_op WITH (NOLOCK) ON netsend_op.id = j.notify_netsend_operator_id
	LEFT JOIN msdb.dbo.sysoperators page_op WITH (NOLOCK) ON page_op.id = j.notify_page_operator_id
	WHERE js.step_name LIKE @SearchString
	OR js.command LIKE @SearchString
	OR j.description LIKE @SearchString
	OR j.Name LIKE @SearchString
	OR SUSER_SNAME(j.owner_sid) LIKE @SearchString

	OR email_op.name LIKE @SearchString
	OR email_op.email_address LIKE @SearchString
	OR email_op.pager_address LIKE @SearchString
	OR email_op.netsend_address LIKE @SearchString

	OR netsend_op.name LIKE @SearchString
	OR netsend_op.email_address LIKE @SearchString
	OR netsend_op.pager_address LIKE @SearchString
	OR netsend_op.netsend_address LIKE @SearchString

	OR page_op.name  LIKE @SearchString
	OR page_op.email_address LIKE @SearchString
	OR page_op.pager_address LIKE @SearchString
	OR page_op.netsend_address LIKE @SearchString

	SELECT @SQLAgentJobsCount = @@ROWCOUNT
	--#endregion jobs
END


SELECT @Where = ''
+ ' WHERE (c.name LIKE N''' + @SearchString + ''') '
+ CASE WHEN @IncludeSystem = 0 THEN ' AND (o.type NOT IN (''S'', ''IT''))' ELSE '' END
+ CASE WHEN @Tables = 0 THEN ' AND (o.type NOT IN (''U'', ''S'')' ELSE '' END
+ CASE WHEN @Views = 0 THEN ' AND (o.type <> ''V'')' ELSE '' END

SELECT @Where2 = ''
+ ' WHERE (o.name LIKE N''' + @SearchString + ''') '
+ CASE WHEN @IncludeSystem = 0 THEN ' AND (o.type NOT IN (''S'', ''IT''))' ELSE '' END
+ CASE WHEN @Tables = 0 THEN ' AND (o.type NOT IN (''U'', ''S'')' ELSE '' END
+ CASE WHEN @Views = 0 THEN ' AND (o.type <> ''V'')' ELSE '' END
 
SELECT @Where3 = ''
+ ' WHERE (s.name LIKE N''' + @SearchString + ''') '

WHILE @pk <= @pkmax
BEGIN
SELECT @dbname = name
, @state = state
, @state_desc = state_desc
FROM @db WHERE pk = @pk

  IF(@debug <> '')
BEGIN
RAISERROR('%d, %s, %s', 10,1, @pk, @dbname,  @state_desc) WITH NOWAIT
END

IF(@state <> 0)
BEGIN
	INSERT @errors (code, message)
	VALUES ( 50000  + @state, 'Skipping ' + @dbname + ' because state = ' + @state_desc)
END
ELSE
BEGIN
	TRUNCATE TABLE dbo.#tType

	SELECT @cmd = '
	; WITH baseType AS
	(
	SELECT s.name AS DataTypeSchema, t.name AS DataType
	, NULL AS UDDTSchema, NULL AS UDDT
	, t.system_type_id, t.user_type_id
	, CASE WHEN t.user_type_id IN (99, 231, 256, 239) THEN .5 ELSE 1 END AS SizeMult
	, t.schema_id, t.principal_id, t.max_length, t.precision, t.scale, t.collation_name
	, t.is_nullable, t.is_user_defined, t.is_assembly_type, t.default_object_id
	, t.rule_object_id, 0 as is_table_type
	FROM ' + @dbname + '.sys.types t  WITH (NOLOCK)
	JOIN ' + @dbname + '.sys.schemas s WITH (NOLOCK) ON s.schema_id = t.schema_id
	WHERE t.system_type_id = t.user_type_id
	)

	INSERT dbo.#tType
	(DataTypeSchema, DataType, UDDTSchema, UDDT, system_type_id
	, user_type_id, SizeMult, schema_id, principal_id, max_length, precision, scale
	, collation_name, is_nullable, is_user_defined, is_assembly_type, default_object_id
	, rule_object_id, is_table_type)
 
	SELECT bt.DataTypeSchema, bt.DataType
	, bt.UDDTSchema, bt.UDDT
	, bt.system_type_id, bt.user_type_id
	, bt.SizeMult, bt.schema_id, bt.principal_id
	, bt.max_length, bt.precision, bt.scale, bt.collation_name
	, bt.is_nullable, bt.is_user_defined, bt.is_assembly_type, bt.default_object_id
	, bt.rule_object_id
	, 0 as is_table_type -- bt.
	FROM baseType bt

	UNION ALL
 
	SELECT  bt.DataTypeSchema, bt.DataType
	, bt.UDDTSchema, bt.UDDT
	, t.system_type_id, t.user_type_id
	, CASE WHEN bt.user_type_id IN (99, 231, 256, 239) THEN .5 ELSE 1 END AS SizeMult
	, t.schema_id, t.principal_id
	, t.max_length, t.precision, t.scale, t.collation_name
	, t.is_nullable, t.is_user_defined, t.is_assembly_type, t.default_object_id
	, t.rule_object_id
	, 0 AS is_table_type
	FROM ' + @dbname + '.sys.types t  WITH (NOLOCK)
	JOIN ' + @dbname + '.sys.schemas s WITH (NOLOCK) ON s.schema_id = t.schema_id
	JOIN baseType bt ON bt.system_type_id = t.system_type_id
	WHERE t.system_type_id <> t.user_type_id
	;'

	IF(@debug <> '')
	BEGIN
		RAISERROR('@cmd to load dbo.#tType:
	%s
	', 10,1, @cmd) WITH NOWAIT
	END

	EXEC sp_executesql  @cmd

	SELECT @cmd =
	'SELECT ''' + @dbname + ''', s.name, o.name, o.object_id, o.type_desc, o.schema_id
	, c.name, c.column_id
	, t.DataTypeSchema, t.DataType
	, t.UDDTSchema, t.UDDT
	, CAST(c.max_length * t.SizeMult AS int) AS Length
	, c.precision, c.scale, c.max_length, c.is_nullable, c.collation_name, c.is_identity
	FROM ' + @dbname + '.sys.columns c WITH (NOLOCK)
	JOIN ' + @dbname + '.sys.objects o WITH (NOLOCK) ON o.object_id = c.object_id
	JOIN ' + @dbname + '.sys.schemas s WITH (NOLOCK) ON s.schema_id = o.schema_id
	LEFT JOIN #tType t ON t.user_type_id = c.user_type_id
	'
	+ @Where

	IF(@debug <> '')
	BEGIN
		IF( CHARINDEX('Verbose', @debug) > 0)
		BEGIN
			SELECT '#tType' AS '#tType', * FROM #tType
		END
		RAISERROR('-- rows from #tType -- ', 10, 1) WITH NOWAIT
	END


	-- o.parent_object_id

	IF(@debug <> '')
	BEGIN
		RAISERROR('
		(step 1) @cmd = %s
		', 10,1, @cmd) WITH NOWAIT
	END

	INSERT #list( DB, SchemaName, ObjectName, Object_id, ObjectType, ObjectSchema_id
	, [Column], column_id
	, DataTypeSchema, DataType
	, UDDTSchema, UDDT
	, Length, precision, scale
	, StorageLength, is_nullable, collation_name, is_identity)
	EXEC sp_executesql  @cmd

	IF(@debug <> '')
	BEGIN
		IF( CHARINDEX('Verbose', @debug) > 0)
		BEGIN
			SELECT '#list' AS '#list', * FROM #list
		END
		RAISERROR('-- rows from #list -- ', 10, 1) WITH NOWAIT
	END

	--, NULL, NULL, NULL
	--, NULL, NULL, NULL
	--, NULL, NULL, NULL, NULL

	-- object names
	SELECT @cmd =
	'SELECT ''' + @dbname + ''', s.name, o.name, o.object_id, o.type_desc, o.schema_id
	FROM ' + @dbname + '.sys.objects o WITH (NOLOCK)
	JOIN ' + @dbname + '.sys.schemas s WITH (NOLOCK) ON s.schema_id = o.schema_id'
	+ @Where2


	IF(@debug <> '')
	BEGIN
		RAISERROR('(step 2) @cmd = %s', 10,1, @cmd) WITH NOWAIT
	END

	INSERT #list( DB, SchemaName, ObjectName, Object_id, ObjectType, ObjectSchema_id)
	--, [Column], column_id
	--, DataTypeSchema, DataType
	--, UDDTSchema, UDDT
	--, Length, precision, scale, StorageLength, is_nullable, collation_name, is_identity)
	EXEC sp_executesql  @cmd

	-- schema names
	SELECT @cmd =
	'SELECT ''' + @dbname + ''', s.name, NULL, NULL, ''SCHEMA'', s.schema_id
	, NULL, NULL, NULL
	, NULL
	, NULL
	, NULL
	, NULL
	, NULL
	, NULL
	, NULL
	'
	+ ' FROM ' + @dbname + '.sys.schemas s WITH (NOLOCK)'
	+ @Where3

	IF(@debug <> '')
	BEGIN
		RAISERROR('(step 2) @cmd = %s', 10,1, @cmd) WITH NOWAIT
	END

	INSERT #list( DB, SchemaName, ObjectName, Object_id, ObjectType, ObjectSchema_id, [Column], column_id
	, Datatype, Length, precision, scale, StorageLength, is_nullable, collation_name, is_identity)
	EXEC sp_executesql  @cmd


	END
	SELECT @pk = @pk + 1

END
----SELECT l.* FROM #list l

SELECT l.ObjectType, l.DB, l.SchemaName, l.ObjectName, l.[Column], l.column_id
, l.DataTypeSchema, l.DataType
, l.UDDTSchema, l.UDDT

, l.Length
, l.precision
, l.scale
, l.StorageLength
, l.is_nullable
, l.collation_name
, l.is_identity
, l.Object_id
FROM #list l
ORDER BY l.ObjectType, l.DB, l.SchemaName, l.ObjectName, l.[Column]


IF(@SQLAgentJobsCount > 0)
BEGIN
	--#region SQLAgentJobsCount
	SELECT ObjectType
	, DB
	, JobName
	, Description
	--, JobEnabled
	--, start_step_id
	--, owner_sid
	, owner
	, step_id
	, step_name
	, subsystem
	, command
	, database_name
	, database_user_name
	, output_file_name
	--, notify_email_operator_id
	, EmailOpName
	, EmailOpEmailAddress
	, EmailOpPagerAddress
	, EmailOpNetSendAddress
	--, notify_netsend_operator_id
	, netsendOpName
	, netsendOpEmailAddress
	, netsendOpPagerAddress
	, netsendOpNetSendAddress
	--, notify_page_operator_id
	, pageOpName
	, pageOpEmailAddress
	, pageOpPagerAddress
	, pageOpNetSendAddress
	, job_id

	FROM #listSQLAgentJobs
	--#endregion SQLAgentJobsCount
END

SELECT @pk = NULL, @pkmax = NULL
SELECT @pk = MIN(pk), @pkmax = MAX(pk) FROM @errors

IF(@pk IS NOT NULL )
BEGIN
	SELECT 'ERRORS' AS 'Errors', * FROM @errors
END

DROP TABLE #list
END -- of proc
GO
 