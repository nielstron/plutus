{ inputs, cell }:

inputs.cells.plutus.library.pkgs.writeShellApplication {
  name = "autobuild-docs";
  runtimeInputs = [
    inputs.cells.plutus.packages.repo-root
    cell.packages.sphinx-toolchain
  ];
  text = ''
    root="$(repo-root)"
    sphinx-autobuild -j 4 -n "$root/doc/read-the-docs-site" "$root/doc/read-the-docs-site/_build"
  '';
}