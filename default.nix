{
  lib,
  stdenv,
  callPackage,
  zig_0_16,
  pkg-config,
  libx11,
  libxft,
  libxinerama,
  lua5_4,
  freetype,
  fontconfig,
  gitRev ? "unknown",
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "oxwm";
  version = "${lib.substring 0 8 gitRev}";

  src = ./.;

  deps = callPackage ./build.zig.zon.nix {};

  nativeBuildInputs = [zig_0_16.hook pkg-config];

  buildInputs = [
    libx11
    libxinerama
    libxft
    lua5_4
    freetype
    fontconfig
  ];

  postInstall = ''
    install resources/oxwm.desktop -Dt $out/share/xsessions
    install -Dm644 resources/oxwm.1 -t $out/share/man/man1
    install -Dm644 templates/oxwm.lua -t $out/share/oxwm
  '';

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
  ];

  # tests require a running X server
  doCheck = false;

  passthru.providedSessions = ["oxwm"];

  meta = {
    description = "Dynamic window manager written in Zig, inspired by dwm";
    homepage = "https://github.com/tonybanters/oxwm";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "oxwm";
  };
})
