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
  defmodule Request do
    defstruct [
      mode: :sync,
      method: :get,
      path: nil,
      query: nil,
      body: nil,
      headers: [],
      stream_to: nil,
      format: :json,
      opts: [],
      #internal use
      id: nil,
      from: nil,
    ]
    def get(path) do
      %Request{method: :get, path: path}
    end
    def post(path) do
      %Request{method: :post, path: path}
    end
    def delete(path) do
      %Request{method: :delete, path: path}
    end
    def query(r,q) do
      %{r | query: q}
    end
    def body(r,q) do
      %{r | body: q}
    end
    def json(r) do
      %{r | format: :json}
    end
    def packed(r) do
      %{r | format: :packed}
    end
    def raw(r) do
      %{r | format: :raw}
    end
  end #defmodule Request

  defmodule Container do
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
    def wait(srv,id) do
      req = Request.post "/containers/#{id}/wait"
      GenServer.call(srv, req)
    end

    def delete(%Container{server: srv, id: id}), do: delete(srv, id)
    def delete(srv,id) do
      req = Request.delete "/containers/#{id}"
      GenServer.call(srv, req)
    end

    def logs(%Container{server: srv, id: id}), do: logs(srv, id)
    def logs(srv, id, query \\ %{stdin: true, stdout: true, follow: false, timestamp: false}) do
      req = Request.get("/containers/#{id}/logs")
         |> Request.query(query)
         |> Request.packed
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

  defmodule Image do
    @derive [Access,Collectable]
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

  def info(srv) do
    req = Request.get "/info"
    GenServer.call(srv, req)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__,opts)
  end

  def init(opts) do
    table = :ets.new :requests, [:set, :private]
    {:ok, Enum.into(opts, %{:requests => table})}
  end

  def handle_call(%Request{mode: :sync}=req, from, ctx) do
    try do
      mkreq ctx, req, from
      {:noreply,ctx}
    rescue
      err ->
        Logger.error "#{Exception.message err}\n#{Exception.format_stacktrace System.stacktrace}"
        {:reply,{:error,err},ctx}
    end
  end

  def handle_call(%Request{mode: :stream}=req, from, ctx) do
    try do
      reply = mkreq ctx, req, from
      {:reply, reply, ctx}
    rescue
      err ->
        Logger.error "#{Exception.message err}\n#{Exception.format_stacktrace System.stacktrace}"
        {:reply,{:error,err},ctx}
    end
  end

  def handle_info({:hackney_response, id, {:status, code, reason}}, ctx) do
    #Logger.debug "id: #{inspect id}, code: #{code}"
    update_resp ctx, id, :status_code, code
    {:noreply,ctx}
  end
  def handle_info({:hackney_response, id, {:headers, hdr}}, ctx) do
    #Logger.debug "id: #{inspect id}, hdr: #{inspect hdr}"
    update_resp ctx, id, :headers, hdr, fn (req,resp) ->
      if req.mode == :stream and resp.status_code in 200..299 do
        reply req, {:start, resp.status_code, hdr}
      end
    end
    {:noreply,ctx}
  end
  def handle_info({:hackney_response, id, :done}, ctx) do
    #Logger.debug "id: #{inspect id}, done"
    finish_resp ctx, id, &process_resp/2
    {:noreply,ctx}
  end
  def handle_info({:hackney_response, id, {:error, reason}}, ctx) do
    #Logger.debug "id: #{inspect id}, error: #{inspect reason}"
    finish_resp ctx, id, fn(req, resp) ->
      reply req, {:error, reason}
    end
    {:noreply,ctx}
  end
  def handle_info({:hackney_response, id, chunk}, ctx) when is_binary(chunk) do
    lookup_resp(ctx, id, fn(req, resp) ->
      if req.mode == :stream and resp.status_code in 200..299 do
        reply req, {:chunk, chunk}
      else
        resp = %{resp|body: resp.body <> chunk}
        :ets.insert ctx.requests, {id,req,resp}
      end
    end)
    {:noreply,ctx}
  end

  #private func
  defp reply(req, reply) do
    case req.mode do
      :stream ->
        pid = if req.stream_to do
          req.stream_to
        else
          elem req.from, 1
        end
        send pid, %AsyncReply{id: req.id, reply: reply}
      :sync ->
        GenServer.reply req.from, reply
    end
  end

  defp mkurl(ctx, req) do
    if req.query do
      ctx.baseUrl <> req.path <> "?" <> URI.encode_query req.query
    else
      ctx.baseUrl <> req.path
    end
  end

  defp mkhdrs(ctx, req) do
    if req.body do
      Enum.into req.headers,[{"Content-Type","application/json"}]
    else
      req.headers
    end
  end

  defp mkbody(ctx, req) do
    if req.body do
      JSX.encode! req.body
    else
      ""
    end
  end

  defp mkopts(ctx, opts) do
    opts
    |> Dict.put(:ssl_options, ctx.ssl_options)
    |> Dict.put(:stream_to, self())
    |> Dict.put(:async, :true)
  end

  defp mkreq(ctx, req, from) do
    method  = req.method
    url     = mkurl  ctx, req
    headers = mkhdrs ctx, req
    body    = mkbody ctx, req
    options = mkopts ctx, req.opts

    Logger.debug "#{method} #{url} #{inspect headers} #{inspect body} #{inspect options}"
    case :hackney.request(method, url, headers, body, options) do
      {:ok, id} ->
        req = %{req| from: from, id: id}
        :ets.insert ctx.requests, {id, req, %{body: ""}}
        {:ok, id}
      {:error, e} ->
        raise e
    end
  end

  defp lookup_resp(ctx, id, fun \\ nil) do
    case :ets.lookup(ctx.requests, id) do
      [{^id, req, resp}]->
        fun.(req,resp)
      _ ->
        Logger.warn "Not found: #{inspect id}"
        :error
    end
  end

  defp finish_resp(ctx, id, fun) do
    lookup_resp ctx, id, fn(req, resp) ->
      :ets.delete ctx.requests, id
      fun.(req,resp)
    end
  end
  defp update_resp(ctx, id, field, value, callback \\ nil) do
    lookup_resp ctx,id, fn(req,resp) ->
      resp = Dict.put resp, field, value
      :ets.insert ctx.requests, {id,req,resp}
      if callback do
        callback.(req,resp)
      end
    end
  end

  defp process_resp(%Request{mode: :stream} = req, resp) do
    case resp.status_code do
      code when code in 200..299 ->
        reply req, :done
      code ->
        reply req, {:error, {:servfail, code, resp.body}}
    end
  end
  defp process_resp(%Request{mode: :sync} = req, resp) do
    #IO.inspect resp
    case resp.status_code do
      code when code == 204 ->
        reply req, :ok

      code when code in 200..299 ->
        #Logger.debug "get #{code}"
        try do
          body = case req.format do
            :json ->
              JSX.decode! resp.body
            :raw ->
              resp.body
            :packed ->
              parse_packed resp.body, []
          end
          reply req, {:ok, body}
        rescue
          ArgumentError ->
            Logger.error "Bad response [#{code}]: #{inspect resp}"
            reply req, {:error,:badarg}
          e ->
            Logger.error "Unexpected Error: #{inspect e} #{code} #{inspect resp}"
            reply req, {:error,:badarg}
        end

      code ->
        reply req, {:error, {:servfail, code, resp.body}}
    end
  end

  def parse_packed(<<type,0,0,0,size :: integer-big-size(32),rest :: binary>>=packet, acc) do
    if size <= byte_size(rest) do
      <<data :: binary-size(size), rest0 :: binary>> = rest
      type = case type do
        0 -> :stdin
        1 -> :stdout
        2 -> :stderr
        other -> other
      end
      acc = [{type,data}|acc]
      parse_packed(rest0, acc)
    else
      {packet,Enum.reverse(acc)}
    end
  end
  def parse_packed(packet, acc) when byte_size(packet)<8 do
    {packet,Enum.reverse(acc)}
  end
  def parse_packed(packet, _acc) do
    Logger.error "unable to parse packet: #{inspect packet}"
    raise ArgumentError
  end
end
