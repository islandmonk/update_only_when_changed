/*
	Hi, I'm Doug Hills
	Doug@HillsBrother.com

	I've been working with database for twenty five years or so. One of the Silverbacks! I got started with Access and moved on to SQL Server.
	For some reason, I really enjoy working with SQL Server. Over the years, I've crafted a few tricks that help with
	application performance, schema modeling, naming, code generation, whatever. I'd like to share these tricks with whoever might find
	them beneficial. I wouldn't mind feedback / suggestions either. 

	This script produces a script. The machine-generated script can be executed to modify the table of your choice 
	turning it into an UPDATE-ONLY-IF-CHANGED table. Obviously, the script could be modified to affect an 
	array of tables all at once. I don't really recommend that.

	Chief benefits of making a table behave this way:
		1)	Physical disk churn is reduced
		2)	Fewer opportunities for index and data pages to become split/fragmented
		3)	This approach would be a good first step toward making a table behave like a slowly
			changing dimension. With time-machine capabilities!
		4)	Extends SSD physical life

	Costs of this approach
		The method used by this approach is for a table to fire an INSTEAD OF trigger for crud opperations. 
		The trigger makes it such that all CRUD all behaves as expected except for UPDATES. For updates, 
		if an update would leave a row unchanged, the update against that row is not executed.

	Why is this worthwhile?
		In every database that I've created, the datamart/warehouse-ish sorts of operations that keep rollups 
		And materialized views fresh involve a lot of updates against persisted rows in order to ensure a particular 
		state. Frequently, this desired state was already the current state. So, our little routine that keeps these
		objects fresh makes a lot of maneuvers that don't change anything (except for what's in the bare metal).

		Scenario: I have 10,000,000 customers in my enterprise database. Oh no! A new rule came out! The 
		state abbreviation for the customers' addresses absolutely must be persisted in upper-case. Right now, that's the norm
		but it hasn't been enforced. The easiest way to handle this is to have your ETL process include
		an UPDATE command that will change all of those state abbreviations. It is likely that the command will
		look a little like this:
			UPDATE [customer] SET [state_abbrev] = UPPER([state_abbrev])

		This is a very simple command and might be the most likely approach that a developer would take to make sure that 
		the rows in the [customer] table follow the rule. However, everytime this command is executed, every row in the
		table will be physically updated despite the fact that almost all of the rows require no change.

		Clearly, the command could be altered with a predicate that would limit the number of rows updated. That's 
		not really the point of this scenario. Incidentally, what predicicate would identify the rows that are fine
		as is? 

		There is a cost associated with updating a row. Every update is a physical delete and a physical insert. When this 
		happens, the row that is 'updated' is (essentially) physically moved. Even if no change was made, the row is not where it 
		was before the command was executed. From this unnecessary churn, there are costs:

			moving data inevitably causes index and data page splits. Over time, this leads to our data being fragmented
			and slightly more expensive to access.

			deleting and re-writing data for no real reason puts unnecessary wear on our SSDs. SSDs are so much 
			faster than spinners that people sort of ignore the difference in cost between sequential reads and random 
			access--this is fair. Reduced fragmentation isn't as compelling as it was 20 years ago. However, the little dots 
			that the SSDs use for storing data have finite read/write cycle counts. Making it a practice of avoiding updating 
			rows that have no change will make our SSDs last longer.

			and, obviously, it's faster to not move a row than to move it.

		Analyzing the INSTEAD OF trigger created by this script shows how it works. Since most of the table refresh work that 
		I've done in my ETL experiences involve MERGE operations, and since MERGE operations include inserts, updates, and deletes,
		An INSTEAD OF trigger needs to be present for all of those operations if you wish to have INSTEAD OF behaviors for any 
		of them. It would be nice if a merge invoked the INSTEAD OF	UPDATE only for updates and just behaved as normal for the 
		inserts and deletes. But, if a table has an INSTEAD OF trigger defined for *any* operation that occurs in a MERGE, the MERGE 
		will fail unless the table also has an INSTEAD OF trigger for *all* operations.

		The insert and delete portions of the INSTEAD OF trigger created below just make sure that inserts
		and deletes occur exactly as before. 
*/
DECLARE 
	  @table_name varchar(250) = '[flight_recorder].[event_rh]' -- any table name that you want here
	, @table_object_id int
	, @trigger_name varchar(250)
	, @join_predicate varchar(250) = ''
	, @d_join_predicate varchar(250) = '' -- join predicate against deleted psuedotable
	, @i_d_match_predicate varchar(250) = '' -- inserted / deleted psuedotable match predicate
	, @row_hash_columns varchar(max) = ''
	, @set_columns varchar(max) = ''
	, @insert_columns varchar(max) = ''
	, @cmd varchar(max) 
	, @cr char(2) = CHAR(13) + CHAR(10)
	, @tab CHAR(1) = char(9)

SELECT @table_object_id = OBJECT_ID(@table_name)

SELECT @trigger_name = SCHEMA_NAME(t.schema_id) + '_' + t.[name] + '__instead_of_IUD'
FROM sys.tables as t
WHERE t.[object_id] = @table_object_id

-- We'll construct a command that we can execute to make the necessary modifications to the 
-- table to make it manage it's own updates.
-- Chunks of TSQL are generated independetly because that is the easiest way I could think of
-- for doing it. The chuncks are slid into the @cmd variable with text replacement. This gives
-- @cmd its desired value before we execute.
SELECT 
	  @table_object_id = OBJECT_ID(@table_name)
	, @cmd = '
-- Add row_hash column to table {{table_name}}
ALTER TABLE {{table_name}} ADD row_hash as HASHBYTES(''sha2_512'', CONCAT({{row_hash_columns}})
) PERSISTED; 
GO

--------
-- INSTEAD OF UPDATE trigger for {{table_name}}
CREATE OR ALTER TRIGGER {{trigger_name}} ON {{table_name}}
INSTEAD OF UPDATE, INSERT, DELETE 
AS
	-- Doug@HillsBrother.com

	UPDATE t
	SET	{{set_columns}}
	FROM {{table_name}} as t -- target
	INNER JOIN inserted as s -- source
	{{join_predicate}}
	-- rows where there is no difference between inserted and deleted are ignored
	WHERE t.[row_hash] <> s.[row_hash] 

	-- insert all rows that are in the inserted psuedotable
	-- that don''t have corresponding rows in the deleted psuedotable
	INSERT {{table_name}} (
{{insert_columns}}
	)
	SELECT 
{{insert_columns}}
	FROM inserted as i
	WHERE NOT EXISTS (
		SELECT TOP 1 1
		FROM deleted as d
	{{i_d_match_predicate}}	
	)

	-- delete all rows that are in the deleted psuedotable
	-- that don''t have corresponding rows in the inserted psuedotable
	DELETE t 
	FROM {{table_name}} as t
	INNER JOIN deleted as d
	{{d_join_predicate}}
	WHERE NOT EXISTS (
		SELECT TOP 1 1
		FROM inserted as i
	{{i_d_match_predicate}}	
	)
GO
--------------'

SELECT @row_hash_columns +=
	@cr + @tab + CASE rn WHEN 1 THEN '  ' ELSE ', ' END + '[' + [column_name] + ']' 
	-- columns should only be added to the row hash if they are non-rtirivial and non-derived.
	-- Adding a calculated column to this row_hash calc would be a mistake.
FROM (
	SELECT 
		  c.[name] as [column_name]
		, ROW_NUMBER() OVER (ORDER BY c.[column_id]) as rn
	FROM sys.schemas as s
	INNER JOIN sys.tables as t
		ON s.[schema_id] = t.[schema_id]
	INNER JOIN sys.columns as c
		ON t.[object_id] = c.[object_id]
	WHERE t.[object_id] = @table_object_id
	AND c.is_computed = 0
	AND NOT EXISTS (
		SELECT TOP 1 1 as is_part_of_pk
		FROM sys.indexes as i
		INNER JOIN sys.index_columns as ic
			ON i.[object_id] = ic.[object_id]
			AND i.[index_id] = ic.[index_id]
		WHERE i.is_primary_key = 1
		AND t.[object_id] = i.[object_id]
		AND c.column_id = ic.column_id
	)
) as x
	ORDER BY [rn]

SELECT @insert_columns +=
	-- Any column that is not caclculated or otherwise automatically renderered (such as an identity column)
	-- should be included in the insert
	CASE rn WHEN 1 THEN ' ' ELSE @cr END 
	+ @tab + @tab 
	+ CASE rn WHEN 1 THEN '  ' ELSE ', ' END + '[' + [column_name] + ']' 
FROM (
	SELECT 
		  c.[name] as [column_name]
		, ROW_NUMBER() OVER (ORDER BY c.[column_id]) as rn
	FROM sys.schemas as s
	INNER JOIN sys.tables as t
		ON s.[schema_id] = t.[schema_id]
	INNER JOIN sys.columns as c
		ON t.[object_id] = c.[object_id]
	WHERE t.[object_id] = @table_object_id
	AND c.is_computed = 0
	AND c.is_identity = 0
) as x
	ORDER BY [rn]

-- join predicate needs to be based on pk 
SELECT 
	  @join_predicate +=
		CASE WHEN ic.index_column_id = 1 THEN '' ELSE @cr + @tab END
		+ @tab 
		+ CASE WHEN ic.index_column_id = 1 THEN 'ON ' ELSE 'AND ' END + 't.[' + c.[name] + '] = s.[' + c.[name] + '] '

	, @i_d_match_predicate +=
		CASE WHEN ic.index_column_id = 1 THEN '' ELSE @cr + @tab END
		+ @tab 
		+ CASE WHEN ic.index_column_id = 1 THEN 'WHERE ' ELSE 'AND ' END + 'i.[' + c.[name] + '] = d.[' + c.[name] + '] '
FROM sys.tables as t
INNER JOIN sys.columns as c
	ON t.[object_id] = c.[object_id]
INNER JOIN sys.indexes as i
	ON t.[object_id] = i.[object_id]
	AND i.is_primary_key = 1
INNER JOIN sys.index_columns as ic
	ON t.[object_id] = ic.[object_id]
	AND i.[index_id] = ic.[index_id]
	AND c.[column_id] = ic.[column_id]
WHERE t.[object_id] = @table_object_id
ORDER BY ic.index_column_id

SELECT @d_join_predicate = REPLACE(@join_predicate, 's.[', 'd.[')



-- set all columns not included in PK 
SELECT @set_columns +=
	@cr + @tab + @tab + CASE rn WHEN 1 THEN '  ' ELSE ', ' END + '[' + [column_name] + '] = s.[' + [column_name] + ']'
FROM (
	SELECT 
		  c.[name] as [column_name]
		, ROW_NUMBER() OVER (ORDER BY c.[column_id]) as rn
	FROM sys.schemas as s
	INNER JOIN sys.tables as t
		ON s.[schema_id] = t.[schema_id]
	INNER JOIN sys.columns as c
		ON t.[object_id] = c.[object_id]
	WHERE t.[object_id] = @table_object_id

	-- computed columns can't be updated. They should NOT be included
	-- in the row_hash calc
	AND c.is_computed = 0

	-- PK columns should not be included in the row_hash calc
	-- for academic reasons
	-- They could be added with no harm. Adding them contributes nothing and makes
	-- the row_hash rendering marginally more expensive
	AND NOT EXISTS (
		SELECT TOP 1 1 as is_part_of_pk
		FROM sys.indexes as i
		INNER JOIN sys.index_columns as ic
			ON i.[object_id] = ic.[object_id]
			AND i.[index_id] = ic.[index_id]
		WHERE i.is_primary_key = 1
		AND t.[object_id] = i.[object_id]
		AND c.column_id = ic.column_id
	)

	-- Any columns that, as a matter of policy, are never to be 
	-- included in the row_hash calc. 
	AND c.[name] NOT IN ('created', 'modified')
) as x
	ORDER BY [rn]


SELECT @cmd = REPLACE(@cmd, '{{table_name}}'			, @table_name)
SELECT @cmd = REPLACE(@cmd, '{{row_hash_columns}}'		, @row_hash_columns)
SELECT @cmd = REPLACE(@cmd, '{{trigger_name}}'			, @trigger_name)
SELECT @cmd = REPLACE(@cmd, '{{insert_columns}}'		, @insert_columns)
SELECT @cmd = REPLACE(@cmd, '{{set_columns}}'			, @set_columns)
SELECT @cmd = REPLACE(@cmd, '{{join_predicate}}'		, @join_predicate)
SELECT @cmd = REPLACE(@cmd, '{{d_join_predicate}}'		, @d_join_predicate)
SELECT @cmd = REPLACE(@cmd, '{{i_d_match_predicate}}'	, @i_d_match_predicate)

PRINT @cmd
