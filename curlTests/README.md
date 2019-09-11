# curl Tests

These are files for testing the app server while it is running.

## prepare test database

pick a user and set their password. `docker exec -it appserver_test bash` will give you a shell, then you can use psql `psql -U rc2 rc2`. To set a password, use

`update rcuser set passwordData = crypt('foobar', gen_salt('bf', 8)) where id = 100;`

That will then make the login.json correct.

## login

adjust the path if running from inside curlTests directory. 

`url -v -X POST -H "Content-Type: application/json" -d @curlTests/login.json http://localhost:8088/login`

That will return a JWT string you need to add to the authorization header on every request:

`eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzUxMiJ9.eyJpZCI6LTEsInVzZXJJZCI6MTAwfQ.o7fFe_Qc0JNZxJOGCyjKDSXcwIabkJD-7PajgvO5bHnQdSjfH5nI_ew0_J_fu6OTHTTA2HOFFMJNIJSe2Ar1WQ`

## Get info

 `curl -v -H "Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzUxMiJ9.eyJpZCI6LTEsInVzZXJJZCI6MTAwfQ.o7fFe_Qc0JNZxJOGCyjKDSXcwIabkJD-7PajgvO5bHnQdSjfH5nI_ew0_J_fu6OTHTTA2HOFFMJNIJSe2Ar1WQ" http://localhost:8088/info`
 
 ## Logout
 
 this should invalidate the token and require logging in before another URL will not return _401 unauthorized_
 
`curl -v -X DELETE  -H "Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGcsInVzZXJJZCI6MTAwfQ.o7fFe_Qc0JNZxJOGCyjKDSXcwIabkJD-7PajgvO5bHnQdSjfH5nI_ew0_J_fu6OTHTTA2HOFFMJNIJSe2Ar1WQ" http://localhost:8088/login`
