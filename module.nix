# buildModule: build an out-of-tree kernel module against a kernel built by
# `buildKernel`.
#
# The kernel DERIVATION is the input, not a path to an unpacked tarball. That is
# the whole point: a module's symbol CRCs are derived from the exact
# Module.symvers and headers of the kernel it will be loaded into, so taking the
# kernel as a build input makes a CRC mismatch unrepresentable. You cannot
# accidentally build a module against last week's kernel, because "last week's
# kernel" is a different derivation and would produce a different module.
#
# This knows nothing about any particular module. ARCH, CROSS_COMPILE and the
# toolchain all come from the kernel's passthru, so the module is compiled by
# the same compiler that compiled the kernel -- which matters most on the bands
# where that compiler is unusual (k2.6's gcc 4.x, k3 ppc64's elfv1 ABI).
{ pkgs }:

{
  # Module name; also the derivation name.
  name,
  version ? "0",
  # Module source. Must contain a kbuild Makefile with an obj-m.
  src,
  # A derivation produced by buildKernel. Its `dev` output is used as KDIR.
  kernel,
  # Extra make variables, e.g. { KCFLAGS = "-mabi=elfv1"; }.
  makeVars ? { },
  # Extra flags appended verbatim to the make command line.
  extraMakeFlags ? [ ],
  # Anything the module's Makefile shells out to during the build (a codegen
  # step, a python script). The kernel's own toolchain is added automatically.
  nativeBuildInputs ? [ ],
  # Run before the module build; the source is already unpacked and writable.
  preBuild ? "",
  # How to enter the build. Two shapes exist in the wild:
  #
  #   "kbuild"  (default) -- a plain Makefile that is nothing but `obj-m := x.o`.
  #             We drive kbuild ourselves: make -C $KDIR M=$PWD modules
  #
  #   "wrapper" -- the Makefile has its own default target that does codegen
  #             first and then re-enters kbuild itself. We must run make in the
  #             MODULE directory and hand it the kernel tree by variable, or the
  #             codegen never runs.
  #
  # Getting this wrong is not a loud failure: driving kbuild directly against a
  # wrapper Makefile builds the objects and silently skips the generated
  # headers, so pick deliberately.
  entry ? "kbuild",
  # Make target. "modules" for entry = "kbuild"; usually "all" for a wrapper.
  makeTarget ? (if entry == "kbuild" then "modules" else "all"),
  # Make variable a wrapper Makefile reads for the kernel build tree. kbuild's
  # own convention is KDIR; some Makefiles use KERNELDIR.
  kdirVar ? "KDIR",
  # Escape hatches for a kernel derivation not produced by buildKernel. Default
  # to the kernel's passthru, which is what buildKernel populates.
  arch ? null,
  crossPrefix ? null,
  toolchain ? null,
}:

assert pkgs.lib.elem entry [ "kbuild" "wrapper" ]
  || throw "buildModule: entry must be \"kbuild\" or \"wrapper\", got ${entry}";

let
  inherit (pkgs) lib;
  pt = kernel.passthru or { };

  # kernelsmith's buildKernel exports `kernelArch`; accept a plain `arch` too so
  # a hand-rolled kernel derivation can be used without reshaping its passthru.
  arch' = if arch != null then arch
    else pt.kernelArch or pt.arch or (throw
      "buildModule: kernel has no kernelArch/arch in passthru; pass `arch`");
  crossPrefix' = if crossPrefix != null then crossPrefix
    else pt.crossPrefix or pt.cross or (throw
      "buildModule: kernel has no crossPrefix in passthru; pass `crossPrefix`");
  toolchain' = if toolchain != null then toolchain
    else pt.toolchain or (throw
      "buildModule: kernel has no toolchain in passthru; pass `toolchain`");
in
pkgs.stdenv.mkDerivation {
  pname = name;
  inherit version src;

  nativeBuildInputs = [ toolchain' ] ++ nativeBuildInputs
    ++ (with pkgs; [ gnumake bc perl ]);

  # The kernel build tree lives in the store and is read-only. kbuild is happy
  # with that for an out-of-tree build (everything it writes goes under M=), but
  # it does need the source copied somewhere writable, which the default
  # unpackPhase already handles.
  buildPhase = ''
    runHook preBuild
    ${preBuild}

    # `src` is a kbuild-internal variable (Makefile.build sets it per-directory
    # to the source dir of the object being built), and it is ALSO the name
    # stdenv exports for the derivation's source. make imports the environment,
    # so without this the module's Makefile sees src=/nix/store/...-source and
    # any `$(src)/…` path resolves into the read-only store copy rather than the
    # writable build directory. The symptom is a missing-prerequisite error
    # naming a store path, which reads like a packaging mistake rather than a
    # variable collision.
    unset src

    # 32-bit powerpc: arch/powerpc/Makefile does
    #   ifdef CONFIG_PPC32
    #   KBUILD_LDFLAGS_MODULE += arch/powerpc/lib/crtsavres.o
    # -- a BARE RELATIVE path, not $(objtree)-anchored. During modfinal the cwd
    # is the module directory (M=), not the kernel tree, so the link fails with
    # "cannot find arch/powerpc/lib/crtsavres.o" even though the file is present
    # in the build tree. It holds the out-of-line GPR save/restore helpers
    # (_savegpr_*/_restgpr_*) that gcc emits calls to on ppc32 and that are not
    # in libgcc.
    #
    # Mirror it at the path the linker actually looks for. Guarded on existence,
    # so this is a no-op on every other arch and on ppc64.
    if [ -f ${kernel.dev}/arch/powerpc/lib/crtsavres.o ]; then
      mkdir -p arch/powerpc/lib
      cp ${kernel.dev}/arch/powerpc/lib/crtsavres.o arch/powerpc/lib/
    fi

    make ${if entry == "kbuild"
           then "-C ${kernel.dev} M=$PWD"
           else "${kdirVar}=${kernel.dev}"} \
      ARCH=${arch'} \
      CROSS_COMPILE=${crossPrefix'} \
      ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: ''${k}="${v}"'') makeVars)} \
      ${lib.concatStringsSep " " extraMakeFlags} \
      -j$NIX_BUILD_CORES ${makeTarget}

    # Fail loudly rather than installing an empty output. A kbuild Makefile with
    # a mis-set obj-m exits 0 and produces nothing, which downstream reads as
    # "the module has no symbols" much later.
    if [ -z "$(find . -name '*.ko' -print -quit)" ]; then
      echo "buildModule: no .ko produced for ${name} (${kernel.name})" >&2
      exit 1
    fi
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    find . -name '*.ko' -exec cp {} $out/ \;
    runHook postInstall
  '';

  passthru = { inherit kernel; };

  meta.description = "${name} built against ${kernel.name}";
}
