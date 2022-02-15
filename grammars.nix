{ stdenv, lib, runCommand, yj }:
let
  # HACK: nix < 2.6 has a bug in the toml parser, so we convert to JSON
  # before parsing
  languages-json = runCommand "languages-toml-to-json" { } ''
    ${yj}/bin/yj -t < ${./languages.toml} > $out
  '';
  languagesConfig =
    builtins.fromJSON (builtins.readFile (builtins.toPath languages-json));
  isGitGrammar = (grammar:
    builtins.hasAttr "source" grammar && builtins.hasAttr "git" grammar.source
    && builtins.hasAttr "rev" grammar.source);
  gitGrammars = builtins.filter isGitGrammar languagesConfig.grammar;
  buildGrammar = grammar:
    let
      source = builtins.fetchGit {
        url = grammar.source.git;
        rev = grammar.source.rev;
        allRefs = true;
      };
    in stdenv.mkDerivation rec {
      # see https://github.com/NixOS/nixpkgs/blob/fbdd1a7c0bc29af5325e0d7dd70e804a972eb465/pkgs/development/tools/parsing/tree-sitter/grammar.nix

      pname = "helix-tree-sitter-${grammar.name}";
      version = grammar.source.rev;

      src = if builtins.hasAttr "subpath" grammar.source then
        "${source}/${grammar.source.subpath}"
      else
        source;

      dontUnpack = true;
      dontConfigure = true;

      FLAGS = [
        "-I${src}/src"
        "-g"
        "-O3"
        "-fPIC"
        "-fno-exceptions"
        "-Wl,-z,relro,-z,now"
      ];

      NAME = grammar.name;

      buildPhase = ''
        runHook preBuild

        if [[ -e "$src/src/scanner.cc" ]]; then
          $CXX -c "$src/src/scanner.cc" -o scanner.o $FLAGS
        elif [[ -e "$src/src/scanner.c" ]]; then
          $CC -c "$src/src/scanner.c" -o scanner.o $FLAGS
        fi

        $CC -c "$src/src/parser.c" -o parser.o $FLAGS
        $CXX -shared -o $NAME.so *.o

        ls -al

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir $out
        mv $NAME.so $out/
        runHook postInstall
      '';

      # Strip failed on darwin: strip: error: symbols referenced by indirect symbol table entries that can't be stripped
      fixupPhase = lib.optionalString stdenv.isLinux ''
        runHook preFixup
        $STRIP $out/$NAME.so
        runHook postFixup
      '';
    };
  builtGrammars = builtins.map (grammar: {
    inherit (grammar) name;
    artifact = buildGrammar grammar;
  }) gitGrammars;
  grammarLinks = builtins.map (grammar:
    "ln -s ${grammar.artifact}/${grammar.name}.so $out/${grammar.name}.so")
    builtGrammars;
in runCommand "consolidated-helix-grammars" { } ''
  mkdir -p $out
  ${builtins.concatStringsSep "\n" grammarLinks}
''