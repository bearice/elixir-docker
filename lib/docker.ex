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

  def containers(srv) do
    GenServer.call(srv, {:sync_req, :get, "/containers/json", nil})
  end
  def create(srv, body) do
    GenServer.call(srv, {:sync_req, :post, "/containers/create", body})
  end
  def start(srv, opts) do
    GenServer.call(srv, {:sync_req, :post, "/containers/#{}/start", nil})
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__,opts)
  end
  def init(opts) do
    table = :ets.new :requests, [:set, :private]
    {:ok, Enum.into(opts, %{:requests => table})}
  end
  def handle_call({:sync_req, method, path, body}, from, ctx) do
    try do
      mkreq ctx, method, path, body, {:sync_req, from}
      {:noreply,ctx}
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
    Logger.debug "#{method} #{url} #{body}"
    req = %{
      method: method,
      url: url,
      headers: headers,
      body: body,
      options: mkopts(ctx, []),
      from: from,
    }
    %AsyncResponse{id: id} = HTTPoison.request!(
      req.method, req.url, req.body, req.headers, req.options
    )
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
    IO.inspect resp
    case resp do
      %{status_code: code, body: body} ->
        Logger.debug "get #{code}"
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
