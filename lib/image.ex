defmodule Docker.Image do
  alias Docker.Image
  alias Docker.Request

  defstruct id: "", server: nil
  def list(srv) do
    req = Request.get "/images/json"
    case GenServer.call(srv, req) do
      {:ok, list} ->
        {:ok,Enum.map(list, &(from_json(srv,&1)))}
      {:error, err} ->
        {:error, err}
    end
  end

  #TODO stream output
  def pull(srv,id) do
    req = Request.post("/image/create")
       |> Request.query([fromImage: id])
    GenServer.call(srv, req)
  end

  def info(%Image{server: srv, id: id}), do: info(srv, id)
  def info(srv,id) do
    req = Request.get "/images/#{id}/json"
    GenServer.call(srv, req)
  end

  def history(%Image{server: srv, id: id}), do: history(srv, id)
  def history(srv,id) do
    req = Request.get "/images/#{id}/history"
    GenServer.call(srv, req)
  end

  def push(srv,id) do
    req = Request.post "/images/#{id}/push"
    GenServer.call(srv, req)
  end

  def from_json(srv,json) do
    Enum.into(json, %Image{id: json["Id"], server: srv})
  end
end #defmodule Image

