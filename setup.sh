
./autogen.sh
./configure \
    --with-rebar=mix \
    --enable-all

make

rm _build/prod/*.tar.gz

make rel

rm -rf /tmp/libcluster/1
rm -rf /tmp/libcluster/2

mkdir -p /tmp/libcluster/1
mkdir -p /tmp/libcluster/2

FILE=$(ls -1 _build/prod/*.tar.gz)
tar -xzf $FILE -C /tmp/libcluster/1
tar -xzf $FILE -C /tmp/libcluster/2

sed -i "s|#' POLL|EJABBERD_BYPASS_WARNINGS=true\n\n#' POLL|g" /tmp/libcluster/1/conf/ejabberdctl.cfg
sed -i "s|#' POLL|EJABBERD_BYPASS_WARNINGS=true\n\n#' POLL|g" /tmp/libcluster/2/conf/ejabberdctl.cfg
sed -i 's|#ERLANG_NODE=.*|ERLANG_NODE=ejabberd1@127.0.0.1|' /tmp/libcluster/1/conf/ejabberdctl.cfg
sed -i 's|#ERLANG_NODE=.*|ERLANG_NODE=ejabberd2@127.0.0.1|' /tmp/libcluster/2/conf/ejabberdctl.cfg
sed -i 's| port: \([0-9]*\)| port: 1\1|g' /tmp/libcluster/1/conf/ejabberd.yml
sed -i 's| port: \([0-9]*\)| port: 2\1|g' /tmp/libcluster/2/conf/ejabberd.yml
sed -i 's|mod_proxy65:|mod_proxy65:\n    port: 17777|' /tmp/libcluster/1/conf/ejabberd.yml
sed -i 's|mod_proxy65:|mod_proxy65:\n    port: 27777|' /tmp/libcluster/2/conf/ejabberd.yml

FIRST=/tmp/libcluster/1/bin/ejabberdctl
SECOND=/tmp/libcluster/2/bin/ejabberdctl
echo ""

echo "-==> Let's start the first node..."

$FIRST start
$FIRST started

echo "-==> Initial cluster of first node (should be just this node):"

$FIRST list_cluster

echo "-==> Let's start the second node, it should connect automatically to the first node..."

$SECOND start
$SECOND started
sleep 5 # wait a few seconds to let the second node join the cluster properly

echo "-==> Cluster as seen by first node:"

$FIRST list_cluster

echo "-==> Cluster as seen by second node:"

$SECOND list_cluster

echo "-==> Stop first node, and check cluster as seen by second node:"

$FIRST stop
$FIRST stopped
$SECOND list_cluster

echo "-==> Start again first node, and check cluster as seen by both nodes:"

$FIRST start
$FIRST started
sleep 5
$FIRST list_cluster
$SECOND list_cluster

echo "-==> Stopping all nodes..."

$FIRST stop
$SECOND stop
