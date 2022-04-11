
/* test

exec sp_sss @String = 'Name'
, @OnlyCurrentDB = 0
*/
USE master
GO
IF  EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.sp_sss') AND type in (N'P', N'PC'))
DROP PROCEDURE dbo.sp_sss
GO
CREATE PROCEDURE dbo.sp_sss
( @String nvarchar(130) 
, @IncludeSystem bit = 0
, @OnlyCurrentDB bit = 1
, @UseWildPrefix bit = 1
, @UseWildSuffix bit = 1
, @Tables bit = 1
, @Views bit = 1
, @Indexes bit = 0
, @SProcs bit = 0
, @params nvarchar(4000) = ''
, @debug varchar(255) = ''
) AS 
/*
 Sql String Search 
 Find a string used in a object in a database
 Author: ric vander ark 
 
 Dependant on dbo.fnSplitJson2
*/
BEGIN
SET NOCOUNT ON
DECLARE @pk int, @pkmax int
, @cmd nvarchar(3000) 
, @dbname sysname
, @SearchString nvarchar(130)
, @Where nvarchar(1024)


DECLARE @tSJ TABLE
( id int NOT NULL PRIMARY KEY, name nvarchar(4000), value nvarchar(4000)
, offset int, length int, colon int, nested int, errcnt int, msg nvarchar(4000)
)

INSERT @tSJ (id, name, value, offset, length, colon, nested, errcnt, msg)
SELECT id, name, value, offset, length, colon, nested, errcnt, msg 
FROM master.dbo.fnSplitJson2(@params, NULL)





SELECT @debug = ISNULL(@debug, '')
DECLARE @db TABLE
( pk int IDENTITY
, name sysname
, id int
) 

INSERT @db(name, id)
SELECT name, database_id 
FROM master.sys.databases d
WHERE (@IncludeSystem = 1 OR (@IncludeSystem = 0 AND d.name NOT IN ('master', 'tempdb', 'model', 'msdb')))
AND (@OnlyCurrentDB = 0 OR (@OnlyCurrentDB = 1 AND d.database_id = DB_ID()))
 
SELECT @pk = MIN(pk), @pkmax = MAX(pk) FROM @db

-- SELECT * FROM @db

--RETURN

SELECT @SearchString = CASE WHEN @UseWildPrefix = 1 AND RIGHT(@String,1) <> '%' THEN '%' ELSE '' END
 + @String
+ CASE WHEN @UseWildSuffix = 1 AND RIGHT(@String,1) <> '%' THEN '%' ELSE '' END

--SELECT @String , @SearchString
--RETURN

CREATE TABLE #list 
( pk int IDENTITY
, DB sysname
, [Schema] sysname
, ObjectName sysname
, TableObject_id int
, ObjectType varchar(100)
, TableSchema_id int
, [Column] sysname
, column_id int
, Datatype sysname
, [Length] int
, StorageLength int
 )

SELECT @Where = ''
+ ' WHERE c.name LIKE N''' + @SearchString + ''''
+ CASE WHEN @IncludeSystem = 0 THEN ' AND (o.type NOT IN (''S'', ''IT''))' ELSE '' END 
 + CASE WHEN @Tables = 0 THEN ' AND (o.type NOT IN (''U'', ''S'')' ELSE '' END 
+ CASE WHEN @Views = 0 THEN ' AND (o.type <> ''V'')' ELSE '' END 
 
WHILE @pk <= @pkmax
BEGIN
 SELECT @dbname = name FROM @db WHERE pk = @pk
 
 SELECT @cmd = 
 'SELECT ''' + @dbname + ''', s.name, o.name, o.parent_object_id, o.type_desc, o.schema_id'
 + ', c.name, c.column_id, t.name'
+ ', CAST(c.max_length * t.SizeMult AS int), c.max_length'
+ ' FROM ' + @dbname + '.sys.columns c JOIN sys.objects o ON o.object_id = c.object_id'
 + ' JOIN ' + @dbname + '.sys.schemas s ON s.schema_id = o.schema_id'
+ ' JOIN (SELECT DISTINCT name, user_type_id'
+ ', CASE WHEN user_type_id IN (99,231, 256,239) THEN .5 ELSE 1 END AS SizeMult'
 + ' FROM ' + @dbname + '.sys.types WHERE is_user_defined = 0) t on t.user_type_id = c.user_type_id'
+ @Where
 
 --print @cmd
 INSERT #list( DB
 , [Schema]
 , ObjectName
 , TableObject_id
  , ObjectType
 , TableSchema_id
 , [Column]
 , column_id
 , Datatype
 , [Length]
 , StorageLength)
 EXEC sp_executesql  @cmd

 SELECT @pk = @pk + 1
END
----SELECT l.* FROM #list l

SELECT l.ObjectType, l.DB, l.[Schema], l.ObjectName, l.[Column], l.column_id, l.Datatype
 , l.[Length], l.StorageLength
, l.TableObject_id
FROM #list l
ORDER BY l.ObjectType, l.DB, l.[Schema], l.ObjectName, l.[Column]

/*
-- table column name
SELECT --top 10 
  s.name AS [Schema]
 , o.name AS ObjectName
, o.type
-- , o.parent_object_id
, o.type_desc AS ObjectType
-- , o.schema_id
, c.name AS [Column]
, c.column_id
, t.name AS Datatype
 , c.max_length
, CAST(c.max_length * t.SizeMult AS int) AS Length
, c.max_length AS StorageLength
--, c.*
FROM sys.columns c
JOIN sys.objects o ON o.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = o.schema_id
 JOIN (SELECT DISTINCT name, user_type_id
, CASE WHEN user_type_id IN (99,231, 256,239) THEN .5 ELSE 1 END AS SizeMult 
FROM sys.types WHERE is_user_defined = 0) 
t on t.user_type_id = c.user_type_id
where c.name LIKE @String
 AND (@IncludeSystem = 1 OR (@IncludeSystem = 0 AND o.type <> 'S'))
*/


DROP TABLE #list

END
GO

 
 