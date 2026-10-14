defmodule Geofox.ClientTest do
  use ExUnit.Case, async: true

  alias Geofox.Client

  defp client(opts \\ []) do
    {req_options, opts} = Keyword.pop(opts, :req_options, [])
    Client.new([req_options: [plug: {Req.Test, __MODULE__}] ++ req_options] ++ opts)
  end

  describe "post/4" do
    test "sends a JSON body and returns the parsed response on OK" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/gti/public/init"
        assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"language" => "de"}

        Req.Test.json(conn, %{"returnCode" => "OK", "version" => "63"})
      end)

      assert {:ok, %{"returnCode" => "OK", "version" => "63"}} =
               Client.post(client(), "/gti/public/init", %{language: "de"})
    end

    test "signs the exact request body with HMAC-SHA1 when credentials are set" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        expected = :crypto.mac(:hmac, :sha, "secret", body) |> Base.encode64()

        assert Plug.Conn.get_req_header(conn, "geofox-auth-user") == ["user"]
        assert Plug.Conn.get_req_header(conn, "geofox-auth-type") == ["HmacSHA1"]
        assert Plug.Conn.get_req_header(conn, "geofox-auth-signature") == [expected]

        Req.Test.json(conn, %{"returnCode" => "OK"})
      end)

      assert {:ok, _} =
               Client.post(client(user: "user", password: "secret"), "/gti/public/init", %{
                 language: "de",
                 version: 1
               })
    end

    test "omits auth headers without credentials" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "geofox-auth-signature") == []
        Req.Test.json(conn, %{"returnCode" => "OK"})
      end)

      assert {:ok, _} = Client.post(client(), "/gti/public/init", %{})
    end

    test "returns API errors from the returnCode" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"returnCode" => "ERROR_TEXT", "errorText" => "Bad station"})
      end)

      assert {:error, {"ERROR_TEXT", "Bad station"}} =
               Client.post(client(), "/gti/public/checkName", %{})
    end

    test "returns HTTP errors for non-2xx statuses" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"returnCode" => "ERROR_COMM"})
      end)

      assert {:error, {:http_error, 401, %{"returnCode" => "ERROR_COMM"}}} =
               Client.post(client(), "/gti/public/init", %{})
    end

    test "returns transport errors" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:request_failed, %Req.TransportError{reason: :econnrefused}}} =
               Client.post(client(), "/gti/public/init", %{})
    end

    test "retries transient failures when retry is enabled" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 -> Plug.Conn.send_resp(conn, 503, "")
          _ -> Req.Test.json(conn, %{"returnCode" => "OK"})
        end
      end)

      client = client(retry: true, req_options: [retry_delay: 0, retry_log_level: false])

      assert {:ok, _} = Client.post(client, "/gti/public/init", %{})
      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "new/1" do
    test "sets default headers" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert ["geofox_ex/" <> _] = Plug.Conn.get_req_header(conn, "user-agent")
        assert Plug.Conn.get_req_header(conn, "x-platform") == ["web"]
        assert [_trace_id] = Plug.Conn.get_req_header(conn, "x-traceid")
        Req.Test.json(conn, %{"returnCode" => "OK"})
      end)

      assert {:ok, _} = Client.post(client(platform: "web"), "/gti/public/init", %{})
    end
  end
end
