
ccc_mix && make && make rel

rm -rf /tmp/libcluster/1
rm -rf /tmp/libcluster/2

mkdir -p /tmp/libcluster/1
mkdir -p /tmp/libcluster/2

tar -xzvf _build/prod/ejabberd-23.10.27.tar.gz -C /tmp/libcluster/1
tar -xzvf _build/prod/ejabberd-23.10.27.tar.gz -C /tmp/libcluster/2

sed -i 's|#ERLANG_NODE=.*|ERLANG_NODE=ejabberd1@127.0.0.1|' /tmp/libcluster/1/conf/ejabberdctl.cfg
sed -i 's|#ERLANG_NODE=.*|ERLANG_NODE=ejabberd2@127.0.0.1|' /tmp/libcluster/2/conf/ejabberdctl.cfg
sed -i 's| port: \([0-9]*\)| port: 1\1|g' /tmp/libcluster/1/conf/ejabberd.yml
sed -i 's| port: \([0-9]*\)| port: 2\1|g' /tmp/libcluster/2/conf/ejabberd.yml
sed -i 's|mod_proxy65:|mod_proxy65:\n    port: 17777|' /tmp/libcluster/1/conf/ejabberd.yml
sed -i 's|mod_proxy65:|mod_proxy65:\n    port: 27777|' /tmp/libcluster/2/conf/ejabberd.yml

exit 0

# Now try:

/tmp/libcluster/1/bin/ejabberdctl start
/tmp/libcluster/2/bin/ejabberdctl live

erlang:node().
'ejabberd2@127.0.0.1'

erlang:nodes().
['ejabberd1@127.0.0.1']
