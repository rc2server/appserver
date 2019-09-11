# appserver

The latest iteration of the appserver. Written in swift using Kitura. Doesn't really function yet, but need to keep it working on macOS and Linux.

On ubuntu, requires libcurl3-gnutls-dev and libpq-dev installed.

## configuration

Need a json file called *config.json* with a dictionary containing the keys:

* dbHost - localhost
* dbPort - the port docker is mapping to. If you used the startup script it is 5434
*dbUser - rc2
*dbPassword - secret
*jwtHmacSecret: <random gibberish used a key to sign the JWTs>

## Testing

If docker is not located at  `/usr/local/bin/docker`  on your systerm, specify the path in the DOCKER_EXE environment variable before running the tests. 

