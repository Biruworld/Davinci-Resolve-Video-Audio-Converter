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
        version = "0.1.0";

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
        mkdir -p $out/share/applications

        cp video-converter.py $out/bin/davinci-converter
        chmod +x $out/bin/davinci-converter

        cat > $out/share/applications/sh.asterlusnce.davinciconverter.desktop <<EOF
        [Desktop Entry]
        Name=DaVinci Converter
        Comment=Video and audio converter for DaVinci Resolve
        Exec=davinci-converter
        Icon=video-x-generic
        Terminal=false
        Type=Application
        Categories=AudioVideo;Video;
        EOF
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
