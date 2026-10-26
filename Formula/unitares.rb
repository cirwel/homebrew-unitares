class Unitares < Formula
  desc "Single-operator federation kernel for long-running agents"
  homepage "https://github.com/cirwel/unitares"
  url "https://github.com/cirwel/unitares/archive/refs/tags/v3.5.0.tar.gz"
  sha256 "69661373078695bf222479ce6f86a45f16d38922b2193dec25fd25bb07997fff"
  license "Apache-2.0"
  revision 6

  depends_on arch: :arm64
  depends_on "cirwel/unitares/apache-age"
  depends_on "cirwel/unitares/unitares-lease-plane"
  depends_on "cirwel/unitares/unitares-pgvector"
  depends_on :macos
  depends_on "postgresql@17"
  depends_on "python@3.14"
  depends_on "redis"

  # Python wheels use loader-relative IDs; expanding them can exhaust headers.
  preserve_rpath

  # Reviewed setup/model backports; remove when the release includes them.
  patch :DATA

  def fetch
    (buildpath/"runtime.lock").write runtime_lock
    system formula_opt_bin("python@3.14")/"python3.14", "-m", "pip", "download", "--only-binary=:all:",
           "--require-hashes", "-r", "runtime.lock", "--dest", "wheelhouse"
    system formula_opt_bin("python@3.14")/"python3.14", "-m", "pip", "wheel",
           "--no-deps", "./agents/sdk", "--wheel-dir", "wheelhouse"
  end

  def install
    system formula_opt_bin("python@3.14")/"python3.14", "-m", "venv", libexec/"venv"
    system libexec/"venv/bin/python", "-m", "pip", "install", "--no-index",
           "--find-links=wheelhouse", "--require-hashes", "-r", "runtime.lock"
    system libexec/"venv/bin/python", "-m", "pip", "install", "--no-index",
           "--no-deps", *Dir["wheelhouse/unitares_sdk-*.whl"]
    rm_r "wheelhouse"
    app = libexec/"app"
    app.install Dir["*"]
    app.install ".env.example"
    # Runtime files outlive the immutable source keg. No database access here.
    rm_r(app/"data") if (app/"data").exist?
    (var/"unitares/data").mkpath
    (app/"data").make_symlink var/"unitares/data"
    (etc/"unitares").mkpath
    (pkgshare/"native.env.example").write <<~ENV
      DB_POSTGRES_URL=postgresql://YOUR_USER:YOUR_PASSWORD@localhost:5432/governance
      DB_BACKEND=postgres
      DB_AGE_GRAPH=governance_graph
      REDIS_URL=redis://127.0.0.1:6379/0
      UNITARES_KNOWLEDGE_BACKEND=postgres
      UNITARES_DIALECTIC_BACKEND=postgres
      UNITARES_LEASE_PLANE_DATABASE_URL=postgresql://YOUR_USER:YOUR_PASSWORD@localhost:5432/governance
      UNITARES_LEASE_PLANE_HTTP_IP=127.0.0.1
      UNITARES_LEASE_PLANE_HTTP_PORT=8788
      UNITARES_LEASE_PLANE_URL=http://127.0.0.1:8788
      LEASE_PLANE_BASE_URL=http://127.0.0.1:8788
      UNITARES_GOVERNANCE_URL=http://127.0.0.1:8767
      # Set one generated bearer in BOTH services through this shared file.
      LEASE_PLANE_BEARER_TOKEN=replace-before-starting
      UNITARES_MODEL_BASE_URL=
      UNITARES_MODEL_ID=
      UNITARES_RESIDENTS=
    ENV
    (bin/"unitares-server").write <<~SH
      #!/bin/sh
      set -eu
      config="${UNITARES_NATIVE_ENV:-#{etc}/unitares/native.env}"
      [ -f "$config" ] || { echo "Configure $config before starting" >&2; exit 1; }
      set -a
      . "$config"
      set +a
      export PATH="#{libexec}/venv/bin:#{formula_opt_bin("postgresql@17")}:$PATH"
      cd "${UNITARES_NATIVE_APP_ROOT:-#{libexec}/app}"
      exec "#{libexec}/venv/bin/python" src/mcp_server.py --host 127.0.0.1 "$@"
    SH
    (bin/"unitares").write <<~SH
      #!/bin/sh
      export PATH="#{libexec}/venv/bin:$PATH"
      exec "#{libexec}/app/scripts/unitares" "$@"
    SH
  end

  service do
    run [opt_bin/"unitares-server"]
    keep_alive true
    log_path var/"log/unitares.log"
    error_log_path var/"log/unitares.log"
  end

  def caveats
    <<~EOS
      NATIVE PREVIEW: keep the managed set pinned with
      `brew pin unitares unitares-lease-plane apache-age unitares-pgvector`.
      No migrations run during install, post_install, upgrade, or service launch.
      Run `unitares setup` to inspect this installation and `unitares setup --apply`
      to prepare missing private configuration at #{etc}/unitares/native.env,
      with a generated shared lease bearer. Follow https://github.com/cirwel/homebrew-unitares#first-time-setup
      for explicit database bootstrap. Then run `unitares start --check` and
      `unitares start` to start the configured native services in order.
      `unitares stop` stops both writers while retaining PostgreSQL/Redis.
      `unitares logs [server|lease-plane]` reads their logs.
      Run `unitares update --check` to inspect the locally cached native plan,
      and `unitares update` for the coordinated stop, verified backup, recorded
      Homebrew package/dependency transaction, migrations, restart and health
      verification. Resume an interrupted transaction with
      `unitares update --resume`; before any managed formula or schema change,
      `unitares update --abort` can restore prior state.
      Preview verified backup retention with
      `unitares update --cleanup-backups`; add `--yes` to apply it. This never
      removes Homebrew kegs or substitutes for an operator-owned `brew cleanup`.
      Embeddings are omitted; search falls back to PostgreSQL full-text search.
    EOS
  end

  test do
    assert_path_exists libexec/"app/scripts/install/homebrew_services.py"
    assert_path_exists libexec/"app/scripts/install/homebrew_update.py"
    assert_match "Homebrew service control", shell_output("#{bin}/unitares help")
    assert_match "update --homebrew", shell_output("#{bin}/unitares help")
    # Copy source and replace its durable-data symlink with test-private state.
    cp_r libexec/"app", testpath/"app"
    rm testpath/"app/data"
    (testpath/"app/data").mkpath
    ENV["UNITARES_NATIVE_APP_ROOT"] = testpath/"app"
    port = free_port
    # Server startup requires PostgreSQL even for liveness. Require an explicit
    # pre-provisioned disposable database; never create one or default to prod.
    test_db = ENV.fetch("HOMEBREW_UNITARES_TEST_DB_URL") do
      odie "Set HOMEBREW_UNITARES_TEST_DB_URL to a pre-provisioned disposable test database"
    end
    ENV["DB_POSTGRES_URL"] = test_db
    (testpath/"native.env").write <<~ENV
      DB_BACKEND=postgres
      REDIS_URL=redis://127.0.0.1:1/0
      UNITARES_SERVER_PID_FILE=#{testpath}/server.pid
      UNITARES_SERVER_LOCK_FILE=#{testpath}/server.lock
      LEASE_PLANE_BASE_URL=http://127.0.0.1:1
      UNITARES_LEASE_PLANE_URL=http://127.0.0.1:1
      UNITARES_RESIDENTS=
    ENV
    ENV["UNITARES_NATIVE_ENV"] = testpath/"native.env"
    pid = spawn bin/"unitares-server", "--port", port.to_s,
                out: (testpath/"server.log").to_s, err: (testpath/"server.log").to_s
    begin
      live = false
      60.times do
        sleep 1
        break if Process.waitpid(pid, Process::WNOHANG)

        response = IO.popen(["curl", "-fsS", "--max-time", "2", "http://127.0.0.1:#{port}/health/live"],
                            err: File::NULL, &:read)
        if response.include?("alive")
          live = true
          break
        end
      end
      assert live, (testpath/"server.log").read
    ensure
      begin
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def runtime_lock
    <<~'LOCK'
      PyJWT==2.15.1 \
          --hash=sha256:42d59d631f7768a1028a64c7ff581a9bf7519804daf91fc5b6c56e30eec5e193
      PyYAML==6.0.3 \
          --hash=sha256:00c4bdeba853cc34e7dd471f16b4114f4162dc03e6b7afcc2128711f0eca823c \
          --hash=sha256:0150219816b6a1fa26fb4699fb7daa9caf09eb1999f3b70fb6e786805e80375a \
          --hash=sha256:02893d100e99e03eda1c8fd5c441d8c60103fd175728e23e431db1b589cf5ab3 \
          --hash=sha256:02ea2dfa234451bbb8772601d7b8e426c2bfa197136796224e50e35a78777956 \
          --hash=sha256:0f29edc409a6392443abf94b9cf89ce99889a1dd5376d94316ae5145dfedd5d6 \
          --hash=sha256:10892704fc220243f5305762e276552a0395f7beb4dbf9b14ec8fd43b57f126c \
          --hash=sha256:16249ee61e95f858e83976573de0f5b2893b3677ba71c9dd36b9cf8be9ac6d65 \
          --hash=sha256:1d37d57ad971609cf3c53ba6a7e365e40660e3be0e5175fa9f2365a379d6095a \
          --hash=sha256:1ebe39cb5fc479422b83de611d14e2c0d3bb2a18bbcb01f229ab3cfbd8fee7a0 \
          --hash=sha256:214ed4befebe12df36bcc8bc2b64b396ca31be9304b8f59e25c11cf94a4c033b \
          --hash=sha256:2283a07e2c21a2aa78d9c4442724ec1eb15f5e42a723b99cb3d822d48f5f7ad1 \
          --hash=sha256:22ba7cfcad58ef3ecddc7ed1db3409af68d023b7f940da23c6c2a1890976eda6 \
          --hash=sha256:27c0abcb4a5dac13684a37f76e701e054692a9b2d3064b70f5e4eb54810553d7 \
          --hash=sha256:28c8d926f98f432f88adc23edf2e6d4921ac26fb084b028c733d01868d19007e \
          --hash=sha256:2e71d11abed7344e42a8849600193d15b6def118602c4c176f748e4583246007 \
          --hash=sha256:34d5fcd24b8445fadc33f9cf348c1047101756fd760b4dacb5c3e99755703310 \
          --hash=sha256:37503bfbfc9d2c40b344d06b2199cf0e96e97957ab1c1b546fd4f87e53e5d3e4 \
          --hash=sha256:3c5677e12444c15717b902a5798264fa7909e41153cdf9ef7ad571b704a63dd9 \
          --hash=sha256:3ff07ec89bae51176c0549bc4c63aa6202991da2d9a6129d7aef7f1407d3f295 \
          --hash=sha256:41715c910c881bc081f1e8872880d3c650acf13dfa8214bad49ed4cede7c34ea \
          --hash=sha256:418cf3f2111bc80e0933b2cd8cd04f286338bb88bdc7bc8e6dd775ebde60b5e0 \
          --hash=sha256:44edc647873928551a01e7a563d7452ccdebee747728c1080d881d68af7b997e \
          --hash=sha256:4a2e8cebe2ff6ab7d1050ecd59c25d4c8bd7e6f400f5f82b96557ac0abafd0ac \
          --hash=sha256:4ad1906908f2f5ae4e5a8ddfce73c320c2a1429ec52eafd27138b7f1cbe341c9 \
          --hash=sha256:501a031947e3a9025ed4405a168e6ef5ae3126c59f90ce0cd6f2bfc477be31b7 \
          --hash=sha256:5190d403f121660ce8d1d2c1bb2ef1bd05b5f68533fc5c2ea899bd15f4399b35 \
          --hash=sha256:5498cd1645aa724a7c71c8f378eb29ebe23da2fc0d7a08071d89469bf1d2defb \
          --hash=sha256:5cf4e27da7e3fbed4d6c3d8e797387aaad68102272f8f9752883bc32d61cb87b \
          --hash=sha256:5e0b74767e5f8c593e8c9b5912019159ed0533c70051e9cce3e8b6aa699fcd69 \
          --hash=sha256:5ed875a24292240029e4483f9d4a4b8a1ae08843b9c54f43fcc11e404532a8a5 \
          --hash=sha256:5fcd34e47f6e0b794d17de1b4ff496c00986e1c83f7ab2fb8fcfe9616ff7477b \
          --hash=sha256:5fdec68f91a0c6739b380c83b951e2c72ac0197ace422360e6d5a959d8d97b2c \
          --hash=sha256:6344df0d5755a2c9a276d4473ae6b90647e216ab4757f8426893b5dd2ac3f369 \
          --hash=sha256:64386e5e707d03a7e172c0701abfb7e10f0fb753ee1d773128192742712a98fd \
          --hash=sha256:652cb6edd41e718550aad172851962662ff2681490a8a711af6a4d288dd96824 \
          --hash=sha256:66291b10affd76d76f54fad28e22e51719ef9ba22b29e1d7d03d6777a9174198 \
          --hash=sha256:66e1674c3ef6f541c35191caae2d429b967b99e02040f5ba928632d9a7f0f065 \
          --hash=sha256:6adc77889b628398debc7b65c073bcb99c4a0237b248cacaf3fe8a557563ef6c \
          --hash=sha256:79005a0d97d5ddabfeeea4cf676af11e647e41d81c9a7722a193022accdb6b7c \
          --hash=sha256:7c6610def4f163542a622a73fb39f534f8c101d690126992300bf3207eab9764 \
          --hash=sha256:7f047e29dcae44602496db43be01ad42fc6f1cc0d8cd6c83d342306c32270196 \
          --hash=sha256:8098f252adfa6c80ab48096053f512f2321f0b998f98150cea9bd23d83e1467b \
          --hash=sha256:850774a7879607d3a6f50d36d04f00ee69e7fc816450e5f7e58d7f17f1ae5c00 \
          --hash=sha256:8d1fab6bb153a416f9aeb4b8763bc0f22a5586065f86f7664fc23339fc1c1fac \
          --hash=sha256:8da9669d359f02c0b91ccc01cac4a67f16afec0dac22c2ad09f46bee0697eba8 \
          --hash=sha256:8dc52c23056b9ddd46818a57b78404882310fb473d63f17b07d5c40421e47f8e \
          --hash=sha256:9149cad251584d5fb4981be1ecde53a1ca46c891a79788c0df828d2f166bda28 \
          --hash=sha256:93dda82c9c22deb0a405ea4dc5f2d0cda384168e466364dec6255b293923b2f3 \
          --hash=sha256:96b533f0e99f6579b3d4d4995707cf36df9100d67e0c8303a0c55b27b5f99bc5 \
          --hash=sha256:9c57bb8c96f6d1808c030b1687b9b5fb476abaa47f0db9c0101f5e9f394e97f4 \
          --hash=sha256:9c7708761fccb9397fe64bbc0395abcae8c4bf7b0eac081e12b809bf47700d0b \
          --hash=sha256:9f3bfb4965eb874431221a3ff3fdcddc7e74e3b07799e0e84ca4a0f867d449bf \
          --hash=sha256:a33284e20b78bd4a18c8c2282d549d10bc8408a2a7ff57653c0cf0b9be0afce5 \
          --hash=sha256:a80cb027f6b349846a3bf6d73b5e95e782175e52f22108cfa17876aaeff93702 \
          --hash=sha256:b30236e45cf30d2b8e7b3e85881719e98507abed1011bf463a8fa23e9c3e98a8 \
          --hash=sha256:b3bc83488de33889877a0f2543ade9f70c67d66d9ebb4ac959502e12de895788 \
          --hash=sha256:b865addae83924361678b652338317d1bd7e79b1f4596f96b96c77a5a34b34da \
          --hash=sha256:b8bb0864c5a28024fac8a632c443c87c5aa6f215c0b126c449ae1a150412f31d \
          --hash=sha256:ba1cc08a7ccde2d2ec775841541641e4548226580ab850948cbfda66a1befcdc \
          --hash=sha256:bdb2c67c6c1390b63c6ff89f210c8fd09d9a1217a465701eac7316313c915e4c \
          --hash=sha256:c1ff362665ae507275af2853520967820d9124984e0f7466736aea23d8611fba \
          --hash=sha256:c2514fceb77bc5e7a2f7adfaa1feb2fb311607c9cb518dbc378688ec73d8292f \
          --hash=sha256:c3355370a2c156cffb25e876646f149d5d68f5e0a3ce86a5084dd0b64a994917 \
          --hash=sha256:c458b6d084f9b935061bc36216e8a69a7e293a2f1e68bf956dcd9e6cbcd143f5 \
          --hash=sha256:d0eae10f8159e8fdad514efdc92d74fd8d682c933a6dd088030f3834bc8e6b26 \
          --hash=sha256:ebc55a14a21cb14062aa4162f906cd962b28e2e9ea38f9b4391244cd8de4ae0b \
          --hash=sha256:eda16858a3cab07b80edaf74336ece1f986ba330fdb8ee0d6c0d68fe82bc96be \
          --hash=sha256:ee2922902c45ae8ccada2c5b501ab86c36525b883eff4255313a253a3160861c \
          --hash=sha256:efd7b85f94a6f21e4932043973a7ba2613b059c4a000551892ac9f1d11f5baf3 \
          --hash=sha256:f7057c9a337546edc7973c0d3ba84ddcdf0daa14533c2065749c9075001090e6 \
          --hash=sha256:fa160448684b4e94d80416c0fa4aac48967a969efe22931448d853ada8baf926 \
          --hash=sha256:fc09d0aa354569bc501d4e787133afc08552722d3ab34836a80547331bb5d4a0
      aiofiles==25.1.0 \
          --hash=sha256:abe311e527c862958650f9438e859c1fa7568a141b22abcd015e120e86a85695
      annotated-types==0.8.0 \
          --hash=sha256:f072f4d804ea359e4eaf198b1af7a8b0943881a87f31bb764f8bf219bb9419e0
      anyio==4.15.1 \
          --hash=sha256:6152fdbbf9a77fdec97731721bebf7c4c44f7c29b424b0065826173efc7ed101
      asyncpg==0.32.0 \
          --hash=sha256:0549af18b697221d1992b7def18aa61652a85ecbe6e19ba2a75277560efe6016 \
          --hash=sha256:057ed2455e4e14ad9949f1ac1829112c7d0454c9810b124f36de1486febe6824 \
          --hash=sha256:08410cdfa76f4a09f7b396f3e860959f33078f2622e60e4fa4e7a0493f41f452 \
          --hash=sha256:08a978ac1d21957008502f5c25c10acf327b6ef2d192b276fffdfce4ba037114 \
          --hash=sha256:0b7706ff96cfe26fc48aa191f72f8076ddc2c52a5bc75fa9d3f34066e734e2d6 \
          --hash=sha256:0c764dce865b41878396e736d4d2c6c6ce3a8e1b61d1f6bb292e30d265ae7ca6 \
          --hash=sha256:0e25fe441cca81c277554e0f8f7f9c6987d2aaf47cedfc7783d9717ce2853371 \
          --hash=sha256:110f72d33c8b944ab421ca383db0b8849cfeb861547fee6cbb61f65a6bcd0985 \
          --hash=sha256:14ff79ca2574182ce258159c48978a086f9026fc121d935017b5d10c64fa3c72 \
          --hash=sha256:1fba43a9a230ce4d2b4593b761b8e03630c613c282b24566e27c7f53695273b1 \
          --hash=sha256:22927bda5ec97903dc479e08874e667fcb46ff8d2a8ddfe16612f45f1da54d38 \
          --hash=sha256:23638de661ac9a7975278a4fafb1f4c8613e7aae04562675f604dd20ec10e8d8 \
          --hash=sha256:2c6366841a792d0a4d16991de240a8053b7c4772a18a5f27fa6fad09c0e359fb \
          --hash=sha256:2f87452025b47ce80dcc3a0be2b5d1f8aab5deec2516d266f1643d4e53cc40d5 \
          --hash=sha256:38640b106705fef8b0f46cdb5fd9dcf6a638eed5cadb0f441714a21405ca8a0a \
          --hash=sha256:3bbf08c08e31f43be858255614518e78cdfb343571e557e818e9fe736334f4c8 \
          --hash=sha256:418d266a553e932bf961bb43bfd610ee6c5425fb1b9a599a5828fd12bae8f5c4 \
          --hash=sha256:4412cb864442355a6d944adb34c098924d1e14230b6ddbbe9665cffdf2708e8a \
          --hash=sha256:469e6520a839957304582eb8a708d874985914500b64517155f80e6fec00e742 \
          --hash=sha256:4cec40b66a36b14921c155db78631cd96ed00e225fdf38dd5532e9aef350a498 \
          --hash=sha256:4dbe0982cb3ded878de0867dfaeae3116faf471d484ea28b3e3da942f01fb778 \
          --hash=sha256:4ea1a72a00fe705b68a9727c3d538c4c56690af9bb1cbbf3c089f5d3ddcccea0 \
          --hash=sha256:4fa68acb42f22436597016e5d7feef7b0b5c49b4c56aece3fdb3ba0da2326cb2 \
          --hash=sha256:50b283fb4c2f7ecadfa5cc959f5a44ea98a20d0ba89b4074708fb0a4a080c324 \
          --hash=sha256:543f02790d086244c7cdc849e4b671b6c2048be0242b78d943494da6e80c0001 \
          --hash=sha256:54851411bee2aa51a30d0911524201fbb05f82cc0f7c248b140203db637c723d \
          --hash=sha256:5789340b9bcdab94a19eb8ff119322a09991e3626d131b55828535b373e285d4 \
          --hash=sha256:58975b1a51a100c4716ebf22f84c249d27140f7b9385b64ad9b676836f1db9ab \
          --hash=sha256:5ac18d9ee7a8ca70aed276f79b249d9f37e4d55e3525db1002b5f0b62ddec4f5 \
          --hash=sha256:5c3a48908cb0a02393e5bdab7fa92aefd700f2a93212bf91f04aa9657b4f554d \
          --hash=sha256:5faf73279afe1b2137ce503491500b664621762485233ebacb6fb91f7f092baa \
          --hash=sha256:63417b8f7369c54f6754c1fbd5a2968fbe632ff55bfbedd56a0177b6a96bd251 \
          --hash=sha256:643d8d6e955a355045dddfe827d74f4f0d1dc4a18e06963a08260af838fbf093 \
          --hash=sha256:6a1e671e67f4b0bef3c03f37a896d61706f769a83922c119070f1f04e415dc17 \
          --hash=sha256:6af2af292a93d5ef800007c8f8f66b85af2a49b49e4b56a10685a0dc24a6af83 \
          --hash=sha256:6b95fc2ebdb4af072bfa8b64c6d0397b49242d17bef1c0337857904f9267dab2 \
          --hash=sha256:6bee7bb5394bf55fc3bf4144625c33f298949961acdb1e0d67e60f958ac9a2e6 \
          --hash=sha256:6d1d1cd1348ebb9b204b5f56f977c5d4380674c25cc094064bf32bd9c3b7273d \
          --hash=sha256:6e83cdc21ed0a027d3065b19f9fffaf864b91bc007f30bf6e385f2fe84061a79 \
          --hash=sha256:764227423bf30a3001d3da6df90e82d30a2a097d762e4ee5fa074236eda262f4 \
          --hash=sha256:77cf9d7023f063ae6f9e443077b55af0dc1807dd9afff1ae656b93ee0cddedc9 \
          --hash=sha256:7cb31f7a8472ddc6b6f5c9da1290e901d5c77c8441c7213bd13b13ef6fe6359c \
          --hash=sha256:83510bb25d38f0415e155aa3a7af78621369891f5ecd8730d012d9cb26143ffc \
          --hash=sha256:8592f0ed9c315b2117dbdc707cf3292f09a89d5b07661016a84dd881326965cf \
          --hash=sha256:87780aa30b40e2de89717b51cdae4bb80b21b8842c02fb560e1e907e5a856a3d \
          --hash=sha256:87957755d11639cf248c6aaa094eee9d150f07065866d1710c9427e02dfc0790 \
          --hash=sha256:901bc87b94539f32853bd73a9b02fa78f7feed4cf628824caad3093ec6662f58 \
          --hash=sha256:925ce1cc54419d468bfb77632d91e5e2be5be0fdf9d43680c68fe7cedf87051a \
          --hash=sha256:9509e21fc526f1fc27cf80ad9f9b8dde3f3e21935d46be66d649635321d3407c \
          --hash=sha256:968c570c5913b7ce0995953d7239bd2367142d1af4359f87699f7a6ca75c4382 \
          --hash=sha256:96c8226d2026e025852facb5a05035ea5e11b14bebb6b42e4e43948ef8f0d075 \
          --hash=sha256:a515d2875d5a1ff33e222012a90bedbd0be6ee4f13dc13f14d9ce8417aaa799e \
          --hash=sha256:a759f98c5652443db501b20041aeee548e9a04fe7ae939067321acd207218447 \
          --hash=sha256:aa8ca9836448ffac22a8df6a82f48284e45a6fa263c7b06ca74dfeeb9350f98a \
          --hash=sha256:afec11e0b9c001e69966becacd2f948cc8949b4916ec4c0f4dc9b52e47de4528 \
          --hash=sha256:b1666e1b747ebbc75c87cb31972704ae8a3ca15b950f94456e97d26781c67d10 \
          --hash=sha256:c032869fd9c3c9fd1a86ad67e53f63906159068087c2674dd1e19be3cffff571 \
          --hash=sha256:c3ef1dfd11919280e011ffd1c873323c5088a94fd2c3f77946a5250cf306e2eb \
          --hash=sha256:c7a8f7fa8304f757e23cccb8ffef6a6fce0b6320ffc565a884ee3cd0dfad1ac5 \
          --hash=sha256:c938c4da9166ac1ef330475e314e2b94c68bde2795be0f4e8a1e00ccd806cadd \
          --hash=sha256:cd5d16b3a5db37c1e6e445e362952b4af569f85f94e162f947bfa8ea25a45fa5 \
          --hash=sha256:cd7157a86817730c3239bc687abf8186a471525d695e225c187b9a523a808a98 \
          --hash=sha256:ceea1064500d0d7a46c092cdbe9752064c23b720ab0e0bff83d1030fffe7a50a \
          --hash=sha256:d0e4508a3d62b0f42d7a99c030c364050b11e75f61c9dd4861e5fdda7cb60636 \
          --hash=sha256:d10ccbf924d05905a961d284060e1b63d3abc2d137adfe729f5283d29272012d \
          --hash=sha256:d148cb6a9081ed999ca3cd0d95fb9eaf79bf17d885bba93c83de52273d2fe0af \
          --hash=sha256:d3f745f4947df9004e2637753ff81d52f305f790f49d67f72e1677db12b07a7b \
          --hash=sha256:d74eabd68e68861333e3fcb92b520a2a851f6485abf4b723887590399d4980c1 \
          --hash=sha256:d78145adedfe51dc2fda623e6602cf816dabc2eafcff693bd50484321a1c9034 \
          --hash=sha256:d809399022e244eb86bb532a4ae9a45746e0f6dc5154fd6aa2f6ad63fa3f5373 \
          --hash=sha256:db69b9cf879bddeea41210c80b8c8877bfe2709e2bee9d18d5a5c00e7eb75972 \
          --hash=sha256:e101801b4124e905da0732cf2b0d838f682a9ea5273d7cced3d54bdbe744e6f7 \
          --hash=sha256:e1120ef2ae3a5e514c9ea9fce83519ba692710ea5f38434eadbbf12789073dfe \
          --hash=sha256:e45a8ea8a3f5258a2787e7e08330f6677086313c23126896954a264fced4862c \
          --hash=sha256:ed3ae4c3659aea1fb0e3a6c1061fc4c64d9b7a2a8f4a27443dc43d74fa84cf03 \
          --hash=sha256:f2342b1f3e87b2096320a77edcbb830fbd23b1d4d4842c57567764430b95e4fc \
          --hash=sha256:f24d20a68f0e37ca6fc490388e7eeb48abab3da0dbf06248135ed6179f5f521d \
          --hash=sha256:f8eadd207c26850a2e15f3c2a1096b5d051ea6758a26f2f3e65ce16f84297ed8 \
          --hash=sha256:fbe1f8c788fb5df18ea8a5432dfa2473fd8f7f088025fb83d089a7c7b37e37b0 \
          --hash=sha256:fd5adfb01cea16908d617af55b00a84c9e581964b77d4301c29fd735bb7850c3 \
          --hash=sha256:fe3036fb6e7b61159f554af153824786999142b69fea081acf8cb0958603ea26
      attrs==26.1.0 \
          --hash=sha256:c647aa4a12dfbad9333ca4e71fe62ddc36f4e63b2d260a37a8b83d2f043ac309
      cbor2==6.1.5 \
          --hash=sha256:015ed73f10e1f7b67306d41e36e0d7dc40e4a2100bc5c29b7a7f039ad3dc9061 \
          --hash=sha256:040cf628af473fe18cb6f56bdac556d2398102e56852aab5206fbeb3dbde6b52 \
          --hash=sha256:0529a95c1330c9c381286650dd65ff5b4ef136dcee06474ad30c028b5ae99a50 \
          --hash=sha256:09eeb76177758a0fdf1627a9428b384756872b048c6c0d7d158106b29b207d2c \
          --hash=sha256:0b1fa210f23b1f822ee0c9157c99b0e851fce93c6da1dc8441aa7fb3c4089d70 \
          --hash=sha256:0c1565bcd74a389b581e292592ccab0ed9c46286c6e986256820bc68c9ad7e8c \
          --hash=sha256:0fa113902a302c22429b32e2454251a8fd14b18204fdff647c869a54114c3ed1 \
          --hash=sha256:10d5237100190133d6a770181a63d93752cb67a2849c18484d196b5f8880784e \
          --hash=sha256:151f624186a6b607d14074dfffe7b601f403445ab430554e3d920390c3068b05 \
          --hash=sha256:1538e87b4b32764bc4940a37b6aa72e3bc6855033aac18d392d70daa89113a2b \
          --hash=sha256:1ebbc6e2d5ea8acf44cc2247d48ca4ccae724fcdb97eaa673903e2d87f0ffc5d \
          --hash=sha256:2634a4e8dbd86cfbdace0a546a1ded1fb024ebc4fbbeaea0232cc76721e6bc91 \
          --hash=sha256:30f88d1aff6c8c58ffec56591468f820d5ce6aee0bd64ae7443c0d7ef653eaf8 \
          --hash=sha256:40754de6aef3f3d37f2ab36bb431da145359d0e28fce739683f8717ad2e97280 \
          --hash=sha256:4144e2ba881534f62968cdb4a4f134e07a351e75c997d8debca65fcb2edd61c8 \
          --hash=sha256:42217c9de0ead6c5a6c1a6ca6b836204ac46b5bf4f57c758f522f308d7784bf0 \
          --hash=sha256:4c824355799799ab065686a05f65398319109955544db35cc797c60ad208b174 \
          --hash=sha256:4db32eefe9fc173939d114fb78e09f967e69627714ad2e3bca807d0ea9d386ad \
          --hash=sha256:4e298c8a88488ebbf5475e51273b8d80da08f7b47aebfa79eb904fc82da49474 \
          --hash=sha256:519f3f0d0d9467091c678f4a19a31e1b8756c10bbd6294cb3f906092f3da1597 \
          --hash=sha256:547c58e758462f06ba542b0af21afb150ee64c4c81d7ca6d1ecae0655c6a283d \
          --hash=sha256:5a5859d1f82dce094a1bdd6a5b318411b750262070bf5d37fbc9607d185f0b1b \
          --hash=sha256:65a677ff460f5c31f060a4bf8518f3e8184c321fddc0223a5ac2fac59a7f9f30 \
          --hash=sha256:68bcabc5b36a7c7c8825625b7b331a74098a4839d5d38b5cc29cb30a7acfee49 \
          --hash=sha256:694f75fdcdb8c6b9a71ab77f789f56be1deab20bbdbf948d5ff53cd7c2543dfc \
          --hash=sha256:6f340682e2481ab729c399f8b81147476c5a179cfef65d02402702aeb9429088 \
          --hash=sha256:73b97d92ce64a344015909f1888de0abec76211b9c1f33b075563a05512f3a98 \
          --hash=sha256:773ef85feea8beb5666a525e88197e3ef1c6629c6b6cf721e31b228c97cf6555 \
          --hash=sha256:789ef813f416d353aecd5c8824860ee4be94e0f1179a385eb2beccfbeb615e4f \
          --hash=sha256:7de5383eb059498291415f5b07f99e54dac4603dc99960eb0e2307c9cb2dc352 \
          --hash=sha256:7dfb68b65d6b0d0d90512626247bfa4993354f1e2b2d83b28b51785e63853422 \
          --hash=sha256:833db11fbea9808b080e5340d5f96615e28a6a6617618a4331e60082d0dc1ca4 \
          --hash=sha256:8665b7970e563fb807cca5c42815fe0741192a899b74bf9052557486a46f9188 \
          --hash=sha256:9140388e9a732f3748641abb91d257d30cc466a7ed13c2c5a3d1aaa6af37bd66 \
          --hash=sha256:9677ce1c3c0cb1fa5a4f721a127fc2cc06e8efc43ee8e5f94e292186d6b51953 \
          --hash=sha256:9907225060f8afcf31b5c97711cd057272160056a6b1b488313cc2b20c0afe74 \
          --hash=sha256:994b09c578e9dd7c5687a9f151f545bde705d12e47427b5a78c9d6cc970187f5 \
          --hash=sha256:9b3ba6f694ec196ebefc9c67ebc862b0fecdd3d6f85d5557378cf20ff8b1fb31 \
          --hash=sha256:a14edbdc9e02d9daa72c3b8805edb297a6025a35e708f7dd8ccbdf1b18adb40f \
          --hash=sha256:a4956f498cbf5eab192e0f838cc787e09bef4caab57f05ccbf00451935cacb8b \
          --hash=sha256:a9a154e010044662ce2e433f7c49e9c0f89ad7b86cb20e5d2e5afe6fd1753162 \
          --hash=sha256:af14089f5fb36f89b3f766acc7d4990cdfba7487ec0249d51bfa3a8caad25f0a \
          --hash=sha256:b586912cdb086dbad12052250acd5922fbe66a341ebee7031039eedf90fe84b1 \
          --hash=sha256:b70d7c47ea84d456034d2be02e89d92eef7044cfcedf6f05058e21d4452f0fef \
          --hash=sha256:b73d982e35a60e602a200feb2a9d272e850efdc9ff767b0f4887bdbc16d23e52 \
          --hash=sha256:bb58549a45e3f6355338345a2df449f42f45d55e4a20af24d4302d76a1578650 \
          --hash=sha256:c87272763122be24213c7bb3d47750a3af034da8755fbd3fcb0694c1efb6c3e8 \
          --hash=sha256:c916d7af4edcbf5dba157e9a8dd927bbf1fd66d3f137618226f7ad8b54bd944a \
          --hash=sha256:cf89dd755e9781bea60bb67c1569d32ca10c38412126ab58bbc0235c697d98fc \
          --hash=sha256:db607ae2b12c7eb85d463fe502a2f50111125bee69e70f85f793f0b7da7896e7 \
          --hash=sha256:dd3e4f08aaf25bca5db6274ac40e4d138b0e09890510c1fda20d5b7840e505fa \
          --hash=sha256:e1028f34af9158ee810c705a1c6c0b7c71f1e0a3c890fb343afd75725a80c191 \
          --hash=sha256:e1e8a6a72c7ab2f82579497cb1d5564987b02559ab980fe6a5f82a7d65031d19 \
          --hash=sha256:e6d54e11887e649345b2ecb491a8e2866f4abdb6d83abc2a1a52d5ee23785ff8 \
          --hash=sha256:eb30032171afc7ab95e524f13eee0c9a79af356b0414fa3a3736b3febca7d641 \
          --hash=sha256:eba54489d82683e8cdb9af80a2e55c2089e439e76b60cdb9fd4dfdc62ecfee3c \
          --hash=sha256:edc4a4dfa313b2cd78d7562cb99b51615e06c89832b78c0c02e2b5c2e27906ae \
          --hash=sha256:f02c339ab9942578b63a5d54c8956191f6e88f3d8b2c918024ff565f7faa1bde \
          --hash=sha256:f0bd6334302a5016a2b0f5530b7aea3ff588b6894523fd8491b49f7ce9e67f11 \
          --hash=sha256:f294e65db28424fe89985faf74648622e04da7977ca5401ac65c7d1b6538d08a \
          --hash=sha256:f850860e43d47312cb962bfdfe1cd879b180a04d0e7352f80e426b3852be8b79 \
          --hash=sha256:f8f85a49db66df77546d278de4d249772a4557d715df07ba8ae155cfa6a7fb31 \
          --hash=sha256:fd34b35b0a2b366f5b4bd53489ccd10d7576b0d4dd68db38ef64b4e617ea8f76 \
          --hash=sha256:fe81e4ff1b6bab72856d020dab89d86d4dcfbe18af4ff3fe2f391e1b03d0793c
      certifi==2026.10.19 \
          --hash=sha256:42d35340cc5b9ba78e818ddbff0c5b1c2b779de448a340fd1b989f5fa8670e1b
      cffi==2.1.1 \
          --hash=sha256:046bfc24911b37851ee1b51aab8bffe713d89c68c6a057b09484ce9fd5f69b4e \
          --hash=sha256:06c72bb76605a4b0cd0aad6930b69d4baf7dd5d806cfc409b824191099700e66 \
          --hash=sha256:0beceaabe56af686895136a2de78db54ecd8e4046b236b8fd6d6cb61389e9bf2 \
          --hash=sha256:154852545011f779917b11c78db2358d095da62a9a172b78ad0a583ee5adc0d0 \
          --hash=sha256:194cffa889098ced9976c3fc6340305e43f6303657d298da55366907c05c22d6 \
          --hash=sha256:19ee6127ee34de7d83ce3d371ebc5ed91addbdcc39f9ab15ce4eb35a4e534971 \
          --hash=sha256:1a18a57b58cfb21fc28d72e876acf10eaed67a1ed96226f92af4df681d571c4c \
          --hash=sha256:1aa5645c30469b09530c4ebca77ebf8f17618293c58f8549cb1a543a50236e7d \
          --hash=sha256:1dea0e4d7d4f11f619fe8c1d76caf49e24405b4b5743c0e3be16a500ecd930c9 \
          --hash=sha256:208f941bb9d18e768138677f0a6d2ce01f590df56043dda1df1535ac57c88517 \
          --hash=sha256:210019b6c7cf07f081b4c54635c8cf744377001350e29cc0f81c4377b4797735 \
          --hash=sha256:246fa40ce8645a614ff682e0b70f37134e460eaf93a775e0cbe3cca585a67a80 \
          --hash=sha256:25792eac27877609e7bb06d42ff88278a6624fff2ba9bbb523c09616b117e80f \
          --hash=sha256:27350daa11d4f10c540e6e89dada4c54feb7256ad03e9a4dc075ebad7ba360d1 \
          --hash=sha256:28907ab9bfb6aa13184cfc17c6b8e1023c5ab6fd7076d8c20a35e59fe04f8f29 \
          --hash=sha256:2ae64be792b8966f2c69538199728b290e34726562896df1e5dc8ffd8d8188e8 \
          --hash=sha256:31348097ff5bbe827ccc41795d4dd099d9f0625e7def00ee653c137a490c2a6c \
          --hash=sha256:3143d81e29e1e20a9ce10901ec369012947876596f75a222235965f2b7ae832e \
          --hash=sha256:3222ba5d678f80a030e6afbcc33dc1ae5cb45facabb61cee2c7016b8432fde48 \
          --hash=sha256:3311ed60d36f83378794e1009ac6258bafbf81f7888b4caa7b35a521e3f95813 \
          --hash=sha256:334644fbac4eff73d985a17a91226df55d0f394160c4cfb880e084c8f7161cac \
          --hash=sha256:34e261f78cb6ceaaa36f42f2613f4380d94d9c759a9c73c769ee6e0247364632 \
          --hash=sha256:363e05fa78e15116c3c32c210ee36884fd6b9afa6d440e47112c3bd511d64cb6 \
          --hash=sha256:398aff33cee2767e3e781d2554c54bd0dff386bb437581e0d8011fde1a942ec1 \
          --hash=sha256:3d22a20b1fb1632cc72c22f95f7b0d2961c3e1c235f245ba4c606c4771035659 \
          --hash=sha256:42a494cee34437f05546455144f2b5d9ac09b1face62bcfce597d2e521066688 \
          --hash=sha256:42e2f76b9455f5a9a844f770bf3e200ed3da0e15f5df3db9c31fe80b04b3d004 \
          --hash=sha256:42f6930c31dc7f50732c9ae793c2786c7b6b044195967bbdde40bb9be81c4cc0 \
          --hash=sha256:456a61fa52d579ebf9df2e9552ead5129855dbaff6c1e5a9b1bc408809bdc062 \
          --hash=sha256:471cee653ae88de62096552e6d24ccb4a5adb8c8c9f10b5054d0122c15bf2779 \
          --hash=sha256:49cbc70e6542d4ccccb936558d1064a8012541e78f821f955cff24e357776c94 \
          --hash=sha256:4a7c934f7360e8cd64fe9efadcbd10c7c6364f531e432b9a4bf5ccbc9e0e8b50 \
          --hash=sha256:4be96343e422f2dfcd12ab5c9f5aebe03f82f737c6bffeca6830b3875cb44aab \
          --hash=sha256:4f42141fc14250de6dde5ee7ea4432be017252d91f19c5ad043c084cea629cac \
          --hash=sha256:507a24c282e0f42f8ed737cf048572cbf580468da5555764a8331735e9c736b6 \
          --hash=sha256:51b31d1c98274844cfd7838ce00bfc27c7423a4dc00fc0772fc3331c2cc90676 \
          --hash=sha256:58acb8ab8e295e6c5ea12f888cbb13cf21511ef2a3303a23f4325c29d17fe5c1 \
          --hash=sha256:5a59cc1c4442bc3d5c703bf720b51138d0bfc173618807c9ee2490a7541dd3d9 \
          --hash=sha256:5bb4e7ea95dcd6a014a6fef62e62467d67d8e582326443f3d68e71d6320a9fcf \
          --hash=sha256:5c58fe613dc5e5336357eff555824a314d8e43282600435c8d1cb6a7a2fedd13 \
          --hash=sha256:5e7cecbaadb83884793e05828cee59b210b24583b9c7425d0ba6a754fe22eb4e \
          --hash=sha256:616f097f2fe415bc92a247f02e11f634e1f9e9a83d327e3c915c15089c87869e \
          --hash=sha256:63bbfd5ded17c4840ac07cd8f1c21ba9d9708141f840b324f422f41b207e3973 \
          --hash=sha256:64faea20f4e2613363a1a9b9c7dd73058f3ecd00133a511e72ad7c511658f527 \
          --hash=sha256:661c298b4821edebead0c91edd2b00374d67ad7c5a1f7a91d4442633b79d6a72 \
          --hash=sha256:68e62fe11f30d5ca8289242866f0a5291402d8529ca2178ab8afc5c9694ae890 \
          --hash=sha256:6a8dddef476fab96d066d578fc88526767b836ab5ab21754e1d5bf3879c31c7c \
          --hash=sha256:6e192623c49c94421616a5778fba35cf0d5a8d000650c1967ef4448ee5cdd990 \
          --hash=sha256:7225e4514edb64eb6740324353e0da0711954fd8d7da4576755b1c6e09b697cd \
          --hash=sha256:75f80557d1389eddbd0de2681f6a390a0c5338c31ddaa821381c203fc3fd50d9 \
          --hash=sha256:770de9db11e84213beec501cfcaa013b019820ca881e03344dea5844f7876d94 \
          --hash=sha256:7750c6449dff7864bb9bb27ddfb0267756189201a3afc911d82b3caacd70dfc3 \
          --hash=sha256:7bde5e4cc5c10140859842b9d383af292b22639a4dffb725314baf45968cef80 \
          --hash=sha256:7ce713ace7c0e4520535b42b77eaa742c16dab813978064913e5a3cf82973b41 \
          --hash=sha256:7da0c5eff80f0197f3b3d1232ec5a682a9325f4ae9016a78f5f5ca35f9ced1f5 \
          --hash=sha256:7dbb61fe3a7699468030f71bbe5f8a0e326a151daa91beb11a6fc1f980c55e1c \
          --hash=sha256:811bd1e21d32de12efca32393a0ab3f5133b54fce9bd44b8bd77ab07da14bf6a \
          --hash=sha256:8ef53b2de9bcb9197d31854256575d59dbac0cba72ac627bb291ef5eceb74be4 \
          --hash=sha256:937c0052c05a31ca1daf18de3158eed4dbfcb9cc107adbea227728d647be701e \
          --hash=sha256:9d2055050ea716bd38b7f7f1579c275386646b4894c155a3e2f3cd62ed41b7c6 \
          --hash=sha256:9f8d177621de5cb38ee3e731eda45d421db093ec0739f46a5594babda7987a98 \
          --hash=sha256:a2d7755bef5a12ed488f4ef1f1b69ee9191d7396083b755a5d2295f6edb4768b \
          --hash=sha256:a48d62ab9d6f4f98c983223a547af44be6ca3691074c31cecced6facd3ba2dc1 \
          --hash=sha256:a4f00aa42f75d6e4595e8866e748cc1705adc0cddfeb2ca86d0d03993d63ba03 \
          --hash=sha256:a6e721d4b0e45d5b65e87534470e67b18dcd092c83f68fba09f152b9cbc061af \
          --hash=sha256:a730a083190634c65cca36ba5f489531576ebd79bcd5c8e172130f6453127231 \
          --hash=sha256:a931079504ecc49efed7744c476a5c343a92fabf66dec2db95edb1b2fdc770e2 \
          --hash=sha256:aa9511c62d14da7aacc9b4bf51f3f697a621e83b2d6919008243c3aad168eea3 \
          --hash=sha256:ab36d55f9ed2d067327667c2fea18dda018eb628dd6347aa01dda6cf1f5d3836 \
          --hash=sha256:ad2c86c495b899d862ea0f4b42891b8713a3bd45dd4105c7fd51c2a72f39f3a5 \
          --hash=sha256:aeae0e330c9f6acd681f647d46cefd30c29f93e3392882e792e82080c9691399 \
          --hash=sha256:b0431303acaea1089ad4b3e9ce4e6518193def1118d4073ca848635ee4ea2e96 \
          --hash=sha256:b5bdfd1c873d4e093aabc0ca84c4ca6dbc4f752afb5c86f146d9742580c9da2e \
          --hash=sha256:baed1e86cc735622097354b9d1281406caf42ff42a886d29faa8e8d1630333be \
          --hash=sha256:c1453022f490d2459a11819d83ad1d586e9ff65a12ac3e705ffebd46d3685dcf \
          --hash=sha256:c26608d2222fb1e94487e4a387d85f13eb55d5ed725cb25a0c589ac4ee60e7bc \
          --hash=sha256:c7659f22557c5a0bc4855cd635f55edec690cc008a40768527762cb9fb263455 \
          --hash=sha256:c8c69575568085ba0b1b10c0249d779a214aea6f6522e949a0fc9fb0fcb449d0 \
          --hash=sha256:c8d2c9fd1f2d16f780d15127abb050d13d1a76c03a4bd87d7e4980e45e511e12 \
          --hash=sha256:ca82be1a1d406ecfe1d25dc16cb33488e5a16bf4438c9fb590484ea29d92478b \
          --hash=sha256:cc572dace3f60ef98d7b12ff411d20f5362feb31a0439eab0085bbfd349982d7 \
          --hash=sha256:d18e5ac0f2f03f4f518d3e23db0f0cad7faa1da8620e9c09461d443bbf6e6692 \
          --hash=sha256:d28630f5854ab07ab1fd4aba756de52326c82e6be15d414b12793f1975048b54 \
          --hash=sha256:d9c275eaacd24aa73f94ffd6de08fc3f932424d8b6c376f4bed7cde376fe7bc3 \
          --hash=sha256:da0e573f9f97159390c89d9f1a9e41908b66d408cc5b58d08cf3847d844c531b \
          --hash=sha256:dddad92b554513a31f272570678ba307fb9f618f05e3d4a5eacafff9eae03e1d \
          --hash=sha256:df423d40ee8654634421812bc3b196da3f9bd7d32929da813f8394c4348a5358 \
          --hash=sha256:df913725b79db7bcf03448f36b7bf8815363417d5b58deecf9305e3e30f0f21a \
          --hash=sha256:e0bcb7e0f677f543555d2adff3bf19c05f66cdb4796e5ff602442ab2fe3c4ef7 \
          --hash=sha256:e2d65b31f36619cda3999b78b2aa9632e76b78448e7a56fc4240824200e7c4fc \
          --hash=sha256:e6e8cff14d6fb0be70a09c0bdc58096f501952d04624ebf867e0e56da2df8960 \
          --hash=sha256:f16c709686a78c727bbbf059f92b0bf41c6fc60deec706d2dc19f529175a6125 \
          --hash=sha256:f24fb43132a4c6b4cb4eb029492919b2db645be6808d738f244fd146c03c32cb \
          --hash=sha256:f53e442b08449d42821fa4a4fba000095af9f62742a500f978a9f557ec44339a \
          --hash=sha256:f5cfbc5fe74540d335175b656c725d74d90e3730c626d92575eea35029d9afaa \
          --hash=sha256:f81b3b8f3d4e343550fa4baa0e479bba9f2d29ce9c2e9b51d1ce1718d7442fcf \
          --hash=sha256:f8ec5e643a9a937f64e1999eb9f75d072263751912dc5cd06d3c85f8f44be7c3 \
          --hash=sha256:fb92203a88b3d3053034db775110081c49d28be6551923805e039924093761e4 \
          --hash=sha256:fcd22650c908d7b7da162bbfaab594a1227a15d1643a98c68b122ac642fa2264
      click==8.5.0 \
          --hash=sha256:255bc9599cf7748b4b1a446ccc735421bd08a2ae529a8b88597d3de5664ee360
      cryptography==50.0.2 \
          --hash=sha256:0ddc924c04591c2811ca024d62ecad4f7f6f08af8939c211438f48a16bd23602 \
          --hash=sha256:0ec5f09541743261e66e291b4a0cbf0fb2997aeaab6d9e9c740b9dba1b58d1c2 \
          --hash=sha256:0ecbc5652bdb6fc9eaf89a7d196e20941adfe812f43bc4ca05d9150496821047 \
          --hash=sha256:1981f1db4630889b9ef7803fadef12b056f428cb6b85c27ba57b774793b6093c \
          --hash=sha256:1ba34f04897fcdaa73f74145c25f3ec146fbd56593853e88adc2e811303c5f42 \
          --hash=sha256:241449bf940a5d27309bd317e6f9a2af6932113818bb2b8f5c59ddc7ef16da18 \
          --hash=sha256:25784ce8b9621c90c643efb9e1e2162ab3b0224cae446ad5e70e7fcb1ce18b51 \
          --hash=sha256:3dc4fd8058cea1644971207d530e1a03a184a805ffc8ebdddf0599d78a331b81 \
          --hash=sha256:4061c0079120205fb760c58acab6443e217307dcf05e3702cf970e0689972856 \
          --hash=sha256:4a20ce1e5cb4284a86692fdcba7cb8754185c6b2e5c56fcef3751cf451d3cdc2 \
          --hash=sha256:4e81d95e5bafc2d6e34e4bed780e53e4d5b9a2f928573428aa4d35fbec1eb0de \
          --hash=sha256:58a0c478eeca76fe5e07993c5a0703def34a6dc6a0cda4f5564639b33112ffe7 \
          --hash=sha256:58ddb5a8e3179d12f19e4ea34d2d32e9d63a4baa142c875c1eb59f41b7243acd \
          --hash=sha256:630ebfea3bf689d075f82316324ff7433dc447fe6bc1bfc76524b74b4a9567d2 \
          --hash=sha256:6f8700550aa1474a91e5dc07049c46f98b423b5b1ddd0483e0b51362eeeaf5be \
          --hash=sha256:78198641e5be9521beea5aa782bb551a58068d10e6eb04c9c680c1b69f2e7d45 \
          --hash=sha256:79def8d059362e7831389ed3be0ecdf58a89386e1271e35dd9f5af84e81bffd0 \
          --hash=sha256:7a8701d6b584d76e909e3d305b7d126b41439876a5aaf76cddc67fc230eafa2e \
          --hash=sha256:7afa5a6602a9f29af1f3a2965f831bae7c9d5d597b7cbb716d41ab3b7d89879c \
          --hash=sha256:7b75de3c8b3be1cdb1052747c929440c3eea46c1bc2cb8a6e3a48388e9b7b452 \
          --hash=sha256:7c6d0330c472d96f6a6afe24d80dfdf15176c33096f0a4397ae4c60f3dd3be48 \
          --hash=sha256:828d49b0ff5a0e3975865571c5d91dbbdd0d38d8289b249a163e9425413a5e05 \
          --hash=sha256:84f964e537f916e2cc85199e5a88742e964939b575ac8598b3f9d6cc416cdaf1 \
          --hash=sha256:85d0d9a31b9098e98534226d5686b47264b95e62ce459dc2e62fdfc809f9fe93 \
          --hash=sha256:87e9ce85beb6b328ba370cc6e6aea483c92617b4c95b1d33a49297eb662bfb04 \
          --hash=sha256:8c71ba2cd31fc93748c38e1b613200ff1c2665cbfd5341fe3a61cfde35a1430e \
          --hash=sha256:92e665960f25fcdc73725b9cec7a3824f279ba97a98653afe9ffac2e43668f67 \
          --hash=sha256:94e5e9f108ee10471288214d3d233fbfbb492840a8457eb85178d643ddeb32c7 \
          --hash=sha256:9c8402a82ea0dc4ceeab793db05f0fafa8ca139ca34fcde5df0f596103c74107 \
          --hash=sha256:9dab55f57c74c3cad24c323bacbbd04be4705ba6eb0d92e920b1fc4837ed5079 \
          --hash=sha256:a582ab2ae1d34f67112cadc86702774c9ea4374df6bca6afe672817203c99134 \
          --hash=sha256:a6557e5f38e065ca9fbdaf7cfc7435ecb1d113aa81a022d1b51921ee7432e227 \
          --hash=sha256:a9f7355e6fab51f6c369b86fb7571cffa05edee2c2121e0380a37fb9ac1cd5c1 \
          --hash=sha256:ab50ee449bf968271e820086f10a33d101dd060370abc10bcd22279be2656539 \
          --hash=sha256:ac9ed99d81760c62fe89d5f0815cdfa1ba9a35141cf30f1c2d044f04b4803d2e \
          --hash=sha256:b13478603dcd0a2479ff8e87e2c19a7d525734686fe3c49542472293a204212d \
          --hash=sha256:c423ab384a46c4dff7217b2ea5ba2e11cffdeab6441acd04cf65a369caf0366c \
          --hash=sha256:c5e67125c7dca78d199ec4e116aa93dbb83494808ecbb8211a2cb09b1bf41dbd \
          --hash=sha256:c71be1cbfa5cd9a41ee452acf1eccd82b2c05950358b106ec8ceb83411d1a020 \
          --hash=sha256:cbc8738fd8526d80f35cb3a40d41f41a2e7030bb3b18b09a6778ef63d291c2fd \
          --hash=sha256:ce47f66801c20ec6c6632453bb5960fe38939e9306970b48b3a5a26de7745d94 \
          --hash=sha256:d370b8d1dfcdf7130178137f6fbee6140774a1acc6cacefc4b42643ec11d0a3a \
          --hash=sha256:d38cdff612d06fa6a32840d5e1b1f7a27cee4a349aa9085d94a67789d6bfd408 \
          --hash=sha256:d8947001be83df1394050758ce0e745dd74fb134eef0a4b5124208dfc3a68c37 \
          --hash=sha256:deb9fde5c60e437ee4821bc9bc39ff31b42135c27e1dc61ef0a629389c1de62e \
          --hash=sha256:dfe9763530994147d9af1def057a5b9658b00e8f8fe8743d144d1e0911c2e454 \
          --hash=sha256:e105ab60406787da31fccc883fc0f733af1efd78f0136a4599692c4083a73d0c \
          --hash=sha256:e275096ea1e60cc595cda2836fd4a6c725d1125108b868be17f53684d164e2cc \
          --hash=sha256:edc3342adf8f697fc5f59c887a304356f147b397809440ed64e2fa6af2f50f37 \
          --hash=sha256:ee247f5c245c9a2fe7c8e2214e295918838e44e00a45a6718451e4004219e767 \
          --hash=sha256:eef4c2f3423810b3070ab391f85436d2f8bbfcb286ac15cbc73190b3563b1f1a \
          --hash=sha256:f21e8a22c8605750c7af886bab299a363721264061b4ac0a30efb73cfd58efc5 \
          --hash=sha256:f265528741e048bce55c3463ed721fb0aa45a5888d8add8cfeccb3035451bbdc \
          --hash=sha256:f2f9bd7f90c64fe89253f0a2c05e3c4856072660429ce8831b4235bf29403a67 \
          --hash=sha256:f785f6161f202ab04d8ca194158968798e480ca058943907972da5f12e2881e8 \
          --hash=sha256:f9f6143a8c75945eb960d9eb98905a441394abfa24afaae239d514ffb2586480 \
          --hash=sha256:fa8f5efb344d6908a1ce62f4a24e2e5780f825d6f53f5f50ec5ffacac72936cb \
          --hash=sha256:fdd28f912fccfec1846a94e2e1e8f9b0012f557f0c46fe4f3eb0d7a87afcf90b
      h11==0.16.0 \
          --hash=sha256:63cf8bbe7522de3bf65932fda1d9c2772064ffb3dae62d55932da54b31cb6c86
      httpcore2==2.15.1 \
          --hash=sha256:730f603058c260a3288378217b464713350c23e3b8fe8bba753701054032d98a
      httpcore==1.0.9 \
          --hash=sha256:2d400746a40668fc9dec9810239072b40b4484b640a8c38fd654a024c7a1bf55
      httpx2==2.15.1 \
          --hash=sha256:75841cd83d16b417f7d6da8f2089ce8120806efdbf96af37d46c5129c49015be
      httpx==0.28.1 \
          --hash=sha256:d909fcccc110f8c7faf814ca82a9a4d816bc5a6dbfea25d6591d6985b8ba59ad
      idna==3.20 \
          --hash=sha256:ab7ae7122974553370f0bdb919e1a960b2cd1bc1ef0276416d896db81c14582c
      jiter==0.17.0 \
          --hash=sha256:00b5a98df3e3a3e8cf7b619f4ac2f8bf975bbf3d95d02c5d17b8dbfe5c8b8245 \
          --hash=sha256:00d783a779c5664e16dbad5e3a3c3a75e128b07dd5f4765159658d9210a50ca5 \
          --hash=sha256:0239520085cac678e77a606fd7e3f1c60c371d719790c5e3807388d3da4354c2 \
          --hash=sha256:02a360707033d8cef53f7f3480817a1489177a259ec6ec01e98c37e0b922ddca \
          --hash=sha256:02adebb7ce6413c44d40af9ad59d1c1cd79630ccdcb6f7bdd2d461e48c03d8f9 \
          --hash=sha256:0619d806e260ecf0c2a64521942c94af5d547c9ec99b55ae4f51b538b5576a76 \
          --hash=sha256:073dc68c1a700c8fc480e877864a6b6ffc887533e261f4380c08c16bf09d057a \
          --hash=sha256:0b52d52035b3907c5b1f6277857b29c1cbfc965e24e0f27330dbed83edb591ec \
          --hash=sha256:10c5349312e5cb02b7a21e123a57665afa895953f05bf252a9dd4c13a572b7ab \
          --hash=sha256:10cd64a5720ad7f809ac5466ff1705813f1b6b510f195a73acafba0ac0e1f675 \
          --hash=sha256:10f5558eed511b830488003449d942bd75829ad6257dc58cb9a03e596a7777b1 \
          --hash=sha256:11902505d401691720f5785c15b02204248526edee11b635cd6c40cd52b81599 \
          --hash=sha256:155be7355bdb7ca76ab0961be8982c225f964a5c073a83984183f22391cc29fc \
          --hash=sha256:16dd0c1baf098ae70b8f3616574eb3fedf34e26670b89e16a7e67561f737ed2d \
          --hash=sha256:1b18434638228c0c184281609bf3d9459026a0f1ea48fb76c205e3ef72069caa \
          --hash=sha256:29f49b325e0234e4ad9ecca5b861ffbd09b95ccac9bd46fa55841b6e56eea5fe \
          --hash=sha256:2c45ad7c973ef33fe5114a953377b35a95240f4542c0724d9f781e47dc24bac7 \
          --hash=sha256:300ce01ab0215e3dea4d00090143c909aedc65c0f809b3c07983e1d038f291b9 \
          --hash=sha256:30793a24a31e968969757c9e08d830cbb15a2cd3c4959b4498b38f4b1c2258eb \
          --hash=sha256:30c692d567ba206c7cca38c9d1d0ccc70c9786290173c184d871ca12e9981ed7 \
          --hash=sha256:32aaaa764604496610a3ad2d98503ae88ccb2fbe769e892ff4533e778e85f708 \
          --hash=sha256:362bb47423886d45a9f705d2d9d4008c6eedd4e41eb1bab4e96fb6daa06b33fd \
          --hash=sha256:36ee6e69027396664e59995b9a635a947a5304ee9837279584a0bb8145c8f6b8 \
          --hash=sha256:370d8fe5bf201dc6925e8a84c81ac7291f74d9fd1778234fc79d517064a5c76b \
          --hash=sha256:37150a9e02e869475854fa20b7d0d5e26d18d0f8bc17293999973ff27e99ae7a \
          --hash=sha256:37f33d327900bf2879613b3363fd48df97b4232d0c41f54bcf2e790c2fc40a71 \
          --hash=sha256:3ad556afc289f15d2b181b941982d01f06190863c07440185b9f354e1bd2def3 \
          --hash=sha256:3bf4dc2b84a464117fb097d15a25c58d100d2692888e3b0d92df5b48ed16b7c0 \
          --hash=sha256:3c1a5336c04a41b1f1cf9572e294aec27cc569767ff73de7bf87a91f0bea7cb9 \
          --hash=sha256:3e05f5adbf68c4bd11e1610f394034d984152988e84be6f8314235ce6f2139e5 \
          --hash=sha256:40d2c240f8f80b5b0f201b29f0ae129c81448c60c772227a41747b5e0026f6a2 \
          --hash=sha256:42b0260445251b1bc520a63baa94a32d88e0f931fba234f1764db7feb7c72174 \
          --hash=sha256:454c4997d73cc466c71fd565d91e603b0274e48ea0c6b0b7a7aee6967e4ceb7c \
          --hash=sha256:455e4ab35cb2a4a91a8404e08fd3c621bae433922e59bf1c494fe20a426b013b \
          --hash=sha256:4607ec7d93355fbc25b8dc5189153cf21d66063b9f9cd04dd2774e6e783f9b6a \
          --hash=sha256:470e1b1e4c42f1ead2189166a299691871a2df5056c976e7fb96feafaf5f9d44 \
          --hash=sha256:492f37230bbf9581ab2c17bcda862c249afb9ae2e3ab2dd6db59943bc4cc3153 \
          --hash=sha256:4dfbfe5a6e1e80a7082af559f66386405025ec278833e0c649f69cbc6e1004cc \
          --hash=sha256:4e3f052c671d5f425cca5ea5901cf11a831369fba4a55a3862cab93c323b4c3b \
          --hash=sha256:5078ab00664307fab2019b522a93aeb191122789f085daf5fd9e362154021d4a \
          --hash=sha256:51e1519d676a9f14dad9c2a411170d43b022ddb7989562df4e849b261ce127b2 \
          --hash=sha256:523c499235fb65add25d4bb01b1c4709ce695efdc7deb6c0a7bc515b5c44e0fb \
          --hash=sha256:545c36a0f3b2238c242cc9785439d3242a871b7bc39fe3f441bcaa07bf3aa83e \
          --hash=sha256:55d0e0e613a3f9ad600cf436e0e2b8057d1b52bcf1d91b2d36ac53451231e6a8 \
          --hash=sha256:5888fe5abc1ca2fa834a3e1b4c7ef0dcece286a7d7e95a609ef0934b777b9fc9 \
          --hash=sha256:58df29268a95e910f17db7ec9178eb7f15aa8619aaca3575275c4e6b3f4fe4c5 \
          --hash=sha256:59bddbe6f9ffecc68d641e1e2d619ce64cf8a9e9eeb74e5c518f74fc87abf1b0 \
          --hash=sha256:5a52a430d04225ffde633e6840bf2381d34c019ff98526b5929755b9052fb199 \
          --hash=sha256:5bf350452a43173e69e1fc74847c57a60e3d7515807287f29849baa2a85d8718 \
          --hash=sha256:5c23849235d2142ce444b2b8c6eceee9f82f4cc0bd5c9081602e4155c6197807 \
          --hash=sha256:61aed66ee042b3b49ef85fdf75714234d055d89d8496ac1c6e47f89e7a30d5e4 \
          --hash=sha256:6219adaf59711ba7063a52496e8ec6d3fa3e209d7827d83eee3b2abc780a1744 \
          --hash=sha256:64846211a2debe7c071d2146d2283d2b0c1c93dc8fd5fb7794faac2ca6061b5c \
          --hash=sha256:686c93d86f2b426c803024b805bd161a6cd10e9627c23e901640eab646c0ad8a \
          --hash=sha256:6871973bfbd4408f7f1c632b30bbb5bbd9671c1bc8650af6823e24b7be13709b \
          --hash=sha256:6af5b74073bd25bae695e6d00919f6a9be7ed5a9f8836d981eb1ffe84139e6fb \
          --hash=sha256:6b303d88e6a0bda789ec4b7801c7bad68e27230ba1fe4baffc756d1fbd32dc9d \
          --hash=sha256:6cb41cd1432f1dc19a231cf70b54d42b2c9f05085155859263fce06fa4d41388 \
          --hash=sha256:6cf564d43c4388149ca58ee571d0f5ccf875e20d1fd4662fd94cc0d1ea3b10ef \
          --hash=sha256:6eb6aedeb7352b8f3b6af9cbd67983840165c00428e63f1b420a85885128ea31 \
          --hash=sha256:70f19a2ca8429f91e82eeffb2f51cb87bc2d6e953b009b91a92d29c3a16ccb03 \
          --hash=sha256:71dbd74314c5df52a1bccf7b8bca46d14e943af7a2012e73b23f49977ef194c8 \
          --hash=sha256:73b64e69c4150748e020356d958af94bec33c70a0a93d665cfa8f6d580fe1a63 \
          --hash=sha256:746243a080b4ca790b8499af3d7cf9825d5f5987933950cd818e767ee353d826 \
          --hash=sha256:755079792868ce5d4938e83b91a0939b34fb858a1ca65a104f2d771bea57faa1 \
          --hash=sha256:7573e80232c5bcf80c24c038cf7e53a463f5c3b1dd1dd4109d66304f4dccc233 \
          --hash=sha256:76eb4a5c20e86f9f848286f167024890f2862258a965d254774deb7fc1545ca1 \
          --hash=sha256:77f6aac0137309b31448c1bdcda4c6c77077664a6d018ece8d94019c68a5a5b9 \
          --hash=sha256:785a216bbaf8f15fc974e964ced7322cd3d774bb0e86949edd78c6bffd6ba35b \
          --hash=sha256:7b68d3495d95da120651a5628c7ebadee84ed001a1b76e6afc325c42482f15b5 \
          --hash=sha256:8079849db9a1371bfd90bad088458a8fb836261879df2233cc9632464ecf64e1 \
          --hash=sha256:81c83c0abe614446a283d994d2c07c4f58632dea2cdf66ba9e2921bb8ccd593e \
          --hash=sha256:826871c42cebaae22f0a2b5673a4a1a75c851bb2d13b3c17764a630a6b298984 \
          --hash=sha256:84963d3f395ef5e9a32ce47155e08a7962fa292c159a10cb98b931cef1416925 \
          --hash=sha256:84ac78df457e1ee3f7e733bd114823302ae8c5ad5542d7e6647d92ffaa090a04 \
          --hash=sha256:86d703d9faa1ffc8ae4e9de0fa007712ed2171b5c0d93811a8e2e105ac729b0d \
          --hash=sha256:86f3f9343a288eb85a81ef20a752b2f84564296636db54a9fff0b5c8deaf1df2 \
          --hash=sha256:8adca2e793288e5f1bb29279bb439d0d3cfbb50eddca7e7e6ffd42ff4f482406 \
          --hash=sha256:8c21265b251d99bbb40080d178a8953e35601d3a1564e05c4de4c0d2ca616797 \
          --hash=sha256:8c286860abfe8b100cac1c02e225e5776eb9216edd71ba17cdb237da4af32bc9 \
          --hash=sha256:8f770b0c77e5fac482e1ba03ca1a7e18286bfb213d749932a00a7e4cd5de5e06 \
          --hash=sha256:93946d89fa04d5ba64dd323a8dd8d901676cb8a3c81d99ae4f6c051a9b4c3f2f \
          --hash=sha256:96b8b0c6dc5d78682f54a450785e075aa929cde768304cad363cd4efba5a82ac \
          --hash=sha256:9bd3caac219df476dd0cc3fe01d2f1581ed588906feac767abd9614c1c12f8b3 \
          --hash=sha256:a277f97eba7d66b1ee27eb5dab5b774ff46a10c78d89a1d3dcce04ce1357c8ca \
          --hash=sha256:a3cebb1fe4a1abb00465f3f8a17e09112603e8b7c59e5c3adbcd9f7815a64acd \
          --hash=sha256:ac3c6ee3264d6f5c44c617f90bc7e8b9e1587e7d6708c9d8f811cb65582ee312 \
          --hash=sha256:af2f7501580f274b63c4b2283bc425f5df7edf06ae5b171e5f87d912ff359a20 \
          --hash=sha256:b550585523339b71cb852b811aae49d08d7601ad8ffe9f5dc1562f4c3d22fd87 \
          --hash=sha256:b75f85660108965a94be77911a25a253429307294d9415b3c597118977a614de \
          --hash=sha256:b847b18d066c46b3b7ae49d6c94a7634c5e4a8983146ee25562a092000f5e3ad \
          --hash=sha256:bcc064f99183a9cbe7f26ed648c352031a74145cd61ed75d34632c73eb46a5a8 \
          --hash=sha256:c19b9357309b8cc6de8a48fca8e44a8c9c2feaaa2f5896d037fa505d48fcab80 \
          --hash=sha256:c4289293e5278d9314b00f15c37f2120fa51d3d68565292e715524c750e775a9 \
          --hash=sha256:cfafd7be8b16ceadd298db542cead37cddc211c4c49e04ad2596924df18625b1 \
          --hash=sha256:d0ce4feb52493e3513335b2accdcd75605652e4632772d3c8c2f7b86954d7f39 \
          --hash=sha256:d2c0bf24c72fd0491405dce5d40194f2070e9021ce648c1a1d46234b93d848ff \
          --hash=sha256:d47687806f9c54c84ea38733507081337922beca90ce819c7d852dd485bc0f23 \
          --hash=sha256:d85c558c9f8532bba287a990ac63767c7daf756f0d8c030219f62499b1fa228a \
          --hash=sha256:da139721f4b7cafdbff580a4f511ea24cb91f4909330c6b926a1ca53836c0a59 \
          --hash=sha256:dbbfe4e3c21c8166980cddc5bee1a315df082454f007947dfb6fb73800768165 \
          --hash=sha256:dc0288ce39190ee33fe6e4ec73161eed34e7e2da509b525546ca061778d62b64 \
          --hash=sha256:e088612ff90ebc9247e1a43074b72835804261c47e6a6c01cb3ddcb55360d688 \
          --hash=sha256:e654b6b04e39c9cb19cb8b04c6ddf1f2db07751fa14156413969fd78bad0e5cb \
          --hash=sha256:eaba834b72d573547b9d966465b3394b749d5e14208cc70acb63aca37619ab33 \
          --hash=sha256:eae86b1f027031e39db2e0e9c4842221edb7b8cd474d23f87a79b3bd4b651768 \
          --hash=sha256:eb2295da7c3769f6719b227a237aa6a5cfa6550e478bc838001b592c57e16575 \
          --hash=sha256:ebf918dfd6a74adc1b9ad71f63c4ab00902fcd3b7fd39f2e24d871db8d713b91 \
          --hash=sha256:ec89771f4272b989487a6364e519db6bbaba323e8bbf949ac89a45ea9c18b7a3 \
          --hash=sha256:ed1a24005daac667d577402d75a2922f9775a165b146b883ff1ad3602d8be689 \
          --hash=sha256:efe9f61bb30174d2f5c8396445c360c96c44e78164d0815dfe627ccf57849574 \
          --hash=sha256:f0bc7f684b65bcda9c20434267577db71bf9905ceddd32b60d1d93278d8c8d3a \
          --hash=sha256:f3d7f7b34114f7ddc6d72a8e882d49de636b35d9fd12b4d420d3c5729f6c9812 \
          --hash=sha256:f753eb70b1474a29e635e7542ff7312e6d6b951e0b25e8a2e8c34eeb1ddcd478 \
          --hash=sha256:fa13acf1046f95df808c64b1310705e143fab87aee73ae00cc42d640867fd2c1 \
          --hash=sha256:fd7790aa79c8b518e512ebcdfce9f11d8ef5f30efd43720c8a19a548b39fa489 \
          --hash=sha256:fe15ddf316f1f1f643347d3a474e74ce61880c79a11ec5dca53df20c071bd3e8 \
          --hash=sha256:ffa0380ad091de7d3fc33e17a97ff479851ee18a0a2a3ee56ff3215cdc886656
      jsonschema-specifications==2025.9.1 \
          --hash=sha256:98802fee3a11ee76ecaca44429fda8a41bff98b00a0f2838151b113f210cc6fe
      jsonschema==4.26.0 \
          --hash=sha256:d489f15263b8d200f8387e64b4c3a75f06629559fb73deb8fdfb525f2dab50ce
      mcp-types==2.3.0 \
          --hash=sha256:968efdbdaedfab06adae40d378a34395f1090c5921d4be3c9cde283aaf76d91d
      mcp==2.3.0 \
          --hash=sha256:dd0c44c089d16453e8ae31a3877a0054d7a2314caaa81f5e0541b9b1734b2377
      numpy==2.5.4 \
          --hash=sha256:067374eb538c34c745436365cf7b0112595c1d326f21ce4ff340f61230239fbb \
          --hash=sha256:0b4724a19de67bea8cfc4970798efa78bcbbe2ac2613cfac16721a42d44de2a5 \
          --hash=sha256:0f02a46e49cfb6c73bdb7aea1c0d3461dbae9aba613542b65f657cd3d17b9fab \
          --hash=sha256:1c2e71b04c6cad90026e544501bbe0ab9290fa8a4d845e7e8c0d124fb429c988 \
          --hash=sha256:1ef3aa6d7e29bb13677323114280b05acc57607fa2300e66432d665d5418a162 \
          --hash=sha256:2132418bf8dd124a427ca9e6a1daf9ee1a87185344c95119ceae868b99466da1 \
          --hash=sha256:2199ed071f460487c8db2c0e5c0b564494190edb4772fe80f9aad88b2604def5 \
          --hash=sha256:2377da2dd3ba2c1200956acbab2a358c83b8e1f8531191672d1cd6ad83250d53 \
          --hash=sha256:298eca75243f2cbbfdb460560b9fb2a1792a33cf2ab4286efd43d92e8d3df508 \
          --hash=sha256:2c2c4afffdeb7920e445028dd71eb932cac3e704792e964bc2a232426d4f1255 \
          --hash=sha256:2ca144f15135b6212a5c47b1e2aeca6e412f102f95a2d5d88d8aec77eb255de3 \
          --hash=sha256:2fa3328f784fc8277fc48026f6cad516f5c561c5d8e2e39b3c9e0c8f23223b34 \
          --hash=sha256:325518d4245b9e331387702aa58c2ce1dc4cdcbb41dfb4ccd5dcbc7e08db1266 \
          --hash=sha256:332f3378fe077dd850e677ec01bdcc4f22368fb5d50ef10b2c79230b1bf5a592 \
          --hash=sha256:3573cd22564692a5b899ec344e5d5b9cc4576f2985b96f22af3564ed54f2710f \
          --hash=sha256:381a7a3d2e65e64c0ec302795ab9dc12bb1e73f150904699c153716177eebdaf \
          --hash=sha256:38f47be9f74ab870d2633b5456ae519c43758a8d1fd05342f0ce4ecc034396ee \
          --hash=sha256:4054173604cd8658796053f1f3bc0befb68ec1c0762c57fdad61e199256a8617 \
          --hash=sha256:468397ba3c64427474706e5c9123fe266395496714dc684294eac75cd4930d1e \
          --hash=sha256:4e263278bfb5ee6409db8aedbc4cc32973b1b82bc1e8d3c668551d04d83a7e37 \
          --hash=sha256:5258bc06526964be5face2fc6f756857a3f24f21ec3e72ca131337a75b165d6c \
          --hash=sha256:56733449d2544178beaa4545cee357370440cf056c197f9c7bfb19dbfdd0e86d \
          --hash=sha256:5ec3753760c1a6d8bb91200666e545c3a9728e6269dfb5d6ce02340996698aa3 \
          --hash=sha256:5fbf7141bbfd63aea22f435c9062a032b9ea0082fe9845dad7f021d3f1234e71 \
          --hash=sha256:64d1c8ac28a4077cf987e0a71a7a0ef7e2df70722f07f0baa42dbb7eb6938647 \
          --hash=sha256:64f9c9878c1938476365e11ccfb6b770f3b9e5f045ccddc514235041e6959365 \
          --hash=sha256:6c109eac9cd439193678f69d70733c1108487546ca8eafc107b510ae10c1aecd \
          --hash=sha256:6d6a71b9d9a97c03633aa12565ef2825ffa036cc1d99cfd50dacf0f128af4fe2 \
          --hash=sha256:6ffa07666f8da0eef81d149934a626d0d95fbd6838432a33e66245423a9062c0 \
          --hash=sha256:7415db95818b39ec475a5eea54d9e3b6bc83e3912158e46da3438cdce399804d \
          --hash=sha256:77045a4b175bbf5316ec08003880804336c78f92281a1b72222b274ea85ec5ac \
          --hash=sha256:7a14a461d9340f1b46b8648578aed9cdb8b3b018a8fac6c1dde2c9192a01a87f \
          --hash=sha256:80d6ef6e8620eb2c2b4c4caad50b5935d6db3cde2d51581b55dcc79e14016d1d \
          --hash=sha256:81e3420b27048b65eb14c3acf0c174a8cb0e023277716110347d2dcb26026dad \
          --hash=sha256:823874a507a84af050493b622affde94b6f7c3a0dc22cb2801381bc03b871c00 \
          --hash=sha256:8b4d2fd2d34e5f8c9235ee787de5631a37a28402b15cb80814df973d2be54129 \
          --hash=sha256:8dddfbee2e68d26d0d7d7d9cb247b1fd4409241cce32d815a11d97ec2cfde179 \
          --hash=sha256:950ea81d57ef070665581b6e1b5f6a029306423cd1739c5b95fe78aa30db6b9d \
          --hash=sha256:956555e0603a4d38019ae6925711cb9dc43195c076a928accf7ea5d50bddfe53 \
          --hash=sha256:98b053943e5a0474ec0da309d2cb9d3f18ea57f8a2067c2ab7b5f763d1068380 \
          --hash=sha256:9968ab7e49b93ac6e1c3b2239732183152c9150f16308d30b66a372cffe3483c \
          --hash=sha256:9cb18a327b49c5c337f972b03682f6a49855525faaf3c0d3e9c96cd0fd8880a8 \
          --hash=sha256:a7b1b6353e36a7e50de2973a38d705c88ee93adcf120673cee7f45a4a3fa223a \
          --hash=sha256:a813ed7719bf45463c51779e6a98d0385fe905e48447526938a4b8337333d551 \
          --hash=sha256:aa1cce2ff3f8d953de38b76bf44602caeb69f101430208f64a10067f7cb4b1d3 \
          --hash=sha256:ad62a416ddcf863bf44bba76fbf6b53366ab0692e294f51cae4b5fbe0d246788 \
          --hash=sha256:aec3fc4b32ff82421274f5d205c559c51c840c8df66a78efd7f3612dd005a26a \
          --hash=sha256:b1185012870173de7ae33d370bd45b1cf5baee747ea4b97036b65f4e93016877 \
          --hash=sha256:b11e8fda06a7d69f15ebf542660b74466c2e51094800c1fb794f47ad4faeef17 \
          --hash=sha256:b64a85f40e154983960a4167d4c1d57a50c7f109b3d3264a3a984154e90a8454 \
          --hash=sha256:b86966fbe4ad7de710422175572bcdc75fdedadfb54bc6fab7deabccddd7780b \
          --hash=sha256:b89d0aaae2fe498c648f4c4795c084db535af5bd98ef942b2a3681fb74ce8645 \
          --hash=sha256:bc39ac66a7a9a3fbd6134fda43136b60ffde99c8f4501e64e0d2b24da137babf \
          --hash=sha256:c05ede731b03fb1b7591faca9389ade3267d2bddf1ad8882bb3f2cc5e101694f \
          --hash=sha256:c6342f54c67093cae5c0227eb0eb772fdb79f2a2c37a6eb278b9909ee06aa356 \
          --hash=sha256:c668b2f0d651605b58892644b0e302c7157f7159544227758c896982ef384b18 \
          --hash=sha256:c9b80cdf5cedba0e90d93fa5f9a333c4d65bd545cd669b71bb97ce2b703c9d73 \
          --hash=sha256:cfd73180400042a7c532d30c5e287bdd03c59ff9ee1b4c0316af0539e29dfe23 \
          --hash=sha256:d4cccbbc78717966f764cd3af4fb70276fa01fc7a2688af11c78901fa5c04f05 \
          --hash=sha256:d549420b8858885cea8838a727842249218b9c1da24dd517e25c9c7a948310a3 \
          --hash=sha256:d8200f16437b289a5bb927c6e184eccc3e8389bc0070fea4cd5b9e13c1757959 \
          --hash=sha256:e94aef2c639da4a960ad0db8e06471208d8589974953d78b61d345b4eb99e394 \
          --hash=sha256:fbde6962867ee75b48b0ee29b2b9372ec5d617799dbaf38e82dc0596f2f7738a \
          --hash=sha256:fe4d21ab149f15e4e6043dfb0de87e6e5f34ac176cde83060e9802981fca2ac2 \
          --hash=sha256:ffa6ce09a1c6a08e9667dd9c97aa0b14184e8d18f2a14b78b2a2328c9147f076
      openai==3.35.1 \
          --hash=sha256:264fd0fafc889021f526b7c1e5a2df5ca3e8dea874738ecd31da666434f25967
      opentelemetry-api==1.45.1 \
          --hash=sha256:b31553efa588ae44bc306f863c785c5333a9ecc091248c6ee68b4b6c87fdedfb
      orjson==3.13.0 \
          --hash=sha256:0526a3456db67b264c6d661b5f090077f326b6cd074d0ef53a72763595dec5d7 \
          --hash=sha256:08bf722f923d2100bc5e5a5dcf72c656db557049c1bea26582fdd5dd9d5395a1 \
          --hash=sha256:1807c2fa49d393c7ee95fd1ef1b39cbb24aa3ccd81f30b84503ba59407666960 \
          --hash=sha256:1d84820b2ec4ac975cba482214032de5b0dbdd17046170c98e642ef9c4a4ee4b \
          --hash=sha256:2715c4808d1571029ed18fd07a82140bf3ba7def0dc89f8d015c416e3649bf87 \
          --hash=sha256:3ef75ed7e81dae34a3649f82df52cd85f9ac839a7d6ec78ab355b33b3b27ef7f \
          --hash=sha256:4329c19b8a25693f60a77b867c9d2a3ab637b20e36f5b7bea7f5acb492b44b15 \
          --hash=sha256:45e34deb3437509f4ec9888dd9ee5dc426cfe21be10f1eb4ea3a9e4d33034f9e \
          --hash=sha256:4e5c8175e1574dcbe446ee654275d353c1d78bbd9a0dc9f209bf35c9df72d171 \
          --hash=sha256:4ee06e53b998c71ce3eb93b86222912fdd9dcced685ac64d4525d36fac338ea4 \
          --hash=sha256:4f66eac85b072092e9941c3111882afd7527bf926cbc717038fa3654b582002b \
          --hash=sha256:50a5202ba388b3850ba24437951727d3aa6d79a21964a30ae8dc6a059a5fd34c \
          --hash=sha256:51d11525bc3ca736fa97ce4e4c7da9999cc00bf261522bede43b4e7531bd7965 \
          --hash=sha256:554948becd1110123ef9f6a6e1310fd92b2d07d2cbac6dbf65df3de75702e736 \
          --hash=sha256:58a9619d88f8818d9ab6b39d70d203789457ba13c1ed5d274f33ce9ae7e81a36 \
          --hash=sha256:5ef4d4157392a0439b74f7e49e5636b4ea43d9616bd0884effc0195fffcaa2d5 \
          --hash=sha256:637dbca1fccffe83780e806fbc0f17427c0c59bf822528eb0acc8f0aa9f19acb \
          --hash=sha256:64e8f345048d988c8b68d3882e5d41028fca1219a9939b32e4a77be34c8ae8e3 \
          --hash=sha256:65c4e0e106ccc7265b488385659117a6805c37d042f737558ecd68aa0c67ad8f \
          --hash=sha256:6adcaa85d79977659a448b4123a88eb33511a11ed2db243535ad7ea88a6668e0 \
          --hash=sha256:6c8bfe728b81b0fd58a3c7f3f9c5a113f87f2992c9948e0f28707aafd737c0bc \
          --hash=sha256:6d0684895b119ad167fb4ec05113639dc7f728022deec4756a710e838ed92e7a \
          --hash=sha256:6ff2a2c67f35202f7d823753d38ad371a9b7fc297567cdfff4420e763cb9f6f8 \
          --hash=sha256:7804dd1d6161da0e53b284c2aebf20f23e78eaac617300803e1467d1828d987f \
          --hash=sha256:78a12d4f8d740cc9ae197f5223682e5e960ba61b4fb2ce5a6a3bb54e83fde28e \
          --hash=sha256:7991921c5da527a963b6d4cffd0e4ea89c7e71d4be0c8be1bfe6edb223ce7d96 \
          --hash=sha256:7b3bc6b81835ce65f4729ae401607583d41139c6de95bc7453f450f1391d3e7b \
          --hash=sha256:83705c12b4afde10c62a5dd3fe6fdb21b7900bd0dcd5af1c85612ae94d0ee590 \
          --hash=sha256:84d87e322e1674408f85adea63f11aa19201eba082755aec20ebc217f493bbd2 \
          --hash=sha256:8594956a75223f657e1e68c568c0eeb3dd145f02cd6b78a47fd9a8095dbc4eae \
          --hash=sha256:89bcf2d4bc6c9a7e1763c8cf534f38712e66b76a0fefda7fb7785462f0d635e4 \
          --hash=sha256:89efecad02515df7f318d0613b5dfd6d2a1acd323a2b8294712789a715945525 \
          --hash=sha256:8c2ac5c09b017c484df1b4c68b2cf250b4e8ba08204cb58e7cd6cbbc71a9c902 \
          --hash=sha256:91d933e668ff0ffe164d7c2daec36beba6d1ce7fadb71538fbe142a71f8a1e6e \
          --hash=sha256:93c70a5e22bbbbdeafc7b273441e8452a196041d67fd4d9a9c450c66370a8486 \
          --hash=sha256:948bad47f2e2e43527f14248364a0e5dee26dd3184691010ec4a1ebeb0fd6771 \
          --hash=sha256:9825b954155b345c4759f24e5f8d652b9aec2261bb5d4e1abe06bba0a1200535 \
          --hash=sha256:a0377d6962fa431c93ecd78fdea771bb62ec545b24ee0c5d4e32acf2260af259 \
          --hash=sha256:a79cdc4934fe81f593072c94e13da3095e9d41c2deef8f6ff2901794ca1c5042 \
          --hash=sha256:a7bfc7db961c7d96cb75889dc6a1e4ae1e91d87ee61da564f582bd742b8dfeef \
          --hash=sha256:ac81530647c3423107cf61c3481e91f57134e9ddfb6ef83f5150ccbdcbc3a3ee \
          --hash=sha256:ae1d895cf7bbfd50ef34bb63bb727b14514f259f3e3f8dd010783bd38e864c6e \
          --hash=sha256:b081f0e7b600ff24513dec4ca75507fa05e904607847e386e8310d5b7b96b6c7 \
          --hash=sha256:b571236d8393edcd3236e07423f762bfcf571f852aad667a3bce9e7b755e0790 \
          --hash=sha256:b74c30e56346aad067937d766846ee74c231d1d18aad3f324e9b9261de3b2d5e \
          --hash=sha256:bceadfd314bd238f584fc229a4bbaf0e573597e7a026dec5429fbf29fd66c641 \
          --hash=sha256:c5e3ccaac3106e8fa6e2f2f6962449d7c757d7b067e41b395a19d6f0d6cec892 \
          --hash=sha256:c749ab3ac30b5ab1ffb7677f8b92eacfdfdc5260210baa398f845bc3714c05d8 \
          --hash=sha256:cbed5f4c4b88d94bcc36115f4c3bb3aa25da1563a5c3328aa3acebce2b083040 \
          --hash=sha256:dd61e64802d51d1e4f16531c64536354fc3bc67932dc0cff254044f72bf0f187 \
          --hash=sha256:dd9d9a101bd8dbfad112170f009cd155e52bb8c936468821a0d03cbb96c0e426 \
          --hash=sha256:ded33b972cffdaf4ca0ac917338ab61d2bb10d68987dbcae641c313fbfdbf499 \
          --hash=sha256:e8e05549f3b30f9d8a8e28c5aba11cc2a4b90b90961ec685ca58444b0815fc09 \
          --hash=sha256:e9b61676116f755126b90e740a9cff36b91562f47ec330056cc88cc3b9f02f4b \
          --hash=sha256:efa160215c4630836d3b1250af4c7a305acd8239e0d75aff986b8088c2fcacb6 \
          --hash=sha256:f5c05a8fee59309f537590a1ff12d3c1009c485e96a50a9ac60dd085c09d0fc0 \
          --hash=sha256:fb8644dc6d705e1269ed2842bf4dbe2b4e50d670de503bf79d5cef3a5148a4c7 \
          --hash=sha256:fbbad6b9b1da43f25c1f5b20cd5a268e028a2fc95d5a8d1ade6059973bc71584
      prometheus_client==0.26.0 \
          --hash=sha256:fa93d06737aa02bacd05794768508bb97d2fbee28cb3bca04eaae92f0ca953d6
      psutil==7.2.2 \
          --hash=sha256:076a2d2f923fd4821644f5ba89f059523da90dc9014e85f8e45a5774ca5bc6f9 \
          --hash=sha256:11fe5a4f613759764e79c65cf11ebdf26e33d6dd34336f8a337aa2996d71c841 \
          --hash=sha256:1a571f2330c966c62aeda00dd24620425d4b0cc86881c89861fbc04549e5dc63 \
          --hash=sha256:1a7b04c10f32cc88ab39cbf606e117fd74721c831c98a27dc04578deb0c16979 \
          --hash=sha256:1fa4ecf83bcdf6e6c8f4449aff98eefb5d0604bf88cb883d7da3d8d2d909546a \
          --hash=sha256:2edccc433cbfa046b980b0df0171cd25bcaeb3a68fe9022db0979e7aa74a826b \
          --hash=sha256:7b6d09433a10592ce39b13d7be5a54fbac1d1228ed29abc880fb23df7cb694c9 \
          --hash=sha256:8c233660f575a5a89e6d4cb65d9f938126312bca76d8fe087b947b3a1aaac9ee \
          --hash=sha256:917e891983ca3c1887b4ef36447b1e0873e70c933afc831c6b6da078ba474312 \
          --hash=sha256:ab486563df44c17f5173621c7b198955bd6b613fb87c71c161f827d3fb149a9b \
          --hash=sha256:ae0aefdd8796a7737eccea863f80f81e468a1e4cf14d926bd9b6f5f2d5f90ca9 \
          --hash=sha256:b0726cecd84f9474419d67252add4ac0cd9811b04d61123054b9fb6f57df6e9e \
          --hash=sha256:b58fabe35e80b264a4e3bb23e6b96f9e45a3df7fb7eed419ac0e5947c61e47cc \
          --hash=sha256:c7663d4e37f13e884d13994247449e9f8f574bc4655d509c3b95e9ec9e2b9dc1 \
          --hash=sha256:e452c464a02e7dc7822a05d25db4cde564444a67e58539a00f929c51eddda0cf \
          --hash=sha256:e78c8603dcd9a04c7364f1a3e670cea95d51ee865e4efb3556a3a63adef958ea \
          --hash=sha256:eb7e81434c8d223ec4a219b5fc1c47d0417b12be7ea866e24fb5ad6e84b3d988 \
          --hash=sha256:ed0cace939114f62738d808fdcecd4c869222507e266e574799e9c0faa17d486 \
          --hash=sha256:eed63d3b4d62449571547b60578c5b2c4bcccc5387148db46e0c2313dad0ee00 \
          --hash=sha256:fd04ef36b4a6d599bbdb225dd1d3f51e00105f6d48a28f006da7f9822f2606d8
      pyOpenSSL==26.4.0 \
          --hash=sha256:f0eb0cb2d581d3ad2b9c489468485e7f2ab6727d08401bcf9d824c3caddf3c1c
      pyasn1==0.6.4 \
          --hash=sha256:deda9277cfd454080ec40b207fb6df82206a3a2688735233cdcd8d3d565f088b
      pyasn1_modules==0.4.2 \
          --hash=sha256:29253a9207ce32b64c3ac6600edc75368f98473906e8fd1043bd6b5b1de2c14a
      pycparser==3.11 \
          --hash=sha256:51d5a8ba2be0bbe440b99d2112604c95bbbc3c2748a64260186c541e1729cd80
      pydantic==2.14.1 \
          --hash=sha256:9195d967ec791692a04438115466764fb8b9a27b31f14a760437694f40d6b454
      pydantic_core==2.50.1 \
          --hash=sha256:0036473f5583e6a60e50b8b21651511564277a3f05cc5dab8cf579f552cd5f6c \
          --hash=sha256:0048b6dddc8ef4b64fccaad878bd143b0c3882ea9936279dc11d613f6b7dd1bc \
          --hash=sha256:009634b83993777ddcd69cad0ffcace43dabde692109528e35f0fde91e386a8b \
          --hash=sha256:028e2f212273d4a39b1ec1e0de8166b1165a65fc0f1111452a9d94fc7c625c63 \
          --hash=sha256:062e891facce5ca296a1c37098e5e466780457f86413894b399f0cf22934f769 \
          --hash=sha256:06e01fbbfdb9be777b316a71b6c49efaf4a08b615d0a98d678cda3023f79d019 \
          --hash=sha256:06ead20d39ffd6f2f6f2a8f8a6de67ff8bb1b4f14a8a30e058502514ee2ac685 \
          --hash=sha256:0b3a6f334c6a2345ca15318ff894502a90012536404b37c844a976c76c846e0b \
          --hash=sha256:0c003c3b7f49debb893d2d85ae099ac5959c9839e2f330fadb1fcdf7a6594482 \
          --hash=sha256:131059670f1d2444269b8585cb888963994871932447c08b39ac6a51fcfef658 \
          --hash=sha256:132529c83901437ff642f585216831bf5fd7a91df66829907e155192ead62498 \
          --hash=sha256:17e722e156d0444ecaefbe640bdb60928752bf2013e2b7a11cdb099aaae19bec \
          --hash=sha256:1a9006395dece0e32e704c315eff8a00bede494f6108546cfc5539c89fef4f9a \
          --hash=sha256:1c8632d4ac04e6f91128fca584b3a8a507d81604c24eeaaad00d4be42765c32b \
          --hash=sha256:1c96fd793b73d1b92e65570132505498fe7b21eaef73cdf74e67e5dfba7ac9e4 \
          --hash=sha256:1cf41f1ae3fa155cf167a72689ad044bcc1e3c97e064123677149bdfb5dafc4a \
          --hash=sha256:1deeacb112d14d3f4fcb16b165f7dbaf76c70ba6e82f37ba042bdab51970a0b8 \
          --hash=sha256:1ef800dd7d85bcdadf4c3076e4c94e43939493558a3b69a1ea830c706d4617bb \
          --hash=sha256:1fa4c8bc12c1354c5550c0c35c1852c8c1901e89e06561724e03f8d0342e1f87 \
          --hash=sha256:2005207aafe1231315718bf6ed5d064a7300fb4772754af35ee72fc68159492e \
          --hash=sha256:23923ab9292c40da026330b1ecf4dc2618c8e86e0422e5d1fbf50d94d64ca4f8 \
          --hash=sha256:23edad659e8dbd8ca7e4e877fe6c81573abbdf215bd25a68b53e1272f58b80c7 \
          --hash=sha256:2ab756b72bd5054e4c7ef3ded331b35786cbd3cf931531a508f79a9537517064 \
          --hash=sha256:2cbd1b75b09e976ed0d6b6ca297675632ca35df86130088457cdc60ef36970ae \
          --hash=sha256:2cf91809d0721ab81592ba67bea7694821679c10b1a2e3c3460082b286c1918a \
          --hash=sha256:2df1ff41884de2bc4b307bafd7c40a691094fad2ff8e767e5b45a319257bcf4e \
          --hash=sha256:2eb75304506894a281d346220a4f7481a1b8729577c5ed2a05395991966a8396 \
          --hash=sha256:2eedf82ee4753cdab8e50044c6bd569577eebc3859b11fecf4eb9223761ff966 \
          --hash=sha256:30ddf019d082c117b5d309e5b86710c2a78909907ec1a9381feec3eec02eca0b \
          --hash=sha256:325c23f3e35cfbf0fe3486fa5f7260d1e45885173002d30a28ca019994124255 \
          --hash=sha256:32fad3a91e51b6d2039c572db04a5a873260b399f6bd62c3552671fa7a4a2899 \
          --hash=sha256:36c426eac0af8d1529ff8467e612b933346caec1fdc0d774f78f67a1a11e16c1 \
          --hash=sha256:3a5fce22f1e87d181e924e12da7d81cfe031fb3881a5ddf26ad28f141756ca43 \
          --hash=sha256:3aa9de446b793de2beb6fa2d9d0961803126c4e2a99c2f25ab59b9fd6ea125c0 \
          --hash=sha256:3e46a9eb0a0901dd6275e6b06ac3a464885ef350ec4121fe486869de8053e4bb \
          --hash=sha256:3fde4fdc6487a58d944ca87cf5adc95d5f266e872c19599f5f4c0a8a1b1f9f9f \
          --hash=sha256:409e0ea40ec30d9158f33574fd758e689f6045a0f2596701828c27816ca9687d \
          --hash=sha256:40f523349960fa30f3ea51404308ff50f9997a90df639590f47a057c1f32b415 \
          --hash=sha256:41bc8237121bd8dc8d888dfd6279fc166ffc88c1f1bf3a8bf00869680533ca4c \
          --hash=sha256:42b54c2c90ad348b5e3a85e03e715d572c1fde357ef104cdfe3b03b697a404ea \
          --hash=sha256:455a773617b5913bf5c20d0692e5787b119e52c4d40ea644ca31f5758fd31be2 \
          --hash=sha256:45b11cac094aa25725581d9304eee93c9028516b9ea80dd9e175e13a5a2c840e \
          --hash=sha256:45c6266d071c241f2a168d45bf8c54344f0effce35e7e6b73afdec11f3687568 \
          --hash=sha256:46b3301d3b5c886f77de7546e47274a5842c622ea2020b8c6524c6b66913b4a6 \
          --hash=sha256:476f6ed8e43cd1e0b460920e23571700872b284e77331cb30c4faf459cf48a4b \
          --hash=sha256:48569b0ade9edfbe065cad1d700175546592aebbb42f02adcebcc26e75b896fe \
          --hash=sha256:49c2cbb2397fe4d0987e84606e691af6cb87bc0ee1bd3e7b737f7e10b4c142f9 \
          --hash=sha256:4a53d13cdfbedbfa87f08b83c1a0a5efcc767d785a4b41934fa9cb672670493a \
          --hash=sha256:4be846f55c9477f5f3ddde8f2ce941137e16862a56d018ed885d422bb6ae02f2 \
          --hash=sha256:4df197990c15b5a37c5a277d131d9f2c67de6133f2e5dafd80d9bba4b99f46f9 \
          --hash=sha256:4e834f6a8e4ff772dcc34f58ef5504147a3ea5b0f4eeb13b0f8eb2ca75ac57f1 \
          --hash=sha256:57f51b31ff826e2859120cf4737c5a758a48d96f3e97da40ccee1796d58078ff \
          --hash=sha256:5958c72adb417c39b12ac87525ac60b0d73315fcdc59e21f44ee4a5e2512c9ef \
          --hash=sha256:5dfe41f232befddb9c4377f6cfc702b51595e2d78ed082672adf8758d2c4619f \
          --hash=sha256:5f3cae32fc46121f787cb2486de9cf95a8bf72aec5cc78f64c606fa1735a6ef5 \
          --hash=sha256:64f6047f62a6c5ae08d0a6afb035667aa2d97c3d20d69762e034c5ea144d92a5 \
          --hash=sha256:6a733778df2f7087ec1100ed0b41533e4f3001976e99570fa34f57c66e7f8e3e \
          --hash=sha256:6b20a4bffabdad0db2927ac034ae3b8a681b1f7a0182f3e60b479ad2fde21ebb \
          --hash=sha256:6dbcbee53bf17196a7f745aa9bf5a9603953a1e365b1f020be3207c676a3e7c4 \
          --hash=sha256:6ed4f3cef55164b026fefb41341b7754cc6b624c75dfe7142d2ecceb5ad21c87 \
          --hash=sha256:704075d10b74f2f3c6e15407c696d88701df35fc8953f434a431add0d0074db0 \
          --hash=sha256:739dc730e6be3bd5ec2f4ab5cfc7eb047cc45fc1497b3bafec74ff2ed07df597 \
          --hash=sha256:7456d699b13954e9c0164dcb267250a10ae0dfb03e6e26d6796ab0d46e189c84 \
          --hash=sha256:756d669f04e62ec4148ecfe22be6a4484d9b1181a6ef32e205ebfd200540858b \
          --hash=sha256:7689580e72a642ab5ec64d5f55b2e33636fa43b4ebe63c0c2c965ef307c7d1aa \
          --hash=sha256:76e2e83fa6ec8cdc972d438dafc2522b3a47bee4ec0ae668b29cfb1977ab5242 \
          --hash=sha256:7816e98acc08119dc0f340ab167048ecc54126316330c1f0caf7c6756c88e28f \
          --hash=sha256:79490e33c4c0fcb933bbbcfc3a62184d8803b99f535863dfbb925e1bcb6945ad \
          --hash=sha256:7f476456ac2bb0d937f75191494a09c83a30765fea4f70f3b404942fe25f6cdf \
          --hash=sha256:844b869f118e22a41a091bdcedda8a71bc1b0f62c38d1a0c3211cece47e1d8fc \
          --hash=sha256:84bc765b282a9d5b7fe0348b8648904f25a6a04b2139da52b1dd30c8ac3a2c8f \
          --hash=sha256:84f34323a61a365b4e9295de6028474754829aaddd59c7bf1a040e7487ef8f3c \
          --hash=sha256:8812592c85d0edf423f10eadcef42716d71e8219085ad9e85b775057b7306133 \
          --hash=sha256:88e492e8b9d0312e7dc13667c30222abf284dc3b79b5302b3607b41a5784ce61 \
          --hash=sha256:8a6791afa2245e6c6b180122d105941644f5bd410bb18623b408808cc41a3102 \
          --hash=sha256:8b4c3df25bd323bf1d36a648d563cf1fc69d717451569927151bdad7cad07a77 \
          --hash=sha256:8daa7ee75245d43ad7d747e5c9ecc1b1d06552f72b14887e9276f787d57375f4 \
          --hash=sha256:93ba4e9d8210d941c200431a56b2c0400b131865947903937ed3ec5404307d2e \
          --hash=sha256:94845ff54dc5193f228cab81b2662a04bfbb892e95bdc15edf7399000ce57d54 \
          --hash=sha256:94be440c03fede26969a5ce75468e0e6a9927a1b46d9b679ee8adc1b057b0350 \
          --hash=sha256:9572c1369e9c9da2d64a7b7992c786d90ff295abc93964cfe3125e4290768070 \
          --hash=sha256:983a662de2571cb2502fc8ff47b6770b03d025d2eb314c92f77b3f07c74720ed \
          --hash=sha256:992c3514ec891fa7858099183e4d64e6bd5a5d4ff452fae29df22faa77a006bb \
          --hash=sha256:99ba9bc2b8062ea0c326a990f7f00e6530c23579de66dd246e72c4cafef950a5 \
          --hash=sha256:9d1bed94af6a63835461f3cf7502058eb166c58c4778e11d0f433cfb1bd69e19 \
          --hash=sha256:9e4472072de0137ee0d8e72d6620e85939c271d2f90f6bbb4b15c24638b79f92 \
          --hash=sha256:a27c09d86600f1bf2fe3f37e1ae697faf3143931c09322cd799da94deee923b5 \
          --hash=sha256:a29a061fec0b4e2d714f277e70a3a18125ecff803f2fea6eade2f2e53711d112 \
          --hash=sha256:a3cda0e538208e5d722bbf3698b24f19c0a7d05bc8d5f8a7f9b121ea7fa243d9 \
          --hash=sha256:a44101320cfe99432db74237545a63057dc7a88dfe792cbcad0647f2af56cb81 \
          --hash=sha256:a4aaaa791bdae1c972a7e81765f4f3571c926b8e0b9b6e47346499fb80079665 \
          --hash=sha256:a51eee75939cf811ac09b278745a6cee7dc873ccfbc8b9af3cc88fe4b7ce25b5 \
          --hash=sha256:a7c58106de36ac6a56314182958de20db8d3a29dfd5db527192cc754e4f8e7fb \
          --hash=sha256:aa8224f10880d9bf1b5993988ba153d42a8b4f3f4f511f93b1f09c93ff613c72 \
          --hash=sha256:acbf31f37c53a5ac0c34706c80b4f5107ba20b05fdd3816124bf236ef0c57dd2 \
          --hash=sha256:adc06d218a1cadfd2ec4628424d7d79ce4eba69c2965e7e7b55106f0da5208c8 \
          --hash=sha256:ae28183297fb0d2b8dc46a1f01d51f5e45825fc5afe76a835a6cb7fb34821295 \
          --hash=sha256:b0135bcdcaa0f23573f286e4cb5e0fd2962700964ed13df085b85f2b97aeab9e \
          --hash=sha256:b087b1c5be7ac687cf22eabfe4b6b608d40df23610651e93611e1f49118baf84 \
          --hash=sha256:b0d955195bbbe489ad343fcc956eacea9357b79cb22192c66cacdefcbc14b32f \
          --hash=sha256:b281a3b0f0822618fe5e3e0d8a2048b6356b14388505dc9374ccffeb69989713 \
          --hash=sha256:b6d0c2183008c188e19f4906d426b293bdc4f67ab17df8e180fe16cda208fa71 \
          --hash=sha256:bbce99252ba3167b2b6277f1829d5bf4b43b754524bddf7f944707c3db7d2253 \
          --hash=sha256:bc1f08f68dac9f9e83845a8039880aba2ab553eb9b2259c3243a313182c253fe \
          --hash=sha256:bc94f474417604bd383d2cd445d071b07dd55fedceed3ce33407bf1fcc107290 \
          --hash=sha256:bed5163e03b98bc1fa2eb05d74c63d9c5c95d8ed6254985481640fbf5e237dea \
          --hash=sha256:c17799a62c142d61b8a3c51752a7cbc87fe2ad4ccfab10e628a77b405075c662 \
          --hash=sha256:c18db21573bd2c6489f9a544b7499f0df2853958c568e5e783536ee1f690af41 \
          --hash=sha256:c3ede305158e75510be50869b319550ab072008c13d64d4ab1e094fb286b6f44 \
          --hash=sha256:c516cc5367ca3448995d42cb994bf3f4c9002d2a7c22eac9622551269ad1b807 \
          --hash=sha256:c531166c42ea7bdfecc8c50049581f05dd1993b09cc7c52bb36a14e96deaec7d \
          --hash=sha256:c73622ef819328873b53109ee4f77ceb598bffedd02daf916102be3228866b78 \
          --hash=sha256:c8dce1f1e0e5358b682a6ad3fa5e31b31d4560997b8e61417e9217c8d60f8a0c \
          --hash=sha256:cb57f304525a5e3c13333b772bf9a473f36326e9c821b2e8e1b2fd36f80ae2c3 \
          --hash=sha256:ce8c25ca38cc0e3d7753ba180808de2c0c8cb24eae0df64491e40921454e9831 \
          --hash=sha256:ceff0acc940be2715bd6ad17b24c0e5304abf44f6efd0f81ee8499e640f9dc86 \
          --hash=sha256:cf356f70551d40374eaffb1aa63f1eb6d2006681cbd7a9faea173ce0f4dd7cd2 \
          --hash=sha256:d2d82aa62521c55ddfb000ae70f88cdd8de974078f6024e821dfe5addd0c818f \
          --hash=sha256:d32f3acc081cc3923386d88f422cde8892335e95f034e0104bb4cf9310d9915f \
          --hash=sha256:d4193206b6587047437f6f11d7e776df23e1c1e23af2a54d9347275614791e10 \
          --hash=sha256:d5c0e32fdbce7f1e8ef4d11f655694bf5f4175c757a9f1dc2be09b8864e5bcf5 \
          --hash=sha256:d5e062c01286d861fd6a1c4ff6e063547b3e713067f2df033c0ff97ac2ca006b \
          --hash=sha256:d8f9e8a6c4ab04b78d61f78627370d834eb004b2869dcb28cfffa647b4ea1980 \
          --hash=sha256:d939de9c82e2126f7f48a7e658f8a85ed46d57662d53f44c49b8895fe94a3eb7 \
          --hash=sha256:de531ce1e2a3364e8767878b58f4ff728a434b4fde089781fe30b1e08e2396e0 \
          --hash=sha256:e5faeaee74a57d32b3ab3aebad2e348f06d3ba946fc5d28c1728455f00a3d13a \
          --hash=sha256:e6f0cc1bb9900dc558960894adeb30b0c083366fc1d69b856209fb2ca5c36fe5 \
          --hash=sha256:e8e1d6ce820aa23317e8209a86bd65a540973c12dc7552b48a4f6c8e9926815e \
          --hash=sha256:ed1e728b39a383c81035b2459cfcb35d99dfb01f7d6ebe3a913bc1cc5b81e459 \
          --hash=sha256:ee6db2fbed51a7991302e8fac498cd67e336246026d0dfa84cf5166ce1412760 \
          --hash=sha256:efbecf43d321f7b9281441f1f213f7c21c66988b0e06c2730ba13ed47a46bb08 \
          --hash=sha256:f2c634642694e6a0dad2ab1d375589fa671fd442edd5caf7d9737b8f6ca22906 \
          --hash=sha256:f3377c8c2b3ce898423c5e5dd94c7982e30aa7717a7e6ab2470b9de364963709 \
          --hash=sha256:f5187624823423e1d1b82b1072ac41dc837389e18d3d0572cc19bbee46cd550a \
          --hash=sha256:f77ac30b19221cd9bd3fcfa3d4614eff93140d0572ab730cded17b64adca05f3 \
          --hash=sha256:fe90228920fd8ff2be62622b6bb8a2b11acd65046d50c6b130614b5879605a20
      python-dotenv==1.2.4 \
          --hash=sha256:42269a8a5b3fd54ffa6f3d84b18abed50064717576b4ecf03dc4a55d8aa04fdc
      python-multipart==0.0.32 \
          --hash=sha256:ff6d3f776f16878c894e52e107296ffc890e913c611b1a4ec6c44e2821fe2e23
      redis==8.1.0 \
          --hash=sha256:a4fe1aac3d3b3cc791d4b3d5931c5a956045dc951ee74d1c913ee3ac4d2ee9fb
      referencing==0.37.0 \
          --hash=sha256:381329a9f99628c9069361716891d34ad94af76e461dcb0335825aecc7692231
      rpds-py==2026.9.1 \
          --hash=sha256:00ba2d8c7dd4ee537978ddf4b3fbd712bef2d8751603f7f3146b3f4287768e25 \
          --hash=sha256:01445c8d194aa032a08e944f16567672da1c62dbdbefd8b6d0693032e290cf68 \
          --hash=sha256:028ad274ea951dac64491b5d1e65712a4aeabfdbdb9fccf797b57bd899b0c495 \
          --hash=sha256:0483515261947e4e8b8e1375bf7463e7eb6ccfb3d86e7b554d90cd5285f20f32 \
          --hash=sha256:068c37bba854ec2fe42f7365c640af11dd9895890ccbf2df5070d0c059bd7f96 \
          --hash=sha256:074a4d198bc34d9a8ea425114fc3ded6d11ec01f6a314a8db67454a5152d8834 \
          --hash=sha256:07deecbfce94c78473018bc7d10b337cc651d12df87a1eb2cb3e4024bc9c33d0 \
          --hash=sha256:08dae4a4095150a7c4545a1fb40b98e1ab1744fbc2770d92c977b9dadaa49ab6 \
          --hash=sha256:0da298fb372dc192610a4b9ecbc68a0cd8b675bbbd1fc519d01b41cfd658333e \
          --hash=sha256:0f045bb053c9057720d72c56dffe30dffdc05997b2897a827b9325f0ab6623fa \
          --hash=sha256:10e208f2425d973938afcd56e28a7c4be32e27b6a60b5d381f49fb9d8acf9759 \
          --hash=sha256:136a1c3fe4402b7008bc81cb62ee538481795b61a7e83df88dff3b3f02b726ff \
          --hash=sha256:159a7aab5c5e8b112c8830f54717ce56da1252ebdbb526f5be2df2309280b9e7 \
          --hash=sha256:172e47169583f46ce118cbec68e6795d0da0f4606b488b6434f8276bca0a058c \
          --hash=sha256:1c2d1f6da5128eabf34e963d7163a818846075a52568250d006c4c953b40f903 \
          --hash=sha256:1d55198263bb51f557550c6ed2e6d1cb6a6fed6eb5c9120b741c5926bef8a45d \
          --hash=sha256:1d77b649e6f7cdf12ca5c2a98dad0ad37f9ea9b6f960408a92f0cb12bb3d04d9 \
          --hash=sha256:1e8d4d79d828299bf44a55db22a9388ab967b49d17132c88eab0f4360b48da8e \
          --hash=sha256:22ffd29a63d71fb1b81552c21f2c2b734949b7ac751a9be70675a939a900839b \
          --hash=sha256:2693b2728bbcc48d09a981a356954b0c47c53ff25b545856f28a889ea619f69a \
          --hash=sha256:270bdcdaac5d5b6f73c5e22e7e135c7f2a50e789f71d9e241d5be8d90026e19a \
          --hash=sha256:2711d29b653b3bce48a63d18b9c6b53274669e6d6c4094dddeb4d9a0e45128b2 \
          --hash=sha256:2c16ab111bc27c646ba8aa005d0527754edc538ebb636f0b1bf8e244b48d1945 \
          --hash=sha256:306ee1850d8105b5baf977e78d45fcadd12c1a54678d614c9baf217708446e91 \
          --hash=sha256:3231c4c0e521dafa5be0c9f114ee2c2ad46650836f2d72caa86801950c3e7044 \
          --hash=sha256:3890a6aa36e6baa53d5258a2a25d3ef8b37ad165a6ab27a892d7c3e3a432cd69 \
          --hash=sha256:3a72c11530d71abfb66c8d7696a2f86c43e63fca8b948f1a784ac490f4ec688e \
          --hash=sha256:3b5a6f40f0a1486b4b36c888123afc67acdbd9f33235927acf5ff295429a0ba3 \
          --hash=sha256:3c91c210ae7645626c608400e3519b4a642f837cce09ca830db3beb2e9f274d4 \
          --hash=sha256:3cd182d7291d29b92c521a0069d9c01ba6193628a9a105531d11b40a6d731a33 \
          --hash=sha256:3e524c7874ac72884d28e16dd5b8d839fd09e0fe76b020d3fbca23212a7b8c52 \
          --hash=sha256:3e93b2cd69a9830be33e03945cd7cda940a0a8bfcfbff41d6144f0cb0d3d8bd9 \
          --hash=sha256:3edae8c5ddfdb6985d49ae9d150516e5076888879022f91a26c2de9276ce0bdb \
          --hash=sha256:3f0e9ac28fc067d4d34b88ae43c48e9489455c97fee9633d851f7eeed5a05d35 \
          --hash=sha256:42e75466f83cd43f6026c81eab74246efb2bdadafb307b85700632d06c68f299 \
          --hash=sha256:44b32a7c4f0da3d28af31c259e38ddcff096f855e205ed0671d02fcf44f1ea1c \
          --hash=sha256:457866b85daf5034296666168b84a69e0b2e89dc4f1af102b46f6448a60b9063 \
          --hash=sha256:45bc6bccf78b20fd834237d18db64965d7ee68ba7f60440a26c7ab71e7b8d51a \
          --hash=sha256:46d80bc76b51a6c24f9944368c28d38b8bcbcea1da4f2f8d3ebc31a67e8c6ec6 \
          --hash=sha256:492e5e428cbe126221611f47e068f01660352feec4ad18bc0f5ea9b2ae88fb14 \
          --hash=sha256:4b26b03d9d2658ee2fa234f8f4f19f38a09773fe5261028025032e26d4d35af0 \
          --hash=sha256:4c0d2cb595a420b34d5086db0add011e26e2c09d6a024afbac4228bf8f863a30 \
          --hash=sha256:4cfaf02209061880210819934de2f4f6aa83dc04dafe6770276acc240a56da31 \
          --hash=sha256:501909f2e4a1e2dee528ef766fe3c469060ebc17e54a8383d404ba07a81a6f02 \
          --hash=sha256:50906f5aea24b5a865cbd0a589698288631d9f3a54c3a937c83aefa95a0d14af \
          --hash=sha256:54ac2158a6f96cfbabff0b2eedaf94b90c5ec7ca8317fcadc61e1c2b2e0ff6ef \
          --hash=sha256:56c6952a9b15047466d0c2347c446a761d4527f89976156341e68f0ce5cc08b0 \
          --hash=sha256:56cd8b3f77d7b6812f533b662186a1f28316931166ddc00fb893b1b0db7e9888 \
          --hash=sha256:57492a550a1d88d29d003247e5f78dd8cf04a701fac0e4c8db8745a6d2504e0a \
          --hash=sha256:5943980471829f6de242a20b109de3111ba6b77e3af0ffc587028ac854b05e6c \
          --hash=sha256:5c6ee90dee3e85e055ddfd502d611643d9b0fd94c818220bda84ec3dacd9b27b \
          --hash=sha256:5c90e7fa02e8f5de0d10c17595c568ada48c5302e749462c0ea1a4c362111a86 \
          --hash=sha256:5ce8943f79c2210f7abcc28e86367b03b28d95027fd01c46d2472373ae70c86f \
          --hash=sha256:617f59cde379b4f648a09797b7f683d04b90a46344cddab85639da5aff0f5531 \
          --hash=sha256:6307a0da524939decb8ca4a3933b8ab62525794411d6984fca6726e732804af6 \
          --hash=sha256:684fd492fff4fead00587544e059be2bbcb6f93454f21fa2a91b66fc7508be82 \
          --hash=sha256:6b5b393eda5ea42cca1c1a6665f2a4882b4fd5d1777e41ce0545a107fb008c9d \
          --hash=sha256:6b723eb406dec5bc9ec516c73ab9c3239a3284e017f7eb89ee2b3258bd504fb7 \
          --hash=sha256:6b9bf3135b4ad5981df9a73d71a35272d650a2985ae9c2746357b24d59de2448 \
          --hash=sha256:6beb738155fe8ab8091afdfa5a3226b21c2b1593f1e50ebb90eb25b44dbc0391 \
          --hash=sha256:6c0dbbcc19735fe5f8b0a54c07659d154a9e69f47e15d0a6ab7299215daf62cb \
          --hash=sha256:6cdc537c8633d7fd92a82e2e0d2ab74320a3f63d5e59fb9cf08711e08fe151c4 \
          --hash=sha256:6eae33003518fd4cb4f83a218d5371469dd3001aa3b87128c005b07762f7fe5e \
          --hash=sha256:740d0a99cf9de0b17a3943388e9294a59becf75e7c43421f387bd3c7a9901f7c \
          --hash=sha256:75c38c50ab9aca840225d9a9a3810bf11d04bd5c1f186cabbb8aee56db3e9b15 \
          --hash=sha256:761fdae6728ceb99ab182fad2f0cc1e262f610834dc891aea1d1a2a2e634776f \
          --hash=sha256:7664419f27db41d4f1c43a78dccda7dd6e8ef2428df3ee01d0c2a07a6b071297 \
          --hash=sha256:76d3af9732d2dab69f28179b40ba2d87e2f1d5824b4a694780aa787d685e8f36 \
          --hash=sha256:78326f4cb4427a56ba4996c0762b63be45f06b85f086526420d2b3a66e40f84d \
          --hash=sha256:7868b85224291c6cb6759f9b5adb9745f486d226f62b16a614dd5a2a5ab2b35b \
          --hash=sha256:815d26356930846a40c7bc1366e7b1b0320ab8a063e66c11298a208bed0fd237 \
          --hash=sha256:8171b44a054e5c67fd748ada04187f1250bf35b95f85e52ab64bcf3331a923bb \
          --hash=sha256:821b2755db9194409254012f429c56643416fb96ef9be090be82ec8826b7f477 \
          --hash=sha256:837c6b305e26fe0f75b15c92cf3b2ba29e0ae19dc40b1c557b026cb426347d0c \
          --hash=sha256:839dde845559254f34885267c6878f60d61d5205180226d976fe488d45fa128e \
          --hash=sha256:84a6ecc0c940169190d2c23bd969debd48c94dbc855acd60188a68d71d421608 \
          --hash=sha256:8601470267d938bcb7f3ab1a336100af51a4fd5b6ed030ef52461bb3ef5e7e07 \
          --hash=sha256:88b5268892fde430d5531f95bc560b6efbbd67c929662c586afd729a96e7461c \
          --hash=sha256:8aa5dda18d39b6143eb24809d158f9252c88f402749b6f1b62a506cc7d96cc35 \
          --hash=sha256:926bdd3e3b5998ddf70cc64bc8cf57209571f9044542913afb673799fec77dd0 \
          --hash=sha256:96beca19ec79de272e8668585380ff9092c47077c1d7a1e098e00bbd921f4785 \
          --hash=sha256:9a0460d43603d1fd9ef59c30278531e15d78581721ddb538fa560aa7817ea4ad \
          --hash=sha256:a03d57b86d2a51d0a66c92177e2be154ad015f357791d306e714569999cdb4cc \
          --hash=sha256:a36b70596407634ca82d4b989a3729074a008537a0522e4c8046a67c729103e9 \
          --hash=sha256:a3a52a3ba86436ab3aef510fbe21512abc2ddd1993005dfe50514bd2284ef025 \
          --hash=sha256:a3dbc5ed9514908d5046107d7b1346bde71eea61de6e0e4919c19354f97e769f \
          --hash=sha256:a431156bb41865fc14cd5d79bb9d7bbed83110b0159e34e62ae30951f96c0009 \
          --hash=sha256:a575404ebc9cf2e91edd32eaf570ec1430eb900d4f56724ba7dd4bc1fc9c176d \
          --hash=sha256:a5cf77eb04f20b720be95265a3e00eb2a14814074255cc27069c551b2db53118 \
          --hash=sha256:a8763f20692da7df39b0afdd1ba3042b004c50a45994f76c2d9a25641f7673db \
          --hash=sha256:ab4b2fda7c2b542f7f9d886cc6a838c5079d2b76f72e6081411faba11adde2c9 \
          --hash=sha256:addeda51556dac7c1a2f14cda62db8b621cd12afba3091d03a96c72932387eab \
          --hash=sha256:b242c27c8f836305a4a72df9cdd564386ac57b807bd252a063223331c9316b37 \
          --hash=sha256:b4f062343e7ad3fa94f2c66e5ae667dee47ee74dd41a9057c4fbe163236a123d \
          --hash=sha256:b5b8b0753718d258fd454283fbd57e14545d3b40583fa672e27cb4f987626bcc \
          --hash=sha256:be3e47e2d91aa3942ff9bf4077a505226005abfc39b6f7554a91c1b9393986b9 \
          --hash=sha256:befc2d6a953e563f8a7bfd87a42c22ebf8a3e980dcb7b6a4d17b70b0e914e8a3 \
          --hash=sha256:bf35d0568abda97233239ce32896d3ad53fccc537832c104e30c94aa5fb93569 \
          --hash=sha256:c933c6678c6f116ff8af47a4c6db0868b8ace74af0343016c0ef00f00272ea69 \
          --hash=sha256:c9d1aca01f49170fdcf5c92761b1fafe97f554b721ca4570c5949fff778f0d4b \
          --hash=sha256:cdeaa99ce822dca76cfb1b993e9120c5ea212f2eb66d48950ad63c349668a018 \
          --hash=sha256:ce4d4f52e2a4324396caddbd45a97d8d7be5f42edd25d2355282a9c34f9b2f7f \
          --hash=sha256:d1028417bb44037eb3069c1009bd7b7277212876cda22fbe565b0bca9fab6d2c \
          --hash=sha256:d151e148117294133bf8af7eeace085e7e87432db15ab6adf640330298a47f6f \
          --hash=sha256:d7841166b7fa64c9c56404617ae4341448847482d45933b13135d26c130519e5 \
          --hash=sha256:d7fca4eb6df565e2a928f1c7dad92d27db8f9df0f449e76423ed5d7e713ed445 \
          --hash=sha256:d95a354e02393eada6d7351184671aced9d4cce109dabf927cb7aa99624352a1 \
          --hash=sha256:d9edf30457d74eebfd76b045535e36f1cd89062566a128a0db2145ca042d787e \
          --hash=sha256:dbc2673f9223d420c91145599b3ba45a8a50c207d1976908e5fb5ddb0c9b9429 \
          --hash=sha256:e01b3c878c8641913e688edd1b3f08658c6783d29cf6b826bd3c0d1ae7a1ffaa \
          --hash=sha256:e21c1429e205828ea886a2293a4a2c8e01f4c25d9893ca330e97a6cf73f52e7b \
          --hash=sha256:e43d4a1f673e8a1cbd8533e809e02b4bf9d4f2280269bb640436556312121250 \
          --hash=sha256:e6d198bad4e49dd6732fbd636e2fc5c082f45c8cad0b4acb756b00c82c76072e \
          --hash=sha256:e6ea1cda8d8c688278430e4268a42f5e5da3bdd74578dfadc0820c3f1766ce83 \
          --hash=sha256:ea394a937f17a54c51239348bdbe2e3518124c8d4a8951ba04a311d3095bd18f \
          --hash=sha256:eac2f5dbafd585dfe31f86a23ebf0d3ba480a9d49ebc87947267b5608d4ea0cd \
          --hash=sha256:eb61be926bb81567c1f48bdc8aa22b9855048dc2efd53871f9f7e6e9a5632346 \
          --hash=sha256:eba5d173f7d5708b22a93815017a4611873ed54db9f268077c0dd1ed99cfc858 \
          --hash=sha256:ec450527cbf485e13c8d3602a54f428ab0432fdade0ede75efd74b735421c871 \
          --hash=sha256:eef6a03b0b6d08d0835ccfa8ec8d1bc70525e3801387567137b50c557695e6da \
          --hash=sha256:ef0d8c843e2827d6c120ab4687e9423fb1d893db1df27b7c1506615bcb9734a0 \
          --hash=sha256:ef6b65b03247c54692ad4fd9ee97cb772781927db72e3cb05e70b3db6d1ff14f \
          --hash=sha256:f3d6ed6a98cfd19155996605474982cc470d7601746a6439078f1a5a3fa8b050 \
          --hash=sha256:fce4b85234a0cbad67bf8e6e1201ee815d172c9aebad75f25645bc4d834f8e31 \
          --hash=sha256:fda1d96e542c37b6c804547dbf489c129fe7c97183a76a5ec275909ba1a063df \
          --hash=sha256:fdcd198979b4ecffcc1beba366a7fbcf4eb41243691a82fe52ceb0b902f09c12 \
          --hash=sha256:fe5ad0664ec772b02c45859041aa17655709cced7a31005817fbbbd988c25567
      sniffio==1.3.1 \
          --hash=sha256:2f6da418d1f1e0fddd844478f41680e794e6051915791a034ff65e5f100525a2
      sse-starlette==3.5.0 \
          --hash=sha256:3e6e1070df3f0f5d9cea81496de92dbb72f6721871d99748ece67441dd8b7997
      starlette==1.9.0 \
          --hash=sha256:fd3f159936e882d06c1108f84688f7cda2cf85fc6a592a50edbd175e882c2ddc
      truststore==0.10.5 \
          --hash=sha256:9aaaedaefaf06d8b206278cf8b5012bc897f485a874503501e12d776df78951c
      typing-inspection==0.4.4 \
          --hash=sha256:65b8397ba37ccbce054456aaccddfc91e6e3083c92824df348d96ca832f3f147
      typing_extensions==4.16.0 \
          --hash=sha256:481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8
      uvicorn==0.54.0 \
          --hash=sha256:505bdb0f318731d45f1f712071fc781a8981f6847a31c902c9f5e652d4f67faf
      webauthn==3.0.1 \
          --hash=sha256:9927b2f530773bd1d7f8194cd643a2e634a20995ea31f2d8f7a3e70b11c93e31
      websockets==17.3 \
          --hash=sha256:018fab26140ce221c3853454a608e4e7004f4f10641cb97819dcd5b917bb2e99 \
          --hash=sha256:07246d4f0293ef0b87eff3d7dd88c1f03dd9f678fa39f6de87b2af8504e7e0de \
          --hash=sha256:078d1d41f45ee34eed5a4f3bbe7c588caecbdd6e12dfca73e8c1b0e803773793 \
          --hash=sha256:0824e6ecee838cc28e6481062574c7fde49f9a2cedfacd36f0e91cb4b37fd6fe \
          --hash=sha256:09f007b2150eff015b2109f006e2ac2012d376f41486defa88ae78a776b00cff \
          --hash=sha256:0a0bcf66289b9d017c175562c35c5304b5cc3ed56aded994ae30b0a9654ba405 \
          --hash=sha256:0a657b51e4a5f4ac577c11e706ff9a884ea5aaf3e2666bae283a251c63e66acb \
          --hash=sha256:0c63ad657695e8f1a48624754cb6b464118ac50d4c1d477c26461c98390f0a62 \
          --hash=sha256:0d20d6ea5aabbeba2e054d33e405192ef75dc12947bbd00ec97d23b14969d325 \
          --hash=sha256:0e65260a1b1d7b81651f47343d836de70b88b02358ae3658efa6382104ec37b1 \
          --hash=sha256:0f78bb2e82fe88912c9d7b25c98e57a9b08655579af89f164fd4c0657a075d62 \
          --hash=sha256:10b24e836ee0233ca078e1244f6ba40343a22127a9a736f46a7e7b18de2cc711 \
          --hash=sha256:13cffaedde6e06183860fc92d88fe1d190abda73837fe4c14f5d4803c472f5dd \
          --hash=sha256:13eace1b315345ebac5b27821f5dcce24e5cf9976ab18f79e00a59bdd67e5d19 \
          --hash=sha256:15decc0fe293d9e3f924bd483f3d76f3d0ff26845112a470e3f8842fec2c82a1 \
          --hash=sha256:1dae5cd6c92d4440b15f20aa2987baa73c47ea14baa0fec8536a542e82e0ab33 \
          --hash=sha256:1db2604e6aedb7a2cb2f6e0575d6c9a852ccac8239703a930ac83b63309177a5 \
          --hash=sha256:2129c9a5fc05a230ce088745a790af073e582b584badc7b05db067ee326f56d7 \
          --hash=sha256:23046098ebf844753cfd211033624a8247520e5bf2194c24cb1a8c222917acff \
          --hash=sha256:23cb6f6d64e3a389bb8ba150f947f9a6c8c0aca383e814ca3c5cffab738d5646 \
          --hash=sha256:26838e2d95d7004c52e8c7b6b51676c872093a3b55a497824f899116a15a8a55 \
          --hash=sha256:2789d203babb6ceb2770aadc2394c1f99263ec37fba57a93064f9a8ad899e8ff \
          --hash=sha256:28d1935c16782a1e3650c9baa79069b016fff739e292e4cb14bbb830d6930491 \
          --hash=sha256:29b01520c39ef2f23c88b002f11e6ef4165675f6c92f5f3578fd587d69b5a5fc \
          --hash=sha256:2a377c7132b1e69be7a50d7434d7f26f69e93c70166ebb6d8f8cabf802ac4506 \
          --hash=sha256:2b06213c8e1ce93b18d0476d7a5e647436c8f23d099888c9065e930e80f4bed5 \
          --hash=sha256:2c460aeb12c2bd1c204944d9e9199595bf9e505eb542018d304bf9e63cb60cad \
          --hash=sha256:2d08ca4bf5a9cdb6fd81b86b51bd5cfb10527d3a1199888f2b02cc6c6a3d5f80 \
          --hash=sha256:2d875224bac1a05a20acade268a7a0e3498e7f8cf890acb7c2b23bacd2bd3659 \
          --hash=sha256:2e99440ef446c7833690c1754e23b0188d440f3cb89812b0764c697a7880cb33 \
          --hash=sha256:2fa79b9a48ae59744316c71a34cb9f76f30c93e117338522c5135cb7eac10351 \
          --hash=sha256:32029441af953e980b9940f042b337fe4ad9a97fa8b17a4ed878ec67b5b89ef4 \
          --hash=sha256:33221e49be79d7bfe6d12bc52ef9458b256ab74fa8ac5660acfa3065de1c7870 \
          --hash=sha256:34c78052277053bcb09810ac8e9ba4029f9e3e277833fc18ec1c928a6246ac91 \
          --hash=sha256:35381b575f70a08d4241e73c0cde4672bb9b2a9aae8767ca6b7fb61305a052c8 \
          --hash=sha256:35fe35d20baa661cef4a12ee7bc42eaf2376d43ef9816ab29dd47ca957f7a73a \
          --hash=sha256:39f532fa0d9026de4b9315a175998646112776baad54d55348435c11b05d034e \
          --hash=sha256:3c4f631dc8d00e470cde3ec0a35d4b58a817bea592411956f1cf4099dbb306b3 \
          --hash=sha256:3d78d93846eddc990551c1c31914d90d71957ca3af468969826f7ed0d7d1d51c \
          --hash=sha256:411aa0fb234f42a1444dea1e177890ddfc577b36ffdfafec25cb0d2c818e1af8 \
          --hash=sha256:41665c7ea01d3ae497a0c61fd22d3424230d18782a5fceb79f04db9ccb2042c9 \
          --hash=sha256:4170556762c6fd2913d99dfdd8dbb4c927584899df7facb1034627e355263c45 \
          --hash=sha256:43f270a5f21e12db08c73d83849a877c02ab7b7d0fb6e2718b5101d9c810212f \
          --hash=sha256:443fa28652682d2a3ec3eca49af1b87cb2523561257683e62e03a98967b22138 \
          --hash=sha256:45cc1ccb12ced6d242335159e8221733c8696da5ad0b6ceef6debb0f5ce89110 \
          --hash=sha256:46ae05aa1aecd47d4d7de0f05ce2d1d2eb418f8de614964d754cc3b9a409c400 \
          --hash=sha256:49fb5b4960ebe1bc557b435da8687deef1302a08f030a33c5606fa6fb11b773b \
          --hash=sha256:4a9133dbaedc6f1af358127275676171d9a1bb3e61f47ee62b2ff9acb78af3d0 \
          --hash=sha256:4aa85b34c21cf97b3470793d0bf0763d32bfd1e67b83067a0a3ba8dc3474dacf \
          --hash=sha256:4d5f2492cb2192aab2d42e57f2caa2159b4fd20fde06f859ec13354f524b176c \
          --hash=sha256:4e7b5d23ef144b32645d97bd99f382c4394c443395f45fe1576786838d26e308 \
          --hash=sha256:4f7431e71072962d3ed1768038200aa4f1e76d9c2d7bedd554d57a55faaf6644 \
          --hash=sha256:508775efa11d26aec186d10154359f52276e2baf9ca201b52356330883276dfd \
          --hash=sha256:5142798871a248b422f353e0684d51dfa119de3403a6fa0904b7cb806d9790ce \
          --hash=sha256:52a2ca6f401fb49a8d5d9e0e48ade5f58f1bdda33132907b0e4e3b702628fa4e \
          --hash=sha256:53209dffd91b0aefed9ea630fa6ad5c2944d6210ba3a8a3a8664dc1575289b14 \
          --hash=sha256:534ed583fd4323de45d196535a444cebd1af2105e6e4e0cdcbf8cea266a8747a \
          --hash=sha256:54fcd24944e6d127d198c28dc363967b7131ff0c97833962c2ef2048018de02d \
          --hash=sha256:55494475206113dbaf731dc8c5ffd5e1094175b753b7bbaad09fe3d7df61165c \
          --hash=sha256:5670a762c7ae388bf8aa04199fd436180a4d28318dca9c1eae7b38604676dbfd \
          --hash=sha256:56a76556ab04ab54a675acce2cac8b4e74ea2cec558a7c9ed37e0367b04b5d50 \
          --hash=sha256:56d43c311f3519fb1057b6114dc24e9060bc3fb6aedf4aa11160484154b66b63 \
          --hash=sha256:5868a02c4f6d698ddd19b4c9742748c03dec045289915806845189d96bc3d314 \
          --hash=sha256:58e5d1e935a90878a935c7d2737a25c71cf4f1c13b6e6bef454ab722c4f338bb \
          --hash=sha256:5ad409b7ea102339041281117cf2dadfe71edbb653dc48037cc55d516fb7f448 \
          --hash=sha256:5af7070d80d278832cbca9c3c3dd44b30a26dcfa3ae1e0f6f19ff34edc27b689 \
          --hash=sha256:5d0c871efc696ef5eb8514df64b86ab28736db753ebb42a2101f3b562f4849c0 \
          --hash=sha256:5e0c0ed37472c4729f3001066510a656486f08f149dda1ebfd3dfe4450c9756e \
          --hash=sha256:5e1c174b366565e101f903f9d1cc96d5508f805759dd37d012743f1c73ec0d7b \
          --hash=sha256:62059d739af7fc035ed6e63c5390118a60a5e9aa5a5541cd0486a83e741842c7 \
          --hash=sha256:623d4b44f64efdf235b1e8dce266057073d93cde6197e7d7684f20c297f67f30 \
          --hash=sha256:628efe13630ac3397e7d1278b6be6f22f37a86d638a324334b4cd43c1daf9928 \
          --hash=sha256:6342f79d6f50e680c8aa59e0615d745e867e51ffd59c77093be60b7c433067af \
          --hash=sha256:63b87c93e28957e6dc2bb92d31727a863c9bf4a4daa080f0995fdcb0242c9166 \
          --hash=sha256:65e937576141ac50fac32fa9736dbb3e0e4a7769f91be004011a09216c6ab05f \
          --hash=sha256:66027e401c70d0cf55021b91b8a7ec2cd5810e20602f945b4fe6ae8b37ed232b \
          --hash=sha256:6644eecd99c4e8cdf72e646e17b391bb70b054f44becde37dcdc48cbec7e1527 \
          --hash=sha256:6705af9d1005127302c04d9f1533ba56e289336c465923ef878430e99295a0b9 \
          --hash=sha256:6a8248b1ba8861e48e4c7ced3895a1264d2a3b617de72ec94172ce6e64bf16c7 \
          --hash=sha256:6b14914e67044724c31a9360c7b89e9d070117c630746eefdc1620d967545acd \
          --hash=sha256:6b7b540bb321f7f0a7b8f5d107f941bb361e3a154c0b594dae0394997b91b743 \
          --hash=sha256:71250e010eede33c1d638e2c7a98288520d67f782fd5eceecaeca3129233a09a \
          --hash=sha256:722ab747ff5dc28070b1a8c020dba6466f13f2ab56bc251ad301fefa2454aa1e \
          --hash=sha256:724224d4c457207271239114bf43afafc3eca4a1b4661ccdd428d11869a03bbd \
          --hash=sha256:729989759feb81ff6493879a0d60a0bd7d2eee41001bbec0381a080318439382 \
          --hash=sha256:740bba4223fa5216d4d6c5dcd29e697f37229b8a61b69e1a50527b0ea993ab2c \
          --hash=sha256:7bdc658c9474864893e0b6b94f1390bf6a912952df1870dd93bb7d1a902b5628 \
          --hash=sha256:7d53fc4b90ef6e11de639dc18744d9be8cbd70ccb5ce80027aaffe7b1ab0215a \
          --hash=sha256:7fa69212ea60ea24e2d8aff23fe102b1f87f1b27a320f92d2e7b3468997a496a \
          --hash=sha256:80326bc571164bbbb6bead2e35d0c943b23b24fde629032197c58151529d24d8 \
          --hash=sha256:80578e91764bfca297ddca322c00a3136d993b829e9839e7fa378a19c1fcc25d \
          --hash=sha256:80a6e37e235780f189558ab804f3cbc01c18f5c578995739b49613d544d34ebf \
          --hash=sha256:8135a549e27e9941a70e2d2156676ef2ffeff4b06e9d564dbaaae963482afdef \
          --hash=sha256:82e60c00cfb8493a5ba27cdf9b3695fdd153f666f73e11f18968f78ead1d8705 \
          --hash=sha256:856bbb24f2ee6436af7609267e73309e4bb0a0f9982f79f1c2e01019279c6671 \
          --hash=sha256:85d6daa3a7ca404570ae130babbeb347ef9d3faca5300fb13cfa4bb48c3d30d1 \
          --hash=sha256:8879b6a4040ee925c638548238ab7fe612cf5fa8752fe847346da0da8be81c3f \
          --hash=sha256:8b3bede7d583bc9f47d8693a29984882e59077db1a5238ad977fc70ae8169741 \
          --hash=sha256:8dbb3862aa649de95660b6337d97101977f160b5b354d07b82fe309874d2c8bc \
          --hash=sha256:8f244dfee05ea29b8064701880865eb1684f3a704a5665bd10b64694444dbbd4 \
          --hash=sha256:8f7469408740cf06a79b01605f2ae0b2acc8839c03fcbbf05da49baee12d3302 \
          --hash=sha256:90cc9973c51811918247a78d9ab2f54871296e4e37e69a98aba4d3c9acedbf62 \
          --hash=sha256:90d8c4fa5ba293cf92de351fbc292cdaadb1a1d58d031a1a97ff9b8fb6250ec7 \
          --hash=sha256:94c02b0702656f083c098bdbd93bce22a7aa7a2b34ba56d2472efb67dab7cf58 \
          --hash=sha256:9662a9fe457820c60365b3209e03cbd8e4a817195d55de65a80fa680b4bea136 \
          --hash=sha256:997617dd7856c5dad742bf6893b872319156dd43f47587541a59e4a852d52bbc \
          --hash=sha256:99c5637b74e2805ee4de9e2a43c8b45f678e50abb1c2da9880f0372f6498ba2f \
          --hash=sha256:9a215749c9a88ef2842e880215193e56ae60b856773c99702b078236bc6d4adb \
          --hash=sha256:9bde5d82d7ac4859e0cb3a35e148f537a8d4e56aa43f42582b5f263982f095ae \
          --hash=sha256:a004c1fe5a72c496f28c6c1d8c2dc5cfe3278d99478e18f8b838c70a912b366f \
          --hash=sha256:a0e2e7c2c1a4f25db7b6596738d810c10732e77f852247300a1bc49e364d6dc9 \
          --hash=sha256:a22c4956a4d858200dba83f0691bb692d77b0eeddfca80157820d20b85dea4f1 \
          --hash=sha256:a7f391838e8adcf1f2fe71561d9e5a9f74ea7ffa5052eb2db329aac677383136 \
          --hash=sha256:a9eacb382f400bb5865e7e6d24bbe709a84510291e707f169dd4a24ee4a5ac6a \
          --hash=sha256:ace8dd1efa5f44c482d091aa38322e20e3ffe5adcdba6b67ad9f4e7da58f3f68 \
          --hash=sha256:ade76f8c84ade325bbed96806357fffd353fcc29a5166d6dc6d39381f6d9f76c \
          --hash=sha256:af37a1e6b6bd506b597d5fb4cf111fb527d1b2223608a5d441d4738827cfd166 \
          --hash=sha256:af7c474f0d8f4d2a196370e85033873c7b063a0b5da9a4f143aa023e3bd25407 \
          --hash=sha256:b225c656efa2dedecc81651d2290170af25887b7de4f38c5efc7c5ae2b9442ab \
          --hash=sha256:b459d29c8b82a420a98fa0ce8e9cf787ce0062d98cc90604ef9574fb3cc26ff8 \
          --hash=sha256:bc6f87d03e3691154673aaa8f08991723d6e3394c83ef2875c7a9049eac9595c \
          --hash=sha256:bc8fd230ef013951900c1fda100eebe4a4b1b407dde2a44186995042dda2c628 \
          --hash=sha256:bd645b5d2f810a181c44f4a71135e7c365b44f4be9ed3d1892635be13a857553 \
          --hash=sha256:be7be57097a65a8fab3d0f0a10d12931deb626a7d8082eb732b1ae41f3a202e3 \
          --hash=sha256:c15a165673bb3fb57facbf040edf5c0556d20ccd2e0ccc5f23ebb69fb715fdc1 \
          --hash=sha256:c4b3f2c7d84f303da873b634d0beef83b5e1137294c3de4e23102841dac0cf4a \
          --hash=sha256:c534c9524a2acd0b97b7022074bec3784ac273c683cf9535087e437672ea8531 \
          --hash=sha256:c95d25b5382ee0e6191ecafdeabefdc1f7bff8dfee29239b9b79e760ef3b04bd \
          --hash=sha256:c9d06edfd974e918b40e0662a7e76dac13125529ee5ec9fbe42dc0d6faa209c3 \
          --hash=sha256:cdb8e4b0f6a41b857c74c03116e8ffbef59ef8e533e934b532843178990d01d5 \
          --hash=sha256:ce39283ef08b0f28478e920d4d89a1fc169176e568e8a6a821332673145522eb \
          --hash=sha256:cfef7f7aa434a1e632e0ebda14b39f4f1d7975e0fce5c77ea7b43156fabf9bd8 \
          --hash=sha256:d2605a3b2af8d66f8b75312d223642c065ec773446c04566d9030ad5e2db13c9 \
          --hash=sha256:d338813a440bf6d2f0df55140d3f3080284410b1ebfe9df50e3847bcdb1a17bb \
          --hash=sha256:d355b22270be8062360b9df2ee0b10277590789a1059257916fb9e256a0cff80 \
          --hash=sha256:d68da281ac208b6236ffa8beef23fe7c7c956d8bf09b421d447232fd94441b35 \
          --hash=sha256:dafbb58a149d1ebd5767b3f064f911c5ee0897608005e51c3904b0ada2a8d99c \
          --hash=sha256:dc2b495a92b3971966bf102e73589f950db3ec1ca6713265355ce7771d97b199 \
          --hash=sha256:dd0f3037d501178a761fd2814370aca547f79e99a200a61a1f6e7b79ec3d78b9 \
          --hash=sha256:de2c12555bf05546f3ee75733f2c81de70aab7f530e86d0d2162b0ddcb3c39ae \
          --hash=sha256:e164c4a6868d11988c7f2386e3278ccff21c665cd7d08279b62709dd37a3167c \
          --hash=sha256:ed59cb4ee258674a6ed9b8515e42079db02cb3be94f133fdd3f200183a40c49d \
          --hash=sha256:ef07e0b6b879f699a16fc7a513b974246fdeaef44908a021130cf4afe6a1c89c \
          --hash=sha256:ef2950896673a9809e8e5ab857525924fbcacfc98b858b0509ccf50d341f80f4 \
          --hash=sha256:f09f145b89ea292cf6c25fd7c8c0d90207fd6a9e54c7828499669996a1e5bdcc \
          --hash=sha256:f27e7e8a85512b6a4b490d5756edde8e6772883a5800e1476172e44eda3f7d7c \
          --hash=sha256:f300f28dff74ff4148c21e6971e4de6ca0c34e0086a3d95c017c5174ebf85ca5 \
          --hash=sha256:f3ed747b7651668131029c720fbc32c7ee2d129bdad200e6c8f4037b20f7913a \
          --hash=sha256:f87f02afe05c1c246012e3de100a77cfbabd17db709fe93cf074271ab239b312 \
          --hash=sha256:fa87ea2ad64e59fe5622c1dc5716106b6d6e7e4b26b848cb5f5710a75c292ef5 \
          --hash=sha256:fc23e72bd7f8a8e540fed2244524d0a9aeb6ae3325f3d56f04a7a3debe5b04c2 \
          --hash=sha256:fdd00937f15f5f93c8e53d8060a8c4c010431ab595a9b5b50ddd569a04603944 \
          --hash=sha256:fe7a168d805c8a7bf1c2de55b7ab2bc958586bfd88d0e87235a92cac66b590a7
    LOCK
  end
end

__END__
diff --git a/.env.example b/.env.example
--- a/.env.example
+++ b/.env.example
@@ -77,0 +78,3 @@
+# Start and verify the core first. Leave these settings unset to keep automatic
+# local model selection off. Ollama is optional; agents may still explicitly
+# choose a model for an individual call.
@@ -98,3 +101,5 @@
-# Outside Docker, the default base URL is http://localhost:11434/v1. There is
-# no default model: with UNITARES_MODEL_ID unset, consult and the local
-# reviewer refuse with MODEL_NOT_CONFIGURED. The older names
+# Outside Docker, an explicitly chosen model uses http://localhost:11434/v1
+# when no base URL is set. Automatic selection of a sole served model requires
+# an explicitly configured UNITARES_MODEL_BASE_URL. The local reviewer always
+# needs UNITARES_MODEL_ID; otherwise it refuses with MODEL_NOT_CONFIGURED.
+# The older names
diff --git a/docs/INTERFACE_CONTRACT.md b/docs/INTERFACE_CONTRACT.md
--- a/docs/INTERFACE_CONTRACT.md
+++ b/docs/INTERFACE_CONTRACT.md
@@ -3 +3 @@
-**Current contract:** `unitares.interface-contract.v1`, version `1.56.0`
+**Current contract:** `unitares.interface-contract.v1`, version `1.56.1`
@@ -1122,0 +1123,17 @@
+
+## 1.56.1 (2026-10-23)
+
+Automatic local model selection requires an explicitly configured endpoint; fresh installs stay model-free.
+
+- **Behavior:** when neither the caller nor `UNITARES_MODEL_ID` names a model,
+  sole-model discovery requires an explicitly configured `UNITARES_MODEL_BASE_URL`.
+  Unconfigured installs return `MODEL_NOT_CONFIGURED` without probing for a default.
+- **Compatibility:** explicit agent model picks, configured defaults, privacy
+  classification and opt-in consultation degradation retain their behavior.
+  An install relying on incidental discovery must explicitly set the endpoint.
+- **Descriptions:** the full `consult.model` description, registry notes and
+  refusal recovery explain the explicit endpoint requirement.
+- **Schema digests:** input and surface hashes are unchanged. The advertised
+  brief schema is unchanged; only its full explanatory description changes.
+- **Client action:** choose a model per call, set `UNITARES_MODEL_ID`, or explicitly
+  configure the endpoint to permit its sole-model default.
diff --git a/docs/install/CHOOSING_INSTALLATION.md b/docs/install/CHOOSING_INSTALLATION.md
new file mode 100644
--- /dev/null
+++ b/docs/install/CHOOSING_INSTALLATION.md
@@ -0,0 +1,134 @@
+# Choose one primary UNITARES installation
+
+An installation consists of the server, coordination lease plane, database,
+cache, and their configuration. Choose one primary installation per machine
+and connect clients to its endpoint. Installing a second copy does not migrate
+the first copy's data or switch its clients.
+
+## Available paths
+
+- **Docker Compose:** the current published, supported installation and update
+  path. It runs the services together and keeps data in Docker volumes. Follow
+  the [installation manual](../manual/02-install.md#21-docker-quickstart).
+- **Native macOS:** runs services directly on the Mac. For source-checkout installs, follow the
+  [native install playbook](PLAYBOOK.md). For packaged installs, the [Homebrew preview tap](https://github.com/cirwel/homebrew-unitares)
+  provides the native packages for Apple Silicon Macs. Its README covers
+  installation and the explicit database setup and upgrade steps.
+
+Homebrew is the intended recommended Mac experience once first-time setup,
+startup, backup/migration/update, and recovery are available through the same
+CLI. The public preview still requires explicit database provisioning and
+backed-up upgrades; it does not yet replace the
+supported Docker installation path.
+Docker remains a supported choice for server and advanced deployments.
+
+Installation method and optional capabilities are separate choices. Semantic
+search needs embeddings; model-assisted consultation needs a configured model.
+Neither capability appears merely by changing Docker to Homebrew. The manual's
+[capability table](../manual/02-install.md#24-quickstart-defaults-and-a-full-setup)
+names the defaults and the explicit setup for each feature.
+
+## Before creating another installation
+
+The [managed Docker launcher](../../scripts/install/launch.sh) checks for a
+Homebrew `unitares` installation, a native environment file, and the standard
+native LaunchAgent. It reports discovered paths. A configured native service
+blocks creation of a new Docker checkout; a package alone does not, because
+its CLI can be used with Docker. An existing managed Docker checkout with its
+own `.env` can still be reused after the usual ownership, origin, release and
+clean-checkout validation. Its configuration is preserved. The launcher does
+not read credentials from native configuration, stop that installation, or
+move its data.
+
+Homebrew is located through `PATH` or its standard macOS/Linuxbrew executable
+locations. `UNITARES_NATIVE_ENV` can identify a custom native configuration.
+These checks do not discover every source checkout, custom service manager,
+remote Docker context, or remote server. Review those explicitly before choosing
+an installation. An installed package is reported as installed, not as proof
+that its service is running.
+
+Existing UNITARES Docker containers also have an owner checkout. The launcher
+refuses containers owned by another checkout, or whose ownership is unknown,
+before creating its managed directory. Reuse the owning checkout for updates;
+changing directories is not a database migration.
+
+For a deliberate native-plus-Docker test, choose two free alternate ports and
+pass `--separate` explicitly:
+
+```sh
+curl -fsSL https://raw.githubusercontent.com/cirwel/unitares/master/scripts/install/launch.sh \
+  -o launch.sh
+GOVERNANCE_HOST_PORT=18767 LEASE_PLANE_HOST_PORT=18788 \
+  sh launch.sh --separate
+```
+
+Both ports must be distinct, between 1 and 65535, and different from the native
+defaults 8767 and 8788. Pick different values if a custom installation already
+uses these example ports. This option does not permit taking over another
+Docker checkout's fixed container names or volumes.
+
+For a new managed checkout the launcher saves these ports in `.env`, so later
+CLI updates keep them. For an existing checkout it requires matching numeric
+port assignments in `.env`, optionally surrounded by single or double quotes,
+and never rewrites the file. Use `KEY=value` with no `export` prefix or spaces
+around `=` or the value. Inline comments and variable expressions are also
+rejected because the CLI's port reader does not resolve them. Repeat the same
+explicit command to rerun the launcher alongside the native installation.
+
+## Know which server answered
+
+`unitares status` and `unitares status --json` report the endpoint they queried
+alongside the running version. A Homebrew CLI can connect to a Docker server or
+a remote server; the CLI's package version does not identify that server.
+URL credentials and query parameters are omitted from the displayed endpoint.
+
+```sh
+UNITARES_URL=http://localhost:18767 unitares status
+```
+
+## Control a configured Homebrew installation
+
+The CLI bundled in a Homebrew package selects its native services for `start`,
+`stop`, and `logs`. From a source checkout, select them explicitly:
+
+```sh
+unitares start --homebrew --check
+unitares start --homebrew
+unitares logs --homebrew server --no-follow
+unitares logs --homebrew lease-plane
+unitares stop --homebrew
+```
+
+This controls the current macOS user's local Homebrew installation. The
+formulae, a private `$(brew --prefix)/etc/unitares/native.env`, and the database
+must already be configured. Startup checks port ownership, starts missing
+PostgreSQL/Redis services, verifies the installed package's schema without
+applying migrations, then starts the lease plane and server and checks deep
+health. Existing services are reused. `--check` reports the plan without
+changing services; it does not claim that an offline database passed its schema
+check.
+
+Stop shuts down the server and lease plane and leaves PostgreSQL/Redis running.
+If startup fails, only writers newly started by that invocation are stopped;
+shared dependencies and pre-existing writers are retained. Inspect the error
+and logs before retrying. Neither start nor stop upgrades packages, creates a
+database, changes configuration, or runs migrations.
+
+This initial native path supports local PostgreSQL on 5432, Redis on 6379, and
+the packaged server on 8767. Both writers must name the same database with an
+explicit URL-encoded username and password. Configure the lease-plane port
+consistently in its bind setting and both client URLs. Configuration values
+must be single-line literal shell assignments, optionally quoted; shell
+expansion is refused. Custom Homebrew per-service environment files and custom
+writer commands require their existing service procedure. A shell-only
+`UNITARES_NATIVE_ENV` override cannot select a different launchd configuration.
+
+Native upgrades still use the documented stop/backup/migrate/restart procedure.
+`unitares update` and Docker model configuration refuse a Homebrew package;
+invoke the CLI in the owning Docker checkout to manage that stack.
+
+Before switching the primary installation, identify its database and connected
+clients, take and verify a backup, stop its writers, and validate the replacement
+before moving clients. Retain the old data until that validation passes. Do not
+delete Docker volumes or point native services at an existing database as a
+shortcut around this process.
diff --git a/docs/install/HOMEBREW_SETUP.md b/docs/install/HOMEBREW_SETUP.md
new file mode 100644
--- /dev/null
+++ b/docs/install/HOMEBREW_SETUP.md
@@ -0,0 +1,77 @@
+# Homebrew first-run configuration
+
+The native macOS preview tap is published at
+https://github.com/cirwel/homebrew-unitares. Follow its README for package
+installation and explicit first-time database provisioning.
+From a source checkout, `--homebrew` selects the installed native package;
+a packaged CLI selects it automatically.
+
+```sh
+unitares setup --homebrew
+unitares setup --homebrew --apply
+```
+
+The first command inspects the install without writing files or changing
+services. `--apply` creates a missing `$(brew --prefix)/etc/unitares/native.env`
+with mode 600. It prompts for the URL of your deliberately chosen PostgreSQL
+database without displaying the input. Use a URL with a URL-encoded user,
+password and database name on localhost port 5432. It does not create the
+PostgreSQL role or database. For automation, supply `DB_POSTGRES_URL` through
+a secret environment and add `--non-interactive`; do not put credentials in
+command arguments or shell history.
+
+Both writers receive the same database URL and one generated lease bearer.
+Redis uses localhost:6379, the server localhost:8767 and the lease plane
+localhost:8788. Model endpoint, model ID and resident roster start empty.
+Ollama is optional. Setup refuses competing port owners and custom service
+environments so an existing Docker/Colima installation cannot be mistaken for
+the native services.
+
+Existing configuration is inspected unchanged, including on repeated
+`--apply` runs. Credentials are never rotated by setup. An invalid file needs
+an explicit repair; setup will not replace it. The file contains secrets: keep
+it private and outside Git. Its assignments must be literal values without
+shell expansion. Existing configuration takes precedence over shell database
+settings.
+
+## Database next step
+
+Setup performs read-only database inspection only when the selected Homebrew
+PostgreSQL service is running. It never installs formulae, starts services,
+creates databases or applies SQL. A successful setup exit means the inspection
+completed, **not** that the server is ready; read its database-readiness line.
+
+- **Unknown:** PostgreSQL is stopped, credentials failed, or inspection failed.
+  Start the selected dependency with `brew services start postgresql@17` when
+  appropriate, verify the chosen database and credentials, then rerun setup.
+  Unknown does not mean empty.
+- **No UNITARES migration registry:** this does not establish emptiness. Only
+  if you deliberately created a new empty database, use the
+  [Homebrew first-time setup](https://github.com/cirwel/homebrew-unitares#first-time-setup) for it. Keep both writers stopped. The
+  bootstrap script is `scripts/install/bootstrap_postgres.sh` inside
+  `$(brew --prefix)/opt/unitares/libexec/app`; use the installed package's
+  Python and PostgreSQL tools. An existing database without the registry may
+  belong to another application or have an interrupted base bootstrap. Preserve
+  it and inspect its schema or restore a known backup. The migration runner
+  cannot repair a missing base schema or migration registry.
+- **Existing registry, schema not verified:** inspect the bootstrap stage.
+  If the base schema is complete and only numbered migrations remain, follow
+  the manual's [database backup and migration steps](../manual/02-install.md#updating-a-bare-metal-or-launchagent-install): back up,
+  quiesce both writers and use `scripts/dev/apply_migrations.py`. If the base
+  bootstrap itself is incomplete, preserve and inspect it or restore a backup;
+  do not treat numbered migrations as a generic repair. Do not rerun fresh
+  bootstrap over an existing database. For Homebrew, use `unitares stop` to
+  stop the two writers and verify their processes/listeners have stopped.
+  Run the database steps with the installed package's Python and scripts;
+  do not run the manual's source-checkout Git or pip commands inside a keg.
+- **Schema verified:** run `unitares start --homebrew --check`, then
+  `unitares start --homebrew`. Startup checks the schema again and waits for
+  server deep health.
+
+For commands that accept a database URL, pass its password through libpq's
+`PGPASSWORD` environment instead of including it in process arguments. Setup's
+own probes do this automatically and suppress raw database error output.
+
+Native upgrades remain the separate backed-up procedure in
+[Choosing an installation](CHOOSING_INSTALLATION.md). Setup does not switch
+clients, copy a Docker database, or change which installation owns your data.
diff --git a/docs/interface-contract.v1.json b/docs/interface-contract.v1.json
--- a/docs/interface-contract.v1.json
+++ b/docs/interface-contract.v1.json
@@ -3 +3 @@
-  "version": "1.56.0",
+  "version": "1.56.1",
diff --git a/docs/manual/02-install.md b/docs/manual/02-install.md
--- a/docs/manual/02-install.md
+++ b/docs/manual/02-install.md
@@ -131,0 +132,5 @@
+Start and verify the core installation first. A fresh install has no default
+model connected; Ollama is optional. An unrelated Ollama installation on the
+same machine does not become UNITARES's model just because it serves one model.
+Agents can still discover available models and explicitly choose one for a call.
+
@@ -162,2 +167,2 @@
-| `UNITARES_MODEL_BASE_URL` | Base URL of the model server, including `/v1` | `http://localhost:11434/v1` (Ollama on the same machine) |
-| `UNITARES_MODEL_ID` | The default model, used when an agent names none | None. An agent picks with `consult(model=...)` from the models `list_inference_hosts` lists; with no default and none picked, the endpoint's only model is used, else the call is refused with `MODEL_NOT_CONFIGURED` (through v3.4.0 it fell back to `gemma4:latest`) |
+| `UNITARES_MODEL_BASE_URL` | Base URL of the model server, including `/v1` | Explicit model requests use `http://localhost:11434/v1` when unset. Set this explicitly to enable automatic selection of the endpoint's sole served model. |
+| `UNITARES_MODEL_ID` | The default model, used when an agent names none | None. An agent can pick with `consult(model=...)`. Otherwise use this configured default, or the sole model at an explicitly configured endpoint; without either, return `MODEL_NOT_CONFIGURED`. |
@@ -184,0 +190,12 @@
+
+For Homebrew or a source installation, `unitares model --no-docker` prints the
+settings. Save them in the server's own environment (Homebrew uses
+`$(brew --prefix)/etc/unitares/native.env`) and restart the native server through
+its service manager. The core installation remains usable when this step is skipped.
+
+**Optional fallback:** after configuring local inference, a caller can use
+`consult(effort='thorough', allow_degraded=True)` to permit standard local advice
+when the thorough lane cannot run and its safety checks permit degradation.
+The response records that degradation. `allow_degraded` is false by default;
+this is not a universal retry switch for every provider or review workflow.
+Configuring Ollama does not grant permission to send prompts to a cloud provider.
@@ -549 +566 @@
-| Model for `consult` and the local reviewer | None named | `UNITARES_MODEL_BASE_URL` and `UNITARES_MODEL_ID` ([Choose a model](#choose-a-model-optional)), or `./scripts/unitares model` | `consult` answers `MODEL_NOT_CONFIGURED` (no model named, and the endpoint lists no single model to fall back on); `request_review` records the thesis and waits for a peer or the operator | `docker-compose.yml`; `UNITARES_MODEL_BASE_URL`, `UNITARES_MODEL_ID` |
+| Model for `consult` and the local reviewer | None named | `UNITARES_MODEL_BASE_URL` and `UNITARES_MODEL_ID` ([Choose a model](#choose-a-model-optional)), or `./scripts/unitares model` | `consult` answers `MODEL_NOT_CONFIGURED` (no model chosen and no explicitly configured endpoint with a sole served model); `request_review` records the thesis and waits for a peer or the operator | `docker-compose.yml`; `UNITARES_MODEL_BASE_URL`, `UNITARES_MODEL_ID` |
diff --git a/scripts/install/homebrew_services.py b/scripts/install/homebrew_services.py
new file mode 100644
--- /dev/null
+++ b/scripts/install/homebrew_services.py
@@ -0,0 +1,432 @@
+#!/usr/bin/env python3
+"""Control the existing, configured macOS Homebrew install; never install or migrate."""
+from __future__ import annotations
+
+import argparse
+import contextlib
+import fcntl
+import getpass
+import json
+import os
+from pathlib import Path
+import re
+import secrets
+import shlex
+import shutil
+import socket
+import stat
+import subprocess
+import sys
+import tempfile
+import time
+import urllib.request
+
+SERVICES = ('postgresql@17', 'redis', 'unitares-lease-plane', 'unitares')
+WRITERS = ('unitares', 'unitares-lease-plane')
+# Literal shell words only: the formula wrappers source this same file.
+WORD = r'''(?:[A-Za-z0-9_./:@%?=+,\-]+|'[^']*'|"[^"$`\\]*")*'''
+ASSIGNMENT = re.compile(rf'^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=({WORD})(?:\s+#.*)?$')
+
+
+class Refusal(RuntimeError):
+    pass
+
+
+def run(args, *, env=None, timeout=30):
+    try:
+        return subprocess.run(args, env=env, text=True, capture_output=True, timeout=timeout)
+    except (OSError, subprocess.TimeoutExpired) as exc:
+        raise Refusal(f'Could not complete {Path(args[0]).name}; check the installation.') from exc
+
+
+def read_config(path: Path) -> dict[str, str]:
+    try:
+        info = path.lstat()
+        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
+            raise Refusal(f'{path} must be a regular file owned by you with mode 600.')
+        lines = path.read_text().splitlines()
+    except OSError as exc:
+        raise Refusal(f'Configure {path} before starting; see docs/install/CHOOSING_INSTALLATION.md.') from exc
+    values = {}
+    for number, line in enumerate(lines, 1):
+        line = line.strip()
+        if not line or line.startswith('#'):
+            continue
+        match = ASSIGNMENT.fullmatch(line)
+        if not match:
+            raise Refusal(f'{path}:{number}: use single-line literal KEY=value assignments, without shell expansion.')
+        key, value = match.groups()
+        values[key] = ''.join(shlex.split(value))
+    return values
+
+
+def local_url(value: str, scheme: tuple[str, ...], port: int | None = None):
+    from urllib.parse import urlsplit
+    try:
+        url = urlsplit(value)
+        if url.scheme not in scheme or url.hostname not in ('localhost', '127.0.0.1'):
+            raise ValueError()
+        actual_port = url.port or {'postgresql': 5432, 'postgres': 5432, 'redis': 6379, 'http': 80}[url.scheme]
+        if port is not None and actual_port != port:
+            raise ValueError()
+        return url, actual_port
+    except ValueError as exc:
+        raise Refusal('Homebrew service control requires local, explicitly configured service endpoints.') from exc
+
+
+class Homebrew:
+    def __init__(self):
+        if sys.platform != 'darwin' or os.geteuid() == 0:
+            raise Refusal('Homebrew service control supports a regular macOS user, without sudo.')
+        self.brew = shutil.which('brew')
+        if not self.brew:
+            self.brew = next((p for p in ('/opt/homebrew/bin/brew', '/usr/local/bin/brew') if os.access(p, os.X_OK)), None)
+        if not self.brew:
+            raise Refusal('Homebrew is not installed or available on PATH.')
+        self.env = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_ANALYTICS='1')
+        prefix = self.call('--prefix').strip()
+        if not prefix.startswith('/') or '\n' in prefix:
+            raise Refusal('Homebrew returned an invalid prefix.')
+        self.prefix = Path(prefix)
+        self.app = self.prefix / 'opt/unitares/libexec/app'
+        self.config = self.prefix / 'etc/unitares/native.env'
+
+    def call(self, *args):
+        result = run([self.brew, *args], env=self.env)
+        if result.returncode:
+            # Homebrew output may include service environment values. Do not echo it.
+            raise Refusal(f'Homebrew {" ".join(args)} failed; inspect it with brew services info.')
+        return result.stdout
+
+    def info(self):
+        try:
+            records = json.loads(self.call('services', 'info', *SERVICES, '--json'))
+            result = {record['name']: record for record in records}
+            if set(result) != set(SERVICES):
+                raise ValueError()
+            return result
+        except (ValueError, TypeError, KeyError) as exc:
+            raise Refusal('Homebrew did not return a complete service inventory.') from exc
+
+    def check_installation(self):
+        override = os.environ.get('UNITARES_NATIVE_ENV')
+        if override and Path(override).absolute() != self.config:
+            raise Refusal('brew services uses its configured environment, not this shell’s UNITARES_NATIVE_ENV override. Use the canonical native.env.')
+        config_home = Path(os.environ.get('HOMEBREW_USER_CONFIG_HOME', str(Path.home() / '.homebrew')))
+        for name in SERVICES:
+            if (config_home / 'services' / f'{name}.env').exists():
+                raise Refusal(f'Custom Homebrew environment for {name}: use that service’s own procedure.')
+        for name, binary in (('unitares', 'unitares-server'), ('unitares-lease-plane', 'unitares-lease-plane'), ('postgresql@17', 'psql'), ('redis', 'redis-server')):
+            if not os.access(self.prefix / 'opt' / name / 'bin' / binary, os.X_OK):
+                raise Refusal(f'Install the {name} formula before starting.')
+    def configure(self, config=None):
+        self.check_installation()
+        if config is None:
+            config = read_config(self.config)
+        required = ('DB_POSTGRES_URL', 'UNITARES_LEASE_PLANE_DATABASE_URL', 'LEASE_PLANE_BEARER_TOKEN', 'REDIS_URL')
+        if any(not config.get(key) for key in required):
+            raise Refusal('native.env is incomplete; configure both database URLs, Redis and the lease bearer.')
+        if config['DB_POSTGRES_URL'] != config['UNITARES_LEASE_PLANE_DATABASE_URL']:
+            raise Refusal('The server and lease plane must use the same database URL.')
+        db, _ = local_url(config['DB_POSTGRES_URL'], ('postgresql', 'postgres'), 5432)
+        if not db.username or not db.password or not db.path.strip('/') or db.query or db.fragment:
+            raise Refusal('Use an explicit local database URL with a URL-encoded user, password and database, without query options.')
+        if any(marker in config['LEASE_PLANE_BEARER_TOKEN'].lower() for marker in ('replace-before', 'change-me', 'changeme')):
+            raise Refusal('Replace the template lease bearer before starting.')
+        local_url(config['REDIS_URL'], ('redis',), 6379)
+        local_url(config.get('UNITARES_GOVERNANCE_URL', 'http://127.0.0.1:8767'), ('http',), 8767)
+        try:
+            lease_port = int(config.get('UNITARES_LEASE_PLANE_HTTP_PORT', '8788'))
+            if not 1 <= lease_port <= 65535 or lease_port in (8767, 5432, 6379):
+                raise ValueError()
+        except ValueError as exc:
+            raise Refusal('Configure a valid, distinct lease-plane port.') from exc
+        if config.get('UNITARES_LEASE_PLANE_HTTP_IP', '127.0.0.1') != '127.0.0.1':
+            raise Refusal('This Homebrew service path requires loopback-only listeners.')
+        for key in ('UNITARES_LEASE_PLANE_URL', 'LEASE_PLANE_BASE_URL'):
+            local_url(config.get(key, 'http://127.0.0.1:8788'), ('http',), lease_port)
+        tokens = [token.strip() for token in config.get('UNITARES_MCP_BEARER_TOKENS', '').split(',') if token.strip()]
+        # Use the service's configuration, never a shell-only client credential.
+        self.health_token = tokens[0] if tokens else config.get('UNITARES_HTTP_API_TOKEN', '')
+        self.runtime_env = dict(self.env, **config)
+        self.runtime_env['PATH'] = f'{self.prefix}/opt/postgresql@17/bin:{self.env.get("PATH", "")}'
+        self.ports = dict(zip(SERVICES, (5432, 6379, lease_port, 8767)))
+
+    def check_commands(self, records):
+        for name in WRITERS:
+            command = records[name].get('command', '')
+            binary = 'unitares-server' if name == 'unitares' else name
+            if shlex.split(command) != [str(self.prefix / 'opt' / name / 'bin' / binary)]:
+                raise Refusal(f'{name} has a custom service command; use its own procedure.')
+
+    def setup(self, apply=False, non_interactive=False):
+        """Create only a missing configuration; never start services or execute DDL."""
+        self.check_installation()
+        records = self.info()
+        self.check_commands(records)
+        print(f'Installation: Homebrew\nConfiguration: {self.config}')
+        # lexists includes dangling symlinks, which must never be replaced.
+        if os.path.lexists(self.config):
+            self.configure()
+            self.check_ports(records)
+            print('Existing configuration preserved. Shell database settings are ignored.')
+            self.setup_next_step(records)
+            return
+        self.ports = dict(zip(SERVICES, (5432, 6379, 8788, 8767)))
+        self.check_ports(records)
+        if any(records[name].get('running') or records[name].get('loaded') for name in WRITERS):
+            raise Refusal('A native writer is active without canonical configuration; stop and inspect that installation first.')
+        if not apply:
+            print('Plan: create a private native.env using your explicit PostgreSQL URL and a generated lease bearer. Models and residents remain optional. No database or service changes.')
+            print('Next: unitares setup --homebrew --apply (hidden database URL prompt; automation may supply DB_POSTGRES_URL in its environment).')
+            return
+        db_url = os.environ.get('DB_POSTGRES_URL', '')
+        if not db_url and not non_interactive and sys.stdin.isatty():
+            db_url = getpass.getpass('PostgreSQL URL for your chosen database (input hidden): ')
+        if not db_url:
+            raise Refusal('Supply DB_POSTGRES_URL in the environment, or run interactively for a hidden prompt. No configuration was written.')
+        # Keep generated values literal in both the Python reader and shell wrappers.
+        if any(char.isspace() or ord(char) < 32 or ord(char) == 127 or char in "'\"$`\\" for char in db_url):
+            raise Refusal('URL-encode database credentials; the URL must be a single literal value.')
+        config = {
+            'DB_POSTGRES_URL': db_url,
+            'DB_BACKEND': 'postgres',
+            'DB_AGE_GRAPH': 'governance_graph',
+            'REDIS_URL': 'redis://127.0.0.1:6379/0',
+            'UNITARES_KNOWLEDGE_BACKEND': 'postgres',
+            'UNITARES_DIALECTIC_BACKEND': 'postgres',
+            'UNITARES_LEASE_PLANE_DATABASE_URL': db_url,
+            'UNITARES_LEASE_PLANE_HTTP_IP': '127.0.0.1',
+            'UNITARES_LEASE_PLANE_HTTP_PORT': '8788',
+            'UNITARES_LEASE_PLANE_URL': 'http://127.0.0.1:8788',
+            'LEASE_PLANE_BASE_URL': 'http://127.0.0.1:8788',
+            'UNITARES_GOVERNANCE_URL': 'http://127.0.0.1:8767',
+            'LEASE_PLANE_BEARER_TOKEN': secrets.token_urlsafe(32),
+            'UNITARES_MODEL_BASE_URL': '',
+            'UNITARES_MODEL_ID': '',
+            'UNITARES_RESIDENTS': '',
+        }
+        self.configure(config)
+        directory = self.config.parent
+        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
+        info = directory.lstat()
+        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
+            raise Refusal('The native configuration directory must be owned by you, not a symlink or writable by others.')
+        # Publish a complete private file atomically, without replacing a racing creator.
+        fd, temporary = tempfile.mkstemp(prefix='.native-', dir=directory)
+        try:
+            with os.fdopen(fd, 'w') as output:
+                output.write('# UNITARES native services; private configuration.\n')
+                output.writelines(f'{key}={shlex.quote(value)}\n' for key, value in config.items())
+                output.flush()
+                os.fsync(output.fileno())
+            os.link(temporary, self.config)
+        finally:
+            os.unlink(temporary)
+        print('Created private configuration (mode 600). No services or databases were changed.')
+        self.setup_next_step(records)
+
+    def database_environment(self):
+        from urllib.parse import unquote, urlsplit, urlunsplit
+        db = urlsplit(self.runtime_env['DB_POSTGRES_URL'])
+        public_url = urlunsplit(db._replace(netloc=f'{db.username}@{db.hostname}:{db.port or 5432}'))
+        # libpq shell overrides (especially PGHOSTADDR) must not redirect this probe.
+        env = {key: value for key, value in self.runtime_env.items() if not key.startswith('PG')}
+        env.update(PGPASSWORD=unquote(db.password), PGCONNECT_TIMEOUT='5', DB_POSTGRES_URL=public_url,
+                   UNITARES_LEASE_PLANE_DATABASE_URL=public_url)
+        return public_url, env
+
+    def setup_next_step(self, records):
+        guide = Path(__file__).resolve().parents[2] / 'docs/install/HOMEBREW_SETUP.md'
+        if not records['postgresql@17'].get('running'):
+            print('Database readiness: unknown (Homebrew PostgreSQL is stopped). Start that dependency, then rerun setup. This does not establish that the database is empty.')
+        else:
+            url, env = self.database_environment()
+            # Absence of our registry never proves absence of someone else's data.
+            query = "SELECT to_regclass('core.schema_migrations') IS NOT NULL"
+            result = run([str(self.prefix / 'opt/postgresql@17/bin/psql'), '-X', '-Atq',
+                          '-v', 'ON_ERROR_STOP=1', url, '-c', query], env=env)
+            if result.returncode or result.stdout.strip() not in ('t', 'f'):
+                print('Database readiness: unknown (connection or inspection failed). Verify the selected database and credentials; do not bootstrap an unknown database.')
+            elif result.stdout.strip() == 'f':
+                print('Database readiness: no UNITARES migration registry. Database contents and freshness are not established. Use fresh bootstrap only for a deliberately new empty database; otherwise inspect or restore the existing database first.')
+            else:
+                try:
+                    self.check_schema()
+                except Refusal:
+                    print('Database readiness: existing registry, schema not verified. Inspect the bootstrap stage and use backed-up migration recovery when the base schema is complete, never fresh bootstrap. Stop both writers before applying migrations.')
+                else:
+                    print('Database readiness: schema verified. Next: unitares start --homebrew --check, then unitares start --homebrew.')
+        print(f'Fresh bootstrap / existing-database recovery: {guide}')
+
+    @contextlib.contextmanager
+    def lock(self):
+        directory = self.prefix / 'var/unitares'
+        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
+        fd = os.open(directory / 'service-control.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
+        try:
+            try:
+                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
+            except BlockingIOError as exc:
+                raise Refusal('Another native service-control command is running.') from exc
+            yield
+        finally:
+            os.close(fd)
+
+    def check_ports(self, records):
+        for name, port in self.ports.items():
+            try:
+                with socket.create_connection(('127.0.0.1', port), timeout=0.3):
+                    pass
+            except OSError:
+                continue
+            owners = run(['lsof', '-nP', '-t', f'-iTCP:{port}', '-sTCP:LISTEN']).stdout.split()
+            pid = records[name].get('pid')
+            if not records[name].get('running') or not pid or not owners or set(owners) != {str(pid)}:
+                raise Refusal(f'Port {port} is occupied outside the selected Homebrew {name} service; reuse that installation or choose separate ports.')
+
+    def wait_port(self, name, timeout):
+        end = time.monotonic() + timeout
+        while time.monotonic() < end:
+            records = self.info()
+            self.check_ports(records)
+            try:
+                with socket.create_connection(('127.0.0.1', self.ports[name]), timeout=0.3):
+                    if records[name].get('running'):
+                        return
+            except OSError:
+                pass
+            time.sleep(1)
+        raise Refusal(f'{name} did not become ready; inspect its Homebrew logs.')
+
+    def check_schema(self):
+        python = self.prefix / 'opt/unitares/libexec/venv/bin/python'
+        script = self.app / 'scripts/dev/apply_migrations.py'
+        if not python.is_file() or not script.is_file():
+            raise Refusal('The installed package lacks the native schema check.')
+        # The checker forwards its URL to psql. Keep the password in libpq's
+        # environment so neither Python nor nested psql argv contains it.
+        public_url, env = self.database_environment()
+        result = run([str(python), str(script), '--check', '--db-url', public_url], env=env, timeout=60)
+        if result.returncode:
+            raise Refusal('The installed schema check failed. Bootstrap a fresh database or use the documented backed-up native upgrade procedure before starting writers.')
+
+    def start(self, check=False, timeout=60):
+        self.configure()
+        records = self.info()
+        self.check_commands(records)
+        self.check_ports(records)
+        print(f'Installation: Homebrew\nConfiguration: {self.config}\nEndpoint: http://127.0.0.1:8767')
+        if check:
+            print('Plan: start missing services in order: PostgreSQL, Redis, lease plane, server. Check the schema before starting writers; no migrations run.')
+            return
+        started = []
+        try:
+            for name in SERVICES:
+                if name == 'unitares-lease-plane':
+                    self.check_schema()
+                if not records[name].get('running'):
+                    # Include a partially successful start in failure cleanup.
+                    started.append(name)
+                    self.call('services', 'start', name)
+                self.wait_port(name, timeout)
+            end = time.monotonic() + timeout
+            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
+            headers = {'Authorization': 'Bearer ' + self.health_token} if self.health_token else {}
+            request = urllib.request.Request('http://127.0.0.1:8767/health/deep', headers=headers)
+            while time.monotonic() < end:
+                try:
+                    with opener.open(request, timeout=2) as response:
+                        payload = json.load(response)
+                        status = payload.get('status') if isinstance(payload, dict) else None
+                    if status in ('healthy', 'moderate'):
+                        print(f'Deep health: {status}')
+                        return
+                except (OSError, ValueError):
+                    pass
+                time.sleep(1)
+            raise Refusal('Server deep health did not become healthy/moderate; inspect unitares logs.')
+        except (Refusal, KeyboardInterrupt):
+            for name in reversed(started):
+                if name in WRITERS:
+                    try:
+                        self.call('services', 'stop', name)
+                    except Refusal:
+                        print(f'warning: could not stop newly started {name}; inspect brew services info.', file=sys.stderr)
+            print('Any dependencies started by this command remain available; pre-existing writers were not stopped.', file=sys.stderr)
+            raise
+
+    def stop(self, check=False):
+        records = self.info()
+        if check:
+            print('Plan: stop the Homebrew server, then lease plane. Leave PostgreSQL and Redis running.')
+            return
+        errors = []
+        for name in WRITERS:
+            if records[name].get('running') or records[name].get('loaded') or records[name].get('registered'):
+                try:
+                    self.call('services', 'stop', name)
+                except Refusal as exc:
+                    errors.append(str(exc))
+        if errors:
+            raise Refusal('; '.join(errors))
+        after = self.info()
+        if any(after[name].get('running') or after[name].get('loaded') for name in WRITERS):
+            raise Refusal('A Homebrew writer remains running; inspect brew services info.')
+        print('Stopped Homebrew server and lease plane. PostgreSQL/Redis were left unchanged.')
+
+    def logs(self, service, follow=True, lines=100):
+        name = {'server': 'unitares', 'lease-plane': 'unitares-lease-plane'}[service]
+        path = self.prefix / 'var/log' / f'{name}.log'
+        if not path.is_file():
+            raise Refusal(f'No log file yet: {path}')
+        args = ['tail', '-n', str(lines)] + (['-F'] if follow else []) + [str(path)]
+        os.execvp('tail', args)
+
+
+def main(argv=None):
+    parser = argparse.ArgumentParser(description=__doc__)
+    actions = parser.add_subparsers(dest='action', required=True)
+    setup = actions.add_parser('setup', help='inspect native setup; --apply creates missing private configuration only')
+    setup.add_argument('--apply', action='store_true')
+    setup.add_argument('--non-interactive', action='store_true')
+    start = actions.add_parser('start')
+    start.add_argument('--check', action='store_true', help='report the startup plan without changing services')
+    start.add_argument('--timeout', type=int, default=60, help='readiness timeout per service, in seconds')
+    stop = actions.add_parser('stop')
+    stop.add_argument('--check', action='store_true', help='report the stop plan without changing services')
+    logs = actions.add_parser('logs')
+    logs.add_argument('service', nargs='?', choices=('server', 'lease-plane'), default='server')
+    logs.add_argument('--no-follow', action='store_true')
+    logs.add_argument('--tail', type=int, default=100)
+    args = parser.parse_args(argv)
+    if not 1 <= getattr(args, 'timeout', 60) <= 300 or not 1 <= getattr(args, 'tail', 100) <= 10000:
+        parser.error('timeout must be 1–300 seconds; tail must be 1–10000 lines')
+    try:
+        brew = Homebrew()
+        if args.action == 'setup':
+            if args.apply:
+                with brew.lock():
+                    brew.setup(apply=True, non_interactive=args.non_interactive)
+            else:
+                brew.setup()
+        elif args.action == 'logs':
+            brew.logs(args.service, not args.no_follow, args.tail)
+        elif args.check:
+            getattr(brew, args.action)(check=True)
+        else:
+            with brew.lock():
+                if args.action == 'start':
+                    brew.start(timeout=args.timeout)
+                else:
+                    brew.stop()
+        return 0
+    except (Refusal, OSError) as exc:
+        print(f'error: {exc}', file=sys.stderr)
+        return 1
+    except KeyboardInterrupt:
+        return 130
+
+
+if __name__ == '__main__':
+    raise SystemExit(main())
diff --git a/scripts/install/launch.sh b/scripts/install/launch.sh
--- a/scripts/install/launch.sh
+++ b/scripts/install/launch.sh
@@ -6 +6,3 @@
-case "${1:-up}" in
+separate=0
+for arg in "$@"; do
+    case "$arg" in
@@ -8 +10 @@
-        echo 'Usage: sh launch.sh [up]'
+        echo 'Usage: sh launch.sh [up] [--separate]'
@@ -9,0 +12,2 @@
+        echo '--separate requires explicit GOVERNANCE_HOST_PORT and LEASE_PLANE_HOST_PORT, outside 8767/8788.'
+        echo 'Choose an installation: https://github.com/cirwel/unitares/blob/master/docs/install/CHOOSING_INSTALLATION.md'
@@ -11,3 +15,54 @@
-    up) [ "$#" -le 1 ] || fail 'up takes no arguments' ;;
-    *) fail 'expected up or --help' ;;
-esac
+    up) ;;
+    --separate) separate=1 ;;
+    *) fail 'expected up, --separate or --help' ;;
+    esac
+done
+stack=${UNITARES_STACK_DIR:-"$HOME/.unitares/stack"}
+case "$stack" in /*) ;; *) fail 'UNITARES_STACK_DIR must be an absolute path' ;; esac
+
+# Probe installation metadata only: never source native.env, start a service,
+# or infer the owner of an HTTP endpoint from its version string.
+native=0
+brew_prefix=""
+brew_command=$(command -v brew 2>/dev/null || true)
+if [ -z "$brew_command" ]; then
+    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
+        if [ -x "$candidate" ]; then brew_command=$candidate; break; fi
+    done
+fi
+if [ -n "$brew_command" ]; then
+    brew_prefix=$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 "$brew_command" --prefix 2>/dev/null) \
+        || fail 'Cannot inspect the Homebrew prefix; check brew before installing another stack'
+    case "$brew_prefix" in /*) ;; *) fail 'Homebrew returned an invalid prefix' ;; esac
+    if [ -e "$brew_prefix/opt/unitares" ] || [ -L "$brew_prefix/opt/unitares" ]; then
+        printf 'Existing Homebrew installation: %s\n' "$brew_prefix/opt/unitares" >&2
+        echo 'Package presence alone does not establish a configured native server.' >&2
+    fi
+fi
+native_config=${UNITARES_NATIVE_ENV:-"${brew_prefix:-/opt/homebrew}/etc/unitares/native.env"}
+if [ -f "$native_config" ]; then
+    printf 'Existing native configuration: %s\n' "$native_config" >&2
+    native=1
+fi
+if [ -f "$HOME/Library/LaunchAgents/com.unitares.governance-mcp.plist" ]; then
+    printf 'Existing native LaunchAgent: %s\n' "$HOME/Library/LaunchAgents/com.unitares.governance-mcp.plist" >&2
+    native=1
+fi
+if [ "$native" = 1 ] && [ "$separate" = 0 ]; then
+    if [ -d "$stack/.git" ] && [ -f "$stack/.env" ]; then
+        echo 'Native configuration also exists; reusing the existing managed Docker checkout after validation. Its ports and data will be preserved.' >&2
+    else
+        fail 'Use the existing native installation, or explicitly choose a separate Docker install with --separate and two alternate host ports. Nothing was installed. See https://github.com/cirwel/unitares/blob/master/docs/install/CHOOSING_INSTALLATION.md'
+    fi
+fi
+if [ "$separate" = 1 ]; then
+    # Explicit environment values override .env in Compose. Do not evaluate
+    # someone else's .env as shell code or guess its interpolated port values.
+    for port in "${GOVERNANCE_HOST_PORT:-}" "${LEASE_PLANE_HOST_PORT:-}"; do
+        case "$port" in ''|*[!0-9]*|0*|8767|8788) fail '--separate requires two explicit alternate host ports (1-65535, excluding 8767/8788)' ;; esac
+        [ "${#port}" -le 5 ] && [ "$port" -le 65535 ] \
+            || fail '--separate host ports must be in 1-65535'
+    done
+    [ "$GOVERNANCE_HOST_PORT" != "$LEASE_PLANE_HOST_PORT" ] \
+        || fail '--separate requires different server and lease-plane ports'
+fi
@@ -20,2 +74,0 @@
-stack=${UNITARES_STACK_DIR:-"$HOME/.unitares/stack"}
-case "$stack" in /*) ;; *) fail 'UNITARES_STACK_DIR must be an absolute path' ;; esac
@@ -22,0 +76,14 @@
+# Check existing Compose ownership before creating a checkout or lock. Resolve
+# an existing parent without creating it, so symlinked paths still compare.
+if [ -d "$(dirname "$stack")" ]; then
+    stack=$(cd "$(dirname "$stack")" && pwd -P)/$(basename "$stack")
+fi
+check_compose_ownership() {
+    for name in unitares-postgres-age unitares-redis unitares-lease-plane unitares-governance-mcp; do
+        if owner=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$name" 2>/dev/null); then
+            [ "$owner" = "$stack" ] \
+                || fail "$name belongs to ${owner:-an unknown checkout}; use that installation instead"
+        fi
+    done
+}
+check_compose_ownership
@@ -65,5 +132 @@
-for name in unitares-postgres-age unitares-redis unitares-lease-plane unitares-governance-mcp; do
-    owner=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$name" 2>/dev/null || true)
-    [ -z "$owner" ] || [ "$owner" = "$stack" ] \
-        || fail "$name belongs to $owner; use that installation instead"
-done
+check_compose_ownership
@@ -71 +134,9 @@
-    (umask 077; cp "$stack/.env.example" "$stack/.env")
+    [ ! -L "$stack/.env" ] || fail '.env is a broken symlink; leaving it untouched'
+    (
+        umask 077
+        cp "$stack/.env.example" "$stack/.env"
+        if [ "$separate" = 1 ]; then
+            printf '\nGOVERNANCE_HOST_PORT=%s\nLEASE_PLANE_HOST_PORT=%s\n' \
+                "$GOVERNANCE_HOST_PORT" "$LEASE_PLANE_HOST_PORT" >> "$stack/.env"
+        fi
+    )
@@ -73,0 +145,43 @@
+if [ "$separate" = 1 ]; then
+    # Save fresh choices above so later CLI updates keep the same ports. An
+    # existing file is operator-owned: require literal matching assignments,
+    # rather than silently rewriting it or evaluating dotenv expressions.
+    for key in GOVERNANCE_HOST_PORT LEASE_PLANE_HOST_PORT; do
+        saved=$(awk -v key="$key" '
+            /^[[:space:]]*#/ { next }
+            { line=$0; sub(/^[[:space:]]*export[[:space:]]+/, "", line)
+              if (line ~ ("^[[:space:]]*" key "([[:space:]]*(#.*)?)?$")) invalid=1
+              if (line ~ ("^[[:space:]]*" key "[[:space:]]*:")) invalid=1
+              pos=index(line, "="); name=substr(line, 1, pos-1)
+              gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
+              if (pos && name==key) {
+                  # Reject assignment forms the CLI port reader skips.
+                  if ($0 !~ ("^[[:space:]]*" key "=")) invalid=1
+                  value=substr(line, pos+1)
+              } }
+            END {
+                if (invalid) { print "unsupported port assignment"; exit }
+                quote=substr(value, 1, 1)
+                if ((quote=="\"" || quote==sprintf("%c", 39)) && substr(value, length(value), 1)==quote)
+                    value=substr(value, 2, length(value)-2)
+                print value
+            }
+        ' "$stack/.env")
+        case "$key" in GOVERNANCE_HOST_PORT) expected=$GOVERNANCE_HOST_PORT ;; *) expected=$LEASE_PLANE_HOST_PORT ;; esac
+        [ "$saved" = "$expected" ] \
+            || fail "Set the literal $key=$expected in $stack/.env before retrying; existing configuration was not changed"
+    done
+    # Check a later invocation without this command's port overrides resolves
+    # identically. Compare Compose's complete config internally: line-reading
+    # `config --environment` is ambiguous when a value contains newlines.
+    # Never print these configurations, which may contain credentials.
+    explicit_config=$(docker compose --project-directory "$stack" config) \
+        || fail 'Cannot resolve the Compose configuration; no services were started'
+    saved_config=$(
+        unset GOVERNANCE_HOST_PORT LEASE_PLANE_HOST_PORT
+        docker compose --project-directory "$stack" config
+    ) || fail 'Cannot resolve the saved Compose configuration; no services were started'
+    [ "$saved_config" = "$explicit_config" ] \
+        || fail "Compose and the CLI disagree on saved ports; use single literal assignments in $stack/.env before retrying"
+    unset explicit_config saved_config
+fi
@@ -75 +189,4 @@
-printf 'Installed: %s\nCheckout: %s\n' "$installed" "$stack"
+printf 'Installation: Docker Compose\nInstalled: %s\nCheckout: %s\n' "$installed" "$stack"
+if [ "$separate" = 1 ]; then
+    printf 'Separate install: server port %s, lease-plane port %s\n' "$GOVERNANCE_HOST_PORT" "$LEASE_PLANE_HOST_PORT"
+fi
@@ -115,0 +233,2 @@
+printf 'Optional: connect a model for advice and local reviews with ./scripts/unitares model.\n'
+printf 'Ollama is one supported choice; core startup does not require a model.\n'
diff --git a/scripts/install/setup.py b/scripts/install/setup.py
--- a/scripts/install/setup.py
+++ b/scripts/install/setup.py
@@ -498,0 +499 @@
+    lines.append("Optional, after the core is running: connect a model for advice and local reviews. See docs/manual/02-install.md#choose-a-model-optional; Ollama is one supported choice.")
diff --git a/scripts/unitares b/scripts/unitares
--- a/scripts/unitares
+++ b/scripts/unitares
@@ -435 +435,12 @@
-    local health residents tiers latest errbuf auth_hint=0
+    local health residents tiers latest errbuf endpoint auth_hint=0
+    # Attribute the remote report to its endpoint, not to this CLI's install.
+    # Never echo URL credentials, query parameters or fragments in status.
+    endpoint=$(STATUS_URL="$UNITARES_URL" python3 -c '
+import os
+from urllib.parse import urlsplit, urlunsplit
+try:
+    url = urlsplit(os.environ["STATUS_URL"])
+    print(urlunsplit((url.scheme, url.netloc.rsplit("@", 1)[-1], url.path, "", "")))
+except ValueError:
+    print("[invalid endpoint URL]")
+')
@@ -448 +459 @@
-                printf '%s\n' '{"health": {"status": "warming_up"}, "residents": null, "tiers": null, "auth_required": false, "release": {"current": null, "latest": null, "comparison": "unknown"}}'
+                STATUS_ENDPOINT="$endpoint" python3 -c 'import json, os; print(json.dumps({"endpoint": os.environ["STATUS_ENDPOINT"], "health": {"status": "warming_up"}, "residents": None, "tiers": None, "auth_required": False, "release": {"current": None, "latest": None, "comparison": "unknown"}}))'
@@ -449,0 +461 @@
+                printf 'Endpoint: %s\n' "$endpoint"
@@ -541 +553 @@
-    JSON_MODE="$json_mode" python3 -c '
+    JSON_MODE="$json_mode" STATUS_ENDPOINT="$endpoint" python3 -c '
@@ -583,0 +596 @@
+        "endpoint": os.environ["STATUS_ENDPOINT"],
@@ -605,0 +619 @@
+print("Endpoint: " + os.environ["STATUS_ENDPOINT"])
@@ -955,0 +970,27 @@
+_is_homebrew_package() {
+    local root
+    root="$(_repo_root)"
+    case "$root" in
+        */libexec/app) [ -x "$root/../../bin/unitares-server" ] ;;
+        *) return 1 ;;
+    esac
+}
+
+_has_homebrew_option() {
+    local arg
+    for arg in "$@"; do
+        [ "$arg" != "--homebrew" ] || return 0
+    done
+    return 1
+}
+
+_homebrew_service() {
+    local action="$1" arg
+    local -a options=()
+    shift
+    for arg in "$@"; do
+        [ "$arg" = "--homebrew" ] || options+=("$arg")
+    done
+    python3 "$(_repo_root)/scripts/install/homebrew_services.py" "$action" "${options[@]+"${options[@]}"}"
+}
+
@@ -982,0 +1024,5 @@
+    if _is_homebrew_package; then
+        echo "error: this CLI belongs to a Homebrew package; this operation requires a Docker checkout." >&2
+        echo "       Native upgrades still require stopping both writers, backup and explicit migration. See docs/install/CHOOSING_INSTALLATION.md." >&2
+        return 1
+    fi
@@ -1013,0 +1060,4 @@
+    if _has_homebrew_option "$@" || _is_homebrew_package; then
+        _homebrew_service start "$@"
+        return $?
+    fi
@@ -1017,0 +1068,9 @@
+cmd_setup() {
+    if _has_homebrew_option "$@" || _is_homebrew_package; then
+        _homebrew_service setup "$@"
+    else
+        echo 'Select the installed native package with unitares setup --homebrew. For source installs, use scripts/install/setup.py.' >&2
+        return 1
+    fi
+}
+
@@ -1018,0 +1078,4 @@
+    if _has_homebrew_option "$@" || _is_homebrew_package; then
+        _homebrew_service stop "$@"
+        return $?
+    fi
@@ -1023,0 +1087,4 @@
+    if _has_homebrew_option "$@" || _is_homebrew_package; then
+        _homebrew_service logs "$@"
+        return $?
+    fi
@@ -1519,2 +1586,15 @@
-  start | stop                      Start or stop the stack
-  logs [service]                    Follow logs (default: governance-mcp)
+  start | stop                      Start or stop this installation
+  logs [service]                    Follow this installation's logs
+
+Homebrew service control (automatic from a Homebrew package):
+  setup --homebrew [--apply] [--non-interactive]
+                                    Inspect native configuration and database
+                                    readiness; --apply creates missing config
+  start --homebrew [--check]         Start missing services; verify the schema
+                                    before starting either writer
+  stop --homebrew [--check]          Stop both writers; retain PostgreSQL/Redis
+  logs --homebrew [server|lease-plane] [--no-follow] [--tail N]
+                                    Read native service logs
+  From a source checkout, --homebrew explicitly selects the installed native
+  services. Configuration/bootstrap must already be complete. No migrations
+  run during start. Native update is still a separate backed-up procedure.
@@ -1574,0 +1655 @@
+    setup)       shift; cmd_setup "$@" ;;
diff --git a/src/interface_contract.py b/src/interface_contract.py
--- a/src/interface_contract.py
+++ b/src/interface_contract.py
@@ -324 +324,2 @@
-INTERFACE_CONTRACT_VERSION = "1.56.0"
+# 1.56.1 (2026-10-23): Automatic local model selection requires an explicitly configured endpoint; fresh installs stay model-free.
+INTERFACE_CONTRACT_VERSION = "1.56.1"
diff --git a/src/local_inference_env.py b/src/local_inference_env.py
--- a/src/local_inference_env.py
+++ b/src/local_inference_env.py
@@ -548,2 +548,2 @@
-        f"{MODEL_ENV} (`unitares model` writes it) or serve exactly one model "
-        "at the endpoint."
+        f"{MODEL_ENV} (`unitares model` writes it), or explicitly configure "
+        f"{MODEL_BASE_URL_ENV} for an endpoint serving exactly one model."
@@ -736,3 +736,5 @@
-    endpoint's only served model, when it lists exactly one. With several
-    served and none named, nothing is guessed. Blocking (it may ask the
-    endpoint); async callers run it with ``asyncio.to_thread``.
+    explicitly configured endpoint's only served model, when it lists exactly
+    one. A fresh install never selects an incidental model at the default
+    Ollama address. With several served and none named, nothing is guessed.
+    Blocking (it may ask the endpoint); async callers run it with
+    ``asyncio.to_thread``.
@@ -742,0 +745,2 @@
+    if not _resolve(MODEL_BASE_URL_ENV, _normalize_base_setting):
+        return ""
diff --git a/src/mcp_handlers/schemas/core.py b/src/mcp_handlers/schemas/core.py
--- a/src/mcp_handlers/schemas/core.py
+++ b/src/mcp_handlers/schemas/core.py
@@ -1028 +1028 @@
-            "endpoint's only served model."
+            "sole served model at an explicitly configured UNITARES_MODEL_BASE_URL."
diff --git a/src/mcp_handlers/support/inference_registry.py b/src/mcp_handlers/support/inference_registry.py
--- a/src/mcp_handlers/support/inference_registry.py
+++ b/src/mcp_handlers/support/inference_registry.py
@@ -297 +297,2 @@
-                        "a model, a call uses the endpoint's only served model, "
+                        "a model, a call uses the sole served model only when "
+                        "UNITARES_MODEL_BASE_URL is explicitly configured, "
--- a/scripts/unitares
+++ b/scripts/unitares
@@ -996,0 +997,9 @@
+_homebrew_update() {
+    local arg
+    local -a options=()
+    for arg in "$@"; do
+        [ "$arg" = "--homebrew" ] || options+=("$arg")
+    done
+    python3 "$(_repo_root)/scripts/install/homebrew_update.py" "${options[@]+"${options[@]}"}"
+}
+
@@ -1026 +1035 @@
-        echo "       Native upgrades still require stopping both writers, backup and explicit migration. See docs/install/CHOOSING_INSTALLATION.md." >&2
+        echo "       Use 'unitares update' for the coordinated native upgrade lifecycle. See docs/install/CHOOSING_INSTALLATION.md." >&2
@@ -1380,0 +1390,4 @@
+    if _has_homebrew_option "$@" || _is_homebrew_package; then
+        _homebrew_update "$@"
+        return $?
+    fi
@@ -1597,0 +1611,7 @@
+  update --homebrew [--check|--resume|--abort|--cleanup-backups] [--yes]
+                    [--accept-identity-change] [--retain-backups N]
+                    [--older-than-days N]
+                                    Refresh and upgrade the managed formulae,
+                                    back up, migrate, restart and verify, or
+                                    dry-run indexed backup retention cleanup.
+                                    An interrupted update resumes from its journal
@@ -1599,2 +1619,2 @@
-  services. Configuration/bootstrap must already be complete. No migrations
-  run during start. Native update is still a separate backed-up procedure.
+  installation. Configuration/bootstrap must already be complete. No
+  migrations run during start or as a Homebrew formula hook.
--- a/scripts/install/homebrew_services.py
+++ b/scripts/install/homebrew_services.py
@@ -265,0 +266,3 @@
+        info = directory.lstat()
+        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
+            raise Refusal('The UNITARES runtime directory must be a private directory owned by you.')
@@ -275,0 +279,22 @@
+    def check_update_barrier(self):
+        directory = self.prefix / 'var/unitares'
+        journal = directory / 'native-update.json'
+        if not os.path.lexists(journal):
+            return
+        directory_info = directory.lstat()
+        journal_info = journal.lstat()
+        if (not stat.S_ISDIR(directory_info.st_mode) or directory_info.st_uid != os.getuid()
+                or directory_info.st_mode & 0o022 or not stat.S_ISREG(journal_info.st_mode)
+                or journal_info.st_uid != os.getuid() or journal_info.st_mode & 0o077):
+            raise Refusal('The native update journal is not a private regular file owned by you.')
+        try:
+            state = json.loads(journal.read_text())
+            stage = state['stage']
+        except (OSError, ValueError, TypeError, KeyError) as exc:
+            raise Refusal('The native update journal is unreadable; inspect it before starting writers.') from exc
+        if stage not in ('complete', 'aborted'):
+            raise Refusal(
+                f'Native update stage {stage!r} is unfinished; keep writers stopped and run '
+                '`unitares update --resume`.'
+            )
+
@@ -314 +339,3 @@
-    def start(self, check=False, timeout=60):
+    def start(self, check=False, timeout=60, allow_update_stage=False):
+        if not allow_update_stage:
+            self.check_update_barrier()
--- /dev/null
+++ b/scripts/install/homebrew_update.py
@@ -0,0 +1,1285 @@
+#!/usr/bin/env python3
+"""Coordinate a safe update of the packaged macOS Homebrew installation.
+
+Homebrew installs immutable application kegs, but it does not own the UNITARES
+database transition.  This command is the explicit operator boundary between
+those two jobs: refresh and install the reviewed formulae, while UNITARES owns
+writer quiescence, backup, migrations, restart and recovery evidence.
+
+Formula hooks must never call this module.  It is intentionally interactive
+unless ``--yes`` is supplied, and its journal makes an interrupted update
+resumable by the newly installed keg.
+"""
+
+from __future__ import annotations
+
+import argparse
+from datetime import datetime, timedelta, timezone
+import hashlib
+import json
+import os
+from pathlib import Path
+import socket
+import stat
+import subprocess
+import sys
+import tempfile
+
+try:  # Imported as a package in tests and as a script from an installed keg.
+    from .homebrew_services import Homebrew, Refusal, WRITERS, run
+except ImportError:  # pragma: no cover - exercised by installed-package CI
+    from homebrew_services import Homebrew, Refusal, WRITERS, run
+
+
+TAP = "cirwel/unitares"
+FORMULAE = (
+    "unitares",
+    "unitares-lease-plane",
+    "apache-age",
+    "unitares-pgvector",
+)
+QUALIFIED_FORMULAE = tuple(f"{TAP}/{name}" for name in FORMULAE)
+JOURNAL_VERSION = 1
+BACKUP_INDEX_VERSION = 1
+CLEANUP_JOURNAL_VERSION = 1
+FINAL_STAGES = frozenset({"complete", "aborted"})
+
+
+def _utc_now() -> str:
+    return datetime.now(timezone.utc).isoformat()
+
+
+def _target_version(formula: dict) -> str:
+    stable = str(formula.get("versions", {}).get("stable") or "")
+    revision = int(formula.get("revision") or 0)
+    if not stable:
+        raise Refusal("Homebrew returned a formula without a stable version.")
+    return f"{stable}_{revision}" if revision else stable
+
+
+class NativeUpdater:
+    def __init__(self, brew: Homebrew):
+        self.brew = brew
+        self.state_dir = brew.prefix / "var/unitares"
+        self.journal_path = self.state_dir / "native-update.json"
+        self.backup_index_path = self.state_dir / "native-update-backups.json"
+        self.cleanup_journal_path = self.state_dir / "native-update-cleanup.json"
+
+    def _brew_process(self, *args: str, timeout: int = 1800, refresh: bool = False):
+        env = dict(self.brew.env, HOMEBREW_NO_ANALYTICS="1")
+        if refresh:
+            env.pop("HOMEBREW_NO_AUTO_UPDATE", None)
+        result = run([self.brew.brew, *args], env=env, timeout=timeout)
+        if result.returncode:
+            diagnostics = (result.stderr or result.stdout).strip()
+            if diagnostics:
+                print(f"Homebrew diagnostics:\n{diagnostics}", file=sys.stderr)
+            raise Refusal(
+                f"Homebrew {' '.join(args)} failed. Inspect the diagnostics above; "
+                "if an update journal was created, continue with `unitares update --resume`."
+            )
+        return result
+
+    def refresh_tap(self) -> None:
+        print("… Refreshing Homebrew and tap metadata")
+        self._brew_process("update", timeout=900, refresh=True)
+
+    def inventory(self) -> dict[str, dict[str, object]]:
+        result = self._brew_process(
+            "info", "--json=v2", "--formula", *QUALIFIED_FORMULAE
+        )
+        try:
+            formulae = json.loads(result.stdout)["formulae"]
+            by_name = {item["name"]: item for item in formulae}
+        except (json.JSONDecodeError, KeyError, TypeError) as exc:
+            raise Refusal(
+                "Homebrew returned an unreadable UNITARES package inventory."
+            ) from exc
+        if set(by_name) != set(FORMULAE):
+            raise Refusal(
+                "Homebrew did not return the complete managed UNITARES package set."
+            )
+        inventory: dict[str, dict[str, object]] = {}
+        for name in FORMULAE:
+            formula = by_name[name]
+            if formula.get("tap") != TAP:
+                raise Refusal(f"{name} is not owned by the {TAP} tap.")
+            installed = formula.get("installed") or []
+            linked = str(formula.get("linked_keg") or "")
+            if not installed or not linked:
+                raise Refusal(
+                    f"The managed {name} formula is not installed and linked."
+                )
+            inventory[name] = {
+                "installed": linked,
+                "target": _target_version(formula),
+                "pinned": bool(formula.get("pinned")),
+            }
+        return inventory
+
+    def repair_managed_links(self) -> None:
+        """Repair the narrow interruption window between Homebrew unlink/link."""
+        result = self._brew_process(
+            "info", "--json=v2", "--formula", *QUALIFIED_FORMULAE
+        )
+        try:
+            formulae = json.loads(result.stdout)["formulae"]
+            by_name = {item["name"]: item for item in formulae}
+        except (json.JSONDecodeError, KeyError, TypeError) as exc:
+            raise Refusal(
+                "Homebrew returned an unreadable UNITARES package inventory."
+            ) from exc
+        if set(by_name) != set(FORMULAE):
+            raise Refusal(
+                "Homebrew did not return the complete managed UNITARES package set."
+            )
+        if len(FORMULAE) != len(QUALIFIED_FORMULAE):
+            raise Refusal("The managed Homebrew formula configuration is inconsistent.")
+        for name, qualified in zip(FORMULAE, QUALIFIED_FORMULAE):
+            formula = by_name[name]
+            if formula.get("tap") != TAP:
+                raise Refusal(f"{name} is not owned by the {TAP} tap.")
+            if not formula.get("installed"):
+                raise Refusal(
+                    f"The interrupted update left no installed {name} keg. Reinstall that managed formula, "
+                    "then run `unitares update --resume`."
+                )
+            if not formula.get("linked_keg"):
+                print(f"… Repairing interrupted Homebrew link for {name}")
+                self._brew_process("link", qualified, timeout=300)
+
+    @staticmethod
+    def changes(inventory: dict[str, dict[str, object]]) -> dict[str, tuple[str, str]]:
+        return {
+            name: (str(item["installed"]), str(item["target"]))
+            for name, item in inventory.items()
+            if item["installed"] != item["target"]
+        }
+
+    def _secure_state_dir(self, *, create: bool) -> bool:
+        if not os.path.lexists(self.state_dir):
+            if not create:
+                return False
+            self.state_dir.mkdir(mode=0o700, parents=True)
+        info = self.state_dir.lstat()
+        if (
+            not stat.S_ISDIR(info.st_mode)
+            or info.st_uid != os.getuid()
+            or info.st_mode & 0o022
+        ):
+            raise Refusal(f"{self.state_dir} must be a private directory owned by you.")
+        return True
+
+    def _write_private_json(self, path: Path, value: dict) -> None:
+        self._secure_state_dir(create=True)
+        fd, temporary = tempfile.mkstemp(prefix=".native-update-", dir=self.state_dir)
+        try:
+            os.fchmod(fd, 0o600)
+            with os.fdopen(fd, "w") as output:
+                json.dump(value, output, indent=2, sort_keys=True)
+                output.write("\n")
+                output.flush()
+                os.fsync(output.fileno())
+            os.replace(temporary, path)
+        finally:
+            try:
+                os.unlink(temporary)
+            except FileNotFoundError:
+                pass
+
+    def write_journal(self, state: dict) -> None:
+        state["updated_at"] = _utc_now()
+        self._write_private_json(self.journal_path, state)
+
+    def read_journal(self, *, required: bool = True) -> dict | None:
+        if not self._secure_state_dir(create=False):
+            if required:
+                raise Refusal("No interrupted native update is available to resume.")
+            return None
+        if not os.path.lexists(self.journal_path):
+            if required:
+                raise Refusal("No interrupted native update is available to resume.")
+            return None
+        info = self.journal_path.lstat()
+        if (
+            not stat.S_ISREG(info.st_mode)
+            or info.st_uid != os.getuid()
+            or info.st_mode & 0o077
+        ):
+            raise Refusal(
+                f"{self.journal_path} must be a regular private file owned by you."
+            )
+        try:
+            state = json.loads(self.journal_path.read_text())
+        except (OSError, json.JSONDecodeError) as exc:
+            raise Refusal(
+                "The native update journal is unreadable; preserve it and inspect before continuing."
+            ) from exc
+        if (
+            not isinstance(state, dict)
+            or state.get("journal_version") != JOURNAL_VERSION
+            or not isinstance(state.get("stage"), str)
+        ):
+            raise Refusal("The native update journal has an unsupported format.")
+        if state["stage"] not in FINAL_STAGES:
+            required_fields = {
+                "config_sha256": str,
+                "target": dict,
+                "writers_were_running": bool,
+            }
+            if any(
+                not isinstance(state.get(key), kind)
+                for key, kind in required_fields.items()
+            ):
+                raise Refusal(
+                    "The native update journal is incomplete; preserve and inspect it."
+                )
+            target = state["target"]
+            if set(target) != set(FORMULAE) or any(
+                not isinstance(target[name], dict)
+                or not isinstance(target[name].get("target"), str)
+                or not isinstance(target[name].get("installed"), str)
+                for name in FORMULAE
+            ):
+                raise Refusal("The native update journal has an invalid package plan.")
+        return state
+
+    def read_backup_index(self) -> dict:
+        if not self._secure_state_dir(create=False) or not os.path.lexists(
+            self.backup_index_path
+        ):
+            return {"index_version": BACKUP_INDEX_VERSION, "entries": []}
+        info = self.backup_index_path.lstat()
+        if (
+            not stat.S_ISREG(info.st_mode)
+            or info.st_uid != os.getuid()
+            or info.st_mode & 0o077
+        ):
+            raise Refusal(
+                f"{self.backup_index_path} must be a regular private file owned by you."
+            )
+        try:
+            index = json.loads(self.backup_index_path.read_text())
+        except (OSError, json.JSONDecodeError) as exc:
+            raise Refusal("The native backup index is unreadable; preserve and inspect it.") from exc
+        entries = index.get("entries") if isinstance(index, dict) else None
+        if (
+            not isinstance(index, dict)
+            or index.get("index_version") != BACKUP_INDEX_VERSION
+            or not isinstance(entries, list)
+        ):
+            raise Refusal("The native backup index has an unsupported format.")
+        required = {
+            "path": str,
+            "sha256": str,
+            "size": int,
+            "target": str,
+            "verified_at": str,
+        }
+        if any(
+            not isinstance(entry, dict)
+            or any(not isinstance(entry.get(key), kind) for key, kind in required.items())
+            or len(entry["sha256"]) != 64
+            for entry in entries
+        ):
+            raise Refusal("The native backup index contains an invalid entry.")
+        return index
+
+    @staticmethod
+    def _file_sha256(path: Path) -> str:
+        digest = hashlib.sha256()
+        with path.open("rb") as source:
+            for chunk in iter(lambda: source.read(1024 * 1024), b""):
+                digest.update(chunk)
+        return digest.hexdigest()
+
+    def record_backup(self, path: Path, target: str) -> None:
+        index = self.read_backup_index()
+        value = str(path)
+        index["entries"] = [
+            entry for entry in index["entries"] if entry["path"] != value
+        ]
+        index["entries"].append(
+            {
+                "path": value,
+                "sha256": self._file_sha256(path),
+                "size": path.stat().st_size,
+                "target": target,
+                "verified_at": _utc_now(),
+            }
+        )
+        index["updated_at"] = _utc_now()
+        self._write_private_json(self.backup_index_path, index)
+
+    def read_cleanup_journal(self) -> dict | None:
+        if not self._secure_state_dir(create=False) or not os.path.lexists(
+            self.cleanup_journal_path
+        ):
+            return None
+        info = self.cleanup_journal_path.lstat()
+        if (
+            not stat.S_ISREG(info.st_mode)
+            or info.st_uid != os.getuid()
+            or info.st_mode & 0o077
+        ):
+            raise Refusal(
+                f"{self.cleanup_journal_path} must be a regular private file owned by you."
+            )
+        try:
+            cleanup = json.loads(self.cleanup_journal_path.read_text())
+        except (OSError, json.JSONDecodeError) as exc:
+            raise Refusal(
+                "The native backup-cleanup journal is unreadable; preserve and inspect it."
+            ) from exc
+        if (
+            not isinstance(cleanup, dict)
+            or cleanup.get("journal_version") != CLEANUP_JOURNAL_VERSION
+            or cleanup.get("stage") not in {"planned", "deleting", "complete"}
+            or not isinstance(cleanup.get("candidates"), list)
+            or not all(isinstance(value, str) for value in cleanup["candidates"])
+            or not isinstance(cleanup.get("deleted", []), list)
+            or not all(isinstance(value, str) for value in cleanup.get("deleted", []))
+            or not isinstance(cleanup.get("retain"), int)
+            or cleanup["retain"] < 1
+            or not isinstance(cleanup.get("older_than_days"), int)
+            or cleanup["older_than_days"] < 0
+        ):
+            raise Refusal("The native backup-cleanup journal has an invalid format.")
+        return cleanup
+
+    @staticmethod
+    def _entry_time(entry: dict) -> datetime:
+        try:
+            value = datetime.fromisoformat(entry["verified_at"])
+        except ValueError as exc:
+            raise Refusal("The native backup index contains an invalid timestamp.") from exc
+        if value.tzinfo is None:
+            raise Refusal("The native backup index contains a timezone-free timestamp.")
+        return value
+
+    def _protected_backup_paths(self, *, retain: int, index: dict) -> set[str]:
+        ordered = sorted(index["entries"], key=self._entry_time, reverse=True)
+        protected = {entry["path"] for entry in ordered[:retain]}
+        journal = self.read_journal(required=False)
+        if journal:
+            backup = journal.get("backup")
+            if isinstance(backup, str):
+                protected.add(backup)
+            superseded = journal.get("superseded_backups", [])
+            if isinstance(superseded, list):
+                protected.update(value for value in superseded if isinstance(value, str))
+        return protected
+
+    def _verify_indexed_backup(self, entry: dict, backup_dir: Path) -> Path:
+        path = Path(entry["path"])
+        try:
+            root = backup_dir.resolve(strict=True)
+            resolved = path.resolve(strict=True)
+            info = path.lstat()
+        except OSError as exc:
+            raise Refusal(f"Indexed backup is missing or inaccessible: {path}") from exc
+        if resolved.parent != root:
+            raise Refusal(f"Indexed backup escapes the configured backup directory: {path}")
+        if (
+            not stat.S_ISREG(info.st_mode)
+            or info.st_uid != os.getuid()
+            or info.st_mode & 0o077
+            or info.st_size != entry["size"]
+            or self._file_sha256(path) != entry["sha256"]
+        ):
+            raise Refusal(f"Indexed backup no longer matches its verified record: {path}")
+        pg_restore = self.brew.prefix / "opt/postgresql@17/bin/pg_restore"
+        result = subprocess.run(
+            [str(pg_restore), "--list", str(path)],
+            stdout=subprocess.DEVNULL,
+            stderr=subprocess.DEVNULL,
+            timeout=60,
+        )
+        if result.returncode:
+            raise Refusal(f"Indexed backup no longer passes pg_restore verification: {path}")
+        return path
+
+    def cleanup_backups(
+        self, *, retain: int = 3, older_than_days: int = 30, apply: bool = False
+    ) -> int:
+        if retain < 1:
+            raise Refusal("Backup cleanup must retain at least one verified backup.")
+        if older_than_days < 0:
+            raise Refusal("Backup cleanup age cannot be negative.")
+        update = self.read_journal(required=False)
+        if update and update["stage"] not in FINAL_STAGES:
+            raise Refusal(
+                "Backup cleanup is blocked while a native update is unfinished. Resume or safely abort it first."
+            )
+        backup_dir = Path(
+            os.environ.get(
+                "UNITARES_BACKUP_DIR", str(Path.home() / ".unitares/backups")
+            )
+        ).expanduser()
+        if not backup_dir.exists():
+            print(f"No native backup directory exists at {backup_dir}.")
+            return 0
+        directory_info = backup_dir.lstat()
+        if (
+            not stat.S_ISDIR(directory_info.st_mode)
+            or directory_info.st_uid != os.getuid()
+            or directory_info.st_mode & 0o022
+        ):
+            raise Refusal(f"{backup_dir} must be a private directory owned by you.")
+
+        index = self.read_backup_index()
+        entries = {entry["path"]: entry for entry in index["entries"]}
+        root = backup_dir.resolve(strict=True)
+        verified_entries = []
+        stale_names = set()
+        outside_names = set()
+        for entry in index["entries"]:
+            path = Path(entry["path"])
+            if not os.path.lexists(path):
+                stale_names.add(entry["path"])
+                continue
+            try:
+                resolved = path.resolve(strict=True)
+            except OSError as exc:
+                raise Refusal(
+                    f"Indexed backup is inaccessible and cannot be classified safely: {path}"
+                ) from exc
+            if resolved.parent != root:
+                outside_names.add(entry["path"])
+                continue
+            self._verify_indexed_backup(entry, backup_dir)
+            verified_entries.append(entry)
+        cleanup = self.read_cleanup_journal()
+        resume_plan = bool(
+            cleanup
+            and cleanup["stage"] != "complete"
+            and (apply or cleanup["stage"] == "deleting")
+        )
+        policy_retain = cleanup["retain"] if resume_plan else retain
+        policy_age = cleanup["older_than_days"] if resume_plan else older_than_days
+        verified_index = {"entries": verified_entries}
+        protected = self._protected_backup_paths(
+            retain=policy_retain, index=verified_index
+        )
+        if resume_plan:
+            assert cleanup is not None
+            candidate_names = cleanup["candidates"]
+            print(
+                f"Using recorded cleanup policy: retain {policy_retain}, older than {policy_age} day(s)."
+            )
+            if cleanup["stage"] == "deleting" and not apply:
+                print(
+                    "An interrupted backup-cleanup plan is waiting; this dry run shows its remaining work."
+                )
+        else:
+            cutoff = datetime.now(timezone.utc) - timedelta(days=policy_age)
+            candidate_names = [
+                entry["path"]
+                for entry in verified_entries
+                if entry["path"] not in protected and self._entry_time(entry) <= cutoff
+            ]
+            candidate_names.extend(
+                sorted(value for value in stale_names if value not in protected)
+            )
+            cleanup = None
+
+        for value in candidate_names:
+            if value not in entries:
+                if not cleanup or value not in cleanup.get("deleted", []):
+                    raise Refusal(
+                        f"Cleanup journal references an unindexed backup: {value}"
+                    )
+                continue
+            if value in protected:
+                raise Refusal(f"Cleanup plan now names a protected backup: {value}")
+            if not os.path.lexists(value):
+                # A hard interruption can land after unlink but before the
+                # deletion receipt is durably rewritten. A fresh stale index
+                # record is also safe to reconcile. Existing changed files
+                # still fail closed through full verification above.
+                continue
+            if value in outside_names:
+                raise Refusal(
+                    f"Cleanup plan names a backup outside the configured directory: {value}"
+                )
+
+        if not candidate_names:
+            print(
+                f"No indexed backups are eligible; retaining {len(verified_entries)} verified backup(s), including the newest {policy_retain} and anything newer than {policy_age} day(s)."
+            )
+            if outside_names:
+                print(
+                    f"Left {len(outside_names)} out-of-directory index record(s) untouched."
+                )
+            print("Homebrew kegs are not modified; Homebrew remains their cleanup owner.")
+            return 0
+
+        for value in candidate_names:
+            if value in stale_names or not os.path.lexists(value):
+                verb = "Remove stale index entry" if apply else "Would remove stale index entry"
+            else:
+                verb = "Remove" if apply else "Would remove"
+            print(f"{verb}: {value}")
+        if not apply:
+            if not resume_plan:
+                cleanup = {
+                    "journal_version": CLEANUP_JOURNAL_VERSION,
+                    "stage": "planned",
+                    "created_at": _utc_now(),
+                    "candidates": candidate_names,
+                    "deleted": [],
+                    "retain": policy_retain,
+                    "older_than_days": policy_age,
+                }
+                self._write_private_json(self.cleanup_journal_path, cleanup)
+            print("Dry run only. Re-run with --yes to delete exactly this eligible set.")
+            print("Homebrew kegs are not modified; Homebrew remains their cleanup owner.")
+            return 0
+
+        if cleanup is None or cleanup["stage"] == "complete":
+            cleanup = {
+                "journal_version": CLEANUP_JOURNAL_VERSION,
+                "stage": "planned",
+                "created_at": _utc_now(),
+                "candidates": candidate_names,
+                "deleted": [],
+                "retain": policy_retain,
+                "older_than_days": policy_age,
+            }
+            self._write_private_json(self.cleanup_journal_path, cleanup)
+        cleanup["stage"] = "deleting"
+        self._write_private_json(self.cleanup_journal_path, cleanup)
+        deleted = set(cleanup.get("deleted", []))
+        for value in cleanup["candidates"]:
+            if value in deleted:
+                continue
+            entry = entries.get(value)
+            path = Path(value)
+            if entry is not None and os.path.lexists(path):
+                if value in self._protected_backup_paths(
+                    retain=policy_retain, index=verified_index
+                ):
+                    raise Refusal(f"Cleanup candidate became protected: {value}")
+                self._verify_indexed_backup(entry, backup_dir).unlink()
+            deleted.add(value)
+            cleanup["deleted"] = sorted(deleted)
+            self._write_private_json(self.cleanup_journal_path, cleanup)
+
+        index["entries"] = [
+            entry for entry in index["entries"] if entry["path"] not in deleted
+        ]
+        index["updated_at"] = _utc_now()
+        self._write_private_json(self.backup_index_path, index)
+        cleanup["stage"] = "complete"
+        cleanup["completed_at"] = _utc_now()
+        self._write_private_json(self.cleanup_journal_path, cleanup)
+        retained_verified = sum(
+            entry["path"] not in deleted for entry in verified_entries
+        )
+        print(
+            f"Removed or reconciled {len(deleted)} indexed backup(s); retained {retained_verified} verified backup(s)."
+        )
+        if outside_names:
+            print(f"Left {len(outside_names)} out-of-directory index record(s) untouched.")
+        print("Homebrew kegs were not modified; Homebrew remains their cleanup owner.")
+        return 0
+
+    def _database_value(self, sql: str) -> str:
+        public_url, env = self.brew.database_environment()
+        psql = self.brew.prefix / "opt/postgresql@17/bin/psql"
+        result = run(
+            [str(psql), "-X", "-Atq", "-v", "ON_ERROR_STOP=1", public_url, "-c", sql],
+            env=env,
+            timeout=30,
+        )
+        if result.returncode:
+            raise Refusal("Could not inspect the configured UNITARES database.")
+        return result.stdout.strip()
+
+    def schema_version(self) -> int:
+        value = self._database_value(
+            "SELECT COALESCE(MAX(version), 0) FROM core.schema_migrations"
+        )
+        try:
+            return int(value)
+        except ValueError as exc:
+            raise Refusal("The database returned an invalid schema version.") from exc
+
+    def agent_count(self) -> int:
+        value = self._database_value("SELECT count(*) FROM core.agents")
+        try:
+            return int(value)
+        except ValueError as exc:
+            raise Refusal("The database returned an invalid identity count.") from exc
+
+    def verify_quiesced(self) -> None:
+        records = self.brew.info()
+        if any(
+            records[name].get("running")
+            or records[name].get("loaded")
+            or records[name].get("registered")
+            for name in WRITERS
+        ):
+            raise Refusal(
+                "A Homebrew writer is still registered or running; no migration was attempted."
+            )
+        for name in WRITERS:
+            port = self.brew.ports[name]
+            try:
+                with socket.create_connection(("127.0.0.1", port), timeout=0.3):
+                    raise Refusal(
+                        f"Port {port} still has a listener; no migration was attempted."
+                    )
+            except Refusal:
+                raise
+            except OSError:
+                pass
+        clients = self._database_value(
+            "SELECT count(*) FROM pg_stat_activity "
+            "WHERE datname=current_database() AND pid<>pg_backend_pid() "
+            "AND backend_type='client backend'"
+        )
+        if clients != "0":
+            raise Refusal(
+                f"The selected database still has {clients} other connection(s); "
+                "stop their writers before resuming."
+            )
+
+    def backup_database(self, target: str, *, pristine: bool = True) -> Path:
+        backup_dir = Path(
+            os.environ.get(
+                "UNITARES_BACKUP_DIR", str(Path.home() / ".unitares/backups")
+            )
+        ).expanduser()
+        backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
+        info = backup_dir.lstat()
+        if (
+            not stat.S_ISDIR(info.st_mode)
+            or info.st_uid != os.getuid()
+            or info.st_mode & 0o022
+        ):
+            raise Refusal(f"{backup_dir} must be a private directory owned by you.")
+        safe_target = "".join(
+            char if char.isalnum() or char in "._-" else "-" for char in target
+        )
+        path = (
+            backup_dir
+            / f"unitares-{datetime.now().strftime('%Y%m%d-%H%M%S')}-before-{safe_target}.dump"
+        )
+        public_url, env = self.brew.database_environment()
+        pg_dump = self.brew.prefix / "opt/postgresql@17/bin/pg_dump"
+        pg_restore = self.brew.prefix / "opt/postgresql@17/bin/pg_restore"
+        failure = (
+            "The database backup failed, so no package or schema change was made."
+            if pristine
+            else "The refreshed database backup failed. The existing update state was preserved and no retry was attempted."
+        )
+        verification_failure = (
+            "The database backup could not be verified, so no package or schema change was made."
+            if pristine
+            else "The refreshed database backup could not be verified. The existing update state was preserved and no retry was attempted."
+        )
+        created = False
+        try:
+            fd = os.open(
+                path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
+            )
+            created = True
+            with os.fdopen(fd, "wb") as output:
+                result = subprocess.run(
+                    [str(pg_dump), "--format=custom", public_url],
+                    env=env,
+                    stdout=output,
+                    stderr=subprocess.DEVNULL,
+                    timeout=600,
+                )
+            if result.returncode or not path.stat().st_size:
+                path.unlink()
+                created = False
+                raise Refusal(failure)
+            check = subprocess.run(
+                [str(pg_restore), "--list", str(path)],
+                env=env,
+                stdout=subprocess.DEVNULL,
+                stderr=subprocess.DEVNULL,
+                timeout=60,
+            )
+            if check.returncode:
+                path.unlink()
+                created = False
+                raise Refusal(verification_failure)
+        except (OSError, subprocess.TimeoutExpired):
+            if created:
+                try:
+                    path.unlink()
+                except OSError:
+                    pass
+            raise Refusal(failure)
+        except KeyboardInterrupt:
+            if created:
+                try:
+                    path.unlink()
+                except OSError:
+                    pass
+            raise
+        try:
+            self.record_backup(path, target)
+        except (OSError, Refusal) as exc:
+            consequence = (
+                "No package or schema change was made"
+                if pristine
+                else "The existing update state was preserved and no retry was attempted"
+            )
+            raise Refusal(
+                f"The database backup was verified at {path}, but its retention record could not be written. "
+                f"{consequence}; preserve the backup and repair the private runtime directory."
+            ) from exc
+        print(f"✓ Verified database backup: {path}")
+        return path
+
+    def migration_plan(self) -> tuple[bool, str]:
+        public_url, env = self.brew.database_environment()
+        python = self.brew.prefix / "opt/unitares/libexec/venv/bin/python"
+        script = self.brew.app / "scripts/dev/apply_migrations.py"
+        result = run(
+            [str(python), str(script), "--db-url", public_url], env=env, timeout=120
+        )
+        output = "\n".join(
+            part.strip() for part in (result.stdout, result.stderr) if part.strip()
+        )
+        if result.returncode:
+            raise Refusal("The installed migration planner refused the database state.")
+        return "No pending migrations" not in output, output
+
+    def apply_migrations(self) -> None:
+        self.verify_quiesced()
+        public_url, env = self.brew.database_environment()
+        python = self.brew.prefix / "opt/unitares/libexec/venv/bin/python"
+        script = self.brew.app / "scripts/dev/apply_migrations.py"
+        result = run(
+            [
+                str(python),
+                str(script),
+                "--db-url",
+                public_url,
+                "--apply",
+                "--dialectic-writers-quiesced",
+            ],
+            env=env,
+            timeout=900,
+        )
+        if result.stdout.strip():
+            print(result.stdout.strip())
+        if result.returncode:
+            if result.stderr.strip():
+                print(result.stderr.strip(), file=sys.stderr)
+            raise Refusal(
+                "Database migrations did not complete. The new package remains installed and both writers "
+                "remain stopped; repair forward, then run `unitares update --resume`."
+            )
+
+    def managed_pins(self, action: str) -> None:
+        for name in FORMULAE:
+            result = run([self.brew.brew, action, name], env=self.brew.env, timeout=60)
+            # unpin is allowed to report that a formula was not pinned; pin is
+            # idempotent on current Homebrew. Other failures are actionable.
+            if result.returncode and action == "pin":
+                raise Refusal(
+                    f"Could not pin {name}; pin the managed UNITARES packages before continuing."
+                )
+
+    def formula_state(self) -> dict[str, dict[str, object]]:
+        result = self._brew_process(
+            "info", "--json=v2", "--installed", "--formula", timeout=300
+        )
+        try:
+            formulae = json.loads(result.stdout)["formulae"]
+            return {
+                str(item.get("full_name") or item["name"]): {
+                    "linked_keg": str(item.get("linked_keg") or ""),
+                    "installed": sorted(
+                        str(version["version"]) for version in item["installed"]
+                    ),
+                }
+                for item in formulae
+            }
+        except (json.JSONDecodeError, KeyError, TypeError) as exc:
+            raise Refusal(
+                "Homebrew returned an unreadable installed-formula inventory."
+            ) from exc
+
+    def _upgrade_packages(self) -> None:
+        self._secure_state_dir(create=True)
+        log_path = self.state_dir / "native-update-homebrew.log"
+        env = dict(self.brew.env, HOMEBREW_NO_INSTALL_CLEANUP="1")
+        try:
+            fd = os.open(
+                log_path,
+                os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
+                0o600,
+            )
+            with os.fdopen(fd, "w") as output:
+                result = subprocess.run(
+                    [self.brew.brew, "upgrade", "--formula", *QUALIFIED_FORMULAE],
+                    env=env,
+                    text=True,
+                    stdout=output,
+                    stderr=subprocess.STDOUT,
+                    timeout=3600,
+                )
+        except (OSError, subprocess.TimeoutExpired) as exc:
+            raise Refusal(
+                f"The Homebrew package transaction did not finish; inspect {log_path}, "
+                "then run `unitares update --resume`. If the command is no longer on PATH, run "
+                "`$(brew --prefix)/opt/unitares/bin/unitares update --resume`."
+            ) from exc
+        if result.returncode:
+            raise Refusal(
+                f"The Homebrew package transaction failed; inspect {log_path}. Both writers remain "
+                "stopped; then run `unitares update --resume`. If the command is no longer on PATH, run "
+                "`$(brew --prefix)/opt/unitares/bin/unitares update --resume`."
+            )
+
+    def install_packages(self, target: dict[str, dict[str, object]]) -> None:
+        self.managed_pins("unpin")
+        try:
+            self._upgrade_packages()
+            installed = self.inventory()
+            mismatches = [
+                name
+                for name in FORMULAE
+                if installed[name]["installed"] != target[name]["target"]
+            ]
+            if mismatches:
+                raise Refusal(
+                    "Homebrew did not activate the planned versions for: "
+                    + ", ".join(mismatches)
+                )
+        except BaseException as original:
+            try:
+                self.managed_pins("pin")
+            except Refusal as pin_error:
+                if isinstance(original, Refusal):
+                    raise Refusal(
+                        f"{original} Additionally, restoring managed pins failed: {pin_error}"
+                    ) from original
+                print(
+                    f"warning: restoring managed pins failed: {pin_error}",
+                    file=sys.stderr,
+                )
+            raise
+        else:
+            # Managed packages stay pinned between explicit UNITARES updates so
+            # a broad `brew upgrade` cannot split the server/extension set.
+            self.managed_pins("pin")
+
+    def reexec(self) -> None:
+        cli = self.brew.prefix / "bin/unitares"
+        if not os.access(cli, os.X_OK):
+            raise Refusal(
+                "The upgraded package did not install an executable unitares CLI."
+            )
+        sys.stdout.flush()
+        sys.stderr.flush()
+        os.execve(
+            cli,
+            [str(cli), "update", "--resume", "--yes"],
+            os.environ.copy(),
+        )
+
+    @staticmethod
+    def _confirm(prompt: str, assume_yes: bool) -> bool:
+        if assume_yes:
+            return True
+        if not sys.stdin.isatty():
+            raise Refusal("Not a terminal; re-run with --yes to proceed.")
+        return input(f"{prompt} [y/N] ").strip().lower() in {"y", "yes"}
+
+    def report(
+        self, inventory: dict[str, dict[str, object]], *, local_metadata: bool
+    ) -> None:
+        print("Installation: Homebrew")
+        for name in FORMULAE:
+            item = inventory[name]
+            suffix = (
+                "" if item["installed"] == item["target"] else f" → {item['target']}"
+            )
+            print(f"  {name}: {item['installed']}{suffix}")
+        if local_metadata:
+            print(
+                "Tap metadata: locally cached (the apply command refreshes it before changing packages)."
+            )
+
+    def begin(self, *, check: bool, assume_yes: bool) -> int:
+        self.brew.configure()
+        existing = self.read_journal(required=False)
+        if existing and existing["stage"] not in FINAL_STAGES:
+            raise Refusal(
+                f"An update stopped at stage {existing['stage']!r}; run `unitares update --resume`."
+            )
+        if check:
+            inventory = self.inventory()
+            self.report(inventory, local_metadata=True)
+            pending, plan = self.migration_plan()
+            if plan:
+                print(plan)
+            if self.changes(inventory) or pending:
+                print(
+                    "Run `unitares update` to refresh the tap and perform the coordinated update."
+                )
+            else:
+                print(
+                    "✓ Installed packages and database schema match the locally cached tap."
+                )
+            return 0
+
+        self.refresh_tap()
+        inventory = self.inventory()
+        self.report(inventory, local_metadata=False)
+        changes = self.changes(inventory)
+        pending, plan = self.migration_plan()
+        if not changes and not pending:
+            self.managed_pins("pin")
+            print("✓ Already current; managed UNITARES packages are pinned.")
+            return 0
+        if plan:
+            print(plan)
+        target_label = str(inventory["unitares"]["target"])
+        if not self._confirm(
+            f"Stop both writers, make a verified backup, install {target_label}, apply migrations and verify health?",
+            assume_yes,
+        ):
+            print("Nothing changed.")
+            return 0
+
+        records = self.brew.info()
+        writer_states = [bool(records[name].get("running")) for name in WRITERS]
+        if any(writer_states) and not all(writer_states):
+            raise Refusal(
+                "Only one UNITARES writer is running; reconcile the native services before updating."
+            )
+        state = {
+            "journal_version": JOURNAL_VERSION,
+            "created_at": _utc_now(),
+            "stage": "planned",
+            "target": inventory,
+            "writers_were_running": all(writer_states),
+            "config_sha256": hashlib.sha256(self.brew.config.read_bytes()).hexdigest(),
+        }
+        self.write_journal(state)
+        return self.resume(state=state)
+
+    def abort(self) -> int:
+        state = self.read_journal(required=True)
+        assert state is not None
+        if state["stage"] in FINAL_STAGES:
+            print(f"Native update journal is already {state['stage']}.")
+            return 0
+        if state["stage"] not in {"planned", "stopped", "backed_up"}:
+            raise Refusal(
+                "This update cannot be abandoned because packages or schema may have changed; repair forward with "
+                "`unitares update --resume`."
+            )
+        self.brew.configure()
+        if hashlib.sha256(self.brew.config.read_bytes()).hexdigest() != state.get(
+            "config_sha256"
+        ):
+            raise Refusal(
+                "Restore the configuration recorded for this update before abandoning it."
+            )
+        self.repair_managed_links()
+        self.managed_pins("pin")
+        live = self.inventory()
+        changed = [
+            name
+            for name in FORMULAE
+            if live[name]["installed"] != state["target"][name]["installed"]
+        ]
+        if changed:
+            raise Refusal(
+                "This update cannot be abandoned because installed versions changed for: "
+                + ", ".join(changed)
+                + ". Repair forward with `unitares update --resume`."
+            )
+        before = state.get("formula_state_before")
+        if before is not None:
+            if not isinstance(before, dict):
+                raise Refusal(
+                    "The update journal contains an unreadable Homebrew formula inventory."
+                )
+            after = self.formula_state()
+            if after != before:
+                state["formula_state_at_abort"] = after
+                state["formula_changes_at_abort"] = sorted(
+                    name
+                    for name in set(before) | set(after)
+                    if before.get(name) != after.get(name)
+                )
+        if "schema_before" in state and self.schema_version() != state["schema_before"]:
+            raise Refusal(
+                "This update cannot be abandoned because the schema version changed; repair forward with "
+                "`unitares update --resume`."
+            )
+        state["stage"] = "aborted"
+        state["aborted_at"] = _utc_now()
+        state["abort_reason"] = "operator abandoned before package or schema change"
+        self.write_journal(state)
+        if state["writers_were_running"]:
+            self.brew.start()
+        else:
+            print("Writers were stopped before the update and remain stopped.")
+        print("Native update safely abandoned before any package or schema change.")
+        return 0
+
+    def resume(
+        self,
+        *,
+        state: dict | None = None,
+        accept_identity_change: bool = False,
+        assume_yes: bool = False,
+    ) -> int:
+        loaded_from_journal = state is None
+        state = state or self.read_journal(required=True)
+        assert state is not None
+        initial_stage = state["stage"]
+        if state["stage"] in FINAL_STAGES:
+            print(f"Native update journal is already {state['stage']}.")
+            return 0
+        self.brew.configure()
+        if hashlib.sha256(self.brew.config.read_bytes()).hexdigest() != state.get(
+            "config_sha256"
+        ):
+            raise Refusal(
+                "The private native configuration changed during the update. Writers remain stopped; "
+                "inspect the configuration and journal before resuming."
+            )
+        if accept_identity_change and state["stage"] != "verification_failed":
+            raise Refusal(
+                "--accept-identity-change is only valid for a recorded identity verification failure."
+            )
+        if state["stage"] == "verification_failed":
+            self.verify_quiesced()
+            if not accept_identity_change:
+                raise Refusal(
+                    "Identity count changed during the quiesced update. Inspect the database and backup, "
+                    "then explicitly continue with `unitares update --resume --accept-identity-change`."
+                )
+            state["agent_count_accepted"] = self.agent_count()
+            state["identity_change_accepted_at"] = _utc_now()
+            state["stage"] = "migrated"
+            self.write_journal(state)
+        if state["stage"] == "planned":
+            self.brew.stop()
+            self.brew.configure()
+            self.verify_quiesced()
+            state["stage"] = "stopped"
+            state["schema_before"] = self.schema_version()
+            state["agent_count_before"] = self.agent_count()
+            self.write_journal(state)
+        if state["stage"] == "stopped":
+            self.verify_quiesced()
+            try:
+                backup = self.backup_database(
+                    str(state["target"]["unitares"]["target"])
+                )
+            except Refusal:
+                state["stage"] = "aborted"
+                self.write_journal(state)
+                if state["writers_were_running"]:
+                    self.brew.start()
+                raise
+            state["backup"] = str(backup)
+            state["stage"] = "backed_up"
+            self.write_journal(state)
+        if state["stage"] == "backed_up":
+            self.verify_quiesced()
+            package_inventory = state["target"]
+            if loaded_from_journal:
+                # Tap metadata can change between any interrupted journal stage
+                # and this recovery. Resolve it again before package changes and
+                # require renewed consent for a different target.
+                self.refresh_tap()
+                self.repair_managed_links()
+                refreshed = self.inventory()
+                targets_changed = any(
+                    refreshed[name]["target"] != state["target"][name]["target"]
+                    for name in FORMULAE
+                )
+                self.report(refreshed, local_metadata=False)
+                if targets_changed and not self._confirm(
+                    "The tap target changed since this update began. Continue with the refreshed package set?",
+                    assume_yes,
+                ):
+                    raise Refusal(
+                        "Target change was not accepted; writers remain stopped. Review and run "
+                        "`unitares update --resume` to confirm it, or `unitares update --abort` "
+                        "to restore prior state while abort remains safe."
+                    )
+                if targets_changed:
+                    state.setdefault("superseded_targets", []).append(
+                        {
+                            name: state["target"][name]["target"]
+                            for name in FORMULAE
+                        }
+                    )
+                for name in FORMULAE:
+                    state["target"][name]["target"] = refreshed[name]["target"]
+                package_inventory = {
+                    name: {
+                        **state["target"][name],
+                        "installed": refreshed[name]["installed"],
+                    }
+                    for name in FORMULAE
+                }
+            if loaded_from_journal and initial_stage == "backed_up":
+                # A prior package attempt may have been interrupted. Refresh
+                # evidence immediately before retrying so even external writes
+                # between attempts are included in the new backup.
+                previous = state.get("backup")
+                state["schema_before"] = self.schema_version()
+                state["agent_count_before"] = self.agent_count()
+                backup = self.backup_database(
+                    str(state["target"]["unitares"]["target"]), pristine=False
+                )
+                if previous and previous != str(backup):
+                    state.setdefault("superseded_backups", []).append(previous)
+                state["backup"] = str(backup)
+                self.write_journal(state)
+            if self.changes(package_inventory):
+                if "formula_state_before" not in state:
+                    state["formula_state_before"] = self.formula_state()
+                    self.write_journal(state)
+                self.install_packages(state["target"])
+                state["formula_state_after"] = self.formula_state()
+                state["stage"] = "packages_installed"
+                self.write_journal(state)
+                self.reexec()
+                raise AssertionError("reexec returned")
+            self.managed_pins("pin")
+            if "formula_state_before" in state:
+                state["formula_state_after"] = self.formula_state()
+            state["stage"] = "packages_installed"
+            self.write_journal(state)
+        if state["stage"] in {"packages_installed", "migration_failed"}:
+            self.verify_quiesced()
+            try:
+                self.apply_migrations()
+            except Refusal:
+                state["stage"] = "migration_failed"
+                state["schema_after"] = self.schema_version()
+                self.write_journal(state)
+                raise
+            state["schema_after"] = self.schema_version()
+            state["agent_count_after"] = self.agent_count()
+            if state["agent_count_after"] != state["agent_count_before"]:
+                state["stage"] = "verification_failed"
+                self.write_journal(state)
+                raise Refusal(
+                    "Identity count changed during the quiesced update. Writers remain stopped; inspect the database and backup, "
+                    "then explicitly continue with `unitares update --resume --accept-identity-change`."
+                )
+            state["stage"] = "migrated"
+            self.write_journal(state)
+        if state["stage"] in {"migrated", "restart_failed"}:
+            if state["writers_were_running"]:
+                try:
+                    self.brew.start(allow_update_stage=True)
+                except Refusal:
+                    state["stage"] = "restart_failed"
+                    self.write_journal(state)
+                    raise
+            else:
+                self.brew.check_schema()
+                print("Writers were stopped before the update and remain stopped.")
+            state["stage"] = "complete"
+            self.write_journal(state)
+            print(
+                f"✓ Native update complete. Schema {state['schema_before']} → {state['schema_after']}. "
+                f"Verified backup: {state['backup']}"
+            )
+            return 0
+        raise Refusal(f"Cannot resume unknown native update stage {state['stage']!r}.")
+
+
+def main(argv: list[str] | None = None) -> int:
+    parser = argparse.ArgumentParser(description=__doc__)
+    group = parser.add_mutually_exclusive_group()
+    group.add_argument(
+        "--check",
+        action="store_true",
+        help="report against locally cached tap metadata",
+    )
+    group.add_argument(
+        "--resume", action="store_true", help="resume the durable native update journal"
+    )
+    group.add_argument(
+        "--abort",
+        action="store_true",
+        help="abandon only if no managed package or schema version changed",
+    )
+    group.add_argument(
+        "--cleanup-backups",
+        action="store_true",
+        help="dry-run indexed backup retention; add --yes to delete eligible backups",
+    )
+    parser.add_argument(
+        "--yes",
+        "-y",
+        action="store_true",
+        help="confirm the coordinated update non-interactively",
+    )
+    parser.add_argument(
+        "--accept-identity-change",
+        action="store_true",
+        help="after inspection, explicitly accept a recorded identity-count change",
+    )
+    parser.add_argument(
+        "--retain-backups",
+        type=int,
+        default=3,
+        metavar="N",
+        help="with --cleanup-backups, always retain at least the newest N indexed backups (default: 3)",
+    )
+    parser.add_argument(
+        "--older-than-days",
+        type=int,
+        default=30,
+        metavar="N",
+        help="with --cleanup-backups, only consider indexed backups at least N days old (default: 30)",
+    )
+    args = parser.parse_args(argv)
+    if args.accept_identity_change and not args.resume:
+        parser.error("--accept-identity-change requires --resume")
+    if not args.cleanup_backups and (
+        args.retain_backups != 3 or args.older_than_days != 30
+    ):
+        parser.error("--retain-backups and --older-than-days require --cleanup-backups")
+    try:
+        brew = Homebrew()
+        updater = NativeUpdater(brew)
+        if args.check:
+            return updater.begin(check=True, assume_yes=args.yes)
+        with brew.lock():
+            if args.resume:
+                return updater.resume(
+                    accept_identity_change=args.accept_identity_change,
+                    assume_yes=args.yes,
+                )
+            if args.abort:
+                return updater.abort()
+            if args.cleanup_backups:
+                return updater.cleanup_backups(
+                    retain=args.retain_backups,
+                    older_than_days=args.older_than_days,
+                    apply=args.yes,
+                )
+            return updater.begin(check=False, assume_yes=args.yes)
+    except (Refusal, OSError) as exc:
+        print(f"error: {exc}", file=sys.stderr)
+        return 1
+    except KeyboardInterrupt:
+        return 130
+
+
+if __name__ == "__main__":
+    raise SystemExit(main())
