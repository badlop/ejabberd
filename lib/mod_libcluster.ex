defmodule ModLibcluster do
  use Ejabberd.Module

  def start(_host, _opts) do
    info('Starting ejabberd module Libcluster Demo')
    topologies = [
      example: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: [:"ejabberd1@127.0.0.1", :"ejabberd2@127.0.0.1"]],
      ]
    ]
    children = [
      {Cluster.Supervisor, [topologies, [name: MyApp.ClusterSupervisor]]},
      # ..other children..
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
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

  def mod_options(_host) do
    []
  end

  def mod_doc() do
    %{:desc => 'This is just a demonstration.'}
  end

end
