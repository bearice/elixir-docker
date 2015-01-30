Docker API binding in Elixir
===

Warining: this ia a UNSTABLE version, and APIs would be change quickly

example:
```elixir
require Logger

server = %{
  baseUrl: "https://docker-06.lan.zhaowei.jimubox.com:2376",
  ssl_options: [
    {:certfile, 'docker.crt'},
    {:keyfile, 'docker.key'},
  ]
}

{:ok,conn} = Docker.start_link server
IO.inspect Docker.info conn
IO.inspect Docker.Container.list conn
IO.inspect Docker.Image.list conn

IO.inspect Docker.Container.create conn, "test", %{
  "Cmd": ["bash","-c","for i in {1..3}; do date;uptime 1>&2; echo hello; sleep 1; done; exit 100"],
  "Image": "ubuntu",
}

IO.inspect Docker.Container.start conn, "test"

loop = fn(loop) ->
  receive do
    %Docker.AsyncReply{reply: {:error, err}} ->
      Logger.error err
      loop.(loop)
    %Docker.AsyncReply{reply: {:chunk, data}} ->
      IO.inspect data
      loop.(loop)
    %Docker.AsyncReply{reply: :done} ->
      Logger.debug "EOF"
    :exit -> :ok
    msg ->
      Logger.warn "Unexpected message: #{inspect msg}"
      loop.(loop)
  end
end

pid = spawn fn()->
  IO.inspect Docker.Container.follow conn, "test"
  loop.(loop)
end

IO.inspect Docker.Container.wait conn, "test", :infinity
IO.inspect Docker.Container.delete conn, "test"

send pid, :exit
```
