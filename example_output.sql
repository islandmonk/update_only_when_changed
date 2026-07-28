--------
-- INSTEAD OF UPDATE trigger for [dbo].[note]
CREATE OR ALTER TRIGGER dbo_note__instead_of_IUD ON [dbo].[note]
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
	SET	
		  [object_id] = i.[object_id]
		, [column_id] = i.[column_id]
		, [parent_note_id] = i.[parent_note_id]
		, [note_type_id] = i.[note_type_id]
		, [note] = i.[note]
	FROM [dbo].[note] as d -- deleted
	INNER JOIN inserted as i 
		ON d.[note_id] = i.[note_id] 
	-- rows having no distinction between inserted and deleted are ignored
	
	WHERE i.[object_id] IS DISTINCT FROM d.[object_id] 
	OR i.[column_id] IS DISTINCT FROM d.[column_id] 
	OR i.[parent_note_id] IS DISTINCT FROM d.[parent_note_id] 
	OR i.[note_type_id] IS DISTINCT FROM d.[note_type_id] 
	OR i.[note] COLLATE SQL_Latin1_General_CP1_CS_AS 
		IS DISTINCT FROM d.[note] COLLATE SQL_Latin1_General_CP1_CS_AS 
	OR i.[created] IS DISTINCT FROM d.[created]  

	-- Inserts proceed as usual

	INSERT [dbo].[note] (
 		  [object_id]
		, [column_id]
		, [parent_note_id]
		, [note_type_id]
		, [note]
		, [created]
	)
	SELECT 
 		  [object_id]
		, [column_id]
		, [parent_note_id]
		, [note_type_id]
		, [note]
		, [created]
	FROM inserted as i
	WHERE NOT EXISTS (
		SELECT 1
		FROM deleted as d
		WHERE d.[note_id] = i.[note_id] 	
	)

	-- Deletes proceed  as usual

	DELETE t 
	FROM [dbo].[note] as t -- target 
	INNER JOIN deleted as d
		ON d.[note_id] = t.[note_id] 
	WHERE NOT EXISTS (
		SELECT 1
		FROM inserted as i
		WHERE d.[note_id] = i.[note_id] 	
	)
GO
--------------
