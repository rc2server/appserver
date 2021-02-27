# appserver

The appserver for rc2. Uses swift 5.3

(this was in old version, not sure if still true)
On ubuntu, requires libcurl3-gnutls-dev and libpq-dev installed.

## building

`swift build` will not work unless you do ` export KITURA_NIO=1` once (or put in .bash_profile)

## configuration

when running uses config.json. if `export RC2_CONFIG_FILE_NAME=config-test.json` is set, that file name will be used. Can be passed to the container via docker or docker-compose.

The following environment variables can be used to override the config file:

<dl>
	<dt>RC2_LOG_CLIENT_IN</dt>
	<dd>If set, log JSON received from a client</dd>
	<dt>RC2_LOG_CLIENT_OUT</dt>
	<dd>If set, all JSON sent to the cient will be logged</dd>
	<dt>RC2_LOG_COMPUTE_IN</dt>
	<dd>If set, all JSON received from compute is logged</dd>
	<dt>RC2_LOG_COMPUTE_OUT</dt>
	<dd>If set, all JSON sent to compute is logged</dd>
</dl>

## working with Xcode

Xcode will not work by opening Package.swift. Instead, use `swift package generate-xcodeproj`. Open it, then edit the schema. Add `-p 3415` to arguments, and `RC2_CONFIG_FILE_NAME = xcode-debug.json` to environment variables. 

Start the dbserver and compute using `docker-compose -f compose-xcode.yml up` from the rc2root/containers directory.

## db setup

if rcuser is empty, run `psql -c "select rc2CreateUser('local', 'Local', 'Account', 'singlesignin@rc2.io', 'local');"` This does not apply if testing with docker

## Testing

Run `setupDockerForTesting.sh` to start the docker container for testing. It is set to auto remove, so just run `docker stop appserver_test` to stop testing.

If docker is not located at  `/usr/local/bin/docker`  on your systerm, specify the path in the DOCKER_EXE environment variable before running the tests. 

## to fix

## notes

need to run `export KITURA_NIO=1` before building

For testing, run `export RC2_CONFIG_FILE_NAME=config-test.json`

