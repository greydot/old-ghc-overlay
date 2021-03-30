self: super:

let 
    inherit (super.haskell) compiler packages;
    haskellLib = super.haskell.lib;
    callPackage = super.newScope { inherit haskellLib; overrides = super.haskell.packageOverrides; };
    ghc = callPackage ./ghc865.nix { inherit (super.python3Packages) sphinx; bootPkgs = super.haskell.packages.ghc865Binary; buildLlvmPackages = super.llvmPackages_6; };
in
{
  haskell = super.haskell // {
    compiler = super.haskell.compiler // {
      ghc865 = ghc;
    };
    packages = super.haskell.packages // {
      ghc865 = callPackage (super.path + "/pkgs/development/haskell-modules") {
        buildHaskellPackages = super.buildPackages.haskell.packages.ghc865;
        ghc = ghc;
        compilerConfig = callPackage ./configuration-ghc-8.6.x.nix { };
      };
    };
  };
}
