
[![Docker Image Version (latest by date)](https://img.shields.io/docker/v/ejabberd/ecs)](https://hub.docker.com/r/ejabberd/ecs/)
[![Docker Image Size (latest by date)](https://img.shields.io/docker/image-size/ejabberd/ecs)](https://hub.docker.com/r/ejabberd/ecs/)
[![Docker Stars](https://img.shields.io/docker/stars/ejabberd/ecs)](https://hub.docker.com/r/ejabberd/ecs/)
[![Docker Pulls](https://img.shields.io/docker/pulls/ejabberd/ecs)](https://hub.docker.com/r/ejabberd/ecs/)
[![Build Status](https://github.com/processone/docker-ejabberd/actions/workflows/tests.yml/badge.svg)](https://github.com/processone/docker-ejabberd/actions/workflows/tests.yml)
[![GitHub stars](https://img.shields.io/github/stars/processone/docker-ejabberd?style=social)](https://github.com/processone/docker-ejabberd)

# ejabberd Community Server

ejabberd is an open-source XMPP server, robust, scalable and modular,
built using Erlang/OTP, and also includes MQTT Broker and SIP Service.

This Docker image allows you to run a single node ejabberd instance in a Docker container.

If you are using a Windows operating system, check the tutorials mentioned in
[ejabberd Docs > Docker Image](https://docs.ejabberd.im/admin/installation/#docker-image).

# Start ejabberd

## With default configuration

You can start ejabberd in a new container with the following command:

```bash
docker run --name ejabberd -d -p 5222:5222 ghcr.io/badlop/ejabberd-edi
```

This command will run Docker image as a daemon,
using ejabberd default configuration file and XMPP domain "localhost".
Check the available
[ejabberd packages](https://github.com/badlop?tab=packages&repo_name=ejabberd).

To stop the running container, you can run:

```bash
docker stop ejabberd
```

If needed, you can restart the stopped ejabberd container with:

```bash
docker restart ejabberd
```

## Start with Erlang console attached

If you would like to start ejabberd with an Erlang console attached you can use the `live` command:

```bash
docker run --name ejabberd -it -p 5222:5222 ghcr.io/badlop/ejabberd-edi live
```

This command will use default configuration file and XMPP domain "localhost".

## Start with your configuration and database

The following command will pass config file using Docker volume feature
and share local directory to store database.
Notice that ejabberd is ran in the container with an account named 'ejabberd',
and the volumes you mount must grant proper rights to that account.

```bash
mkdir database
chown ejabberd database

cp ejabberd.yml.example ejabberd.yml

docker run --name ejabberd -it \
  -v $(pwd)/ejabberd.yml:/opt/ejabberd/conf/ejabberd.yml \
  -v $(pwd)/database:/opt/ejabberd/database \
  -p 5222:5222 ghcr.io/badlop/ejabberd-edi live
```

# Next steps

## Register the administrator account

The default ejabberd configuration has not granted admin privilege
to any account,
you may want to register a new account in ejabberd
and grant it admin rights.

You can register this account using the `ejabberdctl` script, for example:

```bash
docker exec -it ejabberd ejabberdctl register admin localhost passw0rd
```

Then edit conf/ejabberd.yml and add the ACL as explained in
[ejabberd Docs: Administration Account](https://docs.ejabberd.im/admin/installation/#administration-account)

## Check ejabberd log files

You can execute a Docker command to check the content of the log files from
inside to container, even if you do not put it on a shared persistent drive:

```bash
docker exec -it ejabberd tail -f logs/ejabberd.log
```

## Inspect the container files

The container uses Debian GNU/Linux. You can start a shell there with:

```bash
docker exec -it ejabberd bash
```

## Open ejabberd debug console

You can open a live debug Erlang console attached to a running container:

```bash
docker exec -it ejabberd ejabberdctl debug
```

## CAPTCHA

ejabberd includes two example CAPTCHA scripts.
If you want to use any of them, first install some additional required libraries:

```bash
docker exec --user root ejabberd apt-get update
docker exec --user root ejabberd apt-get install -y --no-install-recommends gsfonts imagemagick

```

Now update your ejabberd configuration file, for example:
```bash
docker exec -it ejabberd vi conf/ejabberd.yml
```

and add the required options:
```
captcha_cmd: /opt/ejabberd-22.04/lib/ejabberd-22.04/priv/bin/captcha.sh
captcha_url: https://localhost:5443/captcha
```

Finally, reload the configuration file or restart the container:
```bash
docker exec ejabberd ejabberdctl reload_config
```

# Advanced Docker configuration

## Ports

This Docker image exposes the ports:

- `5222`: The default port for XMPP clients.
- `5269`: For XMPP federation. Only needed if you want to communicate with users on other servers.
- `5280`: For admin interface.
- `5443`: With encryption, used for admin interface, API, CAPTCHA, OAuth, Websockets and XMPP BOSH.
- `1883`: Used for MQTT
- `4369-4399`: EPMD and Erlang connectivity, used for `ejabberdctl` and clustering

## Volumes

ejabberd produces two types of data: log files and database (Mnesia).
This is the kind of data you probably want to store on a persistent or local drive (at least the database).

Here are the volume you may want to map:

- `/opt/ejabberd/conf/`: Directory containing configuration and certificates
- `/opt/ejabberd/database/`: Directory containing Mnesia database.
You should back up or export the content of the directory to persistent storage
(host storage, local storage, any storage plugin)
- `/opt/ejabberd/logs/`: Directory containing log files
- `/opt/ejabberd/upload/`: Directory containing uploaded files. This should also be backed up.

All these files are owned by `ejabberd` user inside the container.

It's possible to install additional ejabberd modules using Docker volumes,
check [this comment](https://github.com/processone/docker-ejabberd/issues/81#issuecomment-1036115146)
explains how to install an additional module using docker-compose.

## Commands on start (REVISAR)

The ejabberdctl script reads the `CTL_ON_CREATE` environment variable
the first time the docker container is started,
and reads `CTL_ON_START` every time the container is started.
Those variables can contain one ejabberdctl command,
or several commands separated with the blankspace and `;` characters.

Example usage (see the full [docker-compose.yml](https://github.com/processone/docker-ejabberd/issues/64#issuecomment-887741332) example):
```yaml
    environment:
      - CTL_ON_CREATE=register admin localhost asd
      - CTL_ON_START=stats registeredusers ;
                     check_password admin localhost asd ;
                     status
```

## Clustering (REVISAR)

When setting several Docker containers to form a
[cluster of ejabberd nodes](https://docs.ejabberd.im/admin/guide/clustering/),
each one must have a different
[Erlang Node Name](https://docs.ejabberd.im/admin/guide/security/#erlang-node-name)
and the same
[Erlang Cookie](https://docs.ejabberd.im/admin/guide/security/#erlang-cookie).

For this you can either:
- edit `conf/ejabberdctl.cfg` and set variables `ERLANG_NODE` and `ERLANG_COOKIE`
- set the environment variables `ERLANG_NODE_ARG` and `ERLANG_COOKIE`

Example using environment variables (see the full [docker-compose.yml](https://github.com/processone/docker-ejabberd/issues/64#issuecomment-887741332) example):
```yaml
    environment:
      - ERLANG_NODE_ARG=ejabberd@node7
      - ERLANG_COOKIE=dummycookie123
```

## Clustering (REVISAR)

When setting several Docker containers to form a
[cluster of ejabberd nodes](https://docs.ejabberd.im/admin/guide/clustering/),
each one must have a different
[Erlang Node Name](https://docs.ejabberd.im/admin/guide/security/#erlang-node-name)
and the same
[Erlang Cookie](https://docs.ejabberd.im/admin/guide/security/#erlang-cookie).

For this you can edit `conf/ejabberdctl.cfg`
variables `ERLANG_NODE` and `ERLANG_COOKIE`,
or set the environment variables `ERLANG_NODE_ARG` and `ERLANG_COOKIE`.

Example usage (see the full [docker-compose.yml](https://github.com/processone/docker-ejabberd/issues/64#issuecomment-887741332) example):
```yaml
    environment:
      - ERLANG_NODE_ARG=ejabberd@node7
      - ERLANG_COOKIE=dummycookie123
```

# Generating ejabberd release

## Configuration (REVISAR)

Image is built by embedding an ejabberd Erlang/OTP standalone release in the image.

The configuration of ejabberd Erlang/OTP release is customized with:

- `rel/config.exs`: Customize ejabberd release
- `rel/dev.exs`: ejabberd environment configuration for development release
- `rel/prod.exs`: ejabberd environment configuration for production Docker release
- `vars.config`: ejabberd compilation configuration options
- `conf/ejabberd.yml`: ejabberd default config file

Build ejabberd Community Server base image from ejabberd master on Github:

```bash
docker build -t ejabberd/ecs .
```

Build ejabberd Community Server base image for a given ejabberd version:

```bash
./build.sh 18.03
```
