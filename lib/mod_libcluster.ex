defmodule ModLibcluster do
  use Ejabberd.Module

  def start(_host, opts) do
    info('Starting ejabberd module Libcluster with nodes #{inspect(opts[:nodes])}')
    topologies = [
      epmd_ejabberd_cluster: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: opts[:nodes]],
        connect: {:ejabberd_admin, :join_cluster, []},
        disconnect: {:ejabberd_admin, :leave_cluster, []}
      ]
    ]
    children = [
      {Cluster.Supervisor, [topologies, [name: Ejabberd.ClusterSupervisor]]},
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: Ejabberd.Supervisor)
    info('Started ejabberd module Libcluster Demo')
    :ok
  end

  def stop(_host) do
    info('Stopping ejabberd module Libcluster Demo')
    :ok
  end

  def depends(_host, _opts) do
    []
  end

  def mod_opt_type(:nodes) do
    :econf.list(:econf.atom)
  end

  def mod_options(_host) do
    [
     {:nodes, []}
    ]
  end

  def mod_doc() do
    %{:desc => 'This is just a demonstration.'}
  end

end
