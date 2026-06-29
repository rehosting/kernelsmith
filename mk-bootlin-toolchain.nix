# mkBootlinToolchain: vendor a prebuilt Bootlin (Buildroot) cross toolchain.
#
# This is the PRIMARY sourcing path for the k3/k4/k6 bands (gcc >= 5.4). Instead
# of compiling a toolchain, we fetch Bootlin's pinned prebuilt SDK tarball,
# extract it, run their relocate-sdk.sh (Bootlin SDKs hardcode their build-time
# path), and autoPatchelf the x86_64 host binaries onto the Nix loader.
#
# The k2.6 band (gcc 4.x) is NOT available from Bootlin and uses
# mk-cross-toolchain.nix (musl-cross-make) instead.
#
# Returns a derivation whose $out/bin holds <triple>-{gcc,ld,...}, matching the
# interface mk-cross-toolchain.nix produces (passthru.target is the triple).
{ pkgs }:

{
  # display name, e.g. "mipseb-k4"
  name,
  # the fetched Bootlin tarball (fetchurl), and the triple its binaries use
  tarball,
  # full Buildroot triple, e.g. "mips-buildroot-linux-musl"
  target,
  # the short CROSS_COMPILE alias Bootlin also ships, e.g. "mips-linux-"
  crossAlias ? null,
}:

pkgs.stdenv.mkDerivation {
  pname = "bootlin-${name}";
  version = "prebuilt";
  src = tarball;

  nativeBuildInputs = with pkgs; [ autoPatchelfHook ];
  # Shared libs the Bootlin host binaries (gcc, gdb, etc.) link against.
  buildInputs = with pkgs; [
    stdenv.cc.cc.lib # libstdc++, libgcc_s
    zlib
    ncurses # gdb / some frontends
    expat # gdb
    python3 # gdb pretty-printers (libpython)
    libxcrypt-legacy # libcrypt.so.1 for the bundled gdb _crypt python module
  ];

  # Bootlin tarballs unpack to a single <name>/ dir; strip it into $out.
  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    # The archive has one top-level dir; move its contents to $out.
    shopt -s dotglob
    cp -a */* $out/
    # Bootlin SDKs are relocatable but hardcode the build path; their script
    # rewrites it to the SDK's current location ($out).
    if [ -x "$out/relocate-sdk.sh" ]; then
      ( cd "$out" && ./relocate-sdk.sh )
    fi
    runHook postInstall
  '';

  # autoPatchelfHook runs in postFixup and rewrites the ELF interpreter/RPATH of
  # the host-side toolchain binaries onto the Nix store.
  dontStrip = true; # cross toolchain target libs must not be host-stripped

  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/${target}-gcc" --version | head -1
    "$out/bin/${target}-gcc" -dumpmachine
  '';

  passthru = {
    inherit target;
    cross = if crossAlias != null then crossAlias else "${target}-";
  };

  meta.description = "Bootlin prebuilt musl cross toolchain: ${target} (${name})";
}
