defmodule Docker.Container do
  alias Docker.Container
  alias Docker.Request

  @derive [Access,Collectable]
  defstruct id: "", server: nil

  def list(srv) do
    req = Request.get "/containers/json"
    case GenServer.call(srv, req) do
      {:ok, list} ->
        {:ok, Enum.map(list, &(from_json(srv,&1))) }
      {:error, err} ->
        {:error, err}
    end
  end
  def create(srv, name, body) do
    req = Request.post("/containers/create")
       |> Request.query([name: name])
       |> Request.body(body)
    GenServer.call(srv, req)
  end
  def create(srv, body) do
    req = Request.post("/containers/create")
       |> Request.body(body)
    GenServer.call(srv, req)
  end

  def start(%Container{server: srv, id: id}), do: start(srv, id)
  def start(srv, id) do
    req = Request.post "/containers/#{id}/start"
    GenServer.call(srv, req)
  end

  def stop(%Container{server: srv, id: id}), do: stop(srv, id)
  def stop(srv, id) do
    req = Request.post "/containers/#{id}/stop"
    GenServer.call(srv, req)
  end

  def restart(%Container{server: srv, id: id}), do: restart(srv, id)
  def restart(srv, id) do
    req = Request.post "/containers/#{id}/restart"
    GenServer.call(srv, req)
  end

  def kill(%Container{server: srv, id: id}), do: kill(srv, id)
  def kill(srv, id) do
    req = Request.post "/containers/#{id}/kill"
    GenServer.call(srv, req)
  end

  def pause(%Container{server: srv, id: id}), do: pause(srv, id)
  def pause(srv, id) do
    req = Request.post "/containers/#{id}/pause"
    GenServer.call(srv, req)
  end

  def unpause(%Container{server: srv, id: id}), do: unpause(srv, id)
  def unpause(srv, id) do
    req = Request.post "/containers/#{id}/unpause"
    GenServer.call(srv, req)
  end

  def info(%Container{server: srv, id: id}), do: info(srv, id)
  def info(srv,id) do
    req = Request.get "/containers/#{id}/json"
    GenServer.call(srv, req)
  end

  def wait(%Container{server: srv, id: id}), do: wait(srv, id)
  def wait(srv,id, timeout \\ :infinity) do
    req = Request.post "/containers/#{id}/wait"
    GenServer.call(srv, req, timeout)
  end

  def delete(%Container{server: srv, id: id}), do: delete(srv, id)
  def delete(srv,id) do
    req = Request.delete "/containers/#{id}"
    GenServer.call(srv, req)
  end

  def logs(%Container{server: srv, id: id}), do: logs(srv, id)
  def logs(srv, id, query \\ %{stderr: true, stdout: true, follow: false, timestamp: false}) do
    req = Request.get("/containers/#{id}/logs")
       |> Request.query(query)
       |> Request.packed
    GenServer.call(srv, req)
  end

  def follow(srv, id, query \\ %{stderr: true, stdout: true, follow: true, timestamp: false},pid\\self) do
    req = Request.get("/containers/#{id}/logs")
       |> Request.query(query)
       |> Request.packed
       |> Request.stream_to(pid)
    GenServer.call(srv, req)
  end

  def top(%Container{server: srv, id: id}), do: top(srv, id)
  def top(srv, id, query \\ %{}) do
    req = Request.post("/containers/#{id}/top")
       |> Request.query(query)
    GenServer.call(srv, req)
  end

  #TODO stream apis
  #def attach(srv, id) do
  #  GenServer.call(srv, {:stream, :post, "/containers/#{id}/attach", nil})
  #end

  #private func
  defp from_json(srv,json) do
    Enum.into(json, %Container{id: json["Id"], server: srv})
  end
end #defmodule Container


