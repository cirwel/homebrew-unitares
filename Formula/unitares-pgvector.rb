class UnitaresPgvector < Formula
  desc "Vector extension built only for UNITARES PostgreSQL 17"
  homepage "https://github.com/pgvector/pgvector"
  url "https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.7.tar.gz"
  sha256 "cac0b10c360f05b2d521200105ba3697e773d4cd3731f5a915a7e37ebe0bea85"
  license "PostgreSQL"
  depends_on "postgresql@17"
  conflicts_with "pgvector", because: "both install PostgreSQL 17 vector extension files"

  def install
    ENV["PG_CONFIG"] = formula_opt_bin("postgresql@17")/"pg_config"
    system "make", "OPTFLAGS="
    system "make", "install", "pkglibdir=#{lib}/postgresql@17",
           "datadir=#{share}/postgresql@17", "pkgincludedir=#{include}/postgresql@17"
  end

  test do
    assert_path_exists share/"postgresql@17/extension/vector.control"
  end
end
