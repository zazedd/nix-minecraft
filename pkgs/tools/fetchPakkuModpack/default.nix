{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  pakku,
  jq,
  cacert,
}:

let
  fetchPakkuModpack =
    {
      # Provide a path to the pakku modpack source directory
      src ? null,
      # Or provide GitHub coordinates
      owner ? null,
      repo ? null,
      rev ? null,
      srcHash ? "",
      # Hash of the modpack output
      packHash ? "",
      # CurseForge API key (required if modpack has CurseForge projects)
      curseforgeApiKey ? null,
      # GitHub access token
      githubAccessToken ? null,
      ...
    }@args:
    let
      srcNull = src == null;
      ownerNull = owner == null;
      repoNull = repo == null;
      revNull = rev == null;

      mSrc =
        if !srcNull then src
        else if !ownerNull && !repoNull && !revNull then
          fetchFromGitHub {
            inherit owner repo rev;
            hash = srcHash;
          }
        else throw "either 'src' or ('owner' and 'repo' and 'rev') must be provided";

      pakkuJson = builtins.fromJSON (builtins.readFile (mSrc + "/pakku.json"));

      lockFile = 
        let lockPath = mSrc + "/pakku-lock.json";
        in if builtins.pathExists lockPath
           then builtins.fromJSON (builtins.readFile lockPath)
           else null;

      pname = args.pname or pakkuJson.name or "pakku-modpack";
      version = args.version or pakkuJson.version or "";

      drv = fetchPakkuModpack args;

      # extract client-only file names from lock file
      clientOnlyFiles =
        if lockFile != null then
          lib.flatten (
            map (proj:
              if (proj.side or "BOTH") == "CLIENT" then
                map (f: f.file_name) (proj.files or [])
              else []
            ) (lockFile.projects or [])
          )
        else [];
    in

    stdenvNoCC.mkDerivation (
      finalAttrs:
      {
        inherit pname version;
        src = mSrc;

        nativeBuildInputs = [
          pakku
          jq
          cacert
        ];

        SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
        HOME = "/build/home";
        CLIENT_ONLY_FILES = builtins.toJSON clientOnlyFiles;

        buildPhase = ''
          runHook preBuild
          mkdir -p $HOME

          mkdir -p workdir
          cp -r $src/* workdir/
          chmod -R u+w workdir
          cd workdir

          ${lib.optionalString (curseforgeApiKey != null) ''
            export CURSEFORGE_API_KEY="${curseforgeApiKey}"
          ''}
          ${lib.optionalString (githubAccessToken != null) ''
            export GITHUB_ACCESS_TOKEN="${githubAccessToken}"
          ''}

          # Fetch all mod files using pakku (-y for non-interactive)
          pakku -y fetch
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out

          # copy mods
          if [ -d "mods" ]; then
            mkdir -p $out/mods

            readarray -t client_files < <(echo "$CLIENT_ONLY_FILES" | jq -r '.[]')

            for mod in mods/*; do
              if [ -f "$mod" ]; then
                modname=$(basename "$mod")
                is_client_only=false

                for client_file in "''${client_files[@]}"; do
                  if [ "$modname" = "$client_file" ]; then
                    is_client_only=true
                    echo "skipping client-only mod: $modname"
                    break
                  fi
                done

                if [ "$is_client_only" = "false" ]; then
                  cp "$mod" $out/mods/
                fi
              fi
            done
          fi

          # copy common overrides (config, etc.)
          for override in ${lib.escapeShellArgs (pakkuJson.overrides or [])}; do
            # Skip negated patterns (starting with !)
            if [[ "$override" != "!"* ]] && [ -e "$override" ]; then
              mkdir -p "$out/$(dirname "$override")"
              cp -r "$override" "$out/$override" 2>/dev/null || true
            fi
          done

          for override in ${lib.escapeShellArgs (pakkuJson.server_overrides or [])}; do
            if [ -e "$override" ]; then
              mkdir -p "$out/$(dirname "$override")"
              cp -r "$override" "$out/$override" 2>/dev/null || true
            fi
          done

          cp pakku.json $out/
          [ -f "pakku-lock.json" ] && cp pakku-lock.json $out/

          rm -rf $out/.pakku 2>/dev/null || true
          rm -rf $out/.git 2>/dev/null || true

          runHook postInstall
        '';

        passthru = {
          manifest = pakkuJson;
          lock = lockFile;

          versions = {
            minecraft =
              if lockFile != null then
                builtins.head (lockFile.mc_versions or [])
              else null;

            loaders = if lockFile != null then lockFile.loaders or {} else {};
          };

          addFiles =
            files:
            stdenvNoCC.mkDerivation {
              inherit (drv) pname version;
              src = null;
              dontUnpack = true;
              dontConfigure = true;
              dontBuild = true;
              dontFixup = true;

              installPhase = ''
                cp -as "${drv}" $out
                chmod u+w -R $out
              ''
              + lib.concatLines (
                lib.mapAttrsToList (name: file: ''
                  mkdir -p "$out/$(dirname "${name}")"
                  cp -as "${file}" "$out/${name}"
                '') files
              );

              passthru = { 
                inherit (drv) manifest lock versions; 
              };
              meta = drv.meta or { };
            };
        };

        dontFixup = true;

        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = packHash;
      }
      // (builtins.removeAttrs args [
        "src" "owner" "repo" "rev" "srcHash" "packHash"
        "curseforgeApiKey" "githubAccessToken"
      ])
    );
in
fetchPakkuModpack
