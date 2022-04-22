ejabberd Community Edition
==========================

[![CI](https://github.com/processone/ejabberd/actions/workflows/ci.yml/badge.svg)](https://github.com/processone/ejabberd/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/processone/ejabberd/badge.svg?branch=master "Coverage in coveralls.io")](https://coveralls.io/github/processone/ejabberd?branch=master)
[![Translation status](https://hosted.weblate.org/widgets/ejabberd/-/ejabberd-po/svg-badge.svg "Translation status in Weblate")](https://hosted.weblate.org/projects/ejabberd/ejabberd-po/)
[![Hex version](https://img.shields.io/hexpm/v/ejabberd.svg "Hex version")](https://hex.pm/packages/ejabberd)

[ejabberd][home] is an open-source,
robust, scalable and extensible realtime platform built using [Erlang/OTP][erlang],
that includes [XMPP][xmpp] Server, [MQTT][mqtt] Broker and [SIP][sip] Service.

There is a [detailed feature list][features] in the [ejabberd Documentation][docs].

[home]: https://ejabberd.im/
[erlang]: https://www.erlang.org/
[xmpp]: https://xmpp.org/
[mqtt]: https://mqtt.org/
[sip]: https://en.wikipedia.org/wiki/Session_Initiation_Protocol
[docs]: https://docs.ejabberd.im
[features]: https://docs.ejabberd.im/admin/introduction/


Installation
------------

There are several ways to install ejabberd:
* Source code: compile yourself, see [COMPILE](COMPILE.md)
* Installers with GUI from [ProcessOne Downloads][p1dl]
* Installers from [ejabberd GitHub Releases][ghr]
* Container images from [ejabberd Github Packages][ghp], see [CONTAINER](CONTAINER.md)
* Container images from [ejabberd Docker Hub][dhecs], see [ecs README][edhreadme]
* Using your [Operating System package][osp]
* Using the [Homebrew][hb] package manager

[p1dl]: https://www.process-one.net/en/ejabberd/downloads/
[ghr]: https://github.com/processone/ejabberd/releases
[osp]: https://docs.ejabberd.im/admin/installation/#operating-system-packages
[ghp]: https://github.com/processone/ejabberd/pkgs/container/ejabberd
[dhecs]: https://hub.docker.com/r/ejabberd/ecs/
[edhreadme]: https://github.com/processone/docker-ejabberd/tree/master/ecs#readme
[hb]: https://docs.ejabberd.im/admin/installation/#homebrew


Documentation
-------------

Please check the [ejabberd Docs][docs] website.

When compiling from source code, you can get some help with:

    ./configure --help
    make help

Once ejabberd is installed, try:

    ejabberdctl help
    man ejabberd.yml


Contributing
------------

For bug reports, discussing, improvement proposals, please check
[CONTRIBUTING](CONTRUBUTING.md).

You can improve ejabberd translations online
[using Weblate](https://hosted.weblate.org/projects/ejabberd/ejabberd-po/)
or in your local machine, see
[Localization documentation](https://docs.ejabberd.im/developer/extending-ejabberd/localization/).

For security reports or concerns, please contact us by email
on the address: contact [at] process-one [dot] net
or some other method from [ProcessOne Contact](https://www.process-one.net/en/company/contact/).


License
-------

ejabberd is released under the GNU General Public License v2 (see [COPYING](COPYING.md)),
and [ejabberd translations](https://github.com/processone/ejabberd-po/) under MIT License.


Links
-----

- Community site: https://www.ejabberd.im/
- ejabberd commercial offering and support: https://www.process-one.net/en/ejabberd
