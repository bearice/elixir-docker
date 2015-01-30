defmodule DockerTest do
  use ExUnit.Case, async: false

  setup do
    server = %{
      baseUrl: "https://docker-06.lan.zhaowei.jimubox.com:2376",
      ssl_options: [
        {:certfile, 'docker.crt'},
        {:keyfile, 'docker.key'},
      ]
    }
    {:ok,conn} = Docker.start_link server
    {:ok,[conn: conn]}
  end

  test "docker info", ctx do
    assert {:ok, %{"ID"=>_}} = Docker.info ctx.conn
  end

  test "docker ps", ctx do
    assert {:ok, list} = Docker.Container.list ctx.conn
    assert is_list list
  end

  test "docker images", ctx do
    assert {:ok, list} = Docker.Image.list ctx.conn
    assert is_list list
  end

  test "docker create, attach, wait and delete", ctx do
    {:ok, %{"Id" => id}} = Docker.Container.create ctx.conn, "test", %{
      "Cmd": ["bash","-c","sleep 1; echo hello world; exit 100"],
      "Image": "ubuntu",
    }
    assert :ok = Docker.Container.start(ctx.conn, id)
    assert {:ok, ref} = Docker.Container.follow ctx.conn, id
    assert_receive %Docker.AsyncReply{id: ^ref, reply: {:chunk,[{:stdout, "hello world\n"}]}}, 2000
    assert_receive %Docker.AsyncReply{id: ^ref, reply: :done}, 1000
    assert {:ok, %{"StatusCode"=> 100}} = Docker.Container.wait(ctx.conn, id, :infinity)
    assert :ok = Docker.Container.delete(ctx.conn, id)
  end
end


