class ApacheAge < Formula
  desc "Graph extension for PostgreSQL 17"
  homepage "https://age.apache.org/"
  url "https://github.com/apache/age/archive/refs/tags/PG17/v1.7.0-rc0.tar.gz"
  version "1.7.0-rc0"
  sha256 "ef3c44ffed1690bbe8652d3466434c42faf1133f3ea7cdad3331f012144495d2"
  license "Apache-2.0"

  depends_on "bison" => :build
  depends_on "flex" => :build
  depends_on "postgresql@17"

  def install
    pg = Formula["postgresql@17"]
    ENV.prepend_path "PATH", formula_opt_bin("bison")
    ENV.prepend_path "PATH", formula_opt_bin("flex")
    args = ["PG_CONFIG=#{pg.opt_bin}/pg_config"]
    system "make", *args
    system "make", "install", *args, "pkglibdir=#{lib}/postgresql@17",
           "datadir=#{share}/postgresql@17", "pkgincludedir=#{include}/postgresql@17"
  end

  def caveats
    <<~EOS
      Built only for PostgreSQL 17. Rebuild this formula after changing
      postgresql@17. It installs extension files but runs no SQL.
      Existing manually installed AGE files must be reconciled by their owner;
      do not use `brew link --overwrite` on a live installation.
    EOS
  end

  test do
    # Deliberately no initdb or CREATE EXTENSION against a user's database.
    assert_path_exists lib/"postgresql@17/age.#{OS.mac? ? "dylib" : "so"}"
    assert_match "1.7.0", (share/"postgresql@17/extension/age.control").read
  end
end
