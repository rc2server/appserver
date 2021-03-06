#!/bin/bash

# all tests should execute "drop owned by current_user"

# stop docker container on exit
function finish {
	docker stop appserver_test
}
#trap finish EXIT
PDIR=`pwd`
SQLFILE="${PDIR}/rc2root/rc2.sql"
export KITURA_NIO=1
echo "looking for ${SQLFILE}"
docker run --name appserver_test -e POSTGRES_PASSWORD="apptest" -p 5434:5432 --rm -d postgres:11
echo "waiting for db to start"
sleep 5;
docker logs appserver_test
docker exec appserver_test psql -U postgres -c "create database rc2;"
docker exec appserver_test psql -U postgres -c "create extension if not exists pgcrypto;"
docker exec appserver_test psql -U postgres -c "create user rc2 superuser password 'secret';"
docker exec appserver_test psql -U postgres -c "grant all privileges on database rc2 to rc2;"
docker cp "${SQLFILE}" appserver_test:/tmp/rc2.sql
docker exec appserver_test psql -U postgres -d rc2 --file=/tmp/rc2.sql
docker exec appserver_test psql -U rc2 -c "select rc2CreateUser('rc2', 'local', 'Account', 'singlesignin@rc2.io', 'local');"
docker cp testData.pgsql appserver_test:/tmp/testData.sql
docker exec appserver_test psql -U rc2 -d rc2 -f /tmp/testData.sql 
sleep 1;
echo "server ready"

#while true
#do
#	sleep 5
#done

#swift test

