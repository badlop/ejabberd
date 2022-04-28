echo "export PATH=/workspaces/ejabberd/_build/relive:$PATH" >>$HOME/.bashrc
echo "COOKIE" >$HOME/.erlang.cookie
chmod 400 $HOME/.erlang.cookie
./autogen.sh; ./configure --with-rebar=./rebar3; make deps
