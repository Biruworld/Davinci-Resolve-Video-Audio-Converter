{
  description = "DaVinci Resolve Video Audio Converter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
      };

      python = pkgs.python3.withPackages (ps: [
        ps.pygobject3
      ]);
    in
    {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "davinci-converter";
        version = "4.0";

        src = ./.;

        nativeBuildInputs = [
          pkgs.wrapGAppsHook4
          pkgs.gobject-introspection
          pkgs.makeWrapper
        ];

        buildInputs = [
          pkgs.gtk4
          pkgs.libadwaita
          pkgs.ffmpeg-full
          python
        ];

        dontBuild = true;

        installPhase = ''
          mkdir -p $out/bin
          cp video-converter.py $out/bin/davinci-converter
          chmod +x $out/bin/davinci-converter
        '';

        postFixup = ''
          wrapProgram $out/bin/davinci-converter \
            --prefix PATH : ${pkgs.lib.makeBinPath [
              pkgs.ffmpeg-full
              pkgs.xdg-utils
            ]}
        '';
      };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/davinci-converter";
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          python
          pkgs.gobject-introspection
          pkgs.gtk4
          pkgs.libadwaita
          pkgs.ffmpeg-full
        ];
      };
    };
}
