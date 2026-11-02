defmodule DemoWeb.Router do
  use DemoWeb, :router

  # No inline scripts or style attributes are used, so 'unsafe-inline' is not
  # needed. LiveView connects back to the same origin over ws/wss.
  # Kept as a plain string literal so Sobelow (Config.CSP) can inspect it.
  @secure_headers %{
    "content-security-policy" =>
      "default-src 'self'; script-src 'self'; style-src 'self'; \
      img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; \
      object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @secure_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DemoWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", DemoWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:demo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DemoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
