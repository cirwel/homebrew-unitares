class UnitaresLeasePlane < Formula
  desc "Coordination lease service for UNITARES"
  homepage "https://github.com/cirwel/unitares"
  url "https://github.com/cirwel/unitares/releases/download/v3.6.0/unitares-3.6.0.tar.gz"
  sha256 "3104c35a1497d1c5eadfd0309dd7ab850f735790f9de0ed54b29a305fbf6b82f"
  license "Apache-2.0"
  depends_on "elixir" => :build
  depends_on "erlang" => :build

  depends_on "openssl@4"

  def fetch
    ENV.prepend_path "PATH", formula_opt_bin("erlang")
    ENV.prepend_path "PATH", formula_opt_bin("elixir")
    # Homebrew owns this private build directory; no concurrent Mix writers.
    ENV["MIX_OS_CONCURRENCY_LOCK"] = "0"
    ENV["MIX_ENV"] = "prod"
    ENV["MIX_HOME"] = buildpath/".mix"
    ENV["HEX_HOME"] = buildpath/".hex"
    system "mix", "local.hex", "--force"
    system "mix", "local.rebar", "--force"
    cd "elixir/lease_plane" do
      system "mix", "deps.get", "--only", "prod"
    end
  end

  def install
    ENV.prepend_path "PATH", formula_opt_bin("erlang")
    ENV.prepend_path "PATH", formula_opt_bin("elixir")
    # Homebrew owns this private build directory; no concurrent Mix writers.
    ENV["MIX_OS_CONCURRENCY_LOCK"] = "0"
    ENV["MIX_ENV"] = "prod"
    ENV["MIX_HOME"] = buildpath/".mix"
    ENV["HEX_HOME"] = buildpath/".hex"
    cd "elixir/lease_plane" do
      (buildpath/"elixir/lease_plane/config/runtime.exs").write <<~EOS
        import Config
        config :lease_plane,
          database_url: System.fetch_env!("UNITARES_LEASE_PLANE_DATABASE_URL")
      EOS
      system "mix", "deps.compile"
      system "mix", "compile"
      # Generate an OTP release locally; no runtime dependency fetch/build.
      system "mix", "release", "--overwrite"
      libexec.install Dir["_build/prod/rel/lease_plane/*"]
    end
    (bin/"unitares-lease-plane").write <<~SH
      #!/bin/sh
      set -eu
      config="${UNITARES_NATIVE_ENV:-#{etc}/unitares/native.env}"
      [ -f "$config" ] || { echo "Configure $config before starting" >&2; exit 1; }
      set -a
      . "$config"
      set +a
      export RELEASE_DISTRIBUTION=none
      export RELEASE_TMP="#{var}/unitares/lease-plane"
      mkdir -p "$RELEASE_TMP"
      exec "#{libexec}/bin/lease_plane" start
    SH
  end

  service do
    run [opt_bin/"unitares-lease-plane"]
    keep_alive true
    log_path var/"log/unitares-lease-plane.log"
    error_log_path var/"log/unitares-lease-plane.log"
  end

  test do
    assert_path_exists libexec/"bin/lease_plane"
    assert_match "lease_plane", shell_output("#{libexec}/bin/lease_plane version")
    ENV["UNITARES_LEASE_PLANE_DATABASE_URL"] = "postgresql://probe:probe@127.0.0.1:1/probe"
    ENV["RELEASE_DISTRIBUTION"] = "none"
    ENV["RELEASE_TMP"] = testpath
    code = "IO.puts(Application.fetch_env!(:lease_plane, :database_url))"
    output = shell_output("#{libexec}/bin/lease_plane eval '#{code}'")
    assert_match ENV["UNITARES_LEASE_PLANE_DATABASE_URL"], output
  end
end
