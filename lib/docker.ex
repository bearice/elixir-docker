defmodule Docker do
  require Logger
  use GenServer

  alias HTTPoison.AsyncResponse
  alias HTTPoison.AsyncStatus
  alias HTTPoison.AsyncHeaders
  alias HTTPoison.AsyncChunk
  alias HTTPoison.AsyncEnd
  alias HTTPoison.Response
  alias HTTPoison.Error

  defmodule AsyncReply do
    defstruct id: nil, reply: nil
  end

  defmodule Container do
    @derive [Access,Collectable]
    defstruct id: "", server: nil

    def list(srv) do
      case GenServer.call(srv, {:sync_req, :get, "/containers/json", nil}) do
        {:ok, list} ->
          {:ok, Enum.map(list, &(from_json(srv,&1))) }
        {:error, err} ->
          Logger.error err
          raise err
      end
    end
    def create(srv, body) do
      GenServer.call(srv, {:sync_req, :post, "/containers/create", body})
    end

    def start(%Container{server: srv, id: id}), do: start(srv, id)
    def start(srv, id) do
      GenServer.call(srv, {:sync_req, :post, "/containers/#{id}/start", nil})
    end

    def stop(%Container{server: srv, id: id}), do: stop(srv, id)
    def stop(srv, id) do
      GenServer.call(srv, {:sync_req, :post, "/containers/#{id}/stop", nil})
    end

    def restart(%Container{server: srv, id: id}), do: restart(srv, id)
    def restart(srv, id) do
      GenServer.call(srv, {:sync_req, :post, "/containers/#{id}/restart", nil})
    end

    def kill(%Container{server: srv, id: id}), do: kill(srv, id)
    def kill(srv, id) do
      GenServer.call(srv, {:sync_req, :post, "/containers/#{id}/kill", nil})
    end

    def pause(%Container{server: srv, id: id}), do: pause(srv, id)
    def pause(srv, id) do
      GenServer.call(srv, {:sync_req, :post, "/containers/#{id}/pause", nil})
    end

    def unpause(%Container{server: srv, id: id}), do: unpause(srv, id)
    def unpause(srv, id) do
      GenServer.call(srv, {:sync_req, :post, "/containers/#{id}/unpause", nil})
    end

    def info(%Container{server: srv, id: id}), do: info(srv, id)
    def info(srv,id) do
      GenServer.call(srv, {:sync_req, :get, "/containers/#{id}/json", nil})
    end

    def wait(%Container{server: srv, id: id}), do: wait(srv, id)
    def wait(srv,id) do
      GenServer.call(srv, {:sync_req, :post, "/containers/#{id}/wait", nil})
    end

    def delete(%Container{server: srv, id: id}), do: delete(srv, id)
    def delete(srv,id) do
      GenServer.call(srv, {:sync_req, :delete, "/containers/#{id}", nil})
    end

    def logs(%Container{server: srv, id: id}), do: logs(srv, id)
    def logs(srv,id) do
      GenServer.call(srv, {:sync_req, :get, "/containers/#{id}/logs", nil})
    end

    def top(%Container{server: srv, id: id}), do: top(srv, id)
    def top(srv,id) do
      GenServer.call(srv, {:sync_req, :get, "/containers/#{id}/top", nil})
    end

    #TODO stream apis
    #def attach(srv, id) do
    #  GenServer.call(srv, {:async_req, :post, "/containers/#{id}/attach", nil})
    #end

    def from_json(srv,json) do
      Enum.into(json, %Container{id: json["Id"], server: srv})
    end
  end #defmodule Container

  defmodule Image do
    @derive [Access,Collectable]
    defstruct id: "", server: nil
    def list(srv) do
      case GenServer.call(srv, {:sync_req, :get, "/images/json", nil}) do
        {:ok, list} ->
          {:ok,Enum.map(list, &(from_json(srv,&1)))}
        {:error, err} ->
          Logger.error err
          raise err
      end
    end

    #TODO stream output
    def pull(srv,id) do
      GenServer.call(srv, {:sync_req, :post, "/images/create", [fromImage: id], nil})
    end

    def info(%Image{server: srv, id: id}), do: info(srv, id)
    def info(srv,id) do
      GenServer.call(srv, {:sync_req, :get, "/images/#{id}/json", nil})
    end

    def history(%Image{server: srv, id: id}), do: history(srv, id)
    def history(srv,id) do
      GenServer.call(srv, {:sync_req, :get, "/images/#{id}/history", nil})
    end

    def push(srv,id) do
      GenServer.call(srv, {:sync_req, :get, "/images/#{id}/push", nil})
    end

    def from_json(srv,json) do
      Enum.into(json, %Container{id: json["Id"], server: srv})
    end
  end

  def info(srv) do
    GenServer.call(srv, {:sync_req, :get, "/info", nil})
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__,opts)
  end

  def init(opts) do
    table = :ets.new :requests, [:set, :private]
    {:ok, Enum.into(opts, %{:requests => table})}
  end

  def handle_call({type, method, path, query, body}, from, ctx) do
      path = path <> "?" <> URI.encode_query(query)
      handle_call({type, method, path, body}, from, ctx)
  end

  def handle_call({:sync_req, method, path, body}, from, ctx) do
    try do
      mkreq ctx, method, path, body, {:sync_req, from}
      {:noreply,ctx}
    rescue
      e -> {:reply,{:error,e},ctx}
    end
  end

  def handle_call({:async_req, method, path, body}, from, ctx) do
    try do
      id = make_ref
      mkreq ctx, method, path, body, {:async_req, id, from}
      {:reply, {:ok, id}, ctx}
    rescue
      e -> {:reply,{:error,e},ctx}
    end
  end

  def handle_info(%AsyncStatus{id: id, code: code}, ctx) do
    update_resp(ctx, id, :status_code, code)
    {:noreply,ctx}
  end
  def handle_info(%AsyncHeaders{id: id, headers: hdr}, ctx) do
    update_resp(ctx, id, :headers, hdr)
    {:noreply,ctx}
  end
  def handle_info(%AsyncChunk{id: id, chunk: chunk}, ctx) do
    update_resp(ctx, id, :body, chunk, fn(parts)-> parts <> chunk end)
    {:noreply,ctx}
  end
  def handle_info(%AsyncEnd{id: id}, ctx) do
    finish_resp ctx, id, &(process_resp(ctx, &1, &2))
    {:noreply,ctx}
  end
  def handle_info(%Error{id: id, reason: reason}, ctx) do
    finish_resp ctx, id, fn(req, resp) ->
      reply req.from, {:error, reason}
    end
    {:noreply,ctx}
  end

  #private func
  defp reply({:async_req, id, from}, reply) do
    send from, %AsyncReply{id: id, reply: reply}
  end

  defp reply({:sync_req, from}, reply) do
    GenServer.reply from, reply
  end

  defp mkurl(ctx, path) do
    ctx.baseUrl <> path
  end

  defp mkopts(ctx, opts) do
    opts
    |> Dict.put(:hackney, [ssl_options: ctx.ssl_options])
    |> Dict.put(:stream_to, self())
  end

  defp mkreq(ctx, method, path, payload, from) do
    url  = mkurl  ctx, path
    if payload do
      body = JSX.encode! payload
      headers = [{"Content-Type","application/json"}]
    else
      body = ""
      headers = []
    end
    #Logger.debug "#{method} #{url} #{body}"
    req = %{
      method: method,
      url: url,
      headers: headers,
      body: body,
      options: mkopts(ctx, []),
      from: from,
    }
    %AsyncResponse{id: id} = HTTPoison.request!(req.method, req.url, req.body, req.headers, req.options)
    :ets.insert ctx.requests, {id, req, %{body: ""}}
  end

  defp update_resp(ctx, id, field, value, fun \\ nil) do
    unless fun do
      fun = fn(_any) -> value end
    end
    case :ets.lookup(ctx.requests,id) do
      [{^id, from, resp}]->
        resp = Dict.update(resp, field, value, fun)
        :ets.insert ctx.requests, {id, from, resp}
      _ ->
        Logger.warn "Not found: #{inspect id}"
        :error
    end
  end

  defp finish_resp(ctx, id, cb) do
    case :ets.lookup(ctx.requests,id) do
      [{^id, req, resp}]->
        :ets.delete ctx.requests,id
        cb.(req,resp)
      _ ->
        Logger.warn "Not found: #{inspect id}"
        :error
    end
  end

  defp process_resp(ctx, req, resp) do
    #IO.inspect resp
    case resp do
      %{status_code: code, body: body} ->
        #Logger.debug "get #{code}"
        try do
          reply req.from, {:ok, JSX.decode!(body)}
        rescue
          ArgumentError ->
            Logger.error "Bad response [#{code}]: #{inspect resp}"
            reply req.from, {:error,:badarg}
        end
    end
  end
end
