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

  alias Docker.JsonDecoder
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
      format: JsonDecoder,
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
      %{r | format: Docker.JsonDecoder}
    end
    def packed(r) do
      %{r | format: Docker.PackedDecoder}
    end
    def raw(r) do
      %{r | format: Docker.RawDecoder}
    end
    def stream_to(r,pid) do
      %{r | mode: :stream, stream_to: pid}
    end
  end #defmodule Request

  def info(srv) do
    req = Request.get "/info"
    GenServer.call(srv, req)
  end

  def monitor(srv, query \\ %{}, pid \\ self) do
    req = Request.get("/events")
       |> Request.query(query)
       |> Request.json
       |> Request.stream_to(pid)
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
    update_resp ctx, id, :headers, hdr
    #fn (req,resp) ->
    #  if req.mode == :stream and resp.status_code in 200..299 do
    #    reply req, {:start, resp.status_code, hdr}
    #  end
    #end
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
    lookup_resp ctx, id, fn(req, resp) ->
      if req.mode == :stream and resp.status_code in 200..299 do
        try do
          {objs, stats} = req.format.decode_chunk! chunk, resp.body
          resp = %{resp|body: stats}
          :ets.insert ctx.requests, {id,req,resp}
          if objs != nil do
            reply req, {:chunk, objs}
          end
        rescue e ->
          Logger.error """
          Unexpected Error, Response = #{inspect resp}
          #{Exception.message e}
          #{Exception.format_stacktrace System.stacktrace}
          """
          reply req, {:error, e}
        end
      else
        resp = %{resp|body: resp.body <> chunk}
        :ets.insert ctx.requests, {id,req,resp}
      end
    end
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
        raise inspect e
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
        last_chunk = req.format.flush! resp.body
        if last_chunk do
          reply req, {:chunk, last_chunk}
        end
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
        body = req.format.decode! resp.body
        reply req, {:ok, body}

      code ->
        reply req, {:error, {:servfail, code, resp.body}}
    end
  rescue err ->
      Logger.error """
      Unexpected Error, Response = #{inspect resp}
      #{Exception.message err}
      #{Exception.format_stacktrace System.stacktrace}
      """
      reply req, {:error,:badarg}
  end
end

