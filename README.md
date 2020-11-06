# appserver

The appserver for rc2. Uses swift 5.3

(this was in old version, not sure if still true)
On ubuntu, requires libcurl3-gnutls-dev and libpq-dev installed.

## building

`swift build` will not work unless you do ` export KITURA_NIO=1` once (or put in .bash_profile)

## configuration

when running uses config.json. When not in docker, use to use the debug config `export RC2_CONFIG_FILE_NAME=config-test.json`

## db setup

if rcuser is empty, run `psql -c "select rc2CreateUser('local', 'Local', 'Account', 'singlesignin@rc2.io', 'local');"` This does not apply if testing with docker

## Testing Using Docker

If docker is not located at  `/usr/local/bin/docker`  on your systerm, specify the path in the DOCKER_EXE environment variable before running the tests. 

## to fix

## notes

need to run `export KITURA_NIO=1` before building

for testing, run `export RC2_CONFIG_FILE_NAME=config-test.json`

