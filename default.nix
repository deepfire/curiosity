let packages = {
    common           = ./common;
    node-editor      = ./node-editor;
  };
in (import ./../reflex-platform {
   }).project ({ pkgs, ... }: {
  name = "lift";

  inherit packages;

  shells = {
    ghcjs = [
      "common"
      "node-editor"
      ];
    ghc = [
      "common"
      "lift"
    ];
  };

  shellToolOverrides = ghc: old: {
    ghc-mod = null;
    ghcid = pkgs.haskell.lib.justStaticExecutables old.ghcid;
  };

  overrides = self: old: with pkgs.haskell.lib;
    let inherit (pkgs.haskell.lib) overrideCabal;
        unbreak = old: overrideCabal old (drv: { broken = false; });
        fix = { check ? false
              , jailbreak ? true
              , broken ? false }:
              x:
                ( if check     then id else dontCheck)
                ((if jailbreak then doJailbreak else id)
                 (if broken    then unbreak x else x));
        l = name: path: cabalExtras:
          fix {}
            (self.callCabal2nixWithOptions name path cabalExtras {});
        gh = owner: repo: rev: sha256: cabalExtras:
          fix {}
            (self.callCabal2nixWithOptions repo (pkgs.fetchFromGitHub { inherit owner repo rev sha256;}) cabalExtras {});
        sources = import ./nix/sources.nix {};
        niv = repo: { pkg ? repo
                    , subdir ? if pkg == repo then null else pkg
                    , check ? false, jailbreak ? true, broken ? false }:
          fix { inherit check jailbreak broken; }
            (self.callCabal2nixWithOptions
              pkg
              (sources."${repo}").outPath
              (if subdir == null
               then ""
               else "--subpath ${subdir}")
              {});
  in {
    ### Locals
    common                      = self.callCabal2nix "common" ./common {};
    lift                        = self.callCabal2nix "lift"   ./lift   {};

    ### IOHK
    cardano-prelude             = niv "cardano-prelude"
                                      { subdir = "cardano-prelude"; };
    contra-tracer               = niv "iohk-monitoring-framework"
                                      { pkg = "contra-tracer"; };
    directory-contents          = niv "directory-contents" {};
    io-sim                      = niv "ouroboros-network"
                                      { pkg = "io-sim"; };
    io-sim-classes              = niv "ouroboros-network"
                                      { pkg = "io-sim-classes"; };
    ouroboros-network-framework = niv "ouroboros-network"
                                      { pkg = "ouroboros-network-framework"; };
    ouroboros-network-testing   = niv "ouroboros-network"
                                      { pkg = "ouroboros-network-testing"; };
    network-mux                 = niv "ouroboros-network"
                                      { pkg = "network-mux";
                                        broken = true; };
    nothunks                    = fix { broken = true; } old."nothunks";
    canonical-json              = fix { broken = true; } old."canonical-json";
    typed-protocols             = niv "ouroboros-network"
                                      { pkg = "typed-protocols"; };
    typed-protocols-examples    = niv "ouroboros-network"
                                      { pkg = "typed-protocols-examples"; };
    Win32-network               = niv "ouroboros-network"
                                      { pkg = "Win32-network"; };

    ### Externals
    parsers-megaparsec          = fix { broken = true; } old."parsers-megaparsec";
    ghc-lib-parser              = self.callHackage "ghc-lib-parser" "8.10.2.20200916" {};
    websockets                  = niv "websockets" {};

    ### Luna IDE
    frontend-common       = dontCheck (doJailbreak (self.callCabal2nix "frontend-common"           ./lib                           {}));
    luna-api-definition   = dontCheck (doJailbreak (self.callCabal2nix "luna-api-definition"       ./api-definition/api-definition {}));

    container             = ds "container"         "1bac6323943afeb2b13d3e21e69ab4a537d3030e" "124wlvrybalr0xh3jsin2x5r3hcw846zafndg90lkyq529dcgm1x" "";
    convert               = ds "convert"           "d10f56856a656ee515bd0ddcfaba43ad10b70814" "1wxszfxmarrf1i1gcz4bhiv813qiks00wmy03rws7lmpr0009fbc" "";

    data-construction     = ds "data-construction" "91a341c5dec89fbf032199c0900c901e76ee7ed0" "0c43k1rypzg6jnmh5hm5jn2prgcwxq512z1i6jx899z1nfgzifas" "";
    data-layer            = ds "data-layer"        "1561bb0c339e756c8b7e09b6ec7a691859dfa211" "00hm1kwbfffmspcsj5yxd4jmhnryjvrvd6qywdqlfx1g4vwsprmr" "";
    data-prop             = ds "data-prop"         "f01ee9e01218ee1c69993bc5f853afe2af682f65" "17lz81xh289caj8skz7k66xny2alasc9nm32h633n8cj6qifl7rw" "";
    data-repr             = ds "data-repr"         "13c19a96db90b214bb27676ccb4149a3d69098bf" "1ra26pw97hh4zfzi27wjsy7a3lhjyrzf8a0i1nb6wqpi9rwfkj77" "";
    data-rtuple           = ds "data-rtuple"       "594532867fb643114d05e7cee8ee72c2e75d01bf" "15fkm8pjk0yg19yr9vc2f3w9ybikyiz4zrhhvalh8fzaq33b40w4" "";
    dependent-state       = ds "dependent-state"   "5517fd30a11515b3f635523e3012dbb92d93dfd4" "067myjh039qa6015smpkllz8jwqr8yapimk5r9yhm5nkqb9hdsxl" "";

    functor-utils         = ds "functor-utils"     "51c39f10daacaae7190de7d9be5e026d9e81af02" "03jbiacbm3bbqscgya5zkyra33vld0gpa451vcjfd95p7xv7d5kg" "";

    impossible            = ds "impossible"        "d00ad627e2ad744d298783807c247181b7ecae15" "1ypzmw56i2qjp89p8bc31qfxqxh9k3avhv3m5lvm4gni8zgzaxg7" "";

    lens-utils            = ds "lens-utils"        "92beec5427b5823b30b502029e2432e96e1ae031" "06kq6l237lsvp85rjgc396al3lxd5sdsbz7d5kgf6q53npayq13v" "";
    luna-lexer            = ds "luna"              "4a3a34fb67099dcaa28a76a2f6e705b203299d8e" "0x2lq86698bbqpgh4xisw47nwih4w74fslmpcv79yw0znj9kpqim" "--subpath syntax/text/lexer";

    monoid                = ds "monoid"            "20a14a0403d774383f870f4731af0393581b7066" "19zva1mxn08r8pz406wm64lihmnmxrp97r0sz98k24w4vgfsqs4v" "";
    monad-branch          = ds "monad-branch"      "554ccf8a4c4f28225467112fb1ed6c0bd6d638d3" "03zf70nriypq4rmsgj5a80ayqqgk9d57c53abbdsyf5yrfvjymsr" "";

    parsert               = ds "parsert"           "d613c488009ef90d2cd63fb5bcb4624eb0414a99" "03xvimhkgn4rwhylm2wyw43ba23gwi97w971vfa1rfii4iyiydaw" "";
    prologue              = ds "prologue"          "a973466beb8fd3c89177b1d92922dc1557b6a264" "0v9qq96np27bppxikfdwxfkc66pfg728gcb7p1gdi3rfp7dpdjp0" "";

    react-flux            = ds "react-flux"        "038212dc91ff7689efac6cdcb123ed622c578fc2" "1db3wm2gm48q7isl517fnzirw2y09s0w4hzj1cvy0x5gnqiiydcm" "";

    text-processing       = ds "text-processing"   "3cc205b1d047495d411a47d4064e361188c05e13" "1n593l4v4afaxsqcm4imx0fn6f007h7sd9r7dhyavzx6mv66d48a" "";
    typelevel             = ds "typelevel"         "7cd8bff92bd207f5de5875e85bcd997b2eedd1aa" "0aab7qm5szgimrqs78sp335xnxabip9s52vlv2s7r584bzssmzhd" "";

    vector-text           = ds "vector-text"       "02a820e2a1c2b68001cc1d98ef40d549bf5cab48" "06djbrh3fb2drj349x0ppvc2a322dxsbibxndl2j6bjdq4w98bvf" "";
    visualization-api     = ds "visualization-api" "4f3a72d46c9b7b5a7ff86add55984f21c6bbfd67" "1haf6cjly6ccwafnqv469p7gjf939af7g24nmr5h3dbgsgxlwx8k" "";
  };
})
