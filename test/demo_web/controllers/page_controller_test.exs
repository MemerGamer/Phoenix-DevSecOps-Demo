defmodule DemoWeb.PageControllerTest do
  use DemoWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end

  test "GET / sets a restrictive Content-Security-Policy", %{conn: conn} do
    conn = get(conn, ~p"/")
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "default-src 'self'"
    assert csp =~ "script-src 'self'"
    assert csp =~ "object-src 'none'"
    assert csp =~ "frame-ancestors 'self'"
    refute csp =~ "unsafe-inline"
    refute csp =~ "unsafe-eval"
  end

  test "GET / renders no inline scripts", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    for [_, attrs, body] <- Regex.scan(~r/<script([^>]*)>(.*?)<\/script>/s, html) do
      assert attrs =~ "src=", "inline script found: #{body}"
      assert String.trim(body) == ""
    end
  end
end
