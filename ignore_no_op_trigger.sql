/*
	Hi, I'm Doug Hills
	Doug@HillsBrother.com

	This script produces a script. The resulting machine-generated script can be executed to modify the table of your choice 
	turning it into an UPDATE-ONLY-IF-CHANGED table. Obviously, the script could be modified to affect an array of tables all 
	at once. I don't really recommend that.

	The trigger produced by this script is INSTEAD OF INSERT, UPDATE, DELETE

	The reason that it is for all operations is that if the table encounters a MERGE command where INSERTs and DELETEs
	might be happening with the UPDATEs, there needs to be an INSTEAD OF INSERT and INSTEAD OF DELETE for the table
	as well. So this trigger does everything. If the table doesn't need to anticipate MERGE operations, all but the
	update parts of the trigger can be removed.

	Compound primary keys are fine. But running this against a table with no PK will generate mush.

	Chief benefits of making a table behave this way:
		1)	Physical disk churn is reduced
		2)	Fewer opportunities for index and data pages to become split/fragmented
		3)	This approach would be a good first step toward making a table behave like a slowly
			changing dimension. With time-travel capabilities!
		4)	Extends SSD physical life

	Costs of this approach
		The method used by this approach is for a table to fire an INSTEAD OF trigger for crud opperations. 
		The trigger makes it such that all CRUD all behaves as expected except for UPDATEs. For updates, 
		if an update were to leave a row unchanged, it is simply skipped. The cost of knowing if a row is changed
		or not is a compound predicate acting as gatekeeper to the UPDATE operation. The approach used here uses
		IS DISTINCT FROM for each non-key column irrespective of its NULLability. This at least keeps the
		trigger less sensitive to NULLability and data type changes in its schema. Wnenever the table's schema *does*
		otherwise change, it will be necessary to rerun this script to produce a revised INSTEAD OF UPDATE trigger.
		This revised script must then be executed against the database containing the table.

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
		table will be physically updated despite the fact that almost all of them already contain the desired values.

		Clearly, the command could be altered with a predicate that would limit the number of rows updated. That's 
		not really the point of this scenario--let's stay focused. But it *is* good to bring that up. Not all of the hands
		touching our databases are as gentle as ours, yes? Incidentally, what predicicate would identify the rows that are fine
		as is? 

		There is a cost associated with updating a row. Every update is a physical delete and a physical insert. When this 
		happens, the row that is 'updated' is (essentially) physically moved. Even if no change was made, the row is not where it 
		was before the command was executed. From this unnecessary churn, there are costs:

			moving data inevitably causes index and data page splits. Over time, this leads to our data being fragmented
			and slightly more expensive to access.

			deleting and re-writing data for no real reason puts unnecessary wear on our SSDs. SSDs are so much 
			faster than spinners that people sort of ignore the difference in cost between sequential reads and random 
			access. That's fair. Reduced fragmentation isn't as compelling as it was 20 years ago. However, the little dots 
			that the SSDs use for storing data have finite read/write cycle counts. Making it a practice of avoiding updating 
			rows that have no change will extend the reliability of our SSDs.

			and, obviously, it's faster to not move a row than to move it.

		Analyzing the INSTEAD OF trigger created by this script shows how it works. Since most of the table refresh work that 
		I've done in my ETL experiences involve MERGE operations, and since MERGE operations include inserts, updates, and deletes,
		An INSTEAD OF trigger needs to be present for all of those operations if you wish to have INSTEAD OF behaviors for any 
		of them. It would be nice if a merge invoked the INSTEAD OF	UPDATE only for updates and just behaved as normal for the 
		inserts and deletes. But, if a table has an INSTEAD OF trigger defined for *any* operation that occurs in a MERGE, the MERGE 
		will fail unless the table also has an INSTEAD OF trigger for *all* operations. I'm repeating myself here. Unnecessarily?

		The insert and delete portions of the INSTEAD OF trigger created below just make sure that inserts
		and deletes occur exactly as before. 

		Paul White's article on redundant updates:
		https://www.sql.kiwi/2010/08/the-impact-of-non-updating-updates.html?m=1
*/
DECLARE 
	  @table_name			varchar(250) = '[dbo].[note]' -- any table name that you want here
	, @two_part_table_name	varchar(250)
	, @table_object_id		int
	, @trigger_name			varchar(250)
	, @match_predicate		varchar(250) = '' -- inserted / deleted psuedotable match predicate
	, @join_predicate		varchar(250) = ''
	, @join_predicate_d		varchar(250) = ''
	, @is_changed_predicate	varchar(max) = ''
	, @set_columns			varchar(max) = ''
	, @insert_columns		varchar(max) = ''
	, @cmd					varchar(max) 
	, @cr					char(2) = CHAR(13) + CHAR(10)
	, @tab					CHAR(1) = char(9)
	, @message				varchar(250)

SELECT @table_object_id = OBJECT_ID(@table_name)

IF @table_object_id IS NULL
BEGIN
	SELECT @message = 'I''m Sorry Dave. I don''t think that that table ' + @table_name + ' exists.'
	PRINT @message
	RETURN
END 

IF NOT EXISTS (
	SELECT 1
	FROM sys.indexes as i
	WHERE [object_id] = @table_object_id
	AND i.is_primary_key = 1
)
BEGIN
	SELECT @message = 'I''m Sorry Dave. I don''t think that that table ' + @table_name + ' has a primary key. We really need one.'
	PRINT @message
	RETURN
END

SELECT 
	  @two_part_table_name = '[' + SCHEMA_NAME(t.[schema_id]) + '].[' + t.[name] + ']'
	, @trigger_name = SCHEMA_NAME(t.schema_id) + '_' + t.[name] + '__instead_of_IUD'
FROM sys.tables as t
WHERE [object_id] = @table_object_id

-- Construct a command that we can execute to make the necessary modifications to the 
-- table to make it ignore redundant updates.

SELECT 
	  @table_object_id = OBJECT_ID(@table_name)
	, @cmd = '
--------
-- INSTEAD OF UPDATE trigger for {{table_name}}
CREATE OR ALTER TRIGGER {{trigger_name}} ON {{table_name}}
INSTEAD OF UPDATE, INSERT, DELETE 
AS
	/*
	-- Doug@HillsBrother.com

	This is the definition of an INSTEAD OF trigger. Its initial purpose is to reduce churn on tables
	mostly for the sake of performance. There is nothing stopping you from altering this trigger to
	add other functionality. Important Note: you are allowed AFTER UPDATE triggers on the same
	table as one with an INSTEAD OF UPDATE trigger. AFTER UPDATE business logic is still available 
	to you even if you go with this approach.
	*/

	UPDATE d
	SET	{{set_columns}}
	FROM {{table_name}} as d -- deleted
	INNER JOIN inserted as i 
	{{join_predicate}}
	-- rows having no distinction between inserted and deleted are ignored
	{{is_changed_predicate}} 

	-- Inserts proceed as usual

	INSERT {{table_name}} (
{{insert_columns}}
	)
	SELECT 
{{insert_columns}}
	FROM inserted as i
	WHERE NOT EXISTS (
		SELECT 1
		FROM deleted as d
	{{match_predicate}}	
	)

	-- Deletes proceed  as usual

	DELETE t 
	FROM {{table_name}} as t -- target 
	INNER JOIN deleted as d
	{{join_predicate_d}}
	WHERE NOT EXISTS (
		SELECT 1
		FROM inserted as i
	{{match_predicate}}	
	)
GO
--------------'

SELECT @is_changed_predicate +=
	  @cr + @tab 
	+ CASE rn 
		WHEN 1 THEN 'WHERE ' 
		ELSE 'OR ' 
	  END 
	+ 'i.[' + [column_name] + '] ' 
	+ col8
	+ CASE 
		WHEN LEN(col8) > 0 THEN @cr + @tab + @tab
		ELSE ''
	  END
	+ 'IS DISTINCT FROM d.[' + [column_name] + '] '
	+ col8
	-- columns should only be added to the predicate if they are non-trivial and non-derived.
	-- Adding a calculated column to this predicate calc would be a mistake.
FROM (
	SELECT 
		  c.[name] as [column_name]
		, CASE c.collation_name
			WHEN 'SQL_Latin1_General_CP1_CI_AS'
			THEN 'COLLATE SQL_Latin1_General_CP1_CS_AS '
			ELSE ''
		  END as col8
		, ROW_NUMBER() OVER (ORDER BY c.[column_id]) as rn
	FROM sys.schemas as s
	INNER JOIN sys.tables as t
		ON s.[schema_id] = t.[schema_id]
	INNER JOIN sys.columns as c
		ON t.[object_id] = c.[object_id]
	WHERE t.[object_id] = @table_object_id
	AND c.is_computed = 0
	AND NOT EXISTS (
		SELECT 1 as is_part_of_pk
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
	-- should be included in the insert. That might sound confusing. Absolutely *DO* include the identity
	-- column
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
		+ CASE WHEN ic.index_column_id = 1 THEN 'ON ' ELSE 'AND ' END + 'd.[' + c.[name] + '] = i.[' + c.[name] + '] '
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

SELECT 
	  @match_predicate = REPLACE(@join_predicate, 'ON d.[', 'WHERE d.[')
	, @join_predicate_d = REPLACE(@join_predicate, '= i.[', '= t.[')

-- set all columns not included in PK 
SELECT @set_columns +=
	@cr + @tab + @tab + CASE rn WHEN 1 THEN '  ' ELSE ', ' END + '[' + [column_name] + '] = i.[' + [column_name] + ']'
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
	-- in the compound predicate
	AND c.is_computed = 0

	-- PK columns should not be included in the compound predicate. They wouldn't hurt
	-- anything. Leave them out nonetheless. Adding them contributes nothing
	-- while making the compound predicate marginally more expensive.
	AND NOT EXISTS (
		SELECT 1 as is_part_of_pk
		FROM sys.indexes as i
		INNER JOIN sys.index_columns as ic
			ON i.[object_id] = ic.[object_id]
			AND i.[index_id] = ic.[index_id]
		WHERE i.is_primary_key = 1
		AND t.[object_id] = i.[object_id]
		AND c.column_id = ic.column_id
	)

	-- Any columns that, for whatever reason, are never to be 
	-- included in the IS_CHANGED predicate. 
	-- WARNING: Add to this list at your peril.
	--  		Innappropriately ignoring a changed field is not in
	-- 			the data industry's top ten list of Best Practices.
	AND c.[name] NOT IN ('created', 'modified')
) as x
ORDER BY [rn]


SELECT @cmd = REPLACE(@cmd, '{{table_name}}'			, @two_part_table_name)
SELECT @cmd = REPLACE(@cmd, '{{is_changed_predicate}}'	, @is_changed_predicate)
SELECT @cmd = REPLACE(@cmd, '{{trigger_name}}'			, @trigger_name)
SELECT @cmd = REPLACE(@cmd, '{{insert_columns}}'		, @insert_columns)
SELECT @cmd = REPLACE(@cmd, '{{set_columns}}'			, @set_columns)
SELECT @cmd = REPLACE(@cmd, '{{join_predicate}}'		, @join_predicate)
SELECT @cmd = REPLACE(@cmd, '{{join_predicate_d}}'		, @join_predicate_d)
SELECT @cmd = REPLACE(@cmd, '{{match_predicate}}'		, @match_predicate)

--print @join_predicate
--print @join_predicate_d
PRINT @cmd

