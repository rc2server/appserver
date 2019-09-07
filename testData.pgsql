DO $$
DECLARE userId int;
DECLARE projectId int;
DECLARE wspaceId int;
DECLARE fileId int;
DECLARE wspaceName text;
BEGIN

FOR userNum IN 1..5 LOOP

INSERT INTO rcuser (login, firstname, lastname, email)
	VALUES('login' || userNum::text, 'login', 'login', 'login' || userNum::text || '@login.login')
		RETURNING id INTO userId;

	FOR projectNum IN 1..2 LOOP
 		INSERT INTO rcproject (userid, name) VALUES (userId, 'project' || projectNum::text)
 			RETURNING id INTO projectId;
 		
 		FOR wspaceNum IN 1..2 LOOP
 			wspaceName := 'wspace ' || projectNum::text || '.' || wspaceNum::text;
 			INSERT INTO rcworkspace (name, userid, projectid) 
 				VALUES (wspaceName, userId, projectId)
 				RETURNING id INTO wspaceId;
 			
 			FOR fileNum IN 1..3 LOOP
 				INSERT INTO rcfile (wspaceid, name, filesize) 
 					VALUES (wspaceId, 'file' || fileNum::text || '.R', 9)
 					RETURNING id INTO fileId;
 				INSERT INTO rcfiledata (id, bindata) VALUES (fileId, 'rnorm(11)'::bytea);
 			END LOOP;
 		END LOOP;
	END LOOP;
END LOOP;

END $$;
