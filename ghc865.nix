{ lib, stdenv, pkgsBuildTarget, targetPackages

# build-tools
, bootPkgs
, autoconf, automake, coreutils, fetchurl, fetchpatch, perl, python3, m4, sphinx
, bash

, libiconv ? null, ncurses

, # GHC can be built with system libffi or a bundled one.
  libffi ? null

, useLLVM ? !stdenv.targetPlatform.isx86 || stdenv.targetPlatform.isiOS
, # LLVM is conceptually a run-time-only depedendency, but for
  # non-x86, we need LLVM to bootstrap later stages, so it becomes a
  # build-time dependency too.
  buildLlvmPackages, llvmPackages

, # If enabled, GHC will be built with the GPL-free but slower integer-simple
  # library instead of the faster but GPLed integer-gmp library.
  enableIntegerSimple ? !(lib.any (lib.meta.platformMatch stdenv.hostPlatform) gmp.meta.platforms), gmp

, # If enabled, use -fPIC when compiling static libs.
  enableRelocatedStaticLibs ? stdenv.targetPlatform != stdenv.hostPlatform

, # Whether to build dynamic libs for the standard library (on the target
  # platform). Static libs are always built.
  enableShared ? !stdenv.targetPlatform.isWindows && !stdenv.targetPlatform.useiOSPrebuilt

, # Whether to build terminfo.
  enableTerminfo ? !stdenv.targetPlatform.isWindows

, # What flavour to build. An empty string indicates no
  # specific flavour and falls back to ghc default values.
  ghcFlavour ? lib.optionalString (stdenv.targetPlatform != stdenv.hostPlatform)
    (if useLLVM then "perf-cross" else "perf-cross-ncg")

, # Whether to disable the large address space allocator
  # necessary fix for iOS: https://www.reddit.com/r/haskell/comments/4ttdz1/building_an_osxi386_to_iosarm64_cross_compiler/d5qvd67/
  disableLargeAddressSpace ? stdenv.targetPlatform.isDarwin && stdenv.targetPlatform.isAarch64
}:

assert !enableIntegerSimple -> gmp != null;

let
  inherit (stdenv) buildPlatform hostPlatform targetPlatform;
  inherit (bootPkgs) ghc;

  # TODO(@Ericson2314) Make unconditional
  targetPrefix = lib.optionalString
    (targetPlatform != hostPlatform)
    "${targetPlatform.config}-";

  buildMK = ''
    BuildFlavour = ${ghcFlavour}
    ifneq \"\$(BuildFlavour)\" \"\"
    include mk/flavours/\$(BuildFlavour).mk
    endif
    DYNAMIC_GHC_PROGRAMS = ${if enableShared then "YES" else "NO"}
    INTEGER_LIBRARY = ${if enableIntegerSimple then "integer-simple" else "integer-gmp"}
  ''
    # We only need to build stage1 on most cross-compilation because
    # we will be running the compiler on the native system. In some
    # situations, like native Musl compilation, we need the compiler
    # to actually link to our new Libc. The iOS simulator is a special
    # exception because we can???t actually run simulators binaries
    # ourselves.
  + lib.optionalString (targetPlatform != hostPlatform) ''
    Stage1Only = ${if (targetPlatform.system == hostPlatform.system && !targetPlatform.isiOS) then "NO" else "YES"}
    CrossCompilePrefix = ${targetPrefix}
    HADDOCK_DOCS = NO
    BUILD_SPHINX_HTML = NO
    BUILD_SPHINX_PDF = NO
  '' + lib.optionalString enableRelocatedStaticLibs ''
    GhcLibHcOpts += -fPIC
    GhcRtsHcOpts += -fPIC
  '' + lib.optionalString targetPlatform.useAndroidPrebuilt ''
    EXTRA_CC_OPTS += -std=gnu99
  '';

  # Splicer will pull out correct variations
  libDeps = platform: lib.optional enableTerminfo ncurses
    ++ [libffi]
    ++ lib.optional (!enableIntegerSimple) gmp
    ++ lib.optional (platform.libc != "glibc" && !targetPlatform.isWindows) libiconv;

  toolsForTarget = [
    pkgsBuildTarget.targetPackages.stdenv.cc
  ] ++ lib.optional useLLVM buildLlvmPackages.llvm;

  targetCC = builtins.head toolsForTarget;

  # ld.gold is disabled for musl libc due to https://sourceware.org/bugzilla/show_bug.cgi?id=23856
  # see #84670 and #49071 for more background.
  useLdGold = targetPlatform.isLinux && !(targetPlatform.useLLVM or false) && !targetPlatform.isMusl;

in
stdenv.mkDerivation (rec {
  version = "8.6.5";
  name = "${targetPrefix}ghc-${version}";

  src = fetchurl {
    url = "https://downloads.haskell.org/ghc/${version}/ghc-${version}-src.tar.xz";
    sha256 = "0qg3zsmbk4rkwkc3jpas3zs74qaxmw4sp4v1mhsbj0a0dzls2jjd";
  };

  enableParallelBuilding = true;

  outputs = [ "out" "doc" ];

  patches = [
    # See upstream patch at
    # https://gitlab.haskell.org/ghc/ghc/-/merge_requests/4885. Since we build
    # from source distributions, the auto-generated configure script needs to be
    # patched as well, therefore we use an in-tree patch instead of pulling the
    # upstream patch. Don't forget to check backport status of the upstream patch
    # when adding new GHC releases in nixpkgs.
    ./respect-ar-path.patch

    (fetchpatch { # https://phabricator.haskell.org/D5123
     url = "https://gitlab.haskell.org/ghc/ghc/-/commit/13ff0b7ced097286e0d7b054f050871effe07f86.diff";
     name = "D5123.diff";
     sha256 = "140lmnqxra7xkwy370c5pyf8dgdwgmbpcrs1dapnwr2dh8bavn8c";
    })
    (fetchpatch { # https://github.com/haskell/haddock/issues/900
     url = "https://patch-diff.githubusercontent.com/raw/haskell/haddock/pull/983.diff";
     name = "loadpluginsinmodules.diff";
     sha256 = "0bvvv0zsfq2581zsir97zfkggc1kkircbbajc2fz3b169ycpbha1";
     extraPrefix = "utils/haddock/";
     stripLen = 1;
   })
  ];

  postPatch = "patchShebangs .";

  # GHC is a bit confused on its cross terminology.
  preConfigure = ''
    for env in $(env | grep '^TARGET_' | sed -E 's|\+?=.*||'); do
      export "''${env#TARGET_}=''${!env}"
    done
    # GHC is a bit confused on its cross terminology, as these would normally be
    # the *host* tools.
    export CC="${targetCC}/bin/${targetCC.targetPrefix}cc"
    export CXX="${targetCC}/bin/${targetCC.targetPrefix}cxx"
    # Use gold to work around https://sourceware.org/bugzilla/show_bug.cgi?id=16177
    export LD="${targetCC.bintools}/bin/${targetCC.bintools.targetPrefix}ld${lib.optionalString useLdGold ".gold"}"
    export AS="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}as"
    export AR="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}ar"
    export NM="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}nm"
    export RANLIB="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}ranlib"
    export READELF="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}readelf"
    export STRIP="${targetCC.bintools.bintools}/bin/${targetCC.bintools.targetPrefix}strip"

    echo -n "${buildMK}" > mk/build.mk
    sed -i -e 's|-isysroot /Developer/SDKs/MacOSX10.5.sdk||' configure
  '' + lib.optionalString (!stdenv.isDarwin) ''
    export NIX_LDFLAGS+=" -rpath $out/lib/ghc-${version}"
  '' + lib.optionalString stdenv.isDarwin ''
    export NIX_LDFLAGS+=" -no_dtrace_dof"
  '' + lib.optionalString targetPlatform.useAndroidPrebuilt ''
    sed -i -e '5i ,("armv7a-unknown-linux-androideabi", ("e-m:e-p:32:32-i64:64-v128:64:128-a:0:32-n32-S64", "cortex-a8", ""))' llvm-targets
  '' + lib.optionalString targetPlatform.isMusl ''
      echo "patching llvm-targets for musl targets..."
      echo "Cloning these existing '*-linux-gnu*' targets:"
      grep linux-gnu llvm-targets | sed 's/^/  /'
      echo "(go go gadget sed)"
      sed -i 's,\(^.*linux-\)gnu\(.*\)$,\0\n\1musl\2,' llvm-targets
      echo "llvm-targets now contains these '*-linux-musl*' targets:"
      grep linux-musl llvm-targets | sed 's/^/  /'

      echo "And now patching to preserve '-musleabi' as done with '-gnueabi'"
      # (aclocal.m4 is actual source, but patch configure as well since we don't re-gen)
      for x in configure aclocal.m4; do
        substituteInPlace $x \
          --replace '*-android*|*-gnueabi*)' \
                    '*-android*|*-gnueabi*|*-musleabi*)'
      done
  '';

  # TODO(@Ericson2314): Always pass "--target" and always prefix.
  configurePlatforms = [ "build" "host" ]
    ++ lib.optional (targetPlatform != hostPlatform) "target";
  # `--with` flags for libraries needed for RTS linker
  configureFlags = [
    "--datadir=$doc/share/doc/ghc"
    "--with-curses-includes=${ncurses.dev}/include" "--with-curses-libraries=${ncurses.out}/lib"
  ] ++ lib.optionals (libffi != null) ["--with-system-libffi" "--with-ffi-includes=${targetPackages.libffi.dev}/include" "--with-ffi-libraries=${targetPackages.libffi.out}/lib"
  ] ++ lib.optionals (targetPlatform == hostPlatform && !enableIntegerSimple) [
    "--with-gmp-includes=${targetPackages.gmp.dev}/include" "--with-gmp-libraries=${targetPackages.gmp.out}/lib"
  ] ++ lib.optionals (targetPlatform == hostPlatform && hostPlatform.libc != "glibc" && !targetPlatform.isWindows) [
    "--with-iconv-includes=${libiconv}/include" "--with-iconv-libraries=${libiconv}/lib"
  ] ++ lib.optionals (targetPlatform != hostPlatform) [
    "--enable-bootstrap-with-devel-snapshot"
  ] ++ lib.optionals useLdGold [
    "CFLAGS=-fuse-ld=gold"
    "CONF_GCC_LINKER_OPTS_STAGE1=-fuse-ld=gold"
    "CONF_GCC_LINKER_OPTS_STAGE2=-fuse-ld=gold"
  ] ++ lib.optionals (disableLargeAddressSpace) [
    "--disable-large-address-space"
  ];

  # Make sure we never relax`$PATH` and hooks support for compatibility.
  strictDeps = true;

  # Don???t add -liconv to LDFLAGS automatically so that GHC will add it itself.
  dontAddExtraLibs = true;

  nativeBuildInputs = [
    perl autoconf automake m4 python3 sphinx
    ghc bootPkgs.alex bootPkgs.happy bootPkgs.hscolour
  ];

  # For building runtime libs
  depsBuildTarget = toolsForTarget;

  buildInputs = [ perl bash ] ++ (libDeps hostPlatform);

  propagatedBuildInputs = [ targetPackages.stdenv.cc ]
    ++ lib.optional useLLVM llvmPackages.llvm;

  depsTargetTarget = map lib.getDev (libDeps targetPlatform);
  depsTargetTargetPropagated = map (lib.getOutput "out") (libDeps targetPlatform);

  # required, because otherwise all symbols from HSffi.o are stripped, and
  # that in turn causes GHCi to abort
  stripDebugFlags = [ "-S" ] ++ lib.optional (!targetPlatform.isDarwin) "--keep-file-symbols";

  # See #63511 - the only unstripped file is the debug rts which isn't meant to
  # be stripped.
  dontStrip = true;

  checkTarget = "test";

  hardeningDisable = [ "format" ] ++ lib.optional stdenv.targetPlatform.isMusl "pie";

  postInstall = ''
    # Install the bash completion file.
    install -D -m 444 utils/completion/ghc.bash $out/share/bash-completion/completions/${targetPrefix}ghc

    # Patch scripts to include "readelf" and "cat" in $PATH.
    for i in "$out/bin/"*; do
      test ! -h $i || continue
      egrep --quiet '^#!' <(head -n 1 $i) || continue
      sed -i -e '2i export PATH="$PATH:${lib.makeBinPath [ targetPackages.stdenv.cc.bintools coreutils ]}"' $i
    done
  ''
  # Temporary work-around for https://github.com/NixOS/nixpkgs/issues/66277
  + lib.optionalString hostPlatform.isAarch64 ''
    rm -rf "$doc/share/doc/ghc/html/libraries"
  '';

  passthru = {
    inherit bootPkgs targetPrefix;

    inherit llvmPackages;
    inherit enableShared;

    # Our Cabal compiler name
    haskellCompilerName = "ghc-${version}";
  };

  meta = {
    homepage = "http://haskell.org/ghc";
    description = "The Glasgow Haskell Compiler";
    maintainers = with lib.maintainers; [ marcweber andres peti ];
    timeout = 24 * 3600;
    inherit (ghc.meta) license platforms;
  };

} // lib.optionalAttrs targetPlatform.useAndroidPrebuilt {
  dontStrip = true;
  dontPatchELF = true;
  noAuditTmpdir = true;
})
